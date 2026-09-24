// Home media servers (Stage 6, lib/media-server): Plex through the plex.tv PIN, Jellyfin and
// Emby through address + credentials, one index per connection in the localStorage-backed
// store, playable copies for a title, and playback sources. Progress writes follow later.
import type { Meta } from "@/lib/cinemeta";
import { mediaServerConnections, saveMediaServerConnection, removeMediaServerConnection, updateMediaServerConnection, mediaServerToken, mediaServerSyncDue } from "@/lib/media-server/connections";
import { discoverAndAuthenticate } from "@/lib/media-server/discovery";
import { synchronizeMediaServer, subscribeMediaServerSyncProgress, mediaServerAdapter } from "@/lib/media-server/sync";
import { mediaServerItems, removeMediaServerItems, mediaServerSyncSummaries } from "@/lib/media-server/index-store";
import { matchingServerItems, serverPlayableCopies, groupMediaServerTitles } from "@/lib/media-server/selectors";
import { createMediaServerPlayerSrc } from "@/lib/media-server/playback";
import { mediaServerRequest } from "@/lib/media-server/transport";
import { getSecret, setSecret } from "@/lib/secret-store";
import { activeProfileId } from "@/lib/active-profile-id";
import { scrubLibrary as scrubMusicLibrary } from "./music";
import type { MediaServerConnection, MediaServerProvider, MediaServerQuality, MediaServerProgress } from "@/lib/media-server/types";

const PLEX_ORIGIN = "https://plex.tv";
const DEVICE_KEY = "harbor.plex-auth.device.v1";

function plexClientId(): string {
  const key = `${DEVICE_KEY}.${activeProfileId()}`;
  const existing = getSecret(key);
  if (existing) return existing;
  const value = crypto.randomUUID();
  setSecret(key, value);
  return value;
}
function plexHeaders(id = plexClientId()): Record<string, string> {
  return { Accept: "application/json", "X-Plex-Product": "Harbor", "X-Plex-Version": "1", "X-Plex-Client-Identifier": id };
}
type PlexPin = { id: number; code: string; authToken?: string; expiresAt?: string };
type PlexResource = { name?: string; provides?: string; owned?: boolean; presence?: boolean; accessToken?: string; clientIdentifier?: string; connections?: Array<{ uri?: string; local?: boolean; relay?: boolean; protocol?: string; address?: string; port?: number }> };

let syncSub: (() => void) | null = null;
function ensureProgressBridge(): void {
  if (syncSub) return;
  syncSub = subscribeMediaServerSyncProgress((p) => { window.dispatchEvent(new CustomEvent("harbor:media-server-sync", { detail: p })); });
}

// ------------------------------------------------------------------------ connections
export function connections(): Array<MediaServerConnection & { lastSummary: { at: number; movies: number; shows: number; episodes: number } | null }> {
  const list = mediaServerConnections();
  return list.map((c) => ({ ...c, lastSummary: null }));
}

export async function connectionsWithSummaries() {
  const summaries = await mediaServerSyncSummaries();
  return mediaServerConnections().map((c) => {
    const s = summaries.find((x) => x.connectionId === c.id);
    return { ...c, lastSummary: s ? { at: s.at, movies: s.movies, shows: s.shows, episodes: s.episodes } : null };
  });
}

function newConnection(provider: MediaServerProvider, name: string, origin: string, userId: string): MediaServerConnection {
  return {
    id: `ms_${Date.now().toString(36)}_${Math.random().toString(36).slice(2, 6)}`, profileId: activeProfileId(), provider, name, origin, userId,
    enabled: true, readProgress: true, writeProgress: true, fanOut: true, includeContinueWatching: true, directPlay: true, transcodeFallback: true,
    preferredQuality: "original" as MediaServerQuality, priority: mediaServerConnections().length, createdAt: Date.now(), refreshInterval: "launch",
  };
}

