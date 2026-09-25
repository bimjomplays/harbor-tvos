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
import { BP_COLLECTIONS_ALL, bpCatalogFor, bpMapLimit, bpStripCollectionSuffix, resolveBpCollection } from "@/views/big-picture/use-bp-collections";
import { tmdbCollection, type TmdbCollection } from "@/lib/providers/tmdb/tmdb-collection";
import { loadEffective } from "@/lib/settings/profile-store";
import { currentAuthor } from "@/lib/theme-auth";
import { t } from "@/lib/i18n";

export type CollectionCard = {
  key: string;
  source: "mine" | "community" | "tmdb" | "tvdb";
  /** The collection's own id (a uuid for mine/community, the TMDB/TVDB id otherwise). */
  ref: string;
  /** community: the owner's handle, for "Save to my collections". */
  handle?: string;
  /** community: already saved into this device's collections. */
  saved?: boolean;
  /** community: the signed-in member's own collection (community-hub SaveButton isOwn: no Save). */
  own?: boolean;
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

/** community-share-button useCurrentHandle, compared as community-hub's SaveButton does. */
function isOwnHandle(handle: string): boolean {
  const me = currentAuthor()?.handle;
  return !!me && me.toLowerCase() === handle.toLowerCase();
}

export async function community(): Promise<CollectionCard[]> {
  const list: CommunityCollection[] = await fetchCommunityCollections();
  lastCommunity = list;
  const own = readCollections();
  return list.map((c) => ({ ...card(c, "community", c.displayName || c.handle), handle: c.handle, saved: isSaved(c, own), own: isOwnHandle(c.handle) }));
}

/**
 * `communityFailed`: bp-collection-steps stepCommunity sets ctx.communityFailed when
 * fetchCommunityCollections throws (offline, harbor.site down), and bp-collections endMessage
 * then says "Community collections are unavailable right now." (or, in All, "That's everything
 * we could reach…") instead of "Nobody has shared a collection yet."
 */
export async function all(): Promise<{ mine: CollectionCard[]; community: CollectionCard[]; communityFailed: boolean }> {
  const m = mine();
  let communityFailed = false;
  const c = await community().catch(() => {
    communityFailed = true;
    return [] as CollectionCard[];
  });
  return { mine: m, community: c, communityFailed };
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

// ------------------------------------------------------------- Home "Collections" row
// bp-collections-row.tsx over use-bp-collection-feed.ts useBpCuratedRow: the first `limit` (30)
// franchises of the curated catalog, resolved HYDRATE_LANES (4) wide and kept in catalog order;
// one that neither loads by id nor heals by name is dropped (tmdbEntry: stripped name, the
// backdrop only, "{count} films"). bp-home mounts the row only with a TMDB key and when the
// synced layout does not hide "collections" (use-bp-row-layout useBpPinnedRows). Upstream fills
// it lazily as it scrolls into view; a TV build waits at most CURATED_BUDGET_MS and returns what
// resolved (the resolver memoizes hits, so the next Home build is instant).
const CURATED_BUDGET_MS = 8000;

function tmdbHomeCard(tc: TmdbCollection, name: string, image: string | null): CollectionCard {
  const items: CollectionItem[] = tc.parts.map((m) => ({ id: m.id, type: m.type, name: m.name, poster: m.poster } as CollectionItem));
  return { key: `tmdb:${tc.id}`, source: "tmdb", ref: String(tc.id), name, image, count: tc.parts.length, byline: null,
    description: tc.overview || null, items, hidden: 0 };
}

/**
 * The TMDB key the curated row reads with, or null when it shows nothing. bp-discover's
 * BpCollectionsBand (`home` false) gates on the key alone (showCollections = Boolean(tmdbKey));
 * the Home row also honours the synced Home layout hiding "collections" (useBpPinnedRows).
 */
export function curatedGate(s: { tmdbKey?: unknown; homeRows?: unknown }, home: boolean): string | null {
  const key = typeof s.tmdbKey === "string" ? s.tmdbKey : "";
  if (!key) return null;
  if (!home) return key;
  // useBpPinnedRows: a malformed synced `hidden` degrades to "show every band".
  const rows = s.homeRows as { hidden?: unknown } | null | undefined;
  const raw = rows && typeof rows === "object" ? rows.hidden : undefined;
  if (Array.isArray(raw) && raw.includes("collections")) return null;
  return key;
}

/** `home` false: Discover's Collections band (bp-collections-band.tsx), which the Home layout does not hide. */
export async function curatedRow(profileId: string, linked: boolean, limit = 30, home = true): Promise<CollectionCard[]> {
  const s = loadEffective(profileId, linked);
  const key = curatedGate(s as { tmdbKey?: unknown; homeRows?: unknown }, home !== false);
  if (!key) return [];
  const slice = COLLECTIONS_CATALOG.slice(0, limit);
  const found = new Array<CollectionCard | null>(slice.length).fill(null);
  const work = bpMapLimit(slice.map((c, i) => ({ c, i })), 4, async ({ c, i }) => {
    const hit = await resolveBpCollection(key, c.id, c.name).catch(() => null);
    if (hit) found[i] = tmdbHomeCard(hit, bpStripCollectionSuffix(hit.name || c.name), hit.backdrop ?? null);
  }).catch(() => {});
  await Promise.race([work, new Promise((r) => setTimeout(r, CURATED_BUDGET_MS))]);
  return found.filter((e): e is CollectionCard => e !== null);
}

/** bp-collection-detail for a Home collection card: the TMDB collection by id (memoized upstream). */
export async function tmdbCard(profileId: string, linked: boolean, id: number | string, name: string): Promise<CollectionCard | null> {
  const key = loadEffective(profileId, linked).tmdbKey;
  const n = Number(id);
  if (!key || !Number.isFinite(n) || n <= 0) return null;
  const tc = await tmdbCollection(key, n).catch(() => null);
  if (!tc) return null;
  return tmdbHomeCard(tc, bpStripCollectionSuffix(tc.name || name), tc.backdrop ?? tc.poster ?? null);
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
  // community-hub create: t("Untitled collection"), in the viewer's language (social pass).
  const id = createCollection(name.trim() || t("Untitled collection"));
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
  // (social pass) community-hub SaveButton renders nothing for the member's own collection; the TV
  // offered Save on it and copied the viewer's own shared collection into their collections.
  if (!c || isOwnHandle(c.handle)) return null;
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
