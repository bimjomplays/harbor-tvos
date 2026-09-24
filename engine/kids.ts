// Kids mode for the TV app: the data half of views/kids.tsx (the Kids page), its franchise
// rail (views/kids/kids-franchise-rail.tsx + kids-franchises.ts), the franchise grid it opens
// (views/grid.tsx with kidsHero) and the simplified kids detail page (views/kids-detail.tsx +
// kids-detail/kids-episodes.tsx). Row specs, hero curation, franchise lists and the kid-safe
// filters are upstream's own modules; this file only replaces the React state around them.
import type { Meta } from "@/lib/cinemeta";
import { meta as fetchMeta, narrowMediaType, topMovies } from "@/lib/cinemeta";
import { recentlyPlayed } from "@/lib/playback-history";
import { listPager } from "@/lib/list-pager";
import { applyPageRows, loadPageRows } from "@/lib/page-rows";
import { loadEffective } from "@/lib/settings/profile-store";
import { tmdbLogo } from "@/lib/providers/tmdb/tmdb-images";
import { tmdbDetails, tmdbSeasonEpisodes } from "@/lib/providers/tmdb/tmdb-details";
import { tmdbCollection } from "@/lib/providers/tmdb/tmdb-collection";
import { dropUnreleased, dropUnsafeCinemetaKids, dropUnsafeGenres } from "@/views/kids/kids-filter";
import { buildKidsHero, kidsSpecs } from "@/views/kids/kids-specs";
import { franchiseFetcher, KIDS_FRANCHISES } from "@/views/kids/kids-franchises";

// kids.tsx:20 MAX_PER_ROW; kids.tsx:84 hasMore when the first page carried 14 or more.
const MAX_PER_ROW = 120;
const PAGINATE_THRESHOLD = 14;
// kids.tsx restRows: a row with fewer than 4 titles after the filters and dedup is dropped.
const MIN_ROW_METAS = 4;

export type KidsRow = { key: string; title: string; metas: Meta[]; hasMore: boolean };
export type KidsPage = { hasTmdb: boolean; hero: Meta[]; rows: KidsRow[]; failed: boolean };

type LiveRow = KidsRow & { page: number; fetcher?: (page: number) => Promise<Meta[]> };

/** Last build per profile, so Swift can page a row by key (kids.tsx loadMore). */
const builds = new Map<string, { hero: Meta[]; rows: LiveRow[] }>();
const buildKey = (profileId: string, linked: boolean) => `${profileId}|${linked ? 1 : 0}`;

/** kids.tsx restRows: filters, then dedup against the hero and earlier rows. */
function restRows(hero: Meta[], rows: LiveRow[]): KidsRow[] {
  const seen = new Set<string>();
  for (const m of hero) seen.add(m.id);
  return rows
    .map((r) => {
      const metas = dropUnsafeGenres(dropUnreleased(r.metas)).filter((m) => {
        if (seen.has(m.id)) return false;
        seen.add(m.id);
        return true;
      });
      return { key: r.key, title: r.title, metas, hasMore: r.hasMore };
    })
    .filter((r) => r.metas.length >= MIN_ROW_METAS);
}

/** kids.tsx CatalogRows(custom = usePageRows("kids")): hidden rows drop, renames and order apply. */
function customize(rows: KidsRow[]): KidsRow[] {
  return applyPageRows(rows, loadPageRows("kids"), false);
}

/** kids.tsx load effect: TMDB hero + kidsSpecs first pages, else the Cinemeta Animation/Family pair. */
export async function page(profileId: string, linked: boolean): Promise<KidsPage> {
  const settings = loadEffective(profileId, linked);
  const key = settings.tmdbKey;
  const seen = recentlyPlayed();
  let hero: Meta[] = [];
  let rows: LiveRow[] = [];
  if (key) {
    const heroPool = await buildKidsHero(key, seen).catch(() => [] as Meta[]);
    hero = dropUnsafeGenres(dropUnreleased(heroPool));
    const specs = kidsSpecs(key);
    const firstPages = await Promise.all(specs.map((s) => s.fetcher(1).catch(() => [] as Meta[])));
    rows = specs
      .map((spec, i) => ({
        key: spec.key,
        title: spec.title,
        metas: firstPages[i],
        page: 1,
        hasMore: firstPages[i].length >= PAGINATE_THRESHOLD,
        fetcher: spec.fetcher,
      }))
      .filter((r) => r.metas.length > 0);
  } else {
    const [animation, family] = await Promise.all(
      ["Animation", "Family"].map((genre) =>
        topMovies(genre)
          .then(dropUnreleased)
          .then(dropUnsafeCinemetaKids)
          .catch(() => [] as Meta[]),
      ),
    );
    hero = animation.filter((m) => m.background).slice(0, 5);
    rows = [
      { key: "cinemeta-animation", title: "Animated Movies", metas: animation },
      { key: "cinemeta-family", title: "Family Movies", metas: family },
    ].map((row) => ({ ...row, page: 1, hasMore: false, fetcher: listPager(row.metas) }));
  }
  builds.set(buildKey(profileId, linked), { hero, rows });
  const shown = customize(restRows(hero, rows));
  return { hasTmdb: Boolean(key), hero, rows: shown, failed: hero.length === 0 && shown.length === 0 };
}

