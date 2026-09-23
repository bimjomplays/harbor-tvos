// Person page (bp-person.tsx + use-bp-person.ts without React): facts, Known For, IMDb Top,
// Frequent Collaborators (desktop's ranking, cache-first, fetched off the page load), awards
// from the bundled index, and the filmography sections with sort / minimum rating.
import type { Meta } from "@/lib/cinemeta";
import { creditToMeta, tmdbPerson, tmdbPersonCached, type PersonCredit, type PersonDetail } from "@/lib/providers/tmdb/tmdb-people";
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

const SECTION_TITLES: Record<string, (n: number) => string> = {
  movies: (n) => `Movies · ${n}`, shows: (n) => `TV Shows · ${n}`, directing: () => "Directing",
  writing: () => "Writing", producing: () => "Producing", otherCrew: () => "Other Work",
};

const collabInflight = new Set<number>();

function loadCollaborators(person: PersonDetail, key: string): void {
  if (collabInflight.has(person.id)) return;
  const sample = dedupeByMedia([...person.cast, ...person.crew].filter((c) => !isCameoOrGuest(c))).sort((a, b) => notableScore(b) - notableScore(a)).slice(0, SAMPLE_SIZE);
  if (sample.length === 0) return;
  collabInflight.add(person.id);
  void Promise.all(sample.map((c) => tmdbTitleCredits(key, c.mediaType, c.id).then((credits): CollaboratorTitle | null => (credits ? { key: `${c.mediaType}:${c.id}`, ...credits } : null)).catch(() => null)))
    .then((fetched) => {
      const resolved = fetched.filter((t): t is CollaboratorTitle => t !== null);
      const ranked = rankCollaborators(resolved, person.id);
      if (resolved.length * 2 >= sample.length) writeCollaborators(person.id, ranked);
      window.dispatchEvent(new CustomEvent("harbor:person-updated", { detail: { personId: person.id } }));
    })
    .finally(() => collabInflight.delete(person.id));
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
  let collaborators: Collaborator[] = readCollaborators(personId) ?? [];
  if (collaborators.length === 0) loadCollaborators(person, s.tmdbKey);
  const age = person.birthday ? calcAge(person.birthday, person.deathday) : null;
  const facts: string[] = [];
  if (person.birthday) facts.push(`Born ${fmtDate(person.birthday)}${age != null ? ` · ${age}` : ""}`);
  if (person.deathday) facts.push(`Died ${fmtDate(person.deathday)}`);
  if (person.placeOfBirth) facts.push(person.placeOfBirth);
  const metas = (list: PersonCredit[]): Meta[] => list.map(creditToMeta);
  return {
    hasKey: true,
    person: { id: person.id, name: person.name, department: person.knownForDepartment, portrait: portrait(person.profilePath), imdbId: person.imdbId, biography: person.biography?.trim() ?? "", facts },
    knownFor: metas(knownFor),
    topRated: metas(topRated),
    collaborators: collaborators.map((c) => ({ id: c.id, name: c.name, portrait: portrait(c.profilePath), role: c.role ?? null, titles: c.titles })),
    awards: awards.map((a) => ({ type: a.type, wins: a.wins, nominations: a.nominations })),
    sections: shaped.filter((x) => x.credits.length > 0).map((x) => ({ id: x.id, title: SECTION_TITLES[x.id](x.credits.length), metas: metas(x.credits) })),
    total: count(raw), shownTotal: count(shaped), sort, minRating,
  };
}
