// Stage 3/4 glue: resume position and progress writes (local resume, local CW, Stremio library).
// Mirrors src/views/player/hooks/use-resume-autosave.ts + use-stremio-sync.ts in simplified form
// (docs/player-spec.md §3); cadence is the Swift side's job.
import { readResumeEntry, saveResumeMs, clearResume } from "@/lib/resume";
import { saveLocalCw, clearLocalCw } from "@/lib/local-cw";
import { setMovieWatchedLocal } from "@/lib/movie-watched";
import { libraryGetOne, libraryPut, type LibraryItem } from "@/lib/stremio";
import { resolveStartMs } from "@/lib/player/resume-start";
import type { Meta } from "@/lib/cinemeta";
import { loadEffective } from "@/lib/settings/profile-store";
import { unzlibSync, zlibSync } from "fflate";

/**
 * The playback settings the Big Picture chrome reads (settings/defaults.ts): the up-next lead
 * (skip-pill-container.tsx nextEpisodeLead: -1 = auto, 0 = off), auto-advance
 * (player.tsx useAutoNextEpisode) and the seek steps (bp-player-scrub.tsx).
 */
export function prefs(profileId: string, linked: boolean) {
  const s = loadEffective(profileId, linked);
  const num = (v: unknown, d: number) => (typeof v === "number" && Number.isFinite(v) ? v : d);
  return {
    autoPlayNextEpisode: s.autoPlayNextEpisode !== false,
    nextEpisodeLeadSec: num(s.nextEpisodeLeadSec, -1),
    seekBackStepSec: num(s.seekBackStepSec, 10) || 10,
    seekForwardStepSec: num(s.seekForwardStepSec, 10) || 10,
  };
}

// lib/stremio-watched.ts canonicalVideoOrder (not exported): Stremio indexes the watched
// bitfield against videos sorted by (season, episode, released); bit i is that position.
type Vid = NonNullable<Meta["videos"]>[number];
const ordKey = (v: number | null | undefined) => (typeof v === "number" && Number.isFinite(v) ? v : -Infinity);
const releasedMs = (v: Vid) => { const r = v?.released ?? v?.firstAired; if (!r) return -Infinity; const t = Date.parse(r); return Number.isNaN(t) ? -Infinity : t; };
const cmpNum = (a: number, b: number) => (a === b ? 0 : a < b ? -1 : 1);
function canonicalVideoOrder(videos: Vid[]): Vid[] {
  return [...videos].sort((a, b) => cmpNum(ordKey(a?.season), ordKey(b?.season)) || cmpNum(ordKey(a?.episode), ordKey(b?.episode)) || cmpNum(releasedMs(a), releasedMs(b)));
}

const WATCHED_RATIO = 0.85;      // use-resume-autosave.ts:33 / playback-end.ts:3
const CREDITS_RATIO = 0.9;       // use-stremio-sync.ts:19 (cloud flaggedWatched)
const MIN_POSITION_SEC = 5;      // use-resume-autosave.ts:30
const STUB_MAX_SEC = 150;        // use-resume-autosave.ts:34

export type ProgressInput = {
  meta: Meta;
  season?: number | null;
  episode?: number | null;
  videoId?: string | null;
  imdbId?: string | null;
  positionMs: number;
  durationMs: number;
  authKey?: string | null;
  /** true on the final write (exit / natural end) so the cloud write is not skipped. */
  flush?: boolean;
};

export function startPosition(meta: Meta, season: number | null, episode: number | null, authKey: string | null, imdbId: string | null, imdbVerified: boolean, videoId: string | null) {
  return resolveStartMs({
    metaId: meta.id,
    season: season ?? undefined,
    episode: episode ?? undefined,
    authKey,
    imdbId,
    imdbVerified,
    openingVid: videoId ?? undefined,
  });
}

export type ProgressResult = { watched: boolean; cloud: "written" | "skipped" | "failed" | "none" };

