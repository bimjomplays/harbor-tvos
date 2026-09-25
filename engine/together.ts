// Watch Together on the TV: upstream's TogetherProvider (lib/together/provider.tsx) without React.
//
// The relay client, the event reducer and every derivation are upstream's own modules
// (TogetherClient, applyRoomEvent, createCommandSender, deriveHostSource, …); this file only
// replaces React state with module state and forwards changes to Swift:
//   harbor:together       detail = view(), throttled (participants, chat, toasts, cursors, strokes)
//   harbor:together-sync  detail = {kind:"state", state} | {kind:"command", from, command}, immediate
// The player's room sync (use-room-sync.ts) runs in Swift beside the player (Together/
// TogetherPlayback.swift) because it acts on live playback position.
//
// Nothing here writes to the Harbor account server. The only persisted values are upstream's
// own localStorage keys (harbor.together.clientId / .name) and the togetherRelayUrl setting,
// which upstream's relay panel and invite links write in the same shape.
import { TogetherClient, type RoomEvent, type RoomSnapshot } from "@/lib/together/client";
import { applyRoomEvent, inviteMediaKey } from "@/lib/together/provider-events";
import { createCommandSender } from "@/lib/together/seek-coalesce";
import {
  WT_PROTO,
  generateRoomCode,
  normalizeRoomCode,
  type ParticipantLocation,
  type PlayInvite,
  type RoomCommand,
  type SyncState,
} from "@/lib/together/protocol";
import type {
  ChatMessage,
  IncomingDraw,
  IncomingHostLeaving,
  IncomingInvite,
  IncomingParticipantLeft,
  IncomingSummon,
  PartialSyncState,
  RemoteCursor,
} from "@/lib/together/provider-types";
import { deriveHostSource, deriveRoomGuestPick, hostSourceMatchesMedia, type LastInviteMeta } from "@/lib/together/room-derive";
import type { SourceDescriptor } from "@/lib/together/protocol";
import { HARBOR_PUBLIC_RELAY, isPublicRelay, relayOutdated } from "@/lib/together/relay-version";
import { buildInviteUrl, WEB_JOIN_BASE } from "@/lib/together/invite";
import { buildPlayInvite } from "@/lib/together/build-invite";
import { buildSourceDescriptor } from "@/lib/together/source-descriptor";
import { nameColor } from "@/lib/together/colors";
import { loadEffective, persistEffective } from "@/lib/settings/profile-store";
import type { Settings } from "@/lib/settings/types";
import { randomUuid } from "@/lib/uuid";
import { currentAuthor } from "@/lib/theme-auth";
import { fetchProfileAlias, isPlaceholderName } from "@/lib/account/name-sync";
import type { Meta } from "@/lib/cinemeta";
import type { PlayEpisode } from "@/lib/view";

// provider.tsx
const CLIENT_ID_KEY = "harbor.together.clientId";
const NAME_KEY = "harbor.together.name";
// provider.tsx: the summon toast clears itself after 14 s.
const SUMMON_TTL_MS = 14000;
// provider.tsx: cursors idle for 6 s are dropped (checked every 1.5 s).
const CURSOR_TTL_MS = 6000;
// App.tsx TogetherLocationPublisher: presence every 6 s while in a room.
const PRESENCE_MS = 6000;
// use-draw-mode.ts STROKE_GC_MS: other people's strokes fade after 9.5 s.
const STROKE_GC_MS = 9500;
const STROKE_MAX_POINTS = 600;
const EMIT_THROTTLE_MS = 150;

type Stroke = {
  id: string;
  authorId: string;
  authorName: string;
  color: string;
  points: { x: number; y: number }[];
  bornAt: number;
  path: string;
};

const EMPTY: RoomSnapshot = {
  state: "disconnected",
  room: null,
  participants: [],
  syncState: null,
  hostClientId: null,
  started: false,
  relayVersion: null,
  lastError: null,
};

function loadOrInitClientId(): string {
  let id = localStorage.getItem(CLIENT_ID_KEY);
  if (!id) {
    id = randomUuid();
    localStorage.setItem(CLIENT_ID_KEY, id);
  }
  return id;
}

function loadOrInitName(): string {
  return localStorage.getItem(NAME_KEY) ?? `Guest ${Math.floor(Math.random() * 9000 + 1000)}`;
}

