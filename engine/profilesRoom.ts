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

// ---------------------------------------------------------------- Who's watching at launch
// (profiles device pass) lib/profiles.tsx decides whether the chooser opens at launch
// (pickerOpen's initial state, which bp-who-is-watching-layer reads) and which profile a
// "Start as" default opens (launchDefault). Neither is exported, so they are mirrored here.
// The TV asked only when no profile was active, so a household of several profiles always
// woke up in whoever used it last. Swift stamps `harbor.profile.lastSelectAt` on every pick
// (markProfileSelectedNow).

const PROFILES_KEY = "harbor.profiles.v1";
const SETTINGS_KEY = "harbor.settings";
const SHARED_SETTINGS_KEY = "harbor.settings.shared";
const LAST_SELECT_KEY = "harbor.profile.lastSelectAt";

type PromptInterval = "launch" | "15m" | "30m" | "never";

function readJSON(key: string): Record<string, unknown> {
  try {
    const raw = localStorage.getItem(key);
    const parsed = raw ? JSON.parse(raw) : null;
    return parsed && typeof parsed === "object" && !Array.isArray(parsed) ? (parsed as Record<string, unknown>) : {};
  } catch {
    return {};
  }
}

/** lib/profiles.tsx readLaunchSettingsRaw: the shared blob first, else the active mirror. */
function readLaunchSettings(): Record<string, unknown> {
  try {
    if (localStorage.getItem(SHARED_SETTINGS_KEY) != null) return readJSON(SHARED_SETTINGS_KEY);
  } catch {
    return {};
  }
  return readJSON(SETTINGS_KEY);
}

/** lib/profiles.tsx readProfilePromptInterval. */
function promptInterval(s: Record<string, unknown>): PromptInterval {
  const v = s.profilePromptInterval;
  if (v === "launch" || v === "15m" || v === "30m" || v === "never") return v;
  return s.skipProfileScreen === true ? "never" : "launch";
}

function intervalMinutes(i: PromptInterval): number {
  return i === "15m" ? 15 : i === "30m" ? 30 : 0;
}

function lastSelectAt(): number {
  try {
    return Number(localStorage.getItem(LAST_SELECT_KEY)) || 0;
  } catch {
    return 0;
  }
}

type LaunchProfile = { id: string; passwordHash?: unknown };

function isLocked(p: LaunchProfile): boolean {
  return typeof p.passwordHash === "string" && p.passwordHash.length > 0;
}

/**
 * Once per process, at launch: `defaultId` is the "Start as" profile to open (never one with a
 * PIN; launchDefault), and `open` says whether Who's watching comes up (pickerOpen's initial
 * state: always with no active profile; never for a one-profile household or with a default;
 * else per profilePromptInterval, "launch" by default).
 */
export function launchPicker(): { open: boolean; defaultId: string | null } {
  const blob = readJSON(PROFILES_KEY);
  const list: unknown[] = Array.isArray(blob.profiles) ? blob.profiles : [];
  const profiles = list.filter(
    (p): p is LaunchProfile => !!p && typeof p === "object" && typeof (p as { id?: unknown }).id === "string",
  );
  const settings = readLaunchSettings();
  const wanted = typeof settings.defaultProfileId === "string" ? settings.defaultProfileId : "";
  const def = wanted ? profiles.find((p) => p.id === wanted && !isLocked(p)) : undefined;
  const activeId = def ? def.id : typeof blob.activeId === "string" ? blob.activeId : null;
  if (!activeId || !profiles.some((p) => p.id === activeId)) return { open: true, defaultId: null };
  if (def) return { open: false, defaultId: def.id };
  if (profiles.length <= 1) return { open: false, defaultId: null };
  const interval = promptInterval(settings);
  if (interval === "never") return { open: false, defaultId: null };
  if (interval === "launch") return { open: true, defaultId: null };
  return { open: Date.now() - lastSelectAt() >= intervalMinutes(interval) * 60000, defaultId: null };
}
