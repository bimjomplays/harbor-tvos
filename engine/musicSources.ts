// Music sources (Stage 12). Upstream keeps every music connector in Rust
// (src-tauri/src/music/connectors/*, registry.rs, matching.rs, rows.rs) behind Tauri commands;
// tvOS has no Tauri, so the connectors that need nothing but plain HTTP are ported here, one
// section per upstream module, with the same ids, row ids, limits and fallbacks:
//   catalog     connectors/catalog/{mod,deezer,itunes}.rs   (browse + search, never playable)
//   soundcloud  connectors/soundcloud/*.rs                   (gated by source consent)
//   jellyfin    connectors/jellyfin/*.rs                     (adopts the home-server connection)
//   plex        connectors/plex/*.rs                         (adopts the home-server connection)
//   subsonic    connectors/subsonic/*.rs                     (its own sign-in: Navidrome / Subsonic)
// plus the open databases the catalog leans on: catalog/listenbrainz.rs, musicbrainz.rs.
// Left out, with the reasons in docs/music-spec.md: spotify (librespot), youtube (yt-dlp),
// local (no user file system).
import type {
  MusicAlbumRef,
  MusicArtistRef,
  MusicCatalogItem,
  MusicCatalogRow,
  MusicConnectorHealth,
  MusicPlaylistRef,
  MusicRowLayout,
  MusicSearchResults,
  MusicSourceCandidate,
  MusicStationRef,
  MusicTrack,
} from "@/lib/music/types";
import { mediaServerConnections, mediaServerToken } from "@/lib/media-server/connections";
import { musicSourceAllowed } from "@/lib/music/source-consent";
import { getSecret, setSecret } from "@/lib/secret-store";
import { md5Hex } from "./md5";

export type MusicStream = { url: string; mimeType: string; bitrate: number; httpHeaders?: Record<string, string> };
type Health = MusicConnectorHealth["health"];

export interface Connector {
  id: string;
  name: string;
  kind: "streaming" | "server" | "catalog";
  searchable: boolean;
  playable: boolean;
  browsable: boolean;
  health: Health;
  /** Configured / allowed on this TV right now (server sign-in present, consent given). */
  ready(): boolean;
  detail?(): string | undefined;
  search(query: string, limit: number): Promise<MusicTrack[]>;
  searchTyped(query: string, limit: number): Promise<MusicSearchResults>;
  browseHome(): Promise<MusicCatalogRow[]>;
  resolve(track: MusicTrack): Promise<MusicStream>;
  albumTracks(album: MusicAlbumRef): Promise<MusicTrack[]>;
  artistTop(artist: MusicArtistRef): Promise<MusicTrack[]>;
  artistRows(artist: MusicArtistRef): Promise<MusicCatalogRow[]>;
  playlistTracks(playlist: MusicPlaylistRef): Promise<MusicTrack[]>;
  stationTracks(station: MusicStationRef): Promise<MusicTrack[]>;
}

// ------------------------------------------------------------------------------ shared bits
/** music.rs duration_label */
export function durationLabel(seconds: number): string {
  const s = Math.max(0, Math.floor(seconds));
  return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}`;
}

function text(value: unknown): string | undefined {
  if (typeof value === "number" && Number.isFinite(value)) return String(value);
  if (typeof value !== "string") return undefined;
  const trimmed = value.trim();
  return trimmed ? trimmed : undefined;
}

function num(value: unknown): number | undefined {
  if (typeof value === "number" && Number.isFinite(value)) return value;
  if (typeof value === "string" && value.trim() && Number.isFinite(Number(value))) return Number(value);
  return undefined;
}

function unsupported(id: string, request: string): Error {
  return new Error(`Music connector ${id} does not support ${request}`);
}

/** Every connector's classify_error: transport trouble is offline, anything else degraded. */
function classify(error: unknown, extra: string[] = []): Health {
  const lower = String(error instanceof Error ? error.message : error).toLowerCase();
  const markers = ["timed out", "timeout", "network", "connection", "dns", "resolve host", "offline", "request failed", ...extra];
  return markers.some((m) => lower.includes(m)) ? "offline" : "degraded";
}

export function withTimeout<T>(work: Promise<T>, ms: number, message: string): Promise<T> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  const timeout = new Promise<never>((_, reject) => {
    timer = setTimeout(() => reject(new Error(message)), ms);
  });
  return Promise.race([work, timeout]).finally(() => {
    if (timer !== undefined) clearTimeout(timer);
  });
}

type FetchInit = { method?: string; headers?: Record<string, string>; body?: string; timeoutMs?: number };
async function request(url: string, init: FetchInit = {}): Promise<{ status: number; text: string; headers: { get(name: string): string | null } }> {
  let response: Response;
  try {
    response = await fetch(url, { method: init.method ?? "GET", headers: init.headers, body: init.body, harborTimeoutMs: init.timeoutMs ?? 20000 } as RequestInit);
  } catch (cause) {
    throw new Error(`request failed: ${cause instanceof Error ? cause.message : String(cause)}`);
  }
  return { status: response.status, text: await response.text(), headers: response.headers };
}

function recorder(connector: { health: Health }, extra: string[] = []) {
  return async <T>(work: Promise<T>): Promise<T> => {
    try {
      const value = await work;
      connector.health = "healthy";
      return value;
    } catch (cause) {
      connector.health = classify(cause, extra);
      throw cause;
    }
  };
}

function row(id: string, title: string, titleLiteral: boolean, subtitle: string | undefined, layout: MusicRowLayout, source: string, items: MusicCatalogItem[]): MusicCatalogRow {
  return { id, title, titleLiteral, subtitle, layout, source, items };
}

function trackItems(tracks: MusicTrack[]): MusicCatalogItem[] {
  return tracks.map((t) => ({ kind: "track" as const, ...t }));
}
function albumItems(albums: MusicAlbumRef[]): MusicCatalogItem[] {
  return albums.map((a) => ({ kind: "album" as const, ...a }));
}
function artistItems(artists: MusicArtistRef[]): MusicCatalogItem[] {
  return artists.map((a) => ({ kind: "artist" as const, ...a }));
}
function playlistItems(playlists: MusicPlaylistRef[]): MusicCatalogItem[] {
  return playlists.map((p) => ({ kind: "playlist" as const, ...p }));
}
function stationItems(stations: MusicStationRef[]): MusicCatalogItem[] {
  return stations.map((s) => ({ kind: "station" as const, ...s }));
}

function emptyResults(): MusicSearchResults {
  return { tracks: [], albums: [], artists: [], playlists: [] };
}

// =========================================================================== open catalog
// connectors/catalog/mod.rs + deezer.rs + itunes.rs. Browsable and searchable, never playable:
// a catalog track is matched to a playable source before it plays (registry.rs candidates).
const PROVIDER_TIMEOUT = 10_000;
const CATALOG_ROW_LIMIT = 20;
const DEEZER = "https://api.deezer.com";

function releaseYear(value: unknown): number | undefined {
  const head = text(value)?.slice(0, 4);
  const year = head && /^\d{4}$/.test(head) ? Number(head) : undefined;
  return year && year > 0 ? year : undefined;
}

function catalogNumericId(value: string, prefix: string): number {
  const raw = value.startsWith(prefix) ? value.slice(prefix.length) : "";
  if (!/^\d+$/.test(raw) || Number(raw) <= 0) throw new Error("Invalid catalog identity");
  return Number(raw);
}

async function deezerJson(url: string): Promise<Record<string, unknown>> {
  const res = await request(url, { headers: { Accept: "application/json" }, timeoutMs: PROVIDER_TIMEOUT });
  if (res.status < 200 || res.status >= 300) throw new Error(`Deezer returned ${res.status}`);
  let value: Record<string, unknown>;
  try {
    value = JSON.parse(res.text) as Record<string, unknown>;
  } catch {
    throw new Error("Deezer response was unreadable");
  }
  // deezer.rs failure_message: an error body can arrive with HTTP 200.
  const error = value?.error as { code?: number; message?: string } | undefined;
  if (error && typeof error === "object") throw new Error(`Deezer error ${error.code ?? 0}: ${error.message ?? "Deezer rejected the request"}`);
  return value;
}
function deezerData(value: Record<string, unknown>): Record<string, unknown>[] {
  return Array.isArray(value.data) ? (value.data as Record<string, unknown>[]) : [];
}

function deezerAlbum(entry: Record<string, unknown>, credit?: { id: number; name: string }): MusicAlbumRef | undefined {
  const id = num(entry.id);
  const title = text(entry.title);
  const artistNode = (entry.artist as Record<string, unknown> | undefined) ?? (credit ? { id: credit.id, name: credit.name } : undefined);
  const artist = text(artistNode?.name);
  if (!id || !title || !artist) return undefined;
  return {
    id: `deezer:album:${id}`,
    connectorId: "catalog",
    title,
    artist,
    artwork: text(entry.cover_big) ?? text(entry.cover_medium) ?? "",
    year: releaseYear(entry.release_date),
    trackCount: num(entry.nb_tracks),
  };
}
function deezerTrack(entry: Record<string, unknown>): MusicTrack | undefined {
  const id = num(entry.id);
  const title = text(entry.title);
  const artist = text((entry.artist as Record<string, unknown> | undefined)?.name);
  if (!id || !title || !artist) return undefined;
  const release = entry.album as Record<string, unknown> | undefined;
  const seconds = num(entry.duration) ?? 0;
  return {
    explicit: typeof entry.explicit_lyrics === "boolean" ? entry.explicit_lyrics : undefined,
    version: text(entry.title_version),
    id: `deezer:track:${id}`,
    connectorId: "catalog",
    sourceId: String(id),
    title,
    artist,
    album: text(release?.title),
    artwork: text(release?.cover_xl) ?? text(release?.cover_big) ?? text(release?.cover_medium) ?? "",
    durationSeconds: seconds,
    durationLabel: durationLabel(seconds),
  };
}
function deezerArtist(entry: Record<string, unknown>): MusicArtistRef | undefined {
  const id = num(entry.id);
  const name = text(entry.name);
  if (!id || !name) return undefined;
  const position = num(entry.position);
  return {
    id: `deezer:artist:${id}`,
    connectorId: "catalog",
    name,
    artwork: text(entry.picture_big) ?? text(entry.picture_medium),
    subtitle: position !== undefined ? `#${position}` : undefined,
  };
}
const pick = <T, U>(list: T[], map: (entry: T) => U | undefined, limit: number): U[] => {
  const out: U[] = [];
  for (const entry of list) {
    if (out.length >= limit) break;
    const value = map(entry);
    if (value !== undefined) out.push(value);
  }
  return out;
};

export const deezer = {
  chartAlbums: async (limit: number) => pick(deezerData(await deezerJson(`${DEEZER}/chart/0/albums?limit=25&index=0`)), (e) => deezerAlbum(e), limit),
  chartTracks: async (limit: number) => pick(deezerData(await deezerJson(`${DEEZER}/chart/0/tracks?limit=25&index=0`)), deezerTrack, limit),
  chartArtists: async (limit: number) => pick(deezerData(await deezerJson(`${DEEZER}/chart/0/artists?limit=25&index=0`)), deezerArtist, limit),
  editorial: async (limit: number) => pick(deezerData(await deezerJson(`${DEEZER}/editorial/0/selection?limit=25`)), (e) => deezerAlbum(e), limit),
  searchArtists: async (query: string, limit: number) => {
    const capped = Math.min(50, Math.max(1, limit));
    const params = new URLSearchParams({ q: query.trim(), limit: String(capped) });
    return pick(deezerData(await deezerJson(`${DEEZER}/search/artist?${params}`)), deezerArtist, capped);
  },
  /** deezer.rs complete_album_tracks: the embedded list stops at 25; page the rest. */
  albumTracks: async (albumId: string): Promise<MusicTrack[]> => {
    const id = catalogNumericId(albumId, "deezer:album:");
    const album = await deezerJson(`${DEEZER}/album/${id}`);
    if (num(album.id) !== id) throw new Error("Deezer returned a different album identity");
    let entries = deezerData((album.tracks as Record<string, unknown>) ?? {});
    const expected = num(album.nb_tracks);
    if (expected !== undefined && expected > entries.length) {
      entries = [];
      for (let page = 0; page < 100 && entries.length < expected; page++) {
        const batch = deezerData(await deezerJson(`${DEEZER}/album/${id}/tracks?limit=100&index=${entries.length}`));
        if (batch.length === 0) throw new Error("Deezer returned an incomplete album. Please try again.");
        entries.push(...batch);
      }
    }
    const cover = text(album.cover_big) ?? text(album.cover_medium) ?? "";
    return entries.map((entry) => {
      const parsed = deezerTrack(entry);
      if (!parsed) throw new Error("Deezer returned an album track without its title or artist");
      return { ...parsed, album: parsed.album ?? text(album.title), artwork: parsed.artwork || cover };
    });
  },
  artistTop: async (artistId: string) => {
    const id = catalogNumericId(artistId, "deezer:artist:");
    return pick(deezerData(await deezerJson(`${DEEZER}/artist/${id}/top?limit=50`)), deezerTrack, 50);
  },
  artistAlbums: async (artist: MusicArtistRef) => {
    const id = catalogNumericId(artist.id, "deezer:artist:");
    return pick(deezerData(await deezerJson(`${DEEZER}/artist/${id}/albums?limit=50`)), (e) => deezerAlbum(e, { id, name: artist.name }), 50);
  },
  relatedArtists: async (artistId: string) => {
    const id = catalogNumericId(artistId, "deezer:artist:");
    return pick(deezerData(await deezerJson(`${DEEZER}/artist/${id}/related?limit=12`)), deezerArtist, 12);
  },
};

