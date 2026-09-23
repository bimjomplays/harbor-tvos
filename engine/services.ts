// Streaming services (bp-home.tsx "Your streaming" band + bp-service.tsx page): the brand tiles
// the viewer has on, their poster mosaic, and the per-service category rows, all TMDB-backed
// (use-bp-service-rows.ts pooled fetch, use-bp-service-posters.ts).
import type { Meta } from "@/lib/cinemeta";
import { SERVICES, providerIdsFor, servicePosters } from "@/lib/providers/streaming";
import { CATEGORIES, dedupe, fetchCategoryBatch, type Category } from "@/lib/providers/service-catalog";
import { CATALOG_REQUEST_TIMEOUT_MS, withTimeout } from "@/lib/progressive-rows";
import type { StreamingService } from "@/lib/settings";
import { loadEffective } from "@/lib/settings/profile-store";

const ROW_PAGES = 1;
const ROW_CONCURRENCY = 4;

export type ServiceTile = { id: StreamingService; name: string; tint: string; logo: string };

function svc(id: string): StreamingService | null {
  return id in SERVICES ? (id as StreamingService) : null;
}

/** bp-home.tsx:49-56: only with a TMDB key, only services switched on. */
export function list(profileId: string, linked: boolean): { hasKey: boolean; services: ServiceTile[] } {
  const s = loadEffective(profileId, linked);
  const hasKey = !!s.tmdbKey;
  const ids = hasKey ? (Object.keys(s.streaming) as StreamingService[]).filter((k) => s.streaming[k] && k in SERVICES) : [];
  return { hasKey, services: ids.map((id) => ({ id, name: SERVICES[id].name, tint: SERVICES[id].tint, logo: SERVICES[id].logo })) };
}

export function all(): ServiceTile[] {
  return (Object.keys(SERVICES) as StreamingService[]).map((id) => ({ id, name: SERVICES[id].name, tint: SERVICES[id].tint, logo: SERVICES[id].logo }));
}

const posterCache = new Map<string, string[]>();

/** Poster mosaic for a focused tile (cached per service/key/region; [] on failure is not cached). */
export async function posters(service: string, profileId: string, linked: boolean): Promise<string[]> {
  const id = svc(service);
  const s = loadEffective(profileId, linked);
  if (!id || !s.tmdbKey) return [];
  const slot = `${id}\u0000${s.tmdbKey}\u0000${s.region}`;
  const hit = posterCache.get(slot);
  if (hit) return hit;
  try {
    const out = await servicePosters(s.tmdbKey, id, s.region);
    posterCache.set(slot, out);
    return out;
  } catch {
    return [];
  }
}

function mix(movies: Meta[], series: Meta[]): Meta[] {
  const out: Meta[] = [];
  const reach = Math.max(movies.length, series.length);
  for (let i = 0; i < reach; i++) {
    if (movies[i]) out.push(movies[i]);
    if (series[i]) out.push(series[i]);
  }
  return dedupe(out);
}

async function pooled<T>(items: readonly T[], limit: number, run: (item: T) => Promise<void>): Promise<void> {
  let next = 0;
  const worker = async () => {
    for (;;) {
      const i = next++;
      if (i >= items.length) return;
      await run(items[i]).catch(() => {});
    }
  };
  await Promise.all(Array.from({ length: Math.min(limit, items.length) }, worker));
}

export type ServiceRow = { key: string; name: string; type: "movie" | "series"; metas: Meta[]; hasMore: boolean };

/** use-bp-service-rows: every category in parallel (4 lanes, 5 s cap each), CATEGORIES order. */
export async function rows(service: string, profileId: string, linked: boolean): Promise<{ hasKey: boolean; name: string; tint: string; rows: ServiceRow[] }> {
  const id = svc(service);
  const s = loadEffective(profileId, linked);
  if (!id) return { hasKey: !!s.tmdbKey, name: service, tint: "#ffffff", rows: [] };
  if (!s.tmdbKey) return { hasKey: false, name: SERVICES[id].name, tint: SERVICES[id].tint, rows: [] };
  const ids = providerIdsFor(SERVICES[id]);
  const out = new Map<string, ServiceRow>();
  await pooled(CATEGORIES, ROW_CONCURRENCY, async (cat: Category) => {
    const metas = await withTimeout(fetchCategoryBatch(s.tmdbKey, ids, s.region, cat, 0, ROW_PAGES).then((b) => mix(b.movies, b.series)), CATALOG_REQUEST_TIMEOUT_MS);
    if (metas.length === 0) return;
    out.set(cat.id, { key: `svc:${id}:${cat.id}`, name: cat.label, type: cat.fetchMovies ? "movie" : "series", metas, hasMore: true });
  });
  return { hasKey: true, name: SERVICES[id].name, tint: SERVICES[id].tint, rows: CATEGORIES.map((c) => out.get(c.id)).filter((r): r is ServiceRow => !!r) };
}

/** Next page of one service category row (`svc:<service>:<category>`). */
export async function page(rowKey: string, pageNo: number, profileId: string, linked: boolean): Promise<Meta[]> {
  const [, service, catId] = rowKey.split(":");
  const id = svc(service ?? "");
  const cat = CATEGORIES.find((c) => c.id === catId);
  const s = loadEffective(profileId, linked);
  if (!id || !cat || !s.tmdbKey) return [];
  const b = await fetchCategoryBatch(s.tmdbKey, providerIdsFor(SERVICES[id]), s.region, cat, pageNo - 1, ROW_PAGES);
  return mix(b.movies, b.series);
}
