// Episode watched state and spoiler masking for the detail episode strip, without React:
//   - detail/use-bp-episode-strip.ts watchedOf: Harbor's manual marks (lib/manual-watched) or a
//     key pulled from the Stremio library (remoteWatchedKeys), after lib/stremio-watched-pull.ts
//     has reconciled the library bitfield into that store; plus, like the desktop strip
//     (views/detail/series-episodes.tsx combinedWatched), Trakt and Simkl history, with a manual
//     "unwatched" always winning.
//   - components/episode-watched-menu.tsx + series-episodes/use-mark-season.ts +
//     anime-episodes/use-anime-watched-routing.ts: the marks, written where upstream writes them
//     (manual store, Simkl history, AniList/MAL progress for anime, and the Stremio library
//     bitfield as views/detail.tsx pushes it on every manual-watched change).
//   - lib/spoilers.ts spoilerMaskFor for each card, next-up exempt like use-episode-progress-map.ts.
import type { Meta } from "@/lib/cinemeta";
import { meta as fetchCinemetaMeta, narrowMediaType } from "@/lib/cinemeta";
import {
  applyRemoteWatched,
  manualEpisodeKeys,
  manualWatchedState,
  recordManualWatchedMeta,
  remoteWatchedKeys,
  setManualWatched,
  setManualWatchedMany,
  setManualWatchedUpTo,
  unwatchedAt,
  type ManualWatchedMeta,
} from "@/lib/manual-watched";
import { clearResume } from "@/lib/resume";
import { spoilerMaskFor, spoilerActive, type SpoilerMask } from "@/lib/spoilers";
import { cloudWriteId, libraryGetOne, libraryGetOneStrict, type LibraryItem } from "@/lib/stremio";
import { cloudLibraryPut } from "@/lib/stremio-write-queue";
import { withItemLock } from "@/lib/stremio-item-lock";
import { detectAnimeForCw, isDetectedAnime } from "@/lib/anime-detect";
import { markEpisodesWatched, unmarkEpisodesWatched } from "@/lib/simkl/history";
import { stremioIdToSimklTarget } from "@/lib/simkl/ids";
import { loadSimklWatchedMap, simklWatchedForId } from "@/lib/simkl/list-status";
import { getSession as simklSession } from "@/lib/simkl/session";
import type { SimklIds } from "@/lib/simkl/types";
import { fetchWatchedKeySet } from "@/lib/trakt/history";
import { getSession as traktSession } from "@/lib/trakt/session";
import { syncAnimeProgress } from "@/lib/anilist/sync";
import { syncMalProgress } from "@/lib/mal/sync";
import { loadEffective } from "@/lib/settings/profile-store";
import { decodeWatchedField, encodeWatchedField } from "./player";

const ANIME_ID = /^(kitsu|mal|anilist|anidb):/;

/** One card of the strip: its source pair, the id its marks live under (anime franchise entries
 *  carry their own sourceMetaId) and its air date for the "aired only" rules. */
export type EpisodeRef = { season: number; episode: number; metaId?: string | null; released?: string | null };

const key = (season: number, episode: number) => `${season}:${episode}`;
const ownerOf = (ref: { metaId?: string | null }, metaId: string) => (ref.metaId ? ref.metaId : metaId);

/** episode-watched-menu.tsx airedByNow. */
export function airedByNow(released?: string | null): boolean {
  if (!released) return true;
  const t = Date.parse(released);
  return !Number.isFinite(t) || t <= Date.now();
}

const timeout = <T,>(p: Promise<T>, ms: number, fallback: T) =>
  Promise.race([p.catch(() => fallback), new Promise<T>((r) => setTimeout(() => r(fallback), ms))]);

// ------------------------------------------------------------------- reading the sources

/** lib/stremio-watched-pull.ts lastPullMtime: an unset only follows a newer library write. */
const lastPullMtime = new Map<string, number>();

