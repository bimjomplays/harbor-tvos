// Playlist VOD (views/playlist-vod.tsx): the movie and series entries of an IPTV source that
// Live TV filters out. M3U sources are classified line by line (lib/iptv/vod.ts buildVodLibrary);
// Xtream logins ask the provider's VOD and series APIs (lib/iptv/xtream-vod.ts), and a series'
// episodes are fetched when it is opened. The library stays in the engine; Swift pages through it.
import { readPlaylists, type StoredPlaylist } from "@/lib/iptv/playlists-store";
import { loadPlaylist } from "@/lib/iptv/store";
import { buildVodLibrary, type VodEpisode, type VodLibrary, type VodMovie, type VodSeries } from "@/lib/iptv/vod";
import { credsFromServer } from "@/lib/iptv/xtream";
import { clearSeriesInfoCache, fetchXtreamSeries, fetchXtreamSeriesEpisodes, fetchXtreamVod } from "@/lib/iptv/xtream-vod";
import { iptvSourceSignature, isPersistentCacheFresh } from "@/lib/iptv/persistent-cache";
import { normalizeArabic } from "@/lib/iptv/rtl";
import { clearResume, readResumeEntry, saveResumeMs } from "@/lib/resume";
import type { IptvChannel, IptvPlaylist } from "@/lib/iptv/types";
import { t } from "@/lib/i18n";

// ------------------------------------------------------------------------------ sources
// use-vod-sources.ts: every playlist except guide-only ones; the active one is remembered.
const ACTIVE_KEY = "harbor.vod.active";

export type VodSourceView = { id: string; name: string; kind: "m3u" | "xtream" };

function vodSources(): StoredPlaylist[] {
  return readPlaylists().filter((p) => (p.kind ?? "m3u") !== "epg");
}

function readActive(): string | null {
  try { return localStorage.getItem(ACTIVE_KEY); } catch { return null; }
}

function writeActive(id: string | null): void {
  try {
    if (id) localStorage.setItem(ACTIVE_KEY, id);
    else localStorage.removeItem(ACTIVE_KEY);
  } catch { /* noop */ }
}

/** The VOD-capable sources and the active one (falls back to the first, like use-vod-sources). */
export function sources(): { sources: VodSourceView[]; activeId: string | null } {
  const list = vodSources();
  let active = readActive();
  if (list.length === 0) {
    if (active !== null) writeActive(null);
    return { sources: [], activeId: null };
  }
  if (!active || !list.some((s) => s.id === active)) {
    active = list[0].id;
    writeActive(active);
  }
  return { sources: list.map((p) => ({ id: p.id, name: p.name, kind: p.kind === "xtream" ? "xtream" : "m3u" })), activeId: active };
}

export function setActive(id: string): void {
  if (vodSources().some((s) => s.id === id)) writeActive(id);
}

// ------------------------------------------------------------------------------ library
// use-xtream-vod-library.ts Snapshot, minus the IndexedDB copy (the engine has no IndexedDB, so
// the 6-hour freshness window applies to the in-memory copy only).
type Snapshot = {
  library: VodLibrary;
  fetchedAt: number | null;
  moviesLoading: boolean;
  seriesLoading: boolean;
  movieError: string | null;
  seriesError: string | null;
  movieTotal: number | null;
  seriesTotal: number | null;
  signature: string;
};

export type VodStatus = {
  playlistId: string;
  kind: "m3u" | "xtream";
  movies: number;
  series: number;
  moviesLoading: boolean;
  seriesLoading: boolean;
  movieError: string | null;
  seriesError: string | null;
  movieTotal: number | null;
  seriesTotal: number | null;
  fetchedAt: number | null;
};

const EMPTY_LIBRARY: VodLibrary = { movies: [], series: [] };
const cache = new Map<string, Snapshot>();
const inflight = new Map<string, { signature: string; promise: Promise<void> }>();
/** normalizeArabic(title) per item, built once per library (playlist-vod.tsx movieIndex / seriesIndex). */
const searchIndex = new WeakMap<object, string[]>();

function emptySnapshot(signature: string): Snapshot {
  return { library: EMPTY_LIBRARY, fetchedAt: null, moviesLoading: false, seriesLoading: false, movieError: null, seriesError: null, movieTotal: null, seriesTotal: null, signature };
}

