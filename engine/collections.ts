// Collections room (Stage 2 slice): the sources that need no TMDB key first —
// community collections from harbor.site and this device's own lists. TMDB curated/open
// feeds and TVDB lists join once a TMDB key is in play.
import { fetchCommunityCollections, type CommunityCollection } from "@/lib/social/collections-sync";
import { readCollections, absCollectionImage, type Collection, type CollectionItem } from "@/lib/collections";

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
