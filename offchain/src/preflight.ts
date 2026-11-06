// Mainnet preflight (read-only): what must the deployer hold on each chain?
//
//   node src/preflight.ts            table for every deployable chain
//   node src/preflight.ts --json     machine-readable
//
// Needs: MAINNET_DEPLOYER_PRIVATE_KEY in ../.env (only the ADDRESS is used). Sends nothing.
// Per chain it queries, live: gas price, the deployer's native + USDC balance, and the real CCIP fee for a USDC grant
// message on the chain's first payout lane. "Need" = deployment gas + fee reserves for both stacks + USDC seed.

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { createPublicClient, encodeAbiParameters, formatEther, formatUnits, http, parseAbi, type Address, type Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, "..", "..");
const envFile = path.join(root, ".env");
if (fs.existsSync(envFile)) process.loadEnvFile(envFile);

const DEPLOY_GAS = 14_000_000n; // whole source + destination stack incl. pool, position and wiring (rehearsal-measured upper bound)
const GAS_BUFFER = 130n; // percent
const FEE_MESSAGES = BigInt(process.env.FEE_MESSAGES ?? "3"); // CCIP messages worth of native fee reserve, on each side (a grant costs one fee; its ACK another)
const SEED_USD = BigInt(process.env.SEED_USD ?? "20"); // USDC seed liquidity per chain

const router = parseAbi([
  "function getFee(uint64 dest, (bytes receiver, bytes data, (address token, uint256 amount)[] tokenAmounts, address feeToken, bytes extraArgs) message) view returns (uint256)",
]);
const erc20 = parseAbi(["function balanceOf(address) view returns (uint256)"]);

function extraArgsV2(gasLimit: bigint): Hex {
  const enc = encodeAbiParameters([{ type: "uint256" }, { type: "bool" }], [gasLimit, true]);
  return `0x181dcf10${enc.slice(2)}` as Hex;
}

async function main() {
  const regPath = path.join(root, "chains", "registry.json");
  const reg = JSON.parse(fs.readFileSync(regPath, "utf8")).chains;
  const key = process.env.MAINNET_DEPLOYER_PRIVATE_KEY as Hex | undefined;
  if (!key) throw new Error("MAINNET_DEPLOYER_PRIVATE_KEY missing from .env");
  const deployer = privateKeyToAccount(key).address;
  const chains = Object.values<any>(reg).filter((c) => c.capabilities.source);
  const json = process.argv.includes("--json");

  const rows: any[] = [];
  for (const c of chains) {
    const client = createPublicClient({ transport: http(c.rpc, { timeout: 15000 }) });
    const row: any = { chainId: c.chainId, chain: c.name, native: c.native, deployer };
    try {
      const gasPrice = await client.getGasPrice();
      const [bal, usdcBal] = await Promise.all([
        client.getBalance({ address: deployer }),
        client.readContract({ address: c.tokens.usdc.address as Address, abi: erc20, functionName: "balanceOf", args: [deployer] }) as Promise<bigint>,
      ]);
      const destChain = reg[String(c.payoutLanes[0])];
      const msg = {
        receiver: encodeAbiParameters([{ type: "address" }], ["0x000000000000000000000000000000000000bEEF"]),
        data: "0x" as Hex,
        tokenAmounts: [{ token: c.tokens.usdc.address as Address, amount: 1_000_000n }],
        feeToken: "0x0000000000000000000000000000000000000000" as Address,
        extraArgs: extraArgsV2(600_000n),
      };
      let fee = 0n;
      try {
        fee = (await client.readContract({ address: c.ccip.router, abi: router, functionName: "getFee", args: [BigInt(destChain.ccip.selector), msg] })) as bigint;
      } catch {
        fee = 0n;
      }
      const gasCost = (DEPLOY_GAS * gasPrice * GAS_BUFFER) / 100n;
      const reserves = fee * FEE_MESSAGES * 2n; // dispatcher (sends grants) + receiver (sends ACKs)
      const needNative = gasCost + reserves;
      Object.assign(row, {
        gasPriceGwei: Number(gasPrice) / 1e9,
        ccipFeeNative: fee === 0n ? "n/a" : formatEther(fee),
        needNative: formatEther(needNative),
        haveNative: formatEther(bal),
        nativeShort: bal < needNative ? formatEther(needNative - bal) : "0",
        needUsdc: SEED_USD.toString(),
        haveUsdc: formatUnits(usdcBal, c.tokens.usdc.decimals),
        usdcShort: usdcBal < SEED_USD * 10n ** BigInt(c.tokens.usdc.decimals) ? (SEED_USD - BigInt(Math.floor(Number(formatUnits(usdcBal, c.tokens.usdc.decimals))))).toString() : "0",
        ready: bal >= needNative && usdcBal >= SEED_USD * 10n ** BigInt(c.tokens.usdc.decimals),
      });
    } catch (e: any) {
      row.error = e.shortMessage ?? e.message;
    }
    rows.push(row);
  }

  if (json) return console.log(JSON.stringify(rows, null, 2));
  console.log(`Deployer (same address on every chain): ${deployer}\n`);
  console.log("chain".padEnd(12), "native".padEnd(6), "gas gwei".padStart(10), "CCIP fee".padStart(12), "need native".padStart(13), "have".padStart(10), "| USDC need/have");
  for (const r of rows) {
    if (r.error) { console.log(r.chain.padEnd(12), "ERROR", r.error); continue; }
    console.log(
      r.chain.padEnd(12), (r.chainId === 999 ? "HYPE" : r.native).padEnd(6), String(r.gasPriceGwei.toFixed(3)).padStart(10), String(r.ccipFeeNative === "n/a" ? "n/a" : Number(r.ccipFeeNative).toPrecision(3)).padStart(12),
      Number(r.needNative).toPrecision(3).padStart(13), Number(r.haveNative).toPrecision(3).padStart(10), `| ${r.needUsdc} / ${Number(r.haveUsdc).toFixed(2)}  ${r.ready ? "READY" : "needs funding"}`,
    );
  }
  const ready = rows.filter((r) => r.ready).length;
  console.log(`\n${ready} of ${rows.length} chains funded. Chains without funding are skipped by the deploy, never failed.`);
}

main().catch((e) => { console.error(e instanceof Error ? e.message : e); process.exit(1); });