export async function saveProgress(p: ProgressInput): Promise<ProgressResult> {
  const durSec = p.durationMs / 1000;
  const posSec = p.positionMs / 1000;
  if (durSec > 0 && durSec < STUB_MAX_SEC) return { watched: false, cloud: "skipped" };
  const ratio = durSec > 0 ? p.positionMs / p.durationMs : 0;
  const watched = ratio >= WATCHED_RATIO;
  const s = p.season ?? undefined;
  const e = p.episode ?? undefined;
  const isEpisode = typeof s === "number" && typeof e === "number";

  if (watched) {
    clearResume(p.meta.id, s, e);
  } else if (posSec >= MIN_POSITION_SEC) {
    saveResumeMs(p.meta.id, p.positionMs, s, e, undefined, durSec > 0 ? ratio : undefined);
  }
  const t = Date.now();
  const type = isEpisode || p.meta.type === "series" ? "series" : "movie";
  if (watched && type === "movie") {
    clearLocalCw(p.meta.id);
    // mark-watched.ts markMovieWatched: the local flag is what the card's check mark reads.
    setMovieWatchedLocal(p.meta.id, true);
  }
  else if (posSec >= MIN_POSITION_SEC) {
    saveLocalCw({ id: p.meta.id, type, name: p.meta.name, poster: p.meta.poster, background: p.meta.background,
      season: s, episode: e, positionMs: p.positionMs, durationMs: p.durationMs, t } as never);
  }

  if (!p.authKey || posSec < 6) return { watched, cloud: "none" };
  try {
    const cid = p.meta.id;
    const videoId = p.videoId ?? (isEpisode ? `${cid}:${s}:${e}` : cid);
    const existing = await libraryGetOne(p.authKey, cid).catch(() => null);
    const prevState = existing?.state ?? { timeOffset: 0, duration: 0 };
    const flagged = ratio >= CREDITS_RATIO ? 1 : (prevState.flaggedWatched ?? 0);
    const item: LibraryItem = {
      ...(existing ?? { _id: cid, removed: false, temp: false, _ctime: new Date(t).toISOString() } as LibraryItem),
      type,
      name: p.meta.name,
      poster: p.meta.poster ?? existing?.poster,
      background: p.meta.background ?? existing?.background,
      _mtime: new Date(t).toISOString(),
      state: {
        ...prevState,
        timeOffset: Math.round(p.positionMs),
        duration: Math.round(p.durationMs),
        video_id: videoId,
        season: s,
        episode: e,
        lastWatched: new Date(t).toISOString(),
        flaggedWatched: flagged,
        timesWatched: flagged === 1 && (prevState.flaggedWatched ?? 0) === 0 ? (prevState.timesWatched ?? 0) + 1 : (prevState.timesWatched ?? 0),
      },
    };
    await libraryPut(p.authKey, item);
    return { watched, cloud: "written" };
  } catch {
    return { watched, cloud: "failed" };
  }
}

export function localResume(metaId: string, season: number | null, episode: number | null) {
  return readResumeEntry(metaId, season ?? undefined, episode ?? undefined);
}


/**
 * Which episodes the Stremio library marks watched, as "season:episode" keys.
 * Same wire format as lib/stremio-watched.ts decodeWatchedEpisodes ("<anchorVideoId>:<anchorLength>:<base64 deflate bitfield>"),
 * inflated with fflate because JavaScriptCore has no DecompressionStream.
 */
export async function watchedEpisodes(authKey: string | null, meta: Meta): Promise<string[]> {
  if (!authKey || !meta.videos || meta.videos.length === 0) return [];
  const item = await libraryGetOne(authKey, meta.id).catch(() => null);
  const field = (item?.state as { watched?: string } | undefined)?.watched;
  return decodeWatchedField(field, meta.videos);
}

/** Pure decoder for the `state.watched` field; see watchedEpisodes. */
export function decodeWatchedField(field: string | null | undefined, videos: Meta["videos"]): string[] {
  if (!field || !videos || videos.length === 0) return [];
  const parts = field.split(":");
  if (parts.length < 3) return [];
  const b64 = parts[parts.length - 1];
  const anchorLength = Number.parseInt(parts[parts.length - 2], 10);
  const anchorVideoId = parts.slice(0, -2).join(":");
  if (!Number.isFinite(anchorLength) || anchorLength <= 0) return [];
  let bytes: Uint8Array;
  try {
    const bin = atob(b64);
    const raw = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) raw[i] = bin.charCodeAt(i);
    bytes = unzlibSync(raw);   // DecompressionStream("deflate") is zlib-framed, not raw deflate
  } catch {
    return [];
  }
  const bit = (i: number) => i >= 0 && i < bytes.length * 8 && (bytes[i >> 3] & (1 << (i & 7))) !== 0;
  const sorted = canonicalVideoOrder(videos);
  const anchorIdx = sorted.findIndex((v) => v.id === anchorVideoId);
  const offset = anchorLength - anchorIdx - 1;
  const keys: string[] = [];
  for (let i = 0; i < sorted.length; i++) {
    const v = sorted[i];
    if (v?.season != null && v?.episode != null && bit(i + offset)) keys.push(`${v.season}:${v.episode}`);
  }
  return keys;
}

/**
 * lib/stremio-watched.ts encodeWatchedEpisodes: "season:episode" keys back into Stremio's
 * "<anchorVideoId>:<anchorLength>:<base64 zlib bitfield>". fflate's zlibSync stands in for
 * CompressionStream("deflate") (zlib-framed too), which JavaScriptCore does not have.
 */
