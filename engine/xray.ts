// X-Ray while paused (components/player/xray/*, lib/xray/use-xray-cast.ts) as data for the TV's
// player overlay (App/Sources/Player/PlayerXRay.swift). settings.xrayEnabled, off by default.
//
// Upstream's rail leads with the faces matched on screen (lib/face, ONNX models over captured
// frames) and falls back to the cast list when matching cannot run. The TV has no face engine,
// so the rail is always that cast fallback and the browser has no "In scene" tab; Cast, Crew and
// About follow xray-browser.tsx / xray-about.tsx.
import type { Meta } from "@/lib/cinemeta";
import { tmdbDetails, type CastEntry, type CrewEntry, type TmdbDetail } from "@/lib/providers/tmdb/tmdb-details";
import { fetchTvdbCast } from "@/lib/providers/tvdb-cast";
import { loadEffective } from "@/lib/settings/profile-store";
import { t } from "@/lib/i18n";

// xray-actor-card.tsx IMG / photoOf / initials.
const IMG = "https://image.tmdb.org/t/p/w185";

export type XrayPerson = {
  /** TMDB person id; TVDB's fallback cast carries negative ids (tvdb-cast.ts toCast). */
  id: number;
  name: string;
  sub: string | null;
  photo: string | null;
  initials: string;
  /** xray-rail / xray-browser React key `${p.id}:${p.sub ?? ""}`: unique per card. */
  key: string;
};

export type XrayAbout = {
  title: string;
  logo: string | null;
  tagline: string | null;
  overview: string | null;
  genres: string[];
  year: string | null;
  runtime: string | null;
  rating: string | null;
  votes: string | null;
  status: string | null;
  facts: Array<{ label: string; value: string }>;
  /** The big still (the title's backdrop first); strip thumbnails swap it. */
  hero: string | null;
  videos: Array<{ ytId: string; name: string; thumb: string }>;
  /** stripBackdrops: up to nine thumbnails with the videos first. */
  strip: string[];
  /** The thumbnail row shows when there is a video or more than one still. */
  showStrip: boolean;
};

export type XrayData = {
  needsTmdbKey: boolean;
  /** Whether TMDB answered (xray-browser.tsx: no details and no scene people → the key note). */
  hasDetails: boolean;
  /** xray-overlay.tsx castFallback: TMDB's cast, else TVDB's (use-xray-cast). */
  rail: XrayPerson[];
  /** xray-browser.tsx castPeople(details): TMDB only. */
  cast: XrayPerson[];
  crew: XrayPerson[];
  about: XrayAbout | null;
  tabs: Array<{ id: "cast" | "crew" | "about"; label: string }>;
  /** The tab the browser opens on (upstream: "in-scene" when faces matched, else "cast"). */
  initialTab: "cast" | "crew" | "about" | null;
  /** xray-rail status line when there is nothing to list. */
  railStatus: string | null;
  /** xray-browser.tsx Empty labels. */
  empty: { details: string; cast: string; crew: string };
};

export function photoOf(profilePath: string | null | undefined): string | null {
  if (!profilePath) return null;
  return profilePath.startsWith("http") ? profilePath : `${IMG}${profilePath}`;
}

export function initials(name: string): string {
  const parts = name.trim().split(/\s+/).filter(Boolean);
  return ((parts[0]?.[0] ?? "") + (parts.length > 1 ? parts[parts.length - 1][0] : "")).toUpperCase() || "?";
}

function person(id: number, name: string, sub: string | null | undefined, profilePath: string | null): XrayPerson {
  const s = sub && sub.trim() ? sub : null;
  return { id, name, sub: s, photo: photoOf(profilePath), initials: initials(name), key: `${id}:${s ?? ""}` };
}

/** Upstream renders each card with a `${id}:${sub}` React key; the TV keeps the first of any repeat. */
function uniqueByKey(list: XrayPerson[]): XrayPerson[] {
  const seen = new Set<string>();
  return list.filter((p) => (seen.has(p.key) ? false : (seen.add(p.key), true)));
}

