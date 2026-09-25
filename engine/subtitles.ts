// Online subtitles through upstream's providers (docs/player-spec.md §4).
import type { Meta } from "@/lib/cinemeta";
import { narrowMediaType } from "@/lib/cinemeta";
import { loadEffective } from "@/lib/settings/profile-store";
import { searchSubtitles, deduplicateAndRankSubtitleResults } from "@/lib/subtitles/search";
import { normalizeLang, languageName, filterTracksByPreferredLanguage } from "@/lib/subtitles/language";
import { prepareSubtitle } from "@/lib/subtitles/prepare";
import { safeFetchBytes } from "@/lib/safe-fetch";
import { parseSubtitle, type SubCue, type SubFormat } from "@/lib/subtitles/parser";
import { stripSdhText } from "@/lib/subtitles/sdh-filter";
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
import { isSafeProviderSubtitleUrl } from "@/lib/subtitles/provider-url";
import { subtitleTrackDownloadHeaders } from "@/lib/subtitles/provider-auth";
import { t } from "@/lib/i18n";
import type { Addon } from "@/lib/addons";
import type { PlayEpisode } from "@/lib/view";
import { buildStreamIds } from "@/lib/streams/stream-ids";
import { resolveAnimeSearchCoords } from "@/lib/subtitles/anime-numbering";
import { subtitleStreamDescriptor } from "@/lib/subtitles/provider-label";
import { rankSubtitleCandidates } from "@/lib/subtitles/search";
import { flagEmoji } from "./settingsRoom";

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

/**
 * prepare.ts defaultFetchBytes, with the raw bytes asked of the host. Without
 * `harborResponseType: "base64"` the host hands every body over as (lossy) UTF-8 text, which
 * destroyed zipped subtitles (SubDL / SubSource / OpenSubtitles archives: "invalid path") and
 * any non-UTF-8 file (a Latin-1 SRT turned into U+FFFD and failed as "decode-unhealthy")
 * before upstream's archive reader and encoding sniffing ever saw them (player tracks pass).
 */
function fetchSubtitleBytes(url: string, signal: AbortSignal, timeoutMs: number, headers?: Record<string, string>, maxBytes?: number): Promise<Response> {
  return safeFetchBytes(url, { method: "GET", signal, headers, harborResponseType: "base64", harborTimeoutMs: timeoutMs } as RequestInit, timeoutMs, maxBytes);
}

export async function prepare(url: string): Promise<{ text: string; format: string; encoding: string }> {
  // No blob: URLs in JavaScriptCore; the native side writes `text` to a file for mpv.
  const p = await prepareSubtitle({ url }, { fetchBytes: fetchSubtitleBytes, createPlayable: async () => ({ url: "harbor-tvos://subtitle", cleanup: () => {} }) });
  return { text: p.text, format: p.format, encoding: p.encoding };
}

/**
 * mpv.ts addSeedSubtitles' gate for a stream-bundled subtitle (PlayerSrc.subtitles: an addon
 * stream's `subtitles`, a home server's external files): `subtitle.trustedSource !== true &&
 * !isSafeProviderSubtitleUrl(url)` skips it, so an addon's subtitle must be a public http(s) URL
 * with no user name or password. A trusted (home-server) one passes, but only over http(s): the
 * TV has no local library, so a file path could only point into the app's own container.
 */
