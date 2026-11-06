// The Nidhi milestone agent: verifies a developer's milestone on GitHub and, if it passes, pays it on-chain.
//
//   node src/agent.ts            check every committed milestone once (the agent GitHub Action runs this)
//   node src/agent.ts m1         just one milestone
//   node src/agent.ts --dry-run  verify and sign, but send nothing
//
// For each milestone the DAO has pre-signed (mandates/<id>.json):
//   1. skip it if the hook already used its grantId (paid once, never twice)
//   2. find the merged PR tagged "[<id>]" in the milestone's repo
//   3. pin the evidence to immutable SHAs and apply the DAO's rubric (it alone decides pass/fail)
//   4. let the model jury review it (it may only veto)
//   5. sign the EIP-712 Attestation with the AUDITOR key (an ENSv2 role on nidhi-dao.eth), evidenceHash = the spec
//      the DAO committed to, inputsHash = the SHA-pinned evidence
//   6. publish "<id>:pr<n>:<inputsHash>" to auditor.nidhi-dao.eth (the only record this agent may write)
//   7. send the payout: wrap, approve the router, swap through the ENS-gated hook. CCIP carries it to the grantee.
// The agent holds no power alone: the hook also needs the approver's signature, the ENS roles, the cap and the band.
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { createWalletClient, encodeAbiParameters, http, keccak256, parseAbi, toHex, type Address, type Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { sepolia } from "viem/chains";
import { evaluateRubric, fetchEvidence, findMilestonePr, hashJson, hashText } from "./lib.ts";
import { runJury } from "./llm/jury.ts";
import { loadMilestones, mandatePath, readMandate } from "./milestone.ts";
import { ATTESTATION_TYPES, MANDATE_TYPES, MAX_SQRT, MIN_SQRT, RPCS, knownHooks, transport, domain, hookData, poolKey, publicClient, repoRoot, sourceStack, toJson, zeroForOne } from "./stack.ts";
import { boardAbi, boardDeployment, bountySpecHash, ensureContributorName, githubOf, readBounties, validLabel, type BoardBounty } from "./bounty.ts";

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, "..");
if (fs.existsSync(path.join(repoRoot, ".env"))) process.loadEnvFile(path.join(repoRoot, ".env"));

const hookAbi = parseAbi(["function grantUsed(bytes32) view returns (bool)", "function remainingToday() view returns (uint256)", "function paused() view returns (bool)"]);
const wethAbi = parseAbi(["function deposit() payable", "function approve(address,uint256) returns (bool)", "function balanceOf(address) view returns (uint256)", "function allowance(address,address) view returns (uint256)"]);
const routerAbi = [{
  type: "function", name: "swap", stateMutability: "nonpayable",
  inputs: [
    { name: "key", type: "tuple", components: [{ name: "currency0", type: "address" }, { name: "currency1", type: "address" }, { name: "fee", type: "uint24" }, { name: "tickSpacing", type: "int24" }, { name: "hooks", type: "address" }] },
    { name: "params", type: "tuple", components: [{ name: "zeroForOne", type: "bool" }, { name: "amountSpecified", type: "int256" }, { name: "sqrtPriceLimitX96", type: "uint160" }] },
    { name: "hookData", type: "bytes" }, { name: "deadline", type: "uint256" }],
  outputs: [{ name: "delta", type: "int256" }],
}] as const;

/** paid if ANY ENS-gated hook (v4, v5, ...) has used this grantId: a redeploy must never pay a milestone twice */
async function usedAnywhere(grantId: Hex): Promise<boolean> {
  const pub = publicClient(11155111);
  for (const h of knownHooks()) if (await pub.readContract({ address: h, abi: hookAbi, functionName: "grantUsed", args: [grantId] })) return true;
  return false;
}

const log = (id: string, msg: string) => console.log(`[agent] ${id.padEnd(3)} ${msg}`);

