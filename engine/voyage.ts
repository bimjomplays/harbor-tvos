// Harbor Voyages glue (src/lib/voyage/* + src/components/voyage/*): a short, themed run of films
// the viewer builds one pick at a time ("Choose 1 of 3"), then sails through in order. Upstream's
// store runs as is (pool generation, heading ranking, TMDB related-title enrichment, streak,
// persistence under "harbor.voyage.v1"); this file only turns its state into the plain JSON the
// Swift room renders, because the store's reader (useVoyage) is a React hook.
//
// Not ported: voyage-launch.tsx (a lottie-web boat that the route thumbnails fly into before the
// first film starts) and voyage-prefetch.tsx (pre-warms the desktop stream picker's cache, which
// the TV does not have). The TV starts the first film straight away.
import type { Meta } from "@/lib/cinemeta";
import { loadEffective } from "@/lib/settings/profile-store";
import { VOYAGE_THEMES, THEME_PALETTE, themeById } from "@/lib/voyage/themes";
import {
  chooseHeading,
  endVoyage,
  launchVoyage,
  metaById,
  nextUnplayedId,
  rerollHeadings,
  startVoyage,
  undoPick,
  voyageReady,
} from "@/lib/voyage/store";
import { ensureRelated } from "@/lib/voyage/affinity";
import { isVoyageWatched, voyageProgress } from "@/lib/voyage/progress";
import type { StoredVoyage, Voyage, VoyageState } from "@/lib/voyage/types";
import { parseTmdbRef, shapeCredits, type PortCredits } from "@/components/voyage/port-hover-credits";
import { tmdbIdFromImdb } from "@/lib/providers/tmdb/tmdb-imdb-resolve";
import { tmdbTitleCredits, tmdbTitleCreditsCached } from "@/lib/providers/tmdb/tmdb-title-credits";

const KEY = "harbor.voyage.v1";

export type VoyageThemeTile = {
  id: string; label: string; tagline: string; type: "movie" | "series"; genre: string | null;
  accent: string; backdrop: string | null; from: string; to: string;
};
export type VoyageSlot = { index: number; meta: Meta | null; done: boolean; progress: number; current: boolean };
export type VoyageView = {
  id: string; themeId: string; themeLabel: string; tagline: string; accent: string;
  phase: "building" | "sailing"; targetLength: number; picked: number;
  /** voyage-route.tsx: ready (queue full), stuck (no headings left while building). */
  ready: boolean; stuck: boolean;
  /** route-rail.tsx: slots, how many are watched (the counter), connectors lit before `current`. */
  slots: VoyageSlot[]; watched: number; current: number;
  /** voyage-picker.tsx: the three headings on offer. */
  headings: Meta[];
  /** voyage-sailing.tsx: the next unwatched film and its 1-based place in the route. */
  next: Meta | null; nextPosition: number;
  /** voyage-banner.tsx pitch reads playedIds.length. */
  played: number;
  /** voyage-banner.tsx: the active pool's backdrops for the capsule strip. */
  bannerItems: Meta[];
};
export type VoyageSnapshot = { active: VoyageView | null; streak: number };

// store.ts load()/adopt(): the same reading of the persisted state the store starts from. Every
// store mutation persists synchronously (set → persist), so this is always the store's state.
function adopt(v: StoredVoyage): Voyage {
  if (v.phase) return { ...v, phase: v.phase, playedIds: v.playedIds ?? [] };
  if (v.routeIds.length === 0) return { ...v, phase: "building", playedIds: [] };
  return { ...v, phase: "sailing", playedIds: [...v.routeIds], targetLength: v.routeIds.length };
}
function readState(): VoyageState {
  try {
    const raw = localStorage.getItem(KEY);
    if (raw) {
      const s = JSON.parse(raw) as Omit<VoyageState, "active"> & { active: StoredVoyage | null };
      return { ...s, active: s.active ? adopt(s.active) : null };
    }
  } catch {
    /* ignore */
  }
  return { active: null, streak: 0, lastSail: null };
}

// voyage-banner.tsx items: backdrops that are not just the poster again, eight at most.
export function bannerItems(pool: Meta[]): Meta[] {
  return pool.filter((m) => m.background && m.background !== m.poster && m.name).slice(0, 8);
}

