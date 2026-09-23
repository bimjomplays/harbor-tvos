# Harbor Big Picture Sports Room — Native Port Spec (Stage 9)

Scope: exact data sourcing, gating, layout logic and watch/play resolution for the
Big Picture "Sports" room — `src/views/big-picture/bp-sports.tsx` and everything
under `src/views/big-picture/sports/`, plus the `src/lib/sports/*` modules that feed
it. File paths are relative to `reference/harbor` (repo root) unless stated
otherwise. Every claim cites `file:line`; anything not found after a grep is marked
**not found** rather than guessed.

Cross-references (not repeated here):
- **Visual/layout anatomy** (tile sizes, focus scale, row gaps, hero geometry) not
  specific to Sports is in `docs/big-picture-design.md`.
- **IPTV playlist storage, channel/EPG parsing, player hand-off mechanics** are in
  `docs/livetv-spec.md` — this doc only covers how Sports *matches* a game to an
  already-parsed `IptvChannel`, not how playlists are fetched/parsed.
- **Settings storage scheme** (`harbor.settings*` keys) is in `docs/harbor-protocol.md`.

---

## 1. DATA SOURCES AND GATING

### 1.1 Consent gate

`BpSports` (`src/views/big-picture/bp-sports.tsx:35-43`) reads sports consent via
`useSyncExternalStore` on `subscribeSportsConsent`/`getSportsConsentSnapshot`
(`src/lib/sports/consent.ts`) and renders `<BpSportsConsent />`
(`src/views/big-picture/sports/bp-sports-consent.tsx`) for **any** status other than
`"accepted"` — i.e. both `"unknown"` (first visit) and `"declined"` show the notice
screen (`bp-sports.tsx:41`). Only once accepted does `<BpSportsPage />` (the room
itself) render.

Consent model (`src/lib/sports/consent.ts`):
- `SPORTS_CONSENT_VERSION = 1`, storage key `SPORTS_CONSENT_KEY =
  "harbor-sports-consent"` (`consent.ts:1-2`), written as JSON to
  `localStorage` via `storage().setItem(...)` (`consent.ts:88`).
- Snapshot shape: `{ version: number; status: "unknown"|"accepted"|"declined";
  acceptedAt?: string; declinedAt?: string; persisted: boolean }`
  (`consent.ts:5-11`).
- A stored receipt with a mismatched `version` or a missing/invalid ISO
  timestamp is discarded back to `UNKNOWN` (`consent.ts:34-52`) — the port must
  version its own receipt the same way if the schema ever changes.
- `acceptSportsConsent()` / `declineSportsConsent()` / `resetSportsConsent()`
  are the only mutators (`consent.ts:109-111`); declining from inside the room
  also switches the active Big Picture tab to `"live"`
  (`bp-sports-consent.tsx:107-110`).
- Cross-tab/cross-window sync listens on the `storage` DOM event
  (`consent.ts:125-136`) — a native port has no equivalent and can drop this.

Consent screen content (`bp-sports-consent.tsx`): a scrollable notice built from
`SPORTS_USAGE_SUMMARY`, `SPORTS_USAGE_SECTIONS`, `SPORTS_USAGE_DETAILS`,
`SPORTS_POLICY_LINKS` (`src/lib/sports/usage-notice.ts`, not opened in this pass —
these are plain translated strings, not logic), a single "I understand…" acknowledge
toggle that must be checked before "Agree and open Sports" activates
(`bp-sports-consent.tsx:69-185`), and "Decline and hide Sports".

### 1.2 Tab visibility vs. desktop "available" gating (two different gates)

These are **not the same check** and a native port only needs the first one:

- **Big Picture tab visibility** — the "Sports" tab in the BP top bar is hidden
  only when `consent.status === "declined"` (`src/views/big-picture/bp-top-bar.tsx:125,
  144-149` `useBpTabGate`/`visibleTabs`). It is **not** gated on having any Live TV
  source configured. Comment at `bp-top-bar.tsx:203-206` explains Live TV's tab is
  deliberately ungated for the same reason.
- **Desktop settings "available" flag** — `SportsAccessRow`
  (`src/views/settings/sports-access-row.tsx:19`) additionally requires
  `hasSportsSource(usePlaylists())` (`src/lib/sports/enabled.ts:8-20`: true if any
  non-`epg` playlist has a non-empty `url` or complete Xtream
  `server`/`username`/`password`) before the desktop "Show Sports" toggle can be
  turned on. `useSportsEnabled()` (`enabled.ts:21-29`) — `hasSportsSource(...) &&
  consent.status !== "declined"` — gates the **desktop** nav item
  (`src/chrome/nav-items.tsx:2,294-295`) and the top-level `App.tsx` sports route
  (`src/App.tsx:1344-1348`). **The Big Picture room itself does not call
  `useSportsEnabled` anywhere** (grep of `src/views/big-picture` found no hit) — on
  tvOS, showing the Sports tab need not depend on any Live TV/IPTV source existing.

### 1.3 ESPN public scoreboard — the no-key baseline

Base URL: `SITE_BASE = "https://site.api.espn.com/apis/site/v2/sports"`
(`src/lib/sports/espn-leagues.ts:9`). No API key, no auth header on any of these
requests (plain `safeFetch`, `src/lib/sports/espn-scoreboard.ts:1,39,65`).

**Per-league scoreboard** (used by the simple, non-hub `fetchSports`/`fetchLeague`
path in `espn-scoreboard.ts`, and by `fetchHubSlice`'s ESPN branch in
`src/lib/sports/hub-data.ts:304-329`):
```
GET {SITE_BASE}/{league.path}/scoreboard?dates={YYYYMMDD}
GET {SITE_BASE}/{league.path}/scoreboard?dates={YYYYMMDD}&limit=200   (day/live mode)
GET {SITE_BASE}/{league.path}/scoreboard?dates={YYYYMM}&limit=200     (upcoming mode, per touched month, hub-data.ts:320-324)
```
`league.path` is one entry per league in the `LEAGUES` table
(`espn-leagues.ts:37-337`, e.g. `"soccer/eng.1"` for EPL, `"basketball/nba"` for
NBA, `"football/nfl"` for NFL, `"baseball/mlb"` for MLB, `"hockey/nhl"` for NHL,
`"mma/ufc"` for UFC, `"racing/f1"` for F1, `"tennis/atp"`/`"tennis/wta"`,
`"golf/pga"`, `"rugby/164205"`). `DEFAULT_SPORTS_LEAGUES = ["ROSHN","EPL","UCL",
"NBA","NFL"]` (`espn-leagues.ts:344`) is a narrower legacy default not used by the
BP room (it uses `HUB_DEFAULTS`, §1.5).

**Aggregate soccer board** (one request covers dozens of competitions instead of
one request per league): `GET {SITE_BASE}/soccer/all/scoreboard?dates={day}&limit=1000`
(`hub-data.ts:246-249`), parsed by `parseSoccerBoard` (`hub-data.ts:372-381`) which
maps each event's `competitions[0].altGameNote` (a "League Name, Round" string) back
to a `LEAGUES` entry via the `SOCCER_ALIASES` table (`hub-data.ts:344-370`) — events
whose league name has no alias entry are silently dropped. `liveScoreboardKeys`
(`src/lib/sports/live-schedule.ts:5-16`) always substitutes the key `"SOCCER_ALL"`
in place of every individual soccer league for the live/board fetch, so only one
soccer request is made regardless of how many soccer leagues are selected.

**Live scoreboard variant** (mode `"live"`): fetched through
`fetchLiveScoreboardEvents` (`src/lib/sports/live-scoreboard.ts`, not opened in
depth — signature at `hub-data.ts:14`) hitting the same `scoreboard` path with a
UTC date-range query built by `liveDateRange` (`live-schedule.ts:19-25`, format
`YYYYMMDD-YYYYMMDD`, spanning yesterday+today so games crossing midnight UTC are
still returned).