export function seedAllowed(url: string, trusted: boolean | null | undefined): boolean {
  if (typeof url !== "string" || !/^https?:\/\//i.test(url.trim())) return false;
  return trusted === true || isSafeProviderSubtitleUrl(url.trim());
}

/**
 * mpv.ts addSeedSubtitles' preparation of one seed: prepareSubtitle({ url, language,
 * requestHeaders: subtitleTrackDownloadHeaders(undefined, url, !trusted) }). An addon's subtitle
 * carries the public-network marker, so safeFetchBytes refuses a redirect to a private host too.
 * null when the gate refuses it; a failed download throws (the player skips that seed, as
 * upstream's "seed subtitle preparation failed" does).
 */
export async function prepareSeed(
  url: string,
  trusted: boolean | null,
  lang: string | null,
  serverHeaders?: Record<string, string> | null,
): Promise<{ text: string; format: string; encoding: string } | null> {
  if (!seedAllowed(url, trusted)) return null;
  const target = url.trim();
  // (TV) A home server's subtitle file answers only with the server's token (Plex /library/streams,
  // Jellyfin/Emby Subtitles/…/Stream): Swift hands over the stream's own headers for a trusted
  // seed on the stream's origin. An addon's seed never gets them.
  const extra = trusted === true && serverHeaders ? serverHeaders : {};
  const requestHeaders = { ...extra, ...(subtitleTrackDownloadHeaders(undefined, target, trusted !== true) ?? {}) };
  const p = await prepareSubtitle(
    { url: target, language: lang ?? undefined, requestHeaders },
    { fetchBytes: fetchSubtitleBytes, createPlayable: async () => ({ url: "harbor-tvos://subtitle", cleanup: () => {} }) },
  );
  return { text: p.text, format: p.format, encoding: p.encoding };
}

/**
 * The AVPlayer engine draws sideloaded subtitles itself, as upstream's html5 engine does
 * (lib/player/html5/bridge.ts ensureLoaded → prepareSubtitle's cues, parsed by
 * lib/subtitles/parser.ts parseSubtitle: SRT / VTT, ASS reduced to its dialogue text).
 * `text` is what `prepare` returned; `format` its format (anything else is sniffed).
 * tickCues shows `stripSdhText(cue.text)` while settings.subHideSdh is on; that happens here,
 * once per cue, and cues left empty by it are dropped (they would draw nothing).
 */
export function cues(profileId: string, linked: boolean, text: string, format?: string | null): SubCue[] {
  const known: SubFormat[] = ["srt", "vtt", "ass", "ssa", "sub"];
  const fmt = known.find((f) => f === (format ?? "").toLowerCase());
  const list = parseSubtitle(text ?? "", fmt);
  if (loadEffective(profileId, linked).subHideSdh !== true) return list;
  return list.map((c) => ({ ...c, text: stripSdhText(c.text) })).filter((c) => c.text.length > 0);
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
  // bp-subtitle-parts.tsx resultDetail: t("{count} dl", { count }) (player parity pass 2).
  if (typeof r.downloads === "number" && r.downloads > 0) parts.push(t("{count} dl", { count: r.downloads }));
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

// ------------------------------------------------------------------ S4: the subtitle step
// bp-subtitle-step.tsx + views/play-picker/hooks/use-subtitle-choices.ts: with
// settings.subtitlePreselect on, "Choose subtitles" between the stream pick and the player.

/** view.ts PlayerSrc, the parts use-subtitle-choices reads. */
export type SubtitleStepSrc = {
  meta: Meta;
  episode?: PlayEpisode | null;
  imdbId?: string | null;
  imdbIdVerified?: boolean | null;
  /** PlayerStreamRef (the picker's streamsRoom.deadRef), or null (a home-server copy). */
  streamRef?: Record<string, unknown> | null;
  /** The resolved link's file name: use-pick-handler streamRef.resolvedFilename. */
  filename?: string | null;
};

export type SubtitleChoice = {
  id: string;
  url: string;
  lang: string;
  /** The language group this result is in (languageName(lang), use-subtitle-choices groups). */
  langKey: string;
  /** BpTrackRow label: r.title || languageName(r.lang). */
  label: string;
  /** bp-subtitle-step trackDetail: source · FORMAT · the compact classification labels. */
  detail: string;
  /** `<Flag language={languageName(r.lang)}>` as settingsRoom.flagEmoji's emoji (null: no flag). */
  flag: string | null;
};

export type SubtitleChoices = {
  error: boolean;
  results: SubtitleChoice[];
  groups: { langKey: string; langDisplay: string; count: number }[];
  bestId: string | null;
};

function isAnimeStepSrc(src: SubtitleStepSrc): boolean {
  return (
    !!src.meta?.id?.startsWith("kitsu:") ||
    !!src.meta?.id?.startsWith("mal:") ||
    (src.meta?.genres ?? []).some((g) => g.toLowerCase() === "anime")
  );
}

function isJapaneseLang(lang: string): boolean {
  const l = lang.trim().toLowerCase();
  return l === "ja" || l === "jpn" || l === "jp" || l === "japanese";
}

type StepStreamRef = {
  title?: string | null;
  parsedTitle?: string | null;
  source?: string | null;
  resolution?: string | null;
  quality?: string | null;
  releaseGroup?: string | null;
  resolvedFilename?: string | null;
};

/**
 * use-subtitle-choices.ts as one call: the subtitle addons (gatherSubtitleAddons), the picked
 * stream's ids (buildStreamIds), the anime search coordinates (resolveAnimeSearchCoords), then
 * searchSubtitles with the same query and options; `groups` by languageName in result order and
 * `bestId` = rankSubtitleCandidates(results, preferredLangs, stream hints)[0]. A failed search is
 * `error: true` with no results (the step's "Couldn't load subtitles" line).
 */
export async function choices(profileId: string, linked: boolean, authKey: string | null, src: SubtitleStepSrc): Promise<SubtitleChoices> {
  const settings = loadEffective(profileId, linked) as Settings;
  const primary = settings.preferredSubLangs?.length ? settings.preferredSubLangs : (settings.preferredLanguages ?? []);
  const base = primary.length > 0 ? primary : ["English"];
  const preferredLangs = isAnimeStepSrc(src) ? base : base.filter((l) => !isJapaneseLang(l));
  const episode = src.episode ?? undefined;
  const metaId = src.meta?.id ?? "";
  const ref = (src.streamRef ?? {}) as StepStreamRef;
  // use-pick-handler: streamRef.resolvedFilename = r.data.filename ?? the stream's hinted file name.
  const streamRef: StepStreamRef = { ...ref, resolvedFilename: src.filename ?? ref.resolvedFilename ?? null };
  let addons: Addon[] = [];
  try {
    addons = await gatherSubtitleAddons(authKey);
  } catch {
    addons = [];
  }
  const enabled = (settings.subProvidersEnabled ?? {}) as { wyzie?: boolean; addons?: boolean; opensubtitles?: boolean; subdl?: boolean; subsource?: boolean };
  const candidateIds = buildStreamIds(metaId, episode, src.imdbId ?? null, src.meta?.behaviorHints?.defaultVideoId ?? null);
  const animeIds = candidateIds.some((i) => i.startsWith("kitsu:") || i.startsWith("mal:"));
  const imdbEpAligned = !animeIds || episode?.imdbEpisode == null || episode.episode === episode.imdbEpisode;
  const imdbId = src.imdbId ?? (metaId.startsWith("tt") ? metaId : undefined);
  const hints = {
    release: streamRef.title ?? streamRef.parsedTitle ?? null,
    source: streamRef.source ?? null,
    resolution: streamRef.resolution ?? null,
  };
  let results: SubResult[];
  try {
    const coords = await resolveAnimeSearchCoords({
      isAnime: isAnimeStepSrc(src),
      metaId,
      imdbId,
      imdbVerified: src.imdbIdVerified === true || metaId.startsWith("tt"),
      episode,
    });
    results = await searchSubtitles(
      {
        imdbId,
        stremioId: metaId,
        candidateIds,
        type: src.meta?.type === "series" ? "series" : "movie",
        season: coords ? coords.season : imdbEpAligned ? (episode?.imdbSeason ?? episode?.season) : episode?.season,
        episode: coords ? coords.episode : imdbEpAligned ? (episode?.imdbEpisode ?? episode?.episode) : episode?.episode,
        langs: preferredLangs,
        filename: subtitleStreamDescriptor(streamRef),
      },
      {
        timeoutMs: 7_000,
        providers: {
          wyzie: enabled.wyzie === true,
          addons: enabled.addons !== false,
          opensubtitles: enabled.opensubtitles !== false,
        },
        addons,
        preferredLangs,
        streamHints: hints,
        extra: {
          userAgent: "Harbor",
          netAllowed: true,
          subdlApiKey: settings.subdlApiKey || null,
          subsourceApiKey: settings.subsourceApiKey || null,
          enabled: { subdl: enabled.subdl === true, subsource: enabled.subsource === true },
        } as never,
      },
    );
  } catch {
    return { error: true, results: [], groups: [], bestId: null };
  }
  const groups = new Map<string, number>();
  for (const r of results) {
    const key = languageName(r.lang);
    groups.set(key, (groups.get(key) ?? 0) + 1);
  }
  const ranked = results.length
    ? rankSubtitleCandidates(results, preferredLangs, {
        ...hints,
        season: episode?.imdbSeason ?? episode?.season ?? null,
        episode: episode?.imdbEpisode ?? episode?.episode ?? null,
      })
    : [];
  return {
    error: false,
    results: results.map((r) => {
      const parts: string[] = [r.source];
      if (r.format) parts.push(r.format.toUpperCase());
      parts.push(...subtitleClassificationLabels(r, t, "compact").map(({ label }) => label));
      return {
        id: r.id,
        url: r.url,
        lang: r.lang,
        langKey: languageName(r.lang),
        label: r.title || languageName(r.lang),
        detail: parts.filter(Boolean).join(" · "),
        flag: flagEmoji(languageName(r.lang)),
      };
    }),
    groups: [...groups.entries()].map(([langDisplay, count]) => ({ langKey: langDisplay, langDisplay, count })),
    bestId: ranked[0]?.id ?? null,
  };
}