// ------------------------------------------------------------------------------ module state
let relayUrl = "";
let guestsPick = false;
let shareCursors = true;
let client: TogetherClient | null = null;
let offClient: (() => void) | null = null;
let clientId = "";
let displayName = "";
let selfAvatar: string | null = null;
let selfColor: string | null = null;
let snapshot: RoomSnapshot = EMPTY;
let chat: ChatMessage[] = [];
let incomingInvite: IncomingInvite | null = null;
let incomingHostLeaving: IncomingHostLeaving | null = null;
let incomingParticipantLeft: IncomingParticipantLeft | null = null;
let incomingSummon: IncomingSummon | null = null;
let cursorMap = new Map<string, RemoteCursor>();
let presenceMap = new Map<string, number>();
let participantLocations = new Map<string, ParticipantLocation>();
let strokes: Stroke[] = [];
const lastInviteRef: { current: LastInviteMeta | null } = { current: null };
const stateListenersRef: { current: Set<(s: SyncState) => void> } = { current: new Set() };
const commandListenersRef: { current: Set<(from: string, c: RoomCommand) => void> } = { current: new Set() };
const drawListenersRef: { current: Set<(e: IncomingDraw) => void> } = { current: new Set() };
const commandSender = createCommandSender((c) => client?.sendCommand(c));
let location: ParticipantLocation | undefined;
let presenceTimer: ReturnType<typeof setInterval> | null = null;
let sweepTimer: ReturnType<typeof setInterval> | null = null;
let summonTimer: ReturnType<typeof setTimeout> | null = null;
let rev = 0;
let emitTimer: ReturnType<typeof setTimeout> | null = null;
let lastEmitAt = 0;
let aliasTried = "";

function ensureIdentity() {
  if (!clientId) clientId = loadOrInitClientId();
  if (!displayName) displayName = loadOrInitName();
}

// A setState stand-in: provider-events hands either a value or an updater.
function setter<T>(get: () => T, set: (v: T) => void) {
  return (v: T | ((prev: T) => T)) => {
    const next = typeof v === "function" ? (v as (p: T) => T)(get()) : v;
    set(next);
    changed();
  };
}

const sinks = {
  get clientId() {
    return clientId;
  },
  stateListenersRef,
  commandListenersRef,
  drawListenersRef,
  lastInviteRef,
  setSnapshot: setter(() => snapshot, (v) => {
    snapshot = v;
    onSnapshot();
  }),
  setCursorMap: setter(() => cursorMap, (v) => (cursorMap = v)),
  setPresenceMap: setter(() => presenceMap, (v) => (presenceMap = v)),
  setParticipantLocations: setter(() => participantLocations, (v) => (participantLocations = v)),
  setChat: setter(() => chat, (v) => (chat = v)),
  setIncomingInvite: setter(() => incomingInvite, (v) => (incomingInvite = v)),
  setIncomingHostLeaving: setter(() => incomingHostLeaving, (v) => (incomingHostLeaving = v)),
  setIncomingParticipantLeft: setter(() => incomingParticipantLeft, (v) => (incomingParticipantLeft = v)),
  setIncomingSummon: setter(() => incomingSummon, (v) => {
    incomingSummon = v;
    armSummonTimer();
  }),
};

// Swift hears incoming playback state and commands straight away (use-room-sync listens to both).
stateListenersRef.current.add((state) => emitSync({ kind: "state", state }));
commandListenersRef.current.add((from, command) => emitSync({ kind: "command", from, command }));
// use-draw-mode.ts: other people's strokes, kept view-only on the TV.
drawListenersRef.current.add((e) => {
  if (e.from === clientId) return;
  if (e.phase === "clear") {
    strokes = strokes.filter((s) => s.path !== e.path);
  } else if (e.x == null || e.y == null) {
    if (e.phase === "end") strokes = strokes.filter((s) => Date.now() - s.bornAt < STROKE_GC_MS);
  } else {
    const point = { x: e.x, y: e.y };
    const idx = strokes.findIndex((s) => s.id === e.strokeId);
    if (idx === -1) {
      // (bug pass 2) A nameless draw event: nameColor(undefined) threw and stopped the view.
      strokes = [
        ...strokes,
        { id: e.strokeId, authorId: e.from, authorName: typeof e.name === "string" ? e.name : "", color: e.color || nameColor(typeof e.name === "string" ? e.name : ""), points: [point], bornAt: Date.now(), path: e.path },
      ];
    } else if (strokes[idx].points.length < STROKE_MAX_POINTS) {
      const next = strokes.slice();
      next[idx] = { ...next[idx], points: [...next[idx].points, point] };
      strokes = next;
    }
  }
  changed();
});

