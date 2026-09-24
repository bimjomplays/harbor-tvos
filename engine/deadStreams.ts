// lib/dead-streams.ts for the TV: the store of streams that did not play, which the picker's
// auto candidates skip (streams.ts autoCandidates → isStreamDead, use-auto-candidates.ts).
// The player marks a stream dead when an auto-picked one fails to open or stalls before its first
// frame (views/player.tsx, autoNextStreamOnStall) or when a file turns out to be a stub
// (views/player/hooks/use-stub-detection.ts); the stub also leaves the notice the next picker
// shows (auto-play-transition.tsx / play-picker.tsx consumeRecentStubEvent).
import {
  clearDeadStreams,
  consumeRecentStubEvent,
  isStreamDead,
  markStreamDead,
  recordStubEvent,
  shouldFlagAsStub,
  streamFingerprint,
  SHORT_PLAYBACK_SEC,
  STUB_TTL_MS,
} from "@/lib/dead-streams";
import { clearPlayback, readPlayback, streamMatchesEntry } from "@/lib/playback-history";
import type { Meta } from "@/lib/cinemeta";

/** streamsRoom.deadRef's shape (view.ts PlayerStreamRef, trimmed). */
export type DeadRef = {
  infoHash?: string | null;
  fileIdx?: number | null;
  url?: string | null;
  addonId?: string | null;
  title?: string | null;
  parsedTitle?: string | null;
  resolution?: string | null;
  source?: string | null;
  size?: number | null;
};

/**
 * views/player.tsx `markStreamDead(src.streamRef, "load-failed", STUB_TTL_MS)`: an auto-picked
 * stream that errored or stalled before playing stays out of the auto candidates for 4 hours.
 */
export function markDead(ref: DeadRef | null, reason = "load-failed"): boolean {
  if (!ref || !streamFingerprint(ref)) return false;
  markStreamDead(ref, reason, STUB_TTL_MS);
  return true;
}

export function isDead(ref: DeadRef | null): boolean {
  return !!ref && isStreamDead(ref);
}

/** auto-play-transition.tsx / play-picker.tsx: a stub recorded in the last `maxAgeMs`, once. */
export function consumeStubEvent(maxAgeMs = 8000): string | null {
  return consumeRecentStubEvent(maxAgeMs)?.reason ?? null;
}

export function clear(): void {
  clearDeadStreams();
}

export type StubInput = {
  meta: Meta;
  /** The URL the player opened (PlayerSrc.url). */
  url: string;
  /** PlayerSrc.title, the fallback title for the fingerprint. */
  title?: string | null;
  ref?: DeadRef | null;
  durationSec: number;
  /** PlayerSnapshot.status === "playing". */
  playing: boolean;
  season?: number | null;
  episode?: number | null;
};

/**
 * use-stub-detection.ts (under settings.instantPlay, which the caller checks): a movie or episode
 * whose file plays for under SHORT_PLAYBACK_SEC is a stub (an uncached debrid placeholder). It is
 * marked dead for 4 hours, the stub event is recorded for the next picker's notice, and
 * use-player-exit onStubEject forgets the remembered pick when it was this stream. True when the
 * player should send the viewer back to the picker.
 */
export function flagStub(input: StubInput): boolean {
  const { meta, url, title, ref, durationSec, playing } = input;
  if (meta.id?.startsWith("iptv:") || meta.id?.startsWith("url:")) return false;
  const metaType = String(meta.type ?? "").toLowerCase();
  if (metaType && !["movie", "series", "anime"].includes(metaType)) return false;
  if (/\.m3u8(\?|#|$)/i.test(url)) return false;
  if (durationSec <= 0 || durationSec >= SHORT_PLAYBACK_SEC) return false;
  if (!playing) return false;
  const runtimeMin = meta.runtime ? parseInt(meta.runtime, 10) : null;
  const isAnime = meta.id?.startsWith("kitsu:") || meta.id?.startsWith("mal:");
  const flag = shouldFlagAsStub({ durationSec, runtimeMinutes: runtimeMin, isAnime, bytesAdvertised: ref?.size ?? null });
  if (!flag) return false;
  const sf = {
    infoHash: ref?.infoHash ?? undefined,
    fileIdx: undefined,
    url,
    addonId: ref?.addonId ?? "",
    title: ref?.title ?? title ?? null,
  };
  const reason = `stub_${Math.round(durationSec)}s`;
  markStreamDead(sf, reason, STUB_TTL_MS);
  recordStubEvent(reason);
  if (ref) {
    const season = input.season ?? undefined;
    const episode = input.episode ?? undefined;
    const remembered = readPlayback(meta.id, season, episode);
    if (remembered && streamMatchesEntry(ref, remembered)) clearPlayback(meta.id, season, episode);
  }
  return true;
}
