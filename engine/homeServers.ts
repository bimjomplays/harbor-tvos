// Home media servers (Stage 6, lib/media-server): Plex through the plex.tv PIN, Jellyfin and
// Emby through address + credentials, one index per connection in the localStorage-backed
// store, playable copies for a title, and playback sources. Progress writes follow later.
import type { Meta } from "@/lib/cinemeta";
import { mediaServerConnections, saveMediaServerConnection, removeMediaServerConnection, updateMediaServerConnection, mediaServerToken, mediaServerSyncDue } from "@/lib/media-server/connections";
import { discoverAndAuthenticate } from "@/lib/media-server/discovery";
import { synchronizeMediaServer, subscribeMediaServerSyncProgress, mediaServerAdapter } from "@/lib/media-server/sync";
import { mediaServerItems, removeMediaServerItems, mediaServerSyncSummaries } from "@/lib/media-server/index-store";
import { matchingServerItems, serverPlayableCopies, groupMediaServerTitles } from "@/lib/media-server/selectors";
import { createMediaServerPlayerSrc, switchMediaServerQuality } from "@/lib/media-server/playback";
import { decidePlaybackSource } from "@/lib/media-server/playback-policy";
import { getMediaServerHealthSnapshot, markMediaServerInactive, probeMediaServerHealth, type MediaServerHealth } from "@/lib/media-server/health";
import { MEDIA_SERVER_QUALITIES, connectionQuality } from "@/lib/media-server/quality";
import { loadEffective } from "@/lib/settings/profile-store";
import { t } from "@/lib/i18n";
import type { PlayerSrc } from "@/lib/view";
import { mediaServerRequest } from "@/lib/media-server/transport";
import { getSecret, setSecret } from "@/lib/secret-store";
import { activeProfileId } from "@/lib/active-profile-id";
import { scrubLibrary as scrubMusicLibrary } from "./music";
import type { MediaServerConnection, MediaServerProvider, MediaServerQuality, MediaServerProgress, PlayableCopy } from "@/lib/media-server/types";

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
export async function stopPlayback(connectionId: string, itemId: string, openedSessionId: string | null, positionMs: number): Promise<void> {
  // A quality switch replaced the session the player was opened with (and already stopped that
  // one): the held session is the live one, even when it is none (back to direct play).
  const held = playing.get(sessionKey(connectionId, itemId));
  playing.delete(sessionKey(connectionId, itemId));
  const playbackSessionId = held ? held.playbackSessionId ?? null : openedSessionId;
  if (!playbackSessionId) return;
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
  if (src.homeServer) playing.set(sessionKey(connectionId, item.id), { versionId: src.homeServer.versionId, quality: src.homeServer.quality, playbackSessionId: src.homeServer.playbackSessionId ?? null });
  return {
    url: src.url, headers: src.headers ?? null, subtitle: src.subtitle ?? null,
    // media-server/playback.ts mediaServerPlayerSrc: the server's own files are trustedSource.
    subtitles: (src.subtitles ?? []).map((s) => ({ url: s.url, lang: s.lang ?? null, trustedSource: true })),
    resumeMs: item.progress?.positionMs ?? 0,
    session: { connectionId, itemId: item.id, versionId: src.homeServer?.versionId ?? versionId ?? null, playbackSessionId: src.homeServer?.playbackSessionId ?? null },
  };
}

export function hasToken(id: string): boolean {
  const c = mediaServerConnections().find((x) => x.id === id);
  return !!c && !!mediaServerToken(c);
}

// ------------------------------------------------------------------ Play button preference
/** How long the Play button waits for a server's health probe before treating it as offline. */
const HEALTH_WAIT_MS = 5000;
/** use-media-server-health.ts re-probes every 30 s; a fresher answer is reused as is. */
const HEALTH_FRESH_MS = 30_000;
const probedAt = new Map<string, number>();

/** lib/media-server/health.ts over the connections these copies live on: id → checking / active / inactive. */
async function copyServerHealth(ids: string[]): Promise<Record<string, MediaServerHealth>> {
  const conns = mediaServerConnections().filter((c) => ids.includes(c.id));
  const snapshot = getMediaServerHealthSnapshot();
  const now = Date.now();
  const out: Record<string, MediaServerHealth> = { ...snapshot };
  await Promise.all(conns.map(async (c) => {
    const known = snapshot[c.id];
    if (known && known !== "checking" && now - (probedAt.get(c.id) ?? 0) < HEALTH_FRESH_MS) { out[c.id] = known; return; }
    probedAt.set(c.id, now);
    // The race's own outcome: a server that was active earlier and now doesn't answer within the
    // wait counts as offline (the snapshot would still say active) (review 35).
    const answered = await Promise.race([
      probeMediaServerHealth(c).then(() => true, () => true),
      new Promise<false>((r) => setTimeout(() => r(false), HEALTH_WAIT_MS)),
    ]);
    out[c.id] = answered ? (getMediaServerHealthSnapshot()[c.id] ?? "inactive") : "inactive";
  }));
  return out;
}

