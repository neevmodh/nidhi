import type { Address, Hex, Log } from "viem";
import { client } from "./chains";
import snapshot from "../data/ledger-snapshot.json";

// Incremental, shared event history for every contract the app reads.
//
// One cache entry per (chain, contract address) holds ALL of that contract's logs up to a block. A read only fetches
// the blocks after it, in parallel windows, and then filters by event in memory. Starting points, in order:
//   1. this tab's memory   2. this browser's storage   3. the build-time snapshot (data/ledger-snapshot.json)   4. deploy
// Logs are append-only facts on the chain, so a cached log never goes stale; only new blocks are ever fetched.
// Anything that can change (a grant's status, a payout, a role, an ENS record) is read live elsewhere, not from here.

interface Entry { from: number; to: number; logs: RawLog[] }
interface RawLog { b: number; i: number; t: Hex; topics: Hex[]; data: Hex }

const STORE = "nidhi.logs.v1";
const mem = new Map<string, Entry>();
const inflight = new Map<string, Promise<Entry>>();
const head = new Map<number, { at: number; block: number; p?: Promise<number> }>();

const key = (chainId: number, address: Address) => `${chainId}:${address.toLowerCase()}`;
// provider log-range caps: Arbitrum allows wide ranges; Unichain's RPC rejects more than 1,000 blocks (its fallback is pruned)
const WINDOW: Record<number, number> = { 421614: 40_000, 1301: 1_000 };
const step = (chainId: number) => WINDOW[chainId] ?? 9_000;
// Load-balanced public RPCs disagree about the head by a few blocks; scanning a little behind it avoids
// "range extends beyond current head" errors. Those last blocks are read on the next refresh, seconds later.
const LAG: Record<number, number> = { 11155111: 3, 84532: 20, 421614: 80, 1301: 20 };
const lag = (chainId: number) => LAG[chainId] ?? 5;

function load(k: string): Entry | undefined {
  if (mem.has(k)) return mem.get(k);
  try {
    const all = JSON.parse(localStorage.getItem(STORE) ?? "{}");
    if (all[k]) { mem.set(k, all[k]); return all[k]; }
  } catch { /* storage unavailable or corrupt: fall through */ }
  const snap = (snapshot as any)?.entries?.[k] as Entry | undefined;
  if (snap && Array.isArray(snap.logs)) { mem.set(k, snap); return snap; }
  return undefined;
}

function save(k: string, e: Entry) {
  mem.set(k, e);
  try {
    const all = JSON.parse(localStorage.getItem(STORE) ?? "{}");
    all[k] = e;
    localStorage.setItem(STORE, JSON.stringify(all));
  } catch { /* private mode or quota: memory still works */ }
}

/** the chain head, shared by every read for a few seconds */
export async function latestBlock(chainId: number): Promise<number> {
  const h = head.get(chainId);
  if (h && Date.now() - h.at < 4_000) return h.p ?? h.block;
  const p = client(chainId).getBlockNumber().then((n) => {
    head.set(chainId, { at: Date.now(), block: Number(n) });
    return Number(n);
  });
  head.set(chainId, { at: Date.now(), block: h?.block ?? 0, p });
  try { return await p; } catch (e) { head.delete(chainId); throw e; }
}

async function windows<T>(ranges: [number, number][], fn: (r: [number, number]) => Promise<T>, concurrency = 4): Promise<T[]> {
  const out: T[] = new Array(ranges.length);
  let next = 0;
  await Promise.all(Array.from({ length: Math.min(concurrency, ranges.length) }, async () => {
    while (next < ranges.length) { const i = next++; out[i] = await fn(ranges[i]); }
  }));
  return out;
}

async function refresh(chainId: number, address: Address, fromBlock: number): Promise<Entry> {
  const k = key(chainId, address);
  let have = load(k);
  if (have && (typeof have.from !== "number" || fromBlock < have.from)) have = undefined; // asked for older history: rescan
  const latest = Math.max(0, (await latestBlock(chainId)) - lag(chainId));
  const start = have ? Math.max(have.to + 1, fromBlock) : fromBlock;
  if (have && start > latest) return have;
  const ranges: [number, number][] = [];
  for (let s = start; s <= latest; s += step(chainId) + 1) ranges.push([s, Math.min(s + step(chainId), latest)]);
  const get = (a: number, b: number) => client(chainId).getLogs({ address, fromBlock: BigInt(a), toBlock: BigInt(b) });
  // one retry per window: a lagging node can still reject the newest blocks
  const chunks = await windows(ranges, ([a, b]) => get(a, b).catch(() => new Promise((r) => setTimeout(r, 600)).then(() => get(a, b))));
  const fresh: RawLog[] = chunks.flat().map((l) => ({ b: Number(l.blockNumber), i: Number(l.logIndex), t: l.transactionHash!, topics: l.topics as Hex[], data: l.data }));
  const seen = new Set((have?.logs ?? []).map((l) => `${l.b}:${l.i}`));
  const logs = [...(have?.logs ?? []), ...fresh.filter((l) => !seen.has(`${l.b}:${l.i}`))].sort((x, y) => x.b - y.b || x.i - y.i);
  const e = { from: have?.from ?? fromBlock, to: latest, logs };
  save(k, e);
  return e;
}

/** every log of a contract from `fromBlock`, fetched incrementally and shared by all screens */
export async function contractLogs(chainId: number, address: Address, fromBlock: number): Promise<Log[]> {
  const k = key(chainId, address);
  let p = inflight.get(k);
  if (!p) {
    p = refresh(chainId, address, fromBlock).finally(() => inflight.delete(k));
    inflight.set(k, p);
  }
  const e = await p;
  return e.logs
    .filter((l) => l.b >= fromBlock)
    .map((l) => ({ address, blockNumber: BigInt(l.b), logIndex: l.i, transactionHash: l.t, topics: l.topics, data: l.data, blockHash: null, transactionIndex: null, removed: false }) as unknown as Log);
}
