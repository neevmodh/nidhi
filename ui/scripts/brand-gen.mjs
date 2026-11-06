import opentype from "opentype.js";
import fs from "node:fs";
const font = opentype.loadSync("fraunces.ttf");
const out = process.argv[2] || "out"; fs.mkdirSync(out, { recursive: true });

// ---- the mark, 24-unit grid -------------------------------------------------
const FLAME = "M12.6 1.6C14.35 3.15 14.7 4.95 13.55 6.0C12.95 6.55 12.0 6.6 11.35 6.05C10.35 5.2 10.55 3.45 12.6 1.6Z";
const VESSEL = "M8.4 8.2H15.6M9.95 8.2C9.95 9.25 10.2 9.8 10.45 10.15C6.5 11.0 4.45 13.55 4.45 16.35C4.45 18.35 5.35 19.9 6.85 20.95H17.15C18.65 19.9 19.55 18.35 19.55 16.35C19.55 13.55 17.5 11.0 13.55 10.15C13.8 9.8 14.05 9.25 14.05 8.2";
const ARCS3 = "M8.6 15.15C10.85 15.95 13.15 15.95 15.4 15.15M7.75 17.95C10.55 18.95 13.45 18.95 16.25 17.95";
const ARCS1 = "M8.1 16.9C10.7 17.85 13.3 17.85 15.9 16.9"; // small sizes: one resting arc

function mark({ ink, flame, arcs = ARCS3, sw = 1.75 }) {
  return `<path d="${FLAME}" fill="${flame}"/>` +
    `<g fill="none" stroke="${ink}" stroke-width="${sw}" stroke-linecap="round" stroke-linejoin="round"><path d="${VESSEL}"/><path d="${arcs}" stroke-width="${(sw * 0.86).toFixed(2)}"/></g>`;
}
const svg = (vb, body, title) => `<svg xmlns="http://www.w3.org/2000/svg" viewBox="${vb}" role="img" aria-label="${title}"><title>${title}</title>${body}</svg>\n`;

// ---- the wordmark: real Fraunces outlines (opsz 72, SOFT 100, wght 400) -------
const SIZE = 100, track = -0.02 * SIZE;
function word(withFlame) {
  const chars = withFlame ? ["n", "i", "d", "h", "ı"] : ["n", "i", "d", "h", "i"];
  let x = 0; const parts = []; let lastI = null;
  for (const ch of chars) {
    const g = font.charToGlyph(ch);
    const p = g.getPath(x, 0, SIZE);
    parts.push(p.toPathData(2));
    if (ch === "ı") lastI = { x, adv: g.advanceWidth * SIZE / font.unitsPerEm, bb: g.getBoundingBox() };
    x += g.advanceWidth * SIZE / font.unitsPerEm + track;
  }
  const width = x - track;
  return { d: parts.join(""), width, lastI };
}
const xHeight = (font.tables.os2.sxHeight || 480) * SIZE / font.unitsPerEm;
const asc = (font.tables.os2.sCapHeight || 700) * SIZE / font.unitsPerEm;

function lockup({ ink, flame, flameDot = true }) {
  const w = word(flameDot);
  const markScale = 120 / 24;           // mark drawn at 128 units tall, on the cap height
  const gap = 30, mx = 0, wx = 120 + gap;
  const base = 104;                     // baseline of the word inside a 140-tall box
  let flameDotSvg = "";
  if (flameDot && w.lastI) {
    // the small flame replaces the dot: same almond, scaled to ~40% of the mark's flame
    const s = (SIZE / 24) * 0.95;
    const stemCx = w.lastI.x + (w.lastI.bb.x1 + w.lastI.bb.x2) / 2 * SIZE / font.unitsPerEm;
    const fx = wx + stemCx - 12.55 * s, fy = base - xHeight - 4 - 6.6 * s;
    flameDotSvg = `<path transform="translate(${fx.toFixed(2)} ${fy.toFixed(2)}) scale(${s.toFixed(3)})" d="${FLAME}" fill="${flame}"/>`;
  }
  const total = wx + w.width + 4;
  const body = `<g transform="translate(${mx} ${(base - 20.95 * markScale).toFixed(2)}) scale(${markScale.toFixed(4)})">${mark({ ink, flame })}</g>` +
    `<path transform="translate(${wx} ${base})" d="${w.d}" fill="${ink}"/>` + flameDotSvg;
  return svg(`0 0 ${total.toFixed(0)} 140`, body, "nidhi");
}

const GOLD = "#C9A45A", DEEPGOLD = "#8C6A2A", BONE = "#F4EFE6", INK = "#1C1610", TILE = "#17130F";
fs.writeFileSync(`${out}/nidhi-mark.svg`, svg("0 0 24 24", mark({ ink: "currentColor", flame: GOLD }), "Nidhi"));
fs.writeFileSync(`${out}/nidhi-mark-gold.svg`, svg("0 0 24 24", mark({ ink: GOLD, flame: GOLD }), "Nidhi"));
fs.writeFileSync(`${out}/nidhi-logo-evening.svg`, lockup({ ink: BONE, flame: GOLD }));
fs.writeFileSync(`${out}/nidhi-logo-day.svg`, lockup({ ink: INK, flame: DEEPGOLD }));
fs.writeFileSync(`${out}/nidhi-logo-plain-dot.svg`, lockup({ ink: BONE, flame: GOLD, flameDot: false }));
fs.writeFileSync(`${out}/nidhi-mono.svg`, lockup({ ink: "currentColor", flame: "currentColor" }));
fs.writeFileSync(`${out}/favicon.svg`, svg("0 0 32 32",
  `<rect width="32" height="32" rx="7" fill="${TILE}"/><g transform="translate(4 3.4) scale(1)">${mark({ ink: GOLD, flame: GOLD, arcs: ARCS1, sw: 2.1 })}</g>`, "Nidhi"));
fs.writeFileSync(`${out}/app-icon.svg`, svg("0 0 512 512",
  `<rect width="512" height="512" rx="102" fill="${TILE}"/><g transform="translate(100 92) scale(13)">${mark({ ink: GOLD, flame: GOLD })}</g>`, "Nidhi"));
console.log("wrote", fs.readdirSync(out).join(" "));
