// Chain registry generator (read-only).
//
//   node src/registry.ts            regenerate ../chains/registry.json and print the capability table
//   node src/registry.ts --check    re-verify the committed registry against live RPCs (exit 1 on drift)
//
// Sources (all official / on-chain):
//   - Uniswap deployments page            -> v4 PoolManager, PositionManager, V4Quoter, StateView, ReservesLens, FeeOnTransferDetector
//   - Uniswap Trading API chains page     -> Universal Router 2.1.2 address + whether the Trading API serves the chain
//   - Chainlink CCIP chains/tokens/lanes  -> router, selector, USDC/LINK token + lanes between chains
//   - on-chain reads                      -> code at every address, wrapped native (UniversalRouter.WETH9()), reference pool
// Nothing here sends a transaction.

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { createPublicClient, encodeAbiParameters, getAddress, http, keccak256, parseAbi, zeroAddress, type Address, type PublicClient } from "viem";

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, "..", "..");
const OUT = path.join(root, "chains", "registry.json");

// Uniswap page chain label -> chainId
const UNI_NAMES: Record<string, number> = {
  Ethereum: 1, Optimism: 10, "BNB Chain": 56, Unichain: 130, Polygon: 137, Monad: 143, "X Layer": 196, "World Chain": 480,
  HyperEVM: 999, Soneium: 1868, Tempo: 4217, MegaETH: 4326, "Robinhood Chain": 4663, Arc: 5042, Base: 8453, Arbitrum: 42161,
  Celo: 42220, Avalanche: 43114, Ink: 57073, Linea: 59144, Zora: 7777777,
};

const SHORT: Record<number, string> = {
  1: "ethereum", 10: "optimism", 56: "bnb", 130: "unichain", 137: "polygon", 143: "monad", 196: "xlayer", 480: "worldchain",
  999: "hyperevm", 1868: "soneium", 4217: "tempo", 4326: "megaeth", 4663: "robinhood", 5042: "arc", 8453: "base", 42161: "arbitrum",
  42220: "celo", 43114: "avalanche", 57073: "ink", 59144: "linea", 7777777: "zora",
};

// chainlist.org is wrong or thin for some chains; pin known-good public RPCs first.
const RPC_PINS: Record<number, string[]> = {
  999: ["https://rpc.hyperliquid.xyz/evm"],
  143: ["https://rpc.monad.xyz"],
  8453: ["https://mainnet.base.org"],
  1: ["https://ethereum-rpc.publicnode.com"],
  137: ["https://polygon-bor-rpc.publicnode.com"],
  42161: ["https://arb1.arbitrum.io/rpc"],
  10: ["https://mainnet.optimism.io"],
};

// Canonical wrapped-native candidates. NOT trusted blindly: each is accepted only if it has code, answers symbol(),
// and a funded v4 reference pool exists against the payout token. (UniversalRouter v2 does not expose WETH9().)
const WRAPPED_CANDIDATES: Record<number, string[]> = {
  1: ["0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2"],
  10: ["0x4200000000000000000000000000000000000006"],
  56: ["0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c"],
  130: ["0x4200000000000000000000000000000000000006"],
  137: ["0x0d500B1d8E8eF31E21C99d1Db9A6444d3ADf1270", "0x7ceB23fD6bC0adD59E62ac25578270cFf1b9f619"],
  143: ["0x3bd359C1119dA7Da1D913D1C4D2B7c461115433A"],
  196: ["0xe538905cf8410324e03A5A23C1c177a474D59b2b"],
  480: ["0x4200000000000000000000000000000000000006"],
  999: ["0x5555555555555555555555555555555555555555"],
  1868: ["0x4200000000000000000000000000000000000006"],
  4326: ["0x4200000000000000000000000000000000000006"],
  4663: ["0x4200000000000000000000000000000000000006"],
  8453: ["0x4200000000000000000000000000000000000006"],
  42161: ["0x82aF49447D8a07e3bd95BD0d56f35241523fBab1"],
  43114: ["0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7"],
  57073: ["0x4200000000000000000000000000000000000006"],
  59144: ["0xe5D7C2a44FfDDf6b295A15c148167daaAf5Cf34f"],
  7777777: ["0x4200000000000000000000000000000000000006"],
};

