import { useEffect, useRef, useState, type ReactNode } from "react";
import { Link } from "react-router-dom";
import { useGrants } from "../lib/grants";
import { Icon, Mark, ProtocolLogo, Skel } from "../components/ui";

const REPO = "https://github.com/neevmodh/nidhi";

/** alice's ENS avatar: a drawn illustration, not a photo of a real person */
function Avatar({ size = 48, id }: { size?: number; id: string }) {
  return (
    <svg width={size} height={size} viewBox="0 0 64 64" role="img" aria-label="alice's avatar" className="lp-avatar__img">
      <defs>
        <linearGradient id={id} x1="0" y1="0" x2="1" y2="1">
          <stop offset="0" stopColor="#D6E8FF" />
          <stop offset="1" stopColor="#5298FF" />
        </linearGradient>
      </defs>
      <rect width="64" height="64" fill={`url(#${id})`} />
      <path d="M9 64c2-12 11-19 23-19s21 7 23 19z" fill="#1F4FA8" />
      <path d="M26 43h12v6c-2 2.4-4 3.4-6 3.4s-4-1-6-3.4z" fill="#E9BC96" />
      <path d="M20.5 30c-1.2 7 .8 13 3.4 16 .2-5-.6-10 1.2-15zM43.5 30c1.2 7-.8 13-3.4 16-.2-5 .6-10-1.2-15z" fill="#2B2420" />
      <circle cx="32" cy="30" r="11" fill="#F7D6B8" />
      <path d="M20.5 30c0-8.5 5-14 11.5-14s11.5 5.5 11.5 14c-2.2-4.2-6.2-6.6-11.5-7-4.6.5-9.2 2.6-11.5 7z" fill="#2B2420" />
      <circle cx="28" cy="31" r="1.1" fill="#2B2420" />
      <circle cx="36" cy="31" r="1.1" fill="#2B2420" />
      <path d="M29.3 35.2c1.6 1.3 3.8 1.3 5.4 0" fill="none" stroke="#B5703F" strokeWidth="1.2" strokeLinecap="round" />
    </svg>
  );
}

function EnsBadge() {
  return <span className="lp-badge"><ProtocolLogo name="ens" /></span>;
}

/** an ENS name: bold label, softer parent */
function EnsName({ label, parent }: { label: string; parent: string }) {
  return <span className="lp-ensname">{label}<span>{parent}</span></span>;
}

function ChainChip({ logo, children }: { logo: string; children: ReactNode }) {
  return <span className="lp-chainchip"><ProtocolLogo name={logo} />{children}</span>;
}

const SLIDES = [
  {
    key: "ens", name: "ENS", logo: "ens", eyebrow: "01 · Identity and permission",
    title: "ENS decides who may approve, and who gets paid.",
    points: [
      "Approver, auditor and guardian are roles on the DAO's name, read live on every grant.",
      <>A grantee is a name like <span className="lp-enschip"><ProtocolLogo name="ens" />alice.nidhi-dao.eth</span> that holds an address on each chain.</>,
      "Revoke a role or let a name expire, and payments stop at once. No contract upgrade.",
    ],
  },
  {
    key: "uni", name: "Uniswap", logo: "uniswap", eyebrow: "02 · Enforcement",
    title: "The Uniswap v4 hook won't swap until every rule passes.",
    points: [
      "Two different people must sign: an approver and an auditor.",
      "The amount has to fit the daily cap and the price band quoted by V4Quoter.",
      "The hook keeps the swap output itself and hands it straight to Chainlink. It never sits in a wallet.",
    ],
  },
  {
    key: "link", name: "Chainlink", logo: "chainlink", eyebrow: "03 · Delivery",
    title: "Chainlink CCIP pays on their chain and sends a receipt back.",
    points: [
      "CCIP 2.0 waits 32 blocks instead of full finality, so money lands in about 7 minutes.",
      "A receipt travels back, so the DAO sees the grant settled on its own chain.",
      "If a payout fails, it's held safely and can be retried. Nothing is lost.",
    ],
  },
] as const;

