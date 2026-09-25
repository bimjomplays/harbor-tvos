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
import { readPlayerPrefs, writePlayerPrefs, type PerShowPrefs } from "@/lib/player-prefs";
import {
  readRememberedSub,
  writeRememberedSub,
  rememberedFromChoice,
  rememberedSubAppliesToStream,
  subtitleMediaKey,
  subtitleStreamKey,
  noteSubtitleOrigin,
  lookupSubtitleOrigin,
  type RememberedSub,
} from "@/lib/subtitles/subtitle-memory";
import { langScore, pickBestTrack, normalizeLang } from "@/lib/subtitles/language";
import { isAutoSelectableSubtitleTrack, pickDesiredSubtitleTrack } from "@/lib/subtitles/track-selection";
import type { Settings } from "@/lib/settings";
import type { PlayerStreamRef } from "@/lib/view";
import { stallWaitSec } from "@/lib/player/stall-wait";

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
    // views/player.tsx: an auto-picked stream that has not started within stallWaitMs moves on
    // to the next candidate (opt-in; lib/player/stall-wait.ts clamps the wait to 5–120 s).
    autoNextStreamOnStall: s.autoNextStreamOnStall === true,
    autoNextStreamOnStallSec: stallWaitSec(s.autoNextStreamOnStallSec),
    // use-stub-detection.ts runs only under instantPlay.
    instantPlay: s.instantPlay !== false,
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
 * (bug pass 2) Every local episode resume entry of one title in one read, newest first (lib/resume.ts
 * entryKey `${id}|s${season}e${episode}` + readAll, not exported). Detail asked localResume once per
 * episode — a thousand bridge calls for a long anime. Entries without a position are left out.
 */
export function localResumes(metaId: string): Array<{ season: number; episode: number; ms: number; t: number; pct?: number }> {
  let all: Record<string, { ms?: unknown; t?: unknown; pct?: unknown }> = {};
  try {
    const raw = localStorage.getItem("harbor.resume");
    const parsed = raw ? JSON.parse(raw) : {};
    if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) all = parsed;
  } catch {
    return [];
  }
  const prefix = `${metaId}|s`;
  const out: Array<{ season: number; episode: number; ms: number; t: number; pct?: number }> = [];
  for (const [key, value] of Object.entries(all)) {
    if (!key.startsWith(prefix)) continue;
    const m = /^(\d+)e(\d+)$/.exec(key.slice(prefix.length));
    if (!m || !value || typeof value !== "object") continue;
    const ms = typeof value.ms === "number" && Number.isFinite(value.ms) ? value.ms : 0;
    if (ms <= 0) continue;
    const t = typeof value.t === "number" && Number.isFinite(value.t) ? value.t : 0;
    const pct = typeof value.pct === "number" && Number.isFinite(value.pct) ? value.pct : undefined;
    out.push({ season: Number.parseInt(m[1], 10), episode: Number.parseInt(m[2], 10), ms, t, ...(pct !== undefined ? { pct } : {}) });
  }
  return out.sort((a, b) => b.t - a.t);
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
  // stremio-core construct_and_resize: an anchor that is not in this video list gives an empty
  // field; guessing an offset would land marks on the wrong episodes (review 27).
  if (anchorIdx < 0) return [];
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

// ------------------------------------------------------------------ per-show track memory + rules
// lib/player-prefs.ts (per show: audioLang, subLang, subsOff, subDelaySec; keyed by src.meta.id),
// lib/subtitles/subtitle-memory.ts (per episode: the exact subtitle, or off) and the track choice
// of views/player/hooks/use-track-autoload.ts. The hook's own helpers are not exported upstream, so
// they are copied below verbatim; everything else is upstream's code. Swift hands over the track
// list once the file is open and applies the plan (MPVPlayerController / NativePlayerController).

/** Which title a player shows: upstream keys player-prefs by src.meta.id (the series or movie id). */
export type TrackMemoryKey = {
  metaId: string;
  season?: number | null;
  episode?: number | null;
  genres?: string[] | null;
  /** The stream's release file name: subtitle-memory's streamKey (subtitleStreamKey). */
  filename?: string | null;
};

/** A track as Swift reads it (MPVPlayerController.Track); ids are only unique per type. */
export type TrackIn = {
  id: number | string;
  type: string; // "audio" | "sub"
  lang?: string | null;
  title?: string | null;
  codec?: string | null;
  channels?: string | null;
  external?: boolean;
  forced?: boolean;
  hearingImpaired?: boolean;
  default?: boolean;
  selected?: boolean;
  secondary?: boolean;
  externalFilename?: string | null;
};