function emitSync(detail: unknown) {
  window.dispatchEvent(new CustomEvent("harbor:together-sync", { detail }));
}

function changed() {
  rev += 1;
  if (emitTimer != null) return;
  const wait = Math.max(0, EMIT_THROTTLE_MS - (Date.now() - lastEmitAt));
  emitTimer = setTimeout(() => {
    emitTimer = null;
    lastEmitAt = Date.now();
    window.dispatchEvent(new CustomEvent("harbor:together", { detail: view() }));
  }, wait);
}

function armSummonTimer() {
  if (summonTimer != null) clearTimeout(summonTimer);
  summonTimer = null;
  if (!incomingSummon) return;
  summonTimer = setTimeout(() => {
    summonTimer = null;
    incomingSummon = null;
    changed();
  }, SUMMON_TTL_MS);
}

// provider.tsx: leaving clears cursors/presence/toasts; while joined, idle cursors are swept.
function onSnapshot() {
  if (snapshot.state === "disconnected") {
    cursorMap = new Map();
    presenceMap = new Map();
    participantLocations = new Map();
    incomingInvite = null;
    incomingHostLeaving = null;
    incomingSummon = null;
    strokes = [];
  }
  const joined = snapshot.state === "joined";
  if (joined && sweepTimer == null) {
    sweepTimer = setInterval(() => {
      const now = Date.now();
      let dirty = false;
      for (const [k, v] of cursorMap) {
        if (now - v.updatedAt > CURSOR_TTL_MS) {
          cursorMap.delete(k);
          dirty = true;
        }
      }
      const live = strokes.filter((s) => now - s.bornAt < STROKE_GC_MS);
      if (live.length !== strokes.length) {
        strokes = live;
        dirty = true;
      }
      if (dirty) {
        cursorMap = new Map(cursorMap);
        changed();
      }
    }, 1500);
  } else if (!joined && sweepTimer != null) {
    clearInterval(sweepTimer);
    sweepTimer = null;
  }
  // App.tsx TogetherLocationPublisher
  if (joined && presenceTimer == null) {
    client?.sendPresence(location);
    presenceTimer = setInterval(() => client?.sendPresence(location), PRESENCE_MS);
  } else if (!joined && presenceTimer != null) {
    clearInterval(presenceTimer);
    presenceTimer = null;
  }
}

function attachClient(url: string) {
  if (offClient) offClient();
  if (client) client.leave();
  offClient = null;
  client = null;
  relayUrl = url;
  // The old client's leave() lands after its listener is gone, so its "disconnected" never
  // arrives: reset here, which also stops the sweep / presence timers and the summon expiry.
  snapshot = EMPTY;
  onSnapshot();
  armSummonTimer();
  changed();
  if (!url) return;
  ensureIdentity();
  const c = new TogetherClient(url, clientId, displayName, selfAvatar, selfColor);
  client = c;
  offClient = c.on((e: RoomEvent) => applyRoomEvent(e, sinks as Parameters<typeof applyRoomEvent>[1]));
}

// ------------------------------------------------------------------------------ public API

export type Identity = {
  profileId?: string;
  linked?: boolean;
  /** The profile's avatar when it is a shareable URL (use-self-identity.ts); bundled art is not. */
  avatar?: string | null;
  /** The profile colour (use-self-identity.ts: settings.harborColor wins). */
  color?: string | null;
};

function settingsFor(id: Identity): Settings {
  return loadEffective(id.profileId || "default", id.linked !== false) as Settings;
}

/**
 * provider.tsx mount: read the relay from the active profile's settings, build the client for
 * it (a relay change tears the old one down, like the provider's [relayUrl] effect) and push
 * the avatar/colour (use-self-identity). Safe to call on every profile switch.
 */
