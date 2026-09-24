// Social surfaces for the TV (Stage 10): the signed-in account's profile, other members'
// profiles, notifications, the friends activity feed, groups and shared lists.
//
// Every request is upstream's own client (lib/social/*, views/profile/profile-api.ts), so the
// TV reads and writes exactly what desktop Harbor does, in the same shape. The hooks that
// drive those clients upstream (use-profile, use-notification-center, use-feed,
// use-group-discovery, use-group, use-shared-list) are React; the orchestration they do is
// ported here as plain async functions that return JSON for Swift.
import { currentAuthor, authToken } from "@/lib/theme-auth";
import {
  fetchActivity,
  fetchBadges,
  fetchComments,
  fetchFriends as fetchProfileFriends,
  fetchSummary,
  postComment,
  setCommentLike,
  ProfileNotFound,
} from "@/views/profile/profile-api";
import type { ProfileSummary } from "@/views/profile/profile-types";
import { validateComment } from "@/views/profile/text-safety";
import { badgeIconUrl } from "@/views/profile/badge-catalog";
import { compactNumber, formatWatchTime } from "@/views/profile/profile-bits";
import { STAT_LABELS, STAT_ORDER, sanitizeStatLayout, watchMinutes } from "@/lib/profile-card-layout";
import { fetchAllNotifications, markAllNotificationsRead, type CenterNotif } from "@/lib/social/notifications";
import { dismissNotifs, isDismissed } from "@/lib/social/dismissed-notifications";
import {
  acceptFriend,
  declineFriend,
  fetchPendingRequests,
  removeFriend,
  sendFriendRequest,
  type PendingRequest,
} from "@/lib/social/friends";
import { fetchFriendsFeed, fetchFriendsWatching } from "@/lib/social/feed";
import {
  fetchGroup,
  fetchGroupInvites,
  fetchMyGroups,
  fetchPublicGroups,
  groupPerms,
  joinGroup,
  leaveGroup,
  myGroupRole,
  respondToInvite,
  type GroupDetail,
} from "@/lib/social/groups";
import { createGroupPost, fetchGroupPosts, likeGroupPost, type GroupPost } from "@/lib/social/group-posts";
import { likeList, unlikeList } from "@/lib/social/list-likes";
import { saveList } from "@/lib/social/save-list";
import { renderBbcode } from "@/lib/social/bbcode";
import { HARBOR_API_BASE } from "@/lib/config/endpoints";

function message(e: unknown, fallback: string): string {
  const m = (e as { message?: unknown } | null)?.message;
  return typeof m === "string" && m && !/^Request failed/.test(m) ? m : fallback;
}

/** Throw a message the TV can show as-is (upstream's hooks set these same strings as `error`). */
function fail(e: unknown, fallback: string): never {
  throw new Error(message(e, fallback));
}

// ------------------------------------------------------------------------------ identity
/** account-menu-panel.tsx: "View my profile" and "Notifications" exist only with an author. */
export function me() {
  const a = currentAuthor();
  if (!a || !authToken()) return { signedIn: false, handle: null, username: null, avatar: null, verified: false };
  return { signedIn: true, handle: a.handle ?? null, username: a.username, avatar: a.avatar ?? null, verified: !!a.verified };
}

// ------------------------------------------------------------------------------ profile
type Stat = { key: string; label: string; value: string };

/** profile-hero.tsx: the hero's stat pills, in STAT_ORDER, minus the ones the member hid. */
function heroStats(p: ProfileSummary): { stats: Stat[]; watch: ReturnType<typeof formatWatchTime> } {
  const hidden = new Set(sanitizeStatLayout(p.statLayout).hidden);
  const c = p.counts ?? ({} as ProfileSummary["counts"]);
  const minutes = watchMinutes(c);
  const watch = formatWatchTime(minutes);
  const pad = (n: number) => String(n).padStart(2, "0");
  const stats: Stat[] = [];
  for (const k of STAT_ORDER) {
    if (hidden.has(k)) continue;
    let value = "";
    if (k === "watchTime") value = `${watch.a} ${pad(watch.aVal)} ${watch.b} ${pad(watch.bVal)} ${watch.c} ${pad(watch.cVal)}`;
    else if (k === "episodes") value = compactNumber(c.episodesWatched ?? 0);
    else if (k === "movies") value = compactNumber(c.moviesWatched ?? 0);
    else if (k === "read") value = compactNumber(c.mangaRead ?? 0);
    else if (k === "friends") value = compactNumber(c.friends ?? 0);
    else if (k === "badges") value = compactNumber(c.badges ?? 0);
    stats.push({ key: k, label: STAT_LABELS[k], value });
  }
  return { stats, watch };
}

