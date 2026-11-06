// Nidhi treasury operations through the Uniswap Trading API.
//
//   node src/treasury.ts quote <IN> <OUT> <amount> [--exact-output]      read-only, e.g. quote ETH USDC 0.001
//   node src/treasury.ts fund-grant <grantLabel> [--pay USDC|ETH] [--yes]      (default: pay USDC)
//
// fund-grant makes the treasury executor hold exactly the WETH a grant needs (its `amountInWei` from grants.json),
// buying any shortfall at the best Uniswap route (EXACT_OUTPUT) before the grant is paid through the Nidhi hook.
// Every transaction is summarised and requires confirmation (or --yes). Keys and the API key come from .env.

import fs from "node:fs";
import path from "node:path";
import readline from "node:readline/promises";
import { fileURLToPath } from "node:url";
import { createPublicClient, createWalletClient, formatUnits, http, parseAbi, parseUnits, type Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { sepolia } from "viem/chains";
import { NATIVE, checkApproval, prepareSwap, quote, swap, validateBeforeBroadcast, type TxRequest } from "./uniswap/tradingApi.ts";

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, "..");
const envFile = path.resolve(root, "..", ".env");
if (fs.existsSync(envFile)) process.loadEnvFile(envFile);

const CHAIN_ID = 11155111;
const TOKENS: Record<string, { address: string; decimals: number }> = {
  ETH: { address: NATIVE, decimals: 18 },
  WETH: { address: "0x7b79995e5f793A07Bc00c21412e50Ecae098E7f9", decimals: 18 },
  USDC: { address: "0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238", decimals: 6 },
};
const erc20 = parseAbi(["function balanceOf(address) view returns (uint256)"]);

const rpc = process.env.SEPOLIA_RPC_URL ?? "https://ethereum-sepolia-rpc.publicnode.com";
const pub = createPublicClient({ chain: sepolia, transport: http(rpc) });

function token(sym: string) {
  const t = TOKENS[sym.toUpperCase()];
  if (!t) throw new Error(`unknown token ${sym}; use one of ${Object.keys(TOKENS).join(", ")}`);
  return { sym: sym.toUpperCase(), ...t };
}

async function balanceOf(sym: string, who: Hex): Promise<bigint> {
  const t = token(sym);
  return t.address === NATIVE ? pub.getBalance({ address: who }) : pub.readContract({ address: t.address as Hex, abi: erc20, functionName: "balanceOf", args: [who] });
}

async function confirm(summary: string, yes: boolean) {
  console.log(summary);
  if (yes) return;
  const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
  const answer = (await rl.question("Broadcast? [y/N] ")).trim().toLowerCase();
  rl.close();
  if (answer !== "y" && answer !== "yes") throw new Error("aborted by user");
}

/** Low, explicit EIP-1559 fees: Sepolia base fee is tiny, while some RPCs suggest huge priority fees. */
async function fees() {
  const block = await pub.getBlock();
  const base = block.baseFeePerGas ?? 1n;
  const tip = 1_000_000n; // 0.001 gwei
  return { maxPriorityFeePerGas: tip, maxFeePerGas: base * 2n + tip };
}

async function send(tx: TxRequest, label: string) {
  validateBeforeBroadcast(tx);
  const account = privateKeyToAccount(process.env.PRIVATE_KEY as Hex);
  const wallet = createWalletClient({ chain: sepolia, transport: http(rpc), account });
  const hash = await wallet.sendTransaction({
    to: tx.to,
    data: tx.data,
    value: BigInt(tx.value ?? "0"),
    gas: tx.gasLimit ? (BigInt(tx.gasLimit) * 12n) / 10n : undefined,
    ...(await fees()),
  });
  const r = await pub.waitForTransactionReceipt({ hash });
  if (r.status !== "success") throw new Error(`${label} reverted: ${hash}`);
  console.log(`  ${label}: https://sepolia.etherscan.io/tx/${hash}`);
  return hash;
}