function SlideVisual({ k }: { k: string }) {
  if (k === "ens") {
    return (
      <div className="lp-profile">
        <div className="lp-profile__banner"><span className="lp-profile__tag"><ProtocolLogo name="ens" />ENS name</span></div>
        <div className="lp-profile__body">
          <div className="lp-avatar lp-avatar--lg"><span className="lp-avatar__ring"><Avatar size={76} id="av-card" /></span><EnsBadge /></div>
          <p className="lp-profile__name">alice.nidhi-dao.eth <ProtocolLogo name="ens" /></p>
          <span className="lp-enschip lp-enschip--sub"><ProtocolLogo name="ens" />subname of nidhi-dao.eth</span>
          <div className="lp-records">
            <div><span><ProtocolLogo name="arbitrum" />Arbitrum</span><span className="mono">0x9f75…b9C7</span></div>
            <div><span><ProtocolLogo name="base" />Base</span><span className="mono">0x9f75…b9C7</span></div>
          </div>
          <div className="lp-roles">
            <span className="small muted">Roles on nidhi-dao.eth</span>
            <span className="lp-pill lp-pill--ok">approver</span>
            <span className="lp-pill lp-pill--ok">auditor</span>
            <span className="lp-pill">guardian</span>
          </div>
        </div>
      </div>
    );
  }
  if (k === "uni") {
    const checks = [["Approver signature", "passed"], ["Auditor signature", "passed"], ["Daily cap", "within limit"], ["Price band", "0.25 – 0.31 BnM"]];
    return (
      <div className="lp-visual">
        <p className="small muted">Inside the swap, before anything moves</p>
        <div className="lp-checks">
          {checks.map(([a, b]) => <div key={a}><span>{a}</span><span className="lp-ok"><Icon name="check" size="sm" />{b}</span></div>)}
        </div>
        <div className="lp-swapbar"><ProtocolLogo name="uniswap" />Swap 0.0003 WETH → 0.28 CCIP-BnM</div>
      </div>
    );
  }
  return (
    <div className="lp-visual">
      <div className="lp-lane">
        <ChainChip logo="ethereum">Sepolia</ChainChip>
        <span className="lp-wire"><i className="lp-dot lp-dot--blue" /></span>
        <ChainChip logo="arbitrum">Arbitrum</ChainChip>
      </div>
      <div className="lp-twin">
        <div><p className="small muted">Paid to alice</p><p className="lp-big">7m 15s</p></div>
        <div><p className="small muted">Before CCIP 2.0</p><p className="lp-big muted">15–25 min</p></div>
      </div>
      <div className="lp-okbar">Receipt back on Sepolia · grant Settled</div>
    </div>
  );
}

function Slides() {
  const [i, setI] = useState(0);
  const [paused, setPaused] = useState(false);
  useEffect(() => {
    if (paused) return;
    const t = setInterval(() => setI((x) => (x + 1) % SLIDES.length), 7000);
    return () => clearInterval(t);
  }, [paused]);
  const s = SLIDES[i];
  const go = (n: number) => { setI((n + SLIDES.length) % SLIDES.length); setPaused(true); };
  return (
    <div onMouseEnter={() => setPaused(true)} onMouseLeave={() => setPaused(false)}>
      <div className="lp-tabs" role="tablist" aria-label="What each protocol does">
        {SLIDES.map((x, n) => (
          <button key={x.key} role="tab" aria-selected={n === i} className={n === i ? "is-on" : ""} onClick={() => go(n)}>
            <ProtocolLogo name={x.logo} />{x.name}
          </button>
        ))}
      </div>
      <div className="lp-slide" key={s.key} role="tabpanel">
        <div className="lp-slide__text">
          <p className="lp-eyebrow"><ProtocolLogo name={s.logo} size="lg" />{s.eyebrow}</p>
          <h3 className="h3">{s.title}</h3>
          <ul>{s.points.map((p, n) => <li key={n}>{p}</li>)}</ul>
        </div>
        <SlideVisual k={s.key} />
      </div>
      <div className="lp-slidenav">
        <div className="lp-dots" aria-hidden>{SLIDES.map((x, n) => <i key={x.key} className={n === i ? "is-on" : ""} />)}</div>
        <div className="row">
          <button className="lp-arrow" aria-label="Previous slide" onClick={() => go(i - 1)}><Icon name="caret-left" /></button>
          <button className="lp-arrow lp-arrow--dark" aria-label="Next slide" onClick={() => go(i + 1)}><Icon name="caret-right" /></button>
        </div>
      </div>
    </div>
  );
}

