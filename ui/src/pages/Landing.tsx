import { Link, useNavigate } from "react-router-dom";
import { CHAINS, ccipUrl, txUrl } from "../lib/chains";
import { useGrants, type Grant } from "../lib/grants";
import { amount, ago, short } from "../lib/format";
import mainnets from "../data/mainnets.json";
import { Footer, GradeToggle } from "../components/shell";
import { Icon, Logo, ProtocolLogo, Route, Skel, StatusChip } from "../components/ui";

const SOURCE_MAINNETS = (mainnets as any).sourceChains.length as number;

/** the product's own UI, live: the newest grant's progress */
function AppFrame({ g }: { g?: Grant }) {
  const steps = [
    ["Signed", true],
    ["Swapped on Uniswap v4", true],
    ["Sent by CCIP", !!g],
    ["Paid", !!g && g.status >= 2],
    ["Receipt back", !!g && g.status === 3],
  ] as const;
  return (
    <div className="appframe" aria-label="Live grant from the testnet deployment">
      <div className="appframe__bar"><span /><span /><span /><p className="small muted">nidhi / grants / {g ? short(g.id, 6, 4) : "…"}</p></div>
      <div className="appframe__body">
        <div className="row row--between">
          <span className="label">Latest grant</span>
          {g ? <StatusChip status={g.status} /> : <Skel w={80} />}
        </div>
        <p className="h3" style={{ marginTop: 12 }}>{g ? <>{amount(g.amount, g.src.payout.decimals)} {g.src.payout.symbol} to {g.label ?? short(g.recipient)}</> : <Skel w={240} />}</p>
        <div style={{ marginTop: 8 }}>{g ? <Route from={g.src} to={g.dest} /> : <Skel w={200} />}</div>
        <ol className="tl" style={{ marginTop: 28 }}>
          {steps.map(([t, on], i) => {
            const live = !on && (i === 0 || steps[i - 1][1]);
            return (
              <li key={t} data-state={on ? "done" : live ? "live" : "todo"} style={{ paddingBottom: i === steps.length - 1 ? 0 : 18 }}>
                <span className="dot">{on && <Icon name="check" size="sm" />}</span>
                <p className="t-title small">{t}</p>
                <span />
              </li>
            );
          })}
        </ol>
        {g && <p className="small muted" style={{ marginTop: 20 }}>Sent {ago(g.dispatchedAt)} · read live from {g.src.short}</p>}
      </div>
    </div>
  );
}

function Diagram({ kind }: { kind: "swap" | "name" | "lane" }) {
  const stroke = "var(--accent)";
  if (kind === "swap") return (
    <svg viewBox="0 0 240 72" className="diagram" aria-hidden>
      <rect x="2" y="22" width="64" height="28" rx="14" fill="none" stroke="var(--line-strong)" /><text x="34" y="40" textAnchor="middle" className="dg-t">pool</text>
      <path d="M66 36H104" stroke={stroke} className="dg-flow" /><rect x="104" y="18" width="40" height="36" rx="10" fill="var(--accent-soft)" stroke={stroke} /><text x="124" y="40" textAnchor="middle" className="dg-t">hook</text>
      <path d="M144 36H180" stroke={stroke} className="dg-flow" /><rect x="180" y="22" width="58" height="28" rx="14" fill="none" stroke="var(--line-strong)" /><text x="209" y="40" textAnchor="middle" className="dg-t">vault</text>
    </svg>
  );
  if (kind === "name") return (
    <svg viewBox="0 0 240 72" className="diagram" aria-hidden>
      <rect x="2" y="22" width="96" height="28" rx="14" fill="none" stroke="var(--line-strong)" /><text x="50" y="40" textAnchor="middle" className="dg-t">alice.dao.eth</text>
      <path d="M98 36H140" stroke={stroke} className="dg-flow" /><rect x="140" y="22" width="98" height="28" rx="14" fill="var(--accent-soft)" stroke={stroke} /><text x="189" y="40" textAnchor="middle" className="dg-t">0x9f75…b9C7</text>
    </svg>
  );
  return (
    <svg viewBox="0 0 240 72" className="diagram" aria-hidden>
      <rect x="2" y="22" width="70" height="28" rx="14" fill="none" stroke="var(--line-strong)" /><text x="37" y="40" textAnchor="middle" className="dg-t">Base</text>
      <path d="M72 30H168" stroke={stroke} className="dg-flow" /><path d="M168 42H72" stroke="var(--line-strong)" strokeDasharray="3 4" />
      <rect x="168" y="22" width="70" height="28" rx="14" fill="none" stroke="var(--line-strong)" /><text x="203" y="40" textAnchor="middle" className="dg-t">Arbitrum</text>
    </svg>
  );
}

