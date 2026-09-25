// Sports event screen, second half (parity rows SP-1, SP-4, SP-8, SP-11, SP-12): the data logic
// of upstream's Big Picture event rows without React. Swift draws the diagrams with SwiftUI shapes
// from the finished numbers here; nothing below knows about pixels, only upstream's percentages.
//   eventRows   bp-sports-event-rows BpSportsStatsRow + BpSportsLineupsRow (live situation cell:
//               bp-sports-live-situation/-diamond/-field/-court; play by play: bp-sports-live-plays;
//               team stats; formation pitch: bp-sports-extra-pitch; player tables: -extra-players)
//   where       bp-sports-event-rows BpSportsWhereRow + bp-sports-extra-venue useBpSportsVenue
//   actions     use-bp-sports-event useBpSportsEventActions (reminder bell, follow a side, OpenDota)
//   reminders   lib/sports/reminders + reminder-state, run like components/sports-reminder-loop.tsx
//   apiSports   views/settings/sports-api-setting.tsx over lib/sports/api-credentials
import type { MatchPlayer, MatchTeamStatRow, SportsGame, SportsMatchDetail } from "@/lib/sports/espn-types";
import { hubLeague, sportsJson } from "@/lib/sports/hub-data";
import { sportsLeagueByTag } from "@/lib/sports/provider";
import { getLeagueLabel } from "@/lib/sports/espn-leagues";
import { basketballFive } from "@/lib/sports/field-lineups";
import { playIcon } from "@/lib/sports/play-icon";
import { bpSportsSituationKind } from "@/views/big-picture/sports/bp-sports-live-situation";
import { bpSportsHasPlays } from "@/views/big-picture/sports/bp-sports-live-plays";
import { bpSportsHasPitch } from "@/views/big-picture/sports/bp-sports-extra-pitch";
import { buildPitchLayout, goalsFromEvents, goalsOf, orientPoint, subStatesFromEvents, toCanvasPoint, type PitchSide } from "@/views/sports/pitch/pitch-formation";
import { watchProviders } from "@/lib/sports/watch-providers";
import { loadCompetitionMetadata } from "@/lib/sports/competition-metadata";
import { racingVenue } from "@/lib/sports/racing-venues";
import { isTeamFavourite, readFavourites, toggleFavouriteTeam, type FavouriteTeam } from "@/lib/sports/favourites";
import { readSportsReminders, reminderId, saveSportsReminder } from "@/lib/sports/reminders";
import { dueReminderChannels, reminderMessage, type SportsReminder } from "@/lib/sports/reminder-state";
import { getSportsConsentSnapshot } from "@/lib/sports/consent";
import { fireWebhook } from "@/lib/calendar";
import { loadEffective, sourceKeyFor, serializeSettings } from "@/lib/settings/profile-store";
import { readSportsApiKey, saveSportsApiKey } from "@/lib/sports/api-credentials";
import { API_SPORTS_LEAGUES, getApiSportsStatus, invalidateApiSportsCredentials } from "@/lib/sports/providers/api-sports";
import { detail, forgetSlices } from "./sports";
import { markSettingsPatched } from "./sync";
import { getUiLanguage, t } from "@/lib/i18n";

// ------------------------------------------------------------------ SP-1 / SP-11: event rows
const PAIRED = 8;
const PLAYS_OPENED = 24;
const PLAYER_COLUMNS = 6;
const PLAYER_TABLES = 8;
const SCORED = new Set(["goal", "touchdown", "homerun", "three", "score", "finish"]);

/** bp-sports-live-plays scored(): the loud rows. */
function scored(event: { type: SportsMatchDetail["events"][number]["type"]; text: string }): boolean {
  const kind = playIcon(event);
  if (SCORED.has(kind)) return true;
  if (kind !== "kick") return false;
  if (/\bno\s*good\b|\bmissed\b|\bblocked\b/i.test(event.text)) return false;
  if (!/field goal|extra point|\bpat\b/i.test(event.text)) return false;
  return /\bgood\b/i.test(event.text);
}

/** bp-sports-event-rows numberOf. */
function numberOf(value: string): number {
  const parsed = Number.parseFloat((value ?? "").replace(/[^0-9.-]/g, ""));
  return Number.isFinite(parsed) ? Math.max(0, parsed) : 0;
}

