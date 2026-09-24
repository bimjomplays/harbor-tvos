// use-bp-anime-detail.ts without React or the TVDB panel: the Kitsu chain (lib/providers/anime-detail)
// for a kitsu/mal/anilist/anidb id, its episodes as PlayEpisodes, the AniList characters row.
import type { Meta } from "@/lib/cinemeta";
import { animeDetails, type AnimeDetailExtras } from "@/lib/providers/anime-detail";
import { fetchAnimeCharactersByKitsu, type AnimeCharacter } from "@/lib/providers/anime-characters";
import type { KitsuEpisode } from "@/lib/providers/kitsu";
import { loadEffective } from "@/lib/settings/profile-store";
import { animeSeasonKey } from "@/views/detail/anime-episodes/anime-season-key";
import { bpAnimePlayEpisode } from "@/views/big-picture/use-bp-anime-detail";

const ANIME_ID = /^(kitsu|mal|anilist|anidb):/;

export type AnimeEpisode = {
  id: number; season: number; number: number; title: string; synopsis: string; thumbnail: string | null;
  airdate: string | null; length: number | null; filler: boolean; absoluteNumber: number | null;
  imdbSeason: number | null; imdbEpisode: number | null; playEpisode: ReturnType<typeof bpAnimePlayEpisode>;
  /** A franchise entry merged into this list: its manual watched marks live under this id. */
  sourceMetaId: string | null;
};
export type AnimeDetail = {
  canonicalId: string;
  imdbId: string | null;
  detail: { name: string | null; overview: string | null; backdrop: string | null; poster: string | null; year: string | null; genres: string[] };
  episodes: AnimeEpisode[];
  showSeason: boolean;
  streamers: Array<{ name: string; url: string }>;
  characters: AnimeCharacter[];
};

const timeout = <T,>(p: Promise<T>, ms: number, fallback: T) => Promise.race([p.catch(() => fallback), new Promise<T>((r) => setTimeout(() => r(fallback), ms))]);

function pick(d: Record<string, unknown>, keys: string[]): string | null {
  for (const k of keys) { const v = d[k]; if (typeof v === "string" && v) return v; }
  return null;
}

function toEpisode(ep: KitsuEpisode): AnimeEpisode {
  return {
    id: ep.id, season: animeSeasonKey(ep), number: ep.number, title: ep.title, synopsis: ep.synopsis, thumbnail: ep.thumbnail ?? ep.thumbnailFallback ?? null,
    airdate: ep.airdate, length: ep.length, filler: ep.filler === true, absoluteNumber: ep.absoluteNumber ?? null,
    imdbSeason: ep.imdbSeason ?? null, imdbEpisode: ep.imdbEpisode ?? null, playEpisode: bpAnimePlayEpisode(ep),
    sourceMetaId: ep.sourceMetaId ?? null,
  };
}

export async function load(meta: Meta, profileId: string, linked: boolean): Promise<AnimeDetail | null> {
  if (!ANIME_ID.test(meta.id)) return null;
  const settings = loadEffective(profileId, linked);
  const res = await animeDetails(settings, meta).catch(() => null);
  if (!res) return null;
  const [extras, enriched, characters] = await Promise.all([
    timeout<AnimeDetailExtras>(res.extrasPromise, 6000, {}),
    timeout<KitsuEpisode[]>(res.enrichPromise, 8000, res.episodes),
    timeout<AnimeCharacter[]>(fetchAnimeCharactersByKitsu(res.kitsuId), 6000, []),
  ]);
  const d = { ...(res.detail as unknown as Record<string, unknown>), ...(extras as Record<string, unknown>) };
  const episodes = (enriched.length > 0 ? enriched : res.episodes).map(toEpisode);
  const genres = Array.isArray(d.genres) ? (d.genres as unknown[]).map((g) => (typeof g === "string" ? g : (g as { name?: string })?.name ?? "")).filter(Boolean) : [];
  return {
    canonicalId: `kitsu:${res.kitsuId}`,
    imdbId: (extras.imdbId as string | undefined) ?? res.imdbId ?? (d.imdbId as string | undefined) ?? null,
    detail: {
      name: pick(d, ["title", "name"]) ?? meta.name ?? null,
      overview: pick(d, ["overview", "description"]) ?? meta.description ?? null,
      backdrop: res.backdrops[0] ?? pick(d, ["backdrop", "background"]) ?? meta.background ?? null,
      poster: pick(d, ["poster"]) ?? meta.poster ?? null,
      year: pick(d, ["year", "releaseInfo"]) ?? meta.releaseInfo ?? null,
      genres,
    },
    episodes,
    showSeason: new Set(episodes.map((e) => e.season)).size > 1,
    streamers: (res.streamers ?? []).map((s) => ({ name: (s as { name?: string }).name ?? "", url: (s as { url?: string }).url ?? "" })).filter((s) => s.name),
    characters,
  };
}
