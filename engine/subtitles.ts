// Online subtitles through upstream's providers (docs/player-spec.md §4).
import type { Meta } from "@/lib/cinemeta";
import { narrowMediaType } from "@/lib/cinemeta";
import { loadEffective } from "@/lib/settings/profile-store";
import { searchSubtitles, deduplicateAndRankSubtitleResults } from "@/lib/subtitles/search";
import { normalizeLang, languageName, filterTracksByPreferredLanguage } from "@/lib/subtitles/language";
import { prepareSubtitle } from "@/lib/subtitles/prepare";
import type { SubResult } from "@/lib/subtitles/types";
import type { TrackInfo } from "@/lib/player/bridge";
import type { Settings } from "@/lib/settings";
import { gatherSubtitleAddons } from "@/lib/subtitles/addon-source";
import { providerLabel, releaseOf } from "@/lib/subtitles/provider-label";
import { subtitleClassificationLabels } from "@/lib/subtitles/classification-labels";
import { subtitleTrackLanguageLabel, subtitleTrackTitle } from "@/lib/subtitles/track-label";
import { parseTitleQuery, searchTitleCandidates, bestCandidate } from "@/lib/subtitles/title-search";
import { subtitleConfidenceRank } from "@/lib/subtitles/release-match";
import { rankByRelease } from "@/components/player/subtitle-menu/best-match";
import { isVeryNewRelease } from "@/components/player/subtitle-menu/utils";
import { loadSubPresets } from "@/lib/player/sub-presets";
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

// ------------------------------------------------------------------ Big Picture subtitle panel
// bp-player-subtitles.tsx / bp-subtitle-find.tsx / bp-subtitle-parts.tsx / bp-subtitle-tune.tsx:
// the pure parts of the in-player Subtitles dialog, so Swift shows exactly upstream's labels.

const same = (key: string) => key;

/** bp-subtitle-parts.tsx tagsOf: compact classification badges ("HI/SDH", "Forced", …). */
function tagsOf(x: { hearingImpaired?: boolean; forced?: boolean; foreignOnly?: boolean; machineTranslated?: boolean }): string[] {
  return subtitleClassificationLabels(x, same, "compact").map(({ label }) => label);
}

/** bp-subtitle-parts.tsx trackDetail (a TV has no local-file import, so never "Imported"). */
function trackDetail(track: TrackInfo): string {
  const parts = [track.external ? "External" : "Embedded", subtitleTrackLanguageLabel(track)];
  if (track.codec) parts.push(track.codec.toUpperCase());
  if (track.release && track.release !== subtitleTrackTitle(track)) parts.push(track.release);
  return parts.join(" · ");
}

/** bp-subtitle-parts.tsx resultDetail. */
function resultDetail(r: SubResult): string {
  const parts = [providerLabel(r)];
  if (r.format) parts.push(r.format.toUpperCase());
  if (typeof r.downloads === "number" && r.downloads > 0) parts.push(`${r.downloads} dl`);
  const rel = releaseOf(r);
  if (rel) parts.push(rel);
  return parts.join(" · ");
}

/** mpv's subtitle track list as Swift reads it (MPVPlayerController.Track). */
export type TrackIn = {
  id: string | number;
  lang?: string | null;
  title?: string | null;
  codec?: string | null;
  external?: boolean;
  forced?: boolean;
  hearingImpaired?: boolean;
  default?: boolean;
  selected?: boolean;
  secondary?: boolean;
  externalFilename?: string | null;
};

export type TrackRow = {
  id: string;
  /** In the viewer's languages (filterTracksByPreferredLanguage), or selected / secondary. */
  keep: boolean;
  langKey: string;
  langDisplay: string;
  title: string;
  detail: string;
  tags: string[];
};

/**
 * bp-player-subtitles.tsx langTracks + groupByLang + pickBestMatch inputs. `ranked` is
 * rankByRelease's order with pickBestMatch's gate per entry: the best match of a filtered
 * pool is the first ranked id inside it, and only when that one is eligible.
 */
