// Library room (use-bp-library.ts + use-bp-library-services.ts without React): tabs, one feed
// per tab (Saved / Watchlist / History / My Lists / Favorites / Trakt / Simkl), the same merge
// rules, then bp's sort → sections → cap. Local files and media servers do not exist on tvOS.
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
import { anilist as anilistGlue, mal as malGlue } from "./trackers";

export type Tab = "library" | "watchlist" | "history" | "lists" | "favorites" | "trakt" | "anilist" | "mal" | "simkl";
type Status = "loading" | "ready" | "error";

export type Entry = {
  key: string; meta: Meta; date: number | null; group?: string;
  progress?: number; season?: number; episode?: number; watched?: boolean;
};

const CORE: Array<{ id: Tab; label: string }> = [
  { id: "library", label: "Saved" }, { id: "watchlist", label: "Watchlist" }, { id: "history", label: "History" },
  { id: "lists", label: "My Lists" }, { id: "favorites", label: "Favorites" },
];

export function tabs(): Array<{ id: Tab; label: string }> {
  const out = [...CORE];
  if (traktConnected()) out.push({ id: "trakt", label: "Trakt" });
  if (anilistGlue.status().authenticated) out.push({ id: "anilist", label: "AniList" });
  if (malGlue.status().authenticated) out.push({ id: "mal", label: "MyAnimeList" });
  if (simklConnected()) out.push({ id: "simkl", label: "Simkl" });
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

export type FeedInput = {
  tab: Tab; profileId: string; linked: boolean; authKey: string | null;
  sort?: SortKey; flat?: boolean; type?: TypeKey; query?: string; group?: string; limit?: number; force?: boolean;
};

/** One finished library page: filtered + sorted + grouped + capped, with chips data. */
export async function feed(input: FeedInput) {
  const s = loadEffective(input.profileId, input.linked);
  const hideAnime = s.hideContent?.anime === true;
  const sort: SortKey = input.sort ?? ((s.librarySort as SortKey) || "recent");
  const type: TypeKey = input.type ?? "all";
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
  } else if (tab === "anilist" || tab === "mal") {
    const svc = await (tab === "anilist" ? anilistGlue : malGlue).entries(!!input.force);
    entries = svc.entries; status = svc.status; groups = svc.groups;
  } else if (tab === "simkl") {
    const sk = await simklEntries(!!input.force);
    entries = sk.entries; status = sk.status;
    groups = (Object.keys(SIMKL_STATUS_LABELS) as Array<keyof typeof SIMKL_STATUS_LABELS>).map((id) => ({ id, label: SIMKL_STATUS_LABELS[id] }));
  }

  // bp-library.tsx:210: chip counts describe the group-scoped set, before type/query filters.
  const scoped = input.group ? entries.filter((e) => e.group === input.group) : entries;
  const total = scoped.length;
  const filtered = applyFilter(scoped, type, input.query ?? "");
  // buildBpSections + capBpSections
  let sections: Array<{ label: string; items: Entry[]; total: number }>;
  if (filtered.length === 0) sections = [];
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
  return { tab, sections: capped, shown, matched: filtered.length, total, hasMore: shown < filtered.length, groups, status, hidden, signedIn, sort, counts };
}

/** Persist the sort choice like SortControl (settings.librarySort). */
export function setSort(sort: SortKey, profileId: string, linked: boolean): void {
  const s = loadEffective(profileId, linked);
  persistEffective({ ...s, librarySort: sort }, profileId, linked);
}