function sourceOf(playlistId: string): StoredPlaylist {
  const pl = vodSources().find((p) => p.id === playlistId);
  if (!pl) throw new Error("playlist not found");
  return pl;
}

function statusOf(pl: StoredPlaylist, snap: Snapshot | undefined): VodStatus {
  const s = snap ?? emptySnapshot("");
  return {
    playlistId: pl.id,
    kind: pl.kind === "xtream" ? "xtream" : "m3u",
    movies: s.library.movies.length,
    series: s.library.series.length,
    moviesLoading: s.moviesLoading,
    seriesLoading: s.seriesLoading,
    movieError: s.movieError,
    seriesError: s.seriesError,
    movieTotal: s.movieTotal,
    seriesTotal: s.seriesTotal,
    fetchedAt: s.fetchedAt,
  };
}

function errorText(e: unknown): string {
  return e instanceof Error ? e.message : String(e);
}

// use-xtream-vod-library.ts makeLibrary: one batch of Xtream rows through buildVodLibrary.
function makeLibrary(pl: StoredPlaylist, channels: readonly IptvChannel[]): VodLibrary {
  const playlist: IptvPlaylist = { id: pl.id, name: pl.name, url: pl.url, epgUrl: pl.epgUrl ?? null, channels: [...channels], fetchedAt: Date.now(), groups: [] };
  return buildVodLibrary([playlist], new Map([[pl.id, pl.name]]));
}

function appendUnique<T extends { id: string }>(target: T[], seen: Set<string>, items: readonly T[]): void {
  for (const item of items) {
    if (seen.has(item.id)) continue;
    seen.add(item.id);
    target.push(item);
  }
}

async function loadXtream(pl: StoredPlaylist, signature: string, force: boolean): Promise<void> {
  const held = cache.get(pl.id);
  if (!force && held && held.signature === signature && isPersistentCacheFresh(held.fetchedAt)) return;
  if (!pl.xtream) throw new Error("This source has no Xtream login.");
  const creds = credsFromServer(pl.xtream.server, pl.xtream.username, pl.xtream.password);
  if (!creds) throw new Error("This source's Xtream server address is not valid.");
  const restored = held && held.signature === signature ? held : emptySnapshot(signature);
  const isCurrent = () => cache.get(pl.id)?.signature === signature;
  const publish = (patch: Partial<Snapshot>) => {
    if (!isCurrent()) return false;
    const cur = cache.get(pl.id)!;
    cache.set(pl.id, { ...cur, ...patch });
    return true;
  };
  cache.set(pl.id, { ...restored, moviesLoading: true, seriesLoading: true, movieError: null, seriesError: null });

  const movies: VodMovie[] = [];
  const movieIds = new Set<string>();
  const series: VodSeries[] = [];
  const seriesIds = new Set<string>();
  let moviesOk = false;
  let seriesOk = false;
  // Batches publish as they parse so the "Loaded {loaded} of {total}" line can move while a big
  // catalogue is still being read.
  const movieTask = fetchXtreamVod(creds, pl.id, {
    onStart: (total) => { publish({ movieTotal: total }); },
    onBatch: (channels) => {
      appendUnique(movies, movieIds, makeLibrary(pl, channels).movies);
      const cur = cache.get(pl.id);
      return publish({ library: { movies: movies.slice(), series: cur?.library.series ?? [] } });
    },
  }).then(() => { moviesOk = true; publish({ moviesLoading: false }); })
    .catch((e) => {
      const cur = cache.get(pl.id);
      if (restored.library.movies.length > 0 && cur) publish({ library: { movies: restored.library.movies, series: cur.library.series } });
      publish({ moviesLoading: false, movieError: errorText(e) });
    });
  const seriesTask = fetchXtreamSeries(creds, pl.id, {
    onStart: (total) => { publish({ seriesTotal: total }); },
    onBatch: (channels) => {
      if (!isCurrent()) return false;
      appendUnique(series, seriesIds, makeLibrary(pl, channels).series);
      return true;
    },
  }).then(() => { seriesOk = true; })
    .catch((e) => { publish({ seriesError: errorText(e) }); });
  await Promise.all([movieTask, seriesTask]);
  const cur = cache.get(pl.id);
  if (!cur || !isCurrent()) return;
  // The series gate publishes after the movies: the finished list lands in one piece.
  publish({ library: { movies: cur.library.movies, series: seriesOk ? series : restored.library.series }, seriesLoading: false });
  if (moviesOk && seriesOk) publish({ fetchedAt: Date.now() });
}

