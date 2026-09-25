// Library room (use-bp-library.ts + use-bp-library-services.ts without React): tabs, one feed
// per tab (Saved / Watchlist / History / My Lists / Favorites / Trakt / AniList / MAL / Simkl /
// Letterboxd), the same merge rules, then bp's sort → sections → cap, plus the library repair
// actions. Local files do not exist on tvOS.
import type { Meta } from "@/lib/cinemeta";
import { library, isAnimeCwItem, type LibraryItem } from "@/lib/stremio";
import { readLocalEntries } from "@/lib/watchlist";
import { readLists } from "@/lib/custom-lists";
import { isAuthenticated as traktConnected, getSession as traktSession } from "@/lib/trakt/session";
import { fetchWatchlist as fetchTraktWatchlist } from "@/lib/trakt/watchlist";
import { fetchWatchedHistory, type HistoryItem } from "@/lib/trakt/history";
import { traktItemToMeta } from "@/lib/trakt/to-meta";
import type { TraktItem } from "@/lib/trakt/types";
import { isAuthenticated as simklConnected } from "@/lib/simkl/session";
import { getLocalCache, syncWatchlistCache, type SimklCache } from "@/lib/simkl/activities";
import { SIMKL_STATUS_LABELS } from "@/lib/simkl/list-status";
import { filterLibrary, mergeWatchlist } from "@/views/library/watchlist-tab";
import { filterHistory, historyItemsToDated, mergeHistory } from "@/views/library/history-merge";
import { applyFilter, parseTs, sortedGroups, type SortKey, type TypeKey } from "@/views/library/shared";
import { loadEffective, persistEffective } from "@/lib/settings/profile-store";
import { markSettingsPatched } from "./sync";
import { anilist as anilistGlue, mal as malGlue } from "./trackers";
import { mediaServerConnections } from "@/lib/media-server/connections";
import { titles as homeServerTitles } from "./homeServers";
import { status as letterboxdStatus, watchlist as letterboxdWatchlist } from "./letterboxd";
import { repairStremioLibrary, type RepairProgress, type RepairResult } from "@/lib/stremio-library-repair";
import { findCorruptAnimeEntries, healCorruptAnimeEntries } from "@/lib/anime-cw-repair";
import { clearResurfaceCache } from "@/lib/cw-resurface";
import { readLibraryFilterPreferences, writeLibraryFilterPreferences } from "@/views/library/filter-preferences";

export type Tab = "library" | "watchlist" | "history" | "lists" | "favorites" | "media-servers" | "trakt" | "anilist" | "mal" | "simkl" | "letterboxd";
type Status = "loading" | "ready" | "error";

export type Entry = {
  key: string; meta: Meta; date: number | null; group?: string; groups?: string[];
  progress?: number; season?: number; episode?: number; watched?: boolean;
};

const CORE: Array<{ id: Tab; label: string }> = [
  { id: "library", label: "Saved" }, { id: "watchlist", label: "Watchlist" }, { id: "history", label: "History" },
  { id: "lists", label: "My Lists" }, { id: "favorites", label: "Favorites" },
];

export function tabs(profileId = "default", linked = true): Array<{ id: Tab; label: string }> {
  const out = [...CORE];
  if (mediaServerConnections().length > 0) out.push({ id: "media-servers", label: "Media Servers" });
  if (traktConnected()) out.push({ id: "trakt", label: "Trakt" });
  if (anilistGlue.status().authenticated) out.push({ id: "anilist", label: "AniList" });
  if (malGlue.status().authenticated) out.push({ id: "mal", label: "MyAnimeList" });
  if (simklConnected()) out.push({ id: "simkl", label: "Simkl" });
  // use-bp-library.ts:72: Letterboxd joins while its integration is active.
  if (letterboxdStatus(profileId || "default", linked !== false).active) out.push({ id: "letterboxd", label: "Letterboxd" });
  return out;
}

// ---- cached remote sources (30 s), so filter/sort/tab switches never refetch
const TTL = 30_000;
let stremioCache: { authKey: string; at: number; items: LibraryItem[] } | null = null;
let traktCache: { token: string; at: number; watchlist: TraktItem[]; history: HistoryItem[]; error: boolean } | null = null;

