// Detail / quick-panel actions without React: custom lists (lib/custom-lists), ratings
// (lib/ratings, synced to harbor.site social), and the anime row customisation the anime
// settings expose (lib/anime-customization), each as plain calls the TV can make.
import type { Meta } from "@/lib/cinemeta";
import { readLists, createList, toggleInList, listContains, deleteList, renameList } from "@/lib/custom-lists";
import { rate as rateUpstream, unrate as unrateUpstream } from "@/lib/ratings/actions";
import { getRating } from "@/lib/ratings/store";
import { ratingTarget, type RatingMediaType } from "@/lib/ratings/types";
import { applyAnimeRowCustomization, animeMoveRow, animeToggleHidden, EMPTY_ANIME_ROWS, type AnimeRowCustomization } from "@/lib/anime-customization";
import { loadEffective, persistEffective } from "@/lib/settings/profile-store";
import { markSettingsPatched } from "./sync";

// ------------------------------------------------------------------------------- lists
export type ListSummary = { id: string; name: string; count: number; contains: boolean };

export function lists(itemId: string | null): ListSummary[] {
  return readLists().map((l) => ({ id: l.id, name: l.name, count: l.items.length, contains: itemId ? listContains(l.id, itemId) : false }));
}

/** bp-list-dialog: Select toggles membership; returns the new state. */
export function toggleList(listId: string, meta: Meta): boolean {
  return toggleInList(listId, { id: meta.id, type: meta.type, name: meta.name, poster: meta.poster });
}

export function newList(name: string): string | null {
  return createList(name.trim());
}

export function removeList(id: string): void { deleteList(id); }
export function renameListTo(id: string, name: string): void { renameList(id, name.trim()); }

// ----------------------------------------------------------------------------- ratings
const ANIME_ID = /^(kitsu|mal|anilist|anidb):/i;
function mediaTypeFor(meta: Meta): RatingMediaType {
  const t = meta.type;
  if (t === "manga") return "manga" as RatingMediaType;
  if (t === "movie") return "movie";
  if (t === "series" || t === "tv") return "series";
  if (ANIME_ID.test(meta.id) || t === "anime") return "anime";
  return meta.id.includes(":tv:") || meta.id.includes(":series:") ? "series" : "movie";
}

export function rating(itemKey: string): { score: number; updatedAt: number } | null {
  const r = getRating(itemKey);
  return r ? { score: r.score, updatedAt: r.updatedAt } : null;
}

/** bp-rate-dialog: 1–10, optimistic locally, synced to harbor.site when signed in. */
export async function rate(meta: Meta, score: number): Promise<{ score: number; synced: boolean }> {
  try {
    await rateUpstream(ratingTarget(meta, mediaTypeFor(meta)), score);
    return { score, synced: true };
  } catch {
    return { score, synced: false };
  }
}

export async function unrate(itemKey: string): Promise<void> {
  await unrateUpstream(itemKey).catch(() => undefined);
}

// -------------------------------------------------------------------------- anime rows
export type AnimeRowState = { key: string; name: string; originalName: string; hidden: boolean };
// Per profile: a kid profile's addons and hidden rows differ from the adult's.
const animeGroupsByProfile = new Map<string, Array<{ key: string; name: string }>>();
/** animeRoom records the groups it last built (per profile) so the settings panel can list them without rebuilding. */
export function noteAnimeGroups(groups: Array<{ key: string; name: string }>, profileId = "default"): void { animeGroupsByProfile.set(profileId, groups); }
const lastGroups = (profileId: string) => animeGroupsByProfile.get(profileId) ?? [];

function custom(profileId: string, linked: boolean): AnimeRowCustomization {
  return loadEffective(profileId, linked).animeRows ?? EMPTY_ANIME_ROWS;
}
function write(profileId: string, linked: boolean, next: AnimeRowCustomization): void {
  const s = loadEffective(profileId, linked);
  persistEffective({ ...s, animeRows: next }, profileId, linked);
  markSettingsPatched(["animeRows"]);
  if (typeof window !== "undefined") window.dispatchEvent(new CustomEvent("harbor:settings-updated", { detail: { profileId, fields: ["animeRows"] } }));
}

