# Harbor "Big Picture" — Design Spec for a Native SwiftUI Rebuild

Source repo: `reference/harbor` (read-only reference; this document is
the only file written). All citations are `path:line` relative to that repo root. Every
value below was read directly from source; anything not found in the code is marked
**"not found"** rather than guessed.

Big Picture is a React/TypeScript ten-foot UI, styled with Tailwind v4 utility classes plus
one hand-written CSS-variable stylesheet (`bp-tokens.ts`) injected at runtime, not a
separate `.css` file. There is no `src/styles` directory and no `bp-` class names in
`src/index.css` (`src/index.css` has 0 matches for `\-\-bp|\.bp-`) — virtually all
Big Picture layout/sizing is inline Tailwind arbitrary-value classes
(`text-[clamp(...)]`, `w-[clamp(...)]`, etc.) on the components themselves, or JS helpers
like `bpBoxCss()`/`bpBoxPx()` in `src/views/big-picture/bp-art.ts`.

---

## 1. Canvas and scale

**Design viewport width: `1140px` CSS pixels**, fixed and never derived from the physical
panel. Set in `reference/harbor/index-tv.html:33`:

```js
var CANVAS = 1140;
```

- This script (`index-tv.html:24-47`) only runs on TV-class user agents, detected by regex
  at `index-tv.html:35-39`: `/\bAFT[A-Z0-9]+\b/` (Fire TV) or
  `/Android ?TV|Google ?TV|SMART-?TV|Tizen|Web ?0S|WebOS|NetCast|BRAVIA|HbbTV|CrKey|VIDAA/i`.
  If matched, and the device's actual `innerWidth` differs from 1140 by ≥48px, it rewrites
  the `<meta name="viewport">` tag to `width=1140, viewport-fit=cover`
  (`index-tv.html:41-43`).
- Design commentary at `index-tv.html:7-23`: the canvas is "settled by eye on a real panel
  from a sofa," deliberately **not** derived from the device's native resolution — a 4K
  stick and a 1080p set both render the same 1140px canvas, just at different sharpness.
  1080 was an earlier value; 1140 was chosen because "the row below the focused one being
  clipped by the hint bar... needs vertical room" (`index-tv.html:14-17`).
  It must never be changed at runtime after boot — doing so measured ~3-second focus
  stalls on a Fire TV Stick 4K Max (`index-tv.html:20-23`).
  A meta comment (`index-tv.html:26-32`) explicitly warns against widening the canvas to
  "fix" apparent zoom, since a wider canvas shrinks every card.
- Multiple internal comments describe the design height as **`607px`**
  (`bp-tokens.ts:114`: "A television lays out on 1080x607") and elsewhere as **`641px`**
  (`bp-tokens.ts:103,110,301` etc.: "1140x641"). Both pairs share the same ~16:9 aspect
  ratio (1080/607 = 1.779, 1140/641 = 1.778); height is not set explicitly anywhere —
  it falls out of the device's native aspect ratio at the fixed 1140 width. The 1080×607
  comments appear to be an older/unupdated reference to the same 16:9 design; the current
  literal `CANVAS` value is 1140. **Treat 1140×641 as the authoritative modern figure**,
  reported here as-is with both citations since the code contains both.

**Safe-area / overscan insets** — `src/views/big-picture/bp-safe-area.ts`:
- Default overscan for any TV-class user agent (same regex list as above, plus the Fire TV
  pattern): **`TEN_FOOT_OVERSCAN = 0.02`** (2%) (`bp-safe-area.ts:11,70`). Comment
  (`bp-safe-area.ts:5-10`): Fire TV certification asks for 5%, but real HDMI panels
  default to 1:1 (no crop) for years, so 2% is "the token inset the design gutter absorbs
  for free."
- Hard ceiling: **`MAX_OVERSCAN = 0.1`** (10%) (`bp-safe-area.ts:3,27`).
- Can be overridden by a `?overscan=` URL query param (`bp-safe-area.ts:30-37`) or a
  persisted `bigPictureOverscan` value in the `harbor.settings` localStorage key
  (`bp-safe-area.ts:16,39-49`); URL param wins over stored setting, both win over the
  device-detected default (`bp-safe-area.ts:60-65`).
- Actual inset in pixels: `bpSafeAreaPx()` returns
  `{ x: Math.round(overscan * innerWidth), y: Math.round(overscan * innerHeight) }`
  (`bp-safe-area.ts:94-99`); at 2% on the 1140-wide canvas that is ~23px horizontal.
- CSS mirror in `bp-tokens.ts:48-50`: `--bp-overscan: 0` (set at runtime to the resolved
  fraction), `--bp-safe-x: calc(var(--bp-overscan) * 100vw)`,
  `--bp-safe-y: calc(var(--bp-overscan) * 100vh)`.
- The page's outer gutter combines the safe-area inset with a design margin rather than
  summing them blindly — `bp-tokens.ts:51-55`:
  ```
  --bp-gutter: max(clamp(56px, 7.5vw, 110px), calc(var(--bp-safe-x) + clamp(10px, 0.9vw, 20px)));
  ```
  Comment: "max, never safe-x + gutter... The second term only wins past 4.2 percent
  overscan."

**Base font size**: no explicit `html { font-size }` override was found for Big Picture
(no match for `html\s*{` in `src/index.css`, and no `font-size` rule scoped to
`[data-bp-root]` in `bp-tokens.ts`). Text sizing instead comes entirely from `clamp()`
expressions on individual elements (see §3/§4) mixing a px floor with a `vh`/`vw` term —
there is no single root rem/em scale to port; each text role has its own clamp.

**How sizes scale**: almost every dimension in Big Picture is authored as
`clamp(pxFloor, vh-or-vw term, pxCeiling)`. On the 1140×641 TV canvas, most clamps resolve
to their **px floor**, not their fluid term — comment at `bp-tokens.ts:114-125`:
> "at that height 500 of Big Picture's 677 clamps resolve to their px floor rather than
> their vh term. The floor scale IS the ten-foot design... median 1.22x overall, 1.37x for
> sizes, 1.21x for fonts, 1.18x for spacing" relative to their raw vh value.

A second, separate upscale applies **only off the TV** (desktop windows and Steam Deck
taller than 800px, explicitly excluding anything carrying the `[data-bp-tv]` attribute):
a single dial `--bp-up: 1.3` (`bp-tokens.ts:193-195`) multiplies chrome heights, row
rhythm, and dozens of named text/size tokens (`bp-tokens.ts:196-444`). **This upscale does
not apply to the TV build** — the Apple TV target should use the base (TV-floor) clamp
values throughout, not the ×1.3 desktop numbers. This document lists the base (TV) values
unless stated otherwise.

---

## 2. Color tokens

Big Picture does not hardcode a fixed palette. It layers `--bp-*` tokens
(`bp-tokens.ts:1-155`) on top of the app-wide theme tokens (`--color-*`, defined per theme
preset in `src/lib/theme.ts`). The **default shipped theme** is `"cool-grey"` / display name
**"Harbor default"** (`src/lib/theme.ts:124-126`), paired by default with font pair
`sentient-switzer` (`src/lib/theme.ts:1854-1859`, `DEFAULT_THEME`).

### 2.1 Base theme tokens — "Harbor default" (`cool-grey`)

`src/lib/theme.ts:124-143`. Values are authored in OKLCH; hex approximations were computed
by converting OKLCH→sRGB (D65, standard OKLab matrices) for convenience — the **source of
truth is the OKLCH string cited**, hex is a derived approximation for quick reference in a
tool (SwiftUI/Figma) that doesn't take OKLCH directly.

| Token | OKLCH (source, `theme.ts` line) | ≈ Hex (computed) |
|---|---|---|
| `--color-canvas` | `oklch(0.18 0.004 260)` (132) | `#111213` |
| `--color-surface` | `oklch(0.22 0.004 260)` (133) | `#191b1c` |
| `--color-elevated` | `oklch(0.27 0.004 260)` (134) | `#252628` |
| `--color-raised` | `oklch(0.32 0.004 260)` (135) | `#323335` |
| `--color-ink` (text primary) | `oklch(0.97 0.003 260)` (136) | `#f4f5f7` |
| `--color-ink-muted` (text secondary) | `oklch(0.72 0.003 260)` (137) | `#a3a5a6` |
| `--color-ink-subtle` | `oklch(0.50 0.003 260)` (138) | `#626365` |
| `--color-edge` | `oklch(0.36 0.004 260 / 0.55)` (139) | `#3c3d3f` @ 55% alpha |
| `--color-edge-soft` | `oklch(0.36 0.004 260 / 0.25)` (140) | `#3c3d3f` @ 25% alpha |
| `--color-accent` | `oklch(0.78 0.13 60)` (141) | `#f4a25c` |
| `--color-accent-soft` | `oklch(0.78 0.13 60 / 0.18)` (142) | `#f4a25c` @ 18% alpha |
| `--color-danger` | `oklch(0.55 0.18 25)` (143) | `#c53637` |

Sanity check: `index-tv.html:49` sets `<meta name="theme-color" content="#111214">` and
the boot-splash background is `#08090a` (`index-tv.html:104`), both consistent with the
computed canvas hex above.

Base radii and motion tokens also live in `src/index.css:42-56` (Tailwind `@theme` block,
not `--bp-*`): `--radius-sm: 6px`, `--radius-md: 10px`, `--radius-lg: 14px`,
`--radius-xl: 20px`, `--radius-2xl: 28px` — these are the **app-wide** radii; Big Picture
uses its own `--bp-r-*` scale instead (see §4).

### 2.2 Big Picture–specific tokens (`bp-tokens.ts:1-155`)

All computed from the base theme tokens above via CSS `color-mix()`, so they follow
whatever theme preset is active. Values below are as they resolve under the default theme.

| Token | Formula | Line |
|---|---|---|
| `--bp-void` | `color-mix(in oklab, var(--color-canvas) 78%, #000 22%)` — canvas darkened further | 3 |
| `--bp-page` | `var(--color-canvas)` | 4 |
| `--bp-panel` | `color-mix(in oklab, var(--color-surface) 88%, #000 12%)` | 5 |
| `--bp-panel-2` | `color-mix(in oklab, var(--color-elevated) 92%, #000 8%)` | 6 |
| `--bp-glass` | `color-mix(in oklab, var(--color-ink) 7%, transparent)` | 7 |
| `--bp-edge` | `color-mix(in oklab, var(--color-ink) 11%, transparent)` | 8 |
| `--bp-edge-2` | `color-mix(in oklab, var(--color-ink) 18%, transparent)` | 9 |
| `--bp-on` | `color-mix(in oklab, var(--color-ink) 22%, var(--bp-void))` | 10 |
| `--bp-plate-lo` | `color-mix(in oklab, var(--color-ink) 7%, transparent)` (shimmer/loading plate, low) | 12 |
| `--bp-plate-hi` | `color-mix(in oklab, var(--color-ink) 11%, transparent)` (shimmer/loading plate, high) | 13 |
| `--bp-touch` | `var(--color-accent)` (≈ `#f4a25c`) | 15 |
| `--bp-focus-stroke` | `color-mix(in oklab, var(--color-ink) 86%, transparent)` — the focus-ring color, near-white | 16 |
| `--bp-focus-face` | `color-mix(in oklab, var(--color-ink) 22%, var(--bp-panel-2))` | 17 |
| `--bp-live` | `#4ade80` (hardcoded green, live-badge color) | 18 |
| `--service-logo-filter` | `brightness(0) invert(1)` (forces service logos to solid white) | 154 |