async function loadM3u(pl: StoredPlaylist, signature: string, force: boolean): Promise<void> {
  const held = cache.get(pl.id);
  cache.set(pl.id, { ...(held && held.signature === signature ? held : emptySnapshot(signature)), moviesLoading: true, seriesLoading: true, movieError: null, seriesError: null });
  try {
    // playlist-vod.tsx: the same cached playlist Live TV loads, classified for VOD lines.
    const playlist = await loadPlaylist(pl, { force });
    const library = buildVodLibrary([playlist], new Map([[pl.id, pl.name]]));
    cache.set(pl.id, { ...emptySnapshot(signature), library, fetchedAt: playlist.fetchedAt ?? Date.now() });
  } catch (e) {
    const cur = cache.get(pl.id) ?? emptySnapshot(signature);
    cache.set(pl.id, { ...cur, moviesLoading: false, seriesLoading: false, movieError: errorText(e), seriesError: errorText(e) });
  }
}

/** Loads (or serves) the source's VOD library; `force` is the refresh button. */
export async function load(playlistId: string, force = false): Promise<VodStatus> {
  const pl = sourceOf(playlistId);
  const signature = iptvSourceSignature(pl);
  const held = cache.get(pl.id);
  if (held && held.signature !== signature) {
    cache.delete(pl.id);
    clearSeriesInfoCache(pl.id);
  }
  const pending = inflight.get(pl.id);
  if (pending && pending.signature === signature && !force) {
    await pending.promise;
    return statusOf(pl, cache.get(pl.id));
  }
  const promise = (pl.kind === "xtream" ? loadXtream(pl, signature, force) : loadM3u(pl, signature, force)).finally(() => {
    if (inflight.get(pl.id)?.promise === promise) inflight.delete(pl.id);
  });
  inflight.set(pl.id, { signature, promise });
  await promise;
  return statusOf(pl, cache.get(pl.id));
}

/** The loading line while `load` runs (playlist-vod.tsx CatalogProgress). */
export function status(playlistId: string): VodStatus {
  const pl = sourceOf(playlistId);
  return statusOf(pl, cache.get(pl.id));
}

/** use-vod-sources removePlaylist / editPlaylist: clearXtreamVodLibraryCache. */
export function clearVodCache(playlistId?: string): void {
  if (playlistId) { cache.delete(playlistId); clearSeriesInfoCache(playlistId); }
  else { cache.clear(); clearSeriesInfoCache(); }
}

// --------------------------------------------------------------------------------- pages
const WATCHED_RATIO = 0.9;

export type VodItemView = {
  id: string;
  kind: "movie" | "series";
  title: string;
  year: number | null;
  logo: string | null;
  group: string | null;
  /** vod-card subtitle: a series' group or episode count; a movie has none (its year shows). */
  subtitle: string | null;
  /** Movies only: the file. */
  url: string | null;
  playlistName: string;
  /** Movies only: the saved spot (lib/resume), for a progress line on the card. */
  resumeSec: number | null;
};

function titleIndex(items: ReadonlyArray<{ title: string }>): string[] {
  const cached = searchIndex.get(items);
  if (cached) return cached;
  const built = items.map((i) => normalizeArabic(i.title));
  searchIndex.set(items, built);
  return built;
}

function movieView(m: VodMovie): VodItemView {
  const resume = readResumeEntry(m.id);
  return { id: m.id, kind: "movie", title: m.title, year: m.year, logo: m.logo, group: m.group, subtitle: null, url: m.url, playlistName: m.playlistName, resumeSec: resume && resume.ms > 0 ? resume.ms / 1000 : null };
}

function seriesView(s: VodSeries): VodItemView {
  // playlist-vod.tsx: an Xtream series says its category (or "Open to load episodes"), an M3U one its
  // episode count, through t() like upstream.
  const subtitle = s.xtreamSeriesId
    ? (s.group ?? t("Open to load episodes"))
    : s.episodes.length === 1 ? t("{n} episode", { n: 1 }) : t("{n} episodes", { n: s.episodes.length });
  return { id: s.id, kind: "series", title: s.title, year: null, logo: s.logo, group: s.group, subtitle, url: null, playlistName: s.playlistName, resumeSec: null };
}

