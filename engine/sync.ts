// Profile sync, both directions, on upstream's own engine (lib/profile-sync + lib/layout-sync
// + the TV settings sections). This file only wires the two stores upstream leaves to React
// providers (the roster and the active profile's settings) onto localStorage and tells the
// host when the bundle changed something underneath it.
//
// Ownership: `harbor.profiles.v1` is written by Swift (ProfilesStore) and by the roster apply
// path here. Swift reloads the blob on `harbor:roster-applied`; this side marks the roster
// dirty on `harbor:profiles-updated`. Neither event is re-emitted by its receiver, so there is
// no loop.
import "@/lib/layout-sync/register";
import { registerTvSyncSections } from "@/views/settings/tv-panel/store";
import { configureRosterStore } from "@/lib/profile-sync/roster-store";
import { noteProfileDeleted } from "@/lib/profile-sync/roster-section";
import {
  flushSyncNow,
  markSectionCleared,
  markSectionDirty,
  requestSyncPull,
  restoreParkedSection,
  startProfileSync,
  stopProfileSync,
} from "@/lib/profile-sync/scheduler";
import { runPull } from "@/lib/profile-sync/engine";
import { getSyncStatus, subscribeSyncStatus } from "@/lib/profile-sync/status";
import { isSectionKey } from "@/lib/profile-sync/sections";
import { readParked } from "@/lib/profile-sync/parked";
import { syncIdFor } from "@/lib/profile-sync/id-map";
import type { LocalProfileLike, RosterApply, SyncStatus } from "@/lib/profile-sync/types";
import { configureLayoutStore } from "@/lib/layout-sync/store";
import { SYNCED_SETTINGS_FIELDS } from "@/lib/layout-sync/sections";
import { loadEffective, persistEffective } from "@/lib/settings/profile-store";
import type { Settings } from "@/lib/settings/types";
// (bug pass) The one purge list (profilesRoom.ts), not a second, shorter copy.
import { PROFILE_KEY_PREFIXES } from "./profilesRoom";

const PROFILES_KEY = "harbor.profiles.v1";

type Blob = { activeId?: string | null; profiles?: Array<Record<string, unknown>> };

function readBlob(): Blob {
  try {
    const raw = localStorage.getItem(PROFILES_KEY);
    const parsed = raw ? (JSON.parse(raw) as Blob) : null;
    return parsed && typeof parsed === "object" ? parsed : {};
  } catch {
    return {};
  }
}

function writeBlob(blob: Blob): void {
  localStorage.setItem(PROFILES_KEY, JSON.stringify(blob));
}

function readKid(raw: unknown): LocalProfileLike["kid"] {
  if (!raw || typeof raw !== "object") return null;
  const k = raw as Record<string, unknown>;
  return {
    age: typeof k.age === "number" ? k.age : 7,
    curfewMinutes: typeof k.curfewMinutes === "number" ? k.curfewMinutes : null,
    parentPinHash: typeof k.parentPinHash === "string" ? k.parentPinHash : null,
  };
}

/** Same reading as roster-store's fallback, plus the device-local passwordHash the wire never carries. */
function readLocal(): LocalProfileLike[] {
  const out: LocalProfileLike[] = [];
  for (const p of readBlob().profiles ?? []) {
    if (typeof p?.id !== "string" || typeof p?.name !== "string") continue;
    out.push({
      id: p.id,
      name: p.name,
      avatar: typeof p.avatar === "string" ? p.avatar : null,
      color: typeof p.color === "string" ? p.color : "",
      isPrimary: p.isPrimary === true,
      kid: readKid(p.kid),
      hideContent: p.hideContent ?? null,
      lockedTabs: p.lockedTabs ?? null,
      settingsLinked: p.settingsLinked !== false,
      createdAt: typeof p.createdAt === "number" ? p.createdAt : 0,
      bootstrap: typeof p.bootstrap === "boolean" ? p.bootstrap : undefined,
      passwordHash: typeof p.passwordHash === "string" ? p.passwordHash : null,
    });
  }
  return out;
}

const COLORS = ["#7dd3fc", "#60a5fa", "#a78bfa", "#f472b6", "#fb7185", "#fb923c", "#fbbf24", "#a3e635", "#34d399", "#22d3ee"];

/** lib/profiles.tsx adoptProfile: the wire carries no secrets, so those come off the profile being replaced. */
function adopt(next: LocalProfileLike, prev: Record<string, unknown> | undefined, fallbackColor: string): Record<string, unknown> {
  const prevKid = (prev?.kid ?? null) as { parentPinHash?: string | null } | null;
  return {
    ...(prev ?? {}),
    id: next.id,
    name: next.name,
    avatar: next.avatar,
    color: next.color || (prev?.color as string | undefined) || fallbackColor,
    isPrimary: next.isPrimary,
    shareStremioWith: (prev?.shareStremioWith as string | null | undefined) ?? null,
    passwordHash: next.passwordHash ?? (prev?.passwordHash as string | null | undefined) ?? null,
    hideContent: next.hideContent ?? null,
    lockedTabs: next.lockedTabs ?? null,
    kid: next.kid
      ? { age: next.kid.age, curfewMinutes: next.kid.curfewMinutes, parentPinHash: next.kid.parentPinHash ?? prevKid?.parentPinHash ?? null }
      : null,
    settingsLinked: next.settingsLinked !== false,
    createdAt: next.createdAt || (prev?.createdAt as number | undefined) || Date.now(),
    bootstrap: next.bootstrap ?? (prev?.bootstrap as boolean | undefined),
  };
}