**Scrims / gradients** (`bp-tokens.ts:20-35`):
```css
--bp-scrim-up: linear-gradient(0deg,
  var(--bp-void) 0%,
  color-mix(in oklab, var(--bp-void) 88%, transparent) 18%,
  color-mix(in oklab, var(--bp-void) 62%, transparent) 34%,
  color-mix(in oklab, var(--bp-void) 30%, transparent) 52%,
  color-mix(in oklab, var(--bp-void) 10%, transparent) 68%,
  transparent 82%);
--bp-scrim-side: linear-gradient(100deg,
  color-mix(in oklab, var(--bp-void) 82%, transparent) 0%,
  color-mix(in oklab, var(--bp-void) 52%, transparent) 30%,
  color-mix(in oklab, var(--bp-void) 16%, transparent) 52%,
  transparent 70%);
```
Under `[dir="rtl"]`, `--bp-scrim-side` flips its gradient angle to `260deg`
(`bp-tokens.ts:157-165`).

**Card focus-ring / shadow color recipe** (used as the literal `box-shadow` on a focused
tile, `bp-tokens.ts:517-520`):
```css
box-shadow:
  0 0 0 2px var(--bp-void),
  0 0 0 4px var(--bp-focus-stroke),
  0 24px 56px -22px rgba(0, 0, 0, 0.92);
```
i.e. a 2px void-colored gap, then a 4px near-white (`--bp-focus-stroke`) ring, then a large
soft drop shadow. See §4 for full focus/press mechanics.

**Badge / mark colors found directly on components** (not centralized tokens):
- Generic text badge (`bp-card-marks.tsx:24`): background `var(--color-ink)`
  (≈ `#f4f5f7`), text `var(--color-canvas)` (≈ `#111213`) — i.e. inverted pill.
- Live badge: `--bp-live: #4ade80` (green) (`bp-tokens.ts:18`).
- State-mark chip background (`bp-card-state-marks.tsx:84`): `bg-[var(--bp-void)]/92`
  (92% opaque void) with a `ring-1 ring-[var(--bp-edge-2)]` border.

**Verdict on "app theme tokens vs Big Picture-specific"**: Big Picture's own tokens
(`--bp-*`) are always derived from whichever `--color-*` theme is active — there is no
independent Big Picture palette baked in. To port to SwiftUI, implement the base
`--color-*` scale (§2.1) as the app's `Color` assets, then derive the `--bp-*` values with
the same `color-mix` percentages (or bake equivalent static colors from the default theme,
per the hex table above, since Big Picture always resolves through the active theme).

---

## 3. Typography

**Font pair source of truth**: `src/lib/theme.ts`. The default pair is `sentient-switzer`
(`theme.ts:1764-1770`, `DEFAULT_THEME.fontPair` at `theme.ts:1858`):

```ts
"sentient-switzer": {
  name: "Sentient + Switzer",
  blurb: "Default. Humanist serif, warm sans.",
  display: '"Sentient", "Iowan Old Style", "Georgia", serif',
  sans: '"Switzer", "Inter", system-ui, sans-serif',
},
```

Applied as CSS custom properties `--font-display` / `--font-sans` at the document root
(`theme.ts:1951-1955`), with the *same literal default* duplicated in
`src/index.css:48-49`:
```css
--font-display: "Sentient", "Iowan Old Style", "Georgia", serif;
--font-sans: "Switzer", "Inter", system-ui, sans-serif;
```
`:root { font-family: var(--font-sans); }` (`src/index.css:65-66`) — **Switzer is the base
UI/body font**; Sentient (`font-display` Tailwind utility, generated by the `@theme` block)
is opt-in per element for headline-weight text.

**Where the font files are**: **not bundled in the repo.** They are loaded remotely via
`<link>` preconnects/stylesheets in `index-tv.html:55-81`:
- Fontshare CDN (`api.fontshare.com`/`cdn.fontshare.com`) serves Sentient, Switzer,
  General Sans, Cabinet Grotesk (`index-tv.html:70-75`).
- Google Fonts serves Oswald, Fraunces, Vazirmatn, Inter, IBM Plex Sans, Plus Jakarta Sans,
  Fredoka (`index-tv.html:76-81`).
Both stylesheet `<link>` tags use `media="print" onload="this.media='all'"` to avoid
blocking first paint (`index-tv.html:65-69` comment explains a 1.5s block was measured
without this trick). No local `.woff2`/`.ttf` files for Sentient/Switzer exist under
`src/assets/fonts/` — that folder only has unrelated kids-theme fonts
(`WonderfulFontyCure-4nnoD.ttf`, `blending.otf`, `qr-ames-beta.otf`) referenced by
`--font-anime` / `--font-book` (`src/index.css:52-53`), not by Big Picture.

**Other named font roles** (`src/index.css:42-56`, Tailwind `@theme` block — app-wide, not
Big-Picture-specific but available if a card ever needs them): `--font-mono: "JetBrains
Mono", ui-monospace, monospace`; `--font-channel: "General Sans", "Switzer", "Inter",
system-ui, sans-serif`; `--font-rank: "Oswald", "Arial Narrow", "Helvetica Neue",
sans-serif` (used for ranked-row numerals); `--font-arabic: "Geeza Pro", "SF Arabic",
"Segoe UI", "Tahoma", "Noto Naskh Arabic", serif`.

### 3.1 Sizes and weights by role (TV-floor values; ignore the ×1.3 desktop upscale — §1)

| Role | Font-size (clamp, TV floor first) | Weight / other | Citation |
|---|---|---|---|
| Hero title (Home spotlight) | `clamp(36px, 5.6vh, 54px)` | `font-display` (Sentient), `font-semibold`, `leading-[1.12]`, `tracking-[-0.02em]`, `text-ink`, drop-shadow | `bp-spotlight.tsx:28` |
| Hero title (generic `[data-bp-hero-title]`, e.g. detail hero) | `clamp(30px, 4.7vh, 44px)` (this is the *base* the non-TV `--bp-up` multiplies) | — | `bp-tokens.ts:234-237` |
| Row title (`[data-bp-row-header]`) | `var(--bp-row-title)` = `clamp(19px, 2.6vh, 32px)` | `font-bold`, `leading-[1.25]`, `tracking-[-0.015em]`; dims to `color-mix(ink 55%, transparent)` when row unfocused, full `text-ink` when the row carries focus | `bp-row-header.tsx:63`; token at `bp-tokens.ts:65` |
| Row "See all" chip | `clamp(15px, 1.9vh, 22px)` | `font-semibold`, `text-ink-muted` | `bp-row-header.tsx:113` |
| Card/tile title (poster caption) | `clamp(10.5px, 1.4vh, 16px)` | `font-semibold`, `leading-tight`, `text-ink`, fades in on focus (`transition-opacity duration-[var(--bp-focus-fade)]`) | `bp-tile.tsx:211` |
| Hero body/description | `clamp(16px, 2vh, 23px)` (spotlight instance) | regular weight (no bold/semibold class), `leading-[1.55]`, `text-ink-muted`, `line-clamp-2` | `bp-spotlight.tsx:161-163` |
| Hero body (`[data-bp-hero-desc]` token base, detail-hero context) | `clamp(14.2px, 1.7vh, 20px)` | — | `bp-tokens.ts:248-249` |
| Detail heading (`--bp-detail-heading`) | `clamp(14px, 2.05vh, 26px)` | — | `bp-tokens.ts:66` |
| Detail synopsis | `clamp(13px, 1.85vh, 22px)` | — | `bp-tokens.ts:308` (base cited via the ×up rule; base = this clamp) |
| Continue-Watching card title | `clamp(14px, 1.98vh, 23px)` | — | `bp-tokens.ts:350-352` (base clamp) |
| Person name (cast/crew detail) | `clamp(26px, 4.6vh, 64px)` | — | `bp-tokens.ts:384-386` |
| Hint bar chip / label text | `clamp(13.4px, 1.5vh, 18px)` | chip: `font-semibold`, `text-ink`; label: `font-medium`, `text-ink-muted` | `bp-hint-bar.tsx:137,145` |
| Badge / mark pill text | `clamp(9.8px, 1.22vh, 14px)` | `font-bold`, `uppercase`, `tracking-[0.04em]`, `leading-none` | `bp-card-marks.tsx:24` |

General pattern: nearly all Big Picture text uses the **sans** family (Switzer) by default
via inherited `:root` `font-family`; only hero-scale titles opt into `font-display`
(Sentient serif) explicitly (confirmed at `bp-spotlight.tsx:28`). Row titles, card titles,
badges, hint bar — no `font-display` class found on any of them, so they render in Switzer.

---

## 4. Spacing and shapes

### 4.1 Card sizes (actual px, computed at the 1140px TV canvas width)

Defined in `src/views/big-picture/bp-art.ts:207-214` as `BP_TILE_BOX` /
`BP_FLUID_BOX`, each a `{min, vw, max}` triple consumed by `bpBoxCss()` (→
`clamp(min px, vw vw, max px)`, `bp-art.ts:147-149`) and `bpBoxPx()` (→ resolved px at
current viewport, floored/ceilinged, then multiplied by the off-TV upscale factor —
always `1` on Android TV, `bp-art.ts:141,207-214` and `bpBoxUpscale()` at
`bp-art.ts:139-144`):

```ts
export const BP_TILE_BOX: Record<"poster" | "wide", BpArtBox> = {
  poster: { min: 177, vw: 13, max: 220 },
  wide:   { min: 230, vw: 19, max: 380 },
};
export const BP_FLUID_BOX: Record<"wide", BpArtBox> = {
  wide: { min: 240, vw: 20, max: 400 },
};
```
(`bp-art.ts:207-213`)

- **Poster card**: `clamp(177px, 13vw, 220px)` wide, aspect ratio **`2 / 3`**
  (`bp-tile.tsx:49` `SHAPE.poster`). At the 1140px canvas, `13vw = 148.2px`, which is
  below the 177px floor, so **the poster card resolves to its floor: 177 × 265.5px**
  (177 × 1.5 for the 2:3 ratio).
- **Wide/landscape card** (e.g. Continue Watching, episode cells): `clamp(230px, 19vw,
  380px)` wide, aspect ratio **`16 / 9`** (`bp-tile.tsx:50` `SHAPE.wide`). At 1140px,
  `19vw = 216.6px` < 230px floor, so **it resolves to 230 × 129.4px** (230 × 9/16).
- A separate "fluid wide" bucket exists for grid/rail contexts that exceed the tile's own
  box: `clamp(240px, 20vw, 400px)` (`bp-art.ts:212-213`, used via `BP_FLUID_BOX.wide`,
  comment at `bp-tile.tsx:56-59`).
- **Ranked-row cell** (Top 10 style numeral + poster): width is the poster box divided by
  `RANK_ART = 0.6` (i.e. the poster covers the right 60% of the cell,
  `bp-tile.tsx:23-34`), aspect ratio **`10 / 9`** (`bp-tile.tsx:41-42`), height
  `calc(<box css> * 0.9)` (`bp-tile.tsx:46`, `BP_RANK_CELL_HEIGHT`).

### 4.2 Gaps and row padding

- **Row title font size token**: `--bp-row-title: clamp(19px, 2.6vh, 32px)`
  (`bp-tokens.ts:65`).
- **Horizontal track gap between cards in a row**: `--bp-track-gap: clamp(21px, 1.9vw,
  32px)` (`bp-tokens.ts:67`).
- **Vertical gap between rows**: `--bp-row-gap: clamp(20px, 2.6vh, 40px)`
  (`bp-tokens.ts:56`).
- **Row's horizontal padding == page gutter**: every `[data-bp-row]` gets
  `padding: 0 var(--bp-gutter)` and a matching negative margin so the row's scroll track
  still bleeds edge-to-edge (`bp-tokens.ts:448-453`). `--bp-gutter` itself:
  `max(clamp(56px, 7.5vw, 110px), safe-x + clamp(10px, 0.9vw, 20px))` (`bp-tokens.ts:55`,
  see §1). On the 1140px canvas with 0 or low overscan this resolves to its floor,
  **≈ 85.5px** (`7.5vw` of 1140 = 85.5px, between the 56px floor and 110px ceiling).
