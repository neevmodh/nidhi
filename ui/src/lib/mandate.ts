import { encodeAbiParameters, keccak256, toHex, type Address, type Hex } from "viem";
import { chainById, type ChainInfo } from "./chains";

// Mirrors src/libraries/Mandate.sol and NidhiHook.GrantAuth exactly.
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

export interface Mandate {
  grantId: Hex; executor: Address; recipient: Address; tokenIn: Address; tokenOut: Address;
  amountIn: bigint; minOut: bigint; maxOut: bigint; destChainSelector: bigint; destReceiver: Address;
  evidenceHash: Hex; deadline: bigint; poolId: Hex; recipientLabelHash: Hex;
}
export interface Attestation { grantId: Hex; evidenceHash: Hex; inputsHash: Hex; rubricHash: Hex; issuedAt: bigint; }

export interface Draft {
  v: 1;
  src: number;
  /** which source stack signs and swaps: the RoleAuthority stack (default) or the ENSv2-gated one */
  stack?: "roles" | "ens";
  label: string;
  mandate: Mandate;
  attestation: Attestation;
  approver?: Address; approverSig?: Hex;
  auditor?: Address; auditorSig?: Hex;
}

export const domain = (c: ChainInfo, hook: Address = c.deployment!.hook) => ({ name: "Nidhi", version: "1", chainId: c.id, verifyingContract: hook });

export const poolKey = (c: ChainInfo, hook: Address = c.deployment!.hook) => {
  const [c0, c1] = c.base.address.toLowerCase() < c.payout.address.toLowerCase() ? [c.base.address, c.payout.address] : [c.payout.address, c.base.address];
  return { currency0: c0, currency1: c1, fee: 3000, tickSpacing: 60, hooks: hook } as const;
};
export const zeroForOne = (c: ChainInfo) => c.base.address.toLowerCase() < c.payout.address.toLowerCase();
export const MIN_SQRT = 4295128739n + 1n;
export const MAX_SQRT = 1461446703485210103287273052203988822378723970342n - 1n;

export const newGrantId = (label: string) => keccak256(toHex(`nidhi-ui:${label}:${Date.now()}:${Math.random()}`));
export const labelHash = (label: string) => keccak256(toHex(label));

const GRANT_AUTH = [{
  type: "tuple",
  components: [
    { name: "mandate", type: "tuple", components: MANDATE_TYPES.Mandate as any },
    { name: "approver", type: "address" }, { name: "approverSig", type: "bytes" },
    { name: "attestation", type: "tuple", components: ATTESTATION_TYPES.Attestation as any },
    { name: "auditor", type: "address" }, { name: "auditorSig", type: "bytes" },
    { name: "recipientLabel", type: "string" },
  ],
}] as const;

export function hookData(d: Draft): Hex {
  return encodeAbiParameters(GRANT_AUTH as any, [{
    mandate: d.mandate, approver: d.approver!, approverSig: d.approverSig!, attestation: d.attestation,
    auditor: d.auditor!, auditorSig: d.auditorSig!, recipientLabel: d.label,
  }]);
}

// ---- the draft travels in the URL so three different people can open the same grant
const big = (_: string, v: unknown) => (typeof v === "bigint" ? `${v}n` : v);
const unbig = (_: string, v: unknown) => (typeof v === "string" && /^\d+n$/.test(v) ? BigInt(v.slice(0, -1)) : v);
export const encodeDraft = (d: Draft) => btoa(unescape(encodeURIComponent(JSON.stringify(d, big)))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
export function decodeDraft(s: string): Draft | null {
  try {
    const d = JSON.parse(decodeURIComponent(escape(atob(s.replace(/-/g, "+").replace(/_/g, "/")))), unbig) as Draft;
    return d?.v === 1 && chainById(d.src) ? d : null;
  } catch { return null; }
}