async function stremioItems(authKey: string | null, force: boolean): Promise<{ items: LibraryItem[]; status: Status }> {
  if (!authKey) return { items: [], status: "ready" };
  if (!force && stremioCache && stremioCache.authKey === authKey && Date.now() - stremioCache.at < TTL) return { items: stremioCache.items, status: "ready" };
  try {
    const items = await library(authKey);
    stremioCache = { authKey, at: Date.now(), items };
    return { items, status: "ready" };
  } catch {
    return { items: stremioCache?.items ?? [], status: "error" };
  }
}

async function traktItems(force: boolean): Promise<{ watchlist: TraktItem[]; history: HistoryItem[]; status: Status }> {
  if (!traktConnected()) return { watchlist: [], history: [], status: "ready" };
  // Sessions are per profile: the cache belongs to one access token, never to "whoever is connected".
  const token = traktSession()?.accessToken ?? "";
  const same = traktCache && traktCache.token === token;
  if (!force && same && Date.now() - traktCache!.at < TTL) return { ...traktCache!, status: traktCache!.error ? "error" : "ready" };
  const [w, h] = await Promise.allSettled([fetchTraktWatchlist(), fetchWatchedHistory(200)]);
  const watchlist = w.status === "fulfilled" ? w.value : (same ? traktCache!.watchlist : []);
  const history = h.status === "fulfilled" ? h.value : (same ? traktCache!.history : []);
  const error = w.status === "rejected" && h.status === "rejected";
  traktCache = { token, at: Date.now(), watchlist, history, error };
  return { watchlist, history, status: error ? "error" : "ready" };
}

function usable(i: LibraryItem): boolean {
  return (i.type as string) !== "other" && !i._id.startsWith("iptv:");
}

function worst(a: Status, b: Status): Status {
  if (a === "loading" || b === "loading") return "loading";
  return a === "error" || b === "error" ? "error" : "ready";
}

/** lib/media-list-store.ts readMap for the favorites prefix (`harbor.favorites.v1.<profile>`). */
function favorites(profileId: string): Entry[] {
  try {
    const arr = JSON.parse(localStorage.getItem(`harbor.favorites.v1.${profileId}`) ?? "[]") as unknown[];
    const out: Entry[] = [];
    for (const el of Array.isArray(arr) ? arr : []) {
      if (typeof el === "string") out.push({ key: el, meta: { id: el, type: /^(kitsu|mal|anilist|anidb):|:tv:|:series:/.test(el) ? "series" : "movie", name: "" }, date: null });
      else if (el && typeof (el as { id?: unknown }).id === "string") {
        const e = el as { id: string; type?: string; name?: string; poster?: string; addedAt?: number };
        out.push({ key: e.id, meta: { id: e.id, type: e.type === "series" ? "series" : "movie", name: e.name ?? "", poster: e.poster }, date: e.addedAt || null });
      }
    }
    return out;
  } catch {
    return [];
  }
}

function simklIdIndex(cache: SimklCache): Map<number, string> {
  const out = new Map<number, string>();
  for (const [k, v] of Object.entries(cache.kitsuToSimkl)) out.set(v, `kitsu:${k}`);
  for (const [k, v] of Object.entries(cache.malToSimkl)) out.set(v, `mal:${k}`);
  for (const [k, v] of Object.entries(cache.tmdbToSimkl)) { const p = k.split(":"); if (p.length === 2) out.set(v, `tmdb:${p[0]}:${p[1]}`); }
  for (const [k, v] of Object.entries(cache.imdbToSimkl)) out.set(v, k);
  return out;
}

async function simklEntries(force: boolean): Promise<{ entries: Entry[]; status: Status }> {
  if (!simklConnected()) return { entries: [], status: "ready" };
  let cache = getLocalCache();
  let status: Status = "ready";
  if (!cache || force) {
    try { cache = await syncWatchlistCache(); } catch { if (!cache) return { entries: [], status: "error" }; status = "error"; }
  }
  if (!cache) return { entries: [], status };
  const index = simklIdIndex(cache);
  const entries: Entry[] = Object.values(cache.items).map((item) => ({
    key: `simkl:${item.simklId}`,
    meta: { id: index.get(item.simklId) ?? `simkl:${item.simklId}`, type: item.type === "movie" ? "movie" : "series", name: item.title, releaseInfo: item.year ? String(item.year) : undefined, poster: item.poster ? `https://simkl.in/posters/${item.poster}_m.jpg` : undefined },
    date: parseTs(item.watchedAt), group: item.status,
  }));
  return { entries, status };
}

