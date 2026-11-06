// Post an on-chain milestone to NidhiBountyBoard from the command line: the same transaction the app's
// "New milestone" form sends. The signer must hold the approver role on nidhi-dao.eth.
//
//   node src/post-bounty.ts '{"title":"...","body":"...","repo":"neevmodh/nidhi","payTo":84532,"amountEth":"0.0003",
//                             "paths":["CONTRIBUTING.md"],"approvals":0,"days":14,"grantee":""}'
import fs from "node:fs";
import path from "node:path";
import { createWalletClient, http, keccak256, parseEther, toHex, zeroAddress, type Address, type Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { sepolia } from "viem/chains";
import { boardAbi, boardDeployment, bountySpecHash } from "./bounty.ts";
import { RPCS, ensVersion, poolKey, publicClient, repoRoot, sourceStack, transport, zeroForOne } from "./stack.ts";

if (fs.existsSync(path.join(repoRoot, ".env"))) process.loadEnvFile(path.join(repoRoot, ".env"));
const quoterAbi = [{ type: "function", name: "quoteExactInputSingle", stateMutability: "nonpayable",
  inputs: [{ name: "params", type: "tuple", components: [
    { name: "poolKey", type: "tuple", components: [{ name: "currency0", type: "address" }, { name: "currency1", type: "address" }, { name: "fee", type: "uint24" }, { name: "tickSpacing", type: "int24" }, { name: "hooks", type: "address" }] },
    { name: "zeroForOne", type: "bool" }, { name: "exactAmount", type: "uint128" }, { name: "hookData", type: "bytes" }] }],
  outputs: [{ name: "amountOut", type: "uint256" }, { name: "gasEstimate", type: "uint256" }] }] as const;

async function main() {
  const a = JSON.parse(process.argv[2] ?? "{}");
  const board = boardDeployment();
  if (!board) throw new Error("no deployments/bounty-board.json");
  const s = sourceStack();
  const pub = publicClient(s.chainId);
  const ens = JSON.parse(fs.readFileSync(path.join(repoRoot, "deployments", `ens-${ensVersion()}-stack.json`), "utf8"));
  const destSel = s.selectors[String(a.payTo)];
  const wei = parseEther(String(a.amountEth));
  const { result } = await pub.simulateContract({ address: s.quoter, abi: quoterAbi, functionName: "quoteExactInputSingle", args: [{ poolKey: poolKey(s), zeroForOne: zeroForOne(s), exactAmount: wei, hookData: "0x" }] });
  const q = result[0] as bigint;
  const rules = { minApprovals: a.approvals ?? 1, requiredPathGlobs: a.paths ?? [] };
  const spec = { title: a.title, repo: a.repo, body: a.body, rules: JSON.stringify(rules), grantee: a.grantee ?? "" };
  const bounty = {
    poster: zeroAddress, cancelled: false, grantId: `0x${"0".repeat(64)}` as Hex, specHash: bountySpecHash(spec, destSel, wei),
    granteeLabelHash: spec.grantee ? keccak256(toHex(spec.grantee)) : (`0x${"0".repeat(64)}` as Hex),
    executor: ens.deployer as Address, tokenIn: s.base, tokenOut: s.payout, amountIn: wei, minOut: (q * 50n) / 100n, maxOut: (q * 150n) / 100n,
    destChainSelector: destSel, destReceiver: s.receivers[String(a.payTo)], poolId: s.poolId,
    deadline: BigInt(Math.floor(Date.now() / 1000) + (a.days ?? 14) * 86400),
  };
  const account = privateKeyToAccount(process.env.APPROVER_PRIVATE_KEY as Hex);
  const w = createWalletClient({ chain: sepolia, transport: transport(11155111), account });
  const { request, result: id } = await pub.simulateContract({ account, address: board.board, abi: boardAbi, functionName: "post", args: [bounty, spec] });
  const hash = await w.writeContract(request);
  await pub.waitForTransactionReceipt({ hash });
  console.log(`[post] milestone b${id} posted by ${account.address}: "${a.title}" (${spec.grantee ? `assigned to ${spec.grantee}` : "open"}) tx ${hash}`);
  console.log(`       claim it with a PR titled "[b${id}] ..." and "nidhi-wallet: 0x..." in its description`);
}
main().catch((e) => { console.error(e.shortMessage ?? e.message); process.exit(1); });