// xray-browser.tsx CREW_PRIORITY / crewPeople.
const CREW_PRIORITY: Record<string, number> = {
  Director: 0,
  Creator: 0,
  Writer: 1,
  Screenplay: 1,
  Story: 1,
  "Original Music Composer": 2,
  Composer: 2,
  Music: 2,
  "Director of Photography": 3,
  Editor: 4,
  Producer: 5,
  "Executive Producer": 6,
};

export function crewPeople(crew: CrewEntry[]): XrayPerson[] {
  const byId = new Map<number, { name: string; jobs: string[]; profilePath: string | null; best: number }>();
  for (const c of crew) {
    const pr = CREW_PRIORITY[c.job];
    if (pr === undefined) continue;
    const e = byId.get(c.id) ?? { name: c.name, jobs: [], profilePath: c.profilePath, best: 99 };
    if (!e.jobs.includes(c.job)) e.jobs.push(c.job);
    e.best = Math.min(e.best, pr);
    if (!e.profilePath && c.profilePath) e.profilePath = c.profilePath;
    byId.set(c.id, e);
  }
  return [...byId.entries()]
    .map(([id, e]) => ({ id, e }))
    .sort((a, b) => a.e.best - b.e.best || a.e.name.localeCompare(b.e.name))
    .map(({ id, e }) => person(id, e.name, e.jobs.join(", "), e.profilePath));
}

function castPeople(cast: CastEntry[]): XrayPerson[] {
  return uniqueByKey(cast.map((c) => person(c.id, c.name, c.character, c.profilePath)));
}

// xray-about.tsx fmtVotes.
export function fmtVotes(n: number): string {
  if (n >= 1_000_000) return (n / 1_000_000).toFixed(1).replace(/\.0$/, "") + "M";
  if (n >= 1_000) return Math.round(n / 1_000) + "K";
  return String(n);
}

const YT_THUMB = (id: string) => `https://img.youtube.com/vi/${id}/mqdefault.jpg`;

// xray-about.tsx collectVideos: the lead trailer, then TMDB's extra videos, each YouTube id once.
function collectVideos(details: TmdbDetail | null, title: string): XrayAbout["videos"] {
  const seen = new Set<string>();
  const out: XrayAbout["videos"] = [];
  const push = (ytId: string | null | undefined, name: string) => {
    if (!ytId || seen.has(ytId)) return;
    seen.add(ytId);
    out.push({ ytId, name, thumb: YT_THUMB(ytId) });
  };
  push(details?.trailerYtId, `${title} trailer`);
  for (const v of details?.extraVideos ?? []) push(v.ytId, v.name || v.type || title);
  return out;
}

/** xray-about.tsx XrayAbout, as data. */
export function aboutOf(meta: Meta, details: TmdbDetail | null): XrayAbout | null {
  // xray-browser.tsx hasAbout.
  if (!(details?.overview || meta.description)) return null;
  const title = details?.title || meta.name;
  const genres = (details?.genres?.length ? details.genres : meta.genres) ?? [];
  const votes = details?.voteCount ?? 0;
  const network = details?.networks?.[0] ?? details?.productionCompanies?.[0];
  const language = details?.spokenLanguages?.[0] ?? details?.originalLanguage;
  const country = details?.productionCountries?.[0];
  const helmers = details?.directors?.length
    ? { label: t("Director"), people: details.directors }
    : details?.creators?.length
      ? { label: t("Creator"), people: details.creators }
      : null;
  const writers = details?.writers ?? [];
  const facts: XrayAbout["facts"] = [];
  // FactPeople shows the first three names.
  if (helmers) facts.push({ label: helmers.label, value: helmers.people.slice(0, 3).map((p) => p.name).join(", ") });
  if (writers.length) facts.push({ label: t("Writers"), value: writers.slice(0, 3).map((p) => p.name).join(", ") });
  if (network) facts.push({ label: t("Network"), value: network });
  if (language) facts.push({ label: t("Language"), value: language });
  if (country) facts.push({ label: t("Country"), value: country });
  const list = details?.gallery?.backdrops ?? [];
  const base = details?.backdrop || meta.background;
  const backdrops = [...new Set(base ? [base, ...list.filter((b) => b !== base)] : list)];
  const videos = collectVideos(details, title);
  const strip = backdrops.slice(0, Math.max(0, 9 - videos.length));
  const rating = details?.rating || meta.imdbRating;
  return {
    title,
    logo: details?.logo || meta.logo || null,
    tagline: details?.tagline || null,
    overview: details?.overview || meta.description || null,
    genres,
    year: details?.year || meta.releaseInfo || null,
    runtime: details?.runtime || meta.runtime || null,
    rating: rating || null,
    votes: rating && votes > 0 ? fmtVotes(votes) : null,
    status: details?.status || null,
    facts,
    hero: backdrops[0] ?? null,
    videos,
    strip,
    showStrip: videos.length > 0 || strip.length > 1,
  };
}

