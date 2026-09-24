// Profile management helpers the TV needs beyond the roster: upstream's avatar catalog and
// the per-profile storage purge (lib/profiles.tsx purgeProfileStorage, not exported).
import { AVATAR_CATALOG, avatarUrl } from "@/lib/avatars/catalog";
import { PROFILE_COLORS } from "@/lib/profiles";

const PROFILE_KEY_PREFIXES = [
  "harbor.auth.", "harbor.theme-session.", "harbor.localcw.v1.", "harbor.favorites.v1.", "harbor.charfavorites.v1.",
  "harbor.mangafav.v1.", "harbor.mangaread.v1.", "harbor.manga.match.mal.v1.", "harbor.manga.match.anilist.v1.",
  "harbor.localwatchlist.v1.", "harbor.settings.", "harbor.trakt.session.v1.", "harbor.tvsettings.v1.",
  // The TV's AI search keys (Keychain) die with the profile too (review 34).
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