/**
 * stremio-watched-pull.ts applySeries for the title on screen, with the videos the detail page
 * already holds: library bitfield keys the viewer never touched are adopted as remote marks, a
 * manual unmark wins unless the library was written after it, and a remote mark the library no
 * longer carries is dropped. Upstream skips anime-detected tt ids because its anime strip keys
 * them under the kitsu mapping; the TV strip shows this tt title's own Cinemeta episodes, so the
 * bitfield is the right source for it either way.
 */
export function reconcileLibraryWatched(item: LibraryItem | null, meta: Meta): number {
  if (!item || (item.removed && !item.temp)) return 0;
  const id = meta.id;
  const watched = (item.state as { watched?: unknown } | undefined)?.watched;
  if (typeof watched !== "string" || watched.length === 0) return 0;
  const rawMt = item._mtime as unknown;
  const parsed = typeof rawMt === "number" ? rawMt : Date.parse(String(rawMt ?? ""));
  const remoteMtime = Number.isFinite(parsed) ? parsed : 0;
  const keys = new Set(decodeWatchedField(watched, meta.videos));
  if (keys.size === 0) return 0;
  const add: Array<{ season: number; episode: number }> = [];
  for (const k of keys) {
    const [season, episode] = k.split(":").map(Number);
    if (!Number.isInteger(season) || !Number.isInteger(episode)) continue;
    const st = manualWatchedState(id, season, episode);
    if (st === undefined) add.push({ season, episode });
    else if (st === false && remoteMtime > (unwatchedAt(id, season, episode) ?? 0)) add.push({ season, episode });
  }
  const unset: Array<{ season: number; episode: number }> = [];
  const canUnset = remoteMtime > (lastPullMtime.get(id) ?? 0);
  if (canUnset) {
    for (const rk of remoteWatchedKeys(id)) {
      if (keys.has(rk)) continue;
      const [season, episode] = rk.split(":").map(Number);
      if (!Number.isInteger(season) || !Number.isInteger(episode)) continue;
      if (manualWatchedState(id, season, episode) === true) unset.push({ season, episode });
    }
  }
  applyRemoteWatched(id, add, unset);
  if (canUnset) lastPullMtime.set(id, remoteMtime);
  return add.length;
}

/** Trakt and Simkl history for one title, as "season:episode" keys (series-episodes.tsx useWatchedSets). */
const externalWatched = new Map<string, Set<string>>();

async function externalKeys(meta: Meta, imdbId: string | null): Promise<Set<string>> {
  const out = new Set<string>();
  const jobs: Array<Promise<void>> = [];
  if (traktSession()) {
    // lib/trakt/history.ts fetchWatchedKeySet keys episodes "imdb:<show>:<s>:<e>" / "tmdb:<show>:<s>:<e>".
    // Upstream strips every key down to "<s>:<e>" whatever the show; only this title's rows count here.
    const tmdb = /^tmdb:(?:tv:)?(\d+)$/.exec(meta.id)?.[1];
    const prefixes = [imdbId ? `imdb:${imdbId}:` : null, tmdb ? `tmdb:${tmdb}:` : null].filter((p): p is string => !!p);
    if (prefixes.length > 0) {
      jobs.push(timeout(fetchWatchedKeySet(), 8000, new Set<string>()).then((set) => {
        for (const k of set) for (const p of prefixes) if (k.startsWith(p)) out.add(k.slice(p.length));
      }));
    }
  }
  if (simklSession()) {
    jobs.push(timeout(loadSimklWatchedMap(), 8000, new Map<string, Set<string>>()).then((map) => {
      for (const k of simklWatchedForId(map, imdbId, meta.id)) out.add(k);
    }));
  }
  await Promise.all(jobs);
  return out;
}

/**
 * The network half, once per detail open: the Stremio library bitfield reconciled into the
 * manual store, and this title's Trakt/Simkl history remembered for state().
 */