export function animeRows(profileId: string, linked: boolean): AnimeRowState[] {
  const c = custom(profileId, linked);
  const groups = lastGroups(profileId);
  const shown = applyAnimeRowCustomization(groups, c, true);
  return shown.map((g) => ({ key: g.key, name: g.name, originalName: groups.find((x) => x.key === g.key)?.name ?? g.name, hidden: c.hidden.includes(g.key) }));
}

export function animeRowMove(profileId: string, linked: boolean, key: string, delta: -1 | 1): AnimeRowState[] {
  write(profileId, linked, animeMoveRow(custom(profileId, linked), lastGroups(profileId), key, delta));
  return animeRows(profileId, linked);
}

export function animeRowToggleHidden(profileId: string, linked: boolean, key: string): AnimeRowState[] {
  write(profileId, linked, animeToggleHidden(custom(profileId, linked), key));
  return animeRows(profileId, linked);
}

export function animeRowRename(profileId: string, linked: boolean, key: string, name: string): AnimeRowState[] {
  const c = custom(profileId, linked);
  const renamed = { ...c.renamed };
  if (name.trim()) renamed[key] = name.trim(); else delete renamed[key];
  write(profileId, linked, { ...c, renamed });
  return animeRows(profileId, linked);
}

export function animeRowsReset(profileId: string, linked: boolean): AnimeRowState[] {
  write(profileId, linked, EMPTY_ANIME_ROWS);
  return animeRows(profileId, linked);
}

// ------------------------------------------------------------------------ hero actions
// use-bp-detail-actions.ts without React: the state behind each secondary action on the detail
// hero (Favourite, Remind me, Mark watched, Mark watched on Trakt) and the writes they make.
// Download is not ported: tvOS has no offline store Harbor can write a film into.
import { mediaFavoriteHas, setMediaFavorite } from "@/lib/media-favorites";
import { getReminder, removeReminder, setReminder } from "@/lib/reminders";
import { isMovieWatchedLocal } from "@/lib/movie-watched";
import { markMovieWatched, unmarkMovieWatched } from "@/lib/mark-watched";
import { pushWatched } from "@/lib/trakt/history";
import { stremioIdToTraktTarget } from "@/lib/trakt/ids";
import { getSession as traktSession } from "@/lib/trakt/session";

export type HeroState = {
  /** useIsFavorite(meta.id, [imdbId]) */
  favorite: boolean;
  /** useReminder(isSeries ? meta.id : undefined) */
  reminder: boolean;
  /** isMovieWatchedLocal(meta.id); the Stremio library half (stremioMovieWatched) is the caller's. */
  watchedLocal: boolean;
  /** trakt.isConnected && resolveTarget(meta.id).kind === "movie" (movies only). */
  traktMovie: boolean;
  /** settings.showWatchedButton */
  showWatchedButton: boolean;
  /** useRating(meta.id)?.score */
  rating: number | null;
};

const isMovieMeta = (meta: Meta) => meta.type === "movie";

function favoriteOn(profileId: string, metaId: string, imdbId: string | null): boolean {
  return mediaFavoriteHas(profileId, metaId) || (!!imdbId && mediaFavoriteHas(profileId, imdbId));
}

export function heroState(meta: Meta, imdbId: string | null, profileId: string, linked: boolean): HeroState {
  const settings = loadEffective(profileId, linked);
  const target = isMovieMeta(meta) && !!traktSession() ? stremioIdToTraktTarget(meta.id) : null;
  const r = getRating(meta.id);
  return {
    favorite: favoriteOn(profileId, meta.id, imdbId),
    reminder: !isMovieMeta(meta) && !!getReminder(meta.id),
    watchedLocal: isMovieMeta(meta) && isMovieWatchedLocal(meta.id),
    traktMovie: !!target && target.ok && target.target.kind === "movie",
    showWatchedButton: settings.showWatchedButton !== false,
    rating: r?.score ? r.score : null,
  };
}

/** "Add to favorites" / "Favorited": useMediaFavorites().toggle(seed). Returns the new state. */
export function toggleFavorite(meta: Meta, imdbId: string | null, profileId: string): boolean {
  const on = favoriteOn(profileId, meta.id, imdbId);
  const seed = { id: meta.id, type: meta.type, name: meta.name, poster: meta.poster };
  if (on) {
    setMediaFavorite(profileId, seed, false);
    if (imdbId && imdbId !== meta.id) setMediaFavorite(profileId, { ...seed, id: imdbId }, false);
  } else {
    setMediaFavorite(profileId, seed, true);
  }
  return !on;
}

