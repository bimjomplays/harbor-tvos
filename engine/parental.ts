// Per-profile gating for the adult shell, without React:
//  - lib/parental.tsx ParentalProvider: `hiddenTabs` (the profile's lockedTabs over DEFAULT_HIDDEN)
//    and `locked` (a PIN is set, a tab is locked, and this session has not unlocked the profile).
//  - bp-top-bar.tsx useBpTabGate / visibleTabs: which Big Picture tabs that hides, plus the
//    Anime tab when the profile hides anime (hiddenByAnime).
//  - lib/profile-identity-sync.tsx: the active profile's `hideContent` is copied into the
//    effective settings, so every row / search / detail filter that reads
//    `settings.hideContent` follows the profile.
// The session unlock itself (profiles.tsx sessionUnlockedIds + parental.tsx sessionUnlockedFor)
// is device-local UI state and lives in Swift (ProfilesStore); it arrives here as a flag.
import { anyTabLocked, DEFAULT_HIDDEN, LOCKABLE_TABS, type HiddenTabs, type LockableTab } from "@/lib/lockable-tabs";
import { isProfileLocked } from "@/lib/profile-sync/profile-lock";
import { loadEffective, persistEffective } from "@/lib/settings/profile-store";
import type { ContentCategory, ContentFilters } from "@/lib/settings/types";
import { markSettingsPatched } from "./sync";

const PROFILES_KEY = "harbor.profiles.v1";

type StoredProfile = {
  id?: unknown;
  passwordHash?: unknown;
  lockedTabs?: unknown;
  hideContent?: unknown;
  settingsLinked?: unknown;
};

function readBlob(): { activeId: string | null; profiles: StoredProfile[] } {
  try {
    const raw = localStorage.getItem(PROFILES_KEY);
    const parsed = raw ? (JSON.parse(raw) as { activeId?: unknown; profiles?: unknown }) : null;
    return {
      activeId: typeof parsed?.activeId === "string" ? parsed.activeId : null,
      profiles: Array.isArray(parsed?.profiles) ? (parsed.profiles as StoredProfile[]) : [],
    };
  } catch {
    return { activeId: null, profiles: [] };
  }
}

function findProfile(profileId: string): StoredProfile | null {
  return readBlob().profiles.find((p) => p && p.id === profileId) ?? null;
}

/** The wire carries lockedTabs as `unknown` (profile-sync/types.ts); read only the lockable keys. */
function readLockedTabs(raw: unknown): HiddenTabs | null {
  if (!raw || typeof raw !== "object") return null;
  const src = raw as Record<string, unknown>;
  const out: HiddenTabs = { ...DEFAULT_HIDDEN };
  for (const { key } of LOCKABLE_TABS) out[key] = src[key] === true;
  return out;
}

/** parental.tsx: `{ ...DEFAULT_HIDDEN, ...(activeProfile?.lockedTabs ?? {}) }`. */
export function hiddenTabsFor(profileId: string): HiddenTabs {
  return readLockedTabs(findProfile(profileId)?.lockedTabs) ?? { ...DEFAULT_HIDDEN };
}

// bp-top-bar.tsx TABS: the tabs carrying a parentalKey, and the one hiddenByAnime. Discover,
// Live TV, Search, Collections and Settings carry none there, so a lock never hides them on a
// TV. Calendar is not a Big Picture tab upstream; this port has one, and it takes the key the
// desktop sidebar gives it (chrome/nav-items.tsx `parentalKey: "calendar"`).
const BP_TAB_GATES: Array<{ room: string; parentalKey?: LockableTab; hiddenByAnime?: boolean }> = [
  { room: "anime", parentalKey: "anime", hiddenByAnime: true },
  // The TV's Manga tab (Stage 13) takes the key the desktop sidebar gives it (chrome/nav-items.tsx
  // manga `parentalKey: "anime"`). Hiding it is sidebar editing now (engine/navEdit.ts).
  { room: "manga", parentalKey: "anime" },
  // The TV's eBook tab (Stage 13) likewise takes nav-items.tsx ebook `parentalKey: "anime"`.
  { room: "ebook", parentalKey: "anime" },
  { room: "shows", parentalKey: "shows" },
  { room: "movies", parentalKey: "movies" },
  { room: "sports", parentalKey: "sports" },
  { room: "library", parentalKey: "library" },
  { room: "calendar", parentalKey: "calendar" },
];

export type TabGate = {
  /** A PIN is set on the profile (the gate is inert without one). */
  hasPin: boolean;
  /** Any tab is marked locked, PIN or not (profile editor's "N tabs locked"). */
  anyLocked: boolean;
  /** parental.tsx `locked`: PIN set, a tab locked, and not unlocked this session. */
  locked: boolean;
  hiddenTabs: HiddenTabs;
  /** settings.hideContent.anime for the profile's effective settings. */
  animeHidden: boolean;
  /** Room ids (Swift `Room.rawValue`) the top bar, tab cycling and entry points must skip. */
  hiddenRooms: string[];
};

