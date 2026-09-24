// Stage 9 themes without CSS: upstream's preset library (lib/theme.ts THEME_PRESETS,
// FEATURED_CUSTOM_THEMES, TEMPLATE_THEMES, grouped the way views/settings/theme-panel/
// custom-themes-section.tsx buildEntries does), applyTheme's token + font-pair resolution, and
// bp-tokens.ts's --bp-* color-mix derivations, all resolved to sRGB so SwiftUI can paint them.
// Custom CSS/JS/HTML layers (kawaii's gingham, ElegantFin) cannot run on tvOS; tokens, fonts,
// card/button styles, gradient backgrounds and the Aurora bokeh do.
import {
  customColorsToTokens,
  DEFAULT_THEME,
  FEATURED_CUSTOM_THEMES,
  FONT_PAIRS,
  getThemeById,
  isLightColor,
  TEMPLATE_THEMES,
  THEME_PRESETS,
  type FontPairId,
  type ThemePreset,
  type ThemeSettings,
} from "@/lib/theme";
import { nextBackgroundImage } from "@/lib/theme-background";
import type { Settings } from "@/lib/settings/types";
import { loadEffective, persistEffective } from "@/lib/settings/profile-store";
import { markSettingsPatched } from "./sync";

/** sRGB 0..1 plus alpha, the shape Swift's Color(.sRGB, red:green:blue:opacity:) takes. */
export type Rgba = [number, number, number, number];

// ------------------------------------------------------------------ CSS color parsing
type Lab = { L: number; a: number; b: number; alpha: number };

const clamp01 = (v: number) => Math.min(1, Math.max(0, v));
const toGamma = (c: number) => (c <= 0.0031308 ? 12.92 * c : 1.055 * c ** (1 / 2.4) - 0.055);

function oklabToSrgb({ L, a, b, alpha }: Lab): Rgba {
  const l = (L + 0.3963377774 * a + 0.2158037573 * b) ** 3;
  const m = (L - 0.1055613458 * a - 0.0638541728 * b) ** 3;
  const s = (L - 0.0894841775 * a - 1.291485548 * b) ** 3;
  const r = 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s;
  const g = -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s;
  const bl = -0.0041960863 * l - 0.7034186147 * m + 1.707614701 * s;
  return [clamp01(toGamma(r)), clamp01(toGamma(g)), clamp01(toGamma(bl)), clamp01(alpha)];
}

const TRANSPARENT: Rgba = [0, 0, 0, 0];

/** The color syntaxes lib/theme.ts presets use: #rgb/#rrggbb/#rrggbbaa, rgb()/rgba(), oklch(). */
export function parseCssColor(input: string): Rgba | null {
  const s = input.trim().toLowerCase();
  if (s === "transparent") return TRANSPARENT;
  if (s === "black") return [0, 0, 0, 1];
  if (s === "white") return [1, 1, 1, 1];
  const hex = /^#([0-9a-f]{3,8})$/.exec(s);
  if (hex) {
    let h = hex[1];
    if (h.length === 3 || h.length === 4) h = h.replace(/./g, (c) => c + c);
    if (h.length !== 6 && h.length !== 8) return null;
    const n = (i: number) => parseInt(h.slice(i, i + 2), 16) / 255;
    return [n(0), n(2), n(4), h.length === 8 ? n(6) : 1];
  }
  const rgb = /^rgba?\(\s*([\d.]+)[,\s]+([\d.]+)[,\s]+([\d.]+)(?:\s*[,/]\s*([\d.]+%?))?\s*\)$/.exec(s);
  if (rgb) {
    const a = rgb[4] === undefined ? 1 : rgb[4].endsWith("%") ? Number(rgb[4].slice(0, -1)) / 100 : Number(rgb[4]);
    return [Number(rgb[1]) / 255, Number(rgb[2]) / 255, Number(rgb[3]) / 255, clamp01(a)];
  }
  const oklch = /^oklch\(\s*([\d.]+)(%?)\s+([\d.]+)\s+([\d.]+)(?:deg)?\s*(?:\/\s*([\d.]+)(%?))?\s*\)$/.exec(s);
  if (oklch) {
    const L = oklch[2] ? Number(oklch[1]) / 100 : Number(oklch[1]);
    const C = Number(oklch[3]);
    const h = (Number(oklch[4]) * Math.PI) / 180;
    const alpha = oklch[5] === undefined ? 1 : oklch[6] ? Number(oklch[5]) / 100 : Number(oklch[5]);
    return oklabToSrgb({ L, a: C * Math.cos(h), b: C * Math.sin(h), alpha });
  }
  return null;
}

