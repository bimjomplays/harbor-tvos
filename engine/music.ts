// Music room glue (Stage 12): what views/music.tsx and lib/music/{player,sources,catalog}.ts do
// on top of the Tauri commands, rebuilt over engine/musicSources.ts. Swift owns the AVPlayer and
// the queue; the engine owns sources, rows, matching, the liked/recent library and the copy.
import { t } from "@/lib/i18n";
import type { MusicCatalogItem, MusicCatalogRow, MusicSearchResults, MusicTrack } from "@/lib/music/types";
import { classifyHomeRow } from "@/views/music/music-home-rows";
import {
  acceptMusicSources,
  getMusicSourceConsent,
  setMusicSourceEnabled,
  withdrawMusicSourceConsent,
} from "@/lib/music/source-consent";
import { favoriteArtists } from "@/lib/music/sources";
import { isMusicLiked, likedIdsFor } from "@/lib/music/liked";
import { loadTrackLyrics } from "@/lib/music/lyrics";
import { getLyricOffset, setLyricOffset as storeLyricOffset } from "@/lib/music/lyric-offset";
import * as src from "./musicSources";
import * as radioLib from "./musicRadio";
import * as scrobbling from "./musicScrobble";
import * as spotify from "./musicSpotify";

// ------------------------------------------------------------------------------ copy
const COPY_KEYS = [
  "music.title", "music.loading", "music.error.load", "music.error.search", "music.error.playback", "music.searchPlaceholder", "music.searchEmpty",
  "music.searchResults", "music.search.top", "music.search.tracks", "music.search.albums", "music.search.artists", "music.search.playlists",
  "music.search.scopeAll", "music.search.clear", "music.search.resume", "music.row.tryAgain", "music.row.resolving", "music.row.emptyRow", "music.row.stationBadge",
  "music.nowPlaying", "music.play", "music.pause", "music.resume", "music.previous", "music.next", "music.saveTrack", "music.unsaveTrack", "music.saved", "music.save",
  "music.listenNext", "music.player.close", "music.queue.nowPlaying", "music.queue.empty", "music.queue.playNext", "music.queue.previous", "music.row.upNext",
  "music.card.addToQueue", "music.card.goToArtist", "music.card.goToAlbum", "music.source.none", "music.source.loading", "music.library.saveEmpty",
  "music.connections.title", "music.connections.subtitle", "music.connections.streaming", "music.connections.server", "music.connections.catalog",
  "music.connections.statusConnected", "music.connections.statusDisconnected", "music.connections.statusError", "music.connections.statusUnavailable",
  "music.connect.serverBody", "music.consent.title", "music.consent.hosting", "music.consent.terms", "music.consent.responsibility", "music.consent.rights",
  "music.consent.enable", "music.consent.accept", "music.home.title", "music.home.body", "music.offline.title", "music.offline.retry",
  "music.searchLabel", "music.position", "music.trackCount", "music.connect.action",
  // second batch: Navidrome sign-in, Last.fm, radio, lyrics (music.ts / music-now-playing.ts)
  "music.connect.title", "music.connect.connecting", "music.connect.disconnect", "music.connect.connected", "music.connect.failed",
  "music.connections.scrobbler", "music.connections.capability.scrobble",
  "music.lastfm.connected", "music.lastfm.saved", "music.lastfm.history", "music.lastfm.live", "music.lastfm.connect", "music.lastfm.disconnect",
  "music.lastfm.apiKey", "music.lastfm.secret", "music.lastfm.finish", "music.lastfm.authorize", "music.lastfm.browserPrompt",
  "music.card.startRadio", "music.radio.error", "music.now.next",
  "Lyrics", "Lyric sync", "Lyrics earlier", "Lyrics later", "Finding lyrics", "No lyrics for this track",
  // Spotify (music.ts spotify + spotifySetup, spotify-setup.tsx, recovery.ts)
  "music.spotify.connect", "music.spotify.connectDetail", "music.spotify.connectAction", "music.spotify.connectedAs", "music.spotify.premium",
  "music.spotifySetup.createTitle", "music.spotifySetup.createBody", "music.spotifySetup.dashboard", "music.spotifySetup.redirectTitle",
  "music.spotifySetup.redirectBody", "music.spotifySetup.redirectLabel", "music.spotifySetup.clientTitle", "music.spotifySetup.clientPlaceholder",
  "music.spotifySetup.accountHint", "music.spotifySetup.authorize", "music.spotifySetup.saved", "music.spotifySetup.savedHint",
  "music.spotifySetup.missingSaved", "music.spotifySetup.rejected", "music.recovery.premium", "music.recovery.setup", "music.recovery.spotifySetup",
  "music.source.spotifyQuality",
] as const;