**Per-team schedule** (used by favourites, not by the BP room's rows directly):
`GET {BASE}/{league.path}/teams/{teamId}/schedule`, retried with
`?season={currentYear}` if the first response has zero events
(`src/lib/sports/favourites.ts:390-399`).

**Game summary / detail** (opened from the game card, §4):
`GET {SITE_BASE}/{league.path}/summary?event={eventId}` (`src/lib/sports/
espn-summary.ts:113`), routed through `fetchGameSummary` → `fetchMatchSummary`
(`src/lib/sports/provider.ts:166-183`, `espn-summary.ts:214`) only when
`game.source` is the ESPN provider id (default when `source` is unset). Cached 25 s
client-side in `src/views/sports/use-match-detail.ts:11`.

**Fetch behavior/caching in `espn-scoreboard.ts`** (the simpler, legacy path — used
outside the hub for team schedules and non-hub `fetchSports` callers):
- `TTL = 10_000` ms for the "current day, no explicit date" cache entry, `DATED_TTL
  = 120_000` ms for any other cached date (`espn-scoreboard.ts:6-7`).
- In-memory `Map` cache keyed by `` `${league}@${dates}` `` or bare `league`,
  capped at `LEAGUES.length * 3 + 64` entries with LRU eviction
  (`espn-scoreboard.ts:9-32`).
- `FETCH_CONCURRENCY = 8` (pooled worker loop, `espn-scoreboard.ts:8,127-143`).
- If a league's scoreboard returns zero events for "today" it walks the league's
  own published `calendar` array backwards, sampling every 3rd past date (max 10
  candidates), then finally falls back to walking day-by-day up to 60 days back
  looking for the last results (`espn-scoreboard.ts:79-107`) — this "self-healing
  when the season is between rounds" behavior only exists in this legacy path, not
  in the hub's `fetchHubSlice`.

**The hub's own caching** (`fetchHubSlice`/`useSportsHub`/`hub-cache.ts` — the path
the BP room actually uses, §1.5) is a *different* cache with different TTLs:
- `freshFor(key)` in `src/lib/sports/hub-cache.ts:14`: **15 min** if the cache key
  ends `@upcoming`, else **90 s**.
- `useSportsHub` (`src/views/sports/use-hub.ts`) re-polls on an interval of
  **15 min** for `mode === "upcoming"`, else **60 s**
  (`use-hub.ts:84`), and forces a fetch bypassing any cached slice younger than
  `maxAge` — 15 min for upcoming, **15 s** for day/live modes, or `0` (forced) on
  the first run after an explicit user refresh (`use-hub.ts:77`).
- Each league/day/mode slice is persisted via `readSportsSlice`/`saveSportsSlice`
  (`src/lib/sports/slice-storage.ts`, re-exported at `hub-cache.ts:6`, not opened in
  this pass) so a cold app start can render instantly from disk
  (`cachedSportsSnapshot`, `hub-cache.ts:61-81`) before any network request lands.
  Stale-but-present data is rendered with a synthesized `savedAt` timestamp
  (`hub-cache.ts:52-58`) — this is what puts "Saved" badges on cards (§3.4).

### 1.4 Free feeds beyond ESPN (also no key)

`HUB_LEAGUES` (`src/lib/sports/hub-data.ts:39-67`) is the full catalog the BP room
selects from — `LEAGUES` (ESPN, §1.3) plus several additional free sources, all
routed through `fetchHubSlice` (`hub-data.ts:206-342`):
- **TheSportsDB** (`DB = "https://www.thesportsdb.com/api/v1/json/123"`,
  `hub-data.ts:20`) for any league whose `path` is purely numeric (a TheSportsDB
  league id) — e.g. Dota/LoL/RLCS esports leagues, boxing orgs, motorsport series
  added via `dbLeague(...)` (`hub-data.ts:24-38,46-66`). Endpoints:
  `{DB}/eventsnextleague.php?id={path}` (upcoming) or
  `{DB}/eventsday.php?d={ISO date}&l={path}` per day (`hub-data.ts:285-303`).
- **OpenDota** (`https://api.opendota.com/api/proMatches`,
  `https://api.opendota.com/api/live`) for `DOTA2` (`hub-data.ts:216-235`).
- **ONE Championship** schedule scraper for `ONE` (`src/lib/sports/providers/
  one-schedule.ts`, not opened; call site `hub-data.ts:208-215`).
- **Boxing**: `fetchBoxingCalendars` (organizer calendars) merged with TheSportsDB
  day feeds via `mergeBoxingGames` (`src/lib/sports/providers/boxing-schedule.ts`,
  not opened; call site `hub-data.ts:262-284`).
- **Market odds** (event-detail extra, not a game-list source): Polymarket public
  search, `https://gamma-api.polymarket.com/public-search`
  (`src/views/big-picture/sports/bp-sports-extra-odds.tsx:21,56`), parsed by
  `parseMarketOdds` (`src/lib/sports/market-odds.ts:22-72`) matching on team names +
  a 6-hour start-time window; gated off for kid profiles
  (`bp-sports-extra-odds.tsx:140`, `useActiveKid`) and by `settings.sportsShowOdds`
  (§5).
- **Featured artwork**: TheSportsDB lookups for a fixed 5-league set
  (`LEAGUE_IDS` = F1/NBA/EPL/UFC/BOXING, `src/lib/sports/hub-artwork.ts:14-20`),
  cached to `localStorage` key `"harbor.sports.featured-artwork.v1"`
  (`hub-artwork.ts:10`), 7-day retention (`RETAIN_MS`, `hub-artwork.ts:12`), max 40
  entries (`MAX_ENTRIES`, `hub-artwork.ts:11`).

None of the above require any credential.

### 1.5 api-sports paid key

Only **4** `HUB_LEAGUES` entries route to the paid provider: `HUB_TO_API = { EGYPT:
"EGY", QATAR: "QSL", UAE: "UAE", KHL: "KHL" }` (`src/lib/sports/api-hub-leagues.ts:6`).
For any other league the key is irrelevant.

- **Storage**: key name `"harbor.sports.api-sports.v1"`
  (`src/lib/sports/api-credentials.ts:3`), stored through Harbor's device secret
  store (`src/lib/secret-store.ts` — Tauri-backed, `invoke("secrets_write", …)`,
  **desktop/Tauri-only**, §6), read with `readSportsApiKey()`
  (`api-credentials.ts:15-17`), written with `saveSportsApiKey(value)`
  (`api-credentials.ts:19-25`), which bumps an in-memory `revision` counter that
  invalidates the credential-scoped hub cache (`api-credentials.ts:6,23-24`;
  consumed by `sportsApiRevision()`/`subscribeSportsApiCredentials` in
  `src/views/sports/use-hub.ts:9,20-21,32-33,58-61`).
- **Settings UI**: `SportsApiSetting` (`src/views/settings/sports-api-setting.tsx`)
  — Section title `"Sports metadata"`, subtitle `"Optional schedules and scores for
  selected {football} and hockey competitions…"` (`sports-api-setting.tsx:49-54`), a
  single free-text `KeyField` labeled `"API-Sports key"` with a "Clear key" action
  (`sports-api-setting.tsx:61-85`); saving does **not** verify the key
  (`sports-api-setting.tsx:88-91`). Lists the 4 gated leagues by label
  (`sports-api-setting.tsx:56-59`).
- **Fetch routing**: `fetchHubSlice` only calls the paid provider when `mode !==
  "upcoming"` and a key is present (`hub-data.ts:255-261`, `optionalApiHubSlice`,
  `api-hub-leagues.ts:11-35`); on failure or when unavailable it silently falls
  through to the public path for that league — **the key is additive, never
  required** (comment at `api-hub-leagues.ts:5` and `hub-data.ts:260`).
  `api-hub-cache.ts` keeps paid-source slices in a separate in-memory-only cache
  (never `localStorage`) that is cleared whenever the credential changes
  (`src/lib/sports/api-hub-cache.ts:6-31`).

### 1.6 Enabled sports/leagues (personalization)

