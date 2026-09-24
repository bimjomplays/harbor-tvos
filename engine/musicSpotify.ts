// Spotify (Stage 12). Upstream: src-tauri/src/music/spotify/* (librespot 0.8) and
// src/lib/music/spotify-setup.ts + components/music/music-connections/spotify-setup.tsx.
//
// Split on the TV:
//   engine (this file)  auth.rs (PKCE with the listener's own client id), keystore.rs (the
//                       harbor.spotify.v1.* keys; the TV routes that prefix to the Keychain),
//                       tokens.rs (web token, refresh, market), api.rs, parse.rs, browse.rs,
//                       artist_catalog.rs (first album page), connector.rs (health), and the
//                       status mod.rs keeps.
//   rust/harbor-ffi     session.rs + player.rs + control.rs: librespot session, Premium check,
//                       player, PCM into Swift (src/spotify).
//   Swift               SpotifyPlayback.swift drives the Rust session and hands its status here.
//
// Authorization: upstream opens the authorize URL in the desktop browser and catches the redirect
// on a loopback listener at 127.0.0.1:8898 (librespot-oauth). The TV has no browser and its
// loopback is not the phone's, so the TV shows the authorize URL as a QR code, the phone signs in,
// Spotify sends the phone to http://127.0.0.1:8898/login?code=... (a page that does not load), and
// the viewer pastes that address back (typed on the phone through the hand-off page). The same
// redirect URI is registered as upstream tells the listener to, so one Spotify app works for both.
import type { MusicAlbumRef, MusicArtistRef, MusicCatalogItem, MusicCatalogRow, MusicPlaylistRef, MusicRowLayout, MusicSearchResults, MusicTrack } from "@/lib/music/types";
import { SPOTIFY_DASHBOARD_URL, SPOTIFY_REDIRECT_URI } from "@/lib/music/spotify-setup";
import type { Connector, MusicStream } from "./musicSources";

// ---------------------------------------------------------------------------------- copy
// auth.rs / session.rs / tokens.rs / api.rs strings, verbatim.
export const EXPIRED = "Spotify sign in expired";
export const REJECTED_CLIENT = "Spotify rejected that client id";
export const MISSING_CLIENT_ID = "Spotify needs your own client id";
export const BRING_YOUR_OWN = "Bring your own Spotify app";
export const CONNECT_FIRST = "Connect Spotify Premium to use Spotify";
export const FREE_ACCOUNT = "Spotify Free cannot stream through third party apps. Connect a Spotify Premium account.";
const SIGN_IN_AGAIN = "Spotify sign in expired";
const RESTRICTED_CLIENT = "Spotify rejected the request";

/** auth.rs setup_hint */
export function setupHint(): string {
  return `Create an app at developer.spotify.com/dashboard, add ${SPOTIFY_REDIRECT_URI} as a redirect URI, then paste the client id here.`;
}

// ----------------------------------------------------------------------------- keystore
// keystore.rs keys. localStorage on the TV is KeyValueStore; the harbor.spotify.v1 prefix is in
// its secret tier (Keychain), the same place upstream's secrets_write puts them.
export const KEYS = {
  session: "harbor.spotify.v1.credentials",
  deviceId: "harbor.spotify.v1.deviceId",
  webToken: "harbor.spotify.v1.webToken",
  clientId: "harbor.spotify.v1.clientId",
} as const;
const TOKEN_SKEW_SECONDS = 60;

function read(key: string): string | null {
  try {
    const value = localStorage.getItem(key)?.trim();
    return value ? value : null;
  } catch {
    return null;
  }
}
function write(key: string, value: string | null): void {
  try {
    if (value == null) localStorage.removeItem(key);
    else localStorage.setItem(key, value);
  } catch {
    /* a full store must not break sign-in */
  }
}

export type WebToken = { accessToken: string; refreshToken?: string | null; expiresAt: number; scopes: string[] };
const nowSeconds = () => Math.floor(Date.now() / 1000);
/** keystore.rs WebToken::is_fresh */
export function isFresh(token: WebToken | null | undefined, now = nowSeconds()): token is WebToken {
  return !!token && !!token.accessToken?.trim() && token.expiresAt > now + TOKEN_SKEW_SECONDS;
}
function storedWebToken(): WebToken | null {
  const raw = read(KEYS.webToken);
  if (!raw) return null;
  try {
    const t = JSON.parse(raw) as Partial<WebToken>;
    if (typeof t.accessToken !== "string" || typeof t.expiresAt !== "number") return null;
    return { accessToken: t.accessToken, refreshToken: typeof t.refreshToken === "string" ? t.refreshToken : null, expiresAt: t.expiresAt, scopes: Array.isArray(t.scopes) ? t.scopes.filter((s): s is string => typeof s === "string") : [] };
  } catch {
    return null;
  }
}

