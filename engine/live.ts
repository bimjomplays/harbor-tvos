// Live TV on upstream's IPTV stack: sources (M3U, Xtream, middleware probing), the 6-hour
// playlist cache, favorites/pins/stats ordering (bp-guide-order), and an XMLTV guide with
// upstream's channel↔EPG resolver. Swift gets flat channel lists plus now/next per channel.
import { readPlaylists, writePlaylists, type StoredPlaylist } from "@/lib/iptv/playlists-store";
import { detectProviderShape } from "@/lib/iptv/ingest/detect";
import { loadPlaylist, clearPlaylistCache } from "@/lib/iptv/store";
import { deriveEpgUrls } from "@/lib/iptv/m3u";
import { parseXmltv, indexProgramsByChannel, findCurrent } from "@/lib/iptv/xmltv";
import { computeTvgIdCounts, epgProgramsForChannel } from "@/lib/iptv/epg-resolver";
import { epgOffsetHoursPref } from "@/lib/iptv/settings-bridge";
import { recordChannelPlay, removeStatsForSource } from "@/lib/iptv/channel-stats";
import { removePinsForSource } from "@/lib/iptv/pins";
import { removeEpgOverridesForSource } from "@/lib/iptv/epg-map";
import { headersFromChannel } from "@/lib/iptv/channel-headers";
import { bpGuideOrder } from "@/views/big-picture/bp-guide-order";
import type { EpgIndex, EpgProgram, IptvChannel } from "@/lib/iptv/types";
import { loadStoredSettings } from "@/lib/settings/load";
import { gunzipSync } from "fflate";

export type LiveChannel = {
  id: string;
  name: string;
  logo: string | null;
  url: string;
  group: string | null;
  tvgId: string | null;
  /** Referer / User-Agent the playlist asked for (channel-headers.ts). */
  headers: Record<string, string> | null;
  favorite: boolean;
};

export type LiveGroup = { name: string; count: number };

export type LivePlaylistView = {
  id: string;
  name: string;
  kind: "m3u" | "xtream" | "epg";
  /** Channels in guide order for the "All" category (favorites, pins, most watched, region networks, rest). */
  channels: LiveChannel[];
  groups: LiveGroup[];
  total: number;
  epgUrl: string | null;
};

export type NowNext = {
  id: string;
  now: ProgramView | null;
  next: ProgramView | null;
  /** False when the guide holds nothing for this channel (no match), so the row can say "Live". */
  known: boolean;
};

export type ProgramView = { title: string; description: string | null; startMs: number; endMs: number; category: string | null };

// ------------------------------------------------------------------------------ sources

export function playlists(): StoredPlaylist[] {
  return readPlaylists();
}

/**
 * Add any source upstream accepts: an M3U/M3U8 URL, a middleware host (probed for
 * /iptv/m3u etc.), or an Xtream `get.php` / `player_api.php` login URL. The EPG URL is taken
 * from the argument, else derived for Xtream logins.
 */
export function addPlaylist(name: string, url: string, epgUrl?: string | null): StoredPlaylist {
  const trimmed = url.trim();
  const id = `pl_${Date.now().toString(36)}_${Math.random().toString(36).slice(2, 6)}`;
  const probe = detectProviderShape({ id, name: name.trim() || trimmed, url: trimmed });
  if (probe.kind === "invalid") throw new Error(probe.reason);
  const entry: StoredPlaylist = { id, name: name.trim() || trimmed, url: trimmed, kind: probe.kind === "xtream" ? "xtream" : probe.kind === "epg" ? "epg" : "m3u" };
  if (probe.kind === "xtream") entry.xtream = { server: probe.creds.base, username: probe.creds.username, password: probe.creds.password };
  const epg = (epgUrl ?? "").trim() || (probe.kind === "xtream" ? deriveEpgUrls(trimmed)[0] ?? null : null);
  if (epg) entry.epgUrl = epg;
  writePlaylists([...readPlaylists().filter((p) => p.url !== trimmed), entry]);
  return entry;
}

export function setEpgUrl(id: string, epgUrl: string | null): void {
  writePlaylists(readPlaylists().map((p) => (p.id === id ? { ...p, epgUrl: (epgUrl ?? "").trim() || undefined } : p)));
  epgCache.delete(id);
}

export function removePlaylist(id: string): void {
  writePlaylists(readPlaylists().filter((p) => p.id !== id));
  clearPlaylistCache(id);
  epgCache.delete(id);
  loaded.delete(id);
  removeFavoritesForSource(id);
  removePinsForSource(id);
  removeStatsForSource(id);
  removeEpgOverridesForSource(id);
}

// ---------------------------------------------------------------------------- favorites
// lib/iptv/favorites.tsx storage, without the React provider.
const FAV_KEY = "harbor.iptv.favorites.v2";
type StoredFavorite = { id: string; name: string; logo: string | null; group: string | null; url: string; tvgId: string | null; sourceId: string };

