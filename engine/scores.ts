// use-bp-card-badges.ts without React: every score a hero or detail page can carry, in desktop's
// push order, gated by the same settings. One awaited call per title; each provider is best effort.
import type { Meta } from "@/lib/cinemeta";
import { meta as fetchMeta } from "@/lib/cinemeta";
import { externalToKitsu, kitsuToImdb } from "@/lib/providers/anime-mapping";
import { harborImdbTitle } from "@/lib/providers/harbor-imdb";
import { mdblistCardCached, mdblistCardPrefetch, setMdblistBatchKey, type CardScores } from "@/lib/providers/mdblist-batch";
import { omdbScores } from "@/lib/providers/omdb";
import { get as tmdbGet } from "@/lib/providers/tmdb/tmdb-client";
import { tmdbIdFromImdb, tmdbImdbId } from "@/lib/providers/tmdb/tmdb-imdb-resolve";
import { safeFetch } from "@/lib/safe-fetch";
import { HARBOR_API_BASE } from "@/lib/config/endpoints";
import { loadEffective } from "@/lib/settings/profile-store";
import type { Settings } from "@/lib/settings/types";
import { BP_ANIME_ID } from "@/views/big-picture/use-bp-card-badges";

export type ScoreBadge =
  | { kind: "rating"; source: "imdb" | "mal" | "tmdb"; value: string }
  | { kind: "simkl" | "rt" | "audience" | "metacritic" | "letterboxd" | "mdblist" | "trakt"; value: number };

type Surface = "card" | "detail";
type Gates = { imdb: boolean; tmdb: boolean; mal: boolean; rt: boolean; audience: boolean; metacritic: boolean; letterboxd: boolean; mdblist: boolean; trakt: boolean; simkl: boolean; pairAnimeImdb: boolean };

function gates(s: Settings, surface: Surface): Gates {
  if (surface === "detail") {
    const on = s.showDetailRatings !== false;
    return { imdb: on && s.showImdbDetail, tmdb: on && s.showTmdbDetail, mal: on && s.showMalDetail, rt: on && s.showRtDetail, audience: on && s.showRtAudienceDetail, metacritic: on && s.showMetacriticDetail, letterboxd: on && s.showLetterboxdDetail, mdblist: on && s.showMdblistDetail, trakt: on && s.showTraktDetail, simkl: on && s.showSimklDetail, pairAnimeImdb: true };
  }
  return { imdb: s.showImdbBadge, tmdb: s.showTmdbBadge, mal: s.showMalBadge, rt: s.showRtBadge, audience: s.showPopcornBadge, metacritic: s.showMetacriticBadge, letterboxd: s.showLetterboxdBadge, mdblist: s.showMdblistBadge, trakt: s.showTraktBadge, simkl: s.showSimklBadge, pairAnimeImdb: false };
}

const ANIME_NUMERIC_ID = /^(kitsu|mal|anilist|anidb):(\d+)/;
async function resolveAnimeImdb(metaId: string): Promise<string | null> {
  const m = metaId.match(ANIME_NUMERIC_ID);
  if (!m) return null;
  const idNum = Number(m[2]);
  if (!Number.isFinite(idNum)) return null;
  let kitsuId: number | null = m[1] === "kitsu" ? idNum : null;
  if (kitsuId == null) kitsuId = await externalToKitsu(m[1] === "mal" ? "myanimelist" : m[1], idNum).catch(() => null);
  if (kitsuId == null) return null;
  return kitsuToImdb(kitsuId).catch(() => null);
}

const voteCache = new Map<string, string | null>();
async function tmdbVote(key: string, metaId: string, type: "movie" | "series"): Promise<string | null> {
  if (voteCache.has(metaId)) return voteCache.get(metaId) ?? null;
  const tmdbId = metaId.startsWith("tmdb:") ? metaId : await tmdbIdFromImdb(key, metaId, type).catch(() => null);
  const match = tmdbId?.match(/^tmdb:(movie|tv):(\d+)$/);
  let out: string | null = null;
  if (match) {
    const data = await tmdbGet<{ vote_average?: number; vote_count?: number }>(key, `${match[1]}/${match[2]}`).catch(() => null);
    const avg = data?.vote_average;
    out = typeof avg === "number" && avg > 0 && (data?.vote_count ?? 0) > 0 ? avg.toFixed(1) : null;
  }
  voteCache.set(metaId, out);
  return out;
}

const simklCache = new Map<string, number | null>();
async function simklScore(spec: string): Promise<number | null> {
  const key = spec.toLowerCase();
  if (simklCache.has(key)) return simklCache.get(key) ?? null;
  const val = await safeFetch(`${HARBOR_API_BASE}/api/simkl/ratings?ids=${encodeURIComponent(key)}`)
    .then((r) => (r.ok ? r.json() : null))
    .then((data: { ratings?: Record<string, { rating?: number } | null> } | null) => { const hit = data?.ratings?.[key]; return hit && typeof hit.rating === "number" ? hit.rating : null; })
    .catch(() => null);
  simklCache.set(key, val);
  return val;
}

