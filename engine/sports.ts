// Sports room (Stage 11) on upstream's hub: use-bp-sports.ts without React state, the same
// feeds (fetchHubSlice through loadSportsSlices), row shaping (bp-sports-rows.ts), discovery
// (featuredEvents), hot events, consent, personalization and game detail. Swift keeps only the
// UI state (mode, group, day) and asks for one finished page model per change.
import { HUB_DEFAULTS, HUB_GROUPS, HUB_LEAGUES, dayStamp, hubLeague } from "@/lib/sports/hub-data";
import { fetchHubSlice } from "@/lib/sports/hub-data";
import { cachedSportsSnapshot, eventCards, gameKey, loadSportsSlices, mergeSlices, type SportsSlice, type SportsSnapshot } from "@/lib/sports/hub-cache";
import { featuredEvents } from "@/lib/sports/hub-discovery";
import { HOT_EVENT_LEAGUES, hotEvents } from "@/lib/sports/hot-events";
import { currentLiveGames, liveDateRange, liveScoreboardKeys } from "@/lib/sports/live-schedule";
import { gamesInSportsSelection, selectedSportsLeagues, sportsSelectionScope } from "@/lib/sports/personalization";
import { getGroupLabel, getLeagueLabel } from "@/lib/sports/espn-leagues";
import { involvesTeam, readFavourites, writeFavourites, toggleFavouriteTeam, fetchLeagueTeams, teamCatalogStatus, teamCatalogIsPartial, type FavouriteTeam } from "@/lib/sports/favourites";
import { fetchGameSummary } from "@/lib/sports/provider";
import { matchCardContext, relativeCardStart } from "@/lib/sports/card-context";
import { formatSportsEventDate } from "@/lib/sports/event-date";
import { acceptSportsConsent, declineSportsConsent, getSportsConsentSnapshot } from "@/lib/sports/consent";
import { bpSportsForYouRows, bpSportsHotRows, bpSportsLeagueRows } from "@/views/big-picture/sports/bp-sports-rows";
import type { SportsGame } from "@/lib/sports/espn-types";
import { loadStoredSettings } from "@/lib/settings/load";
import { serializeSettings } from "@/lib/settings/profile-store";
import { readPlaylists } from "@/lib/iptv/playlists-store";
import { loadPlaylist } from "@/lib/iptv/store";
import { headersFromChannel } from "@/lib/iptv/channel-headers";
import { recordChannelPlay } from "@/lib/iptv/channel-stats";
import type { IptvChannel } from "@/lib/iptv/types";
import { buildSportsChannelIndex, matchChannelsForGameAsync, type ChannelMatch, type SportsChannelIndex } from "@/lib/sports/iptv-match";
import { watchProviders } from "@/lib/sports/watch-providers";
import { SPORTS_BROADCASTS } from "@/lib/sports/broadcasts";

export type Mode = "for-you" | "live" | "schedule" | "hot" | "explore";

const t = (key: string) => key;
const LIVE_SCOREBOARDS = liveScoreboardKeys(HUB_LEAGUES);
const HOT_LEAGUE_LIMIT = 24;
const UPCOMING_BROWSE_LIMIT = 16;

// ---------------------------------------------------------------------------- consent
export function consent() {
  return getSportsConsentSnapshot();
}
export function accept() { acceptSportsConsent(); return getSportsConsentSnapshot(); }
export function decline() { declineSportsConsent(); return getSportsConsentSnapshot(); }

// ---------------------------------------------------------------------------- catalog
export function catalog() {
  return {
    groups: HUB_GROUPS.map((g) => ({ key: g.key, label: getGroupLabel(g), icon: g.icon })),
    leagues: HUB_LEAGUES.map((l) => ({ key: l.key, tag: l.tag, group: l.group, label: getLeagueLabel(l), logo: l.logo })),
    defaults: HUB_DEFAULTS,
    selected: selected(),
    personalized: !!readFavourites().personalized || (loadStoredSettings().sportsLeagues ?? []).length > 0,
  };
}

function selected(): string[] {
  const s = loadStoredSettings();
  return selectedSportsLeagues(HUB_LEAGUES, s.sportsLeagues ?? [], !!readFavourites().personalized, HUB_DEFAULTS);
}