async function publishToEns(id: string, value: string): Promise<Hex | null> {
  const key = process.env.AUDITOR_PRIVATE_KEY as Hex;
  const subs = JSON.parse(fs.readFileSync(path.join(repoRoot, "deployments", "sepolia-subnames.json"), "utf8"));
  const ens = JSON.parse(fs.readFileSync(path.join(repoRoot, "deployments", "sepolia-ens.json"), "utf8"));
  const enc = new TextEncoder();
  const name = new Uint8Array([7, ...enc.encode("auditor"), ens.label.length, ...enc.encode(ens.label), 3, ...enc.encode("eth"), 0]);
  const account = privateKeyToAccount(key);
  const pub = publicClient(11155111);
  if ((await pub.getBalance({ address: account.address })) === 0n) { log(id, "ENS publish skipped: the agent key has no Sepolia gas"); return null; }
  const wallet = createWalletClient({ chain: sepolia, transport: transport(11155111), account });
  const hash = await wallet.writeContract({ address: subs.grantsResolver, abi: parseAbi(["function setText(bytes name, string key, string value)"]), functionName: "setText", args: [toHex(name), "nidhi.attestation", value] });
  await pub.waitForTransactionReceipt({ hash });
  return hash;
}

async function handle(id: string, m: any, base: any, dryRun: boolean) {
  if (!fs.existsSync(mandatePath(id))) return log(id, "not committed by the DAO yet (node src/milestone.ts commit " + id + ")");
  const md = readMandate(id);
  const s = sourceStack();
  const pub = publicClient(s.chainId);
  if (md.hook.toLowerCase() !== s.hook.toLowerCase()) return log(id, "mandate was signed for a different hook: re-commit it");
  if (await usedAnywhere(md.mandate.grantId)) return log(id, "already paid");
  if (Number(md.mandate.deadline) < Date.now() / 1000) return log(id, "mandate expired: the DAO must re-commit it");

  const pr = await findMilestonePr(m.repo, id);
  if (!pr) return log(id, `waiting: no merged PR tagged [${id}] in ${m.repo}`);
  log(id, `PR #${pr.number} "${pr.title}" merged ${pr.mergedAt}`);

  // 3. evidence + the DAO's rubric (the spec the DAO signed fixes these rules)
  const rules = md.spec.rules;
  const rfp = fs.readFileSync(path.join(root, m.rfp), "utf8");
  const { evidence, diff } = await fetchEvidence(m.repo, pr.number);
  const results = evaluateRubric(evidence, rules, []);
  for (const r of results) log(id, `  ${r.pass ? "PASS" : "FAIL"}  ${r.rule.padEnd(24)} ${r.detail}`);
  // 4. the model jury may veto
  const jury = await runJury(rfp, diff);
  for (const j of jury.jurors) log(id, `  JURY  ${(j.status === "reviewed" ? `${j.provider}:${j.model}` : j.provider).padEnd(32)} ${j.status === "reviewed" ? j.review.verdict : `unavailable`}`);
  const pass = results.every((r) => r.pass) && !jury.veto;

  const inputs = { repo: evidence.repo, pr: evidence.pr, evidence, diffHash: hashText(diff), rfpHash: hashText(rfp) };
  const inputsHash = hashJson(inputs);
  const rubricHash = hashJson(rules);
  const record: any = { id, pr: pr.number, prTitle: pr.title, results, jury: { reviewed: jury.reviewed, veto: jury.veto, jurors: jury.jurors.map((j: any) => ({ provider: j.provider, model: j.model, status: j.status, verdict: j.review?.verdict })) }, inputsHash, rubricHash, specHash: md.specHash, at: new Date().toISOString(), pass };
  fs.mkdirSync(path.join(root, "out", "agent"), { recursive: true });
  const save = () => fs.writeFileSync(path.join(root, "out", "agent", `${id}.json`), toJson(record));
  if (!pass) { save(); return log(id, `REJECTED (${results.every((r) => r.pass) ? "jury veto" : "rubric failed"}): no attestation, no payout`); }

  // 5. sign the attestation: this spec (evidenceHash) is satisfied by this SHA-pinned evidence (inputsHash)
  const auditor = privateKeyToAccount(process.env.AUDITOR_PRIVATE_KEY as Hex);
  const attestation = { grantId: md.mandate.grantId, evidenceHash: md.specHash, inputsHash, rubricHash, issuedAt: BigInt(Math.floor(Date.now() / 1000)) };
  const auditorSig = await auditor.signTypedData({ domain: domain(s), types: ATTESTATION_TYPES, primaryType: "Attestation", message: attestation });
  record.attestation = { ...attestation, auditor: auditor.address, auditorSig };
  log(id, `VERIFIED: attestation signed by ${auditor.address}`);
  if (dryRun) { save(); return log(id, "dry run: nothing published or sent"); }

  // 6. publish to the agent's ENS name
  record.ensTx = await publishToEns(id, `${id}:pr${pr.number}:${inputsHash}`).catch((e) => { log(id, `ENS publish failed (${e.shortMessage ?? e.message}); paying anyway`); return null; });
  if (record.ensTx) log(id, `published to auditor.nidhi-dao.eth (${record.ensTx})`);

  // 7. pay: the agent is the mandate's executor
  const tx = await pay(id, md.mandate, md.approver as Address, md.approverSig, attestation, auditor.address, auditorSig, m.grantee);
  if (tx) record.payoutTx = tx;
  save();
  if (tx) log(id, `PAID: ${m.grantee}.nidhi-dao.eth on chain ${m.payTo}; CCIP is delivering it (grant ${md.mandate.grantId})`);
}