// itunes.rs
function itunesArtwork(url: unknown): string {
  return text(url)?.replace("100x100bb", "500x500bb") ?? "";
}
async function itunesResults(url: string): Promise<Record<string, unknown>[]> {
  const res = await request(url, { timeoutMs: PROVIDER_TIMEOUT });
  if (res.status < 200 || res.status >= 300) throw new Error(`iTunes returned ${res.status}`);
  if (!res.text.trim()) return [];
  try {
    const body = JSON.parse(res.text) as { results?: Record<string, unknown>[] };
    return Array.isArray(body.results) ? body.results : [];
  } catch {
    throw new Error("iTunes response was unreadable");
  }
}
function itunesSearchUrl(query: string, entity: string, limit: number): string {
  const params = new URLSearchParams({ term: query.trim(), media: "music", entity, limit: String(Math.min(50, Math.max(1, limit))), country: "US" });
  return `https://itunes.apple.com/search?${params}`;
}
function itunesTrack(entry: Record<string, unknown>): MusicTrack | undefined {
  if (entry.kind !== "song") return undefined;
  const id = num(entry.trackId);
  const title = text(entry.trackName);
  const artist = text(entry.artistName);
  if (!id || !title || !artist) return undefined;
  const seconds = Math.floor((num(entry.trackTimeMillis) ?? 0) / 1000);
  return { id: `itunes:track:${id}`, connectorId: "catalog", sourceId: String(id), title, artist, album: text(entry.collectionName), artwork: itunesArtwork(entry.artworkUrl100), durationSeconds: seconds, durationLabel: durationLabel(seconds) };
}
function itunesAlbum(entry: Record<string, unknown>): MusicAlbumRef | undefined {
  const id = num(entry.collectionId);
  const title = text(entry.collectionName);
  const artist = text(entry.artistName);
  if (!id || !title || !artist) return undefined;
  return { id: `itunes:album:${id}`, connectorId: "catalog", title, artist, artwork: itunesArtwork(entry.artworkUrl100), year: releaseYear(entry.releaseDate), trackCount: num(entry.trackCount) };
}
function itunesArtist(entry: Record<string, unknown>): MusicArtistRef | undefined {
  const id = num(entry.artistId);
  const name = text(entry.artistName);
  if (!id || !name) return undefined;
  return { id: `itunes:artist:${id}`, connectorId: "catalog", name, subtitle: text(entry.primaryGenreName) };
}
export const itunes = {
  songs: async (query: string, limit: number) => pick(await itunesResults(itunesSearchUrl(query, "song", limit)), itunesTrack, Math.min(50, Math.max(1, limit))),
  albums: async (query: string, limit: number) => pick(await itunesResults(itunesSearchUrl(query, "album", limit)), itunesAlbum, limit),
  artists: async (query: string, limit: number) => pick(await itunesResults(itunesSearchUrl(query, "musicArtist", limit)), itunesArtist, limit),
  tracks: async (id: string, prefix: string) => pick(await itunesResults(`https://itunes.apple.com/lookup?id=${catalogNumericId(id, prefix)}&entity=song&limit=200`), itunesTrack, 200),
  artistAlbums: async (id: string) => pick(await itunesResults(`https://itunes.apple.com/lookup?id=${catalogNumericId(id, "itunes:artist:")}&entity=album&limit=200`), itunesAlbum, 200),
};

// http.rs: one polite client for the open databases (MusicBrainz asks for a contactable agent).
const OPEN_DATA_AGENT = "Harbor/1.0 ( https://github.com/harborstremio/harbor )";
const OPEN_DATA_TIMEOUT = 6000;
async function openDataGet(url: string, provider: string): Promise<{ contentType: string; text: string }> {
  const res = await request(url, { headers: { "User-Agent": OPEN_DATA_AGENT, Accept: "application/json" }, timeoutMs: OPEN_DATA_TIMEOUT });
  if (res.status < 200 || res.status >= 300) throw new Error(`${provider} returned HTTP ${res.status}`);
  return { contentType: res.headers.get("content-type") ?? "", text: res.text };
}
/** listenbrainz.rs pace() / musicbrainz.rs LAST_REQUEST: at most one call a second per service. */
function pacer(): () => Promise<void> {
  let chain: Promise<void> = Promise.resolve();
  let last = 0;
  return () => {
    const turn = chain.then(async () => {
      const wait = last + 1000 - Date.now();
      if (wait > 0) await new Promise((r) => setTimeout(r, wait));
      last = Date.now();
    });
    chain = turn.catch(() => undefined);
    return turn;
  };
}

// coverart.rs
function safeMbid(raw: unknown): string | undefined {
  const trimmed = typeof raw === "string" ? raw.trim() : "";
  return trimmed.length === 36 && /^[0-9a-fA-F-]+$/.test(trimmed) ? trimmed.toLowerCase() : undefined;
}
function releaseArtwork(releaseMbid: string, caaId: number | string): string {
  return `https://archive.org/download/mbid-${releaseMbid}/mbid-${releaseMbid}-${caaId}_thumb500.jpg`;
}
/** catalog/mod.rs release_year: the head of a date, 1000..=3000. */
function catalogYear(value: unknown): number | undefined {
  const head = typeof value === "string" ? value.trim().slice(0, 4) : "";
  const year = /^\d{4}$/.test(head) ? Number(head) : NaN;
  return year >= 1000 && year <= 3000 ? year : undefined;
}

// listenbrainz.rs: fresh releases (the "New releases" shelf) and the sitewide artist chart
// (the charting-artists fallback when Deezer's artist chart fails).
const LB_FRESH = "https://api.listenbrainz.org/1/explore/fresh-releases/?days=7&sort=release_date&past=true&future=false";
const LB_SITEWIDE = "https://api.listenbrainz.org/1/stats/sitewide/artists?count=25&offset=0&range=month";
const lbPace = pacer();
async function lbFetch(url: string): Promise<string> {
  await lbPace();
  const res = await openDataGet(url, "ListenBrainz");
  if (!res.text.trim()) return "";
  if (!res.contentType.includes("json")) throw new Error("ListenBrainz is verifying the client");
  return res.text;
}
/** listenbrainz.rs listens(): 1234567 → "1,234,567 listens". */
function listens(count: number): string {
  return `${String(Math.floor(count)).replace(/\B(?=(\d{3})+(?!\d))/g, ",")} listens`;
}
export function parseFreshReleases(body: string, limit: number): MusicAlbumRef[] {
  if (!body.trim()) return [];
  let parsed: { payload?: { releases?: Record<string, unknown>[] } };
  try {
    parsed = JSON.parse(body);
  } catch (cause) {
    throw new Error(`ListenBrainz fresh releases were unreadable: ${cause instanceof Error ? cause.message : cause}`);
  }
  if (!Array.isArray(parsed?.payload?.releases)) throw new Error("ListenBrainz fresh releases were unreadable: missing releases");
  const releases = parsed.payload!.releases!.filter((r) => r.release_group_primary_type === "Album" || r.release_group_primary_type === "EP");
  releases.sort((a, b) => String(b.release_date ?? "").localeCompare(String(a.release_date ?? "")));
  const out: MusicAlbumRef[] = [];
  for (const release of releases) {
    if (out.length >= limit) break;
    const title = text(release.release_name);
    const artist = text(release.artist_credit_name);
    const artMbid = safeMbid(release.caa_release_mbid);
    const caaId = num(release.caa_id);
    if (!title || !artist || !artMbid || caaId === undefined) continue;
    const releaseMbid = safeMbid(release.release_mbid);
    const groupMbid = safeMbid(release.release_group_mbid);
    const [entity, mbid] = releaseMbid ? ["release", releaseMbid] : ["release-group", groupMbid];
    if (!mbid) continue;
    // caa_id is a 64-bit integer; String(num) keeps it exact below 2^53 (current ids are ~3.5e10).
    out.push({ id: `musicbrainz:${entity}:${mbid}`, connectorId: "catalog", title, artist, artwork: releaseArtwork(artMbid, caaId), year: catalogYear(release.release_date) });
  }
  return out;
}
function parseTopArtists(body: string, limit: number): MusicArtistRef[] {
  if (!body.trim()) return [];
  let parsed: { payload?: { artists?: Record<string, unknown>[] } };
  try {
    parsed = JSON.parse(body);
  } catch (cause) {
    throw new Error(`ListenBrainz statistics were unreadable: ${cause instanceof Error ? cause.message : cause}`);
  }
  const out: MusicArtistRef[] = [];
  for (const entry of parsed?.payload?.artists ?? []) {
    if (out.length >= limit) break;
    const name = text(entry.artist_name);
    const mbid = safeMbid(entry.artist_mbid);
    if (!name || !mbid) continue;
    const count = num(entry.listen_count);
    out.push({ id: `musicbrainz:artist:${mbid}`, connectorId: "catalog", name, subtitle: count !== undefined ? listens(count) : undefined });
  }
  return out;
}
export const listenbrainz = {
  freshReleases: async (limit: number) => parseFreshReleases(await lbFetch(LB_FRESH), limit),
  topArtists: async (limit: number) => parseTopArtists(await lbFetch(LB_SITEWIDE), limit),
};

// musicbrainz.rs: track lists for the ListenBrainz releases and artists opened from the home.
const mbPace = pacer();
async function mbFetch(path: string): Promise<Record<string, unknown>> {
  await mbPace();
  const res = await openDataGet(`https://musicbrainz.org/ws/2/${path}&fmt=json`, "MusicBrainz");
  try {
    return JSON.parse(res.text) as Record<string, unknown>;
  } catch (cause) {
    throw new Error(`MusicBrainz response was unreadable: ${cause instanceof Error ? cause.message : cause}`);
  }
}
function mbId(id: string, prefix: string): string {
  const found = id.startsWith(prefix) ? safeMbid(id.slice(prefix.length)) : undefined;
  if (!found) throw new Error("Invalid MusicBrainz identity");
  return found;
}
function mbCredit(entry: Record<string, unknown>, fallback: string): string {
  const credits = Array.isArray(entry["artist-credit"]) ? (entry["artist-credit"] as Record<string, unknown>[]) : [];
  const joined = credits.map((c) => `${typeof c.name === "string" ? c.name : typeof (c.artist as Record<string, unknown> | undefined)?.name === "string" ? (c.artist as Record<string, unknown>).name : ""}${typeof c.joinphrase === "string" ? c.joinphrase : ""}`).join("");
  return joined.trim() ? joined : fallback;
}
function mbRecording(entry: Record<string, unknown>, fallback: string): MusicTrack | undefined {
  const id = safeMbid(entry.id);
  const title = typeof entry.title === "string" ? entry.title.trim() : "";
  if (!id || !title) return undefined;
  const seconds = Math.floor((num(entry.length) ?? 0) / 1000);
  return { id: `musicbrainz:recording:${id}`, connectorId: "catalog", sourceId: id, title, artist: mbCredit(entry, fallback), artwork: "", durationSeconds: seconds, durationLabel: durationLabel(seconds) };
}
export const musicbrainz = {
  albumTracks: async (album: MusicAlbumRef): Promise<MusicTrack[]> => {
    let release: string;
    if (album.id.startsWith("musicbrainz:release:")) release = mbId(album.id, "musicbrainz:release:");
    else {
      const group = mbId(album.id, "musicbrainz:release-group:");
      const data = await mbFetch(`release?release-group=${group}&status=official&limit=1`);
      const first = safeMbid(((data.releases as Record<string, unknown>[] | undefined) ?? [])[0]?.id);
      if (!first) throw new Error("MusicBrainz has no published edition for this release");
      release = first;
    }
    const data = await mbFetch(`release/${release}?inc=recordings+artist-credits`);
    const tracks: MusicTrack[] = [];
    for (const medium of (data.media as Record<string, unknown>[] | undefined) ?? []) {
      for (const entry of (medium.tracks as Record<string, unknown>[] | undefined) ?? []) {
        const track = mbRecording((entry.recording as Record<string, unknown>) ?? {}, album.artist);
        if (!track) continue;
        // The release-track identity keeps a recording repeated on two discs distinct.
        const trackId = safeMbid(entry.id);
        if (trackId) track.id = `musicbrainz:track:${trackId}`;
        if (typeof entry.title === "string" && entry.title.trim()) track.title = entry.title;
        tracks.push({ ...track, album: album.title, artwork: album.artwork });
      }
    }
    return tracks;
  },
  artistTracks: async (artist: MusicArtistRef): Promise<MusicTrack[]> => {
    const id = mbId(artist.id, "musicbrainz:artist:");
    const data = await mbFetch(`recording?artist=${id}&limit=50&inc=artist-credits`);
    return ((data.recordings as Record<string, unknown>[] | undefined) ?? []).map((e) => mbRecording(e, artist.name)).filter((t): t is MusicTrack => !!t);
  },
  artistAlbums: async (artist: MusicArtistRef): Promise<MusicAlbumRef[]> => {
    const id = mbId(artist.id, "musicbrainz:artist:");
    const data = await mbFetch(`release-group?artist=${id}&type=album|ep&limit=50`);
    const out: MusicAlbumRef[] = [];
    for (const entry of (data["release-groups"] as Record<string, unknown>[] | undefined) ?? []) {
      const group = safeMbid(entry.id);
      if (!group || typeof entry.title !== "string") continue;
      out.push({ id: `musicbrainz:release-group:${group}`, connectorId: "catalog", title: entry.title, artist: artist.name, artwork: `https://coverartarchive.org/release-group/${group}/front-500`, year: catalogYear(entry["first-release-date"]) });
    }
    return out;
  },
};

function settle<T>(provider: string, work: Promise<T>): Promise<T> {
  return withTimeout(work, PROVIDER_TIMEOUT, `${provider} timed out`);
}