/**
 * kids.tsx loadMore: the next page of one row, merged into the last build (dedup, capped at
 * MAX_PER_ROW). Returns the row as it now shows, after the same filters and dedup as `page`.
 */
export async function loadMore(profileId: string, linked: boolean, rowKey: string): Promise<KidsRow | null> {
  const build = builds.get(buildKey(profileId, linked));
  const row = build?.rows.find((r) => r.key === rowKey);
  if (!build || !row) return null;
  if (row.fetcher && row.hasMore && row.metas.length < MAX_PER_ROW) {
    const next = row.page + 1;
    const more = await row.fetcher(next).catch(() => [] as Meta[]);
    const ids = new Set(row.metas.map((m) => m.id));
    const combined = [...row.metas, ...more.filter((m) => !ids.has(m.id))];
    const reachedCap = combined.length >= MAX_PER_ROW;
    row.metas = reachedCap ? combined.slice(0, MAX_PER_ROW) : combined;
    row.page = next;
    row.hasMore = !reachedCap && more.length > 0;
  }
  return restRows(build.hero, build.rows).find((r) => r.key === rowKey) ?? null;
}

// ------------------------------------------------------------------------ hero card logo
/** kids-hero.tsx KidsHeroCard: TMDB's logo for tmdb ids, else the Cinemeta meta's logo. */
export async function logo(meta: Meta, profileId: string, linked: boolean): Promise<string | null> {
  if (meta.logo) return meta.logo;
  const settings = loadEffective(profileId, linked);
  const url = meta.id.startsWith("tmdb:")
    ? await tmdbLogo(settings.tmdbKey, meta.id, meta.originalLanguage).catch(() => undefined)
    : await fetchMeta(narrowMediaType(meta.type), meta.id).then((full) => full?.logo).catch(() => undefined);
  return url ?? null;
}

// ------------------------------------------------------------------------- franchises
// Tailwind palette entries the franchise gradients use (`from-… via-… to-…` in kids-franchises.ts).
const TAILWIND: Record<string, string> = {
  "amber-300": "#fcd34d", "amber-400": "#fbbf24",
  "blue-400": "#60a5fa", "blue-500": "#3b82f6", "blue-600": "#2563eb",
  "cyan-300": "#67e8f9", "cyan-600": "#0891b2",
  "emerald-500": "#10b981", "emerald-700": "#047857",
  "fuchsia-500": "#d946ef",
  "green-500": "#22c55e", "green-600": "#16a34a",
  "indigo-400": "#818cf8",
  "lime-500": "#84cc16",
  "orange-500": "#f97316",
  "purple-700": "#7e22ce",
  "red-500": "#ef4444", "red-600": "#dc2626",
  "rose-500": "#f43f5e",
  "sky-300": "#7dd3fc", "sky-400": "#38bdf8",
  "teal-500": "#14b8a6",
  "violet-600": "#7c3aed",
  "yellow-300": "#fde047", "yellow-400": "#facc15",
};

/** "from-sky-400 via-sky-300 to-amber-300" → the three stops as CSS hex. */
export function gradStops(grad: string): string[] {
  return grad
    .split(/\s+/)
    .map((c) => /^(?:from|via|to)-(.+)$/.exec(c)?.[1])
    .filter((c): c is string => Boolean(c))
    .map((c) => TAILWIND[c])
    .filter((c): c is string => Boolean(c));
}

export type FranchiseTile = { key: string; name: string; stops: string[]; drop: number | null; art: string };

/** kids-franchise-rail.tsx: the "Pick a World" tiles, only with a TMDB key (the rail returns null without). */
export function franchises(profileId: string, linked: boolean): FranchiseTile[] {
  if (!loadEffective(profileId, linked).tmdbKey) return [];
  return KIDS_FRANCHISES.map((f) => ({
    key: f.key,
    name: f.name,
    stops: gradStops(f.grad),
    drop: f.drop ?? null,
    art: `/kids/cta/${f.key}.webp`,
  }));
}