/** keystore.rs device_id: a UUID minted once. */
export function deviceId(): string {
  const stored = read(KEYS.deviceId);
  if (stored && /^[0-9a-fA-F-]{36}$/.test(stored)) return stored;
  const minted = crypto.randomUUID();
  write(KEYS.deviceId, minted);
  return minted;
}

// ------------------------------------------------------------------------------- status
/** mod.rs SpotifyStatus (the Rust session's, as Swift reports it) + the account that goes with it. */
export type SpotifyStatus = { connected: boolean; username: string | null; country: string | null; premium: boolean; accountType: string | null; error: string | null };
let account: SpotifyStatus = { connected: false, username: null, country: null, premium: false, accountType: null, error: null };
/** tokens.rs session_token: a login5 token Swift fetched from the session. */
let sessionToken: { accessToken: string; expiresAt: number } | null = null;
let webTokenCache: WebToken | null = null;
let health: "unknown" | "healthy" | "degraded" | "offline" = "unknown";

export function status(): SpotifyStatus {
  return { ...account };
}
export function connected(): boolean {
  return account.connected;
}

/** mod.rs connection(): the Sources row (detail line, error, capabilities). */
export function connection() {
  const state = account.connected ? "connected" : account.error ? "error" : "disconnected";
  return {
    status: state,
    account: account.connected ? account.username : null,
    detail: account.connected ? account.accountType : BRING_YOUR_OWN,
    error: account.error,
    clientIdSaved: !!read(KEYS.clientId),
  };
}

/** mod.rs record_failure: the error the Sources row shows; a saved sign-in is left alone. */
export function recordFailure(error: string): SpotifyStatus {
  account = { ...account, connected: false, premium: false, error: error || "Spotify sign in failed" };
  return status();
}

/** mod.rs initialize: what Swift connects with at launch (keystore::load), when there is one. */
export function restore(): { credentials: string | null; deviceId: string } {
  return { credentials: read(KEYS.session), deviceId: deviceId() };
}

/**
 * The Rust session answered (connect_with after session::connect). Keeps the harvested reusable
 * sign-in (keystore::capture), and when the tier is still unknown asks the Web API (probe_tier):
 * a Free account is refused with upstream's copy and Swift shuts the session down.
 */
export async function sessionReady(rust: SpotifyStatus & { credentials?: string | null }, token: { accessToken: string; expiresAt: number } | null): Promise<SpotifyStatus & { shutdown: boolean }> {
  if (rust.credentials) write(KEYS.session, rust.credentials);
  // A token belongs to the session that minted it; a new session replaces it (or has none yet).
  sessionToken = token?.accessToken ? { accessToken: token.accessToken, expiresAt: token.expiresAt } : null;
  if (!rust.connected) {
    account = { connected: false, username: null, country: null, premium: false, accountType: null, error: rust.error ?? account.error };
    return { ...status(), shutdown: false };
  }
  let premium = rust.premium;
  let accountType = rust.accountType;
  if (!accountType) {
    const probe = await probeTier(token?.accessToken ?? webTokenCache?.accessToken ?? storedWebToken()?.accessToken ?? null);
    if (probe === "free") {
      sessionToken = null;
      account = { connected: false, username: null, country: null, premium: false, accountType: null, error: FREE_ACCOUNT };
      return { ...status(), shutdown: true };
    }
    if (probe === "premium") {
      premium = true;
      accountType = "Premium";
    }
  }
  account = { connected: true, username: rust.username, country: rust.country, premium, accountType, error: null };
  health = "healthy";
  return { ...status(), shutdown: false };
}

/** tokens.rs probe_tier: /me's `product`. */
async function probeTier(token: string | null): Promise<"premium" | "free" | "unknown"> {
  if (!token) return "unknown";
  try {
    const me = await apiGet(token, "/me", {});
    const product = typeof me.product === "string" ? me.product.trim().toLowerCase() : "";
    return product === "premium" ? "premium" : product ? "free" : "unknown";
  } catch {
    return "unknown";
  }
}

/** mod.rs disconnect + keystore::forget (the client id stays, as upstream). */
export function forget(): SpotifyStatus {
  write(KEYS.webToken, null);
  write(KEYS.session, null);
  webTokenCache = null;
  sessionToken = null;
  pending = null;
  account = { connected: false, username: null, country: null, premium: false, accountType: null, error: null };
  health = "unknown";
  return status();
}