/** "Remind me" / "Reminder on" (series only): the same entry use-bp-detail-actions writes. */
export function toggleReminder(meta: Meta): boolean {
  if (getReminder(meta.id)) {
    removeReminder(meta.id);
    return false;
  }
  const now = Date.now();
  setReminder({ id: meta.id, name: meta.name, poster: meta.poster, type: "series", episodes: true, seasons: true, tone: "chime", lastNotifiedAt: now, createdAt: now });
  return true;
}

/** "Mark watched" / "Marked watched" (movies, settings.showWatchedButton): lib/mark-watched. */
export async function setMovieWatched(meta: Meta, imdbId: string | null, watched: boolean): Promise<boolean> {
  const tmdb = meta.id.startsWith("tmdb:") ? meta.id.split(":")[2] : null;
  if (watched) await markMovieWatched(meta, imdbId, tmdb).catch(() => undefined);
  else await unmarkMovieWatched(meta, imdbId).catch(() => undefined);
  return watched;
}

/** "Mark watched on Trakt": pushWatched(resolveTarget(meta.id)). */
export async function traktMarkWatched(metaId: string): Promise<boolean> {
  const r = stremioIdToTraktTarget(metaId);
  if (!r.ok || r.target.kind !== "movie" || !traktSession()) return false;
  return pushWatched(r.target).catch(() => false);
}

// ---------------------------------------------------------------------------- trackers
// use-bp-trackers.ts: Simkl for everything, AniList and MyAnimeList for anime, each with its
// list status, the choices bp-status-dialog offers, and whether "Remove from list" applies.
import { deleteListEntry as anilistDelete, fetchListEntry as anilistFetch, saveListEntry as anilistSave } from "@/lib/anilist/mutations";
import { resolveAnilistMediaId } from "@/lib/anilist/sync";
import { getSession as anilistGetSession, isAuthenticated as anilistAuthed } from "@/lib/anilist/session";
import type { MediaListStatus } from "@/lib/anilist/types";
import { deleteListEntry as malDelete, fetchListEntry as malFetch, resolveMalMediaId, saveListEntry as malSave } from "@/lib/mal/mutations";
import { getSession as malGetSession, isAuthenticated as malAuthed } from "@/lib/mal/session";
import type { MalListStatus } from "@/lib/mal/types";
import { resolveSimklTarget } from "@/lib/simkl/ids";
import { clearSimklStatus, loadSimklStatusMap, MOVIE_STATUS_ORDER, setSimklStatus, SHOW_STATUS_ORDER, SIMKL_STATUS_LABELS, statusForId, type WatchlistStatus } from "@/lib/simkl/list-status";
import { getSession as simklGetSession } from "@/lib/simkl/session";

const ANILIST_LABELS: Record<MediaListStatus, string> = { CURRENT: "Watching", PLANNING: "Plan to Watch", COMPLETED: "Completed", REPEATING: "Rewatching", PAUSED: "On Hold", DROPPED: "Dropped" };
const ANILIST_ORDER: MediaListStatus[] = ["CURRENT", "PLANNING", "COMPLETED", "REPEATING", "PAUSED", "DROPPED"];
const MAL_LABELS: Record<MalListStatus, string> = { watching: "Watching", plan_to_watch: "Plan to Watch", completed: "Completed", on_hold: "On Hold", dropped: "Dropped" };
const MAL_ORDER: MalListStatus[] = ["watching", "plan_to_watch", "completed", "on_hold", "dropped"];

export type BpTracker = { key: "simkl" | "anilist" | "mal"; name: string; status: string | null; statusLabel: string | null; choices: Array<{ id: string; label: string }>; canRemove: boolean };

/** use-bp-trackers isBpAnime */
const isAnimeMeta = (meta: Meta) => meta.type === "anime" || ANIME_ID.test(meta.id);

