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
let lastAnimeGroups: Array<{ key: string; name: string }> = [];
/** animeRoom records the groups it last built so the settings panel can list them without rebuilding. */
export function noteAnimeGroups(groups: Array<{ key: string; name: string }>): void { lastAnimeGroups = groups; }

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
  const shown = applyAnimeRowCustomization(lastAnimeGroups, c, true);
  return shown.map((g) => ({ key: g.key, name: g.name, originalName: lastAnimeGroups.find((x) => x.key === g.key)?.name ?? g.name, hidden: c.hidden.includes(g.key) }));
}

export function animeRowMove(profileId: string, linked: boolean, key: string, delta: -1 | 1): AnimeRowState[] {
  write(profileId, linked, animeMoveRow(custom(profileId, linked), lastAnimeGroups, key, delta));
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
