import { useState } from "react";
import { useAccount, useReadContract, useSwitchChain, useWriteContract } from "wagmi";
import { chainById } from "../lib/chains";
import { useApp } from "../lib/app";
import { useChainState, useRoles } from "../lib/grants";
import { sameAddr } from "../lib/format";
import { explain } from "../lib/errors";
import { nidhiHookAbi, destinationReceiverAbi } from "../data/abi";
import { PageHead, WalletButton } from "../components/shell";
import { Chip, ErrorNote, Icon } from "../components/ui";

export default function Settings() {
  const { chainId, grade, setGrade } = useApp();
  const ch = chainById(chainId)!;
  const { address, chainId: walletChain } = useAccount();
  const roles = useRoles(chainId);
  const st = useChainState(chainId);
  const isGuardian = !!address && !!roles.data?.roles.guardian.some((a) => sameAddr(a, address));
  const queue = useReadContract({ address: ch.deployment?.receiver, abi: destinationReceiverAbi, functionName: "queueLength", chainId: chainId as any });

  return (
    <>
      <PageHead title="Settings" sub="Display, wallet and the guardian's controls." />
      <div className="grid">
        <div className="card span-6">
          <span className="label">Display</span>
          <div className="row" style={{ marginTop: 16 }}>
            <button className={`btn ${grade === "evening" ? "btn--primary" : "btn--secondary"}`} onClick={() => setGrade("evening")}><Icon name="moon" size="sm" />Evening</button>
            <button className={`btn ${grade === "day" ? "btn--primary" : "btn--secondary"}`} onClick={() => setGrade("day")}><Icon name="sun" size="sm" />Day</button>
          </div>
        </div>
        <div className="card span-6">
          <span className="label">Wallet</span>
          <div className="row" style={{ marginTop: 16 }}><WalletButton /></div>
          <p className="small muted" style={{ marginTop: 12 }}>Reading needs no wallet. Signing and sending do.</p>
        </div>
        <div className="card span-12">
          <div className="row row--between">
            <span className="label">Guardian controls on {ch.short}</span>
            {st.data && (st.data.paused ? <Chip tone="warn">Grants paused</Chip> : <Chip tone="ok">Grants running</Chip>)}
          </div>
          {isGuardian ? <PauseControl chainId={chainId} paused={!!st.data?.paused} walletChain={walletChain} onDone={() => st.refetch()} />
            : <p className="muted" style={{ marginTop: 16 }}>Only a wallet holding the guardian role on {ch.short} can pause grants. The receiver queue holds {queue.data !== undefined ? String(queue.data) : "…"} item(s).</p>}
        </div>
      </div>
    </>
  );
}

function PauseControl({ chainId, paused, walletChain, onDone }: { chainId: number; paused: boolean; walletChain?: number; onDone: () => void }) {
  const ch = chainById(chainId)!;
  const [confirm, setConfirm] = useState(false);
  const [err, setErr] = useState<{ text: string; raw: string } | null>(null);
  const { writeContractAsync, isPending } = useWriteContract();
  const { switchChainAsync } = useSwitchChain();
  async function go() {
    setErr(null);
    try {
      if (walletChain !== chainId) await switchChainAsync({ chainId: chainId as any });
      await writeContractAsync({ address: ch.deployment!.hook, abi: nidhiHookAbi, functionName: "setPaused", args: [!paused], chainId: chainId as any });
      setConfirm(false); setTimeout(onDone, 6000);
    } catch (e) { setErr(explain(e)); }
  }
  return (
    <div style={{ marginTop: 16 }} className="stack">
      <p className="measure">{paused ? "Resume lets signed grants swap again." : "Pause stops every new grant on this chain at once. Grants already sent still settle."}</p>
      {!confirm ? <button className="btn btn--secondary" onClick={() => setConfirm(true)}><Icon name={paused ? "play" : "pause"} size="sm" />{paused ? "Resume grants" : "Pause grants"}</button>
        : <div className="row"><button className="btn btn--primary" disabled={isPending} onClick={go}>{isPending ? "Confirm in your wallet" : paused ? "Yes, resume" : "Yes, pause now"}</button><button className="btn btn--secondary" onClick={() => setConfirm(false)}>Keep as is</button></div>}
      {err && <ErrorNote {...err} />}
    </div>
  );
}