const surname = (name: string) => (name ?? "").split(" ").at(-1) ?? "";

function groupOf(game: SportsGame): string {
  return sportsLeagueByTag(game.league)?.group ?? hubLeague(game.league)?.group ?? "";
}

/** bp-sports-event-rows statLines: every team stat as a bar, then the combat tape rows (no bar). */
function statLines(d: SportsMatchDetail) {
  const lines: Array<MatchTeamStatRow & { bar: boolean }> = (d.allStats ?? []).map((stat) => ({ ...stat, bar: true }));
  const home = d.homeProfile, away = d.awayProfile;
  if (home && away) {
    const tape: Array<[string, string, string]> = [
      ["Height", home.height, away.height], ["Weight", home.weight, away.weight], ["Age", home.age, away.age],
      ["Reach", home.reach, away.reach], ["Stance", home.stance, away.stance],
    ];
    for (const [label, homeValue, awayValue] of tape) if (homeValue !== "-" || awayValue !== "-") lines.push({ label, homeValue, awayValue, bar: false });
  }
  return lines.map((stat) => {
    const away = numberOf(stat.awayValue);
    const total = away + numberOf(stat.homeValue);
    return { label: stat.label, awayValue: stat.awayValue || "0", homeValue: stat.homeValue || "0", bar: stat.bar, share: total > 0 ? Math.round((away / total) * 100) : 50 };
  });
}

function nameOf(roster: MatchPlayer[], id: string | undefined): string {
  if (!id) return "";
  return roster.find((p) => p.id === id)?.name ?? "";
}

/** bp-sports-live-diamond: bases, count, outs, batter and pitcher. */
function diamond(d: SportsMatchDetail) {
  const s = d.baseball;
  const roster = [...(d.homeRoster ?? []), ...(d.awayRoster ?? [])];
  const held = [s?.onFirstId, s?.onSecondId, s?.onThirdId];
  const labels = ["First base", "Second base", "Third base"];
  return {
    bases: held.map(Boolean),
    balls: s?.balls ?? null, strikes: s?.strikes ?? null, outs: s?.outs ?? null,
    batter: nameOf(roster, s?.batterId), pitcher: nameOf(roster, s?.pitcherId),
    runners: held.map((id, i) => (id ? `${t(labels[i])}: ${nameOf(roster, id) || t("On base")}` : "")).filter(Boolean).join(" · "),
  };
}

/** bp-sports-live-field: down, distance, possession, the ball marker on a 0-100 field with 8 % end zones. */
function field(d: SportsMatchDetail) {
  const s = d.football;
  if (!s) return null;
  const owner = [d.home, d.away].find((side) => side.id === s.possessionTeamId);
  const spot = (yardLine: number) => 8 + Math.min(100, Math.max(0, yardLine)) * 0.84;
  return {
    down: Number.isFinite(s.down) ? s.down : null, distance: typeof s.distance === "number" && Number.isFinite(s.distance) ? s.distance : null,
    owner: owner ? { name: owner.name, abbr: owner.abbr || owner.name, logo: owner.logo || "" } : null,
    marker: typeof s.yardLine === "number" && Number.isFinite(s.yardLine) ? spot(s.yardLine) : -1,
    yardLine: s.yardLineText ?? "",
  };
}

/** bp-sports-live-court: both starting fives on their lineup spots (away mirrored). */
function court(d: SportsMatchDetail) {
  const seat = (home: boolean) => (seatInfo: ReturnType<typeof basketballFive>[number]) => ({
    jersey: seatInfo.player?.jersey || seatInfo.slot,
    name: seatInfo.player ? surname(seatInfo.player.name) : seatInfo.slot,
    left: home ? seatInfo.x : 100 - seatInfo.x,
    top: seatInfo.y,
  });
  return { homeName: d.home.name, awayName: d.away.name, home: basketballFive(d.homeRoster ?? []).map(seat(true)), away: basketballFive(d.awayRoster ?? []).map(seat(false)) };
}

