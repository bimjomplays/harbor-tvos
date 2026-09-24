// bp-home "Your addons" band + the addon page (views/big-picture/addons) without React: the
// installed addons as cards (cloud-merged when signed in), each addon's browsable catalogs, and
// paged catalog feeds through upstream's fetcher.
import { createAddonCatalogFetcher, type AddonCatalogCursor } from "@/lib/addons";
import { fetchManifestAt, loadInstalled } from "@/lib/addon-store";
import type { Meta } from "@/lib/cinemeta";
import { BP_ADDON_MAX_CARDS, bpAddonBase, bpCursorFor, bpUsableCatalogs, enrich, hydrateStripped, loadCloudAddons, mergeCloud, readLocalAddonEntries, type BpAddonEntry } from "@/views/big-picture/addons/bp-addon-entries";

export type AddonCard = { key: string; id: string; name: string; base: string; logo: string | null; hasCatalogs: boolean; posters: string[] };
export type AddonCatalog = { key: string; name: string; type: string; cursor: AddonCatalogCursor };

import { BP_ADDON_MOSAIC_MIN, bpAddonPosterStore, bpAddonTopUp } from "@/views/big-picture/addons/bp-addon-posters";

const posterCache = new Map<string, string[]>();
/** The last band's entries by base, so a focused card's mosaic top-up finds its cursor. */
const entriesByBase = new Map<string, BpAddonEntry>();

async function postersFor(entry: BpAddonEntry): Promise<string[]> {
  if (!entry.cursor) return [];
  const held = posterCache.get(entry.key);
  if (held) return held;
  const page = await Promise.race([
    createAddonCatalogFetcher(entry.cursor, { initialPageSize: 12 })(1, 0).catch(() => [] as Meta[]),
    new Promise<Meta[]>((r) => setTimeout(() => r([]), 6000)),
  ]);
  const out = page.map((m) => m.poster).filter((p): p is string => !!p).slice(0, 4);
  posterCache.set(entry.key, out);
  return out;
}

/** The band: local entries first (a synchronous read), the cloud list merged in when signed in. */
export async function cards(authKey: string | null, withPosters = true): Promise<AddonCard[]> {
  let entries = readLocalAddonEntries();
  if (authKey) {
    const cloud = await loadCloudAddons(authKey).catch(() => []);
    entries = enrich(mergeCloud(entries, cloud), cloud);
  }
  entries = (await hydrateStripped(entries).catch(() => entries)).slice(0, BP_ADDON_MAX_CARDS);
  for (const e of entries) entriesByBase.set(e.base, e);
  const posters = withPosters ? await Promise.all(entries.map((e) => postersFor(e))) : entries.map(() => []);
  return entries.map((e, i) => ({ key: e.key, id: e.id, name: e.name, base: e.base, logo: e.logo ?? null, hasCatalogs: e.hasCatalogs, posters: posters[i] }));
}

function toCatalogs(base: string, defs: ReturnType<typeof bpUsableCatalogs>): AddonCatalog[] {
  const out: AddonCatalog[] = [];
  for (const def of defs) {
    const cursor = bpCursorFor(base, [def]);
    if (cursor) out.push({ key: `${def.type}:${def.id}`, name: def.name, type: def.type, cursor });
  }
  return out;
}

/** use-bp-addon-catalogs: the install list first, the manifest only when a quota strip left none. */
export async function catalogs(base: string): Promise<AddonCatalog[]> {
  try {
    const hit = loadInstalled().find((a) => bpAddonBase(a.transportUrl) === base);
    const local = hit ? toCatalogs(base, bpUsableCatalogs(hit.manifest)) : [];
    if (local.length > 0) return local;
  } catch { /* fall through */ }
  const manifest = await fetchManifestAt(`${base}/manifest.json`).catch(() => null);
  return manifest ? toCatalogs(base, bpUsableCatalogs(manifest)) : [];
}

/** use-bp-addon-feed: one page of a catalog cursor. */
export async function feed(cursor: AddonCatalogCursor, page: number, loaded: number): Promise<Meta[]> {
  return createAddonCatalogFetcher(cursor)(page, loaded).catch(() => [] as Meta[]);
}

/**
 * bp-addon-row band art: the focused addon's mosaic posters (bp-addon-posters pool, persisted in
 * harbor.bp.addon-posters.v1). Below BP_ADDON_MOSAIC_MIN (14) the pool is topped up from the
 * addon's first catalog (bpAddonTopUp: single flight per base, 60 s cooldown after an empty or
 * failed answer); the band only paints a mosaic from 14 up, so fewer come back as [].
 */
export async function bandPosters(base: string): Promise<string[]> {
  const held = bpAddonPosterStore.getSnapshot().get(base);
  if (held && held.length >= BP_ADDON_MOSAIC_MIN) return [...held];
  const entry = entriesByBase.get(base) ?? readLocalAddonEntries().find((e) => e.base === base);
  if (entry) await bpAddonTopUp(entry).catch(() => {});
  const list = bpAddonPosterStore.getSnapshot().get(base) ?? [];
  return list.length >= BP_ADDON_MOSAIC_MIN ? [...list] : [];
}
