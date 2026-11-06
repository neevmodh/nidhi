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
  11155111: ["https://ethereum-sepolia-rpc.publicnode.com", "https://sepolia.gateway.tenderly.co"],
  84532: ["https://sepolia.base.org", "https://base-sepolia-rpc.publicnode.com", "https://base-sepolia.gateway.tenderly.co"],
  421614: ["https://sepolia-rollup.arbitrum.io/rpc", "https://arbitrum-sepolia-rpc.publicnode.com", "https://arbitrum-sepolia.gateway.tenderly.co"],
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
      transport: fallback(RPCS[id].map((u) => http(u, { timeout: 8_000, retryCount: 1, batch: { wait: 16 } }))),
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

// ---- source stacks: a chain can run more than one (Sepolia: the RoleAuthority stack and the ENSv2-gated stack)
export interface EnsIdentity {
  authority: Address; name: string; subregistry: Address; sharedResolver: Address; bobResolver: Address;
  carolExpiry: number; granteeWallet: Address; grantees: string; daoResolver: Address;
  approver: Address; auditor: Address; auditorName: string;
}
export interface Stack {
  kind: "roles" | "ens" | "hop";
  label: string;
  /** multi-hop: the stack sends to a relay on `via`, which forwards to `final` (no direct lane) */
  hop?: { via: ChainId; final: ChainId; relay: Address; finalReceiver: Address };
  hook: Address; router: Address; dispatcher: Address; authority: Address;
  poolId: `0x${string}`; positionId: number; fromBlock: number;
  /** destination chain id => the receiver this stack routes to, when it differs from that chain's own receiver */
  receivers?: Record<string, Address>;
  lanes: ChainId[];
}

export function stacksOf(c: ChainInfo): Stack[] {
  const d = c.deployment;
  if (!d) return [];
  const out: Stack[] = [{ kind: "roles", label: "RoleAuthority", hook: d.hook, router: d.router, dispatcher: d.dispatcher, authority: d.authority, poolId: d.poolId, positionId: d.positionId, fromBlock: d.fromBlock, lanes: c.lanes }];
  const e = (d as any).ens;
  // the current ENS stack first (stackOf picks it), then earlier ones, still read for their history
  for (const [i, s] of [e?.stack, ...(e?.previous ?? [])].filter(Boolean).entries()) {
    out.push({ kind: "ens", label: i === 0 ? "ENSv2 · nidhi-dao.eth" : `ENSv2 · nidhi-dao.eth (${s.version ?? "earlier"})`, hook: s.hook, router: s.router, dispatcher: s.dispatcher, authority: s.authority, poolId: s.poolId, positionId: s.positionId, fromBlock: s.fromBlock, receivers: s.receivers, lanes: Object.keys(s.receivers ?? {}).map(Number) as ChainId[] });
  }
  const h = (d as any).hop;
  if (h?.stack && h?.route) {
    const s = h.stack, r = h.route;
    out.push({ kind: "hop", label: `Multi-hop via ${SHORT[r.via] ?? r.via}`, hop: { via: r.via, final: r.final, relay: r.relay, finalReceiver: r.finalReceiver }, hook: s.hook, router: s.router, dispatcher: s.dispatcher, authority: s.authority, poolId: s.poolId, positionId: s.positionId, fromBlock: s.fromBlock, receivers: { [String(r.via)]: r.relay }, lanes: [r.via] });
  }
  return out;
}
export const ensOf = (c?: ChainInfo): EnsIdentity | undefined => (c?.deployment as any)?.ens?.identity;
export const stackOf = (c: ChainInfo, kind?: string) => stacksOf(c).find((s) => s.kind === (kind ?? "roles")) ?? stacksOf(c)[0];
