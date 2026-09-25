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
import { MIRROR_KEY, loadEffective, persistEffective, serializeSettings } from "@/lib/settings/profile-store";
import type { Settings } from "@/lib/settings/types";
import { markSettingsPatched } from "./sync";
import { readPlaylists } from "@/lib/iptv/playlists-store";
import { loadPlaylist } from "@/lib/iptv/store";
import { headersFromChannel } from "@/lib/iptv/channel-headers";
import { recordChannelPlay } from "@/lib/iptv/channel-stats";
import type { IptvChannel } from "@/lib/iptv/types";
import { buildSportsChannelIndex, leagueForTag, matchChannelsForGameAsync, searchSportsChannels, type ChannelMatch, type SportsChannelIndex } from "@/lib/sports/iptv-match";
import { watchProviders } from "@/lib/sports/watch-providers";
import { SPORTS_BROADCASTS } from "@/lib/sports/broadcasts";
import { syncSportsReminders } from "@/lib/sports/reminders";

export type Mode = "for-you" | "live" | "schedule" | "hot" | "explore";

// lib/i18n t(): English until the host installs the chosen catalog (settingsRoom.installUiCatalog).
import { t } from "@/lib/i18n";
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

/**
 * Personalize save (bp-sports-personalize.tsx:152-168): both stores, `personalized: true`.
 * The settings half is upstream's `update({ sportsLeagues })`: the active profile's source key and
 * the `harbor.settings` mirror (persistEffective), marked for profile sync. Writing the mirror
 * alone was undone by the next settings.activate (every profile switch, launch and
 * harbor:settings-updated rewrites the mirror from the source key), so the picks reverted.
 */
