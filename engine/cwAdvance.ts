// Continue Watching advance (views/home/hooks/use-cw-advance.ts useCwAdvance, without React):
// a finished episode's card moves on to the next unwatched, aired episode ("Up Next"), a
// caught-up show leaves the row (cwHideCaughtUp) or, with animeCwEnd "timer", stays with a
// countdown to the next air date, and recently finished library shows whose next episode has
// aired resurface (lib/cw-resurface). settings.cwAdvanceNext gates all of it.
//
// The effect body is ported line for line (upstream keeps it private inside the hook);
// shouldDropFinished is upstream's own export. Swift gets one finished list per call: the
// compute runs against a grace period, and a late answer raises the room's reload event
// (Home: `harbor:home-updated`, Anime: `harbor:anime-updated`) the way upstream's state update
// re-renders the row.
import { fetchEpisodeList, nextUnwatchedAfter } from "@/lib/series-episodes";
import type { Meta } from "@/lib/cinemeta";
import type { PlayEpisode } from "@/lib/view";
import { getEpisodeProgress } from "@/lib/episode-progress";
import { simklWatchedForId, statusForId, type WatchlistStatus } from "@/lib/simkl/list-status";
import { episodeFromVideoId, isAnimeCwItem, libraryMetaType, type LibraryItem } from "@/lib/stremio";
import { isEpisodeHidden } from "@/lib/hidden-episodes";
import { isNextAired, resurfaceCandidates, type AnimeMode } from "@/lib/cw-resurface";
import { lastPlayedEpisode } from "@/lib/resume";
import { getViewedSeason } from "@/lib/season-view-pref";
import { getAnimeCwId } from "@/lib/anime-cw-ids";
import { preferredMixedSeason, providerAliasCoords, resolveEffectiveEpisode } from "@/lib/cw-anime-episode";
import { isSplitFranchiseKitsu } from "@/lib/providers/anime-franchise-root";
import { parseKitsuId } from "@/lib/providers/kitsu";
import { franchiseDedupKey } from "@/lib/providers/jikan";
import { shouldDropFinished } from "@/views/home/hooks/use-cw-advance";

const FINISHED_RATIO = 0.9;
const ANIME_ID = /^(kitsu|mal|anilist|anidb):/;

export type CwAdvanceOpts = {
  tmdbKey: string;
  /** settings.cwAdvanceNext */
  enabled: boolean;
  /** The resurface pool (use-cw-advance `library`); defaults to the items. */
  library?: LibraryItem[];
  animeMode: AnimeMode;
  traktWatched: Set<string>;
  simklWatched: Map<string, Set<string>>;
  anilistWatched: Map<string, Set<string>>;
  simklStatus: Map<string, WatchlistStatus>;
  /** settings.episodeHiding */
  episodeHiding: boolean;
  /** settings.animeCwEnd */
  animeCwEnd: "hide" | "timer";
  /** settings.cwHideCaughtUp */
  hideCaughtUp: boolean;
};

export type CwAdvanceState = {
  advanced: Map<string, LibraryItem>;
  extra: LibraryItem[];
  removed: Set<string>;
  /** Earliest future air date among "timer" cards (ms), for the re-run timer. */
  soonestAir: number | null;
};

// use-cw-advance.ts:36-49
function isFinishedSeries(i: LibraryItem): boolean {
  if (i.type !== "series" || !i.state) return false;
  const dur = i.state.duration ?? 0;
  const off = i.state.timeOffset ?? 0;
  if ((i.state.flaggedWatched ?? 0) > 0) return dur <= 0 || off / dur >= FINISHED_RATIO;
  return dur > 0 && off / dur >= FINISHED_RATIO;
}

function currentEpisode(i: LibraryItem): { season: number; episode: number } | null {
  const season = i.state?.season;
  const episode = i.state?.episode;
  if (season && episode) return { season, episode };
  return episodeFromVideoId(i.state?.video_id ?? "");
}

function scopedSplitItem(id: string): boolean {
  return isSplitFranchiseKitsu(parseKitsuId(id) ?? parseKitsuId(getAnimeCwId(id) ?? ""));
}