/**
 * use-profile.ts: summary first, then friends, badges and recent activity. A private profile
 * the viewer does not own shows only the hero (profile.tsx `locked`).
 */
export async function profile(handle?: string | null) {
  const target = (handle || currentAuthor()?.handle || "").trim();
  if (!target) return { state: currentAuthor() ? "no-handle" : "signed-out", handle: null };
  let summary: ProfileSummary;
  try {
    summary = await fetchSummary(target);
  } catch (e) {
    return { state: e instanceof ProfileNotFound ? "empty" : "error", handle: target };
  }
  const locked = !!summary.private && !summary.isOwner;
  const [friends, badges, activity] = locked
    ? [[], [], []]
    : await Promise.all([
        fetchProfileFriends(target).catch(() => []),
        fetchBadges(target).catch(() => []),
        fetchActivity(target).catch(() => []),
      ]);
  const { stats } = heroStats(summary);
  // profile-hero.tsx nameBadges: the badges the member chose to show next to the name.
  const shown = new Set(summary.shownBadges ?? []);
  return {
    state: "ready",
    handle: target,
    locked,
    summary: {
      handle: summary.handle,
      alias: summary.alias,
      avatarUrl: summary.avatarUrl ?? null,
      bannerUrl: summary.bannerUrl ?? null,
      verified: !!summary.verified && !summary.hideVerified,
      level: summary.level ?? 0,
      xp: summary.xp ?? 0,
      xpToNext: summary.xpToNext ?? 0,
      slogan: summary.slogan ?? null,
      description: summary.description ?? null,
      location: summary.location ?? null,
      pronouns: summary.pronouns ?? null,
      online: !!summary.online,
      memberSince: summary.memberSince ?? null,
      isOwner: !!summary.isOwner,
      friendStatus: summary.friendStatus ?? "none",
      friendEdgeId: summary.friendEdgeId ?? null,
      watching: summary.watching ?? null,
      featuredLists: (summary.featuredLists ?? []).map((l) => ({
        id: l.id,
        name: l.name,
        description: l.description ?? null,
        count: l.items?.length ?? 0,
        posters: (l.items ?? []).slice(0, 4).map((i) => i.poster).filter(Boolean),
        likeCount: l.likeCount ?? 0,
      })),
    },
    stats,
    friends: friends.map((f) => ({ handle: f.handle, alias: f.alias, avatarUrl: f.avatarUrl ?? null, online: !!f.online, slogan: f.slogan ?? null })),
    badges: badges.map((b) => ({
      id: b.id,
      name: b.name,
      description: b.description,
      iconUrl: b.iconUrl || badgeIconUrl(b.id) || null,
      tier: b.tier,
      shown: shown.has(b.id),
    })),
    activity: activity.map((a) => ({
      id: a.id,
      kind: a.kind,
      title: a.title,
      posterUrl: a.posterUrl ?? null,
      subtitle: a.subtitle ?? null,
      rating: a.rating ?? null,
      at: a.at,
      metaId: a.metaId ?? null,
    })),
  };
}

/** comments-section.tsx / use-comments.ts: one page, newest first. */
export async function comments(handle: string, cursor?: string | null) {
  try {
    const page = await fetchComments(handle, cursor ?? undefined);
    return {
      total: page.total ?? null,
      nextCursor: page.nextCursor ?? null,
      comments: (page.comments ?? []).map((c) => ({
        id: c.id,
        parentId: c.parentId ?? null,
        authorHandle: c.authorHandle,
        authorAlias: c.authorAlias,
        authorAvatarUrl: c.authorAvatarUrl ?? null,
        body: c.body,
        at: c.at,
        likeCount: c.likeCount ?? 0,
        liked: !!c.liked,
      })),
    };
  } catch (e) {
    fail(e, "Could not load comments.");
  }
}

