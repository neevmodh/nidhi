import { useMemo, useState } from "react";
import { Link, useNavigate } from "react-router-dom";
import { deployedChains } from "../lib/chains";
import { useGrants, type Status } from "../lib/grants";
import { amount, ago, short } from "../lib/format";
import { PageHead } from "../components/shell";
import { Empty, ErrorNote, Icon, Route, Skel, StatusChip } from "../components/ui";

export default function Grants() {
  const [chain, setChain] = useState<number | "all">("all");
  const [status, setStatus] = useState<Status | "all">("all");
  const [q, setQ] = useState("");
  const { data, isLoading, error } = useGrants();
  const nav = useNavigate();

  const rows = useMemo(() => {
    const needle = q.trim().toLowerCase();
    return (data?.grants ?? []).filter((g) =>
      (chain === "all" || g.src.id === chain || g.dest?.id === chain) &&
      (status === "all" || g.status === status) &&
      (!needle || g.id.toLowerCase().includes(needle) || (g.label ?? "").toLowerCase().includes(needle) || g.recipient.toLowerCase().includes(needle)),
    );
  }, [data, chain, status, q]);

  return (
    <>
      <PageHead title="Grants" sub="Every grant sent from any Nidhi deployment, read from the chains." />

      <div className="row row--wrap" style={{ marginBottom: 24, gap: 12 }}>
        <select className="select" style={{ width: 220 }} value={chain} onChange={(e) => setChain(e.target.value === "all" ? "all" : Number(e.target.value))} aria-label="Chain">
          <option value="all">All chains</option>
          {deployedChains().map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}
        </select>
        <select className="select" style={{ width: 200 }} value={status} onChange={(e) => setStatus(e.target.value === "all" ? "all" : (Number(e.target.value) as Status))} aria-label="Status">
          <option value="all">All statuses</option>
          <option value={1}>In flight</option>
          <option value={2}>Held</option>
          <option value={3}>Settled</option>
        </select>
        <div style={{ position: "relative", flex: "1 1 240px", maxWidth: 360 }}>
          <span style={{ position: "absolute", left: 14, top: 14, color: "var(--muted)" }}><Icon name="magnifying-glass" size="sm" /></span>
          <input className="input" style={{ paddingLeft: 40 }} placeholder="Search by id, name or address" value={q} onChange={(e) => setQ(e.target.value)} aria-label="Search grants" />
        </div>
      </div>

      {error && <ErrorNote text="The grant ledger could not be read." raw={String(error)} />}
      {data?.failed.length ? <div className="note note--warn" style={{ marginBottom: 24 }}><Icon name="warning" /><p>Could not reach {data.failed.join(", ")}. Grants from there are missing until it answers.</p></div> : null}

      <div className="card" style={{ padding: "8px 24px 0" }}>
        {isLoading && <div style={{ padding: "24px 0" }}><Skel w={360} /></div>}
        {data && rows.length === 0 && <Empty title={data.grants.length ? "No grants match these filters." : "No grants yet."} action={!data.grants.length && <Link to="/app/new" className="btn btn--primary"><Icon name="plus" size="sm" />New grant</Link>} />}
        {rows.length > 0 && (
          <table className="table">
            <thead><tr><th>Grant</th><th>Grantee</th><th>Route</th><th>Amount</th><th>Status</th><th>Sent</th><th aria-label="Open" /></tr></thead>
            <tbody>
              {rows.map((g) => (
                <tr key={`${g.src.id}-${g.id}`} data-href onClick={() => nav(`/app/grants/${g.src.key}/${g.id}`)}>
                  <td className="mono">{short(g.id, 6, 4)}</td>
                  <td>{g.label ? <span>{g.label}</span> : <span className="mono">{short(g.recipient)}</span>}</td>
                  <td><Route from={g.src} to={g.dest} /></td>
                  <td className="mono">{amount(g.amount, g.src.payout.decimals)} {g.src.payout.symbol}</td>
                  <td><StatusChip status={g.status} /></td>
                  <td className="muted small">{ago(g.dispatchedAt)}</td>
                  <td><Icon name="caret-right" size="sm" /></td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </div>
    </>
  );
}