- **Storage keys**: `settings.sportsLeagues: string[]`, default `[]`
  (`src/lib/settings/defaults.ts:409`, type at `src/lib/settings/types.ts:488`) —
  part of the general settings blob, not a bespoke key. Migration note: if a saved
  list contains `"TENNIS"` without `"TENNIS_WTA"`, the WTA tour is auto-added on
  load (`src/lib/settings/load.ts:247-248`). Favourite **teams** (distinct from
  followed leagues) live in their own store, key `"harbor.sports.favourites.v1"`
  (`src/lib/sports/favourites.ts:33`), shape `SportsFavourites = { personalized?:
  boolean; leagues: string[]; teams: FavouriteTeam[]; home: Record<string, string> }`
  (`favourites.ts:22-27`) — note `favourites.leagues` and `settings.sportsLeagues`
  are two separate arrays; the BP room's "which leagues am I following" logic reads
  `settings.sportsLeagues`, not `favourites.leagues`.
- **Selection resolution**: `selectedSportsLeagues(catalog, saved, personalized,
  defaults)` (`src/lib/sports/personalization.ts:4-14`) — returns `saved` if
  `saved.length > 0` **or** `favourites.personalized === true`; otherwise returns
  `HUB_DEFAULTS` (a 40+ league starter list spanning soccer, US majors, combat,
  motorsport, tennis, golf, esports etc., `hub-data.ts:75-126`). An intentionally
  *empty* saved selection (after the user has been through onboarding once) is
  respected and does **not** silently repopulate defaults (comment at
  `personalization.ts:3`).
- **Personalize flow**: `BpSportsPersonalize`
  (`src/views/big-picture/sports/bp-sports-personalize.tsx`) is a 3-step wizard,
  titles `"Choose your sports"` → `"Pick your leagues"` → `"Follow your teams"`
  (`bp-sports-personalize.tsx:31`):
  1. Sport/group grid (`HUB_GROUPS` deduped by key) with a `"Use popular leagues"`
     shortcut that sets `leagues = [...HUB_DEFAULTS]`
     (`bp-sports-personalize.tsx:186-188`); toggling a group on adds its first 3
     leagues (`bp-sports-personalize.tsx:122-130`).
  2. Per-sport league grid limited to leagues in the chosen groups
     (`bp-sports-personalize.tsx:76-78,205-218`).
  3. Team picker, skipped for "event" groups (`combat`, `boxing`, `esports`,
     `motorsport`, `golf`, `tennis`, `EVENT_GROUPS` at
     `bp-sports-personalize.tsx:30`) — teams are fetched per league via
     `fetchLeagueTeams` (`favourites.ts:323-329`) with cached/loading/error/partial
     states (`bp-sports-personalize.tsx:98-120,220-287`).
  - **Save**: `writeFavourites({ ...fav, personalized: true, teams, leagues, home:
    <pruned> })` then `update({ sportsLeagues: leagues })`
    (`bp-sports-personalize.tsx:152-168`) — writes to **both** stores on save.
  - Entry points into this flow: the `"Make it yours"` chip
    (`bp-sports-chips.tsx:81-88`), the empty-state CTA (`bp-sports-empty.tsx:94-106`),
    and (browse-mode fallback) the personalize chip in `bp-sports.tsx:184`.

---

## 2. DATA MODEL

### 2.1 `SportsGame` and related types, verbatim (`src/lib/sports/espn-types.ts`)

```ts
export type SportsSide = {
  id: string;
  name: string;
  abbr: string;
  logo: string;
  score: string;
  winner: boolean;
  periods?: { period: number; value: string; winner?: boolean; tiebreak?: string }[];
  currentPoint?: string;
  serving?: boolean;
  /** Published overall record from this competition's scoreboard. */
  record?: string;
  /** Published top25 poll ranking; absent for unranked competitors. */
  rank?: number;
};

export type EventContext = {
  id: string;
  name: string;
  round: string;
  draw: string;
  venue: string;
  major: boolean;
  court?: string;
  bestOf?: number;
};

export type SportsGame = {
  /** Present only when displaying a cached slice that has not refreshed successfully. */
  savedAt?: number;
  id: string;
  league: string;
  state: "pre" | "in" | "post";
  detail: string;
  home: SportsSide;
  away: SportsSide;
  startMs: number;
  /** Published calendar date (YYYY-MM-DD) when no start time is available; startMs is a sort anchor. */
  dateOnly?: string;
  context?: EventContext;
  source?: string;
  artwork?: string;
  poster?: string;
  broadcasts?: string[];
};
```
(`espn-types.ts:1-45`.) `LeagueDef` (`espn-types.ts:161-170`): `{ key, label,
labelEn, labelRu?, tag, path, logo, group }`. `SportsMatchDetail = SportsGame & {
baseball?, football?, homeFormation?, awayFormation?, homeRoster, awayRoster,
homeStats, awayStats, allStats, playerStats?, partnerships?, events,
homeProfile?, awayProfile? }` (`espn-types.ts:120-135`) — the richer type behind
the event-detail rows (§4).

### 2.2 Fields the TV room renders, and where

| Field | Rendered where | Notes |
|---|---|---|
| `home`/`away` name, `abbr`, `logo`, `record`, `rank` | `BpSportsCard` (`bp-sports-card.tsx:136-173`), `BpSportsHero` (`bp-sports-hero.tsx`), `BpSportsEventHero` (`bp-sports-event-hero.tsx:46-105`) | Logo resolved through `BpSportsMark`/`BpSportsLeagueMark` fallback chain (§2.3). `rank` shown as `#{n}` prefix only when present (`bp-sports-card.tsx:153-158`). |
| `home.score`/`away.score` | Card side rows (`bp-sports-card.tsx:166-170`), hero (`"{home} - {away}"`, `bp-sports-hero.tsx:204`), event hero (`"{away} : {home}"`, `bp-sports-event-hero.tsx:245`) | Only shown once `state !== "pre"` and not for a `savedAt`-stale card (`scored` flag, `bp-sports-card.tsx:194`). Empty score renders `"0"`. |
| `state` | Status pill/text — Live (`bp-live` color dot + `detail`), Final, or a formatted date/countdown (§3.4) | `BpSportsState` (`bp-sports-card.tsx:92-134`). |
| `detail` | Live clock text next to the "Live" pill (card + hero + event hero) | e.g. ESPN's `shortDetail` ("Q3 4:12"). |
| `startMs`/`dateOnly` | Countdown (<90 min: relative time via `Intl.RelativeTimeFormat`) or formatted date (`formatSportsEventDate`, `src/lib/sports/event-date.ts`) | `dateOnly` (calendar-only events) is formatted in UTC, never local TZ (`event-date.ts:13-18`) — see §3.4 for exact rule. |
| `league` (ESPN `tag`) | League chip icon/label everywhere via `hubLeague(tag)` → `getLeagueLabel(def)` | `HUB_LEAGUES.find(l => l.tag === tag)` (`hub-data.ts:127`). |
| `context.{name,round,draw,venue,major}` | Event title, `matchCardContext` stage/venue rows on the card's "quiet" line, event-hero facts strip | `matchCardContext` (`src/lib/sports/card-context.ts:32-53`). |
| `broadcasts` | Card "quiet" line (as a `kind:"broadcast"` context row), watch-resolution input (§2.4) | Array of raw broadcaster names from ESPN `competition.broadcasts[].names` (`src/lib/sports/espn-parse.ts:186-188`). |
| `artwork`/`poster` | Single-subject card art, hero/backdrop art (§2.3) | Only TheSportsDB-sourced games (`parseDbEvents`, `hub-data.ts:174-175`) populate these from the feed directly; ESPN games get artwork from `hub-artwork.ts` (§1.4) or generic "scenery" photos. |
| `savedAt` | "Saved" badge (card, hero note, event hero) | Set by `renderedSlice()` when a cached slice is older than `freshFor()` (`hub-cache.ts:52-58`) — signals a failed refresh, not intentionally-stale UX. |
| `source` | Drives provider-specific behavior: which detail endpoint to call (§4), boxing/ONE "visit official page" provenance notes (`bp-sports-event-hero.tsx:161-174`), OpenDota "view match statistics" external-link action (`use-bp-sports-event.ts:211-217`) | Values seen: unset/`"espn"`, `"thesportsdb-hub"`, `"api-sports"`, `"opendota"`, `"official-boxing"`, `"official-one"`. |

