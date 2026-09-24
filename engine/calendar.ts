// Calendar (Stage 5): views/calendar.tsx + views/calendar/* without React. One call builds a whole
// month for the Big Picture calendar room: the source switcher (source-switcher.tsx), the data
// dispatch (use-calendar-data.ts), the filter chips and "Watchlist only" (calendar.tsx `filtered`),
// the 42-cell month grid (utils.ts buildMonthCells) and the empty-state copy (empty-states.tsx).
// The custom-source rail (calendar/config/*) and the reminders (lib/reminders.ts, the
// RemindersRunner in lib/reminders-runner.tsx, components/reminders-manager.tsx) live here too.
import type { Meta } from "@/lib/cinemeta";
import {
  applyCalendarFilter,
  fetchCalendarRange,
  fetchCustomCalendar,
  groupByDate,
  monthRangeISO,
  todayLocalISO,
  type CalendarFilter,
  type CalendarItem,
} from "@/lib/calendar";
import {
  fetchAnticipatedCalendar,
  fetchAniListAiringCalendar,
  fetchAnimeDubCalendar,
  fetchLibraryCalendar,
  fetchSimklCalendar,
  fetchSimklPremieresCalendar,
  fetchTraktCalendar,
} from "@/lib/calendar-sources";
import { library, type LibraryItem } from "@/lib/stremio";
import { isAuthenticated as traktConnected } from "@/lib/trakt/session";
import { isAuthenticated as simklConnected } from "@/lib/simkl/session";
import { loadEffective, persistEffective } from "@/lib/settings/profile-store";
import type { Settings } from "@/lib/settings/types";
import { t } from "@/lib/i18n";
import { formatRemaining } from "@/lib/use-now";
import { fetchEpisodeList } from "@/lib/series-episodes";
import {
  clearUnseenReminders,
  listReminders,
  markReminderUnseen,
  removeReminder as removeUpstreamReminder,
  setReminderSeen,
  type ReminderEntry,
} from "@/lib/reminders";
import {
  buildLibraryNameSet,
  buildMonthCells,
  calendarEpisodeHint,
  calendarToMeta,
  FILTERS,
  formatDateLong,
  isUpcoming,
  MONTH_NAMES,
  normalizeName,
  orderedWeekdayNames,
} from "@/views/calendar/utils";
import {
  buildActiveCount,
  buildGenreOptions,
  buildGroupSummaries,
  buildSummary,
} from "@/views/calendar/config/rail-sources";
import { COUNTRIES, WATCH_PROVIDERS, type CustomCalendar } from "@/views/calendar/config/constants";
import { MOVIE_GENRES, TV_GENRES } from "@/lib/feed/tags";
import { markSettingsPatched } from "./sync";

type Source = Settings["calendarSource"];

// ------------------------------------------------------------------ source switcher
// source-switcher.tsx OPTIONS (labels and hints verbatim); the glyph is an SF Symbol name.
const OPTIONS: Array<{ id: Source; label: string; hint: string; icon: string }> = [
  { id: "library", label: "My library", hint: "Upcoming episodes and movies from your saved shows", icon: "books.vertical" },
  { id: "all", label: "All upcoming", hint: "Everything releasing this month from TMDB", icon: "globe" },
  { id: "trakt", label: "My Trakt", hint: "Upcoming episodes and movies from your Trakt watchlist", icon: "checkmark.circle" },
  { id: "anticipated", label: "Trakt anticipated", hint: "The most anticipated upcoming releases on Trakt", icon: "checkmark.circle" },
  { id: "simkl", label: "My Simkl", hint: "Upcoming episodes and movies from your Simkl watching and plan-to-watch lists", icon: "s.circle" },
  { id: "simkl-anticipated", label: "Simkl premieres", hint: "New shows and anime premiering this month, from Simkl", icon: "s.circle" },
  { id: "anime", label: "Anime", hint: "Anime episodes airing this month, sub or dub", icon: "sparkles" },
  { id: "custom", label: "Custom", hint: "Build your own feed from actors, directors, and Trakt lists", icon: "star" },
];