/**
 * CSS color-mix(x p, y) with premultiplied alpha, so mixing with `transparent` only thins alpha.
 * bp-tokens.ts mixes `in oklab`; this port resolved the shipped default palette (Theme.swift) by
 * mixing gamma-encoded sRGB, and every theme is mixed the same way so they keep the relative
 * depth the default has and the default stays exactly what ships (smoke checks the match).
 */
export function mixColor(x: Rgba, p: number, y: Rgba): Rgba {
  const wa = x[3] * p, wb = y[3] * (1 - p);
  const alpha = wa + wb;
  if (alpha <= 0) return TRANSPARENT;
  const ch = (i: number) => clamp01((x[i] * wa + y[i] * wb) / alpha);
  return [ch(0), ch(1), ch(2), clamp01(alpha)];
}

const round = (c: Rgba): Rgba => c.map((v) => Math.round(v * 10000) / 10000) as Rgba;

// ------------------------------------------------------------------ palette
export type BpPalette = {
  canvas: Rgba; surface: Rgba; elevated: Rgba; raised: Rgba;
  ink: Rgba; inkMuted: Rgba; inkSubtle: Rgba; accent: Rgba; danger: Rgba;
  void: Rgba; panel: Rgba; panel2: Rgba; on: Rgba;
};

const BLACK: Rgba = [0, 0, 0, 1];

/** bp-tokens.ts:1-18 (--bp-void, --bp-panel, --bp-panel-2, --bp-on) over a resolved --color-* token map. */
export function bpPalette(tokens: Record<string, string>): BpPalette {
  const fallback = THEME_PRESETS["cool-grey"].tokens;
  const c = (k: string) => parseCssColor(tokens[k] ?? "") ?? parseCssColor(fallback[k])!;
  const canvas = c("--color-canvas"), surface = c("--color-surface"), elevated = c("--color-elevated");
  const ink = c("--color-ink");
  const voidColor = mixColor(canvas, 0.78, BLACK);
  return {
    canvas: round(canvas), surface: round(surface), elevated: round(elevated), raised: round(c("--color-raised")),
    ink: round(ink), inkMuted: round(c("--color-ink-muted")), inkSubtle: round(c("--color-ink-subtle")),
    accent: round(c("--color-accent")), danger: round(c("--color-danger")),
    void: round(voidColor),
    panel: round(mixColor(surface, 0.88, BLACK)),
    panel2: round(mixColor(elevated, 0.92, BLACK)),
    on: round(mixColor(ink, 0.22, voidColor)),
  };
}

// ------------------------------------------------------------------ backgrounds
export type BgStop = { color: Rgba; at: number };
export type BgLayer =
  | { kind: "linear"; angle: number; stops: BgStop[] }
  | { kind: "radial"; rx: number; ry: number; cx: number; cy: number; stops: BgStop[] };

function splitTop(s: string): string[] {
  const out: string[] = [];
  let depth = 0, start = 0;
  for (let i = 0; i < s.length; i += 1) {
    if (s[i] === "(") depth += 1;
    else if (s[i] === ")") depth -= 1;
    else if (s[i] === "," && depth === 0) { out.push(s.slice(start, i).trim()); start = i + 1; }
  }
  out.push(s.slice(start).trim());
  return out.filter((p) => p.length > 0);
}

function parseStops(parts: string[]): BgStop[] | null {
  const raw = parts.map((p) => {
    const m = /^(.*?)(?:\s+(-?[\d.]+)%)?$/.exec(p.trim());
    const color = m ? parseCssColor(m[1]) : null;
    return color ? { color, at: m?.[2] === undefined ? null : Number(m[2]) / 100 } : null;
  });
  if (raw.length < 2 || raw.some((r) => r === null)) return null;
  const stops = raw as Array<{ color: Rgba; at: number | null }>;
  return stops.map((st, i) => ({ color: round(st.color), at: st.at ?? i / (stops.length - 1) }));
}

