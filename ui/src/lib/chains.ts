import { createPublicClient, fallback, http, type Address, type PublicClient } from "viem";
import { arbitrumSepolia, baseSepolia, sepolia, unichainSepolia } from "viem/chains";
import testnets from "../data/testnets.json";
import deployments from "../data/deployments.json";

export type ChainId = 11155111 | 84532 | 421614 | 1301;

export interface Deployment {
  chainId: number;
  hook: Address;
  dispatcher: Address;
  receiver: Address;
  router: Address;
  authority: Address;
  admin: Address;
  deployer: Address;
  poolId: `0x${string}`;
  positionId: number;
  dailyCapBaseWei: number | string;
  fromBlock: number;
}

export interface ChainInfo {
  id: ChainId;
  key: string;
  name: string;
  short: string;
  logo: string; // key into logos.ts
  explorer: string;
  selector: bigint;
  ccipRouter: Address;
  payout: { symbol: string; address: Address; decimals: number };
  base: { symbol: string; address: Address };
  uniswap: { poolManager: Address; positionManager: Address; quoter: Address; stateView?: Address };
  lanes: ChainId[];
  tradingApi: boolean;
  deployment?: Deployment;
}

const SHORT: Record<number, string> = { 11155111: "Sepolia", 84532: "Base Sepolia", 421614: "Arbitrum Sepolia", 1301: "Unichain Sepolia" };
const LOGO: Record<number, string> = { 11155111: "ethereum", 84532: "base", 421614: "arbitrum", 1301: "unichain" };
const VIEM = { 11155111: sepolia, 84532: baseSepolia, 421614: arbitrumSepolia, 1301: unichainSepolia } as const;

// Several public RPCs per chain: a flaky one never blanks a screen.
const RPCS: Record<number, string[]> = {
  11155111: ["https://ethereum-sepolia-rpc.publicnode.com", "https://sepolia.drpc.org", "https://1rpc.io/sepolia"],
  84532: ["https://sepolia.base.org", "https://base-sepolia-rpc.publicnode.com"],
  421614: ["https://sepolia-rollup.arbitrum.io/rpc", "https://arbitrum-sepolia-rpc.publicnode.com"],
  1301: ["https://sepolia.unichain.org", "https://unichain-sepolia-rpc.publicnode.com"],
};

const raw = (testnets as any).chains as Record<string, any>;
const deps = deployments as Record<string, Deployment>;

export const CHAINS: ChainInfo[] = Object.values(raw).map((c: any) => ({
  id: c.chainId,
  key: c.key,
  name: c.name,
  short: SHORT[c.chainId] ?? c.name,
  logo: LOGO[c.chainId] ?? "ethereum",
  explorer: c.explorer,
  selector: BigInt(c.ccip.selector),
  ccipRouter: c.ccip.router,
  payout: c.payoutToken,
  base: c.wrappedNative,
  uniswap: c.uniswap,
  lanes: c.payoutLanes,
  tradingApi: c.tradingApi,
  deployment: deps[String(c.chainId)],
}));

// a stable, readable order: L1 first, then the L2s
const ORDER: ChainId[] = [11155111, 84532, 421614, 1301];
CHAINS.sort((a, b) => ORDER.indexOf(a.id) - ORDER.indexOf(b.id));

export const chainById = (id: number) => CHAINS.find((c) => c.id === id);
export const chainBySelector = (sel: bigint) => CHAINS.find((c) => c.selector === sel);
export const deployedChains = () => CHAINS.filter((c) => c.deployment);
export const viemChain = (id: ChainId) => VIEM[id];

const clients = new Map<number, PublicClient>();
export function client(id: number): PublicClient {
  let c = clients.get(id);
  if (!c) {
    c = createPublicClient({
      chain: VIEM[id as ChainId],
      transport: fallback(RPCS[id].map((u) => http(u, { timeout: 15_000, retryCount: 1 }))),
      batch: { multicall: true },
    }) as PublicClient;
    clients.set(id, c);
  }
  return c;
}
export const rpcUrls = (id: number) => RPCS[id];

export const txUrl = (c: ChainInfo, hash: string) => `${c.explorer}/tx/${hash}`;
export const addrUrl = (c: ChainInfo, a: string) => `${c.explorer}/address/${a}`;
export const ccipUrl = (messageId: string) => `https://ccip.chain.link/msg/${messageId}`;

export const chainByKey = (k?: string) => CHAINS.find((c) => c.key === k || String(c.id) === k);
