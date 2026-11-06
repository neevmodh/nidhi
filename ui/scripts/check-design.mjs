// Design gates (CI): no emoji, no violet/lavender colours (OKLCH hue 270-330), no banned fonts.
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const ui = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const roots = ["src", "index.html", "public/brand", "public/favicon.svg"].map((p) => path.join(ui, p));
const skip = /src[\\/]data[\\/]logos\.ts$/; // third-party logos keep their own colours (taste-skill rule)
const files = [];
const walk = (p) => fs.statSync(p).isDirectory() ? fs.readdirSync(p).forEach((f) => walk(path.join(p, f))) : files.push(p);
roots.filter(fs.existsSync).forEach(walk);

const EMOJI = /[\u{1F300}-\u{1FAFF}\u{2600}-\u{27BF}\u{1F000}-\u{1F2FF}\u{FE0F}]/u;
const BANNED = /\b(Inter|Roboto|Open Sans|Lato|Montserrat|Poppins|Space Grotesk|Plus Jakarta Sans)\b/;

function hue(hex) {
  let h = hex.slice(1); if (h.length === 3) h = [...h].map((c) => c + c).join("");
  const [r, g, b] = [0, 2, 4].map((i) => { const v = parseInt(h.slice(i, i + 2), 16) / 255; return v <= 0.04045 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4; });
  const l = Math.cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b);
  const m = Math.cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b);
  const s = Math.cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b);
  const A = 1.9779984951 * l - 2.428592205 * m + 0.4505937099 * s;
  const B = 0.0259040371 * l + 0.7827717662 * m - 0.808675766 * s;
  const C = Math.hypot(A, B);
  return { h: (Math.atan2(B, A) * 180 / Math.PI + 360) % 360, c: C };
}

const fails = [];
for (const f of files) {
  if (skip.test(f) || !/\.(tsx?|css|html|svg|json)$/.test(f)) continue;
  const text = fs.readFileSync(f, "utf8");
  const rel = path.relative(ui, f);
  text.split("\n").forEach((line, i) => {
    if (EMOJI.test(line)) fails.push(`${rel}:${i + 1} emoji`);
    if (BANNED.test(line) && /font|family/i.test(line)) fails.push(`${rel}:${i + 1} banned font`);
    for (const [hex] of line.matchAll(/#[0-9a-fA-F]{6}\b|#[0-9a-fA-F]{3}\b/g)) {
      const { h, c } = hue(hex);
      if (c > 0.03 && h >= 270 && h <= 330) fails.push(`${rel}:${i + 1} violet ${hex} (hue ${h.toFixed(0)})`);
    }
  });
}
if (fails.length) { console.error(fails.join("\n")); console.error(`\n${fails.length} design gate failure(s)`); process.exit(1); }
console.log(`design gates: ${files.length} files clean (no emoji, no violet, no banned fonts)`);