// ------------------------------------------------------------- owned (Media Servers) sort
// bp-library.tsx OWNED_SORTS / numericMeta / sortOwned: the owned tabs (local, media-servers)
// sort by one key in a chosen direction into a single unlabelled section. Local files do not
// exist on tvOS, so Media Servers is the one owned tab here.
export type OwnedSortKey = "added" | "title" | "year" | "rating" | "runtime";
export type SortDir = "asc" | "desc";
const OWNED_SORT_KEYS: readonly OwnedSortKey[] = ["added", "title", "year", "rating", "runtime"];

function ownedSortKey(v: unknown): OwnedSortKey | null {
  return OWNED_SORT_KEYS.includes(v as OwnedSortKey) ? (v as OwnedSortKey) : null;
}

function sortDirKey(v: unknown): SortDir | null {
  return v === "asc" || v === "desc" ? v : null;
}

function numericMeta(entry: Entry, key: OwnedSortKey): number | null {
  const raw =
    key === "year"
      ? entry.meta.releaseInfo?.match(/\d{4}/)?.[0]
      : key === "rating"
        ? entry.meta.imdbRating
        : key === "runtime"
          ? entry.meta.runtime?.match(/\d+/)?.[0]
          : entry.date;
  if (raw == null) return null;
  const value = Number(raw);
  return Number.isFinite(value) ? value : null;
}

/** bp-library sortOwned: title by locale (base sensitivity), numbers by value, missing values last either way. */
export function sortOwned(entries: Entry[], key: OwnedSortKey, dir: SortDir): Entry[] {
  const mul = dir === "asc" ? 1 : -1;
  return [...entries].sort((a, b) => {
    if (key === "title")
      return mul * (a.meta.name ?? "").localeCompare(b.meta.name ?? "", undefined, { sensitivity: "base" });
    const av = numericMeta(a, key);
    const bv = numericMeta(b, key);
    if (av == null && bv == null) return 0;
    if (av == null) return 1;
    if (bv == null) return -1;
    return mul * (av - bv);
  });
}

export type FeedInput = {
  tab: Tab; profileId: string; linked: boolean; authKey: string | null;
  sort?: SortKey; flat?: boolean; type?: TypeKey; query?: string; group?: string; limit?: number; force?: boolean;
  /** History only (bp-library "Episodes / Posters"): false collapses a show's episodes into one card. */
  episodes?: boolean;
  /** Media Servers (bp-library ownedSort / sortDir): the owned tab's own sort and direction. */
  ownedSort?: OwnedSortKey | null; sortDir?: SortDir | null;
  /** Media Servers: bp-library's [tab] effect. Type, server, sort and direction come from the saved
   *  filter preferences (views/library/filter-preferences) instead of the input. */
  restore?: boolean;
};

