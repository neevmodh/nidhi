// Testnet registry generator (read-only).
//
//   node src/testnets.ts      writes ../chains/testnets.json (same schema as registry.json) after on-chain checks
//
// Testnets have no deep reference pool and no USDC lanes, so a chain entry differs from mainnet in three ways:
//   - the payout token is CCIP-BnM (Chainlink's public test token; anyone can `drip`)
//   - there is no referencePool: the guard is disabled and the pool is created at `testPool.initTick`
//   - lanes come from Chainlink's CCIP-BnM destinations, intersected with the chains we deploy on
// Addresses: Uniswap's deployments page (identified on-chain by `poolManager()` / `WETH9()`), Chainlink CCIP directory.
// Nothing here sends a transaction.

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { createPublicClient, getAddress, http, parseAbi, type Address } from "viem";

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, "..", "..");
const OUT = path.join(root, "chains", "testnets.json");

const IDS = [11155111, 84532, 421614, 1301] as const;

interface Pin {
  key: string;
  name: string;
  rpc: string;
  poolManager: Address;
  positionManager: Address;
  quoter: Address;
  stateView?: Address;
  permit2: Address;
  tradingApi: boolean;
  explorer: string;
}

const PINS: Record<number, Pin> = {
  11155111: {
    key: "sepolia", name: "Ethereum Sepolia", rpc: "https://ethereum-sepolia-rpc.publicnode.com",
    poolManager: "0xE03A1074c86CFeDd5C142C4F04F1a1536e203543", positionManager: "0x429ba70129df741B2Ca2a85BC3A2a3328e5c09b4",
    quoter: "0x68aFa8b853cAa7a2D40B0F6AEE5C4DbC147C8244", stateView: "0xE1Dd9c3fA50EDB962E442f60DfBc432e24537E4C",
    permit2: "0x000000000022D473030F116dDEE9F6B43aC78BA3", tradingApi: true, explorer: "https://sepolia.etherscan.io",
  },
  84532: {
    key: "base-sepolia", name: "Base Sepolia", rpc: "https://sepolia.base.org",
    poolManager: "0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408", positionManager: "0x4B2C77d209D3405F41a037Ec6c77F7F5b8e2ca80",
    quoter: "0x4A6513c898fe1B2d0E78d3b0e0A4a151589B1cBa", stateView: "0x571291b572ed32ce6751a2Cb2486EbEe8DEfB9B4",
    permit2: "0x000000000022D473030F116dDEE9F6B43aC78BA3", tradingApi: true, explorer: "https://sepolia.basescan.org",
  },
  421614: {
    key: "arbitrum-sepolia", name: "Arbitrum Sepolia", rpc: "https://sepolia-rollup.arbitrum.io/rpc",
    poolManager: "0xFB3e0C6F74eB1a21CC1Da29aeC80D2Dfe6C9a317", positionManager: "0xAc631556d3d4019C95769033B5E719dD77124BAc",
    quoter: "0x7dE51022d70A725b508085468052E25e22b5c4c9", stateView: "0x9D467FA9062b6e9B1a46E26007aD82db116c67cB",
    permit2: "0x000000000022D473030F116dDEE9F6B43aC78BA3", tradingApi: false, explorer: "https://sepolia.arbiscan.io",
  },
  1301: {
    key: "unichain-sepolia", name: "Unichain Sepolia", rpc: "https://sepolia.unichain.org",
    poolManager: "0x9cB26A7183B2F4515945Dc52CB4195B0d2D06C95", positionManager: "0x12A98709BB5D0641D61458f85dcAFbE17AC2d05c",
    quoter: "0xB2b34025a07af3925313b6B46f8046Ee8FfBa30B",
    permit2: "0x000000000022D473030F116dDEE9F6B43aC78BA3", tradingApi: true, explorer: "https://unichain-sepolia.blockscout.com",
  },
};

const abi = parseAbi([
  "function poolManager() view returns (address)",
  "function WETH9() view returns (address)",
  "function nextTokenId() view returns (uint256)",
  "function decimals() view returns (uint8)",
  "function symbol() view returns (string)",
  "function isChainSupported(uint64) view returns (bool)",
  "function getArmProxy() view returns (address)",
  "function isCursed() view returns (bool)",
]);

async function json(url: string): Promise<any> {
  const r = await fetch(url);
  if (!r.ok) throw new Error(`${url} -> ${r.status}`);
  return r.json();
}