- **Detail-page gaps**: `--bp-detail-gap: clamp(16px, 1.35vw, 30px)` (general),
  `--bp-detail-gap-tight: clamp(9px, 0.85vw, 17px)` (`bp-tokens.ts:68-69`).

### 4.3 Corner radii

Global radius scale, `bp-tokens.ts:37-40`:
```css
--bp-r-xs: 8px;
--bp-r-sm: 10px;
--bp-r-md: 16px;
--bp-r-lg: 24px;
```
- **Poster/wide/rank tile corner radius: `var(--bp-r-xs)` = 8px** — confirmed directly on
  the shared tile component: `rounded-[var(--bp-r-xs)]` (`bp-tile.tsx:170`).
- Continue-Watching cell: `rounded-[var(--bp-r-xs)]` (8px) (`bp-cw-row.tsx:164,289`).
- Larger panels (facts card, collection card, detail chip rows): `var(--bp-r-md)` (16px),
  e.g. `bp-collection-card.tsx:13,130`, `bp-facts.tsx:117`.
- Big panel/banner surfaces (e.g. anime announcement band): `var(--bp-r-lg)` (24px), e.g.
  `bp-anime-announcement.tsx:10`.
- Small chips/action buttons: `var(--bp-r-sm)` (10px) or `var(--bp-r-xs)` (8px)
  interchangeably by context (e.g. `bp-anime-awards.tsx:288` uses `--bp-r-sm`;
  `bp-detail-actions.tsx:53` uses `--bp-r-xs`).

### 4.4 Focus scale, animation timing/easing, press feedback, shadow

All from `bp-tokens.ts`:

| Token | Value | Line |
|---|---|---|
| `--bp-focus-lift` (card grow scale, focused) | `1.03` | 127 |
| `--bp-focus-lift-wide` (same, for `[data-bp-tile="wide"]`) | `1.03` | 128 |
| `--bp-focus-dwell` (delay before the grow-in starts) | `70ms` | 138 |
| `--bp-focus-dur` (grow-in/out duration) | `190ms` | 139 |
| `--bp-press` (scale multiplier on OK/press-down, on top of the focus lift) | `0.965` | 144 |
| `--bp-press-dur` | `90ms` | 145 |
| `--bp-focus-fade` (fade for anything that changes with focus, e.g. card title reveal) | `var(--bp-dur)` = `260ms` | 150, 43 |
| `--bp-dur-fast` / `--bp-dur` / `--bp-dur-slow` (general durations) | `160ms` / `260ms` / `420ms` | 42-44 |
| `--bp-ease` (primary easing) | `cubic-bezier(0.22, 1, 0.36, 1)` | 45 |
| `--bp-ease-in` (press-down easing) | `cubic-bezier(0.5, 0, 0.75, 0)` | 46 |

Focus-ring recipe (applied as `box-shadow` on `[data-bp-tile][data-bp-focus="true"]`,
`bp-tokens.ts:501-522`):
```css
transform: scale(var(--bp-focus-lift));
transition-delay: var(--bp-focus-dwell), 0ms; /* grow waits 70ms, so a fast scan never triggers it */
box-shadow:
  0 0 0 2px var(--bp-void),      /* 2px gap in the void color */
  0 0 0 4px var(--bp-focus-stroke), /* 4px near-white ring, ≈86%-opacity ink */
  0 24px 56px -22px rgba(0, 0, 0, 0.92); /* large soft contact shadow */
```
Design rationale in the surrounding comments (`bp-tokens.ts:512-516`): focus reads as "the
card coming FORWARD" via lift + shadow + brighter face, not as an outline drawn around it;
a drawn ring was explicitly rejected. `box-shadow` is deliberately excluded from the
transition list so the ring itself snaps instantly (no cross-dissolve) while only the
scale/grow animates (`bp-tokens.ts:494-496`).

Press feedback (`bp-tokens.ts:564-573`), applied only to the already-focused tile:
```css
transform: scale(calc(var(--bp-focus-lift) * var(--bp-press))); /* 1.03 * 0.965 ≈ 0.994 */
transition-duration: var(--bp-press-dur); /* 90ms */
transition-timing-function: var(--bp-ease-in); /* cubic-bezier(0.5,0,0.75,0) */
```

**Android TV motion is globally reduced from the above**: `[data-bp-root][data-bp-tv]
[data-bp-rail-row] { transition-duration: 0ms; }` (`bp-tokens.ts:649-652`) — the *row
slide/fade* is zeroed on TV specifically (not the card grow or the focus ring, which keep
their durations per the comment at `bp-tokens.ts:625-627`: "NOT here on purpose: the tile
grow and the rail slide... they are the two motions the ten-foot design is actually made
of"). This was a measured GPU-cost tradeoff on Fire TV Stick hardware (detailed
perf comments at `bp-tokens.ts:604-627`).

`prefers-reduced-motion: reduce` strips all tile/key transforms to `none` and caps every
transition/animation duration to `1ms` (with animation-iteration-count forced to `1` to
avoid infinite loops spinning at 1ms) — `bp-tokens.ts:789-819`.

---

## 5. Shell layout

**Correction to the task's assumption**: Big Picture's primary navigation is a **top bar**
(`src/views/big-picture/bp-top-bar.tsx`, `BpTopBar`), not a side rail.
`bp-rail.tsx`/`use-bp-rail.ts` implement a different, generic mechanism: a vertical
**content-row scroller** used *inside* pages (Home, Discover, Movies, Shows, Sports,
Catalog, a generic Service page) to bring the focused row into view — imported by
`bp-home.tsx:13`, `bp-discover.tsx:17`, `bp-movies.tsx:8`, `bp-shows.tsx:11`,
`bp-sports.tsx:13`, `bp-catalog-page.tsx:2`, `bp-service.tsx:10`. It carries no list of
rooms/tabs.

### 5.1 Top bar / nav — `bp-top-bar.tsx`

`<header data-bp-top-bar>`, `absolute inset-x-0 top-0 z-30`, height `h-[var(--bp-bar-h)]`
(`bp-top-bar.tsx:295-297`). Mounted directly by `bp-shell.tsx:424` as a sibling of
`<main>`, above the ambient background layer.

Bar height token: `--bp-bar-h: calc(clamp(72px, 9vh, 112px) + var(--bp-safe-y, 0px))`
(`bp-tokens.ts:83`; TV-scoped copy is identical, `bp-tokens.ts:200` — the `84px`/`128px`
values at that line only apply off-TV). No animated expand/collapse of the bar's own
height was found; it is a fixed-height header.

**Rooms, in order** (`bp-top-bar.tsx:41-95`), each entry `{kind, label, icon}`:

| # | kind | Label | Icon | Notes |
|---|---|---|---|---|
| 1 | `home` | "Home" | `<HomeIcon>` | `bp-top-bar.tsx:42` |
| 2 | `discover` | "Discover" | `<NavGlyph name="explore">` | `:44-47` |
| 3 | `anime` | "Anime" | `<AnimeIcon>` | hidden if anime content is hidden in settings; parental-lock key `anime` (`:49-54`) |
| 4 | `shows` | "Shows" | `<TvIcon>` | parental-lock key `shows` (`:55`) |
| 5 | `movies` | "Movies" | `<MoviesIcon>` | parental-lock key `movies` (`:56-61`) |
| 6 | `live` | "Live TV" | `<NavGlyph name="livetv">` | `:66-69` |
| 7 | `sports` | "Sports" | `<NavGlyph name="sports">` | parental-lock key `sports` (`:70-75`) |
| 8 | `search` | "Search" | `<NavGlyph name="search">` | `:76-80` |
| 9 | `library` | "Library" | `<LibraryIcon>` | parental-lock key `library` (`:81-86`) |
| 10 | `collections` | "Collections" | `<NavGlyph name="collections">` | `:89-93` |
| 11 | `settings` | "Settings" | `<SettingsIcon>` | `:94`; rendered as a `cog` button pulled out of the main scroll track, appended after the profile chip (`:252,367-375`) so "Right off the last tab still reaches it" (`:249-251`) |

Visibility filtering (anime-hidden setting, sports-consent-declined, parental
lock/hidden-tabs) happens in `visibleTabs()` (`bp-top-bar.tsx:122-129`); `bpTabKinds()` is
exported for other consumers (`:131-133`).

**Layout**: 3-column grid `grid-cols-[auto_minmax(0,1fr)_auto]` (`bp-top-bar.tsx:297`).
Col 1: brand mark/wordmark (`HarborMark`, `h-[clamp(28px,3.4vh,44px)]`, `:299-338`).
Col 2: `<nav data-bp-row>` containing the scrollable tab strip (`:340-380`). Col 3:
`BpStatus` + clock.

Tabs render **icon-only at all sizes on TV**; the text label only appears when the tab is
active *and* the viewport is ≥1400px wide (`min-[1400px]:inline`, `:226`) — i.e. **on the
1140px-wide TV canvas, every tab is icon-only, with no visible label even when
focused/active** (comment confirms this at `:137-139`). Tab hit height:
`h-[clamp(44px,5vh,58px)]` (`:135`).

**Profile chip position**: `<BpProfileMenu>` sits inside the tab strip's trailing
`ms-auto` span, after a 1px vertical divider (`--bp-edge-2`) and immediately before the
Settings cog button — i.e. at the **end of the horizontal tab row, just left of Settings**
(`bp-top-bar.tsx:356-376`). Rationale in the comment: the profile "joins Settings in the
same track... it is not a tab because every item in the strip pushes a route and this one
changes who the app belongs to" (`:356-360`).

No width "expanded vs collapsed" state exists for this bar (it's a fixed-height horizontal
strip, not a rail with two states) — the side-rail framing in the original brief does not
apply to this codebase.

### 5.2 Hint bar — `bp-hint-bar.tsx`

`<footer data-bp-hint-bar>`, `absolute inset-x-0 bottom-0`, height `h-[var(--bp-hint-h)]`,
`z-[65]` when `raised`, else `z-30` (`bp-hint-bar.tsx:120-125`).
`--bp-hint-h: calc(clamp(52px, 6.4vh, 74px) + var(--bp-safe-y, 0px))` (`bp-tokens.ts:94`,
identical on TV, `bp-tokens.ts:202`).

Content: a right-aligned row of glyph-chip + label pairs, built from an `actions: BpAction[]`
prop, optionally prefixed with a "Nav" hint via a `jump` prop (`bp-hint-bar.tsx:83-118`).
Populated purely by props — no ambient context consumed besides device-type detection
(`useGamepads()` / `isAndroid()`) to choose the right glyph set.

Exact label strings (`useActionLabels`, `bp-hint-bar.tsx:65-81`): **"Select", "Toggle",
"Type", "Phone keyboard", "Back", "Exit", "Search", "Clear", "Switch tab", "Nav", "Hold to
skip or continue", "Hold to continue."**

Glyph sets by input device:
- Gamepad (`PAD_GLYPH`, `:22-32`): select/toggle/type = **"A"**; back/exit = **"B"**;
  search/phone = **"Y"**; tabs = **"LB / RB"**; actions/advance = **"▼"**. `nav` has no pad
  glyph and is dropped when a gamepad is connected.
- TV remote (`REMOTE_GLYPH`, `:36-44`): select/toggle/type = **"OK"**; back/exit =
  **"Back"**; nav = **"Menu"**; actions/advance = **"▼"**.
- Keyboard (`KEY_GLYPH`, `:50-63`): select/toggle/type = **"Enter"**; back/exit =
  **"Esc"**; search/phone = **"Tab"**; clear = **"Del"**; tabs = **"PgUp / PgDn"**;
  actions/advance = **"↓"**.

