// Anime room (use-bp-anime.ts + bp-anime-groups.ts without React): the 16 Jikan spec rows load
// progressively on Jikan's own queue, Continue Watching comes from local + cloud anime items,
// the hero is upstream's seeded selection, awards join from the bundled index, addon anime
// catalogs stream in, and buildBpAnimeGroups shapes it all. Every arrival raises
// `harbor:anime-updated`; the host re-reads `page()` (cheap, from memory).
import type { Meta } from "@/lib/cinemeta";
import { EMPTY_ROW, ROW_MAX_PAGES, ROW_MIN_VISIBLE, SPECS, TOP_PICKS_KEY, type RowState } from "@/views/anime/anime-rows";
import { buildBpAnimeGroups, filterSpecRows, mergeAwardWinners, dedupeAnimeAddonRows, cleanMeta, type BpAnimeRow } from "@/views/big-picture/bp-anime-groups";
import { buildHeroSelection } from "@/views/anime/hero-build";
import { animeFiltered, type AnimeFilterOpts } from "@/lib/anime-filter";
import { applyAnimeRowCustomization, EMPTY_ANIME_ROWS } from "@/lib/anime-customization";
import { noteAnimeGroups } from "./actions";
import { loadAnimeAddonRows } from "@/lib/addons-anime-filter";
import type { AddonRow } from "@/lib/addons";
import { listLocalCw, localCwEntry } from "@/lib/local-cw";
import { anyProfileSharesStremioWith, type Profile } from "@/lib/profiles";
import { fetchSimklPlaybackItems } from "@/lib/simkl/playback";
import { isAuthenticated as simklConnected } from "@/lib/simkl/session";
import { isCwDismissed } from "@/lib/cw-dismiss";
import { franchiseRootSync } from "@/lib/providers/anime-franchise-root";
import { ANIME_CLOUD_ID, isAnimeCwItem, isCwMember, library, type LibraryItem } from "@/lib/stremio";
import { readCollections } from "@/lib/collections";
import { collectionPageIds } from "@/lib/page-collection-rows";
import { loadEffective } from "@/lib/settings/profile-store";
import { anilist as anilistGlue, mal as malGlue } from "./trackers";

const MAX_ITEMS = 80;
const CW_CAP = 20;
const AUTO_FILL_BUDGET = 4;

const t = (key: string, vars?: Record<string, string | number>) => key.replace(/\{(\w+)\}/g, (_, k) => String(vars?.[k] ?? `{${k}}`));

// ------------------------------------------------------------------------- spec rows
const rowsByKey: Record<string, RowState> = {};
for (const s of SPECS) rowsByKey[s.key] = EMPTY_ROW;
const loading = new Set<string>();
let started = false;
let pending = 0;
const filled = new Set<string>();

function notify(): void {
  window.dispatchEvent(new CustomEvent("harbor:anime-updated"));
}

/** use-bp-anime-specs: fire flat in SPECS order; Jikan's 400 ms queue paces the requests. */
function ensureStarted(): void {
  if (started) return;
  started = true;
  pending = SPECS.length;
  for (const s of SPECS) {
    s.fetcher(1)
      .then((metas) => { rowsByKey[s.key] = { metas, page: 1, hasMore: metas.length >= ROW_MIN_VISIBLE, ready: true }; })
      .catch(() => { rowsByKey[s.key] = { ...EMPTY_ROW, ready: true }; })
      .finally(() => { pending -= 1; notify(); });
  }
}

export function loadMore(key: string): boolean {
  if (loading.has(key)) return false;
  const spec = SPECS.find((s) => s.key === key);
  const row = rowsByKey[key];
  if (!spec || !row || !row.hasMore || row.page >= ROW_MAX_PAGES || row.metas.length >= MAX_ITEMS) return false;
  loading.add(key);
  const next = row.page + 1;
  spec.fetcher(next).then((more) => {
    const cur = rowsByKey[key];
    const ids = new Set(cur.metas.map((m) => m.id));
    const fresh = more.filter((m) => !ids.has(m.id));
    rowsByKey[key] = { ...cur, metas: [...cur.metas, ...fresh], page: next, hasMore: more.length >= ROW_MIN_VISIBLE && cur.metas.length + fresh.length < MAX_ITEMS };
  }).catch(() => {}).finally(() => { loading.delete(key); notify(); });
  return true;
}

