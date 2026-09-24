// Collections room (bp-collections.tsx / bp-collection-steps.ts without React): this device's
// own collections (editable from the TV, after community-hub.tsx / community-editor.tsx),
// community collections from harbor.site, TMDB curated franchises (needs a TMDB key) and TVDB
// lists (Harbor's TVDB proxy, no key).
import type { Meta } from "@/lib/cinemeta";
import { fetchCommunityCollections, publishCollections, notifyCommunityChanged, type CommunityCollection } from "@/lib/social/collections-sync";
import { purgeCollectionFromPages } from "@/lib/page-collection-rows";
import {
  readCollections, absCollectionImage, createCollection, renameCollection, deleteCollection, addToCollection,
  removeFromCollection, saveCommunityCollection, MAX_COLLECTIONS, MAX_COLLECTION_ITEMS,
  type Collection, type CollectionItem,
} from "@/lib/collections";
import { COLLECTION_CATEGORIES, COLLECTIONS_CATALOG } from "@/lib/collections-catalog";
import { searchTvdbCollectionsOrNull, fetchTvdbCollection, fetchTvdbEntity, entityToMeta } from "@/lib/providers/tvdb-collections";
import { searchAll, searchCinemeta } from "@/lib/search";
import { BP_COLLECTIONS_ALL, bpCatalogFor, bpMapLimit, resolveBpCollection } from "@/views/big-picture/use-bp-collections";
import { loadEffective } from "@/lib/settings/profile-store";

export type CollectionCard = {
  key: string;
  source: "mine" | "community" | "tmdb" | "tvdb";
  /** The collection's own id (a uuid for mine/community, the TMDB/TVDB id otherwise). */
  ref: string;
  /** community: the owner's handle, for "Save to my collections". */
  handle?: string;
  /** community: already saved into this device's collections. */
  saved?: boolean;
  name: string;
  image: string | null;
  /** null for a TVDB list until it is opened (bp-collection-card "TVDB list"). */
  count: number | null;
  byline: string | null;
  description: string | null;
  items: CollectionItem[];
  /** bp-collection-items: manga items are not shown in Big Picture, but the viewer is told how many. */
  hidden: number;
};

function card(c: Collection, source: "mine" | "community", byline: string | null): CollectionCard {
  const items = c.items.filter((i) => i.type !== "manga");
  return {
    key: `${source}:${c.id}`,
    source,
    ref: c.id,
    name: c.name,
    image: absCollectionImage(c.coverImage ?? c.bgImage ?? undefined) ?? items.find((i) => i.poster)?.poster ?? null,
    count: items.length,
    byline,
    description: c.description ?? null,
    items,
    hidden: c.items.length - items.length,
  };
}

export function mine(): CollectionCard[] {
  return readCollections().map((c) => card(c, "mine", null));
}

let lastCommunity: CommunityCollection[] = [];

function isSaved(c: CommunityCollection, own: Collection[]): boolean {
  return own.some((x) => x.sourceHandle === c.handle && x.sourceId === c.id);
}

export async function community(): Promise<CollectionCard[]> {
  const list: CommunityCollection[] = await fetchCommunityCollections();
  lastCommunity = list;
  const own = readCollections();
  return list.map((c) => ({ ...card(c, "community", c.displayName || c.handle), handle: c.handle, saved: isSaved(c, own) }));
}

export async function all(): Promise<{ mine: CollectionCard[]; community: CollectionCard[] }> {
  const m = mine();
  const c = await community().catch(() => [] as CollectionCard[]);
  return { mine: m, community: c };
}


// ------------------------------------------------------------- TMDB curated collections
// bp-collection-steps "curated" phase: the ~110-franchise catalog (lib/collections-catalog),
// resolved against TMDB a page at a time, four lanes wide, ids healed by name when TMDB moved them.
const TMDB_PAGE = 12;
export function categories(): string[] { return [BP_COLLECTIONS_ALL, ...COLLECTION_CATEGORIES]; }