type PlanTrack = {
  id: string;
  kind: "audio" | "subtitle";
  label: string;
  lang?: string;
  title?: string;
  external: boolean;
  externalFilename?: string;
  forced: boolean;
  default: boolean;
  selected: boolean;
  secondary: boolean;
};

/** lib/player/mpv.ts track-list mapping: label = title || lang || "type id", then the tags. */
function toPlanTrack(t: TrackIn): PlanTrack {
  const type = t.type === "audio" ? "audio" : "sub";
  const id = String(t.id);
  const lang = t.lang ?? undefined;
  const title = t.title ?? undefined;
  const codec = t.codec ? t.codec.toUpperCase() : undefined;
  const baseLabel = title || lang || `${type} ${id}`;
  const tags: string[] = [];
  if (codec) tags.push(codec);
  if (type === "audio" && t.channels) tags.push(t.channels);
  if (t.forced) tags.push("Forced");
  if (t.hearingImpaired) tags.push("SDH");
  if (t.external) tags.push("External");
  return {
    id,
    kind: type === "audio" ? "audio" : "subtitle",
    label: tags.length > 0 ? `${baseLabel} · ${tags.join(" · ")}` : baseLabel,
    lang,
    title,
    external: t.external === true,
    externalFilename: t.externalFilename ?? undefined,
    forced: t.forced === true,
    default: t.default === true,
    selected: t.selected === true && t.secondary !== true,
    secondary: t.secondary === true,
  };
}

// use-track-autoload.ts helpers (module-private upstream), unchanged.
function blockWords(s: Settings): string[] {
  return (s.trackBlockWords ?? []).map((w) => w.trim().toLowerCase()).filter(Boolean);
}
function trackMatchesWords(t: { title?: string; label?: string }, words: string[]): boolean {
  const hay = `${t.title ?? ""} ${t.label ?? ""}`.toLowerCase();
  return words.some((w) => hay.includes(w));
}
function isForcedTrack(t: { title?: string; label?: string }): boolean {
  return /\bforced\b/i.test(`${t.title ?? ""} ${t.label ?? ""}`);
}
function subsOffFor(prefs: PerShowPrefs | null, s: Settings): boolean {
  if (prefs?.subsOff != null) return prefs.subsOff;
  if (s.subtitlesOffByDefault) return true;
  if (prefs?.subLang) return false;
  return false;
}
function resolveLangPreference(primary: string[] | undefined, fallback: string[] | undefined): string[] {
  if (primary && primary.length > 0) return primary;
  if (fallback && fallback.length > 0) return fallback;
  return ["English"];
}
function isJapanese(lang: string): boolean {
  const l = lang.trim().toLowerCase();
  return l === "ja" || l === "jpn" || l === "jp" || l === "japanese";
}

function streamRefOf(key: TrackMemoryKey | null | undefined): PlayerStreamRef | null {
  const name = key?.filename?.trim();
  return name ? { title: name } : null;
}

function mediaKeyOf(key: TrackMemoryKey): string {
  return subtitleMediaKey(key.metaId, key.season ?? null, key.episode ?? null);
}

function baseName(path: string): string {
  const parts = path.replace(/\\/g, "/").split("/");
  return parts[parts.length - 1] || path;
}

export type TrackPlan = {
  /** Audio track to select; null leaves the current one. */
  audioId: string | null;
  /** "select" subId, "off", or "none" (no automatic choice: the engine's start state stays). */
  sub: "select" | "off" | "none";
  subId: string | null;
  /** subtitle-memory: an added (external) subtitle to fetch again and select. */
  restore: { source: string; lang: string | null; title: string | null } | null;
  /** use-secondary-sub.ts autoPick over settings.secondarySubLang. */
  secondaryId: string | null;
  /** player-prefs subDelaySec (0 when none is saved). */
  subDelaySec: number;
  /** Why, for the player's log lines. */
  notes: string[];
};

/**
 * One pass of use-track-autoload's track effect for a freshly opened file (no user pick yet, no
 * subtitle preselect), plus its subtitle-memory restore effect and use-secondary-sub's auto pick.
 * External tracks are never auto-selected: upstream only auto-picks prepared autoload results.
 */
