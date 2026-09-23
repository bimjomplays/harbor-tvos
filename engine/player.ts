// Stage 3/4 glue: resume position and progress writes (local resume, local CW, Stremio library).
// Mirrors src/views/player/hooks/use-resume-autosave.ts + use-stremio-sync.ts in simplified form
// (docs/player-spec.md §3); cadence is the Swift side's job.
import { readResumeEntry, saveResumeMs, clearResume } from "@/lib/resume";
import { saveLocalCw, clearLocalCw } from "@/lib/local-cw";
import { libraryGetOne, libraryPut, type LibraryItem } from "@/lib/stremio";
import { resolveStartMs } from "@/lib/player/resume-start";
import type { Meta } from "@/lib/cinemeta";

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
  if (watched && type === "movie") clearLocalCw(p.meta.id);
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