/** Test hook: health.ts markMediaServerInactive (the settings panel's "server went away"). */
export function markInactive(connectionId: string): void {
  markMediaServerInactive(connectionId);
}

/**
 * bp-streams.tsx's applyPreference effect for the Play button, once the home-server copies are
 * in: what the source list does about settings.playbackSourcePreference. The TV has no Local
 * Library, so localFiles is always empty here.
 *   show-all          switch the list to every source (a "local" preference with no local files)
 *   show-media-server switch the list to the home-server copies (no preferred server: ask)
 *   play              start this copy now (decidePlaybackSource picked one)
 *   none              leave the list as it is
 * One TV deviation: a home-server preference with no copy of this title shows every source,
 * where upstream leaves an empty "Media servers" list up.
 * bp-streams.tsx waits for homeServerHealthReady and decides over availableHomeServerCopies (only
 * copies whose server answered, lib/media-server/health.ts): a server known offline, or one that
 * doesn't answer within HEALTH_WAIT_MS, never auto-plays (review 29).
 */
export async function preferredSource(profileId: string, linked: boolean, copies: Array<{ key: string; connectionId: string }>): Promise<{ action: "none" | "show-all" | "show-media-server" | "play"; copyKey?: string }> {
  const s = loadEffective(profileId, linked);
  const preference = s.playbackSourcePreference;
  const localCount = 0;
  if (preference === "local" && localCount === 0) return { action: "show-all" };
  if (preference === "home-server" && copies.length === 0) return { action: "show-all" };
  if (preference === "home-server" && s.preferredMediaServerId == null) return { action: "show-media-server" };
  // Only the preferred server's copies can auto-play (decidePlaybackSource), so only it is probed.
  const preferred = s.preferredMediaServerId;
  const health = preference === "home-server" && preferred && copies.some((c) => c.connectionId === preferred) ? await copyServerHealth([preferred]) : {};
  // A copy on a connection this device doesn't know (never probed) is left to the chooser's own check.
  const available = copies.filter((c) => health[c.connectionId] === undefined || health[c.connectionId] === "active");
  const decision = decidePlaybackSource(s, localCount, available as unknown as PlayableCopy[]);
  if (decision.kind === "home-server") return { action: "play", copyKey: decision.copy.key };
  return { action: "none" };
}

// ------------------------------------------------------------------ in-player quality switch
type Playing = { versionId: string; quality: MediaServerQuality; playbackSessionId: string | null };
/** The session each home-server playback is on now (PlayerSrc.homeServer), by connection + item. */
const playing = new Map<string, Playing>();
const sessionKey = (connectionId: string, itemId: string) => `${connectionId}\n${itemId}`;

/** bp-ten-foot.tsx HomeServerQualityPanel: MEDIA_SERVER_QUALITIES and the one playing now. */
export function qualityOptions(connectionId: string, itemId: string): { current: MediaServerQuality; options: Array<{ id: MediaServerQuality; label: string }> } {
  const connection = mediaServerConnections().find((c) => c.id === connectionId);
  const current = playing.get(sessionKey(connectionId, itemId))?.quality ?? (connection ? connectionQuality(connection) : "original");
  return { current, options: MEDIA_SERVER_QUALITIES.map((q) => ({ id: q.id, label: t(q.label) })) };
}

/**
 * lib/media-server/playback.ts switchMediaServerQuality for the TV player: the same item at
 * another quality from `positionMs`, the connection's preferredQuality updated and the old
 * transcode session stopped. The player swaps to the returned URL in place.
 */
export async function switchQuality(connectionId: string, itemId: string, versionId: string | null, quality: MediaServerQuality, positionMs: number, isPlaying: boolean, playbackSessionId: string | null) {
  const key = sessionKey(connectionId, itemId);
  const held = playing.get(key);
  const src = {
    meta: { id: "", type: "movie", name: "" }, url: "", title: "",
    homeServer: {
      connectionId, itemId, versionId: held?.versionId ?? versionId ?? "", quality: held?.quality ?? "original",
      playbackSessionId: held?.playbackSessionId ?? playbackSessionId ?? undefined,
    },
  } as unknown as PlayerSrc;
  const next = await switchMediaServerQuality({ src, quality, positionMs: Math.max(0, Math.round(positionMs)), playing: isPlaying });
  const hs = next.homeServer!;
  playing.set(key, { versionId: hs.versionId, quality: hs.quality, playbackSessionId: hs.playbackSessionId ?? null });
  return {
    url: next.url, headers: next.headers ?? null, quality: hs.quality, subtitle: next.subtitle ?? null,
    subtitles: (next.subtitles ?? []).map((sub) => ({ url: sub.url, lang: sub.lang ?? null, trustedSource: true })),
  };
}