function readFavorites(): Map<string, StoredFavorite> {
  const map = new Map<string, StoredFavorite>();
  try {
    const parsed = JSON.parse(localStorage.getItem(FAV_KEY) ?? "[]");
    if (Array.isArray(parsed)) for (const e of parsed) if (e && typeof e.id === "string") map.set(e.id, e as StoredFavorite);
  } catch { /* ignore */ }
  return map;
}

function writeFavorites(map: Map<string, StoredFavorite>): void {
  localStorage.setItem(FAV_KEY, JSON.stringify(Array.from(map.values())));
}

export function favorites(): StoredFavorite[] {
  return Array.from(readFavorites().values());
}

export function toggleFavorite(channel: { id: string; name: string; logo?: string | null; group?: string | null; url: string; tvgId?: string | null }): boolean {
  const map = readFavorites();
  if (map.has(channel.id)) {
    map.delete(channel.id);
    writeFavorites(map);
    return false;
  }
  map.set(channel.id, { id: channel.id, name: channel.name, logo: channel.logo ?? null, group: channel.group ?? null, url: channel.url, tvgId: channel.tvgId ?? null, sourceId: channel.id.split("::")[0] ?? "" });
  writeFavorites(map);
  return true;
}

function removeFavoritesForSource(sourceId: string): void {
  const map = readFavorites();
  let changed = false;
  for (const [id, f] of map) {
    if (f.sourceId === sourceId || id.startsWith(`${sourceId}::`)) { map.delete(id); changed = true; }
  }
  if (changed) writeFavorites(map);
}

function readPins(): string[] {
  try {
    const parsed = JSON.parse(localStorage.getItem("harbor.iptv.pins.v1") ?? "[]");
    return Array.isArray(parsed) ? parsed.filter((x): x is string => typeof x === "string") : [];
  } catch {
    return [];
  }
}

// ----------------------------------------------------------------------------- channels

const MAX_CHANNELS = 6000;
const loaded = new Map<string, IptvChannel[]>();

function toView(ch: IptvChannel, favs: Map<string, StoredFavorite>): LiveChannel {
  return { id: ch.id, name: ch.name, logo: ch.logo, url: ch.url, group: ch.group, tvgId: ch.tvgId, headers: headersFromChannel(ch) ?? null, favorite: favs.has(ch.id) };
}

/** Loads (or serves from upstream's cache) one playlist, ordered like the Big Picture guide. */
export async function channels(playlistId: string, force = false): Promise<LivePlaylistView> {
  const pl = readPlaylists().find((p) => p.id === playlistId);
  if (!pl) throw new Error("playlist not found");
  const playlist = await loadPlaylist(pl, { force });
  const all = playlist.channels.slice(0, MAX_CHANNELS);
  loaded.set(playlistId, all);
  const favs = readFavorites();
  const region = String(loadStoredSettings().region ?? "US");
  const ordered = bpGuideOrder({ channels: all, favoriteIds: new Set(favs.keys()), pinnedOrder: readPins(), hiddenGroups: [], region, promoteNetworks: true });
  const counts = new Map<string, number>();
  for (const ch of all) {
    const g = ch.group ?? "Uncategorized";
    counts.set(g, (counts.get(g) ?? 0) + 1);
  }
  return {
    id: pl.id,
    name: pl.name,
    kind: pl.kind ?? "m3u",
    channels: ordered.map((ch) => toView(ch, favs)),
    groups: Array.from(counts, ([name, count]) => ({ name, count })),
    total: playlist.channels.length,
    epgUrl: pl.epgUrl ?? null,
  };
}

/** Tell the stats store a channel was tuned (feeds the "most watched" band). */
export function recordPlay(playlistId: string, channelId: string): void {
  const ch = loaded.get(playlistId)?.find((c) => c.id === channelId);
  if (ch) recordChannelPlay(ch);
}

// ---------------------------------------------------------------------------------- EPG

const EPG_TTL_MS = 60 * 60 * 1000;
const epgCache = new Map<string, { index: EpgIndex; url: string; loading: Promise<EpgIndex> | null }>();

async function fetchXmltv(url: string): Promise<EpgIndex> {
  const res = await fetch(url, { headers: { "User-Agent": "VLC/3.0.20 LibVLC/3.0.20", Accept: "application/xml, text/xml, application/octet-stream, */*" } });
  if (!res.ok) throw new Error(`EPG fetch failed: ${res.status}`);
  let bytes = new Uint8Array(await res.arrayBuffer());
  if (bytes.length > 1 && bytes[0] === 0x1f && bytes[1] === 0x8b) bytes = gunzipSync(bytes);
  const text = new TextDecoder().decode(bytes);
  const parsed = parseXmltv(text);
  return { byChannel: indexProgramsByChannel(parsed.programs), channelMeta: parsed.channelMeta, fetchedAt: Date.now() };
}