/** Personalize save (bp-sports-personalize.tsx:152-168): both stores, `personalized: true`. */
export function setLeagues(keys: string[], settingsKey = "harbor.settings"): string[] {
  const fav = readFavourites();
  const leagues = keys.filter((k) => HUB_LEAGUES.some((l) => l.key === k));
  writeFavourites({ ...fav, personalized: true, leagues });
  const s = { ...loadStoredSettings(settingsKey), sportsLeagues: leagues };
  localStorage.setItem(settingsKey, serializeSettings(s));
  return leagues;
}

export function toggleTeam(team: FavouriteTeam): boolean {
  return toggleFavouriteTeam(team);
}

// ------------------------------------------------------------------------------ feeds
// Memory cache of slices keyed `${league}@${day}@${mode}` with upstream's freshness rules.
const slices = new Map<string, SportsSlice>();
const readSlice = (key: string) => slices.get(key);
const saveSlice = (key: string, slice: SportsSlice) => { slices.set(key, slice); };

type FeedMode = "day" | "live" | "upcoming";
const inflight = new Map<string, Promise<void>>();
const EMPTY: SportsSnapshot = { games: [], at: 0, stale: false, failed: 0, failedKeys: [], pending: 0 };
const lastFailed = new Map<string, number>();

function notify(): void {
  window.dispatchEvent(new CustomEvent("harbor:sports-updated"));
}

/**
 * useSportsHub without React: the cached snapshot is returned at once; anything older than
 * `maxAge` refreshes in the background (one load per key set), and every landed slice
 * dispatches `harbor:sports-updated` so the host re-reads the page from cache.
 * `wait` blocks until the load finishes (tests, "Refresh").
 */
async function feed(keys: string[], mode: FeedMode, force: boolean, wait: boolean): Promise<SportsSnapshot> {
  if (keys.length === 0) return EMPTY;
  const maxAge = force ? 0 : mode === "upcoming" ? 15 * 60_000 : 15_000;
  const due = keys.some((k) => { const hit = readSlice(k); return !hit || Date.now() - hit.at >= maxAge; });
  const signature = keys.join(",") + "|" + mode;
  let running = inflight.get(signature);
  if (due && !running) {
    const controller = new AbortController();
    running = loadSportsSlices(keys, readSlice, (key) => fetchHubSlice(key, controller.signal), saveSlice, (snap) => {
      for (const k of snap.failedKeys) lastFailed.set(k, Date.now());
      notify();
    }, controller.signal, 5, maxAge).catch(() => {}).finally(() => { inflight.delete(signature); notify(); });
    inflight.set(signature, running);
  }
  if (wait && running) await running;
  const snap = cachedSportsSnapshot(keys, readSlice);
  const failedKeys = keys.filter((k) => { const at = lastFailed.get(k); const hit = readSlice(k); return at !== undefined && (!hit || hit.at < at); });
  return { ...snap, failed: failedKeys.length, failedKeys, pending: inflight.has(signature) ? keys.filter((k) => !readSlice(k)).length || 1 : 0 };
}

// ------------------------------------------------------------------------- page model
export type GameView = SportsGame & {
  key: string;
  leagueLabel: string;
  leagueLogo: string;
  group: string;
  /** BpSportsState text: "Saved" | live detail | "Final" | countdown | date. */
  statusText: string;
  live: boolean;
  /** Solo subject (motorsport/golf/individual): one mark + context name. */
  single: boolean;
  faceOff: boolean;
  headline: string;
  /** First non-start context row (stage/venue/broadcasts), else names, else the date. */
  quiet: string;
  startLabel: string;
};

function view(g: SportsGame, now: number, locale: string): GameView {
  const def = hubLeague(g.league);
  const live = g.state === "in";
  const dateLabel = formatSportsEventDate(g.startMs, locale, true, g.dateOnly) || "Time TBA";
  let statusText: string;
  if (g.savedAt !== undefined) statusText = "Saved";
  else if (live) statusText = g.detail || "Live";
  else if (g.state === "post") statusText = "Final";
  else if (g.dateOnly === undefined && g.startMs - now > 0 && g.startMs - now <= 90 * 60_000) statusText = relativeCardStart(g.startMs, locale, now);
  else statusText = dateLabel;
  const single = !g.home.name || !g.away.name;
  const group = def?.group ?? "";
  const faceOff = !single && (group === "combat" || group === "boxing");
  const headline = single ? (g.context?.name || g.home.name || g.away.name) : faceOff ? `${g.away.name} vs ${g.home.name}` : "";
  const rows = matchCardContext(g, now).filter((r) => r.kind !== "start");
  const quiet = rows.length ? String(rows[0].value) : single ? [g.home.name, g.away.name].filter(Boolean).join(" · ") : dateLabel;
  return { ...g, key: gameKey(g), leagueLabel: def ? getLeagueLabel(def) : g.league, leagueLogo: def?.logo ?? "", group, statusText, live, single, faceOff, headline, quiet, startLabel: dateLabel };
}