/** One finished library page: filtered + sorted + grouped + capped, with chips data. */
export async function feed(input: FeedInput) {
  const s = loadEffective(input.profileId, input.linked);
  const hideAnime = s.hideContent?.anime === true;
  const sort: SortKey = input.sort ?? ((s.librarySort as SortKey) || "recent");
  let type: TypeKey = input.type ?? "all";
  let group: string | null = input.group || null;
  const limit = input.limit ?? 60;
  const tab = input.tab;
  let entries: Entry[] = [];
  let groups: Array<{ id: string; label: string }> = [];
  let status: Status = "ready";
  let hidden = 0;
  const signedIn = !!input.authKey || traktConnected();

  if (tab === "library" || tab === "watchlist" || tab === "history") {
    const st = await stremioItems(input.authKey, !!input.force);
    const tr = await traktItems(!!input.force);
    const keep = st.items.filter((i) => usable(i) && !(hideAnime && isAnimeCwItem(i)));
    if (tab === "history") {
      const own = mergeHistory(filterHistory(keep), []);
      const seen = new Set(own.map((e) => e.key));
      const extra = historyItemsToDated(tr.history).filter((e) => !seen.has(e.key));
      entries = [
        ...own.map((e) => ({ key: e.key, meta: e.meta, date: e.date, progress: e.progress, season: e.season, episode: e.episode, watched: e.watched })),
        ...extra.map((e) => ({ key: e.key, meta: e.meta, date: e.date })),
      ];
      if (input.episodes === false) {
        // history-tab "Posters": one card per title, the most recent episode's date and progress.
        const byTitle = new Map<string, (typeof entries)[number]>();
        for (const e of entries.slice().sort((a, b) => (b.date ?? 0) - (a.date ?? 0))) if (!byTitle.has(e.meta.id)) byTitle.set(e.meta.id, e);
        entries = Array.from(byTitle.values());
      }
    } else {
      const merged = mergeWatchlist(readLocalEntries(), filterLibrary(keep, s.libraryBookmarkedOnly !== false, tab), tr.watchlist);
      entries = merged.map((m) => ({ key: m.key, meta: m.meta, date: m.date }));
    }
    status = worst(st.status, tr.status);
  } else if (tab === "lists") {
    const lists = readLists();
    for (const list of lists) for (const item of list.items) {
      if (item.type === "manga") continue;
      entries.push({ key: `${list.id}:${item.id}`, meta: { id: item.id, type: item.type, name: item.name, poster: item.poster }, date: item.addedAt || null, group: list.id });
    }
    groups = lists.map((l) => ({ id: l.id, label: l.name }));
  } else if (tab === "favorites") {
    entries = favorites(input.profileId);
  } else if (tab === "trakt") {
    const tr = await traktItems(!!input.force);
    for (const item of tr.watchlist) {
      const meta = traktItemToMeta(item);
      if (meta) entries.push({ key: `w:${meta.id}`, meta, date: parseTs(item.contextDate), group: "watchlist" });
    }
    for (const e of historyItemsToDated(tr.history)) entries.push({ key: `h:${e.key}`, meta: e.meta, date: e.date, group: "history" });
    groups = [{ id: "watchlist", label: "Watchlist" }, { id: "history", label: "History" }];
    status = tr.status;
  } else if (tab === "media-servers") {
    const list = await homeServerTitles();
    entries = list.map((t) => ({ key: t.key, meta: t.meta, date: t.date, group: t.groups[0], groups: t.groups }));
    const seen = new Map<string, string>();
    for (const t of list) for (const c of t.connections) seen.set(c.id, c.label);
    groups = [...seen].map(([id, label]) => ({ id, label }));
  } else if (tab === "anilist" || tab === "mal") {
    const svc = await (tab === "anilist" ? anilistGlue : malGlue).entries(!!input.force);
    entries = svc.entries; status = svc.status; groups = svc.groups;
  } else if (tab === "simkl") {
    const sk = await simklEntries(!!input.force);
    entries = sk.entries; status = sk.status;
    groups = (Object.keys(SIMKL_STATUS_LABELS) as Array<keyof typeof SIMKL_STATUS_LABELS>).map((id) => ({ id, label: SIMKL_STATUS_LABELS[id] }));
  } else if (tab === "letterboxd") {
    // use-bp-library-services useLetterboxdFeed: the watchlist, undated.
    const lb = await letterboxdWatchlist(input.profileId, input.linked);
    entries = lb.metas.map((meta) => ({ key: meta.id, meta, date: null }));
    status = lb.status;
  }

  // bp-library.tsx [tab] effect + filter-preferences write: Media Servers keeps its type, server,
  // sort and direction per profile (harbor.library.filters.media-servers.<profile>); every other
  // tab starts unfiltered on the shared librarySort.
  let owned: { type: TypeKey; group: string; sort: OwnedSortKey; dir: SortDir } | null = null;
  if (tab === "media-servers") {
    const saved = input.restore ? readLibraryFilterPreferences("media-servers") : {};
    if (input.restore) {
      type = saved.type === "movie" || saved.type === "series" ? saved.type : "all";
      group = saved.server && saved.server !== "all" ? saved.server : null;
    }
    const sortKey: OwnedSortKey = (input.restore ? ownedSortKey(saved.sort) : ownedSortKey(input.ownedSort)) ?? "added";
    const dir: SortDir = (input.restore ? sortDirKey(saved.sortDir) : sortDirKey(input.sortDir)) ?? "desc";
    owned = { type, group: group ?? "", sort: sortKey, dir };
    // Genres and the Library row are not on the TV, so they are written as unset.
    writeLibraryFilterPreferences("media-servers", { type, genres: [], sort: sortKey, sortDir: dir, server: group || "all", library: "all" });
  }

  // bp-library.tsx:210: chip counts describe the group-scoped set, before type/query filters; a
  // media-server title belongs to every server that has it (e.groups).
  const pick = group;
  const scoped = pick ? entries.filter((e) => e.group === pick || (e.groups?.includes(pick) ?? false)) : entries;
  const total = scoped.length;
  const filtered = applyFilter(scoped, type, input.query ?? "");
  // buildBpSections (or sortOwned on the owned tab) + capBpSections
  let sections: Array<{ label: string; items: Entry[]; total: number }>;
  if (filtered.length === 0) sections = [];
  else if (owned) {
    const items = sortOwned(filtered, owned.sort, owned.dir);
    sections = [{ label: "", items, total: items.length }];
  }
  else if (sort === "recent" && (input.flat || filtered.every((e) => e.date == null))) {
    const items = [...filtered].sort((a, b) => (b.date ?? -Infinity) - (a.date ?? -Infinity));
    sections = [{ label: "", items, total: items.length }];
  } else sections = sortedGroups(filtered, sort).map((g) => ({ ...g, total: g.items.length }));
  let shown = 0;
  const capped: typeof sections = [];
  for (const sec of sections) {
    if (shown >= limit) break;
    const items = sec.items.slice(0, limit - shown);
    shown += items.length;
    capped.push({ label: sec.label, items, total: sec.total });
  }
  const counts = { all: scoped.length, movie: scoped.filter((e) => e.meta.type === "movie").length, series: scoped.filter((e) => e.meta.type === "series").length };
  // bp-library.tsx:220-221: the View row needs a dated entry and the Year sort a release year,
  // both over the filtered (visible) set.
  const dated = filtered.some((e) => e.date != null);
  const years = filtered.some((e) => !!e.meta.releaseInfo);
  return { tab, sections: capped, shown, matched: filtered.length, total, hasMore: shown < filtered.length, groups, status, hidden, signedIn, sort, counts, dated, years, owned };
}

