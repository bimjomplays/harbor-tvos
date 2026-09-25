// Discover room glue: the pure parts of use-bp-discover.ts and queue/use-bp-queue.ts.
import type { Meta } from "@/lib/cinemeta";
import { getPool, extendPool, selectDailyRows, fetchGenreSample, type FeedItem } from "@/lib/feed";
import { snoozeQueueItem, blockQueueItem } from "@/lib/feed/skipped";
import { getDownvotedIds, getUpvotedIds } from "@/lib/feed/preferences";
import { rankByAffinity } from "@/lib/feed/rank";
import { filterQueuePool, shuffleQueuePool } from "@/lib/feed/skipped";
import { getStore } from "@/lib/discover/store";
import { CATALOG_REQUEST_TIMEOUT_MS, withTimeout } from "@/lib/progressive-rows";
import { metaLooksAnime } from "@/lib/anime-detect";
import { GENRE_PALETTE } from "@/components/genre-tiles";
import { BP_GENRES, bpAwardSummaries, bpAwardDetail, bpAwardsOverview } from "@/views/big-picture/use-bp-discover";
import type { AwardType } from "@/lib/providers/wikidata";
import { fetchRankList, peekRankSnapshot } from "@/lib/harbor-rank";
import { setBundledAwards, bundledAwardsVersion } from "@/lib/awards-history";
import { loadEffective } from "@/lib/settings/profile-store";
import type { Settings } from "@/lib/settings/types";
import { MOVIE_GENRES } from "@/lib/feed/tags";
import { tmdbDiscover } from "@/lib/providers/tmdb";

const RAIL_COUNT = 8;
const MIN_RAIL = 10;

export type DiscoverRail = { key: string; name: string; kicker?: string; metas: Meta[] };
export type QueuePeek = { status: "loading" | "nokey" | "unreachable" | "empty" | "ready"; total: number; posters: string[]; backdrop: string | null };
export type GenreTile = { genre: string; from: string; to: string; ink: string };
/** voyagePool: discover.tsx voyageBannerPool, the Voyages banner shows once it has three. */
export type DiscoverBuild = { rails: DiscoverRail[]; queue: QueuePeek; genres: GenreTile[]; voyagePool: Meta[] };

// use-bp-discover.ts:210-231
function claimRail(batch: Meta[], seen: Set<string>): Meta[] {
  const taken: Meta[] = [];
  const takenIds = new Set<string>();
  for (const m of batch) {
    if (!m.poster || seen.has(m.id) || takenIds.has(m.id)) continue;
    takenIds.add(m.id);
    taken.push(m);
  }
  if (taken.length < MIN_RAIL) {
    for (const m of batch) {
      if (taken.length >= MIN_RAIL) break;
      if (!m.poster || takenIds.has(m.id)) continue;
      takenIds.add(m.id);
      taken.push(m);
    }
  }
  for (const id of takenIds) seen.add(id);
  return taken;
}

export async function rails(settings: Settings, count = RAIL_COUNT): Promise<DiscoverRail[]> {
  const defs = selectDailyRows(settings.tmdbKey, getStore().affinity, settings, count);
  const batches = await Promise.all(defs.map((d) => withTimeout(d.fetch(1), CATALOG_REQUEST_TIMEOUT_MS).catch(() => [] as Meta[])));
  const out: DiscoverRail[] = [];
  const seen = new Set<string>();
  for (let i = 0; i < defs.length; i += 1) {
    let metas = claimRail(batches[i], seen);
    if (settings.animeOnlyInAnimeRoom) metas = metas.filter((m) => !metaLooksAnime(m));
    if (metas.length === 0) continue;
    out.push({ key: defs[i].id, name: defs[i].shelf.title, kicker: defs[i].shelf.kicker, metas });
  }
  return out;
}

// queue/use-bp-queue.ts:46-50, 82-87
function buildOrder(source: FeedItem[]): FeedItem[] {
  const voted = new Set<string>([...getDownvotedIds(), ...getUpvotedIds()]);
  const kept = filterQueuePool(source).filter((it) => !voted.has(it.meta.id));
  return rankByAffinity(shuffleQueuePool(kept));
}