const STEPS = [
  { tag: "Commit", logo: "", title: "The work is committed", short: "A developer merges PR #13, tagged [b2], with CI green.", detail: "The developer does the job and merges a pull request whose title carries the milestone id.", proof: "PR #13 · docs/faq.md · merged" },
  { tag: "Grant", logo: "ethereum", title: "The DAO had already committed", short: "Milestone b2 was posted on-chain: 0.0003 WETH to alice.nidhi-dao.eth.", detail: "Before any work, the DAO posted the task on-chain with its amount, chain and rules, signed by an approver.", proof: "b2 · on the milestone board, Sepolia" },
  { tag: "Check · ENS", logo: "ens", title: "The agent checks the work", short: "Merged, CI green, right files. It signs as auditor, a role it holds on nidhi-dao.eth.", detail: "The agent compares the PR against the committed rules, then signs. ENS confirms the approver and auditor really hold their roles.", proof: "auditor.nidhi-dao.eth signed" },
  { tag: "Swap · Uniswap v4", logo: "uniswap", title: "The hook swaps, only if every rule passes", short: "Two signatures, daily cap and price band checked, then WETH becomes CCIP-BnM.", detail: "Inside the swap, the v4 hook verifies both signatures, the cap and the quoted price band, and keeps the output for delivery.", proof: "0.0003 WETH → 0.28 BnM" },
  { tag: "Bridge · Chainlink CCIP", logo: "chainlink", title: "CCIP carries it across", short: "From Sepolia to Arbitrum after 32 blocks, not full finality.", detail: "A programmable token transfer moves the tokens plus the grant details. CCIP 2.0 waits 32 blocks, about 6 minutes.", proof: "Sepolia → Arbitrum · 32 blocks" },
  { tag: "Paid", logo: "arbitrum", title: "alice is paid, the DAO gets a receipt", short: "The receiver pays alice and sends a receipt home. The grant shows Settled.", detail: "On Arbitrum the receiver pays the address alice.nidhi-dao.eth resolves to, then a receipt returns to Sepolia.", proof: "+0.28 BnM · 7m 15s · Settled" },
];

function Flow() {
  const [step, setStep] = useState(0);
  const refs = useRef<(HTMLLIElement | null)[]>([]);
  useEffect(() => {
    const io = new IntersectionObserver((entries) => {
      entries.forEach((e) => { if (e.isIntersecting) setStep(Number((e.target as HTMLElement).dataset.i)); });
    }, { rootMargin: "-45% 0px -50% 0px" });
    refs.current.forEach((el) => el && io.observe(el));
    return () => io.disconnect();
  }, []);
  const cur = STEPS[step];
  return (
    <div className="lp-flow">
      <div className="lp-flow__pin">
        <div className="lp-flow__card">
          <div className="row row--between"><span className="small lp-dim">Step {step + 1} of {STEPS.length}</span><span className="lp-flow__tag">{cur.logo && <span className="lp-flow__logo"><ProtocolLogo name={cur.logo} /></span>}{cur.tag}</span></div>
          <p className="lp-flow__title">{cur.title}</p>
          <p className="lp-flow__detail">{cur.detail}</p>
          <p className="lp-flow__proof mono">{cur.proof}</p>
          <div className="lp-flow__bar"><i style={{ width: `${((step + 1) / STEPS.length) * 100}%` }} /></div>
        </div>
      </div>
      <ol className="lp-flow__list" style={{ ["--fill" as string]: step / (STEPS.length - 1) }}>
        {STEPS.map((s, n) => (
          <li key={s.tag} ref={(el) => { refs.current[n] = el; }} data-i={n} data-state={n < step ? "done" : n === step ? "on" : "todo"}>
            <span className="lp-flow__dot">{n < step ? <Icon name="check" size="sm" /> : n + 1}</span>
            <div className="lp-flow__item">
              <p className="lp-flow__itemtag">{s.logo && <span className="lp-flow__logo"><ProtocolLogo name={s.logo} /></span>}{s.tag}</p>
              <p className="lp-flow__itemtitle">{s.title}</p>
              <p className="lp-flow__itemshort">{s.short}</p>
            </div>
          </li>
        ))}
      </ol>
    </div>
  );
}

