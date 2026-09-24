// Stage 3 glue: from a title (+ episode) to ranked streams and a playable URL.
// Mirrors views/play-picker/use-imdb-id.ts, use-addons.ts and use-pipeline-result.ts without React.
import type { Addon } from "@/lib/addons";
import { torboxAddonFor, userAddons, withDebridKeys } from "@/lib/addons";
import { fetchInstalledAddons, fetchManifestAt, filterEnabled } from "@/lib/addon-store";
import { applyOrderToItems, loadDisplayOrder } from "@/lib/addons-store/reorder";
import { narrowMediaType, isAddonNativeMeta, type Meta } from "@/lib/cinemeta";
import { buildDebridClients } from "@/lib/debrid/registry";
import type { DebridStore } from "@/lib/debrid/types";
import { animeKitsuMeta } from "@/lib/providers/anime-kitsu-addon";
import { externalToKitsu, kitsuToImdb } from "@/lib/providers/anime-mapping";
import { tmdbImdbId } from "@/lib/providers/tmdb";
import { loadEffective } from "@/lib/settings/profile-store";
import type { Settings } from "@/lib/settings/types";
import { buildStreamIdsWithIdentity } from "@/lib/streams/anime-identity";
import { buildEpisodePipelineInput } from "@/lib/streams/episode-pipeline-input";
import { runPipeline, type PipelineResult } from "@/lib/streams/pipeline";
import { resolveStream, type ResolveResult } from "@/lib/streams/resolve";
import type { ScoredStream } from "@/lib/streams/types";
import type { PlayEpisode } from "@/lib/view";
import { cinemetaImdbFallback, stampAddonOrder, hasInstantMarker, isWatchHub, needsDownload, streamMatchesLangs, streamIsCached, playError, translatePickerError, isDebridFailure, displayTitle, torrentFilename, streamSummaryParts, contributorLabel } from "@/views/play-picker/picker-utils";
import { isFilterEmpty, matchesCustomFilter } from "@/lib/streams/custom-filters";
import { isVideoFile, trackersFromSources, type TorrentFile } from "@/lib/torrent/stremio-stream";
import { magnetFromHash } from "@/lib/debrid/types";
import { matchEpisodeFileIndex, type EpisodeHint } from "@/lib/streams/episode-file";
import { hasUncachedMarker } from "@/lib/streams/cached";
import { persistEffective } from "@/lib/settings/profile-store";
import { markSettingsPatched } from "./sync";
import { titleTokensPresent } from "@/lib/streams/trust";
import { isStreamDead } from "@/lib/dead-streams";
import { readPlayback, savePlayback, streamMatchesEntry, streamMatchesSource } from "@/lib/playback-history";
import { readSeasonLock, saveSeasonLock } from "@/lib/season-lock";
import { episodeSpanContains } from "@/lib/episode-span";
import { shims } from "./shims/index.js";

export type ResolvedImdb = { id: string | null; verified: boolean };
const UNRESOLVED: ResolvedImdb = { id: null, verified: false };

/** use-imdb-id.ts as a function. */
export async function resolveImdb(meta: Meta, tmdbKey: string | undefined): Promise<ResolvedImdb> {
  if (meta.id.startsWith("tt")) return { id: meta.id, verified: true };
  const ext = meta.id.match(/^(kitsu|mal|anilist|anidb):(\d+)$/);
  if (ext) {
    const source = ext[1] === "mal" ? "myanimelist" : ext[1];
    const rawId = parseInt(ext[2], 10);
    let kitsuId = source === "kitsu" ? rawId : null;
    if (source !== "kitsu" && Number.isFinite(rawId)) kitsuId = await externalToKitsu(source, rawId).catch(() => null);
    if (kitsuId && Number.isFinite(kitsuId)) {
      const addonRes = await animeKitsuMeta(`kitsu:${kitsuId}`).catch(() => null);
      if (addonRes?.imdb_id) return { id: addonRes.imdb_id, verified: true };
      const fromXml = await kitsuToImdb(kitsuId).catch(() => null);
      return fromXml ? { id: fromXml, verified: true } : UNRESOLVED;
    }
    return UNRESOLVED;
  }
  if (isAddonNativeMeta(meta)) return UNRESOLVED;
  if (tmdbKey) {
    const id = await tmdbImdbId(tmdbKey, meta.id).catch(() => null);
    if (id) return { id, verified: true };
  }
  const fallback = await cinemetaImdbFallback(meta.name, narrowMediaType(meta.type), meta.releaseInfo).catch(() => null);
  return fallback ? { id: fallback, verified: false } : UNRESOLVED;
}