export function configure(id: Identity = {}) {
  ensureIdentity();
  const s = settingsFor(id);
  guestsPick = !!s.togetherGuestsPick;
  shareCursors = s.togetherShareCursors !== false;
  const avatar = id.avatar && /^(https?:|data:)/i.test(id.avatar) ? id.avatar : null;
  const color = (s as { harborColor?: string }).harborColor || id.color || null;
  if (avatar !== selfAvatar || color !== selfColor) {
    selfAvatar = avatar;
    selfColor = color;
    client?.setProfile(selfAvatar, selfColor);
  }
  const url = (s.togetherRelayUrl || "").trim();
  if (url !== relayUrl || (url && !client)) attachClient(url);
  void adoptAccountAlias();
  changed();
  return view();
}

/**
 * components/harbor-name-sync.tsx, read half only: a signed-in account's profile alias replaces
 * a placeholder "Guest 1234" name. The TV never pushes its name back (that PATCH is the
 * desktop's name-sync session, not part of Watch Together).
 */
async function adoptAccountAlias() {
  const a = currentAuthor();
  if (!a?.handle || aliasTried === a.id) return;
  aliasTried = a.id;
  if (!isPlaceholderName(localStorage.getItem(NAME_KEY))) return;
  try {
    const alias = await fetchProfileAlias(a.handle, a.id);
    if (alias && isPlaceholderName(localStorage.getItem(NAME_KEY))) setName(alias);
  } catch {
    aliasTried = "";
  }
}

/** relay-panel.tsx "Use Harbor's public relay" / a pasted relay URL / "Remove": the setting itself. */
export function setRelay(id: Identity, url: string) {
  const s = settingsFor(id);
  const next = (url || "").trim();
  if ((s.togetherRelayUrl || "") !== next) {
    persistEffective({ ...s, togetherRelayUrl: next } as Settings, id.profileId || "default", id.linked !== false);
  }
  return configure(id);
}

/** guest-pick-toggle.tsx: the host lets guests choose their own source. */
export function setGuestsPick(id: Identity, on: boolean) {
  const s = settingsFor(id);
  persistEffective({ ...s, togetherGuestsPick: !!on } as Settings, id.profileId || "default", id.linked !== false);
  guestsPick = !!on;
  changed();
  return view();
}

/** provider.tsx setDisplayName. */
export function setName(n: string) {
  ensureIdentity();
  const trimmed = String(n ?? "").trim().slice(0, 32) || `Guest ${Math.floor(Math.random() * 9000 + 1000)}`;
  displayName = trimmed;
  localStorage.setItem(NAME_KEY, trimmed);
  client?.setName(trimmed);
  changed();
  return view();
}

/** provider.tsx startSession: a fresh code on this relay. */
export function start(): string | null {
  if (!client) return null;
  const code = generateRoomCode();
  chat = [];
  client.join(code);
  changed();
  return code;
}

export type JoinTarget = { relay: string | null; room: string };

/**
 * together-modal.tsx handleJoin: a bare code, or an invite link (lib/together/invite.ts
 * `?harbor-relay=…&harbor-room=…`), which also carries the relay to use.
 */
export function parseJoin(input: string): JoinTarget | null {
  const value = String(input ?? "").trim();
  if (!value) return null;
  if (/^https?:\/\//i.test(value) || value.includes("harbor-relay=")) {
    try {
      const url = new URL(value.startsWith("http") ? value : `https://x${value.startsWith("?") ? value : `?${value}`}`);
      const relay = url.searchParams.get("harbor-relay");
      const room = url.searchParams.get("harbor-room");
      if (relay && room && /^wss?:\/\//i.test(relay.trim())) {
        const norm = normalizeRoomCode(room);
        return norm ? { relay: relay.trim(), room: norm } : null;
      }
    } catch {}
    return null;
  }
  const norm = normalizeRoomCode(value);
  return norm ? { relay: null, room: norm } : null;
}

/** provider.tsx joinSession (+ the invite link's relay switch). */
export function join(id: Identity, input: string) {
  const target = parseJoin(input);
  if (!target) return { ok: false, reason: "invalid" as const, view: view() };
  if (target.relay && target.relay !== relayUrl) setRelay(id, target.relay);
  if (!client) return { ok: false, reason: "no-relay" as const, view: view() };
  chat = [];
  client.join(target.room);
  changed();
  return { ok: true, reason: null, view: view() };
}

