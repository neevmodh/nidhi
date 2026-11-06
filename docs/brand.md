# Nidhi brand

*Nidhi* (निधि) means treasure, or treasury. The brand is a lamplit vault: warm black, bone paper, old gold. Cozy like a
lamp in a dark room, premium like an old bank's brass. Never neon, never purple.

## The mark: the lamp vessel

A *kalasha*, the rounded treasure vessel, holding one flame. The vessel is the treasury, and the flame is the moment a grant
is paid. Two arcs rest inside the belly, like coins.

- Drawn on a 24-unit grid: rim, a short narrow neck, a round belly, a flat foot; one stroke weight (1.75) with round caps
  and joins; the flame leans 8 degrees right so it reads as alive.
- The wordmark is **nidhi** in lowercase Fraunces (opsz 72, SOFT 100, weight 400, -2% tracking), converted to outlines.
  The dot of the final *i* is the same flame.
- Source and generator: `ui/scripts/brand-gen.mjs` (needs a Fraunces TTF pinned to those axes, from Google Fonts).

| File | Use |
|---|---|
| `ui/public/brand/nidhi-logo-evening.svg` | lockup on warm black |
| `ui/public/brand/nidhi-logo-day.svg` | lockup on bone |
| `ui/public/brand/nidhi-mono.svg` | one colour, follows `currentColor` |
| `ui/public/brand/nidhi-mark.svg` / `nidhi-mark-gold.svg` | the mark alone |
| `ui/public/brand/favicon.svg`, `app-icon.svg`, `apple-touch-icon.png` | small sizes; the favicon keeps one arc so it stays clear at 16px |

**Clear space:** one flame height on every side. **Minimum size:** mark 16px, lockup 24px tall.
**Do not:** add a gradient, outline, shadow or glow; recolour it (above all, never violet or lavender); stretch it; redraw
the wordmark in another face; put it on a busy photograph.

## Colour

| Token | Evening | Day | Use |
|---|---|---|---|
| ground | `#0E0B08` | `#F3EEE4` | page |
| panel | `#17130F` | `#E9E2D5` | inputs, panels |
| card | `#1F1A14` | `#FBF8F2` | cards |
| ink | `#F4EFE6` | `#1C1610` | text, hairlines at 12-15% |
| muted | `#A39887` | `#65594B` | labels, meta |
| gold | `#C9A45A` | `#8C6A2A` | the one filled button, links, focus, the flame |
| sage / amber / brick | `#8DB597` `#D9A066` `#D27466` | `#3F6B4C` `#8F541C` `#9C3B30` | settled / held / failed |

The interface stays 90-95% neutral; gold is the only accent. `ui/scripts/check-design.mjs` fails CI on any colour with an
OKLCH hue between 270 and 330 degrees, on any emoji and on banned fonts.

## Type

Fraunces (display: headings, figures, the wordmark), Geist (text and interface, 400 and 500), Geist Mono (addresses,
hashes, amounts). Sentence case everywhere; labels 13px at 500; body 16px.

## Icons

Interface glyphs: Phosphor, regular weight, from one SVG sprite. Protocol and chain marks: their official SVGs in their own
colours (via @web3icons/core), never redrawn or tinted. No emoji anywhere.