/** Every string the Swift room shows, in the profile's UI language (lib/i18n). */
export function copy(): Record<string, string> {
  const out: Record<string, string> = {};
  for (const key of COPY_KEYS) out[key] = t(key);
  return out;
}

// --------------------------------------------------------------------------- library
// Upstream keeps liked tracks and recents in the Rust music database (library.rs,
// music_add_recent / music_set_liked); the TV keeps the same lists in engine storage.
const LIKED_KEY = "harbor.music.liked.v1";
const RECENTS_KEY = "harbor.music.recents.v1";
const RECENTS_LIMIT = 50;

function readList(key: string): MusicTrack[] {
  try {
    const raw = JSON.parse(localStorage.getItem(key) ?? "[]") as unknown;
    return Array.isArray(raw) ? (raw.filter((x) => x && typeof x === "object" && typeof (x as MusicTrack).id === "string") as MusicTrack[]) : [];
  } catch {
    return [];
  }
}
function writeList(key: string, list: MusicTrack[]): void {
  try {
    localStorage.setItem(key, JSON.stringify(list));
  } catch {
    /* a full store must not stop playback */
  }
}
export type MusicLibrary = { liked: MusicTrack[]; likedIds: string[]; recents: MusicTrack[] };
export function library(): MusicLibrary {
  const liked = readList(LIKED_KEY);
  return { liked, likedIds: liked.map((x) => x.id), recents: readList(RECENTS_KEY) };
}
export function addRecent(track: MusicTrack): MusicLibrary {
  writeList(RECENTS_KEY, [track, ...readList(RECENTS_KEY).filter((x) => x.id !== track.id)].slice(0, RECENTS_LIMIT));
  return library();
}
/** liked.ts isMusicLiked: a track substituted from a catalog entry also answers to that entry. */
export function isLiked(track: MusicTrack): boolean {
  return isMusicLiked(readList(LIKED_KEY).map((x) => x.id), track);
}
/** player.ts toggleMusicLiked */
export function setLiked(track: MusicTrack, liked: boolean): MusicLibrary {
  const drop = new Set(likedIdsFor(track));
  const rest = readList(LIKED_KEY).filter((x) => !drop.has(x.id));
  writeList(LIKED_KEY, liked ? [track, ...rest] : rest);
  return library();
}

// ----------------------------------------------------------------------------- cards
export type MusicCard = {
  key: string;
  kind: MusicCatalogItem["kind"];
  title: string;
  subtitle: string;
  artwork: string;
  artworks: string[];
  circle: boolean;
  connectorId: string;
  track: MusicTrack | null;
  item: MusicCatalogItem;
};
export type MusicBand = { key: string; title: string; subtitle: string; layout: string; source: string; numbered: boolean; cards: MusicCard[]; notice: string | null };