export function trackView(
  profileId: string,
  linked: boolean,
  tracks: TrackIn[],
  streamRelease: string | null,
  season: number | null,
  episode: number | null,
): { tracks: TrackRow[]; ranked: { id: string; eligible: boolean }[] } {
  const settings = loadEffective(profileId, linked) as Settings;
  const preferred = (settings.preferredSubLangs?.length ?? 0) > 0 ? settings.preferredSubLangs : (settings.preferredLanguages ?? []);
  const infos = tracks.map((t) => ({
    id: String(t.id),
    label: t.title || t.lang || `sub ${t.id}`,
    lang: t.lang ?? undefined,
    kind: "subtitle",
    selected: t.selected === true,
    codec: t.codec ? t.codec.toUpperCase() : undefined,
    title: t.title ?? undefined,
    external: t.external === true,
    externalFilename: t.externalFilename ?? undefined,
    forced: t.forced === true,
    default: t.default === true,
    hearingImpaired: t.hearingImpaired === true,
    secondary: t.secondary === true,
  }) as TrackInfo);
  const keep = new Set(filterTracksByPreferredLanguage(infos, preferred));
  for (const t of infos) if (t.selected || t.secondary) keep.add(t);
  const hints = streamRelease || season != null
    ? { release: streamRelease, season: season ?? undefined, episode: episode ?? undefined }
    : null;
  const ranked = rankByRelease(infos, hints).map((v) => ({
    id: v.track.id,
    eligible: subtitleConfidenceRank(v.confidence) >= 4 && v.score > 0,
  }));
  return {
    tracks: infos.map((t) => {
      const langDisplay = subtitleTrackLanguageLabel(t);
      return {
        id: t.id,
        keep: keep.has(t),
        langKey: langDisplay.toLowerCase(),
        langDisplay,
        title: subtitleTrackTitle(t),
        detail: trackDetail(t),
        tags: tagsOf(t),
      };
    }),
    ranked,
  };
}

/** bp-subtitle-find.tsx BpSubtitleTarget. */
export type SubtitleTarget = { imdbId: string; type: "movie" | "series"; title: string; season?: number; episode?: number };

export type FoundSubtitle = {
  id: string;
  url: string;
  lang: string;
  /** languageName(lang): the group heading. */
  langName: string;
  title: string;
  detail: string;
  tags: string[];
  provider: string;
  hearingImpaired: boolean;
  forced: boolean;
};

/**
 * bp-subtitle-find.tsx run(): search every subtitle source for `target` (the playing title,
 * or another title / season / episode the viewer asked for). Results keep upstream's rank;
 * Swift filters HI/Forced, groups by language and pages 40 at a time ("Show {count} more").
 */
export async function find(
  profileId: string,
  linked: boolean,
  authKey: string | null,
  target: SubtitleTarget,
  home: SubtitleTarget | null,
  stremioId: string | null,
  releaseDate: string | null,
): Promise<{ results: FoundSubtitle[]; tooNew: boolean }> {
  const settings = loadEffective(profileId, linked) as Settings;
  const enabled = (settings.subProvidersEnabled ?? {}) as { wyzie?: boolean; addons?: boolean; opensubtitles?: boolean; subdl?: boolean; subsource?: boolean };
  const addons = await gatherSubtitleAddons(authKey).catch(() => []);
  const playing = home != null && target.imdbId === home.imdbId && target.title === home.title;
  const langs = settings.preferredSubLangs ?? [];
  const found = await searchSubtitles(
    {
      imdbId: target.imdbId || undefined,
      title: target.imdbId ? undefined : target.title || undefined,
      type: target.type,
      season: target.season,
      episode: target.episode,
      langs,
      stremioId: playing ? (stremioId ?? undefined) : undefined,
    },
    {
      timeoutMs: 8_000,
      providers: {
        wyzie: target.imdbId ? enabled.wyzie === true : true,
        addons: enabled.addons ?? true,
        opensubtitles: enabled.opensubtitles ?? true,
      },
      addons,
      preferredLangs: langs,
      extra: {
        userAgent: "Harbor",
        netAllowed: true,
        subdlApiKey: settings.subdlApiKey || null,
        subsourceApiKey: settings.subsourceApiKey || null,
        enabled: { subdl: enabled.subdl === true, subsource: enabled.subsource === true },
      } as never,
    },
  );
  const results = found.map((r) => {
    const langName = languageName(r.lang);
    return {
      id: r.id,
      url: r.url,
      lang: r.lang,
      langName,
      title: releaseOf(r) || r.title || langName,
      detail: resultDetail(r),
      tags: tagsOf(r),
      provider: providerLabel(r),
      hearingImpaired: r.hearingImpaired === true,
      forced: r.forced === true,
    };
  });
  return { results, tooNew: isVeryNewRelease(releaseDate) };
}

/**
 * bp-subtitle-find.tsx submit(): turn what the viewer typed ("Show S2E5", "Movie 1999") into
 * a new target. `null` means the query is too short: search the current target again.
 */
export async function titleTarget(query: string, current: SubtitleTarget): Promise<SubtitleTarget | null> {
  const parsed = parseTitleQuery(query);
  if (parsed.title.length < 2) return null;
  const cands = await searchTitleCandidates(query).catch(() => []);
  const top = bestCandidate(cands, parsed);
  const series = top ? top.type === "series" : parsed.season != null;
  return {
    imdbId: top?.imdbId ?? "",
    type: series ? "series" : "movie",
    title: top?.name ?? parsed.title,
    season: series ? (parsed.season ?? current.season ?? 1) : undefined,
    episode: series ? (parsed.episode ?? current.episode ?? 1) : undefined,
  };
}

/** bp-subtitle-tune.tsx BpSubtitleLook "Presets" (lib/player/sub-presets loadSubPresets). */
export function presets() {
  return loadSubPresets();
}