function catalogConnector(): Connector {
  const self: Connector = {
    id: "catalog",
    name: "Open catalog",
    kind: "catalog",
    searchable: true,
    playable: false,
    browsable: true,
    health: "unknown",
    ready: () => true,
    search: async () => [],
    resolve: async () => {
      throw unsupported("catalog", "playback");
    },
    // catalog/mod.rs home_rows: ListenBrainz fresh releases, the Deezer charts and editorial,
    // with ListenBrainz's sitewide artist chart standing in when Deezer's artist chart fails.
    browseHome: () =>
      record(
        (async () => {
          const [releases, tracks, albums, artists, editorial] = await Promise.allSettled([
            settle("ListenBrainz", listenbrainz.freshReleases(CATALOG_ROW_LIMIT)),
            settle("Deezer", deezer.chartTracks(CATALOG_ROW_LIMIT)),
            settle("Deezer", deezer.chartAlbums(CATALOG_ROW_LIMIT)),
            settle("Deezer", deezer.chartArtists(CATALOG_ROW_LIMIT)),
            settle("Deezer", deezer.editorial(CATALOG_ROW_LIMIT)),
          ]);
          const rows: MusicCatalogRow[] = [];
          const failures: string[] = [];
          const take = <T>(r: PromiseSettledResult<T[]>, build: (v: T[]) => MusicCatalogRow) => {
            if (r.status === "rejected") failures.push(String(r.reason instanceof Error ? r.reason.message : r.reason));
            else if (r.value.length) rows.push(build(r.value));
          };
          take(releases, (v) => row("catalog:new-releases", "music.row.newReleases", false, "Fresh releases from ListenBrainz", "covers", "catalog", albumItems(v)));
          take(tracks, (v) => row("catalog:charts:tracks", "Top tracks", true, "Track chart from Deezer", "trackGrid", "catalog", trackItems(v)));
          take(albums, (v) => row("catalog:charts", "music.row.charts", false, "Album chart from Deezer", "covers", "catalog", albumItems(v)));
          if (artists.status === "fulfilled" && artists.value.length) {
            rows.push(row("catalog:charting-artists", "Charting artists", true, "Artist chart from Deezer", "circles", "catalog", artistItems(artists.value)));
          } else {
            // The Rust starts both requests together; the TV asks ListenBrainz only when needed.
            if (artists.status === "rejected") failures.push(String(artists.reason instanceof Error ? artists.reason.message : artists.reason));
            const popular = await settle("ListenBrainz", listenbrainz.topArtists(CATALOG_ROW_LIMIT)).then(
              (value) => ({ status: "fulfilled", value }) as const,
              (reason) => ({ status: "rejected", reason }) as const,
            );
            take(popular, (v) => row("catalog:charting-artists", "Charting artists", true, "Most played on ListenBrainz this month", "circles", "catalog", artistItems(v)));
          }
          take(editorial, (v) => row("catalog:editorial", "Editorial selection", true, "Selected by the Deezer editors", "covers", "catalog", albumItems(v)));
          if (!rows.length) throw new Error(failures.length ? [...new Set(failures)].sort().join("; ") : "The open catalog has nothing to show right now");
          return rows;
        })(),
      ),
    // catalog/mod.rs search_catalog: iTunes albums + songs, Deezer artists with iTunes fallback.
    searchTyped: (query, limit) =>
      record(
        (async () => {
          const [albums, artistsFirst, tracks] = await Promise.allSettled([
            settle("iTunes", itunes.albums(query, limit)),
            settle("Deezer", deezer.searchArtists(query, limit)),
            settle("iTunes", itunes.songs(query, limit)),
          ]);
          let artists = artistsFirst;
          if (artists.status === "rejected" || artists.value.length === 0) {
            artists = await settle("iTunes", itunes.artists(query, limit)).then(
              (value) => ({ status: "fulfilled", value }) as const,
              (reason) => ({ status: "rejected", reason }) as const,
            );
          }
          if (albums.status === "rejected" && artists.status === "rejected" && tracks.status === "rejected") {
            throw new Error([albums.reason, artists.reason, tracks.reason].map((e) => (e instanceof Error ? e.message : String(e))).join("; "));
          }
          return {
            tracks: tracks.status === "fulfilled" ? tracks.value : [],
            albums: albums.status === "fulfilled" ? albums.value : [],
            artists: artists.status === "fulfilled" ? artists.value : [],
            playlists: [],
          };
        })(),
      ),
    albumTracks: (album) =>
      record(
        album.id.startsWith("deezer:album:")
          ? settle("Deezer", deezer.albumTracks(album.id))
          : album.id.startsWith("itunes:album:")
            ? settle("iTunes", itunes.tracks(album.id, "itunes:album:"))
            : album.id.startsWith("musicbrainz:")
              ? settle("MusicBrainz", musicbrainz.albumTracks(album))
              : Promise.reject(new Error("This catalog has not supplied a track list for this release")),
      ),
    artistTop: (artist) =>
      record(
        artist.id.startsWith("deezer:artist:")
          ? settle("Deezer", deezer.artistTop(artist.id))
          : artist.id.startsWith("itunes:artist:")
            ? settle("iTunes", itunes.tracks(artist.id, "itunes:artist:"))
            : artist.id.startsWith("musicbrainz:artist:")
              ? settle("MusicBrainz", musicbrainz.artistTracks(artist))
              : Promise.reject(new Error("This catalog has not supplied tracks for this artist")),
      ),
    artistRows: async (artist) => {
      const rows: MusicCatalogRow[] = [];
      if (artist.id.startsWith("deezer:artist:")) {
        const [albums, related] = await Promise.allSettled([settle("Deezer", deezer.artistAlbums(artist)), settle("Deezer", deezer.relatedArtists(artist.id))]);
        if (albums.status === "rejected" && related.status === "rejected") throw new Error("Artist discovery could not load from Deezer");
        if (albums.status === "fulfilled" && albums.value.length) rows.push(row("artist:albums", "music.search.albums", false, "Deezer", "covers", "catalog", albumItems(albums.value)));
        if (related.status === "fulfilled" && related.value.length) rows.push(row("artist:related", "music.detail.relatedArtists", false, "Deezer", "circles", "catalog", artistItems(related.value)));
      } else if (artist.id.startsWith("itunes:artist:")) {
        const albums = await settle("iTunes", itunes.artistAlbums(artist.id));
        if (albums.length) rows.push(row("artist:albums", "music.search.albums", false, "Apple Music", "covers", "catalog", albumItems(albums)));
      } else if (artist.id.startsWith("musicbrainz:artist:")) {
        const albums = await settle("MusicBrainz", musicbrainz.artistAlbums(artist));
        if (albums.length) rows.push(row("artist:albums", "music.search.albums", false, "MusicBrainz", "covers", "catalog", albumItems(albums)));
      }
      return rows;
    },
    playlistTracks: async () => {
      throw unsupported("catalog", "playlists");
    },
    stationTracks: async () => {
      throw unsupported("catalog", "stations");
    },
  };
  const record = recorder(self);
  return self;
}

// ============================================================================== SoundCloud
// connectors/soundcloud/{identity,client,fetch,parse,stream,browse,mod}.rs
const SC_API = "https://api-v2.soundcloud.com";
const SC_HOME = "https://soundcloud.com/";
const SC_UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36";
const SC_CACHE_KEY = "harbor.music.soundcloud-client-id";
const SC_SYSTEM_PLAYLIST = "soundcloud:system-playlists:";
const SC_PAGE_LIMIT = 50;

// identity.rs: the public web app publishes a client id inside one of its script bundles.
let scClientId: string | null = null;
let scScrape: Promise<string> | null = null;
function scCached(): string | null {
  if (scClientId) return scClientId;
  try {
    const stored = localStorage.getItem(SC_CACHE_KEY)?.trim();
    if (stored && stored.length === 32) scClientId = stored;
  } catch {
    /* optional cache */
  }
  return scClientId;
}
export function soundcloudBundles(html: string): string[] {
  const urls: string[] = [];
  for (const match of html.matchAll(/https:\/\/a-v2\.sndcdn\.com\/assets\/[A-Za-z0-9._~/-]+\.js/g)) {
    if (!urls.includes(match[0])) urls.push(match[0]);
  }
  return urls.reverse().slice(0, 6);
}
export function soundcloudIdFromBundle(body: string): string | null {
  return /client_id\s*:\s*"([0-9a-zA-Z]{32})"/.exec(body)?.[1] ?? null;
}
async function scWalkWebApp(): Promise<string> {
  const page = await request(SC_HOME, { headers: { "User-Agent": SC_UA }, timeoutMs: 2000 });
  const bundles = soundcloudBundles(page.text);
  const missing = new Error("SoundCloud did not publish a usable client id");
  if (!bundles.length) throw missing;
  // first_id: whichever bundle answers with an id first wins.
  return new Promise<string>((resolve, reject) => {
    let left = bundles.length;
    for (const url of bundles) {
      request(url, { headers: { "User-Agent": SC_UA, Range: "bytes=0-50000" }, timeoutMs: 2000 })
        .then((res) => soundcloudIdFromBundle(res.text))
        .catch(() => null)
        .then((found) => {
          if (found) resolve(found);
          else if (--left === 0) reject(missing);
        });
    }
  });
}
async function scEnsure(): Promise<string> {
  const held = scCached();
  if (held) return held;
  if (!scScrape) {
    scScrape = withTimeout(scWalkWebApp(), 5000, "SoundCloud timed out while publishing a client id")
      .then((id) => {
        scClientId = id;
        try {
          localStorage.setItem(SC_CACHE_KEY, id);
        } catch {
          /* optional cache */
        }
        return id;
      })
      .finally(() => {
        scScrape = null;
      });
  }
  return scScrape;
}
function scInvalidate(stale: string): void {
  if (scClientId !== stale) return;
  scClientId = null;
  try {
    localStorage.removeItem(SC_CACHE_KEY);
  } catch {
    /* optional cache */
  }
}

// client.rs
function scSafeApiUrl(raw: string): string {
  let parsed: URL;
  try {
    parsed = new URL(raw.trim());
  } catch {
    throw new Error("Invalid SoundCloud request");
  }
  if (parsed.protocol !== "https:" || parsed.hostname.toLowerCase() !== "api-v2.soundcloud.com") throw new Error("Invalid SoundCloud request");
  return parsed.toString();
}
export function soundcloudSafeMediaUrl(raw: string): string {
  let parsed: URL;
  try {
    parsed = new URL(raw.trim());
  } catch {
    throw new Error("SoundCloud returned an unusable stream URL");
  }
  const host = parsed.hostname.toLowerCase();
  const known = host.endsWith(".sndcdn.com") || host.endsWith(".soundcloud.com") || host.endsWith(".soundcloud.cloud");
  if (parsed.protocol !== "https:" || !known) throw new Error("SoundCloud returned an unusable stream URL");
  return parsed.toString();
}
async function scGetUrl(url: string, params: Record<string, string> = {}): Promise<Record<string, unknown>> {
  const safe = scSafeApiUrl(url);
  const attempt = async (id: string) => {
    const target = new URL(safe);
    for (const [k, v] of Object.entries(params)) target.searchParams.append(k, v);
    target.searchParams.append("client_id", id);
    const res = await request(target.toString(), { headers: { "User-Agent": SC_UA, Accept: "application/json" }, timeoutMs: 8000 });
    if (res.status === 401 || res.status === 403) return "unauthorized" as const;
    if (res.status < 200 || res.status >= 300) throw new Error(`SoundCloud returned HTTP ${res.status}`);
    try {
      return JSON.parse(res.text) as Record<string, unknown>;
    } catch {
      throw new Error("SoundCloud response was invalid");
    }
  };
  const issued = await scEnsure();
  const first = await attempt(issued);
  if (first !== "unauthorized") return first;
  scInvalidate(issued);
  const second = await attempt(await scEnsure());
  if (second === "unauthorized") throw new Error("SoundCloud rejected the request");
  return second;
}
const scGet = (path: string, params: Record<string, string> = {}) => scGetUrl(`${SC_API}${path}`, params);

// parse.rs
type ScTrack = Record<string, unknown>;
function scPlayable(track: ScTrack): boolean {
  const policy = (text(track.policy) ?? "ALLOW").toUpperCase();
  return track.streamable !== false && (policy === "ALLOW" || policy === "MONETIZE");
}
const scUpgrade = (url: string) => url.replace("-large.jpg", "-t500x500.jpg");
export function soundcloudTrack(track: ScTrack): MusicTrack | undefined {
  const sourceId = num(track.id);
  const title = text(track.title);
  if (!sourceId || !title) return undefined;
  const user = track.user as Record<string, unknown> | undefined;
  const publisher = track.publisher_metadata as Record<string, unknown> | undefined;
  const artist = text(publisher?.artist) ?? text(user?.username) ?? "Unknown artist";
  const seconds = Math.floor((num(track.full_duration) ?? num(track.duration) ?? 0) / 1000);
  const art = text(track.artwork_url) ?? text(user?.avatar_url);
  return { id: `soundcloud:${sourceId}`, connectorId: "soundcloud", sourceId: String(sourceId), title, artist, album: text(publisher?.album_title), artwork: art ? scUpgrade(art) : "", durationSeconds: seconds, durationLabel: durationLabel(seconds) };
}
const scTracks = (list: ScTrack[]) => list.filter(scPlayable).map(soundcloudTrack).filter((t): t is MusicTrack => !!t);
function scArtist(user: Record<string, unknown>): MusicArtistRef | undefined {
  const id = num(user.id);
  const name = text(user.username);
  if (!id || !name) return undefined;
  const art = text(user.avatar_url);
  return { id: String(id), connectorId: "soundcloud", name, artwork: art ? scUpgrade(art) : undefined };
}
function scPlaylistId(playlist: Record<string, unknown>): string | undefined {
  const urn = text(playlist.urn);
  if (urn?.startsWith(SC_SYSTEM_PLAYLIST)) return urn;
  const id = num(playlist.id);
  return id ? String(id) : undefined;
}
function scPlaylist(playlist: Record<string, unknown>): MusicPlaylistRef | undefined {
  const id = scPlaylistId(playlist);
  const name = text(playlist.title);
  if (!id || !name) return undefined;
  const artwork: string[] = [];
  const add = (url: unknown) => {
    const u = text(url);
    if (!u || artwork.length >= 4) return;
    const up = scUpgrade(u);
    if (!artwork.includes(up)) artwork.push(up);
  };
  add(playlist.artwork_url);
  add(playlist.calculated_artwork_url);
  for (const t of (playlist.tracks as ScTrack[] | undefined) ?? []) add(t.artwork_url);
  return { id, connectorId: "soundcloud", name, artwork, trackCount: num(playlist.track_count), subtitle: text((playlist.user as Record<string, unknown> | undefined)?.username) };
}
function scNumericId(raw: string): number | undefined {
  const tail = raw.trim().split(":").pop() ?? "";
  return /^\d+$/.test(tail) ? Number(tail) : undefined;
}

// fetch.rs
async function scCollection(path: string, query: string, limit: number): Promise<Record<string, unknown>[]> {
  const body = await scGet(path, { q: query.trim(), limit: String(Math.min(SC_PAGE_LIMIT, Math.max(1, limit))), offset: "0", linked_partitioning: "1" });
  return Array.isArray(body.collection) ? (body.collection as Record<string, unknown>[]) : [];
}
async function scTracksByIds(ids: number[]): Promise<ScTrack[]> {
  if (!ids.length) return [];
  const value = (await scGet("/tracks", { ids: ids.join(",") })) as unknown;
  return Array.isArray(value) ? (value as ScTrack[]) : [];
}
async function scPlaylistById(id: string): Promise<Record<string, unknown>> {
  const trimmed = id.trim();
  if (trimmed.startsWith(SC_SYSTEM_PLAYLIST) && /^[A-Za-z0-9:_-]+$/.test(trimmed)) return scGet(`/system-playlists/${trimmed}`);
  const numeric = scNumericId(id);
  if (!numeric) throw new Error("SoundCloud playlist id is invalid");
  return scGet(`/playlists/${numeric}`);
}
/** fetch.rs hydrate: playlist entries past the first few arrive as bare ids. */
async function scHydrate(tracks: ScTrack[], limit: number): Promise<MusicTrack[]> {
  const head = tracks.slice(0, limit);
  const shallow = head.filter((t) => t.title == null || t.media == null).map((t) => num(t.id)).filter((id): id is number => !!id);
  if (!shallow.length) return scTracks(head);
  const fetched: ScTrack[] = [];
  for (let i = 0; i < shallow.length; i += 50) fetched.push(...(await scTracksByIds(shallow.slice(i, i + 50))));
  const byId = new Map(fetched.map((t) => [num(t.id), t] as const));
  return scTracks(head.map((t) => byId.get(num(t.id)) ?? t));
}
async function scTrackFor(track: MusicTrack): Promise<ScTrack> {
  const id = scNumericId(track.id.replace(/^soundcloud:/, "")) ?? scNumericId(track.sourceId ?? "");
  if (!id) throw new Error("SoundCloud could not find this track");
  const found = await scTracksByIds([id]);
  if (!found.length) throw new Error("SoundCloud could not find this track");
  return found[0]!;
}