/** Re-fetch every spec row (the room's refresh). */
export function refresh(): void {
  started = false;
  filled.clear();
  for (const s of SPECS) rowsByKey[s.key] = EMPTY_ROW;
  ensureStarted();
}

// ------------------------------------------------------------------------ addon rows
let addonRows: AddonRow[] = [];
let addonKey: string | null = null;
let stopAddons: (() => void) | null = null;

function ensureAddons(authKey: string | null, profileId: string): void {
  // Installed addons are per profile even without a Stremio session (two guest profiles).
  const key = `${profileId}|${authKey ?? ""}`;
  if (addonKey === key) return;
  stopAddons?.();
  addonKey = key;
  addonRows = [];
  stopAddons = loadAnimeAddonRows(authKey, (rows) => { addonRows = rows; notify(); });
}

// --------------------------------------------------------------- continue watching
let cloud: { authKey: string; at: number; items: LibraryItem[] } | null = null;

async function cloudItems(authKey: string | null, force: boolean): Promise<LibraryItem[]> {
  if (!authKey) return [];
  if (!force && cloud && cloud.authKey === authKey && Date.now() - cloud.at < 30_000) return cloud.items;
  const items = await library(authKey).catch(() => cloud?.items ?? []);
  cloud = { authKey, at: Date.now(), items };
  return items;
}

function localAnimeCw(): LibraryItem[] {
  return listLocalCw().filter((e) => ANIME_CLOUD_ID.test(e.id)).map((e) => ({
    _id: e.id, type: e.type, name: e.name, poster: e.poster, background: e.background,
    state: { timeOffset: e.positionMs, duration: e.durationMs, season: e.season, episode: e.episode, video_id: e.videoId,
      flaggedWatched: e.durationMs > 0 && e.positionMs / e.durationMs >= 0.9 ? 1 : 0, lastWatched: new Date(e.t).toISOString() },
    removed: false, temp: false, _ctime: new Date(e.t).toISOString(), _mtime: new Date(e.t).toISOString(), local: true,
  } as LibraryItem));
}

function profilesBlob(): { activeId?: string | null; profiles?: Profile[] } {
  try { return JSON.parse(localStorage.getItem("harbor.profiles.v1") ?? "{}") as { activeId?: string | null; profiles?: Profile[] }; } catch { return {}; }
}

/**
 * use-bp-anime-cw raw: local anime resume + cloud anime items + Simkl playback, dismissed
 * dropped, cloud rows hidden when this profile shares the Stremio session and asked for
 * per-profile Continue Watching, one per franchise, newest first.
 */
function animeCw(cloudList: LibraryItem[], simklList: LibraryItem[], hideSharedCw: boolean): LibraryItem[] {
  const pool = [...localAnimeCw(), ...cloudList.filter((i) => !ANIME_CLOUD_ID.test(i._id)), ...simklList];
  const seen = new Set<string>();
  const seenRoot = new Set<string>();
  return pool
    .filter((i) => {
      if (!isCwMember(i)) return false;
      if (!(i as LibraryItem & { local?: boolean }).local && !isAnimeCwItem(i)) return false;
      if (isCwDismissed(i)) return false;
      if (hideSharedCw && localCwEntry(i._id) === null && !(i as LibraryItem & { local?: boolean }).local) return false;
      if (seen.has(i._id)) return false;
      seen.add(i._id);
      return true;
    })
    .sort((a, b) => Date.parse(b.state?.lastWatched ?? b._mtime) - Date.parse(a.state?.lastWatched ?? a._mtime))
    .filter((i) => {
      const root = franchiseRootSync(i._id);
      if (!root) return true;
      if (seenRoot.has(root)) return false;
      seenRoot.add(root);
      return true;
    })
    .slice(0, CW_CAP);
}

// ------------------------------------------------------------------------------ page
const seed = Math.floor(Math.random() * 0x7fffffff);