// ---------------------------------------------------------------------------------- auth
const SCOPES = [
  "streaming",
  "user-read-email",
  "user-read-private",
  "user-read-playback-state",
  "user-modify-playback-state",
  "user-read-currently-playing",
  "user-read-recently-played",
  "user-top-read",
  "user-library-read",
  "playlist-read-private",
  "playlist-read-collaborative",
  "playlist-modify-private",
  "playlist-modify-public",
];
const AUTHORIZE_URL = "https://accounts.spotify.com/authorize";
const TOKEN_URL = "https://accounts.spotify.com/api/token";
/** auth.rs OAUTH_TIMEOUT is 90 s for the loopback; a phone round trip gets ten minutes. */
const PENDING_TTL_MS = 10 * 60 * 1000;

let pending: { clientId: string; verifier: string; state: string; at: number } | null = null;

function base64url(bytes: Uint8Array): string {
  const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
  let out = "";
  for (let i = 0; i < bytes.length; i += 3) {
    const a = bytes[i]!, b = bytes[i + 1], c = bytes[i + 2];
    out += alphabet[a >> 2];
    out += alphabet[((a & 3) << 4) | ((b ?? 0) >> 4)];
    if (b !== undefined) out += alphabet[((b & 15) << 2) | ((c ?? 0) >> 6)];
    if (c !== undefined) out += alphabet[c & 63];
  }
  return out;
}
function randomToken(size: number): string {
  const bytes = new Uint8Array(size);
  crypto.getRandomValues(bytes);
  return base64url(bytes);
}
/** RFC 7636 S256, as oauth2's PkceCodeChallenge::new_random_sha256 (32 random bytes). */
export async function pkcePair(): Promise<{ verifier: string; challenge: string }> {
  const verifier = randomToken(32);
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(verifier));
  return { verifier, challenge: base64url(new Uint8Array(digest)) };
}

/** auth.rs client_id: the saved client id, else the setup walkthrough. */
function clientId(): string {
  const saved = read(KEYS.clientId);
  if (!saved) throw new Error(`${MISSING_CLIENT_ID}. ${setupHint()}`);
  return saved;
}

/** What the setup sheet shows (spotify-setup.tsx): the saved client id and the redirect URI. */
export function setup(): { clientId: string; redirectUri: string; dashboardUrl: string; hint: string } {
  return { clientId: read(KEYS.clientId) ?? "", redirectUri: SPOTIFY_REDIRECT_URI, dashboardUrl: SPOTIFY_DASHBOARD_URL, hint: setupHint() };
}

/**
 * connector.rs connect (a typed client id is saved first) + the authorize URL auth.rs would open.
 * The phone opens it from a QR code.
 */
export async function begin(typedClientId: string | null): Promise<{ authorizeUrl: string; redirectUri: string }> {
  const typed = (typedClientId ?? "").trim();
  if (typed) write(KEYS.clientId, typed);
  const id = clientId();
  const { verifier, challenge } = await pkcePair();
  const state = randomToken(16);
  pending = { clientId: id, verifier, state, at: Date.now() };
  const query = new URLSearchParams({
    response_type: "code",
    client_id: id,
    redirect_uri: SPOTIFY_REDIRECT_URI,
    scope: SCOPES.join(" "),
    state,
    code_challenge: challenge,
    code_challenge_method: "S256",
  });
  return { authorizeUrl: `${AUTHORIZE_URL}?${query.toString()}`, redirectUri: SPOTIFY_REDIRECT_URI };
}

/** The code (and state) from what the viewer pasted: the whole redirect address, or just the code. */
export function readRedirect(pasted: string): { code: string | null; state: string | null; error: string | null } {
  const raw = (pasted ?? "").trim();
  if (!raw) return { code: null, state: null, error: null };
  const queryAt = raw.indexOf("?");
  if (queryAt >= 0 || raw.includes("code=") || raw.includes("error=")) {
    const params = new URLSearchParams(queryAt >= 0 ? raw.slice(queryAt + 1).split("#")[0] : raw);
    return { code: params.get("code"), state: params.get("state"), error: params.get("error") };
  }
  return /^[A-Za-z0-9_-]{16,}$/.test(raw) ? { code: raw, state: null, error: null } : { code: null, state: null, error: null };
}

