// Home's extra rows: views/big-picture/use-bp-extra-rows.ts without React, plus a row editor over
// lib/home-customization for the TV (Settings → Home rows).
//
// use-bp-extra-rows returns `{ before, after }`, which use-bp-catalog.ts lays around the catalog
// rows before dedup-by-key and applyHomeRowCustomization:
//   before: custom list rows (homeRows.listRows), home collection rows, pinned rows, Arabic rows,
//           Russian rows
//   after:  Favorites + My Watchlist, Trakt rails, Simkl rails, Letterboxd rails, anime rows
// The synchronous ones (lists, collections, favorites, watchlist, pinned AniList/MAL list rails)
// are read from storage on every build. The async ones (useAsyncRows upstream) run here as
// cached groups: rooms.home waits a short grace for them, and one that lands later raises
// `harbor:home-updated` so the TV re-reads Home, the way upstream's rows pop in when their
// promise settles.
import type { Meta } from "@/lib/cinemeta";
import type { HomeRow } from "@/views/home/home-types";
import type { Settings } from "@/lib/settings/types";
import { buildAnimeHomeRows } from "@/views/home/home-rows";
import { buildArabicHomeRows } from "@/lib/arabic/home-rows";
import { buildRussianHomeRows } from "@/lib/russian/home-rows";
import { buildTraktHomeRows } from "@/lib/trakt/home-rails";
import { isAuthenticated as traktAuthenticated } from "@/lib/trakt/session";
import { buildSimklHomeRows } from "@/lib/simkl/home-rails";
import { isAuthenticated as simklAuthenticated } from "@/lib/simkl/session";
import { readLists } from "@/lib/custom-lists";
import { readCollections } from "@/lib/collections";
import { collectionPageIds } from "@/lib/page-collection-rows";
import { pinnedBuiltinTitle, readPinnedCatalogs, type PinnedCatalog } from "@/lib/pinned-catalogs";
import { buildPinnedCatalogRows, pinnedRowKey } from "@/lib/pinned-catalogs-rows";
import { fetchAnilistTopAnime, fetchAnilistTrendingAnime } from "@/lib/anilist/browse";
import {
  addListRow,
  effectiveOrder,
  moveRow,
  removeListRow,
  renameRow,
  resetHomeRows,
  toggleRowHidden,
  toggleRowNumerals,
  type HomeRowCustomization,
} from "@/lib/home-customization";
import { loadEffective, persistEffective } from "@/lib/settings/profile-store";
import { getUiLanguage, t } from "@/lib/i18n";
import { anilist as anilistGlue, mal as malGlue } from "./trackers";
import { homeRailKey as letterboxdKey, homeRailRows as letterboxdRows } from "./letterboxd";
import { markSettingsPatched } from "./sync";

export type BpExtraRows = { before: HomeRow[]; after: HomeRow[] };

/** use-bp-extra-rows.ts listRow. */
function listRow(key: string, name: string, metas: Meta[]): HomeRow {
  return { key, type: "movie", name, metas, page: 1, hasMore: false, noDedup: true };
}

// ------------------------------------------------------------------------------ gating
export type ExtraPlan = { anime: boolean; arabic: boolean; russian: boolean; trakt: boolean; simkl: boolean; letterboxd: boolean };
export type ExtraEnv = { uiLang: string; trakt: boolean; simkl: boolean; letterboxd: boolean };

/**
 * Which async builders run (use-bp-extra-rows.ts): anime unless hideContent.anime or classic
 * mode; Arabic / Russian only in that UI language with a TMDB key and not classic; Trakt when
 * connected; Simkl when connected (buildSimklHomeRows itself returns nothing while
 * simklHomeRailsEnabled is off); Letterboxd when `lbReady`.
 */
export function extraPlan(s: Settings, env: ExtraEnv): ExtraPlan {
  const classic = s.homeMode === "classic";
  return {
    anime: !(s.hideContent?.anime === true || classic),
    arabic: env.uiLang === "ar" && !classic && !!s.tmdbKey,
    russian: env.uiLang === "ru" && !classic && !!s.tmdbKey,
    trakt: env.trakt,
    simkl: env.simkl && s.simklHomeRailsEnabled === true,
    letterboxd: env.letterboxd,
  };
}

// --------------------------------------------------------------------------- async groups
// useAsyncRows: one promise per builder and deps. A finished group is kept until its deps change;
// after GROUP_TTL_MS a build refreshes it in the background (Home remounts refetch upstream).
const GROUP_TTL_MS = 5 * 60_000;
type Group<T> = { sig: string; value: T; done: boolean; at: number; inflight: Promise<void> | null; late: boolean; mark: string };
const groups = new Map<string, Group<unknown>>();