// use-cw-advance.ts:77-92
function nextEpAired(list: PlayEpisode[], nextEp: PlayEpisode, isAnime: boolean): boolean {
  if (isNextAired(isAnime, nextEp.airDate)) return true;
  if (!isAnime || nextEp.airDate) return false;
  const now = Date.now();
  let boundary = -1;
  for (let k = 0; k < list.length; k++) {
    const raw = list[k].airDate;
    const t = raw ? Date.parse(raw) : NaN;
    if (Number.isFinite(t) && t <= now) boundary = k;
  }
  if (boundary < 0) return false;
  const idx = list.findIndex((e) => e.season === nextEp.season && e.episode === nextEp.episode);
  return idx >= 0 && idx <= boundary;
}

// use-cw-advance.ts:94-127
function watchedPredicate(
  i: LibraryItem,
  cur: { season: number; episode: number },
  traktWatched: Set<string>,
  simklWatched: Map<string, Set<string>>,
  anilistWatched: Map<string, Set<string>>,
  simklStatus: Map<string, WatchlistStatus>,
) {
  const finished = isFinishedSeries(i);
  const traktImdb = i._id.startsWith("tt") ? i._id : null;
  const simklSet = simklWatchedForId(simklWatched, i._id);
  const aniSet = anilistWatched.get(i._id);
  const simklCompleted = statusForId(simklStatus, i._id) === "completed";
  return (season: number, episode: number): boolean => {
    const prog = getEpisodeProgress(i._id, season, episode, null, traktImdb, traktWatched, undefined, aniSet, simklSet);
    if (prog.watched) return true;
    if (season === cur.season && episode === cur.episode) return finished;
    if (simklCompleted && (season < cur.season || (season === cur.season && episode < cur.episode))) return true;
    return false;
  };
}

/**
 * use-cw-advance.ts listCacheRef: episode lists per series. Upstream keeps them for the life of
 * the mounted row; the TV engine lives for the whole session, so an entry ages out after an
 * hour and a newly announced episode is picked up.
 */
const LIST_TTL_MS = 60 * 60 * 1000;
const listCache = new Map<string, { list: PlayEpisode[]; at: number }>();

