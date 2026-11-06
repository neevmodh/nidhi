import { useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { useAccount, usePublicClient, useSwitchChain, useWriteContract } from "wagmi";
import { keccak256, parseEther, toHex, zeroAddress, type Address } from "viem";
import { chainById, client, stackOf } from "../lib/chains";
import { amount } from "../lib/format";
import { explain } from "../lib/errors";
import { bountySpecHash } from "../lib/canonical";
import { poolKey, zeroForOne } from "../lib/mandate";
import { nidhiBountyBoardAbi } from "../data/abi";
import data from "../data/milestones.json";
import { WalletButton } from "../components/shell";
import { ErrorNote, ExtLink, Icon, ProtocolLogo, Skel } from "../components/ui";

const SEPOLIA = 11155111;
const authAbi = [
  { type: "function", name: "APPROVER", stateMutability: "view", inputs: [], outputs: [{ type: "bytes32" }] },
  { type: "function", name: "isAuthorized", stateMutability: "view", inputs: [{ type: "bytes32" }, { type: "address" }], outputs: [{ type: "bool" }] },
  { type: "function", name: "resolveGrantee", stateMutability: "view", inputs: [{ type: "string" }, { type: "uint64" }], outputs: [{ type: "address" }] },
] as const;
const quoterAbi = [{ type: "function", name: "quoteExactInputSingle", stateMutability: "nonpayable",
  inputs: [{ name: "params", type: "tuple", components: [
    { name: "poolKey", type: "tuple", components: [{ name: "currency0", type: "address" }, { name: "currency1", type: "address" }, { name: "fee", type: "uint24" }, { name: "tickSpacing", type: "int24" }, { name: "hooks", type: "address" }] },
    { name: "zeroForOne", type: "bool" }, { name: "exactAmount", type: "uint128" }, { name: "hookData", type: "bytes" }] }],
  outputs: [{ name: "amountOut", type: "uint256" }, { name: "gasEstimate", type: "uint256" }] }] as const;

/** Post a milestone on-chain. The wallet must hold the approver role on nidhi-dao.eth (checked live). */
export default function NewMilestone({ onDone }: { onDone: () => void }) {
  const board = (data as any).board;
  const src = chainById(SEPOLIA)!;
  const stack = stackOf(src, "ens");
  const { address, chainId: wc } = useAccount();
  const { switchChainAsync } = useSwitchChain();
  const { writeContractAsync, isPending } = useWriteContract();
  const pub = usePublicClient({ chainId: SEPOLIA as any });

  const [kind, setKind] = useState<"open" | "assigned">("open");
  const [title, setTitle] = useState("");
  const [body, setBody] = useState("");
  const [repo, setRepo] = useState("neevmodh/nidhi");
  const [grantee, setGrantee] = useState("");
  const [payTo, setPayTo] = useState<number>(stack.lanes[0]);
  const [amt, setAmt] = useState("0.0003");
  const [paths, setPaths] = useState("docs/**");
  const [approvals, setApprovals] = useState(0);
  const [days, setDays] = useState(14);
  const [err, setErr] = useState<{ text: string; raw: string } | null>(null);
  const [done, setDone] = useState<string | null>(null);

  const dest = chainById(payTo);
  let wei = 0n; try { wei = parseEther(amt || "0"); } catch { wei = 0n; }

  const role = useQuery({
    queryKey: ["ens-approver", address],
    enabled: !!address,
    queryFn: async () => {
      const c = client(SEPOLIA);
      const r = await c.readContract({ address: stack.authority, abi: authAbi, functionName: "APPROVER" });
      return c.readContract({ address: stack.authority, abi: authAbi, functionName: "isAuthorized", args: [r, address!] });
    },
  });
  const payee = useQuery({
    queryKey: ["ms-payee", grantee, payTo],
    enabled: kind === "assigned" && /^[a-z0-9-]{1,63}$/.test(grantee) && !!dest,
    queryFn: () => client(SEPOLIA).readContract({ address: stack.authority, abi: authAbi, functionName: "resolveGrantee", args: [grantee, dest!.selector] }) as Promise<Address>,
  });
  const quote = useQuery({
    queryKey: ["ms-quote", wei.toString()],
    enabled: wei > 0n,
    queryFn: async () => {
      const { result } = await client(SEPOLIA).simulateContract({ address: src.uniswap.quoter, abi: quoterAbi, functionName: "quoteExactInputSingle", args: [{ poolKey: poolKey(src, stack.hook), zeroForOne: zeroForOne(src), exactAmount: wei, hookData: "0x" }] });
      return result[0] as bigint;
    },
  });

  const assignedOk = kind === "open" || (payee.data && payee.data !== zeroAddress);
  const ready = !!board && !!role.data && title.trim().length > 2 && body.trim().length > 10 && /^[\w.-]+\/[\w.-]+$/.test(repo) && wei > 0n && !!quote.data && assignedOk && !!dest;

  async function submit() {
    setErr(null); setDone(null);
    try {
      const rules = { minApprovals: approvals, requiredPathGlobs: paths.split(",").map((p) => p.trim()).filter(Boolean) };
      const spec = { title: title.trim(), repo: repo.trim(), body: body.trim(), rules: JSON.stringify(rules), grantee: kind === "assigned" ? grantee : "" };
      const specHash = bountySpecHash(spec, dest!.selector, wei);
      const q = quote.data!;
      const bounty = {
        poster: zeroAddress, cancelled: false, grantId: "0x0000000000000000000000000000000000000000000000000000000000000000" as const,
        specHash, granteeLabelHash: kind === "assigned" ? keccak256(toHex(grantee)) : ("0x0000000000000000000000000000000000000000000000000000000000000000" as const),
        executor: board.executor as Address, tokenIn: src.base.address, tokenOut: src.payout.address,
        amountIn: wei, minOut: (q * 50n) / 100n, maxOut: (q * 150n) / 100n,
        destChainSelector: dest!.selector, destReceiver: stack.receivers![String(payTo)],
        poolId: stack.poolId, deadline: BigInt(Math.floor(Date.now() / 1000) + days * 86400),
      };
      if (wc !== SEPOLIA) await switchChainAsync({ chainId: SEPOLIA as any });
      const hash = await writeContractAsync({ address: board.board, abi: nidhiBountyBoardAbi, functionName: "post", args: [bounty as any, spec], chainId: SEPOLIA as any });
      await pub?.waitForTransactionReceipt({ hash });
      setDone(hash);
      setTimeout(onDone, 1500);
    } catch (e) { setErr(explain(e)); }
  }

  if (!board) return <div className="card">No milestone board is deployed.</div>;
  return (
    <section className="card span-12 stack" aria-label="New milestone">
      <div className="row row--between row--wrap">
        <span className="label">New milestone · posted on-chain to the milestone board</span>
        {!address ? <WalletButton /> : role.isLoading ? <Skel w={160} /> : role.data
          ? <span className="chip chip--ok"><svg viewBox="0 0 10 10"><circle cx="5" cy="5" r="5" fill="currentColor" /></svg><span>You hold the approver role on nidhi-dao.eth</span></span>
          : <span className="chip chip--bad"><svg viewBox="0 0 10 10"><path d="M1.5 1.5l7 7m0-7-7 7" stroke="currentColor" strokeWidth="2" strokeLinecap="round" /></svg><span>This wallet is not an approver on nidhi-dao.eth</span></span>}
      </div>

      <div className="field">
        <label>Who can claim it</label>
        <div className="row row--wrap" role="radiogroup">
          <button role="radio" aria-checked={kind === "open"} className={`btn ${kind === "open" ? "btn--primary" : "btn--secondary"}`} onClick={() => setKind("open")}>Open to anyone</button>
          <button role="radio" aria-checked={kind === "assigned"} className={`btn ${kind === "assigned" ? "btn--primary" : "btn--secondary"}`} onClick={() => setKind("assigned")}><ProtocolLogo name="ens" />Assigned to an ENS name</button>
        </div>
        <span className="hint">{kind === "open" ? "The first merged PR that passes is paid. The author gets <github>.nidhi-dao.eth if they don't have one." : "Only this subname of nidhi-dao.eth can be paid."}</span>
      </div>

      <div className="grid">
        <div className="field span-8"><label htmlFor="nm-t">Title</label><input id="nm-t" className="input" value={title} onChange={(e) => setTitle(e.target.value)} placeholder="Add dark mode to the grant timeline" /></div>
        <div className="field span-4"><label htmlFor="nm-r">Repository</label><input id="nm-r" className="input mono" value={repo} onChange={(e) => setRepo(e.target.value.trim())} /></div>
        <div className="field span-12"><label htmlFor="nm-b">Task</label><textarea id="nm-b" className="input" style={{ height: 112, padding: 12, resize: "vertical" }} value={body} onChange={(e) => setBody(e.target.value)} placeholder="What must be delivered, and how it will be judged." /></div>
        {kind === "assigned" && (
          <div className="field span-4">
            <label htmlFor="nm-g">Grantee (subname)</label>
            <input id="nm-g" className="input" value={grantee} onChange={(e) => setGrantee(e.target.value.toLowerCase().trim())} placeholder="alice" />
            {grantee && (payee.isLoading ? <span className="hint">Resolving on ENS…</span> : payee.data && payee.data !== zeroAddress ? <span className="hint hint--ok">{grantee}.nidhi-dao.eth resolves on {dest?.short}</span> : <span className="hint hint--bad">No address on {dest?.short} for this name</span>)}
          </div>
        )}
        <div className="field span-4"><label htmlFor="nm-p">Paid on</label>
          <select id="nm-p" className="select" value={payTo} onChange={(e) => setPayTo(Number(e.target.value))}>{stack.lanes.map((l) => <option key={l} value={l}>{chainById(l)?.name}</option>)}</select></div>
        <div className="field span-4"><label htmlFor="nm-a">Amount (WETH)</label><input id="nm-a" className="input mono" inputMode="decimal" value={amt} onChange={(e) => setAmt(e.target.value)} />
          <span className="hint">{quote.isLoading ? "Quoting on Uniswap v4…" : quote.data ? `≈ ${amount(quote.data)} CCIP-BnM to the grantee (V4Quoter)` : ""}</span></div>
        <div className="field span-4"><label htmlFor="nm-f">Required paths</label><input id="nm-f" className="input mono" value={paths} onChange={(e) => setPaths(e.target.value)} placeholder="docs/**, ui/src/**" /></div>
        <div className="field span-4"><label htmlFor="nm-v">Approving reviews needed</label><input id="nm-v" className="input mono" type="number" min={0} max={5} value={approvals} onChange={(e) => setApprovals(Math.max(0, Math.min(5, Number(e.target.value))))} /></div>
        <div className="field span-4"><label htmlFor="nm-d">Open for (days)</label><input id="nm-d" className="input mono" type="number" min={1} max={90} value={days} onChange={(e) => setDays(Math.max(1, Math.min(90, Number(e.target.value))))} /></div>
      </div>

      <p className="small muted">You commit, on-chain, to this exact text, amount, chain and rules. The agent pays only a payout that matches it, once, and the hook still checks the price band and the daily cap. CI must be green and the PR must be merged.</p>
      <div className="row row--wrap">
        <button className="btn btn--primary" disabled={!ready || isPending} onClick={submit}><Icon name="plus" size="sm" />{isPending ? "Confirm in your wallet" : "Post milestone"}</button>
        {done && <span className="small hint--ok">Posted. <ExtLink href={`${src.explorer}/tx/${done}`}>View the transaction</ExtLink></span>}
      </div>
      {err && <ErrorNote {...err} />}
    </section>
  );
}