const hasAnyResources = (a: Addon) => (a.manifest.resources ?? []).length > 0;

/** use-addons.ts as a function: Stremio account addons + locally installed, manifests resolved,
 * user order applied, debrid keys injected, TorBox auto-added. Stream plugins come later. */
export async function gatherStreamAddons(authKey: string | null, settings: Settings): Promise<Addon[]> {
  const stremioAddons = filterEnabled(authKey ? await userAddons(authKey).catch(() => [] as Addon[]) : []);
  const installed = filterEnabled(await fetchInstalledAddons().catch(() => [] as Addon[]));
  const merged: Addon[] = [];
  const idxByUrl = new Map<string, number>();
  for (const a of [...stremioAddons, ...installed]) {
    const existing = idxByUrl.get(a.transportUrl);
    if (existing === undefined) { idxByUrl.set(a.transportUrl, merged.length); merged.push(a); continue; }
    if (!hasAnyResources(merged[existing]) && hasAnyResources(a)) merged[existing] = a;
  }
  const resolved = await Promise.all(merged.map(async (a) => {
    if (hasAnyResources(a)) return a;
    const manifest = await fetchManifestAt(a.transportUrl).catch(() => null);
    return manifest ? { ...a, manifest } : a;
  }));
  const savedOrder = loadDisplayOrder();
  const ordered = savedOrder.length > 0 ? applyOrderToItems(resolved, savedOrder) : resolved;
  const list = withDebridKeys(ordered, { rdKey: settings.rdKey, tbKey: settings.tbKey, adKey: settings.adKey, pmKey: settings.pmKey, dlKey: settings.dlKey });
  const torbox = torboxAddonFor(settings.tbKey);
  if (torbox) {
    const i = list.findIndex((a) => a.manifest.id === "app.torbox.stremio" || a.transportUrl?.includes("stremio.torbox.app"));
    if (i >= 0) { if (list[i].transportUrl !== torbox.transportUrl) list[i] = torbox; } else list.push(torbox);
  }
  return list;
}

function debridsFor(settings: Settings): DebridStore[] {
  return buildDebridClients({ rdKey: settings.rdKey, tbKey: settings.tbKey, adKey: settings.adKey, pmKey: settings.pmKey, dlKey: settings.dlKey });
}

export type StreamSearch = {
  token: string;
  imdb: ResolvedImdb;
  streamIds: string[];
  addonCount: number;
  /** Installed order (transport URLs): orderByAddonNative groups by this, then by each stream's nativeIdx. */
  addonOrder?: string[];
  /** use-bp-streams noSources: addons.length === 0 && debrids.length === 0. */
  debridCount?: number;
  /** use-bp-stream-play seasonLock: same-source retries also run during auto-fire. */
  seasonLock?: boolean;
  result: PipelineResult | null;
  error?: string;
};

const searches = new Map<string, AbortController>();
const lastResults = new Map<string, PipelineResult>();

/**
 * Runs the whole picker pipeline for a title. Partial results arrive as
 * `harbor-tvos:streams` events `{ token, phase: "partial" | "progress", ... }`; the returned
 * value is the final result. `cancelSearch(token)` aborts.
 */
