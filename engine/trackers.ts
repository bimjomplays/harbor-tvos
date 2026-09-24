// AniList and MyAnimeList (lib/anilist/auth, lib/mal/auth): the TV builds the authorize URL
// (shown as text + QR), the viewer signs in on a phone and pastes the code back through the
// tvOS keyboard, then upstream exchanges it through Harbor's proxies. Rails for the anime room
// and the Library tabs follow use-anilist-anime-rails / use-mal-anime-rails.
import type { Meta } from "@/lib/cinemeta";
import * as anilistAuth from "@/lib/anilist/auth";
import * as anilistSession from "@/lib/anilist/session";
import { fetchMediaListCollection, readCachedCollection } from "@/lib/anilist/lists";
import { anilistEntryToMeta } from "@/lib/anilist/to-meta";
import type { AnilistListGroup, MediaListStatus } from "@/lib/anilist/types";
import * as malAuth from "@/lib/mal/auth";
import * as malSession from "@/lib/mal/session";
import { fetchMalList, readCachedMalList } from "@/lib/mal/lists";
import type { MalListEntry, MalListGroup, MalListStatus } from "@/lib/mal/types";
import { malAnimeToMeta } from "@/lib/mal/to-meta";

export type Rail = { key: string; title: string; metas: Meta[] };
export type RailsState = { rails: Rail[]; loading: boolean; error: boolean };

// ------------------------------------------------------------------------------ AniList
export const ANILIST_RAILS: Array<{ key: string; title: string; statuses: MediaListStatus[] }> = [
  { key: "watching", title: "Watching", statuses: ["CURRENT", "REPEATING"] },
  { key: "planning", title: "Plan to Watch", statuses: ["PLANNING"] },
  { key: "completed", title: "Completed", statuses: ["COMPLETED"] },
  { key: "paused", title: "On Hold", statuses: ["PAUSED"] },
  { key: "dropped", title: "Dropped", statuses: ["DROPPED"] },
];

function anilistRailsFrom(groups: AnilistListGroup[]): Rail[] {
  const byStatus = new Map(groups.map((g) => [g.status, g.entries]));
  const out: Rail[] = [];
  for (const rail of ANILIST_RAILS) {
    const metas = rail.statuses.flatMap((s) => byStatus.get(s) ?? []).map(anilistEntryToMeta).filter((m): m is Meta => m != null);
    if (metas.length >= 1) out.push({ key: rail.key, title: rail.title, metas });
  }
  return out;
}

let anilistLoad: Promise<AnilistListGroup[]> | null = null;
let anilistFailed = false;
/** When the last AniList load settled without data: no new try for a minute (review 27). */
let anilistTriedAt = 0;
const RETRY_MS = 60_000;

export const anilist = {
  authorizeUrl: (): string => anilistAuth.buildAuthorizeUrl(),
  async complete(pasted: string): Promise<{ userName: string; userId: number }> {
    const s = await anilistAuth.completeAuthorization(pasted);
    anilistLoad = null; anilistFailed = false;
    return { userName: s.userName, userId: s.userId };
  },
  status(): { authenticated: boolean; username: string | null } {
    const s = anilistSession.getSession();
    return { authenticated: anilistSession.isAuthenticated(), username: s?.userName ?? null };
  },
  disconnect(): void {
    anilistSession.setSession(null);
    anilistLoad = null;
  },
  /** Cached rails at once; a fetch fills them and raises `harbor:anime-updated`. */
  rails(force = false): RailsState {
    const s = anilistSession.getSession();
    if (!s || !anilistSession.isAuthenticated()) return { rails: [], loading: false, error: false };
    const cached = readCachedCollection(s.userId);
    if ((!cached || force) && !anilistLoad && (force || cached || Date.now() - anilistTriedAt >= RETRY_MS)) {
      anilistLoad = fetchMediaListCollection(s.userId);
      // fetchMediaListCollection resolves [] on failure without caching: "failed" is "still no
      // cache", or every Home read would fetch and re-read again (review 27).
      const uid = s.userId;
      anilistLoad.then(() => { anilistFailed = readCachedCollection(uid) == null; }).catch(() => { anilistFailed = true; })
        .finally(() => { if (anilistFailed) anilistTriedAt = Date.now(); }).finally(() => { anilistLoad = null; window.dispatchEvent(new CustomEvent("harbor:anime-updated")); });
    }
    return { rails: cached ? anilistRailsFrom(cached) : [], loading: !cached && !anilistFailed, error: anilistFailed && !cached };
  },
  /** Library tab entries: every list entry with its status group. */
  async entries(force = false): Promise<{ entries: Array<{ key: string; meta: Meta; date: number | null; group: string }>; status: "loading" | "ready" | "error"; groups: Array<{ id: string; label: string }> }> {
    const s = anilistSession.getSession();
    const groups = ANILIST_RAILS.map((g) => ({ id: g.key, label: g.title }));
    if (!s) return { entries: [], status: "ready", groups };
    let list = readCachedCollection(s.userId);
    let status: "ready" | "error" = "ready";
    if (!list || force) {
      try { list = await fetchMediaListCollection(s.userId); } catch { if (!list) return { entries: [], status: "error", groups }; status = "error"; }
    }
    const entries = list.flatMap((g) => g.entries.map((e) => {
      const meta = anilistEntryToMeta(e);
      return meta ? { key: `anilist:${e.id}`, meta, date: null, group: ANILIST_RAILS.find((r) => r.statuses.includes(e.status as MediaListStatus))?.key ?? "" } : null;
    })).filter((x): x is NonNullable<typeof x> => !!x);
    return { entries, status, groups };
  },
};