/** auth.rs describe(OAuthError) */
export function describeAuth(text: string): string {
  const marker = text.toLowerCase();
  if (marker.includes("invalid_grant")) return `${EXPIRED}. Connect Spotify again.`;
  if (marker.includes("invalid_client") || marker.includes("unauthorized_client") || marker.includes("redirect_uri") || marker.includes("invalid redirect"))
    return `${REJECTED_CLIENT}. Confirm the Spotify app allows ${SPOTIFY_REDIRECT_URI} as a redirect URI.`;
  if (marker.includes("auth code param not found") || marker.includes("access_denied")) return "Spotify sign in was cancelled before it finished.";
  return `Spotify sign in failed: ${text}`;
}

async function tokenRequest(form: Record<string, string>): Promise<WebToken> {
  let response: Response;
  try {
    response = await fetch(TOKEN_URL, {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams(form).toString(),
      harborTimeoutMs: 25000,
    } as RequestInit);
  } catch (cause) {
    throw new Error(describeAuth(`request failed: ${cause instanceof Error ? cause.message : String(cause)}`));
  }
  const body = await response.text();
  let value: Record<string, unknown> = {};
  try {
    value = JSON.parse(body) as Record<string, unknown>;
  } catch {
    /* described below */
  }
  if (!response.ok || typeof value.access_token !== "string") {
    const reason = [value.error, value.error_description].filter((x) => typeof x === "string").join(": ") || `HTTP ${response.status}`;
    throw new Error(describeAuth(reason));
  }
  const expiresIn = typeof value.expires_in === "number" ? value.expires_in : 3600;
  return {
    accessToken: value.access_token,
    refreshToken: typeof value.refresh_token === "string" && value.refresh_token.trim() ? value.refresh_token : null,
    expiresAt: nowSeconds() + Math.max(0, Math.floor(expiresIn)),
    scopes: typeof value.scope === "string" ? value.scope.split(/\s+/).filter(Boolean) : [...SCOPES],
  };
}

/** mod.rs adopt_web_token */
function adopt(granted: WebToken, previousRefresh: string | null): string {
  const token: WebToken = { ...granted, refreshToken: granted.refreshToken ?? previousRefresh };
  write(KEYS.webToken, JSON.stringify(token));
  webTokenCache = token;
  return token.accessToken;
}

/**
 * The second half of connect_interactive: the pasted redirect is exchanged for tokens (PKCE, no
 * secret), the web token is kept, and the access token goes to Swift for the librespot session.
 */
export async function finish(pasted: string): Promise<{ accessToken: string; deviceId: string }> {
  const flow = pending;
  if (!flow || Date.now() - flow.at > PENDING_TTL_MS) {
    pending = null;
    throw new Error("Spotify sign in timed out. Authorize Spotify again.");
  }
  const redirect = readRedirect(pasted);
  if (redirect.error) throw new Error(describeAuth(redirect.error));
  if (!redirect.code) throw new Error("Paste the whole address your phone ended on (it starts with http://127.0.0.1:8898/login).");
  if (redirect.state && redirect.state !== flow.state) throw new Error("That address belongs to another sign in. Authorize Spotify again.");
  const granted = await tokenRequest({
    grant_type: "authorization_code",
    code: redirect.code,
    redirect_uri: SPOTIFY_REDIRECT_URI,
    client_id: flow.clientId,
    code_verifier: flow.verifier,
  });
  pending = null;
  return { accessToken: adopt(granted, null), deviceId: deviceId() };
}

/** auth.rs refresh */
async function refresh(refreshToken: string): Promise<WebToken> {
  return tokenRequest({ grant_type: "refresh_token", refresh_token: refreshToken, client_id: clientId() });
}

/** tokens.rs web_token: fresh cache, stored token, refresh, then the session's login5 token. */
export async function webToken(): Promise<string> {
  if (!account.connected) throw new Error(CONNECT_FIRST);
  const now = nowSeconds();
  if (isFresh(webTokenCache, now)) return webTokenCache.accessToken;
  const stored = webTokenCache ?? storedWebToken();
  if (stored) {
    if (isFresh(stored, now)) {
      webTokenCache = stored;
      return stored.accessToken;
    }
    if (stored.refreshToken) {
      try {
        const granted = await refresh(stored.refreshToken);
        // Refresh cannot grant new scopes; keep the ones the sign-in granted.
        return adopt({ ...granted, scopes: stored.scopes }, stored.refreshToken);
      } catch (cause) {
        if (String(cause instanceof Error ? cause.message : cause).includes(EXPIRED)) {
          webTokenCache = null;
          write(KEYS.webToken, null);
        }
      }
    }
  }
  if (sessionToken && sessionToken.expiresAt > now + TOKEN_SKEW_SECONDS) return sessionToken.accessToken;
  throw new Error(CONNECT_FIRST);
}