export async function load(authKey: string | null, meta: Meta, imdbId: string | null): Promise<boolean> {
  const pull = async () => {
    if (!authKey || !meta.videos?.length || ANIME_ID.test(meta.id)) return;
    // stremio-watched-pull decodes against Cinemeta's own videos for the tt id: only a list that
    // lines up with it (the check pushToLibrary makes) may be decoded (review 27).
    if (!meta.id.startsWith("tt") || !String(meta.videos[0]?.id ?? "").startsWith(meta.id)) return;
    const item = await timeout(libraryGetOne(authKey, meta.id), 8000, null);
    reconcileLibraryWatched(item, meta);
  };
  const ext = externalKeys(meta, imdbId).then((set) => { externalWatched.set(meta.id, set); });
  await Promise.all([pull().catch(() => undefined), ext.catch(() => undefined)]);
  return true;
}

// ----------------------------------------------------------------------------- the state

export type EpisodeWatchedState = {
  /** "season:episode" of every ref that reads watched. */
  watched: string[];
  /** episode-watched-menu.tsx `started`: unwatched refs of `season` with a local resume entry. */
  started: string[];
  /** spoilerMaskFor per ref of `season`, only where something is masked. */
  masks: Record<string, SpoilerMask>;
  /** bp-episode-card.tsx: settings.showEpisodeRating / showEpisodeDescription !== false. */
  showEpisodeRating: boolean;
  showEpisodeDescription: boolean;
};

/** lib/resume.ts entryKey + readAll (not exported): one parse for the whole season. */
function resumeKeys(): Set<string> {
  try {
    const raw = localStorage.getItem("harbor.resume");
    return new Set(raw ? Object.keys(JSON.parse(raw) as Record<string, unknown>) : []);
  } catch {
    return new Set();
  }
}

export function watchedKeysFor(metaId: string, refs: EpisodeRef[]): Set<string> {
  const byOwner = new Map<string, { on: Set<string>; off: Set<string>; remote: Set<string>; ext: Set<string> }>();
  const sets = (owner: string) => {
    let s = byOwner.get(owner);
    if (!s) {
      const m = manualEpisodeKeys(owner);
      s = { on: m.watched, off: m.unwatched, remote: remoteWatchedKeys(owner), ext: owner === metaId ? (externalWatched.get(metaId) ?? new Set()) : new Set() };
      byOwner.set(owner, s);
    }
    return s;
  };
  const out = new Set<string>();
  for (const r of refs) {
    const k = key(r.season, r.episode);
    const s = sets(ownerOf(r, metaId));
    if (s.off.has(k)) continue;
    if (s.on.has(k) || s.remote.has(k) || s.ext.has(k)) out.add(k);
  }
  return out;
}

/**
 * Everything the strip draws for `season` (refs is the whole title so "up to here" and the
 * next-season up-next read the same answer). Next up is the first unwatched card of the season,
 * as use-episode-progress-map.ts / use-anime-progress-map.ts pick it. `shown`, when given, is the
 * strip itself as "season:episode" keys in its order (an anime season chip of the TVDB panel mixes
 * Kitsu seasons, use-anime-progress-map displayEpisodes); it replaces the season filter.
 */
export function state(metaId: string, refs: EpisodeRef[], season: number | null, profileId: string, linked: boolean, shown?: string[] | null): EpisodeWatchedState {
  const settings = loadEffective(profileId, linked);
  const watched = watchedKeysFor(metaId, refs);
  let inSeason = season == null ? refs : refs.filter((r) => r.season === season);
  if (Array.isArray(shown)) {
    const byKey = new Map(refs.map((r) => [key(r.season, r.episode), r] as const));
    inSeason = shown.map((k) => byKey.get(k)).filter((r): r is EpisodeRef => r != null);
  }
  const resume = resumeKeys();
  const started: string[] = [];
  const masks: Record<string, SpoilerMask> = {};
  let nextUp: string | null = null;
  for (const r of inSeason) {
    const k = key(r.season, r.episode);
    if (!watched.has(k) && nextUp == null) nextUp = k;
  }
  for (const r of inSeason) {
    const k = key(r.season, r.episode);
    const isWatched = watched.has(k);
    if (!isWatched && resume.has(`${ownerOf(r, metaId)}|s${r.season}e${r.episode}`)) started.push(k);
    const mask = spoilerMaskFor(settings, { watched: isWatched, isNextUp: k === nextUp });
    if (spoilerActive(mask)) masks[k] = mask;
  }
  return {
    watched: [...watched],
    started,
    masks,
    showEpisodeRating: settings.showEpisodeRating !== false,
    showEpisodeDescription: settings.showEpisodeDescription !== false,
  };
}