export default function Landing() {
  const { data } = useGrants();
  const grants = data?.grants ?? [];
  const settled = grants.filter((g) => g.status === 3).length;
  const nav = useNavigate();
  const live = CHAINS.filter((c) => c.deployment);

  return (
    <div className="landing">
      <header className="bar">
        <div className="wrap bar__in">
          <a className="skip" href="#main">Skip to content</a>
          <Link to="/" className="bar__logo" aria-label="nidhi home"><Logo height={26} /></Link>
          <nav className="bar__nav" aria-label="Sections">
            <a href="#how">How it works</a><a href="#proof">Proof</a><a href="#chains">Chains</a><a href="#security">Security</a>
          </nav>
          <div className="bar__end"><GradeToggle /><Link to="/app" className="btn btn--primary">Open the app<Icon name="arrow-right" size="sm" /></Link></div>
        </div>
      </header>

      <main id="main">
        <section className="screen hero">
          <div className="wrap hero__in">
            <div className="hero__words">
              <h1 className="h1">Cross-chain grants for DAOs, paid only after two signatures</h1>
              <p className="lead" style={{ marginTop: 24 }}>A Uniswap v4 hook swaps the treasury into the grantee's token. Chainlink CCIP pays them on their own chain and sends a receipt back.</p>
              <div className="btn-row" style={{ marginTop: 40 }}>
                <Link to="/app" className="btn btn--primary">Open the app<Icon name="arrow-right" size="sm" /></Link>
                <a href="https://github.com/neevmodh/nidhi" target="_blank" rel="noreferrer" className="btn btn--secondary">Read the contracts</a>
              </div>
              <p className="small muted" style={{ marginTop: 32 }}>{live.length} testnets live · {data ? `${settled} grants settled end to end` : "reading the chains…"}</p>
            </div>
            <AppFrame g={grants[0]} />
          </div>
        </section>

        <section className="screen" id="how">
          <div className="wrap">
            <h2 className="h2">Three protocols, one grant</h2>
            <p className="lead muted" style={{ marginTop: 16 }}>Each layer does one job, and each can stop the grant.</p>
            <div className="grid" style={{ marginTop: 48 }}>
              {[
                { logo: "ens", t: "Checks who may sign", b: "Approver, auditor and guardian roles, and each grantee's address per chain, from ENS on Sepolia or a DAO role registry.", d: "name" as const },
                { logo: "uniswap", t: "Swaps inside a guarded hook", b: "The hook checks both signatures, the daily cap and the price band, then keeps the output away from the caller.", d: "swap" as const },
                { logo: "chainlink", t: "Pays on the other chain", b: "CCIP carries the exact amount to the grantee and returns a receipt that marks the grant settled.", d: "lane" as const },
              ].map((c) => (
                <article className="card span-4 card--link how" key={c.t}>
                  <div className="card__label"><ProtocolLogo name={c.logo} size="lg" /></div>
                  <h3 className="h3">{c.t}</h3>
                  <p className="muted" style={{ marginTop: 8 }}>{c.b}</p>
                  <div className="panel" style={{ marginTop: 24 }}><Diagram kind={c.d} /></div>
                </article>
              ))}
            </div>
          </div>
        </section>

        <section className="screen" id="proof">
          <div className="wrap">
            <h2 className="h2">Grants sent on testnet <span className="muted">Every row is read from the chain.</span></h2>
            <div className="card" style={{ marginTop: 48, padding: "8px 24px 0" }}>
              {!data && <div style={{ padding: 24 }}><Skel w={320} /></div>}
              {data && grants.length === 0 && <p className="muted" style={{ padding: 24 }}>No grants yet.</p>}
              {grants.length > 0 && (
                <table className="table">
                  <thead><tr><th>Grant</th><th>Route</th><th>Amount</th><th>Status</th><th>Proof</th></tr></thead>
                  <tbody>
                    {grants.slice(0, 6).map((g) => (
                      <tr key={g.id} data-href onClick={() => nav(`/app/grants/${g.src.key}/${g.id}`)}>
                        <td className="mono">{short(g.id, 6, 4)}</td>
                        <td><Route from={g.src} to={g.dest} /></td>
                        <td className="mono">{amount(g.amount, g.src.payout.decimals)} {g.src.payout.symbol}</td>
                        <td><StatusChip status={g.status} /></td>
                        <td onClick={(e) => e.stopPropagation()}><span className="row" style={{ justifyContent: "flex-end" }}>
                          <a className="link small" href={txUrl(g.src, g.dispatchTx)} target="_blank" rel="noreferrer">Swap</a>
                          <a className="link small" href={ccipUrl(g.messageId)} target="_blank" rel="noreferrer">CCIP</a>
                        </span></td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              )}
            </div>
          </div>
        </section>

        <section className="screen" id="chains">
          <div className="wrap">
            <h2 className="h2">Live on {live.length} testnets, ready for {SOURCE_MAINNETS} mainnets</h2>
            <p className="lead muted" style={{ marginTop: 16 }}>Every mainnet below was rehearsed on a fork against the real Uniswap v4 and CCIP contracts.</p>
            <div className="grid" style={{ marginTop: 48 }}>
              {live.map((c) => (
                <Link to="/app/network" className="card span-3 card--link" key={c.id}>
                  <div className="card__label"><ProtocolLogo name={c.logo} size="lg" /></div>
                  <p className="h3">{c.short}</p>
                  <p className="small muted" style={{ marginTop: 8 }}>{c.lanes.length} CCIP lanes · hook <span className="mono">{short(c.deployment!.hook, 6, 4)}</span></p>
                </Link>
              ))}
            </div>
            <div className="row row--wrap" style={{ marginTop: 32, gap: 16 }}>
              {["ethereum", "base", "arbitrum", "polygon", "avalanche", "monad", "unichain", "optimism", "ink"].map((k) => <ProtocolLogo key={k} name={k} size="lg" title={k} />)}
            </div>
          </div>
        </section>

        <section className="screen" id="security">
          <div className="wrap">
            <h2 className="h2">Six checks before money moves</h2>
            <div className="grid" style={{ marginTop: 48 }}>
              {[
                ["signature", "Two different signers", "An approver signs the mandate, a separate auditor signs the evidence."],
                ["coins", "A daily cap", "The hook refuses any grant above what is left for the day."],
                ["pause", "A guardian pause", "One wallet can stop every new grant at once."],
                ["lock-simple", "Routes that only grow", "A destination can be added, never redirected."],
                ["shield-check", "A receiver that never reverts", "A failed payout is held and retried, never lost in transit."],
                ["scales", "A price band", "On mainnet the swap must match the deep Uniswap pool within 3%."],
              ].map(([ic, t, b]) => (
                <div className="card span-4" key={t}>
                  <span style={{ color: "var(--accent)" }}><Icon name={ic} size="lg" /></span>
                  <h3 className="h3" style={{ marginTop: 16 }}>{t}</h3>
                  <p className="muted" style={{ marginTop: 8 }}>{b}</p>
                </div>
              ))}
            </div>
          </div>
        </section>

        <section className="screen close">
          <div className="wrap close__in">
            <h2 className="h1">Pay your first grant</h2>
            <p className="lead muted">Name a grantee, sign twice and send. The receipt comes back on its own.</p>
            <Link to="/app/new" className="btn btn--primary">Start a grant<Icon name="arrow-right" size="sm" /></Link>
          </div>
        </section>
      </main>
      <Footer />
    </div>
  );
}
