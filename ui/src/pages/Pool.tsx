import { useQuery } from "@tanstack/react-query";
import { chainById, client, addrUrl } from "../lib/chains";
import { useApp } from "../lib/app";
import { nidhiHookAbi } from "../data/abi";
import { short } from "../lib/format";
import { PageHead } from "../components/shell";
import { ErrorNote, ExtLink, Hash, ProtocolLogo, Skel } from "../components/ui";

const stateViewAbi = [{ type: "function", name: "getSlot0", stateMutability: "view", inputs: [{ name: "poolId", type: "bytes32" }], outputs: [{ type: "uint160" }, { type: "int24" }, { type: "uint24" }, { type: "uint24" }] },
  { type: "function", name: "getLiquidity", stateMutability: "view", inputs: [{ name: "poolId", type: "bytes32" }], outputs: [{ type: "uint128" }] }] as const;
const nftAbi = [{ type: "function", name: "ownerOf", stateMutability: "view", inputs: [{ type: "uint256" }], outputs: [{ type: "address" }] }] as const;

export default function Pool() {
  const { chainId } = useApp();
  const ch = chainById(chainId)!;
  const d = ch.deployment!;
  const q = useQuery({
    queryKey: ["pool", chainId],
    queryFn: async () => {
      const c = client(chainId);
      const sv = ch.uniswap.stateView;
      const [slot, liq] = sv ? await Promise.all([
        c.readContract({ address: sv, abi: stateViewAbi, functionName: "getSlot0", args: [d.poolId] }),
        c.readContract({ address: sv, abi: stateViewAbi, functionName: "getLiquidity", args: [d.poolId] }),
      ]) : [null, null];
      const [owner, guardBps] = await Promise.all([
        c.readContract({ address: ch.uniswap.positionManager, abi: nftAbi, functionName: "ownerOf", args: [BigInt(d.positionId)] }),
        c.readContract({ address: d.hook, abi: nidhiHookAbi, functionName: "guardMaxDeviationBps" }) as Promise<number>,
      ]);
      let price: number | null = null;
      if (slot) {
        const sqrt = Number(slot[0]) / 2 ** 96;
        const p = sqrt * sqrt; // token1 per token0, both 18 decimals here
        price = ch.base.address.toLowerCase() < ch.payout.address.toLowerCase() ? p : 1 / p;
      }
      return { tick: slot ? Number(slot[1]) : null, liq, price, owner, guardBps: Number(guardBps) };
    },
    refetchInterval: 30_000,
  });
  const s = q.data;
  return (
    <>
      <PageHead title={<>{ch.base.symbol} / {ch.payout.symbol} pool</>} sub={<span className="route"><ProtocolLogo name="uniswap" /> Uniswap v4 · fee 0.30% · tick spacing 60 · hook <span className="mono">{short(d.hook)}</span></span>} />
      {q.error && <ErrorNote text="The pool could not be read from this chain." raw={String(q.error)} />}
      <div className="grid">
        <div className="card stat span-4">
          <span className="label">Price, from StateView</span>
          <span className="fig">{s ? (s.price !== null ? <>{s.price.toFixed(1)} <span className="small muted">{ch.payout.symbol} per {ch.base.symbol}</span></> : "No StateView here") : <Skel />}</span>
          <span className="small muted">{s?.tick !== null && s ? `tick ${s.tick}` : ""}</span>
        </div>
        <div className="card stat span-4">
          <span className="label">DAO position</span>
          <span className="fig">#{d.positionId}</span>
          <span className="small muted">single-sided {ch.payout.symbol}, held as a PositionManager NFT</span>
        </div>
        <div className="card stat span-4">
          <span className="label">Reference-price guard</span>
          <span className="fig">{s ? (s.guardBps ? `${s.guardBps / 100}%` : "Off") : <Skel w={60} />}</span>
          <span className="small muted">{s?.guardBps ? "band against the canonical deep pool" : "testnets have no deep pool; mainnet uses 3%"}</span>
        </div>
      </div>
      <div className="section-title"><h2 className="h3">Contracts</h2></div>
      <div className="card">
        <dl className="kv">
          <dt>Pool id</dt><dd><Hash value={d.poolId} n={10} /></dd>
          <dt>Position owner</dt><dd>{s ? <Hash value={s.owner} href={addrUrl(ch, s.owner)} /> : <Skel />}</dd>
          <dt>PoolManager</dt><dd><Hash value={ch.uniswap.poolManager} href={addrUrl(ch, ch.uniswap.poolManager)} /></dd>
          <dt>PositionManager</dt><dd><Hash value={ch.uniswap.positionManager} href={addrUrl(ch, ch.uniswap.positionManager)} /></dd>
          <dt>V4Quoter</dt><dd><Hash value={ch.uniswap.quoter} href={addrUrl(ch, ch.uniswap.quoter)} /></dd>
          <dt>In-range liquidity</dt><dd className="mono">{s?.liq !== null && s ? String(s.liq) : "—"}</dd>
        </dl>
        <div style={{ marginTop: 16 }}><ExtLink href={addrUrl(ch, d.hook)}>Hook on the explorer</ExtLink></div>
      </div>
    </>
  );
}
