import { Link, useNavigate } from "react-router-dom";
import { formatEther } from "viem";
import { chainById } from "../lib/chains";
import { useApp } from "../lib/app";
import { useChainState, useGrants } from "../lib/grants";
import { amount, ago, short } from "../lib/format";
import { PageHead } from "../components/shell";
import { Chip, Empty, ErrorNote, Icon, Route, Skel, StatusChip, Steps } from "../components/ui";

export default function Overview() {
  const { chainId } = useApp();
  const ch = chainById(chainId)!;
  const st = useChainState(chainId);
  const gr = useGrants(chainId);
  const nav = useNavigate();
  const s = st.data;
  const grants = gr.data?.grants ?? [];
  const held = grants.filter((g) => g.status === 2).length;
  const routes = s?.routes.filter((r) => r.wired).length ?? 0;

  return (
    <>
      <PageHead title={<>Treasury on {ch.short}</>} sub={<>Hook <span className="mono">{short(ch.deployment?.hook)}</span> on Uniswap v4, settled by Chainlink CCIP.</>} />

      {st.error && <ErrorNote text="This chain's RPC did not answer. The numbers below may be missing." raw={String(st.error)} />}

      <div className="grid">
        <div className="card stat span-3">
          <span className="label">Cap left today</span>
          <span className="fig fade-in">{s ? <>{amount(s.remaining, 18)} <span className="small muted">{ch.base.symbol}</span></> : <Skel />}</span>
          <span className="small muted">{s ? `of ${amount(s.cap, 18)} ${ch.base.symbol} a day` : <Skel w={120} />}</span>
        </div>
        <div className="card stat span-3">
          <span className="label">CCIP fee reserve</span>
          <span className="fig fade-in">{s ? <>{Number(formatEther(s.feeReserve)).toFixed(4)} <span className="small muted">ETH</span></> : <Skel />}</span>
          <span className="small muted">on the dispatcher, paid per grant</span>
        </div>
        <div className="card stat span-3">
          <span className="label">Routes wired</span>
          <span className="fig fade-in">{s ? routes : <Skel w={40} />}</span>
          <span className="small muted">{s ? s.routes.filter((r) => r.wired).map((r) => r.to.short).join(", ") || "none yet" : <Skel w={140} />}</span>
        </div>
        <div className="card stat span-3">
          <span className="label">Grants sent from here</span>
          <span className="fig fade-in">{gr.data ? grants.length : <Skel w={40} />}</span>
          <span className="small muted">{gr.data ? (held ? `${held} held` : "none held") : <Skel w={80} />}</span>
        </div>
      </div>

      <div className="section-title">
        <h2 className="h3">Recent grants</h2>
        <Link to="/app/grants" className="link small">See all grants</Link>
      </div>
      <div className="card" style={{ padding: "0 24px" }}>
        {gr.isLoading && <div style={{ padding: "24px 0" }}><Skel w={320} /></div>}
        {gr.data && grants.length === 0 && <Empty title={`No grants sent from ${ch.short} yet.`} action={<Link to="/app/new" className="btn btn--primary"><Icon name="plus" size="sm" />New grant</Link>} />}
        {grants.length > 0 && (
          <table className="table">
            <tbody>
              {grants.slice(0, 5).map((g) => (
                <tr key={g.id} data-href onClick={() => nav(`/app/grants/${g.src.key}/${g.id}`)}>
                  <td><span className="mono">{short(g.id, 6, 4)}</span></td>
                  <td>{g.label ?? short(g.recipient)}</td>
                  <td><Route from={g.src} to={g.dest} /></td>
                  <td className="mono">{amount(g.amount, ch.payout.decimals)} {ch.payout.symbol}</td>
                  <td><Steps status={g.status} /></td>
                  <td><StatusChip status={g.status} /></td>
                  <td className="muted small">{ago(g.dispatchedAt)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </div>

      <div className="section-title"><h2 className="h3">Health</h2></div>
      <div className="row row--wrap" style={{ gap: 12 }}>
        {s ? (
          <>
            {s.paused ? <Chip tone="warn">Hook paused</Chip> : <Chip tone="ok">Hook running</Chip>}
            {s.cursed === null ? <Chip tone="idle">RMN status unknown</Chip> : s.cursed ? <Chip tone="bad">CCIP RMN cursed</Chip> : <Chip tone="ok">CCIP RMN not cursed</Chip>}
            {s.queue > 0n ? <Chip tone="warn">{String(s.queue)} in the receiver queue</Chip> : <Chip tone="ok">Receiver queue empty</Chip>}
            {s.dispPending !== "0x0000000000000000000000000000000000000000" ? <Chip tone="flight">Ownership handover pending</Chip> : <Chip tone="ok">Owned by the DAO admin</Chip>}
          </>
        ) : <Skel w={420} />}
      </div>
    </>
  );
}
