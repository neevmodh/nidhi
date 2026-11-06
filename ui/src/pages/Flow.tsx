import { useEffect, useMemo, useState } from "react";
import { Link, useLocation, useNavigate, useSearchParams } from "react-router-dom";
import { useQuery } from "@tanstack/react-query";
import { useAccount, useSignTypedData, useSwitchChain, useWriteContract, usePublicClient } from "wagmi";
import { isHex, parseEther, zeroAddress, type Address, type Hex } from "viem";
import { chainById, client, deployedChains, txUrl } from "../lib/chains";
import { useApp } from "../lib/app";
import { useChainState, useRoles } from "../lib/grants";
import { amount, sameAddr, short } from "../lib/format";
import { explain } from "../lib/errors";
import { nidhiSwapRouterAbi, roleAuthorityAbi } from "../data/abi";
import evidence from "../data/evidence.json";
import {
  ATTESTATION_TYPES, MANDATE_TYPES, MAX_SQRT, MIN_SQRT, decodeDraft, domain, encodeDraft, hookData, labelHash,
  newGrantId, poolKey, zeroForOne, type Draft,
} from "../lib/mandate";
import { PageHead, WalletButton } from "../components/shell";
import { ChainName, Chip, ErrorNote, ExtLink, Hash, Icon, Route, Skel } from "../components/ui";

const quoterAbi = [{
  type: "function", name: "quoteExactInputSingle", stateMutability: "nonpayable",
  inputs: [{ name: "params", type: "tuple", components: [
    { name: "poolKey", type: "tuple", components: [{ name: "currency0", type: "address" }, { name: "currency1", type: "address" }, { name: "fee", type: "uint24" }, { name: "tickSpacing", type: "int24" }, { name: "hooks", type: "address" }] },
    { name: "zeroForOne", type: "bool" }, { name: "exactAmount", type: "uint128" }, { name: "hookData", type: "bytes" }] }],
  outputs: [{ name: "amountOut", type: "uint256" }, { name: "gasEstimate", type: "uint256" }],
}] as const;
const wethAbi = [
  { type: "function", name: "deposit", stateMutability: "payable", inputs: [], outputs: [] },
  { type: "function", name: "approve", stateMutability: "nonpayable", inputs: [{ type: "address" }, { type: "uint256" }], outputs: [{ type: "bool" }] },
  { type: "function", name: "balanceOf", stateMutability: "view", inputs: [{ type: "address" }], outputs: [{ type: "uint256" }] },
  { type: "function", name: "allowance", stateMutability: "view", inputs: [{ type: "address" }, { type: "address" }], outputs: [{ type: "uint256" }] },
] as const;

const bundle = evidence as any;
const BAND = 10n; // percent either side of the V4Quoter quote

function Stepper({ at }: { at: 1 | 2 | 3 }) {
  const items = ["Details", "Signatures", "Send"];
  return (
    <ol className="row" style={{ listStyle: "none", padding: 0, margin: "0 0 32px", gap: 12 }} aria-label="Progress">
      {items.map((t, i) => (
        <li key={t} className="row" style={{ gap: 8, color: i + 1 <= at ? "var(--ink)" : "var(--muted)" }} aria-current={i + 1 === at ? "step" : undefined}>
          <span className="chip" style={{ background: i + 1 === at ? "var(--accent)" : "var(--g-alt)", color: i + 1 === at ? "var(--accent-ink)" : "inherit" }}>{i + 1}</span>
          <span className="small">{t}</span>
          {i < 2 && <span style={{ width: 32, height: 1, background: "var(--line-strong)" }} />}
        </li>
      ))}
    </ol>
  );
}

