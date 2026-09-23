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
function itemsOf(connectionId: string): MediaServerItem[] { return readJson<MediaServerItem[]>(ITEMS + connectionId, []); }

export async function putMediaServerItems(items: MediaServerItem[], deletedIds: string[] = [], connectionId?: string): Promise<void> {
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
  try { localStorage.removeItem(ITEMS + connectionId); } catch { /* ignore */ }
  writeJson(CONNS, connectionIds().filter((id) => id !== connectionId));
}

export async function setManualMapping(connectionId: string, itemId: string, identity: MediaIdentity): Promise<void> {
  const list = (await manualMappings()).filter((m) => !(m.connectionId === connectionId && m.itemId === itemId));
  list.push({ connectionId, itemId, identity });
  writeJson(MAPPINGS, list);
}

export async function manualMappings(): Promise<Array<{ connectionId: string; itemId: string; identity: MediaIdentity }>> {
  return readJson(MAPPINGS, []);
}

export async function putMediaServerMetadata(key: string, meta: unknown): Promise<void> {
  writeJson(METADATA + key, { meta, updatedAt: Date.now() });
}

export async function mediaServerMetadata<T>(key: string): Promise<T | null> {
  return readJson<{ meta?: T } | null>(METADATA + key, null)?.meta ?? null;
}

export async function putMediaServerSyncSummary(summary: MediaServerSyncSummary): Promise<void> {
  const list = (await mediaServerSyncSummaries()).filter((s) => s.connectionId !== summary.connectionId);
  list.push(summary);
  writeJson(SUMMARIES, list);
}

export async function mediaServerSyncSummaries(): Promise<MediaServerSyncSummary[]> {
  return readJson(SUMMARIES, []);
}
