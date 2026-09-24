// The Search room's fan-out, lifted from lib/search-context.tsx without React: TMDB (when a key
// exists), anime (AniList + Jikan + Kitsu), installed addon catalogs fused into Movies/Series,
// Cinemeta, one "From <addon>" group per addon that answers, Live TV channels from the viewer's
// playlists, AniList characters (franchise row), the addon index ("Addons you could install") and
// TVDB collection hits (components/search/use-collection-hits.ts, a separate hook upstream).
// Slow addon groups keep arriving after the call returns, as `harbor:search-addon-group` events
// carrying the same request id.
import { metaLooksAnime } from "@/lib/anime-detect";
import { anilistCharacterSearch, type CharacterHit } from "@/lib/anilist/character";
import { gatherCatalogAddons, type Addon } from "@/lib/addons";
import { searchAll, searchAnime, searchCinemeta, searchLiveTvChannels, type SearchResults } from "@/lib/search";
import { mergeMetas, searchAddonCatalogs, searchAddonGroups, type AddonQuery } from "@/lib/search-addons";
import { searchAddonIndex } from "@/lib/search-addon-index";
import { normalizeSearchQuery } from "@/lib/search-query";
import { loadEffective } from "@/lib/settings/profile-store";
import { entityToMeta, fetchTvdbCollection, fetchTvdbEntity, searchTvdbCollections, type TvdbCollectionHit } from "@/lib/providers/tvdb-collections";
import { HYDRATE_LANES } from "@/views/big-picture/bp-collection-steps";
import { bpMapLimit } from "@/views/big-picture/use-bp-collections";
import type { Meta } from "@/lib/cinemeta";
import { playlists } from "./live";
import { hiddenTabsFor } from "./parental";
import { searchManga } from "@/lib/manga/api";
import type { MangaSummary } from "@/lib/manga/model";

const SOURCE_TIMEOUT_MS = 8000;
const CACHE_TTL_MS = 60_000;
const MAX_CACHE_ENTRIES = 16;

type Cache<T> = Map<string, { expiresAt: number; result: T }>;
const tmdbCache: Cache<SearchResults | null> = new Map();
const animeCache: Cache<Awaited<ReturnType<typeof searchAnime>>> = new Map();
const cineCache: Cache<{ movies: Meta[]; series: Meta[] }> = new Map();

function cached<T>(cache: Cache<T>, key: string, load: () => Promise<T>): Promise<T> {
  const now = Date.now();
  const hit = cache.get(key);
  if (hit && hit.expiresAt > now) return Promise.resolve(hit.result);
  return load().then((result) => {
    cache.set(key, { expiresAt: Date.now() + CACHE_TTL_MS, result });
    if (cache.size > MAX_CACHE_ENTRIES) cache.delete(cache.keys().next().value as string);
    return result;
  });
}

function guard<T>(p: Promise<T>, fallback: T, ms = SOURCE_TIMEOUT_MS): Promise<T> {
  return Promise.race([p.catch(() => fallback), new Promise<T>((resolve) => setTimeout(() => resolve(fallback), ms))]);
}

type TitledMeta = { name?: string; releaseInfo?: string };
function dedupeByTitle<T extends TitledMeta>(list: T[]): T[] {
  const seen = new Map<string, T[]>();
  const out: T[] = [];
  const norm = (s: string) => s.toLowerCase().replace(/[^a-z0-9]+/g, " ").trim();
  for (const m of list) {
    const key = norm(m.name ?? "");
    if (!key) { out.push(m); continue; }
    const bucket = seen.get(key);
    if (!bucket) { seen.set(key, [m]); out.push(m); continue; }
    const year = (m.releaseInfo ?? "").slice(0, 4);
    const clashes = bucket.some((prev) => { const py = (prev.releaseInfo ?? "").slice(0, 4); return !year || !py || year === py; });
    if (clashes) continue;
    bucket.push(m);
    out.push(m);
  }
  return out;
}
const normShow = (s: string) => s.toLowerCase().replace(/[^a-z0-9]+/g, " ").trim();

let addonsMemo: { key: string | null; addons: Addon[] } | null = null;
if (typeof window !== "undefined") window.addEventListener("harbor:addons-changed", () => { addonsMemo = null; });
async function ensureAddons(authKey: string | null): Promise<Addon[]> {
  if (addonsMemo && addonsMemo.key === authKey) return addonsMemo.addons;
  const a = await gatherCatalogAddons(authKey).catch(() => [] as Addon[]);
  addonsMemo = { key: authKey, addons: a };
  return a;
}

let requestSeq = 0;

export type FanOut = SearchResults & {
  requestId: number;
  /** Every addon slot in installed order, including pending/empty/failed ones (bp-search-rows). */
  addonQueries: AddonQuery[];
  /** use-collection-hits: TVDB lists matching the query (Collections chip, banner cells). */
  collections: TvdbCollectionHit[];
};

/** use-collection-hits.ts useCollectionHits: nothing under three characters, never throws. */
export function collections(query: string): Promise<TvdbCollectionHit[]> {
  const q = query.trim();
  if (q.length < 3) return Promise.resolve([]);
  return searchTvdbCollections(q).catch(() => [] as TvdbCollectionHit[]);
}

/**
 * bp-collection.tsx useBpCollection: a TVDB list's first 40 entries hydrated to metas
 * (HYDRATE_LANES wide, entityToMeta: imdb id when TVDB has one), shaped like the Collections
 * room's card so the same items overlay can show it. null when the list could not be loaded.
 */