// ============================================================ 1. New grant
export function NewGrant() {
  const { chainId } = useApp();
  const src = chainById(chainId)!;
  const [params] = useSearchParams();
  const nav = useNavigate();
  const { address } = useAccount();
  const st = useChainState(chainId);

  const [label, setLabel] = useState("");
  const [dest, setDest] = useState<number>(src.lanes.find((l) => chainById(l)?.deployment) ?? src.lanes[0]);
  const [amountIn, setAmountIn] = useState("0.0003");
  const [executor, setExecutor] = useState<string>("");
  const [evid, setEvid] = useState<string>(params.get("evidence") ?? bundle?.hashes?.evidenceHash ?? "");
  useEffect(() => { if (address && !executor) setExecutor(address); }, [address, executor]);
  useEffect(() => { setDest(src.lanes.find((l) => chainById(l)?.deployment) ?? src.lanes[0]); }, [chainId]); // eslint-disable-line react-hooks/exhaustive-deps

  const destCh = chainById(dest);
  let wei = 0n; try { wei = parseEther(amountIn || "0"); } catch { wei = 0n; }

  // grantee name must resolve on the chosen destination (fail-closed, same call the hook makes)
  const payee = useQuery({
    queryKey: ["payee", chainId, label, dest],
    enabled: /^[a-z0-9-]{1,63}$/.test(label) && !!destCh,
    queryFn: () => client(chainId).readContract({ address: src.deployment!.authority, abi: roleAuthorityAbi, functionName: "resolveGrantee", args: [label, destCh!.selector] }) as Promise<Address>,
  });
  const quote = useQuery({
    queryKey: ["quote", chainId, wei.toString()],
    enabled: wei > 0n,
    queryFn: async () => {
      const { result } = await client(chainId).simulateContract({
        address: src.uniswap.quoter, abi: quoterAbi, functionName: "quoteExactInputSingle",
        args: [{ poolKey: poolKey(src), zeroForOne: zeroForOne(src), exactAmount: wei, hookData: "0x" }],
      });
      return result[0] as bigint;
    },
  });

  const payeeOk = payee.data && payee.data !== zeroAddress;
  const capOk = st.data ? wei <= st.data.remaining : true;
  const evidOk = isHex(evid) && evid.length === 66;
  const execOk = /^0x[0-9a-fA-F]{40}$/.test(executor);
  const ready = payeeOk && capOk && evidOk && execOk && quote.data && destCh?.deployment;

  function create() {
    const q = quote.data!;
    const grantId = newGrantId(label);
    const useBundle = sameAddr(evid, bundle?.hashes?.evidenceHash);
    const d: Draft = {
      v: 1, src: chainId, label,
      mandate: {
        grantId, executor: executor as Address, recipient: payee.data!, tokenIn: src.base.address, tokenOut: src.payout.address,
        amountIn: wei, minOut: (q * (100n - BAND)) / 100n, maxOut: (q * (100n + BAND)) / 100n,
        destChainSelector: destCh!.selector, destReceiver: destCh!.deployment!.receiver, evidenceHash: evid as Hex,
        deadline: BigInt(Math.floor(Date.now() / 1000) + 3600), poolId: src.deployment!.poolId, recipientLabelHash: labelHash(label),
      },
      attestation: {
        grantId, evidenceHash: evid as Hex,
        inputsHash: useBundle ? bundle.hashes.inputsHash : labelHash("inputs"),
        rubricHash: useBundle ? bundle.hashes.rubricHash : labelHash("rubric"),
        issuedAt: BigInt(Math.floor(Date.now() / 1000)),
      },
    };
    nav(`/app/sign#${encodeDraft(d)}`);
  }

  return (
    <>
      <PageHead title="New grant" sub="Name the grantee, the chain they are paid on and the amount. Two people then sign it." />
      <Stepper at={1} />
      <div className="grid">
        <div className="card span-8 stack">
          <div className="field">
            <label htmlFor="n-l">Grantee name</label>
            <input id="n-l" className="input" value={label} onChange={(e) => setLabel(e.target.value.toLowerCase().trim())} placeholder="alice" autoComplete="off" />
            {label && (payee.isLoading ? <span className="hint">Checking the name on {src.short}…</span>
              : payeeOk ? <span className="hint hint--ok">Paid to <span className="mono">{short(payee.data)}</span> on {destCh?.short}</span>
              : <span className="hint hint--bad">No address for this name on {destCh?.short}. The admin names grantees under Roles.</span>)}
          </div>
          <div className="field">
            <label htmlFor="n-d">Paid on</label>
            <select id="n-d" className="select" value={dest} onChange={(e) => setDest(Number(e.target.value))}>
              {src.lanes.filter((l) => chainById(l)?.deployment).map((l) => <option key={l} value={l}>{chainById(l)?.name}</option>)}
            </select>
            <span className="hint">Only chains with a live CCIP lane from {src.short} appear.</span>
          </div>
          <div className="field">
            <label htmlFor="n-a">Amount in ({src.base.symbol})</label>
            <input id="n-a" className="input mono" inputMode="decimal" value={amountIn} onChange={(e) => setAmountIn(e.target.value)} />
            {st.data && <span className={`hint ${capOk ? "" : "hint--bad"}`}>{capOk ? `Cap left today: ${amount(st.data.remaining)} ${src.base.symbol}` : `More than today's cap. Left: ${amount(st.data.remaining)} ${src.base.symbol}`}</span>}
          </div>
          <div className="field">
            <label htmlFor="n-x">Executor (who sends the swap)</label>
            <input id="n-x" className="input mono" value={executor} onChange={(e) => setExecutor(e.target.value.trim())} placeholder="0x…" />
            <span className="hint">Only this wallet can send the signed grant.</span>
          </div>
          <div className="field">
            <label htmlFor="n-e">Evidence hash</label>
            <input id="n-e" className="input mono" value={evid} onChange={(e) => setEvid(e.target.value.trim())} placeholder="0x…" />
            <span className="hint">{sameAddr(evid, bundle?.hashes?.evidenceHash) ? <>From the audit of {bundle.grantLabel}. <Link className="link" to={`/app/audit/${bundle.grantLabel}`}>See the report</Link></> : "Paste the hash the auditor printed."}</span>
          </div>
        </div>
        <aside className="card span-4 stack" aria-label="Summary">
          <span className="label">Summary</span>
          <Route from={src} to={destCh} />
          <dl className="kv small">
            <dt>Grantee</dt><dd>{label || "—"}</dd>
            <dt>In</dt><dd className="mono">{amountIn || "0"} {src.base.symbol}</dd>
            <dt>Quote</dt><dd className="mono">{quote.isLoading ? <Skel w={60} /> : quote.data ? `${amount(quote.data)} ${src.payout.symbol}` : "—"}</dd>
            <dt>Accepted band</dt><dd className="mono">{quote.data ? `${amount((quote.data * 90n) / 100n)} – ${amount((quote.data * 110n) / 100n)}` : "—"}</dd>
          </dl>
          <p className="small muted">Quoted by Uniswap's V4Quoter against the hooked pool. The hook refuses any output outside the band.</p>
          {quote.error && <ErrorNote text="The quote failed." raw={String(quote.error)} />}
          <button className="btn btn--primary btn--block" disabled={!ready} onClick={create}>Prepare for signing<Icon name="arrow-right" size="sm" /></button>
        </aside>
      </div>
    </>
  );
}