Chip shape: round pill `w-[clamp(22px,2.5vh,28px)] rounded-full` for single-character
glyphs, or a padded pill `rounded-[var(--bp-r-xs)]` for multi-character glyphs
(`bp-hint-bar.tsx:137-141`).

### 5.3 Boot splash — `bp-boot-splash.ts` + `index-tv.html#boot`

`index-tv.html` paints `<div id="boot">` **inline, before the JS bundle loads**
(comment: "the html lands at 195ms and the first React paint at 9952ms," measured on a
Fire TV Stick 4K Max — `index-tv.html:90-94`). `#boot`: `position: fixed; inset: 0;
z-index: 2147483000; background: #08090a; pointer-events: none; transition: opacity 620ms
cubic-bezier(0.22, 1, 0.36, 1)` (`index-tv.html:95-107`); `[data-leaving="true"] {opacity:
0}` (`:108`). Contains a Harbor mark SVG (`.boot-mark`, `width: min(24vw, 200px)`,
`animation: boot-mark-in 1200ms cubic-bezier(0.22,1,0.36,1) both`, `:110-113`) and a
spinner (`.boot-spin`, `animation: boot-spinner-in 900ms ... 500ms both` then an infinite
`arc` spin at 1300ms + a dash animation at 2000ms, `:115-129`).

`bp-boot-splash.ts` (React side) only *talks to* that pre-painted DOM node — it never
creates the splash (TV entry only). `FADE_MS = 620` (`bp-boot-splash.ts:1`, matching the
CSS transition above). `bpBootSplashDismiss(fade: boolean)`
(`bp-boot-splash.ts:27-36`): if `fade` is `false`, the node is removed **instantly**
(`el.remove()`) — used when handing off into `BpIntro`, which draws the identical mark at
the identical spot, so a cross-dissolve would read as a flicker; if `fade` is `true`, it
sets `data-leaving="true"` (triggering the 620ms CSS fade) then removes the node after
`FADE_MS`. Called from `bp-intro.tsx:71` (instant) and `bp-shell.tsx:203` (faded, direct-
to-home path with no intro).

### 5.4 Ambient background layers — `bp-ambient.tsx` + `bp-ambient-layers.tsx`

`BpAmbient` computes state; `BpAmbientLayers` renders. Mounted in `bp-shell.tsx:422` as a
sibling before `BpTopBar`, skipped entirely on `search`/`live`/`sports`/`sports-event`
routes (`bp-shell.tsx:413-421` — "Live TV gets the flat canvas and no ambient at all").

Root: `<div data-bp-ambient class="pointer-events-none absolute inset-0 overflow-hidden
bg-[var(--bp-void)]">` (`bp-ambient-layers.tsx:177-181`), with a flat `bg-[var(--bp-page)]`
fill as its first child. Most layers live inside one masked envelope div spanning the end
`76%` of the width (`bp-ambient-layers.tsx:88,187-190`). Paint order:

1. **Wash** — radial brand-tinted gradient anchored at the top corner, crossfading a/b
   pair, `duration-[520ms]` (`:194-201`).
2. **Mosaic** — a rotated (-14°), scaled (1.55×) poster grid at `opacity: 0.32`, 6 columns ×
   8 posters (doubled for looping), each column drifting via
   `bp-mosaic-drift {74+ci*9}s linear infinite`, alternating direction
   (`bp-mosaic.tsx:6-9,48-65`; keyframe `bp-mosaic-drift` at `bp-tokens.ts:724-727`:
   `translate3d(0,0,0)` → `translate3d(0,-50%,0)`).
3. **Still/split band art** — fixed `opacity: 0.5` wrapper, individual images crossfade
   `duration-[560ms]`; drift class = `bp-kenburns 14s cubic-bezier(0.22,1,0.36,1) 900ms
   forwards` (`:215-256`; keyframe `bp-kenburns` at `bp-tokens.ts:734-737`: `0% scale(1.005)
   → 72% scale(1.075) translate(-1.1%,-0.7%) → 100% scale(1) translate(0,0)`).
4. **Title/hero backdrop art** — the main image stack, opacity toggled with a 440ms
   transition (`BP_TITLE_ART_FADE_MS = 440`, `:7,263`), each layer fading
   `duration-[480ms] ease-[cubic-bezier(0.4,0,0.2,1)]` and (except mid-crossfade "bridge"
   layers) animated with the same 14s Ken Burns; capped at 2 stacked layers (3 only
   mid-transition), pruned back to 1 after `PRUNE_MS = 1200` (`:9,46-63`).
5. Static scrim/fade overlays (no animation): `var(--bp-scrim-side)`, a page-fade gradient,
   a top-fade gradient (`:315-317`).
6. **Tint** — bottom-anchored radial gradient, a/b crossfade, `duration-[620ms]`, sits
   *outside* the 76% envelope at full `inset-0` (`:117-119,321-330`).
7. `LEFT_VOID` — a full-inset radial gradient (`:99-100,333`).
8. **Floor** — bottom gradient whose *height* animates (`transition-[height]
   duration-[520ms]`) to match the current row/band's resting floor value
   (`:90-91,334-337`).

`bp-drift` keyframe (`bp-tokens.ts:729-732`: `scale(1.06)` → `scale(1.14)
translate3d(-1.4%,-1%,0)`) is defined but **not referenced anywhere in the ambient/mosaic
files** — not found in this subsystem; presumably used elsewhere.

On Android TV specifically, the two hero-art `<img>` layers get `willChange: "opacity"`
(gated by `isAndroidTv()`) to force a GPU-composited crossfade rather than a main-thread
repaint — capped at 2 layers deliberately (`bp-ambient-layers.tsx:154-174`, echoing the
perf philosophy in `bp-tokens.ts:604-627`).

---

## 6. Focus and input rules

All citations relative to the repo root.

### 6.1 Spatial focus model — `bp-focus-core.ts`, `use-bp-focus.ts`

**Focusable markup contract**: an element must carry `data-bp-focusable` and must not be
`data-bp-disabled="true"` (`bp-focus-core.ts:24`). The focused element carries
`data-bp-focus="true"`, and every `[data-bp-row]` ancestor of it carries
`data-bp-row-focus` (`bp-focus-core.ts:25,27-28,406-409`) — both written exclusively by
`applyBpFocus` (`bp-focus-core.ts:393-433`), which marks the element/ancestors, reveals
`content-visibility` on ancestor rows, calls `el.focus({preventScroll:true})`
(`:414`), verifies the browser actually landed there before committing
(`:415-426`), scrolls it into view (`centerScroll`, `:430`), and plays a navigate sound
(`:431`).

**Move resolution order**, `move()` in `use-bp-focus.ts:173-367`:
1. If the ring is inside `[data-bp-grid]`, movement resolves via `gridStep`/`candidatesFor`
   scoped to that grid only — a horizontal dead-end inside a grid never escapes it
   (`use-bp-focus.ts:241-253`; `bp-focus-core.ts:540-552`).
2. If the ring is in a horizontal track (`[data-bp-scroll-x]` or a row), horizontal
   movement is scoped to that track only (`use-bp-focus.ts:255-263`,
   `bp-focus-core.ts:532-560` — "Left/Right in a chip strip leaks into whatever happens to
   sit below it" is explicitly prevented, `:555-556`).
3. Vertical movement on a self-scrolling rail resolves **by row index, not geometry**, via
   `bpRailStep` (`use-bp-focus.ts:267-279`, `bp-focus-core.ts:594-628`) — rails animate
   their transform, so cross-row geometry is unreliable for ~420ms (`use-bp-focus.ts:265-266`).
4. Otherwise, `moveVertically`/`candidatesFor` ranks every measured focusable on the page by
   direction (`use-bp-focus.ts:84-130`, `bp-focus-core.ts:149-155` `rankMeasured`).
5. If nothing is found, off-screen rows (hidden via `content-visibility:auto`) are revealed
   and re-measured once (`use-bp-focus.ts:105-124`, `bp-focus-core.ts:99-114`).
6. If still nothing, a nudge/shake animation plays plus an audible hover click
   (`nudge`, `use-bp-focus.ts:70-82`, `SFX.hover` at `:81`).

**Escape to the nav bar**: Left (Right in RTL) out of the start of a row jumps straight to
the top nav bar rather than walking upward row by row — modeled on "Apple's tvOS rule that
focus returns to the tab bar from anywhere" (`use-bp-focus.ts:192-197`, `toNav` at
`:204-208`). A row can declare its owning tab via `data-bp-row-tab`, so Left out of a
Movies row lands on the Movies tab specifically (`use-bp-focus.ts:197-203`,
`bpChromeOrder` at `bp-focus-core.ts:211-219`).

**Row "see all" escape**: Right at the end of a row (Left in RTL) reaches that row's "see
all" if present; Left off the see-all returns to the cell it was pressed from
(`use-bp-focus.ts:210-213,221-228`, `bpSeeAllEnter`/`bpSeeAllExit`).

**Focus memory** (`bp-restore.ts`): two memories are kept — a whole-route position
(`rememberBpPosition`/`readBpPosition`, `:13-19`), restored once on route entry, and a
per-row position keyed by `routeKey + rowKey` (`rememberBpRowPosition`/`readBpRowPosition`,
`:26-32`), restored whenever vertical entry lands on a row via `bpRailStep`, which looks up
the remembered cell by `data-bp-restore-key` (`bp-focus-core.ts:612-617`); with no
remembered cell it falls back to the first non-"lead" cell (`:619-624`,
`isBpLeadKey` at `:564-568`). A row's own "see all" is deliberately never remembered as a
row position — "Down then Up return to the heading rather than to the card"
(`use-bp-focus.ts:159-162`).

**Route-entry restore/seeding**: on mount, a saved whole-route position is looked up by
`data-bp-restore-key` and focused silently; failing that, an element flagged
`data-bp-autofocus="true"` is used, else the first focusable on the page
(`use-bp-focus.ts:400-438,493-495`, `recoverBpFocus`). A `MutationObserver` plus a
6-second settle window (`SETTLE_WINDOW_MS`, `:66,394-471`) keeps retrying while content
streams in.

**Key handling / repeat throttling**: arrow keys are captured on `window` in the capture
phase (`use-bp-focus.ts:594-601`). Held-key repeats are throttled to ≥90ms apart
(`REPEAT_MIN_MS`, `:134,540-546` — "eleven steps a second on a hold," `:132-133`). Before
spatial nav runs, an arrow press is offered in order to: the program guide handler
(`bpGuideHandledKey`, `:520`), the queue handler (`bpQueueHandledKey`, `:526`), the
onboarding handler (`bpOnboardHandledKey`, `:531`), and a caller-supplied `onDir` (`:532`)
— each declines with `false` to fall through to normal spatial navigation.

### 6.2 Select/OK, Back/Menu, Play-Pause, "long-press" per context

**No literal "long-press" gesture exists** anywhere in `src/views/big-picture/` or
`src/lib/` (searched for `longPress`/`long-press`/`LongPress` — not found). Its functional
equivalent is a dedicated **Options** action, bound to `Tab` on a keyboard and to
`ContextMenu`/a gamepad's north (Y) button on a remote/controller:
- Key handler: `(e.key === "Tab" || e.key === "ContextMenu") && onOptions` →
  `SFX.open()` then `onOptions()` (`use-bp-focus.ts:581-586`).
- Gamepad: `north: "options"` (`src/lib/gamepad/mapping.ts:27`), dispatched as synthetic
  key `ContextMenu` (`TV_NAV_KEY.options`, `src/lib/keyboard-navigation.ts:1491`).

