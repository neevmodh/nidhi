// End-to-end check of the UI's write path, on a live testnet, with the UI's own code.
// It does exactly what NewGrant -> Sign -> Execute do in the browser (same mandate.ts, same quoter call,
// same EIP-712 domain and types, same hookData encoding), but signs with the role keys from ../.env
// instead of browser wallets.
//
//   npx tsx scripts/e2e-grant.ts [label] [srcChainId] [destChainId] [amountEth]
import fs from "node:fs";
import path from "node:path";
import { createWalletClient, http, parseEther, type Address, type Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { chainById, client, rpcUrls, viemChain, type ChainId } from "../src/lib/chains";
import {
  ATTESTATION_TYPES, MANDATE_TYPES, MAX_SQRT, MIN_SQRT, domain, hookData, labelHash, newGrantId, poolKey, zeroForOne, type Draft,
} from "../src/lib/mandate";
import { nidhiSwapRouterAbi, roleAuthorityAbi } from "../src/data/abi";
import evidence from "../src/data/evidence.json";

const env = Object.fromEntries(
  fs.readFileSync(path.resolve(import.meta.dirname, "../../.env"), "utf8").split("\n")
    .map((l) => l.match(/^([A-Z0-9_]+)=(.*)$/)).filter(Boolean).map((m) => [m![1], m![2].trim()]),
);
const [label = "alice", srcArg = "84532", destArg = "421614", amt = "0.0003"] = process.argv.slice(2);
const src = chainById(Number(srcArg))!;
const dest = chainById(Number(destArg))!;
const executor = privateKeyToAccount(env.PRIVATE_KEY as Hex);
const approver = privateKeyToAccount(env.APPROVER_PRIVATE_KEY as Hex);
const auditor = privateKeyToAccount(env.AUDITOR_PRIVATE_KEY as Hex);
const pub = client(src.id);
const wallet = createWalletClient({ account: executor, chain: viemChain(src.id as ChainId), transport: http(rpcUrls(src.id)[0]) });
const ev = evidence as any;

const quoterAbi = [{ type: "function", name: "quoteExactInputSingle", stateMutability: "nonpayable",
  inputs: [{ name: "params", type: "tuple", components: [
    { name: "poolKey", type: "tuple", components: [{ name: "currency0", type: "address" }, { name: "currency1", type: "address" }, { name: "fee", type: "uint24" }, { name: "tickSpacing", type: "int24" }, { name: "hooks", type: "address" }] },
    { name: "zeroForOne", type: "bool" }, { name: "exactAmount", type: "uint128" }, { name: "hookData", type: "bytes" }] }],
  outputs: [{ name: "amountOut", type: "uint256" }, { name: "gasEstimate", type: "uint256" }] }] as const;
const wethAbi = [
  { type: "function", name: "deposit", stateMutability: "payable", inputs: [], outputs: [] },
  { type: "function", name: "approve", stateMutability: "nonpayable", inputs: [{ type: "address" }, { type: "uint256" }], outputs: [{ type: "bool" }] },
] as const;

async function main() {
  const wei = parseEther(amt);
  console.log(`grant ${label}: ${src.short} -> ${dest.short}, ${amt} ${src.base.symbol}`);

  // NewGrant: resolve the payee the same way the hook will, and quote with V4Quoter
  const recipient = (await pub.readContract({ address: src.deployment!.authority, abi: roleAuthorityAbi, functionName: "resolveGrantee", args: [label, dest.selector] })) as Address;
  if (/^0x0+$/.test(recipient)) throw new Error(`${label} is not registered for ${dest.short} on ${src.short}`);
  const { result } = await pub.simulateContract({ address: src.uniswap.quoter, abi: quoterAbi, functionName: "quoteExactInputSingle",
    args: [{ poolKey: poolKey(src), zeroForOne: zeroForOne(src), exactAmount: wei, hookData: "0x" }] });
  const q = result[0] as bigint;
  console.log(`  payee ${recipient}, quote ${q}`);

  const grantId = newGrantId(label);
  const now = BigInt(Math.floor(Date.now() / 1000));
  const draft: Draft = {
    v: 1, src: src.id, label,
    mandate: {
      grantId, executor: executor.address, recipient, tokenIn: src.base.address, tokenOut: src.payout.address,
      amountIn: wei, minOut: (q * 90n) / 100n, maxOut: (q * 110n) / 100n, destChainSelector: dest.selector,
      destReceiver: dest.deployment!.receiver, evidenceHash: ev.hashes.evidenceHash, deadline: now + 3600n,
      poolId: src.deployment!.poolId, recipientLabelHash: labelHash(label),
    },
    attestation: { grantId, evidenceHash: ev.hashes.evidenceHash, inputsHash: ev.hashes.inputsHash, rubricHash: ev.hashes.rubricHash, issuedAt: now },
  };

  // Sign: same domain + types the browser uses with signTypedData
  draft.approver = approver.address;
  draft.approverSig = await approver.signTypedData({ domain: domain(src), types: MANDATE_TYPES, primaryType: "Mandate", message: draft.mandate as any });
  draft.auditor = auditor.address;
  draft.auditorSig = await auditor.signTypedData({ domain: domain(src), types: ATTESTATION_TYPES, primaryType: "Attestation", message: draft.attestation as any });
  console.log(`  signed by approver ${approver.address} and auditor ${auditor.address} (evidence ${ev.grantLabel})`);

  // Execute: wrap, approve the router, swap with the UI's hookData encoding
  const send = async (what: string, p: Promise<Hex>) => { const h = await p; await pub.waitForTransactionReceipt({ hash: h }); console.log(`  ${what}: ${h}`); return h; };
  await send("wrap", wallet.writeContract({ address: src.base.address, abi: wethAbi, functionName: "deposit", value: wei }));
  await send("approve", wallet.writeContract({ address: src.base.address, abi: wethAbi, functionName: "approve", args: [src.deployment!.router, wei] }));
  const tx = await send("swap", wallet.writeContract({
    address: src.deployment!.router, abi: nidhiSwapRouterAbi, functionName: "swap",
    args: [poolKey(src) as any, { zeroForOne: zeroForOne(src), amountSpecified: -wei, sqrtPriceLimitX96: zeroForOne(src) ? MIN_SQRT : MAX_SQRT } as any, hookData(draft), now + 600n],
  }));
  console.log(`\nGRANT_ID=${grantId}\nSWAP_TX=${tx}\nUI=/app/grants/${src.key}/${grantId}`);
}

main().catch((e) => { console.error(e?.shortMessage ?? e?.message ?? e); process.exit(1); });