export type PageInput = { mode: Mode; group: string; day?: string; browsing?: boolean; force?: boolean; locale?: string; wait?: boolean };

/** One finished page: chips, heroes, rows, status (use-bp-sports.ts). */
export async function page(input: PageInput) {
  const now = Date.now();
  const locale = input.locale || "en";
  const today = dayStamp(new Date());
  const day = input.day || today;
  const mode = input.mode;
  const browsing = !!input.browsing;
  const fav = readFavourites();
  const sel = selected();
  const scope = sportsSelectionScope(HUB_LEAGUES, sel, input.group || "all", browsing, "");
  const { group, leagues } = scope;
  const groups = HUB_GROUPS.filter((g) => scope.groups.has(g.key) || (browsing && g.key === group)).map((g) => ({ key: g.key, label: getGroupLabel(g) }));
  const esportsLeagues = sel.filter((k) => HUB_LEAGUES.find((d) => d.key === k)?.group === "esports");

  const others = leagues.filter((k) => { const d = HUB_LEAGUES.find((x) => x.key === k); return d?.group !== "soccer" || /^\d+$/.test(d.path); });
  const soccer = group === "soccer" || (group === "all" && leagues.some((k) => HUB_LEAGUES.find((x) => x.key === k)?.group === "soccer"));
  const boardLeagues = mode === "live" ? LIVE_SCOREBOARDS : soccer ? ["SOCCER_ALL", ...others] : others;
  const boardDay = mode === "live" ? liveDateRange(today) : day;
  const boardOn = mode !== "hot" && mode !== "explore";
  const wait = !!input.wait;
  const boardFeed = boardOn ? await feed(boardLeagues.map((k) => `${k}@${boardDay}@${mode === "live" ? "live" : "day"}`), mode === "live" ? "live" : "day", !!input.force, wait) : EMPTY;
  const boardGames = mode === "live" ? boardFeed.games : gamesInSportsSelection(boardFeed.games, HUB_LEAGUES, leagues);
  const upcomingLeagues = browsing ? leagues.slice(0, UPCOMING_BROWSE_LIMIT) : leagues;
  const upcomingOn = mode !== "hot" && mode !== "live" && mode !== "explore";
  const upcomingFeed = upcomingOn ? await feed(upcomingLeagues.map((k) => `${k}@${today}@upcoming`), "upcoming", !!input.force, wait) : EMPTY;
  const upcomingGames = gamesInSportsSelection(upcomingFeed.games, HUB_LEAGUES, leagues);
  const all = mergeSlices([{ at: 1, games: upcomingGames }, { at: 2, games: boardGames }]);

  let hot: ReturnType<typeof hotEvents> = [];
  let hotFeed: SportsSnapshot = EMPTY;
  if (mode === "hot") {
    const hotLeagues = [...new Set([...HOT_EVENT_LEAGUES, ...fav.leagues])].slice(0, HOT_LEAGUE_LIMIT);
    hotFeed = await feed(hotLeagues.map((k) => `${k}@${today}@upcoming`), "upcoming", !!input.force, wait);
    const pool = mergeSlices([{ at: 1, games: all }, { at: 2, games: hotFeed.games }]);
    hot = hotEvents(pool, now, (game) => fav.teams.some((team) => involvesTeam(game, team)));
  }

  const live = boardGames.filter((g) => g.state === "in");
  const liveDays = [...new Set(live.map((g) => dayStamp(new Date(g.startMs))))];
  const next = eventCards(all.filter((g) => g.state === "pre" && g.startMs >= now));
  const filtered = group === "all" ? all : all.filter((g) => hubLeague(g.league)?.group === group);
  const coming = next.filter((g) => group === "all" ? sel.some((k) => HUB_LEAGUES.find((d) => d.key === k)?.tag === g.league) : hubLeague(g.league)?.group === group);
  const heroes = mode === "for-you" ? featuredEvents(live, group === "all" ? next : coming) : [];
  const dateTitle = new Date(+day.slice(0, 4), +day.slice(4, 6) - 1, +day.slice(6, 8)).toLocaleDateString(locale, { weekday: "long", month: "long", day: "numeric" });

  let rows;
  if (mode === "live") rows = bpSportsLeagueRows(currentLiveGames(boardGames), "live");
  else if (mode === "schedule") rows = bpSportsLeagueRows(eventCards(boardGames), "schedule");
  else if (mode === "hot") rows = bpSportsHotRows(hot, t);
  else if (mode === "explore") rows = [];
  else rows = bpSportsForYouRows({
    t, live,
    following: filtered.filter((g) => fav.teams.some((team) => involvesTeam(g, team))),
    coming,
    fights: next.filter((g) => ["combat", "boxing"].includes(hubLeague(g.league)?.group || "")),
    esports: all.filter((g) => hubLeague(g.league)?.group === "esports"),
    dayGames: eventCards(boardGames),
    pitchGame: boardGames.find((g) => g.state === "in" && hubLeague(g.league)?.group === "soccer") ?? boardGames.find((g) => g.state === "pre" && hubLeague(g.league)?.group === "soccer") ?? null,
    dateTitle, otherDay: day !== today,
    showFights: group === "all" || group === "combat" || group === "boxing",
    showEsports: group === "all" && esportsLeagues.length > 0,
  });
  rows = rows.filter((r) => r.games.length > 0);

  const busy = mode === "hot" ? hotFeed.pending > 0 : mode !== "explore" && (boardFeed.pending > 0 || (mode !== "live" && upcomingFeed.pending > 0));
  const failed = mode === "hot" ? hotFeed.failed > 0 : boardFeed.failed + (mode === "live" ? 0 : upcomingFeed.failed) > 0;
  const failedKeys = mode === "hot" ? hotFeed.failedKeys : [...boardFeed.failedKeys, ...(mode === "live" ? [] : upcomingFeed.failedKeys)];
  const stale = mode === "hot" ? hotFeed.stale : boardFeed.stale || (mode !== "live" && upcomingFeed.stale);
  const at = mode === "hot" ? hotFeed.at : boardFeed.at || (mode === "live" ? 0 : upcomingFeed.at);
  const personalized = !!fav.personalized || (loadStoredSettings().sportsLeagues ?? []).length > 0;
  // bp-sports.tsx:142-153 status note.
  // bp-sports.tsx:141-149: one label per league, "Soccer" for the aggregate board.
  const failedLabels = [...new Set(failedKeys.map((k) => k.split("@")[0]))].map((k) => (k === "SOCCER_ALL" ? "Soccer" : hubLeague(k) ? getLeagueLabel(hubLeague(k)!) : k));
  const note = busy ? null : stale ? "Showing saved schedules while feeds reconnect."
    : failed ? `Some feeds did not respond. Available events are still shown. (${failedLabels.slice(0, 3).join(", ")}${failedLabels.length > 3 ? ` +${failedLabels.length - 3}` : ""})`
    : null;

  return {
    mode, group, groups, showGroups: mode === "for-you" || mode === "schedule",
    day, today, liveDays, dateTitle,
    heroes: heroes.map((g) => view(g, now, locale)),
    rows: rows.map((r) => ({ key: r.key, title: r.title, description: r.description ?? null, games: r.games.map((g) => view(g, now, locale)) })),
    status: { busy, failed, failedKeys, stale, at, note },
    empty: (mode === "for-you" && filtered.length === 0) || (mode !== "for-you" && mode !== "explore" && !busy && rows.length === 0),
    personalized,
    explore: HUB_GROUPS.map((g) => ({ key: g.key, label: getGroupLabel(g), icon: g.icon })),
  };
}

