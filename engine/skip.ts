// Skip intro/outro/recap segments: lib/skip-intro useSkipSegments as one async function.
// Simkl-based anime → imdb/tmdb resolution is left out until the Simkl tracker arrives.
import type { Meta } from "@/lib/cinemeta";
import type { PlayEpisode } from "@/lib/view";
import { loadEffective } from "@/lib/settings/profile-store";
import { mergeSegments, type SkipSegment } from "@/lib/skip-intro";
import { fetchAniSkipSegments, kitsuToMal } from "@/lib/skip-intro/aniskip";
import { fetchIntroDbSegments, readTheIntroDbKey, setTheIntroDbApiKey } from "@/lib/skip-intro/theintrodb";
import { fetchSkipDbSegments } from "@/lib/skip-intro/skipdb";
import { fetchIntroDbAppSegments } from "@/lib/skip-intro/introdb-app";
import { chaptersToSegments } from "@/lib/skip-intro/chapters";
import type { Chapter } from "@/lib/player/bridge";

const MIN_OUTRO_START_FRACTION = 0.5;
const MAX_SEGMENT_SEC = 360;

function parseKitsuId(id: string): number | null {
  if (!id.startsWith("kitsu:")) return null;
  const n = parseInt(id.slice("kitsu:".length).split(":")[0], 10);
  return Number.isFinite(n) ? n : null;
}

export async function segments(
  profileId: string,
  linked: boolean,
  meta: Meta,
  episode: PlayEpisode | null,
  durationSec: number,
  chapters?: Chapter[] | null,
): Promise<SkipSegment[]> {
  if (durationSec <= 0) return [];
  const settings = loadEffective(profileId, linked);
  setTheIntroDbApiKey(readTheIntroDbKey(settings));
  const kitsuId = parseKitsuId(meta.id);
  const epNum = episode?.episode;
  const introSeason = episode?.imdbSeason ?? episode?.season;
  const introEpisode = episode?.imdbEpisode ?? episode?.episode;
  const introDbId = meta.id.startsWith("tt") || meta.id.startsWith("tmdb:") ? meta.id
    : episode?.imdbId && episode.imdbId.startsWith("tt") ? episode.imdbId : meta.id;
  const skipImdbId = meta.id.startsWith("tt") ? meta.id
    : episode?.imdbId && episode.imdbId.startsWith("tt") ? episode.imdbId : null;
  const ep = introSeason != null && introEpisode != null ? { season: introSeason, episode: introEpisode } : undefined;
  const quiet = <T,>(p: Promise<T>, fallback: T) => p.catch(() => fallback);

  const [aniSkip, introDb, skipDb, introDbApp] = await Promise.all([
    (async () => {
      if (kitsuId == null || epNum == null) return [] as SkipSegment[];
      const malId = await quiet(kitsuToMal(kitsuId), null);
      return malId == null ? [] : quiet(fetchAniSkipSegments(malId, epNum, durationSec), [] as SkipSegment[]);
    })(),
    introDbId.startsWith("tmdb:") || introDbId.startsWith("tt") ? quiet(fetchIntroDbSegments(introDbId, ep, durationSec), [] as SkipSegment[]) : Promise.resolve([] as SkipSegment[]),
    skipImdbId ? quiet(fetchSkipDbSegments(skipImdbId, ep, durationSec), [] as SkipSegment[]) : Promise.resolve([] as SkipSegment[]),
    skipImdbId && ep ? quiet(fetchIntroDbAppSegments(skipImdbId, ep), [] as SkipSegment[]) : Promise.resolve([] as SkipSegment[]),
  ]);

  // (player tracks pass) useSkipSegments' fromChapters: the file's own "Opening" / "Ending" /
  // "Recap" chapters (mpv chapter-list) are the last source, as upstream merges them.
  const list = (chapters ?? []).filter((c) => c && typeof c.startSec === "number" && Number.isFinite(c.startSec) && c.startSec >= 0)
    .map((c) => ({ title: typeof c.title === "string" ? c.title : "", startSec: c.startSec }));
  const fromChapters = chaptersToSegments(list, durationSec);
  const minOutroStart = durationSec * MIN_OUTRO_START_FRACTION;
  return mergeSegments([aniSkip, skipDb, introDb, introDbApp, fromChapters])
    .filter((s) => s.startSec < durationSec)
    .map((s) => (s.endSec > durationSec ? { ...s, endSec: durationSec } : s))
    .filter((s) => { const len = s.endSec - s.startSec; return len >= 2 && len <= MAX_SEGMENT_SEC; })
    .filter((s) => s.kind !== "outro" || s.startSec >= minOutroStart);
}