function trackItem(track: MusicTrack): MusicCatalogItem {
  return { kind: "track", ...track };
}
export function card(item: MusicCatalogItem): MusicCard {
  const base = { kind: item.kind, connectorId: item.connectorId ?? "", item };
  switch (item.kind) {
    case "track": {
      const { kind: _kind, ...track } = item;
      return { ...base, key: `track:${src.sourceKey(track)}`, title: item.title, subtitle: item.artist, artwork: item.artwork, artworks: [], circle: false, track };
    }
    case "album":
      return { ...base, key: `album:${item.connectorId}:${item.id}`, title: item.title, subtitle: [item.artist, item.year].filter(Boolean).join(" · "), artwork: item.artwork, artworks: [], circle: false, track: null };
    case "artist":
      return { ...base, key: `artist:${item.connectorId}:${item.id}`, title: item.name, subtitle: item.subtitle ?? "", artwork: item.artwork ?? "", artworks: [], circle: true, track: null };
    case "playlist":
      return { ...base, key: `playlist:${item.connectorId}:${item.id}`, title: item.name, subtitle: item.subtitle ?? (item.trackCount ? t("music.trackCount", { count: item.trackCount }) : ""), artwork: item.artwork[0] ?? "", artworks: item.artwork.slice(0, 4), circle: false, track: null };
    case "station":
      return { ...base, key: `station:${item.connectorId}:${item.id}`, title: item.name, subtitle: item.subtitle ?? t("music.row.stationBadge"), artwork: item.artwork, artworks: [], circle: false, track: null };
  }
}
/**
 * subsonic/catalog.rs names its shelves with keys (music.row.serverNewest ...) that upstream's
 * catalogs never define, so the desktop shows the raw key. The TV shows upstream copy where a
 * string with the same meaning exists, and plain English for the two that have none.
 */
const SUBSONIC_ROW_TITLES: Record<string, () => string> = {
  "music.row.serverNewest": () => t("music.row.server"),
  "music.row.serverFrequent": () => "Most played",
  "music.row.serverRandom": () => "Random albums",
  "music.row.serverStarred": () => t("music.row.liked"),
  "music.row.serverArtists": () => t("music.search.artists"),
  "music.row.serverPlaylists": () => t("music.row.playlists"),
};
function rowTitle(rowData: MusicCatalogRow): string {
  if (rowData.titleLiteral) return rowData.title;
  const translated = t(rowData.title);
  const fallback = SUBSONIC_ROW_TITLES[rowData.title];
  return translated === rowData.title && fallback ? fallback() : translated;
}
function band(key: string, rowData: MusicCatalogRow, extra: Partial<MusicBand> = {}): MusicBand {
  const seen = new Set<string>();
  const cards = rowData.items.map(card).filter((c) => (seen.has(c.key) ? false : (seen.add(c.key), true)));
  return {
    key,
    title: rowTitle(rowData),
    subtitle: rowData.subtitle ?? "",
    layout: rowData.layout,
    source: rowData.source,
    numbered: false,
    cards,
    notice: null,
    ...extra,
  };
}

// ------------------------------------------------------------------------------ home
const HOME_TTL = 6 * 60 * 60 * 1000; // rows.rs ROW_CACHE_TTL
let homeCache: { at: number; key: string; rows: MusicCatalogRow[]; errors: Array<{ source: string; message: string }> } | null = null;

function connectionsKey(): string {
  return src.active().map((c) => c.id).join(",");
}

/** The kind music-home-rows.ts classifies by (only the id and kind are read). */
function homeConnections() {
  return src.connectors.map((c) => ({ id: c.id, name: c.name, kind: c.kind, status: c.ready() ? "connected" : "disconnected", capabilities: [], needs: [] }) as never);
}

/**
 * views/music.tsx band order, for the bands the TV can back: recents, server shelves, new
 * releases, the chart that stands in for "fresh" before there is history, your artists, charts,
 * up next / liked, stations, then every other row. `upcoming` is the rest of Swift's queue.
 */