async function simklTracker(harborId: string, isMovie: boolean): Promise<BpTracker | null> {
  if (!simklGetSession() || !harborId) return null;
  const tgt = await resolveSimklTarget(harborId, isMovie ? "movie" : "series").catch(() => null);
  if (!tgt) return null;
  const malKey = "ids" in tgt && tgt.ids.mal != null ? `mal:${tgt.ids.mal}` : null;
  const map = await loadSimklStatusMap().catch(() => null);
  const status = map ? (statusForId(map, harborId) ?? (malKey ? statusForId(map, malKey) : null)) : null;
  const order = tgt.kind === "movie" ? MOVIE_STATUS_ORDER : SHOW_STATUS_ORDER;
  return { key: "simkl", name: "Simkl", status, statusLabel: status ? SIMKL_STATUS_LABELS[status] : null, choices: order.map((s) => ({ id: s, label: SIMKL_STATUS_LABELS[s] })), canRemove: !!status };
}

async function anilistTracker(harborId: string): Promise<BpTracker | null> {
  if (!anilistGetSession() || !anilistAuthed() || !harborId) return null;
  const id = await resolveAnilistMediaId(harborId).catch(() => null);
  if (id == null) return null;
  const info = await anilistFetch(id).catch(() => null);
  const status: MediaListStatus | null = info?.entry?.status ?? null;
  return { key: "anilist", name: "AniList", status, statusLabel: status ? ANILIST_LABELS[status] : null, choices: ANILIST_ORDER.map((s) => ({ id: s, label: ANILIST_LABELS[s] })), canRemove: info?.entry?.id != null };
}

async function malTracker(harborId: string): Promise<BpTracker | null> {
  if (!malGetSession() || !malAuthed() || !harborId) return null;
  const id = await resolveMalMediaId(harborId).catch(() => null);
  if (id == null) return null;
  const info = await malFetch(id).catch(() => null);
  const status: MalListStatus | null = info?.entry?.status ?? null;
  return { key: "mal", name: "MyAnimeList", status, statusLabel: status ? MAL_LABELS[status] : null, choices: MAL_ORDER.map((s) => ({ id: s, label: MAL_LABELS[s] })), canRemove: !!status };
}

/** useBpTrackers({ meta: trackerMeta, isMovie }): for anime `meta.id` is the canonical kitsu id. */
export async function trackers(meta: Meta, isMovie: boolean): Promise<BpTracker[]> {
  const anime = isAnimeMeta(meta);
  const out = await Promise.all([
    simklTracker(meta.id, isMovie),
    anime ? anilistTracker(meta.id) : Promise.resolve(null),
    anime ? malTracker(meta.id) : Promise.resolve(null),
  ]);
  return out.filter((t): t is BpTracker => t !== null);
}

/** bp-status-dialog choice (BpTracker.set). Returns the tracker as it now stands. */
export async function trackerSet(key: string, meta: Meta, isMovie: boolean, status: string): Promise<BpTracker | null> {
  if (key === "simkl") {
    const tgt = await resolveSimklTarget(meta.id, isMovie ? "movie" : "series").catch(() => null);
    if (tgt) await setSimklStatus(tgt, status as WatchlistStatus).catch(() => null);
    return simklTracker(meta.id, isMovie);
  }
  if (key === "anilist") {
    const id = await resolveAnilistMediaId(meta.id).catch(() => null);
    if (id != null) await anilistSave({ mediaId: id, status: status as MediaListStatus }).catch(() => null);
    return anilistTracker(meta.id);
  }
  if (key === "mal") {
    const id = await resolveMalMediaId(meta.id).catch(() => null);
    if (id != null) await malSave({ malId: id, status: status as MalListStatus }).catch(() => null);
    return malTracker(meta.id);
  }
  return null;
}

/** bp-status-dialog "Remove from list" (BpTracker.remove). */
export async function trackerRemove(key: string, meta: Meta, isMovie: boolean): Promise<BpTracker | null> {
  if (key === "simkl") {
    const tgt = await resolveSimklTarget(meta.id, isMovie ? "movie" : "series").catch(() => null);
    if (tgt) await clearSimklStatus(tgt).catch(() => undefined);
    return simklTracker(meta.id, isMovie);
  }
  if (key === "anilist") {
    const id = await resolveAnilistMediaId(meta.id).catch(() => null);
    const info = id != null ? await anilistFetch(id).catch(() => null) : null;
    if (info?.entry?.id != null) await anilistDelete(info.entry.id).catch(() => false);
    return anilistTracker(meta.id);
  }
  if (key === "mal") {
    const id = await resolveMalMediaId(meta.id).catch(() => null);
    if (id != null) await malDelete(id).catch(() => false);
    return malTracker(meta.id);
  }
  return null;
}