function kitsuIdOf(meta: Meta): number | null {
  const m = meta.id?.match(/^kitsu:(\d+)/);
  return m ? Number(m[1]) : null;
}

/** xray-browser.tsx tabs + initial tab, and the rail's status line, from what was loaded. */
export function assemble(meta: Meta, details: TmdbDetail | null, fallback: CastEntry[], hasKey: boolean): XrayData {
  const rail = castPeople(fallback);
  const cast = castPeople(details?.cast ?? []);
  const crew = details ? crewPeople(details.crew ?? []) : [];
  const about = aboutOf(meta, details);
  const tabs: XrayData["tabs"] = [];
  if (cast.length) tabs.push({ id: "cast", label: t("Cast") });
  if (crew.length) tabs.push({ id: "crew", label: t("Crew") });
  if (about) tabs.push({ id: "about", label: t("About") });
  const detailsNote = t("Add a TMDB key in Settings to see the cast, crew, and details.");
  return {
    needsTmdbKey: !hasKey,
    hasDetails: details !== null,
    rail,
    cast,
    crew,
    about,
    tabs,
    initialTab: tabs[0]?.id ?? null,
    railStatus: rail.length > 0 ? null : !hasKey ? detailsNote : t("No cast information for this title."),
    empty: { details: detailsNote, cast: t("No cast information for this title."), crew: t("No crew information for this title.") },
  };
}

const cache = new Map<string, { at: number; value: XrayData }>();
const TTL_MS = 10 * 60_000;

/**
 * use-xray-cast.ts: TMDB details when there is a key, then TVDB's cast (no key needed) when
 * TMDB listed nobody. Keyed like upstream's effect (meta.id, tmdbKey); ten minutes.
 */
export async function load(meta: Meta, profileId: string, linked: boolean): Promise<XrayData> {
  const s = loadEffective(profileId, linked);
  const key = (s.tmdbKey ?? "").trim();
  const cacheKey = `${meta.id}|${meta.type}|${key}`;
  const hit = cache.get(cacheKey);
  if (hit && Date.now() - hit.at < TTL_MS) return hit.value;
  const detail = key ? await tmdbDetails(key, meta).catch(() => null) : null;
  let list: CastEntry[] = detail?.cast ?? [];
  if (list.length === 0) {
    const imdb = meta.id?.startsWith("tt") ? meta.id.split(":")[0] : (detail?.imdbId ?? null);
    list = await fetchTvdbCast({ imdb, kitsuId: kitsuIdOf(meta), type: meta.type === "movie" ? "movie" : "series" }).catch(() => []);
  }
  const value = assemble(meta, detail, list, key.length > 0);
  // A failed TMDB answer is not remembered (the next pause asks again).
  if (!key || detail) cache.set(cacheKey, { at: Date.now(), value });
  return value;
}

/** settings.xrayEnabled for the active profile (xray-overlay.tsx `if (!settings.xrayEnabled) return null`). */
export function enabled(profileId: string, linked: boolean): boolean {
  return loadEffective(profileId, linked).xrayEnabled === true;
}