async function main() {
  const [chainsDoc, tokensDoc] = await Promise.all([
    json("https://docs.chain.link/api/ccip/v1/chains?environment=testnet&outputKey=chainId"),
    json("https://docs.chain.link/api/ccip/v1/tokens?environment=testnet"),
  ]);
  const ccipChains = (chainsDoc.data ?? chainsDoc).evm ?? chainsDoc.data ?? chainsDoc;
  const bnm = (tokensDoc.data ?? tokensDoc)["CCIP-BnM"];

  const chains: Record<string, any> = {};
  for (const id of IDS) {
    const pin = PINS[id];
    const cc = ccipChains[String(id)];
    const b = bnm[String(id)];
    if (!cc || !b) throw new Error(`Chainlink has no CCIP-BnM entry for ${id}`);
    const client = createPublicClient({ transport: http(pin.rpc, { timeout: 20000 }) });

    // every Uniswap address is identified by what it answers, not by where it was listed
    const ok = async (f: () => Promise<boolean>) => { try { return await f(); } catch { return false; } };
    const checks = {
      poolManager: (await client.getCode({ address: pin.poolManager }))!.length > 2,
      positionManager: await ok(async () => (await client.readContract({ address: pin.positionManager, abi, functionName: "poolManager" })) === pin.poolManager),
      quoter: await ok(async () => (await client.readContract({ address: pin.quoter, abi, functionName: "poolManager" })) === pin.poolManager),
      ccipRouter: (await client.getCode({ address: cc.router }))!.length > 2,
      bnm: (await client.getCode({ address: b.tokenAddress }))!.length > 2,
    };
    for (const [k, v] of Object.entries(checks)) if (!v) throw new Error(`${pin.name}: ${k} check failed`);

    const weth = (await client.readContract({ address: pin.positionManager, abi, functionName: "WETH9" })) as Address;
    const lanes: number[] = [];
    for (const d of b.destinations as string[]) {
      const did = Number(d);
      if (!(IDS as readonly number[]).includes(did) || did === id) continue;
      const sel = BigInt(ccipChains[d].selector);
      const supported = await client.readContract({ address: cc.router, abi, functionName: "isChainSupported", args: [sel] });
      if (supported) lanes.push(did);
    }
    const arm = (await client.readContract({ address: cc.router, abi, functionName: "getArmProxy" })) as Address;
    const cursed = await client.readContract({ address: arm, abi, functionName: "isCursed" });

    chains[String(id)] = {
      chainId: id,
      key: pin.key,
      name: pin.name,
      testnet: true,
      uniswap: {
        poolManager: pin.poolManager,
        positionManager: pin.positionManager,
        quoter: pin.quoter,
        ...(pin.stateView ? { stateView: pin.stateView } : {}),
        permit2: pin.permit2,
      },
      tradingApi: pin.tradingApi,
      ccip: { selector: String(cc.selector), router: getAddress(cc.router), rmn: cc.rmn, feeTokens: cc.feeTokens, cursedAtGeneration: cursed },
      lanesTo: lanes.map(String),
      tokens: { bnm: { address: getAddress(b.tokenAddress), decimals: b.decimals } },
      rpc: pin.rpc,
      explorer: pin.explorer,
      native: "ETH",
      codeChecks: checks,
      payoutToken: { symbol: "CCIP-BnM", address: getAddress(b.tokenAddress), decimals: b.decimals },
      wrappedNative: { address: getAddress(weth), symbol: "WETH" },
      // No reference pool on testnets: the guard is off and the pool is opened at ~1 WETH = 1000 BnM.
      testPool: { fee: 3000, tickSpacing: 60, initTickBaseIsCurrency0: 69060 },
      capabilities: { destination: true, source: true },
      payoutLanes: lanes,
    };
  }

  const doc = {
    generatedAt: new Date().toISOString(),
    testnet: true,
    sourceChains: [...IDS],
    sources: ["developers.uniswap.org/deployments", "docs.chain.link/api/ccip/v1", "on-chain reads"],
    chains,
  };
  fs.writeFileSync(OUT, JSON.stringify(doc, null, 2) + "\n");
  console.log("chain".padEnd(18), "id".padEnd(9), "cursed", "lanes");
  for (const c of Object.values<any>(chains)) console.log(c.name.padEnd(18), String(c.chainId).padEnd(9), String(c.ccip.cursedAtGeneration).padEnd(6), c.payoutLanes.join(","));
  console.log(`\nwrote ${path.relative(root, OUT)}`);
}

main().catch((e) => { console.error(e instanceof Error ? e.message : e); process.exit(1); });