let lastCommentAt = 0;
/** comment-compose.tsx: validateComment, then post (upstream's 15 s cooldown included). */
export async function comment(handle: string, body: string) {
  const issue = validateComment(body ?? "", lastCommentAt, Date.now());
  const COPY: Record<string, string> = {
    empty: "Write something first.",
    "too-long": "Keep it under 280 characters.",
    url: "Links are not allowed in comments.",
    spam: "That looks like spam.",
    cooldown: "Slow down a little before posting again.",
  };
  if (issue) throw new Error(COPY[issue] ?? "Could not post.");
  try {
    const c = await postComment(handle, body.trim());
    lastCommentAt = Date.now();
    return { id: c.id };
  } catch (e) {
    const status = (e as { status?: number }).status;
    fail(e, status === 429 ? "Slow down a little before posting again." : "Could not post.");
  }
}

export async function commentLike(handle: string, id: string, liked: boolean) {
  try {
    return await setCommentLike(handle, id, !!liked);
  } catch (e) {
    fail(e, "Could not update.");
  }
}

// profile-hero.tsx FriendButton: the actions its four states offer.
export async function friendRequest(handle: string) {
  try {
    await sendFriendRequest(handle);
    return { friendStatus: "outgoing" };
  } catch (e) {
    fail(e, "Try again");
  }
}
export async function friendAccept(edgeId: string) {
  try {
    await acceptFriend(edgeId);
    return { friendStatus: "friends" };
  } catch (e) {
    fail(e, "Try again");
  }
}
export async function friendDecline(edgeId: string) {
  try {
    await declineFriend(edgeId);
    return { friendStatus: "none" };
  } catch (e) {
    fail(e, "Try again");
  }
}
export async function friendRemove(handle: string) {
  try {
    await removeFriend(handle);
    return { friendStatus: "none" };
  } catch (e) {
    fail(e, "Try again");
  }
}

// ------------------------------------------------------------------------------ notifications
// components/notification-center/notification-rows.tsx notifTitle (TITLE_BY_KIND, GENERIC_TITLES).
const TITLE_BY_KIND: Record<string, string> = {
  "friend-request": "Friend request",
  comment: "New comment",
  "group-added": "Group invite",
  "group-post": "New group post",
  mention: "You were mentioned",
  downloads: "Downloads milestone",
  stars: "Ratings milestone",
  "diagnostics-request": "Diagnostics requested",
  system: "Message from Harbor",
};
const GENERIC_TITLES = new Set(["", "Notification", "New badge unlocked", "New badge"]);

function titleCase(s: string): string {
  return s.replace(/[_-]+/g, " ").trim().replace(/\b\w/g, (c) => c.toUpperCase());
}

function badgeName(n: CenterNotif): string {
  const raw = (n.body || "").trim();
  if (!raw || raw.length > 24 || /[.!?]/.test(raw)) return "";
  return titleCase(raw);
}

function notifTitle(n: CenterNotif): string {
  if (n.kind === "badge-received") {
    const name = badgeName(n);
    if (name) return `You earned the ${name} badge`;
    if (n.title && !GENERIC_TITLES.has(n.title)) return n.title;
    return "You earned a new badge";
  }
  const known = TITLE_BY_KIND[n.kind];
  if (known) return known;
  if (n.title && !GENERIC_TITLES.has(n.title)) return n.title;
  return "Notification";
}

/**
 * notification-rows.tsx detailAction + notification-center.tsx openNotif: where a row leads.
 * "group" opens the group, "profile" the member's own profile, "detail" shows the text.
 */
function notifTarget(n: CenterNotif): { open: "group" | "profile" | "detail"; id: string | null; label: string | null } {
  const groupKind = n.kind === "group-added" || n.kind === "group-post";
  const groupMention = n.kind === "mention" && n.entityType === "group";
  if ((groupKind || groupMention) && n.targetId) return { open: "group", id: n.targetId, label: "Open group" };
  const own = currentAuthor()?.handle ?? null;
  if (n.kind === "badge-received" && own) return { open: "profile", id: own, label: "View badges" };
  if (n.kind === "comment" && n.source === "social" && own) return { open: "profile", id: own, label: "View profile" };
  return { open: "detail", id: null, label: null };
}

