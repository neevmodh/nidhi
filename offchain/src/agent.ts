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
import { createWalletClient, http, parseAbi, toHex, type Address, type Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { sepolia } from "viem/chains";
import { evaluateRubric, fetchEvidence, findMilestonePr, hashJson, hashText } from "./lib.ts";
import { runJury } from "./llm/jury.ts";
import { loadMilestones, mandatePath, readMandate } from "./milestone.ts";
import { ATTESTATION_TYPES, MAX_SQRT, MIN_SQRT, RPCS, domain, hookData, poolKey, publicClient, repoRoot, sourceStack, toJson, zeroForOne } from "./stack.ts";

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
  const wallet = createWalletClient({ chain: sepolia, transport: http(RPCS[11155111][0]), account });
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
  if (await pub.readContract({ address: s.hook, abi: hookAbi, functionName: "grantUsed", args: [md.mandate.grantId] })) return log(id, "already paid");
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
  const executor = privateKeyToAccount(process.env.PRIVATE_KEY as Hex);
  if (executor.address.toLowerCase() !== String(md.mandate.executor).toLowerCase()) throw new Error("PRIVATE_KEY is not the executor named in the mandate");
  const [paused, left] = await Promise.all([
    pub.readContract({ address: s.hook, abi: hookAbi, functionName: "paused" }),
    pub.readContract({ address: s.hook, abi: hookAbi, functionName: "remainingToday" }),
  ]);
  if (paused) { save(); return log(id, "the guardian has paused grants: payout waits"); }
  if ((left as bigint) < md.mandate.amountIn) { save(); return log(id, "today's cap is used up: payout retries tomorrow"); }

  const wallet = createWalletClient({ chain: sepolia, transport: http(RPCS[s.chainId][0]), account: executor });
  const send = async (what: string, p: Promise<Hex>) => { const h = await p; await pub.waitForTransactionReceipt({ hash: h }); log(id, `  ${what}: ${h}`); return h; };
  const weth = (await pub.readContract({ address: s.base, abi: wethAbi, functionName: "balanceOf", args: [executor.address] })) as bigint;
  if (weth < md.mandate.amountIn) await send("wrap", wallet.writeContract({ address: s.base, abi: wethAbi, functionName: "deposit", value: md.mandate.amountIn - weth }));
  const allowance = (await pub.readContract({ address: s.base, abi: wethAbi, functionName: "allowance", args: [executor.address, s.router] })) as bigint;
  if (allowance < md.mandate.amountIn) await send("approve", wallet.writeContract({ address: s.base, abi: wethAbi, functionName: "approve", args: [s.router, md.mandate.amountIn] }));
  const data = hookData({ mandate: md.mandate, approver: md.approver as Address, approverSig: md.approverSig, attestation, auditor: auditor.address, auditorSig, recipientLabel: m.grantee });
  record.payoutTx = await send("payout swap", wallet.writeContract({
    address: s.router, abi: routerAbi, functionName: "swap", gas: 2_500_000n,
    args: [poolKey(s) as any, { zeroForOne: zeroForOne(s), amountSpecified: -md.mandate.amountIn, sqrtPriceLimitX96: zeroForOne(s) ? MIN_SQRT : MAX_SQRT }, data, BigInt(Math.floor(Date.now() / 1000) + 600)],
  }));
  save();
  log(id, `PAID: ${m.grantee}.nidhi-dao.eth on chain ${m.payTo}; CCIP is delivering it (grant ${md.mandate.grantId})`);
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
}

main();
