// Detail page extras from TMDB (use-bp-detail.ts steps 3-6): tagline, cast, crew, More Like
// This, You Might Also Like, watch providers, the franchise collection. Everything is null
// without a TMDB key; Cinemeta already carries the basics the hero shows.
import type { Meta } from "@/lib/cinemeta";
import { tmdbDetails } from "@/lib/providers/tmdb/tmdb-details";
import { tmdbWatchProviders } from "@/lib/providers/tmdb/tmdb-watch";
import { tmdbCollection } from "@/lib/providers/tmdb/tmdb-collection";
import { loadEffective } from "@/lib/settings/profile-store";

const IMG = "https://image.tmdb.org/t/p/w342";
const portrait = (path: string | null | undefined): string | null => (!path ? null : path.startsWith("http") ? path : `${IMG}${path}`);

export type DetailExtras = {
  kind: "movie" | "tv";
  tmdbId: number;
  imdbId: string | null;
  tagline: string;
  overview: string;
  rating: string | null;
  runtime: string | null;
  status: string;
  genres: string[];
  cast: Array<{ id: number; name: string; character: string; profile: string | null }>;
  crew: Array<{ label: string; names: string[]; people: Array<{ id: number | null; name: string }> }>;
  recommendations: Meta[];
  similar: Meta[];
  trailerYtId: string | null;
  videos: Array<{ ytId: string; name: string; type: string }>;
  collection: { id: number; name: string } | null;
  facts: Array<{ label: string; value: string }>;
  watchOn: Array<{ name: string; logo: string }>;
  gallery: { backdrops: number; posters: number; logos: number };
};

const cache = new Map<string, { at: number; value: DetailExtras | null }>();

export async function extras(meta: Meta, profileId: string, linked: boolean): Promise<DetailExtras | null> {
  const s = loadEffective(profileId, linked);
  if (!s.tmdbKey) return null;
  const key = `${meta.id}|${s.tmdbKey}|${s.region}`;
  const hit = cache.get(key);
  if (hit && Date.now() - hit.at < 10 * 60_000) return hit.value;
  const d = await tmdbDetails(s.tmdbKey, meta).catch(() => null);
  if (!d) { cache.set(key, { at: Date.now(), value: null }); return null; }
  // bp-crew-row: Director/Creator/Writer/Producers/Cinematography/Music/Editor, capped 2-4 each.
  const crew: DetailExtras["crew"] = [];
  // bp-crew-row cells open the Person page, so each name keeps its TMDB id when the detail carried one.
  const push = (label: string, list: Array<{ name: string; id?: number }>, cap: number) => {
    if (list.length) crew.push({ label, names: list.slice(0, cap).map((p) => p.name), people: list.slice(0, cap).map((p) => ({ id: typeof p.id === "number" ? p.id : null, name: p.name })) });
  };
  push(d.kind === "tv" ? "Created by" : "Directed by", d.kind === "tv" ? d.creators : d.directors, 3);
  if (d.kind === "tv") push("Directed by", d.directors, 2);
  push("Written by", d.writers, 3);
  push("Produced by", d.producers, 4);
  push("Cinematography", d.cinematography, 2);
  push("Music", d.composer, 2);
  push("Edited by", d.editor, 2);
  // bp-facts: the first rows of the facts card.
  const facts: DetailExtras["facts"] = [];
  const fact = (label: string, value: string | number | undefined | null) => { if (value !== undefined && value !== null && String(value).trim() !== "") facts.push({ label, value: String(value) }); };
  fact("Status", d.status);
  fact(d.kind === "tv" ? "First aired" : "Released", d.kind === "tv" ? d.firstAirDate : d.releaseDate);
  if (d.kind === "tv") fact("Last aired", d.lastAirDate);
  fact(d.kind === "tv" ? "Length" : "Runtime", d.runtime);
  fact("Network", d.networks.join(", "));
  fact("Studio", d.productionCompanies.slice(0, 3).join(", "));
  fact("Country", d.productionCountries.join(", "));
  fact("Language", d.spokenLanguages.join(", "));
  fact("Genres", d.genres.join(", "));
  if (d.originalTitle && d.originalTitle !== d.title) fact("Original title", d.originalTitle);
  if (d.budget) fact("Budget", `$${Math.round(d.budget / 1e6)}M`);
  if (d.revenue) fact("Box office", `$${Math.round(d.revenue / 1e6)}M`);
  fact("Rating", d.rating ? `${d.rating} (${d.voteCount} votes)` : undefined);
  let watchOn: DetailExtras["watchOn"] = [];
  try { watchOn = (await tmdbWatchProviders(s.tmdbKey, d.kind, d.id, s.region)).map((p) => ({ name: p.name, logo: p.logo })); } catch { /* optional */ }
  const value: DetailExtras = {
    kind: d.kind, tmdbId: d.id, imdbId: d.imdbId, tagline: d.tagline, overview: d.overview,
    rating: d.rating ?? null, runtime: d.runtime ?? null, status: d.status, genres: d.genres,
    cast: d.cast.slice(0, 20).map((c) => ({ id: c.id, name: c.name, character: c.character, profile: portrait(c.profilePath) })),
    crew, recommendations: d.recommendations, similar: d.similar,
    trailerYtId: d.trailerYtId, videos: d.extraVideos.slice(0, 14),
    collection: d.collection ?? null, facts, watchOn,
    gallery: { backdrops: d.gallery.backdrops.length, posters: d.gallery.posters.length, logos: d.gallery.logos.length },
  };
  cache.set(key, { at: Date.now(), value });
  return value;
}