let notifyTimer: ReturnType<typeof setTimeout> | null = null;
/** When the last `harbor:home-updated` went out (rooms.home reuses its catalog rows right after). */
let homeUpdatedAt = 0;
export const lastHomeUpdate = (): number => homeUpdatedAt;
/** Home re-reads on this (BrowseModel); debounced so a burst of arrivals is one reload. */
export function notifyHome(): void {
  if (notifyTimer) clearTimeout(notifyTimer);
  notifyTimer = setTimeout(() => {
    notifyTimer = null;
    homeUpdatedAt = Date.now();
    window.dispatchEvent(new CustomEvent("harbor:home-updated"));
  }, 300);
}

function rowsMark(v: unknown): string {
  if (!Array.isArray(v)) return "";
  return v.map((r: { key?: string; metas?: Meta[] }) => `${r.key ?? ""}:${(r.metas ?? []).map((m) => m.id).join(",")}`).join("|");
}

function group<T>(name: string, sig: string | null, empty: T, build: () => Promise<T>): { value: T; wait: Promise<void> | null } {
  if (sig === null) return { value: empty, wait: null };
  let g = groups.get(name) as Group<T> | undefined;
  if (!g || g.sig !== sig) {
    g = { sig, value: empty, done: false, at: 0, inflight: null, late: false, mark: "" };
    groups.set(name, g as Group<unknown>);
  }
  const stale = g.done && Date.now() - g.at > GROUP_TTL_MS;
  if (!g.inflight && (!g.done || stale)) {
    const mine = g;
    // useAsyncRows `.catch(() => {})`: a failed build keeps what was there.
    mine.inflight = build()
      .then((v) => { mine.value = v; }, () => undefined)
      .then(() => {
        const mark = rowsMark(mine.value);
        const changed = mark !== mine.mark;
        mine.mark = mark;
        mine.done = true;
        mine.at = Date.now();
        mine.inflight = null;
        if (mine.late && groups.get(name) === mine) {
          mine.late = false;
          if (changed) notifyHome();
        }
      });
    // A stale group shows its old rows now; the refresh re-renders Home when it lands.
    if (stale) mine.late = true;
  }
  return { value: g.value, wait: g.done ? null : g.inflight };
}

/** rooms.home stopped waiting: whatever is still in flight re-renders Home when it lands. */
export function markPendingLate(): void {
  for (const g of groups.values()) if (g.inflight) g.late = true;
}

/** Tests: forget every cached group. */
export function resetExtraGroups(): void {
  groups.clear();
}

// ---------------------------------------------------------------------- storage-backed rows
type MediaEntry = { id: string; type: "movie" | "series"; name: string; poster?: string; addedAt: number };

/** lib/media-list-store.tsx readMap (Favorites: harbor.favorites.v1.<pid>, My Watchlist: harbor.localwatchlist.v1.<pid>). */
function readMediaList(prefix: string, profileId: string): MediaEntry[] {
  const inferType = (id: string): "movie" | "series" => (id.includes(":tv:") || id.includes(":series:") ? "series" : "movie");
  const out = new Map<string, MediaEntry>();
  try {
    const arr = JSON.parse(localStorage.getItem(prefix + profileId) ?? "null") as unknown;
    if (!Array.isArray(arr)) return [];
    for (const el of arr as Array<string | Record<string, unknown>>) {
      if (typeof el === "string") out.set(el, { id: el, type: inferType(el), name: "", addedAt: 0 });
      else if (el && typeof el.id === "string") {
        out.set(el.id, {
          id: el.id,
          type: el.type === "series" ? "series" : el.type === "movie" ? "movie" : inferType(el.id),
          name: typeof el.name === "string" ? el.name : "",
          poster: typeof el.poster === "string" ? el.poster : undefined,
          addedAt: typeof el.addedAt === "number" ? el.addedAt : 0,
        });
      }
    }
  } catch {
    return [];
  }
  return [...out.values()];
}