// use-bp-queue.ts `order` / orderedPool: one order per pool build, shared by the Discover band and
// the deck ("the Discover band and the queue have to name the same titles in the same places").
// (device-flow pass) The band built its own shuffle (shuffleQueuePool is Math.random), so its fan
// and backdrop named other titles than the deck opened on, and it kept counting what the deck had
// skipped; and the deck was kept per key only, so the next day's pool (getPool memoises per day)
// never reached it on an Apple TV left running. `source` is getPool's array: identity is the
// "same pool" test, as upstream's.
const FIRST_EXTENSION_PAGE = 2;
let deck: { key: string; source: FeedItem[]; items: FeedItem[]; page: number } | null = null;

function orderedPool(source: FeedItem[], key: string): FeedItem[] {
  if (deck && deck.source === source && deck.key === key) return deck.items;
  deck = { key, source, items: buildOrder(source), page: FIRST_EXTENSION_PAGE };
  return deck.items;
}

export async function queuePeek(settings: Settings, count = 4): Promise<QueuePeek> {
  const key = settings.tmdbKey;
  let entries: FeedItem[] = [];
  let raw = 0;
  try {
    const pool = await getPool(key);
    raw = pool.length;
    entries = orderedPool(pool, key);
  } catch {
    entries = [];
  }
  const status: QueuePeek["status"] = entries.length > 0 ? "ready" : !key ? "nokey" : raw === 0 ? "unreachable" : "empty";
  return {
    status,
    total: entries.length,
    posters: entries.slice(0, count).flatMap((it) => (it.meta.poster ? [it.meta.poster] : [])),
    backdrop: entries[0]?.meta.background ?? null,
  };
}

/** The ordered queue itself (Discovery Queue overlay), first `limit` items. */
export async function queue(settings: Settings, limit = 40): Promise<Meta[]> {
  let pool: FeedItem[] = [];
  try { pool = await getPool(settings.tmdbKey); } catch { pool = []; }
  return buildOrder(pool).slice(0, limit).map((it) => it.meta);
}

export function genres(): GenreTile[] {
  return BP_GENRES.map((g) => {
    const p = GENRE_PALETTE[g] ?? GENRE_PALETTE.Drama;
    return { genre: g, from: p.from, to: p.to, ink: p.ink };
  });
}

/** Up to three backdrops for a genre tile (needs a TMDB key; empty otherwise). */
export async function genreArt(settings: Settings, genre: string): Promise<Meta[]> {
  if (!settings.tmdbKey) return [];
  const metas = await fetchGenreSample(settings.tmdbKey, genre).catch(() => [] as Meta[]);
  return metas.filter((m) => m.background).slice(0, 3);
}

// discover.tsx surprisePool → voyageBannerPool: every rail title with a poster, once, whose
// backdrop is not just the poster again (the TV's Discover has no featured / critics' pick to
// leave out; the rails already honour animeOnlyInAnimeRoom). voyage-banner.tsx keeps eight.
export function voyagePool(list: DiscoverRail[]): Meta[] {
  const seen = new Set<string>();
  const out: Meta[] = [];
  for (const m of list.flatMap((r) => r.metas)) {
    if (!m.poster || seen.has(m.id)) continue;
    seen.add(m.id);
    if (m.background && m.background !== m.poster && m.name) out.push(m);
  }
  return out.slice(0, 8);
}

export async function buildFor(profileId: string, linked: boolean): Promise<DiscoverBuild> {
  const settings = loadEffective(profileId, linked);
  const [r, q] = await Promise.all([rails(settings), queuePeek(settings)]);
  return { rails: r, queue: q, genres: genres(), voyagePool: voyagePool(r) };
}

/** The band's peek on its own: Discover reads it again when the deck closes (skips and blocks). */
export function queuePeekFor(profileId: string, linked: boolean): Promise<QueuePeek> {
  return queuePeek(loadEffective(profileId, linked));
}

export function queueFor(profileId: string, linked: boolean, limit = 40): Promise<Meta[]> {
  return queue(loadEffective(profileId, linked), limit);
}

export function genreArtFor(profileId: string, linked: boolean, genre: string): Promise<Meta[]> {
  return genreArt(loadEffective(profileId, linked), genre);
}

// ----------------------------------------------------------------------- awards / people
/** The 4 MB awards catalog arrives from the app bundle as a JSON string (awards-history.ts:27-35). */
export function installAwards(rawJson: string): number {
  setBundledAwards(JSON.parse(rawJson), true);
  return bundledAwardsVersion();
}
export function awardsInstalled(): boolean {
  return bundledAwardsVersion() > 0;
}
/** Bundled awards (offline): one summary tile per award body plus the band blurb numbers. */
export function awards() {
  const summaries = bpAwardSummaries();
  const overview = bpAwardsOverview();
  return { summaries, overview };
}

