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

// detail/bp-videos-row: the other trailer candidates first (the lead one is "Watch trailer"),
// then TMDB's extra videos, each YouTube id once, 14 cards.
function videoClips(candidates: string[], extras: Array<{ ytId: string; name: string; type: string }>): DetailExtras["videos"] {
  const seen = new Set<string>();
  const clips: DetailExtras["videos"] = [];
  for (const ytId of candidates.slice(1)) { if (!seen.has(ytId)) { seen.add(ytId); clips.push({ ytId, name: "Trailer", type: "Trailer" }); } }
  for (const v of extras) { if (!seen.has(v.ytId)) { seen.add(v.ytId); clips.push({ ytId: v.ytId, name: v.name || v.type, type: v.type }); } }
  return clips.slice(0, 14);
}
export const _videoClips = videoClips;

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
    trailerYtId: d.trailerYtId, videos: videoClips(d.trailerCandidates, d.extraVideos),
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


// ------------------------------------------------------------------ episode still ladder
// use-bp-episode-art.ts without React: per episode, the still candidates in upstream's order
// (TMDB season still → TVDB order → TVDB proxy → ani.zip → the meta's own thumbnail →
// metahub), sized like bp-art, de-duplicated. The cell walks the list and falls back to
// bp-episode-still's numbered plate when every url fails.
import { aniZipByImdb as artAniZipByImdb, aniZipByKitsu as artAniZipByKitsu, type AniZipMapping } from "@/lib/providers/anizip";
import { kitsuToTvdb as artKitsuToTvdb } from "@/lib/providers/anime-mapping";
import { parseKitsuId as artParseKitsuId } from "@/lib/providers/kitsu";
import { tmdbIdFromImdb as artTmdbIdFromImdb, tmdbImdbId as artTmdbImdbId } from "@/lib/providers/tmdb";
import { IMG as ART_TMDB_IMG, tmdbLanguageIso as artTmdbLanguageIso } from "@/lib/providers/tmdb/tmdb-client";
import { tvdbLangFromIso1 as artTvdbLang, tvdbSeriesByRemote as artTvdbSeriesByRemote } from "@/lib/providers/tvdb";
import { fetchTvdbOrderBySeriesId as artTvdbOrder, type TvdbOrder } from "@/lib/providers/tvdb-order";
import { fetchTvdbProxyImages as artTvdbProxy, pickTvdbImage as artPickTvdbImage, type TvdbImageMap } from "@/lib/providers/tvdb-proxy";
import { bpCardArt } from "@/views/big-picture/bp-art";

export type EpisodeArtRef = { key: string; season: number; episode: number; absoluteNumber?: number | null; still?: string | null };

// A resolved answer is reused for the session (a rejection is dropped so it can retry).
const artMemo = new Map<string, Promise<unknown>>();
function artOnce<T>(slot: string, run: () => Promise<T>): Promise<T> {
  const hit = artMemo.get(slot) as Promise<T> | undefined;
  if (hit) return hit;
  const p = run();
  artMemo.set(slot, p);
  if (artMemo.size > 60) { const first = artMemo.keys().next().value; if (first !== undefined) artMemo.delete(first); }
  void p.catch(() => artMemo.delete(slot));
  return p;
}

// BP_EPISODE_BOX {min 212, vw 17.5, max 340} on a 1920-wide TV is 336; hdEpisodeImages off asks for half.
const artWidth = (hd: boolean) => (hd ? 336 : 168);
const directImdb = (metaId: string) => (metaId.startsWith("tt") ? metaId.split(":")[0] : null);
const directTmdbTv = (metaId: string) => { const m = /^tmdb:tv:(\d+)$/.exec(metaId); return m ? Number(m[1]) : null; };
const metahubStill = (imdb: string | null, season: number, episode: number) => (imdb?.startsWith("tt") ? `https://episodes.metahub.space/${imdb}/${season}/${episode}/w780.jpg` : undefined);

function aniZipArt(mapping: AniZipMapping | null) {
  const art = { byPair: new Map<string, string>(), byNumber: new Map<number, string>(), pairByNumber: new Map<number, { season: number; episode: number }>() };
  for (const [key, ep] of Object.entries(mapping?.episodes ?? {})) {
    const n = Number(key);
    const abs = ep.absoluteEpisodeNumber;
    if (ep.image) {
      if (Number.isFinite(n)) art.byNumber.set(n, ep.image);
      if (abs != null) art.byNumber.set(abs, ep.image);
      if (ep.seasonNumber != null && ep.episodeNumber != null) art.byPair.set(`${ep.seasonNumber}:${ep.episodeNumber}`, ep.image);
    }
    if (ep.seasonNumber == null || ep.seasonNumber < 1 || ep.episodeNumber == null) continue;
    const pair = { season: ep.seasonNumber, episode: ep.episodeNumber };
    if (Number.isFinite(n)) art.pairByNumber.set(n, pair);
    if (abs != null) art.pairByNumber.set(abs, pair);
  }
  return art;
}

// Absolute lookups lead only for anime (the meta's season is a constant 1 there).
function orderStill(order: TvdbOrder | null, season: number, episode: number, abs: number | null, absFirst: boolean): string | undefined {
  if (!order) return undefined;
  const byAbs = abs != null ? order.imageByAbs.get(abs) : undefined;
  if (absFirst && byAbs) return byAbs;
  const hit = order.bySeason.get(season)?.find((e) => e.episodeNumber === episode);
  return hit?.stillUrl ?? byAbs;
}