// stream.rs select_transcoding, with one tvOS rule on top: AVPlayer has no Opus/Ogg decoder,
// so an ogg transcoding is never picked here (upstream's mpv plays it).
type ScTranscoding = { url?: string; preset?: string; snipped?: boolean; format?: { protocol?: string; mime_type?: string } };
function presetBitrate(preset: string): number {
  for (const segment of preset.split(/[_-]/)) {
    const m = /^(\d+)k$/.exec(segment);
    if (m) return Number(m[1]) * 1000;
  }
  return 0;
}
export function soundcloudSelect(transcodings: ScTranscoding[]): ScTranscoding | undefined {
  let best: { score: number; t: ScTranscoding } | undefined;
  for (const t of transcodings) {
    if (!(t.url ?? "").trim()) continue;
    const protocol = (t.format?.protocol ?? "").toLowerCase();
    if (protocol.startsWith("ctr-") || protocol.startsWith("cbc-") || protocol.includes("encrypted")) continue;
    const preset = (t.preset ?? "").toLowerCase();
    if (preset.startsWith("abr")) continue;
    const mime = (t.format?.mime_type ?? "").toLowerCase();
    if (mime.includes("ogg") || mime.includes("opus") || preset.startsWith("opus")) continue;
    let score = protocol === "progressive" ? 4000 : protocol === "hls" ? 2000 : NaN;
    if (Number.isNaN(score)) continue;
    score += Math.floor(presetBitrate(preset) / 1000);
    if (t.snipped) score -= 8000;
    if (!best || score > best.score) best = { score, t };
  }
  return best?.t;
}
async function scResolve(track: MusicTrack): Promise<MusicStream> {
  const source = await scTrackFor(track);
  if (!scPlayable(source)) throw new Error("SoundCloud does not allow playback of this track");
  const media = source.media as { transcodings?: ScTranscoding[] } | undefined;
  const selected = soundcloudSelect(media?.transcodings ?? []);
  if (!selected) throw new Error("SoundCloud did not offer a playable stream");
  if (selected.snipped) throw new Error("SoundCloud only offers a preview of this track");
  const auth = text(source.track_authorization);
  const payload = await scGetUrl(selected.url!, auth ? { track_authorization: auth } : {});
  const signed = text(payload.url);
  if (!signed) throw new Error("SoundCloud did not return a stream URL");
  const protocol = (selected.format?.protocol ?? "").toLowerCase();
  const mime = protocol === "hls" ? "application/vnd.apple.mpegurl" : (selected.format?.mime_type ?? "").split(";")[0]!.trim() || "audio/mpeg";
  return { url: soundcloudSafeMediaUrl(signed), mimeType: mime, bitrate: presetBitrate(selected.preset ?? "") };
}

// browse.rs home
async function scHome(): Promise<MusicCatalogRow[]> {
  const body = await scGet("/mixed-selections");
  const selections = (Array.isArray(body.collection) ? body.collection : []) as Record<string, unknown>[];
  const rows: MusicCatalogRow[] = [];
  const playlistsOf = (s: Record<string, unknown>) => {
    const items = s.items as { collection?: Record<string, unknown>[] } | undefined;
    return Array.isArray(items?.collection) ? items!.collection! : [];
  };
  const trending = async (): Promise<MusicCatalogRow | null> => {
    const ordered = [...selections.filter((s) => (text(s.urn) ?? "").includes("trending")), ...selections];
    const urn = ordered.flatMap(playlistsOf).map((p) => text(p.urn)).find((u) => u?.startsWith(SC_SYSTEM_PLAYLIST));
    if (!urn) return null;
    const playlist = await scPlaylistById(urn);
    const title = text(playlist.title);
    if (!title) return null;
    const tracks = await scHydrate((playlist.tracks as ScTrack[] | undefined) ?? [], 18);
    return tracks.length ? row("soundcloud:home:trending", title, true, undefined, "trackGrid", "soundcloud", trackItems(tracks)) : null;
  };
  const top = await withTimeout(trending(), 3000, "trending").catch(() => null);
  if (top) rows.push(top);
  for (const selection of selections.slice(0, 6)) {
    const urn = text(selection.urn);
    const title = text(selection.title);
    if (!urn || !title) continue;
    const items = playlistsOf(selection).map(scPlaylist).filter((p): p is MusicPlaylistRef => !!p).slice(0, 12);
    if (!items.length) continue;
    const slug = urn.replace(/^soundcloud:selections:/, "").replace(/[^A-Za-z0-9]/g, "-").toLowerCase();
    rows.push(row(`soundcloud:selection:${slug}`, title, true, text(selection.description), "covers", "soundcloud", playlistItems(items)));
  }
  if (!rows.length) throw new Error("SoundCloud did not return anything to browse");
  return rows;
}

function soundcloudConnector(): Connector {
  const self: Connector = {
    id: "soundcloud",
    name: "SoundCloud",
    kind: "streaming",
    searchable: true,
    playable: true,
    browsable: true,
    health: "unknown",
    // source-consent.ts: a gated source stays silent until the listener turns it on.
    ready: () => musicSourceAllowed("soundcloud"),
    search: (query, limit) => record(scCollection("/search/tracks", query, limit).then((found) => scTracks(found).slice(0, limit))),
    searchTyped: (query, limit) =>
      record(
        (async () => {
          const side = Math.min(limit, 12);
          const [found, users, lists] = await Promise.allSettled([scCollection("/search/tracks", query, limit), scCollection("/search/users", query, side), scCollection("/search/playlists", query, side)]);
          if (found.status === "rejected") throw found.reason;
          const tracks = scTracks(found.value).slice(0, limit);
          return {
            top: tracks[0] ? { kind: "track" as const, ...tracks[0] } : undefined,
            tracks,
            albums: [],
            artists: users.status === "fulfilled" ? users.value.map(scArtist).filter((a): a is MusicArtistRef => !!a) : [],
            playlists: lists.status === "fulfilled" ? lists.value.map(scPlaylist).filter((p): p is MusicPlaylistRef => !!p) : [],
          };
        })(),
      ),
    // mod.rs browse_home: no client id yet means warm it and show nothing this time.
    browseHome: async () => {
      if (!scCached()) {
        void scEnsure().catch(() => undefined);
        return [];
      }
      return record(scHome());
    },
    resolve: (track) => record(scResolve(track)),
    playlistTracks: (playlist) => record(scPlaylistById(playlist.id).then((p) => scHydrate((p.tracks as ScTrack[] | undefined) ?? [], 100))),
    artistTop: (artist) =>
      record(
        (async () => {
          const user = scNumericId(artist.id);
          if (!user) throw new Error("SoundCloud artist id is invalid");
          const body = await scGet(`/users/${user}/tracks`, { limit: "20", linked_partitioning: "1" });
          return scTracks((body.collection as ScTrack[] | undefined) ?? []);
        })(),
      ),
    albumTracks: async () => {
      throw unsupported("soundcloud", "albums");
    },
    artistRows: async () => [],
    stationTracks: async () => {
      throw unsupported("soundcloud", "stations");
    },
  };
  const record = recorder(self);
  return self;
}

// ================================================================================ Jellyfin
// connectors/jellyfin/*.rs. config.rs adopt(): the music connector reuses the first Jellyfin
// connection the video side already signed in with, with the shared device id "harbor".
type JellyfinConfig = { origin: string; userId: string; token: string; deviceId: string; serverName: string };
type JfItem = Record<string, unknown> & { Id?: string; Name?: string; Type?: string };

function jellyfinConfig(): JellyfinConfig | null {
  for (const c of mediaServerConnections()) {
    if (c.provider !== "jellyfin" || c.enabled === false || !c.userId) continue;
    const token = mediaServerToken(c);
    if (!token) continue;
    return { origin: c.origin.replace(/\/+$/, ""), userId: c.userId, token, deviceId: "harbor", serverName: c.name };
  }
  return null;
}
function jfAuthorization(config: JellyfinConfig): string {
  return `MediaBrowser Client="Harbor", Device="Harbor Music", DeviceId="${config.deviceId}", Version="1", Token="${config.token}"`;
}
async function jfDispatch(config: JellyfinConfig, method: "GET" | "POST", path: string, params: Record<string, string> = {}, body?: unknown): Promise<unknown> {
  const url = new URL(`${config.origin}${path}`);
  for (const [k, v] of Object.entries(params)) url.searchParams.append(k, v);
  for (let attempt = 0; ; attempt++) {
    const res = await request(url.toString(), {
      method,
      headers: { Accept: "application/json", Authorization: jfAuthorization(config), ...(body !== undefined ? { "Content-Type": "application/json" } : {}) },
      body: body !== undefined ? JSON.stringify(body) : undefined,
      timeoutMs: 20000,
    });
    if (res.status === 503 && attempt === 0) {
      const wait = Math.min(4, Number(res.headers.get("retry-after")) || 4);
      await new Promise((r) => setTimeout(r, wait * 1000));
      continue;
    }
    if (res.status === 401 || res.status === 403) throw new Error("Jellyfin rejected the saved sign in");
    if (res.status < 200 || res.status >= 300) throw new Error(`Jellyfin returned ${res.status}`);
    if (!res.text.trim()) return null;
    try {
      return JSON.parse(res.text);
    } catch {
      throw new Error("Jellyfin response was unreadable");
    }
  }
}
async function jfList(config: JellyfinConfig, path: string, params: Record<string, string>): Promise<JfItem[]> {
  const page = (await jfDispatch(config, "GET", path, params)) as { Items?: JfItem[] } | null;
  return Array.isArray(page?.Items) ? page!.Items! : [];
}
function jfSafeId(value: string): string {
  const trimmed = value.replace(/^jellyfin:/, "").trim();
  if (!trimmed || trimmed.length > 64 || !/^[A-Za-z0-9-]+$/.test(trimmed)) throw new Error("Jellyfin item is not addressable");
  return trimmed;
}
// items.rs
function jfArtist(item: JfItem): string {
  const first = ((item.Artists as string[] | undefined) ?? []).map((a) => a?.trim()).find((a) => a);
  return first ?? text(item.AlbumArtist) ?? "Unknown artist";
}
function jfArtwork(origin: string, item: JfItem): string {
  const tags = (item.ImageTags as Record<string, string> | undefined) ?? {};
  let pair: [string, string] | undefined;
  if (tags.Primary && item.Id) pair = [item.Id, tags.Primary];
  else if (text(item.AlbumId) && text(item.AlbumPrimaryImageTag)) pair = [String(item.AlbumId), String(item.AlbumPrimaryImageTag)];
  else if (text(item.ParentPrimaryImageItemId) && text(item.ParentPrimaryImageTag)) pair = [String(item.ParentPrimaryImageItemId), String(item.ParentPrimaryImageTag)];
  if (!pair) return "";
  const params = new URLSearchParams({ fillHeight: "400", fillWidth: "400", quality: "90", format: "Jpg", tag: pair[1] });
  // Upstream asks for Webp; tvOS UIImage decodes JPEG everywhere, so the TV asks for Jpg.
  return `${origin}/Items/${pair[0]}/Images/Primary?${params}`;
}
function jfNamed(item: JfItem): string | undefined {
  return item.Id ? text(item.Name) : undefined;
}
function jfCount(item: JfItem): number | undefined {
  const n = num(item.ChildCount) ?? 0;
  return n > 0 ? n : undefined;
}
function jfTrack(origin: string, item: JfItem): MusicTrack | undefined {
  const title = jfNamed(item);
  if (!title) return undefined;
  const seconds = Math.floor(Math.max(0, num(item.RunTimeTicks) ?? 0) / 10_000_000);
  return { id: `jellyfin:${item.Id}`, connectorId: "jellyfin", sourceId: item.Id, title, artist: jfArtist(item), album: text(item.Album), artwork: jfArtwork(origin, item), durationSeconds: seconds, durationLabel: durationLabel(seconds) };
}
function jfAlbum(origin: string, item: JfItem): MusicAlbumRef | undefined {
  const title = jfNamed(item);
  if (!title) return undefined;
  const named = text(item.AlbumArtist);
  return { id: item.Id!, connectorId: "jellyfin", title, artist: named ?? jfArtist(item), artwork: jfArtwork(origin, item), year: num(item.ProductionYear), trackCount: jfCount(item) };
}
function jfArtistRef(origin: string, item: JfItem): MusicArtistRef | undefined {
  const name = jfNamed(item);
  if (!name) return undefined;
  const art = jfArtwork(origin, item);
  return { id: item.Id!, connectorId: "jellyfin", name, artwork: art || undefined };
}
function jfPlaylist(origin: string, item: JfItem): MusicPlaylistRef | undefined {
  const name = jfNamed(item);
  if (!name) return undefined;
  const art = jfArtwork(origin, item);
  return { id: item.Id!, connectorId: "jellyfin", name, artwork: art ? [art] : [], trackCount: jfCount(item) };
}
function jfStation(origin: string, item: JfItem): MusicStationRef | undefined {
  const name = jfNamed(item);
  if (!name) return undefined;
  return { id: item.Id!, connectorId: "jellyfin", name, artwork: jfArtwork(origin, item) };
}
const defined = <T>(v: T | undefined): v is T => v !== undefined;
// browse.rs
const JF_ALBUM_FIELDS = "ChildCount,ProductionYear,DateCreated";
function jfBase(config: JellyfinConfig): Record<string, string> {
  return { userId: config.userId, recursive: "true", enableTotalRecordCount: "false" };
}
let jfLibrary: { key: string; id: string | null } | null = null;
async function jfMusicLibrary(config: JellyfinConfig): Promise<string | null> {
  const key = `${config.origin}|${config.userId}`;
  if (jfLibrary?.key === key) return jfLibrary.id;
  const views = await jfList(config, "/UserViews", { userId: config.userId, includeExternalContent: "false" }).catch(() => []);
  const id = views.find((v) => v.CollectionType === "music")?.Id ?? null;
  jfLibrary = { key, id };
  return id;
}
async function jfHome(config: JellyfinConfig): Promise<MusicCatalogRow[]> {
  const library = await jfMusicLibrary(config);
  const scoped = { ...jfBase(config), ...(library ? { parentId: library } : {}) };
  const [albums, lists, favourites, artists] = await Promise.allSettled([
    jfList(config, "/Items", { ...scoped, includeItemTypes: "MusicAlbum", sortBy: "DateCreated", sortOrder: "Descending", limit: "24", fields: JF_ALBUM_FIELDS }),
    jfList(config, "/Items", { ...jfBase(config), includeItemTypes: "Playlist", mediaTypes: "Audio", sortBy: "SortName", limit: "24", fields: "ChildCount" }),
    jfList(config, "/Items", { ...scoped, includeItemTypes: "Audio", filters: "IsFavorite", sortBy: "SortName", limit: "18" }),
    jfList(config, "/Items", { ...scoped, includeItemTypes: "MusicArtist", filters: "IsFavorite", sortBy: "SortName", limit: "12" }),
  ]);
  if (albums.status === "rejected") throw albums.reason;
  const o = config.origin;
  const subtitle = config.serverName || undefined;
  let seeds = artists.status === "fulfilled" ? artists.value : [];
  if (!seeds.length) seeds = albums.value.slice(0, 8);
  const rows: MusicCatalogRow[] = [];
  const push = (id: string, title: string, layout: MusicRowLayout, items: MusicCatalogItem[]) => {
    if (items.length) rows.push(row(id, title, false, subtitle, layout, "jellyfin", items));
  };
  push("jellyfin:home:recent", "music.row.server", "covers", albumItems(albums.value.map((i) => jfAlbum(o, i)).filter(defined)));
  push("jellyfin:home:stations", "music.row.stations", "covers", stationItems(seeds.map((i) => jfStation(o, i)).filter(defined)));
  push("jellyfin:home:playlists", "music.row.playlists", "covers", playlistItems((lists.status === "fulfilled" ? lists.value : []).map((i) => jfPlaylist(o, i)).filter(defined)));
  push("jellyfin:home:favourites", "music.row.liked", "trackGrid", trackItems((favourites.status === "fulfilled" ? favourites.value : []).map((i) => jfTrack(o, i)).filter(defined)));
  return rows;
}
// stream.rs: containers the client plays as-is. Upstream lists what mpv plays; AVPlayer has no
// Ogg/Opus/WebM/Matroska/WavPack decoder, so those are left for the server to transcode to mp3.
const JF_DIRECT = "flac,alac,m4a,m4b,aac,mp3,wav,aiff";
const JF_UNIVERSAL = "flac,mp3,aac,m4a|aac,alac,m4a|alac,m4b|aac,wav,aiff";
async function jfResolve(config: JellyfinConfig, track: MusicTrack): Promise<MusicStream> {
  const itemId = jfSafeId(track.sourceId ?? track.id);
  const info = (await jfDispatch(config, "POST", `/Items/${itemId}/PlaybackInfo`, { userId: config.userId }, {
    UserId: config.userId,
    MaxStreamingBitrate: 320000,
    EnableDirectPlay: true,
    EnableDirectStream: true,
    EnableTranscoding: true,
    DeviceProfile: {
      Name: "Harbor Music",
      DirectPlayProfiles: [{ Type: "Audio", Container: JF_DIRECT }],
      MaxStreamingBitrate: 320000,
      MaxStaticBitrate: 320000,
      MusicStreamingTranscodingBitrate: 320000,
      TranscodingProfiles: [{ Type: "Audio", Container: "mp3", AudioCodec: "mp3", Protocol: "http", Context: "Streaming" }],
      CodecProfiles: [],
      SubtitleProfiles: [],
    },
  })) as { MediaSources?: Record<string, unknown>[]; PlaySessionId?: string } | null;
  const source = info?.MediaSources?.[0] ?? {};
  const container = (text(source.Container) ?? "").toLowerCase();
  const direct = (source.SupportsDirectPlay === true || source.SupportsDirectStream === true) && JF_DIRECT.split(",").includes(container);
  const session = text(info?.PlaySessionId) ?? itemId;
  const url = new URL(`${config.origin}/Audio/${itemId}/universal`);
  const params: Record<string, string> = {
    userId: config.userId, deviceId: config.deviceId, container: JF_UNIVERSAL, transcodingContainer: "mp3", transcodingProtocol: "http", audioCodec: "mp3",
    maxStreamingBitrate: "320000", startTimeTicks: "0", enableRedirection: "true", enableRemoteMedia: "false", enableAudioVbrEncoding: "true", playSessionId: session, ApiKey: config.token,
  };
  for (const [k, v] of Object.entries(params)) url.searchParams.append(k, v);
  const mime = !direct ? "audio/mpeg" : ({ flac: "audio/flac", mp3: "audio/mpeg", wav: "audio/wav", aiff: "audio/aiff" } as Record<string, string>)[container] ?? "audio/mp4";
  // mod.rs report(): the previous session is closed and this one announced; failures only log.
  const previous = jfSession;
  jfSession = { config, itemId, session, sourceId: text(source.Id) };
  if (previous) void jfReportStopped(previous).catch(() => undefined);
  void jfDispatch(config, "POST", "/Sessions/Playing", {}, { ItemId: itemId, PlaySessionId: session, CanSeek: true, IsPaused: false, PlayMethod: direct ? "DirectStream" : "Transcode", ...(jfSession.sourceId ? { MediaSourceId: jfSession.sourceId } : {}) }).catch(() => undefined);
  return { url: url.toString(), mimeType: mime, bitrate: direct ? Math.floor((num(source.Bitrate) ?? 0) / 1000) : 320 };
}
let jfSession: { config: JellyfinConfig; itemId: string; session: string; sourceId?: string } | null = null;
function jfReportStopped(s: NonNullable<typeof jfSession>): Promise<unknown> {
  return jfDispatch(s.config, "POST", "/Sessions/Playing/Stopped", {}, { ItemId: s.itemId, PlaySessionId: s.session, ...(s.sourceId ? { MediaSourceId: s.sourceId } : {}) });
}
/** The player stopped for good: close the open Jellyfin session. */
export function jellyfinStopped(): void {
  const s = jfSession;
  jfSession = null;
  if (s) void jfReportStopped(s).catch(() => undefined);
}

