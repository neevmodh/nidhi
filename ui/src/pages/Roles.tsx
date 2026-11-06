import { useState } from "react";
import { useAccount, useSwitchChain, useWriteContract } from "wagmi";
import { isAddress, type Address } from "viem";
import { addrUrl, chainById } from "../lib/chains";
import { useApp } from "../lib/app";
import { useRoles } from "../lib/grants";
import { ago, sameAddr } from "../lib/format";
import { explain } from "../lib/errors";
import { roleAuthorityAbi } from "../data/abi";
import { PageHead } from "../components/shell";
import { ChainName, Empty, ErrorNote, Hash, Icon, Skel } from "../components/ui";

export default function Roles() {
  const { chainId } = useApp();
  const ch = chainById(chainId)!;
  const { data, isLoading, error, refetch } = useRoles(chainId);
  const { address, chainId: walletChain } = useAccount();
  const isAdmin = !!address && !!data?.roles.granteeAdmin.some((a) => sameAddr(a, address));

  const roleRow = (name: string, who?: Address[], what?: string) => (
    <div className="card span-3" key={name}>
      <span className="label">{name}</span>
      <div style={{ marginTop: 12 }} className="stack">
        {who === undefined ? <Skel /> : who.length === 0 ? <span className="muted">Nobody</span> : who.map((a) => <div key={a}><Hash value={a} href={addrUrl(ch, a)} />{sameAddr(a, address) && <span className="small muted"> you</span>}</div>)}
      </div>
      <p className="small muted" style={{ marginTop: 12 }}>{what}</p>
    </div>
  );

  return (
    <>
      <PageHead title={<>Roles on {ch.short}</>} sub={<>RoleAuthority <span className="mono">{ch.deployment?.authority.slice(0, 8)}…</span> decides who may approve, audit and pause, and where each grantee is paid. On Sepolia the same hook can read ENSv2 instead.</>} />
      {error && <ErrorNote text="Roles could not be read." raw={String(error)} />}
      <div className="grid">
        {roleRow("Approver", data?.roles.approver, "signs the mandate")}
        {roleRow("Auditor", data?.roles.auditor, "signs the audit attestation")}
        {roleRow("Guardian", data?.roles.guardian, "can pause all grants")}
        {roleRow("Admin", data?.roles.admin, "grants and revokes roles, names grantees")}
      </div>

      <div className="section-title"><h2 className="h3">Grantees</h2></div>
      <div className="card" style={{ padding: "8px 24px 0" }}>
        {isLoading && <div style={{ padding: 24 }}><Skel w={300} /></div>}
        {data && data.grantees.length === 0 && <Empty title="No grantees named on this chain yet." />}
        {data && data.grantees.length > 0 && (
          <table className="table">
            <thead><tr><th>Name</th><th>Paid on</th><th>Address</th><th>Set</th></tr></thead>
            <tbody>
              {data.grantees.map((g) => (
                <tr key={`${g.label}-${g.dest?.id}`}>
                  <td>{g.label}</td>
                  <td><ChainName chain={g.dest} /></td>
                  <td><Hash value={g.account} href={g.dest ? addrUrl(g.dest, g.account) : undefined} /></td>
                  <td className="small muted">{ago(g.at)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </div>
      {isAdmin && <AddGrantee chainId={chainId} walletChain={walletChain} onDone={() => refetch()} />}
    </>
  );
}

function AddGrantee({ chainId, walletChain, onDone }: { chainId: number; walletChain?: number; onDone: () => void }) {
  const ch = chainById(chainId)!;
  const [label, setLabel] = useState("");
  const [dest, setDest] = useState<number>(ch.lanes[0]);
  const [addr, setAddr] = useState("");
  const { writeContractAsync, isPending } = useWriteContract();
  const { switchChainAsync } = useSwitchChain();
  const [err, setErr] = useState<{ text: string; raw: string } | null>(null);
  const [ok, setOk] = useState<string | null>(null);
  const valid = /^[a-z0-9-]{1,63}$/.test(label) && isAddress(addr);

  async function submit() {
    setErr(null); setOk(null);
    try {
      if (walletChain !== chainId) await switchChainAsync({ chainId: chainId as any });
      const hash = await writeContractAsync({ address: ch.deployment!.authority, abi: roleAuthorityAbi, functionName: "setGrantee", args: [label, chainById(dest)!.selector, addr as Address], chainId: chainId as any });
      setOk(hash); setTimeout(onDone, 6000);
    } catch (e) { setErr(explain(e)); }
  }

  return (
    <>
      <div className="section-title"><h2 className="h3">Name a grantee</h2></div>
      <div className="card">
        <div className="grid">
          <div className="field span-4"><label htmlFor="g-l">Name</label><input id="g-l" className="input" value={label} onChange={(e) => setLabel(e.target.value.toLowerCase())} placeholder="alice" /></div>
          <div className="field span-4"><label htmlFor="g-d">Paid on</label>
            <select id="g-d" className="select" value={dest} onChange={(e) => setDest(Number(e.target.value))}>{ch.lanes.map((l) => <option key={l} value={l}>{chainById(l)?.name}</option>)}</select></div>
          <div className="field span-4"><label htmlFor="g-a">Address on that chain</label><input id="g-a" className="input mono" value={addr} onChange={(e) => setAddr(e.target.value.trim())} placeholder="0x…" /></div>
        </div>
        <div className="row" style={{ marginTop: 24 }}>
          <button className="btn btn--primary" disabled={!valid || isPending} onClick={submit}><Icon name="check" size="sm" />{isPending ? "Confirm in your wallet" : "Save grantee"}</button>
          {ok && <span className="small hint--ok">Sent. The list refreshes once it lands.</span>}
        </div>
        {err && <div style={{ marginTop: 16 }}><ErrorNote {...err} /></div>}
      </div>
    </>
  );
}