/** bp-sports-extra-pitch markers(): formation spots (horizontal pitch), goals and subbed-off. */
function pitchSide(roster: MatchPlayer[], formation: string, side: PitchSide, d: SportsMatchDetail) {
  const layout = buildPitchLayout(roster, formation, side);
  const goals = goalsFromEvents(d.events ?? [], roster);
  const subs = subStatesFromEvents(d.events ?? [], roster);
  return {
    formation: layout.formation,
    bench: layout.bench.map((p) => p.name),
    spots: layout.slots.map((slot) => {
      const point = toCanvasPoint(slot, side);
      const placed = orientPoint(point.x, point.y, "horizontal");
      return {
        home: side === "home", jersey: slot.player.jersey || slot.player.position || "-", name: (slot.player.name ?? "").split(" ").at(-1) ?? "",
        left: Number.isFinite(placed.left) ? placed.left : 50, top: Number.isFinite(placed.top) ? placed.top : 50, goals: goalsOf(slot.player, goals) || 0, out: subs.get(slot.player.id) === "out",
      };
    }),
  };
}

/** bp-sports-extra-players bpSportsPlayerStatCells: up to 8 tables, 6 columns each. */
function playerTables(d: SportsMatchDetail) {
  const tables = (d.playerStats ?? []).filter((table) => table.rows.length > 0).slice(0, PLAYER_TABLES);
  return tables.map((table, index) => {
    const team = [d.home, d.away].find((side) => side.id === table.teamId);
    const labels = table.labels.slice(0, PLAYER_COLUMNS);
    return {
      key: `${table.teamId}:${table.name}:${table.innings ?? 0}:${index}`,
      heading: [team?.name, table.name ? table.name : "Players", table.innings ? `Innings ${table.innings}` : ""].filter(Boolean).join(" · "),
      summary: table.summary ?? "",
      labels: labels.map(String),
      rows: table.rows.map((row) => ({
        id: row.player.id || row.player.name || "", name: row.player.name ?? "", image: row.player.image ?? null,
        values: labels.map((_, i) => String(row.values[i] ?? "-")),
      })),
      trimmed: table.labels.length - labels.length,
    };
  });
}

function lineupSide(name: string, formation: string | undefined, roster: MatchPlayer[]) {
  // BpLineupCell: starters first; the collapsed cell shows the starters (or up to 11).
  const ordered = [...roster].sort((a, b) => Number(b.starter) - Number(a.starter));
  return {
    name, formation: formation ?? "",
    players: ordered.map((p) => ({ id: p.id || p.name || "", name: p.name ?? "", jersey: String(p.jersey ?? ""), position: p.position ?? "", starter: !!p.starter })),
    starters: ordered.filter((p) => p.starter).length || Math.min(11, ordered.length),
  };
}

/**
 * The event screen's Stats and Lineups rows for one game (null when the row would be hidden).
 * Market odds are left out: upstream gates them behind settings.sportsShowOdds (default off) and
 * kid profiles, and the TV port does not offer them.
 */