export async function collection(id: number, fallbackName: string, image: string | null) {
  const coll = await fetchTvdbCollection(id).catch(() => null);
  if (!coll) return null;
  const wanted = coll.entries.slice(0, 40);
  const found = await bpMapLimit(wanted, HYDRATE_LANES, (e) => fetchTvdbEntity(e.kind, e.tvdbId).catch(() => null));
  const items = found.filter((c): c is NonNullable<typeof c> => c !== null).map((c) => {
    const m = entityToMeta(c);
    return { id: m.id, type: m.type, name: m.name, poster: m.poster ?? null };
  });
  return {
    key: `tvdb:${coll.id}`,
    source: "tvdb",
    name: coll.name || fallbackName,
    image: coll.image ?? image,
    count: items.length,
    byline: "Collection",
    description: coll.overview,
    items,
    hidden: 0,
  };
}

export async function fanOut(query: string, profileId: string, linked: boolean, authKey: string | null): Promise<FanOut> {
  const settings = loadEffective(profileId, linked);
  const trimmed = query.trim();
  const requestId = ++requestSeq;
  const empty: SearchResults = { query: trimmed, topMatch: null, people: [], movies: [], series: [], liveTv: [], anime: [], manga: [], characters: [], addonGroups: [], addons: [], intent: null };
  if (!trimmed) return { ...empty, requestId, addonQueries: [], collections: [] };
  const hide = settings.hideContent;
  // search-context.tsx: anime needs the tab unlocked-by-profile AND not hidden; Live TV needs
  // its tab not locked. `hiddenTabs` is the profile's lockedTabs whether or not a PIN is set.
  const hiddenTabs = hiddenTabsFor(profileId);
  const animeAllowed = !hiddenTabs.anime && !hide.anime;
  // search-context: manga is asked for only when the reader is switched on and not hidden, and
  // the franchise (character) search runs when either anime or manga is allowed.
  const mangaAllowed = settings.mangaEnabled === true && !hide.manga;
  const franchiseAllowed = animeAllowed || mangaAllowed;
  const lists = playlists();
  const liveTv = !hiddenTabs.liveTv && lists.length > 0 ? searchLiveTvChannels(trimmed, lists) : [];
  const normalized = normalizeSearchQuery(trimmed);
  const key = settings.tmdbKey?.trim() ?? "";
  const addonsP = ensureAddons(authKey);

  const tmdbP = key
    ? guard<SearchResults | null>(cached(tmdbCache, [key, settings.tmdbLanguage, settings.translateTitles, normalized].join("\0"), () => searchAll(key, trimmed)), null)
    : Promise.resolve(null);
  const animeP = animeAllowed ? guard(cached(animeCache, normalized, () => searchAnime(trimmed)), []) : Promise.resolve([]);
  const charactersP: Promise<CharacterHit[]> = franchiseAllowed ? guard(anilistCharacterSearch(trimmed), []) : Promise.resolve([]);
  const mangaP: Promise<MangaSummary[]> = mangaAllowed ? guard(searchManga(trimmed), []) : Promise.resolve([]);
  const addonP = guard(addonsP.then((a) => searchAddonCatalogs(a, trimmed)), { movies: [] as Meta[], series: [] as Meta[] });
  const cineP = guard(cached(cineCache, normalized, () => searchCinemeta(trimmed)), { movies: [], series: [] });
  const collectionsP = guard(collections(trimmed), [] as TvdbCollectionHit[]);

  const queries: AddonQuery[] = [];
  const dropAnime = <T extends { id: string }>(list: T[]): T[] => (hide.anime ? list.filter((m) => !metaLooksAnime(m)) : list);
  const groupsP = addonsP.then((a) => searchAddonGroups(a, trimmed, undefined, (q) => {
    const metas = dropAnime(q.metas);
    const at = queries.findIndex((x) => x.id === q.id);
    const next = { ...q, metas };
    if (at < 0) queries.push(next); else queries[at] = next;
    if (q.state !== "pending" && typeof window !== "undefined") {
      window.dispatchEvent(new CustomEvent("harbor:search-addon-group", { detail: { requestId, query: trimmed, group: next } }));
    }
  })).catch(() => []);
  // Groups are streamed; the call itself waits only for the primary sources.
  void groupsP;

  const [tmdb, anime, characters, addon, cine, collectionHits, manga] = await Promise.all([tmdbP, animeP, charactersP, addonP, cineP, collectionsP, mangaP]);
  const base = tmdb ?? empty;
  const animeTitles = new Set(anime.map((a) => normShow(a.name)));
  const notAnimeDupe = (m: { name?: string }) => animeTitles.size === 0 || !animeTitles.has(normShow(m.name ?? ""));
  const movies = dropAnime(dedupeByTitle(mergeMetas(mergeMetas(base.movies, addon.movies), cine.movies)).filter(notAnimeDupe));
  const series = dropAnime(dedupeByTitle(mergeMetas(mergeMetas(base.series, addon.series), cine.series)).filter(notAnimeDupe));
  const shown = new Set([...movies, ...series].map((m) => m.id));
  const topMatch = hide.anime && base.topMatch && metaLooksAnime(base.topMatch.meta) ? null : base.topMatch;
  return {
    ...base,
    requestId,
    topMatch,
    movies,
    series,
    liveTv,
    anime,
    manga,
    characters: characters
      .map((ch) => ({ ...ch, anime: animeAllowed ? ch.anime : [], manga: mangaAllowed ? ch.manga : [] }))
      .filter((ch) => ch.anime.length + ch.manga.length > 0),
    addonGroups: queries.filter((q) => q.state === "ok").map((q) => ({ id: q.id, name: q.name, logo: q.logo, metas: q.metas.filter((m) => !shown.has(m.id)) })).filter((g) => g.metas.length > 0),
    addonQueries: queries.slice(),
    addons: searchAddonIndex(trimmed),
    collections: collectionHits,
  };
}