export function encodeWatchedField(keys: Iterable<string>, videos: Meta["videos"]): string | null {
  if (!videos || videos.length === 0) return null;
  const set = new Set(keys);
  const sorted = canonicalVideoOrder(videos);
  const bytes = new Uint8Array(Math.ceil(sorted.length / 8));
  let lastWatched = -1;
  for (let i = 0; i < sorted.length; i++) {
    const v = sorted[i];
    if (v?.season != null && v?.episode != null && set.has(`${v.season}:${v.episode}`)) {
      bytes[i >> 3] |= 1 << (i & 7);
      lastWatched = i;
    }
  }
  let b64: string;
  try {
    const out = zlibSync(bytes);
    let bin = "";
    for (let i = 0; i < out.length; i++) bin += String.fromCharCode(out[i]);
    b64 = btoa(bin);
  } catch {
    return null;
  }
  const anchorIdx = Math.max(0, lastWatched);
  const anchorVideoId = sorted[anchorIdx]?.id;
  if (!anchorVideoId) return null;
  return `${anchorVideoId}:${anchorIdx + 1}:${b64}`;
}

/** What the picker knows about the stream the player is about to open (streams/types.ts fields). */
export type EngineHints = {
  url: string;
  isLive?: boolean;
  /** behaviorHints.notWebReady: a plain <video> (here AVPlayer) should not be handed it. */
  notWebReady?: boolean | null;
  /** streams/types.ts Container ("mkv" | "mp4" | …) parsed from the release name. */
  container?: string | null;
  /** streams/types.ts HdrFormat ("HDR10" | "HDR10+" | "DV" | "DV+HDR10" | "HLG"). */
  hdrFormat?: string | null;
  filename?: string | null;
  /** use-player-bridge.ts autoFallbackTried: the native engine already failed on this stream. */
  fallbackTried?: boolean;
};

export type EngineChoice = {
  /** "native" is AVPlayer, the TV's stand-in for upstream's html5 engine. */
  engine: "mpv" | "native";
  /** settings.playerEngine as stored (upstream's values, so a synced profile means the same). */
  want: "auto" | "mpv" | "html5";
  reason: "fallback" | "setting" | "live-hls" | "hls" | "dolby-vision" | "default";
};

/** html5/bridge.ts load(): upstream's own HLS test for a source URL. */
export function isHlsUrl(url: string): boolean {
  const lower = url.toLowerCase();
  const bare = lower.split("?")[0];
  return bare.endsWith(".m3u8") || lower.includes("m3u8") || lower.includes("/playlist/");
}

/** Containers AVPlayer opens as a file (it has no Matroska, AVI or WebM demuxer). */
const AVPLAYER_FILE = new Set(["mp4", "m4v", "mov"]);

function extensionOf(s: string | null | undefined): string | null {
  if (!s) return null;
  const bare = s.toLowerCase().split(/[?#]/)[0];
  const m = /\.([a-z0-9]{2,4})$/.exec(bare);
  return m ? m[1] : null;
}

/**
 * The engine a stream plays on. Upstream (use-player-bridge.ts chosenEngine + player-utils.ts
 * pickBridge): a live, web-ready source goes to html5; after an html5 decode/codec/no-audio
 * failure the retry goes to mpv; "html5" and "mpv" are honoured; "auto" picks mpv wherever libmpv
 * exists (the desktop app, which is what the TV is) or the stream is not web-ready.
 *
 * TV mapping (PLAN decision 4): AVPlayer stands in for html5, and Auto hands it the sources it
 * plays better than mpv on Apple TV: web-ready HLS, live or not (AVPlayer cannot open raw
 * MPEG-TS, so what upstream's mpegts.js path plays live stays on mpv), and web-ready Dolby Vision
 * in an MP4-family file (real DV output; mpv only tone-maps it). Everything else stays on mpv.
 * An explicit "mpv" keeps live HLS on mpv too: upstream overrides the setting for live because
 * its desktop mpv window is the weaker live player, which is not true on the TV.
 */
export function pickEngine(want: string | null | undefined, hints: EngineHints): EngineChoice {
  const w: EngineChoice["want"] = want === "mpv" || want === "html5" ? want : "auto";
  if (hints.fallbackTried) return { engine: "mpv", want: w, reason: "fallback" };
  if (w === "html5") return { engine: "native", want: w, reason: "setting" };
  if (w === "mpv") return { engine: "mpv", want: w, reason: "setting" };
  const webReady = hints.notWebReady !== true;
  const hls = isHlsUrl(hints.url ?? "") || hints.container === "m3u8";
  if (webReady && hls) return { engine: "native", want: w, reason: hints.isLive ? "live-hls" : "hls" };
  const dv = hints.hdrFormat ? hints.hdrFormat.startsWith("DV") : /\b(dv|dovi|dolby[ ._-]?vision)\b/i.test(hints.filename ?? "");
  const ext = hints.container?.toLowerCase() || extensionOf(hints.filename) || extensionOf(hints.url);
  if (webReady && !hints.isLive && dv && ext != null && AVPLAYER_FILE.has(ext)) {
    return { engine: "native", want: w, reason: "dolby-vision" };
  }
  return { engine: "mpv", want: w, reason: "default" };
}

/** Swift's entry: the profile's playerEngine setting applied to one stream. */
export function engineFor(profileId: string, linked: boolean, hints: EngineHints): EngineChoice {
  const s = loadEffective(profileId, linked);
  return pickEngine(s.playerEngine, hints);
}