// ------------------------------------------------------------------------ data
// use-calendar-data.ts dispatch(): the same fetcher per source, and "stop" (no rows) when the
// source cannot run (not signed in, not connected, no TMDB key).
async function fetchSource(
  source: Source,
  s: Settings,
  authKey: string | null,
  year: number,
  month: number,
  animeDub: boolean,
): Promise<CalendarItem[]> {
  const trakt = traktConnected();
  if (source === "library") {
    if (!authKey) return [];
    return fetchLibraryCalendar(authKey, year, month, { tmdbKey: s.tmdbKey, includeTrakt: trakt });
  }
  if (source === "trakt") return trakt ? fetchTraktCalendar(year, month) : [];
  if (source === "simkl") return simklConnected() ? fetchSimklCalendar(year, month, { tmdbKey: s.tmdbKey }) : [];
  if (source === "simkl-anticipated") return fetchSimklPremieresCalendar(year, month);
  if (source === "anime") return animeDub ? fetchAnimeDubCalendar(year, month) : fetchAniListAiringCalendar(year, month);
  if (source === "anticipated") return fetchAnticipatedCalendar(year, month);
  if (source === "custom") {
    if (!s.tmdbKey) return [];
    const { start, end } = monthRangeISO(year, month);
    const extras: Promise<CalendarItem[]>[] = [];
    if (s.customCalendar.includeTraktAnticipated) extras.push(fetchAnticipatedCalendar(year, month).catch(() => []));
    if (s.customCalendar.includeTraktWatchlist && trakt) extras.push(fetchTraktCalendar(year, month).catch(() => []));
    const extra = (await Promise.all(extras)).flat();
    return fetchCustomCalendar({
      apiKey: s.tmdbKey,
      region: s.region,
      filters: {
        trackedPeople: s.customCalendar.trackedPeople,
        genres: s.customCalendar.genres,
        watchProviders: s.customCalendar.watchProviders,
        originCountries: s.customCalendar.originCountries,
        mediaTypes: s.customCalendar.mediaTypes,
      },
      start,
      end,
      extra,
    });
  }
  if (!s.tmdbKey) return [];
  const { start, end } = monthRangeISO(year, month);
  return fetchCalendarRange(s.tmdbKey, start, end, s.region);
}

// calendar.tsx loads the Stremio library for "Watchlist only" while the source is All upcoming.
let libraryCache: { authKey: string; at: number; items: LibraryItem[] } | null = null;
async function libraryItems(authKey: string | null): Promise<LibraryItem[]> {
  if (!authKey) return [];
  if (libraryCache && libraryCache.authKey === authKey && Date.now() - libraryCache.at < 60_000) return libraryCache.items;
  try {
    const items = await library(authKey);
    libraryCache = { authKey, at: Date.now(), items };
    return items;
  } catch {
    return [];
  }
}

// empty-states.tsx EmptyState: heading and body per source / filter (copy verbatim).
function emptyCopy(source: Source, filter: CalendarFilter, watchlistOnly: boolean, animeDub: boolean): { heading: string; body: string } {
  const heading =
    source === "library" ? t("Nothing from your library this month")
    : source === "trakt" ? t("Nothing on Trakt this month")
    : source === "anticipated" ? t("Nothing anticipated this month")
    : source === "simkl" ? t("Nothing on Simkl this month")
    : source === "simkl-anticipated" ? t("No Simkl premieres this month")
    : source === "anime" ? t(animeDub ? "No dubbed episodes this month" : "Nothing airing this month")
    : t("Nothing this month");
  const filterKind = filter === "movie" ? t("movies") : filter === "tv" ? t("TV") : t("anime");
  const body =
    source === "library"
      ? t("Your saved shows have no episodes scheduled for this month. Switch to All upcoming to browse the full release calendar.")
      : source === "trakt"
        ? t("Trakt has no upcoming releases for your watchlist this month. Past months and dates more than six months out aren't covered by Trakt's calendar feed.")
        : source === "anticipated"
          ? t("None of Trakt's most-anticipated upcoming releases land in this month. Try a different month.")
          : source === "simkl"
            ? t("Your Simkl plan-to-watch list has no episodes airing this month. Switch to All upcoming to browse everything.")
            : source === "simkl-anticipated"
              ? t("Simkl lists no new shows or anime premiering this month. Try a different month.")
              : source === "anime"
                ? t(animeDub
                    ? "The dub schedule has no episodes releasing this month. Try a different month."
                    : "AniList has no anime episodes scheduled to air this month. Try a different month.")
                : watchlistOnly
                  ? t("Nothing from your library lands this month. Toggle Watchlist off to see all releases.")
                  : filter === "all"
                    ? t("TMDB has no notable releases for this month and region.")
                    : t("No {kind} releases this month. Try a different filter.", { kind: filterKind });
  return { heading, body };
}

