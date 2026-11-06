import { useEffect, useRef, useState, type ReactNode } from "react";
import { Link, NavLink, Outlet, useLocation } from "react-router-dom";
import { useAccount, useConnect, useDisconnect } from "wagmi";
import { CHAINS, chainById } from "../lib/chains";
import { useApp } from "../lib/app";
import { short } from "../lib/format";
import { Icon, Logo, ProtocolLogo } from "./ui";

function ChainSwitch() {
  const { chainId, setChainId } = useApp();
  const [open, setOpen] = useState(false);
  const ref = useRef<HTMLDivElement>(null);
  useEffect(() => {
    const off = (e: MouseEvent) => { if (!ref.current?.contains(e.target as Node)) setOpen(false); };
    document.addEventListener("click", off);
    return () => document.removeEventListener("click", off);
  }, []);
  const cur = chainById(chainId);
  return (
    <div className="chainsw" ref={ref}>
      <button className="chainsw__btn" aria-haspopup="listbox" aria-expanded={open} onClick={() => setOpen(!open)}>
        {cur && <ProtocolLogo name={cur.logo} />}
        <span>{cur?.short}</span>
        <Icon name="caret-down" size="sm" />
      </button>
      {open && (
        <ul className="chainsw__menu" role="listbox">
          {CHAINS.filter((c) => c.deployment).map((c) => (
            <li key={c.id}>
              <button role="option" aria-selected={c.id === chainId} onClick={() => { setChainId(c.id); setOpen(false); }}>
                <ProtocolLogo name={c.logo} />
                <span>{c.name}</span>
                {c.id === chainId && <Icon name="check" size="sm" />}
              </button>
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}

export function WalletButton() {
  const { address, isConnected } = useAccount();
  const { connect, connectors, isPending } = useConnect();
  const { disconnect } = useDisconnect();
  if (isConnected) {
    return (
      <button className="btn btn--secondary" onClick={() => disconnect()} title="Disconnect">
        <Icon name="wallet" size="sm" />
        <span className="mono">{short(address, 6, 4)}</span>
      </button>
    );
  }
  const inj = connectors[0];
  return (
    <button className="btn btn--secondary" disabled={!inj || isPending} onClick={() => inj && connect({ connector: inj })}>
      <Icon name="wallet" size="sm" />
      {isPending ? "Connecting" : "Connect wallet"}
    </button>
  );
}

export function GradeToggle() {
  const { grade, setGrade } = useApp();
  const next = grade === "evening" ? "day" : "evening";
  return (
    <button className="icon-btn" onClick={() => setGrade(next)} aria-label={`Switch to ${next}`} title={`Switch to ${next}`}>
      <Icon name={grade === "evening" ? "sun" : "moon"} />
    </button>
  );
}

const NAV = [
  ["/app", "Overview"],
  ["/app/milestones", "Milestones"],
  ["/app/grants", "Grants"],
  ["/app/network", "Network"],
  ["/app/pool", "Pool"],
  ["/app/roles", "Roles"],
  ["/app/ens", "ENS"],
] as const;

export function AppBar() {
  const [sheet, setSheet] = useState(false);
  const loc = useLocation();
  useEffect(() => setSheet(false), [loc.pathname]);
  return (
    <header className="bar">
      <div className="wrap bar__in">
        <a className="skip" href="#main">Skip to content</a>
        <Link to="/" className="bar__logo" aria-label="nidhi home"><Logo height={26} /></Link>
        <ChainSwitch />
        <nav className="bar__nav" aria-label="Main">
          {NAV.map(([to, label]) => (
            <NavLink key={to} to={to} end={to === "/app"} className={({ isActive }) => (isActive ? "is-on" : "")}>{label}</NavLink>
          ))}
        </nav>
        <div className="bar__end">
          <GradeToggle />
          <WalletButton />
          <Link to="/app/new" className="btn btn--primary bar__cta"><Icon name="plus" size="sm" />New grant</Link>
          <button className="icon-btn bar__menu" aria-label="Menu" aria-expanded={sheet} onClick={() => setSheet(!sheet)}><Icon name={sheet ? "x" : "list"} /></button>
        </div>
      </div>
      {sheet && (
        <div className="sheet" onClick={() => setSheet(false)}>
          {NAV.map(([to, label]) => <NavLink key={to} to={to} end={to === "/app"}>{label}</NavLink>)}
          <NavLink to="/app/settings">Settings</NavLink>
        </div>
      )}
    </header>
  );
}

export function Footer() {
  return (
    <footer className="foot">
      <div className="wrap foot__in">
        <div className="stack foot__brand">
          <Logo height={30} />
          <p className="muted small measure">Nidhi means treasury in Sanskrit. DAO grants paid on the contributor's chain, only after the work is checked.</p>
        </div>
        <div className="foot__cols">
          <div className="stack small"><p className="label">Product</p><Link className="link" to="/app">Open the app</Link><Link className="link" to="/app/milestones">Milestones</Link><Link className="link" to="/app/grants">Live grants</Link></div>
          <div className="stack small"><p className="label">Build</p><a className="link" href="https://github.com/neevmodh/nidhi" target="_blank" rel="noreferrer">GitHub</a><a className="link" href="https://github.com/neevmodh/nidhi/tree/main/docs/architecture" target="_blank" rel="noreferrer">Architecture</a><a className="link" href="https://github.com/neevmodh/nidhi/blob/main/docs/faq.md" target="_blank" rel="noreferrer">FAQ</a></div>
          <div className="stack small"><p className="label">Built on</p>
            <a className="foot__proto" href="https://docs.uniswap.org/contracts/v4/overview" target="_blank" rel="noreferrer"><ProtocolLogo name="uniswap" />Uniswap v4</a>
            <a className="foot__proto" href="https://docs.chain.link/ccip" target="_blank" rel="noreferrer"><ProtocolLogo name="chainlink" />Chainlink CCIP</a>
            <a className="foot__proto" href="https://docs.ens.domains" target="_blank" rel="noreferrer"><ProtocolLogo name="ens" />ENS</a>
          </div>
        </div>
      </div>
      <div className="wrap foot__legal small muted">
        <span>nidhi {new Date().getFullYear()} · built at ETHGlobal Mumbai</span>
        <span>Testnet deployment. Product names and logos are trademarks of their owners.</span>
      </div>
    </footer>
  );
}

export function AppLayout() {
  const { pathname } = useLocation();
  const landing = pathname === "/";
  return (
    <>
      <AppBar />
      {landing
        ? <main id="main" className="landing"><Outlet /></main>
        : <main id="main" className="page"><div className="wrap"><Outlet /></div></main>}
      <Footer />
      <nav className="actionbar"><Link to="/app/new" className="btn btn--primary btn--block"><Icon name="plus" size="sm" />New grant</Link></nav>
    </>
  );
}

export function PageHead({ title, sub, action }: { title: ReactNode; sub?: ReactNode; action?: ReactNode }) {
  return (
    <div className="page-head">
      <div>
        <h1 className="h2">{title}</h1>
        {sub && <p className="muted" style={{ marginTop: 12 }}>{sub}</p>}
      </div>
      {action}
    </div>
  );
}
