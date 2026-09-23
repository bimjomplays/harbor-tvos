// Online subtitles through upstream's providers (docs/player-spec.md §4).
import type { Meta } from "@/lib/cinemeta";
import { narrowMediaType } from "@/lib/cinemeta";
import { loadEffective } from "@/lib/settings/profile-store";
import { searchSubtitles, deduplicateAndRankSubtitleResults } from "@/lib/subtitles/search";
import { normalizeLang } from "@/lib/subtitles/language";
import { prepareSubtitle } from "@/lib/subtitles/prepare";
import type { SubResult } from "@/lib/subtitles/types";
import { gatherStreamAddons } from "./streams";

function langCodes(names: string[] | undefined): string[] {
  const out = (names ?? ["English"]).map((n) => normalizeLang(n)).filter(Boolean);
  return out.length > 0 ? out : ["en"];
}

export async function search(
  profileId: string,
  linked: boolean,
  authKey: string | null,
  meta: Meta,
  season: number | null,
  episode: number | null,
  imdbId: string | null,
): Promise<SubResult[]> {
  const settings = loadEffective(profileId, linked);
  const langs = langCodes(settings.preferredSubLangs as string[] | undefined);
  const addons = await gatherStreamAddons(authKey, settings).catch(() => []);
  const type = narrowMediaType(meta.type);
  const results = await searchSubtitles(
    {
      imdbId: imdbId ?? (meta.id.startsWith("tt") ? meta.id : undefined),
      stremioId: meta.id,
      type,
      title: meta.name,
      year: meta.releaseInfo ? parseInt(meta.releaseInfo, 10) || undefined : undefined,
      season: season ?? undefined,
      episode: episode ?? undefined,
      langs,
    },
    {
      preferredLangs: langs,
      addons,
      providers: (settings as { subProvidersEnabled?: { wyzie?: boolean; addons?: boolean; opensubtitles?: boolean } }).subProvidersEnabled,
      timeoutMs: 12000,
    },
  );
  return deduplicateAndRankSubtitleResults(results, langs).slice(0, 40);
}

export async function prepare(url: string): Promise<{ text: string; format: string; encoding: string }> {
  // No blob: URLs in JavaScriptCore; the native side writes `text` to a file for mpv.
  const p = await prepareSubtitle({ url }, { createPlayable: () => ({ url: "harbor-tvos://subtitle", cleanup: () => {} }) });
  return { text: p.text, format: p.format, encoding: p.encoding };
}