/** Jellyfin / Emby: address + username/password (upstream candidateServerOrigins tries http/https + default port). */
export async function connect(provider: "jellyfin" | "emby", address: string, username: string, password: string): Promise<MediaServerConnection> {
  const { origin, auth } = await discoverAndAuthenticate(provider, address, { username, password });
  const connection = newConnection(provider, `${provider === "emby" ? "Emby" : "Jellyfin"} · ${auth.userName || username}`, origin, auth.userId);
  saveMediaServerConnection(connection, auth.token);
  return connection;
}

// ------------------------------------------------------------------------------- Plex
const pins = new Map<number, { code: string; clientId: string; expiresAt: number }>();

/** signInWithPlex, split: mint the PIN and show it (the TV cannot open a browser). */
export async function plexPinStart(): Promise<{ pinId: number; code: string; url: string; expiresAt: number }> {
  const id = plexClientId();
  const created = await mediaServerRequest<PlexPin>(PLEX_ORIGIN, "/api/v2/pins?strong=true", { method: "POST", headers: plexHeaders(id) });
  const pin = created.body;
  const expiresAt = pin.expiresAt ? Date.parse(pin.expiresAt) : Date.now() + 5 * 60_000;
  pins.set(pin.id, { code: pin.code, clientId: id, expiresAt });
  const params = new URLSearchParams({ clientID: id, code: pin.code, "context[device][product]": "Harbor" });
  return { pinId: pin.id, code: pin.code, url: `https://app.plex.tv/auth#?${params}`, expiresAt };
}

/** One poll; "pending" until the viewer approves on plex.tv/link, then the reachable servers. */
export async function plexPinPoll(pinId: number): Promise<{ kind: "pending" | "expired" | "authorized"; servers?: Array<{ id: string; name: string; owned: boolean; available: boolean; origin: string }> }> {
  const held = pins.get(pinId);
  if (!held) return { kind: "expired" };
  if (Date.now() > held.expiresAt) { pins.delete(pinId); return { kind: "expired" }; }
  const polled = await mediaServerRequest<PlexPin>(PLEX_ORIGIN, `/api/v2/pins/${pinId}`, { headers: plexHeaders(held.clientId) });
  const token = polled.body.authToken ?? "";
  if (!token) return { kind: "pending" };
  const resources = await mediaServerRequest<PlexResource[]>(PLEX_ORIGIN, "/api/v2/resources?includeHttps=1&includeRelay=1", { headers: { ...plexHeaders(held.clientId), "X-Plex-Token": token } });
  const servers = (resources.body ?? [])
    .filter((r) => r.provides?.split(",").includes("server") && r.accessToken)
    .flatMap((r) => {
      const conns = [...(r.connections ?? [])].sort((a, b) => Number(a.relay) - Number(b.relay) || Number(!a.local) - Number(!b.local));
      const endpoint = conns.find((e) => e.uri) ?? conns.find((e) => e.address && e.port);
      const origin = endpoint?.uri ?? (endpoint?.address ? `${endpoint.protocol ?? "http"}://${endpoint.address}:${endpoint.port}` : "");
      return origin ? [{ id: r.clientIdentifier ?? `${r.name}:${origin}`, name: r.name ?? "Plex", owned: r.owned !== false, available: r.presence !== false, origin, token: r.accessToken! }] : [];
    });
  plexServers.set(pinId, servers);
  pins.delete(pinId);
  return { kind: "authorized", servers: servers.map(({ token: _t, ...s }) => s) };
}

const plexServers = new Map<number, Array<{ id: string; name: string; owned: boolean; available: boolean; origin: string; token: string }>>();

/** Save one of the servers the PIN returned. */
export function plexAdd(pinId: number, serverId: string): MediaServerConnection {
  const server = (plexServers.get(pinId) ?? []).find((s) => s.id === serverId);
  if (!server) throw new Error("That Plex server is no longer offered; sign in again.");
  const connection = newConnection("plex", server.name, server.origin, "");
  saveMediaServerConnection(connection, server.token);
  plexServers.delete(pinId);
  return connection;
}

