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
  crew: Array<{ label: string; names: string[] }>;
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
  const push = (label: string, list: Array<{ name: string }>, cap: number) => { if (list.length) crew.push({ label, names: list.slice(0, cap).map((p) => p.name) }); };
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