export async function search(
  token: string,
  profileId: string,
  linked: boolean,
  authKey: string | null,
  meta: Meta,
  episode: PlayEpisode | null,
  opts: { strictMode?: boolean; filterDisabled?: boolean } = {},
): Promise<StreamSearch> {
  const settings = loadEffective(profileId, linked);
  const ac = new AbortController();
  searches.get(token)?.abort();
  searches.set(token, ac);
  try {
    const imdb = await resolveImdb(meta, settings.tmdbKey || undefined);
    const streamIds = await buildStreamIdsWithIdentity(meta.id, episode ?? undefined, imdb.id, meta.behaviorHints?.defaultVideoId);
    if (streamIds.length === 0) return { token, imdb, streamIds, addonCount: 0, result: null, error: "no-stream-ids" };
    const addons = await gatherStreamAddons(authKey, settings);
    const input = buildEpisodePipelineInput({
      meta, episode: episode ?? undefined, imdbId: imdb.id, streamIds, addons, debrids: debridsFor(settings), settings,
      strictMode: opts.strictMode ?? false, filterDisabled: opts.filterDisabled ?? false, animeTitles: null,
    });
    const result = await runPipeline(
      input,
      ac.signal,
      (partial) => {
        if (ac.signal.aborted || partial.picker.all.length === 0) return;
        stampAddonOrder(partial.picker.all, partial.raw.addon);
        stampPickerRows(partial.picker.all, settings, meta, episode);
        lastResults.set(token, partial);
        shims.events.emit("harbor-tvos:streams", { token, phase: "partial", picker: partial.picker, rejected: partial.rejected.length, debridErrors: partial.debridErrors ?? [] });
      },
      (progress) => {
        if (ac.signal.aborted) return;
        shims.events.emit("harbor-tvos:streams", { token, phase: "progress", ...progress });
      },
    );
    stampAddonOrder(result.picker.all, result.raw.addon);
    stampPickerRows(result.picker.all, settings, meta, episode);
    lastResults.set(token, result);
    const seasonLock = !!settings.seasonSourceLock && (meta.type === "series" || /^(kitsu|mal|anilist|anidb):/.test(meta.id));
    return { token, imdb, streamIds, addonCount: addons.length, result, addonOrder: addons.map((a) => a.transportUrl), debridCount: debridsFor(settings).length, seasonLock };
  } catch (e) {
    return { token, imdb: UNRESOLVED, streamIds: [], addonCount: 0, result: null, error: (e as Error).message };
  } finally {
    if (searches.get(token) === ac) searches.delete(token);
  }
}

// ------------------------------------------------------------------ picker rows and saved filters
// bp-stream-row.tsx: AIOStreams-style descriptions prefix each line with a pictograph; the row
// drops the glyph and keeps the sentence. Built at runtime so an engine without Unicode property
// escapes still loads (it then keeps the glyphs).
const PICTOGRAPH: RegExp | null = (() => {
  try {
    return new RegExp("\\p{Extended_Pictographic}|\\p{Regional_Indicator}|[\\u{1F3FB}-\\u{1F3FF}]|\\u{FE0F}|\\u{200D}|\\u{20E3}", "gu");
  } catch {
    return null;
  }
})();

/** bp-stream-row.tsx plainLine. */
export function plainLine(text: string): string {
  return (PICTOGRAPH ? text.replace(PICTOGRAPH, "") : text).replace(/\s{2,}/g, " ").trim();
}

/** bp-stream-row.tsx detailLine: the summary parts, then each description line not seen yet. */
export function detailLine(description: string, summary: string[], headline: string): string {
  const seen = new Set([headline]);
  const parts = [...summary];
  for (const raw of description.split("\n")) {
    const line = plainLine(raw);
    if (!line || seen.has(line)) continue;
    seen.add(line);
    parts.push(line);
  }
  return parts.join(" · ");
}

/** What BpStreamRow prints under the headline: the one-line detail, the full description
 * (settings.fullStreamDescription) and the torrent filename (settings.pickerShowFilename). */
export type PickerRowText = { headline: string; detail: string; description: string; filename: string };

export function pickerRowText(stream: ScoredStream, showName: string, episode: PlayEpisode | null): PickerRowText {
  const addonName = contributorLabel(stream) || stream.addonId;
  const headline = plainLine(displayTitle(stream, showName, episode ?? undefined) || addonName);
  const rawDescription = stream.title?.trim() || stream.description?.trim() || "";
  const description = rawDescription.split("\n").map(plainLine).filter(Boolean).join("\n");
  return { headline, detail: detailLine(rawDescription, streamSummaryParts(stream), headline), description, filename: torrentFilename(stream) };
}

/** settings.customStreamFilters as the picker's filter menu lists them (bp-stream-chips filterMenuOptions). */
export type SavedStreamFilter = { id: string; name: string; empty: boolean };

/**
 * bp-stream-filters.ts customFilters / activeFilterId: the saved filters (synced from the desktop's
 * Stream filters panel) and the active one. `activeId` is null unless it names a saved filter.
 */