export function leave() {
  chat = [];
  client?.leave();
  changed();
  return view();
}

export function retry() {
  client?.retry();
  return view();
}

/** provider.tsx publishState: the partial state this TV is playing. */
export function publishState(state: PartialSyncState) {
  ensureIdentity();
  client?.publishState({ ...state, updatedAt: Date.now(), updatedBy: clientId, hostClientId: null });
}

/** provider.tsx sendCommand: seeks go through upstream's 250 ms coalescer. */
export function sendCommand(command: RoomCommand) {
  commandSender.send(command);
}

export function sendChat(text: string) {
  client?.sendChat(String(text ?? ""));
}

export function markReady(ready: boolean) {
  client?.markReady(!!ready);
}

export function claimHost(fresh: boolean) {
  client?.claimHost(!!fresh);
}

export function startRoom() {
  client?.startRoom();
}

export function notifyHostLeaving() {
  client?.notifyHostLeaving();
}

export function clearInvite() {
  client?.clearInvite();
}

export function suppressOutgoingFor(ms: number) {
  client?.suppressOutgoingFor(Math.max(0, Number(ms) || 0));
}

/** provider.tsx sendInvite: stamped with the protocol and the host's guests-pick setting. */
export function sendInvite(invite: PlayInvite) {
  client?.sendInvite({ ...invite, proto: WT_PROTO, guestPick: guestsPick || undefined });
}

/** App.tsx TogetherLocationPublisher: where this TV is (player / picker / meta / home…). */
export function setLocation(loc: ParticipantLocation | null) {
  location = loc ?? undefined;
  if (snapshot.state === "joined") client?.sendPresence(location);
}

export function dismiss(kind: "invite" | "hostLeaving" | "participantLeft" | "summon") {
  if (kind === "invite") incomingInvite = null;
  else if (kind === "hostLeaving") incomingHostLeaving = null;
  else if (kind === "participantLeft") incomingParticipantLeft = null;
  else if (kind === "summon") {
    incomingSummon = null;
    armSummonTimer();
  }
  changed();
  return view();
}

/** provider.tsx wasInvitedTo: an invite for this media arrived in the last minute. */
export function wasInvitedTo(key: string): boolean {
  const r = lastInviteRef.current;
  return !!r && r.key === key && Date.now() - r.at < 60_000;
}

/**
 * The player opened (views/play-picker/use-room-invite.ts + use-pick-handler.ts): in a room,
 * when nobody else is the host and this title was not the one we were invited to, the TV
 * becomes the host and invites everyone to it. Returns the role the player should take.
 */
export function playerOpened(meta: Meta, episode: PlayEpisode | null, source: SourceRefLike | null, durationSec?: number) {
  const inSession = snapshot.state === "joined" && !!snapshot.room;
  const key = inviteMediaKey({ mediaId: meta.id, episode: episode ?? undefined } as PlayInvite);
  const foreignHost = !!snapshot.hostClientId && snapshot.hostClientId !== clientId;
  const canInvite = inSession && !wasInvitedTo(key) && !foreignHost;
  if (canInvite) {
    claimHost(true);
    sendInvite(buildPlayInvite(meta, episode ?? undefined));
  }
  return { invited: canInvite, source: buildSourceDescriptor(source as never, durationSec) };
}

/** lib/together/source-descriptor.ts buildSourceDescriptor over the fields the TV knows. */
type SourceRefLike = { title?: string; parsedTitle?: string; resolution?: string; size?: number; infoHash?: string; fileIdx?: number };
export function sourceDescriptor(ref: SourceRefLike | null, durationSec?: number) {
  return buildSourceDescriptor(ref as never, durationSec);
}

/** invite-panel.tsx: the link a friend opens (or pastes into their Harbor) to join this room. */
export function inviteUrl(): string | null {
  if (!relayUrl || !snapshot.room) return null;
  return buildInviteUrl(relayUrl, snapshot.room, WEB_JOIN_BASE);
}