/** use-notification-center.ts refresh: theme + social notifications and pending friend requests. */
export async function notifications() {
  if (!currentAuthor()) return { authed: false, items: [], pending: [], unread: 0, badge: 0 };
  const [feed, reqs] = await Promise.all([
    fetchAllNotifications(),
    fetchPendingRequests().catch(() => [] as PendingRequest[]),
  ]);
  const visible = feed.items.filter((n) => !isDismissed(n.id) && n.kind !== "friend-request");
  const unread = visible.filter((n) => !n.read).length;
  return {
    authed: true,
    items: visible.map((n) => ({
      id: n.id,
      kind: n.kind,
      source: n.source,
      title: notifTitle(n),
      body: n.body ?? null,
      cover: n.cover ?? null,
      createdAt: n.createdAt,
      read: n.read,
      target: notifTarget(n),
    })),
    pending: reqs.map((p) => ({
      edgeId: p.edgeId,
      handle: p.from.handle,
      alias: p.from.alias,
      avatarUrl: p.from.avatarUrl ?? null,
      slogan: p.slogan ?? null,
      createdAt: p.createdAt,
    })),
    unread,
    badge: unread + reqs.length,
  };
}

export async function notificationsMarkRead() {
  await markAllNotificationsRead();
  return true;
}

/** use-notification-center.ts dismiss / clearAll (clearAll also marks everything read). */
export async function notificationsDismiss(ids: string[], markRead = false) {
  dismissNotifs((ids ?? []).filter((x) => typeof x === "string"));
  if (markRead) await markAllNotificationsRead();
  return true;
}

// ------------------------------------------------------------------------------ feed
/** use-feed.ts: one page of friends' activity. */
export async function feed(cursor?: string | null) {
  try {
    const d = await fetchFriendsFeed(cursor ?? undefined);
    return {
      items: (d.items ?? []).map((i) => ({
        id: i.id,
        kind: i.kind,
        title: i.title,
        posterUrl: i.posterUrl ?? null,
        subtitle: i.subtitle ?? null,
        rating: i.rating ?? null,
        at: i.at,
        metaId: i.metaId,
        // views/feed.tsx open(): anime ids and series open as series, the rest as movies.
        type: i.type === "manga" ? "manga" : i.type === "series" || i.type === "anime" || /^(kitsu|mal|anilist|anidb):/i.test(i.metaId) ? "series" : "movie",
        actor: { handle: i.actor.handle, alias: i.actor.alias, avatarUrl: i.actor.avatarUrl ?? null, online: !!i.actor.online },
      })),
      nextCursor: d.nextCursor ?? null,
      friendCount: d.friendCount ?? 0,
      sharingCount: d.sharingCount ?? 0,
    };
  } catch (e) {
    fail(e, "Could not load activity");
  }
}

/** watching-strip.tsx: friends watching right now (polled every 60 s upstream). */
export async function watching() {
  const d = await fetchFriendsWatching().catch(() => ({ items: [] }));
  return (d.items ?? []).map((w) => ({
    handle: w.actor.handle,
    alias: w.actor.alias,
    avatarUrl: w.actor.avatarUrl ?? null,
    since: w.since,
    kind: w.watching.kind,
    title: w.watching.title ?? null,
    sub: w.watching.sub ?? null,
    posterUrl: w.watching.posterUrl ?? null,
    partySize: w.watching.partySize ?? null,
    paused: !!w.watching.paused,
  }));
}

// ------------------------------------------------------------------------------ groups
type GroupLike = { id: string; name: string; description?: string; avatarUrl?: string; visibility: string; tags: string[]; memberCount: number; isMember: boolean; isOwner: boolean; isPending?: boolean; owner?: { handle: string; alias: string } };