export async function eventRows(game: SportsGame, given?: SportsMatchDetail | null) {
  // `given` lets a caller (the offline smoke) supply the summary; the app always fetches it.
  let d: SportsMatchDetail | null = given ?? null;
  if (!d) {
    try {
      d = (await detail(game)) as SportsMatchDetail | null;
    } catch {
      d = null;
    }
  }
  if (!d) return { stats: null, lineups: null };

  // BpSportsStatsRow.
  const lines = statLines(d);
  const stats = lines.length > 0;
  const kind = bpSportsSituationKind(game, d);
  const plays = bpSportsHasPlays(d);
  const live = kind !== "" || plays;
  let statsRow = null;
  if (stats || live) {
    const surface = kind === "diamond" ? "On the diamond" : kind === "field" ? "On the field" : "On the court";
    const title = live && game.state === "in" ? "Live now" : stats ? "Key statistics" : plays ? "Play by play" : surface;
    const quiet = (label: string) => (label === title ? "" : label);
    const newest = [...(d.events ?? [])].reverse().slice(0, PLAYS_OPENED);
    statsRow = {
      title,
      situation: kind === "" ? null : {
        kind, caption: quiet(surface),
        diamond: kind === "diamond" ? diamond(d) : null,
        field: kind === "field" ? field(d) : null,
        court: kind === "court" ? court(d) : null,
      },
      plays: plays ? {
        caption: quiet("Play by play"), total: (d.events ?? []).length,
        rows: newest.map((e, i) => ({ id: e.id || `${e.time}:${e.text}:${i}`, time: String(e.time ?? ""), text: String(e.text ?? ""), participant: e.participantName ?? "", icon: playIcon({ type: e.type, text: String(e.text ?? "") }), loud: scored({ type: e.type, text: String(e.text ?? "") }) })),
      } : null,
      team: stats ? { caption: quiet("Key statistics"), paired: PAIRED, lines } : null,
    };
  }

  // BpSportsLineupsRow.
  const homeRoster = d.homeRoster ?? [], awayRoster = d.awayRoster ?? [];
  const players = playerTables(d);
  const rosters = homeRoster.length > 0 || awayRoster.length > 0;
  let lineups = null;
  if (rosters || players.length > 0) {
    const pitch = bpSportsHasPitch(groupOf(game), d);
    const home = pitch ? pitchSide(homeRoster, d.homeFormation ?? "", "home", d) : null;
    const away = pitch ? pitchSide(awayRoster, d.awayFormation ?? "", "away", d) : null;
    lineups = {
      title: rosters && players.length > 0 ? "Lineups and player statistics" : rosters ? "Lineups" : "Player statistics",
      pitch: home && away ? {
        homeName: game.home.name, awayName: game.away.name, homeFormation: home.formation, awayFormation: away.formation,
        spots: [...home.spots, ...away.spots], bench: [...home.bench, ...away.bench],
      } : null,
      away: awayRoster.length > 0 ? lineupSide(game.away.name, d.awayFormation, awayRoster) : null,
      home: homeRoster.length > 0 ? lineupSide(game.home.name, d.homeFormation, homeRoster) : null,
      players,
    };
  }
  return { stats: statsRow, lineups };
}

// ----------------------------------------------------------- SP-8: where to watch + venue
const UFC_GUIDE = "https://www.ufc.com/watch";
const F1_GUIDE = "https://www.formula1.com/en/information/f1-broadcast-information.45y3LNsT1D6VoK0ZmX8ciJ";

/** bp-sports-extra-venue useBpSportsVenue: racing venue table, then competition metadata, then the feed's venue. */
async function venueOf(game: SportsGame) {
  const def = hubLeague(game.league);
  const competition = def
    ? await Promise.race([
        loadCompetitionMetadata(game, def, new AbortController().signal, sportsJson).then((m) => m.venue).catch(() => undefined),
        new Promise<undefined>((r) => setTimeout(() => r(undefined), 10_000)),
      ])
    : undefined;
  const track = racingVenue({ league: game.league, name: game.context?.name || game.home.name, venue: game.context?.venue, context: game.context, startMs: game.startMs });
  const name = track?.name || competition?.name || game.context?.venue || "";
  if (!name) return null;
  const facts: string[] = [];
  if (track?.length) facts.push(`Length ${track.length}`);
  if (track?.turns) facts.push(`${track.turns} turns`);
  if (track?.layout) facts.push(track.layout === "oval" ? "Oval circuit" : track.layout === "street" ? "Street circuit" : "Road circuit");
  return {
    name,
    location: track?.location || competition?.location || "",
    image: track?.map || track?.photo || competition?.image || "",
    url: track?.website || track?.sourceUrl || competition?.website || "",
    facts,
  };
}

/** BpSportsWhereRow: venue cell, a tile per watch provider, the UFC / F1 official guides. */
export async function where(game: SportsGame) {
  const venue = await venueOf(game).catch(() => null);
  const marks = watchProviders(game).map((p) => ({ id: p.id, name: p.name, note: p.listed ? "Listed broadcaster" : "Check event availability", logo: p.logo, url: p.url }));
  const taken = new Set(marks.map((m) => m.id));
  if (game.league === "UFC" && !taken.has("ufc")) marks.push({ id: "ufc", name: "Official UFC watch guide", note: "", logo: "", url: UFC_GUIDE });
  if (game.league === "F1" && !taken.has("f1")) marks.push({ id: "f1", name: "Find your country's F1 broadcaster", note: "", logo: "", url: F1_GUIDE });
  if (marks.length === 0 && !venue) return null;
  return {
    title: venue ? "Venue and where to watch" : "Where to watch",
    venue, marks,
    note: marks.length > 0
      ? "Subscriptions, pay-per-view and regional availability are set by each provider. Check that the event is included before purchasing. Use only sources you are authorized to access. Harbor does not bypass subscriptions or access restrictions."
      : null,
  };
}