export async function home(force: boolean, upcoming: MusicTrack[] | null): Promise<{ bands: MusicBand[]; errors: Array<{ source: string; message: string }>; failed: boolean }> {
  const key = connectionsKey();
  if (force || !homeCache || homeCache.key !== key || Date.now() - homeCache.at > HOME_TTL) {
    const loaded = await src.browseHome();
    homeCache = { at: Date.now(), key, rows: loaded.rows, errors: loaded.errors };
  }
  const { rows, errors } = homeCache;
  const slots: Record<string, MusicCatalogRow[]> = { newReleases: [], charts: [], stations: [], server: [], scrobble: [], extra: [] };
  const connections = homeConnections();
  for (const row of rows) slots[classifyHomeRow(row, connections)]!.push(row);

  const lib = library();
  const bands: MusicBand[] = [];
  const recents = lib.recents.slice(0, 18);
  if (recents.length) bands.push({ key: "recents", title: t("music.row.recents"), subtitle: t("music.row.recentsSubtitle"), layout: "covers", source: "", numbered: false, cards: recents.map((x) => card(trackItem(x))), notice: null });

  if (slots.server!.length) for (const row of slots.server!) bands.push(band(`server:${row.id}`, row));
  else if (!src.connectors.some((c) => c.kind === "server" && c.ready()))
    bands.push({ key: "server", title: t("music.row.server"), subtitle: t("music.row.serverSubtitle"), layout: "covers", source: "", numbered: false, cards: [], notice: t("music.connect.serverBody") });

  const spare: MusicCatalogRow[] = [];
  if (slots.newReleases![0]) bands.push(band("new-releases", slots.newReleases![0]));
  spare.push(...slots.newReleases!.slice(1));

  const chartsInFresh = lib.recents.length === 0 && (slots.charts![0]?.items.some((i) => i.kind === "track") ?? false);
  if (chartsInFresh) bands.push(band("fresh", slots.charts![0]!, { layout: "trackGrid", numbered: true }));

  const artists = favoriteArtists(lib.recents).slice(0, 18);
  if (artists.length) {
    const items: MusicCatalogItem[] = artists.map((name) => ({ kind: "artist", id: `history:${name}`, connectorId: "catalog", name, artwork: lib.recents.find((x) => x.artist.startsWith(name) && x.artwork)?.artwork }));
    bands.push({ key: "artists", title: t("music.row.artists"), subtitle: t("music.row.artistsSubtitle"), layout: "circles", source: "", numbered: false, cards: items.map(card), notice: null });
  }
  if (!chartsInFresh && slots.charts![0]) bands.push(band("charts", slots.charts![0]));
  spare.push(...slots.charts!.slice(1));

  const next = upcoming ?? [];
  if (next.length) bands.push({ key: "liked", title: t("music.row.upNext"), subtitle: t("music.row.upNextSubtitle"), layout: "trackGrid", source: "", numbered: true, cards: next.map((x) => card(trackItem(x))), notice: null });
  else if (lib.liked.length) bands.push({ key: "liked", title: t("music.row.liked"), subtitle: t("music.row.likedSubtitle"), layout: "trackGrid", source: "", numbered: false, cards: lib.liked.map((x) => card(trackItem(x))), notice: null });

  for (const row of slots.stations!) bands.push(band(`station:${row.id}`, row));
  for (const row of [...spare, ...slots.extra!]) bands.push(band(`home:${row.id}`, row));

  const failed = rows.length === 0 && errors.length > 0 && lib.recents.length === 0 && lib.liked.length === 0;
  return { bands: bands.filter((b) => b.cards.length || b.notice), errors, failed };
}

// ---------------------------------------------------------------------------- search
export async function search(query: string, connectorId: string | null): Promise<{ top: MusicCard | null; tracks: MusicCard[]; albums: MusicCard[]; artists: MusicCard[]; playlists: MusicCard[]; errors: Array<{ source: string; message: string }> }> {
  const q = query.trim();
  if (!q) return { top: null, tracks: [], albums: [], artists: [], playlists: [], errors: [] };
  const r: MusicSearchResults & { errors: Array<{ source: string; message: string }> } = await src.searchTyped(q, 24, connectorId);
  return {
    top: r.top ? card(r.top) : null,
    tracks: r.tracks.map((x) => card(trackItem(x))),
    albums: r.albums.map((x) => card({ kind: "album", ...x })),
    artists: r.artists.map((x) => card({ kind: "artist", ...x })),
    playlists: r.playlists.map((x) => card({ kind: "playlist", ...x })),
    errors: r.errors,
  };
}

// ------------------------------------------------------------------------------ open
export type MusicPage = { kind: string; title: string; subtitle: string; artwork: string; circle: boolean; tracks: MusicTrack[]; bands: MusicBand[] };