export async function tmdb(profileId: string, linked: boolean, category: string, page: number): Promise<{ cards: CollectionCard[]; done: boolean }> {
  const key = loadEffective(profileId, linked).tmdbKey;
  if (!key) return { cards: [], done: true };
  const catalog = bpCatalogFor(category || BP_COLLECTIONS_ALL);
  const slice = catalog.slice((page - 1) * TMDB_PAGE, page * TMDB_PAGE);
  if (slice.length === 0) return { cards: [], done: true };
  const found = await bpMapLimit(slice, 4, (c) => resolveBpCollection(key, c.id, c.name).catch(() => null));
  const cards: CollectionCard[] = [];
  found.forEach((tc, i) => {
    if (!tc || tc.parts.length < 2) return;
    const items: CollectionItem[] = tc.parts.map((m) => ({ id: m.id, type: m.type, name: m.name, poster: m.poster } as CollectionItem));
    cards.push({ key: `tmdb:${tc.id}`, source: "tmdb", ref: String(tc.id), name: tc.name, image: tc.backdrop ?? tc.poster ?? tc.parts.find((m) => m.poster)?.poster ?? null,
      count: items.length, byline: slice[i].cats[0] ?? "TMDB", description: tc.overview || null, items, hidden: 0 });
  });
  return { cards, done: page * TMDB_PAGE >= catalog.length };
}

// ------------------------------------------------------------------------ TVDB lists
// bp-collection-steps stepTvdb: TVDB lists found by searching the curated franchise names
// (TVDB_SEEDS), five names per pull, three lanes, the first three hits of each. "All" stops
// after ten names and offers "See every TVDB list"; the TVDB source walks every name.
const TVDB_SEEDS = COLLECTIONS_CATALOG.map((c) => c.name);
const TVDB_NAMES_PER_PULL = 5;
const TVDB_HITS_PER_NAME = 3;
const TVDB_ALL_CAP = 10;

export type TvdbPage = {
  cards: CollectionCard[];
  /** The seed index to pass back for the next pull. */
  next: number;
  done: boolean;
  /** Every name in this pull went unanswered ("TVDB lists are unavailable right now."). */
  failed: boolean;
  /** "All" stopped at its cap while more names remain (the "See every TVDB list" card). */
  capped: boolean;
};

export async function tvdb(scope: "all" | "tvdb", from: number): Promise<TvdbPage> {
  const limit = Math.min(TVDB_SEEDS.length, scope === "all" ? TVDB_ALL_CAP : TVDB_SEEDS.length);
  const start = Math.max(0, Math.floor(Number(from) || 0));
  if (start >= limit) return { cards: [], next: start, done: true, failed: false, capped: limit < TVDB_SEEDS.length };
  const slice = TVDB_SEEDS.slice(start, Math.min(start + TVDB_NAMES_PER_PULL, limit));
  let broke = 0;
  const groups = await bpMapLimit(slice, 3, async (n) => {
    const hits = await searchTvdbCollectionsOrNull(n).catch(() => null);
    if (hits) return hits;
    broke += 1;
    return [];
  });
  const seen = new Set<string>();
  const cards: CollectionCard[] = [];
  for (const g of groups) {
    for (const h of g.slice(0, TVDB_HITS_PER_NAME)) {
      const key = `tvdb:${h.id}`;
      if (seen.has(key)) continue;
      seen.add(key);
      cards.push({ key, source: "tvdb", ref: String(h.id), name: h.name, image: h.image, count: null, byline: null, description: h.overview, items: [], hidden: 0 });
    }
  }
  const next = start + slice.length;
  const done = next >= limit;
  return { cards, next, done, failed: broke === slice.length, capped: done && limit < TVDB_SEEDS.length };
}

// bp-collection.tsx useBpCollection: the list's entries (at most 40) hydrated four lanes wide,
// kept in list order; an entity TVDB cannot describe is left out.
const TVDB_MAX_ENTRIES = 40;
const TVDB_HYDRATE_LANES = 4;

export type TvdbDetail = { name: string; overview: string | null; image: string | null; items: CollectionItem[]; failed: boolean };