/** wrap, approve and swap through the ENS-gated hook; returns the payout tx, or null if the payout must wait */
async function pay(id: string, mandate: any, approver: Address, approverSig: Hex, attestation: any, auditor: Address, auditorSig: Hex, label: string): Promise<Hex | null> {
  const s = sourceStack();
  const pub = publicClient(s.chainId);
  const executor = privateKeyToAccount(process.env.PRIVATE_KEY as Hex);
  if (executor.address.toLowerCase() !== String(mandate.executor).toLowerCase()) throw new Error("PRIVATE_KEY is not the executor named in the mandate");
  const [paused, left] = await Promise.all([
    pub.readContract({ address: s.hook, abi: hookAbi, functionName: "paused" }),
    pub.readContract({ address: s.hook, abi: hookAbi, functionName: "remainingToday" }),
  ]);
  if (paused) { log(id, "the guardian has paused grants: payout waits"); return null; }
  if ((left as bigint) < BigInt(mandate.amountIn)) { log(id, "today's cap is used up: payout retries tomorrow"); return null; }

  const wallet = createWalletClient({ chain: sepolia, transport: transport(s.chainId), account: executor });
  const send = async (what: string, p: Promise<Hex>) => { const h = await p; await pub.waitForTransactionReceipt({ hash: h }); log(id, `  ${what}: ${h}`); return h; };
  const amountIn = BigInt(mandate.amountIn);
  const weth = (await pub.readContract({ address: s.base, abi: wethAbi, functionName: "balanceOf", args: [executor.address] })) as bigint;
  if (weth < amountIn) await send("wrap", wallet.writeContract({ address: s.base, abi: wethAbi, functionName: "deposit", value: amountIn - weth }));
  const allowance = (await pub.readContract({ address: s.base, abi: wethAbi, functionName: "allowance", args: [executor.address, s.router] })) as bigint;
  if (allowance < amountIn) await send("approve", wallet.writeContract({ address: s.base, abi: wethAbi, functionName: "approve", args: [s.router, amountIn] }));
  const data = hookData({ mandate, approver, approverSig, attestation, auditor, auditorSig, recipientLabel: label });
  return send("payout swap", wallet.writeContract({
    address: s.router, abi: routerAbi, functionName: "swap", gas: 2_500_000n,
    args: [poolKey(s) as any, { zeroForOne: zeroForOne(s), amountSpecified: -amountIn, sqrtPriceLimitX96: zeroForOne(s) ? MIN_SQRT : MAX_SQRT }, data, BigInt(Math.floor(Date.now() / 1000) + 600)],
  }));
}

