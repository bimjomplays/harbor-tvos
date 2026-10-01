// Landscape backdrops for anime metas. Jikan/MAL metas (ids "mal:N") carry `background: poster`
// (jikan.ts toMeta) and Kitsu/AniList ids often carry no real backdrop, so the TV's hero behind a
// focused anime card was the poster, upscaled and blurred, while Movies and Shows show a 16:9 still.
// Source order, first hit wins, null when none (never throws):
//   1. Cinemeta/metahub background (the same art Movies/Shows use) when an IMDb id is known, either
//      passed in or found through ani.zip's mapping for the kitsu/mal/anilist/anidb id. The URL is
//      verified with a HEAD (an unknown tt answers 404), so a title metahub lacks falls through.
//   2. AniList bannerImage (anilistRequest, signed out, serialised with a gap and 429 retry inside).
//   3. Kitsu coverImage (upstream kitsuCoverImage, cached per id).
// Results are cached in memory per id (hits for the session, misses for a few minutes).
import type { Meta } from "@/lib/cinemeta";
import { safeFetch } from "@/lib/safe-fetch";
import { anilistRequest } from "@/lib/anilist/client";
import { kitsuCoverImage } from "@/lib/providers/kitsu";
import { aniZipByAnidb, aniZipByAnilist, aniZipByKitsu, aniZipByMal, type AniZipMapping } from "@/lib/providers/anizip";

const ANIME_ID = /^(kitsu|mal|anilist|anidb):(\d+)/;
const IMDB_ID = /^tt\d+$/;
const CACHE_MAX = 600;
const MISS_TTL_MS = 5 * 60 * 1000;
const ANILIST_GAP_MS = 700;
const STEP_TIMEOUT_MS = 8000;

const hits = new Map<string, string>();
const misses = new Map<string, number>();
const inflight = new Map<string, Promise<string | null>>();

function remember(id: string, url: string | null): void {
  if (url) {
    hits.delete(id);
    hits.set(id, url);
    if (hits.size > CACHE_MAX) { const oldest = hits.keys().next().value; if (oldest !== undefined) hits.delete(oldest); }
  } else {
    misses.delete(id);
    misses.set(id, Date.now());
    if (misses.size > CACHE_MAX) { const oldest = misses.keys().next().value; if (oldest !== undefined) misses.delete(oldest); }
  }
}

function within<T>(p: Promise<T>, ms: number, fallback: T): Promise<T> {
  return Promise.race([p.catch(() => fallback), new Promise<T>((r) => setTimeout(() => r(fallback), ms))]);
}

/** The metahub 16:9 background for an IMDb id, or null when metahub has none (HEAD answers 404). */
async function metahubBackground(imdb: string): Promise<string | null> {
  const url = `https://images.metahub.space/background/medium/${imdb}/img`;
  const ac = new AbortController();
  const timer = setTimeout(() => ac.abort(), STEP_TIMEOUT_MS);
  try {
    const res = await safeFetch(url, { method: "HEAD", signal: ac.signal });
    const type = res.headers.get("content-type") ?? "";
    // 405/501: a host that refuses HEAD says nothing about the image; take the URL on trust.
    const ok = (res.ok && !type.startsWith("text/")) || res.status === 405 || res.status === 501;
    return ok ? url : null;
  } catch {
    return null;
  } finally {
    clearTimeout(timer);
  }
}

let anilistChain: Promise<unknown> = Promise.resolve();
/** AniList allows ~90 requests a minute; the Anime room's own rows share it, so these queue. */
function anilistSlot<T>(run: () => Promise<T>): Promise<T> {
  const p = anilistChain.then(run, run);
  anilistChain = p.then(() => new Promise((r) => setTimeout(r, ANILIST_GAP_MS)), () => new Promise((r) => setTimeout(r, ANILIST_GAP_MS)));
  return p;
}

const BANNER_BY_ID = `query ($id: Int) { Media(id: $id, type: ANIME) { bannerImage } }`;
const BANNER_BY_MAL = `query ($id: Int) { Media(idMal: $id, type: ANIME) { bannerImage } }`;

