// Anime "Top Picks for You" (use-bp-anime-hero.ts useBpAnimeTopPicks over
// lib/use-anime-top-picks.ts useAnimeTopPicks and lib/use-watch-history-recs.ts), without React.
// Seeds: watch-history recommendations (Jikan recs for the first six anime in Continue
// Watching), sequels of finished franchises (Kitsu relations), up to three genres from the
// taste affinity topped up with settings.animeFavoriteGenres, then new / airing / top pages.
// Scoring, exclusion, the daily page rotation and the shown-ring are upstream's own exports
// (lib/anime-top-picks-utils.ts). Every Jikan call goes through lib/providers/jikan's
// throttled queue (400 ms spacing, 429 back-off), the same queue the Anime room's spec rows
// use, so picks never add a second request stream.
//
// The room reads picks synchronously; a build runs in the background when its inputs change
// and raises `harbor:anime-updated` (through `notify`) as picks land, the way the hook's
// setPicks re-renders the row.
import type { Meta } from "@/lib/cinemeta";
import { subscribe as subscribeTaste } from "@/lib/discover/store";
import { getDownvotedIds, getUpvotedIds, subscribePrefs } from "@/lib/feed/preferences";
import { recentlyPlayed, subscribePlayback, watchTitleKey } from "@/lib/playback-history";
import {
  animeFranchiseKey,
  jikanByGenre,
  jikanNewReleases,
  jikanRecommendationsForMalId,
  jikanResolveMalId,
  jikanTopAiring,
  jikanTopAnime,
  jikanTopPopular,
  stripFranchiseSuffix,
} from "@/lib/providers/jikan";
import { kitsuRelated, parseKitsuId } from "@/lib/providers/kitsu";
import type { LibraryItem } from "@/lib/stremio";
import {
  animeSeedGenres,
  buildExclusion,
  dayIndex,
  finishedFranchises,
  pageFor,
  rankPicks,
  recordShownPicks,
  scorePick,
  type PickEntry,
  type PickSource,
} from "@/lib/anime-top-picks-utils";
import { animeFiltered, enrichAnimeCountry, type AnimeFilterOpts } from "@/lib/anime-filter";

// ------------------------------------------------ lib/use-watch-history-recs.ts (ported)
// Ported rather than imported: upstream's module saves both of its caches from one timer, and
// a second in-memory copy of the recs cache here would overwrite the other's on every save.
const MAL_CACHE_KEY = "harbor.anime.mal_id_by_franchise.v1";
const REC_CACHE_KEY = "harbor.anime.recs_by_mal.v1";
const REC_TTL_MS = 30 * 24 * 60 * 60 * 1000;

type MalIdCache = Record<string, number>;
type RecCache = Record<string, { metas: Meta[]; t: number }>;
let malCache: MalIdCache | null = null;
let recCache: RecCache | null = null;

function loadMalCache(): MalIdCache {
  if (malCache) return malCache;
  try {
    const parsed = JSON.parse(localStorage.getItem(MAL_CACHE_KEY) ?? "{}") as MalIdCache;
    const out: MalIdCache = {};
    for (const [k, v] of Object.entries(parsed)) if (typeof v === "number") out[k] = v;
    malCache = out;
  } catch {
    malCache = {};
  }
  return malCache!;
}

function loadRecCache(): RecCache {
  if (recCache) return recCache;
  try {
    const parsed = JSON.parse(localStorage.getItem(REC_CACHE_KEY) ?? "{}") as RecCache;
    const out: RecCache = {};
    for (const [k, v] of Object.entries(parsed)) if (Array.isArray(v?.metas) && v.metas.length > 0) out[k] = v;
    recCache = out;
  } catch {
    recCache = {};
  }
  return recCache!;
}

let saveTimer: ReturnType<typeof setTimeout> | null = null;
function scheduleSave(): void {
  if (saveTimer != null) clearTimeout(saveTimer);
  saveTimer = setTimeout(() => {
    saveTimer = null;
    try {
      localStorage.setItem(MAL_CACHE_KEY, JSON.stringify(malCache ?? {}));
      localStorage.setItem(REC_CACHE_KEY, JSON.stringify(recCache ?? {}));
    } catch {
      /* quota — ignore */
    }
  }, 400);
}

const malInflight = new Map<string, Promise<number | null>>();
const malMisses = new Set<string>();