/** views/player.tsx nextEpMask: the up-next card's mask (isNextUp is always true there). */
export function upNextMask(profileId: string, linked: boolean, watched: boolean): SpoilerMask {
  return spoilerMaskFor(loadEffective(profileId, linked), { watched, isNextUp: true });
}

// ------------------------------------------------------------------------------ the marks

export type MarkScope = "episode" | "upTo" | "season" | "shown";

function simklShowIds(owner: string, season: number, episode: number): SimklIds | null {
  if (!simklSession()) return null;
  const r = stremioIdToSimklTarget(owner, { season, episode });
  if (!r.ok) return null;
  if (r.target.kind === "episode") return r.target.show.ids;
  if (r.target.kind === "anime-episode") return r.target.anime.ids;
  return null;
}

/**
 * One choice of the episode's hold-Select menu:
 *   "episode" watched   → episode-watched-menu "Mark as watched"
 *   "episode" unwatched → "Mark as unwatched" (also clears the episode's local resume entry)
 *   "upTo"              → "Mark watched up to here" (aired episodes of this entry, earlier seasons too)
 *   "season"            → use-mark-season.ts / use-anime-watched-routing.ts markMany
 *   "shown"             → anime-episodes.tsx markSeason = markMany(displayEpisodes): every ref
 *                         passed (the anime season chip on screen), grouped by the id its marks live under
 * The manual store is written before this returns. Simkl history follows when connected, an anime
 * season mark advances AniList/MAL progress when their auto-sync is on, and a series then pushes
 * its marks into the Stremio library bitfield; those run in the background (settle() awaits them).
 */
export function mark(
  authKey: string | null,
  meta: Meta,
  imdbId: string | null,
  target: EpisodeRef,
  scope: MarkScope,
  watched: boolean,
  refs: EpisodeRef[],
  profileId: string,
  linked: boolean,
): boolean {
  if (scope === "shown") return markShown(authKey, meta, imdbId, refs, watched, profileId, linked);
  const owner = ownerOf(target, meta.id);
  const manualMeta: ManualWatchedMeta = { type: "series", name: meta.name, poster: meta.poster, background: meta.background };
  const pool = refs.filter((r) => ownerOf(r, meta.id) === owner);
  const showIds = simklShowIds(owner, target.season, target.episode);
  const writes: Array<Promise<unknown>> = [];

  if (scope === "episode") {
    if (watched) {
      recordManualWatchedMeta(owner, manualMeta);
      setManualWatched(owner, target.season, target.episode, true);
      if (showIds) writes.push(markEpisodesWatched(showIds, target.season, [target.episode]));
    } else {
      setManualWatched(owner, target.season, target.episode, false);
      clearResume(owner, target.season, target.episode);
      if (showIds) writes.push(unmarkEpisodesWatched(showIds, target.season, [target.episode]));
    }
  } else if (scope === "upTo") {
    if (!watched) return false;
    recordManualWatchedMeta(owner, manualMeta);
    if (pool.length > 0) {
      const upTo = pool
        .filter((e) => airedByNow(e.released) && (e.season < target.season || (e.season === target.season && e.episode <= target.episode)))
        .map((e) => ({ season: e.season, episode: e.episode }));
      setManualWatchedMany(owner, upTo, true);
      const eps = upTo.filter((e) => e.season === target.season).map((e) => e.episode);
      if (showIds && eps.length > 0) writes.push(markEpisodesWatched(showIds, target.season, eps));
    } else {
      setManualWatchedUpTo(owner, target.season, target.episode, true);
      if (showIds) writes.push(markEpisodesWatched(showIds, target.season, Array.from({ length: target.episode }, (_, i) => i + 1)));
    }
  } else {
    const inSeason = pool.filter((e) => e.season === target.season);
    const eligible = (watched ? inSeason.filter((e) => airedByNow(e.released)) : inSeason).map((e) => ({ season: e.season, episode: e.episode }));
    if (eligible.length === 0) return false;
    if (watched) recordManualWatchedMeta(owner, manualMeta);
    setManualWatchedMany(owner, eligible, watched);
    if (ANIME_ID.test(owner)) {
      // use-anime-watched-routing.ts markMany: progress to the highest episode, never backwards.
      const settings = loadEffective(profileId, linked);
      const highest = Math.max(...eligible.map((e) => e.episode));
      if (watched && Number.isFinite(highest) && highest > 0) {
        if (settings.anilistAutoSync) writes.push(syncAnimeProgress(owner, highest, meta.name));
        if (settings.malAutoSync) writes.push(syncMalProgress(owner, highest, meta.name));
      }
    } else if (showIds) {
      const eps = eligible.map((e) => e.episode);
      writes.push(watched ? markEpisodesWatched(showIds, target.season, eps) : unmarkEpisodesWatched(showIds, target.season, eps));
    }
  }
  // The strip reads the manual store as soon as this returns; the services follow in the
  // background, as the menu's `void markEpisodesWatched(...)` and detail.tsx's effect do.
  const network = async () => {
    await Promise.all(writes.map((p) => timeout(p, 10000, undefined)));
    if (authKey && owner === meta.id) await timeout(pushToLibrary(authKey, meta, imdbId), 12000, false);
  };
  const prev = inflight;
  inflight = prev.then(network).catch(() => undefined);
  return true;
}