### 2.3 Artwork resolution

`useSportsArtwork(game)` (`src/views/sports/use-artwork.ts`) → `cachedArtwork`/
`fetchSportsArtwork` (`src/lib/sports/hub-artwork.ts`) returns `{ backdrop?,
poster?, home?, away? }` (only for the 5 `LEAGUE_IDS` leagues, §1.4). Card art
(`bpSportsCardArt`, `src/views/big-picture/sports/bp-sports-art.ts:67-70`) is only
used for "single subject" games (`bpSportsSingleSubject`, `bp-sports-art.ts:49-51`
— events with a named `context` and either no `away` side or a group in
`SINGLE_SUBJECT = {combat, boxing, esports, golf, motorsport}`), preferring
`game.artwork` → `game.poster` → a generic per-sport "scenery" photo at
`/sports/hero-photos/{group}.webp` (`bp-sports-art.ts:53-70`; scenery photo set:
`SCENERY_GROUPS`, `bp-sports-art.ts:6-34`, one static asset per sport, defaulting to
`soccer` if the group isn't in the set). Backdrop layering/cross-fade logic (image
candidate list, decode-before-commit, Ken Burns drift) is in
`bp-sports-backdrop.tsx:58-122` and is desktop-DOM-specific (§6).

### 2.4 Watch resolution — exact matching rules

"Watch" for a game resolves through up to 4 independent sources, tried in this
priority order by `useBpSportsWatch`'s `plan` state machine
(`src/views/big-picture/sports/bp-sports-watch.tsx:103-122`):

1. **A manually-attached web stream** for this exact game id (`attachments.streams
   [game.id]`, plan `"stream"`) — set via "Paste a stream" (`AddStreamDialog`, not
   opened in this pass) and stored under `localStorage` key
   `"harbor.sports.sources.v1"` (`src/views/sports/source-store.ts:3`), shape
   `Attachments = { channels: Record<leagueTag,string[]>; streams:
   Record<gameId,AttachedStream> }` (`source-store.ts:14-17`).
2. **Official/organizer broadcasts** (`useBpOfficialBroadcasts`,
   `src/views/big-picture/sports/bp-sports-broadcast-source.ts:99-124`, plan
   `"broadcast"`) — a static curated list `SPORTS_BROADCASTS` keyed by `league`
   (`src/lib/sports/broadcasts.ts:12-47`, e.g. RLCS → Twitch `RocketLeague`, LEC →
   Twitch `lec`, Dota TI → Twitch `dota2ti`) merged with a live esports-feed lookup
   (`fetchEsportsFeed`, matched to the game by team-name overlap within a ±3 h
   window, `bp-sports-broadcast-source.ts:33-79`).
3. **A matched Live TV/IPTV channel** from the user's own playlists
   (`matchChannelsForGameAsync`, plan `"channel"` if an `"exact"`-tier match exists,
   else `"picker"` to let the user choose among weaker matches) — the scoring
   algorithm, below.
4. **Addon-provided listings** (Stremio addon catalogs whose name/id suggests
   sports/TV content, plan `"addons"`) — matched via
   `sportsAddonListings`/`mergeSportsAddonListings`
   (`src/lib/sports/addon-sources-model.ts:126-194`).
5. If none of the above and no Live TV source exists at all, plan is `"setup"` →
   pressing Watch jumps to the Live TV tab (`bp-sports-watch.tsx:181-184`).

**Channel matching algorithm** (`src/lib/sports/iptv-match.ts`,
`matchChannelsForGame`, `iptv-match.ts:339-416`) — run per channel in the user's
prepared sports-relevant channel index (`buildSportsChannelIndex` filters to
channels whose normalized name/group matches a sports-network regex or contains
"vs"/"versus", `iptv-match.ts:225-244`):
- Channel names are normalized: strip a leading country-flag/bracket region prefix
  (`stripPrefix`, `iptv-match.ts:95-110`), Arabic-normalize, lowercase, strip
  diacritics/quality markers, collapse to single spaces (`normalizeChannelName`,
  `iptv-match.ts:112-120`).
- **Scoring weights** (`iptv-match.ts:76-91`):

  | Signal | Weight |
  |---|---|
  | Both teams' full name phrase present | `W_TEAM_BOTH = 60` |
  | One team matched (phrase or ≥2 significant word tokens, or 1 token ≥5 chars and not a common word) | `W_TEAM_ONE = 26` |
  | Only weak (abbreviation-only) team hits, ≥2 | `W_TEAM_WEAK = 16` |
  | League keyword phrase in channel name | `W_LEAGUE = 34` |
  | League *group* keyword only | `W_LEAGUE_GROUP = 12` |
  | Known TV network airs this exact league | `W_NET_LEAGUE = 30` |
  | Known network airs this sport group | `W_NET_GROUP = 14` |
  | Known network, any sport | `W_NET_ANY = 6` |
  | Network's region matches league's region | `+W_NET_REGION = 6` |
  | Broadcast-listing name exact substring match | `W_LISTING_EXACT = 34` |
  | Listing brand prefix match, no channel-number conflict | `W_LISTING_BRAND = 14` |
  | Listing brand + matching channel number | `W_LISTING_NUMBER = 26` |
  | Listing brand matched but channel number conflicts | **`-16`** (`P_LISTING_NUMBER`) |
  | Channel region fits league region | `+W_REGION = 5` (×1 or ×2 via `regionStrength`) |

  Plus an **event-identity score** from `createEventChannelMatcher`
  (`src/lib/sports/event-match.ts:22-71`): `both` (both team surnames/last-name
  tokens found, or a "X vs Y" title pair matched) → `+120`; `numberMatch` (e.g.
  `"UFC 305"` event number matches a `"UFC 305"` token in the channel name) →
  `+95`; a hard **conflict** (event number mismatch, a date token in the channel
  name >1 day off the game's day, or the channel name contains
  "ended/replay/rerun/highlights/classic") **excludes the channel entirely** unless
  it is already user-attached (`iptv-match.ts:366-367,398`).
- A channel is only kept if `attached` (pinned by the user) or total `score >= FLOOR
  = 20` (`iptv-match.ts:91,398`). `confidence = score / SATURATION` where
  `SATURATION = 92`, clamped to `[0,1]` (`iptv-match.ts:90,399`).
- **Tier**: `"exact"` if `attached` or an event/number match fired or confidence ≥
  0.85; `"likely"` if confidence ≥ 0.5; else `"possible"`
  (`tierOf`, `iptv-match.ts:334-337,404-408`).
- Results are sorted attached-first, then by "event specificity" (TV-guide matchup
  > event-name matchup > any event signal > none), then by raw score, then label
  (`compareChannelMatches`, `iptv-match.ts:418-431`), and capped to `opts.limit`
  (default 8, `iptv-match.ts:342,415`).
- `bestChannelForGame` (`iptv-match.ts:456-462`) is the top-1 match, used by
  `useBpWatchGame` (`bp-sports-broadcast-play.ts:79-100`) for the hero/card's direct
  "tap to watch a live game" shortcut — it only auto-plays when that top match's
  tier is exactly `"exact"` (`bp-sports-broadcast-play.ts:94`).
- An **EPG cross-check** upgrades a candidate to a guaranteed match: if the user's
  guide has a program airing on that channel at `game.startMs` whose title itself
  passes the event matcher (no conflict, and `both`/`numberMatch`), that's treated
  as `"TV guide matchup"`, the highest specificity tier
  (`iptv-match.ts:357-365,420-421`).

