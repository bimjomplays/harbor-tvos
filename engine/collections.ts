// Collections room (Stage 2 slice): the sources that need no TMDB key first —
// community collections from harbor.site and this device's own lists. TMDB curated/open
// feeds and TVDB lists join once a TMDB key is in play.
import { fetchCommunityCollections, type CommunityCollection } from "@/lib/social/collections-sync";
import { readCollections, absCollectionImage, type Collection, type CollectionItem } from "@/lib/collections";
import { COLLECTION_CATEGORIES } from "@/lib/collections-catalog";
import { BP_COLLECTIONS_ALL, bpCatalogFor, bpMapLimit, resolveBpCollection } from "@/views/big-picture/use-bp-collections";
import { loadEffective } from "@/lib/settings/profile-store";

export type CollectionCard = {
  key: string;
  source: "mine" | "community";
  name: string;
  image: string | null;
  count: number;
  byline: string | null;
  description: string | null;
  items: CollectionItem[];
  /** bp-collection-items: manga items are not shown in Big Picture, but the viewer is told how many. */
  hidden: number;
};

function card(c: Collection, source: CollectionCard["source"], byline: string | null): CollectionCard {
  const items = c.items.filter((i) => i.type !== "manga");
  return {
    key: `${source}:${c.id}`,
    source,
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

export async function community(): Promise<CollectionCard[]> {
  const list: CommunityCollection[] = await fetchCommunityCollections();
  return list.map((c) => card(c, "community", c.displayName || c.handle));
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
    cards.push({ key: `tmdb:${tc.id}`, source: "tmdb" as CollectionCard["source"], name: tc.name, image: tc.backdrop ?? tc.poster ?? tc.parts.find((m) => m.poster)?.poster ?? null,
      count: items.length, byline: slice[i].cats[0] ?? "TMDB", description: tc.overview || null, items, hidden: 0 });
  });
  return { cards, done: page * TMDB_PAGE >= catalog.length };
}