// chainlist.org has stale/wrong entries for some chains
const NATIVE_OVERRIDE: Record<number, string> = { 999: "HYPE" };

const FEE_TIERS: [number, number][] = [[100, 1], [500, 10], [3000, 60], [10000, 200]];
const MIN_REF_LIQUIDITY = 10n ** 9n; // below this a "reference" pool is not meaningful

const ur = parseAbi(["function WETH9() view returns (address)"]);
const erc20 = parseAbi(["function symbol() view returns (string)", "function decimals() view returns (uint8)"]);
const stateViewAbi = parseAbi([
  "function getLiquidity(bytes32 poolId) view returns (uint128)",
  "function getSlot0(bytes32 poolId) view returns (uint160 sqrtPriceX96,int24 tick,uint24 protocolFee,uint24 lpFee)",
]);
const router = parseAbi(["function isChainSupported(uint64) view returns (bool)", "function getArmProxy() view returns (address)"]);
const rmnAbi = parseAbi(["function isCursed() view returns (bool)"]);

async function getText(url: string): Promise<string> {
  const r = await fetch(url, { headers: { "User-Agent": "nidhi-registry" } });
  if (!r.ok) throw new Error(`${url} -> ${r.status}`);
  return r.text();
}
async function getJson(url: string): Promise<any> {
  return JSON.parse(await getText(url));
}

/** Rows "<chain label> <address>" under each contract heading on the Uniswap deployments page (SSR HTML). */
function parseUniswapPage(html: string) {
  const rowRe = /<span class="text-neutral1">([^<]+)<\/span><\/span><\/div><div[^>]*>\s*<button[^>]*aria-label="Copy address (0x[0-9a-fA-F]{40})"/g;
  const names = ["PoolManager", "PositionManager", "V4Quoter", "StateView", "ReservesLens", "FeeOnTransferDetector", "WETHHook", "ERC7914Detector", "PoolSwapTest"];
  const heads: { i: number; n: string }[] = [];
  for (const n of names) for (const m of html.matchAll(new RegExp(`>${n}<`, "g"))) heads.push({ i: m.index!, n });
  heads.sort((a, b) => a.i - b.i);
  const out: Record<string, Record<string, string>> = {};
  for (const m of html.matchAll(rowRe)) {
    let cur: string | null = null;
    for (const h of heads) { if (h.i < m.index!) cur = h.n; else break; }
    if (!cur) continue;
    out[cur] ??= {};
    out[cur][m[1]] ??= getAddress(m[2]); // first row per chain under a heading wins (headers repeat for variants)
  }
  return out;
}

/** Universal Router 2.1.2 + UniswapX flags from the Trading API supported-chains markdown table. */
function parseTradingApi(md: string) {
  const out: Record<number, { universalRouter: Address; uniswapX: boolean }> = {};
  for (const line of md.split("\n")) {
    const m = line.match(/^\|\s*(\d+)\s*\|\s*([^|]+)\|\s*(0x[0-9a-fA-F]{40})\s*\|\s*([^|]*)\|/);
    if (m) out[Number(m[1])] = { universalRouter: getAddress(m[3]), uniswapX: /yes/i.test(m[4]) };
  }
  return out;
}

async function pickRpc(chainId: number, chainlist: any[]): Promise<{ url: string; client: PublicClient } | null> {
  const listed = (chainlist.find((c) => c.chainId === chainId)?.rpc ?? []).filter((u: string) => u.startsWith("http") && !u.includes("${"));
  for (const url of [...(RPC_PINS[chainId] ?? []), ...listed]) {
    try {
      const client = createPublicClient({ transport: http(url, { timeout: 8000, retryCount: 0 }) });
      if ((await client.getChainId()) === chainId) return { url, client: client as PublicClient };
    } catch { /* next */ }
  }
  return null;
}