export type CalendarEntry = {
  id: string;
  name: string;
  type: "movie" | "tv";
  poster: string | null;
  releaseDate: string;
  releaseTime: string | null;
  releaseAtMs: number | null;
  upcoming: boolean;
  isAnime: boolean;
  overview: string;
  voteAverage: number;
  /** calendar-chip.tsx tag: Anime / Movie / TV. */
  tag: string;
  dateLong: string;
  /** calendarToMeta(item): what openMeta receives. */
  meta: Meta;
  /** calendarEpisodeHint(item): the episode the release is about, when there is one. */
  season: number | null;
  episode: number | null;
};

export type CalendarCell = { iso: string; day: number; inMonth: boolean; isToday: boolean; items: CalendarEntry[] };

export type CalendarMonth = {
  year: number;
  month: number;
  monthLabel: string;
  todayISO: string;
  source: Source;
  sources: Array<{ id: Source; label: string; hint: string; icon: string }>;
  traktConnected: boolean;
  simklConnected: boolean;
  signedIn: boolean;
  weekStartsMonday: boolean;
  posterSize: "default" | "large";
  weekdays: string[];
  /** Sub / Dub pair, only on the Anime source. */
  animeDubToggle: boolean;
  animeDub: boolean;
  hideTypeTag: boolean;
  /** The filter chips (All / Movies / TV / Anime with counts); empty when the source shows none. */
  filters: Array<{ id: CalendarFilter; label: string; count: number }>;
  filter: CalendarFilter;
  /** "Watchlist only" (All upcoming only); disabled while signed out. */
  watchlistToggle: boolean;
  watchlistOnly: boolean;
  /** The Custom source's rail summary: active filter count and one-line summary. */
  custom: { activeCount: number; summary: string } | null;
  status: "not-signed-in" | "no-key" | "error" | "empty" | "ready";
  error: string | null;
  emptyHeading: string;
  emptyBody: string;
  total: number;
  cells: CalendarCell[];
};

function toEntry(item: CalendarItem): CalendarEntry {
  const hint = calendarEpisodeHint(item);
  const meta = calendarToMeta(item);
  return {
    id: item.id,
    name: item.name,
    type: item.type,
    poster: item.poster ?? null,
    releaseDate: item.releaseDate,
    releaseTime: item.releaseTime ?? null,
    releaseAtMs: item.releaseAtMs ?? null,
    upcoming: isUpcoming(item),
    isAnime: item.isAnime,
    overview: item.overview ?? "",
    voteAverage: Number.isFinite(item.voteAverage) ? item.voteAverage : 0,
    tag: item.isAnime ? t("Anime") : item.type === "movie" ? t("Movie") : t("TV"),
    dateLong: formatDateLong(item.releaseDate),
    // JSON drops undefined; keep the Swift Meta's required fields present.
    meta: { ...meta, name: meta.name || item.name },
    season: hint?.season ?? null,
    episode: hint?.episode ?? null,
  };
}

export type MonthInput = {
  profileId?: string;
  linked?: boolean;
  authKey?: string | null;
  year: number;
  /** 0-based, as upstream's Date months. */
  month: number;
  filter?: CalendarFilter;
  watchlistOnly?: boolean;
  animeDub?: boolean;
};