function jellyfinConnector(): Connector {
  const need = (): JellyfinConfig => {
    const c = jellyfinConfig();
    if (!c) throw new Error("Connect a Jellyfin server to play from it");
    return c;
  };
  const tracksOf = (c: JellyfinConfig, items: JfItem[]) => items.map((i) => jfTrack(c.origin, i)).filter(defined);
  const searchItems = (c: JellyfinConfig, query: string, limit: number, kinds: string) =>
    jfList(c, "/Items", { ...jfBase(c), searchTerm: query, includeItemTypes: kinds, limit: String(Math.min(limit, 60)), fields: JF_ALBUM_FIELDS });
  const self: Connector = {
    id: "jellyfin",
    name: "Jellyfin",
    kind: "server",
    searchable: true,
    playable: true,
    browsable: true,
    health: "unknown",
    ready: () => jellyfinConfig() !== null,
    detail: () => jellyfinConfig()?.serverName,
    search: (query, limit) => record((async () => { const c = need(); return tracksOf(c, await searchItems(c, query, limit, "Audio")).slice(0, limit); })()),
    searchTyped: (query, limit) =>
      record(
        (async () => {
          const c = need();
          const found = await searchItems(c, query, limit * 3, "Audio,MusicAlbum,MusicArtist,Playlist");
          const of = (type: string) => found.filter((i) => i.Type === type);
          const results: MusicSearchResults = {
            tracks: tracksOf(c, of("Audio")).slice(0, limit),
            albums: of("MusicAlbum").map((i) => jfAlbum(c.origin, i)).filter(defined).slice(0, limit),
            artists: of("MusicArtist").map((i) => jfArtistRef(c.origin, i)).filter(defined).slice(0, limit),
            playlists: of("Playlist").map((i) => jfPlaylist(c.origin, i)).filter(defined).slice(0, limit),
          };
          results.top = results.tracks[0] ? { kind: "track", ...results.tracks[0] } : results.albums[0] ? { kind: "album", ...results.albums[0] } : results.artists[0] ? { kind: "artist", ...results.artists[0] } : undefined;
          return results;
        })(),
      ),
    browseHome: () => (jellyfinConfig() ? record(jfHome(need())) : Promise.resolve([])),
    resolve: (track) => record(jfResolve(need(), track)),
    albumTracks: (album) => record((async () => { const c = need(); return tracksOf(c, await jfList(c, "/Items", { ...jfBase(c), parentId: jfSafeId(album.id), includeItemTypes: "Audio", sortBy: "ParentIndexNumber,IndexNumber,SortName", sortOrder: "Ascending", limit: "200" })); })()),
    artistTop: (artist) => record((async () => { const c = need(); return tracksOf(c, await jfList(c, "/Items", { ...jfBase(c), artistIds: jfSafeId(artist.id), includeItemTypes: "Audio", sortBy: "PlayCount", sortOrder: "Descending", limit: "30" })); })()),
    artistRows: async () => [],
    playlistTracks: (playlist) => record((async () => { const c = need(); return tracksOf(c, await jfList(c, `/Playlists/${jfSafeId(playlist.id)}/Items`, { userId: c.userId, limit: "200" })); })()),
    // browse.rs station_tracks: InstantMix, with the seed song first (10.11 stopped including it).
    stationTracks: (station) =>
      record(
        (async () => {
          const c = need();
          const id = jfSafeId(station.id);
          const [seed, mix] = await Promise.all([jfDispatch(c, "GET", `/Items/${id}`).catch(() => null), jfList(c, `/Items/${id}/InstantMix`, { userId: c.userId, limit: "60" })]);
          const mixed = tracksOf(c, mix);
          const seedItem = seed as JfItem | null;
          const first = seedItem && seedItem.Type === "Audio" ? jfTrack(c.origin, seedItem) : undefined;
          if (!first || mixed[0]?.id === first.id) return mixed;
          return [first, ...mixed.filter((t) => t.id !== first.id)];
        })(),
      ),
  };
  const record = recorder(self);
  return self;
}

// ==================================================================================== Plex
// connectors/plex/*.rs. session.rs discovers a server with a music section ("artist" type);
// on the TV the Plex connection the video side saved already carries origin + server token.
type PlexConfig = { origin: string; token: string; clientId: string; section: string; server: string };
const PLEX_DEVICE_KEY = "harbor.plex-auth.device.v1";
let plexProbe: { key: string; at: number; config: Promise<PlexConfig | null> } | null = null;