const hasCode = async (c: PublicClient, a: Address) => ((await c.getCode({ address: a })) ?? "0x") !== "0x";

function poolId(c0: Address, c1: Address, fee: number, spacing: number): `0x${string}` {
  return keccak256(encodeAbiParameters(
    [{ type: "address" }, { type: "address" }, { type: "uint24" }, { type: "int24" }, { type: "address" }],
    [c0, c1, fee, spacing, zeroAddress],
  ));
}

async function referencePool(c: PublicClient, stateView: Address, a: Address, b: Address) {
  const [c0, c1] = BigInt(a) < BigInt(b) ? [a, b] : [b, a];
  let best: { fee: number; tickSpacing: number; liquidity: string; poolId: string } | null = null;
  let bestL = 0n;
  for (const [fee, spacing] of FEE_TIERS) {
    const id = poolId(c0, c1, fee, spacing);
    try {
      const l = (await c.readContract({ address: stateView, abi: stateViewAbi, functionName: "getLiquidity", args: [id] })) as bigint;
      if (l > bestL) { bestL = l; best = { fee, tickSpacing: spacing, liquidity: l.toString(), poolId: id }; }
    } catch { /* pool absent */ }
  }
  return bestL >= MIN_REF_LIQUIDITY ? best : null;
}

async function build() {
  console.log("fetching official sources…");
  const [uniHtml, tradingMd, ccipChains, ccipTokens, ccipLanes, chainlist] = await Promise.all([
    getText("https://developers.uniswap.org/deployments"),
    getText("https://developers.uniswap.org/docs/trading/swapping-api/supported-chains.md"),
    getJson("https://docs.chain.link/api/ccip/v1/chains?environment=mainnet&outputKey=chainId"),
    getJson("https://docs.chain.link/api/ccip/v1/tokens?environment=mainnet"),
    getJson("https://docs.chain.link/api/ccip/v1/lanes?environment=mainnet&outputKey=chainId"),
    getJson("https://chainid.network/chains.json"),
  ]);
  const uni = parseUniswapPage(uniHtml);
  const trading = parseTradingApi(tradingMd);
  const ccip = ccipChains.data.evm;
  const tokens = ccipTokens.data ?? ccipTokens;
  const lanes = ccipLanes.data ?? ccipLanes;
  const ids = Object.values(UNI_NAMES);

  const registry: Record<string, any> = {};
  for (const [label, chainId] of Object.entries(UNI_NAMES)) {
    const row = (k: string) => uni[k]?.[label] as Address | undefined;
    const ch = ccip[String(chainId)];
    const entry: any = {
      chainId, key: SHORT[chainId], name: label,
      uniswap: { poolManager: row("PoolManager"), positionManager: row("PositionManager"), quoter: row("V4Quoter"), stateView: row("StateView"), reservesLens: row("ReservesLens"), feeOnTransferDetector: row("FeeOnTransferDetector") ?? null, permit2: "0x000000000022D473030F116dDEE9F6B43aC78BA3", universalRouter: trading[chainId]?.universalRouter ?? null },
      tradingApi: Boolean(trading[chainId]),
      uniswapX: Boolean(trading[chainId]?.uniswapX),
      ccip: ch ? { selector: ch.selector, router: getAddress(ch.router), feeTokens: ch.feeTokens ?? [] } : null,
      lanesTo: ids.filter((o) => o !== chainId && lanes[`${chainId}_to_${o}`]).map(String),
    };
    const usdc = tokens.USDC?.[String(chainId)], link = tokens.LINK?.[String(chainId)];
    entry.tokens = {
      usdc: usdc ? { address: getAddress(usdc.tokenAddress), decimals: usdc.decimals, poolType: usdc.pool?.type } : null,
      link: link ? { address: getAddress(link.tokenAddress), decimals: link.decimals } : null,
    };

    const rpc = await pickRpc(chainId, chainlist);
    entry.rpc = rpc?.url ?? null;
    entry.native = NATIVE_OVERRIDE[chainId] ?? chainlist.find((c: any) => c.chainId === chainId)?.nativeCurrency?.symbol ?? "?";
    if (rpc) {
      const c = rpc.client;
      const checks: Record<string, boolean> = {};
      for (const [k, v] of Object.entries(entry.uniswap)) if (v && k !== "permit2") checks[k] = await hasCode(c, v as Address);
      checks.permit2 = await hasCode(c, entry.uniswap.permit2);
      if (entry.ccip) {
        checks.ccipRouter = await hasCode(c, entry.ccip.router);
        // live Risk Management Network status (transient; a cursed chain cannot send CCIP messages right now)
        try {
          const arm = (await c.readContract({ address: entry.ccip.router, abi: router, functionName: "getArmProxy" })) as Address;
          entry.ccip.rmn = getAddress(arm);
          entry.ccip.cursedAtGeneration = (await c.readContract({ address: arm, abi: rmnAbi, functionName: "isCursed" })) as boolean;
        } catch { entry.ccip.cursedAtGeneration = null; }
      }
      entry.codeChecks = checks;
      // payout token: USDC where CCIP supports it, else LINK
      const payout = entry.tokens.usdc ?? entry.tokens.link;
      entry.payoutToken = payout ? { symbol: entry.tokens.usdc ? "USDC" : "LINK", address: payout.address, decimals: payout.decimals } : null;

      // wrapped native: CCIP WETH data first, then canonical candidates; accept only with code + symbol()
      const cands = [tokens.WETH?.[String(chainId)]?.tokenAddress, ...(WRAPPED_CANDIDATES[chainId] ?? [])].filter(Boolean).map((a: string) => getAddress(a));
      for (const cand of [...new Set(cands)]) {
        if (!(await hasCode(c, cand))) continue;
        try {
          const sym = (await c.readContract({ address: cand, abi: erc20, functionName: "symbol" })) as string;
          if (/^W/i.test(sym)) { entry.wrappedNative = { address: cand, symbol: sym }; break; }
        } catch { /* next */ }
      }

      // reference pool: the deepest hookless v4 pool for (native|wrapped, payout)
      if (entry.payoutToken && entry.uniswap.stateView) {
        const sides: Address[] = [zeroAddress, ...(entry.wrappedNative ? [entry.wrappedNative.address] : [])];
        let best: any = null;
        for (const side of sides) {
          const rp = await referencePool(c, entry.uniswap.stateView, side, entry.payoutToken.address);
          if (rp && (!best || BigInt(rp.liquidity) > BigInt(best.liquidity))) best = { ...rp, base: side === zeroAddress ? "native" : "wrapped" };
        }
        entry.referencePool = best;
      }
    }
    // capability derivation
    const codeOk = entry.codeChecks && Object.values(entry.codeChecks).every(Boolean);
    entry.capabilities = {
      destination: Boolean(entry.ccip && codeOk && entry.payoutToken && entry.lanesTo.length),
      source: Boolean(entry.ccip && codeOk && entry.payoutToken && entry.wrappedNative && entry.referencePool && entry.lanesTo.length),
    };
    registry[String(chainId)] = entry;
    const cap = entry.capabilities;
    console.log(`${String(chainId).padStart(8)} ${label.padEnd(16)} rpc=${rpc ? "ok " : "NO "} code=${codeOk ? "ok" : "??"} payout=${(entry.payoutToken?.symbol ?? "-").padEnd(4)} wrapped=${entry.wrappedNative ? "ok" : "-"} refPool=${entry.referencePool ? "L=" + entry.referencePool.liquidity.slice(0, 8) : "-"} lanes=${String(entry.lanesTo.length).padStart(2)} -> source:${cap.source ? "Y" : "n"} dest:${cap.destination ? "Y" : "n"}`);
  }

  // USDC payout lanes: a grant needs USDC supported at BOTH ends on a real lane, with a hookable source pool.
  const sources = Object.values(registry).filter((c: any) => c.capabilities.source).map((c: any) => c.chainId as number);
  for (const e of Object.values<any>(registry)) {
    const usdcDest: number[] = (tokens.USDC?.[String(e.chainId)]?.destinations ?? []).map(Number);
    e.payoutLanes = e.capabilities.source
      ? usdcDest.filter((d) => sources.includes(d) && e.lanesTo.includes(String(d))).sort((a, b) => a - b)
      : [];
    // a chain can receive iff some source chain reaches it with USDC
    e.capabilities.destination = Object.values<any>(registry).some((o) => o.payoutLanes?.includes(e.chainId)) || Boolean(e.capabilities.source && e.payoutLanes.length);
    if (!e.capabilities.source) {
      e.excludedBecause = !e.ccip ? "no CCIP router"
        : !e.tokens.usdc ? "no CCIP-supported USDC (cannot pay a USDC grant)"
        : !e.wrappedNative ? "no verified wrapped-native token"
        : !e.referencePool ? "no funded canonical v4 USDC pool to price against"
        : "no USDC lane to another Nidhi chain";
    }
  }
  fs.mkdirSync(path.dirname(OUT), { recursive: true });
  const sourceChains = Object.values<any>(registry).filter((c) => c.capabilities.source).map((c) => c.chainId);
  const doc = { generatedAt: new Date().toISOString(), sourceChains, sources: ["developers.uniswap.org/deployments", "developers.uniswap.org/docs/trading/swapping-api/supported-chains", "docs.chain.link/api/ccip/v1", "on-chain reads"], chains: registry };
  fs.writeFileSync(OUT, JSON.stringify(doc, null, 2) + "\n");
  const live = Object.values<any>(registry).filter((c) => c.capabilities.source);
  const laneCount = live.reduce((n, c) => n + c.payoutLanes.length, 0);
  console.log(`\nwrote ${path.relative(root, OUT)}: ${Object.keys(registry).length} chains`);
  console.log(`DEPLOYABLE (source + destination): ${live.length} chains, ${laneCount} directed USDC payout lanes: ${live.map((c) => c.key).join(", ")}`);
  for (const e of Object.values<any>(registry)) if (!e.capabilities.source) console.log(`  excluded ${e.name.padEnd(16)} ${e.excludedBecause}`);
}