/**
 * use-anime-watched-routing.ts markMany(displayEpisodes, watched): aired episodes only when marking,
 * one manual write per owner (a franchise entry keeps its own id), AniList / MAL progress to the
 * highest episode when their auto-sync is on, then the Stremio library bitfield of the page's own id.
 */
function markShown(authKey: string | null, meta: Meta, imdbId: string | null, refs: EpisodeRef[], watched: boolean, profileId: string, linked: boolean): boolean {
  const eligible = watched ? refs.filter((e) => airedByNow(e.released)) : refs;
  if (eligible.length === 0) return false;
  const groups = new Map<string, Array<{ season: number; episode: number }>>();
  for (const e of eligible) {
    const owner = ownerOf(e, meta.id);
    const list = groups.get(owner) ?? [];
    list.push({ season: e.season, episode: e.episode });
    groups.set(owner, list);
  }
  const settings = loadEffective(profileId, linked);
  const writes: Array<Promise<unknown>> = [];
  for (const [owner, eps] of groups) {
    if (watched) recordManualWatchedMeta(owner, { type: "series", name: meta.name, poster: meta.poster, background: meta.background });
    setManualWatchedMany(owner, eps, watched);
    const highest = Math.max(...eps.map((e) => e.episode));
    if (watched && ANIME_ID.test(owner) && Number.isFinite(highest) && highest > 0) {
      if (settings.anilistAutoSync) writes.push(syncAnimeProgress(owner, highest, meta.name));
      if (settings.malAutoSync) writes.push(syncMalProgress(owner, highest, meta.name));
    }
  }
  const network = async () => {
    await Promise.all(writes.map((p) => timeout(p, 10000, undefined)));
    if (authKey && groups.has(meta.id)) await timeout(pushToLibrary(authKey, meta, imdbId), 12000, false);
  };
  const prev = inflight;
  inflight = prev.then(network).catch(() => undefined);
  return true;
}

let inflight: Promise<unknown> = Promise.resolve();

/** Resolves once every mark's Simkl / AniList / MAL / Stremio writes have finished. */
export async function settle(): Promise<boolean> {
  await inflight;
  return true;
}

// ------------------------------------------------------------- the Stremio library write