/** Day strip for schedule mode: 3 days back, 10 ahead (date-band). */
export function days(anchor?: string): Array<{ key: string; label: string; today: boolean }> {
  const base = anchor ? new Date(+anchor.slice(0, 4), +anchor.slice(4, 6) - 1, +anchor.slice(6, 8)) : new Date();
  const today = dayStamp(new Date());
  const out: Array<{ key: string; label: string; today: boolean }> = [];
  for (let i = -3; i <= 10; i++) {
    const d = new Date(base); d.setDate(base.getDate() + i);
    const key = dayStamp(d);
    out.push({ key, label: key === today ? "Today" : d.toLocaleDateString("en", { weekday: "short" }), today: key === today });
  }
  return out;
}

/** Game detail (espn summary and provider branches), 25 s cache like use-match-detail.ts. */
const detailCache = new Map<string, { at: number; value: unknown }>();
export async function detail(game: SportsGame): Promise<unknown> {
  const key = gameKey(game);
  const hit = detailCache.get(key);
  if (hit && Date.now() - hit.at < 25_000) return hit.value;
  const value = await fetchGameSummary(game);
  detailCache.set(key, { at: Date.now(), value });
  return value;
}

// ------------------------------------------------------------------------------ watch
// bp-sports-watch.tsx plan, minus embedded web players: attached streams and official
// Twitch/YouTube broadcasts are listed as information, Live TV channels are playable.
const ATTACH_KEY = "harbor.sports.sources.v1";
type Attachments = { channels: Record<string, string[]>; streams: Record<string, { url: string; kind: string; headers?: Record<string, string>; page: string; title: string; poster: string }> };