async function check() {
  const doc = JSON.parse(fs.readFileSync(OUT, "utf8"));
  let bad = 0;
  for (const e of Object.values<any>(doc.chains)) {
    if (!e.rpc) { console.log(`${e.name}: no rpc recorded`); bad++; continue; }
    const c = createPublicClient({ transport: http(e.rpc, { timeout: 8000, retryCount: 1 }) }) as PublicClient;
    try {
      for (const [k, a] of Object.entries<any>({ ...e.uniswap, ...(e.ccip ? { ccipRouter: e.ccip.router } : {}) })) {
        if (a && !(await hasCode(c, a))) { console.log(`${e.name}: ${k} ${a} has no code`); bad++; }
      }
      if (e.ccip) {
        const ok = await c.readContract({ address: e.ccip.router, abi: router, functionName: "isChainSupported", args: [BigInt(doc.chains["8453"]?.ccip?.selector ?? 0)] }).catch(() => null);
        if (ok === null) { console.log(`${e.name}: CCIP router did not answer isChainSupported`); bad++; }
      }
    } catch (err: any) { console.log(`${e.name}: RPC error ${err.shortMessage ?? err.message}`); bad++; }
  }
  console.log(bad ? `${bad} problem(s)` : "registry verified against live chains");
  process.exit(bad ? 1 : 0);
}

(process.argv.includes("--check") ? check() : build()).catch((e) => { console.error(e); process.exit(1); });
