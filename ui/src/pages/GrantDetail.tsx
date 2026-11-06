import { Link, useParams } from "react-router-dom";
import type { Hex } from "viem";
import { addrUrl, ccipUrl, chainByKey, txUrl } from "../lib/chains";
import { useGrant } from "../lib/grants";
import { amount, ago, short } from "../lib/format";
import evidence from "../data/evidence.json";
import { ErrorNote, ExtLink, Hash, Icon, Route, Skel, StatusChip } from "../components/ui";

type State = "done" | "live" | "held" | "todo";

function Step({ state, title, children, link }: { state: State; title: string; children?: React.ReactNode; link?: React.ReactNode }) {
  return (
    <li data-state={state}>
      <span className="dot" aria-hidden>{state === "done" ? <Icon name="check" size="sm" /> : state === "held" ? <Icon name="warning" size="sm" /> : null}</span>
      <div>
        <p className="t-title">{title}</p>
        {children && <div className="t-meta">{children}</div>}
      </div>
      <div className="small">{link}</div>
    </li>
  );
}

export default function GrantDetail() {
  const { chain: key, id } = useParams();
  const src = chainByKey(key);
  const { data, isLoading, error } = useGrant(src?.id ?? 0, id as Hex);

  if (!src) return <ErrorNote text="Unknown chain in this link." />;
  if (error) return <><Link to="/app/grants" className="link small">Back to grants</Link><div style={{ marginTop: 24 }}><ErrorNote text={(error as Error).message} /></div></>;
  if (isLoading || !data) return <div className="stack"><Skel w={220} /><Skel w={480} /><Skel w={360} /></div>;

  const { grant: g, payout } = data;
  const dest = g.dest;
  const paid = payout?.outcome === 1 || payout?.outcome === 3;
  const held = payout?.outcome === 2;
  const ev = evidence as any;

  const sent: State = "done";
  const delivered: State = payout && payout.outcome > 0 ? (held ? "held" : "done") : "live";
  const receipt: State = g.status === 3 ? "done" : payout?.ackTx ? "live" : paid ? "live" : "todo";

  return (
    <>
      <Link to="/app/grants" className="link small row" style={{ display: "inline-flex", gap: 6 }}><Icon name="arrow-left" size="sm" />Grants</Link>
      <div className="page-head" style={{ marginTop: 24 }}>
        <div>
          <h1 className="h2">{g.label ? <>Grant to {g.label}</> : "Grant"}</h1>
          <p className="muted" style={{ marginTop: 12 }}>
            <span className="mono">{short(g.id, 10, 6)}</span> · {amount(g.amount, src.payout.decimals)} {src.payout.symbol} to <span className="mono">{short(g.recipient)}</span>
          </p>
        </div>
        <StatusChip status={g.status} />
      </div>

      <div className="grid">
        <section className="card span-7" aria-label="Timeline">
          <div className="card__label"><span className="label">Timeline</span></div>
          <ol className="tl">
            <Step state="done" title="Authorised by two signers" link={data.swapTx && <ExtLink href={txUrl(src, data.swapTx)}>Swap tx</ExtLink>}>
              approver <span className="mono">{short(data.approver)}</span> · auditor <span className="mono">{short(data.auditor)}</span>
            </Step>
            <Step state="done" title={`Swapped on Uniswap v4 (${src.short})`} link={<ExtLink href={addrUrl(src, src.deployment!.hook)}>Hook</ExtLink>}>
              the hook captured {amount(g.amount, src.payout.decimals)} {src.payout.symbol} straight into the dispatcher
            </Step>
            <Step state={sent} title="Sent by Chainlink CCIP" link={<ExtLink href={ccipUrl(g.messageId)}>CCIP explorer</ExtLink>}>
              message <span className="mono">{short(g.messageId, 8, 4)}</span> · fee {amount(g.fee, 18, 6)} ETH · {ago(g.dispatchedAt)}
            </Step>
            <Step state={delivered} title={held ? `Payout held on ${dest?.short}` : `Paid on ${dest?.short ?? "the destination"}`} link={payout?.paidTx && dest && <ExtLink href={txUrl(dest, payout.paidTx)}>Payout tx</ExtLink>}>
              {payout && payout.outcome > 0
                ? held ? "the transfer reverted; the funds wait in the receiver and can be retried" : <>{amount(payout.amount, dest!.payout.decimals)} {dest!.payout.symbol} reached <span className="mono">{short(g.recipient)}</span></>
                : "waiting for CCIP to deliver (usually 10 to 25 minutes on testnets)"}
            </Step>
            <Step state={receipt} title="Receipt back to the source" link={data.ackTx ? <ExtLink href={txUrl(src, data.ackTx)}>Receipt tx</ExtLink> : payout?.ackMessageId ? <ExtLink href={ccipUrl(payout.ackMessageId)}>Receipt message</ExtLink> : null}>
              {g.status === 3 ? "the source ledger marked this grant settled" : payout?.ackTx ? "the receiver sent the receipt; CCIP is carrying it back" : "sent once the payout lands"}
            </Step>
          </ol>
        </section>

        <div className="span-5 stack">
          <section className="card" aria-label="Facts">
            <div className="card__label"><span className="label">Facts</span></div>
            <dl className="kv">
              <dt>Route</dt><dd><Route from={src} to={dest} /></dd>
              <dt>Amount</dt><dd className="mono">{amount(g.amount, src.payout.decimals)} {src.payout.symbol}</dd>
              <dt>Grantee</dt><dd><Hash value={g.recipient} href={dest ? addrUrl(dest, g.recipient) : undefined} /></dd>
              <dt>Grant id</dt><dd><Hash value={g.id} n={8} /></dd>
              <dt>Message</dt><dd><Hash value={g.messageId} href={ccipUrl(g.messageId)} /></dd>
              <dt>Executor</dt><dd><Hash value={data.executor} href={data.executor ? addrUrl(src, data.executor) : undefined} /></dd>
            </dl>
          </section>
          {ev && (
            <section className="card" aria-label="Evidence">
              <div className="card__label"><Icon name="git-pull-request" size="sm" /><span className="label">Latest audit evidence</span></div>
              <p className="small muted">The auditor's most recent run, {ev.grantLabel}. Its evidence hash binds the PR, its files and the rubric.</p>
              <div style={{ marginTop: 16 }}><Link to={`/app/audit/${ev.grantLabel}`} className="btn btn--secondary">Open the audit report<Icon name="arrow-right" size="sm" /></Link></div>
            </section>
          )}
        </div>
      </div>
    </>
  );
}
