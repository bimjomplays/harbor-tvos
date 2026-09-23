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
import { involvesTeam, readFavourites, writeFavourites, toggleFavouriteTeam, type FavouriteTeam } from "@/lib/sports/favourites";
import { fetchGameSummary } from "@/lib/sports/provider";
import { matchCardContext, relativeCardStart } from "@/lib/sports/card-context";
import { formatSportsEventDate } from "@/lib/sports/event-date";
import { acceptSportsConsent, declineSportsConsent, getSportsConsentSnapshot } from "@/lib/sports/consent";
import { bpSportsForYouRows, bpSportsHotRows, bpSportsLeagueRows } from "@/views/big-picture/sports/bp-sports-rows";
import type { SportsGame } from "@/lib/sports/espn-types";
import { loadStoredSettings } from "@/lib/settings/load";
import { serializeSettings } from "@/lib/settings/profile-store";

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
  const note = busy ? null : stale ? "Showing saved schedules while feeds reconnect."
    : failed ? `Some feeds did not respond. Available events are still shown. (${failedKeys.slice(0, 3).map((k) => (k.split("@")[0] === "SOCCER_ALL" ? "Soccer" : k.split("@")[0])).join(", ")}${failedKeys.length > 3 ? ` +${failedKeys.length - 3}` : ""})`
    : null;

  return {
    mode, group, groups, showGroups: mode === "for-you" || mode === "schedule",
    day, today, liveDays, dateTitle,
    heroes: heroes.map((g) => view(g, now, locale)),
    rows: rows.map((r) => ({ key: r.key, title: r.title, description: r.description ?? null, games: r.games.map((g) => view(g, now, locale)) })),
    status: { busy, failed, failedKeys, stale, at, note },
    empty: (mode === "for-you" && filtered.length === 0) || (mode !== "for-you" && mode !== "explore" && rows.length === 0),
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