/** One month of the calendar room, as calendar.tsx renders it for the saved source. */
export async function month(input: MonthInput): Promise<CalendarMonth> {
  const profileId = input.profileId || "default";
  const linked = input.linked !== false;
  const s = loadEffective(profileId, linked);
  const authKey = input.authKey || null;
  const source: Source = s.calendarSource ?? "library";
  const year = Math.trunc(input.year);
  const monthIdx = Math.max(0, Math.min(11, Math.trunc(input.month)));
  const animeDub = !!input.animeDub;
  const trakt = traktConnected();
  const simkl = simklConnected();
  const hideAnime = !!s.hideContent?.anime;
  const filtersShown = hideAnime || source === "all" ? FILTERS.filter((f) => f.id !== "anime") : FILTERS;
  let filter: CalendarFilter = input.filter ?? "all";
  if (!filtersShown.some((f) => f.id === filter)) filter = "all";
  const watchlistOnly = source === "all" && !!authKey && !!input.watchlistOnly;

  let items: CalendarItem[] = [];
  let error: string | null = null;
  let status: CalendarMonth["status"] = "ready";
  if (source === "library" && !authKey) status = "not-signed-in";
  else if (source === "all" && !s.tmdbKey) status = "no-key";
  else {
    try {
      items = await fetchSource(source, s, authKey, year, monthIdx, animeDub);
    } catch (e) {
      error = e instanceof Error ? e.message : t("Failed to load");
      status = "error";
    }
  }

  // calendar.tsx `filtered`.
  const dropAnime = (list: CalendarItem[]) => (hideAnime ? list.filter((i) => !i.isAnime) : list);
  let filtered: CalendarItem[];
  if (source !== "all" && source !== "simkl-anticipated") filtered = dropAnime(items);
  else {
    // All upcoming is exclusively movies and TV — anime lives in the dedicated Anime source.
    const f: CalendarFilter = source === "all" && filter === "anime" ? "all" : filter;
    filtered = dropAnime(applyCalendarFilter(items, f));
    if (source === "all") filtered = filtered.filter((i) => !i.isAnime);
    if (source === "all" && watchlistOnly) {
      const names = buildLibraryNameSet(await libraryItems(authKey));
      filtered = filtered.filter((i) => names.has(`${normalizeName(i.name)}::${i.type === "tv" ? "tv" : "movie"}`));
    }
  }
  if (status === "ready" && filtered.length === 0) status = "empty";

  const showAllControls = source === "all";
  const showPremiereFilters = source === "simkl-anticipated";
  const filters = showAllControls || showPremiereFilters
    ? filtersShown.map((f) => ({
        id: f.id,
        label: t(f.label),
        count: f.id === "all" ? (showAllControls ? filtered.length : items.length) : applyCalendarFilter(items, f.id).length,
      }))
    : [];

  const grouped = groupByDate(filtered);
  const todayISO = todayLocalISO();
  const cells = buildMonthCells(year, monthIdx, !!s.weekStartsMonday).map((c) => ({
    iso: c.iso,
    day: c.date.getDate(),
    inMonth: c.inMonth,
    isToday: c.iso === todayISO,
    items: (grouped.get(c.iso) ?? []).map(toEntry),
  }));
  const { heading, body } = emptyCopy(source, filter, watchlistOnly, animeDub);
  const visible = OPTIONS.filter(
    (o) => (o.id !== "trakt" || trakt) && (o.id !== "simkl" || simkl) && (o.id !== "simkl-anticipated" || simkl),
  );
  return {
    year,
    month: monthIdx,
    monthLabel: `${t(MONTH_NAMES[monthIdx])} ${year}`,
    todayISO,
    source,
    sources: visible.map((o) => ({ ...o, label: t(o.label), hint: t(o.hint) })),
    traktConnected: trakt,
    simklConnected: simkl,
    signedIn: !!authKey,
    weekStartsMonday: !!s.weekStartsMonday,
    posterSize: s.calendarPosterSize === "large" ? "large" : "default",
    weekdays: orderedWeekdayNames(!!s.weekStartsMonday).map((d) => t(d)),
    animeDubToggle: source === "anime",
    animeDub,
    hideTypeTag: source === "anime",
    filters,
    filter,
    watchlistToggle: showAllControls,
    watchlistOnly,
    custom: source === "custom" ? { activeCount: buildActiveCount(s.customCalendar), summary: buildSummary(s.customCalendar, t) } : null,
    status,
    error,
    emptyHeading: heading,
    emptyBody: body,
    total: filtered.length,
    cells,
  };
}