// ---------------------------------------------------------------- SP-4: hero actions + bell
const INDIVIDUAL = new Set(["tennis", "combat", "golf", "motorsport"]);
const UNNAMED = /^(tbd|tba|winner|loser)\b/i;
const DEFAULT_LEAD = 15;

/** The active profile's settings source, as profile-store readActiveSourceForRecovery reads it. */
function activeSource(): { profileId: string; linked: boolean } {
  try {
    const raw = localStorage.getItem("harbor.profiles.v1");
    if (!raw) return { profileId: "default", linked: true };
    const s = JSON.parse(raw) as { profiles?: Array<{ id: string; settingsLinked?: boolean }>; activeId?: string | null };
    const id = s.activeId || "default";
    const p = s.profiles?.find((x) => x.id === id);
    return { profileId: id, linked: p?.settingsLinked !== false };
  } catch {
    return { profileId: "default", linked: true };
  }
}

/** settings.webhooks for the active profile (the reminder loop reads it on every tick, like useSettings). */
export function webhooks(): { discordUrl: string; telegramUrl: string } {
  const { profileId, linked } = activeSource();
  const w = loadEffective(profileId, linked).webhooks;
  return { discordUrl: w?.discordUrl ?? "", telegramUrl: w?.telegramUrl ?? "" };
}

/** Settings → Webhooks, the two fields a sports reminder needs; the rest of settings.webhooks is kept. */
export function setWebhooks(discordUrl: string, telegramUrl: string): { discordUrl: string; telegramUrl: string } {
  const { profileId, linked } = activeSource();
  const current = loadEffective(profileId, linked);
  const next = { ...current, webhooks: { ...current.webhooks, discordUrl: discordUrl.trim(), telegramUrl: telegramUrl.trim() } };
  localStorage.setItem(sourceKeyFor(profileId, linked), serializeSettings(next));
  markSettingsPatched(["webhooks"]);
  return webhooks();
}

/** webhooks-panel.tsx send(): the "Send test" message for a saved Discord or Telegram destination. */
export async function testWebhook(kind: "discord" | "telegram"): Promise<{ ok: boolean; message: string }> {
  const w = webhooks();
  const url = kind === "discord" ? w.discordUrl : w.telegramUrl;
  if (!url) return { ok: false, message: "No URL configured" };
  const service = kind === "discord" ? "Discord" : "Telegram";
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 12_000);
  const res = await fireWebhook(kind, url, { text: `Harbor test message (${service}). If you can read this, it's wired up.`, items: [] }, controller.signal).finally(() => clearTimeout(timer));
  return { ok: res.ok, message: res.ok ? "Sent. Check your channel." : (res.error ?? "Failed") };
}

function reminderChannels(): Array<"discord" | "telegram"> {
  const w = webhooks();
  return (["discord", "telegram"] as const).filter((c) => (c === "discord" ? w.discordUrl : w.telegramUrl));
}

function favouriteOf(side: SportsGame["home"], leagueKey: string, group: string): FavouriteTeam | null {
  if (!side.id || !side.name || UNNAMED.test(side.name)) return null;
  return { id: side.id, leagueKey, group, name: side.name, abbr: side.abbr, logo: side.logo };
}