/** Every category and its winners by year for one award body. */
export function awardDetail(type: AwardType) {
  const d = bpAwardDetail(type);
  return {
    type,
    title: d.meta.title,
    wins: d.wins,
    span: d.span,
    decades: d.decades,
    groups: d.groups.map((g) => ({
      category: g.category,
      entries: g.entries.slice(0, 200),
    })),
  };
}

// ----------------------------------------------------------------- anime award overlay
// bp-award-tiles.tsx BpAnimeAwardTile (after the classic tiles, past a divider) and
// bp-anime-awards.tsx BpAnimeAward: one tile per bundled anime award source ("{n} winners"),
// and the overlay's data (source chips, "All years" + per-year chips with counts, categories
// with the Grand prize first, winners newest first). The overlay filters by year on the TV.
import { allAwardSources as animeAwardSourceIds, awardSourceMeta as animeAwardSourceMeta, readAnimeAwardSource, animeAwardId, type AwardSourceId } from "@/lib/anime-awards";
import { tmdbImdbId as awardTmdbImdbId } from "@/lib/providers/tmdb/tmdb-imdb-resolve";

export type AnimeAwardTile = { id: AwardSourceId; name: string; shortName: string; wins: number };
export function animeAwardSources(): AnimeAwardTile[] {
  return animeAwardSourceIds().map((id) => {
    const d = readAnimeAwardSource(id);
    const meta = animeAwardSourceMeta(id);
    return { id, name: meta.name, shortName: meta.shortName, wins: d.categories.reduce((n, c) => n + c.winners.length, 0) };
  });
}

export type AnimeAwardView = {
  id: AwardSourceId; name: string; totalWins: number; yearSpan: string; years: number[];
  perYear: Array<{ year: number; count: number }>;
  categories: Array<{ key: string; name: string; isAOTY: boolean; winners: Array<{ year: number; title: string; mapped: boolean }> }>;
};
export function animeAward(source: string): AnimeAwardView {
  const id = (animeAwardSourceIds() as string[]).includes(source) ? (source as AwardSourceId) : "crunchyroll";
  const data = readAnimeAwardSource(id);
  const totalWins = data.categories.reduce((n, c) => n + c.winners.length, 0);
  const yearSpan = data.years.length === 0 ? "" : data.years.length === 1 ? String(data.years[0]) : `${data.years[data.years.length - 1]} - ${data.years[0]}`;
  const counts = new Map<number, number>();
  for (const c of data.categories) for (const w of c.winners) counts.set(w.year, (counts.get(w.year) ?? 0) + 1);
  return {
    id, name: data.meta.name, totalWins, yearSpan, years: data.years,
    perYear: data.years.map((year) => ({ year, count: counts.get(year) ?? 0 })),
    categories: data.categories.map((c) => ({ key: c.key, name: c.name, isAOTY: c.isAOTY,
      winners: c.winners.map((w) => ({ year: w.year, title: w.title, mapped: animeAwardId(w.title) != null })) })),
  };
}

// BpAwardWinner.activate: a mapped winner opens its kitsu/anilist id; otherwise TMDB search
// (tv with first_air_date_year, then movie with year) when a key exists. The TV opens titles by
// IMDb id, so a TMDB hit is resolved to one when it can be (the tmdb: id otherwise).
async function awardSearchTmdb(key: string, title: string, year: number, type: "movie" | "tv"): Promise<number | null> {
  const params = new URLSearchParams({ api_key: key, query: title, include_adult: "false" });
  if (type === "movie") params.set("year", String(year));
  else params.set("first_air_date_year", String(year));
  try {
    const res = await fetch(`https://api.themoviedb.org/3/search/${type}?${params}`);
    if (!res.ok) return null;
    const data = (await res.json()) as { results?: Array<{ id?: number }> };
    return data.results?.[0]?.id ?? null;
  } catch {
    return null;
  }
}
export async function animeAwardOpen(title: string, year: number, profileId: string, linked: boolean): Promise<Meta | null> {
  const mapped = animeAwardId(title);
  if (mapped) return { id: mapped, type: "series", name: title } as Meta;
  const key = loadEffective(profileId, linked).tmdbKey;
  if (!key) return null;
  const tv = await awardSearchTmdb(key, title, year, "tv");
  const hit = tv ? { id: `tmdb:tv:${tv}`, type: "series" } : null;
  const movie = hit ? null : await awardSearchTmdb(key, title, year, "movie");
  const found = hit ?? (movie ? { id: `tmdb:movie:${movie}`, type: "movie" } : null);
  if (!found) return null;
  const imdb = await awardTmdbImdbId(key, found.id).catch(() => null);
  return { id: imdb ?? found.id, type: found.type, name: title } as Meta;
}