export function remove(id: string): void {
  removeMediaServerConnection(id);
  void removeMediaServerItems(id);
  // Liked / recent music keeps Plex art without its token; a list from an older build is rewritten.
  scrubMusicLibrary();
}

export function update(id: string, patch: Partial<Pick<MediaServerConnection, "enabled" | "readProgress" | "writeProgress" | "includeContinueWatching" | "preferredQuality" | "refreshInterval" | "enabledLibraryIds">>): void {
  updateMediaServerConnection(id, patch);
}

export async function libraries(id: string) {
  const c = mediaServerConnections().find((x) => x.id === id);
  if (!c) throw new Error("connection not found");
  return mediaServerAdapter(c).libraries(c);
}

/** Full index of one connection; progress goes out as `harbor:media-server-sync` events. */
export async function sync(id: string): Promise<{ libraries: number; itemCount: number; removedItems: number }> {
  ensureProgressBridge();
  const c = mediaServerConnections().find((x) => x.id === id);
  if (!c) throw new Error("connection not found");
  try {
    // synchronizeMediaServer already records lastSyncAt and the detailed lastSyncResult.
    const r = await synchronizeMediaServer(c);
    return { libraries: r.libraries.length, itemCount: r.itemCount, removedItems: r.removedItems };
  } catch (cause) {
    // App.tsx MediaServerSyncRunner: a failure is persisted so the row can warn about it later.
    updateMediaServerConnection(id, { lastSyncResult: { ok: false, message: cause instanceof Error ? cause.message : String(cause), at: Date.now() } }, c.profileId);
    throw cause;
  }
}

// ------------------------------------------------------------------------------ runner
// App.tsx MediaServerSyncRunner: every due connection at launch (once per launch for the
// "launch" interval), then every 15 minutes; failures are recorded on the connection.
const RUNNER_MS = 15 * 60 * 1000;
const launchSynced = new Set<string>();
let runnerTimer: ReturnType<typeof setInterval> | null = null;
let running = false;

export async function runDueSyncs(): Promise<string[]> {
  if (running) return [];
  running = true;
  const done: string[] = [];
  try {
    for (const c of mediaServerConnections().filter((e) => mediaServerSyncDue(e) && (e.refreshInterval !== "launch" || !launchSynced.has(e.id)))) {
      if (c.refreshInterval === "launch") launchSynced.add(c.id);
      await sync(c.id).then(() => done.push(c.id), () => undefined);
    }
  } finally {
    running = false;
  }
  return done;
}

export function startRunner(): void {
  if (runnerTimer) return;
  ensureProgressBridge();
  runnerTimer = setInterval(() => void runDueSyncs(), RUNNER_MS);
  void runDueSyncs();
}

// ---------------------------------------------------------------------- progress writes
/** progress-sync.ts report(): the server learns the position, or that the title was watched. */
export async function reportProgress(connectionId: string, itemId: string, positionMs: number, durationMs: number | null, watched: boolean): Promise<boolean> {
  const connection = mediaServerConnections().find((c) => c.id === connectionId);
  if (!connection || !connection.writeProgress) return false;
  const item = (await mediaServerItems(connectionId)).find((i) => i.id === itemId);
  if (!item) return false;
  const adapter = mediaServerAdapter(connection);
  if (watched) await adapter.setWatched(connection, item, true);
  else {
    const progress: MediaServerProgress = { positionMs: Math.max(0, Math.round(positionMs)), durationMs: durationMs && durationMs > 0 ? Math.round(durationMs) : undefined, played: false, updatedAt: Date.now() };
    await adapter.reportProgress(connection, item, progress);
  }
  return true;
}

/** progress-sync.ts session teardown: tells a transcoding server the session ended. */
export async function stopPlayback(connectionId: string, itemId: string, playbackSessionId: string, positionMs: number): Promise<void> {
  const connection = mediaServerConnections().find((c) => c.id === connectionId);
  if (!connection) return;
  const item = (await mediaServerItems(connectionId)).find((i) => i.id === itemId);
  const adapter = mediaServerAdapter(connection);
  if (item && adapter.stopPlayback) await adapter.stopPlayback(connection, item, playbackSessionId, Math.max(0, Math.round(positionMs)));
}