export function streamFilters(profileId: string, linked: boolean): { filters: SavedStreamFilter[]; activeId: string | null } {
  const s = loadEffective(profileId, linked);
  const list = Array.isArray(s.customStreamFilters) ? s.customStreamFilters : [];
  const filters = list.map((f) => ({ id: f.id, name: (f.name ?? "").trim(), empty: isFilterEmpty(f) }));
  const activeId = filters.some((f) => f.id === s.activeStreamFilterId) ? s.activeStreamFilterId : null;
  return { filters, activeId };
}

/** bp-stream-filters setActiveFilterId: update({ activeStreamFilterId: id }). */
export function setActiveStreamFilter(profileId: string, linked: boolean, id: string | null): string | null {
  const s = loadEffective(profileId, linked);
  const next = id != null && (s.customStreamFilters ?? []).some((f) => f.id === id) ? id : null;
  persistEffective({ ...s, activeStreamFilterId: next }, profileId, linked);
  markSettingsPatched(["activeStreamFilterId"]);
  return next;
}

/**
 * Stamps what the TV's picker rows need onto every stream it will receive: `tvRow`
 * (pickerRowText) and `tvFilters`, the ids of the saved filters the stream passes
 * (matchesCustomFilter; an empty filter passes everything, as bp-stream-filters ignores it).
 * The picker narrows by the active id with upstream's fallback when nothing passes.
 */
export function stampPickerRows(all: ScoredStream[], settings: Settings, meta: Meta, episode: PlayEpisode | null): void {
  const filters = Array.isArray(settings.customStreamFilters) ? settings.customStreamFilters : [];
  for (const s of all) {
    const out = s as ScoredStream & { tvRow?: PickerRowText; tvFilters?: string[] };
    out.tvRow = pickerRowText(s, meta.name, episode);
    out.tvFilters = filters.filter((f) => isFilterEmpty(f) || matchesCustomFilter(s, f)).map((f) => f.id);
  }
}

export function cancelSearch(token: string): void {
  searches.get(token)?.abort();
  searches.delete(token);
}

/** picker-utils translatePickerError with upstream's `{name}` substitution; null for a code it has no copy for. */
const fmt = (key: string, vars?: Record<string, string | number>) => key.replace(/\{(\w+)\}/g, (m, k: string) => (vars && k in vars ? String(vars[k]) : m));
export function failureMessage(code: string): string | null {
  const e = playError(code);
  if (e.kind === "play" && e.code === "unknown-playback") return null;
  return translatePickerError(fmt, e);
}

export type ResolveOutcome =
  | (ResolveResult & { ok: true })
  | { ok: false; code: string; tried: Array<{ slug: string; code: string }>; webUrl?: string; message: string | null; debridFailure: boolean; p2p?: P2pPlan };

// ------------------------------------------------------------------ P2P (Stage 6, librqbit)
// Upstream reaches its torrent engine through Tauri commands (lib/torrent/local-engine.ts). The
// bundle has no Tauri, so resolveStream's local-engine attempt (tryLocalEngine) always comes back
// empty and it reports an engine failure code. The TV's engine is the librqbit static library
// behind App/Sources/Torrent/TorrentEngine.swift: when resolveStream would have handed the stream
// to the local engine, the outcome carries a P2pPlan and Swift streams it there.

/** Everything TorrentEngine.swift needs to stream one torrent the way tryLocalEngine would. */
export type P2pPlan = {
  infoHash: string;
  magnet: string;
  trackers: string[];
  /** The addon's fileIdx; null → selectEngineFileIdx over the torrent's files (p2pFileIdx). */
  fileIdx: number | null;
  filename: string | null;
  season: number | null;
  episode: number | null;
  notWebReady: boolean;
  subtitles: Array<{ url: string; lang?: string; id?: string }>;
  /** settings.streamCacheRetentionHours / streamCacheMaxGb for the engine's cache sweep. */
  retentionHours: number;
  maxGb: number;
  /** resolveStream's P2P-first pick (committed, uncached, with debrids): when the engine fails,
   * resolve again with afterP2p so the debrids get their turn, as resolveStream continues upstream. */
  debridFallback: boolean;
};

/** resolve.ts engineFailureCode values after which upstream's tryTorrentEngine had tried (or
 * would try) the local engine: "unreachable"/"no-files" from a non-strict remote server fall
 * through to it, and "engine-not-ready" is what the missing Tauri engine reports. */
const LOCAL_ENGINE_CODES = new Set(["engine-not-ready", "engine-no-peers", "remote-server-unreachable"]);