function groupCard(g: GroupLike) {
  return {
    id: g.id,
    name: g.name,
    description: g.description ?? null,
    avatarUrl: g.avatarUrl ?? null,
    visibility: g.visibility,
    tags: g.tags ?? [],
    memberCount: g.memberCount ?? 0,
    isMember: !!g.isMember,
    isOwner: !!g.isOwner,
    isPending: !!g.isPending,
    ownerAlias: g.owner?.alias ?? null,
  };
}

/**
 * use-group-discovery.ts + views/groups.tsx: "Your groups" (only while not searching), then the
 * public groups minus the ones already listed. Invites (group-invite-banner) are listed first.
 */
export async function groups(q?: string | null, tag?: string | null, cursor?: string | null) {
  const signedIn = !!currentAuthor();
  const browsing = !!(q && q.trim()) || !!tag;
  const [mine, invites, pub] = await Promise.all([
    signedIn && !browsing && !cursor ? fetchMyGroups().catch(() => []) : Promise.resolve([]),
    signedIn && !browsing && !cursor ? fetchGroupInvites().catch(() => []) : Promise.resolve([]),
    fetchPublicGroups({ q: q?.trim() || undefined, tag: tag || undefined, cursor: cursor || undefined }).then(
      (d) => ({ ok: true as const, d }),
      () => ({ ok: false as const, d: null }),
    ),
  ]);
  const mineIds = new Set(mine.map((g) => g.id));
  return {
    signedIn,
    mine: mine.map(groupCard),
    invites: invites.map(groupCard),
    groups: pub.ok ? pub.d.groups.filter((g) => !mineIds.has(g.id)).map(groupCard) : [],
    topTags: pub.ok ? pub.d.topTags ?? [] : [],
    total: pub.ok ? pub.d.total ?? 0 : 0,
    nextCursor: pub.ok ? pub.d.nextCursor ?? null : null,
    phase: pub.ok ? "ready" : "error",
  };
}

function groupView(d: GroupDetail) {
  const perms = groupPerms(d);
  return {
    ...groupCard(d),
    bannerUrl: d.bannerUrl ?? null,
    createdAt: d.createdAt,
    role: d.isMember || d.isOwner ? myGroupRole(d) : null,
    can: perms,
    members: (d.members ?? []).map((m) => ({
      userId: m.userId,
      handle: m.handle,
      alias: m.alias,
      avatarUrl: m.avatarUrl ?? null,
      online: !!m.online,
      role: m.role,
    })),
  };
}

/** use-group.ts load. */
export async function group(id: string) {
  try {
    return groupView(await fetchGroup(id));
  } catch (e) {
    fail(e, "It may be invite only, or it no longer exists.");
  }
}

export async function groupJoin(id: string) {
  try {
    return groupView(await joinGroup(id));
  } catch (e) {
    fail(e, "Could not join.");
  }
}

export async function groupLeave(id: string) {
  try {
    await leaveGroup(id);
    return true;
  } catch (e) {
    fail(e, "Could not leave.");
  }
}

/** group-invite-banner.tsx: accept (the group comes back) or decline. */
export async function groupRespond(id: string, accept: boolean) {
  try {
    const r = await respondToInvite(id, !!accept);
    return r && "id" in r ? groupView(r as GroupDetail) : null;
  } catch (e) {
    fail(e, accept ? "Could not join." : "Could not decline.");
  }
}

// post-body.tsx renders BBCode to HTML; the TV shows its text.
function htmlToText(html: string): string {
  return html
    .replace(/<br\s*\/?>/gi, "\n")
    .replace(/<\/(p|div|li|h\d|blockquote)>/gi, "\n")
    .replace(/<li[^>]*>/gi, "• ")
    .replace(/<[^>]+>/g, "")
    .replace(/&nbsp;/g, " ")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&quot;/g, '"')
    .replace(/&#39;|&#x27;/g, "'")
    .replace(/&amp;/g, "&")
    .replace(/\n{3,}/g, "\n\n")
    .trim();
}

function postView(p: GroupPost) {
  let text = p.body;
  try {
    text = htmlToText(renderBbcode(p.body));
  } catch {}
  return {
    id: p.id,
    text,
    pinned: !!p.pinned,
    createdAt: p.createdAt,
    edited: !!p.editedAt,
    author: p.author ? { handle: p.author.handle, alias: p.author.alias, avatarUrl: p.author.avatarUrl ?? null } : null,
    likeCount: p.likeCount ?? 0,
    liked: !!p.liked,
  };
}

