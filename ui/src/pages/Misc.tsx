import { useState } from "react";
import { Link } from "react-router-dom";
import { useQuery } from "@tanstack/react-query";
import { useAccount, useSwitchChain, useWriteContract } from "wagmi";
import type { Hex } from "viem";
import { chainById, client } from "../lib/chains";
import { useApp } from "../lib/app";
import { OUTCOME } from "../lib/grants";
import { amount, short } from "../lib/format";
import { explain } from "../lib/errors";
import { destinationReceiverAbi } from "../data/abi";
import evidence from "../data/evidence.json";
import { PageHead } from "../components/shell";
import { Chip, Empty, ErrorNote, ExtLink, Hash, Icon, Mark, Skel } from "../components/ui";

export function Queue() {
  const { chainId } = useApp();
  const ch = chainById(chainId)!;
  const rx = ch.deployment!.receiver;
  const q = useQuery({
    queryKey: ["queue", chainId],
    queryFn: async () => {
      const c = client(chainId);
      const n = Number(await c.readContract({ address: rx, abi: destinationReceiverAbi, functionName: "queueLength" }));
      const ids = await Promise.all(Array.from({ length: n }, (_, i) => c.readContract({ address: rx, abi: destinationReceiverAbi, functionName: "queuedAt", args: [BigInt(i)] }) as Promise<Hex>));
      return Promise.all(ids.map(async (id) => ({ id, p: (await c.readContract({ address: rx, abi: destinationReceiverAbi, functionName: "getPayout", args: [id] })) as any })));
    },
    refetchInterval: 30_000,
  });
  const { writeContractAsync, isPending } = useWriteContract();
  const { switchChainAsync } = useSwitchChain();
  const { chainId: wc } = useAccount();
  const [err, setErr] = useState<{ text: string; raw: string } | null>(null);
  async function act(fn: "retryPayout" | "retryAck", id: Hex) {
    setErr(null);
    try {
      if (wc !== chainId) await switchChainAsync({ chainId: chainId as any });
      await writeContractAsync({ address: rx, abi: destinationReceiverAbi, functionName: fn, args: [id], chainId: chainId as any });
      setTimeout(() => q.refetch(), 6000);
    } catch (e) { setErr(explain(e)); }
  }
  return (
    <>
      <PageHead title={<>Receiver queue on {ch.short}</>} sub="Payouts that could not be paid on arrival, and receipts that could not be sent, wait here. Anyone can retry them; nothing is lost." />
      {err && <ErrorNote {...err} />}
      <div className="card" style={{ padding: "8px 24px 0" }}>
        {q.isLoading && <div style={{ padding: 24 }}><Skel w={300} /></div>}
        {q.data && q.data.length === 0 && <Empty title="Nothing is waiting. Every payout landed and every receipt was sent." />}
        {q.data && q.data.length > 0 && (
          <table className="table">
            <thead><tr><th>Grant</th><th>Grantee</th><th>Amount</th><th>Payout</th><th>Receipt</th><th>Action</th></tr></thead>
            <tbody>
              {q.data.map(({ id, p }) => (
                <tr key={id}>
                  <td className="mono">{short(id)}</td>
                  <td><Hash value={p.recipient} /></td>
                  <td className="mono">{amount(BigInt(p.amount), ch.payout.decimals)} {ch.payout.symbol}</td>
                  <td>{Number(p.outcome) === 2 ? <Chip tone="warn">Held</Chip> : <Chip tone="ok">{OUTCOME[Number(p.outcome)]}</Chip>}</td>
                  <td>{p.ackPending ? <Chip tone="flight">Not sent</Chip> : <Chip tone="ok">Sent</Chip>}</td>
                  <td><div className="row" style={{ justifyContent: "flex-end" }}>
                    {Number(p.outcome) === 2 && <button className="btn btn--secondary" disabled={isPending} onClick={() => act("retryPayout", id)}><Icon name="arrow-clockwise" size="sm" />Retry payout</button>}
                    {p.ackPending && <button className="btn btn--secondary" disabled={isPending} onClick={() => act("retryAck", id)}>Send receipt</button>}
                  </div></td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </div>
      <p className="small muted" style={{ marginTop: 16 }}>Chainlink Automation can drain this queue through <span className="mono">checkUpkeep</span> and <span className="mono">performUpkeep</span>. No upkeep is registered on testnet yet.</p>
    </>
  );
}

export function Audit() {
  const ev = evidence as any;
  if (!ev) return <><PageHead title="Audit report" /><Empty title="No audit has been run yet. Run node offchain/src/audit.ts <grant> to make one." /></>;
  const rules: any[] = ev.output?.results ?? [];
  const jury: any[] = ev.output?.jury?.jurors ?? [];
  const passed = Boolean(ev.output?.pass);
  const pr = ev.inputs?.evidence ?? {};
  const value = ev.output?.valuation;
  const evidenceHash: string = ev.hashes?.evidenceHash;
  return (
    <>
      <PageHead title={<>Audit of {ev.grantLabel}</>} sub={<>{pr.title ?? `${ev.inputs?.repo}#${ev.inputs?.pr}`} · evidence <span className="mono">{short(evidenceHash, 10, 6)}</span></>} action={passed ? <Chip tone="ok">Passed</Chip> : <Chip tone="bad">Rejected</Chip>} />
      <div className="grid">
        <section className="card span-7">
          <div className="card__label"><Icon name="scales" size="sm" /><span className="label">Rubric, which decides</span></div>
          <table className="table"><tbody>
            {rules.map((r, i) => (
              <tr key={i}><td>{r.rule ?? r.name ?? r.id}</td><td className="small muted">{r.detail ?? r.note ?? ""}</td><td>{(r.pass ?? r.passed) ? <Chip tone="ok">Pass</Chip> : <Chip tone="bad">Fail</Chip>}</td></tr>
            ))}
            {rules.length === 0 && <tr><td className="muted">The bundle has no rubric rows.</td></tr>}
          </tbody></table>
        </section>
        <div className="span-5 stack">
          <section className="card">
            <div className="card__label"><Icon name="users-three" size="sm" /><span className="label">Model jury, which can only veto</span></div>
            <div className="stack small">
              {jury.length ? jury.map((j, i) => <div key={i} className="row row--between"><span>{j.provider}{j.model ? ` · ${j.model}` : ""}</span><span className="muted">{j.review?.verdict?.replaceAll("_", " ") ?? j.status ?? "reviewed"}</span></div>) : <span className="muted">No juror output in the bundle.</span>}
            </div>
          </section>
          <section className="card">
            <div className="card__label"><Icon name="git-pull-request" size="sm" /><span className="label">Evidence</span></div>
            <dl className="kv small">
              <dt>Pull request</dt><dd><ExtLink href={`https://github.com/${ev.inputs?.repo}/pull/${ev.inputs?.pr}`}>{ev.inputs?.repo}#{ev.inputs?.pr}</ExtLink></dd>
              {pr.mergeCommitSha && <><dt>Merge commit</dt><dd className="mono">{short(pr.mergeCommitSha, 8, 4)}</dd></>}
              {pr.files && <><dt>Files</dt><dd>{pr.files.length}</dd></>}
              {value && <><dt>Value</dt><dd>about ${Number(value.usd).toFixed(2)}, Uniswap Trading API</dd></>}
              <dt>Evidence hash</dt><dd><Hash value={evidenceHash} n={8} /></dd>
            </dl>
          </section>
          {passed ? <Link to={`/app/new?evidence=${evidenceHash}`} className="btn btn--primary">Use this evidence in a grant<Icon name="arrow-right" size="sm" /></Link> : <div className="note note--bad"><Icon name="x" /><p>The rubric failed, so no attestation was signed.</p></div>}
        </div>
      </div>
    </>
  );
}

export function NotFound() {
  return (
    <div className="empty" style={{ minHeight: "60svh", alignContent: "center" }}>
      <Mark size={56} />
      <h1 className="h2">This page does not exist.</h1>
      <Link to="/app" className="btn btn--secondary">Go to the overview</Link>
    </div>
  );
}