**Addon-source matching** (`src/lib/sports/addon-sources-model.ts`): a Stremio
catalog counts as "sports" if it advertises type `tv`/`channel`/`sport(s)`/
`event(s)`/`live`, or the addon/catalog id or name matches a sports-keyword regex
(`sportsAddonCatalogs`, `addon-sources-model.ts:26-61`; adult/`configurationRequired`
addons excluded). Each listing returned by a catalog is classified `match: "event" |
"channel" | null` (`sportsAddonListings`, `addon-sources-model.ts:126-184`) using the
same `createEventChannelMatcher` event-identity check (team-code-pair match or a
long/multi-word event-title substring match) for `"event"`, or a normalized-name
match against the game's `broadcasts` list for `"channel"`. Listings are deduped by
`{transportUrl, type, id}`, preferring an `"event"` match on collision
(`mergeSportsAddonListings`, `addon-sources-model.ts:186-194`).

---

## 3. BIG PICTURE SCREEN COMPOSITION (`BpSportsPage`, `bp-sports.tsx:45-221`)

Top-to-bottom layout: chips → (schedule mode only) date band → status note →
either the rail (hero + rows + empty state) or the Explore grid.

### 3.1 Chips (`BpSportsChips`, `bp-sports-chips.tsx`)

Row 1 — mode chips, fixed order and labels (`MODES`, `bp-sports-chips.tsx:12-18`):
`"For you"` (`for-you`) → `"Live now"` (`live`) → `"Schedule"` (`schedule`) →
`"Hot"` (`hot`) → `"Explore"` (`explore`); then a divider, a `"Make it yours"` chip
(opens personalize), and a `"Refresh"`/`"Retry"` chip (spinning icon while
`status.busy`, label switches to "Retry" once `!busy && (failed || stale)`,
`bp-sports-chips.tsx:58-66,89-100`). A trailing status string ("Updating
schedules…" / "Updated {time}") right-aligns in the same row
(`bp-sports-chips.tsx:58-65,70`). Selection is restored per-chip via
`restoreKey={"sports-mode:"+key}` (focus-memory mechanism shared across BP, see
`docs/big-picture-design.md`).

Row 2 — sport-group chips, shown only when `showGroups = mode === "for-you" ||
mode === "schedule"` (`use-bp-sports.ts:317`): `"Your sports"` (group `"all"`) +
one chip per group the user follows (`scope.groups`, computed by
`sportsSelectionScope`, `personalization.ts:17-40` — the set of `.group` values
among the user's selected leagues) + a trailing `"All sports"` chip that switches
to Explore mode (`bp-sports-chips.tsx:121-127`). While browsing from Explore
(`browsing === true`), the browsed group is force-included even if not personally
followed (`use-bp-sports.ts:98-99`).

### 3.2 Date band (`BpSportsDateBand`, `bp-sports-date-band.tsx`) — schedule mode only

A horizontally-scrolling day strip built by `buildDays(anchor)`
(`src/views/sports/date-bar.ts`, not opened — shared with the desktop date bar).
Today's cell shows `"Today"`; others show a locale short-weekday
(`date-band.tsx:63-65`). A small dot under a cell is lit if any currently-live game
falls on that day (`liveDays`, computed from `boardGames` filtered to `state ===
"in"`, `use-bp-sports.ts:175-179`). Selecting a day resets `focused`/`browsed`
state on the page (`bp-sports.tsx:62-65`) and re-fetches via `boardFeed` with
`mode: "day"`.

### 3.3 Hero (`BpSportsHero`, `bp-sports-hero.tsx:144-341`)

Shown only in `mode === "for-you"`; `heroes = featuredEvents(live, group === "all" ?
next : coming)` (`use-bp-sports.ts:197-200`). `featuredEvents`
(`src/lib/sports/hub-discovery.ts:19-39`) picks, in priority order: a numbered UFC
event → up to 2 live games → next Boxing game → next F1 → next NBA → then
`diverseEvents(upcoming, 8)` (one game per league, in feed order,
`hub-discovery.ts:5-17`) — deduped by event/game key, capped at 8 total.

- **Auto-cycle**: `useBpSportsCycle(games.length, active)`
  (`use-bp-sports-cycle.ts`) advances to the next hero every **7000 ms**
  (`HOLD_MS`), paused indefinitely while a card or the hero button has focus
  (`cardFocused()`, `use-bp-sports-cycle.ts:5-11`), and disabled entirely under
  `prefers-reduced-motion` (`use-bp-sports-cycle.ts:13-16,34`). Focusing the hero
  button itself resets the hold timer (`bump()`, `bp-sports-hero.tsx:323-325`).
- **Combat/boxing subject** (`group === "combat" || "boxing"`) renders a
  full-bleed face-off photo pair instead of team badges (`BpSportsFaceOff`,
  `bp-sports-hero.tsx:82-103`) and a "Name **vs** Name" headline instead of
  badge+name columns (`bp-sports-hero.tsx:287-292`).
  "Solo" subjects (`home.name` or `away.name` empty — motorsport/golf/individual
  events) show one mark + `context.name` (or `home.name`) as the headline
  (`bp-sports-hero.tsx:193,276-286`).
  Otherwise: home/away badge + name columns with a center score-or-"vs"
  (`bp-sports-hero.tsx:294-310`).
- **Subject meta line**: league label · stage/venue context rows (`matchCardContext`
  filtered to `kind === "stage" | "venue"`) · start time (pre) or live `detail`
  (`bp-sports-hero.tsx:181-189`), joined with `" · "`.
- Copy cross-fades via `useBpCopyGate` (shared BP mechanism, not sports-specific);
  a `BpHeroPips` dot row under the CTA shows position among `games.length`
  (`bp-sports-hero.tsx:336`).
- CTA label: `"Watch live"` if `state==="in"`, `"View result"` if `"post"`, else
  `"View event"` (`bp-sports-hero.tsx:217-222`). Pressing it calls the shared
  `watchNow(target)` shortcut first when live (auto-plays only on an `"exact"` best
  channel match, §2.4), else opens the event detail (§4).

### 3.4 Rows — ordering, empty states, loading

Row model per-mode is built in `use-bp-sports.ts:211-255` and shaped by
`src/views/big-picture/sports/bp-sports-rows.ts`:

- **`for-you`** (`bpSportsForYouRows`, `bp-sports-rows.ts:72-121`) — fixed key
  order regardless of content: `live` ("Latest saved scores" if every live game is
  stale, else "Live now") → `your-teams` ("Your teams", followed teams excluding
  finished games) → `day` (only populated when viewing a non-today date, title =
  the selected date) → `coming` ("Coming up", `diverseEvents`) → `fights` ("Fight
  nights", only if `group` is `all`/`combat`/`boxing`) → `pitch` ("On the pitch",
  at most one live-or-next soccer game with a lineup teaser) → `esports`
  ("Esports", only if `group === "all"` and the user follows ≥1 esports league) →
  `today` (same date title as `day`, but only populated when viewing *today*).
  Every row with `games.length === 0` is filtered out before render
  (`BpSportsRow` returns `null` for an empty row, `bp-sports-row.tsx:38`).
- **`live`**/**`schedule`** (`bpSportsLeagueRows`, `bp-sports-rows.ts:31-55`) — one
  row per league present in the filtered game set, title = league label, sorted:
  any-live-game leagues first, then by game count descending, then title
  alphabetically (`bp-sports-rows.ts:48-53`).
- **`hot`** (`bpSportsHotRows`, `bp-sports-rows.ts:123-152`) — a top-12 "Hot right
  now" row, then one row per editorial `reason` bucket (`"Championship stage"`,
  `"Numbered UFC event"`, `"Grand Prix weekend"`, `"Fight night"`, `"Your team"`,
  `"Live now"`, or a catch-all `"In the spotlight"`), sorted by each bucket's top
  score. `hotEvents` scoring (`src/lib/sports/hot-events.ts:52-126`): starts at 10,
  +55 for a final/championship-title match, +48 numbered UFC, +42 F1 weekend, +30
  boxing/combat, +20 for UCL/NFL/NBA, +18 (and reason bumped to `"Your team"`) if a
  followed team is involved, +28 (and forced to `"Live now"`) if currently live,
  plus a recency bonus `max(0, 14 - daysAway)`; capped at 6 events per sport group
  and 24 total (`hot-events.ts:117-125`).
- **`explore`** — no rows; renders `BpSportsExplore` instead (a sport/group tile
  grid, `bp-sports-explore.tsx:18-54`, columns `repeat(auto-fill,
  minmax(clamp(138px,11.5vw,232px),1fr))`) which calls `sports.browse(group)` on
  select — temporarily widens the "for-you" selection to that group without
  touching saved preferences (`use-bp-sports.ts:286-293`, `sportsSelectionScope`,
  `personalization.ts:17-40`).
- **Row rendering / lazy chunking**: `BpSportsRow` renders only `shown` cards
  (`CHUNK = 12` at a time, revealing another chunk once focus is within
  `LOOKAHEAD = 4` cards of the end, `bp-sports-row.tsx:14-15,28-36`) inside a
  horizontally-scrolling, no-visible-scrollbar track.
- **Empty state** (`BpSportsEmpty`, `bp-sports-empty.tsx`) is appended as the last
  rail entry, rendered only when `sports.empty` — `(mode==="for-you" &&
  filtered.length===0) || (mode!=="for-you" && mode!=="explore" && !busy &&
  rows.length===0)` (`use-bp-sports.ts:326-328`). Copy matrix (title/body) branches
  on `busy` (loading), `pitch = !busy && !personalized` (first-run pitch: "Less
  searching. More of your sport." / "Pick your sports, leagues and teams…"), then
  per-`mode` empty copy for live/schedule/hot/for-you
  (`bp-sports-empty.tsx:31-58`). Actions shown: `"Today"` (schedule mode only,
  jumps `setDay(today)`), `"Make it yours"`, `"Explore sports"` — order/emphasis
  swapped depending on whether this is the first-run pitch
  (`bp-sports-empty.tsx:80-119`).
- **Loading skeleton**: there is **no dedicated skeleton/shimmer component** — grep
  of `src/views/big-picture/sports` for `skeleton`/`shimmer` found no hits. The
  "loading" experience is the empty-state's `busy` copy branch (above) plus
  whatever stale/cached rows are already rendered from `cachedSportsSnapshot`
  (§1.3) with "Saved" badges.
- **Status note** under the chips (`bp-sports.tsx:142-153,196-203`): blank while
  busy; `"Showing saved schedules while feeds reconnect."` if `status.stale`;
  else, if any league failed, `"Some feeds did not respond. Available events are
  still shown."` plus up to 3 failed league names (`+N` suffix beyond 3) — special
  case `"SOCCER_ALL"` displays as `"Soccer"` (`bp-sports.tsx:142-146`).

### 3.5 Game card layout (`BpSportsCard`, `bp-sports-card.tsx:175-311`)

Fixed width `clamp(318px, 26vw, 470px)`, min height `clamp(170px, 22vh, 252px)`
(`bp-sports-card.tsx:17-18`). Structure top-to-bottom:
1. Optional background art (single-subject games only, §2.3) with a bottom-heavy
   dark scrim, plus a faint (7%→14% on focus) oversized league/home-logo watermark
   for two-sided games (`bp-sports-card.tsx:226-251`).
2. Header row: league mark + league label, right-aligned status
   (`BpSportsState`, below).
3. Body: either a single centered mark+title (single-subject) or two side rows
   (away above home) each with team mark, `#rank` (if present) + name, and either
   the team's `record` string (pre-game) or its `score` (scored) right-aligned,
   dimmed if that side lost (`bp-sports-card.tsx:136-173,262-299`).
4. Footer "quiet" line: the first non-`"start"` context row from
   `matchCardContext` (stage or venue or broadcast list), else team names for
   single-subject cards, else the formatted start date (`bp-sports-card.tsx:196-201`).

**Status/state text** (`BpSportsState`, `bp-sports-card.tsx:92-134`):
- Stale (`savedAt` set): `"Saved"`.
- Live: a pulsing dot + `game.detail` (fallback `"Live"`).
- Final (`state==="post"`): `"Final"`.
- Pre-game, starting within 90 minutes and not a `dateOnly` event: a live relative
  countdown (`BpSportsCountdown`, ticking via `subscribeBpTick`,
  `bp-sports-card.tsx:68-90`) using `Intl.RelativeTimeFormat`, unit auto-selected
  minutes/hours/days by magnitude (`relativeCardStart`, `card-context.ts:55-64`).
- Otherwise: `formatSportsEventDate(startMs, locale, short=true, dateOnly)` or
  `"Time TBA"` if that returns empty.

**Date/time formatting rule** (`formatSportsEventDate`, `event-date.ts:2-26`): a
`dateOnly` event (calendar date only, no real start time) is always formatted in
**UTC** regardless of viewer timezone, using `month: short, day: numeric` (+
`weekday: short` unless `short=true`); a timed event uses the **local** timezone
via `toLocaleString` with `hour: numeric, minute: 2-digit` appended. Score display:
raw `side.score` string or `"0"` if empty (never a computed value).

### 3.6 D-pad / focus rules

Shared BP conventions apply (see `docs/big-picture-design.md`) — every focusable
element carries `data-bp-focusable`; cards/tiles add `data-bp-tile="wide"` (cards)
or `data-bp-tile` (grid tiles); focus-memory keys are stable per-entity:
`` `sports:${gameKey(game)}` `` for cards (`bp-sports-card.tsx:211`), `` `sports-hero:
${gameId}` `` for the hero button (`bp-sports-hero.tsx:322`), `` `sports-group:
${key}` ``/`` `sports-mode:${key}` ``/`` `sports-day:${key}` `` for chips/date
cells. `data-bp-autofocus` seeds initial focus: the hero if any heroes exist, else
the first game in the first non-empty row (`seedRow`, `bp-sports.tsx:83,106`), else
the empty-state's primary action (`bp-sports.tsx:120`). Rail reflow/shift is driven
by `useBpRail`/`useBpLayoutReflow` keyed on a composite `signature` string
(mode+group+day+row keys/lengths, `bp-sports.tsx:74-76`, `use-bp-sports.ts:306-309`)
so any of those inputs changing re-measures the rail.

---

## 4. GAME DETAIL / WATCH FLOW

### 4.1 Opening a game

`onSelect`/`open` from any card or the hero calls `open(game)` =
`pushBigPicture({ kind: "sports-event", game })` (`use-bp-sports.ts:300-302`,
`src/lib/big-picture.tsx:12`). The BP shell renders `<BpSportsEvent game=
{route.game} />` for that route kind (`src/views/big-picture/bp-shell.tsx:450`);
back-stack key is `` `sports-event:${game.id}` `` (`big-picture.tsx:123`). Exception:
if the card/hero press happens while the game is **live** and the shared
`useBpSportsWatchNow()`/`watchNow` hook finds an `"exact"` channel match, it plays
directly instead of opening detail (`bp-sports-card.tsx:213-217`,
`bp-sports-hero.tsx:327-331`, §2.4 point 3's `useBpWatchGame`).

### 4.2 Event screen composition (`BpSportsEvent`, `bp-sports-event.tsx:26-179`)

`useBpSportsEvent(game)` (`use-bp-sports-event.ts:65-126`) assembles the detail
model: boxing-specific event resolution (`useBoxingEvent`, not opened),
`useMatchDetail(game, enabled)` → `fetchGameSummary` (§4.3), league lookup, athlete
portraits (individual sports only), and a `standings` fetch (`fetchStandings`,
`src/lib/sports/standings.ts`, not opened) skipped for `NO_TABLE` groups (`tennis,
combat, golf, motorsport, esports, boxing`, `use-bp-sports-event.ts:33`).

**Hero** (`BpSportsEventHero`, `bp-sports-event-hero.tsx:131-308`): league mark +
label + Live/Final/Saved pills → title (`context.name`, or blank if two named
sides) → (if both sides are named, `sides` flag) a home/away row with mark, name,
`#rank`/`record`, and a center score (`"{away} : {home}"`) or `"vs"` → a facts strip
(`round`, non-scored `detail`, `venue`, formatted date, joined `broadcasts`) →
primary action row (`BpDetailActions`, live/finished states differ — finished games
show only secondary tool actions, no primary Play button,
`bp-sports-event-hero.tsx:276-282`) → provenance/loading/saved notes. Tapping a
named side (when a `bpSportsWhoSubject` resolves, i.e. team/athlete has an id) opens
the "Who" panel (`BpSportsWhoPanel`, athlete/team profile drill-down — out of scope
for this spec, files `bp-sports-who-*`).

**Rows** (`bp-sports-event.tsx:121-139`, each hidden via `empty:hidden` if it
renders `null`):
1. **Stats** (`BpSportsStatsRow`, `bp-sports-event-rows.tsx:133-187`) — combines a
   live "situation" cell (baseball diamond / football field / basketball court,
   `bpSportsSituationKind`), a play-by-play cell (`bpSportsHasPlays`), market-odds
   cells (§1.4), and a team-stats comparison panel with proportional bars
   (`BpTeamStatsCell`, `bp-sports-event-rows.tsx:87-129` — for combat sports, height/
   weight/age/reach/stance rows substitute for the stat bars). Title adapts:
   "Live now" while any live element is present and the game is in progress, else
   "Odds and statistics"/"Key statistics"/"Market odds"/"Play by play"/a
   sport-surface name, singular label suppressed if it equals the row title.
2. **Lineups** (`BpSportsLineupsRow`, `bp-sports-event-rows.tsx:232-271`) — an
   optional pitch/formation diagram cell (soccer-like sports,
   `bpSportsHasPitch`), then away/home roster cells (starters shown first, "Show
   all N" to expand), then per-player stat tables (`bpSportsPlayerStatCells`).
3. **Standings** (`BpSportsStandingsRow`, re-exported from
   `bp-sports-extra-tables.tsx`) — the fetched `standingsGroup`, both competing
   teams highlighted.
4. **Addon sources** (`BpSportsAddonRow`) — lists matched/unmatched addon catalog
   listings (§2.4 point 4); opening one pushes `BpSportsAddonPanel`.
5. **Where to watch** (`BpSportsWhereRow`, `bp-sports-event-rows.tsx:273-355`) —
   venue cell (`useBpSportsVenue`) + a tile per `watchProviders(game)` entry
   (`src/lib/sports/watch-providers.ts`, not opened) plus hardcoded fallback tiles
   for UFC (`https://www.ufc.com/watch`) and F1
   (`formula1.com/.../f1-broadcast-information`) official watch-guide links when no
   matching provider entry exists (`bp-sports-event-rows.tsx:284-301`). Footer
   note explicitly disclaims that availability/subscriptions are provider-set and
   Harbor does not bypass access restrictions (`bp-sports-event-rows.tsx:312-318`)
   — carry this string into the tvOS port verbatim for policy compliance.
6. **Facts** (`BpSportsFactsRow`) — shown only when the event has no stats/rosters/
   standings at all (`bare` flag, `bp-sports-event.tsx:115-119`).

### 4.3 Detail data fetch

`useMatchDetail(game, enabled)` (`src/views/sports/use-match-detail.ts:26-80`)
caches 25 s (`:11`) and dispatches through `fetchGameSummary`
(`src/lib/sports/provider.ts:166-183`):
- `game.source` unset or `"espn"` → `fetchMatchSummary(league, id, startMs)`
  (`src/lib/sports/espn-summary.ts:214`) → `GET {SITE_BASE}/{path}/summary?event=
  {eventId}` (`espn-summary.ts:113`; combat/tennis have their own summary parsers,
  `espn-summary-combat.ts`/`espn-summary-tennis.ts`, not opened).
- Any other `source` with a registered `SPORTS_PROVIDERS` entry (`provider.ts`) that
  does **not** `needsKey` → that provider's own `fetchSummary(leagueKey, gameId)`.
  A provider needing a key with none configured returns `null` (no detail row data,
  but the hero/score fields from the list `SportsGame` still render).

### 4.4 Watch press → player hand-off

`useBpSportsWatch(game, addons)` (`bp-sports-watch.tsx:51-238`) computes `plan`
(§2.4) and a localized `label`/`press()`. Pressing routes to exactly one of:
- **`"stream"`**: `playStream(attachments.streams[game.id], label)` →
  `useBpSportsPlayStream` (`bp-sports-broadcast-play.ts:54-77`) → `openPlayer({
  meta: { id:"page-stream:"+url, type:"tv", name, poster, background,
  releaseInfo:"Live" }, url, title, subtitle: hostOf(page), notWebReady: true,
  isLive: stream.kind !== "file", headers })`.
- **`"broadcast"`**: opens `BpSportsWatchPicker` seeded on the official-broadcast
  list (multiple options) or plays the single option directly
  (`bp-sports-watch.tsx:168-171`); each option plays through
  `BpSportsBroadcastStage` (an embedded Twitch/YouTube/Kick player,
  `bp-sports-broadcast-stage.tsx`, not opened in depth).
- **`"channel"`**: `playChannel(selected.channel, label)` →
  `useBpSportsPlayChannel` (`bp-sports-broadcast-play.ts:39-52`) →
  `recordChannelPlay(channel)` then `openPlayer({ ...liveChannelSource(channel,
  subtitle), headers: headersFromChannel(channel) })`. `liveChannelSource`
  (`src/lib/iptv/playback-source.ts:6-28`) always sets `notWebReady: true, isLive:
  true` for a live channel — this is the same helper Live TV itself uses (see
  `docs/livetv-spec.md`).
- **`"addons"`**: opens the addon panel (`openAddons`) rather than playing directly
  — the user picks a specific stream inside the addon listing UI
  (`bp-sports-addon-panel.tsx`, `bp-sports-addon-streams.tsx`, not opened in depth).
- **`"picker"`**/no strong signal: opens `BpSportsWatchPicker`
  (`bp-sports-broadcast-picker.tsx:63-336`) — a modal listing official broadcasts
  first, then channel matches (each showing its label + a `tierCopy` line: "Your
  pick for this competition" / "Event matchup found" / "Strong match" / "Likely
  match · check the broadcast" / "Possible match · check the broadcast"), plus
  action chips "Search your channels" (`BpSportsBroadcastSearch`), "Addon sources",
  "Set up Live TV" (→ Live TV tab), "Close". Selecting a channel here pins it via
  `setAttachedStream(game.id, null)` + play (does **not** persist the pick as an
  "always use" attachment; only the *search* flow's `AttachPopover` on desktop does
  that via `toggleAttachedChannel`, `bp-sports-broadcast-picker.tsx` has no
  attach-toggle UI of its own — attaching a default channel per league happens on
  the desktop watch-sources panel, `src/views/sports/watch-sources.tsx:447-450`,
  **not found** in the BP picker).
- **`"setup"`**: `goBigPictureTab("live")`.
- `"finished"` (`game.state === "post"`): no press action; the hero shows only
  secondary tool actions (reminder toggle, follow team, etc., §5) or a "Go back"
  fallback if there are none (`bp-sports-event.tsx:78-87`).

---

## 5. SETTINGS THE ROOM READS

| Setting | Type | Default | file:line |
|---|---|---|---|
| `settings.sportsLeagues` | `string[]` | `[]` | `src/lib/settings/defaults.ts:409`, type `src/lib/settings/types.ts:488`; read `use-bp-sports.ts:88`, `bp-sports-personalize.tsx:56`; written `bp-sports-personalize.tsx:166` |
| `settings.sportsShowOdds` | `boolean` | `false` | `src/lib/settings/defaults.ts:410`, type `types.ts:489`; read `bp-sports-extra-odds.tsx:140` (gates the market-odds cell, also suppressed for kid profiles) |
| `settings.webhooks.discordUrl` / `settings.webhooks.telegramUrl` | `string` | (not opened in this pass — see `docs/harbor-protocol.md` for the webhooks block) | read `use-bp-sports-event.ts:144-148` — determines whether a game reminder can actually be delivered; if neither is configured, pressing "Remind me" opens Settings → Webhooks instead of arming a reminder (`use-bp-sports-event.ts:156-158`) |
| `settings.sportsApiKey` (secret) | `string` | `""` | not a `settings.*` field — stored separately in the device secret store under `"harbor.sports.api-sports.v1"`, `api-credentials.ts:3,15-25` (§1.5) |
| `settings.hideContent.sports` (parental) | via `useParental().hiddenTabs.sports` | unset | gates the BP tab, not the room's internals — `bp-top-bar.tsx:125` (`parentalKey: "sports"`, `bp-top-bar.tsx:73`) |

Favourites/consent/attachments/reminders are **not** under the `settings.*` blob —
they are their own `localStorage`-backed stores (§1.6, §2.4, §1.1):
`"harbor.sports.favourites.v1"`, `"harbor-sports-consent"`,
`"harbor.sports.sources.v1"`, and a reminders store (`src/lib/sports/
reminder-state.ts`/`reminders.ts`, not opened in this pass).

---

## 6. DESKTOP/TAURI-ONLY — REPLACE OR SKIP ON tvOS

1. **api-sports key storage** — `src/lib/secret-store.ts` calls
   `invoke("secrets_write", …)` into a Rust-side encrypted file
   (`secret-store.ts:1,40`). Replace with Keychain (`kSecClassGenericPassword`)
   under an equivalent identifier; keep the same "additive, optional" semantics
   (§1.5) — nothing should require this key to function.
2. **`BpSportsBackdrop`'s DOM image-decode pipeline** (`bp-sports-backdrop.tsx:76-
   122`) — manually walks an `<img>` candidate chain calling `.decode()`, tracks
   Android-TV-specific blur/softening (`isAndroidTv()`, `bp-sports-backdrop.tsx:2,
   126`) and CSS `mask-image` gradients. Port the *candidate-list logic* (artwork →
   poster → scenery, §2.3) and the *layer cross-fade sequencing*
   (`bpPushLayer`/`useBpPrune`, shared BP ambient-layer mechanism), not the DOM
   image loading.
3. **`BpSportsWatchPicker`'s search popover / `AttachPopover`** — built on DOM
   `mousedown`/`Escape` listeners and CSS popover positioning
   (`bp-sports-broadcast-picker.tsx:389-464` equivalent in the desktop
   `watch-sources.tsx:370-464`). The BP variant (`BpSportsBroadcastSearch`) is
   already D-pad-shaped and is the one to port; the desktop mouse-anchored
   `AttachPopover` is not.
4. **Web-embedded broadcast player** (`BpSportsBroadcastStage`, Twitch/YouTube/Kick
   `<iframe>` embeds, `twitchEmbedUrl` requiring a `hostname` "parent" param,
   `broadcasts.ts:49-63`) — an iframe embed model does not exist on tvOS; these
   official streams need a native playback path (they are just URLs — check
   whether they resolve to a native-playable HLS/DASH source, or whether tvOS needs
   its own Twitch/YouTube extractor akin to how `esports-streams.ts`
   /`esports-feeds.ts` already resolve raw stream URLs for some platforms — not
   fully audited in this pass).
5. **Consent's cross-tab `storage` event sync** (`consent.ts:125-136`) — single-
   process tvOS has no other tab/window to sync with; drop it, keep the in-memory
   snapshot + Keychain/UserDefaults-equivalent persistence.
6. **`getUiLanguage()`/`useUiLanguage()` and the whole `t()` translation layer** —
   referenced throughout every file in this spec for labels; assumed to be ported
   as part of the general i18n effort, not sports-specific, so not detailed here.
7. **`window.matchMedia("(prefers-reduced-motion: reduce)")`** gates for the hero
   auto-cycle (§3.3) and consent-screen paging animation — map to tvOS's
   accessibility "Reduce Motion" equivalent.
8. **Web Worker channel-index preparation** (`src/lib/sports/channel-index.ts:13-
   107`, `channel-index.worker.ts`) — offloads `buildSportsChannelIndex` batches to
   a Worker with a 15 s per-batch timeout and a main-thread fallback. Native has no
   Worker API; run `buildSportsChannelIndex`/`matchChannelsForGameAsync` on a
   background queue instead, preserving the batch+yield structure
   (`matchChannelsForGameAsync`, `iptv-match.ts:434-454`) so a large playlist
   doesn't block input.
9. **EPG cross-check dependency on the Live TV guide cache**
   (`watch-sources.tsx:79-117`, `getCachedEpg`/`subscribeEpg` from
   `src/lib/iptv/epg-store.ts`) — the "TV guide matchup" match tier (§2.4) only
   fires if Live TV's XMLTV guide is already loaded for a playlist; this is a real
   cross-room dependency to preserve, not something to simplify away.
10. **`requestIdleCallback`** used by the artwork cache's save scheduler
    (`hub-artwork.ts:41-44`) — falls back to `setTimeout(…, 250)` already
    (`hub-artwork.ts:44`); fine to just always use the `setTimeout` path natively.

---

## 7. MINIMUM VIABLE SLICE

The smallest set of pieces that yields a working room using **ESPN data only** (no
Live TV matching, no addons, no api-sports key, no personalization wizard beyond
accepting defaults):

1. **Consent gate** — a native equivalent of `consent.ts` (§1.1) gating everything
   below; ship the same notice copy (`usage-notice.ts`) for policy reasons.
2. **`LEAGUES`/`HUB_LEAGUES` catalog + ESPN scoreboard fetch** — port
   `espn-leagues.ts` (`LEAGUES` table + `getLeagueLabel`), `espn-parse.ts`
   (`parseEvents`/`toSide`), and a scoreboard client hitting the `SITE_BASE`
   endpoints from §1.3 (day, live-range, and aggregate `soccer/all` variants).
   `HUB_DEFAULTS` (`hub-data.ts:75-126`) as the starter league set —
   `HUB_LEAGUES`'s non-ESPN entries (TheSportsDB/OpenDota/boxing/ONE) can be
   deferred; a pure-ESPN slice already covers soccer, NBA/NFL/MLB/NHL, UFC, F1/
   NASCAR, tennis, golf, rugby.
3. **A simple local cache** — even an in-memory `Map` with the `freshFor`/refresh-
   interval values from §1.3 is enough to avoid re-fetching on every focus change;
   disk persistence (`slice-storage.ts`) can follow later.
4. **`sortGames`, `mergeSlices`/`gamesInSportsSelection`, `eventCards`,
   `bpSportsForYouRows`/`bpSportsLeagueRows`** — the row-shaping functions (§3.4)
   are pure and small; port them as-is.
5. **Hero + Row + Card + Chips + Date band + Empty state** UI (§3.1-3.5) —
   reimplemented natively per `docs/big-picture-design.md`'s row/card anatomy, fed
   by the ported data layer above. Skip the auto-cycle's `cardFocused()` DOM query
   (use the native focus-engine's current-focus API instead) but keep the 7 s
   hold/pause behavior.
6. **Event detail screen, ESPN branch only** — `espn-summary.ts`'s `summary`
   endpoint + `BpSportsEventHero` + the `Stats`/`Lineups`/`Standings` rows; skip
   `Where to watch` (needs `watchProviders`/UFC/F1 links — cheap to add once
   ported) and skip the whole `Addons` row.
7. **A minimal "watch" press**: with no Live TV/channel matching yet, `plan` always
   resolves to `"broadcast"` (official curated list, `broadcasts.ts`) or
   `"finished"`/nothing — i.e. ship §2.4 points 1-2 (attachments + official
   broadcasts) before attempting the IPTV channel-matching engine (§2.4 point 3,
   the largest single piece of logic in this spec) or the addon-catalog matcher
   (§2.4 point 4).
8. **`settings.sportsLeagues` + `selectedSportsLeagues`** (§1.6) so "For you" has
   *something* to show before a personalize UI exists — defaulting silently to
   `HUB_DEFAULTS` is enough; the 3-step wizard (§1.6) can be a fast-follow.

Everything in §6 (secret-store/Keychain, DOM backdrop pipeline, Worker-based
channel indexing, embedded web players) becomes relevant only once channel
matching, artwork layering, and the paid api-sports key are added on top of this
slice.