/** stremio-stream.ts localTorrentAllowed / torrentsDisabled and resolve.ts tryLocalEngine's
 * remoteStreamServerStrict guard, read from the profile's effective settings. */
function localEngineAllowed(settings: Settings): boolean {
  if (settings.torrentsDisabled === true) return false;
  if (settings.directTorrentStream === false) return false;
  return !(settings.remoteStreamServerStrict === true && (settings.remoteStreamServerUrl ?? "").trim() !== "");
}

const P2P_MIN_SEEDERS = 2;

/** stremio-stream.ts engineP2pEligible (directStreamAvailable + the seeders floor), with the TV's
 * engine standing in for its Tauri check. */
function tvEngineP2pEligible(stream: ScoredStream, settings: Settings): boolean {
  if (settings.torrentsDisabled === true || !stream.infoHash) return false;
  const remote = (settings.remoteStreamServerUrl ?? "").trim() !== "";
  if (!remote && settings.directTorrentStream === false) return false;
  if (stream.seeders != null && stream.seeders < P2P_MIN_SEEDERS) return false;
  return true;
}

function p2pPlan(stream: ScoredStream, settings: Settings, hint: EpisodeHint | undefined, debridFallback: boolean): P2pPlan {
  const infoHash = stream.infoHash!.toLowerCase();
  return {
    infoHash,
    magnet: magnetFromHash(infoHash),
    trackers: trackersFromSources(stream.sources),
    fileIdx: typeof stream.fileIdx === "number" && stream.fileIdx >= 0 ? stream.fileIdx : null,
    filename: stream.behaviorHints?.filename ?? stream.behaviorHints?.fileName ?? null,
    season: hint?.season ?? stream.season ?? null,
    episode: hint?.episode ?? stream.episode ?? null,
    notWebReady: stream.behaviorHints?.notWebReady === true,
    subtitles: (stream.subtitles ?? []).map((s) => ({ url: s.url, lang: s.lang, id: s.id })),
    retentionHours: settings.streamCacheRetentionHours ?? 12,
    maxGb: settings.streamCacheMaxGb ?? 20,
    debridFallback,
  };
}

/** resolve.ts selectEngineFileIdx: the episode's file when the names say which, else the largest
 * video (or the largest file when there is no video). */
export function p2pFileIdx(files: TorrentFile[], season: number | null, episode: number | null): number {
  if (files.length === 0) return 0;
  const vids = files.filter(isVideoFile);
  const pool = vids.length > 0 ? vids : files;
  const mi = matchEpisodeFileIndex(pool.map((f) => f.name), { season: season ?? null, episode: episode ?? null });
  if (mi >= 0) return pool[mi].idx;
  return pool.reduce((a, b) => (b.length > a.length ? b : a)).idx;
}

/**
 * Turn a picked stream into a playable link (debrid unrestrict, direct URL, or P2P handoff).
 * A failure carries use-pick-handler's reading of it: the copy for the code and whether it was
 * the debrid's side (two in a row → BpDebridDownDialog).
 */