function plexHeaders(clientId: string, token?: string): Record<string, string> {
  return {
    Accept: "application/json", "X-Plex-Product": "Harbor", "X-Plex-Version": "1", "X-Plex-Platform": "tvOS", "X-Plex-Platform-Version": "1",
    "X-Plex-Device": "Harbor", "X-Plex-Device-Name": "Harbor Apple TV", "X-Plex-Model": "standalone", "X-Plex-Pms-Api-Version": "1.2.2", "X-Plex-Client-Identifier": clientId,
    ...(token ? { "X-Plex-Token": token } : {}),
  };
}
async function plexGet(origin: string, path: string, clientId: string, token: string, timeoutMs: number): Promise<Record<string, unknown>> {
  const res = await request(`${origin}${path}`, { headers: plexHeaders(clientId, token), timeoutMs });
  if (res.status === 401 || res.status === 403) throw new Error("Plex rejected the stored access token");
  if (res.status < 200 || res.status >= 300) throw new Error(`Plex answered ${res.status}`);
  try {
    return JSON.parse(res.text) as Record<string, unknown>;
  } catch {
    throw new Error("Plex sent an unreadable response");
  }
}
const plexContainer = (body: Record<string, unknown>) => (body.MediaContainer as Record<string, unknown> | undefined) ?? {};
const plexNodes = (value: Record<string, unknown>, key: string) => (Array.isArray(value[key]) ? (value[key] as Record<string, unknown>[]) : []);
/** homeServers.ts plexClientId: the identifier the Plex PIN sign-in registered for the profile. */
function plexClientId(profileId: string): string {
  return getSecret(`${PLEX_DEVICE_KEY}.${profileId}`) ?? getSecret(PLEX_DEVICE_KEY) ?? `harbor-${profileId}`;
}
async function plexDiscover(): Promise<PlexConfig | null> {
  for (const c of mediaServerConnections()) {
    if (c.provider !== "plex" || c.enabled === false) continue;
    const token = mediaServerToken(c);
    if (!token) continue;
    const clientId = plexClientId(c.profileId);
    const origin = c.origin.replace(/\/+$/, "");
    try {
      const body = await plexGet(origin, "/library/sections", clientId, token, 5000);
      const dir = plexNodes(plexContainer(body), "Directory").find((d) => d.type === "artist");
      const section = text(dir?.key);
      if (section) return { origin, token, clientId, section, server: c.name };
    } catch {
      /* next connection */
    }
  }
  return null;
}
/** Probed once per connection set for five minutes, like upstream's stored plex.json. */
function plexConfig(): Promise<PlexConfig | null> {
  const key = mediaServerConnections().filter((c) => c.provider === "plex" && c.enabled !== false).map((c) => `${c.id}@${c.origin}`).join("|");
  if (!key) return Promise.resolve(null);
  if (plexProbe && plexProbe.key === key && Date.now() - plexProbe.at < 5 * 60_000) return plexProbe.config;
  plexProbe = { key, at: Date.now(), config: plexDiscover() };
  return plexProbe.config;
}
const plexEncode = (v: string) => encodeURIComponent(v);
function plexSafeKey(raw: string): string {
  const key = raw.trim();
  if (!key || key.length > 40 || !/^[A-Za-z0-9-]+$/.test(key)) throw new Error("Plex item id is invalid");
  return key;
}
function plexSafePath(path: string): string {
  const p = path.trim();
  if (!p.startsWith("/") || p.includes("..") || /[\\ "]/.test(p)) throw new Error("Plex returned an unusable resource path");
  return p;
}
function plexArt(config: PlexConfig, node: Record<string, unknown>, keys: string[], size: number): string {
  const thumb = keys.map((k) => text(node[k])).find(defined);
  if (!thumb) return "";
  let path: string;
  try {
    path = plexSafePath(thumb);
  } catch {
    return "";
  }
  const inner = `${path}?X-Plex-Token=${plexEncode(config.token)}`;
  return `${config.origin}/photo/:/transcode?url=${plexEncode(inner)}&width=${size}&height=${size}&minSize=1&upscale=1&format=jpg&quality=-1&X-Plex-Token=${plexEncode(config.token)}`;
}
function plexTrack(config: PlexConfig, node: Record<string, unknown>): MusicTrack | undefined {
  const key = text(node.ratingKey);
  const title = text(node.title);
  if (!key || !title) return undefined;
  const seconds = Math.floor((num(node.duration) ?? 0) / 1000);
  return {
    id: `plex:${key}`, connectorId: "plex", sourceId: key, title,
    artist: text(node.grandparentTitle) ?? text(node.originalTitle) ?? text(node.parentTitle) ?? "Unknown artist",
    album: text(node.parentTitle), artwork: plexArt(config, node, ["thumb", "parentThumb", "grandparentThumb"], 480), durationSeconds: seconds, durationLabel: durationLabel(seconds),
  };
}
function plexAlbum(config: PlexConfig, node: Record<string, unknown>): MusicAlbumRef | undefined {
  const id = text(node.ratingKey);
  const title = text(node.title);
  if (!id || !title) return undefined;
  return { id, connectorId: "plex", title, artist: text(node.parentTitle) ?? text(node.grandparentTitle) ?? "Unknown artist", artwork: plexArt(config, node, ["thumb", "parentThumb"], 480), year: num(node.year), trackCount: num(node.leafCount) };
}
function plexArtist(config: PlexConfig, node: Record<string, unknown>): MusicArtistRef | undefined {
  const id = text(node.ratingKey);
  const name = text(node.title);
  if (!id || !name) return undefined;
  const art = plexArt(config, node, ["thumb", "art"], 320);
  return { id, connectorId: "plex", name, artwork: art || undefined };
}
function plexPlaylist(config: PlexConfig, node: Record<string, unknown>): MusicPlaylistRef | undefined {
  const id = text(node.ratingKey);
  const name = text(node.title);
  if (!id || !name) return undefined;
  const art = plexArt(config, node, ["composite", "thumb"], 480);
  return { id, connectorId: "plex", name, artwork: art ? [art] : [], trackCount: num(node.leafCount) };
}
function plexStation(config: PlexConfig, node: Record<string, unknown>): MusicStationRef | undefined {
  const keyPath = text(node.key);
  const id = keyPath?.startsWith("/") ? keyPath : text(node.ratingKey);
  const name = text(node.title);
  if (!id || !name) return undefined;
  return { id, connectorId: "plex", name, artwork: plexArt(config, node, ["composite", "thumb", "parentThumb"], 480) };
}
function plexTracks(config: PlexConfig, body: Record<string, unknown>): MusicTrack[] {
  return plexNodes(plexContainer(body), "Metadata").filter((n) => text(n.type) !== "album").map((n) => plexTrack(config, n)).filter(defined);
}
export function plexSlug(raw: string): string {
  let out = "";
  for (const ch of raw.trim().toLowerCase()) {
    if (/[a-z0-9._-]/.test(ch)) out += ch;
    else if (!out.endsWith("-")) out += "-";
  }
  return out.replace(/^-+|-+$/g, "").slice(0, 60);
}
function plexHubRow(config: PlexConfig, hub: Record<string, unknown>): MusicCatalogRow | undefined {
  const context = text(hub.context) ?? "";
  const identifier = plexSlug(text(hub.hubIdentifier) ?? text(hub.title) ?? "");
  const title = text(hub.title);
  if (!identifier || !title) return undefined;
  const stations = context.includes("station") || context.includes("mix");
  const items: MusicCatalogItem[] = [];
  for (const node of [...plexNodes(hub, "Metadata"), ...plexNodes(hub, "Directory")]) {
    if (items.length >= 24) break;
    const type = text(node.type) ?? "";
    const item =
      type === "track" ? trackItems([plexTrack(config, node)].filter(defined))[0]
      : type === "album" ? albumItems([plexAlbum(config, node)].filter(defined))[0]
      : type === "artist" ? artistItems([plexArtist(config, node)].filter(defined))[0]
      : type === "playlist" && stations ? stationItems([plexStation(config, node)].filter(defined))[0]
      : type === "playlist" ? playlistItems([plexPlaylist(config, node)].filter(defined))[0]
      : undefined;
    if (item) items.push(item);
  }
  if (!items.length) return undefined;
  const hubType = text(hub.type) ?? "";
  const layout: MusicRowLayout = hubType === "artist" ? "circles" : hubType === "track" && !stations ? "trackGrid" : "covers";
  return row(`plex:hub:${identifier}`, title, true, config.server, layout, "plex", items);
}

function plexConnector(): Connector {
  const need = async (): Promise<PlexConfig> => {
    const c = await plexConfig();
    if (!c) throw new Error("Connect Plex to play from your server");
    return c;
  };
  const get = (c: PlexConfig, path: string, timeoutMs = 12000) => plexGet(c.origin, path, c.clientId, c.token, timeoutMs);
  const self: Connector = {
    id: "plex",
    name: "Plex",
    kind: "server",
    searchable: true,
    playable: true,
    browsable: true,
    health: "unknown",
    ready: () => mediaServerConnections().some((c) => c.provider === "plex" && c.enabled !== false && !!mediaServerToken(c)),
    detail: () => mediaServerConnections().find((c) => c.provider === "plex" && c.enabled !== false)?.name,
    search: async (query, limit) => (await self.searchTyped(query, limit)).tracks,
    searchTyped: (query, limit) =>
      record(
        (async () => {
          const c = await need();
          const body = await get(c, `/hubs/search?query=${plexEncode(query)}&limit=${limit}&sectionId=${plexSafeKey(c.section)}&includeCollections=0&includeExternalMedia=0`);
          const results = emptyResults();
          for (const hub of plexNodes(plexContainer(body), "Hub")) {
            const nodes = [...plexNodes(hub, "Metadata"), ...plexNodes(hub, "Directory")].slice(0, limit);
            const type = text(hub.type);
            if (type === "track") results.tracks.push(...nodes.map((n) => plexTrack(c, n)).filter(defined));
            else if (type === "album") results.albums.push(...nodes.map((n) => plexAlbum(c, n)).filter(defined));
            else if (type === "artist") results.artists.push(...nodes.map((n) => plexArtist(c, n)).filter(defined));
            else if (type === "playlist") results.playlists.push(...nodes.map((n) => plexPlaylist(c, n)).filter(defined));
          }
          results.top = results.artists[0] ? { kind: "artist", ...results.artists[0] } : results.tracks[0] ? { kind: "track", ...results.tracks[0] } : results.albums[0] ? { kind: "album", ...results.albums[0] } : results.playlists[0] ? { kind: "playlist", ...results.playlists[0] } : undefined;
          return results;
        })(),
      ),
    browseHome: async () => {
      const c = await plexConfig();
      if (!c) return [];
      return record(
        get(c, `/hubs/sections/${plexSafeKey(c.section)}?count=12&includeStations=1&excludeFields=summary`, 8000).then((body) =>
          plexNodes(plexContainer(body), "Hub").map((hub) => plexHubRow(c, hub)).filter(defined).slice(0, 8),
        ),
      );
    },
    // browse.rs resolve: the file itself when Plex names its part, else the mp3 transcoder.
    resolve: (track) =>
      record(
        (async () => {
          const c = await need();
          const key = plexSafeKey(track.sourceId ?? track.id.replace(/^plex:/, ""));
          const body = await get(c, `/library/metadata/${key}`);
          const meta = plexNodes(plexContainer(body), "Metadata")[0];
          const media = meta ? plexNodes(meta, "Media")[0] : undefined;
          const part = media ? plexNodes(media, "Part")[0] : undefined;
          const partKey = text(part?.key);
          const container = (text(part?.container) ?? text(media?.container) ?? text(media?.audioCodec) ?? "").toLowerCase();
          // AVPlayer cannot open Ogg/Opus/Vorbis, so those go through the transcoder on tvOS.
          const avplayable = !["ogg", "opus", "vorbis", "mka", "webm", "wv"].includes(container);
          if (partKey && avplayable) {
            try {
              const mime = ({ flac: "audio/flac", wav: "audio/wav", m4a: "audio/mp4", mp4: "audio/mp4", aac: "audio/mp4", alac: "audio/mp4", aiff: "audio/aiff", aif: "audio/aiff" } as Record<string, string>)[container] ?? "audio/mpeg";
              return { url: `${c.origin}${plexSafePath(partKey)}?X-Plex-Token=${plexEncode(c.token)}`, mimeType: mime, bitrate: num(media?.bitrate) ?? 0 };
            } catch {
              /* fall through to the transcoder */
            }
          }
          const session = crypto.randomUUID();
          return {
            url: `${c.origin}/music/:/transcode/universal/start.mp3?path=${plexEncode(`/library/metadata/${key}`)}&mediaIndex=0&partIndex=0&protocol=http&offset=0&directPlay=0&directStream=1&musicBitrate=320&hasMDE=1&X-Plex-Client-Identifier=${plexEncode(c.clientId)}&X-Plex-Session-Identifier=${plexEncode(session)}&X-Plex-Token=${plexEncode(c.token)}`,
            mimeType: "audio/mpeg",
            bitrate: 320,
          };
        })(),
      ),
    albumTracks: (album) => record((async () => { const c = await need(); return plexTracks(c, await get(c, `/library/metadata/${plexSafeKey(album.id)}/children`)); })()),
    artistTop: (artist) =>
      record(
        (async () => {
          const c = await need();
          const key = plexSafeKey(artist.id);
          const popular = plexTracks(c, await get(c, `/library/sections/${plexSafeKey(c.section)}/all?type=10&artist.id=${key}&sort=ratingCount:desc&group=title&limit=50`));
          if (popular.length) return popular;
          return plexTracks(c, await get(c, `/library/metadata/${key}/allLeaves?X-Plex-Container-Start=0&X-Plex-Container-Size=50`));
        })(),
      ),
    artistRows: async () => [],
    playlistTracks: (playlist) => record((async () => { const c = await need(); return plexTracks(c, await get(c, `/playlists/${plexSafeKey(playlist.id)}/items?type=10&X-Plex-Container-Start=0&X-Plex-Container-Size=200`)); })()),
    stationTracks: (station) =>
      record(
        (async () => {
          const c = await need();
          const path = station.id.startsWith("/") ? plexSafePath(station.id) : `/playlists/${plexSafeKey(station.id)}/items?type=10`;
          return plexTracks(c, await get(c, path));
        })(),
      ),
  };
  const record = recorder(self, ["rejected", "unauthorized"]);
  return self;
}

// ======================================================================= Subsonic / Navidrome
// connectors/subsonic/{mod,client,pairing,catalog,convert,model}.rs. Its own sign-in (server
// URL, username, password); the password itself is never stored, only upstream's pairing:
// base URL, username, salt and token (Navidrome's /auth/login exchange, else md5(password+salt)).
// The four keys live in the secret store as upstream's do (the TV's Keychain tier).
export type SubsonicPairing = { baseUrl: string; username: string; salt: string; token: string };
const SUBSONIC_KEYS = {
  baseUrl: "harbor.subsonic.v1.baseUrl",
  username: "harbor.subsonic.v1.username",
  salt: "harbor.subsonic.v1.salt",
  token: "harbor.subsonic.v1.token",
} as const;
const SUBSONIC_API_VERSION = "1.16.1";
const SUBSONIC_CLIENT = "Harbor";
const SUBSONIC_TIMEOUT = 20_000;
const SUBSONIC_ART = "512";
const NAVIDROME_PORT = "4533";
const SUBSONIC_HOME_SIZE = 24;

/** pairing.rs load(): all four entries, trimmed and non-empty, or nothing. */
export function subsonicPairing(): SubsonicPairing | null {
  const entry = (key: string) => {
    const value = getSecret(key)?.trim();
    return value ? value : null;
  };
  const baseUrl = entry(SUBSONIC_KEYS.baseUrl);
  const username = entry(SUBSONIC_KEYS.username);
  const salt = entry(SUBSONIC_KEYS.salt);
  const token = entry(SUBSONIC_KEYS.token);
  return baseUrl && username && salt && token ? { baseUrl, username, salt, token } : null;
}
function subsonicSave(p: SubsonicPairing | null): void {
  setSecret(SUBSONIC_KEYS.baseUrl, p?.baseUrl ?? null);
  setSecret(SUBSONIC_KEYS.username, p?.username ?? null);
  setSecret(SUBSONIC_KEYS.salt, p?.salt ?? null);
  setSecret(SUBSONIC_KEYS.token, p?.token ?? null);
}
function subsonicAuth(p: SubsonicPairing): [string, string][] {
  return [["u", p.username], ["t", p.token], ["s", p.salt], ["v", SUBSONIC_API_VERSION], ["c", SUBSONIC_CLIENT]];
}
/** client.rs media_url: auth in the query, no f=json (a stream or an image, not an envelope). */
function subsonicMediaUrl(p: SubsonicPairing, method: string, extra: [string, string][]): string {
  const url = new URL(`${p.baseUrl}/rest/${method}`);
  for (const [k, v] of [...subsonicAuth(p), ...extra]) url.searchParams.append(k, v);
  return url.toString();
}
export function subsonicStreamUrl(p: SubsonicPairing, songId: string, transcode = false): string {
  // client.rs stream_url asks for format=raw. AVPlayer has no Ogg/Opus/WMA/APE/WavPack decoder,
  // so on the TV those files ask the server for 320k MP3 instead (see subsonicResolve).
  return subsonicMediaUrl(p, "stream", transcode ? [["id", songId], ["format", "mp3"], ["maxBitRate", "320"]] : [["id", songId], ["format", "raw"]]);
}
function subsonicCoverArt(p: SubsonicPairing, cover: string): string {
  return subsonicMediaUrl(p, "getCoverArt", [["id", cover], ["size", SUBSONIC_ART]]);
}
/** client.rs describe(): 40/41 mean the saved pairing went stale. */
function subsonicDescribe(error: { code?: unknown; message?: unknown } | undefined): string {
  if (!error || typeof error !== "object") return "Music server rejected the request";
  const code = num(error.code) ?? 0;
  if (code === 40 || code === 41) return "Your music server rejected this sign in. Connect it again.";
  return text(error.message) ?? `Music server error ${code}`;
}
type SubsonicBody = Record<string, unknown> & { status?: string; error?: { code?: number; message?: string } };
/** client.rs call(): GET /rest/<method> with auth + f=json, the envelope unwrapped. */
async function subsonicCall(p: SubsonicPairing, method: string, extra: [string, string][] = []): Promise<SubsonicBody> {
  const url = new URL(`${p.baseUrl}/rest/${method}`);
  for (const [k, v] of [...subsonicAuth(p), ["f", "json"], ...extra]) url.searchParams.append(k, v);
  let res: Awaited<ReturnType<typeof request>>;
  try {
    res = await request(url.toString(), { headers: { "User-Agent": "Harbor/1.0" }, timeoutMs: SUBSONIC_TIMEOUT });
  } catch (cause) {
    throw new Error(`Music server request failed: ${cause instanceof Error ? cause.message.replace(/^request failed: /, "") : cause}`);
  }
  if (res.status < 200 || res.status >= 300) throw new Error(`Music server returned HTTP ${res.status}`);
  let body: SubsonicBody | undefined;
  try {
    body = (JSON.parse(res.text) as Record<string, unknown>)["subsonic-response"] as SubsonicBody | undefined;
  } catch {
    body = undefined;
  }
  if (!body || typeof body !== "object") throw new Error("Music server sent a response Harbor could not read");
  if (body.status !== "ok") throw new Error(subsonicDescribe(body.error));
  return body;
}
/** client.rs scrobble(): submission=false is "now playing", true with a time is the scrobble. */
export async function subsonicScrobble(p: SubsonicPairing, songId: string, completedAtMillis: number | null): Promise<void> {
  const extra: [string, string][] = [["id", songId]];
  if (completedAtMillis !== null) extra.push(["submission", "true"], ["time", String(Math.floor(completedAtMillis))]);
  else extra.push(["submission", "false"]);
  await subsonicCall(p, "scrobble", extra);
}
/** client.rs base_candidates: a bare host is tried as https, http, then http on Navidrome's port. */
export function subsonicBaseCandidates(raw: string): string[] {
  const trimmed = raw.trim().replace(/\/+$/, "");
  if (!trimmed) throw new Error("Enter the address of your music server");
  const normalize = (value: string): string => {
    let parsed: URL;
    try {
      parsed = new URL(value);
    } catch {
      throw new Error("That music server address is not valid");
    }
    if (parsed.protocol !== "http:" && parsed.protocol !== "https:") throw new Error("A music server address must start with http or https");
    if (!parsed.hostname) throw new Error("That music server address is missing a host");
    return parsed.toString().replace(/\/+$/, "");
  };
  if (trimmed.includes("://")) return [normalize(trimmed)];
  const out = [normalize(`https://${trimmed}`), normalize(`http://${trimmed}`)];
  if (!trimmed.includes(":")) out.push(normalize(`http://${trimmed}:${NAVIDROME_PORT}`));
  return out;
}
function subsonicSalt(): string {
  return crypto.randomUUID().replace(/-/g, "").slice(0, 16);
}
/** client.rs exchange(): Navidrome's native login hands out a ready salt + token. */
async function subsonicExchange(base: string, username: string, password: string): Promise<SubsonicPairing | null> {
  try {
    const res = await request(`${base}/auth/login`, { method: "POST", headers: { "Content-Type": "application/json", "User-Agent": "Harbor/1.0" }, body: JSON.stringify({ username, password }), timeoutMs: SUBSONIC_TIMEOUT });
    if (res.status < 200 || res.status >= 300) return null;
    const login = JSON.parse(res.text) as { username?: unknown; subsonicSalt?: unknown; subsonicToken?: unknown };
    const salt = typeof login.subsonicSalt === "string" && login.subsonicSalt.length >= 6 ? login.subsonicSalt : null;
    const token = typeof login.subsonicToken === "string" && login.subsonicToken.length === 32 ? login.subsonicToken : null;
    if (!salt || !token) return null;
    return { baseUrl: base, username: typeof login.username === "string" && login.username ? login.username : username, salt, token };
  } catch {
    return null;
  }
}
/** client.rs pair(): exchange or salt, then ping to prove the pairing. */
async function subsonicPair(base: string, username: string, password: string): Promise<SubsonicPairing> {
  const salt = subsonicSalt();
  const pairing = (await subsonicExchange(base, username, password)) ?? { baseUrl: base, username, salt, token: md5Hex(`${password}${salt}`) };
  await subsonicCall(pairing, "ping");
  return pairing;
}
/** convert.rs safe_id */
function subsonicSafeId(raw: string): string {
  let trimmed = raw.trim();
  if (trimmed.startsWith("subsonic:")) trimmed = trimmed.slice("subsonic:".length);
  if (!trimmed || trimmed.length > 128 || !/^[\x21-\x7e]+$/.test(trimmed)) throw new Error("That music server item is not available");
  return trimmed;
}
type SubsonicChild = Record<string, unknown> & { id?: unknown };
function subsonicArtwork(p: SubsonicPairing, cover: unknown): string {
  const c = text(cover);
  return c ? subsonicCoverArt(p, c) : "";
}
/** convert.rs track_ref */
function subsonicTrack(p: SubsonicPairing, song: SubsonicChild): MusicTrack | undefined {
  const id = typeof song.id === "string" ? song.id : typeof song.id === "number" ? String(song.id) : undefined;
  if (!id) return undefined;
  const seconds = Math.max(0, Math.floor(num(song.duration) ?? 0));
  return { id: `subsonic:${id}`, connectorId: "subsonic", sourceId: id, title: typeof song.title === "string" ? song.title : "", artist: typeof song.artist === "string" ? song.artist : "", album: typeof song.album === "string" ? song.album : undefined, artwork: subsonicArtwork(p, song.coverArt), durationSeconds: seconds, durationLabel: durationLabel(seconds) };
}
/** convert.rs album_ref */
function subsonicAlbum(p: SubsonicPairing, album: SubsonicChild): MusicAlbumRef | undefined {
  if (typeof album.id !== "string") return undefined;
  return { id: album.id, connectorId: "subsonic", title: typeof album.name === "string" ? album.name : "", artist: typeof album.artist === "string" ? album.artist : "", artwork: subsonicArtwork(p, album.coverArt), year: num(album.year), trackCount: num(album.songCount) };
}
/** convert.rs artist_ref: the server's cover art, else its own artistImageUrl. */
function subsonicArtist(p: SubsonicPairing, artist: SubsonicChild): MusicArtistRef | undefined {
  if (typeof artist.id !== "string") return undefined;
  const art = subsonicArtwork(p, artist.coverArt) || text(artist.artistImageUrl);
  return { id: artist.id, connectorId: "subsonic", name: typeof artist.name === "string" ? artist.name : "", artwork: art || undefined };
}
/** convert.rs playlist_ref */
function subsonicPlaylist(p: SubsonicPairing, playlist: SubsonicChild): MusicPlaylistRef | undefined {
  if (typeof playlist.id !== "string") return undefined;
  const art = subsonicArtwork(p, playlist.coverArt);
  return { id: playlist.id, connectorId: "subsonic", name: typeof playlist.name === "string" ? playlist.name : "", artwork: art ? [art] : [], trackCount: num(playlist.songCount), subtitle: text(playlist.comment) };
}
function subsonicList(value: unknown, key: string): SubsonicChild[] {
  const node = value && typeof value === "object" ? (value as Record<string, unknown>)[key] : undefined;
  return Array.isArray(node) ? (node as SubsonicChild[]) : [];
}
/** model.rs in_disc_order */
function subsonicDiscOrder(songs: SubsonicChild[]): SubsonicChild[] {
  return songs
    .map((s, i) => ({ s, i }))
    .sort((a, b) => (num(a.s.discNumber) ?? 1) - (num(b.s.discNumber) ?? 1) || (num(a.s.track) ?? 0) - (num(b.s.track) ?? 0) || a.i - b.i)
    .map((x) => x.s);
}
// catalog.rs. The row titles are upstream's lookup keys; lib/i18n has no copy for them yet, so
// music.ts gives them the English the rows are named for (see SUBSONIC_ROW_TITLES there).
async function subsonicHome(p: SubsonicPairing): Promise<MusicCatalogRow[]> {
  const albumRow = async (type: string, id: string, title: string) => {
    const body = await subsonicCall(p, "getAlbumList2", [["type", type], ["size", String(SUBSONIC_HOME_SIZE)]]);
    return row(id, title, false, undefined, "covers", "subsonic", albumItems(subsonicList(body.albumList2, "album").map((a) => subsonicAlbum(p, a)).filter(defined)));
  };
  const outcomes = await Promise.allSettled([
    albumRow("newest", "subsonic:home:newest", "music.row.serverNewest"),
    albumRow("frequent", "subsonic:home:frequent", "music.row.serverFrequent"),
    albumRow("random", "subsonic:home:random", "music.row.serverRandom"),
    subsonicCall(p, "getStarred2").then((body) => row("subsonic:home:starred", "music.row.serverStarred", false, undefined, "trackGrid", "subsonic", trackItems(subsonicList(body.starred2, "song").slice(0, SUBSONIC_HOME_SIZE).map((s) => subsonicTrack(p, s)).filter(defined)))),
    subsonicCall(p, "getArtists").then((body) => {
      const artists = subsonicList(body.artists, "index").flatMap((index) => subsonicList(index, "artist"));
      return row("subsonic:home:artists", "music.row.serverArtists", false, undefined, "circles", "subsonic", artistItems(artists.slice(0, SUBSONIC_HOME_SIZE).map((a) => subsonicArtist(p, a)).filter(defined)));
    }),
    subsonicCall(p, "getPlaylists").then((body) => row("subsonic:home:playlists", "music.row.serverPlaylists", false, undefined, "covers", "subsonic", playlistItems(subsonicList(body.playlists, "playlist").slice(0, SUBSONIC_HOME_SIZE).map((x) => subsonicPlaylist(p, x)).filter(defined)))),
  ]);
  const rows: MusicCatalogRow[] = [];
  let failure: unknown = null;
  for (const o of outcomes) {
    if (o.status === "fulfilled") {
      if (o.value.items.length) rows.push(o.value);
    } else failure = o.reason;
  }
  if (failure && !rows.length) throw failure;
  return rows;
}
async function subsonicAlbumSongs(p: SubsonicPairing, album: string): Promise<MusicTrack[]> {
  const body = await subsonicCall(p, "getAlbum", [["id", album]]);
  return subsonicDiscOrder(subsonicList(body.album, "song")).map((s) => subsonicTrack(p, s)).filter(defined);
}
/** catalog.rs artist_songs: the first four albums' songs, 30 at most. */
async function subsonicArtistSongs(p: SubsonicPairing, artist: string): Promise<MusicTrack[]> {
  const body = await subsonicCall(p, "getArtist", [["id", artist]]);
  const ids = subsonicList(body.artist, "album").slice(0, 4).map((a) => a.id).filter((id): id is string => typeof id === "string");
  if (!ids.length) return [];
  const settled = await Promise.allSettled(ids.map((id) => subsonicAlbumSongs(p, id)));
  const tracks = settled.flatMap((s) => (s.status === "fulfilled" ? s.value : []));
  const failed = settled.find((s) => s.status === "rejected") as PromiseRejectedResult | undefined;
  if (failed && !tracks.length) throw failed.reason;
  return tracks.slice(0, 30);
}
async function subsonicSearch3(p: SubsonicPairing, query: string, artists: number, albums: number, songs: number) {
  const body = await subsonicCall(p, "search3", [["query", query], ["artistCount", String(artists)], ["albumCount", String(albums)], ["songCount", String(songs)]]);
  return body.searchResult3 ?? {};
}
// AVPlayer cannot open these containers; the server transcodes them (TV rule, see stream URL).
const SUBSONIC_TRANSCODE = new Set(["ogg", "oga", "opus", "webm", "mka", "wv", "ape", "wma", "mpc", "dsf", "dff"]);
async function subsonicResolve(p: SubsonicPairing, track: MusicTrack): Promise<MusicStream> {
  const songId = subsonicSafeId(track.sourceId ?? track.id);
  // mod.rs stream(): the "now playing" report is fire-and-forget.
  void subsonicScrobble(p, songId, null).catch(() => undefined);
  const song = await subsonicCall(p, "getSong", [["id", songId]]).then((b) => (b.song as Record<string, unknown> | undefined) ?? {}, () => ({}) as Record<string, unknown>);
  const suffix = (text(song.suffix) ?? "").toLowerCase();
  const transcode = SUBSONIC_TRANSCODE.has(suffix);
  return { url: subsonicStreamUrl(p, songId, transcode), mimeType: transcode ? "audio/mpeg" : "audio/*", bitrate: transcode ? 320 : num(song.bitRate) ?? 0 };
}
/** mod.rs sign_in: every base candidate in turn, the last failure reported. */
export async function subsonicConnect(address: string, username: string, password: string): Promise<SubsonicPairing> {
  const field = (value: string, label: string) => {
    if (!value || !value.trim()) throw new Error(`Enter your music server ${label}`);
    return value;
  };
  const base = field(address, "address");
  const user = field(username, "username").trim();
  const pass = field(password, "password");
  let failure: unknown = null;
  for (const candidate of subsonicBaseCandidates(base)) {
    try {
      const pairing = await subsonicPair(candidate, user, pass);
      subsonicSave(pairing);
      subsonicConnectorRef.health = "healthy";
      return pairing;
    } catch (cause) {
      failure = cause;
    }
  }
  subsonicConnectorRef.health = classify(failure, ["could not reach"]);
  throw failure instanceof Error ? failure : new Error("Harbor could not reach that music server");
}
// ------------------------------------------------------------ artwork at rest (no credentials)
// Subsonic cover art carries u/t/s in its query and Plex art carries X-Plex-Token (twice: the
// transcoder's own and the inner image path's). Tracks the TV keeps (liked, recents) are stored
// with those stripped, and the credentials, which live only in the Keychain, go back on at
// read time; a source that is no longer connected gets no artwork rather than a stale secret.
const SUBSONIC_AUTH_PARAMS = ["u", "t", "s", "p"];
const isSubsonicCover = (u: URL) => /\/rest\/getCoverArt(\.view)?$/.test(u.pathname);
const isPlexTranscode = (u: URL) => u.pathname === "/photo/:/transcode";
function parseUrl(raw: string): URL | null {
  try {
    return new URL(raw);
  } catch {
    return null;
  }
}
/** The inner `url` of Plex's photo transcoder, with or without its token. */
function plexInner(inner: string, token: string | null): string {
  const q = inner.indexOf("?");
  const path = q < 0 ? inner : inner.slice(0, q);
  const params = new URLSearchParams(q < 0 ? "" : inner.slice(q + 1));
  params.delete("X-Plex-Token");
  if (token) params.append("X-Plex-Token", token);
  const rest = params.toString();
  return rest ? `${path}?${rest}` : path;
}
/** An artwork URL as it may be stored: every credential stripped. Idempotent. */
export function artworkAtRest(raw: string): string {
  if (!raw) return raw;
  const u = parseUrl(raw);
  if (!u) return raw;
  if (isSubsonicCover(u)) {
    if (!SUBSONIC_AUTH_PARAMS.some((k) => u.searchParams.has(k))) return raw;
    for (const k of SUBSONIC_AUTH_PARAMS) u.searchParams.delete(k);
    return u.toString();
  }
  if (isPlexTranscode(u) || u.searchParams.has("X-Plex-Token")) {
    const inner = u.searchParams.get("url");
    if (!u.searchParams.has("X-Plex-Token") && !(inner && inner.includes("X-Plex-Token"))) return raw;
    u.searchParams.delete("X-Plex-Token");
    if (inner) u.searchParams.set("url", plexInner(inner, null));
    return u.toString();
  }
  return raw;
}
/** A stored artwork URL with the current credentials put back ("" when its source is gone). */
export function artworkForDisplay(raw: string): string {
  if (!raw) return raw;
  const u = parseUrl(raw);
  if (!u) return raw;
  if (isSubsonicCover(u)) {
    if (u.searchParams.has("t")) return raw;
    const p = subsonicPairing();
    const base = p ? parseUrl(`${p.baseUrl}/rest/`)?.toString() : undefined;
    if (!p || !base || !u.toString().startsWith(base)) return "";
    for (const k of SUBSONIC_AUTH_PARAMS) u.searchParams.delete(k);
    const out = new URL(u.toString());
    out.search = "";
    for (const [k, v] of subsonicAuth(p)) out.searchParams.append(k, v);
    for (const [k, v] of u.searchParams) if (k !== "v" && k !== "c") out.searchParams.append(k, v);
    return out.toString();
  }
  if (isPlexTranscode(u)) {
    if (u.searchParams.has("X-Plex-Token")) return raw;
    const conn = mediaServerConnections().find((c) => c.provider === "plex" && c.enabled !== false && c.origin.replace(/\/+$/, "") === u.origin);
    const token = conn ? mediaServerToken(conn) : null;
    if (!token) return "";
    const inner = u.searchParams.get("url");
    if (inner) u.searchParams.set("url", plexInner(inner, token));
    u.searchParams.append("X-Plex-Token", token);
    return u.toString();
  }
  return raw;
}

/** mod.rs disconnect */
export function subsonicDisconnect(): void {
  subsonicSave(null);
  subsonicConnectorRef.health = "unknown";
}

function subsonicConnector(): Connector {
  const need = (): SubsonicPairing => {
    const p = subsonicPairing();
    if (!p) throw new Error("Connect your music server first");
    return p;
  };
  const self: Connector = {
    id: "subsonic",
    name: "Navidrome",
    kind: "server",
    searchable: true,
    playable: true,
    browsable: true,
    health: "unknown",
    ready: () => subsonicPairing() !== null,
    detail: () => subsonicPairing()?.baseUrl,
    search: (query, limit) =>
      record(
        (async () => {
          const p = need();
          const r = await subsonicSearch3(p, query, 0, 0, limit);
          return subsonicList(r, "song").map((s) => subsonicTrack(p, s)).filter(defined);
        })(),
      ),
    searchTyped: (query, limit) =>
      record(
        (async () => {
          const p = need();
          const r = await subsonicSearch3(p, query, limit, limit, limit);
          const results: MusicSearchResults = {
            tracks: subsonicList(r, "song").map((s) => subsonicTrack(p, s)).filter(defined),
            albums: subsonicList(r, "album").map((a) => subsonicAlbum(p, a)).filter(defined),
            artists: subsonicList(r, "artist").map((a) => subsonicArtist(p, a)).filter(defined),
            playlists: [],
          };
          results.top = results.tracks[0] ? { kind: "track", ...results.tracks[0] } : results.albums[0] ? { kind: "album", ...results.albums[0] } : undefined;
          return results;
        })(),
      ),
    browseHome: () => {
      const p = subsonicPairing();
      return p ? record(subsonicHome(p)) : Promise.resolve([]);
    },
    resolve: (track) => record((async () => subsonicResolve(need(), track))()),
    albumTracks: (album) => record((async () => subsonicAlbumSongs(need(), subsonicSafeId(album.id)))()),
    artistTop: (artist) => record((async () => subsonicArtistSongs(need(), subsonicSafeId(artist.id)))()),
    artistRows: async () => [],
    playlistTracks: (playlist) =>
      record(
        (async () => {
          const p = need();
          const body = await subsonicCall(p, "getPlaylist", [["id", subsonicSafeId(playlist.id)]]);
          return subsonicList(body.playlist, "entry").map((s) => subsonicTrack(p, s)).filter(defined);
        })(),
      ),
    stationTracks: async () => {
      throw unsupported("subsonic", "stations");
    },
  };
  const record = recorder(self, ["could not reach"]);
  return self;
}
const subsonicConnectorRef = subsonicConnector();

// ================================================================================ registry
// registry.rs + matching.rs + rows.rs, over the connectors above.
export const connectors: Connector[] = [catalogConnector(), jellyfinConnector(), plexConnector(), subsonicConnectorRef, soundcloudConnector()];
export function connector(id: string | undefined | null): Connector | undefined {
  return connectors.find((c) => c.id === id);
}
/** Registered and usable on this TV now. */
export function active(): Connector[] {
  return connectors.filter((c) => c.ready());
}

/** rows.rs source_rank */
export function sourceRank(source: string): number {
  const order = ["catalog", "spotify", "youtube", "soundcloud", "local", "jellyfin", "plex", "subsonic"];
  const i = order.indexOf(source);
  return i < 0 ? 8 : i;
}

/** registry.rs browse_home + rows.rs order_rows, with the 12 s BROWSE_TIMEOUT per connector. */
export async function browseHome(): Promise<{ rows: MusicCatalogRow[]; errors: Array<{ source: string; message: string }> }> {
  const list = active().filter((c) => c.browsable);
  const results = await Promise.all(list.map(async (c) => {
    try {
      return { id: c.id, rows: await withTimeout(c.browseHome(), 12_000, `Music connector ${c.id} timed out`), error: null as string | null };
    } catch (cause) {
      return { id: c.id, rows: [] as MusicCatalogRow[], error: cause instanceof Error ? cause.message : String(cause) };
    }
  }));
  results.sort((a, b) => sourceRank(a.id) - sourceRank(b.id) || a.id.localeCompare(b.id));
  const seen = new Set<string>();
  const rows = results.flatMap((r) => r.rows).filter((r) => (seen.has(r.id) ? false : (seen.add(r.id), true)));
  return { rows, errors: results.filter((r) => r.error).map((r) => ({ source: r.id, message: r.error! })) };
}

function trackIdentity(track: MusicTrack): string {
  return `${track.title.trim().toLowerCase()}\u0000${track.artist.trim().toLowerCase()}`;
}
export function sourceKey(track: MusicTrack): string {
  return `${track.connectorId ?? "unknown"}:${track.sourceId ?? track.id}`;
}

/** registry.rs search_typed fan-out + rows.rs merge_typed_results. */
export async function searchTyped(query: string, limit: number, connectorId: string | null): Promise<MusicSearchResults & { errors: Array<{ source: string; message: string }> }> {
  let targets: Connector[];
  if (connectorId) {
    const one = connector(connectorId);
    if (!one) throw new Error(`Unknown music connector: ${connectorId}`);
    if (!one.searchable) throw new Error(`Music connector ${connectorId} does not support search`);
    targets = [one];
  } else {
    const searchable = active().filter((c) => c.searchable);
    const live = searchable.filter((c) => c.health !== "offline");
    targets = live.length ? live : searchable;
    if (!targets.length) throw new Error("No searchable music connectors are installed");
  }
  const settled = await Promise.all(targets.map(async (c) => {
    try {
      return { id: c.id, value: await withTimeout(c.searchTyped(query, limit), 9000, `${c.name} timed out`), error: null as string | null };
    } catch (cause) {
      return { id: c.id, value: null, error: cause instanceof Error ? cause.message : String(cause) };
    }
  }));
  settled.sort((a, b) => sourceRank(a.id) - sourceRank(b.id));
  const ok = settled.filter((s) => s.value).map((s) => s.value!) as MusicSearchResults[];
  const errors = settled.filter((s) => s.error).map((s) => ({ source: s.id, message: s.error! }));
  if (!ok.length) throw new Error(errors.length ? errors.map((e) => `${e.source}: ${e.message}`).join("; ") : "Music sources are offline");
  const merged: MusicSearchResults = { top: ok.map((v) => v.top).find(defined), tracks: [], albums: [], artists: [], playlists: [] };
  const seen = new Set<string>();
  const depth = Math.max(0, ...ok.map((v) => v.tracks.length));
  for (let i = 0; i < depth && merged.tracks.length < limit; i++) {
    for (const v of ok) {
      const t = v.tracks[i];
      if (!t || merged.tracks.length >= limit) continue;
      const key = trackIdentity(t);
      if (!seen.has(key)) {
        seen.add(key);
        merged.tracks.push(t);
      }
    }
  }
  const albums = new Set<string>();
  const artists = new Set<string>();
  const playlists = new Set<string>();
  for (const v of ok) {
    for (const a of v.albums) {
      const key = `${a.title.trim().toLowerCase()}\u0000${a.artist.trim().toLowerCase()}`;
      if (merged.albums.length < limit && !albums.has(key)) (albums.add(key), merged.albums.push(a));
    }
    for (const a of v.artists) {
      const key = a.name.trim().toLowerCase();
      if (merged.artists.length < limit && !artists.has(key)) (artists.add(key), merged.artists.push(a));
    }
    for (const p of v.playlists) {
      const key = `${p.name.trim().toLowerCase()}\u0000${p.connectorId}`;
      if (merged.playlists.length < limit && !playlists.has(key)) (playlists.add(key), merged.playlists.push(p));
    }
  }
  return { ...merged, errors };
}

/** registry.rs search (music_search) + matching.rs settle_search_results: round-robin, deduped. */
export async function searchTracks(query: string, limit: number): Promise<MusicTrack[]> {
  const searchable = active().filter((c) => c.searchable);
  const live = searchable.filter((c) => c.health !== "offline");
  const targets = live.length ? live : searchable;
  const settled = await Promise.all(targets.map((c) => c.search(query, limit).then((v) => ({ ok: true as const, v }), (e) => ({ ok: false as const, e: `${c.id}: ${e instanceof Error ? e.message : e}` }))));
  const queues = settled.filter((s) => s.ok).map((s) => [...(s as { v: MusicTrack[] }).v]);
  if (!queues.length) throw new Error(settled.map((s) => (s.ok ? "" : s.e)).filter(Boolean).join("; ") || "Music sources are offline");
  const seen = new Set<string>();
  const out: MusicTrack[] = [];
  while (out.length < limit) {
    let advanced = false;
    for (const queue of queues) {
      while (queue.length) {
        const t = queue.shift()!;
        advanced = true;
        if (!seen.has(sourceKey(t))) {
          seen.add(sourceKey(t));
          out.push(t);
          break;
        }
      }
      if (out.length === limit) break;
    }
    if (!advanced) break;
  }
  return out;
}

// matching.rs
function normalized(input: string): string {
  return input
    .split("")
    .map((ch) => (/[\p{L}\p{N}]/u.test(ch) ? ch.toLowerCase() : " "))
    .join("")
    .split(/\s+/)
    .filter((t) => t && !["official", "video", "audio", "lyrics", "remastered", "remaster"].includes(t))
    .join(" ");
}
function similarity(left: string, right: string): number {
  const l = normalized(left);
  const r = normalized(right);
  if (!l || !r) return 0;
  if (l === r) return 100;
  if (l.includes(r) || r.includes(l)) return 82;
  const lt = new Set(l.split(" "));
  const rt = new Set(r.split(" "));
  let inter = 0;
  for (const t of lt) if (rt.has(t)) inter++;
  const union = new Set([...lt, ...rt]).size;
  return union === 0 ? 0 : Math.floor((inter * 100) / union);
}
function explicitness(track: MusicTrack): boolean | undefined {
  const lower = track.title.toLowerCase();
  if (lower.includes("(explicit") || lower.includes("[explicit") || lower.includes("explicit version")) return true;
  if (["(clean", "[clean", "clean version", "clean edit", "radio edit", "censored"].some((m) => lower.includes(m))) return false;
  return track.explicit;
}
function lyricBias(target: MusicTrack, candidate: MusicTrack): number {
  const a = explicitness(target);
  const b = explicitness(candidate);
  if (a !== undefined && a === b) return 25;
  if (a === true && b === false) return -60;
  if (a === false && b === true) return -45;
  if (a === true && b === undefined) return -8;
  return 0;
}
export function candidateScore(target: MusicTrack, candidate: MusicTrack): number | null {
  const title = similarity(target.title, candidate.title);
  const artist = similarity(target.artist, candidate.artist);
  if (title < 55 || artist < 35) return null;
  let duration = 0;
  if (target.durationSeconds > 0 && candidate.durationSeconds > 0) {
    const diff = Math.abs(target.durationSeconds - candidate.durationSeconds);
    const tolerance = Math.max(12, Math.floor(Math.max(target.durationSeconds, candidate.durationSeconds) / 10));
    if (diff > tolerance) return null;
    duration = 20 - Math.floor((diff * 20) / Math.max(1, tolerance));
  }
  return title + artist + duration + lyricBias(target, candidate);
}
/** matching.rs connector_priority */
function connectorPriority(id: string): number {
  return id === "spotify" ? 0 : id === "soundcloud" ? 1 : id === "youtube" ? 2 : 3;
}

/** registry.rs candidates: the track as asked, then the best match from every other playable source. */
export async function candidates(track: MusicTrack): Promise<MusicSourceCandidate[]> {
  const originalId = track.connectorId ?? (track.playbackUrl ? "direct" : "youtube");
  const original = connector(originalId);
  const out: MusicSourceCandidate[] = [{ connectorId: originalId, connectorName: original?.name ?? (originalId === "direct" ? "Direct stream" : originalId), health: "healthy", track }];
  const seen = new Set([sourceKey(track)]);
  const query = `${track.artist.trim()} ${track.title.trim()}`;
  const others = active().filter((c) => c.id !== originalId && c.searchable && c.playable);
  const reachable = others.filter((c) => c.health !== "offline");
  const unreachable = others.filter((c) => c.health === "offline");
  const matched = async (list: Connector[]) => {
    const results = await Promise.all(list.map(async (c) => ({ c, tracks: await withTimeout(c.search(query, 5), 9000, "timeout").catch(() => null) })));
    const found: MusicSourceCandidate[] = [];
    for (const { c, tracks } of results) {
      if (!tracks) continue;
      let best: { score: number; t: MusicTrack } | undefined;
      for (const t of tracks) {
        const score = candidateScore(track, t);
        if (score !== null && (!best || score > best.score)) best = { score, t };
      }
      if (!best || seen.has(sourceKey(best.t))) continue;
      seen.add(sourceKey(best.t));
      found.push({ connectorId: c.id, connectorName: c.name, health: c.health, track: best.t });
    }
    return found;
  };
  let alternatives = await matched(reachable);
  if (!alternatives.length && unreachable.length) alternatives = await matched(unreachable);
  alternatives.sort((a, b) => connectorPriority(a.connectorId) - connectorPriority(b.connectorId));
  return [...out, ...alternatives];
}