export type RoomRow = { key: string; group: string; name: string; metas: Meta[]; shape: "poster" | "rank"; loading: boolean; notice: string | null; hasMore: boolean; page: number };

export async function page(profileId: string, linked: boolean, authKey: string | null, force = false) {
  const s = loadEffective(profileId, linked);
  if (force) refresh(); else ensureStarted();
  ensureAddons(authKey, profileId);
  const filterOpts: AnimeFilterOpts = { excludeOrigins: s.animeExcludeOrigins ?? [], hideWatched: !!s.animeHideWatchedPicks, isWatched: undefined };
  const blob = profilesBlob();
  const active = (blob.profiles ?? []).find((p) => p.id === (blob.activeId ?? profileId)) ?? null;
  const hideSharedCw = !!s.cwPerProfile && anyProfileSharesStremioWith(active, blob.profiles ?? []);
  const simkl = simklConnected() ? await fetchSimklPlaybackItems().then((list) => list.filter(isAnimeCwItem)).catch(() => [] as LibraryItem[]) : [];
  const cw = animeCw(await cloudItems(authKey, force), simkl, hideSharedCw);

  const hero = buildHeroSelection(rowsByKey, seed, filterOpts, []);
  const picksRow = rowsByKey[TOP_PICKS_KEY];
  const topPicks = (picksRow?.metas ?? []).filter((m) => !animeFiltered(m, filterOpts)).map(cleanMeta).slice(0, 20);
  const specRows = filterSpecRows(rowsByKey, topPicks);

  // use-bp-anime auto-fill: a row the dedupe left short pulls its next page, up to a budget.
  if (filled.size < AUTO_FILL_BUDGET) {
    for (const spec of SPECS) {
      const raw = rowsByKey[spec.key];
      if (!raw?.ready || !raw.hasMore || raw.page >= ROW_MAX_PAGES) continue;
      const shown = specRows[spec.key];
      if (!shown || shown.metas.length >= ROW_MIN_VISIBLE || filled.has(spec.key)) continue;
      filled.add(spec.key);
      loadMore(spec.key);
      if (filled.size >= AUTO_FILL_BUDGET) break;
    }
  }

  const awards = mergeAwardWinners(specRows, []);
  const collections = readCollections().filter((c) => collectionPageIds("anime").includes(c.id));
  const malConnected = malGlue.status().authenticated;
  const anilistConnected = anilistGlue.status().authenticated;
  const malRails = malConnected ? malGlue.rails(force) : { rails: [], loading: false, error: false };
  const anilistRails = anilistConnected ? anilistGlue.rails(force) : { rails: [], loading: false, error: false };
  const groups = buildBpAnimeGroups({
    t, renamed: s.animeRows?.renamed ?? {},
    cwItems: cw, cwReady: true, cwPending: false,
    malConnected, malRails: malRails.rails, malState: { loading: malRails.loading, error: malRails.error },
    anilistConnected, anilistRails: anilistRails.rails, anilistState: { loading: anilistRails.loading, error: anilistRails.error },
    anilistTrending: [], anilistTop: [],
    awards, specRows, addonRows: dedupeAnimeAddonRows(addonRows, s.hideContent?.adult !== false), collections,
  });
  // Row customisation (order / hidden / renamed) as the anime settings store it.
  noteAnimeGroups(groups.map((g) => ({ key: g.key, name: g.name })), profileId);
  const ordered = applyAnimeRowCustomization(groups.map((g) => ({ key: g.key, name: g.name, group: g })), s.animeRows ?? EMPTY_ANIME_ROWS);
  const rows: RoomRow[] = [];
  for (const entry of ordered) {
    for (const r of entry.group.rows as BpAnimeRow[]) {
      if (r.id === "continueWatching") continue;
      // MAL / AniList placeholders need a sign-in the TV cannot do yet; they stay out of the rail.
      if (r.notice && (r.group === "yourMalLists" || r.group === "yourAnilistLists")) continue;
      rows.push({ key: r.id, group: r.group, name: entry.name === r.title ? r.title : r.title, metas: r.metas, shape: r.ranked ? "rank" : "poster",
        loading: !!r.loading, notice: r.notice ?? null, hasMore: !!r.source?.hasMore, page: r.source?.page ?? 1 });
    }
  }
  const ready = SPECS.filter((sp) => rowsByKey[sp.key]?.ready).length;
  // use-bp-anime.ts:238: failure is "every feed answered with nothing", never "every row hidden".
  const fetched = SPECS.reduce((n, sp) => n + (rowsByKey[sp.key]?.metas.length ?? 0), 0) + addonRows.reduce((n, r) => n + r.metas.length, 0);
  return {
    rows, hero: hero.metas.slice(0, 8), picks: topPicks, cw,
    loading: pending > 0, ready, total: SPECS.length,
    failed: ready === SPECS.length && fetched === 0 && cw.length === 0,
  };
}

