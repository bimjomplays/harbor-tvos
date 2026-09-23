// Room builders for the TV app: the pure parts of use-bp-catalog.ts (Home) and
// use-bp-shows.ts (Movies/Shows), without React state. Swift owns caching and progressive
// rendering; this returns one finished build per call.
import { setTop10Metas } from "@/lib/top10-set";
import type { Meta } from "@/lib/cinemeta";
import { topMovies, topSeries } from "@/lib/cinemeta";
import type { HomeRow, RowSpec } from "@/views/home/home-types";
import { buildAnimeHomeRows, buildCinemetaRows, buildTmdbRows, isStreamingServiceRow, mergeRows } from "@/views/home/home-rows";
import { loadAddonRows, type AddonRow } from "@/lib/addons";
import { applyHomeRowCustomization } from "@/lib/home-customization";
import { applyPageRows, loadPageRows } from "@/lib/page-rows";
import { CATALOG_REQUEST_TIMEOUT_MS, withTimeout } from "@/lib/progressive-rows";
import { recentlyPlayed } from "@/lib/playback-history";
import { metaLooksAnime } from "@/lib/anime-detect";
import { buildShowHero } from "@/views/shows/hero-curation";
import { showSpecs } from "@/views/shows/show-specs";
import { buildMovieHero, HERO_POOL_TARGET, movieSpecs, rotateDaily } from "@/views/movies/movie-specs";
import type { Settings } from "@/lib/settings/types";
import { loadEffective } from "@/lib/settings/profile-store";
import { library, cwSortKey, isCwMember, isAnimeCwItem, type LibraryItem } from "@/lib/stremio";
import { isCwDismissed } from "@/lib/cw-dismiss";
import { listLocalCw, type LocalCwEntry } from "@/lib/local-cw";

export type RoomKind = "movies" | "shows";
export type RoomRow = {
  key: string;
  type: "movie" | "series";
  name: string;
  metas: Meta[];
  hasMore: boolean;
  /** "rank" for the Top 10 row, otherwise "poster". */
  shape: "poster" | "rank";
};
export type RoomBuild = { rows: RoomRow[]; hero: Meta[]; failed: boolean };

/** The last build per room keeps its row fetchers so Swift can page a row by key. */
const lastBuilds = new Map<string, HomeRow[]>();

/** Page `rowKey` of the last `home`/`catalog` build; `page` is 1-based like upstream. */
export async function page(room: "home" | "anime" | RoomKind, rowKey: string, page: number): Promise<Meta[]> {
  const row = lastBuilds.get(room)?.find((r) => r.key === rowKey);
  if (!row?.fetcher) return [];
  return row.fetcher(page).catch(() => [] as Meta[]);
}

export const BP_TOP10_ROW_KEY = "bp-top10";
const FALLBACK_ROW_CAP = 30;
const HERO_SLOTS = 6;
const MIN_ROW_METAS = 4;
const PAGINATE_THRESHOLD = 14;

// use-bp-shows.ts:56-84
const FALLBACK_GENRES: Record<RoomKind, string[]> = {
  shows: ["Drama", "Comedy", "Crime", "Sci-Fi", "Thriller", "Mystery", "Action", "Animation", "Adventure", "Fantasy", "Documentary", "Romance", "Horror"],
  movies: ["Action", "Drama", "Comedy", "Sci-Fi", "Thriller", "Horror", "Romance", "Animation", "Adventure", "Crime", "Mystery", "Fantasy", "Documentary"],
};

const metaType = (kind: RoomKind): "movie" | "series" => (kind === "shows" ? "series" : "movie");

/** isAnimeRow from views/anime/anime-rows.tsx (that file is React), same heuristic. */
function looksAnimeRow(row: AddonRow): boolean {
  if (row.type === "anime") return true;
  const nameLower = (row.name ?? "").toLowerCase();
  if (/\b(anime|mal|anilist|kitsu|aniworld|crunchyroll|funimation)\b/.test(nameLower)) return true;
  const sample = row.metas.slice(0, 6);
  if (sample.length === 0) return false;
  const animeIds = sample.filter((m) => /^(kitsu|mal|anilist|anidb):/.test(m.id));
  return animeIds.length >= Math.ceil(sample.length / 2);
}

function hideAnime<T extends { metas: Meta[] }>(rows: T[], settings: Settings): T[] {
  if (!settings.animeOnlyInAnimeRoom) return rows;
  return rows.map((r) => ({ ...r, metas: r.metas.filter((m) => !metaLooksAnime(m)) }));
}

function strip(row: HomeRow, shape: RoomRow["shape"] = "poster"): RoomRow {
  return { key: row.key, type: row.type, name: row.name, metas: row.metas, hasMore: row.hasMore, shape };
}