export function planTracks(settings: Settings, key: TrackMemoryKey | null, tracksIn: TrackIn[]): TrackPlan {
  const tracks = (tracksIn ?? []).map(toPlanTrack);
  const audioTracks = tracks.filter((t) => t.kind === "audio");
  const subtitleTracks = tracks.filter((t) => t.kind === "subtitle");
  const metaId = key?.metaId ?? "";
  const notes: string[] = [];
  const prefs = metaId ? readPlayerPrefs(metaId) : null;
  const genres = key?.genres ?? [];
  const isAnime = metaId.startsWith("kitsu:") || metaId.startsWith("mal:") || genres.some((g) => g.toLowerCase() === "anime");
  const stripJaForNonAnime = (langs: string[]) => {
    if (isAnime) return langs;
    const kept = langs.filter((l) => !isJapanese(l));
    return kept.length > 0 ? kept : langs;
  };
  const baseAudio = stripJaForNonAnime(resolveLangPreference(settings.preferredAudioLangs, settings.preferredLanguages));
  const baseSub = stripJaForNonAnime(resolveLangPreference(settings.preferredSubLangs, settings.preferredLanguages));
  const audioLangs = prefs?.audioLang ? [prefs.audioLang, ...baseAudio.filter((l) => l !== prefs.audioLang)] : baseAudio;
  const subLangs = prefs?.subLang ? [prefs.subLang, ...baseSub.filter((l) => l !== prefs.subLang)] : baseSub;
  const words = blockWords(settings);
  const allow = <T extends { title?: string; label?: string }>(list: T[]): T[] => {
    if (words.length === 0) return list;
    const kept = list.filter((t) => !trackMatchesWords(t, words));
    return kept.length > 0 ? kept : list;
  };

  let audioId: string | null = null;
  let effAudio: PlanTrack | null = null;
  if (audioTracks.length > 0) {
    const cur = audioTracks.find((t) => t.selected) ?? null;
    const want = pickBestTrack(allow(audioTracks), audioLangs);
    effAudio = want ?? cur;
    if (want && (!cur || cur.id !== want.id)) audioId = want.id;
    if (want) notes.push(`audio: ${want.label}${prefs?.audioLang ? " (show's language)" : ""}`);
  }

  let sub: TrackPlan["sub"] = "none";
  let subId: string | null = null;
  let restore: TrackPlan["restore"] = null;
  const remembered: RememberedSub | null = key && metaId ? readRememberedSub(mediaKeyOf(key)) : null;
  const rememberedApplies = rememberedSubAppliesToStream(remembered, streamRefOf(key));
  if (subsOffFor(prefs, settings)) {
    sub = "off";
    notes.push(prefs?.subsOff === true ? "subs: off (remembered)" : "subs: off by default");
  } else if (remembered && rememberedApplies) {
    const sameLang = (a?: string | null, b?: string | null) => normalizeLang(a ?? "") === normalizeLang(b ?? "");
    if (remembered.off) {
      sub = "off";
      notes.push("subs: off (remembered)");
    } else if (remembered.source) {
      const source = remembered.source;
      const existing = subtitleTracks.find((t) => t.externalFilename != null &&
        (t.externalFilename === source || lookupSubtitleOrigin(t.externalFilename) === source));
      if (existing) {
        sub = "select";
        subId = existing.id;
      } else {
        restore = { source, lang: remembered.lang ?? null, title: remembered.title ?? null };
      }
      notes.push(`subs: ${remembered.title ?? remembered.lang ?? "added"} (remembered)`);
    } else {
      const byTrackId = remembered.trackId
        ? subtitleTracks.find((t) => !t.external && t.id === remembered.trackId && sameLang(t.lang, remembered.lang))
        : undefined;
      const want =
        byTrackId ??
        subtitleTracks.find((t) => !t.external && sameLang(t.lang, remembered.lang) && (!remembered.title || t.title === remembered.title)) ??
        subtitleTracks.find((t) => !t.external && sameLang(t.lang, remembered.lang));
      if (want) {
        sub = "select";
        subId = want.id;
        notes.push(`subs: ${want.label} (remembered)`);
      }
    }
  } else if (subtitleTracks.length > 0 && subLangs.length > 0) {
    const nativeAudio = settings.forcedSubsWhenNativeAudio === true && effAudio != null && langScore(effAudio.lang ?? "", subLangs) >= 0;
    const want = nativeAudio
      ? (subtitleTracks
          .filter((track) => isForcedTrack(track) && isAutoSelectableSubtitleTrack(track))
          .sort((a, b) => langScore(b.lang ?? "", subLangs) - langScore(a.lang ?? "", subLangs))[0] ?? null)
      : pickDesiredSubtitleTrack(allow(subtitleTracks), subLangs, settings.preferEmbeddedSubs === true);
    if (want) {
      sub = "select";
      subId = want.id;
      notes.push(`subs: ${want.label}${nativeAudio ? " (forced, native audio)" : ""}`);
    } else if (nativeAudio) {
      notes.push("subs: none (native audio, no forced track)");
    }
  }

  // use-secondary-sub.ts autoPick: the best other track in settings.secondarySubLang.
  let secondaryId: string | null = null;
  const secondaryLang = (settings.secondarySubLang ?? "").trim();
  if (secondaryLang) {
    const primaryId = sub === "select" ? subId : sub === "off" ? null : (subtitleTracks.find((t) => t.selected)?.id ?? null);
    const pick = pickBestTrack(subtitleTracks.filter((t) => t.id !== primaryId), [secondaryLang])?.id ?? null;
    secondaryId = pick != null && pick !== primaryId ? pick : null;
  }

  const delay = typeof prefs?.subDelaySec === "number" && Number.isFinite(prefs.subDelaySec) ? prefs.subDelaySec : 0;
  return { audioId, sub, subId, restore, secondaryId, subDelaySec: delay, notes };
}