/** Loads the playlist's guide (once an hour); returns how many channels it covers. */
export async function loadEpg(playlistId: string, force = false): Promise<{ channels: number; programs: number; url: string | null }> {
  const pl = readPlaylists().find((p) => p.id === playlistId);
  if (!pl) throw new Error("playlist not found");
  const url = pl.epgUrl ?? (pl.kind === "xtream" || /get\.php|player_api\.php/.test(pl.url) ? deriveEpgUrls(pl.url)[0] ?? null : null);
  if (!url) return { channels: 0, programs: 0, url: null };
  const held = epgCache.get(playlistId);
  if (held && held.url === url && !force && Date.now() - held.index.fetchedAt < EPG_TTL_MS) return summarize(held.index, url);
  if (held?.loading) return summarize(await held.loading, url);
  const loading = fetchXmltv(url);
  epgCache.set(playlistId, { index: held?.index ?? { byChannel: new Map(), fetchedAt: 0 }, url, loading });
  try {
    const index = await loading;
    epgCache.set(playlistId, { index, url, loading: null });
    return summarize(index, url);
  } catch (e) {
    epgCache.set(playlistId, { index: held?.index ?? { byChannel: new Map(), fetchedAt: 0 }, url, loading: null });
    throw e;
  }
}

function summarize(index: EpgIndex, url: string) {
  let programs = 0;
  for (const list of index.byChannel.values()) programs += list.length;
  return { channels: index.byChannel.size, programs, url };
}

function view(p: EpgProgram): ProgramView {
  return { title: p.title, description: p.description, startMs: p.startMs, endMs: p.endMs, category: p.category };
}

/** Now/next for a screenful of channels (epg-resolver matching, tvg-shift + offset applied). */
export function nowNext(playlistId: string, channelIds: string[], nowMs = Date.now()): NowNext[] {
  const all = loaded.get(playlistId) ?? [];
  const epg = epgCache.get(playlistId)?.index ?? null;
  const byId = new Map(all.map((c) => [c.id, c]));
  const counts = computeTvgIdCounts(all);
  const offset = epgOffsetHoursPref();
  return channelIds.map((id) => {
    const ch = byId.get(id);
    const programs = ch && epg && epg.byChannel.size > 0 ? epgProgramsForChannel(ch, epg, counts, offset) : undefined;
    if (!programs || programs.length === 0) return { id, now: null, next: null, known: false };
    const { current, next } = findCurrent(programs, nowMs);
    return { id, now: current ? view(current) : null, next: next ? view(next) : null, known: true };
  });
}

export type LaneCell = { startMs: number; endMs: number; program: ProgramView | null };

const SLOT_MS = 30 * 60_000;
const MIN_GAP_MS = 1000;

// use-bp-guide-data.ts buildLane/closeGap (not exported upstream): a lane is contiguous and
// gapless across the window, empty stretches sliced on half-hour boundaries.
function closeGap(out: LaneCell[], from: number, to: number): void {
  if (to <= from) return;
  if (to - from < MIN_GAP_MS && out.length > 0) { out[out.length - 1].endMs = to; return; }
  let cur = from;
  while (cur < to) {
    const next = Math.min(to, Math.floor(cur / SLOT_MS) * SLOT_MS + SLOT_MS);
    out.push({ startMs: cur, endMs: next, program: null });
    cur = next;
  }
}

function buildLane(programs: readonly EpgProgram[], windowStart: number, windowEnd: number): LaneCell[] {
  const inWindow = programs.filter((p) => p.endMs > windowStart && p.startMs < windowEnd).sort((a, b) => a.startMs - b.startMs);
  const out: LaneCell[] = [];
  let cursor = windowStart;
  for (const program of inWindow) {
    const endMs = Math.min(program.endMs, windowEnd);
    if (endMs <= cursor) continue;
    const startMs = Math.max(program.startMs, cursor);
    closeGap(out, cursor, startMs);
    out.push({ startMs, endMs, program: view(program) });
    cursor = endMs;
  }
  closeGap(out, cursor, windowEnd);
  return out;
}

/** Guide lanes for a screenful of channels: gapless cells over [windowStart, windowEnd). */
export function lanes(playlistId: string, channelIds: string[], windowStart: number, windowEnd: number): Array<{ id: string; cells: LaneCell[] }> {
  const all = loaded.get(playlistId) ?? [];
  const epg = epgCache.get(playlistId)?.index ?? null;
  const byId = new Map(all.map((c) => [c.id, c]));
  const counts = computeTvgIdCounts(all);
  const offset = epgOffsetHoursPref();
  return channelIds.map((id) => {
    const ch = byId.get(id);
    const programs = ch && epg && epg.byChannel.size > 0 ? epgProgramsForChannel(ch, epg, counts, offset) ?? [] : [];
    return { id, cells: buildLane(programs, windowStart, windowEnd) };
  });
}

/** One channel's programmes inside a window (the guide lane / "what's on later"). */
export function schedule(playlistId: string, channelId: string, fromMs: number, toMs: number): ProgramView[] {
  const all = loaded.get(playlistId) ?? [];
  const epg = epgCache.get(playlistId)?.index ?? null;
  const ch = all.find((c) => c.id === channelId);
  if (!ch || !epg) return [];
  const programs = epgProgramsForChannel(ch, epg, computeTvgIdCounts(all), epgOffsetHoursPref()) ?? [];
  return programs.filter((p) => p.endMs > fromMs && p.startMs < toMs).map(view);
}