/** The effect body of useCwAdvance (use-cw-advance.ts:176-354), one pass. */
export async function computeCwAdvance(items: LibraryItem[], o: CwAdvanceOpts): Promise<CwAdvanceState> {
  const next = new Map<string, LibraryItem>();
  const remove = new Set<string>();
  if (!o.enabled) return { advanced: next, extra: [], removed: remove, soonestAir: null };
  const candidates = items.filter((i) => currentEpisode(i) != null && isFinishedSeries(i));
  for (const i of candidates) {
    const cur = currentEpisode(i)!;
    const isAnime = isAnimeCwItem(i) || ANIME_ID.test(i._id);
    const hit = listCache.get(i._id);
    let list = hit && Date.now() - hit.at < LIST_TTL_MS ? hit.list : undefined;
    let fetchOk = list !== undefined;
    if (list === undefined) {
      const meta: Meta = { id: i._id, type: libraryMetaType(i.type), name: i.name, poster: i.poster, background: i.background };
      const res = await fetchEpisodeList(meta, { tmdbKey: o.tmdbKey })
        .then((eps) => ({ ok: true, eps }))
        .catch(() => ({ ok: false, eps: [] as PlayEpisode[] }));
      fetchOk = res.ok;
      if (res.ok) {
        list = res.eps;
        listCache.set(i._id, { list, at: Date.now() });
      }
    }
    if (!list) continue;
    // Bulletproof phantom guard (upstream comment): an entry can never show an episode past
    // the last one its own fully-fetched list contains; key = season*1e5+episode.
    const orderKey = (s: number, e: number) => s * 100000 + e;
    const origCur = cur;
    let effCur = cur;
    let remappedMixed = false;
    const scoped = scopedSplitItem(i._id);
    if (fetchOk && list.length > 0) {
      const maxKey = list.reduce((m, e) => Math.max(m, orderKey(e.season, e.episode)), 0);
      if (orderKey(effCur.season, effCur.episode) > maxKey && list.some((e) => e.season === effCur.season)) {
        const abs = list.find((e) => e.absoluteNumber === effCur.episode);
        if (!abs) {
          remove.add(i._id);
          continue;
        }
        effCur = { season: abs.season, episode: abs.episode };
      }
      if (!list.some((e) => e.season === effCur.season && e.episode === effCur.episode)) {
        if (scoped) {
          const hintSeason = preferredMixedSeason(getViewedSeason(i._id), lastPlayedEpisode(i._id)?.season);
          const resolved = resolveEffectiveEpisode(list, effCur.season, effCur.episode, hintSeason);
          effCur = { season: resolved.season, episode: resolved.episode };
          remappedMixed = resolved.remappedMixed;
        } else {
          const mapped = list.find((e) => e.imdbSeason === effCur.season && e.imdbEpisode === effCur.episode);
          if (mapped) effCur = { season: mapped.season, episode: mapped.episode };
        }
      }
    }
    const checkWatched = watchedPredicate(i, effCur, o.traktWatched, o.simklWatched, o.anilistWatched, o.simklStatus);
    const aliasCur = scoped ? providerAliasCoords(list, effCur.season, effCur.episode) : [];
    const watchedCur = checkWatched(effCur.season, effCur.episode) || aliasCur.some((a) => checkWatched(a.season, a.episode));
    if (!watchedCur) continue;
    const eps = list;
    const nextEp = nextUnwatchedAfter(
      eps,
      effCur,
      (s: number, e: number): boolean => {
        if (s === effCur.season && e === effCur.episode) return true;
        const prog = getEpisodeProgress(i._id, s, e, null, null, new Set());
        if (prog.watched) return true;
        if (!scoped) return false;
        return providerAliasCoords(eps, s, e).some((a) => getEpisodeProgress(i._id, a.season, a.episode, null, null, new Set()).watched);
      },
      o.episodeHiding ? (s, e) => isEpisodeHidden(i._id, s, e) : undefined,
    );
    if (nextEp && nextEpAired(list, nextEp, isAnime)) {
      const displaySeason = remappedMixed ? nextEp.season : origCur.season !== effCur.season ? origCur.season : nextEp.season;
      next.set(i._id, {
        ...i,
        state: { ...i.state!, season: displaySeason, episode: nextEp.episode, video_id: `${i._id}:${displaySeason}:${nextEp.episode}`, timeOffset: 0, flaggedWatched: 0 },
        upNext: true,
      });
    } else if (o.animeCwEnd === "timer" && nextEp && nextEp.airDate) {
      next.set(i._id, { ...i, waitingForAir: true as const, nextAirDate: nextEp.airDate } as LibraryItem);
    } else if (shouldDropFinished(list, fetchOk, i.state, o.animeMode, effCur, nextEp, o.hideCaughtUp)) {
      remove.add(i._id);
    }
  }
  const lib = o.library ?? items;
  const inCw = new Set(items.map((i) => i._id));
  const watchedFor = (item: LibraryItem, c: { season: number; episode: number }) =>
    watchedPredicate(item, c, o.traktWatched, o.simklWatched, o.anilistWatched, o.simklStatus);
  const resurfaced = await resurfaceCandidates(lib, inCw, { tmdbKey: o.tmdbKey, animeMode: o.animeMode }, watchedFor)
    .catch(() => new Map<string, { season: number; episode: number }>());
  const extra: LibraryItem[] = [];
  for (const [id, ep] of resurfaced) {
    if (next.has(id)) continue;
    const src = lib.find((i) => i._id === id);
    if (!src?.state) continue;
    extra.push({
      ...src,
      state: { ...src.state, season: ep.season, episode: ep.episode, video_id: `${id}:${ep.season}:${ep.episode}`, timeOffset: 0, flaggedWatched: 0 },
      upNext: true,
    });
  }
  let soonest: number | null = null;
  if (o.animeCwEnd === "timer") {
    for (const it of next.values()) {
      const air = (it as Record<string, unknown>).nextAirDate;
      if (typeof air !== "string") continue;
      const at = Date.parse(air);
      if (Number.isFinite(at) && at > Date.now() && (soonest === null || at < soonest)) soonest = at;
    }
  }
  return { advanced: next, extra, removed: remove, soonestAir: soonest };
}

/** The hook's return (use-cw-advance.ts:381-389): advanced cards, removals, deduped extras. */
export function applyCwAdvance(items: LibraryItem[], st: CwAdvanceState | null): LibraryItem[] {
  if (!st) return items;
  const base = st.advanced.size === 0 && st.removed.size === 0
    ? items
    : items.map((i) => st.advanced.get(i._id) ?? i).filter((i) => !st.removed.has(i._id));
  if (st.extra.length === 0) return base;
  const keyOf = (i: LibraryItem) => `${i.type}|${franchiseDedupKey(i.name ?? "")}`;
  const baseKeys = new Set(base.map(keyOf));
  const dedupExtra = st.extra.filter((i) => !baseKeys.has(keyOf(i)));
  return dedupExtra.length === 0 ? base : base.concat(dedupExtra);
}

