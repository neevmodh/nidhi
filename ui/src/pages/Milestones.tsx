import { useState } from "react";
import { Link } from "react-router-dom";
import { useQuery } from "@tanstack/react-query";
import { parseAbiItem, parseEventLogs, type Address, type Hex } from "viem";
import { addrUrl, chainById, client, stackOf, stacksOf, txUrl } from "../lib/chains";
import { contractLogs } from "../lib/logcache";
import { amount, ago, short } from "../lib/format";
import data from "../data/milestones.json";
import prsSnapshot from "../data/prs.json";
import { nidhiBountyBoardAbi } from "../data/abi";
import { chainBySelector } from "../lib/chains";
import NewMilestone from "./NewMilestone";
import { PageHead } from "../components/shell";
import { ChainName, Chip, Empty, ExtLink, Icon, Skel } from "../components/ui";

// Milestone grants: the DAO commits a spec and pre-signs its payout; a developer ships a PR tagged "[<id>]";
// the agent verifies the merged work and pays. Every status below is read live: the PR from GitHub, the
// verification and payout from the chain. Only the DAO's committed specs come from the repo.

const authorized = parseAbiItem("event GrantAuthorized(bytes32 indexed grantId, address indexed approver, address indexed auditor, address executor)");
const statusAbi = [{ type: "function", name: "statusOf", stateMutability: "view", inputs: [{ type: "bytes32" }], outputs: [{ type: "uint8" }] }] as const;

interface PrInfo { number: number; title: string; url: string; state: "open" | "merged" | "closed"; author: string; approvals: number; checks: { total: number; failed: number; pending: number } }

// GitHub status. The build bakes a snapshot (scripts/prs.mjs, with CI's token), so the page shows PR state with no
// GitHub request at all. The browser then refreshes it gently: one shared PR list for every card, ETag-cached replies
// (a 304 does not count against GitHub's 60-per-hour unauthenticated limit), and no refresh once a PR is merged.
// If GitHub refuses, the card keeps the last known status instead of going blank.
const SNAP = prsSnapshot as { fetchedAt: string | null; prs: Record<string, PrInfo> };
const GH = "https://api.github.com";
class GhLimit extends Error {}
const gh = async (p: string) => {
  const key = `nidhi.gh:${p}`;
  let cached: { etag: string; body: unknown } | null = null;
  try { cached = JSON.parse(localStorage.getItem(key) ?? "null"); } catch { cached = null; }
  const r = await fetch(`${GH}${p}`, { headers: { Accept: "application/vnd.github+json", ...(cached?.etag ? { "If-None-Match": cached.etag } : {}) } });
  if (r.status === 304 && cached) return cached.body as any;
  if (!r.ok) {
    if (cached) return cached.body as any; // stale but real beats blank
    throw r.status === 403 || r.status === 429 ? new GhLimit("GitHub's hourly limit for this network is used up") : new Error(`GitHub ${r.status}`);
  }
  const body = await r.json();
  try { const etag = r.headers.get("ETag"); if (etag) localStorage.setItem(key, JSON.stringify({ etag, body })); } catch { /* storage full or blocked */ }
  return body;
};

/** one PR list per repo, shared by every milestone card */
function usePrList(repo: string) {
  return useQuery({
    queryKey: ["pr-list", repo],
    staleTime: 5 * 60_000,
    refetchInterval: 5 * 60_000,
    retry: false,
    queryFn: async (): Promise<any[]> => gh(`/repos/${repo}/pulls?state=all&sort=updated&direction=desc&per_page=50`),
  });
}