export async function resolve(
  profileId: string,
  linked: boolean,
  token: string,
  streamIndex: number,
  userCommitted = true,
  forceP2p = false,
  afterP2p = false,
  season: number | null = null,
  episode: number | null = null,
): Promise<ResolveOutcome> {
  const settings = loadEffective(profileId, linked);
  const stream: ScoredStream | undefined = lastResults.get(token)?.picker.all[streamIndex];
  if (!stream) return { ok: false, code: "no-such-stream", tried: [], message: null, debridFailure: false };
  const ac = new AbortController();
  const debrids = debridsFor(settings);
  const hint: EpisodeHint | undefined = season != null || episode != null ? { season, episode } : undefined;
  const fail = (r: { code: string; tried: Array<{ slug: string; code: string }>; webUrl?: string }, p2p?: P2pPlan): ResolveOutcome => ({
    ok: false, code: r.code, tried: r.tried, ...(r.webUrl ? { webUrl: r.webUrl } : {}),
    message: failureMessage(r.code), debridFailure: isDebridFailure(r.code, r.tried), ...(p2p ? { p2p } : {}),
  });
  // use-pick-handler: allowP2pFallback = streamMode !== "addons" || !!stream.infoHash.
  const allowP2pFallback = settings.streamMode !== "addons" || !!stream.infoHash;
  const local = localEngineAllowed(settings);

  // P2P first: the consent dialog's "Stream" (forceP2p) and streamMode "p2p" (use-pick-handler
  // onPlay) go straight to the engine; resolveStream also tries it before the debrids for a
  // committed uncached pick that carries an uncached marker. A configured remote Stremio server
  // (tryRemoteEngine) still answers first, exactly as tryTorrentEngine orders them.
  if (!afterP2p && tvEngineP2pEligible(stream, settings)) {
    const straight = forceP2p || (settings.streamMode === "p2p" && userCommitted);
    const beforeDebrids = userCommitted && allowP2pFallback && debrids.length > 0 && !streamIsCached(stream, debrids) && hasUncachedMarker(stream);
    if (straight || beforeDebrids) {
      const r = await resolveStream({ ...stream, url: undefined }, [], ac.signal, true, false, hint, true, false);
      if (r.ok) return r;
      if (local && LOCAL_ENGINE_CODES.has(r.code)) return fail(r, p2pPlan(stream, settings, hint, !straight));
      if (straight) return fail(r);
    }
  }

  const r = await resolveStream(stream, debrids, ac.signal, userCommitted, false, hint, afterP2p ? false : allowP2pFallback);
  if (r.ok) return r;
  // resolveStream fell back to the torrent engine (no debrid, or every debrid failed on an
  // uncached source) and found none: stream it through the TV's engine.
  if (!afterP2p && local && stream.infoHash && LOCAL_ENGINE_CODES.has(r.code)) return fail(r, p2pPlan(stream, settings, hint, false));
  return fail(r);
}

/**
 * use-pick-handler onPlay: a committed pick of an uncached torrent the P2P engine could stream
 * asks first (BpP2pDialog) unless p2pAutoConsent is on or a kid profile is watching.
 * engineP2pEligible's Tauri check is the TV's librqbit engine here (tvEngineP2pEligible).
 */
export function p2pConsentNeeded(token: string, profileId: string, linked: boolean, streamIndex: number, kid = false): boolean {
  const settings = loadEffective(profileId, linked);
  const stream = lastResults.get(token)?.picker.all[streamIndex];
  if (!stream) return false;
  const debrids = debridsFor(settings);
  const eligible = tvEngineP2pEligible(stream, settings);
  if (settings.p2pAutoConsent || kid) return false;
  if (settings.streamMode === "p2p" && stream.infoHash && eligible) return false;
  return !streamIsCached(stream, debrids) && eligible && (hasUncachedMarker(stream) || (!stream.url && debrids.length === 0));
}

/** BpP2pDialog "Always stream P2P": update({ p2pAutoConsent: true }). */
export function setP2pAutoConsent(profileId: string, linked: boolean): void {
  const s = loadEffective(profileId, linked);
  persistEffective({ ...s, p2pAutoConsent: true }, profileId, linked);
  markSettingsPatched(["p2pAutoConsent"]);
}

/**
 * use-bp-streams rememberedStream: the last pick for this title/episode (else the season lock's
 * source) as an index into the token's picker.all, so the list pins it on top and badges it
 * "Played last". A remembered episode pick that names another episode does not count.
 */
export function remembered(token: string, profileId: string, linked: boolean, meta: Meta, season: number | null, episode: number | null): number | null {
  const pool = lastResults.get(token)?.picker.all ?? [];
  if (pool.length === 0) return null;
  const settings = loadEffective(profileId, linked);
  const isAnimeMetaId = /^(kitsu|mal|anilist|anidb):/.test(meta.id);
  const previous = settings.rememberLastStream ? readPlayback(meta.id, season ?? undefined, episode ?? undefined) : null;
  const source = settings.seasonSourceLock && (meta.type === "series" || isAnimeMetaId) ? readSeasonLock(meta.id, isAnimeMetaId ? null : season) : null;
  let i = -1;
  let kind: "playback" | "source" | null = null;
  if (previous) { kind = "playback"; i = pool.findIndex((s) => streamMatchesEntry(s, previous)); }
  else if (source) { kind = "source"; i = pool.findIndex((s) => streamMatchesSource(s, source)); }
  if (i < 0 || kind == null) return null;
  const match = pool[i];
  if (isAnimeMetaId || episode == null || kind === "source") return i;
  if (match.episode != null && match.episode !== episode) return null;
  if (match.episode != null && match.season != null && season != null && match.season !== season) return null;
  return i;
}