/**
 * views/detail.tsx's manual-watched effect → lib/stremio-watched-sync.ts setEpisodesWatchedStremio:
 * the library bitfield becomes (server ∪ manual watched) − manual unwatched, written under the
 * item lock with the rest of the entry kept (putWithState). Anime is never written, as upstream.
 */
export async function pushToLibrary(authKey: string, meta: Meta, imdbId: string | null): Promise<boolean> {
  const id = meta.id;
  if (ANIME_ID.test(id) || meta.type === "anime") return false;
  const imdb = imdbId?.startsWith("tt") ? imdbId : id.startsWith("tt") ? id : null;
  const cid = cloudWriteId(id, imdb, !!imdb);
  if (!cid) return false;
  // stremio-episode-watched.ts: the bitfield indexes Cinemeta's list for the imdb id.
  let videos = meta.videos;
  const aligned = imdb ? (videos?.[0]?.id?.startsWith(imdb) ?? false) : (videos?.length ?? 0) > 0;
  if (!videos?.length || (imdb && !aligned)) {
    const full = await fetchCinemetaMeta(narrowMediaType(meta.type), imdb ?? id).catch(() => null);
    if (full?.videos?.length) videos = full.videos;
  }
  if (!videos || videos.length === 0) return false;
  const { watched, unwatched } = manualEpisodeKeys(id);
  if (watched.size === 0 && unwatched.size === 0) return false;
  if (/^tt\d+$/.test(id) && !isDetectedAnime(id)) await detectAnimeForCw([{ _id: id, type: "series" }]).catch(() => undefined);
  if (isDetectedAnime(id)) return false;
  return withItemLock(cid, async () => {
    let base: LibraryItem | null;
    try {
      base = await libraryGetOneStrict(authKey, cid);
    } catch {
      return false;
    }
    const s = (base?.state ?? {}) as Record<string, unknown>;
    const num = (v: unknown, d: number) => (typeof v === "number" && Number.isFinite(v) ? v : d);
    const serverField = typeof s.watched === "string" && s.watched.length > 0 ? s.watched : null;
    const merged = new Set(decodeWatchedField(serverField, videos));
    for (const k of watched) merged.add(k);
    for (const k of unwatched) merged.delete(k);
    const field = encodeWatchedField(merged, videos);
    const now = new Date().toISOString();
    const state = {
      lastWatched: now,
      timeWatched: num(s.timeWatched, 0),
      timeOffset: num(s.timeOffset, 0),
      overallTimeWatched: num(s.overallTimeWatched, 0),
      timesWatched: num(s.timesWatched, 0),
      flaggedWatched: num(s.flaggedWatched, 0),
      duration: num(s.duration, 0),
      video_id: typeof s.video_id === "string" ? s.video_id : null,
      watched: field ?? serverField,
      lastVidReleased: typeof s.lastVidReleased === "string" ? s.lastVidReleased : null,
      noNotif: s.noNotif === true,
    };
    const name = (base?.name?.trim() || meta.name || "").trim();
    if (!name) return false;
    const rec = base as unknown as Record<string, unknown> | null;
    const hints = (rec?.behaviorHints ?? {}) as Record<string, unknown>;
    const shape = rec?.posterShape;
    const item = {
      _id: cid,
      type: base?.type ?? (meta.type === "series" ? "series" : "movie"),
      name,
      poster: meta.poster ?? base?.poster ?? null,
      posterShape: shape === "square" || shape === "landscape" || shape === "poster" ? shape : "poster",
      background: meta.background ?? base?.background,
      state,
      behaviorHints: {
        defaultVideoId: hints.defaultVideoId ?? null,
        featuredVideoId: hints.featuredVideoId ?? null,
        hasScheduledVideos: hints.hasScheduledVideos ?? false,
      },
      removed: base ? base.removed === true : false,
      temp: base ? base.temp === true : false,
      _ctime: base?._ctime ?? now,
      _mtime: now,
    };
    return cloudLibraryPut(authKey, item as unknown as LibraryItem);
  });
}