/** use-watch-history-recs.ts malIdForItem: mal: ids directly, else a Jikan title search, cached per franchise. */
async function malIdForItem(item: LibraryItem): Promise<number | null> {
  const direct = item._id.match(/^mal:(\d+)/);
  if (direct) return parseInt(direct[1], 10);
  const cache = loadMalCache();
  const fk = animeFranchiseKey(stripFranchiseSuffix(item.name));
  const hit = cache[fk];
  if (typeof hit === "number") return hit;
  if (malMisses.has(fk)) return null;
  const existing = malInflight.get(fk);
  if (existing) return existing;
  const p = (async () => {
    try {
      const id = await jikanResolveMalId(stripFranchiseSuffix(item.name));
      if (typeof id === "number") {
        cache[fk] = id;
        scheduleSave();
      } else {
        malMisses.add(fk);
      }
      return id;
    } finally {
      malInflight.delete(fk);
    }
  })();
  malInflight.set(fk, p);
  return p;
}

async function recsForMalId(malId: number): Promise<Meta[]> {
  const cache = loadRecCache();
  const hit = cache[String(malId)];
  if (hit && Date.now() - hit.t < REC_TTL_MS) return hit.metas;
  const metas = await jikanRecommendationsForMalId(malId);
  if (metas.length > 0) {
    cache[String(malId)] = { metas, t: Date.now() };
    scheduleSave();
  }
  return metas;
}

/** useWatchHistoryRecommendations: the six newest kitsu/mal CW items' Jikan recs, scored by rank. */
async function watchHistoryRecs(cwItems: LibraryItem[]): Promise<Meta[]> {
  const seeds = cwItems.slice(0, 6).filter((i) => i.name && (i._id.startsWith("kitsu:") || i._id.startsWith("mal:")));
  if (seeds.length === 0) return [];
  const watchedKeys = new Set(seeds.map((s) => animeFranchiseKey(stripFranchiseSuffix(s.name))));
  const pools = await Promise.all(seeds.map(async (item) => {
    const malId = await malIdForItem(item).catch(() => null);
    if (!malId) return [] as Meta[];
    return recsForMalId(malId).catch(() => [] as Meta[]);
  }));
  const scoreByKey = new Map<string, { meta: Meta; score: number }>();
  for (const pool of pools) {
    for (let i = 0; i < pool.length; i++) {
      const m = pool[i];
      const fk = animeFranchiseKey(m.name);
      if (watchedKeys.has(fk)) continue;
      const weight = 1 + Math.max(0, 12 - i) * 0.05;
      const existing = scoreByKey.get(fk);
      if (existing) existing.score += weight;
      else scoreByKey.set(fk, { meta: m, score: weight });
    }
  }
  return Array.from(scoreByKey.values()).sort((a, b) => b.score - a.score).map((x) => x.meta);
}

// ---------------------------------------------------- lib/use-anime-top-picks.ts (ported)
const CAP = 24;
const SEQUEL_ROLES = new Set(["sequel", "side_story", "parent_story", "spinoff", "spin_off"]);
const VISIT_KEY = "harbor.anime.toppicks.visit.v1";
const CACHE_KEY = "harbor.anime.toppicks.cache.v2";

function nextVisit(): number {
  try {
    const cur = Number(localStorage.getItem(VISIT_KEY) ?? "0");
    const next = (Number.isFinite(cur) ? cur : 0) + 1;
    localStorage.setItem(VISIT_KEY, String(next));
    return next;
  } catch {
    return Math.floor(Math.random() * 1000);
  }
}

function readCachedPicks(): Meta[] {
  try {
    const raw = localStorage.getItem(CACHE_KEY);
    if (!raw) return [];
    const arr = JSON.parse(raw) as Meta[];
    if (!Array.isArray(arr)) return [];
    const watched = recentlyPlayed();
    const blocked = new Set<string>([...getDownvotedIds(), ...getUpvotedIds()]);
    return arr
      .filter((m) => m && typeof m.id === "string" && typeof m.name === "string")
      .filter((m) => !blocked.has(m.id))
      .filter((m) => !watched.ids.has(m.id) && !watched.titles.has(watchTitleKey(m.name)))
      .slice(0, CAP);
  } catch {
    return [];
  }
}

function writeCachedPicks(metas: Meta[]): void {
  try {
    localStorage.setItem(CACHE_KEY, JSON.stringify(metas.slice(0, CAP)));
  } catch {}
}