/** tokens.rs market */
export function market(): string {
  const country = (account.country ?? "").trim().toUpperCase();
  return /^[A-Z]{2}$/.test(country) ? country : "US";
}

// ------------------------------------------------------------------------------------ api
const API = "https://api.spotify.com/v1";
const BODY_EXCERPT = 180;
const RESTRICTED_SEARCH_LIMIT = 10;
class ApiError extends Error {
  constructor(message: string, readonly status: number | null) {
    super(message);
  }
  get missing() {
    return this.status === 403 || this.status === 404;
  }
  get overLimit() {
    return this.status === 400;
  }
}
function excerpt(body: string): string {
  const chars = [...body.trim()];
  return chars.slice(0, BODY_EXCERPT).join("");
}
/** api.rs describe */
export function describeApi(status: number, body: string): string {
  switch (status) {
    case 401:
      return `${SIGN_IN_AGAIN}. Connect Spotify again.`;
    case 403:
      return "Spotify refused this request for the connected account.";
    case 404:
      return "Spotify does not have that item.";
    case 429:
      return "Spotify is rate limiting Harbor. Try again in a moment.";
    case 400:
      return `${RESTRICTED_CLIENT}. ${excerpt(body)}`;
    default:
      return `Spotify returned ${status}. ${excerpt(body)}`;
  }
}
const page = (limit: number) => String(Math.min(50, Math.max(1, Math.floor(limit))));

async function apiGet(token: string, path: string, query: Record<string, string>): Promise<Record<string, unknown>> {
  const qs = new URLSearchParams(query).toString();
  let response: Response;
  try {
    response = await fetch(`${API}${path}${qs ? `?${qs}` : ""}`, { headers: { Authorization: `Bearer ${token}` }, harborTimeoutMs: 25000 } as RequestInit);
  } catch (cause) {
    throw new ApiError(`Spotify request failed: ${cause instanceof Error ? cause.message : String(cause)}`, null);
  }
  const body = await response.text();
  if (!response.ok) throw new ApiError(describeApi(response.status, body), response.status);
  try {
    return JSON.parse(body) as Record<string, unknown>;
  } catch (cause) {
    throw new ApiError(`Spotify response was invalid: ${cause instanceof Error ? cause.message : String(cause)}`, response.status);
  }
}
/** api.rs search: a restricted client (400) gets the request again at ten results. */
async function apiSearch(token: string, query: string, kinds: string, limit: number): Promise<Record<string, unknown>> {
  const request = (n: number) => apiGet(token, "/search", { q: query, type: kinds, limit: page(n), market: market() });
  try {
    return await request(limit);
  } catch (cause) {
    if (cause instanceof ApiError && cause.overLimit && limit > RESTRICTED_SEARCH_LIMIT) return request(RESTRICTED_SEARCH_LIMIT);
    throw cause;
  }
}

