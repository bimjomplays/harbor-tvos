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

/** The last mix handed to the taste step, so the done flourish can deal the viewer's own picks. */
let lastTitles: Meta[] = [];

export async function tasteTitles(profileId: string, linked: boolean): Promise<Meta[]> {
  lastTitles = await buildTasteTitles(profileId, linked);
  return lastTitles;
}

async function buildTasteTitles(profileId: string, linked: boolean): Promise<Meta[]> {
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

// bp-done-flourish.tsx: a stock fan when nothing was picked.
const IMG = "https://image.tmdb.org/t/p/w342";
const FALLBACK = [
  "/rzpHPSEgPTpRs8EHbygwsOw7jC0.jpg",
  "/1g0dhYtq4irTY1GPXvft6k4YLjm.jpg",
  "/iPOn6DinuVyLY17YM9mKuPofV08.jpg",
  "/7V0Ebks0GgpKvQ7QbLAIdX5dos4.jpg",
  "/sfQtVlIHljToOwYjhe21KPGzZWK.jpg",
];

/**
 * use-bp-onboard-facts.ts (the counts the done step reads) plus bp-done-flourish's art: "their own
 * five, not a stock fan. The last thing this flow says should be made of what the person just chose."
 */
export function facts(profileId: string, linked: boolean) {
  const s = loadEffective(profileId, linked);
  const picked = getUpvotedIds();
  const mine = lastTitles.filter((m) => picked.has(m.id) && m.poster).slice(0, 5).map((m) => m.poster as string);
  return {
    servicesOn: Object.values(s.streaming).filter(Boolean).length,
    subLangs: s.preferredSubLangs,
    tastePicks: picked.size,
    art: mine.length > 0 ? mine : FALLBACK.map((p) => `${IMG}${p}`),
  };
}

/**
 * bp-step-tmdb.tsx verify(): TMDB's configuration endpoint with the typed key. A refusal
 * (any non-2xx answer) is "rejected"; a request that never answers (captive portal, a region
 * that blocks TMDB) is "unreachable", where the step offers "Save it anyway". Nothing is saved
 * here: the step writes the key only once TMDB has accepted it (or the viewer keeps it anyway).
 */
// (review 19) A request that hangs (a DNS black hole, a captive portal that never answers) held
// "Checking…" for the host's 60 s request timeout. Past this the step says TMDB could not be
// reached and offers "Save it anyway", as a failed request does.
const TMDB_CHECK_TIMEOUT_MS = 12_000;

export async function checkTmdbKey(key: string, timeoutMs: number = TMDB_CHECK_TIMEOUT_MS): Promise<"ok" | "rejected" | "unreachable"> {
  const k = typeof key === "string" ? key.trim() : "";
  if (!k) return "rejected";
  const ms = typeof timeoutMs === "number" && timeoutMs > 0 ? timeoutMs : TMDB_CHECK_TIMEOUT_MS;
  let timer: ReturnType<typeof setTimeout> | undefined;
  const late = new Promise<"unreachable">((resolve) => { timer = setTimeout(() => resolve("unreachable"), ms); });
  const asked = fetch(`https://api.themoviedb.org/3/configuration?api_key=${encodeURIComponent(k)}`)
    .then((res): "ok" | "rejected" => (res.ok ? "ok" : "rejected"))
    .catch((): "unreachable" => "unreachable");
  try {
    return await Promise.race([asked, late]);
  } finally {
    if (timer !== undefined) clearTimeout(timer);
  }
}
