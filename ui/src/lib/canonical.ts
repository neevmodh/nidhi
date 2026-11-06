import { keccak256, toBytes, type Hex } from "viem";

// The same canonical JSON as offchain/src/lib.ts (sorted keys, no whitespace), so a hash made here is the hash the
// agent recomputes. Used for a milestone's spec hash, which the poster commits to on-chain.
export function canonical(value: unknown): string {
  if (value === null || typeof value !== "object") return JSON.stringify(value);
  if (Array.isArray(value)) return `[${value.map(canonical).join(",")}]`;
  const obj = value as Record<string, unknown>;
  return `{${Object.keys(obj).sort().filter((k) => obj[k] !== undefined).map((k) => `${JSON.stringify(k)}:${canonical(obj[k])}`).join(",")}}`;
}
export const hashJson = (v: unknown): Hex => keccak256(toBytes(canonical(v)));

/** mirrors offchain/src/bounty.ts bountySpecHash */
export function bountySpecHash(spec: { title: string; repo: string; body: string; rules: string; grantee: string }, destChainSelector: bigint | string, amountIn: bigint | string): Hex {
  let rules: unknown = {};
  try { rules = JSON.parse(spec.rules || "{}"); } catch { rules = spec.rules; }
  return hashJson({ kind: "nidhi.bounty.v1", title: spec.title, repo: spec.repo, body: spec.body, rules, grantee: spec.grantee, destChainSelector: String(destChainSelector), amountIn: String(amountIn) });
}
