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
import { cinemetaImdbFallback, stampAddonOrder, hasInstantMarker, isWatchHub, needsDownload, streamMatchesLangs, streamIsCached } from "@/views/play-picker/picker-utils";
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
        lastResults.set(token, partial);
        shims.events.emit("harbor-tvos:streams", { token, phase: "partial", picker: partial.picker, rejected: partial.rejected.length, debridErrors: partial.debridErrors ?? [] });
      },
      (progress) => {
        if (ac.signal.aborted) return;
        shims.events.emit("harbor-tvos:streams", { token, phase: "progress", ...progress });
      },
    );
    stampAddonOrder(result.picker.all, result.raw.addon);
    lastResults.set(token, result);
    return { token, imdb, streamIds, addonCount: addons.length, result, addonOrder: addons.map((a) => a.transportUrl) };
  } catch (e) {
    return { token, imdb: UNRESOLVED, streamIds: [], addonCount: 0, result: null, error: (e as Error).message };
  } finally {
    if (searches.get(token) === ac) searches.delete(token);
  }
}

export function cancelSearch(token: string): void {
  searches.get(token)?.abort();
  searches.delete(token);
}

/** Turn a picked stream into a playable link (debrid unrestrict, direct URL, or P2P handoff). */
export async function resolve(
  profileId: string,
  linked: boolean,
  token: string,
  streamIndex: number,
  userCommitted = true,
): Promise<ResolveResult | { ok: false; code: "no-such-stream"; tried: [] }> {
  const settings = loadEffective(profileId, linked);
  const stream: ScoredStream | undefined = lastResults.get(token)?.picker.all[streamIndex];
  if (!stream) return { ok: false, code: "no-such-stream", tried: [] };
  const ac = new AbortController();
  return resolveStream(stream, debridsFor(settings), ac.signal, userCommitted);
}

export function forget(token: string): void {
  lastResults.delete(token);
}


// ------------------------------------------------------------------- instant play (auto-fire)
const RES_PREF: Record<string, number> = { "1080p": 0, "720p": 1, "480p": 2, "4K": 3, SD: 4 };
const LIKELY_PACK_BYTES = 12 * 1024 * 1024 * 1024;

/**
 * views/play-picker/use-auto-candidates.ts without React or Together: the streams worth firing
 * without asking, best first, as indexes into the token's picker.all. Only cached or direct-URL
 * streams qualify (no P2P engine on the TV). The remembered pick and the season lock lead.
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
    if (!isCached(s) && !s.url) return;
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