// ------------------------------------------------------------------- preferences
function writeSettings(profileId: string, linked: boolean, patch: Partial<Settings>): Settings {
  const next = { ...loadEffective(profileId, linked), ...patch } as Settings;
  persistEffective(next, profileId, linked);
  const fields = Object.keys(patch);
  markSettingsPatched(fields);
  if (typeof window !== "undefined") window.dispatchEvent(new CustomEvent("harbor:settings-updated", { detail: { profileId, fields } }));
  return next;
}

/** The header toggles calendar.tsx writes through update(): source, week start, poster size. */
export function setPref(
  profileId: string,
  linked: boolean,
  patch: { calendarSource?: Source; weekStartsMonday?: boolean; calendarPosterSize?: "default" | "large" },
): boolean {
  const clean: Partial<Settings> = {};
  if (patch.calendarSource && OPTIONS.some((o) => o.id === patch.calendarSource)) clean.calendarSource = patch.calendarSource;
  if (typeof patch.weekStartsMonday === "boolean") clean.weekStartsMonday = patch.weekStartsMonday;
  if (patch.calendarPosterSize === "default" || patch.calendarPosterSize === "large") clean.calendarPosterSize = patch.calendarPosterSize;
  if (Object.keys(clean).length === 0) return false;
  writeSettings(profileId || "default", linked !== false, clean);
  return true;
}

// ----------------------------------------------------------- custom source rail
// calendar/config/config-rail.tsx: the same groups, chips and toggles, flattened for the remote.
export type RailChip = { key: string; label: string; selected: boolean };
export type CustomRail = {
  activeCount: number;
  summary: string;
  traktConnected: boolean;
  tmdbKey: boolean;
  mediaTypes: RailChip[];
  groups: Array<{ id: "genres" | "providers" | "countries" | "people"; title: string; count: number; summary: string; chips: RailChip[] }>;
  trakt: Array<{ key: string; label: string; sub: string; on: boolean; disabled: boolean }>;
};

export function customRail(profileId = "default", linked = true): CustomRail {
  const value = loadEffective(profileId || "default", linked !== false).customCalendar;
  const trakt = traktConnected();
  const sums = buildGroupSummaries(value, t);
  return {
    activeCount: buildActiveCount(value),
    summary: buildSummary(value, t),
    traktConnected: trakt,
    tmdbKey: !!loadEffective(profileId || "default", linked !== false).tmdbKey,
    // media-type-gate.tsx
    mediaTypes: [
      { key: "media:movie", label: t("Movies"), selected: value.mediaTypes.movie },
      { key: "media:tv", label: t("Series"), selected: value.mediaTypes.tv },
      { key: "media:anime", label: t("Anime"), selected: value.mediaTypes.anime },
    ],
    groups: [
      { id: "genres", title: t("Genres"), count: value.genres.length, summary: sums.genres,
        chips: buildGenreOptions(value, t, () => {}).map((c) => ({ key: `genre:${c.key}`, label: c.label, selected: c.selected })) },
      { id: "providers", title: t("Where to watch"), count: value.watchProviders.length, summary: sums.watchProviders,
        chips: WATCH_PROVIDERS.map((p) => ({ key: `prov:${p.id}`, label: p.name, selected: value.watchProviders.some((x) => x.id === p.id) })) },
      { id: "countries", title: t("Origin country"), count: value.originCountries.length, summary: sums.originCountries,
        chips: COUNTRIES.map((c) => ({ key: `cn:${c.code}`, label: t(c.name), selected: value.originCountries.includes(c.code) })) },
      // PeopleField: people are added by searching TMDB on the desktop; the TV lists and removes them.
      { id: "people", title: t("Track people"), count: value.trackedPeople.length, summary: sums.trackedPeople,
        chips: value.trackedPeople.map((p) => ({ key: `person:${p.id}`, label: p.name, selected: true })) },
    ],
    trakt: [
      { key: "trakt:anticipated", label: t("Trakt anticipated"), sub: t("Most-anticipated upcoming releases on Trakt"), on: value.includeTraktAnticipated, disabled: false },
      { key: "trakt:watchlist", label: t("My Trakt watchlist"), sub: trakt ? t("Upcoming items from your watchlist") : t("Connect Trakt in settings first"), on: value.includeTraktWatchlist, disabled: !trakt },
    ],
  };
}