/** useBpSportsEventActions: the reminder bell, follow toggles for team sports, OpenDota's page. */
export function actions(game: SportsGame) {
  const group = groupOf(game);
  const leagueKey = hubLeague(game.league)?.key ?? sportsLeagueByTag(game.league)?.key ?? game.league;
  const id = reminderId(game);
  const reminded = readSportsReminders().some((r) => r.id === id);
  const channels = reminderChannels();
  const remindable = game.dateOnly === undefined && game.state === "pre" && Number.isFinite(game.startMs) && game.startMs > Date.now();
  const fav = readFavourites();
  const follow: Array<{ key: string; name: string; logo: string; on: boolean; label: string }> = [];
  if (!INDIVIDUAL.has(group) && group !== "esports") {
    for (const key of ["away", "home"] as const) {
      const team = favouriteOf(game[key], leagueKey, group);
      if (!team) continue;
      const on = isTeamFavourite(fav, leagueKey, team.id);
      // use-bp-sports-event.ts: the follow and reminder labels go through t().
      follow.push({ key, name: team.name, logo: team.logo || "", on, label: on ? t("Following {name}", { name: team.name }) : t("Follow {name}", { name: team.name }) });
    }
  }
  return {
    reminder: remindable ? {
      active: reminded,
      setup: channels.length === 0,
      label: reminded ? t("Reminder set") : channels.length === 0 ? t("Set up reminders") : t("Remind me {n} minutes before", { n: DEFAULT_LEAD }),
    } : null,
    follow,
    opendota: game.source === "opendota" && game.id ? `https://www.opendota.com/matches/${game.id}` : null,
  };
}

/** Follow / unfollow one side (toggleFavouriteTeam); the "Your teams" row follows it. */
export function toggleFollow(game: SportsGame, which: "home" | "away"): boolean {
  const group = groupOf(game);
  const leagueKey = hubLeague(game.league)?.key ?? sportsLeagueByTag(game.league)?.key ?? game.league;
  const team = favouriteOf(game[which], leagueKey, group);
  return team ? toggleFavouriteTeam(team) : false;
}

/**
 * The bell (toggleReminder): a set reminder clears; with no Discord/Telegram webhook configured it
 * asks for one (`setup`, upstream opens Settings → Webhooks); otherwise a reminder is armed for
 * 15 minutes before the start and the runner is started.
 */
export function toggleReminder(game: SportsGame): { state: "set" | "cleared" | "setup" } {
  const id = reminderId(game);
  if (readSportsReminders().some((r) => r.id === id)) {
    saveSportsReminder(null, id);
    return { state: "cleared" };
  }
  const channels = reminderChannels();
  if (channels.length === 0) return { state: "setup" };
  saveSportsReminder({
    id, name: game.context?.name || `${game.away.name} · ${game.home.name}`, league: game.league, startMs: game.startMs,
    leadMinutes: DEFAULT_LEAD, channels: [...channels], sent: {}, attempted: {}, failed: [],
  });
  startReminders();
  return { state: "set" };
}

/** Reminders still able to send something (so the timer can stop when nothing is left to do). */
function pending(r: SportsReminder, now: number): boolean {
  if (r.awaitingStartTime) return true;
  return now <= r.startMs + 10 * 60_000 && r.channels.some((c) => !r.sent[c]);
}

/**
 * sports-reminder-loop.tsx sendDue: every due channel of every reminder, one webhook each; a
 * delivered channel is never retried and a failure is retried after a minute (dueReminderChannels).
 * Returns how many webhooks were delivered on this pass.
 */
