import { formatUnits } from "viem";

export const short = (h?: string, a = 6, b = 4) => (!h ? "" : h.length <= a + b + 2 ? h : `${h.slice(0, a)}…${h.slice(-b)}`);

/** a token amount with sensible precision: 0.2934, 12.5, 1,204 */
export function amount(v: bigint | undefined, decimals = 18, max = 4): string {
  if (v === undefined) return "";
  const n = Number(formatUnits(v, decimals));
  if (n === 0) return "0";
  if (n < 0.0001) return "<0.0001";
  return n.toLocaleString("en-US", { maximumFractionDigits: n >= 100 ? 0 : max });
}

export function ago(ts?: number): string {
  if (!ts) return "";
  const s = Math.max(0, Math.floor(Date.now() / 1000 - ts));
  if (s < 60) return "just now";
  if (s < 3600) return `${Math.floor(s / 60)} min ago`;
  if (s < 86400) return `${Math.floor(s / 3600)} h ago`;
  return `${Math.floor(s / 86400)} d ago`;
}

export const sameAddr = (a?: string, b?: string) => !!a && !!b && a.toLowerCase() === b.toLowerCase();
