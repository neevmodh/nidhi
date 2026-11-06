// Build-time ledger snapshot: every log of every contract the app reads, up to the current block.
// The app starts from it and fetches only the blocks after it, so a first visit does not replay all history.
// Best-effort by design: any failure writes what it has (or an empty snapshot) and the build continues; the app then
// falls back to live scans. It is a cache of public, append-only chain logs, so anyone can re-check it against a node.
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { createPublicClient, fallback, http } from "viem";

const ui = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const out = path.join(ui, "src", "data", "ledger-snapshot.json");
const deployments = JSON.parse(fs.readFileSync(path.join(ui, "src", "data", "deployments.json"), "utf8"));

const RPCS = {
  11155111: ["https://ethereum-sepolia-rpc.publicnode.com", "https://sepolia.gateway.tenderly.co"],
  84532: ["https://sepolia.base.org", "https://base-sepolia-rpc.publicnode.com", "https://base-sepolia.gateway.tenderly.co"],
  421614: ["https://sepolia-rollup.arbitrum.io/rpc", "https://arbitrum-sepolia-rpc.publicnode.com", "https://arbitrum-sepolia.gateway.tenderly.co"],
  1301: ["https://sepolia.unichain.org", "https://unichain-sepolia-rpc.publicnode.com"],
};
const STEP = { 421614: 40_000, 1301: 1_000 }; // Unichain's RPC caps getLogs at 1,000 blocks

// the same (chain, contract) set the app reads; each scanned from its chain's earliest deploy block
function targets() {
  const t = new Map();
  const add = (id, a) => { if (a && /^0x[0-9a-fA-F]{40}$/.test(a)) t.set(`${id}:${a.toLowerCase()}`, { id: Number(id), address: a }); };
  for (const [id, d] of Object.entries(deployments)) {
    for (const k of ["hook", "dispatcher", "receiver", "authority"]) add(id, d[k]);
    const e = d.ens?.stack;
    if (e) {
      for (const k of ["hook", "dispatcher", "authority"]) add(id, e[k]);
      for (const [rid, rx] of Object.entries(e.receivers ?? {})) add(rid, rx);
    }
    const h = d.hop;
    if (h) {
      for (const k of ["hook", "dispatcher", "authority"]) add(id, h.stack[k]);
      add(h.route.final, h.route.finalReceiver);
    }
  }
  return [...t.values()];
}

async function scan(client, id, address, from, to) {
  const step = STEP[id] ?? 9_000;
  const ranges = [];
  for (let s = from; s <= to; s += step + 1) ranges.push([s, Math.min(s + step, to)]);
  const logs = [];
  let next = 0;
  await Promise.all(Array.from({ length: Math.min(4, ranges.length) }, async () => {
    while (next < ranges.length) {
      const [a, b] = ranges[next++];
      const get = () => client.getLogs({ address, fromBlock: BigInt(a), toBlock: BigInt(b) });
      const got = await get().catch(() => new Promise((r) => setTimeout(r, 800)).then(get));
      logs.push(...got.map((l) => ({ b: Number(l.blockNumber), i: Number(l.logIndex), t: l.transactionHash, topics: l.topics, data: l.data })));
    }
  }));
  return logs.sort((x, y) => x.b - y.b || x.i - y.i);
}

async function main() {
  const entries = {};
  const byChain = new Map();
  for (const t of targets()) byChain.set(t.id, [...(byChain.get(t.id) ?? []), t]);
  await Promise.all([...byChain.entries()].map(async ([id, list]) => {
    const from = Number(deployments[String(id)]?.fromBlock ?? 0);
    const client = createPublicClient({ transport: fallback(RPCS[id].map((u) => http(u, { timeout: 20_000, retryCount: 2 }))) });
    try {
      const to = Number(await client.getBlockNumber()) - ({ 11155111: 3, 84532: 20, 421614: 80, 1301: 20 }[id] ?? 5); // behind the head: nodes disagree
      for (const t of list) {
        try {
          entries[`${id}:${t.address.toLowerCase()}`] = { from, to, logs: await scan(client, id, t.address, from, to) };
        } catch (e) { console.warn(`[snapshot] ${id} ${t.address}: ${e.shortMessage ?? e.message} (left for live scan)`); }
      }
    } catch (e) { console.warn(`[snapshot] chain ${id} unreachable: ${e.shortMessage ?? e.message} (left for live scan)`); }
  }));
  const n = Object.values(entries).reduce((a, e) => a + e.logs.length, 0);
  fs.writeFileSync(out, JSON.stringify({ generatedAt: new Date().toISOString(), entries }) + "\n");
  console.log(`[snapshot] ${Object.keys(entries).length} contracts, ${n} logs`);
}

main().catch((e) => {
  console.warn(`[snapshot] skipped: ${e.message}`);
  fs.writeFileSync(out, JSON.stringify({ generatedAt: null, entries: {} }) + "\n");
});