function proxyStill(map: TvdbImageMap, season: number, episode: number, abs: number | null, absFirst: boolean): string | undefined {
  if (absFirst && abs != null) return artPickTvdbImage(map, { seasonNumber: season, number: episode, absoluteNumber: abs }) ?? undefined;
  return map[`s${season}e${episode}`] ?? (abs != null ? map[`abs${abs}`] : undefined);
}

export async function episodeArt(meta: Meta, season: number, episodes: EpisodeArtRef[], profileId: string, linked: boolean): Promise<Record<string, string[]>> {
  const s = loadEffective(profileId, linked);
  const tmdbKey = s.tmdbKey, tvdbKey = s.tvdbKey, seasonType = s.tvdbSeasonType, hd = s.hdEpisodeImages !== false;
  const kitsuId = artParseKitsuId(meta.id);
  let imdbId = directImdb(meta.id);
  let tvId = directTmdbTv(meta.id);
  if (tmdbKey) {
    if (!imdbId && tvId != null) imdbId = (await artOnce(`imdb:${meta.id}`, () => artTmdbImdbId(tmdbKey, meta.id)).catch(() => null)) ?? null;
    if (tvId == null && imdbId) {
      const r = await artOnce(`tv:${imdbId}`, () => artTmdbIdFromImdb(tmdbKey, imdbId!, "series")).catch(() => null);
      const n = r?.startsWith("tmdb:tv:") ? Number(r.slice("tmdb:tv:".length)) : NaN;
      if (Number.isFinite(n)) tvId = n;
    }
  }
  const tmdb: Record<string, string> = {};
  if (tmdbKey && tvId != null && season > 0) {
    const lang = artTmdbLanguageIso() || "en";
    const list = await artOnce(`eps:${tvId}:${season}:${lang}`, () => factsSeasonEpisodes(tmdbKey, tvId!, season)).catch(() => []);
    for (const e of list) if (e.stillPath) tmdb[`${e.seasonNumber}:${e.episodeNumber}`] = e.stillPath.startsWith("http") ? e.stillPath : `${ART_TMDB_IMG}/original${e.stillPath}`;
  }
  const gaps = episodes.some((e) => !e.still && !tmdb[`${e.season}:${e.episode}`]);
  const anime = kitsuId != null;
  let aniZip: AniZipMapping | null = null;
  let proxy: TvdbImageMap = {};
  let order: TvdbOrder | null = null;
  // Below TMDB nothing is fetched until a card is missing art; for anime ani.zip always is.
  const slot = anime ? `kitsu:${kitsuId}` : imdbId ? `imdb:${imdbId}` : "";
  if ((gaps || anime) && slot) {
    const az = artOnce(`anizip:${slot}`, () => (kitsuId != null ? artAniZipByKitsu(kitsuId) : imdbId ? artAniZipByImdb(imdbId) : Promise.resolve(null))).catch(() => null);
    const px = gaps ? artOnce(`proxy:${slot}:${seasonType}`, () => artTvdbProxy({ imdb: imdbId, kitsuId, type: seasonType })).catch(() => ({})) : Promise.resolve({});
    const od = gaps && tvdbKey
      ? artOnce(`order:${slot}:${seasonType}:k`, async () => {
          let seriesId = kitsuId != null ? await artKitsuToTvdb(kitsuId).catch(() => null) : null;
          if (seriesId == null && imdbId) seriesId = await artTvdbSeriesByRemote(tvdbKey, imdbId).catch(() => null);
          if (seriesId == null) return null;
          return artTvdbOrder(tvdbKey, seriesId, seasonType, artTvdbLang(artTmdbLanguageIso()));
        }).catch(() => null)
      : Promise.resolve(null);
    [aniZip, proxy, order] = await Promise.all([az, px as Promise<TvdbImageMap>, od]);
  }
  const az = aniZipArt(aniZip);
  const seriesImdb = imdbId ?? aniZip?.mappings?.imdb_id ?? null;
  const want = artWidth(hd);
  const out: Record<string, string[]> = {};
  for (const ep of episodes) {
    const pair = `${ep.season}:${ep.episode}`;
    // Only a season one number can stand in for an absolute one.
    const abs = ep.absoluteNumber ?? (ep.season === 1 ? ep.episode : null);
    const azPair = abs != null ? az.pairByNumber.get(abs) : undefined;
    const candidates = [
      tmdb[pair],
      orderStill(order, ep.season, ep.episode, abs, anime),
      proxyStill(proxy ?? {}, ep.season, ep.episode, abs, anime),
      az.byPair.get(pair) ?? (abs != null ? az.byNumber.get(abs) : undefined),
      ep.still ?? undefined,
      metahubStill(seriesImdb, azPair?.season ?? ep.season, azPair?.episode ?? ep.episode),
    ];
    const ladder: string[] = [];
    for (const url of candidates) {
      if (!url) continue;
      const sized = bpCardArt(url, want) ?? url;
      if (!ladder.includes(sized)) ladder.push(sized);
    }
    out[ep.key] = ladder;
  }
  return out;
}