/** music-detail-data.ts: album / artist / playlist / station pages from the owning connector. */
export async function open(item: MusicCatalogItem): Promise<MusicPage> {
  const owner = src.connector(item.connectorId);
  if (!owner) throw new Error(`Unknown music connector: ${item.connectorId}`);
  switch (item.kind) {
    case "album": {
      const tracks = await owner.albumTracks(item);
      return { kind: "album", title: item.title, subtitle: [item.artist, item.year].filter(Boolean).join(" · "), artwork: item.artwork || tracks[0]?.artwork || "", circle: false, tracks, bands: [] };
    }
    case "artist": {
      let artist = item;
      // music-personal-bands.tsx: an artist from the listening history opens by name.
      if (artist.id.startsWith("history:")) {
        const found = (await src.deezer.searchArtists(artist.name, 5).catch(() => [])).find((a) => a.name.toLowerCase() === artist.name.toLowerCase()) ?? (await src.deezer.searchArtists(artist.name, 1).catch(() => []))[0];
        if (!found) throw new Error(t("music.source.none"));
        artist = { kind: "artist", ...found };
      }
      const [tracks, rows] = await Promise.allSettled([owner.artistTop(artist), owner.artistRows(artist)]);
      if (tracks.status === "rejected" && rows.status === "rejected") throw tracks.reason;
      const bands = (rows.status === "fulfilled" ? rows.value : []).map((r) => band(r.id, r));
      return { kind: "artist", title: artist.name, subtitle: artist.subtitle ?? "", artwork: artist.artwork ?? "", circle: true, tracks: tracks.status === "fulfilled" ? tracks.value : [], bands };
    }
    case "playlist": {
      const tracks = await owner.playlistTracks(item);
      return { kind: "playlist", title: item.name, subtitle: item.subtitle ?? "", artwork: item.artwork[0] ?? tracks[0]?.artwork ?? "", circle: false, tracks, bands: [] };
    }
    case "station": {
      const tracks = await owner.stationTracks(item);
      return { kind: "station", title: item.name, subtitle: item.subtitle ?? t("music.row.stationBadge"), artwork: item.artwork || tracks[0]?.artwork || "", circle: false, tracks, bands: [] };
    }
    case "track": {
      const { kind: _k, ...track } = item;
      return { kind: "track", title: track.title, subtitle: track.artist, artwork: track.artwork, circle: false, tracks: [track], bands: [] };
    }
  }
}

// --------------------------------------------------------------------------- playback
const attemptKey = (track: MusicTrack) => `${track.connectorId}:${track.id}`;
function withOrigin(candidate: MusicTrack, original: MusicTrack): MusicTrack {
  return { ...candidate, collectionOrigin: original.collectionOrigin ?? { id: original.id, connectorId: original.connectorId } };
}
function errorMessage(cause: unknown): string {
  const raw = cause instanceof Error ? cause.message : String(cause);
  return raw.startsWith("music.") ? t(raw) : raw;
}

export type MusicPrepared = { track: MusicTrack; stream: src.MusicStream; failed: string[] };

/**
 * player.ts playMusic, minus the engine calls: a catalog track is matched to a playable source
 * first (preferring the source that is already playing), then resolved; a source that fails is
 * swapped for the next matched candidate, at most two alternatives, as upstream does.
 */