/** One toggle from the rail: a chip key from customRail(), "clear" (Clear all) or "clear:<group>". */
export function customToggle(profileId: string, linked: boolean, key: string): CustomRail {
  const pid = profileId || "default";
  const lk = linked !== false;
  const value: CustomCalendar = loadEffective(pid, lk).customCalendar;
  let next: CustomCalendar | null = null;
  const [kind, ...rest] = key.split(":");
  const arg = rest.join(":");
  if (key === "clear") {
    next = { ...value, genres: [], watchProviders: [], originCountries: [], trackedPeople: [], includeTraktAnticipated: false, includeTraktWatchlist: false };
  } else if (kind === "clear") {
    const field = ({ genres: "genres", providers: "watchProviders", countries: "originCountries", people: "trackedPeople" } as const)[arg as "genres"];
    if (field) next = { ...value, [field]: [] };
  } else if (kind === "media" && (arg === "movie" || arg === "tv" || arg === "anime")) {
    next = { ...value, mediaTypes: { ...value.mediaTypes, [arg]: !value.mediaTypes[arg] } };
  } else if (kind === "genre") {
    // buildGenreOptions keys: "movie:<id>" / "tv:<id>"; the stored name is the untranslated key.
    const [mediaType, idRaw] = arg.split(":");
    const id = Number(idRaw);
    const table = mediaType === "movie" ? MOVIE_GENRES : mediaType === "tv" ? TV_GENRES : null;
    const name = table ? Object.entries(table).find(([, gid]) => gid === id)?.[0] : undefined;
    if (name && (mediaType === "movie" || mediaType === "tv")) {
      const exists = value.genres.some((g) => g.id === id && g.mediaType === mediaType);
      next = {
        ...value,
        genres: exists
          ? value.genres.filter((g) => !(g.id === id && g.mediaType === mediaType))
          : [...value.genres, { id, name, mediaType }],
      };
    }
  } else if (kind === "prov") {
    const provider = WATCH_PROVIDERS.find((p) => String(p.id) === arg);
    if (provider) {
      const exists = value.watchProviders.some((p) => p.id === provider.id);
      next = { ...value, watchProviders: exists ? value.watchProviders.filter((p) => p.id !== provider.id) : [...value.watchProviders, provider] };
    }
  } else if (kind === "cn") {
    if (COUNTRIES.some((c) => c.code === arg)) {
      const exists = value.originCountries.includes(arg);
      next = { ...value, originCountries: exists ? value.originCountries.filter((c) => c !== arg) : [...value.originCountries, arg] };
    }
  } else if (kind === "person") {
    next = { ...value, trackedPeople: value.trackedPeople.filter((p) => String(p.id) !== arg) };
  } else if (key === "trakt:anticipated") {
    next = { ...value, includeTraktAnticipated: !value.includeTraktAnticipated };
  } else if (key === "trakt:watchlist") {
    if (traktConnected()) next = { ...value, includeTraktWatchlist: !value.includeTraktWatchlist };
  }
  if (next) writeSettings(pid, lk, { customCalendar: next });
  return customRail(pid, lk);
}

// config/people-field.tsx: search TMDB people (searchAll, 8 results) and add one to the Custom
// filter as config-rail.tsx addPerson does ({id, name, profile, role: "any"}).
import { searchAll } from "@/lib/search";
export type PeopleHit = { id: number; name: string; profile: string | null; knownFor: string; tracked: boolean };
export async function customPeopleSearch(profileId: string, linked: boolean, query: string): Promise<{ needsKey: boolean; people: PeopleHit[] }> {
  const s = loadEffective(profileId || "default", linked !== false);
  const q = (query ?? "").trim();
  if (!s.tmdbKey) return { needsKey: true, people: [] };
  if (!q) return { needsKey: false, people: [] };
  const tracked = new Set(s.customCalendar.trackedPeople.map((p) => p.id));
  const r = await searchAll(s.tmdbKey, q).catch(() => null);
  const people = (r?.people ?? []).slice(0, 8).map((p) => ({ id: p.id, name: p.name, profile: p.profile ?? null, knownFor: p.knownFor ?? "", tracked: tracked.has(p.id) }));
  return { needsKey: false, people };
}
export function customAddPerson(profileId: string, linked: boolean, person: { id: number; name: string; profile: string | null }): CustomRail {
  const pid = profileId || "default";
  const lk = linked !== false;
  const value: CustomCalendar = loadEffective(pid, lk).customCalendar;
  if (person && Number.isFinite(person.id) && !value.trackedPeople.some((x) => x.id === person.id)) {
    writeSettings(pid, lk, { customCalendar: { ...value, trackedPeople: [...value.trackedPeople, { id: person.id, name: person.name, profile: person.profile ?? null, role: "any" }] } });
  }
  return customRail(pid, lk);
}

