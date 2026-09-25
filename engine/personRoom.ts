// Person page (bp-person.tsx + use-bp-person.ts without React): facts, Known For, IMDb Top,
// Frequent Collaborators (desktop's ranking, cache-first, fetched off the page load), awards
// from the bundled index, and the filmography sections with sort / minimum rating.
import type { Meta } from "@/lib/cinemeta";
import { creditToMeta, tmdbDepartmentLabelKey, tmdbPerson, tmdbPersonCached, type PersonCredit, type PersonDetail } from "@/lib/providers/tmdb/tmdb-people";
import { t } from "@/lib/i18n";
import { tmdbTitleCredits } from "@/lib/providers/tmdb/tmdb-title-credits";
import { mergeBundledPersonAwards } from "@/lib/awards-history";
import { awardSummary } from "@/lib/providers/wikidata";
import { applyMinRating, rankByRating, sortFilmography, TOP_PERFORMANCE_COUNT, TOP_PERFORMANCE_MIN, type FilmographySort } from "@/views/person/filmography-rank";
import { dedupe, dedupeByMedia, DIRECTOR_JOBS, isCameoOrGuest, notableScore, PRODUCER_JOBS, WRITER_JOBS, calcAge, fmtDate } from "@/views/person/person-utils";
import { rankCollaborators, type Collaborator, type CollaboratorTitle } from "@/views/person/collaborator-rank";
import { readCollaborators, writeCollaborators } from "@/views/person/collaborator-cache";
import { loadEffective } from "@/lib/settings/profile-store";

const IMG = "https://image.tmdb.org/t/p/w342";
const SECTION_CAP = 48;
const KNOWN_FOR_COUNT = 12;
const OTHER_CREW_MIN = 4;
const OTHER_CREW_MAX = 24;
const SAMPLE_SIZE = 20;

const portrait = (path: string | null | undefined): string | null => (!path ? null : path.startsWith("http") ? path : `${IMG}${path}`);
const byPopularity = (a: PersonCredit, b: PersonCredit) => b.popularity - a.popularity;

// bp-person.tsx sectionTitle, translated like upstream's t().
const SECTION_TITLES: Record<string, (n: number) => string> = {
  movies: (n) => t("Movies · {n}", { n }), shows: (n) => t("TV Shows · {n}", { n }), directing: () => t("Directing"),
  writing: () => t("Writing"), producing: () => t("Producing"), otherCrew: () => t("Other Work"),
};

const collabInflight = new Set<number>();
/** (bug pass) use-collaborators setPeople(ranked): this session's answer even when it was not
 *  written (fewer than half the titles resolved), so the page shows it and `page` does not start
 *  another fetch. Without it a failed or empty run fired harbor:person-updated, the page re-read,
 *  found nothing cached and fetched again: an endless loop of TMDB requests. */
const collabSession = new Map<number, Collaborator[]>();

function loadCollaborators(person: PersonDetail, key: string): void {
  if (collabInflight.has(person.id)) return;
  const sample = dedupeByMedia([...person.cast, ...person.crew].filter((c) => !isCameoOrGuest(c))).sort((a, b) => notableScore(b) - notableScore(a)).slice(0, SAMPLE_SIZE);
  if (sample.length === 0) return;
  collabInflight.add(person.id);
  void Promise.all(sample.map((c) => tmdbTitleCredits(key, c.mediaType, c.id).then((credits): CollaboratorTitle | null => (credits ? { key: `${c.mediaType}:${c.id}`, ...credits } : null)).catch(() => null)))
    .then((fetched) => {
      const resolved = fetched.filter((t): t is CollaboratorTitle => t !== null);
      const ranked = rankCollaborators(resolved, person.id);
      collabSession.delete(person.id);
      collabSession.set(person.id, ranked);
      while (collabSession.size > 48) collabSession.delete(collabSession.keys().next().value as number);
      if (resolved.length * 2 >= sample.length) writeCollaborators(person.id, ranked);
      window.dispatchEvent(new CustomEvent("harbor:person-updated", { detail: { personId: person.id } }));
    })
    .finally(() => collabInflight.delete(person.id))
    .catch(() => undefined);   // (bug pass) a throw in the ranking must not surface as an unhandled rejection
}