function cleanName(m: Meta): Meta {
  const name = stripFranchiseSuffix(m.name);
  return name === m.name ? m : { ...m, name };
}

async function sequelMetas(seeds: LibraryItem[]): Promise<Meta[]> {
  const lists = await Promise.all(seeds.slice(0, 6).map(async (item) => {
    try {
      const malId = await malIdForItem(item);
      if (!malId) return [] as Meta[];
      const kitsuId = parseKitsuId(item._id);
      if (kitsuId == null) return [] as Meta[];
      const related = await kitsuRelated(kitsuId);
      return related.filter((rel) => SEQUEL_ROLES.has(rel.role)).map((rel) => rel.meta);
    } catch {
      return [] as Meta[];
    }
  }));
  return lists.flat();
}

export type TopPicksInput = {
  /** The whole cloud library (finished franchises seed sequels and are excluded). */
  libItems: LibraryItem[];
  /** The anime Continue Watching row before the advance pass (use-bp-anime-cw raw). */
  continueWatching: LibraryItem[];
  heroMetas: Meta[];
  /** settings.animeFavoriteGenres (Jikan genre ids). */
  favoriteGenres: number[];
};

// The hook's state, kept for the engine session.
let picks: Meta[] | null = null;
let enriched: { of: Meta[]; metas: Meta[] } | null = null;
let seed: number | null = null;
let version = 0;
let builtKey: string | null = null;
let generation = 0;
let subscribed = false;
let bumpTimer: ReturnType<typeof setTimeout> | null = null;

function current(): Meta[] {
  if (picks === null) picks = readCachedPicks();
  return picks;
}

function setPicks(next: Meta[], notify: () => void): void {
  picks = next;
  notify();
  // useBpAnimeTopPicks: AniList countries join so the origin filter can act on them.
  const of = next;
  void enrichAnimeCountry(next).then((metas) => {
    if (picks !== of) return;
    enriched = { of, metas };
    if (metas !== of) notify();
  }).catch(() => {});
}

/** use-anime-top-picks.ts:108-139: taste, playback and vote changes rebuild (600 ms debounce). */
function ensureSubscribed(): void {
  if (subscribed) return;
  subscribed = true;
  const bump = () => {
    if (bumpTimer) clearTimeout(bumpTimer);
    bumpTimer = setTimeout(() => { bumpTimer = null; version += 1; }, 600);
  };
  const dropWatched = () => {
    const watched = recentlyPlayed();
    if (watched.ids.size === 0 && watched.titles.size === 0 || picks === null) return;
    const next = picks.filter((m) => !watched.ids.has(m.id) && !watched.titles.has(watchTitleKey(m.name)));
    if (next.length !== picks.length) picks = next;
  };
  subscribeTaste(bump);
  subscribePlayback(() => { dropWatched(); bump(); });
  subscribePrefs(() => {
    const blocked = new Set<string>([...getDownvotedIds(), ...getUpvotedIds()]);
    if (picks) picks = picks.filter((m) => !blocked.has(m.id));
    bump();
  });
}