/**
 * The gradient strings presets carry as `background.image` (linear-gradient with a deg angle,
 * radial-gradient with "ellipse W% H% at X% Y%"), first layer on top as in CSS. Anything else
 * (an image url, a data: wallpaper, "none") yields no layers.
 */
export function parseGradientLayers(image: string | null | undefined): BgLayer[] {
  if (!image) return [];
  const layers: BgLayer[] = [];
  for (const part of splitTop(image)) {
    const m = /^(linear|radial)-gradient\((.*)\)$/.exec(part);
    if (!m) return [];
    const args = splitTop(m[2]);
    if (m[1] === "linear") {
      const ang = /^(-?[\d.]+)deg$/.exec(args[0] ?? "");
      const stops = parseStops(ang ? args.slice(1) : args);
      if (!stops) return [];
      layers.push({ kind: "linear", angle: ang ? Number(ang[1]) : 180, stops });
    } else {
      const shape = /^(?:ellipse|circle)?\s*(-?[\d.]+)%\s+(-?[\d.]+)%\s+at\s+(-?[\d.]+)%\s+(-?[\d.]+)%$/.exec(args[0] ?? "");
      const stops = parseStops(shape ? args.slice(1) : args);
      if (!stops) return [];
      layers.push({
        kind: "radial",
        rx: shape ? Number(shape[1]) / 100 : 0.5, ry: shape ? Number(shape[2]) / 100 : 0.5,
        cx: shape ? Number(shape[3]) / 100 : 0.5, cy: shape ? Number(shape[4]) / 100 : 0.5,
        stops,
      });
    }
  }
  return layers;
}

// ------------------------------------------------------------------ fonts
/**
 * FONT_PAIRS resolved against the fonts the app bundles (Sentient, Switzer, Fraunces). The rest
 * (Inter, General Sans, Cabinet Grotesk, IBM Plex, Plus Jakarta) are not shipped, so they fall
 * through their CSS stacks to system-ui, which on tvOS is SF.
 */
const PAIR_FACES: Record<FontPairId, { display: "sentient" | "fraunces" | "system"; sans: "switzer" | "system" }> = {
  "sentient-switzer": { display: "sentient", sans: "switzer" },
  "fraunces-inter": { display: "fraunces", sans: "system" },
  "general-sans": { display: "system", sans: "system" },
  "cabinet-switzer": { display: "system", sans: "switzer" },
  plex: { display: "system", sans: "system" },
  "plus-jakarta": { display: "system", sans: "system" },
  system: { display: "system", sans: "system" },
};

// ------------------------------------------------------------------ library
type Category = "Built-in" | "Featured";
// custom-themes-section.tsx:294-295.
const PROMOTE_TO_FEATURED = new Set(["crunch"]);
const PROMOTE_TO_BUILTIN = new Set(["velvet"]);

function library(): Array<{ theme: ThemePreset; category: Category }> {
  const list: Array<{ theme: ThemePreset; category: Category }> = [];
  for (const t of Object.values(THEME_PRESETS)) list.push({ theme: t, category: PROMOTE_TO_FEATURED.has(t.id) ? "Featured" : "Built-in" });
  for (const t of FEATURED_CUSTOM_THEMES) list.push({ theme: t, category: "Featured" });
  for (const t of TEMPLATE_THEMES) if (PROMOTE_TO_BUILTIN.has(t.id)) list.push({ theme: t, category: "Built-in" });
  // Built-in first, the way the library groups them.
  return [...list.filter((e) => e.category === "Built-in"), ...list.filter((e) => e.category === "Featured")];
}

/** lib/theme.ts resolveTokens (not exported upstream). */
function resolveTokens(theme: ThemeSettings): Record<string, string> {
  if (theme.preset === "custom" && theme.customColors) return customColorsToTokens(theme.customColors);
  if (theme.preset !== "custom") {
    const found = getThemeById(theme.preset);
    if (found) return found.tokens;
  }
  return THEME_PRESETS["cool-grey"].tokens;
}