function locationLabel(loc: ParticipantLocation | undefined): string | null {
  if (!loc) return null;
  switch (loc.kind) {
    case "player":
      return loc.episode ? `Watching ${loc.meta.name} · S${loc.episode.season} E${loc.episode.episode}` : `Watching ${loc.meta.name}`;
    case "picker":
      return `Picking a source for ${loc.meta.name}`;
    case "meta":
      return `Looking at ${loc.meta.name}`;
    case "person":
      return "Looking at a person";
    case "service":
      return `Browsing ${loc.service}`;
    case "addon-detail":
      return "Looking at an addon";
    default:
      return `On ${loc.kind[0].toUpperCase()}${loc.kind.slice(1)}`;
  }
}

/** Everything the TV screens read, as plain JSON. */
/**
 * (player parity pass 2) use-bp-streams.ts hostSourceForMedia: the host's source descriptor when
 * this TV is in a joined room under someone else's host and that host is playing this title (and
 * this episode). null otherwise, as upstream's hook returns.
 */
export function hostSourceForMedia(mediaId: string, episode: { season: number; episode: number } | null): SourceDescriptor | null {
  ensureIdentity();
  const foreignHost = Boolean(snapshot.hostClientId) && snapshot.hostClientId !== clientId;
  if (snapshot.state !== "joined" || !foreignHost) return null;
  const hostSource = deriveHostSource(snapshot);
  return hostSourceMatchesMedia(hostSource, mediaId, episode) ? (hostSource?.descriptor ?? null) : null;
}

export function view() {
  ensureIdentity();
  const inSession = snapshot.state === "joined" && !!snapshot.room;
  const participants = snapshot.participants
    // (bug pass 2) A relay entry without an id is dropped and a missing / non-string name reads
    // as "": nameColor(undefined) threw inside the emit timer, so one malformed participant
    // stopped every harbor:together update and the Watch Together screen froze.
    .filter((p) => p && typeof p.id === "string")
    .sort((a, b) => (Number(a.joinedAt) || 0) - (Number(b.joinedAt) || 0))
    .map((p) => {
      const self = p.id === clientId;
      const name = typeof p.name === "string" ? p.name : "";
      return {
        id: p.id,
        name,
        ready: !!p.ready,
        joinedAt: p.joinedAt,
        avatar: self ? selfAvatar : (p.avatar ?? null),
        color: (self ? selfColor : (typeof p.color === "string" ? p.color : null)) || nameColor(name),
        isSelf: self,
        host: p.id === snapshot.hostClientId,
        activeAt: presenceMap.get(p.id) ?? null,
        location: participantLocations.get(p.id) ?? null,
        locationLabel: locationLabel(participantLocations.get(p.id)),
      };
    });
  const inRoom = snapshot.state === "joined" && snapshot.participants.length >= 2;
  return {
    rev,
    enabled: !!relayUrl,
    relayUrl,
    publicRelay: HARBOR_PUBLIC_RELAY,
    isPublicRelay: isPublicRelay(relayUrl),
    relayOutdated: snapshot.state === "joined" && !isPublicRelay(relayUrl) && relayOutdated(snapshot.relayVersion),
    state: snapshot.state,
    room: snapshot.room,
    lastError: snapshot.lastError,
    started: snapshot.started,
    hostClientId: snapshot.hostClientId,
    syncState: snapshot.syncState,
    clientId,
    displayName,
    selfColor: selfColor || nameColor(displayName),
    inSession,
    inRoom,
    isHost: inRoom && snapshot.hostClientId === clientId,
    guestsPick,
    shareCursors,
    hostSource: deriveHostSource(snapshot),
    roomGuestPick: deriveRoomGuestPick(snapshot, clientId, lastInviteRef.current),
    lastInviteProto: lastInviteRef.current?.proto ?? 0,
    participants,
    chat,
    incomingInvite,
    incomingHostLeaving,
    incomingParticipantLeft,
    incomingSummon,
    cursors: Array.from(cursorMap.values()).filter((c) => c.visible && c.from !== clientId),
    strokes,
    inviteUrl: inviteUrl(),
  };
}

/** Test hook: drop every piece of state (the smoke test builds several rooms in one bundle). */
export function reset() {
  attachClient("");
  chat = [];
  lastInviteRef.current = null;
  location = undefined;
  aliasTried = "";
  changed();
}