// ============================================================ 2. Sign
function useDraft(): Draft | null {
  const { hash } = useLocation();
  return useMemo(() => decodeDraft(hash.slice(1)), [hash]);
}

export function Sign() {
  const draft = useDraft();
  const nav = useNavigate();
  const { address, chainId: wc } = useAccount();
  const { signTypedDataAsync, isPending } = useSignTypedData();
  const { switchChainAsync } = useSwitchChain();
  const [err, setErr] = useState<{ text: string; raw: string } | null>(null);
  const roles = useRoles(draft?.src ?? 84532);
  if (!draft) return <ErrorNote text="This signing link is incomplete or damaged. Start a new grant." />;
  const src = chainById(draft.src)!;
  const dest = deployedChains().find((c) => c.selector === draft.mandate.destChainSelector);
  const m = draft.mandate;
  const isApprover = !!address && !!roles.data?.roles.approver.some((a) => sameAddr(a, address));
  const isAuditor = !!address && !!roles.data?.roles.auditor.some((a) => sameAddr(a, address));
  const link = `${location.origin}${location.pathname}${location.hash}`;

  async function sign(as: "approver" | "auditor") {
    setErr(null);
    try {
      if (as === "approver" && sameAddr(address, draft!.auditor)) throw new Error("same-signer");
      if (as === "auditor" && sameAddr(address, draft!.approver)) throw new Error("same-signer");
      if (wc !== draft!.src) await switchChainAsync({ chainId: draft!.src as any });
      const sig = as === "approver"
        ? await signTypedDataAsync({ domain: domain(src), types: MANDATE_TYPES, primaryType: "Mandate", message: m as any })
        : await signTypedDataAsync({ domain: domain(src), types: ATTESTATION_TYPES, primaryType: "Attestation", message: draft!.attestation as any });
      const next: Draft = as === "approver" ? { ...draft!, approver: address, approverSig: sig } : { ...draft!, auditor: address, auditorSig: sig };
      nav(`/app/sign#${encodeDraft(next)}`, { replace: true });
    } catch (e) {
      setErr((e as Error).message === "same-signer" ? { text: "The approver and the auditor must be two different wallets.", raw: "" } : explain(e));
    }
  }

  const both = draft.approverSig && draft.auditorSig;
  return (
    <>
      <PageHead title="Two signatures, two people" sub={<>Grant to {draft.label} · <Route from={src} to={dest} /></>} action={<WalletButton />} />
      <Stepper at={2} />
      <div className="grid">
        <section className="card span-6 stack">
          <div className="row row--between"><span className="label">Approver signs the mandate</span>{draft.approverSig ? <Chip tone="ok">Signed</Chip> : <Chip tone="idle">Waiting</Chip>}</div>
          <dl className="kv small">
            <dt>Pays</dt><dd><span className="mono">{short(m.recipient)}</span> on <ChainName chain={dest} /></dd>
            <dt>Amount in</dt><dd className="mono">{amount(m.amountIn)} {src.base.symbol}</dd>
            <dt>Output band</dt><dd className="mono">{amount(m.minOut)} – {amount(m.maxOut)} {src.payout.symbol}</dd>
            <dt>Executor</dt><dd className="mono">{short(m.executor)}</dd>
            <dt>Expires</dt><dd>{new Date(Number(m.deadline) * 1000).toLocaleTimeString()}</dd>
          </dl>
          {draft.approverSig ? <p className="small muted">Signed by <span className="mono">{short(draft.approver)}</span></p>
            : <button className="btn btn--primary" disabled={!isApprover || isPending} onClick={() => sign("approver")}><Icon name="signature" size="sm" />Sign as approver</button>}
          {!draft.approverSig && address && !isApprover && <p className="small hint--bad">This wallet does not hold the approver role on {src.short}.</p>}
        </section>
        <section className="card span-6 stack">
          <div className="row row--between"><span className="label">Auditor signs the attestation</span>{draft.auditorSig ? <Chip tone="ok">Signed</Chip> : <Chip tone="idle">Waiting</Chip>}</div>
          <dl className="kv small">
            <dt>Evidence</dt><dd><Hash value={m.evidenceHash} /></dd>
            <dt>Rubric</dt><dd><Hash value={draft.attestation.rubricHash} /></dd>
            <dt>Grant id</dt><dd><Hash value={m.grantId} /></dd>
          </dl>
          {draft.auditorSig ? <p className="small muted">Signed by <span className="mono">{short(draft.auditor)}</span></p>
            : <button className="btn btn--primary" disabled={!isAuditor || isPending} onClick={() => sign("auditor")}><Icon name="signature" size="sm" />Sign as auditor</button>}
          {!draft.auditorSig && address && !isAuditor && <p className="small hint--bad">This wallet does not hold the auditor role on {src.short}.</p>}
        </section>
      </div>
      {err && <div style={{ marginTop: 24 }}><ErrorNote {...err} /></div>}
      <div className="card row row--between row--wrap" style={{ marginTop: 24 }}>
        <div className="stack" style={{ flex: 1, minWidth: 260 }}>
          <span className="label">Share this link with the other signer and the executor</span>
          <span className="mono small muted" style={{ overflowWrap: "anywhere" }}>{short(link, 48, 12)}</span>
        </div>
        <div className="row">
          <button className="btn btn--secondary" onClick={() => navigator.clipboard?.writeText(link)}><Icon name="copy" size="sm" />Copy link</button>
          <button className="btn btn--primary" disabled={!both} onClick={() => nav(`/app/execute${location.hash}`)}>Continue to send<Icon name="arrow-right" size="sm" /></button>
        </div>
      </div>
    </>
  );
}