/** Harbor's own "Top People" ranking (harbor.site); snapshot first, then a refresh. */
export async function people(limit = 24) {
  const snap = peekRankSnapshot("harbor", "Acting", null);
  const fresh = await fetchRankList("harbor", "Acting", null).catch(() => null);
  const result = fresh ?? snap;
  if (!result || result.source !== "harbor") return [];
  return result.list.slice(0, limit).map((p) => ({ id: p.id, rank: p.rank, name: p.name, profilePath: p.profilePath, department: p.department, country: p.country, score: p.score }));
}

// ------------------------------------------------------------------ genre grid page
/** use-bp-genre-grid: one TMDB discover page for a genre shelf; anime hidden when the viewer asked. */
export type GenrePage = { metas: Meta[]; status: "ready" | "no-key" | "failed" | "filtered" | "empty" };
export async function genrePage(profileId: string, linked: boolean, genre: string, page: number): Promise<GenrePage> {
  const settings = loadEffective(profileId, linked);
  const id = MOVIE_GENRES[genre];
  if (!settings.tmdbKey || id == null) return { metas: [], status: "no-key" };
  try {
    const batch = await tmdbDiscover(settings.tmdbKey, "movie", { with_genres: String(id), "vote_count.gte": "180", sort_by: "popularity.desc", page: String(page) });
    // An empty first page means TMDB did not answer (tmdb-client swallows errors into null).
    if (batch.length === 0) return { metas: [], status: page === 1 ? "failed" : "empty" };
    const shown = settings.hideContent?.anime ? batch.filter((m) => !metaLooksAnime(m)) : batch;
    return { metas: shown, status: shown.length > 0 ? "ready" : "filtered" };
  } catch {
    return { metas: [], status: "failed" };
  }
}

// --------------------------------------------------------------- Discovery Queue deck
// queue/use-bp-queue.ts without React: one ordered deck per TMDB key, extended a page at a time
// once the viewer nears the end, entries dropped as they are snoozed (two weeks) or blocked.
export type QueueEntry = { meta: Meta; tag: string };
export type QueueDeck = { status: "loading" | "nokey" | "unreachable" | "empty" | "ready"; entries: QueueEntry[] };
export async function queueOpen(profileId: string, linked: boolean): Promise<QueueDeck> {
  const key = loadEffective(profileId, linked).tmdbKey;
  let items: FeedItem[] = [];
  let raw = 0;
  // use-bp-queue: a failed getPool shows an empty deck and leaves the order alone.
  try { const pool = await getPool(key); raw = pool.length; items = orderedPool(pool, key); } catch { items = []; }
  const entries = items.map((it) => ({ meta: it.meta, tag: it.tag }));
  const status: QueueDeck["status"] = entries.length > 0 ? "ready" : !key ? "nokey" : raw === 0 ? "unreachable" : "empty";
  return { status, entries };
}

export async function queueExtend(profileId: string, linked: boolean): Promise<QueueEntry[]> {
  const key = loadEffective(profileId, linked).tmdbKey;
  if (!deck || deck.key !== key || !key) return [];
  const page = deck.page;
  deck.page += 1;
  const more = await extendPool(key, page).catch(() => [] as FeedItem[]);
  const have = new Set(deck.items.map((it) => it.meta.id));
  const fresh = buildOrder(more.filter((it) => !have.has(it.meta.id)));
  deck.items = [...deck.items, ...fresh];
  return fresh.map((it) => ({ meta: it.meta, tag: it.tag }));
}

function dropFromDeck(id: string) { if (deck) deck.items = deck.items.filter((it) => it.meta.id !== id); }
/** "Skip · Back in two weeks" */
export function queueSnooze(id: string): void { snoozeQueueItem(id); dropFromDeck(id); }
/** "Not interested · Never shown again" */
export function queueBlock(id: string): void { blockQueueItem(id); dropFromDeck(id); }