/**
 * use-pick-handler's PlayerSrc.streamRef for a picked stream, trimmed to what lib/dead-streams
 * fingerprints (infoHash + fileIdx, else url, else addon + title) and what playback-history's
 * streamMatchesEntry compares, so the player can mark it dead (views/player.tsx) or forget it
 * (use-player-exit onStubEject) after the picker's search is gone.
 * TV: `url` is the addon's own link (upstream's streamRef carries none, so a url-only stream it
 * marks by addon + title is never matched by isStreamDead on the picker's side; with the url the
 * auto candidates skip it as intended).
 */
export function deadRef(token: string, streamIndex: number): Record<string, unknown> | null {
  const stream = lastResults.get(token)?.picker.all[streamIndex];
  if (!stream) return null;
  return {
    infoHash: stream.infoHash ?? null,
    fileIdx: stream.fileIdx ?? null,
    url: stream.url ?? null,
    addonId: stream.addonId ?? null,
    title: stream.title ?? null,
    parsedTitle: stream.parsedTitle ?? null,
    resolution: stream.resolution ?? null,
    source: stream.source ?? null,
    size: stream.size ?? null,
  };
}

export function forget(token: string): void {
  lastResults.delete(token);
}


// ------------------------------------------------------------------- instant play (auto-fire)
const RES_PREF: Record<string, number> = { "1080p": 0, "720p": 1, "480p": 2, "4K": 3, SD: 4 };
const LIKELY_PACK_BYTES = 12 * 1024 * 1024 * 1024;

/**
 * views/play-picker/use-auto-candidates.ts without React or Together: the streams worth firing
 * without asking, best first, as indexes into the token's picker.all. Cached and direct-URL
 * streams qualify, torrents only with P2P consent. The remembered pick and the season lock lead.
 */