export async function tvdbDetail(id: number | string, fallbackName: string): Promise<TvdbDetail> {
  const coll = await fetchTvdbCollection(Number(id)).catch(() => null);
  if (!coll) return { name: fallbackName, overview: null, image: null, items: [], failed: true };
  const wanted = coll.entries.slice(0, TVDB_MAX_ENTRIES);
  const found = await bpMapLimit(wanted, TVDB_HYDRATE_LANES, (e) => fetchTvdbEntity(e.kind, e.tvdbId).catch(() => null));
  const items: CollectionItem[] = [];
  const seen = new Set<string>();
  for (const entity of found) {
    if (!entity) continue;
    const m = entityToMeta(entity);
    if (seen.has(m.id)) continue;
    seen.add(m.id);
    items.push({ id: m.id, type: m.type === "movie" ? "movie" : "series", name: m.name, poster: m.poster });
  }
  return { name: coll.name, overview: coll.overview, image: coll.image, items, failed: false };
}

// ------------------------------------------------------------------ editing (mine only)
// community-hub.tsx / community-editor.tsx over lib/collections: new, rename, delete, add and
// remove titles, and "Save to my collections" for a community collection.
export function limits(): { collections: number; items: number } {
  return { collections: MAX_COLLECTIONS, items: MAX_COLLECTION_ITEMS };
}

export function mineCard(id: string): CollectionCard | null {
  const c = readCollections().find((x) => x.id === id);
  return c ? card(c, "mine", null) : null;
}

/** community-hub "New collection"; null when the 24-collection cap is reached. */
export function create(name: string): CollectionCard | null {
  const id = createCollection(name.trim() || "Untitled collection");
  return id ? mineCard(id) : null;
}

export function rename(id: string, name: string): CollectionCard | null {
  renameCollection(id, name);
  return mineCard(id);
}

/** community-hub remove: delete, drop it from any page rows, republish (fails quietly signed out). */
export function remove(id: string): void {
  deleteCollection(id);
  purgeCollectionFromPages(id);
  void publishCollections(readCollections()).then(() => notifyCommunityChanged()).catch(() => {});
}

/** Returns the collection after the change so the overlay can redraw in place. */
export function addItem(id: string, item: { id: string; type: string; name: string; poster?: string | null }): CollectionCard | null {
  addToCollection(id, { id: item.id, type: item.type, name: item.name, poster: item.poster ?? undefined });
  return mineCard(id);
}

export function removeItem(id: string, itemId: string): CollectionCard | null {
  removeFromCollection(id, itemId);
  return mineCard(id);
}

/** community-hub "Save to my collections": copies it here once; returns the local copy. */
export function saveCommunity(handle: string, id: string): CollectionCard | null {
  const c = lastCommunity.find((x) => x.handle === handle && x.id === id);
  if (!c) return null;
  const local = saveCommunityCollection({
    handle: c.handle, id: c.id, name: c.name, description: c.description, coverImage: c.coverImage,
    bgImage: c.bgImage, tags: c.tags, items: c.items,
  });
  return local ? mineCard(local) : null;
}

/** community-editor search ("Search movies, shows, and manga to add"); movies and shows on a TV. */
export async function searchTitles(query: string, profileId: string, linked: boolean): Promise<Meta[]> {
  const q = query.trim();
  if (q.length < 2) return [];
  const key = loadEffective(profileId, linked).tmdbKey?.trim() ?? "";
  let movies: Meta[] = [];
  let series: Meta[] = [];
  if (key) {
    const r = await searchAll(key, q).catch(() => null);
    if (r) { movies = r.movies; series = r.series; }
  }
  if (movies.length === 0 && series.length === 0) {
    const c = await searchCinemeta(q).catch(() => ({ movies: [] as Meta[], series: [] as Meta[] }));
    movies = c.movies; series = c.series;
  }
  const out: Meta[] = [];
  const seen = new Set<string>();
  for (let i = 0; i < Math.max(movies.length, series.length) && out.length < 24; i++) {
    for (const m of [movies[i], series[i]]) {
      if (!m || seen.has(m.id)) continue;
      seen.add(m.id);
      out.push({ id: m.id, type: m.type, name: m.name, poster: m.poster, releaseInfo: m.releaseInfo } as Meta);
    }
  }
  return out;
}