// lib/rankings.tsx RankingsProvider (use-bp-person deptRank = rank(person.id, knownForDepartment
// || "Acting")): TMDB's person/popular pages 1-5, bucketed by known_for_department (Acting,
// Directing, Production, Writing), skipping adult entries and anyone with no known-for title of
// 200+ votes, the first 100 of each ranked in order; kept 6 h. Upstream loads it once for the
// app; fetchPopular is not exported, so it is repeated here. The page reads what is cached and
// starts a load when there is none; harbor:person-updated re-reads the page when it lands.
const RANK_PAGES = 5;
const RANK_TOP = 100;
const RANK_STALE_MS = 6 * 60 * 60 * 1000;
let rankCache: { loadedAt: number; buckets: Record<string, number[]> } | null = null;
let rankInflight: Promise<boolean> | null = null;

function loadRankings(key: string): Promise<boolean> {
  if (rankCache && Date.now() - rankCache.loadedAt < RANK_STALE_MS) return Promise.resolve(false);
  if (rankInflight) return rankInflight;
  rankInflight = (async () => {
    type Popular = { results?: Array<{ id: number; adult?: boolean; known_for_department?: string; known_for?: Array<{ adult?: boolean; vote_count?: number }> }> };
    const pages = await Promise.all(Array.from({ length: RANK_PAGES }, (_, i) => i + 1).map((p) =>
      fetch(`https://api.themoviedb.org/3/person/popular?api_key=${key}&page=${p}`)
        .then((r) => (r.ok ? (r.json() as Promise<Popular>) : null))
        .catch(() => null)));
    const answered = pages.filter((p): p is Popular => p !== null);
    const buckets: Record<string, number[]> = { Acting: [], Directing: [], Production: [], Writing: [] };
    const seen = new Set<number>();
    for (const p of answered.flatMap((x) => x.results ?? [])) {
      const dept = p.known_for_department;
      if (!dept || !(dept in buckets)) continue;
      if (p.adult) continue;
      const kf = Array.isArray(p.known_for) ? p.known_for : [];
      if (kf.some((k) => k.adult)) continue;
      if (!kf.some((k) => (k.vote_count ?? 0) >= 200)) continue;
      if (seen.has(p.id)) continue;
      if (buckets[dept].length >= RANK_TOP) continue;
      seen.add(p.id);
      buckets[dept].push(p.id);
    }
    // Only a load that heard from TMDB is kept (the next Person page tries again otherwise) and
    // worth a re-read of the open page, so an offline run never loops.
    if (answered.length === 0) return false;
    rankCache = { loadedAt: Date.now(), buckets };
    return true;
  })().finally(() => { rankInflight = null; });
  return rankInflight;
}

/** RankingsProvider rank(id, dept): Directing, Production and Writing have their own lists; any other department reads the actors'. */
function deptRankOf(id: number, dept: string): number | null {
  if (!rankCache) return null;
  const bucket = dept === "Directing" || dept === "Production" || dept === "Writing" ? dept : "Acting";
  const at = rankCache.buckets[bucket].indexOf(id);
  return at >= 0 ? at + 1 : null;
}