/** Franchise parts (dropped below 2, like use-bp-detail). */
export async function collection(id: number, profileId: string, linked: boolean): Promise<{ name: string; metas: Meta[] } | null> {
  const s = loadEffective(profileId, linked);
  if (!s.tmdbKey) return null;
  const c = await tmdbCollection(s.tmdbKey, id).catch(() => null);
  if (!c) return null;
  if (c.parts.length < 2) return null;
  return { name: c.name, metas: c.parts };
}


// ------------------------------------------------------------------ per-episode facts
// detail/use-bp-episode-facts.ts: TMDB's season episodes (vote average, runtime) with Harbor's
// IMDb episode ratings on top; keyed "season:episode".
import { tmdbSeasonEpisodes as factsSeasonEpisodes } from "@/lib/providers/tmdb/tmdb-details";
import { harborImdbEpisodes as factsImdbEpisodes } from "@/lib/providers/harbor-imdb";
export type EpisodeFact = { season: number; episode: number; rating: number | null; ratingIsImdb: boolean; runtime: number | null };
export async function episodeFacts(meta: Meta, season: number, profileId: string, linked: boolean): Promise<EpisodeFact[]> {
  const s = loadEffective(profileId, linked);
  const x = await extras(meta, profileId, linked).catch(() => null);
  const imdbId = x?.imdbId ?? (meta.id.startsWith("tt") ? meta.id : null);
  const [tmdbList, imdb] = await Promise.all([
    s.tmdbKey && x?.tmdbId && x.kind === "tv" && season > 0 ? factsSeasonEpisodes(s.tmdbKey, x.tmdbId, season).catch(() => []) : Promise.resolve([]),
    imdbId ? factsImdbEpisodes(imdbId).catch(() => new Map<string, number>()) : Promise.resolve(new Map<string, number>()),
  ]);
  const out = new Map<string, EpisodeFact>();
  for (const e of tmdbList as Array<{ seasonNumber: number; episodeNumber: number; voteAverage?: number | null; runtime?: number | null }>) {
    out.set(`${e.seasonNumber}:${e.episodeNumber}`, { season: e.seasonNumber, episode: e.episodeNumber, rating: e.voteAverage && e.voteAverage > 0 ? e.voteAverage : null, ratingIsImdb: false, runtime: e.runtime && e.runtime > 0 ? e.runtime : null });
  }
  for (const [k, v] of imdb) {
    if (!k.startsWith(`${season}:`)) continue;
    const [se, ep] = k.split(":").map(Number);
    const held = out.get(k);
    out.set(k, { season: se, episode: ep, rating: v, ratingIsImdb: true, runtime: held?.runtime ?? null });
  }
  return Array.from(out.values());
}


// ------------------------------------------------------------------------ awards row
// detail/bp-awards-row.tsx + bp-award-detail-dialog.tsx: one mark per award body with win /
// nomination counts, and the categories and years behind each.
import { fetchAwards as awardsFetch, awardSummary as awardsSummary, type AwardEntry as AwardsEntry } from "@/lib/providers/wikidata";
import { mergeBundledAwards as awardsMergeBundled } from "@/lib/awards-history";
import { AWARD_CATALOG as awardsCatalog } from "@/lib/awards-catalog";
export type TitleAwards = {
  groups: Array<{ type: string; title: string; wins: number; nominations: number }>;
  entries: Array<{ type: string; awardName: string; category: string | null; year: number | null; result: "won" | "nominated"; recipient: string | null }>;
};
export async function awards(meta: Meta): Promise<TitleAwards> {
  const imdbId = meta.id.startsWith("tt") ? meta.id : null;
  const year = Number((meta.releaseInfo ?? "").slice(0, 4)) || undefined;
  const live: AwardsEntry[] | null = imdbId ? await Promise.race([awardsFetch(imdbId, meta.type === "series").catch(() => null), new Promise<null>((r) => setTimeout(() => r(null), 8000))]) : null;
  const merged = awardsMergeBundled(live, meta.name, year);
  const groups = awardsSummary(merged).filter((a) => a.wins > 0 || a.nominations > 0).map((a) => ({ type: a.type, title: awardsCatalog[a.type]?.title ?? "Awards", wins: a.wins, nominations: a.nominations }));
  const entries = merged.filter((e) => e.type !== "other").map((e) => ({ type: e.type, awardName: e.awardName, category: e.category ?? null, year: e.year ?? null, result: e.result, recipient: e.recipient ?? (e.recipients?.[0] ?? null) }));
  return { groups, entries };
}


// ------------------------------------------------------------------------- gallery row
/** bp-gallery-row: up to 24 backdrops, posters and logos from the TMDB detail (already fetched for extras). */
export async function gallery(meta: Meta, profileId: string, linked: boolean): Promise<{ backdrops: string[]; posters: string[]; logos: string[] }> {
  const s = loadEffective(profileId, linked);
  if (!s.tmdbKey) return { backdrops: [], posters: [], logos: [] };
  const d = await tmdbDetails(s.tmdbKey, meta).catch(() => null);
  const g = (d as unknown as { gallery?: { backdrops?: string[]; posters?: string[]; logos?: string[] } } | null)?.gallery;
  return { backdrops: (g?.backdrops ?? []).slice(0, 24), posters: (g?.posters ?? []).slice(0, 24), logos: (g?.logos ?? []).slice(0, 24) };
}