async function mdblist(imdbId: string, kind: "movie" | "show"): Promise<CardScores | null> {
  const held = mdblistCardCached(imdbId, kind);
  if (held) return held;
  mdblistCardPrefetch(imdbId, kind);
  for (let i = 0; i < 8; i += 1) {
    await new Promise((r) => setTimeout(r, 300));
    const got = mdblistCardCached(imdbId, kind);
    if (got) return got;
  }
  return null;
}

const timeout = <T,>(p: Promise<T>, ms: number, fallback: T) => Promise.race([p.catch(() => fallback), new Promise<T>((r) => setTimeout(() => r(fallback), ms))]);

export async function scores(meta: Meta, profileId: string, linked: boolean, surface: Surface = "card"): Promise<ScoreBadge[]> {
  const s = loadEffective(profileId, linked);
  const gate = gates(s, surface);
  const isAnime = BP_ANIME_ID.test(meta.id);
  const mediaKind = meta.type === "series" ? "show" : "movie";
  const cinemetaKind = meta.type === "series" ? "series" : "movie";
  const wantMdblist = gate.audience || gate.metacritic || gate.letterboxd || gate.mdblist || gate.trakt || gate.simkl;
  const want = gate.imdb || gate.tmdb || gate.mal || gate.rt || wantMdblist;
  if (!want) return [];
  if (s.mdblistKey) setMdblistBatchKey(s.mdblistKey);

  let imdbId: string | undefined = meta.id.startsWith("tt") ? meta.id : undefined;
  if (!imdbId && !isAnime) imdbId = (await timeout(tmdbImdbId(s.tmdbKey, meta.id), 4000, null)) ?? undefined;
  const animeWantsImdb = isAnime && (gate.pairAnimeImdb ? gate.imdb : s.animeCardRating === "imdb" && gate.mal);
  const animeImdb = animeWantsImdb ? await timeout(resolveAnimeImdb(meta.id), 4000, null) : null;
  const ratingTt = isAnime ? animeImdb ?? undefined : gate.imdb ? imdbId : undefined;

  const [harborRating, omdb, cinemetaRating, vote, cardScores, simklValueRaw] = await Promise.all([
    ratingTt?.startsWith("tt") ? timeout(harborImdbTitle(ratingTt).then((r) => (r != null ? r.toFixed(1) : null)), 4000, null) : Promise.resolve(null),
    s.omdbKey && imdbId && (gate.imdb || gate.rt) ? timeout(omdbScores(s.omdbKey, imdbId), 5000, null) : Promise.resolve(null),
    gate.imdb && !isAnime && imdbId && !(meta.id.startsWith("tt") && meta.imdbRating) ? timeout(fetchMeta(cinemetaKind, imdbId).then((m) => m?.imdbRating ?? null), 4000, null) : Promise.resolve(null),
    gate.tmdb && !isAnime && s.tmdbKey ? timeout(tmdbVote(s.tmdbKey, meta.id, cinemetaKind), 4000, null) : Promise.resolve(null),
    s.mdblistKey && wantMdblist && imdbId ? timeout(mdblist(imdbId, mediaKind), 4000, null) : Promise.resolve(null),
    gate.simkl ? timeout(simklScore(isAnime ? meta.id : imdbId ? `imdb:${imdbId}` : ""), 4000, null) : Promise.resolve(null),
  ]);
  const simklValue = simklValueRaw ?? cardScores?.simkl ?? null;
  const imdbValue = isAnime ? undefined : harborRating ?? omdb?.imdbRating ?? cinemetaRating ?? (meta.id.startsWith("tt") ? meta.imdbRating : undefined);
  const animeSource: "imdb" | "mal" = animeWantsImdb && harborRating && !gate.pairAnimeImdb ? "imdb" : "mal";
  const animeValue = isAnime && gate.mal ? (animeWantsImdb && harborRating && !gate.pairAnimeImdb ? harborRating : meta.imdbRating) : undefined;
  const animeImdbValue = isAnime && gate.pairAnimeImdb && gate.imdb ? harborRating : undefined;

  const out: ScoreBadge[] = [];
  if (isAnime) {
    if (animeValue) out.push({ kind: "rating", source: animeSource, value: animeValue });
    if (animeImdbValue) out.push({ kind: "rating", source: "imdb", value: animeImdbValue });
  } else {
    if (gate.imdb && imdbValue) out.push({ kind: "rating", source: "imdb", value: imdbValue });
    if (gate.tmdb && vote) out.push({ kind: "rating", source: "tmdb", value: vote });
  }
  if (gate.simkl && simklValue != null) out.push({ kind: "simkl", value: simklValue });
  if (gate.rt && omdb?.rtCritics != null) out.push({ kind: "rt", value: omdb.rtCritics });
  if (gate.audience && cardScores?.rtAudience != null) out.push({ kind: "audience", value: cardScores.rtAudience });
  if (gate.metacritic && cardScores?.metacritic != null) out.push({ kind: "metacritic", value: cardScores.metacritic });
  if (gate.letterboxd && cardScores?.letterboxd != null) out.push({ kind: "letterboxd", value: cardScores.letterboxd });
  if (gate.mdblist && cardScores?.score != null) out.push({ kind: "mdblist", value: cardScores.score });
  if (gate.trakt && cardScores?.trakt != null) out.push({ kind: "trakt", value: cardScores.trakt });
  return out;
}