/**
 * One page of the Movies or Shows tab, filtered like playlist-vod.tsx (normalizeArabic on the
 * query and the titles, substring match). PAGE_SIZE there is 60.
 */
export function page(playlistId: string, tab: "movies" | "series", query: string, offset = 0, limit = 60): { items: VodItemView[]; total: number; libraryTotal: number } {
  const snap = cache.get(playlistId);
  const lib = snap?.library ?? EMPTY_LIBRARY;
  const q = normalizeArabic(query ?? "").trim();
  const start = Math.max(0, Math.floor(offset));
  const count = Math.max(0, Math.min(200, Math.floor(limit)));
  if (tab === "movies") {
    const idx = titleIndex(lib.movies);
    const hits = q ? lib.movies.filter((_, i) => idx[i].includes(q)) : lib.movies;
    return { items: hits.slice(start, start + count).map(movieView), total: hits.length, libraryTotal: lib.movies.length };
  }
  const idx = titleIndex(lib.series);
  const hits = q ? lib.series.filter((_, i) => idx[i].includes(q)) : lib.series;
  return { items: hits.slice(start, start + count).map(seriesView), total: hits.length, libraryTotal: lib.series.length };
}

// -------------------------------------------------------------------------------- series
export type VodEpisodeView = {
  season: number;
  episode: number;
  title: string;
  url: string;
  logo: string | null;
  durationSec: number | null;
  plot: string | null;
  /** episode-row.tsx episodeProgressOf: watched share (needs the runtime) and time left. */
  progress: number;
  leftSec: number;
  watched: boolean;
  /** The saved spot itself (0 = none). */
  resumeSec: number;
};

export type VodSeriesView = {
  id: string;
  title: string;
  logo: string | null;
  group: string | null;
  playlistName: string;
  seasons: number[];
  episodes: VodEpisodeView[];
};

function episodeView(seriesId: string, ep: VodEpisode): VodEpisodeView {
  const entry = readResumeEntry(seriesId, ep.season, ep.episode);
  const total = ep.durationSec && ep.durationSec > 0 ? ep.durationSec : 0;
  const watchedSec = entry && entry.ms > 0 ? entry.ms / 1000 : 0;
  const progress = total > 0 && watchedSec > 0 ? Math.min(1, watchedSec / total) : 0;
  const leftSec = total > 0 && watchedSec > 0 ? Math.max(0, total - watchedSec) : 0;
  return { season: ep.season, episode: ep.episode, title: ep.title, url: ep.url, logo: ep.logo, durationSec: ep.durationSec ?? null, plot: ep.plot ?? null, progress, leftSec, watched: progress >= WATCHED_RATIO, resumeSec: watchedSec };
}

function seriesDetail(s: VodSeries): VodSeriesView {
  return { id: s.id, title: s.title, logo: s.logo, group: s.group, playlistName: s.playlistName, seasons: s.seasons, episodes: s.episodes.map((e) => episodeView(s.id, e)) };
}

/**
 * playlist-vod.tsx openSeries: an M3U series already holds its episodes; an Xtream one asks
 * get_series_info and reads season/episode back from the "S{n}E{n}" names xtream-vod.ts builds.
 */
export async function series(playlistId: string, seriesId: string): Promise<VodSeriesView> {
  const pl = sourceOf(playlistId);
  const snap = cache.get(pl.id);
  const s = snap?.library.series.find((x) => x.id === seriesId);
  if (!s) throw new Error("series not found");
  if (!s.xtreamSeriesId || pl.kind !== "xtream" || !pl.xtream) return seriesDetail(s);
  if (s.episodes.length > 0) return seriesDetail(s);
  const creds = credsFromServer(pl.xtream.server, pl.xtream.username, pl.xtream.password);
  if (!creds) return seriesDetail(s);
  const channels = await fetchXtreamSeriesEpisodes(creds, pl.id, {
    series_id: Number(s.xtreamSeriesId),
    name: s.title,
    cover: s.logo ?? undefined,
    category_id: s.group ?? undefined,
  });
  const episodes: VodEpisode[] = channels.map((channel) => {
    const match = /S(\d+)E(\d+)$/i.exec(channel.name);
    return {
      season: Number(match?.[1]) || 1,
      episode: Number(match?.[2]) || 0,
      title: channel.attrs["episode-title"] || channel.name,
      url: channel.url,
      logo: channel.logo,
      durationSec: channel.durationSec,
      plot: channel.attrs["episode-plot"] || null,
    };
  });
  const seasons = [...new Set(episodes.map((e) => e.season))].sort((a, b) => a - b);
  // Kept on the library entry so a second visit does not refetch (xtream-vod's seriesInfoCache
  // would answer anyway); the order is the provider's, as upstream renders it.
  s.episodes = episodes;
  s.seasons = seasons;
  return seriesDetail(s);
}