/** the newest PR (open or merged) tagged with the milestone id, with its reviews and CI */
function usePr(repo: string, id: string) {
  const snap = SNAP.prs[`${repo}#${id.toLowerCase()}`];
  const list = usePrList(repo);
  const p = list.data?.find((x) => String(x.title).toLowerCase().includes(`[${id.toLowerCase()}]`));
  const final = (snap?.state === "merged" && snap.checks.pending === 0) || (p?.merged_at && snap?.number === p.number && snap.checks.pending === 0);
  const detail = useQuery({
    queryKey: ["pr", repo, p?.number, p?.head?.sha],
    enabled: !!p && !final,
    staleTime: 5 * 60_000,
    refetchInterval: p?.merged_at ? false : 5 * 60_000,
    retry: false,
    queryFn: async (): Promise<PrInfo> => {
      const [reviews, checks] = await Promise.all([
        gh(`/repos/${repo}/pulls/${p.number}/reviews?per_page=100`),
        gh(`/repos/${repo}/commits/${p.head.sha}/check-runs?per_page=100`),
      ]);
      const runs: any[] = (checks.check_runs ?? []).filter((c: any) => c.name !== "agent"); // the agent's own run is not CI
      return {
        number: p.number, title: p.title, url: p.html_url, author: p.user?.login,
        state: p.merged_at ? "merged" : p.state === "open" ? "open" : "closed",
        approvals: (reviews as any[]).filter((r) => r.state === "APPROVED").length,
        checks: {
          total: runs.length,
          failed: runs.filter((c) => c.conclusion && !["success", "neutral", "skipped"].includes(c.conclusion)).length,
          pending: runs.filter((c) => !c.conclusion).length,
        },
      };
    },
  });
  // what to show: live detail; else the snapshot when it is about the same PR; else "no PR yet" when the live list
  // says so; else (list still loading, or GitHub refused) the snapshot as-is. undefined means "still loading".
  let data: PrInfo | null | undefined;
  if (detail.data) data = detail.data;
  else if (p) data = snap && snap.number === p.number ? snap : undefined;
  else if (list.data) data = null;
  else if (SNAP.fetchedAt) data = snap ?? null;
  else data = undefined;
  const limited = list.error instanceof GhLimit || detail.error instanceof GhLimit;
  return {
    data,
    isLoading: data === undefined && (list.isLoading || detail.isLoading),
    error: data === undefined ? (list.error ?? detail.error) : null,
    staleNote: limited && data ? `GitHub's hourly limit is used up on this network; showing the status from ${SNAP.fetchedAt ? ago(Date.parse(SNAP.fetchedAt) / 1000) : "the last build"}` : null,
  };
}

/** did the agent verify (hook GrantAuthorized) and how far did the payout get (dispatcher status) */
function useOnChain(grantId: Hex | null) {
  const src = chainById((data as any).source?.chainId ?? 11155111)!;
  // every ENS-gated stack, newest first: a milestone may have been paid by an earlier one
  const stacks = stacksOf(src).filter((s) => s.kind === ((data as any).source?.stack ?? "ens"));
  return useQuery({
    queryKey: ["milestone-chain", grantId],
    enabled: !!grantId && stacks.length > 0,
    refetchInterval: 30_000,
    queryFn: async () => {
      for (const stack of stacks) {
        const [logs, status] = await Promise.all([
          contractLogs(src.id, stack.hook, stack.fromBlock),
          client(src.id).readContract({ address: stack.dispatcher, abi: statusAbi, functionName: "statusOf", args: [grantId!] }),
        ]);
        const auth = (parseEventLogs({ abi: [authorized], logs, args: { grantId: grantId! } as any, strict: false }) as any[])[0];
        if (auth || Number(status) > 0) return { auditor: auth?.args?.auditor as Address | undefined, tx: auth?.transactionHash as Hex | undefined, status: Number(status), src };
      }
      return { auditor: undefined, tx: undefined, status: 0, src };
    },
  });
}

type StepState = "done" | "live" | "todo" | "bad";
function Step({ state, title, children }: { state: StepState; title: string; children?: React.ReactNode }) {
  return (
    <li data-state={state === "bad" ? "held" : state}>
      <span className="dot" aria-hidden>{state === "done" ? <Icon name="check" size="sm" /> : state === "bad" ? <Icon name="x" size="sm" /> : null}</span>
      <div><p className="t-title">{title}</p>{children && <div className="t-meta">{children}</div>}</div>
      <span />
    </li>
  );
}