// ---------------------------------------------------------------- one answer per call
/** Upstream shows the raw row at once and swaps in the advanced one; the TV waits this long. */
export const CW_ADVANCE_GRACE_MS = 1500;

type Slot = { sig: string; state: CwAdvanceState | null; mark: string; inflight: Promise<CwAdvanceState> | null; inflightSig: string; timer: ReturnType<typeof setTimeout> | null };
const slots = new Map<string, Slot>();

function itemsSig(items: LibraryItem[], o: CwAdvanceOpts): string {
  const it = items.map((i) => `${i._id}:${i.state?.season ?? ""}:${i.state?.episode ?? ""}:${i.state?.timeOffset ?? ""}:${i.state?.flaggedWatched ?? ""}`).join("|");
  const lib = (o.library ?? []).length;
  return [it, lib, o.tmdbKey ? 1 : 0, o.enabled, o.animeMode, o.episodeHiding, o.animeCwEnd, o.hideCaughtUp,
    o.traktWatched.size, o.simklWatched.size, o.anilistWatched.size, o.simklStatus.size].join("#");
}

function stateMark(items: LibraryItem[], st: CwAdvanceState | null): string {
  return applyCwAdvance(items, st).map((i) => {
    const r = i as Record<string, unknown>;
    return `${i._id}:${i.state?.season ?? ""}:${i.state?.episode ?? ""}:${r.upNext === true ? "u" : ""}${r.waitingForAir === true ? `w${String(r.nextAirDate)}` : ""}`;
  }).join("|");
}

/**
 * useCwAdvance for one room ("home", "anime", …): the advanced list, or, when the pass
 * outlives the grace, the last answer for the same row (else the raw row) while the pass
 * finishes and `notify` asks the host to re-read. animeCwEnd "timer" re-runs when the
 * soonest countdown ends (use-cw-advance.ts:334-346: +30 s, at least 30 s, at most 6 h).
 */
export async function advanceCw(room: string, items: LibraryItem[], o: CwAdvanceOpts, notify: () => void, graceMs = CW_ADVANCE_GRACE_MS): Promise<LibraryItem[]> {
  if (!o.enabled) return items;
  const sig = itemsSig(items, o);
  let slot = slots.get(room);
  if (!slot) {
    slot = { sig: "", state: null, mark: "", inflight: null, inflightSig: "", timer: null };
    slots.set(room, slot);
  }
  const mine = slot;
  if (!mine.inflight || mine.inflightSig !== sig) {
    const p = computeCwAdvance(items, o);
    mine.inflight = p;
    mine.inflightSig = sig;
    p.then((st) => {
      if (mine.inflight !== p) { pending.delete(p); return; }
      mine.inflight = null;
      const mark = stateMark(items, st);
      const changed = mine.sig === sig && mark !== mine.mark;
      const late = mine.sig !== sig || changed;
      mine.sig = sig;
      mine.state = st;
      mine.mark = mark;
      if (mine.timer) clearTimeout(mine.timer);
      mine.timer = null;
      if (st.soonestAir !== null) {
        const delay = Math.min(Math.max(st.soonestAir - Date.now() + 30000, 30000), 21600000);
        mine.timer = setTimeout(() => { mine.timer = null; mine.sig = ""; notify(); }, delay);
      }
      if (late && pending.has(p)) notify();
      pending.delete(p);
    }, () => {
      if (mine.inflight === p) mine.inflight = null;
      pending.delete(p);
    });
  }
  const p = mine.inflight!;
  const done = await Promise.race([p.then((st) => st, () => null), new Promise<"late">((r) => setTimeout(() => r("late"), graceMs))]);
  if (done !== "late") {
    if (done === null) return items;
    return applyCwAdvance(items, done);
  }
  // Late: the answer lands after this call returned, so it asks for a re-read if it differs.
  pending.add(p);
  if (mine.sig === sig && mine.state) {
    mine.mark = stateMark(items, mine.state);
    return applyCwAdvance(items, mine.state);
  }
  return items;
}
const pending = new Set<Promise<CwAdvanceState>>();

/** Test hook: forget cached episode lists and per-room answers. */
export function resetCwAdvance(): void {
  listCache.clear();
  for (const s of slots.values()) if (s.timer) clearTimeout(s.timer);
  slots.clear();
  pending.clear();
}
