// Replaces lib/media-server/index-store.ts (IndexedDB) with the same API over localStorage,
// one key per connection so a 5,000-item library is one Caches-tier file. identityMatches is
// upstream's own (its module only touches indexedDB inside the functions replaced here).
import type { MediaIdentity, MediaServerItem, MediaServerSyncSummary } from "../../reference/harbor/src/lib/media-server/types";
import { identityMatches } from "../../reference/harbor/src/lib/media-server/index-store";

export { identityMatches };

const ITEMS = "harbor.media-server.index.v1.";
const CONNS = "harbor.media-server.index.v1";
const MAPPINGS = "harbor.media-server.mappings.v1";
const METADATA = "harbor.media-server.meta.v1.";
const SUMMARIES = "harbor.media-server.summaries.v1";

function readJson<T>(key: string, fallback: T): T {
  try { const raw = localStorage.getItem(key); return raw ? (JSON.parse(raw) as T) : fallback; } catch { return fallback; }
}
function writeJson(key: string, value: unknown): void {
  try { localStorage.setItem(key, JSON.stringify(value)); } catch { /* quota */ }
}
function connectionIds(): string[] { return readJson<string[]>(CONNS, []); }

/**
 * (player parity pass 2) Bumped by every write to the items or the manual mappings (the only
 * writers are the functions below), so a reader can keep what it built from mediaServerItems()
 * until the index changes (homeServers.titleServers' grouping, once per Detail page).
 */
let indexVersion = 0;
export function mediaServerIndexVersion(): number { return indexVersion; }
function itemsOf(connectionId: string): MediaServerItem[] { return readJson<MediaServerItem[]>(ITEMS + connectionId, []); }

export async function putMediaServerItems(items: MediaServerItem[], deletedIds: string[] = [], connectionId?: string): Promise<void> {
  indexVersion++;
  const touched = new Set<string>(items.map((i) => i.connectionId));
  if (connectionId) touched.add(connectionId);
  for (const cid of touched) {
    const byId = new Map(itemsOf(cid).map((i) => [i.id, i]));
    for (const item of items) if (item.connectionId === cid) byId.set(item.id, item);
    if (connectionId === cid) for (const id of deletedIds) byId.delete(id);
    writeJson(ITEMS + cid, [...byId.values()]);
  }
  const ids = new Set(connectionIds());
  for (const cid of touched) ids.add(cid);
  writeJson(CONNS, [...ids]);
}

export async function mediaServerItems(connectionId?: string): Promise<MediaServerItem[]> {
  const result = connectionId ? itemsOf(connectionId) : connectionIds().flatMap(itemsOf);
  const mappings = await manualMappings();
  const byItem = new Map(mappings.map((m) => [`${m.connectionId}:${m.itemId}`, m.identity]));
  return result.map((item) => {
    const mapped = byItem.get(`${item.connectionId}:${item.id}`);
    return mapped ? { ...item, identity: { ...mapped, season: mapped.season ?? item.identity.season, episode: mapped.episode ?? item.identity.episode } } : item;
  });
}

export async function removeMediaServerItems(connectionId: string): Promise<void> {
  indexVersion++;
  try { localStorage.removeItem(ITEMS + connectionId); } catch { /* ignore */ }
  writeJson(CONNS, connectionIds().filter((id) => id !== connectionId));
}

export async function setManualMapping(connectionId: string, itemId: string, identity: MediaIdentity): Promise<void> {
  const list = (await manualMappings()).filter((m) => !(m.connectionId === connectionId && m.itemId === itemId));
  list.push({ connectionId, itemId, identity });
  writeJson(MAPPINGS, list);
  indexVersion++;
}

export async function manualMappings(): Promise<Array<{ connectionId: string; itemId: string; identity: MediaIdentity }>> {
  return readJson(MAPPINGS, []);
}