function MilestoneCard({ id, m }: { id: string; m: any }) {
  const pr = usePr(m.repo, id);
  const chain = useOnChain(m.grantId);
  const dest = chainById(m.payTo);
  const p = pr.data;
  const c = chain.data;
  const needApprovals = m.rules?.minApprovals ?? 1;

  const merged = p?.state === "merged";
  const checksOk = p ? p.checks.failed === 0 : false;
  const reviewsOk = p ? p.approvals >= needApprovals : false;
  const verified = !!c?.auditor;
  const paid = (c?.status ?? 0) >= 1;
  const settled = c?.status === 3;

  const overall = settled ? <Chip tone="ok">Paid and settled</Chip>
    : paid ? <Chip tone="flight">Paid, settling</Chip>
    : merged && (!checksOk || !reviewsOk) ? <Chip tone="bad">Needs work</Chip>
    : merged ? <Chip tone="flight">Agent verifying</Chip>
    : p?.state === "open" ? <Chip tone="flight">PR open</Chip>
    : !m.committed ? <Chip tone="idle">Not committed</Chip>
    : <Chip tone="idle">Open for work</Chip>;

  return (
    <article className="card span-6 stack" aria-label={`Milestone ${id}`}>
      <div className="row row--between">
        <span className="label mono">[{id}]</span>
        {overall}
      </div>
      <h2 className="h3" style={{ fontSize: "var(--t-h3)" }}>{m.title}</h2>
      <p className="muted small">{m.rfpText.replace(/^#.*\n+/, "").trim().split("\n").join(" ")}</p>
      <dl className="kv small">
        <dt>Pays</dt><dd>{m.open ? <>the first merged PR's author, as <span className="mono">&lt;github&gt;.nidhi-dao.eth</span>, on </> : <>{m.grantee}.nidhi-dao.eth on </>}<ChainName chain={dest} /></dd>
        <dt>Amount</dt><dd className="mono">{amount(BigInt(m.amountInWei))} WETH, swapped to CCIP-BnM</dd>
        <dt>Rules</dt><dd>merged · {needApprovals} approval{needApprovals === 1 ? "" : "s"} · CI green · touches {(m.requiredPathGlobs ?? []).join(", ")}</dd>
        <dt>Repo</dt><dd><ExtLink href={`https://github.com/${m.repo}`}>{m.repo}</ExtLink></dd>
        {m.onchain && <><dt>Posted by</dt><dd className="mono">{short(m.approver)} · on-chain</dd></>}
      </dl>

      <ol className="tl" style={{ marginTop: 8 }}>
        <Step state={m.committed ? "done" : "todo"} title="DAO committed the milestone">
          {m.committed ? <>spec <span className="mono">{short(m.specHash, 8, 4)}</span> signed by approver <span className="mono">{short(m.approver)}</span>{m.committedAt ? ` · ${ago(Date.parse(m.committedAt) / 1000)}` : ""}</> : "the approver has not pre-signed this milestone yet"}
        </Step>
        <Step state={!p ? "todo" : merged ? (checksOk && reviewsOk ? "done" : "bad") : "live"} title={p ? `PR #${p.number} ${p.state}` : `Waiting for a PR tagged [${id}]`}>
          {pr.isLoading ? <Skel w={200} /> : pr.error ? String((pr.error as Error).message) : p ? (
            <>
              <a className="link" href={p.url} target="_blank" rel="noreferrer">{p.title}</a> by {p.author} · {p.approvals} approval{p.approvals === 1 ? "" : "s"} · CI {p.checks.total === 0 ? "none yet" : p.checks.failed ? `${p.checks.failed} failed` : p.checks.pending ? `${p.checks.pending} running` : "green"}
              {pr.staleNote && <span className="hint" style={{ display: "block", marginTop: 4 }}>{pr.staleNote}</span>}
            </>
          ) : m.open ? <>open a pull request titled <span className="mono">[{id}] …</span> and add <span className="mono">nidhi-wallet: 0x…</span> to its description</> : `open a pull request whose title contains [${id}]`}
        </Step>
        <Step state={verified ? "done" : merged && checksOk && reviewsOk ? "live" : "todo"} title="Agent verified the work">
          {verified ? <>attested by <span className="mono">{short(c!.auditor)}</span> (ENS auditor role) · <a className="link" href={txUrl(c!.src, c!.tx!)} target="_blank" rel="noreferrer">tx</a></> : merged ? "the agent checks merged PRs within minutes" : "runs when the PR is merged"}
        </Step>
        <Step state={settled ? "done" : paid ? "live" : "todo"} title={settled ? "Paid and settled" : paid ? "Paid, CCIP is delivering" : "Payout"}>
          {paid && m.grantId ? <Link className="link" to={`/app/grants/${c!.src.key}/${m.grantId}`}>Open the grant timeline</Link> : "the agent swaps through the hook and CCIP pays the grantee"}
        </Step>
      </ol>
    </article>
  );
}

/** milestones posted on-chain from the app (NidhiBountyBoard events), read live */
function useBoardMilestones() {
  const board = (data as any).board;
  return useQuery({
    queryKey: ["board-milestones", board?.board],
    enabled: !!board,
    refetchInterval: 30_000,
    queryFn: async () => {
      const logs = await contractLogs(11155111, board.board, board.deployBlock);
      const ev = parseEventLogs({ abi: nidhiBountyBoardAbi as any, logs, strict: false }) as any[];
      const cancelled = new Set(ev.filter((l) => l.eventName === "BountyCancelled").map((l) => String(l.args.id)));
      return ev.filter((l) => l.eventName === "BountyPosted" && !cancelled.has(String(l.args.id))).map((l) => {
        const b = l.args.bounty, sp = l.args.spec;
        let rules: any = {};
        try { rules = JSON.parse(sp.rules || "{}"); } catch { rules = {}; }
        return [`b${l.args.id}`, {
          title: sp.title, repo: sp.repo, rfpText: sp.body, grantee: sp.grantee, open: !sp.grantee, onchain: true,
          payTo: chainBySelector(BigInt(b.destChainSelector))?.id, amountInWei: String(b.amountIn),
          requiredPathGlobs: rules.requiredPathGlobs ?? [], rules: { minApprovals: rules.minApprovals ?? 1 },
          committed: true, specHash: l.args.specHash, grantId: l.args.grantId, approver: l.args.poster, committedAt: null,
        }] as [string, any];
      }).reverse();
    },
  });
}

export default function Milestones() {
  const [adding, setAdding] = useState(false);
  const board = useBoardMilestones();
  const ms = [...(board.data ?? []), ...Object.entries((data as any).milestones ?? {})];
  const src = chainById((data as any).source?.chainId ?? 11155111);
  return (
    <>
      <PageHead
        title="Milestones"
        sub={<>The DAO commits each milestone and pre-signs its payout. A developer opens a PR tagged with the milestone id. When it is merged, the agent checks the work and pays the grantee on their chain, with no one in between.</>}
        action={
          <div className="btn-row">
            <a className="btn btn--secondary" href="https://github.com/neevmodh/nidhi/actions/workflows/agent.yml" target="_blank" rel="noreferrer"><Icon name="lightning" size="sm" />Agent runs</a>
            {(data as any).board && <button className="btn btn--primary" onClick={() => setAdding(!adding)}><Icon name={adding ? "x" : "plus"} size="sm" />{adding ? "Close" : "New milestone"}</button>}
          </div>
        }
      />
      {adding && <div className="grid" style={{ marginBottom: 24 }}><NewMilestone onDone={() => { setAdding(false); board.refetch(); }} /></div>}
      {ms.length === 0 ? <Empty title="No milestones yet." /> : <div className="grid">{ms.map(([id, m]) => <MilestoneCard key={id} id={id} m={m} />)}</div>}
      {board.isLoading && <p className="small muted" style={{ marginTop: 12 }}>Reading on-chain milestones…</p>}
      <div className="card" style={{ marginTop: 24 }}>
        <span className="label">How the agent decides</span>
        <p className="small muted" style={{ marginTop: 8 }}>
          A fixed rubric decides: the PR is merged, has the required approvals, its CI checks passed and it touches the files the milestone names.
          AI models review the diff against the milestone text and can only veto. If it passes, the agent signs an attestation with its ENS auditor role,
          publishes it to <span className="mono">auditor.nidhi-dao.eth</span>, and sends the payout from {src?.short} through the ENS-gated Uniswap v4 hook.
          The hook still checks the approver's signature, the roles, the daily cap and the price band, so the agent cannot pay anything the DAO did not commit to.
        </p>
        <div style={{ marginTop: 12 }}><ExtLink href={addrUrl(src!, stackOf(src!, "ens").hook)}>The hook that pays</ExtLink></div>
      </div>
    </>
  );
}