async function cmdQuote(args: string[]) {
  const [inSym, outSym, amt] = args;
  if (!inSym || !outSym || !amt) throw new Error("usage: quote <IN> <OUT> <amount> [--exact-output]");
  const exactOut = args.includes("--exact-output");
  const tin = token(inSym), tout = token(outSym);
  const amount = parseUnits(amt, exactOut ? tout.decimals : tin.decimals).toString();
  const swapper = privateKeyToAccount(process.env.PRIVATE_KEY as Hex).address;
  const q = await quote({ swapper, tokenIn: tin.address, tokenOut: tout.address, chainId: CHAIN_ID, amount, type: exactOut ? "EXACT_OUTPUT" : "EXACT_INPUT" });
  const pools = (q.quote?.route?.[0] ?? []).map((p: any) => p.type).join(" > ");
  console.log(`routing ${q.routing} via ${pools || "-"}`);
  console.log(`  in : ${formatUnits(BigInt(q.quote.input.amount), tin.decimals)} ${tin.sym}`);
  console.log(`  out: ${formatUnits(BigInt(q.quote.output.amount), tout.decimals)} ${tout.sym}`);
  console.log(`  gas: ~$${Number(q.quote.gasFeeUSD ?? 0).toFixed(6)}`);
}

async function cmdFundGrant(args: string[]) {
  const label = args[0];
  if (!label) throw new Error("usage: fund-grant <grantLabel> [--pay ETH|USDC] [--yes]");
  const yes = args.includes("--yes");
  const payIdx = args.indexOf("--pay");
  const pay = token(payIdx >= 0 ? args[payIdx + 1] : "USDC"); // DAO treasuries hold stables; ETH->WETH routes are thin on testnet
  const grants = JSON.parse(fs.readFileSync(path.join(root, "grants.json"), "utf8")).grants;
  const g = grants[label];
  if (!g) throw new Error(`unknown grant ${label}`);

  const account = privateKeyToAccount(process.env.PRIVATE_KEY as Hex);
  const need = BigInt(g.amountInWei);
  const have = await balanceOf("WETH", account.address);
  console.log(`grant ${label}: needs ${formatUnits(need, 18)} WETH; treasury ${account.address} holds ${formatUnits(have, 18)} WETH`);
  if (have >= need) {
    console.log("treasury already funded - nothing to buy.");
    return;
  }
  const shortfall = (need - have).toString();
  const weth = token("WETH");
  const q = await quote({ swapper: account.address, tokenIn: pay.address, tokenOut: weth.address, chainId: CHAIN_ID, amount: shortfall, type: "EXACT_OUTPUT" });
  const maxIn = BigInt(q.quote.input.amount);
  const payBal = await balanceOf(pay.sym, account.address);
  if (payBal < maxIn) throw new Error(`treasury has ${formatUnits(payBal, pay.decimals)} ${pay.sym}; needs ${formatUnits(maxIn, pay.decimals)}`);

  const pools = (q.quote?.route?.[0] ?? []).map((p: any) => p.type).join(" > ");
  await confirm(
    [
      "",
      "  Uniswap Trading API swap (Sepolia)",
      `  buy      : ${formatUnits(BigInt(shortfall), 18)} WETH (exact output)`,
      `  pay      : up to ${formatUnits(maxIn, pay.decimals)} ${pay.sym}`,
      `  route    : ${q.routing} via ${pools || "-"}`,
      `  gas est. : ~$${Number(q.quote.gasFeeUSD ?? 0).toFixed(6)}`,
      `  from     : ${account.address}`,
      "",
    ].join("\n"),
    yes,
  );

  const approval = await checkApproval(account.address, pay.address, maxIn.toString(), CHAIN_ID);
  if (approval) await send(approval, "approval");

  // Quotes go stale in ~30s: re-quote right before building the swap.
  const fresh = await quote({ swapper: account.address, tokenIn: pay.address, tokenOut: weth.address, chainId: CHAIN_ID, amount: shortfall, type: "EXACT_OUTPUT" });
  const tx = await swap(await prepareSwap(fresh, account));
  await send(tx, "swap");
  console.log(`treasury now holds ${formatUnits(await balanceOf("WETH", account.address), 18)} WETH`);
}

const [cmd, ...rest] = process.argv.slice(2);
const run = cmd === "quote" ? cmdQuote : cmd === "fund-grant" ? cmdFundGrant : null;
if (!run) {
  console.log("usage:\n  node src/treasury.ts quote <IN> <OUT> <amount> [--exact-output]\n  node src/treasury.ts fund-grant <grantLabel> [--pay ETH|USDC] [--yes]");
  process.exit(1);
}
run(rest).catch((e) => {
  console.error(e instanceof Error ? e.message : e);
  process.exit(1);
});
