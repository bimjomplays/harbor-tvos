// Scrobbling (Stage 12, second batch). Upstream: src-tauri/src/music/lastfm.rs (auth + the
// signed track.scrobble call), music/commands/accounts.rs scrobble_track (Subsonic first, then
// Last.fm), music/engine.rs should_scrobble (the threshold), and the settings panel
// components/music/music-lastfm.tsx over lib/music/lastfm.ts. Upstream has no ListenBrainz
// scrobbling and no Last.fm "now playing" call; neither does the TV.
//
// The Last.fm keys are upstream's (harbor.lastfm.v1.*) and live in the secret store, which on the
// TV is the Keychain tier (KeyValueStore.secretPrefixes). Authorizing needs a browser: the TV
// shows the auth URL as a QR code, the viewer approves on a phone, then presses Finish here.
import type { MusicTrack } from "@/lib/music/types";
import { LASTFM_API_KEY, LASTFM_API_SECRET, LASTFM_SESSION_KEY, LASTFM_USERNAME } from "@/lib/music/lastfm";
import { getSecret, setSecret } from "@/lib/secret-store";
import { md5Hex } from "./md5";
import { subsonicPairing, subsonicScrobble } from "./musicSources";

const LASTFM_API = "https://ws.audioscrobbler.com/2.0/";

/** engine.rs should_scrobble: half the track or four minutes, whichever comes first. */
export function shouldScrobble(listenedSeconds: number, durationSeconds: number): boolean {
  const threshold = Number.isFinite(durationSeconds) && durationSeconds > 0 ? Math.min(durationSeconds * 0.5, 240) : 240;
  return listenedSeconds >= threshold;
}

/** lastfm.rs signature(): sorted name+value pairs (format / callback / api_sig left out) + secret. */
export function lastfmSignature(params: Record<string, string>, secret: string): string {
  let value = "";
  for (const name of Object.keys(params).sort()) {
    if (name !== "format" && name !== "callback" && name !== "api_sig") value += `${name}${params[name]}`;
  }
  return md5Hex(value + secret);
}

let lastfmHealth: "unknown" | "healthy" | "degraded" | "offline" = "unknown";
/** lastfm.rs classify_error */
function classify(error: unknown): typeof lastfmHealth {
  const lower = String(error instanceof Error ? error.message : error).toLowerCase();
  return lower.includes("request failed") || lower.includes("offline") || lower.includes("timed out") ? "offline" : "degraded";
}
function recorded<T>(work: Promise<T>): Promise<T> {
  return work.then(
    (value) => {
      lastfmHealth = "healthy";
      return value;
    },
    (cause) => {
      lastfmHealth = classify(cause);
      throw cause;
    },
  );
}

/** lastfm.rs post(): signed, form-encoded, JSON back; an `error` field wins over the status. */
async function lastfmPost(params: Record<string, string>, secret: string): Promise<Record<string, unknown>> {
  const signed: Record<string, string> = { ...params, api_sig: lastfmSignature(params, secret), format: "json" };
  let response: Response;
  try {
    response = await fetch(LASTFM_API, {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams(signed).toString(),
      harborTimeoutMs: 20000,
    } as RequestInit);
  } catch (cause) {
    throw new Error(`Last.fm request failed: ${cause instanceof Error ? cause.message : cause}`);
  }
  let value: Record<string, unknown>;
  try {
    value = JSON.parse(await response.text()) as Record<string, unknown>;
  } catch (cause) {
    throw new Error(`Last.fm response was invalid: ${cause instanceof Error ? cause.message : cause}`);
  }
  if (typeof value?.error === "number") {
    throw new Error(`Last.fm error ${value.error}: ${typeof value.message === "string" ? value.message : "Last.fm rejected the request"}`);
  }
  if (!response.ok) throw new Error(`Last.fm returned HTTP ${response.status}`);
  return value;
}

/** lastfm.rs validate_credentials */
function validate(apiKey: string, apiSecret: string): void {
  if (!apiKey.trim() || !apiSecret.trim() || apiKey.length > 128 || apiSecret.length > 128) throw new Error("Last.fm API key and secret are required");
}

export type LastFmStatus = { connected: boolean; username: string | null; saved: boolean; apiKey: string; health: string };

/** lastfm.rs status() + what music-lastfm.tsx reads back from the secret store. */
export function lastfmStatus(): LastFmStatus {
  const session = getSecret(LASTFM_SESSION_KEY);
  return {
    connected: !!session,
    username: getSecret(LASTFM_USERNAME) || null,
    saved: !!getSecret(LASTFM_API_KEY) && !!getSecret(LASTFM_API_SECRET),
    apiKey: getSecret(LASTFM_API_KEY) ?? "",
    health: session ? (lastfmHealth === "unknown" ? "healthy" : lastfmHealth) : "unknown",
  };
}

/**
 * music-lastfm.tsx begin() + lastfm.rs begin_auth: the key and secret are saved first, then
 * auth.getToken; the viewer opens authUrl on a phone. An empty secret reuses the saved one (the
 * TV never shows the saved secret back).
 */