// ------------------------------------------------------------------------------ progress
// use-resume-autosave.ts record(): a playlist VOD id (isExternalPlaylistId) keeps a local resume
// spot and nothing else: no Continue Watching entry, no watched flags, no Stremio write.
const MIN_POSITION_SEC = 5;
const STUB_MAX_SEC = 150;

/** The same shape as player.startPosition, from the local resume store only. */
export function startPosition(metaId: string, season: number | null, episode: number | null): { ms: number; fromRemote: boolean; finished: boolean } {
  const e = readResumeEntry(metaId, season ?? undefined, episode ?? undefined);
  return { ms: e?.ms ?? 0, fromRemote: false, finished: false };
}

/** The same shape as player.saveProgress; cloud is always "none". */
export function saveProgress(p: { meta: { id: string }; season?: number | null; episode?: number | null; positionMs: number; durationMs: number }): { watched: boolean; cloud: "none" | "skipped" } {
  const durSec = p.durationMs / 1000;
  const posSec = p.positionMs / 1000;
  if (!p.meta?.id) return { watched: false, cloud: "none" };
  if (durSec > 0 && durSec < STUB_MAX_SEC) return { watched: false, cloud: "skipped" };
  if (posSec < MIN_POSITION_SEC) return { watched: false, cloud: "none" };
  const s = p.season ?? undefined;
  const e = p.episode ?? undefined;
  const watched = durSec > 0 && posSec / durSec >= WATCHED_RATIO;
  if (watched) clearResume(p.meta.id, s, e);
  else saveResumeMs(p.meta.id, p.positionMs, s, e, s);
  return { watched, cloud: "none" };
}

// ------------------------------------------------------------------------------ playback
export type VodPlayback = {
  meta: { id: string; type: "movie" | "series"; name: string; poster?: string; background?: string; releaseInfo?: string };
  url: string;
  title: string;
  subtitle: string;
  season: number | null;
  episode: number | null;
};

// playlist-vod.tsx vodMeta.
function vodMeta(id: string, type: "movie" | "series", name: string, logo: string | null, year: number | null): VodPlayback["meta"] {
  const meta: VodPlayback["meta"] = { id, type, name };
  if (logo) { meta.poster = logo; meta.background = logo; }
  if (year) meta.releaseInfo = String(year);
  return meta;
}

/** playlist-vod.tsx playMovie: meta, file, title, and the year (or the playlist) underneath. */
export function playMovie(playlistId: string, movieId: string): VodPlayback {
  const m = cache.get(playlistId)?.library.movies.find((x) => x.id === movieId);
  if (!m) throw new Error("movie not found");
  return { meta: vodMeta(m.id, "movie", m.title, m.logo, m.year), url: m.url, title: m.title, subtitle: m.year ? String(m.year) : m.playlistName, season: null, episode: null };
}

/** playlist-vod.tsx playEpisode: the series meta, "{show} · S{n} · E{n}" underneath. */
export function playEpisode(playlistId: string, seriesId: string, season: number, episode: number): VodPlayback {
  const s = cache.get(playlistId)?.library.series.find((x) => x.id === seriesId);
  const ep = s?.episodes.find((e) => e.season === season && e.episode === episode);
  if (!s || !ep) throw new Error("episode not found");
  return { meta: vodMeta(s.id, "series", s.title, s.logo, null), url: ep.url, title: ep.title, subtitle: `${s.title} · S${ep.season} · E${ep.episode}`, season: ep.season, episode: ep.episode };
}