/** Next page of one spec row for the "See all" grid (rooms.page equivalent). */
export async function specPage(key: string, pageNo: number): Promise<Meta[]> {
  const spec = SPECS.find((sp) => sp.key === key);
  if (!spec) return [];
  return (await spec.fetcher(pageNo)).map(cleanMeta);
}


// ------------------------------------------------------------ hero actions / meta line
// bp-anime-hero-meta.tsx: the award pill or "New", the MAL score, "Sub and Dub", the country.
import { findTopAward as heroTopAward, parseAwardYear as heroAwardYear } from "@/lib/anime-awards";
import { animeHasDub as heroHasDub, ensureDubSet as heroEnsureDub } from "@/lib/providers/anime-dub-sub";
import { jikanScore as heroJikanScore } from "@/lib/mal-rating";
import { kitsuToMal as heroKitsuToMal } from "@/lib/providers/anime-mapping";
import { dubSetReady as heroDubReady } from "@/lib/providers/anime-dub-sub";
export type HeroMeta = { topLine: string; score: string | null; fromMal: boolean; dub: boolean; country: string; episode: string; minutesLeft: string };
// lib/mal-rating resolveMalId: mal: ids directly, kitsu: ids through the ARM mapping.
async function heroMalId(metaId: string): Promise<number | null> {
  if (metaId.startsWith("mal:")) { const n = Number(metaId.slice(4)); return Number.isFinite(n) ? n : null; }
  if (metaId.startsWith("kitsu:")) { const n = Number(metaId.slice(6)); return Number.isFinite(n) ? heroKitsuToMal(n).catch(() => null) : null; }
  return null;
}
export async function heroMeta(meta: Meta, profileId: string, linked: boolean, cwItem: { season?: number | null; episode?: number | null; duration?: number | null; timeOffset?: number | null } | null): Promise<HeroMeta> {
  const s = loadEffective(profileId, linked);
  const win = heroTopAward(meta.name ?? "", heroAwardYear(meta.releaseInfo), meta.id);
  const topLine = win ? (win.isAOTY ? "Anime of the year" : `Best ${win.categoryName ?? ""}`.trim()) : meta.releaseInfo === String(new Date().getFullYear()) ? "New" : "";
  const malId = await heroMalId(meta.id);
  const jikan = malId ? await heroJikanScore(malId).catch(() => null) : null;
  const score = jikan ?? meta.imdbRating ?? null;
  let dub = false;
  if (s.showDubBadge !== false) {
    // ensureDubSet fires the load and returns; wait (bounded) for the set before asking it.
    try { heroEnsureDub(); for (let i = 0; i < 30 && !heroDubReady(); i += 1) await new Promise((r) => setTimeout(r, 100)); dub = heroHasDub(meta.id); } catch { dub = false; }
  }
  const c = (meta as { country?: string }).country ?? "";
  const country = c.length > 3 && c !== "Japan" ? c : "";
  const se = cwItem?.season ?? 0, ep = cwItem?.episode ?? 0;
  const episode = ep > 0 ? (se > 0 ? `S${se} E${ep}` : `E${ep}`) : "";
  const dur = cwItem?.duration ?? 0, off = cwItem?.timeOffset ?? 0;
  const left = dur > 0 ? Math.round((dur - off) / 60000) : 0;
  return { topLine, score, fromMal: jikan != null, dub, country, episode, minutesLeft: left >= 1 ? `${left} min left` : "" };
}