function applyRosterPlan(plan: RosterApply): void {
  // A sign-in made while the bootstrap profile was active stored the account session under
  // that profile's key. Dropping the profile purges the key, so park the session on the
  // legacy global key first; theme-auth migrates it onto the new primary on its next reload.
  for (const id of plan.dropLocalIds) {
    const held = localStorage.getItem(`harbor.theme-session.${id}`);
    if (held && !localStorage.getItem("harbor.theme-session")) localStorage.setItem("harbor.theme-session", held);
  }
  for (const id of plan.dropLocalIds) {
    for (const prefix of PROFILE_KEY_PREFIXES) {
      try { localStorage.removeItem(`${prefix}${id}`); } catch { /* ignore */ }
    }
  }
  const blob = readBlob();
  const existing = blob.profiles ?? [];
  const byId = new Map(existing.map((p) => [String(p.id), p]));
  const used = new Set(existing.map((p) => p.color));
  const free = COLORS.find((c) => !used.has(c)) ?? COLORS[existing.length % COLORS.length];
  const profiles = plan.replaceWith.map((next) => adopt(next, byId.get(next.id), free));
  const stillHere = profiles.some((p) => p.id === blob.activeId);
  const activeId = stillHere ? blob.activeId : null;
  writeBlob({ ...blob, profiles, activeId });
  window.dispatchEvent(new CustomEvent("harbor:roster-applied", { detail: { dropped: plan.dropLocalIds, activeId } }));
  // profiles.tsx dispatches this on every active-id change; theme-auth, local-cw, watchlist,
  // watched flags and the addon store all re-key their caches off it.
  if (activeId !== (blob.activeId ?? null)) {
    window.dispatchEvent(new CustomEvent("harbor:active-profile-changed", { detail: { id: activeId } }));
  }
}

function activeId(): string {
  return readBlob().activeId || "default";
}

function isLinked(profileId: string): boolean {
  const p = (readBlob().profiles ?? []).find((x) => x.id === profileId);
  return p ? p.settingsLinked !== false : true;
}

function readActive(): Settings {
  return loadEffective(activeId(), isLinked(activeId()));
}

function writeActive(patch: Partial<Settings>): void {
  const id = activeId();
  const linked = isLinked(id);
  persistEffective({ ...loadEffective(id, linked), ...patch }, id, linked);
  window.dispatchEvent(new CustomEvent("harbor:settings-updated", { detail: { profileId: id, fields: Object.keys(patch) } }));
}

let wired = false;
let stopStatus: (() => void) | null = null;
let onProfilesUpdated: (() => void) | null = null;

function wire(): void {
  if (wired) return;
  wired = true;
  configureRosterStore({ read: readLocal, apply: applyRosterPlan });
  configureLayoutStore({ activeProfileId: activeId, isLinked, readActive, writeActive });
  registerTvSyncSections();
}

/** Start upstream's scheduler: pull now, then every 15 min; pushes debounce 2.5 s after a mark. */
export function start(): SyncStatus {
  wire();
  startProfileSync();
  if (!stopStatus) {
    stopStatus = subscribeSyncStatus(() => {
      window.dispatchEvent(new CustomEvent("harbor:sync-status", { detail: getSyncStatus() }));
    });
  }
  if (!onProfilesUpdated) {
    onProfilesUpdated = () => markSectionDirty("profiles");
    window.addEventListener("harbor:profiles-updated", onProfilesUpdated);
  }
  return getSyncStatus();
}

export function stop(): void {
  stopProfileSync();
  stopStatus?.();
  stopStatus = null;
  if (onProfilesUpdated) window.removeEventListener("harbor:profiles-updated", onProfilesUpdated);
  onProfilesUpdated = null;
}

export function status(): SyncStatus {
  return getSyncStatus();
}

/** One awaited pull (boot, "Pull now"); the scheduler keeps its own cadence. */
export async function pullNow(): Promise<{ ok: boolean; firstPull?: boolean; reason?: string | null; status: SyncStatus }> {
  wire();
  const r = await runPull();
  if (r.ok) flushSyncNow();
  return { ok: r.ok, firstPull: r.ok ? r.firstPull : undefined, reason: r.ok ? null : r.reason, status: getSyncStatus() };
}

export function pushNow(): void {
  flushSyncNow();
}

export function requestPull(): void {
  requestSyncPull();
}

/** Queue a section after a native-side edit (e.g. the roster after a rename). */
export function markDirty(section: string, profileId?: string): boolean {
  if (!isSectionKey(section)) return false;
  markSectionDirty(section, profileId);
  return true;
}

export function markCleared(section: string, profileId?: string): boolean {
  if (!isSectionKey(section)) return false;
  markSectionCleared(section, profileId);
  return true;
}

/** Call BEFORE removing a profile locally, so the delete reaches the other devices. */
export function profileDeleted(localId: string): void {
  noteProfileDeleted(localId);
}

/** Settings fields that ride profile sync; `settings.patch` marks their sections dirty. */
export function syncedSettingsFields(): string[] {
  return SYNCED_SETTINGS_FIELDS.map(([, field]) => String(field));
}

/** Called by `settings.patch` with the keys it wrote (lib/settings.tsx does the same per field). */
export function markSettingsPatched(fields: string[]): void {
  for (const [section, field] of SYNCED_SETTINGS_FIELDS) {
    if (fields.includes(String(field))) markSectionDirty(section);
  }
}

export function parked(section: string, profileId?: string): { value: unknown; rev: number } | null {
  if (!isSectionKey(section)) return null;
  const scope = section === "profiles" || section === "watchedby" ? "account" : syncIdFor(profileId || activeId());
  if (!scope) return null;
  const p = readParked(`${scope}:${section}`);
  return p ? { value: p.value, rev: p.lostToRev } : null;
}

export function restoreParked(section: string, profileId?: string): boolean {
  if (!isSectionKey(section)) return false;
  return restoreParkedSection(section, profileId);
}