function readAttachments(): Attachments {
  try {
    const raw = JSON.parse(localStorage.getItem(ATTACH_KEY) ?? "{}") as Record<string, unknown>;
    if ("channels" in raw || "streams" in raw) return { channels: (raw.channels as Attachments["channels"]) ?? {}, streams: (raw.streams as Attachments["streams"]) ?? {} };
    return { channels: raw as Attachments["channels"], streams: {} };
  } catch {
    return { channels: {}, streams: {} };
  }
}

export function toggleAttachedChannel(leagueTag: string, channelId: string): boolean {
  const a = readAttachments();
  const current = a.channels[leagueTag] ?? [];
  const on = !current.includes(channelId);
  const kept = on ? [...current, channelId] : current.filter((id) => id !== channelId);
  const channels = { ...a.channels };
  if (kept.length) channels[leagueTag] = kept; else delete channels[leagueTag];
  localStorage.setItem(ATTACH_KEY, JSON.stringify({ channels, streams: a.streams }));
  return on;
}

let indexCache: { signature: string; index: SportsChannelIndex; channels: IptvChannel[] } | null = null;

/** watch-sources.tsx useSportsChannelIndex: every non-EPG playlist, flattened, sports-filtered. */
async function channelIndex(): Promise<{ index: SportsChannelIndex; channels: IptvChannel[]; sources: number }> {
  const sources = readPlaylists().filter((p) => p.kind !== "epg");
  const signature = sources.map((p) => p.id + ":" + p.url).join("|");
  const lists = await Promise.allSettled(sources.map((src) => loadPlaylist(src)));
  const channels: IptvChannel[] = [];
  let stamp = "";
  for (const r of lists) if (r.status === "fulfilled") { channels.push(...r.value.channels); stamp += `${r.value.fetchedAt ?? 0}:${r.value.channels.length}|`; }
  // A re-fetched playlist with the same url but new channels must rebuild (watch-sources.tsx flatten keys on fetchedAt).
  const full = signature + "#" + stamp;
  if (indexCache && indexCache.signature === full) return { ...indexCache, sources: sources.length };
  const index = buildSportsChannelIndex(channels);
  indexCache = { signature: full, index, channels };
  return { index, channels, sources: sources.length };
}

export type WatchOption = {
  channelId: string; name: string; logo: string | null; url: string; headers: Record<string, string> | null;
  tier: string; attached: boolean; label: string; copy: string; reasons: string[]; score: number;
};

function tierCopy(m: ChannelMatch): string {
  return m.attached ? "Your pick for this competition"
    : m.reasons.some((r) => r.kind === "event") ? "Event matchup found"
    : m.tier === "exact" ? "Strong match"
    : m.tier === "likely" ? "Likely match · check the broadcast"
    : "Possible match · check the broadcast";
}

/**
 * Everything the Watch press can do for one game: `plan` is "channel" (an exact match, play
 * it), "picker" (weaker matches), "setup" (no Live TV source), or "finished".
 */