// (review 12) The per-title details (METADATA + upstream's `${title.key}:locale:${language}:${imageLangs}`,
// about 1 KB each) were never dropped: a big library read in a few languages kept thousands of them,
// each one in the bundle's localStorage map and read by the boot snapshot. The index below holds
// every stored key and when it was last read (to the hour); pruneMediaServerMetadata drops titles
// no server holds any more, then the least recently read past a cap. The details and the index are
// lazy namespaces (shims/storage.js LAZY_PREFIXES, KeyValueStore.lazyPrefixes): the boot snapshot
// leaves them out and a key is read from the host the first time it is asked for.
const META_INDEX = "harbor.media-server.meta-index.v1";
const META_TOUCH_MS = 60 * 60_000;
const META_FLUSH_MS = 5_000;
let metaIndex: Map<string, number> | null = null;
let metaIndexDirty = false;
let metaIndexTimer: ReturnType<typeof setTimeout> | null = null;

function metaIndexOf(): Map<string, number> {
  if (metaIndex) return metaIndex;
  const raw = readJson<unknown>(META_INDEX, null);
  const index = new Map<string, number>();
  if (raw && typeof raw === "object" && !Array.isArray(raw))
    for (const [k, v] of Object.entries(raw as Record<string, unknown>)) if (typeof v === "number" && Number.isFinite(v)) index.set(k, v);
  metaIndex = index;
  return index;
}

function flushMetaIndex(): void {
  if (metaIndexTimer != null) { clearTimeout(metaIndexTimer); metaIndexTimer = null; }
  if (!metaIndexDirty || !metaIndex) return;
  metaIndexDirty = false;
  writeJson(META_INDEX, Object.fromEntries(metaIndex));
}

/** One index write for a batch of landings, not one per title. */
function metaIndexChanged(): void {
  metaIndexDirty = true;
  if (metaIndexTimer == null) metaIndexTimer = setTimeout(flushMetaIndex, META_FLUSH_MS);
}

function touchMetadata(key: string, landed: boolean): void {
  const index = metaIndexOf();
  const now = Date.now();
  const at = index.get(key);
  if (!landed && at != null && now - at < META_TOUCH_MS) return;
  index.set(key, now);
  metaIndexChanged();
}

export async function putMediaServerMetadata(key: string, meta: unknown): Promise<void> {
  writeJson(METADATA + key, { meta, updatedAt: Date.now() });
  touchMetadata(key, true);
}

export async function mediaServerMetadata<T>(key: string): Promise<T | null> {
  const meta = readJson<{ meta?: T } | null>(METADATA + key, null)?.meta ?? null;
  // A hit the index does not hold yet (stored before it existed, or its write was lost) is adopted.
  if (meta != null) touchMetadata(key, false);
  return meta;
}

/**
 * (review 12) After a Library read: drops the stored details of titles no server holds any more
 * (`titleKeys`: every stored server's titles, enabled or not), then, past `cap` entries, the least
 * recently read. `keep` (the keys the read itself used) is never dropped, so a library bigger than
 * the cap keeps every title in the language on screen and loses other languages first.
 * Returns how many entries went.
 */
export function pruneMediaServerMetadata(titleKeys: Set<string>, keep: Set<string>, cap: number): number {
  const index = metaIndexOf();
  const drop: string[] = [];
  for (const key of index.keys()) {
    const at = key.lastIndexOf(":locale:");
    if (!keep.has(key) && (at < 0 || !titleKeys.has(key.slice(0, at)))) drop.push(key);
  }
  if (index.size - drop.length > cap) {
    const gone = new Set(drop);
    const oldest = [...index].filter(([k]) => !gone.has(k) && !keep.has(k)).sort((a, b) => a[1] - b[1]);
    for (let i = 0; i < oldest.length && index.size - drop.length > cap; i++) drop.push(oldest[i][0]);
  }
  for (const key of drop) {
    index.delete(key);
    try { localStorage.removeItem(METADATA + key); } catch { /* ignore */ }
  }
  if (drop.length > 0) metaIndexChanged();
  flushMetaIndex();
  return drop.length;
}

export async function putMediaServerSyncSummary(summary: MediaServerSyncSummary): Promise<void> {
  const list = (await mediaServerSyncSummaries()).filter((s) => s.connectionId !== summary.connectionId);
  list.push(summary);
  writeJson(SUMMARIES, list);
}

export async function mediaServerSyncSummaries(): Promise<MediaServerSyncSummary[]> {
  return readJson(SUMMARIES, []);
}