const authAbi = parseAbi(["function resolveGrantee(string label, uint64 destSelector) view returns (address)"]);

/** an on-chain milestone from NidhiBountyBoard: open to anyone (first merged PR wins) or assigned to an ENS name */
async function handleBounty(b: BoardBounty, base: any, dryRun: boolean) {
  const id = `b${b.id}`;
  const s = sourceStack();
  const pub = publicClient(s.chainId);
  const board = boardDeployment();
  const bt = b.bounty;
  if (b.cancelled) return log(id, "cancelled by the DAO");
  if (await usedAnywhere(b.grantId)) return log(id, "already paid");
  if (Number(bt.deadline) < Date.now() / 1000) return log(id, "expired");
  if (String(board.hook).toLowerCase() !== s.hook.toLowerCase()) return log(id, "board is bound to another hook");
  // the text shown to developers must be exactly what the poster committed to on-chain
  if (bountySpecHash(b.spec, bt.destChainSelector, bt.amountIn) !== b.specHash) return log(id, "REFUSED: the posted spec does not match its committed hash");

  const pr = await findMilestonePr(b.spec.repo, id);
  if (!pr) return log(id, `waiting: no merged PR tagged [${id}] in ${b.spec.repo}`);
  log(id, `PR #${pr.number} "${pr.title}" by ${pr.author}, merged ${pr.mergedAt}`);

  let extra: any = {};
  try { extra = JSON.parse(b.spec.rules || "{}"); } catch { /* malformed rules: base rubric only */ }
  const rules = { ...base, ...extra, requiredPathGlobs: [...(base.requiredPathGlobs ?? []), ...(extra.requiredPathGlobs ?? [])] };
  const { evidence, diff } = await fetchEvidence(b.spec.repo, pr.number);
  const results = evaluateRubric(evidence, rules, []);
  for (const r of results) log(id, `  ${r.pass ? "PASS" : "FAIL"}  ${r.rule.padEnd(24)} ${r.detail}`);
  const jury = await runJury(b.spec.body, diff);
  for (const j of jury.jurors) log(id, `  JURY  ${(j.status === "reviewed" ? `${j.provider}:${j.model}` : j.provider).padEnd(32)} ${j.status === "reviewed" ? j.review.verdict : "unavailable"}`);
  if (!(results.every((r) => r.pass) && !jury.veto)) return log(id, `REJECTED (${results.every((r) => r.pass) ? "jury veto" : "rubric failed"}): no payout`);

  // who is paid: the assigned ENS name, or for an open milestone the PR author's ENS identity
  const destSel = BigInt(bt.destChainSelector);
  const payTo = Number(Object.entries(s.selectors).find(([, v]) => v === destSel)?.[0] ?? 0);
  const label = b.spec.grantee || pr.author.toLowerCase();
  if (!validLabel(label)) return log(id, `REFUSED: "${label}" cannot be an ENS label`);
  if (!b.spec.grantee) {
    const wallet = pr.body.match(/nidhi-wallet:\s*(0x[0-9a-fA-F]{40})/i)?.[1] as Address | undefined;
    const gh = await githubOf(label);
    if (!gh) {
      if (!wallet) return log(id, `waiting: ${pr.author} has no ${label}.nidhi-dao.eth yet; add "nidhi-wallet: 0x..." to the PR description`);
      if (dryRun) return log(id, `dry run: would register ${label}.nidhi-dao.eth -> ${wallet}`);
      log(id, `registering ${label}.nidhi-dao.eth for ${pr.author} -> ${wallet}`);
      await ensureContributorName(label, wallet, payTo, (m) => log(id, m));
    } else if (gh.toLowerCase() !== pr.author.toLowerCase()) {
      return log(id, `REFUSED: ${label}.nidhi-dao.eth belongs to GitHub user ${gh}, not ${pr.author}`);
    }
  }
  const recipient = (await pub.readContract({ address: s.authority, abi: authAbi, functionName: "resolveGrantee", args: [label, destSel] })) as Address;
  if (/^0x0+$/.test(recipient)) return log(id, `waiting: ${label}.nidhi-dao.eth has no address for chain ${payTo}`);

  const mandate = {
    grantId: b.grantId, executor: bt.executor, recipient, tokenIn: bt.tokenIn, tokenOut: bt.tokenOut,
    amountIn: BigInt(bt.amountIn), minOut: BigInt(bt.minOut), maxOut: BigInt(bt.maxOut), destChainSelector: destSel,
    destReceiver: bt.destReceiver, evidenceHash: b.specHash, deadline: BigInt(bt.deadline), poolId: bt.poolId,
    recipientLabelHash: keccak256(toHex(label)),
  };
  if (!(await pub.readContract({ address: board.board, abi: boardAbi, functionName: "matches", args: [b.id, mandate] }))) return log(id, "REFUSED: the board would not approve this payout");

  const inputs = { repo: evidence.repo, pr: evidence.pr, evidence, diffHash: hashText(diff), rfpHash: hashText(b.spec.body), winner: label };
  const inputsHash = hashJson(inputs);
  const auditor = privateKeyToAccount(process.env.AUDITOR_PRIVATE_KEY as Hex);
  const attestation = { grantId: b.grantId, evidenceHash: b.specHash, inputsHash, rubricHash: hashJson(rules), issuedAt: BigInt(Math.floor(Date.now() / 1000)) };
  const auditorSig = await auditor.signTypedData({ domain: domain(s), types: ATTESTATION_TYPES, primaryType: "Attestation", message: attestation });
  log(id, `VERIFIED: ${label}.nidhi-dao.eth wins; attestation signed by ${auditor.address}`);
  if (dryRun) return log(id, "dry run: nothing published or sent");

  const ensTx = await publishToEns(id, `${id}:pr${pr.number}:${label}:${inputsHash}`).catch(() => null);
  if (ensTx) log(id, `published to auditor.nidhi-dao.eth (${ensTx})`);
  const approverSig = encodeAbiParameters([{ type: "uint256" }, { type: "tuple", components: MANDATE_TYPES.Mandate as any }], [b.id, mandate]);
  const tx = await pay(id, mandate, board.board, approverSig, attestation, auditor.address, auditorSig, label);
  if (tx) log(id, `PAID: ${label}.nidhi-dao.eth on chain ${payTo}; CCIP is delivering it`);
}

async function main() {
  const args = process.argv.slice(2);
  const dryRun = args.includes("--dry-run");
  const only = args.find((a) => !a.startsWith("--"));
  for (const k of ["PRIVATE_KEY", "AUDITOR_PRIVATE_KEY"]) if (!process.env[k]) throw new Error(`${k} is not set`);
  const { file, base } = loadMilestones();
  for (const [id, m] of Object.entries<any>(file.milestones)) {
    if (only && only !== id) continue;
    try { await handle(id, m, base, dryRun); }
    catch (e: any) { log(id, `error: ${e.shortMessage ?? e.message}`); process.exitCode = 1; }
  }
  // on-chain milestones posted from the app
  let bounties: BoardBounty[] = [];
  try { bounties = await readBounties(); } catch (e: any) { console.log(`[agent] board unreadable: ${e.shortMessage ?? e.message}`); }
  for (const b of bounties) {
    if (only && only !== `b${b.id}`) continue;
    try { await handleBounty(b, base, dryRun); }
    catch (e: any) { log(`b${b.id}`, `error: ${e.shortMessage ?? e.message}`); process.exitCode = 1; }
  }
}

main();