export async function watch(game: SportsGame): Promise<{
  plan: "channel" | "picker" | "setup" | "finished";
  fixture: string;
  channels: WatchOption[];
  providers: Array<{ name: string; url: string; logo: string }>;
  broadcasts: Array<{ title: string; competition: string; channel: string; source: string }>;
  attachedStream: { url: string; title: string; page: string } | null;
  sources: number;
  scanned: number;
}> {
  const fixture = game.away.name ? `${game.away.name} v ${game.home.name}` : game.context?.name || game.home.name;
  const attachments = readAttachments();
  const { index, sources } = await channelIndex();
  const attachedIds = attachments.channels[game.league] ?? [];
  const matches = sources > 0 ? await matchChannelsForGameAsync(game, index, { attachedIds, broadcastNames: game.broadcasts ?? [], limit: 8 }) : [];
  const channels: WatchOption[] = matches.map((m) => ({
    channelId: m.channel.id, name: m.channel.name, logo: m.channel.logo, url: m.channel.url, headers: headersFromChannel(m.channel) ?? null,
    tier: m.tier, attached: m.attached, label: m.label, copy: tierCopy(m), reasons: m.reasons.map((r) => r.label), score: m.score,
  }));
  const stream = attachments.streams[game.id] ?? null;
  const plan = game.state === "post" ? "finished" : sources === 0 ? "setup" : channels.length > 0 && channels[0].tier === "exact" ? "channel" : "picker";
  return {
    plan, fixture, channels,
    providers: watchProviders(game).map((p) => ({ name: p.name, url: p.url, logo: p.logo })),
    broadcasts: SPORTS_BROADCASTS.filter((b) => b.league === game.league).map((b) => ({ title: b.title, competition: b.competition, channel: b.channel, source: b.source })),
    attachedStream: stream ? { url: stream.url, title: stream.title, page: stream.page } : null,
    sources, scanned: index.scanned,
  };
}

/** Tuning a matched channel counts toward Live TV's "most watched" band too. */
export function recordChannelWatch(channelId: string): void {
  const ch = indexCache?.channels.find((c) => c.id === channelId);
  if (ch) recordChannelPlay(ch);
}


// ---------------------------------------------------------------- standings + artwork
import { fetchStandings as fetchStandingsUpstream, type StandingsTable } from "@/lib/sports/standings";
import { fetchSportsArtwork, cachedArtwork, type SportsArtwork } from "@/lib/sports/hub-artwork";
/** bp-sports-event-rows BpSportsStandingsRow: the league table for a game's league. */
export function standings(leagueTag: string): Promise<StandingsTable | null> {
  return fetchStandingsUpstream(leagueTag).catch(() => null);
}
/** lib/sports/hub-artwork: TheSportsDB backdrop/poster/team art for a card or hero with none of its own. */
export async function artwork(game: SportsGame): Promise<SportsArtwork> {
  const held = cachedArtwork(game);
  if (held.backdrop || held.poster) return held;
  return Promise.race([fetchSportsArtwork(game).catch(() => held), new Promise<SportsArtwork>((r) => setTimeout(() => r(held), 6000))]);
}


// ------------------------------------------------------------ personalize step 3: teams
// bp-sports-personalize.tsx: leagues organised by team (not by event) offer a team list; picks
// go straight into the favourites store (toggleTeam) and feed the "Your teams" row.
const EVENT_GROUPS = new Set(["combat", "boxing", "esports", "motorsport", "golf", "tennis"]);
export function teamLeagues(keys: string[]): Array<{ key: string; label: string; group: string }> {
  return HUB_LEAGUES.filter((l) => keys.includes(l.key) && !EVENT_GROUPS.has(l.group)).map((l) => ({ key: l.key, label: getLeagueLabel(l), group: l.group }));
}
export async function teams(leagueKey: string, force = false): Promise<{ status: string; partial: boolean; teams: FavouriteTeam[]; followed: string[] }> {
  const list = await Promise.race([fetchLeagueTeams(leagueKey, { force }).catch(() => [] as FavouriteTeam[]), new Promise<FavouriteTeam[]>((r) => setTimeout(() => r([]), 10000))]);
  const fav = readFavourites();
  return {
    status: String(teamCatalogStatus(leagueKey)), partial: teamCatalogIsPartial(leagueKey),
    teams: list.map((t) => ({ id: t.id, leagueKey: t.leagueKey, group: t.group, name: t.name, abbr: t.abbr, logo: t.logo })),
    followed: fav.teams.filter((t) => t.leagueKey === leagueKey).map((t) => t.id),
  };
}
export function favouriteTeams(): FavouriteTeam[] { return readFavourites().teams; }