export default function Landing() {
  const { data } = useGrants();
  const grants = data?.grants ?? [];
  const settled = grants.filter((g) => g.status === 3).length;
  return (
    <div className="lp">
      {/* 1. hero: one line, two places connected */}
      <section className="lp-hero">
        <div className="wrap lp-hero__in">
          <span className="lp-live"><i />Live on Sepolia, Base, Arbitrum and Unichain testnets</span>
          <h1 className="h1 lp-hero__title">The work ships here.<br />The money lands there.</h1>
          <p className="lead lp-hero__lead">Nidhi pays DAO contributors on their own chain, and only after the work is checked. Two signatures, one Uniswap swap, one Chainlink delivery. About 7 minutes.</p>
          <div className="btn-row lp-hero__cta">
            <Link to="/app/new" className="btn btn--primary btn--lg">Send a test grant</Link>
            <a href="#flow" className="btn btn--secondary btn--lg">See how it moves</a>
          </div>

          <div className="lp-connect" aria-label="A grant moving from nidhi-dao.eth on Sepolia, through the Uniswap v4 hook and Chainlink CCIP, to alice.nidhi-dao.eth on Arbitrum">
            <div className="lp-node">
              <div className="lp-node__head">
                <span className="lp-avatar"><span className="lp-dao"><Mark size={28} /></span><EnsBadge /></span>
                <span className="lp-node__who"><EnsName label="nidhi-dao" parent=".eth" /><ChainChip logo="ethereum">Sepolia<em>·</em>DAO treasury</ChainChip></span>
              </div>
              <p className="lp-node__note">Milestone b2 approved · <b>0.0003 WETH</b></p>
            </div>
            <span className="lp-wire"><i className="lp-dot" /></span>
            <div className="lp-proto"><ProtocolLogo name="uniswap" size="lg" /><span><b>Uniswap v4 hook</b><small>checks, then swaps</small></span></div>
            <span className="lp-wire"><i className="lp-dot" style={{ animationDelay: ".9s" }} /></span>
            <div className="lp-proto"><ProtocolLogo name="chainlink" size="lg" /><span><b>Chainlink CCIP</b><small>crosses chains</small></span></div>
            <span className="lp-wire"><i className="lp-dot" style={{ animationDelay: "1.8s" }} /></span>
            <div className="lp-node lp-node--late">
              <div className="lp-node__head">
                <span className="lp-avatar"><span className="lp-avatar__ring lp-avatar__ring--sm"><Avatar size={48} id="av-hero" /></span><EnsBadge /></span>
                <span className="lp-node__who"><EnsName label="alice" parent=".nidhi-dao.eth" /><ChainChip logo="arbitrum">Arbitrum<em>·</em><span className="mono">0x9f75…b9C7</span></ChainChip></span>
              </div>
              <p className="lp-node__note lp-node__note--ok">+ 0.28 BnM received · 7 min</p>
            </div>
          </div>
        </div>
      </section>

      {/* built on */}
      <section className="wrap lp-strip" aria-label="Built on">
        <div className="lp-strip__group">
          <span className="lp-strip__label">Built on</span>
          <span><ProtocolLogo name="uniswap" size="lg" />Uniswap v4</span>
          <span><ProtocolLogo name="chainlink" size="lg" />Chainlink CCIP</span>
          <span><ProtocolLogo name="ens" size="lg" />ENS</span>
        </div>
        <div className="lp-strip__group">
          <span className="lp-strip__label">Pays on</span>
          {[["ethereum", "Ethereum Sepolia"], ["base", "Base Sepolia"], ["arbitrum", "Arbitrum Sepolia"], ["unichain", "Unichain Sepolia"]].map(([l, t]) => <ProtocolLogo key={l} name={l} size="lg" title={t} />)}
        </div>
      </section>

      {/* 2. why: three slides */}
      <section id="why" className="lp-why">
        <div className="wrap">
          <p className="lp-kicker">Why Nidhi</p>
          <h2 className="h2 lp-measure">Today a DAO pays on trust and bridges by hand. Nidhi makes three protocols do the checking.</h2>
          <Slides />
        </div>
      </section>

      {/* 3. real work */}
      <section id="work" className="wrap lp-work">
        <div>
          <p className="lp-kicker">For real work</p>
          <h2 className="h2">A merged PR is the proof. The payout follows on its own.</h2>
          <p className="lead muted lp-work__lead">The DAO posts a milestone. A developer opens a pull request with its id. When it's merged and CI is green, the Nidhi agent checks the rules, signs as auditor and sends the grant. Nobody has to chase a payment.</p>
          <div className="lp-pills">
            <span>Open bounties: first merge wins</span>
            <span>Contributors get a name.nidhi-dao.eth</span>
          </div>
          <Link to="/app/milestones" className="btn btn--secondary" style={{ marginTop: 28 }}>See open milestones <Icon name="arrow-right" size="sm" /></Link>
        </div>
        <div className="lp-scene" role="img" aria-label="A code editor, a merged pull request and a payment notification">
          <div className="lp-editor">
            <div className="lp-editor__bar"><i /><i /><i /><span className="mono">docs/faq.md</span></div>
            <div className="lp-editor__code">
              {[46, 70, 58, 34, 76, 52, 40, 64].map((w, n) => (
                <div key={n}><span>{n + 1}</span><i className={n === 0 ? "is-gold" : n === 3 ? "is-blue" : n === 6 ? "is-green" : ""} style={{ ["--w" as string]: `${w}%`, animationDelay: `${n * 0.3}s` }} /></div>
              ))}
            </div>
          </div>
          <div className="lp-pr">
            <p><span className="lp-merged">Merged</span><b>[b2] Add a FAQ about faster CCIP payments</b></p>
            <div className="lp-pr__chips"><span className="lp-pill lp-pill--ok">CI green</span><span className="lp-pill lp-pill--ok">touches docs/**</span><span className="lp-pill lp-pill--gold">agent verified</span></div>
          </div>
          <div className="lp-toast">
            <span className="lp-toast__icon"><Icon name="check" /></span>
            <span><b className="lp-toast__who"><ProtocolLogo name="ens" />alice.nidhi-dao.eth</b><small>received 0.28 BnM on <ProtocolLogo name="arbitrum" />Arbitrum</small></span>
          </div>
        </div>
      </section>

      {/* 4. one grant, lighting up as you scroll */}
      <section id="flow" className="lp-dark">
        <div className="wrap">
          <p className="lp-kicker lp-kicker--gold">How a grant moves</p>
          <h2 className="h2 lp-measure">Follow one grant, from commit to paid.</h2>
          <p className="lp-dim lp-sub">Scroll, and each step lights up as it happens.</p>
          <Flow />
        </div>
      </section>

      {/* proof + close */}
      <section className="wrap lp-close">
        <div className="lp-proof">
          <div><p className="fig">6m 36s</p><p className="small muted">fastest live payout</p></div>
          <div><p className="fig">4</p><p className="small muted">testnets live</p></div>
          <div><p className="fig">{data ? settled : <Skel w={40} />}</p><p className="small muted">grants settled on testnet</p></div>
          <div><p className="fig">137</p><p className="small muted">contract tests</p></div>
        </div>
        <div className="lp-cta">
          <div>
            <h2 className="h3">Pay for work, not for promises.</h2>
            <p className="muted">Try the full flow on testnet in under ten minutes.</p>
          </div>
          <div className="btn-row">
            <Link to="/app" className="btn btn--primary btn--lg">Open the app</Link>
            <a href={REPO} target="_blank" rel="noreferrer" className="btn btn--secondary btn--lg">Read the code</a>
          </div>
        </div>
      </section>
    </div>
  );
}