// ------------------------------------------------------------------------ reminders
// components/reminders-manager.tsx summary(): "Episodes + Seasons · Chime".
function reminderSummary(entry: ReminderEntry): string {
  const parts: string[] = [];
  if (entry.episodes) parts.push(t("Episodes"));
  if (entry.seasons) parts.push(t("Seasons"));
  const tone = entry.tone === "chime" ? t("Chime") : entry.tone === "pulse" ? t("Pulse") : t("Silent");
  return `${parts.join(" + ")} · ${tone}`;
}

// tvOS: nothing shows a system notification, so what the runner fired is kept until the viewer
// opens the calendar (the unseen list is upstream's; the message it carried is ours).
const FIRED_KEY = "harbor.reminders.fired.v1";
type Fired = { id: string; name: string; poster: string | null; body: string; at: number };
function readFired(): Fired[] {
  try {
    const raw = localStorage.getItem(FIRED_KEY);
    const arr = raw ? (JSON.parse(raw) as unknown) : [];
    return Array.isArray(arr) ? (arr as Fired[]).filter((f) => f && typeof f.id === "string") : [];
  } catch {
    return [];
  }
}
function writeFired(list: Fired[]): void {
  try {
    if (list.length === 0) localStorage.removeItem(FIRED_KEY);
    else localStorage.setItem(FIRED_KEY, JSON.stringify(list.slice(-50)));
  } catch {
    /* storage full: the toast still showed */
  }
}
function unseenIds(): string[] {
  try {
    const raw = localStorage.getItem("harbor.reminders.unseen.v1");
    const arr = raw ? (JSON.parse(raw) as unknown) : [];
    return Array.isArray(arr) ? arr.filter((x): x is string => typeof x === "string") : [];
  } catch {
    return [];
  }
}

export type ReminderRow = { id: string; name: string; poster: string | null; type: "movie" | "series"; summary: string; unseen: boolean };

/** useReminders(): newest first, with the manager's summary line. */
export function reminders(): ReminderRow[] {
  const unseen = new Set(unseenIds());
  return listReminders().map((r) => ({
    id: r.id,
    name: r.name,
    poster: r.poster ?? null,
    type: r.type,
    summary: reminderSummary(r),
    unseen: unseen.has(r.id),
  }));
}

/** The manager's remove button (removeReminder + "Reminder removed"). */
export function removeReminder(id: string): ReminderRow[] {
  removeUpstreamReminder(id);
  writeFired(readFired().filter((f) => f.id !== id));
  emitRemindersChanged();
  return reminders();
}

/** nav-items.tsx CalendarNavIcon: useUnseenReminderCount(), plus the messages behind it. */
export function unseen(): { count: number; fired: Fired[] } {
  const ids = new Set(unseenIds());
  return { count: ids.size, fired: readFired().filter((f) => ids.has(f.id)) };
}

/** calendar.tsx mount: clearUnseenReminders(). Returns what was unseen so the room can show it once. */
export function clearUnseen(): Fired[] {
  const out = unseen().fired;
  clearUnseenReminders();
  writeFired([]);
  emitRemindersChanged();
  return out;
}

function emitRemindersChanged(): void {
  if (typeof window !== "undefined") window.dispatchEvent(new CustomEvent("harbor:reminders-changed", { detail: { count: unseenIds().length } }));
}

// lib/reminders-runner.tsx, without the component: first check 25 s after start, then every 6 h.
const FIRST_CHECK_MS = 25_000;
const CHECK_EVERY_MS = 6 * 60 * 60 * 1000;
const DAY_OF_WINDOW_MS = 36 * 60 * 60 * 1000;
let running = false;
let runnerProfile: { id: string; linked: boolean } = { id: "default", linked: true };
let firstTimer: ReturnType<typeof setTimeout> | null = null;
let intervalTimer: ReturnType<typeof setInterval> | null = null;

