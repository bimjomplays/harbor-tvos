// Discover room glue: the pure parts of use-bp-discover.ts and queue/use-bp-queue.ts.
import type { Meta } from "@/lib/cinemeta";
import { getPool, selectDailyRows, fetchGenreSample, type FeedItem } from "@/lib/feed";
import { getDownvotedIds, getUpvotedIds } from "@/lib/feed/preferences";
import { rankByAffinity } from "@/lib/feed/rank";
import { filterQueuePool, shuffleQueuePool } from "@/lib/feed/skipped";
import { getStore } from "@/lib/discover/store";
import { CATALOG_REQUEST_TIMEOUT_MS, withTimeout } from "@/lib/progressive-rows";
import { metaLooksAnime } from "@/lib/anime-detect";
import { GENRE_PALETTE } from "@/components/genre-tiles";
import { BP_GENRES, bpAwardSummaries, bpAwardDetail, bpAwardsOverview } from "@/views/big-picture/use-bp-discover";
import type { AwardType } from "@/lib/providers/wikidata";
import { fetchRankList, peekRankSnapshot } from "@/lib/harbor-rank";
import { setBundledAwards, bundledAwardsVersion } from "@/lib/awards-history";
import { loadEffective } from "@/lib/settings/profile-store";
import type { Settings } from "@/lib/settings/types";

const RAIL_COUNT = 8;
const MIN_RAIL = 10;

export type DiscoverRail = { key: string; name: string; kicker?: string; metas: Meta[] };
export type QueuePeek = { status: "loading" | "nokey" | "unreachable" | "empty" | "ready"; total: number; posters: string[]; backdrop: string | null };
export type GenreTile = { genre: string; from: string; to: string; ink: string };
export type DiscoverBuild = { rails: DiscoverRail[]; queue: QueuePeek; genres: GenreTile[] };

// use-bp-discover.ts:210-231
function claimRail(batch: Meta[], seen: Set<string>): Meta[] {
  const taken: Meta[] = [];
  const takenIds = new Set<string>();
  for (const m of batch) {
    if (!m.poster || seen.has(m.id) || takenIds.has(m.id)) continue;
    takenIds.add(m.id);
    taken.push(m);
  }
  if (taken.length < MIN_RAIL) {
    for (const m of batch) {
      if (taken.length >= MIN_RAIL) break;
      if (!m.poster || takenIds.has(m.id)) continue;
      takenIds.add(m.id);
      taken.push(m);
    }
  }
  for (const id of takenIds) seen.add(id);
  return taken;
}

export async function rails(settings: Settings, count = RAIL_COUNT): Promise<DiscoverRail[]> {
  const defs = selectDailyRows(settings.tmdbKey, getStore().affinity, settings, count);
  const batches = await Promise.all(defs.map((d) => withTimeout(d.fetch(1), CATALOG_REQUEST_TIMEOUT_MS).catch(() => [] as Meta[])));
  const out: DiscoverRail[] = [];
  const seen = new Set<string>();
  for (let i = 0; i < defs.length; i += 1) {
    let metas = claimRail(batches[i], seen);
    if (settings.animeOnlyInAnimeRoom) metas = metas.filter((m) => !metaLooksAnime(m));
    if (metas.length === 0) continue;
    out.push({ key: defs[i].id, name: defs[i].shelf.title, kicker: defs[i].shelf.kicker, metas });
  }
  return out;
}

// queue/use-bp-queue.ts:46-50, 82-87
function buildOrder(source: FeedItem[]): FeedItem[] {
  const voted = new Set<string>([...getDownvotedIds(), ...getUpvotedIds()]);
  const kept = filterQueuePool(source).filter((it) => !voted.has(it.meta.id));
  return rankByAffinity(shuffleQueuePool(kept));
}

export async function queuePeek(settings: Settings, count = 4): Promise<QueuePeek> {
  const key = settings.tmdbKey;
  let pool: FeedItem[] = [];
  let raw = 0;
  try {
    pool = await getPool(key);
    raw = pool.length;
  } catch {
    pool = [];
  }
  const entries = buildOrder(pool);
  const status: QueuePeek["status"] = entries.length > 0 ? "ready" : !key ? "nokey" : raw === 0 ? "unreachable" : "empty";
  return {
    status,
    total: entries.length,
    posters: entries.slice(0, count).flatMap((it) => (it.meta.poster ? [it.meta.poster] : [])),
    backdrop: entries[0]?.meta.background ?? null,
  };
}

/** The ordered queue itself (Discovery Queue overlay), first `limit` items. */
export async function queue(settings: Settings, limit = 40): Promise<Meta[]> {
  let pool: FeedItem[] = [];
  try { pool = await getPool(settings.tmdbKey); } catch { pool = []; }
  return buildOrder(pool).slice(0, limit).map((it) => it.meta);
}

export function genres(): GenreTile[] {
  return BP_GENRES.map((g) => {
    const p = GENRE_PALETTE[g] ?? GENRE_PALETTE.Drama;
    return { genre: g, from: p.from, to: p.to, ink: p.ink };
  });
}

/** Up to three backdrops for a genre tile (needs a TMDB key; empty otherwise). */
export async function genreArt(settings: Settings, genre: string): Promise<Meta[]> {
  if (!settings.tmdbKey) return [];
  const metas = await fetchGenreSample(settings.tmdbKey, genre).catch(() => [] as Meta[]);
  return metas.filter((m) => m.background).slice(0, 3);
}

export async function buildFor(profileId: string, linked: boolean): Promise<DiscoverBuild> {
  const settings = loadEffective(profileId, linked);
  const [r, q] = await Promise.all([rails(settings), queuePeek(settings)]);
  return { rails: r, queue: q, genres: genres() };
}

export function queueFor(profileId: string, linked: boolean, limit = 40): Promise<Meta[]> {
  return queue(loadEffective(profileId, linked), limit);
}

export function genreArtFor(profileId: string, linked: boolean, genre: string): Promise<Meta[]> {
  return genreArt(loadEffective(profileId, linked), genre);
}

// ----------------------------------------------------------------------- awards / people
/** The 4 MB awards catalog arrives from the app bundle as a JSON string (awards-history.ts:27-35). */
export function installAwards(rawJson: string): number {
  setBundledAwards(JSON.parse(rawJson), true);
  return bundledAwardsVersion();
}
export function awardsInstalled(): boolean {
  return bundledAwardsVersion() > 0;
}
/** Bundled awards (offline): one summary tile per award body plus the band blurb numbers. */
export function awards() {
  const summaries = bpAwardSummaries();
  const overview = bpAwardsOverview();
  return { summaries, overview };
}

/** Every category and its winners by year for one award body. */
export function awardDetail(type: AwardType) {
  const d = bpAwardDetail(type);
  return {
    type,
    title: d.meta.title,
    wins: d.wins,
    span: d.span,
    decades: d.decades,
    groups: d.groups.map((g) => ({
      category: g.category,
      entries: g.entries.slice(0, 200),
    })),
  };
}

/** Harbor's own "Top People" ranking (harbor.site); snapshot first, then a refresh. */
export async function people(limit = 24) {
  const snap = peekRankSnapshot("harbor", "Acting", null);
  const fresh = await fetchRankList("harbor", "Acting", null).catch(() => null);
  const result = fresh ?? snap;
  if (!result || result.source !== "harbor") return [];
  return result.list.slice(0, limit).map((p) => ({ id: p.id, rank: p.rank, name: p.name, profilePath: p.profilePath, department: p.department, country: p.country, score: p.score }));
}