/** use-bp-extra-rows.ts personalRows: Favorites then My Watchlist, newest first. */
export function personalRows(profileId: string): HomeRow[] {
  const toMetas = (list: MediaEntry[]): Meta[] =>
    [...list].sort((a, b) => b.addedAt - a.addedAt).map((e) => ({ id: e.id, type: e.type, name: e.name, poster: e.poster }) as Meta);
  const fav = readMediaList("harbor.favorites.v1.", profileId);
  const local = readMediaList("harbor.localwatchlist.v1.", profileId);
  const out: HomeRow[] = [];
  if (fav.length > 0) out.push(listRow("harbor-favorites", "Favorites", toMetas(fav)));
  if (local.length > 0) out.push(listRow("harbor-watchlist", "My Watchlist", toMetas(local)));
  return out;
}

/** use-bp-extra-rows.ts listHomeRows: homeRows.listRows in that order, empty lists skipped. */
export function listHomeRows(s: Settings): HomeRow[] {
  const ids = Array.isArray(s.homeRows?.listRows) ? s.homeRows.listRows : [];
  if (ids.length === 0) return [];
  const byId = new Map(readLists().map((l) => [l.id, l]));
  const out: HomeRow[] = [];
  for (const id of ids) {
    const l = byId.get(id);
    if (!l || l.items.length === 0) continue;
    out.push(listRow(`list-${l.id}`, l.name, l.items.map((it) => ({ id: it.id, type: it.type, name: it.name, poster: it.poster }) as Meta)));
  }
  return out;
}

/** use-bp-extra-rows.ts collectionHomeRows: useCollectionRowsForPage("home") (page order, cap 6), empty ones skipped. */
export function collectionHomeRows(): HomeRow[] {
  const byId = new Map(readCollections().map((c) => [c.id, c] as const));
  const out: HomeRow[] = [];
  for (const id of collectionPageIds("home")) {
    const c = byId.get(id);
    if (!c || c.items.length === 0) continue;
    out.push(listRow(`collection-${c.id}`, c.name, c.items.map((it) => ({ id: it.id, type: it.type, name: it.name, poster: it.poster }) as Meta)));
  }
  return out;
}

// --------------------------------------------------------------------------- pinned rows
/** use-pinned-rows.ts pinnedTitle. */
function pinnedTitle(desc: PinnedCatalog): string {
  const title = pinnedBuiltinTitle(desc.source, desc.params.railKey);
  if (!title) return desc.name;
  return title.valueKey ? t(title.key, { name: t(title.valueKey) }) : t(title.key);
}

let railsListener = false;
/** The AniList / MAL list rails load cache-first in trackers.ts; Home re-reads once they land. */
function watchTrackerRails(): void {
  if (railsListener) return;
  railsListener = true;
  const once = () => {
    window.removeEventListener("harbor:anime-updated", once);
    railsListener = false;
    notifyHome();
  };
  window.addEventListener("harbor:anime-updated", once);
}

/**
 * use-pinned-rows.ts usePinnedRows: in pin order, an addon catalog (buildPinnedCatalogRows), an
 * AniList rail (Trending / Top 100 browse lists, else the viewer's list rail) or a MAL list rail.
 */
function pinnedRows(waits: Promise<void>[]): HomeRow[] {
  const pinned = readPinnedCatalogs();
  if (pinned.length === 0) return [];
  const catalogKey = pinned.filter((p) => p.source === "catalog").map((p) => p.id).join("|");
  const cat = group<HomeRow[]>("pinned-catalogs", catalogKey ? catalogKey : null, [], () => buildPinnedCatalogRows(pinned));
  if (cat.wait) waits.push(cat.wait);
  const aniKeys = new Set(pinned.filter((p) => p.source === "anilist").map((p) => p.params.railKey));
  // use-anilist-top.ts: module-cached browse lists (trending 40, top 100).
  const trending = group<Meta[]>("anilist-trending", aniKeys.has("trending") ? "trending" : null, [], () => fetchAnilistTrendingAnime(40));
  const top = group<Meta[]>("anilist-top", aniKeys.has("top100") ? "top100" : null, [], () => fetchAnilistTopAnime(100));
  if (trending.wait) waits.push(trending.wait);
  if (top.wait) waits.push(top.wait);
  const needAnilist = [...aniKeys].some((k) => k !== "trending" && k !== "top100");
  const needMal = pinned.some((p) => p.source === "mal");
  const anilistRails = needAnilist && anilistGlue.status().authenticated ? anilistGlue.rails() : { rails: [], loading: false, error: false };
  const malRails = needMal && malGlue.status().authenticated ? malGlue.rails() : { rails: [], loading: false, error: false };
  if (anilistRails.loading || malRails.loading) watchTrackerRails();

  const extra = new Map<string, Meta[]>();
  if (trending.value.length > 0) extra.set("trending", trending.value);
  if (top.value.length > 0) extra.set("top100", top.value);
  const catalogById = new Map(cat.value.map((r) => [r.key, r] as const));
  const out: HomeRow[] = [];
  for (const desc of pinned) {
    const key = pinnedRowKey(desc.id);
    const name = pinnedTitle(desc);
    if (desc.source === "catalog") {
      const row = catalogById.get(key);
      if (row) out.push(row);
    } else if (desc.source === "anilist") {
      const metas = extra.get(desc.params.railKey);
      if (metas) {
        out.push({ key, type: "series", name, metas, page: 1, hasMore: false, noDedup: true });
        continue;
      }
      const rail = anilistRails.rails.find((r) => r.key === desc.params.railKey);
      if (rail && rail.metas.length > 0) out.push({ key, type: "series", name, metas: rail.metas, page: 1, hasMore: false, noDedup: true });
    } else if (desc.source === "mal") {
      const rail = malRails.rails.find((r) => r.key === desc.params.railKey);
      if (rail && rail.metas.length > 0) out.push({ key, type: "series", name, metas: rail.metas, page: 1, hasMore: false, noDedup: true });
    }
  }
  return out;
}