export async function page(personId: number, profileId: string, linked: boolean, sort: FilmographySort = "popularity", minRating = 0) {
  const s = loadEffective(profileId, linked);
  if (!s.tmdbKey) return { hasKey: false, person: null };
  const person = tmdbPersonCached(personId) ?? (await tmdbPerson(s.tmdbKey, personId).catch(() => null));
  if (!person) return { hasKey: true, person: null };
  const cast = dedupe(person.cast).sort(byPopularity);
  const crew = person.crew.slice().sort(byPopularity);
  const dept = person.knownForDepartment;
  const knownPool = dept === "Acting" || !dept ? cast.filter((c) => !isCameoOrGuest(c)) : dedupeByMedia(crew.filter((c) => c.department === dept));
  const knownFor = knownPool.slice().sort((a, b) => notableScore(b) - notableScore(a)).slice(0, KNOWN_FOR_COUNT);
  const ranked = rankByRating(cast.filter((c) => !isCameoOrGuest(c)), TOP_PERFORMANCE_COUNT);
  const topRated = ranked.length >= TOP_PERFORMANCE_MIN ? ranked : [];
  const crewIn = (jobs: Set<string>) => dedupe(crew.filter((c) => jobs.has(c.job ?? "")));
  const other = dedupe(crew.filter((c) => !DIRECTOR_JOBS.has(c.job ?? "") && !WRITER_JOBS.has(c.job ?? "") && !PRODUCER_JOBS.has(c.job ?? "")));
  const raw = [
    { id: "movies", credits: cast.filter((c) => c.mediaType === "movie") },
    { id: "shows", credits: cast.filter((c) => c.mediaType === "tv") },
    { id: "directing", credits: crewIn(DIRECTOR_JOBS) },
    { id: "writing", credits: crewIn(WRITER_JOBS) },
    { id: "producing", credits: crewIn(PRODUCER_JOBS) },
    { id: "otherCrew", credits: other.length > OTHER_CREW_MIN ? other.slice(0, OTHER_CREW_MAX) : [] },
  ];
  const shaped = raw.map((sec) => ({ id: sec.id, credits: sortFilmography(applyMinRating(sec.credits, minRating), sort).slice(0, SECTION_CAP) }));
  const count = (list: Array<{ credits: PersonCredit[] }>) => list.reduce((n, x) => n + x.credits.length, 0);
  const awards = awardSummary(mergeBundledPersonAwards(null, person.name)).filter((a) => a.wins > 0 || a.nominations > 0);
  // use-collaborators: a cached list (even an empty one) is the answer; only a miss fetches (bug pass).
  const known = readCollaborators(personId) ?? collabSession.get(personId) ?? null;
  const collaborators: Collaborator[] = known ?? [];
  if (known === null) loadCollaborators(person, s.tmdbKey);
  const age = person.birthday ? calcAge(person.birthday, person.deathday) : null;
  const facts: string[] = [];
  if (person.birthday) {
    const born = t("Born {date}", { date: fmtDate(person.birthday) });
    facts.push(age != null ? `${born} · ${age}` : born);
  }
  if (person.deathday) facts.push(t("Died {date}", { date: fmtDate(person.deathday) }));
  // bp-person.tsx departmentLabel: TMDB's department through its catalog key when one exists.
  const departmentKey = person.knownForDepartment ? tmdbDepartmentLabelKey(person.knownForDepartment) : undefined;
  const department = person.knownForDepartment && departmentKey ? t(departmentKey) : person.knownForDepartment;
  if (person.placeOfBirth) facts.push(person.placeOfBirth);
  const metas = (list: PersonCredit[]): Meta[] => list.map(creditToMeta);
  // bp-person.tsx "Top {n}" beside the department: this person's place in their department's list.
  if (!rankCache || Date.now() - rankCache.loadedAt >= RANK_STALE_MS) {
    const id = person.id;
    void loadRankings(s.tmdbKey).then((heard) => {
      if (heard) window.dispatchEvent(new CustomEvent("harbor:person-updated", { detail: { personId: id } }));
    }).catch(() => undefined);
  }
  const deptRank = deptRankOf(person.id, person.knownForDepartment || "Acting");
  return {
    hasKey: true,
    person: { id: person.id, name: person.name, department, portrait: portrait(person.profilePath), imdbId: person.imdbId, biography: person.biography?.trim() ?? "", facts, deptRank, topLabel: deptRank != null ? t("Top {n}", { n: deptRank }) : null },
    knownFor: metas(knownFor),
    topRated: metas(topRated),
    collaborators: collaborators.map((c) => ({ id: c.id, name: c.name, portrait: portrait(c.profilePath), role: c.role ?? null, titles: c.titles })),
    awards: awards.map((a) => ({ type: a.type, wins: a.wins, nominations: a.nominations })),
    sections: shaped.filter((x) => x.credits.length > 0).map((x) => ({ id: x.id, title: SECTION_TITLES[x.id](x.credits.length), metas: metas(x.credits) })),
    total: count(raw), shownTotal: count(shaped), sort, minRating,
  };
}