function themeOf(s: Settings): ThemeSettings {
  return (s.theme as ThemeSettings | undefined) ?? DEFAULT_THEME;
}

export function state(profileId: string, linked: boolean) {
  const theme = themeOf(loadEffective(profileId, linked));
  const preset = theme.preset !== "custom" ? getThemeById(theme.preset) : null;
  const tokens = resolveTokens(theme);
  // applyTheme: the preset's own pairing wins over the picked one.
  const fontPair: FontPairId = (preset?.fontPair ?? theme.fontPair) in FONT_PAIRS ? (preset?.fontPair ?? theme.fontPair) : "sentient-switzer";
  // theme-backdrop.tsx: the chosen image, else the preset's. Only gradients and http(s) images
  // can be drawn here; a data: wallpaper from the desktop is left to the desktop.
  const image = theme.backgroundImage ?? preset?.background?.image ?? null;
  const layers = parseGradientLayers(image);
  const imageUrl = image && /^https?:\/\//.test(image) ? image : null;
  const presetGradient = !!preset?.background?.image && preset.background.image === image && layers.length > 0;
  return {
    active: theme.preset,
    fontPair,
    pickedFontPair: theme.fontPair,
    presetOwnsFont: !!preset?.fontPair,
    faces: PAIR_FACES[fontPair],
    palette: bpPalette(tokens),
    light: isLightColor(tokens["--color-canvas"]),
    layout: preset?.layout ?? "sidebar",
    cardStyle: preset?.cardStyle ?? "flat",
    buttonStyle: preset?.buttonStyle ?? "flat",
    bokeh: !!preset?.bokeh,
    background: {
      layers,
      imageUrl,
      // theme-backdrop.tsx: a preset's own gradient is drawn bare; anything else sits under a
      // 45% black wash and the canvas at the viewer's dim.
      dim: presetGradient ? 0 : Math.max(0, Math.min(1, theme.backgroundDim ?? preset?.background?.dim ?? 0.65)),
      scrim: !presetGradient && (layers.length > 0 || imageUrl !== null),
    },
    presets: library().map(({ theme: t, category }) => ({
      id: t.id,
      name: t.name,
      blurb: t.blurb,
      category,
      swatch: t.swatch.map((c) => round(parseCssColor(c) ?? BLACK)),
      canvasLight: isLightColor(t.tokens["--color-canvas"]),
    })),
    hasCustom: !!theme.customColors,
    fontPairs: (Object.keys(FONT_PAIRS) as FontPairId[]).map((id) => ({ id, name: FONT_PAIRS[id].name, blurb: FONT_PAIRS[id].blurb, faces: PAIR_FACES[id] })),
  };
}

function write(profileId: string, linked: boolean, next: ThemeSettings) {
  const s = loadEffective(profileId, linked);
  persistEffective({ ...s, theme: next }, profileId, linked);
  markSettingsPatched(["theme"]);
  window.dispatchEvent(new CustomEvent("harbor:settings-updated", { detail: { profileId, fields: ["theme"] } }));
}

/** theme-panel.tsx ThemeTab onSelect: the preset, carrying a theme-owned background along. */
export function apply(id: string, profileId: string, linked: boolean) {
  const theme = themeOf(loadEffective(profileId, linked));
  const known = library().some((e) => e.theme.id === id) || (id === "custom" && !!theme.customColors);
  if (!known) return state(profileId, linked);
  write(profileId, linked, {
    ...theme,
    preset: id as ThemeSettings["preset"],
    backgroundImage: nextBackgroundImage(theme.backgroundImage, getThemeById(theme.preset), getThemeById(id)),
  });
  return state(profileId, linked);
}

/** theme-panel.tsx TypographyTab onPickPair. */
export function setFontPair(id: string, profileId: string, linked: boolean) {
  const theme = themeOf(loadEffective(profileId, linked));
  if (!(id in FONT_PAIRS)) return state(profileId, linked);
  write(profileId, linked, { ...theme, fontPair: id as FontPairId, customFontId: null });
  return state(profileId, linked);
}