/** Swift's entry: the profile's settings applied to one file's tracks. */
export function trackPlan(profileId: string, linked: boolean, key: TrackMemoryKey | null, tracks: TrackIn[]): TrackPlan {
  return planTracks(loadEffective(profileId, linked), key, tracks);
}

/** bp-ten-foot.tsx onAudio: the picked track's language becomes the show's audio language. */
export function rememberAudio(key: TrackMemoryKey | null, track: TrackIn | null): boolean {
  if (!key?.metaId || !track?.lang) return false;
  writePlayerPrefs(key.metaId, { audioLang: track.lang });
  return true;
}

/** shell-layer.tsx onRate: the speed picked for this show (player-prefs rate). */
export function rememberRate(key: TrackMemoryKey | null, rate: number): boolean {
  if (!key?.metaId || typeof rate !== "number" || !Number.isFinite(rate) || rate <= 0) return false;
  writePlayerPrefs(key.metaId, { rate });
  return true;
}

/**
 * use-track-autoload.ts prefsAppliedRef: a title starts at the show's remembered rate, else
 * settings.defaultPlaybackSpeed, else 1.
 */
export function startRate(profileId: string, linked: boolean, key: TrackMemoryKey | null): number {
  const saved = key?.metaId ? readPlayerPrefs(key.metaId)?.rate : undefined;
  const fallback = loadEffective(profileId, linked).defaultPlaybackSpeed;
  const wanted = typeof saved === "number" ? saved : (fallback ?? 1);
  return Number.isFinite(wanted) && wanted > 0 ? wanted : 1;
}

/** bp-ten-foot.tsx onSubDelay: the show's subtitle delay. */
export function rememberSubDelay(key: TrackMemoryKey | null, sec: number): boolean {
  if (!key?.metaId || typeof sec !== "number" || !Number.isFinite(sec)) return false;
  writePlayerPrefs(key.metaId, { subDelaySec: sec });
  return true;
}

/**
 * use-playback-controls.ts rememberSubChoice (bp-ten-foot onSubtitle / onAddSubtitle): a track
 * (or null = off) becomes the show's subtitle language and this episode's remembered subtitle.
 * `source` is the download URL of a subtitle that was just added (rememberedChoiceFromLoad).
 */
export function rememberSubtitle(key: TrackMemoryKey | null, track: TrackIn | null, source?: string | null): boolean {
  if (!key?.metaId) return false;
  const mediaKey = mediaKeyOf(key);
  const streamKey = subtitleStreamKey(streamRefOf(key));
  if (!track) {
    writePlayerPrefs(key.metaId, { subsOff: true });
    writeRememberedSub(mediaKey, { off: true });
    return true;
  }
  const lang = track.lang ?? undefined;
  writePlayerPrefs(key.metaId, lang ? { subLang: lang, subsOff: false } : { subsOff: false });
  const external = track.external === true || !!source;
  const file = track.externalFilename ?? undefined;
  const origin = source || (file ? (lookupSubtitleOrigin(file) ?? lookupSubtitleOrigin(baseName(file))) : undefined);
  writeRememberedSub(mediaKey, rememberedFromChoice({
    id: String(track.id),
    lang,
    title: track.title ?? undefined,
    external,
    externalFilename: file,
    source: external ? (origin ?? file) : undefined,
    streamKey,
  }));
  return true;
}

/**
 * noteSubtitleOrigin: the local file an added subtitle was written to (mpv lists the path,
 * AVPlayer's list the file name) maps back to its download URL, so picking it again remembers the URL.
 */
export function noteSubtitleSource(file: string, source: string): boolean {
  if (!file || !source) return false;
  noteSubtitleOrigin(file, source);
  noteSubtitleOrigin(baseName(file), source);
  return true;
}

/** What is remembered for a title (player-prefs) and its episode (subtitle-memory). */
export function trackMemory(key: TrackMemoryKey | null) {
  if (!key?.metaId) return { prefs: null, subtitle: null };
  return { prefs: readPlayerPrefs(key.metaId), subtitle: readRememberedSub(mediaKeyOf(key)) };
}