// ============================================================ 3. Execute
export function Execute() {
  const draft = useDraft();
  const nav = useNavigate();
  const { address, chainId: wc } = useAccount();
  const { switchChainAsync } = useSwitchChain();
  const { writeContractAsync } = useWriteContract();
  const pub = usePublicClient({ chainId: (draft?.src ?? 84532) as any });
  const [busy, setBusy] = useState<string | null>(null);
  const [err, setErr] = useState<{ text: string; raw: string } | null>(null);
  const [done, setDone] = useState<Hex | null>(null);
  const src = draft ? chainById(draft.src)! : null;

  const bal = useQuery({
    queryKey: ["exec-bal", draft?.src, address, done],
    enabled: !!draft && !!address,
    queryFn: async () => {
      const c = client(draft!.src);
      const [w, a] = await Promise.all([
        c.readContract({ address: src!.base.address, abi: wethAbi, functionName: "balanceOf", args: [address!] }),
        c.readContract({ address: src!.base.address, abi: wethAbi, functionName: "allowance", args: [address!, src!.deployment!.router] }),
      ]);
      return { weth: w as bigint, allowance: a as bigint };
    },
    refetchInterval: 8000,
  });
  if (!draft || !src) return <ErrorNote text="This link is incomplete or damaged. Start a new grant." />;
  if (!draft.approverSig || !draft.auditorSig) return <ErrorNote text="Both signatures are needed before sending." />;
  const m = draft.mandate;
  const isExec = sameAddr(address, m.executor);
  const wrapped = (bal.data?.weth ?? 0n) >= m.amountIn;
  const approved = (bal.data?.allowance ?? 0n) >= m.amountIn;

  async function run(step: "wrap" | "approve" | "send") {
    setErr(null); setBusy(step);
    try {
      if (wc !== draft!.src) await switchChainAsync({ chainId: draft!.src as any });
      let hash: Hex;
      if (step === "wrap") hash = await writeContractAsync({ address: src!.base.address, abi: wethAbi, functionName: "deposit", value: m.amountIn - (bal.data?.weth ?? 0n), chainId: draft!.src as any });
      else if (step === "approve") hash = await writeContractAsync({ address: src!.base.address, abi: wethAbi, functionName: "approve", args: [src!.deployment!.router, m.amountIn], chainId: draft!.src as any });
      else hash = await writeContractAsync({
        address: src!.deployment!.router, abi: nidhiSwapRouterAbi, functionName: "swap", chainId: draft!.src as any,
        args: [poolKey(src!) as any, { zeroForOne: zeroForOne(src!), amountSpecified: -m.amountIn, sqrtPriceLimitX96: zeroForOne(src!) ? MIN_SQRT : MAX_SQRT } as any, hookData(draft!), BigInt(Math.floor(Date.now() / 1000) + 600)],
      });
      await pub?.waitForTransactionReceipt({ hash });
      if (step === "send") { setDone(hash); setTimeout(() => nav(`/app/grants/${src!.key}/${m.grantId}`), 2500); }
      bal.refetch();
    } catch (e) { setErr(explain(e)); } finally { setBusy(null); }
  }

  const Row = ({ n, title, ok, action }: { n: number; title: string; ok: boolean; action: React.ReactNode }) => (
    <li className="row row--between" style={{ padding: "16px 0", borderBottom: "1px solid var(--line)" }}>
      <span className="row"><span className="chip">{n}</span>{title}</span>
      {ok ? <Chip tone="ok">Done</Chip> : action}
    </li>
  );

  return (
    <>
      <PageHead title="Send the grant" sub={<>Executor <span className="mono">{short(m.executor)}</span> sends the swap on {src.short}. The hook checks both signatures inside it.</>} action={<WalletButton />} />
      <Stepper at={3} />
      <div className="card">
        {!address ? <p className="muted">Connect the executor's wallet to continue.</p> : !isExec ? <p className="hint--bad">This wallet is not the executor named in the mandate.</p> : (
          <ol style={{ listStyle: "none", margin: 0, padding: 0 }}>
            <Row n={1} title={`Wrap ${amount(m.amountIn)} ETH into ${src.base.symbol}`} ok={wrapped} action={<button className="btn btn--secondary" disabled={!!busy} onClick={() => run("wrap")}>{busy === "wrap" ? "Confirm in wallet" : "Wrap"}</button>} />
            <Row n={2} title="Let Nidhi's router spend it" ok={approved} action={<button className="btn btn--secondary" disabled={!!busy || !wrapped} onClick={() => run("approve")}>{busy === "approve" ? "Confirm in wallet" : "Approve"}</button>} />
            <Row n={3} title="Swap through the hook and send by CCIP" ok={!!done} action={<button className="btn btn--primary" disabled={!!busy || !wrapped || !approved} onClick={() => run("send")}>{busy === "send" ? "Confirm in wallet" : "Send grant"}<Icon name="arrow-right" size="sm" /></button>} />
          </ol>
        )}
        {done && <div className="note note--ok" style={{ marginTop: 16 }}><Icon name="check" /><p>Sent. <ExtLink href={txUrl(src, done)}>View the transaction</ExtLink>. Opening the grant's timeline…</p></div>}
        {err && <div style={{ marginTop: 16 }}><ErrorNote {...err} /></div>}
      </div>
    </>
  );
}