// --------------------------------------------------------------------------------- Home
/** use-bp-catalog.ts without React: base rows (TMDB or Cinemeta), then installed addon rows. */
export async function home(settings: Settings, authKey: string | null): Promise<RoomBuild> {
  const classic = settings.homeMode === "classic";
  const EMPTY = { rows: [] as HomeRow[], hero: [] as Meta[] };
  let base: { rows: HomeRow[]; hero: Meta[] } = EMPTY;
  if (!classic) {
    base = settings.tmdbKey
      ? await buildTmdbRows(settings).catch(() => EMPTY)
      : await buildCinemetaRows().catch(() => EMPTY);
  }
  if (base.rows.length === 0) base = await buildCinemetaRows().catch(() => EMPTY);

  const dedup = classic ? false : !settings.homeShowAllAddonRows;
  const addons = await loadAddonRows(authKey, { dedup }).catch(() => [] as AddonRow[]);
  const usable = classic ? addons : addons.filter((a) => !looksAnimeRow(a) && !isStreamingServiceRow(a.name));
  const merged = mergeRows(base.rows, usable, { dedup });

  const seen = new Set<string>();
  const all: HomeRow[] = [];
  for (const row of merged) {
    if (seen.has(row.key)) continue;
    seen.add(row.key);
    all.push(row);
  }
  const customized = applyHomeRowCustomization(all, settings.homeRows, false);
  lastBuilds.set("home", customized);
  const rows = hideAnime(customized, settings).map((r) => {
    const rank = settings.homeRows?.numerals?.includes(r.key) && r.metas.length >= 10;
    return strip(r, rank ? "rank" : "poster");
  });
  return { rows, hero: base.hero, failed: rows.length === 0 };
}

// ------------------------------------------------------------------------ Movies / Shows
function specRow(kind: RoomKind, spec: RowSpec & { noPaginate?: boolean }, metas: Meta[]): HomeRow {
  return {
    key: spec.key,
    type: metaType(kind),
    name: spec.name,
    metas,
    page: 1,
    hasMore: !spec.noPaginate && metas.length >= PAGINATE_THRESHOLD,
  };
}

async function buildFallback(kind: RoomKind): Promise<{ rows: HomeRow[]; hero: Meta[] }> {
  const fetchTop = kind === "shows" ? topSeries : topMovies;
  const genres = FALLBACK_GENRES[kind];
  const [top, ...byGenre] = await Promise.all([
    withTimeout(fetchTop(), CATALOG_REQUEST_TIMEOUT_MS).catch(() => [] as Meta[]),
    ...genres.map((g) => withTimeout(fetchTop(g), CATALOG_REQUEST_TIMEOUT_MS).catch(() => [] as Meta[])),
  ]);
  const type = metaType(kind);
  const rows: HomeRow[] = [];
  if (top.length > 0) {
    rows.push({ key: "cinemeta-top", type, name: kind === "shows" ? "Top Series" : "Top Movies", metas: top.slice(0, FALLBACK_ROW_CAP), page: 1, hasMore: false });
  }
  for (let i = 0; i < genres.length; i++) {
    const list = byGenre[i] ?? [];
    if (list.length === 0) continue;
    rows.push({
      key: `cinemeta-genre-${genres[i].toLowerCase().replace(/[^a-z]/g, "")}`,
      type,
      name: `Top ${genres[i]}`,
      metas: list.slice(0, FALLBACK_ROW_CAP),
      page: 1,
      hasMore: false,
    });
  }
  const withArt = top.filter((m) => m.background);
  const hero = kind === "movies" ? rotateDaily(withArt, HERO_POOL_TARGET, recentlyPlayed()) : withArt.slice(0, HERO_SLOTS);
  return { rows, hero };
}