// ---------------------------------------------------------------------------------- parse
export const CONNECTOR = "spotify";
type Json = Record<string, unknown>;
const obj = (v: unknown): Json | undefined => (v && typeof v === "object" && !Array.isArray(v) ? (v as Json) : undefined);
function nonEmpty(v: unknown): string | undefined {
  return typeof v === "string" && v.trim() ? v.trim() : undefined;
}
function pointer(body: unknown, path: string[]): unknown {
  let at: unknown = body;
  for (const key of path) at = /^\d+$/.test(key) ? (Array.isArray(at) ? at[Number(key)] : undefined) : obj(at)?.[key];
  return at;
}
export function list(body: unknown, path: string[]): Json[] {
  const v = pointer(body, path);
  return Array.isArray(v) ? v.filter((x): x is Json => !!obj(x)) : [];
}
function durationLabel(seconds: number): string {
  const s = Math.max(0, Math.floor(seconds));
  return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}`;
}
/** parse.rs best_image: the largest by area. */
export function bestImage(images: unknown): string {
  if (!Array.isArray(images)) return "";
  let best: Json | undefined;
  let area = -1;
  for (const image of images) {
    const o = obj(image);
    if (!o) continue;
    const a = (typeof o.width === "number" ? o.width : 0) * (typeof o.height === "number" ? o.height : 0);
    if (a > area) (best = o), (area = a);
  }
  return typeof best?.url === "string" ? best.url : "";
}
function artistNames(artists: unknown): string {
  return Array.isArray(artists) ? artists.map((a) => nonEmpty(obj(a)?.name)).filter(Boolean).join(", ") : "";
}
/** parse.rs track */
export function track(item: Json): MusicTrack | undefined {
  const uri = nonEmpty(item.uri);
  const title = nonEmpty(item.name);
  if (!uri || !title) return undefined;
  const seconds = Math.floor((typeof item.duration_ms === "number" ? item.duration_ms : 0) / 1000);
  const out: MusicTrack = { id: uri, connectorId: CONNECTOR, sourceId: uri, title, artist: artistNames(item.artists), artwork: bestImage(pointer(item, ["album", "images"])), durationSeconds: seconds, durationLabel: durationLabel(seconds) };
  const album = nonEmpty(pointer(item, ["album", "name"]));
  if (album) out.album = album;
  if (typeof item.explicit === "boolean") out.explicit = item.explicit;
  return out;
}
/** parse.rs album_track */
function albumTrack(item: Json, album: MusicAlbumRef): MusicTrack | undefined {
  const t = track(item);
  if (!t) return undefined;
  if (!t.artist) t.artist = album.artist;
  if (!t.album) t.album = album.title;
  if (!t.artwork) t.artwork = album.artwork;
  return t;
}
/** parse.rs album */
export function album(item: Json): MusicAlbumRef | undefined {
  const id = nonEmpty(item.uri);
  const title = nonEmpty(item.name);
  if (!id || !title) return undefined;
  const out: MusicAlbumRef = { id, connectorId: CONNECTOR, title, artist: artistNames(item.artists), artwork: bestImage(item.images) };
  const year = typeof item.release_date === "string" ? Number.parseInt(item.release_date.slice(0, 4), 10) : NaN;
  if (Number.isFinite(year)) out.year = year;
  if (typeof item.total_tracks === "number") out.trackCount = item.total_tracks;
  return out;
}
/** parse.rs artist */
export function artist(item: Json): MusicArtistRef | undefined {
  const id = nonEmpty(item.uri);
  const name = nonEmpty(item.name);
  if (!id || !name) return undefined;
  const out: MusicArtistRef = { id, connectorId: CONNECTOR, name };
  const artwork = bestImage(item.images);
  if (artwork) out.artwork = artwork;
  const genre = nonEmpty(pointer(item, ["genres", "0"]));
  if (genre) out.subtitle = genre;
  return out;
}
/** parse.rs playlist */
export function playlist(item: Json): MusicPlaylistRef | undefined {
  const id = nonEmpty(item.uri);
  const name = nonEmpty(item.name);
  if (!id || !name) return undefined;
  const artwork = bestImage(item.images);
  const total = pointer(item, ["items", "total"]) ?? pointer(item, ["tracks", "total"]);
  const out: MusicPlaylistRef = { id, connectorId: CONNECTOR, name, artwork: artwork ? [artwork] : [] } as MusicPlaylistRef;
  if (typeof total === "number") out.trackCount = total;
  const owner = nonEmpty(pointer(item, ["owner", "display_name"]));
  if (owner) out.subtitle = owner;
  return out;
}
/** parse.rs entry: playlist / saved / recent wrappers. */
function entry(container: Json): Json {
  for (const key of ["item", "track"]) {
    const nested = obj(container[key]);
    if (nested) return nested;
  }
  return container;
}
/** parse.rs base62: the id at the end of a Spotify URI. */
export function base62(uri: string): string | undefined {
  const candidate = uri.split(":").pop()?.trim() ?? "";
  return candidate && candidate.length <= 40 && /^[A-Za-z0-9]+$/.test(candidate) ? candidate : undefined;
}
const defined = <T>(v: T | undefined): v is T => v !== undefined;

// --------------------------------------------------------------------------------- browse
const ROW_LIMIT = 20;
const DETAIL_LIMIT = 50;
const SEARCH_KINDS = "track,album,artist,playlist";
const SOURCE_LABEL = "Spotify";

function row(id: string, title: string, layout: MusicRowLayout, items: MusicCatalogItem[]): MusicCatalogRow | undefined {
  return items.length ? { id, title, titleLiteral: true, subtitle: SOURCE_LABEL, layout, source: CONNECTOR, items } : undefined;
}
const trackItems = (body: unknown): MusicCatalogItem[] => list(body, ["items"]).map(entry).map(track).filter(defined).map((t) => ({ kind: "track" as const, ...t }));
const artistItems = (body: unknown): MusicCatalogItem[] => list(body, ["items"]).map(artist).filter(defined).map((a) => ({ kind: "artist" as const, ...a }));
const albumItems = (body: unknown): MusicCatalogItem[] => list(body, ["items"]).map((e) => obj(e.album) ?? e).map(album).filter(defined).map((a) => ({ kind: "album" as const, ...a }));
const playlistItems = (body: unknown): MusicCatalogItem[] => list(body, ["items"]).map(playlist).filter(defined).map((p) => ({ kind: "playlist" as const, ...p }));

/** browse.rs home: six personal rows in parallel; a failure only matters when every row failed. */
export async function home(): Promise<MusicCatalogRow[]> {
  const token = await webToken();
  const m = market();
  const n = page(ROW_LIMIT);
  const specs: Array<[Promise<Json>, string, string, MusicRowLayout, (b: unknown) => MusicCatalogItem[]]> = [
    [apiGet(token, "/me/player/recently-played", { limit: n }), "spotify:home:recently-played", "Recently played on Spotify", "covers", trackItems],
    [apiGet(token, "/me/top/tracks", { limit: n, time_range: "medium_term" }), "spotify:home:top-tracks", "Your top tracks", "trackGrid", trackItems],
    [apiGet(token, "/me/top/artists", { limit: n, time_range: "medium_term" }), "spotify:home:top-artists", "Your top artists", "circles", artistItems],
    [apiGet(token, "/me/playlists", { limit: n }), "spotify:home:playlists", "Your Spotify playlists", "covers", playlistItems],
    [apiGet(token, "/me/albums", { limit: n, market: m }), "spotify:home:saved-albums", "Albums in your library", "covers", albumItems],
    [apiGet(token, "/me/tracks", { limit: n, market: m }), "spotify:home:saved-tracks", "Liked on Spotify", "trackGrid", trackItems],
  ];
  const settled = await Promise.allSettled(specs.map((s) => s[0]));
  const rows: MusicCatalogRow[] = [];
  let failure: unknown = null;
  settled.forEach((outcome, i) => {
    const [, id, title, layout, items] = specs[i]!;
    if (outcome.status === "fulfilled") {
      const built = row(id, title, layout, items(outcome.value));
      if (built) rows.push(built);
    } else if (failure === null) failure = outcome.reason;
  });
  if (failure !== null && !rows.length) throw failure;
  return rows;
}

/** browse.rs tracks */
export async function tracks(query: string, limit: number): Promise<MusicTrack[]> {
  const token = await webToken();
  const body = await apiSearch(token, query, "track", limit);
  return list(body, ["tracks", "items"]).map(track).filter(defined).slice(0, limit);
}

/** browse.rs top_result: an exact artist name wins, then the first track, album, artist. */
function topResult(query: string, found: MusicSearchResults): MusicCatalogItem | undefined {
  const wanted = query.trim().toLowerCase();
  const exact = found.artists.find((a) => a.name.toLowerCase() === wanted);
  if (exact) return { kind: "artist", ...exact };
  if (found.tracks[0]) return { kind: "track", ...found.tracks[0] };
  if (found.albums[0]) return { kind: "album", ...found.albums[0] };
  return found.artists[0] ? { kind: "artist", ...found.artists[0] } : undefined;
}

/** browse.rs search */
export async function search(query: string, limit: number): Promise<MusicSearchResults> {
  const token = await webToken();
  const body = await apiSearch(token, query, SEARCH_KINDS, limit);
  const found: MusicSearchResults = {
    tracks: list(body, ["tracks", "items"]).map(track).filter(defined).slice(0, limit),
    albums: list(body, ["albums", "items"]).map(album).filter(defined).slice(0, limit),
    artists: list(body, ["artists", "items"]).map(artist).filter(defined).slice(0, limit),
    playlists: list(body, ["playlists", "items"]).map(playlist).filter(defined).slice(0, limit),
  };
  found.top = topResult(query, found);
  return found;
}

/** browse.rs album_tracks */
export async function albumTracks(ref: MusicAlbumRef): Promise<MusicTrack[]> {
  const id = base62(ref.id);
  if (!id) throw new Error("Spotify album id is invalid");
  const token = await webToken();
  const body = await apiGet(token, `/albums/${id}/tracks`, { limit: page(DETAIL_LIMIT), market: market() });
  return list(body, ["items"]).map((item) => albumTrack(item, ref)).filter(defined);
}

/** browse.rs artist_filter */
export function artistFilter(name: string): string {
  return `artist:"${name.replace(/"/g, " ")}"`;
}