/** useBpTabGate + visibleTabs for one profile. */
export function gate(profileId: string, linked: boolean, sessionUnlocked: boolean): TabGate {
  const profile = findProfile(profileId);
  const locks = readLockedTabs(profile?.lockedTabs);
  const hiddenTabs = locks ?? { ...DEFAULT_HIDDEN };
  const hasPin = isProfileLocked(profile ? { id: String(profile.id), passwordHash: typeof profile.passwordHash === "string" ? profile.passwordHash : null } : null);
  const anyLocked = anyTabLocked(locks);
  const locked = hasPin && anyLocked && !sessionUnlocked;
  const settings = loadEffective(profileId, linked);
  const animeHidden = Boolean(settings.hideContent?.anime);
  const hiddenRooms = BP_TAB_GATES.filter((tab) => {
    if (tab.hiddenByAnime && animeHidden) return true;
    return locked && !!tab.parentalKey && hiddenTabs[tab.parentalKey];
  }).map((tab) => tab.room);
  return { hasPin, anyLocked, locked, hiddenTabs, animeHidden, hiddenRooms };
}

/** lockable-tabs.ts LOCKABLE_TABS: the editor's "Lock sidebar tabs" list, in upstream order. */
export function lockable(): Array<{ key: LockableTab; label: string }> {
  return LOCKABLE_TABS.map(({ key, label }) => ({ key, label }));
}

/**
 * editor-view.tsx TabsView onSave: `lockedTabs: anyTabLocked(next) ? next : null`, with next
 * `{ ...DEFAULT_HIDDEN, ...initial }` toggled. Returns the exact value to store on the profile.
 */
export function lockedTabsValue(draft: Record<string, unknown> | null): HiddenTabs | null {
  const next = readLockedTabs(draft);
  return anyTabLocked(next) ? next : null;
}

// ----------------------------------------------------------- profile-identity-sync.tsx
// settings/types.ts ContentCategory. The manga and liveTv switches retired into sidebar editing
// (settings/load.ts `_navHideMigrateV1` → navCustomization.hidden, engine/navEdit.ts), so a
// profile blob that still carries them no longer writes them into the settings.
const CATEGORIES: ContentCategory[] = ["anime", "sports", "adult"];

/** profile-identity-sync.tsx sameHideContent. */
function sameHideContent(a: Partial<ContentFilters>, b: Partial<ContentFilters>): boolean {
  return Boolean(a.anime) === Boolean(b.anime) && Boolean(a.sports) === Boolean(b.sports) && Boolean(a.adult) === Boolean(b.adult);
}

/**
 * ProfileIdentitySync's hideContent effect: when the active profile carries `hideContent` and it
 * differs from the effective settings, write it there (and to the `harbor.settings` mirror the
 * adult filter reads). Returns true when it wrote.
 */
export function syncIdentity(): boolean {
  const { activeId, profiles } = readBlob();
  if (!activeId) return false;
  const profile = profiles.find((p) => p && p.id === activeId);
  const raw = profile?.hideContent;
  if (!raw || typeof raw !== "object") return false;
  const wanted: Partial<ContentFilters> = {};
  for (const key of CATEGORIES) {
    const v = (raw as Record<string, unknown>)[key];
    if (typeof v === "boolean") wanted[key] = v;
  }
  const linked = profile?.settingsLinked !== false;
  const settings = loadEffective(activeId, linked);
  if (sameHideContent(settings.hideContent ?? {}, wanted)) return false;
  persistEffective({ ...settings, hideContent: { ...settings.hideContent, ...wanted } }, activeId, linked);
  markSettingsPatched(["hideContent"]);
  window.dispatchEvent(new CustomEvent("harbor:settings-updated", { detail: { profileId: activeId, fields: ["hideContent"] } }));
  return true;
}

// The provider runs its effect on [activeProfile.id, activeProfile.hideContent]. Here that is
// every event that can change either: Swift switching or editing profiles, and a roster pull.
// Swift's `emitEvent` and `syncStorage` share the engine's serial queue, so the listener sees
// the blob Swift just wrote, and it runs before any room build Swift queues after it.
if (typeof window !== "undefined") {
  for (const type of ["harbor:active-profile-changed", "harbor:profiles-updated", "harbor:roster-applied"]) {
    window.addEventListener(type, () => {
      try { syncIdentity(); } catch { /* a bad blob must not break the event */ }
    });
  }
}