export function lastfmBegin(apiKeyIn: string | null, apiSecretIn: string | null): Promise<{ token: string; authUrl: string }> {
  const apiKey = (apiKeyIn ?? "").trim() || (getSecret(LASTFM_API_KEY) ?? "");
  const apiSecret = (apiSecretIn ?? "").trim() || (getSecret(LASTFM_API_SECRET) ?? "");
  return recorded(
    (async () => {
      validate(apiKey, apiSecret);
      setSecret(LASTFM_API_KEY, apiKey.trim());
      setSecret(LASTFM_API_SECRET, apiSecret.trim());
      const value = await lastfmPost({ api_key: apiKey.trim(), method: "auth.getToken" }, apiSecret);
      const token = typeof value.token === "string" && value.token ? value.token : null;
      if (!token) throw new Error("Last.fm did not return an authorization token");
      const url = new URL("https://www.last.fm/api/auth/");
      url.searchParams.append("api_key", apiKey.trim());
      url.searchParams.append("token", token);
      return { token, authUrl: url.toString() };
    })(),
  );
}

/** music-lastfm.tsx finish() + lastfm.rs complete_auth: auth.getSession, then the session is kept. */
export function lastfmFinish(tokenIn: string): Promise<LastFmStatus> {
  return recorded(
    (async () => {
      const apiKey = getSecret(LASTFM_API_KEY) ?? "";
      const apiSecret = getSecret(LASTFM_API_SECRET) ?? "";
      validate(apiKey, apiSecret);
      const token = (tokenIn ?? "").trim();
      if (!token || token.length > 128) throw new Error("Last.fm authorization token is invalid");
      const value = await lastfmPost({ api_key: apiKey.trim(), method: "auth.getSession", token }, apiSecret);
      const session = value.session && typeof value.session === "object" ? (value.session as Record<string, unknown>) : null;
      if (!session) throw new Error("Last.fm did not return a session");
      const username = typeof session.name === "string" && session.name ? session.name : null;
      if (!username) throw new Error("Last.fm session has no username");
      const key = typeof session.key === "string" && session.key ? session.key : null;
      if (!key) throw new Error("Last.fm session has no key");
      setSecret(LASTFM_SESSION_KEY, key);
      setSecret(LASTFM_USERNAME, username);
      return lastfmStatus();
    })(),
  );
}

/** music-lastfm.tsx disconnect(): all four secrets go. */
export function lastfmDisconnect(): LastFmStatus {
  for (const key of [LASTFM_API_KEY, LASTFM_API_SECRET, LASTFM_SESSION_KEY, LASTFM_USERNAME]) setSecret(key, null);
  lastfmHealth = "unknown";
  return lastfmStatus();
}

/** lastfm.rs scrobble(): Ok(false) without a key, secret and session. */
async function lastfmScrobble(track: MusicTrack, startedAt: number): Promise<boolean> {
  const apiKey = getSecret(LASTFM_API_KEY);
  const apiSecret = getSecret(LASTFM_API_SECRET);
  const session = getSecret(LASTFM_SESSION_KEY);
  if (!apiKey || !apiSecret || !session) return false;
  const params: Record<string, string> = {
    api_key: apiKey,
    artist: track.artist,
    chosenByUser: "1",
    duration: String(Math.max(0, Math.floor(track.durationSeconds || 0))),
    method: "track.scrobble",
    sk: session,
    timestamp: String(Math.floor(startedAt)),
    track: track.title,
  };
  const album = track.album?.trim();
  if (album) params.album = album;
  await lastfmPost(params, apiSecret);
  return true;
}

/** subsonic/mod.rs scrobble(): only for a track the Navidrome server itself played. */
async function subsonicTrackScrobble(track: MusicTrack, startedAt: number): Promise<boolean> {
  if (track.connectorId !== "subsonic") return false;
  const pairing = subsonicPairing();
  if (!pairing) return false;
  const raw = (track.sourceId ?? track.id).trim().replace(/^subsonic:/, "");
  if (!raw || raw.length > 128 || !/^[\x21-\x7e]+$/.test(raw)) throw new Error("That music server item is not available");
  await subsonicScrobble(pairing, raw, Math.floor(startedAt) * 1000);
  return true;
}

/**
 * accounts.rs scrobble_track, called by the player once a track that crossed should_scrobble
 * ends (engine.rs: EndFile or natural EOF). "scrobbled" is upstream's music://lastfm event.
 */
export async function scrobble(track: MusicTrack, startedAt: number): Promise<{ status: "scrobbled" | "skipped" | "error"; message?: string }> {
  try {
    await subsonicTrackScrobble(track, startedAt);
  } catch {
    /* accounts.rs: a Subsonic failure is only logged */
  }
  try {
    const done = await recorded(lastfmScrobble(track, startedAt));
    return { status: done ? "scrobbled" : "skipped" };
  } catch (cause) {
    return { status: "error", message: cause instanceof Error ? cause.message : String(cause) };
  }
}