**Select/OK** — `Enter`/`Space` when not editing text (`use-bp-focus.ts:558-563`) →
`select()` (`:369-386`): plays `SFX.click()`, marks the tile pressed via `bpPressOn`
(visual press state, auto-clears after 400ms, `bp-press.ts:32-40`), then calls `el.click()`
on the marked focusable, scoped to the topmost open dialog if any (`bpFocusScope`,
`use-bp-focus.ts:372`, `bp-focus-core.ts:468-472`) — so Enter cannot reach a row hidden
behind a dialog. What Select *does* is entirely delegated to the element's own `onClick`
(card → detail route, chip → toggle filter, etc.).
- **Player, chrome idle**: Select calls `playbackRef.current.playPause()` then
  `wakeChrome()` (`bp-player-shell.tsx:203-206,228`) — i.e. **Select/OK toggles
  play/pause when the player chrome is hidden**. With chrome up, Select acts on whatever
  transport control has the ring instead (`:211-222`).

**Back/Menu** — `Escape`/`Backspace` (Backspace ignored while editing text) →
`SFX.close()` then `onBack()` (`use-bp-focus.ts:565-572`), always routed through the
shared back-stack (§6.4). Context behavior:
- Shell root: `onBack = runBpBack()` only (`bp-shell.tsx:291-293`); the shell's own
  fallback handles who's-watching → phone-typing → exit-confirm → quick-actions → sources
  panel → `popBigPicture()` → platform-specific root behavior.
- Player: tries `runBpBack()` first; else if a panel is locked, no-op; else if a panel is
  open, closes it and wakes the chrome; else just hides the chrome — "Back does not leave
  playback from here… the next Back falls through uncaught to the player's own
  confirm-and-exit" (`bp-player-shell.tsx:183-196`).
- Player idle (chrome down): Up/Down/Space summon the chrome (`use-bp-player-keys.ts:51-56,
  68-71`); Enter selects/toggles play-pause (`:61-66`); **Left/Right are deliberately not
  consumed** and fall through to the player's own rebindable seek (`:22-26,56-58`).
- Exit-confirm dialog: Back = Cancel (`bp-exit-confirm.tsx:22-29`).
- Search keyboard sheet: Back = Done, closes the sheet (`bp-keyboard-sheet.tsx:44-48`).

**Play-Pause**: no Big-Picture-specific "PlayPause" key distinct from Select — OS media
keys (`MediaPlayPause`/`MediaPlay`/`MediaPause`/`MediaStop`) are handled globally by the
underlying player hook, not BP code
(`src/views/player/hooks/use-keyboard-shortcuts.ts:166-177`); BP's player chrome leaves
playback itself untouched ("Playback itself is untouched: mpv, the bridge and every hook
in views/player stay exactly where they are. This is chrome and a focus layer around them,"
`bp-player-shell.tsx:74-76`). Desktop default hotkey for `playerPlayPause` is `Space`
(`src/lib/hotkeys.ts:116-122`); a gamepad's south (A) button sends `Space` while the
player is active (`PLAYER_BUTTON.south`, `src/lib/gamepad/mapping.ts:43`).

**Options/menu button** per context: shell root opens phone-typing panel on the search
route, else toggles quick-actions (`bp-shell.tsx:298-305`); player wakes the chrome in
both idle and active states (`bp-player-shell.tsx:214,229`).

### 6.3 "Focus is not activation" for text inputs

Repo-wide rule (`AGENTS.md`, Navigation and Input): *"Focus and activation are separate
actions… Focusing an input must not start editing it. Inputs become editable only after
explicit activation."* Two concrete implementations found in Big Picture:

**Search field** (`search/bp-search-input.tsx`): the `<input>` (`:67-91`) is
`data-bp-focusable` and only shows a border-highlight ring when focused (`:52,58-61`) — it
does **not** open the keyboard on focus. Typing begins only after explicit activation:
pressing Select/Enter or clicking calls `onStartTyping` (`:77-87`), wired in
`bp-search.tsx:118-122` to `startTyping()` (`markBpInteracted(); setTyping(true)`; on
Android only, also focuses the native input to summon the OS IME) — comment: "The
keyboard is a bottom sheet that only exists once the field is activated." The sheet itself
(`bp-keyboard-sheet.tsx`) is `inert` and translated off-screen while `open` is false
(`:60-65`), becoming a focus-trap dialog only once activated (comment `:16-19`: "the ring
cannot leave for the grid until Done or Back is pressed").

**Onboarding field** (`onboarding/bp-onboard-field.tsx`): doc-comment states the rule
directly — "`data-tv-text-auto` so focus alone arms the phone keyboard, and it never
persists on keystroke, only the screen above it decides when a draft becomes a saved
value" (`:10-13`). On Android specifically the input is held `readOnly`
(`inputMode="none"`) until armed: "focusing a writable input throws the system IME over
the whole screen before the user has asked for anything. Held readOnly until OK, so the
keyboard is a choice." (`:43-46`). Enter while locked sets `armed=true` and refocuses the
input rather than editing (`:75-82`); blur resets `armed` to false (`:87`).

**General mechanism** (`src/lib/remote/text-entry.ts`): two attributes gate whether a
phone-remote connection may treat a focused element as live text entry —
`data-tv-text-auto` ("Explicit opt-in: focus alone publishes textEntry," `:18-19`) vs.
`data-remote-text-active` ("Armed by select/tap — focus alone does not publish textEntry,"
`:22`). `readHostTextEntry()` (`:43-51`) only reports a field editable if `isArmed()`
(`:38-40`) — i.e., **by default, focus alone is not activation** unless a field is
explicitly flagged auto. Visual distinction between focused/activated is behavioral
(readOnly state / keyboard-sheet visibility), not a separate caret/cursor style — both
`bp-search-input.tsx:58-61` and `bp-onboard-field.tsx:58-59` show the same border-highlight
on focus alone, as a wayfinding cue only.

Also confirmed in §7: Big Picture's PIN entry (`bp-who-is-watching-pin.tsx`) sidesteps the
whole question by being a **custom numeric keypad**, not a native text field that could
receive stray keystrokes on focus.

### 6.4 Back-stack — `bp-back.ts`

`bp-back.ts` (24 lines) implements a simple **LIFO handler stack**, not a route stack:
- `pushBpBack(fn)` (`:7-13`) appends a handler, returns an unregister function.
- `runBpBack()` (`:15-20`) walks handlers **from most-recently-registered backward**; the
  first handler returning `true` stops the walk. Comment: "Back pops one layer at a time.
  A nested dialog registers here so the shell's own chain never tears down the panel the
  dialog is sitting on" (`:5-6`).
- On module load, `window.__harborBack = runBpBack` (`:22-24`) so native/Android Back can
  reach it (`bp-shell.tsx:244-249`: "MainActivity read false off every plain route and
  called leave()").

Every dialog/panel/sheet registers its own handler on mount and unregisters on unmount, so
layers pop in reverse-open order. Concrete registrants:
- `BpExitConfirm`: Back = Cancel (`bp-exit-confirm.tsx:22-29`).
- `BpKeyboardSheet`: Back = Done (`bp-keyboard-sheet.tsx:44-48`).
- **Shell root fallback** (registered once, `bp-shell.tsx:289`; logic at `:250-282`) —
  the actual row→rail / page→home / dialog→page / player→detail hierarchy, as an if-chain:
  who's-watching chooser close → phone-typing panel close → exit-confirm dismiss →
  quick-actions panel close → sources panel close → `popBigPicture()` (pop the route stack)
  → **platform split**: on Android TV, decline (`return false`) so the launcher's own Back
  finishes the activity; otherwise (desktop/window), show `BpExitConfirm`
  (`setConfirmExit(true)`, `:279-281`).
- **Player** (`bp-player-shell.tsx:183-196`): `runBpBack()` first, else no-op if locked,
  else close an open panel, else hide the chrome — leaving the *next* Back to fall through
  to the player's own confirm-and-exit (implementation outside `views/big-picture/`, not
  traced further — out of scope).

The actual page/route stack lives separately, in `src/lib/big-picture.tsx`: `pushBigPicture`
(`:67-72`) dedupes an identical top-of-stack route; `popBigPicture` (`:74-79`) returns
`false` if only one entry remains (i.e., at Home there is nothing left to pop — this is
what lets Back reach the exit-confirm/Android-decline branch); `resetBigPictureToHome`/
`goBigPictureTab` (`:86-90,107-114`) collapse the stack to `[HOME]` or `[HOME, {kind}]`
when switching tabs — "Tabs never stack on themselves… or Back means two different things"
(`:105-106`).

### 6.5 Exit confirmation — `bp-exit-confirm.tsx`

157 lines. **Trigger**: rendered by the shell only when `confirmExit` is true, set exactly
when Back is pressed at the stack root on a non-Android-TV platform (§6.4,
`bp-shell.tsx:279-281`). No other trigger site was found in `src/views/big-picture/`.

**Copy, verbatim** (all via `t()`):
- Title: **"Back to the window?"** (`:88`)
- Body: **"Big Picture closes. Harbor keeps running behind it."** (`:100`)
- Cancel button: **"Not now"** (`:128`)
- Confirm button: **"Leave Big Picture"** (`:151`)

**Options**: exactly two buttons — "Not now" (cancel) and "Leave Big Picture" (confirm)
(`:110-152`) — plus clicking the scrim outside the dialog also cancels (`:54-56`), and Back
itself cancels via the registered handler (`:22-29`).

**On confirm** (`:135-142`): plays `SFX.close()`, calls `onConfirm()` (shell-side, expected
to actually exit Big Picture — wiring not traced further, out of scope).
**On cancel** (button, Back, or scrim click; `:110-119`): plays `SFX.click()` (button
path), calls `onCancel()`; the dialog's mount effect restores whatever previously held
focus on close if that element is still connected (`:39-45`).

**Default focus**: **"Not now" (cancel) is auto-focused** on open —
`data-bp-autofocus="true"` (`:115`), not the destructive option; comment: "The difference
between these two is which one the ring is on" (`:131-134`). The confirm button
deliberately carries **no** `data-bp-restore-key`: "With one, Back-then-Back would reopen
this dialog pre-selected on Leave. It must always open on Not now." (`:104-105`).

**Motion**: respects `prefers-reduced-motion: reduce` (`:10-13,35,72`); deliberately avoids
a full-screen `backdrop-filter` for TV-hardware performance reasons (`:48-50`).

---

## 7. First-launch flow, screen by screen

Order of screens a first-time viewer sees: **boot splash → `BpIntro` → 10-step onboarding
wizard → (if not connected) `bp-connect` → `bp-who-is-watching` → Home.**

### 7.0 Boot splash → `BpIntro` (not user-facing copy; not part of the 10-step wizard)

`src/views/big-picture/bp-intro.tsx` / `use-bp-intro.ts` / `bp-intro-pool.ts`. This is
**not a marketing/onboarding step** — it is the app's every-session boot/splash overlay,
shown whenever Big Picture activates and content isn't ready yet, not gated to first
launch (`use-bp-intro.ts:17-18`). It shows 8 auto-scrolling columns of poster art (sourced
from the live home rows, or a cached pool from the previous session,
`bp-intro.tsx:74-88`, `bp-intro-pool.ts:13-23`), a radial scrim, the animated Harbor mark,
and a spinner — **everything is `aria-hidden`** (`bp-intro.tsx:94`), so there is no
copy to quote. Stays up **5000–8000ms** from the real boot start
(`MIN_VISIBLE_MS=5000`, `MAX_VISIBLE_MS=8000`, `use-bp-intro.ts:4-13`), skippable early by
any keypress/pointerdown. A comment at `bp-onboard-steps.ts:36-39` states the wizard's old
"Splash and welcome" steps were removed because "Big Picture already owns its front door in
BpIntro" — but `BpIntro` itself carries no welcome text.

### 7.1 Onboarding wizard — `src/views/big-picture/onboarding/`

Step order/registry: `bp-onboard-steps.ts:40-132` (`BP_ONBOARD_STEPS`); component mapping:
`bp-step-registry.ts:19-33`. Ordering rationale, quoted verbatim
(`bp-onboard-steps.ts:36-39`):
> "Order is the product. Language first because it reframes every later screen. The phone
> offer sits second so the three screens that need typing are adjacent and the user picks
> the phone up once."

Mounts only after the intro splash is down: `useBpOnboardingGate(chrome.mounted &&
!introUp)` (`bp-shell.tsx:209`); first-run state persisted at localStorage key
`harbor.onboarding.bp` (`bp-onboarding.tsx:22-53`).

**All ten steps, in order** (id — eyebrow / headline / body, each string quoted verbatim;
all citations `bp-onboard-steps.ts` unless noted):

1. **`language`** (`:41-48`) — eyebrow "Language"; headline **"Choose your language"**;
   body "Harbor speaks this everywhere. You can change it later in Settings."
   Primary: "Continue"; no skip. `steps/bp-step-language.tsx`: scrollable list of
   languages (current language first); picking one auto-advances (no explicit Continue
   press needed).

2. **`phone`** (`:49-60`) — eyebrow "Your phone"; headline **"Finish setup on your
   phone"**; body "The next three screens need typing. Scan this and your phone does it
   for you." Primary: "Set this up on the TV instead"; once phone hand-off completes, the
   primary label flips to "Continue". `steps/bp-step-phone.tsx`: `BpHandoffPanel`
   (QR code + pairing code) plus a 3-item checklist ("Artwork and rows", "Your Stremio
   library", "A Harbor account"). Secondary actions: "Turn on phone setup", "Show a new
   code". Status notes (`bp-handoff-panel.tsx:77-103`), e.g. waiting: "Your phone needs to
   be on the same Wi-Fi as this TV."; complete: "All set. Everything below came over from
   your phone."; stalled: "Nothing has connected yet. Your phone may be on a guest
   network, or this TV may be on a different network from your phone."

3. **`tmdb`** (`:61-70`) — eyebrow "Artwork and rows"; headline **"Connect TMDB"**; body
   "Free, two minutes. Unlocks Trending, In Theaters, Top Rated and every service rail."
   Primary: "Continue"; skip: "Use Cinemeta instead". `steps/bp-step-tmdb.tsx`: field
   labeled "TMDB API key, v3 auth", placeholder "32 characters"; actions "Verify key" /
   "Checking…", "Save it anyway" (key unreachable), "Keep the key I have" (already saved).
   Notes: "TMDB did not accept that key. Check you copied the v3 key, not the read access
   token." / "Could not reach TMDB from this TV. You can save the key without checking
   it." When already connected: title "TMDB connected", detail "The key is saved on this
   device only.", action "Use a different key".

4. **`stremio`** (`:71-79`) — eyebrow "Your library"; headline **"Bring in your
   library"**; body "Your Continue Watching, your watchlist and your addons." Primary:
   "Continue"; skip: "Not now". `steps/bp-step-stremio.tsx`: sign-in form, fields "Email"
   (placeholder "you@example.com") and "Password" (placeholder "Your Stremio password");
   action "Sign in" / "Signing in…"; note "Skip this and Harbor still works. Your library
   just stays local."; error fallback "Sign-in failed". Once signed in: "Signed in as
   {name}".

5. **`harbor`** (`:80-88`) — eyebrow "Harbor account"; headline **"Create a Harbor
   account"**; body "Sync your profile, themes, lists and friends. You can do this any
   time." Primary: "Continue"; skip: "Later" (ring parks here by default).
   `steps/bp-step-harbor.tsx`: **deliberately has no TV text-entry path** — comment:
   "The only step with no TV typing path, on purpose... relaying that password over a
   cleartext LAN surface is worse than not offering it here at all." Shows two info cards
   ("Themes and lists" / "Publish a theme, share a list, keep both when you reinstall." and
   "Friends" / "See what the people you follow are watching right now.") and the note
   "There is no safe way to type a password for this on a TV, so this one only happens on
   your phone. Settings has it whenever you want it." If linked via phone: "Signed in as
   {name}".

6. **`layout`** (`:89-96`) — eyebrow "Home"; headline **"How should the home screen
   read?"**; body "Harbor leads with one big title. Classic leads with rows." Primary:
   "Continue"; no skip. `steps/bp-step-layout.tsx`: two choice cards, apply instantly on
   select (auto-advance): **"Harbor"** — "A hero up top, then Top 10, Trending, In
   Theaters and your service rows."; **"Classic"** — "Continue Watching first, then your
   addon catalogs in install order."

7. **`streaming`** (`:97-105`) — eyebrow "Your services"; headline **"Turn off what you do
   not have"**; body "All of them start on. Take off the ones you do not pay for."
   Primary: "Continue"; skip: "Skip". `steps/bp-step-streaming.tsx`: grid of streaming-
   service logo tiles, each toggleable, disabled tiles badged "Off". Note: "{n} on" (once
   a TMDB key is present) or "These rows need a TMDB key before they show anything."

8. **`subtitles`** (`:106-114`) — eyebrow "Subtitles"; headline **"Which subtitle
   languages, in order?"**; body "First match wins. Most people need only one." Primary:
   "Continue"; skip: "Skip". `steps/bp-step-subtitles.tsx`: grid of 24 common subtitle
   languages as numbered toggle chips (pick order shown), plus a live subtitle preview.
   Note: "In order: {list}" or "Nothing selected. Harbor will not load a subtitle on its
   own."

9. **`taste`** (`:115-123`) — eyebrow "Taste"; headline **"What do you like?"**; body
   "Pick up to five. It shapes what Harbor surfaces first." Primary: "Continue"; skip:
   "Skip". `steps/bp-step-taste.tsx`: poster grid (6/row) of TMDB titles, tap to pick up
   to `MAX = 5`; at cap: "That is five. Deselect one to swap it out."; else "{n} of {max}
   picked". Loading: "Finding titles…" A side detail panel shows the focused title's
   backdrop/logo/rating/description with no static copy of its own.

10. **`done`** (`:124-131`) — eyebrow "Ready"; headline **"You are set up"**; body "Saved
    on this device. Another Harbor install starts fresh." Primary: **"Start watching"**;
    no skip (ring parks on the CTA). `steps/bp-step-done.tsx`: `BpDoneFlourish` (fanned
    poster stack of the user's taste picks, or 5 fallback posters, with an animated
    checkmark) plus a recap checklist: TMDB connected / "Running on Cinemeta. Add a TMDB
    key in Settings whenever you want."; "{n} streaming services on"; "Signed in as
    {name}" or "Not signed in to Stremio. Your library stays local."; "Harbor account
    linked as {name}" or "No Harbor account yet"; "Subtitles: {list}" or "No subtitle
    languages set"; conditionally "{n} titles you like". Footer: "Everything here took
    effect straight away, and it is saved on this device."

`BP_ONBOARD_LAST = BP_ONBOARD_STEPS.length - 1` → **10 steps total**
(`bp-onboard-steps.ts:134`). In-flow chrome not tied to a single step: progress bar labeled
`aria-label={t("Setup progress")}` (`bp-onboarding-frame.tsx:148`).

**i18n note**: the literal English strings written inline as `t("...")` arguments *are*
the canonical English source and simultaneously the translation key — none of the
onboarding strings above are present as separate entries in
`src/lib/i18n/locales/en.ts`. `translate.ts`'s `resolve()` falls back to returning the key
itself when no catalog entry exists (confirmed pattern across all onboarding/connect/
who's-watching strings in this document). Non-English locale files (`locales/<lang>/*.ts`)
key their translations off this exact literal English text, e.g.
`locales/ar/settings-fill.ts:457` `"Signed in as {name}": "مسجّل الدخول باسم {name}"`.

### 7.2 Sign-in / connect — `bp-connect.tsx` / `bp-connect-parts.tsx`

Title: **"Finish setting up Harbor"** (`bp-connect.tsx:83`). Body (only shown if no TMDB
key yet): "Harbor needs a TMDB key for artwork, rows and collections. It is free."
(`:86`).

**Accounts covered**: TMDB (API key, not an "account"), Stremio (status display only — no
inline sign-in form exists here), "Harbor account" (status display only). No Trakt or
other service found.

Status rows (`BpConnectStatus`, `bp-connect-parts.tsx:97-138`): "TMDB" → "Artwork, rows
and collections" (off) / "Connected" (on); "Stremio" → "Your Stremio library" (signed out)
/ "Signed in as {name}"; "Harbor account" → "Sync, themes and friends" (signed out) /
"Signed in as {name}".

**This screen is QR-code + pairing-code device linking, not email/password.**
`BpConnectQr` renders a QR (from `handoff.qr`) plus a large pairing/status code
(`bp-connect-parts.tsx:34-95`, `bp-connect.tsx:118-127`). QR accessible label: "Setup QR
code". Note while live: "Scan with your phone to sign in without typing on the remote."
Idle labels: "Getting a code ready…" or, if phone setup is off, "Phone setup is off."

TV-typed fallback (`bp-connect.tsx:133-195`): a single free-text field for the TMDB key
only (no username/password pair) — label "TMDB API key", placeholder "Replace the saved
key" (key exists) or the literal unlocalized example `"e2d78895…"` (no key yet). Buttons:
"Settings" (back), "Turn on phone setup", "Type a key on this TV"; commit row: "Checking…"
/ "Save key", "Cancel".

Verification status/error copy (`bp-connect.tsx:50-57`): "Checking with TMDB…"; **"TMDB
did not accept that key."** (rejected); **"Could not reach TMDB. Check the connection."**
(network failure).

### 7.3 "Who's watching" — `bp-who-is-watching.tsx` + PIN

Title: **"Who's watching?"** (`bp-who-is-watching.tsx:188`). Subtitle: "Pick a profile to
continue." (`:191`).

**Tile grid**: not a fixed CSS grid — rows are computed/balanced by `bpWhoRows()`
(`bp-who-is-watching-logic.ts:10-18`), max **6 tiles per row** (`BP_WHO_ROW_MAX = 6`,
`:3`), rendered as centered `flex flex-wrap` row blocks
(`bp-who-is-watching.tsx:209-231`). Row gap `clamp(22px, 3vh, 48px)` (`:207`); tile gap
`clamp(20px, 2.4vw, 56px)` (`:212`). Tile ("face") size scales with profile count
(`bpWhoFaceSize()`, `bp-who-is-watching-logic.ts:23-27`): ≤6 profiles →
`clamp(120px, 11vw, 190px)`; ≤12 → `clamp(96px, 8.6vw, 150px)`; >12 →
`clamp(76px, 6.8vw, 118px)`. Full tile hit-box = face size × **1.42**
(`bp-who-is-watching-tile.tsx:62`).

**"Add profile"**: not found — no such tile/button/string exists anywhere in the
who's-watching files; this screen only lists existing profiles.

**Kid profiles**: no dedicated "kid" badge exists — the only overlay icon is a lock badge
shown when the profile has a PIN set (`bp-who-is-watching-tile.tsx:28,96-107`), unrelated
to kid status. When kid profiles aren't selectable in the current context, the tile is
grayscale + 50% opacity (`data-bp-who-unavailable`, `bp-who-is-watching-style.ts:62-65`).
Selecting a blocked kid profile shows: **"Kids profiles are not available in Big Picture
yet."** (`bp-who-is-watching.tsx:237`).

Sync-status notices: "Signing in to your Harbor account. Your profiles will appear in a
moment." (pending); "Couldn't reach Harbor. Showing this device only." (failed), with a
"Retry" button.

**PIN entry** (`bp-who-is-watching-pin.tsx`) — a **custom 4-digit numeric keypad built
inline in this file**, distinct from the shared QWERTY `bp-keyboard.tsx`:
- `PIN_LENGTH = 4` (`:9`); `MAX_TRIES = 3` (`:10`); lockout cooldown `COOLDOWN_MS = 30000`
  (30s) (`:11`), tracked per-profile-id and surviving navigation away/back.
- Layout: `grid grid-cols-3`, digits 1–9, then Delete / 0 / Back-chevron (cancel) — a pure
  numeric pad, not alphanumeric (`:198-251`). Key size `clamp(56px, 6vh, 84px)`; grid gap
  `clamp(10px, 1.3vh, 20px)`.
- Title: "Enter {name}'s PIN" (`:172`). Subtitle: "Profile is locked. Enter the 4-digit
  PIN to continue." (`:177`), or during cooldown "Too many tries. Try again in {seconds}s."
  (`:176`).
- **Wrong PIN feedback**: no text string exists for this — the entry clears and the pad
  plays a shake animation (`data-bp-who-shake`, `bp-who-is-watching-style.ts:78-88`), or an
  opacity-blink under reduced motion; only after the 3rd consecutive miss does the
  "Too many tries…" cooldown text appear.

`bp-keyboard.tsx`/`bp-keyboard-sheet.tsx` (full QWERTY, `LETTERS`/`SYMBOLS` rows,
`bp-keyboard.tsx:7-24`) are **not used by the who's-watching PIN flow at all** — they serve
search, subtitle search, sports listings, and the onboarding text fields instead.
`BpKeyboardSheet` "Done" button label: "Done"; sheet `aria-label`: "On-screen keyboard".

---

## 8. Row and card anatomy

All citations relative to the repo root. Note: there is no `bp-hero.tsx` — the actual
Home hero component is `bp-spotlight.tsx`; `bpBoxCss`/`BP_TILE_BOX` live in
`bp-art.ts`, not `bp-grid.tsx`.

### 8.1 Hero / spotlight

**Home hero box height**: `bp-spotlight.tsx:23` authors `HERO_H =
"h-[calc(clamp(374px,58.3vh,560px)_-_var(--bp-hero-give,0px))]"`, but this is overridden by
a higher-specificity rule keyed on `[data-bp-hero-box]` (`bp-tokens.ts:218-219`):
`height: calc(clamp(300px, 42vh, 430px) - var(--bp-hero-give, 0px))`, further overridden
for Home specifically (`[data-bp-home-hero] [data-bp-hero-box]`, `bp-tokens.ts:227-228`):
`height: calc(clamp(260px, 34vh, 380px) - var(--bp-hero-give, 0px))`. `--bp-hero-give` is
`0px` off-Home, `56px` on TV for `[data-bp-home-hero]`/`[data-bp-page-hero]`
(`bp-tokens.ts:112,172-175`) — "how much of its hero box Home hands back" to the first row.
The `data-bp-home-hero` anchor is `bp-home.tsx:267`. (The **anime hero** is a separate,
taller component, `bp-anime-hero.tsx:21-24`, `h-[clamp(374px,58.3vh,630px)]`, not scoped by
`data-bp-hero-box` — out of scope here.)

**Hero content layout** (`bp-spotlight.tsx:88-172`), bottom-anchored flex column
(`flex h-full flex-col justify-end`), horizontal inset `px-[var(--bp-gutter)]`, bottom
inset `pb-[clamp(27px,3.6vh,58px)]` (`:96`), in order:
1. Optional provider mark/badge image — `h-[clamp(19px,3.2vh,29px)]`, `mb-[18px]`,
   opacity 0.85 (`:106-113`).
2. Either a clear logo image — `max-h-[clamp(104px,16.2vh,188px)]`,
   `max-w-[min(32vw,380px)]` (`:126-134`) — or, if no logo, an `<h1>` title:
   `text-[clamp(36px,5.6vh,54px)] font-semibold leading-[1.12] tracking-[-0.02em]
   font-display`, `line-clamp-2`, max-width `min(40vw,470px)` (`COPY_W`, `:25`),
   drop-shadow `0 3px 16px rgba(0,0,0,0.6)` (`:26-28`).
3. Meta/facts row — `mt-[14px]`, `flex flex-wrap gap-x-[16px] gap-y-1`,
   `text-[clamp(15.5px,1.8vh,21px)] font-semibold`: score chips, optional TMDB score
   chip, then fact strings (`:141-155`).
4. Awards corner (`MetaAwardsCorner`), absolutely positioned, translated down
   `clamp(26px,4vh,58px)` (`:157-159`).
5. Overview paragraph — `mt-[18px] line-clamp-2 text-[clamp(16px,2vh,23px)]
   leading-[1.55]`, same `COPY_W` max-width (`:162-169`).

**No action buttons in the Home hero** — `BpSpotlight` renders no Play/secondary-action
row at all (confirmed by full file read, cross-checked against `bp-home.tsx:267-289`,
which places only `<BpSpotlight>` + `<BpBandIdentity>`). Action buttons exist only on the
**Detail page hero** (`detail/bp-detail-hero.tsx`), a different component: title there is
`text-[clamp(52px,8.1vh,84px)]` (`:70-72`, larger than Home's), an italic
`text-[13.4px]` tagline below it (`:75-80`), a fixed `13.4px` meta-facts row (not clamp,
`:83-96`), then `<BpDetailActions>` (`:99-116`), then synopsis expand/collapse.

**Action button anatomy** (`bp-detail-actions.tsx`):
- Primary Play button: height `var(--bp-action-h)` = **47px** (`bp-tokens.ts:75`), padding
  `px-[17px]`, text `13.4px`, 14px Play icon; a `h-[3px]` progress-bar overlay renders when
  `0.01 < progress < 0.97` (`bp-detail-actions.tsx:118-123`).
- Secondary icon buttons (`BpSecondaryAction`, `:29-68`): square `var(--bp-action-box)` =
  **44px**, `var(--bp-r-xs)` (8px) radius, 20px icon/logo, `border-[var(--bp-edge-2)]`
  when inactive, solid `bg-[var(--bp-on)]` when `action.active`.
- Row gap `8px`, horizontal scroll track with `-my-[12px]` bleed (`:13-14`).

### 8.2 Continue Watching row — `bp-cw-row.tsx` / `bp-cw-card-meta.tsx`

**Card box**: `CW_CARD_BOX = { min: 268, vw: 23, max: 452 }` (`:26`) → width
`clamp(268px, 23vw, 452px)`; height = `width * 0.5625` (16:9, `CW_CARD_HEIGHT`, `:28`),
also enforced via inline `aspectRatio: "16 / 9"` (`:181`). Corner radius
`rounded-[var(--bp-r-xs)]` = 8px (`:164`).

**Bottom scrim**: `h-3/5` gradient using `var(--bp-scrim-up)` (`:169-173`).

**Top-start badges** (`BpCwCardBadges`, `bp-cw-card-meta.tsx:283-306`): watched
check-circle and `+N` new-episode pill, each `h-[clamp(21px,2.7vh,32px)]`, positioned
`start/top: clamp(11px,1.3vw,20px)`, gap `clamp(5px,0.5vw,9px)`. Watched = solid
`bg-[var(--color-ink)]` circle with a `Check` icon; new-episode = `rounded-sm` pill
`+{n}`, `text-[clamp(9.8px,1.22vh,14px)] font-bold`.

**Bottom content block** (`data-bp-cw-pad`, `:192`): `absolute inset-x-0 bottom-0`,
padding `clamp(11px,1.3vw,20px)` (= `--bp-cw-pad`), `flex-col gap-1`. Contains a title row
(clear-logo `<img>` `max-h-[clamp(24px,3.8vh,52px)] max-w-76%`, `data-bp-cw-logo`, or
fallback `<span data-bp-cw-title>` `text-[clamp(14px,1.98vh,23px)] font-bold
line-clamp-1`), a status pill below it, and an optional watcher avatar at the row's end.

**Progress bar**: `mt-1 h-[3px] w-full rounded-full bg-[var(--bp-edge-2)]` track, fill
`bg-[var(--bp-touch)]` at `width: {progress*100}%` (`:212-217`).

**Status pill** (`bp-cw-card-meta.tsx:265-266`): `bg-[var(--bp-void)]/92`,
`px-[0.62em] py-[0.34em]`, `rounded-sm`, `text-[clamp(10.5px,1.4vh,16px)] font-semibold`;
leading glyph is a Trakt/Simkl logo, a `Clock` icon (waiting for air), or a filled `Play`
glyph; trailing text is episode title / remaining time / **"Up Next"** (colored
`var(--bp-touch)`). Explicit comment (`:246-247`): "Amber and `--bp-live` both stay off
this pill" — i.e. **no live-TV badge color is used on Continue Watching cards**.

**Watcher avatar** (`BpCwWatcher`, `:333-347`): circle `h-[clamp(34px,4vh,50px)]`,
`bg-[var(--bp-panel-2)]`, ring `shadow-[0_0_0_2px_var(--bp-edge-2),0_4px_14px_rgba(0,0,0,0.55)]`.

**Loading placeholders**: 5 gray boxes (`CW_PLACEHOLDERS = 5`, `:250`), sized to the card
box, `bg-[var(--bp-panel)]`, `rounded-[var(--bp-r-xs)]` (`:281-291`). Row header title
fallback: `t("Jump back in")` (`:263`).

### 8.3 Standard poster row — `bp-row.tsx`, `bp-tile.tsx`, `bp-art.ts`

**Poster box** (`BP_TILE_BOX.poster`, `bp-art.ts:207-210`): `{min:177, vw:13, max:220}` →
`clamp(177px, 13vw, 220px)`, aspect `2 / 3` (`bp-tile.tsx:44`) — resolves to
**177 × 265.5px** on the 1140px TV canvas (13vw = 148.2px < floor).

**Wide box** (`BP_TILE_BOX.wide`): `{min:230, vw:19, max:380}` →
`clamp(230px, 19vw, 380px)`, aspect `16 / 9` — resolves to **230 × 129.4px** on TV.

**Fluid wide box** (grid contexts exceeding the tile's own box): `BP_FLUID_BOX.wide =
{min:240, vw:20, max:400}` (`bp-art.ts:212-214`).

**Fluid poster grid columns** (`BP_POSTER_COLUMNS`, `bp-grid.tsx:4-5`):
`repeat(auto-fill, minmax(clamp(122px, 9.8vw, 186px), 1fr))`.

**Ranked ("Top 10") cell**: `RANK_ART = 0.6` (poster occupies 60% of cell width,
`bp-tile.tsx:24`); `RANK_BOX` = poster box ÷ 0.6 → `min:295px, vw:21.67, max:366.67px`
(`:31-35`); cell aspect `10 / 9` (`RANK_CELL_RATIO`, `:39`); rank label tile height =
`calc(<box css> * 0.9)` (`BP_RANK_CELL_HEIGHT`, `:43`).

**Corner radius**: `rounded-[var(--bp-r-xs)]` = **8px on every tile shape** — poster,
wide, and CW card alike (`bp-tile.tsx:170`, `bp-cw-row.tsx:164`). None of the row/card
surfaces use `--bp-r-sm`/`--bp-r-md`/`--bp-r-lg` (10/16/24px) — those are reserved for
larger panels/dialogs (e.g. `BpStatusDialog`'s outer panel uses `--bp-r-lg`,
`bp-status-dialog.tsx:54`; its choice rows use `--bp-r-sm`, `:89`).

**Gap between cards in a rail**: `gap-[var(--bp-track-gap)]` (`bp-row.tsx:246`,
`bp-cw-row.tsx:271`) = `clamp(21px, 1.9vw, 32px)` (`bp-tokens.ts:67`).
**Row horizontal padding**: `px-[var(--bp-gutter)]` (`bp-row.tsx:246`) — see §4.2.
**Track vertical padding**: `pt-[clamp(12px,1.5vh,24px)] pb-[60px] -mb-[38px]`
(`bp-row.tsx:246`) — the 60px/-38px pair reserves room for a focused card's lift/bloom
overflow without shifting row rhythm.
**Grid (non-rail) gap**: `BpGrid` default `gap = clamp(10px,0.95vw,19px)`
(`bp-grid.tsx:33`), scroller padding `pt-[14px] pb-6`.

**Tile title overlay**: `text-[clamp(10.5px,1.4vh,16px)] font-semibold line-clamp-2`,
`px-2.5 pb-2` (`bp-tile.tsx:220-229`), fades in via `transition-opacity
duration-[var(--bp-focus-fade)]` on focus.

### 8.4 Card marks / badges — `bp-card-marks.tsx`, `bp-card-state-marks.tsx`

**Top-start column** (`BpCardMarks`, `bp-card-marks.tsx:84-140`): `absolute start-[7px]
top-[7px]`, `flex-col gap-[5px]`, max-width `calc(100% - 56px)`. Single "what this title
is" badge, mutually exclusive, priority order (`:118-128`):
anime award badge (`"{year} {shortLabel}"`) → classic (Oscar/Emmy-style) award badge → `t("DUB")`
(if dub available and enabled) → `t("New")` (released this calendar year) → `t("Rerun")`
(+ `" · {releaseInfo}"`, movies re-released >9 months after original release, `isRerun`
`:38-42`) → `t("In Cinema")` (`meta.inTheaters === true`, not a rerun). Chip style
(`BP_MARK_CHIP`, `:23-24`): `bg-[var(--color-ink)]` / `text-[var(--color-canvas)]`
(inverted pill), `rounded-sm`, `px-[0.68em] py-[0.3em]`,
`text-[clamp(9.8px,1.22vh,14px)] font-bold uppercase tracking-[0.04em]`. A watchlist
bookmark mark may appear below/beside it if `watchlistBadge === "topStart"`.

**Other corners** (`BpCardStateMarks`, `bp-card-state-marks.tsx`):
- Circular marks (`CIRCLE`, `:79-80`): `h-[1em] w-[1em]` where 1em =
  `clamp(21px,2.7vh,34px)`, `bg-[var(--bp-void)]/92`, `ring-1 ring-[var(--bp-edge-2)]`,
  glyph `h-[0.5em] w-[0.5em]` — used for Watchlist (`Bookmark`, filled), Watched
  (`Check`), and In-local-library (`HardDrive`).
- Top-10 ribbon: image `/toptabl.png` or `/toptabr.png` (per
  `settings.top10RibbonSide`), `absolute top-0`, `w-[27%] min-w-[34px] max-w-[72px]`,
  `start-[7px]`/`end-[7px]` (`:158-167`), deliberately no drop-shadow.
- Score chips (`BpScoreRow`) placed in whichever top-end/bottom-end zone the user's
  `badgePlacement` setting assigns (`bpCardZones`, `:39-46`); the watched-check always
  takes the *opposite* end from scores.
- All corner groups are `absolute ...-[7px]` (7px inset each edge), `gap-[5px]` between
  stacked marks (`:198-224`).
- Focused-card lift: bottom marks translate up by
  `calc(-2.5 * clamp(10.5px,1.4vh,16px) - 2px)` on focus (`LIFT_STYLE`, `:104-106`) so
  they clear the title overlay.
- **No dedicated "live" badge mark found** on poster/wide cards in these two files — the
  `--bp-live` (`#4ade80`) token exists in `bp-tokens.ts` but is explicitly excluded from
  the CW status pill (see §8.2). A live-TV-specific badge, if any, likely lives in
  `bp-live-row.tsx`/`bp-live-cell.tsx` (out of scope for this pass — not found here).

### 8.5 Empty states — `bp-empty.tsx`

Generic, caller-supplied copy — no hardcoded strings in the component itself. Layout
(`:22-45`): `min-h-[40vh]` centered flex column, `gap-[clamp(14px,1.8vh,26px)]`,
horizontal inset `px-[var(--bp-gutter)]`. Message: `max-w-[46ch]` centered,
`text-[clamp(13.5px,1.95vh,22px)] font-medium text-ink-subtle`. Optional action button:
solid ink plate, height `clamp(48px,5.6vh,66px)`, `px-[clamp(22px,2vw,40px)]`, icon
`RotateCw` (default "retry") or `SlidersHorizontal` ("setup").

Example verbatim copy from real callers:
- **"Genre shelves are built from TMDB. Add a key in Setup to fill this one."** action
  "Open Setup" — `bp-genre-grid.tsx:97-98`.
- **"Couldn't reach TMDB for {genre} titles."** action "Try again" — `bp-genre-grid.tsx:100-104`.
- **"Everything on this page of {genre} is hidden by your anime filter."** action "Show
  more" — `bp-genre-grid.tsx:107-114`.
- **"Nothing in {genre} right now."** action "Try again" — `bp-genre-grid.tsx:116-120`.
- **"Start typing to search movies, series and everything your addons carry."** (no
  action) — `bp-search.tsx:298-300`.
- **"No titles clear that rating."** action "Any rating" — `bp-person.tsx:276-280`.
- **"No filmography on record."** (no action) — `bp-person.tsx:282`.
- **"Filmographies come from TMDB. Add a key in Setup to fill this page."** action "Open
  Setup" — `bp-person.tsx:284-288`.

### 8.6 Toasts / status — `bp-controller-toast.tsx`, `bp-status.tsx`, `bp-status-dialog.tsx`

**`bp-controller-toast.tsx`** — the actual transient toast. Trigger: browser
`gamepadconnected` event (`:99-104`), fires regardless of the app's own controller-input
setting. Timing: appears 30ms after mount, visible 3000ms, unmounts at 3360ms
(`:112-121`) — toast-specific, distinct from the generic `--bp-*-dur` tokens (the slide
transition itself does use `duration-[var(--bp-dur)]`). Position: `fixed inset-x-0
bottom-0 z-[85]`, centered, `pb-[clamp(72px,9vh,120px)]` (`:126-127`). Style: rounded card
`rounded-[var(--bp-r-lg)]` (24px), `border border-[var(--bp-edge-2)]`, background
`color-mix(in oklab, var(--bp-panel) 92%, var(--bp-void))`, shadow
`0 24px 60px -20px rgba(0,0,0,0.85)`, padding `px-[clamp(20px,1.8vw,32px)]
py-[clamp(14px,1.5vh,22px)]`; slides from `translate-y-[130%] opacity-0` to
`translate-y-0 opacity-100` (`:129-132`). Content: a hand-drawn SVG controller silhouette
(Xbox/DualSense/generic, classified from `gamepad.id` via regex, `:9-14`) plus two lines
of text. Verbatim copy (`label()`, `:81-85`): **"Xbox controller connected"**,
**"DualSense connected"**, **"Controller connected"** (generic fallback); subtitle
**"Ready to play"** (`:154`).

**`bp-status.tsx`** — **not a toast**; the persistent top-bar status cluster (Wi-Fi/offline
icon, battery percentage, sync-stale cloud-off icon). Icons `h-[clamp(14px,1.9vh,22px)]`,
`text-danger` color when offline or sync-stale, `aria-label={t("Changes not saved to your
Harbor account yet")}` on the stale icon (`:110-115`). No visible copy except the battery
`{pct}%` number — Wi-Fi/battery glyphs carry only `aria-label`s.

**`bp-status-dialog.tsx`** — a modal dialog (not a toast), e.g. for Trakt/Simkl
watch-status pickers (`BpTracker`). Style: full-screen scrim
`bg-[color-mix(in_oklab,var(--bp-void)_78%,transparent)]`, centered panel
`w-[min(88vw,760px)] max-h-[80vh]`, `rounded-[var(--bp-r-lg)]` (24px),
`border border-[var(--bp-edge-2)] bg-[var(--bp-panel)]`, padding `clamp(26px,3vw,46px)`
(`:52-54`). Header: tracker logo `h-[clamp(26px,3vh,38px)]` + name,
`text-[clamp(20px,2.9vh,35px)] font-display font-semibold`. Body: scrollable list of
status-choice pill buttons `h-[clamp(56px,6.2vh,78px)]`, selected state
`bg-[var(--bp-on)]` with a `Check` icon. Footer: **"Close"** button and, if removable,
**"Remove from list"** with a `Trash2` icon (`:118-138`).

### 8.7 i18n source note for §8

All strings in this section resolve through the same identity-map convention as §7: the
literal English argument passed to `t()` is simultaneously the key and the canonical
English text (`translate.ts`); the flat identity catalog for these particular strings is
`i18n/en.json` (e.g. `"Ready to play"` at line 7076, `"Xbox controller connected"` at line
10435, `"DualSense connected"` at line 3149) rather than `src/lib/i18n/locales/en.ts`,
which only holds a small set of literal overrides (e.g. `"Soccer" → "Football"`) — none of
the strings quoted in §8 are among those overrides.

---

## 9. Screenshots

**No screenshots of Big Picture / the TV interface exist in this repository.** Findings:

- `find` for PNG/WebP/JPG/GIF files matching `big-picture|bp-|tv|television|apple-?tv`
  under the repo (excluding `node_modules`) returned only unrelated assets: award badge
  icons (`public/awards/best_tv.png`, `src/assets/badges/hdtv.png`), cast-device icons for
  a "cast to TV" picker (`src/assets/cast-icons/*_tv*.webp` — Fire TV, Android TV, Roku,
  LG, Samsung etc. device logos, not app screenshots), and TVDB integration guide images
  (`src/assets/tvdb-guide/tvdb1-4.png`).
- `docs/media/` contains only vector brand marks (`harbor-mark.svg`,
  `harbor-wordmark-dark.svg`, `harbor-wordmark-light.svg`) — no screenshots.
- `README.md` embeds several product screenshots, but **all are hosted remotely** at
  `https://harbor.site/readme-media/*.png|jpg|gif` (not present in the repo) and **none is
  labeled as Big Picture / TV**: `hero.png` (desktop launch view, `README.md:33`),
  `detail.png` (`:142`), `discover.png` (`:146`), `player.png` (`:152`), `live-tv.png`
  (`:156`, desktop Live TV grid, not the TV app), `multiview.png` (`:162`),
  `together.jpg` (`:166`), `themes.png` (`:172`), `trickplay.jpg` (`:378`),
  `richactivity.gif` (`:384`). None of the surrounding captions mention "Big Picture,"
  "TV mode," or Apple TV/Android TV/Fire TV.
- `docs/` (repo docs folder) has no image files depicting Big Picture; grep for
  "big picture" (case-insensitive) across `docs/` only matches a release-notes JSON entry
  (`docs/release-notes/0.9.121.json`), not a screenshot reference.

**Conclusion**: there is no visual reference screenshot of Big Picture anywhere in this
codebase; the SwiftUI rebuild will need to be validated against this written spec and the
live component code, not against any shipped image.

---

## Notes on remaining small gaps

A handful of narrow items were explicitly marked "not found" or "out of scope" by the
research passes rather than guessed, and are worth flagging for a final pass before
implementation:

- **§5.1**: no width "expanded vs. collapsed" state exists for the top bar (it is a
  fixed-height horizontal strip, not a two-state rail) — the original brief's side-rail
  framing does not apply to this codebase; confirmed the real nav is `bp-top-bar.tsx`.
- **§6.4/6.5**: the player's own "confirm-and-exit" back-stack registrant (what happens on
  a *second* Back press from an active player) lives outside `src/views/big-picture/`
  (likely `src/views/player/`) and was out of scope for this pass.
- **§7**: onboarding's exit/leave confirmation (`BpOnboardLeave` in `bp-onboarding.tsx`)
  was located but its exact button copy was not read in full.
- **§8.4**: no dedicated "live" badge mark was found on poster/wide cards in
  `bp-card-marks.tsx`/`bp-card-state-marks.tsx`/`bp-cw-card-meta.tsx`; if Live TV rows
  carry their own card badge it would be in `bp-live-row.tsx`/`bp-live-cell.tsx`, not
  reviewed here.

Every other claim in this document is a direct file read with a `file:line` citation.
</content>