export async function runReminders(): Promise<number> {
  if (getSportsConsentSnapshot().status !== "accepted") return 0;
  let delivered = 0;
  for (const reminder of readSportsReminders()) {
    for (const channel of dueReminderChannels(reminder, Date.now())) {
      const latest = readSportsReminders().find((item) => item.id === reminder.id);
      if (!latest || !dueReminderChannels(latest, Date.now()).includes(channel)) continue;
      const w = webhooks();
      const url = channel === "discord" ? w.discordUrl : w.telegramUrl;
      if (!url) continue;
      const attempt = { ...latest, attempted: { ...latest.attempted, [channel]: Date.now() } };
      if (!saveSportsReminder(attempt)) continue;
      // sports-reminder-loop.tsx: the start time is formatted in Harbor's UI language.
      const message = reminderMessage(latest, Date.now(), getUiLanguage());
      const text = channel === "telegram" ? message.replace(/([_*`[])/g, "\\$1") : message;
      const controller = new AbortController();
      const timer = setTimeout(() => controller.abort(), 12_000);
      const result = await fireWebhook(channel, url, { text, items: [] }, controller.signal).finally(() => clearTimeout(timer));
      const remaining = readSportsReminders().find((item) => item.id === reminder.id);
      if (!remaining || remaining.startMs !== latest.startMs) continue;
      if (result.ok) delivered++;
      saveSportsReminder({
        ...remaining,
        sent: result.ok ? { ...remaining.sent, [channel]: Date.now() } : remaining.sent,
        failed: result.ok ? remaining.failed.filter((item) => item !== channel) : [...new Set([...remaining.failed, channel])],
      });
    }
  }
  return delivered;
}

// The runner. Upstream mounts SportsReminderLoop at the app root: a 30 s interval (plus window
// focus) that runs only while Harbor is open. The TV does the same inside the engine: the timer
// lives in JavaScriptCore and ticks only while the app is in the foreground. tvOS gives an app
// no background execution for this (no background fetch that could be relied on, and a webhook
// is not a local notification), so a reminder whose moment passes while Harbor is closed or
// suspended is sent late on the next launch if it is still inside upstream's 10 minute window,
// and not at all after it.
const TICK_MS = 30_000;
let reminderTimer: ReturnType<typeof setInterval> | null = null;
let reminderBusy = false;

async function tick(): Promise<void> {
  if (reminderBusy) return;
  reminderBusy = true;
  try {
    await runReminders();
  } catch {
    // A failed pass is retried on the next tick.
  } finally {
    reminderBusy = false;
  }
  const now = Date.now();
  if (!readSportsReminders().some((r) => pending(r, now)) && reminderTimer) {
    clearInterval(reminderTimer);
    reminderTimer = null;
  }
}

/** Starts (or keeps) the 30 s loop when consent is given and a reminder can still fire. */
export function startReminders(): boolean {
  const now = Date.now();
  if (getSportsConsentSnapshot().status !== "accepted" || !readSportsReminders().some((r) => pending(r, now))) return reminderTimer !== null;
  if (!reminderTimer) reminderTimer = setInterval(() => void tick(), TICK_MS);
  void tick();
  return true;
}

/** Reminders currently stored, for Settings (count and the next start). */
export function reminders(): Array<{ id: string; name: string; league: string; startMs: number; channels: string[]; sent: string[]; failed: string[] }> {
  return readSportsReminders().map((r) => ({
    id: r.id, name: r.name, league: r.league, startMs: r.startMs, channels: r.channels,
    sent: Object.keys(r.sent), failed: r.failed,
  }));
}

// Engine boot: pick up reminders armed in an earlier session (App.tsx mounts the loop at launch).
setTimeout(() => { try { startReminders(); } catch { /* storage not ready: the next arm starts it */ } }, 4000);

// ------------------------------------------------------------------- SP-12: api-sports key
const PAID_HUB_KEYS = ["EGYPT", "QATAR", "UAE", "KHL"];
const ACCOUNT_NOTICES: Record<string, string> = {
  "invalid-key": "API-Sports rejected this key. Check it in your API-Sports dashboard.",
  quota: "Your API-Sports request allowance is exhausted. Public feeds remain available.",
  "rate-limit": "API-Sports is limiting requests. Harbor will retry after the waiting period.",
  unavailable: "API-Sports is unavailable right now. Public feeds remain available.",
};

/** sports-api-setting.tsx: whether a key is saved, which leagues it adds, and account notices. */
export function apiSports(): { saved: boolean; length: number; leagues: string[]; notices: string[] } {
  const key = readSportsApiKey();
  const codes = [...new Set([getApiSportsStatus("football").code, getApiSportsStatus("hockey").code])];
  return {
    saved: key !== "", length: key.length,
    leagues: API_SPORTS_LEAGUES.filter((l) => ["EGY", "QSL", "UAE", "KHL"].includes(l.key)).map(getLeagueLabel),
    notices: codes.filter((c) => ACCOUNT_NOTICES[c]).map((c) => ACCOUNT_NOTICES[c]),
  };
}

/** Save (or clear, with "") the key; saving does not verify it. The paid leagues refetch next time. */
export function setApiSportsKey(value: string): { ok: boolean } {
  try {
    saveSportsApiKey(value.trim());
    invalidateApiSportsCredentials();
    forgetSlices(PAID_HUB_KEYS);
    return { ok: true };
  } catch {
    return { ok: false };
  }
}