/** browse.rs artist_top: a restricted client (403/404) falls back to searching the artist. */
export async function artistTop(ref: MusicArtistRef): Promise<MusicTrack[]> {
  const id = base62(ref.id);
  if (!id) throw new Error("Spotify artist id is invalid");
  const token = await webToken();
  try {
    const body = await apiGet(token, `/artists/${id}/top-tracks`, { market: market() });
    return list(body, ["tracks"]).map(track).filter(defined);
  } catch (cause) {
    if (cause instanceof ApiError && cause.missing) return tracks(artistFilter(ref.name), 10);
    throw cause;
  }
}

/** artist_catalog.rs load(kind: albums), first page, as the artist page's Albums shelf. */
export async function artistRows(ref: MusicArtistRef): Promise<MusicCatalogRow[]> {
  const id = base62(ref.id);
  if (!id) return [];
  const token = await webToken();
  const body = await apiGet(token, `/artists/${id}/albums`, { limit: "10", offset: "0", include_groups: "album,single,appears_on,compilation", market: market() });
  const items = list(body, ["items"]).map(album).filter(defined).map((a) => ({ kind: "album" as const, ...a }));
  return items.length ? [{ id: "artist:albums", title: "music.search.albums", titleLiteral: false, subtitle: SOURCE_LABEL, layout: "covers", source: CONNECTOR, items }] : [];
}