// ------------------------------------------------------------------------- library view
/** groupMediaServerTitles over every enabled connection, as Library entries. */
export async function titles(): Promise<Array<{ key: string; meta: Meta; date: number | null; groups: string[]; libraries: string[]; connections: Array<{ id: string; label: string }> }>> {
  const conns = mediaServerConnections().filter((c) => c.enabled);
  const enabled = new Set(conns.map((c) => c.id));
  const all = await mediaServerItems();
  const grouped = groupMediaServerTitles(all.filter((i) => enabled.has(i.connectionId)));
  return grouped.map((t) => ({
    key: t.key,
    meta: { id: t.identity.imdbId ?? (t.identity.tmdbId != null ? `tmdb:${t.kind === "series" ? "tv" : "movie"}:${t.identity.tmdbId}` : t.key), type: t.kind, name: t.fallbackTitle, releaseInfo: t.year ? String(t.year) : undefined } as Meta,
    date: t.addedAt ?? null,
    groups: t.connectionIds,
    libraries: t.libraryIds,
    connections: conns.map((c) => ({ id: c.id, label: c.name })),
  }));
}

// ------------------------------------------------------------------------------ copies
export type Copy = { key: string; label: string; sourceLabel: string; connectionId: string; itemId: string; versionId: string; quality: string | null; sizeBytes: number | null; resolution: string | null; progressMs: number };

/** use-bp-streams: the home-server copies of a title (or one episode). */
export async function copies(meta: Meta, imdbId: string | null, season?: number | null, episode?: number | null): Promise<Copy[]> {
  const conns = mediaServerConnections().filter((c) => c.enabled);
  if (conns.length === 0) return [];
  const match = meta.id.match(/^tmdb:(?:movie|tv):(\d+)$/);
  const identity = { tmdbId: match ? Number(match[1]) : undefined, imdbId: imdbId ?? (meta.id.startsWith("tt") ? meta.id : undefined) };
  const items = matchingServerItems(await mediaServerItems(), identity, episode != null ? "series" : "movie", season ?? undefined, episode ?? undefined);
  return serverPlayableCopies(items, conns).map((c) => ({
    key: c.key, label: c.label, sourceLabel: c.sourceLabel, connectionId: c.connectionId ?? "", itemId: c.itemId ?? "",
    versionId: c.version.id, quality: (c.version as { quality?: string }).quality ?? null,
    sizeBytes: (c.version as { sizeBytes?: number }).sizeBytes ?? null, resolution: (c.version as { resolution?: string }).resolution ?? null,
    progressMs: c.progress?.positionMs ?? 0,
  }));
}

/** A playable URL for one copy (direct play or the server's transcode), with headers and subtitles. */
export async function play(meta: Meta, connectionId: string, itemId: string, versionId?: string, startPositionMs?: number) {
  const connection = mediaServerConnections().find((c) => c.id === connectionId);
  if (!connection) throw new Error("connection not found");
  const item = (await mediaServerItems(connectionId)).find((i) => i.id === itemId);
  if (!item) throw new Error("This home-server copy is no longer indexed.");
  const src = await createMediaServerPlayerSrc({ meta, connection, item, versionId, startPositionMs });
  return {
    url: src.url, headers: src.headers ?? null, subtitle: src.subtitle ?? null,
    subtitles: (src.subtitles ?? []).map((s) => ({ url: s.url, lang: s.lang ?? null })),
    resumeMs: item.progress?.positionMs ?? 0,
    session: { connectionId, itemId: item.id, versionId: src.homeServer?.versionId ?? versionId ?? null, playbackSessionId: src.homeServer?.playbackSessionId ?? null },
  };
}

export function hasToken(id: string): boolean {
  const c = mediaServerConnections().find((x) => x.id === id);
  return !!c && !!mediaServerToken(c);
}
