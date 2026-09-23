// Anime4K (lib/player/anime4k-modes.ts + views/player/hooks/use-anime4k.ts gates, and the
// shader list src-tauri/src/anime4k.rs downloads). The host downloads the files and hands mpv
// the chain as `glsl-shaders`; this decides whether and which chain applies.
import { ANIME4K_MODES, anime4kChain, type Anime4kMode, type Anime4kTier } from "@/lib/player/anime4k-modes";
import { loadEffective } from "@/lib/settings/profile-store";

const BASE = "https://raw.githubusercontent.com/bloc97/Anime4K/master/glsl";

/** Remote path → local file name, verbatim from anime4k.rs FILES. */
export const FILES: Array<{ remote: string; local: string }> = [
  { remote: "Restore/Anime4K_Clamp_Highlights.glsl", local: "Anime4K_Clamp_Highlights.glsl" },
  { remote: "Restore/Anime4K_Restore_CNN_VL.glsl", local: "Anime4K_Restore_CNN_VL.glsl" },
  { remote: "Restore/Anime4K_Restore_CNN_M.glsl", local: "Anime4K_Restore_CNN_M.glsl" },
  { remote: "Restore/Anime4K_Restore_CNN_Soft_VL.glsl", local: "Anime4K_Restore_CNN_Soft_VL.glsl" },
  { remote: "Restore/Anime4K_Restore_CNN_Soft_M.glsl", local: "Anime4K_Restore_CNN_Soft_M.glsl" },
  { remote: "Upscale/Anime4K_Upscale_CNN_x2_VL.glsl", local: "Anime4K_Upscale_CNN_x2_VL.glsl" },
  { remote: "Upscale/Anime4K_Upscale_CNN_x2_M.glsl", local: "Anime4K_Upscale_CNN_x2_M.glsl" },
  { remote: "Upscale%2BDenoise/Anime4K_Upscale_Denoise_CNN_x2_VL.glsl", local: "Anime4K_Upscale_Denoise_CNN_x2_VL.glsl" },
  { remote: "Upscale%2BDenoise/Anime4K_Upscale_Denoise_CNN_x2_M.glsl", local: "Anime4K_Upscale_Denoise_CNN_x2_M.glsl" },
  { remote: "Upscale/Anime4K_AutoDownscalePre_x2.glsl", local: "Anime4K_AutoDownscalePre_x2.glsl" },
  { remote: "Upscale/Anime4K_AutoDownscalePre_x4.glsl", local: "Anime4K_AutoDownscalePre_x4.glsl" },
];

export function files(): Array<{ url: string; local: string }> {
  return FILES.map((f) => ({ url: `${BASE}/${f.remote}`, local: f.local }));
}

export function modes(): Array<{ id: Anime4kMode; label: string; sub: string }> {
  return ANIME4K_MODES;
}

export type Choice = "auto" | "off" | Anime4kMode;

const SECONDARY_TO_PRIMARY: Partial<Record<Anime4kMode, Anime4kMode>> = { AA: "A", BB: "B", CA: "C" };

function isAnimeSrc(meta: { id: string; genres?: string[] | null }): boolean {
  if (/^(kitsu|mal|anilist|anidb):/.test(meta.id ?? "")) return true;
  return (meta.genres ?? []).some((g) => {
    const lg = g.toLowerCase();
    return lg === "anime" || lg === "animation";
  });
}

/**
 * use-anime4k.ts anime4kShadersFor: auto honours playerAnime4k + AnimeOnly; a source already at
 * display width drops the secondary pass (AA→A…); performance quality forces the fast tier.
 */
export function choose(
  profileId: string,
  linked: boolean,
  meta: { id: string; genres?: string[] | null },
  srcWidth: number,
  displayWidth: number,
): { active: boolean; choice: Choice; mode: Anime4kMode | null; tier: Anime4kTier | null; files: string[]; indicator: boolean } {
  const s = loadEffective(profileId, linked);
  const choice = ((s.playerAnime4kOverride as Choice) || "auto") as Choice;
  const off = { active: false, choice, mode: null, tier: null, files: [], indicator: s.playerAnime4kIndicator !== false };
  if (!s.playerAnime4k || choice === "off") return off;
  const tier: Anime4kTier = s.mpvQuality === "performance" ? "fast" : ((s.playerAnime4kTier as Anime4kTier) || "hq");
  let mode: Anime4kMode;
  if (choice === "auto") {
    if (!(s.playerAnime4k && (!s.playerAnime4kAnimeOnly || isAnimeSrc(meta)))) return off;
    mode = (s.playerAnime4kMode as Anime4kMode) || "A";
  } else mode = choice;
  if (srcWidth > 0 && displayWidth > 0 && srcWidth >= displayWidth) mode = SECONDARY_TO_PRIMARY[mode] ?? mode;
  // The chain is built against a placeholder folder; the host prefixes its own directory.
  const chain = anime4kChain("/", mode, tier).map((p) => p.slice(p.lastIndexOf("/") + 1));
  return { active: true, choice, mode, tier, files: chain, indicator: s.playerAnime4kIndicator !== false };
}
