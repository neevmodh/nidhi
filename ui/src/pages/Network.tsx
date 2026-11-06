import { useState } from "react";
import { formatEther } from "viem";
import { CHAINS, addrUrl, type ChainInfo } from "../lib/chains";
import { useChainState } from "../lib/grants";
import { short } from "../lib/format";
import mainnets from "../data/mainnets.json";
import { PageHead } from "../components/shell";
import { Chip, ExtLink, ProtocolLogo, Skel } from "../components/ui";

// fixed positions for a calm, still lane map
const POS: Record<number, [number, number]> = { 11155111: [120, 70], 84532: [480, 70], 421614: [480, 250], 1301: [120, 250] };

function LaneMap() {
  const pairs = new Set<string>();
  for (const c of CHAINS) for (const l of c.lanes) pairs.add([c.id, l].sort().join("-"));
  return (
    <svg viewBox="0 0 600 320" role="img" aria-label="CCIP lanes between the four testnets" style={{ width: "100%", height: "auto" }}>
      {[...pairs].map((p) => {
        const [a, b] = p.split("-").map(Number);
        const [x1, y1] = POS[a], [x2, y2] = POS[b];
        return <line key={p} x1={x1} y1={y1} x2={x2} y2={y2} stroke="var(--accent)" strokeOpacity=".5" strokeWidth="1.5" />;
      })}
      {CHAINS.map((c) => {
        const [x, y] = POS[c.id];
        return (
          <g key={c.id} transform={`translate(${x} ${y})`}>
            <rect x="-86" y="-22" width="172" height="44" rx="22" fill="var(--g-raise)" stroke="var(--line-strong)" />
            <text x="0" y="5" textAnchor="middle" fill="var(--ink)" fontSize="14" fontFamily="var(--f-text)" fontWeight="500">{c.short}</text>
          </g>
        );
      })}
    </svg>
  );
}

function Row({ c }: { c: ChainInfo }) {
  const { data: s, isLoading } = useChainState(c.id);
  const d = c.deployment!;
  return (
    <tr>
      <td><span className="route"><ProtocolLogo name={c.logo} />{c.name}</span></td>
      <td><a className="mono link" href={addrUrl(c, d.hook)} target="_blank" rel="noreferrer">{short(d.hook)}</a></td>
      <td>{isLoading ? <Skel w={40} /> : `${s?.routes.filter((r) => r.wired).length ?? 0} of ${c.lanes.length}`}</td>
      <td>{isLoading ? <Skel w={70} /> : s?.cursed ? <Chip tone="bad">Cursed</Chip> : s?.cursed === false ? <Chip tone="ok">Clear</Chip> : <Chip tone="idle">Unknown</Chip>}</td>
      <td className="mono">{s ? Number(formatEther(s.feeReserve)).toFixed(4) : <Skel w={50} />}</td>
      <td className="mono">{s ? Number(formatEther(s.rxReserve)).toFixed(4) : <Skel w={50} />}</td>
    </tr>
  );
}

export default function Network() {
  const [tab, setTab] = useState<"testnet" | "mainnet">("testnet");
  const mn = Object.values((mainnets as any).chains) as any[];
  return (
    <>
      <PageHead
        title="Chains and lanes"
        sub="A grant can only go where Chainlink runs a CCIP lane. Routes are add-only."
        action={
          <div className="row" role="tablist" style={{ gap: 8 }}>
            <button role="tab" aria-selected={tab === "testnet"} className={`btn ${tab === "testnet" ? "btn--primary" : "btn--secondary"}`} onClick={() => setTab("testnet")}>Testnets, live</button>
            <button role="tab" aria-selected={tab === "mainnet"} className={`btn ${tab === "mainnet" ? "btn--primary" : "btn--secondary"}`} onClick={() => setTab("mainnet")}>Mainnets, ready</button>
          </div>
        }
      />
      {tab === "testnet" ? (
        <div className="grid">
          <div className="card span-5"><div className="card__label"><span className="label">CCIP lanes, CCIP-BnM</span></div><LaneMap /></div>
          <div className="card span-7" style={{ paddingTop: 8 }}>
            <table className="table">
              <thead><tr><th>Chain</th><th>Hook</th><th>Routes</th><th>RMN</th><th>Dispatcher ETH</th><th>Receiver ETH</th></tr></thead>
              <tbody>{CHAINS.filter((c) => c.deployment).map((c) => <Row key={c.id} c={c} />)}</tbody>
            </table>
          </div>
        </div>
      ) : (
        <div className="card" style={{ paddingTop: 8 }}>
          <p className="small muted" style={{ padding: "16px 0" }}>Rehearsed on forks of each chain with the real Uniswap v4 and CCIP contracts. Not deployed: deploying needs a funded deployer. RMN state is as of registry generation.</p>
          <table className="table">
            <thead><tr><th>Chain</th><th>Can send</th><th>RMN at generation</th><th>USDC lanes</th><th>Trading API</th></tr></thead>
            <tbody>
              {mn.sort((a, b) => Number(b.source) - Number(a.source)).map((c) => (
                <tr key={c.chainId}>
                  <td><span className="route"><ProtocolLogo name={c.key} />{c.name}</span></td>
                  <td>{c.source ? <Chip tone="ok">Yes</Chip> : <span className="small muted">{c.excludedBecause ?? "No USDC lane"}</span>}</td>
                  <td>{c.cursed ? <Chip tone="bad">Cursed</Chip> : <Chip tone="ok">Clear</Chip>}</td>
                  <td>{c.payoutLanes.length}</td>
                  <td>{c.tradingApi ? "Yes" : "No"}</td>
                </tr>
              ))}
            </tbody>
          </table>
          <div style={{ padding: "16px 0" }}><ExtLink href="https://docs.chain.link/ccip/directory/mainnet">Chainlink CCIP directory</ExtLink></div>
        </div>
      )}
    </>
  );
}