// ------------------------------------------------------------------------------ assembly
/**
 * useBpExtraRows for one profile: the rows available now plus the promises still running.
 * Call again after awaiting `waits` to pick up what landed (nothing is fetched twice).
 */
export function extraRows(s: Settings, profileId: string, linked: boolean): { rows: BpExtraRows; waits: Promise<void>[] } {
  const waits: Promise<void>[] = [];
  const lbKey = letterboxdKey(profileId, linked);
  const plan = extraPlan(s, { uiLang: getUiLanguage(), trakt: traktAuthenticated(), simkl: simklAuthenticated(), letterboxd: lbKey !== null });
  const tmdbKey = s.tmdbKey ?? "";
  const run = (name: string, on: boolean, sig: string, build: () => Promise<HomeRow[]>): HomeRow[] => {
    const g = group<HomeRow[]>(name, on ? sig : null, [], build);
    if (g.wait) waits.push(g.wait);
    return g.value;
  };
  const anime = run("anime", plan.anime, "anime", () => buildAnimeHomeRows());
  const arabic = run("arabic", plan.arabic, `${tmdbKey}|${s.tmdbLanguage ?? ""}`, () => buildArabicHomeRows(tmdbKey));
  const russian = run("russian", plan.russian, `${tmdbKey}|${s.tmdbLanguage ?? ""}`, () => buildRussianHomeRows(tmdbKey));
  const trakt = run("trakt", plan.trakt, `${profileId}|${tmdbKey}`, () => buildTraktHomeRows(tmdbKey));
  const simkl = run(
    "simkl",
    plan.simkl,
    JSON.stringify([profileId, tmdbKey, s.simklHomeRailsEnabled, s.simklUpNextRailEnabled, s.simklTrendingRailEnabled, s.simklGranularFilters]),
    () => buildSimklHomeRows(s),
  );
  const letterboxd = run("letterboxd", plan.letterboxd, `${profileId}|${lbKey ?? ""}`, () => letterboxdRows(profileId, linked));
  const pinned = pinnedRows(waits);
  return {
    rows: {
      before: [...listHomeRows(s), ...collectionHomeRows(), ...pinned, ...arabic, ...russian],
      after: [...personalRows(profileId), ...trakt, ...simkl, ...letterboxd, ...anime],
    },
    waits,
  };
}

// ---------------------------------------------------------------------------- row editor
// Upstream's Big Picture has no customize page (use-bp-row-layout.ts: the layout comes from the
// desktop through sync). The TV has no desktop beside it, so Settings → Home rows edits the same
// `settings.homeRows` with lib/home-customization's own moves, over the rows Home last built.
const lastAllByProfile = new Map<string, HomeRow[]>();
/** rooms.home records every row it built (hidden ones included, before customization). */
export function noteHomeRows(profileId: string, rows: HomeRow[]): void {
  lastAllByProfile.set(profileId, rows);
}

/** settings.homeRows, normalised: a synced blob lands verbatim (use-bp-row-layout.ts). */
export function homeCustomization(s: Settings): HomeRowCustomization {
  const h = (s.homeRows ?? {}) as Partial<HomeRowCustomization>;
  const strings = (v: unknown): string[] => (Array.isArray(v) ? v.filter((x): x is string => typeof x === "string") : []);
  return {
    ...h,
    order: strings(h.order),
    hidden: strings(h.hidden),
    renamed: h.renamed && typeof h.renamed === "object" ? h.renamed : {},
    numerals: strings(h.numerals),
    heroSource: typeof h.heroSource === "string" ? h.heroSource : null,
    customSources: Array.isArray(h.customSources) ? h.customSources : [],
    listRows: strings(h.listRows),
  };
}