/** group-posts.tsx: pinned first, then newest. */
export async function groupPosts(id: string, cursor?: string | null) {
  try {
    const page = await fetchGroupPosts(id, cursor ?? undefined);
    const posts = (page.posts ?? []).map(postView);
    if (!cursor) posts.sort((a, b) => Number(b.pinned) - Number(a.pinned));
    return { posts, nextCursor: page.nextCursor ?? null, canPost: !!page.canPost };
  } catch (e) {
    fail(e, "Could not load posts.");
  }
}

export async function groupPostLike(id: string, postId: string, liked: boolean) {
  try {
    return postView(await likeGroupPost(id, postId, !!liked));
  } catch (e) {
    fail(e, "Could not update.");
  }
}

/** post-compose.tsx: typed on the phone, posted as plain text (BBCode passes through). */
export async function groupPost(id: string, body: string) {
  const text = String(body ?? "").trim();
  if (!text) throw new Error("Write something first.");
  try {
    return postView(await createGroupPost(id, text));
  } catch (e) {
    fail(e, "Could not post.");
  }
}

// ------------------------------------------------------------------------------ shared lists
/**
 * lib/deep-link.ts parseHarborList (`harbor://list/<handle>/<listId>`), listShareUrl
 * (`https://harbor.site/list/<handle>/<listId>`), and a bare `handle/listId` typed on the TV.
 */
export function parseListLink(input: string): { handle: string; listId: string } | null {
  let s = String(input ?? "").trim();
  if (!s) return null;
  if (s.startsWith("harbor://")) s = s.slice("harbor://".length);
  else if (/^https?:\/\//i.test(s)) {
    try {
      const u = new URL(s);
      const base = new URL(HARBOR_API_BASE);
      if (u.host !== base.host && !/(^|\.)harbor\.site$/i.test(u.host)) return null;
      s = u.pathname;
    } catch {
      return null;
    }
  }
  const parts = s.split(/[?#]/)[0].split("/").filter((p) => p.length > 0);
  const at = parts[0] === "list" ? 1 : 0;
  if (parts.length - at < 2) return null;
  let handle = "";
  let listId = "";
  try {
    handle = decodeURIComponent(parts[at]).replace(/^@/, "");
    listId = decodeURIComponent(parts[at + 1]);
  } catch {
    return null;
  }
  if (!handle || !listId) return null;
  return { handle, listId };
}

/** use-shared-list.ts: the maker's profile, then the list among their featured lists. */
export async function sharedList(handle: string, listId: string) {
  let s: ProfileSummary;
  try {
    s = await fetchSummary(handle);
  } catch (e) {
    return { state: e instanceof ProfileNotFound ? "missing" : "error" };
  }
  const list = (s.featuredLists ?? []).find((l) => l.id === listId) ?? null;
  if (!list) return { state: "missing" };
  return {
    state: "ready",
    signedIn: !!currentAuthor(),
    owner: { handle: s.handle, alias: s.alias, avatarUrl: s.avatarUrl ?? null, bannerUrl: s.bannerUrl ?? null, isOwner: !!s.isOwner },
    list: {
      id: list.id,
      name: list.name || "Untitled list",
      description: list.description ?? null,
      likeCount: list.likeCount ?? 0,
      liked: !!list.liked,
      items: (list.items ?? []).map((i) => ({ id: i.id, name: i.name || "Untitled", poster: i.poster || null, type: i.type === "series" ? "series" : i.type || "movie" })),
    },
  };
}

/** list-heart.tsx */
export async function listLike(handle: string, listId: string, liked: boolean) {
  try {
    return liked ? await likeList(handle, listId) : await unlikeList(handle, listId);
  } catch (e) {
    fail(e, "Could not update.");
  }
}

/** save-list-button.tsx: copy it into this profile's custom lists. */
export async function listSave(handle: string, listId: string) {
  try {
    return await saveList(handle, listId);
  } catch (e) {
    fail(e, "Could not save this list.");
  }
}