/** The effect body of useAnimeTopPicks (use-anime-top-picks.ts:147-229). */
async function build(input: TopPicksInput, gen: number, notify: () => void): Promise<void> {
  const live = () => gen === generation;
  const { libItems, continueWatching, heroMetas, favoriteGenres } = input;
  // Upstream seeds per mount; the engine lives all session, so at least a new day re-seeds (review 32).
  if (seed === null || Math.floor(seed / 1000) !== dayIndex()) seed = dayIndex() * 1000 + nextVisit();
  const rotation = seed;
  // useWatchHistoryRecommendations feeds the hook as `watchHistoryRecs`: started alongside the
  // pages (as upstream runs them) and awaited with them (review 32).
  const recsP = watchHistoryRecs(continueWatching).catch(() => [] as Meta[]);
  const genres = animeSeedGenres(favoriteGenres);
  const { seeds } = finishedFranchises(libItems);
  const pageSeed = dayIndex();
  const [recs, airing, fresh, ...genreLists] = await Promise.all([
    recsP,
    jikanTopAiring(pageFor("airing", pageSeed)).catch(() => [] as Meta[]),
    jikanNewReleases(pageFor("new", pageSeed)).catch(() => [] as Meta[]),
    ...genres.map((id) => jikanByGenre(id, pageFor(`g${id}`, pageSeed)).catch(() => [] as Meta[])),
  ]);
  if (!live()) return;

  const { skip } = buildExclusion({ heroMetas, continueWatching, libItems });
  const byFranchise = new Map<string, PickEntry>();
  const add = (m: Meta, source: PickSource, idx = 0, len = 0) => {
    if (skip(m)) return;
    const fk = animeFranchiseKey(m.name);
    const s = scorePick(m, source, idx, len);
    const existing = byFranchise.get(fk);
    if (existing) existing.score += s;
    else byFranchise.set(fk, { meta: cleanName(m), score: s });
  };

  for (let i = 0; i < recs.length; i++) add(recs[i], "rec", i, recs.length);
  const maxGenre = Math.max(0, ...genreLists.map((l) => l.length));
  for (let i = 0; i < maxGenre; i++) {
    for (const list of genreLists) if (list[i]) add(list[i], "genre");
  }
  for (const m of fresh) add(m, "new");
  for (const m of airing) add(m, "airing");

  if (current().length === 0 && byFranchise.size > 0) setPicks(rankPicks(byFranchise, rotation, CAP), notify);

  const sequels = await sequelMetas(seeds);
  if (!live()) return;
  for (let i = 0; i < sequels.length; i++) add(sequels[i], "sequel");

  if (current().length === 0 && byFranchise.size > 0) setPicks(rankPicks(byFranchise, rotation, CAP), notify);

  let page = 2;
  while (byFranchise.size < CAP && page <= 5) {
    if (!live()) return;
    const more = await Promise.all([
      ...genres.map((id) => jikanByGenre(id, page).catch(() => [] as Meta[])),
      page === 2 ? jikanTopAnime(1).catch(() => [] as Meta[]) : Promise.resolve([] as Meta[]),
      page === 3 ? jikanTopPopular(1).catch(() => [] as Meta[]) : Promise.resolve([] as Meta[]),
    ]);
    if (!live()) return;
    for (const list of more) for (const m of list) add(m, "top");
    page++;
  }

  if (byFranchise.size < CAP) {
    const floor = await jikanTopAiring(1).catch(() => [] as Meta[]);
    if (!live()) return;
    const watched = recentlyPlayed();
    for (const m of floor) {
      if (byFranchise.size >= CAP) break;
      const fk = animeFranchiseKey(m.name);
      if (byFranchise.has(fk)) continue;
      if (watched.ids.has(m.id) || watched.titles.has(watchTitleKey(m.name))) continue;
      byFranchise.set(fk, { meta: cleanName(m), score: scorePick(m, "airing") });
    }
  }

  const ranked = rankPicks(byFranchise, rotation, CAP);
  recordShownPicks(ranked.map((m) => animeFranchiseKey(m.name)));
  if (live()) {
    setPicks(ranked, notify);
    writeCachedPicks(ranked);
  }
}

/**
 * useBpAnimeTopPicks: the current picks (cached ones first, from the last session), country-
 * enriched when that has landed and run through the anime filter. A change of inputs starts
 * a build; `notify` fires as it lands. Upstream falls back to the hosted hero list when every
 * pick is filtered out; the caller supplies the TV's fallback.
 */
export function animeTopPicks(input: TopPicksInput, filterOpts: AnimeFilterOpts, notify: () => void): Meta[] {
  ensureSubscribed();
  const raw = current();
  // use-anime-top-picks.ts:141-146 dependency keys (heroMetas is read, not a key).
  const finishedKey = finishedFranchises(input.libItems).seeds.map((s) => s._id).join(",");
  const cwKey = input.continueWatching.map((i) => i._id).join(",");
  const genreKey = input.favoriteGenres.join(",");
  const key = `${version}|${finishedKey}|${cwKey}|${genreKey}`;
  if (key !== builtKey) {
    builtKey = key;
    const gen = ++generation;
    running = build(input, gen, notify).catch(() => {});
  }
  const base = enriched && enriched.of === raw && enriched.metas.length > 0 ? enriched.metas : raw;
  return base.filter((m) => !animeFiltered(m, filterOpts));
}

let running: Promise<void> | null = null;
/** Test hook: resolves when the latest build has finished. */
export async function topPicksSettled(): Promise<void> {
  await running;
}

/** Test hook: forget the session state (not the stores). */
export function resetAnimeTopPicks(): void {
  picks = null;
  enriched = null;
  seed = null;
  builtKey = null;
  generation += 1;
  malCache = null;
  recCache = null;
  malMisses.clear();
}