// ----------------------------------------------------------------------------- repair
// settings/advanced-panel/library-repair-rows.tsx: "Repair library" (rewrite every item to
// Stremio's schema, progress as `harbor:library-repair`) and "Fix corrupted anime" (scan, then
// remove the anime saved under a movie/series id). Both act on the active profile's Stremio library.
let repairing = false;

export async function repair(authKey: string | null): Promise<RepairResult> {
  if (!authKey) throw new Error("Sign in to Stremio first. The repair scans only the active profile's library.");
  if (repairing) throw new Error("A repair is already running.");
  repairing = true;
  const emit = (p: RepairProgress) => {
    if (typeof window !== "undefined") window.dispatchEvent(new CustomEvent("harbor:library-repair", { detail: p }));
  };
  try {
    const result = await repairStremioLibrary(authKey, emit);
    stremioCache = null;
    return result;
  } finally {
    repairing = false;
  }
}

let corrupt: { authKey: string; items: LibraryItem[] } | null = null;

/** AnimeRepairRow scan: the corrupt entries (ids and names only; the items stay in the engine). */
export async function animeScan(authKey: string | null): Promise<Array<{ id: string; name: string }>> {
  if (!authKey) throw new Error("Sign in to Stremio first. This scans the active profile's library.");
  const items = await findCorruptAnimeEntries(authKey);
  corrupt = { authKey, items };
  return items.map((i) => ({ id: i._id, name: i.name || i._id }));
}

/** AnimeRepairRow remove: deletes what the last scan found; returns how many. */
export async function animeHeal(authKey: string | null): Promise<number> {
  if (!authKey || !corrupt || corrupt.authKey !== authKey || corrupt.items.length === 0) return 0;
  const n = await healCorruptAnimeEntries(authKey, corrupt.items);
  corrupt = null;
  clearResurfaceCache();
  stremioCache = null;
  return n;
}

/** Persist the sort choice like SortControl (settings.librarySort). */
export function setSort(sort: SortKey, profileId: string, linked: boolean): void {
  const s = loadEffective(profileId, linked);
  persistEffective({ ...s, librarySort: sort }, profileId, linked);
  // bp-library onPick → update({ librarySort }): a settings write that profile sync carries.
  markSettingsPatched(["librarySort"]);
}