/** FranchiseTile open(): franchiseFetcher(page) → dropUnreleased → dropUnsafeGenres (grid.tsx pages it). */
export async function franchisePage(profileId: string, linked: boolean, franchiseKey: string, page: number): Promise<Meta[]> {
  const key = loadEffective(profileId, linked).tmdbKey;
  const f = KIDS_FRANCHISES.find((x) => x.key === franchiseKey);
  if (!key || !f) return [];
  const metas = await franchiseFetcher(key, f)(page).catch(() => [] as Meta[]);
  return dropUnsafeGenres(dropUnreleased(metas));
}

// ------------------------------------------------------------------------ kids detail
export type KidsSeason = { seasonNumber: number; name: string };
export type KidsDetail = {
  name: string;
  backdrop: string | null;
  logo: string | null;
  overview: string;
  genres: string[];
  runtime: string | null;
  year: string | null;
  tvId: number | null;
  seasons: KidsSeason[];
  collection: { id: number; name: string; metas: Meta[] } | null;
  recs: Meta[];
};

/** kids-detail.tsx dedupe: drop the title itself and repeats, keep 24. */
function dedupe(list: Meta[], excludeId: string): Meta[] {
  const seen = new Set<string>([excludeId]);
  const out: Meta[] = [];
  for (const m of list) {
    if (seen.has(m.id)) continue;
    seen.add(m.id);
    out.push(m);
  }
  return out.slice(0, 24);
}

/** kids-detail.tsx KidsDetailView: Cinemeta meta + TMDB detail, merged the way the page reads them. */
export async function detail(meta: Meta, profileId: string, linked: boolean): Promise<KidsDetail> {
  const settings = loadEffective(profileId, linked);
  const key = settings.tmdbKey;
  const [base, d] = await Promise.all([
    fetchMeta(narrowMediaType(meta.type), meta.id).catch(() => null),
    key ? tmdbDetails(key, meta).catch(() => null) : Promise.resolve(null),
  ]);
  const overview = d?.overview || base?.description || (meta.id.startsWith("tmdb:") ? "" : meta.description) || "";
  const genres = (d?.genres?.length ? d.genres : base?.genres) ?? [];
  const recs = dropUnsafeGenres(dropUnreleased(dedupe([...(d?.recommendations ?? []), ...(d?.similar ?? [])], meta.id)));
  // collection-row.tsx under a kid profile: the other parts, through the same kid filters.
  let collection: KidsDetail["collection"] = null;
  if (key && d?.collection) {
    const c = await tmdbCollection(key, d.collection.id).catch(() => null);
    const rest = c ? dropUnsafeGenres(dropUnreleased(c.parts.filter((p) => p.id !== meta.id))) : [];
    if (c && rest.length > 0) collection = { id: d.collection.id, name: d.collection.name || c.name, metas: rest };
  }
  return {
    name: meta.name || base?.name || d?.title || "",
    backdrop: d?.backdrop || base?.background || meta.background || meta.poster || null,
    logo: d?.logo || base?.logo || meta.logo || null,
    overview,
    genres: genres.slice(0, 2),
    runtime: d?.runtime ?? null,
    year: meta.releaseInfo || base?.releaseInfo || null,
    tvId: meta.type === "series" && d && d.kind === "tv" && d.seasons.length > 0 ? d.id : null,
    seasons: meta.type === "series" && d ? d.seasons.map((s) => ({ seasonNumber: s.seasonNumber, name: s.name })) : [],
    collection,
    recs,
  };
}

// kids-episodes.tsx STILL.
const STILL = "https://image.tmdb.org/t/p/w300";
export type KidsEpisode = { id: number; season: number; episode: number; name: string; still: string | null; rating: string | null };

/** kids-episodes.tsx: one season's episodes from TMDB; rating shows as one decimal when above 0. */
export async function episodes(tvId: number, season: number, profileId: string, linked: boolean): Promise<KidsEpisode[]> {
  const key = loadEffective(profileId, linked).tmdbKey;
  if (!key) return [];
  const eps = await tmdbSeasonEpisodes(key, tvId, season).catch(() => []);
  return eps.map((ep) => ({
    id: ep.id,
    season: ep.seasonNumber,
    episode: ep.episodeNumber,
    name: ep.name,
    still: ep.stillPath ? `${STILL}${ep.stillPath}` : null,
    rating: ep.voteAverage && ep.voteAverage > 0 ? ep.voteAverage.toFixed(1) : null,
  }));
}