async function anilistBanner(anilistId: number | null, malId: number | null): Promise<string | null> {
  if (anilistId == null && malId == null) return null;
  const byAnilist = anilistId != null;
  const data = await anilistSlot(() => anilistRequest<{ Media?: { bannerImage?: string | null } | null }>(
    byAnilist ? BANNER_BY_ID : BANNER_BY_MAL, { id: byAnilist ? anilistId : malId }, undefined, true));
  const url = data?.Media?.bannerImage;
  return typeof url === "string" && url.startsWith("http") ? url : null;
}

function num(v: unknown): number | null {
  return typeof v === "number" && Number.isFinite(v) ? v : null;
}

async function resolve(id: string, imdbHint: string | null): Promise<string | null> {
  const m = ANIME_ID.exec(id);
  const scheme = m?.[1] ?? "";
  const n = m ? Number(m[2]) : NaN;
  let kitsuId = scheme === "kitsu" ? n : null;
  let malId = scheme === "mal" ? n : null;
  let anilistId = scheme === "anilist" ? n : null;
  let imdb = imdbHint && IMDB_ID.test(imdbHint) ? imdbHint : IMDB_ID.test(id) ? id : null;

  // One ani.zip lookup (throttled and cached upstream) gives the IMDb id and the sibling ids.
  if (m) {
    const az: AniZipMapping | null = await within<AniZipMapping | null>(
      scheme === "kitsu" ? aniZipByKitsu(n) : scheme === "mal" ? aniZipByMal(n) : scheme === "anilist" ? aniZipByAnilist(n) : aniZipByAnidb(n),
      STEP_TIMEOUT_MS, null);
    const maps = az?.mappings;
    if (maps) {
      if (!imdb && typeof maps.imdb_id === "string" && IMDB_ID.test(maps.imdb_id)) imdb = maps.imdb_id;
      kitsuId = kitsuId ?? num(maps.kitsu_id);
      malId = malId ?? num(maps.mal_id);
      anilistId = anilistId ?? num(maps.anilist_id);
    }
  }

  if (imdb) {
    const url = await metahubBackground(imdb);
    if (url) return url;
  }
  const banner = await within<string | null>(anilistBanner(anilistId, malId), 30_000, null);
  if (banner) return banner;
  if (kitsuId != null) {
    const cover = await within<string | null>(kitsuCoverImage(kitsuId), STEP_TIMEOUT_MS, null);
    if (cover) return cover;
  }
  return null;
}

/**
 * The best landscape image for an anime id ("mal:", "kitsu:", "anilist:", "anidb:") or null. `name`
 * is accepted for the host's call shape and future title matching; the lookup is by id. Never
 * throws; cached per id.
 */
export async function backdrop(id: string, _name?: string | null, imdb?: string | null): Promise<string | null> {
  if (typeof id !== "string" || id === "") return null;
  if (!ANIME_ID.test(id) && !IMDB_ID.test(id)) return null;
  const hit = hits.get(id);
  if (hit) return hit;
  const missAt = misses.get(id);
  if (missAt != null && Date.now() - missAt < MISS_TTL_MS) return null;
  const running = inflight.get(id);
  if (running) return running;
  const p = resolve(id, imdb ?? null).catch(() => null).then((url) => { remember(id, url); return url; }).finally(() => { inflight.delete(id); });
  inflight.set(id, p);
  return p;
}

/** The cached backdrop for an id, without any network (hero slides read this on every page()). */
export function peek(id: string): string | null {
  return hits.get(id) ?? null;
}

/** True when a meta's own `background` is no real backdrop: absent, or Jikan's copy of the poster. */
export function lacksBackdrop(meta: Pick<Meta, "id" | "poster" | "background">): boolean {
  if (!ANIME_ID.test(meta.id)) return false;
  return !meta.background || meta.background === meta.poster;
}

/**
 * Hero slides only (a handful): swap in the cached backdrop where a slide has none, and start the
 * lookup for the rest, calling `onArrive` when one lands so the room re-reads. Returns new objects;
 * the room's own metas are never mutated.
 */
export function withBackdrops(metas: Meta[], onArrive: () => void): Meta[] {
  return metas.map((m) => {
    if (!lacksBackdrop(m)) return m;
    const cached = peek(m.id);
    if (cached) return { ...m, background: cached };
    if (!misses.has(m.id) && !inflight.has(m.id)) void backdrop(m.id, m.name).then((url) => { if (url) onArrive(); });
    return m;
  });
}

/** Tests: forget everything. */
export function reset(): void {
  hits.clear();
  misses.clear();
  inflight.clear();
}