export function autoCandidates(token: string, profileId: string, linked: boolean, meta: Meta, season: number | null, episode: number | null, isAnime: boolean, expectedTitles: string[] | null, prefer1080 = false): number[] {
  const result = lastResults.get(token);
  if (!result) return [];
  const settings = loadEffective(profileId, linked);
  const debrids = debridsFor(settings);
  const all = result.picker.all;
  const isCached = (s: ScoredStream) => streamIsCached(s, debrids);
  const animeId = /^(kitsu|mal|anilist|anidb):/.test(meta.id);
  const previous = settings.rememberLastStream ? readPlayback(meta.id, season ?? undefined, episode ?? undefined) : null;
  const lock = settings.seasonSourceLock && (meta.type === "series" || animeId) ? readSeasonLock(meta.id, animeId ? null : season) : null;
  const preferredLangs = [...(settings.preferredLanguages ?? []), ...(settings.preferredAudioLangs ?? []), ...(isAnime ? ["Japanese"] : [])];
  const hasStrongAddon = all.some((s) => /mediafusion|comet/i.test(s.addonName ?? ""));
  const isTorrentio = (s: ScoredStream) => /torrentio/i.test(s.addonName ?? "");

  const episodeExact = (s: ScoredStream) => episode != null && (season != null && s.season != null ? episodeSpanContains(s, season, episode) : s.episode === episode) && (season == null || s.season == null || s.season === season);
  const episodeConflict = (s: ScoredStream) => {
    if (episode == null || s.episode == null) return false;
    if (season != null && s.season != null) return !episodeSpanContains(s, season, episode);
    return s.episode !== episode;
  };
  const instantTier = (s: ScoredStream) => (!isCached(s) ? 2 : episodeExact(s) ? 0 : 1);
  const isLikelyPack = (s: ScoredStream) => episode != null && (s.seasonPack || (!episodeExact(s) && s.size != null && s.size > LIKELY_PACK_BYTES));
  const nameKnown = (s: ScoredStream) => {
    if (s.seasonPack || s.fileIdx != null || !s.parsedTitle) return true;
    if (isAnime) return !expectedTitles || expectedTitles.length === 0 || expectedTitles.some((t) => titleTokensPresent(t, s.parsedTitle!));
    return !meta.name || titleTokensPresent(meta.name, s.parsedTitle);
  };
  const addonRank = new Map<string, number>();
  for (const s of all) if (!addonRank.has(s.addonId)) addonRank.set(s.addonId, addonRank.size);

  const sorted = all.map((s, i) => ({ s, i })).sort((A, B) => {
    const a = A.s, b = B.s;
    const aw = isWatchHub(a) ? 1 : 0, bw = isWatchHub(b) ? 1 : 0; if (aw !== bw) return aw - bw;
    const ai = instantTier(a), bi = instantTier(b); if (ai !== bi) return ai - bi;
    const an = nameKnown(a) ? 0 : 1, bn = nameKnown(b) ? 0 : 1; if (an !== bn) return an - bn;
    const ap = isLikelyPack(a) ? 1 : 0, bp = isLikelyPack(b) ? 1 : 0; if (ap !== bp) return settings.seasonSourceLock ? bp - ap : ap - bp;
    const ad = needsDownload(a) ? 1 : 0, bd = needsDownload(b) ? 1 : 0; if (ad !== bd) return ad - bd;
    if (prefer1080) { const dr = (RES_PREF[a.resolution] ?? 5) - (RES_PREF[b.resolution] ?? 5); if (dr !== 0) return dr; }
    if (hasStrongAddon) { const at = isTorrentio(a) ? 1 : 0, bt = isTorrentio(b) ? 1 : 0; if (at !== bt) return at - bt; }
    if (preferredLangs.length > 0) { const al = streamMatchesLangs(a, preferredLangs) ? 0 : 1, bl = streamMatchesLangs(b, preferredLangs) ? 0 : 1; if (al !== bl) return al - bl; }
    const ar = addonRank.get(a.addonId) ?? 9999, br = addonRank.get(b.addonId) ?? 9999; if (ar !== br) return ar - br;
    const am = hasInstantMarker(a) ? 1 : 0, bm = hasInstantMarker(b) ? 1 : 0; if (am !== bm) return bm - am;
    return A.i - B.i;
  });

  const out: number[] = [];
  const seen = new Set<string>();
  const key = (s: ScoredStream) => s.url ?? s.infoHash ?? `${s.addonId}:${s.title ?? ""}`;
  const push = (i: number) => {
    const s = all[i];
    if (!s || isStreamDead(s) || isWatchHub(s) || episodeConflict(s)) return;
    // use-auto-fire topInstantPlayable: a torrent only fires on its own with P2P consent
    // (p2pAutoConsent || kid; prefer1080 is use-bp-stream-play's !!kid).
    if (!isCached(s) && !s.url && !((settings.p2pAutoConsent || prefer1080) && tvEngineP2pEligible(s, settings))) return;
    const k = key(s);
    if (seen.has(k)) return;
    seen.add(k);
    out.push(i);
  };
  const instant = (i: number) => i >= 0 && (isCached(all[i]) || !!all[i].url);
  if (lock) { const i = all.findIndex((s) => streamMatchesSource(s, lock)); if (instant(i)) push(i); }
  if (previous) { const i = all.findIndex((s) => streamMatchesEntry(s, previous)); if (instant(i)) push(i); }
  for (const { i } of sorted) push(i);
  return out;
}

/** use-pick-handler: remember what played so the next visit can fire it without asking. */
export function rememberPlayback(token: string, profileId: string, linked: boolean, meta: Meta, streamIndex: number, resolvedUrl: string | null, season: number | null, episode: number | null): boolean {
  const settings = loadEffective(profileId, linked);
  const stream = lastResults.get(token)?.picker.all[streamIndex];
  if (!stream || !settings.rememberLastStream) return false;
  const entry = {
    infoHash: stream.infoHash ?? null, fileIdx: stream.fileIdx ?? null, addonId: stream.addonId ?? null, url: resolvedUrl ?? stream.url ?? null,
    title: meta.name, parsedTitle: stream.parsedTitle ?? null, resolution: stream.resolution ?? null, releaseGroup: stream.releaseGroupNormalized ?? null,
    source: stream.source ?? null, size: stream.size ?? null, bingeGroup: stream.behaviorHints?.bingeGroup ?? null,
    cachedSlugs: Object.entries(stream.cached ?? {}).filter(([, v]) => v === true).map(([k]) => k),
  };
  savePlayback(meta.id, entry, season ?? undefined, episode ?? undefined);
  const animeId = /^(kitsu|mal|anilist|anidb):/.test(meta.id);
  if (settings.seasonSourceLock && (meta.type === "series" || animeId) && episode != null) saveSeasonLock(meta.id, entry, animeId ? null : season, animeId);
  return true;
}