export function setLeagues(keys: string[], profileId?: string | null, linked?: boolean | null): string[] {
  const fav = readFavourites();
  const leagues = keys.filter((k) => HUB_LEAGUES.some((l) => l.key === k));
  writeFavourites({ ...fav, personalized: true, leagues });
  if (typeof profileId === "string" && profileId) {
    const l = linked !== false;
    persistEffective({ ...loadEffective(profileId, l), sportsLeagues: leagues } as Settings, profileId, l);
  } else {
    const s = { ...loadStoredSettings(MIRROR_KEY), sportsLeagues: leagues };
    localStorage.setItem(MIRROR_KEY, serializeSettings(s));
  }
  markSettingsPatched(["sportsLeagues"]);
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
/** use-hub sportsApiRevision: a changed api-sports key must refetch those leagues, so their cached slices go. */
export function forgetSlices(leagueKeys: string[]): void {
  for (const key of [...slices.keys()]) if (leagueKeys.includes(key.split("@")[0])) slices.delete(key);
}

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
  // (bug pass) A feed that failed has no newer slice, so it read as due on the very next call —
  // and every load ends in `harbor:sports-updated`, which makes the host read the page again.
  // Offline (or with one league's feed erroring) that was a load every few hundred ms for as long
  // as the room stayed open. use-hub.ts retries on its interval (60 s, 15 min for upcoming): a
  // key that failed within that window waits for it, unless the viewer forces a refresh.
  const retryAfter = mode === "upcoming" ? 15 * 60_000 : 60_000;
  const now = Date.now();
  const due = keys.some((k) => {
    const hit = readSlice(k);
    if (hit && now - hit.at < maxAge) return false;
    const failedAt = lastFailed.get(k);
    if (!force && failedAt !== undefined && now - failedAt < retryAfter && (!hit || hit.at < failedAt)) return false;
    return true;
  });
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
  // use-bp-sports.ts:157: a reminder follows its game's published start time.
  syncSportsReminders(all);

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
  // (device-flow pass) Through t() and in upstream's shape ("… · NBA, NHL +2"): the English text
  // with the names in brackets was no catalog key, so the note never translated.
  const brokenNames = failedLabels.slice(0, 3).join(", ") + (failedLabels.length > 3 ? ` +${failedLabels.length - 3}` : "");
  const note = busy ? null : stale ? t("Showing saved schedules while feeds reconnect.")
    : failed ? `${t("Some feeds did not respond. Available events are still shown.")}${brokenNames ? ` · ${brokenNames}` : ""}`
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

/**
 * Day strip for schedule mode: date-bar.tsx buildDays, 7 days back and 7 ahead. Each cell is a
 * weekday over the day of the month like bp-sports-date-band.tsx (the weekday alone left two
 * "Mon" cells nobody could tell apart). Weekdays in Harbor's UI language (`toLocaleDateString(lang,
 * …)`); "Today" stays the English source string, which Swift translates.
 */
export function days(anchor?: string | null, locale?: string | null): Array<{ key: string; label: string; number: number; today: boolean }> {
  const lang = locale || "en";
  const base = anchor ? new Date(+anchor.slice(0, 4), +anchor.slice(4, 6) - 1, +anchor.slice(6, 8)) : new Date();
  const today = dayStamp(new Date());
  const out: Array<{ key: string; label: string; number: number; today: boolean }> = [];
  for (let i = -7; i <= 7; i++) {
    const d = new Date(base.getFullYear(), base.getMonth(), base.getDate() + i);
    const key = dayStamp(d);
    out.push({ key, label: key === today ? "Today" : weekdayShort(d, lang), number: d.getDate(), today: key === today });
  }
  return out;
}

function weekdayShort(d: Date, lang: string): string {
  try {
    return d.toLocaleDateString(lang, { weekday: "short" });
  } catch {
    return d.toLocaleDateString("en", { weekday: "short" });
  }
}

/**
 * Game detail (espn summary and provider branches), 25 s cache like use-match-detail.ts. Only a
 * summary is kept (use-match-detail load: `if (detail) cache.set`, at most 24): a failed fetch was
 * cached as null, so the event page's Try again said "not available" again for 25 s.
 */
const detailCache = new Map<string, { at: number; value: unknown }>();
export async function detail(game: SportsGame): Promise<unknown> {
  const key = gameKey(game);
  const hit = detailCache.get(key);
  if (hit && Date.now() - hit.at < 25_000) return hit.value;
  const value = await fetchGameSummary(game);
  if (value) {
    detailCache.set(key, { at: Date.now(), value });
    if (detailCache.size > 24) detailCache.delete(detailCache.keys().next().value!);
  }
  return value;
}

// ------------------------------------------------------------------------------ watch
// bp-sports-watch.tsx plan: an attached stream plays directly, official broadcasts open the
// broadcast list (bp-sports-broadcast-source), Live TV channels are playable, then addons,
// picker, setup.
const ATTACH_KEY = "harbor.sports.sources.v1";
type AttachedStream = { url: string; kind: string; headers?: Record<string, string>; page: string; title: string; poster: string };
type Attachments = { channels: Record<string, string[]>; streams: Record<string, AttachedStream> };

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

/**
 * source-store setAttachedStream(gameId, null): bp-sports-watch `pick` / `playSearched` drop a
 * game's attached stream when a channel is chosen instead. Big Picture never attaches a stream
 * (only the desktop watch-sources panel does, watch-sources.tsx:338), so clearing is the only
 * write the TV makes to `Attachments.streams`.
 */
export function clearAttachedStream(gameId: string): boolean {
  const a = readAttachments();
  if (!(gameId in a.streams)) return false;
  const streams = { ...a.streams };
  delete streams[gameId];
  localStorage.setItem(ATTACH_KEY, JSON.stringify({ channels: a.channels, streams }));
  return true;
}

// bp-sports-broadcast-source.ts: organizer channels + the esports game's catalog broadcasts, and
// the live feed's streams for this exact match when an esports feed has it.
import { esportsGame } from "@/lib/sports/esports-catalog";
import { fetchEsportsFeed, type EsportsGameId, type EsportsMatch } from "@/lib/sports/esports-feeds";
import { esportsEmbedUrl, esportsExternalUrl, type EsportsStream } from "@/lib/sports/esports-streams";

const LEAGUE_GAMES: Record<string, EsportsGameId> = {
  DOTA2: "dota2", DOTA: "dota2", TI: "dota2", LCK: "lol", LEC: "lol", LPL: "lol", LCS: "lol", LTA: "lol", MSI: "lol", WORLDS: "lol",
  RLCS: "rocketleague", VCT: "valorant", VALORANT: "valorant", CS: "cs2", CS2: "cs2", IEM: "cs2", BLAST: "cs2", ESL: "cs2",
};
const NEAR_MS = 3 * 60 * 60_000;
function bpEsportsGameId(league: string, source?: string): EsportsGameId | null {
  if (source === "opendota") return "dota2";
  return LEAGUE_GAMES[(league || "").toUpperCase()] ?? null;
}
const normalizeName = (value: string) => value.toLowerCase().replace(/[^a-z0-9]+/g, "");
function sameTeam(a: string, b: string): boolean {
  const left = normalizeName(a), right = normalizeName(b);
  if (left.length < 3 || right.length < 3) return false;
  return left === right || left.includes(right) || right.includes(left);
}
function feedMatchFor(matches: EsportsMatch[], game: SportsGame): EsportsMatch | null {
  const names = [game.home.name, game.away.name].filter(Boolean);
  if (names.length === 0) return null;
  let loose: EsportsMatch | null = null;
  for (const match of matches) {
    const hits = match.teams.filter((team) => names.some((name) => sameTeam(team.name, name))).length;
    if (hits === 0) continue;
    const near = !Number.isFinite(game.startMs) || Math.abs(match.startMs - game.startMs) <= NEAR_MS;
    if (!near) continue;
    if (hits >= 2) return match;
    if (!loose) loose = match;
  }
  return loose;
}
function playableStreams(streams: readonly EsportsStream[]): EsportsStream[] {
  const seen = new Set<string>();
  const out: EsportsStream[] = [];
  for (const stream of streams) {
    const url = esportsExternalUrl(stream.url);
    if (!url || seen.has(url) || !stream.title) continue;
    seen.add(url);
    out.push({ ...stream, url });
  }
  return out;
}
function catalogBroadcasts(league: string, source?: string): EsportsStream[] {
  const id = bpEsportsGameId(league, source);
  const def = id ? esportsGame(id) : undefined;
  const organizer = SPORTS_BROADCASTS.filter((item) => item.league && item.league === league).map<EsportsStream>((item) => ({
    title: `${item.title} · ${item.competition}`, url: `https://www.twitch.tv/${item.channel}`, platform: "twitch",
  }));
  return playableStreams([...organizer, ...(def?.broadcasts ?? [])]);
}

/**
 * One official broadcast as the TV can use it. Upstream embeds the Twitch/YouTube/Kick public
 * player in an iframe (bp-sports-broadcast-stage + esportsEmbedUrl) and never extracts the
 * provider's HLS, so neither does the port: tvOS has no web view, so the TV opens the provider's
 * own Apple TV app when it answers a URL scheme (`app`: Twitch, YouTube) and otherwise hands the
 * page to the phone (`url`, shown as a QR code; Kick has no Apple TV app).
 */
export type BroadcastView = { title: string; url: string; platform: string; platformLabel: string; app: string | null };
const PLATFORM_LABELS: Record<string, string> = { twitch: "Twitch", youtube: "YouTube", kick: "Kick", external: "" };
export function broadcastView(stream: EsportsStream): BroadcastView {
  let app: string | null = null;
  const embed = esportsEmbedUrl(stream, "localhost");
  if (embed && stream.platform === "twitch") {
    const channel = new URL(embed).searchParams.get("channel");
    if (channel) app = `twitch://stream/${channel}`;
  } else if (embed && stream.platform === "youtube") {
    const id = embed.match(/\/embed\/([a-zA-Z0-9_-]{11})/)?.[1];
    if (id) app = `youtube://watch/${id}`;
  }
  return { title: stream.title, url: stream.url, platform: stream.platform, platformLabel: PLATFORM_LABELS[stream.platform] || "Official broadcast", app };
}

const feedHeld = new Map<string, { at: number; list: EsportsStream[] }>();
/** useBpOfficialBroadcasts: this match's feed streams first (`onAir`), then the catalog. */
export async function officialBroadcasts(game: SportsGame): Promise<{ list: BroadcastView[]; onAir: boolean }> {
  const catalogList = catalogBroadcasts(game.league, game.source);
  const kind = bpEsportsGameId(game.league, game.source);
  let feedList: EsportsStream[] = [];
  if (kind) {
    const key = `${kind}:${game.id}`;
    const hit = feedHeld.get(key);
    if (hit && Date.now() - hit.at < 60_000) feedList = hit.list;
    else {
      const controller = new AbortController();
      const timer = setTimeout(() => controller.abort(), 6000);
      try {
        const result = await fetchEsportsFeed(kind, { signal: controller.signal });
        feedList = playableStreams(feedMatchFor(result.matches, game)?.streams ?? []);
        feedHeld.set(key, { at: Date.now(), list: feedList });
      } catch {
        feedList = [];
      } finally {
        clearTimeout(timer);
      }
    }
  }
  return { list: playableStreams([...feedList, ...catalogList]).map(broadcastView), onAir: feedList.length > 0 };
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
 * Everything the Watch press can do for one game, in bp-sports-watch.tsx's plan order:
 * "stream" (an attached stream plays), "broadcast" (official broadcasts, the list opens),
 * "channel" (an exact or pinned match plays), "addons" (an addon listing matches, or it is the
 * only thing on offer), "picker" (weaker matches), "setup" (no Live TV source), or "finished".
 * `addons` is the summary of `addonSources` once it has loaded (bp-sports-watch waits on neither).
 */
export async function watch(game: SportsGame, addons?: { matched: number; available: number } | null): Promise<{
  plan: "stream" | "broadcast" | "channel" | "addons" | "picker" | "setup" | "finished";
  label: string;
  fixture: string;
  channels: WatchOption[];
  providers: Array<{ name: string; url: string; logo: string }>;
  broadcasts: BroadcastView[];
  onAir: boolean;
  attachedStream: { url: string; title: string; page: string; kind: string; headers: Record<string, string> | null; poster: string } | null;
  sources: number;
  scanned: number;
  /** bp-sports-broadcast-picker: canSearch (index.channels.length > 0), the league's pins and label. */
  searchable: boolean;
  attachedIds: string[];
  leagueLabel: string;
}> {
  const fixture = game.away.name ? `${game.away.name} v ${game.home.name}` : game.context?.name || game.home.name;
  const attachments = readAttachments();
  const [{ index, sources }, shows] = await Promise.all([channelIndex(), officialBroadcasts(game)]);
  const attachedIds = attachments.channels[game.league] ?? [];
  const matches = sources > 0 ? await matchChannelsForGameAsync(game, index, { attachedIds, broadcastNames: game.broadcasts ?? [], limit: 8 }) : [];
  const channels: WatchOption[] = matches.map((m) => ({
    channelId: m.channel.id, name: m.channel.name, logo: m.channel.logo, url: m.channel.url, headers: headersFromChannel(m.channel) ?? null,
    tier: m.tier, attached: m.attached, label: m.label, copy: tierCopy(m), reasons: m.reasons.map((r) => r.label), score: m.score,
  }));
  const stream = attachments.streams[game.id] ?? null;
  const selected = channels.some((c) => c.tier === "exact" || c.attached);
  if (selected) channels.sort((a, b) => Number(b.tier === "exact" || b.attached) - Number(a.tier === "exact" || a.attached));
  const matchedAddon = (addons?.matched ?? 0) > 0, anyAddon = (addons?.available ?? 0) > 0;
  const plan = game.state === "post" ? "finished"
    : stream ? "stream"
    : shows.list.length > 0 ? "broadcast"
    : selected ? "channel"
    : matchedAddon ? "addons"
    : sources > 0 && channels.length > 0 ? "picker"
    : anyAddon ? "addons"
    : sources > 0 ? "picker"
    : "setup";
  // bp-sports-watch.tsx copy.
  const pickCount = shows.list.length + channels.length + (stream ? 1 : 0);
  const label = plan === "finished" ? "Game finished"
    : plan === "stream" ? "Watch"
    : plan === "broadcast" ? (pickCount > 1 ? "Where to watch" : "Watch the broadcast")
    : plan === "channel" ? (game.state === "pre" ? "Preview channel" : "Watch")
    : plan === "addons" ? "Addon sources"
    : plan === "picker" ? (channels.length > 0 ? "Choose a channel" : "No channel found")
    : "Set up Live TV";
  return {
    plan, label, fixture, channels,
    providers: watchProviders(game).map((p) => ({ name: p.name, url: p.url, logo: p.logo })),
    broadcasts: shows.list, onAir: shows.onAir,
    attachedStream: stream ? {
      url: stream.url, title: stream.title ?? "", page: stream.page ?? "", kind: stream.kind ?? "hls",
      headers: stream.headers && Object.keys(stream.headers).length ? stream.headers : null, poster: stream.poster ?? "",
    } : null,
    sources, scanned: index.scanned,
    searchable: index.channels.length > 0, attachedIds: [...attachedIds], leagueLabel: pickerLeagueLabel(game.league),
  };
}

/** bp-sports-broadcast-picker leagueLabel: leagueForTag(league) → getLeagueLabel, else the tag. */
function pickerLeagueLabel(league: string): string {
  if (!league) return "";
  const def = leagueForTag(league);
  return def ? getLeagueLabel(def) : league;
}

/**
 * bp-sports-broadcast-search.tsx: searchSportsChannels(index, query, 30) over the same index the
 * picker matches against (every non-EPG playlist, sports-filtered), with the league's pins so the
 * Pin square reads pressed. An empty query lists the first channels, as upstream's does.
 */
export type ChannelSearchRow = { channelId: string; name: string; logo: string | null; group: string | null; url: string; headers: Record<string, string> | null; attached: boolean };
export async function searchChannels(query: string, leagueTag: string, limit = 30): Promise<{ searchable: boolean; league: string; leagueLabel: string; attachedIds: string[]; rows: ChannelSearchRow[] }> {
  const { index } = await channelIndex();
  const league = typeof leagueTag === "string" ? leagueTag : "";
  const attachedIds = league ? (readAttachments().channels[league] ?? []) : [];
  const attached = new Set(attachedIds);
  const rows = searchSportsChannels(index, typeof query === "string" ? query : "", limit).map((p) => ({
    channelId: p.channel.id, name: p.channel.name, logo: p.channel.logo || null, group: p.channel.group || null,
    url: p.channel.url, headers: headersFromChannel(p.channel) ?? null, attached: attached.has(p.channel.id),
  }));
  return { searchable: index.channels.length > 0, league, leagueLabel: pickerLeagueLabel(league), attachedIds: [...attachedIds], rows };
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


// ------------------------------------------------------------------- "who" panel
// bp-sports-who-panel: a team or athlete bio for one side of a game (bp-sports-who-subject
// picks which; team-profile / athlete-identity fetch it).
import { bpSportsWhoSubject, bpSportsWhoPlayerSubject, type BpSportsWhoSubject } from "@/views/big-picture/sports/bp-sports-who-subject";
import { bpSportsGroup, bpSportsSingleSubject, bpSportsCardArt } from "@/views/big-picture/sports/bp-sports-art";
import { fetchTeamProfile } from "@/lib/sports/team-profile";
import { fetchSportsDbAthleteBio, parseEspnAthleteBio } from "@/lib/sports/athlete-identity";
import { safeFetch as whoFetch } from "@/lib/safe-fetch";
export type WhoView = {
  kind: "team" | "athlete"; key: string; name: string; art: string; eyebrow: string; lead: string; body: string; note: string;
  figures: Array<{ name: string; value: string }>; facts: Array<{ label: string; value: string }>;
  link: { label: string; url: string } | null;
  roster: Array<{ id: string; name: string; image: string | null; position: string | null; jersey: string | null; source: string }>;
};
const WHO_TIMEOUT = 12000;
const WHO_LOUD = /record|rank|standing|points|wins|titles|championships/i;
function whoText(v: unknown): string { return typeof v === "string" ? v.trim().slice(0, 120) : typeof v === "number" && Number.isFinite(v) ? String(v) : ""; }

async function whoView(subject: BpSportsWhoSubject): Promise<WhoView> {
  const base = { key: subject.key, name: subject.name, art: subject.art, figures: [] as WhoView["figures"], facts: [] as WhoView["facts"], link: null as WhoView["link"], roster: [] as WhoView["roster"], body: "", note: "" };
  if (subject.kind === "team") {
    const data = await Promise.race([fetchTeamProfile(subject.identity).catch(() => null), new Promise<null>((r) => setTimeout(() => r(null), WHO_TIMEOUT))]);
    if (!data) return { ...base, kind: "team", eyebrow: "Team profile", lead: "", note: "Profile details could not be loaded." };
    const loud = data.facts.filter((f) => WHO_LOUD.test(f.label) && f.value.length <= 14).slice(0, 4);
    const link = data.links?.find((l) => l.label === "Official website") ?? data.links?.[0] ?? null;
    return {
      ...base, kind: "team", eyebrow: "Team profile", art: data.logo || subject.art,
      lead: data.facts.filter((f) => /standing|league|conference|division/i.test(f.label)).map((f) => f.value).join(" · "),
      figures: loud.map((f) => ({ name: f.label, value: f.value })),
      facts: data.facts.filter((f) => !loud.includes(f)).slice(0, 8),
      body: data.description ?? "",
      note: data.partial ? "Detailed statistics could not be loaded." : "",
      link: link ? { label: link.label, url: link.url } : null,
      roster: data.roster.slice(0, 40).map((p) => ({ id: p.id, name: p.name, image: p.image ?? null, position: p.position ?? null, jersey: p.jersey ?? null, source: p.source })),
    };
  }
  const person = subject.person;
  const espn = person.source === "espn" && /^\d+$/.test(person.id) && person.path.includes("/");
  const db = person.source === "thesportsdb" && /^\d{1,15}$/.test(person.id);
  const facts = person.profile ? ([["Height", person.profile.height], ["Weight", person.profile.weight], ["Reach", person.profile.reach], ["Stance", person.profile.stance], ["Age", person.profile.age]] as Array<[string, string]>).filter(([, v]) => !!v).map(([label, value]) => ({ label, value })) : [];
  if (!espn && !db) return { ...base, kind: "athlete", eyebrow: "Athlete profile", lead: "", facts, note: facts.length === 0 ? "Profile details could not be loaded." : "" };
  try {
    if (db) {
      const bio = await Promise.race([fetchSportsDbAthleteBio(person.id, person.group, new AbortController().signal), new Promise<null>((r) => setTimeout(() => r(null), WHO_TIMEOUT))]);
      return { ...base, kind: "athlete", eyebrow: "Athlete profile", art: bio?.image || subject.art, lead: [bio?.team?.name ?? "", ...(bio?.bio ?? [])].filter(Boolean).join(" · "), facts,
        note: bio ? "Athlete information supplied by TheSportsDB. Statistics may not be available." : "Profile details could not be loaded.",
        link: bio?.recordUrl ? { label: "View profile on TheSportsDB", url: bio.recordUrl } : null };
    }
    const res = await Promise.race([whoFetch(`https://site.web.api.espn.com/apis/common/v3/sports/${person.path}/athletes/${person.id}`), new Promise<null>((r) => setTimeout(() => r(null), WHO_TIMEOUT))]);
    if (!res || res.status === 404) return { ...base, kind: "athlete", eyebrow: "Athlete profile", lead: "", facts, note: "Profile details could not be loaded." };
    if (!res.ok) throw new Error("Athlete profile unavailable");
    const raw = (await res.json()) as Record<string, unknown>;
    const bio = parseEspnAthleteBio(raw, person.id);
    const block = ((raw.athlete as Record<string, unknown> | undefined)?.statsSummary ?? {}) as Record<string, unknown>;
    const figures = (Array.isArray(block.statistics) ? (block.statistics as Array<Record<string, unknown>>) : []).map((st) => ({ name: whoText(st.displayName) || whoText(st.name), value: whoText(st.displayValue) || whoText(st.value) })).filter((st) => st.name && st.value).slice(0, 6);
    return { ...base, kind: "athlete", eyebrow: "Athlete profile", art: bio?.image || subject.art, lead: [bio?.team?.name ?? "", ...(bio?.bio ?? [])].filter(Boolean).join(" · "), figures, facts,
      note: figures.length === 0 ? "Detailed statistics are not provided for this athlete yet." : "", link: bio?.recordUrl ? { label: "View full record on ESPN", url: bio.recordUrl } : null };
  } catch {
    return { ...base, kind: "athlete", eyebrow: "Athlete profile", lead: "", facts, note: "Statistics could not be loaded. Please try again." };
  }
}

export async function who(game: SportsGame, which: "home" | "away"): Promise<WhoView | null> {
  const side = which === "home" ? game.home : game.away;
  const league = hubLeague(game.league);
  const subject = bpSportsWhoSubject({ side, art: bpSportsCardArt(game) ?? "", league, leagueTag: game.league, group: bpSportsGroup(game), individual: bpSportsSingleSubject(game), source: game.source, profile: undefined });
  return subject ? whoView(subject) : null;
}

/** bp-sports-event-hero whoOf: which sides have a profile subject (only those sides are buttons). */
export function whoSides(game: SportsGame): { home: boolean; away: boolean } {
  const league = hubLeague(game.league);
  const has = (which: "home" | "away") => bpSportsWhoSubject({ side: which === "home" ? game.home : game.away, art: bpSportsCardArt(game) ?? "", league, leagueTag: game.league, group: bpSportsGroup(game), individual: bpSportsSingleSubject(game), source: game.source, profile: undefined }) !== null;
  return { home: has("home"), away: has("away") };
}

/** A roster player from a team panel opens as an athlete. */
export async function whoPlayer(leagueTag: string, player: { id: string; name: string; image?: string | null; source: "espn" | "thesportsdb" }): Promise<WhoView | null> {
  const subject = bpSportsWhoPlayerSubject({ id: player.id, name: player.name, image: player.image ?? undefined, source: player.source }, hubLeague(leagueTag), leagueTag);
  return subject ? whoView(subject) : null;
}


// ---------------------------------------------------------------- addon sources (SP-3)
// bp-sports-addon-sources / -play: installed Stremio addons with sports catalogs, listings matched
// to the game (lib/sports/addon-sources), their streams, and a resolved pick.
import { gatherCatalogAddons, type Addon } from "@/lib/addons";
import { isAddonEnabled } from "@/lib/addon-store";
import { clearSportsAddonCatalogCache, loadSportsAddonListings, loadSportsAddonStreams, refreshSportsAddonManifests } from "@/lib/sports/addon-sources";
import { sportsAddonCatalogs, type SportsAddonListing } from "@/lib/sports/addon-sources-model";
import { parseStream } from "@/lib/streams/parser";
import { resolveStream } from "@/lib/streams/resolve";
import type { Stream } from "@/lib/streams/types";

export type AddonListingView = { key: string; addonName: string; addonLogo: string | null; name: string; poster: string | null; match: "event" | "channel" | null };
export type AddonSourcesView = { installed: boolean; failed: boolean; rows: AddonListingView[]; matched: number; available: number };

const ADDON_HTTP = /^https?:\/\//i;
const ADDON_CATALOGUE = /^(movie|series)$/i;
let addonHeld: { identity: string; at: number; providers: Addon[]; rows: SportsAddonListing[]; view: AddonSourcesView } | null = null;
/** (review 14) The streams each recently picked listing answered, by listing key: per listing the
 *  answer of its newest pick that has landed, for the last few listings. One global list (even
 *  with pass 2's and review 12's order rules) could hold another listing's streams while the TV
 *  showed this one's: pick A, B, then A again (all slow), B answered first, A's first answer was
 *  dropped, and every Play of the A streams on screen said "Could not start" until A's second
 *  answer landed. addonPlay names the listing it plays from and looks its streams up here. */
const addonPicked = new Map<string, { pick: number; streams: Stream[] }>();
const ADDON_PICKED_KEEP = 8;
/** (review 14) The listing of the newest pick: what the TV shows, never evicted from addonPicked. */
let addonPickedLatest: string | null = null;
/** Keeps a landed answer and returns what the listing now holds: an answer lands unless a later
 *  pick of the same listing has already landed (review 12), in which case that one is returned. */
function keepAddonPicked(key: string, pick: number, streams: Stream[]): { pick: number; streams: Stream[] } {
  const held = addonPicked.get(key);
  if (held && held.pick > pick) return held;
  const kept = { pick, streams };
  addonPicked.delete(key);
  addonPicked.set(key, kept);
  // (review 14) Never the listing picked last (the one on screen): the late answers of listings the
  // viewer backed out of land after it and were each kept as newest, so nine quick picks followed by
  // a fast one evicted the streams on screen and every Play said "Could not start".
  while (addonPicked.size > ADDON_PICKED_KEEP) {
    let victim: string | null = null;
    for (const k of addonPicked.keys()) {
      if (k !== addonPickedLatest) { victim = k; break; }
    }
    if (victim === null) break;
    addonPicked.delete(victim);
  }
  return kept;
}

function addonIdentity(game: SportsGame, authKey: string | null): string {
  return JSON.stringify([game.id, game.startMs, game.home.name, game.away.name, game.context?.name ?? null, game.broadcasts ?? null, authKey]);
}
const listingView = (r: SportsAddonListing): AddonListingView => ({
  key: r.key, addonName: r.addon.manifest.name, addonLogo: r.addon.manifest.logo || r.meta.logo || r.meta.poster || null,
  name: r.meta.name, poster: r.meta.poster ?? null, match: r.match,
});

/** use-bp-sports-addon-sources: every listing (matching first) for a game; empty unless consented and not finished. */
export async function addonSources(game: SportsGame, authKey: string | null = null, force = false): Promise<AddonSourcesView> {
  const empty: AddonSourcesView = { installed: false, failed: false, rows: [], matched: 0, available: 0 };
  if (getSportsConsentSnapshot().status !== "accepted" || game.state === "post") return empty;
  const identity = addonIdentity(game, authKey);
  if (force) { clearSportsAddonCatalogCache(); addonHeld = null; }
  if (addonHeld && addonHeld.identity === identity && Date.now() - addonHeld.at < 45_000) return addonHeld.view;
  const ac = new AbortController();
  try {
    const gathered = await gatherCatalogAddons(authKey);
    const hydrated = await refreshSportsAddonManifests(gathered, ac.signal);
    const eligible = hydrated.addons.filter((a) => sportsAddonCatalogs(a).length > 0);
    const result = eligible.length ? await loadSportsAddonListings(eligible, game, ac.signal, () => {}) : { rows: [] as SportsAddonListing[], failed: 0, total: 0 };
    const rows = [...result.rows.filter((r) => r.match !== null), ...result.rows.filter((r) => r.match === null)];
    const view: AddonSourcesView = {
      installed: eligible.length > 0, failed: result.failed > 0 || hydrated.failed > 0,
      rows: rows.map(listingView), matched: rows.filter((r) => r.match !== null).length, available: rows.length,
    };
    addonHeld = { identity, at: Date.now(), providers: hydrated.addons, rows, view };
    return view;
  } catch {
    return { ...empty, failed: true };
  }
}

/** bp-sports-addon-play choose: the streams one listing offers (inline, its addon, then others that
 *  accept the id). The answer is what addonPicked holds for the listing once this pick lands (a
 *  later pick's streams when that landed first), and `pick` numbers it (later picks are higher),
 *  so the TV can keep the highest it has seen per listing and always show streams that play. */
let addonStreamsSeq = 0;
export async function addonStreams(key: string): Promise<{ status: "ok" | "listing" | "reload"; pick?: number; rows: Array<{ index: number; name: string; title: string; external: boolean }> }> {
  const row = addonHeld?.rows.find((r) => r.key === key);
  if (!row || !isAddonEnabled(row.addon.transportUrl)) { addonHeld = null; return { status: "reload", rows: [] }; }
  // (review 14) Kept per listing (addonPicked): a slow answer for a listing the viewer backed out
  // of never replaces the streams of the one on screen (pass 2), a listing picked twice plays from
  // its first answer while the second loads (review 12), and A, B, A again plays A's shown answer
  // whichever of B's and A's answers lands first.
  const pick = ++addonStreamsSeq;
  addonPickedLatest = key;
  try {
    const providers = (addonHeld?.providers ?? []).filter((a) => isAddonEnabled(a.transportUrl));
    const streams = await loadSportsAddonStreams(row, new AbortController().signal, providers);
    const held = keepAddonPicked(key, pick, streams);
    return {
      status: "ok", pick: held.pick,
      rows: held.streams.map((st, index) => ({
        index, name: st.name || st.addonName || "Play stream", title: st.title || st.description || st.addonName || "",
        external: !st.url && !!(st.externalUrl || st.ytId),
      })),
    };
  } catch {
    return { status: "listing", rows: [] };
  }
}

/** bp-sports-addon-play play: a direct link plays live; an external page goes to the phone; a
 *  torrent, non-http link or catalogue title hands off to the regular stream list for its meta. */
export async function addonPlay(key: string, index: number): Promise<
  | { kind: "play"; url: string; headers: Record<string, string> | null; title: string; subtitle: string; subtitles: Array<{ url: string; lang: string | null }> }
  | { kind: "external"; url: string }
  | { kind: "handoff"; meta: unknown }
  | { kind: "reload" }
  | { kind: "error" }
> {
  const row = addonHeld?.rows.find((r) => r.key === key);
  // (review 14) The streams of the listing the TV plays from, by its key.
  const stream = addonPicked.get(key)?.streams[index];
  if (!row || !stream) return { kind: "error" };
  if (!isAddonEnabled(row.addon.transportUrl) || (stream.addonUrl && !isAddonEnabled(stream.addonUrl))) { addonHeld = null; addonPicked.clear(); return { kind: "reload" }; }
  if (!stream.url && (stream.externalUrl || stream.ytId)) {
    const url = stream.externalUrl || `https://www.youtube.com/watch?v=${encodeURIComponent(stream.ytId ?? "")}`;
    return ADDON_HTTP.test(url) ? { kind: "external", url } : { kind: "error" };
  }
  if (stream.infoHash || !stream.url || !ADDON_HTTP.test(stream.url) || (ADDON_CATALOGUE.test(row.meta.type) && row.match !== "event")) return { kind: "handoff", meta: row.meta };
  try {
    const result = await resolveStream(parseStream(stream), [], new AbortController().signal, true, false, undefined, false, false);
    if (!result.ok) return { kind: "error" };
    const headers = result.data.headers && Object.keys(result.data.headers).length > 0 ? result.data.headers : null;
    // bp-sports-addon-play openPlayer({ …, subtitles: result.data.subtitles }).
    const subtitles = (result.data.subtitles ?? []).map((s) => ({ url: s.url, lang: s.lang ?? null }));
    return { kind: "play", url: result.data.url, headers, title: row.meta.name, subtitle: row.addon.manifest.name, subtitles };
  } catch {
    return { kind: "error" };
  }
}