export async function prepare(track: MusicTrack, failedKeys: string[] | null, workingSource: string | null): Promise<MusicPrepared> {
  const failed = new Set(failedKeys ?? []);
  const catalog = track.connectorId === "catalog" && !track.playbackUrl;
  let alternatives: MusicTrack[] = [];
  let searched = catalog;
  let current = track;
  const usable = (list: Awaited<ReturnType<typeof src.candidates>>, exclude?: MusicTrack) =>
    list.filter((c) => c.health !== "offline" && c.track.connectorId !== "catalog" && !failed.has(attemptKey(c.track)) && !(exclude && c.track.id === exclude.id && c.track.connectorId === exclude.connectorId));
  if (catalog) {
    const playable = usable(await src.withTimeout(src.candidates(track), 12_000, "music.source.none").catch(() => []));
    const match = playable.find((c) => c.connectorId === workingSource) ?? playable[0];
    if (!match) throw new Error(t("music.source.none"));
    alternatives = playable.filter((c) => c !== match).slice(0, 2).map((c) => withOrigin(c.track, track));
    current = withOrigin(match.track, track);
  }
  for (let attempt = 0; ; attempt++) {
    const owner = src.connector(current.connectorId);
    try {
      // recoverPlayback: a source that already failed for this entry is not asked again.
      if (failed.has(attemptKey(current))) throw new Error(t("music.error.playback"));
      if (current.playbackUrl) return { track: current, stream: { url: current.playbackUrl, mimeType: "", bitrate: 0 }, failed: [...failed] };
      if (!owner || !owner.playable || !owner.ready()) throw new Error(t("music.source.none"));
      return { track: current, stream: await owner.resolve(current), failed: [...failed] };
    } catch (cause) {
      failed.add(attemptKey(current));
      if (!searched) {
        searched = true;
        const failedTrack = current;
        const list = await src.withTimeout(src.candidates(current), 12_000, "music.source.none").catch(() => []);
        alternatives = usable(list, failedTrack).slice(0, 2).map((c) => withOrigin(c.track, failedTrack));
      }
      const next = alternatives[attempt];
      if (!next) throw new Error(errorMessage(cause));
      current = next;
    }
  }
}

/** The listener stopped the player: close any server-side play session (Jellyfin). */
export function stopped(): void {
  src.jellyfinStopped();
}

// ----------------------------------------------------------------- radio, lyrics, scrobbles
function familiar(): MusicTrack[] {
  const lib = library();
  return [...lib.recents, ...lib.liked];
}
/** player.ts musicRadioTracks -> radio.ts loadTrackRadio (the station; Swift plays + arms it). */
export async function radio(track: MusicTrack): Promise<MusicTrack[]> {
  try {
    return await radioLib.loadTrackRadio(track, familiar());
  } catch {
    throw new Error(t("music.radio.error"));
  }
}
/** radio.ts armTrackRadio's extension, asked for by Swift near the end of a radio queue. */
export async function radioExtend(queue: MusicTrack[], index: number): Promise<MusicTrack[]> {
  return radioLib.extendTrackRadio(queue ?? [], index, familiar()).catch(() => []);
}

/**
 * music-now-playing.tsx lyrics panel: lyrics.ts loadTrackLyrics (LRCLIB, synced lines only)
 * with its nine-second give-up, and the per-track sync offset from lyric-offset.ts.
 */
export async function lyrics(track: MusicTrack): Promise<{ lines: Array<{ at: number; text: string }>; offset: number }> {
  const lines = await src.withTimeout(loadTrackLyrics(track), 9000, "lyrics").catch(() => null);
  return { lines: lines ?? [], offset: getLyricOffset(track) };
}
/** lyric-offset.ts setLyricOffset (clamped to +-8 s in 0.25 s steps); returns the stored value. */
export function setLyricOffset(track: MusicTrack, seconds: number): number {
  return storeLyricOffset(track, seconds);
}

/** accounts.rs scrobble_track (Subsonic, then Last.fm). Swift calls it past should_scrobble. */
export function scrobble(track: MusicTrack, startedAt: number) {
  return scrobbling.scrobble(track, startedAt);
}
export function shouldScrobble(listenedSeconds: number, durationSeconds: number): boolean {
  return scrobbling.shouldScrobble(listenedSeconds, durationSeconds);
}

// --------------------------------------------------------------------- Navidrome sign-in
/** subsonic/mod.rs connect: the Connections sheet's form (Server URL, Username, Password). */
export async function subsonicConnect(url: string, username: string, password: string): Promise<{ account: string; detail: string }> {
  const pairing = await src.subsonicConnect(url ?? "", username ?? "", password ?? "");
  homeCache = null;
  return { account: pairing.username, detail: pairing.baseUrl };
}
export function subsonicDisconnect(): boolean {
  src.subsonicDisconnect();
  homeCache = null;
  return true;
}

// ------------------------------------------------------------------------------ Last.fm
export const lastfmStatus = scrobbling.lastfmStatus;
export const lastfmBegin = scrobbling.lastfmBegin;
export const lastfmFinish = scrobbling.lastfmFinish;
export const lastfmDisconnect = scrobbling.lastfmDisconnect;

