// onboarding/use-bp-taste-titles.ts + bp-step-taste.tsx without React: a 40-title mix (TMDB trending
// movies/series and two per genre; Cinemeta tops without a key) and the upvotes that seed Discover.
import { topMovies, topSeries, type Meta } from "@/lib/cinemeta";
import { tmdbDiscover, tmdbTrending } from "@/lib/providers/tmdb";
import { getUpvotedIds, setVote } from "@/lib/feed/preferences";
import { loadEffective } from "@/lib/settings/profile-store";

const CAP = 40;
const GENRE_IDS = ["28", "35", "18", "878", "27", "53", "10749", "16", "14", "80", "37", "12", "9648", "99", "10752"];
const GENRE_FALLBACK = ["Western", "Documentary", "Animation", "Crime", "Comedy"];

function mix(lists: Meta[][]): Meta[] {
  const seen = new Set<string>();
  const out: Meta[] = [];
  const longest = Math.max(0, ...lists.map((l) => l.length));
  for (let i = 0; i < longest && out.length < CAP; i += 1) {
    for (const list of lists) {
      const m = list[i];
      if (m?.poster && !seen.has(m.id)) {
        seen.add(m.id);
        out.push(m);
        if (out.length >= CAP) break;
      }
    }
  }
  return out;
}

export async function tasteTitles(profileId: string, linked: boolean): Promise<Meta[]> {
  const tmdbKey = loadEffective(profileId, linked).tmdbKey;
  if (tmdbKey) {
    const [movies, series, ...byGenre] = await Promise.all([
      tmdbTrending(tmdbKey, "movie", "week").catch(() => [] as Meta[]),
      tmdbTrending(tmdbKey, "tv", "week").catch(() => [] as Meta[]),
      ...GENRE_IDS.map((id) => tmdbDiscover(tmdbKey, "movie", { with_genres: id, sort_by: "popularity.desc", "vote_count.gte": "800", "vote_average.gte": "6.4" }).then((r) => r.slice(0, 2)).catch(() => [] as Meta[])),
    ]);
    const mixed = mix([movies, series, ...byGenre]);
    if (mixed.length >= 16) return mixed;
  }
  const [m, s, ...genreMovies] = await Promise.all([
    topMovies().catch(() => [] as Meta[]),
    topSeries().catch(() => [] as Meta[]),
    ...GENRE_FALLBACK.map((g) => topMovies(g).catch(() => [] as Meta[])),
  ]);
  return mix([m, s, ...genreMovies]);
}

/** Written on select, never on Continue (bp-step-taste toggle). */
export function vote(id: string, up: boolean, name: string, type: string): string[] {
  setVote(id, up ? "up" : null, { name, type: type as never });
  return Array.from(getUpvotedIds());
}

export function upvoted(): string[] {
  return Array.from(getUpvotedIds());
}
