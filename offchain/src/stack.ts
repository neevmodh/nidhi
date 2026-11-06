// The ENSv2-gated source stack the milestone agent pays from, plus the EIP-712 and hookData encodings the hook checks.
// Everything here is read from the repo's deployment files; nothing is hard-coded but the RPC fallbacks.
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { createPublicClient, encodeAbiParameters, fallback, http, keccak256, toHex, type Address, type Hex } from "viem";

const here = path.dirname(fileURLToPath(import.meta.url));
export const repoRoot = path.resolve(here, "..", "..");
const read = (p: string) => JSON.parse(fs.readFileSync(path.join(repoRoot, p), "utf8"));

export const RPCS: Record<number, string[]> = {
  // public RPCs first; a configured private RPC is a fallback, so its rate limits never block a payout
  11155111: ["https://ethereum-sepolia-rpc.publicnode.com", process.env.SEPOLIA_RPC_URL ?? "", "https://sepolia.gateway.tenderly.co"].filter(Boolean),
  84532: ["https://sepolia.base.org", "https://base-sepolia-rpc.publicnode.com"],
  421614: ["https://sepolia-rollup.arbitrum.io/rpc", "https://arbitrum-sepolia-rpc.publicnode.com"],
};

export interface SourceStack {
  chainId: number;
  hook: Address;
  router: Address;
  dispatcher: Address;
  authority: Address;
  poolId: Hex;
  quoter: Address;
  base: Address; // wrapped native, the token the treasury pays in
  payout: Address; // CCIP-BnM on testnets
  receivers: Record<string, Address>; // payout chain id => the receiver this stack routes to
  selectors: Record<string, bigint>;
}

export function sourceStack(): SourceStack {
  const reg = read("chains/testnets.json").chains;
  const s = read("deployments/ens-v4-stack.json");
  const id = Number(s.chainId);
  const receivers: Record<string, Address> = {};
  for (const r of ["84532", "421614"]) {
    const f = path.join(repoRoot, "deployments", `ens-v4-receiver-${r}.json`);
    if (fs.existsSync(f)) receivers[r] = JSON.parse(fs.readFileSync(f, "utf8")).receiver;
  }
  const selectors: Record<string, bigint> = {};
  for (const [k, c] of Object.entries<any>(reg)) selectors[k] = BigInt(c.ccip.selector);
  return {
    chainId: id, hook: s.hook, router: s.router, dispatcher: s.dispatcher, authority: s.authority, poolId: s.poolId,
    quoter: reg[String(id)].uniswap.quoter, base: reg[String(id)].wrappedNative.address, payout: reg[String(id)].payoutToken.address,
    receivers, selectors,
  };
}

/** every RPC for a chain, tried in order, with retries: used for reads AND for sending transactions */
export const transport = (chainId: number) => fallback(RPCS[chainId].map((u) => http(u, { timeout: 20_000, retryCount: 2 })));
export const publicClient = (chainId: number) => createPublicClient({ transport: transport(chainId) });

export const domain = (s: SourceStack) => ({ name: "Nidhi", version: "1", chainId: s.chainId, verifyingContract: s.hook });

export const MANDATE_TYPES = {
  Mandate: [
    { name: "grantId", type: "bytes32" }, { name: "executor", type: "address" }, { name: "recipient", type: "address" },
    { name: "tokenIn", type: "address" }, { name: "tokenOut", type: "address" }, { name: "amountIn", type: "uint128" },
    { name: "minOut", type: "uint128" }, { name: "maxOut", type: "uint128" }, { name: "destChainSelector", type: "uint64" },
    { name: "destReceiver", type: "address" }, { name: "evidenceHash", type: "bytes32" }, { name: "deadline", type: "uint64" },
    { name: "poolId", type: "bytes32" }, { name: "recipientLabelHash", type: "bytes32" },
  ],
} as const;
export const ATTESTATION_TYPES = {
  Attestation: [
    { name: "grantId", type: "bytes32" }, { name: "evidenceHash", type: "bytes32" }, { name: "inputsHash", type: "bytes32" },
    { name: "rubricHash", type: "bytes32" }, { name: "issuedAt", type: "uint64" },
  ],
} as const;

export const labelHash = (label: string) => keccak256(toHex(label));

export function poolKey(s: SourceStack) {
  const [c0, c1] = s.base.toLowerCase() < s.payout.toLowerCase() ? [s.base, s.payout] : [s.payout, s.base];
  return { currency0: c0, currency1: c1, fee: 3000, tickSpacing: 60, hooks: s.hook } as const;
}
export const zeroForOne = (s: SourceStack) => s.base.toLowerCase() < s.payout.toLowerCase();
export const MIN_SQRT = 4295128739n + 1n;
export const MAX_SQRT = 1461446703485210103287273052203988822378723970342n - 1n;

/** NidhiHook.GrantAuth, exactly as the hook decodes it */
export function hookData(g: { mandate: any; approver: Address; approverSig: Hex; attestation: any; auditor: Address; auditorSig: Hex; recipientLabel: string }): Hex {
  return encodeAbiParameters([{
    type: "tuple",
    components: [
      { name: "mandate", type: "tuple", components: MANDATE_TYPES.Mandate as any },
      { name: "approver", type: "address" }, { name: "approverSig", type: "bytes" },
      { name: "attestation", type: "tuple", components: ATTESTATION_TYPES.Attestation as any },
      { name: "auditor", type: "address" }, { name: "auditorSig", type: "bytes" },
      { name: "recipientLabel", type: "string" },
    ],
  }] as any, [g]);
}

// bigint-safe JSON for mandate files
export const toJson = (v: unknown) => JSON.stringify(v, (_, x) => (typeof x === "bigint" ? `${x}n` : x), 2) + "\n";
export const fromJson = (s: string) => JSON.parse(s, (_, x) => (typeof x === "string" && /^\d+n$/.test(x) ? BigInt(x.slice(0, -1)) : x));