function fire(entry: ReminderEntry, body: string): void {
  // fireReminderNotification: no system notification or Web Audio on tvOS; emitListToast
  // becomes the harbor:reminder-fired event the shell shows as its toast.
  const note: Fired = { id: entry.id, name: entry.name, poster: entry.poster ?? null, body, at: Date.now() };
  writeFired([...readFired().filter((f) => f.id !== entry.id), note]);
  markReminderUnseen(entry.id);
  if (typeof window !== "undefined") {
    window.dispatchEvent(new CustomEvent("harbor:reminder-fired", { detail: { ...note, text: `${entry.name}: ${body}`, tone: entry.tone } }));
  }
  emitRemindersChanged();
}

async function checkOne(entry: ReminderEntry, tmdbKey: string, now: number): Promise<void> {
  if (entry.type === "movie") return;
  const meta: Meta = { id: entry.id, type: "series", name: entry.name };
  const eps = await fetchEpisodeList(meta, { tmdbKey });
  if (!eps.length) return;
  const aired = eps
    .map((e) => ({ ...e, at: e.airDate ? Date.parse(e.airDate) : NaN }))
    .filter((e) => Number.isFinite(e.at) && e.at <= now)
    .sort((a, b) => a.at - b.at);
  const keyOf = (e: { season: number; episode: number }) => `${e.season}x${e.episode}`;
  const airedKeys = aired.map(keyOf);
  if (!entry.seenKeys) {
    setReminderSeen(entry.id, airedKeys, now);
    return;
  }
  const seen = new Set(entry.seenKeys);
  const fresh = aired.filter((e) => !seen.has(keyOf(e)) && now - e.at <= DAY_OF_WINDOW_MS && e.at > entry.createdAt);
  if (fresh.length) {
    const prevMaxSeason = aired.reduce((m, e) => (seen.has(keyOf(e)) && e.season > m ? e.season : m), 0);
    const premiere = fresh.find((e) => e.season > prevMaxSeason);
    if (entry.seasons && premiere) {
      fire(entry, t("Season {n} has started", { n: premiere.season }));
    } else if (entry.episodes) {
      const last = fresh[fresh.length - 1];
      const body =
        fresh.length === 1
          ? t("S{s} E{e} is out now", { s: last.season, e: last.episode })
          : t("{n} new episodes are out", { n: fresh.length });
      fire(entry, body);
    }
  }
  setReminderSeen(entry.id, Array.from(new Set([...entry.seenKeys, ...airedKeys])), now);
}

/** checkAll(): every reminder once; a failure keeps its window for the next cycle. */
export async function checkReminders(profileId?: string, linked?: boolean, nowMs?: number): Promise<number> {
  if (running) return 0;
  running = true;
  const before = unseenIds().length;
  try {
    const p = profileId ? { id: profileId, linked: linked !== false } : runnerProfile;
    const tmdbKey = loadEffective(p.id, p.linked).tmdbKey ?? "";
    for (const entry of listReminders()) {
      try {
        await checkOne(entry, tmdbKey, nowMs ?? Date.now());
      } catch {
        /* keep window; retried next cycle */
      }
    }
  } finally {
    running = false;
  }
  return Math.max(0, unseenIds().length - before);
}

/** RemindersRunner mount; calling again only switches which profile's TMDB key the checks use. */
export function startReminders(profileId = "default", linked = true): boolean {
  runnerProfile = { id: profileId || "default", linked: linked !== false };
  if (intervalTimer) return false;
  const run = () => {
    if (listReminders().length === 0) return;
    void checkReminders();
  };
  firstTimer = setTimeout(run, FIRST_CHECK_MS);
  intervalTimer = setInterval(run, CHECK_EVERY_MS);
  return true;
}

export function stopReminders(): void {
  if (firstTimer) clearTimeout(firstTimer);
  if (intervalTimer) clearInterval(intervalTimer);
  firstTimer = null;
  intervalTimer = null;
}

/** use-now.ts formatRemaining, for the "in 2d 4h 10m" airing countdown. */
export function remaining(ms: number): string {
  return formatRemaining(ms);
}