// ------------------------------------------------------------------------------ Spotify
// spotify/mod.rs + auth.rs on the TV (engine/musicSpotify.ts); the librespot session itself is
// Swift + rust/harbor-ffi, which report back through spotifySessionReady / spotifyFailed.
export const spotifySetup = spotify.setup;
export const spotifyStatus = spotify.status;
export const spotifyRestore = spotify.restore;
/** connector.rs connect: save a typed client id, then the authorize URL for the phone. */
export async function spotifyBegin(clientId: string | null) {
  return spotify.begin(clientId);
}
/** The pasted redirect, exchanged for the token Swift signs the librespot session in with. */
export async function spotifyFinish(pasted: string) {
  return spotify.finish(pasted);
}
export async function spotifySessionReady(rust: spotify.SpotifyStatus & { credentials?: string | null }, token: { accessToken: string; expiresAt: number } | null) {
  const out = await spotify.sessionReady(rust, token);
  homeCache = null;
  return out;
}
export function spotifyFailed(error: string) {
  homeCache = null;
  return spotify.recordFailure(error);
}
/** mod.rs disconnect (Swift has already shut the librespot session down). */
export function spotifyDisconnect() {
  homeCache = null;
  return spotify.forget();
}

// ------------------------------------------------------------------ sources + consent
export function connections() {
  const consent = getMusicSourceConsent();
  const sp = spotify.connection();
  const rows = src.connectors.map((c) => ({
    id: c.id,
    name: c.name,
    kind: c.kind as string,
    // spotify/mod.rs connection(): a recorded failure is "error" until the next sign-in.
    status: c.id === "spotify" && !c.ready() ? sp.status : c.ready() ? (c.health === "offline" ? "error" : "connected") : "disconnected",
    health: c.health as string,
    detail: (c.detail?.() ?? null) as string | null,
    // subsonic/mod.rs and spotify/mod.rs connection(): the signed-in user is the account.
    account: (c.id === "subsonic" ? src.subsonicPairing()?.username ?? null : c.id === "spotify" ? sp.account : null) as string | null,
    error: (c.id === "spotify" ? sp.error : null) as string | null,
    gated: c.id === "soundcloud",
    enabled: c.id === "soundcloud" ? !!consent.acceptedAt && consent.sources.soundcloud : c.ready(),
    capabilities: [c.searchable ? "search" : null, c.browsable ? "browse" : null, c.playable ? "play" : null, c.id === "subsonic" ? "library" : null].filter(Boolean) as string[],
  }));
  // lastfm.rs LastFmConnector: a scrobbler (kind "scrobbler", capability "scrobble").
  const fm = scrobbling.lastfmStatus();
  rows.push({
    id: "lastfm",
    name: "Last.fm",
    kind: "scrobbler",
    status: fm.connected ? (fm.health === "offline" ? "error" : "connected") : "disconnected",
    health: fm.health,
    detail: null,
    account: fm.username,
    error: null,
    gated: false,
    enabled: fm.connected,
    capabilities: ["scrobble"],
  });
  return rows;
}

export function consent(): { accepted: boolean; soundcloud: boolean } {
  const c = getMusicSourceConsent();
  return { accepted: !!c.acceptedAt, soundcloud: !!c.acceptedAt && c.sources.soundcloud };
}
/** music-source-consent.tsx accept: only SoundCloud is offered on the TV (no YouTube source). */
export function acceptSoundCloud(): { accepted: boolean; soundcloud: boolean } {
  const c = getMusicSourceConsent();
  if (c.acceptedAt) setMusicSourceEnabled("soundcloud", true);
  else acceptMusicSources(["soundcloud"]);
  homeCache = null;
  return consent();
}
export function setSoundCloud(on: boolean): { accepted: boolean; soundcloud: boolean } {
  if (on) return acceptSoundCloud();
  setMusicSourceEnabled("soundcloud", false);
  homeCache = null;
  return consent();
}
export function withdrawConsent(): { accepted: boolean; soundcloud: boolean } {
  withdrawMusicSourceConsent();
  homeCache = null;
  return consent();
}