/** use-bp-shows.ts useBuiltCatalog + useBpCatalogPage without React. */
export async function catalog(kind: RoomKind, settings: Settings): Promise<RoomBuild> {
  const tmdbKey = settings.tmdbKey;
  const region = settings.region;
  let built: { rows: HomeRow[]; hero: Meta[] } = { rows: [], hero: [] };

  if (tmdbKey) {
    const specs = kind === "shows" ? showSpecs(tmdbKey) : movieSpecs(tmdbKey, region);
    const heroP = withTimeout(kind === "shows" ? buildShowHero(tmdbKey) : buildMovieHero(tmdbKey, recentlyPlayed()), CATALOG_REQUEST_TIMEOUT_MS).catch(() => [] as Meta[]);
    const results = await Promise.allSettled(specs.map((spec) => withTimeout(spec.fetcher(1), CATALOG_REQUEST_TIMEOUT_MS)));
    const rows: HomeRow[] = [];
    results.forEach((r, i) => {
      if (r.status === "fulfilled" && r.value.length > 0) rows.push({ ...specRow(kind, specs[i], r.value), fetcher: specs[i].noPaginate ? undefined : specs[i].fetcher });
    });
    if (rows.length > 0) built = { rows, hero: await heroP };
  }
  if (built.rows.length === 0) built = await buildFallback(kind);
  if (built.rows.length === 0) return { rows: [], hero: [], failed: true };

  // useBpCatalogPage: Top 10 from trending, dedup across rows, MIN_ROW_METAS, page customization.
  const trending = built.rows.find((r) => r.key === "trending")?.metas ?? [];
  const trendingShown = settings.animeOnlyInAnimeRoom ? trending.filter((m) => !metaLooksAnime(m)) : trending;
  const top = trendingShown.slice(0, 10);
  const ranked = top.length >= 10 ? top : [];
  const seen = new Set<string>(ranked.map((m) => m.id));
  const specRows: HomeRow[] = [];
  for (const row of built.rows) {
    if (row.key === "trending" && ranked.length > 0) continue;
    const metas = row.metas.filter((m) => !seen.has(m.id));
    if (metas.length < MIN_ROW_METAS) continue;
    for (const m of metas) seen.add(m.id);
    specRows.push({ ...row, metas });
  }
  const custom = loadPageRows(kind);
  const titled = specRows.map((r) => ({ ...r, title: r.name }));
  const ordered = applyPageRows(titled, custom, false).map(({ title, ...rest }) => ({ ...rest, name: title }) as HomeRow);
  lastBuilds.set(kind, ordered);
  const rows: RoomRow[] = hideAnime(ordered, settings).map((r) => strip(r));
  if (ranked.length > 0) {
    rows.unshift({ key: BP_TOP10_ROW_KEY, type: metaType(kind), name: kind === "shows" ? "Top 10 Series Today" : "Top 10 Movies Today", metas: ranked, hasMore: false, shape: "rank" });
  }
  // bp-top10-feed.ts: the page that just built owns the ribbon set (isTop10 for card marks).
  setTop10Metas(ranked.map((m) => ({ id: m.id, name: m.name })));
  const hero = settings.animeOnlyInAnimeRoom ? built.hero.filter((m) => !metaLooksAnime(m)) : built.hero;
  return { rows, hero, failed: false };
}

// ------------------------------------------------------------- convenience for Swift
/** Same as `home`, reading the effective settings for a profile inside the engine. */
export function homeFor(profileId: string, linked: boolean, authKey: string | null): Promise<RoomBuild> {
  return home(loadEffective(profileId, linked), authKey);
}

/** Same as `catalog`, reading the effective settings for a profile inside the engine. */
export function catalogFor(kind: RoomKind, profileId: string, linked: boolean): Promise<RoomBuild> {
  return catalog(kind, loadEffective(profileId, linked));
}

// ----------------------------------------------------------------- Continue Watching
// views/mobile/mobile-cw-row.tsx useMobileCw: cloud library + local resume entries, merged and
// sorted by recency. Trakt/Simkl imports join when those trackers arrive.
function localToLibraryItem(e: LocalCwEntry): LibraryItem {
  return {
    _id: e.id, type: e.type, name: e.name, poster: e.poster, background: e.background,
    state: {
      timeOffset: e.positionMs, duration: e.durationMs, season: e.season, episode: e.episode, video_id: e.videoId,
      flaggedWatched: e.durationMs > 0 && e.positionMs / e.durationMs >= 0.9 ? 1 : 0,
      lastWatched: new Date(e.t).toISOString(),
    },
    removed: false, temp: false, _ctime: new Date(e.t).toISOString(), _mtime: new Date(e.t).toISOString(), local: true,
  } as LibraryItem;
}

export async function continueWatching(authKey: string | null, settings: Settings, limit = 40): Promise<LibraryItem[]> {
  const cloud = authKey ? await library(authKey).catch(() => [] as LibraryItem[]) : [];
  const local = listLocalCw().map(localToLibraryItem);
  const seen = new Set<string>();
  const merged = [...cloud, ...local]
    .filter((i) => (i.type as string) !== "other" && !i._id.startsWith("iptv:") && !isCwDismissed(i) && isCwMember(i)
      && !(settings.animeOnlyInAnimeRoom && isAnimeCwItem(i)))
    .map((i) => ({ i, k: cwSortKey(i) }))
    .sort((a, b) => b.k - a.k)
    .map((e) => e.i)
    .filter((i) => (seen.has(i._id) ? false : (seen.add(i._id), true)));
  return merged.slice(0, limit);
}

export function continueWatchingFor(profileId: string, linked: boolean, authKey: string | null, limit = 40): Promise<LibraryItem[]> {
  return continueWatching(authKey, loadEffective(profileId, linked), limit);
}

// ----------------------------------------------------------------------------- Anime
/** views/home/home-rows.ts buildAnimeHomeRows: Jikan (MAL) airing / new / popular / upcoming. */
export async function anime(): Promise<RoomBuild> {
  const rows = await buildAnimeHomeRows().catch(() => [] as HomeRow[]);
  lastBuilds.set("anime", rows);
  return { rows: rows.map((r) => strip(r)), hero: rows[0]?.metas.slice(0, 6) ?? [], failed: rows.length === 0 };
}