/** browse.rs playlist_tracks (api.rs playlist_items: /items, else the older /tracks). */
export async function playlistTracks(ref: MusicPlaylistRef): Promise<MusicTrack[]> {
  const id = base62(ref.id);
  if (!id) throw new Error("Spotify playlist id is invalid");
  const token = await webToken();
  const query = { limit: page(DETAIL_LIMIT), market: market(), additional_types: "track" };
  let body: Json;
  try {
    body = await apiGet(token, `/playlists/${id}/items`, query);
  } catch (cause) {
    if (!(cause instanceof ApiError && cause.status === 404)) throw cause;
    body = await apiGet(token, `/playlists/${id}/tracks`, query);
  }
  return list(body, ["items"]).map(entry).map(track).filter(defined);
}

// ------------------------------------------------------------------------------ connector
/** connector.rs is_offline */
function isOffline(error: string): boolean {
  const marker = error.toLowerCase();
  return ["timed out", "network", "connection", "dns", "offline", "request failed"].some((needle) => marker.includes(needle));
}
/** connector.rs record */
async function recorded<T>(work: Promise<T>): Promise<T> {
  try {
    const value = await work;
    health = "healthy";
    return value;
  } catch (cause) {
    const message = cause instanceof Error ? cause.message : String(cause);
    health = message.includes("Connect Spotify Premium") ? "unknown" : isOffline(message) ? "offline" : "degraded";
    throw cause;
  }
}

/** The marker stream the TV's prepare() returns for a Spotify track; Swift plays it through librespot. */
export const SPOTIFY_STREAM_MIME = "audio/x-spotify-uri";

export function spotifyConnector(): Connector {
  const self: Connector = {
    id: CONNECTOR,
    name: "Spotify",
    kind: "streaming",
    searchable: true,
    playable: true,
    browsable: true,
    get health() {
      return health;
    },
    set health(value) {
      health = value;
    },
    ready: () => account.connected,
    detail: () => (account.connected ? account.accountType ?? undefined : BRING_YOUR_OWN),
    search: (query, limit) => recorded(tracks(query, limit)),
    searchTyped: (query, limit) => recorded(search(query, limit)),
    browseHome: () => (account.connected ? recorded(home()) : Promise.resolve([])),
    // Upstream's resolve refuses ("Spotify playback uses Harbor's native Premium session") because
    // music_play_track sends Spotify tracks to the librespot player before resolving anything.
    // The TV's prepare() returns this marker instead and MusicPlayer routes on connectorId.
    resolve: async (t): Promise<MusicStream> => {
      if (!account.connected) throw new Error("Connect Spotify Premium before playing this source");
      const uri = t.sourceId ?? t.id;
      if (!uri.startsWith("spotify:")) throw new Error("Spotify track is missing its URI");
      return { url: uri, mimeType: SPOTIFY_STREAM_MIME, bitrate: 320000 };
    },
    albumTracks: (ref) => recorded(albumTracks(ref)),
    artistTop: (ref) => recorded(artistTop(ref)),
    artistRows: (ref) => recorded(artistRows(ref)),
    playlistTracks: (ref) => recorded(playlistTracks(ref)),
    stationTracks: async () => {
      throw new Error("Music connector spotify does not support stations");
    },
  };
  return self;
}
