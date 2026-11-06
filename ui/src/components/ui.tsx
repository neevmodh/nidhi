import { useState, type ReactNode } from "react";
import { Link } from "react-router-dom";
import { logos } from "../data/logos";
import { logoSvg, markSvg } from "../data/brand";
import { chainById, type ChainInfo } from "../lib/chains";
import { short } from "../lib/format";
import type { Status } from "../lib/grants";

const base = import.meta.env.BASE_URL;

/** Phosphor glyph from the sprite. Decorative unless a label is given. */
export function Icon({ name, size = "md", label }: { name: string; size?: "sm" | "md" | "lg"; label?: string }) {
  return (
    <svg className={`ic ic--${size}`} aria-hidden={label ? undefined : true} role={label ? "img" : undefined} aria-label={label}>
      <use href={`${base}icons.svg#${name}`} />
    </svg>
  );
}

export function Logo({ height = 28 }: { height?: number }) {
  return <span className="logo-mark" style={{ height, width: height * 3.2 }} aria-label="nidhi" role="img" dangerouslySetInnerHTML={{ __html: logoSvg }} />;
}
export function Mark({ size = 24 }: { size?: number }) {
  return <span className="logo-mark" style={{ width: size, height: size }} aria-hidden dangerouslySetInnerHTML={{ __html: markSvg }} />;
}

/** official brand SVG in its own colours (web3icons); trademarks of their owners */
export function ProtocolLogo({ name, size, title }: { name: string; size?: "lg"; title?: string }) {
  const svg = logos[name];
  if (!svg) return null;
  return <span className={`plogo ${size === "lg" ? "plogo--lg" : ""}`} title={title} aria-label={title} role={title ? "img" : undefined} aria-hidden={title ? undefined : true} dangerouslySetInnerHTML={{ __html: svg }} />;
}

export function ChainName({ chain, full }: { chain?: ChainInfo; full?: boolean }) {
  if (!chain) return <span className="muted">Unknown chain</span>;
  return (
    <span className="route">
      <ProtocolLogo name={chain.logo} />
      <span>{full ? chain.name : chain.short}</span>
    </span>
  );
}

export function Route({ from, to }: { from?: ChainInfo; to?: ChainInfo }) {
  return (
    <span className="route">
      <ChainName chain={from} />
      <Icon name="arrow-right" size="sm" />
      <ChainName chain={to} />
    </span>
  );
}

// status chip: earth colour + its own SVG shape, so the state never relies on colour alone
const SHAPES = {
  ok: <svg viewBox="0 0 10 10"><circle cx="5" cy="5" r="5" fill="currentColor" /></svg>,
  flight: <svg viewBox="0 0 10 10"><circle cx="5" cy="5" r="4.25" fill="none" stroke="currentColor" strokeWidth="1.5" /><path d="M5 .75a4.25 4.25 0 0 1 0 8.5z" fill="currentColor" /></svg>,
  warn: <svg viewBox="0 0 10 10"><path d="M5 .6 9.6 9.2H.4z" fill="currentColor" /></svg>,
  bad: <svg viewBox="0 0 10 10"><path d="M1.5 1.5l7 7m0-7-7 7" stroke="currentColor" strokeWidth="2" strokeLinecap="round" /></svg>,
  idle: <svg viewBox="0 0 10 10"><circle cx="5" cy="5" r="4.25" fill="none" stroke="currentColor" strokeWidth="1.5" /></svg>,
};
export function Chip({ tone, children }: { tone: keyof typeof SHAPES; children: ReactNode }) {
  return <span className={`chip chip--${tone}`}>{SHAPES[tone]}<span>{children}</span></span>;
}
export function StatusChip({ status }: { status: Status }) {
  if (status === 3) return <Chip tone="ok">Settled</Chip>;
  if (status === 2) return <Chip tone="warn">Held</Chip>;
  if (status === 1) return <Chip tone="flight">In flight</Chip>;
  return <Chip tone="idle">Not sent</Chip>;
}

/** 4-segment progress: swapped, sent, paid, receipt */
export function Steps({ status, paid }: { status: Status; paid?: boolean }) {
  const n = status === 3 ? 4 : status === 2 ? 3 : status === 1 ? (paid ? 3 : 2) : 0;
  return (
    <span className="steps" aria-label={`${n} of 4 steps done`}>
      {[0, 1, 2, 3].map((i) => <i key={i} data-on={i < n && !(status === 2 && i === 2) ? "" : undefined} data-held={status === 2 && i === 2 ? "" : undefined} />)}
    </span>
  );
}

export function Copy({ value }: { value: string }) {
  const [done, setDone] = useState(false);
  return (
    <button className="icon-btn" aria-label={done ? "Copied" : "Copy"} onClick={() => { navigator.clipboard?.writeText(value).then(() => { setDone(true); setTimeout(() => setDone(false), 1400); }); }}>
      <Icon name={done ? "check" : "copy"} size="sm" />
    </button>
  );
}

/** a hash or address: mono, shortened, copyable, optionally linked to the explorer */
export function Hash({ value, href, n = 6 }: { value?: string; href?: string; n?: number }) {
  if (!value) return <span className="muted">Not yet</span>;
  return (
    <span className="row" style={{ gap: 4, display: "inline-flex" }}>
      {href ? <a className="mono link" href={href} target="_blank" rel="noreferrer">{short(value, n, 4)}</a> : <span className="mono">{short(value, n, 4)}</span>}
      <Copy value={value} />
    </span>
  );
}

export function ExtLink({ href, children }: { href: string; children: ReactNode }) {
  return (
    <a className="link row" style={{ display: "inline-flex", gap: 4 }} href={href} target="_blank" rel="noreferrer">
      {children}
      <Icon name="arrow-up-right" size="sm" />
    </a>
  );
}

export function Empty({ title, action }: { title: string; action?: ReactNode }) {
  return (
    <div className="empty">
      <Mark size={40} />
      <p>{title}</p>
      {action}
    </div>
  );
}

export function Skel({ w = 96 }: { w?: number }) {
  return <span className="skel" style={{ width: w }} aria-hidden />;
}

export function ErrorNote({ text, raw }: { text: string; raw?: string }) {
  const [open, setOpen] = useState(false);
  return (
    <div className="note note--bad" role="alert">
      <span style={{ color: "var(--bad)" }}><Icon name="warning" /></span>
      <div className="stack" style={{ flex: 1 }}>
        <p>{text}</p>
        {raw && (
          <>
            <button className="link small" style={{ background: "none", border: 0, padding: 0, cursor: "pointer" }} onClick={() => setOpen(!open)}>{open ? "Hide details" : "Show details"}</button>
            {open && <p className="mono small muted" style={{ overflowWrap: "anywhere" }}>{raw}</p>}
          </>
        )}
      </div>
    </div>
  );
}

export const chainLink = (id: number, path: string) => `/app/${path}/${chainById(id)?.key ?? id}`;
export { Link };
