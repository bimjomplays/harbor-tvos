// Profile management helpers the TV needs beyond the roster: upstream's avatar catalog and
// the per-profile storage purge (lib/profiles.tsx purgeProfileStorage, not exported).
import { AVATAR_CATALOG, avatarUrl } from "@/lib/avatars/catalog";
import { PROFILE_COLORS } from "@/lib/profiles";

// Mirrors lib/profiles.tsx PROFILE_KEY_PREFIXES (not exported upstream) plus the TV's own
// per-profile keys. (bug pass) This list and engine/sync.ts's roster purge each held a short copy
// (12 of upstream's 33): a deleted profile left its Simkl / AniList / MAL sessions in the Keychain
// and its watch history, watchlist and addon lists behind. One list now serves both.
export const PROFILE_KEY_PREFIXES: readonly string[] = [
  "harbor.auth.",
  "harbor.theme-session.",
  "harbor.localcw.v1.",
  "harbor.favorites.v1.",
  "harbor.charfavorites.v1.",
  "harbor.mangafav.v1.",
  "harbor.mangaread.v1.",
  "harbor.manga.match.mal.v1.",
  "harbor.manga.match.anilist.v1.",
  "harbor.localwatchlist.v1.",
  "harbor.settings.",
  "harbor.trakt.session.v1.",
  "harbor.simkl.session.v1.",
  "harbor.anilist.session.v1.",
  "harbor.mal.session.v1.",
  "harbor.simkl.cache.v2.",
  "harbor.anilist.synced.v1.",
  "harbor.mal.synced.v1.",
  "harbor.moviewatched.v1.",
  "harbor.watchedFlag.v1.",
  "harbor.manualwatched.v1.",
  "harbor.manualunwatched.v1.",
  "harbor.manualwatched.meta.v1.",
  "harbor.manualwatched.dismissed.v1.",
  "harbor.manualunwatched.at.v1.",
  "harbor.manualwatched.fromremote.v1.",
  "harbor.watchevents.v1.",
  "harbor.playback-history.v1.",
  "harbor.watchlist.v1.",
  "harbor.watchlist.aggregate.v1.",
  "harbor.installed-addons.",
  "harbor.addons.disabled.",
  "harbor.stremio.freshwatched.v1.",
  // TV-only: the Settings › TV blob and the AI search keys (Keychain; review 34).
  "harbor.tvsettings.v1.",
  "harbor.ai-search.keys.v1.",
];

export function avatars(): Array<{ group: string; transparent: boolean; items: Array<{ id: string; name: string; path: string }> }> {
  return AVATAR_CATALOG.map((g) => ({ group: g.group, transparent: !!g.transparent, items: g.items.map((i) => ({ id: i.id, name: i.name, path: avatarUrl(i.id) })) }));
}

export function colors(): string[] {
  return [...PROFILE_COLORS];
}

/** lib/profiles.tsx pickColor: first unused brand colour, else round-robin. */
export function pickColor(used: string[]): string {
  const taken = new Set(used);
  return PROFILE_COLORS.find((c) => !taken.has(c)) ?? PROFILE_COLORS[used.length % PROFILE_COLORS.length];
}

export function purge(localId: string): void {
  for (const prefix of PROFILE_KEY_PREFIXES) {
    try { localStorage.removeItem(`${prefix}${localId}`); } catch { /* ignore */ }
  }
}
