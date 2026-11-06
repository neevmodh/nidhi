// DAO side of milestone grants.
//
//   node src/milestone.ts commit <id>   the DAO approver pre-signs the payout mandate for milestone <id>
//   node src/milestone.ts status        where every milestone stands (spec, PR, on-chain payout)
//
// commit resolves the grantee's ENS subname for the payout chain, quotes the payout with Uniswap's V4Quoter, and signs
// an EIP-712 Mandate whose evidenceHash is the milestone SPEC hash (lib.ts: specHashOf). It writes
// mandates/<id>.json, which is public by design: a signature only lets the agent pay this one spec, once.
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { parseAbi, type Address, type Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { findMilestonePr, grantIdOf, milestoneRules, specHashOf } from "./lib.ts";
import { MANDATE_TYPES, domain, fromJson, knownHooks, labelHash, poolKey, publicClient, sourceStack, toJson, zeroForOne } from "./stack.ts";

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, "..");
if (fs.existsSync(path.join(root, "..", ".env"))) process.loadEnvFile(path.join(root, "..", ".env"));

export const BAND = { minPct: 50n, maxPct: 150n }; // wide: the payout happens later, and every grant moves the pool
export const DEADLINE_DAYS = 30n;

export function loadMilestones() {
  const file = JSON.parse(fs.readFileSync(path.join(root, "milestones.json"), "utf8"));
  const base = JSON.parse(fs.readFileSync(path.join(root, "rubric.json"), "utf8")).rules;
  return { file, base };
}
export const mandatePath = (id: string) => path.join(root, "mandates", `${id}.json`);

const authAbi = parseAbi(["function resolveGrantee(string label, uint64 destSelector) view returns (address)"]);
const quoterAbi = [{
  type: "function", name: "quoteExactInputSingle", stateMutability: "nonpayable",
  inputs: [{ name: "params", type: "tuple", components: [
    { name: "poolKey", type: "tuple", components: [{ name: "currency0", type: "address" }, { name: "currency1", type: "address" }, { name: "fee", type: "uint24" }, { name: "tickSpacing", type: "int24" }, { name: "hooks", type: "address" }] },
    { name: "zeroForOne", type: "bool" }, { name: "exactAmount", type: "uint128" }, { name: "hookData", type: "bytes" }] }],
  outputs: [{ name: "amountOut", type: "uint256" }, { name: "gasEstimate", type: "uint256" }],
}] as const;

async function commit(id: string) {
  const { file, base } = loadMilestones();
  const m = file.milestones[id];
  if (!m) throw new Error(`unknown milestone "${id}" in milestones.json`);
  const approverKey = process.env.APPROVER_PRIVATE_KEY as Hex | undefined;
  const executorKey = process.env.PRIVATE_KEY as Hex | undefined;
  if (!approverKey || !executorKey) throw new Error("needs APPROVER_PRIVATE_KEY (signs) and PRIVATE_KEY (the agent's executor address)");

  const s = sourceStack();
  const c = publicClient(s.chainId);
  const rfp = fs.readFileSync(path.join(root, m.rfp), "utf8");
  const rules = milestoneRules(base, m);
  const specHash = specHashOf(id, m, rfp, rules);
  const destSel = s.selectors[String(m.payTo)];
  const destReceiver = s.receivers[String(m.payTo)];
  if (!destSel || !destReceiver) throw new Error(`the source stack has no route to chain ${m.payTo}`);

  const recipient = (await c.readContract({ address: s.authority, abi: authAbi, functionName: "resolveGrantee", args: [m.grantee, destSel] })) as Address;
  if (/^0x0+$/.test(recipient)) throw new Error(`${m.grantee} has no address for chain ${m.payTo} in ENS`);
  const amountIn = BigInt(m.amountInWei);
  const { result } = await c.simulateContract({ address: s.quoter, abi: quoterAbi, functionName: "quoteExactInputSingle", args: [{ poolKey: poolKey(s), zeroForOne: zeroForOne(s), exactAmount: amountIn, hookData: "0x" }] });
  const quote = result[0] as bigint;

  const approver = privateKeyToAccount(approverKey);
  const mandate = {
    grantId: grantIdOf(id),
    executor: privateKeyToAccount(executorKey).address,
    recipient,
    tokenIn: s.base,
    tokenOut: s.payout,
    amountIn,
    minOut: (quote * BAND.minPct) / 100n,
    maxOut: (quote * BAND.maxPct) / 100n,
    destChainSelector: destSel,
    destReceiver,
    evidenceHash: specHash,
    deadline: BigInt(Math.floor(Date.now() / 1000)) + DEADLINE_DAYS * 86400n,
    poolId: s.poolId,
    recipientLabelHash: labelHash(m.grantee),
  };
  const approverSig = await approver.signTypedData({ domain: domain(s), types: MANDATE_TYPES, primaryType: "Mandate", message: mandate });
  fs.mkdirSync(path.join(root, "mandates"), { recursive: true });
  fs.writeFileSync(mandatePath(id), toJson({ id, spec: { ...m, rules }, specHash, quoteAtCommit: quote, mandate, approver: approver.address, approverSig, hook: s.hook, chainId: s.chainId, committedAt: new Date().toISOString() }));
  console.log(`[milestone] ${id} committed: ${m.grantee}.nidhi-dao.eth on chain ${m.payTo}, ${m.amountInWei} wei in, quote ${quote}`);
  console.log(`            spec ${specHash}, signed by approver ${approver.address}; tag a PR "[${id}] ..." to claim it`);
}

async function status() {
  const { file } = loadMilestones();
  const s = sourceStack();
  const c = publicClient(s.chainId);
  for (const [id, m] of Object.entries<any>(file.milestones)) {
    const committed = fs.existsSync(mandatePath(id));
    let used = false; // paid on any ENS stack, current or previous
    for (const h of knownHooks()) used ||= await c.readContract({ address: h, abi: parseAbi(["function grantUsed(bytes32) view returns (bool)"]), functionName: "grantUsed", args: [grantIdOf(id)] });
    let pr = "no merged PR yet";
    try { const p = await findMilestonePr(m.repo, id); if (p) pr = `#${p.number} merged ${p.mergedAt}`; } catch (e: any) { pr = `GitHub: ${e.message.slice(0, 60)}`; }
    console.log(`${id.padEnd(4)} ${m.title.padEnd(34)} ${committed ? "committed" : "NOT committed"} | ${pr} | ${used ? "PAID" : "unpaid"}`);
  }
}

export const readMandate = (id: string) => fromJson(fs.readFileSync(mandatePath(id), "utf8"));

const [cmd, arg] = process.argv.slice(2);
if (import.meta.url === `file://${process.argv[1]}`) {
  (cmd === "commit" ? commit(arg) : cmd === "status" ? status() : Promise.reject(new Error("usage: milestone.ts commit <id> | status")))
    .catch((e) => { console.error(e instanceof Error ? e.message : e); process.exit(1); });
}