// ---------------------------------------------------------------------------------- MAL
export const MAL_RAILS: Array<{ key: string; title: string; statuses: MalListStatus[] }> = [
  { key: "watching", title: "Watching", statuses: ["watching"] },
  { key: "planning", title: "Plan to Watch", statuses: ["plan_to_watch"] },
  { key: "completed", title: "Completed", statuses: ["completed"] },
  { key: "onhold", title: "On Hold", statuses: ["on_hold"] },
  { key: "dropped", title: "Dropped", statuses: ["dropped"] },
];

function malEntryToMeta(entry: MalListEntry): Meta | null {
  const name = entry.anime.title;
  if (!name) return null;
  return { id: `mal:${entry.anime.id}`, type: "series", name, poster: entry.anime.mainPicture ?? undefined, imdbRating: entry.anime.mean != null ? entry.anime.mean.toFixed(1) : undefined };
}

function malRailsFrom(groups: MalListGroup[]): Rail[] {
  const byStatus = new Map(groups.map((g) => [g.status, g.entries]));
  const out: Rail[] = [];
  for (const rail of MAL_RAILS) {
    const metas = rail.statuses.flatMap((s) => byStatus.get(s) ?? []).map(malEntryToMeta).filter((m): m is Meta => m != null);
    if (metas.length >= 1) out.push({ key: rail.key, title: rail.title, metas });
  }
  return out;
}

let malLoad: Promise<MalListGroup[]> | null = null;
let malFailed = false;
let malTriedAt = 0;

export const mal = {
  authorizeUrl: (): string => malAuth.buildAuthorizeUrl(),
  async complete(pasted: string): Promise<{ userName: string }> {
    const s = await malAuth.completeAuthorization(pasted);
    malLoad = null; malFailed = false;
    return { userName: s.userName };
  },
  status(): { authenticated: boolean; username: string | null } {
    const s = malSession.getSession();
    return { authenticated: malSession.isAuthenticated(), username: s?.userName ?? null };
  },
  disconnect(): void {
    malSession.setSession(null);
    malLoad = null;
  },
  rails(force = false): RailsState {
    if (!malSession.isAuthenticated()) return { rails: [], loading: false, error: false };
    const cached = readCachedMalList();
    if ((!cached || force) && !malLoad && (force || cached || Date.now() - malTriedAt >= RETRY_MS)) {
      malLoad = fetchMalList();
      malLoad.then(() => { malFailed = readCachedMalList() == null; }).catch(() => { malFailed = true; })
        .finally(() => { if (malFailed) malTriedAt = Date.now(); }).finally(() => { malLoad = null; window.dispatchEvent(new CustomEvent("harbor:anime-updated")); });
    }
    return { rails: cached ? malRailsFrom(cached) : [], loading: !cached && !malFailed, error: malFailed && !cached };
  },
  async entries(force = false): Promise<{ entries: Array<{ key: string; meta: Meta; date: number | null; group: string }>; status: "loading" | "ready" | "error"; groups: Array<{ id: string; label: string }> }> {
    const groups = MAL_RAILS.map((g) => ({ id: g.key, label: g.title }));
    if (!malSession.isAuthenticated()) return { entries: [], status: "ready", groups };
    let list = readCachedMalList();
    let status: "ready" | "error" = "ready";
    if (!list || force) {
      try { list = await fetchMalList(); } catch { if (!list) return { entries: [], status: "error", groups }; status = "error"; }
    }
    const entries = list.flatMap((g) => g.entries.map((e) => {
      const meta = malAnimeToMeta(e.anime);
      const ts = e.updatedAt ? Date.parse(e.updatedAt) : NaN;
      return meta ? { key: `mal:${e.anime.id}`, meta, date: Number.isFinite(ts) ? ts : null, group: MAL_RAILS.find((r) => r.statuses.includes(e.status as MalListStatus))?.key ?? "" } : null;
    })).filter((x): x is NonNullable<typeof x> => !!x);
    return { entries, status, groups };
  },
};