export type HomeRowsState = {
  rows: Array<{ key: string; name: string; originalName: string; hidden: boolean; numerals: boolean }>;
  lists: Array<{ id: string; name: string; count: number; onHome: boolean }>;
  simkl: { connected: boolean; home: boolean; upNext: boolean; trending: boolean };
};

export function homeRowsState(profileId: string, linked: boolean): HomeRowsState {
  const s = loadEffective(profileId, linked);
  const c = homeCustomization(s);
  const all = lastAllByProfile.get(profileId) ?? [];
  const byKey = new Map(all.map((r) => [r.key, r] as const));
  const rows = effectiveOrder(all, c)
    .map((key) => byKey.get(key))
    .filter((r): r is HomeRow => !!r)
    .map((r) => ({ key: r.key, name: c.renamed[r.key] ?? r.name, originalName: r.name, hidden: c.hidden.includes(r.key), numerals: c.numerals.includes(r.key) }));
  const onHome = new Set(c.listRows ?? []);
  const lists = readLists().map((l) => ({ id: l.id, name: l.name, count: l.items.length, onHome: onHome.has(l.id) }));
  return {
    rows,
    lists,
    simkl: { connected: simklAuthenticated(), home: s.simklHomeRailsEnabled === true, upNext: s.simklUpNextRailEnabled === true, trending: s.simklTrendingRailEnabled === true },
  };
}

function writeSettings(profileId: string, linked: boolean, patch: Partial<Settings>): void {
  const s = loadEffective(profileId, linked);
  persistEffective({ ...s, ...patch }, profileId, linked);
  const fields = Object.keys(patch);
  markSettingsPatched(fields);
  window.dispatchEvent(new CustomEvent("harbor:settings-updated", { detail: { profileId, fields } }));
  notifyHome();
}

function editRows(profileId: string, linked: boolean, fn: (c: HomeRowCustomization, rows: HomeRow[]) => HomeRowCustomization): HomeRowsState {
  const c = homeCustomization(loadEffective(profileId, linked));
  writeSettings(profileId, linked, { homeRows: fn(c, lastAllByProfile.get(profileId) ?? []) as Settings["homeRows"] });
  return homeRowsState(profileId, linked);
}

export const homeRowMove = (profileId: string, linked: boolean, key: string, delta: -1 | 1): HomeRowsState =>
  editRows(profileId, linked, (c, rows) => moveRow(c, rows, key, delta < 0 ? -1 : 1));
export const homeRowToggleHidden = (profileId: string, linked: boolean, key: string): HomeRowsState =>
  editRows(profileId, linked, (c) => toggleRowHidden(c, key));
export const homeRowRename = (profileId: string, linked: boolean, key: string, name: string): HomeRowsState =>
  editRows(profileId, linked, (c) => renameRow(c, key, name));
export const homeRowToggleNumerals = (profileId: string, linked: boolean, key: string): HomeRowsState =>
  editRows(profileId, linked, (c) => toggleRowNumerals(c, key));
/** home-customization.ts addListRow / removeListRow: a custom list as a Home row. */
export const homeListRowToggle = (profileId: string, linked: boolean, listId: string): HomeRowsState =>
  editRows(profileId, linked, (c) => ((c.listRows ?? []).includes(listId) ? removeListRow(c, listId) : addListRow(c, listId)));
/** resetHomeRows keeps nothing, list rows and custom sources included (upstream's reset). */
export const homeRowsReset = (profileId: string, linked: boolean): HomeRowsState =>
  editRows(profileId, linked, () => resetHomeRows());

/** The Simkl home rail switches (simkl panel): simklHomeRailsEnabled / simklUpNextRailEnabled / simklTrendingRailEnabled. */
export function homeSimklRail(profileId: string, linked: boolean, which: "home" | "upNext" | "trending", on: boolean): HomeRowsState {
  const field = which === "home" ? "simklHomeRailsEnabled" : which === "upNext" ? "simklUpNextRailEnabled" : "simklTrendingRailEnabled";
  writeSettings(profileId, linked, { [field]: on } as Partial<Settings>);
  return homeRowsState(profileId, linked);
}