function view(v: Voyage): VoyageView {
  const sailing = v.phase === "sailing";
  // route-rail.tsx: watched ids and the progress of the rest.
  const played = new Set<string>();
  const progress = new Map<string, number>();
  for (const id of v.routeIds) {
    const meta = metaById(v, id);
    if (isVoyageWatched(id, meta)) played.add(id);
    else progress.set(id, voyageProgress(id, meta));
  }
  const current = sailing ? v.routeIds.findIndex((id) => !played.has(id)) : v.routeIds.length;
  const count = Math.max(v.targetLength, v.routeIds.length);
  const slots: VoyageSlot[] = Array.from({ length: count }, (_, i) => {
    const id = v.routeIds[i];
    const meta = id ? metaById(v, id) ?? null : null;
    const done = !!id && played.has(id);
    return { index: i, meta, done, progress: !id || done ? 0 : progress.get(id) ?? 0, current: i === current };
  });
  // voyage-route.tsx
  const ready = voyageReady(v);
  const nextId = sailing ? nextUnplayedId(v) : undefined;
  const next = nextId ? metaById(v, nextId) ?? null : null;
  return {
    id: v.id, themeId: v.themeId, themeLabel: v.themeLabel, tagline: v.tagline, accent: v.accent,
    phase: v.phase, targetLength: v.targetLength, picked: v.routeIds.length,
    ready, stuck: !sailing && !ready && v.headingIds.length === 0,
    slots, watched: played.size, current,
    headings: v.headingIds.map((id) => metaById(v, id)).filter((m): m is Meta => !!m),
    next, nextPosition: next ? v.routeIds.indexOf(next.id) + 1 : 0,
    played: v.playedIds.length,
    bannerItems: bannerItems(v.pool ?? []),
  };
}

function tmdbKey(profileId: string, linked: boolean): string {
  return loadEffective(profileId, linked).tmdbKey ?? "";
}

/** The state the Voyage room and the Discover banner render. */
export function state(): VoyageSnapshot {
  const s = readState();
  return { active: s.active ? view(s.active) : null, streak: s.streak };
}

/** themes.ts VOYAGE_THEMES with their THEME_PALETTE gradient (voyage-chooser.tsx ThemeTile). */
export function themes(): VoyageThemeTile[] {
  return VOYAGE_THEMES.map((t) => {
    const pal = THEME_PALETTE[t.id] ?? THEME_PALETTE.uncharted;
    return {
      id: t.id, label: t.label, tagline: t.tagline, type: t.type, genre: t.genre ?? null,
      accent: t.accent, backdrop: t.backdrop ?? null, from: pal.from, to: pal.to,
    };
  });
}

/** voyage-chooser.tsx start(): false when the pool came back too small to chart. */
export async function start(profileId: string, linked: boolean, themeId: string, length = 5): Promise<{ ok: boolean; state: VoyageSnapshot }> {
  const theme = themeById(themeId);
  const ok = theme ? await startVoyage(theme, length, tmdbKey(profileId, linked)) : false;
  return { ok, state: state() };
}

export function choose(profileId: string, linked: boolean, id: string): VoyageSnapshot {
  chooseHeading(id, tmdbKey(profileId, linked));
  return state();
}

/**
 * store.ts chooseHeading → refineAfterPick: when the pick's TMDB related titles were not in yet,
 * the store re-ranks the headings once they land. This waits for that load (the same in-flight
 * promise, so the store's refinement runs first) and returns the state after it.
 */
export async function settle(profileId: string, linked: boolean, id: string): Promise<VoyageSnapshot> {
  const v = readState().active;
  const meta = v ? metaById(v, id) : undefined;
  if (meta) {
    await ensureRelated(meta, tmdbKey(profileId, linked)).catch(() => []);
    await Promise.resolve();
  }
  return state();
}

export function undo(profileId: string, linked: boolean): VoyageSnapshot {
  undoPick(tmdbKey(profileId, linked));
  return state();
}

export function reroll(profileId: string, linked: boolean): VoyageSnapshot {
  rerollHeadings(tmdbKey(profileId, linked));
  return state();
}

/** voyage-route.tsx sail(): launch, and hand back the first film to play. */
export function launch(): { first: Meta | null; state: VoyageSnapshot } {
  const v = readState().active;
  const first = v ? metaById(v, v.routeIds[0]) ?? null : null;
  launchVoyage();
  return { first, state: state() };
}

export function end(): VoyageSnapshot {
  endVoyage();
  return state();
}

// port-hover-credits.ts usePortCredits without React: director and cast faces for a heading.
export type VoyageCredits = { cast: Array<{ id: number; name: string; profile: string | null }>; director: string | null };
const held = new Map<string, PortCredits | null>();
function shapeOut(c: PortCredits | null): VoyageCredits | null {
  if (!c) return null;
  return {
    cast: c.cast.map((p) => ({ id: p.id, name: p.name, profile: p.profilePath ? `https://image.tmdb.org/t/p/w185${p.profilePath}` : null })),
    director: c.director,
  };
}
export async function credits(profileId: string, linked: boolean, id: string, type: string): Promise<VoyageCredits | null> {
  const key = tmdbKey(profileId, linked);
  if (!id || !key || !id.startsWith("tt")) return null;
  const known = held.get(id);
  if (known !== undefined) return shapeOut(known);
  try {
    const ref = parseTmdbRef(await tmdbIdFromImdb(key, id, type === "series" ? "series" : "movie"));
    if (!ref) {
      held.set(id, null);
      return null;
    }
    const cached = tmdbTitleCreditsCached(ref.kind, ref.id);
    const raw = cached !== undefined ? cached : await tmdbTitleCredits(key, ref.kind, ref.id);
    const shaped = shapeCredits(raw);
    held.set(id, shaped);
    return shapeOut(shaped);
  } catch {
    return null;
  }
}
