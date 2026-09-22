# Harbor TV Browse Rooms — Data & Layout Spec (Stage 2)

Scope: exact data sourcing and layout logic for the six Stage 2 browse rooms — Home,
Discover, Movies, Shows, Search, Collections — plus the metadata-provider inventory,
card badge rules, core TypeScript types, and the settings keys these rooms read.

Cross-references (not repeated here):
- **Visual/layout anatomy** (tile sizes, corner radius, focus scale, gaps, hero box
  height, action-button anatomy, card-mark chip styling) is in
  `docs/big-picture-design.md` §8 "Row and card anatomy" — §8.1 Hero/spotlight, §8.2
  Continue Watching row, §8.3 standard poster row, §8.4 card marks/badges styling.
  This doc covers *what data* fills those shapes and *which rule* fires each mark, not
  their pixel geometry.
- **Account/session API, sync protocol, local-storage key mechanics** are in
  `docs/harbor-protocol.md` — §6 "Local storage keys" already documents the
  `harbor.settings` / `harbor.settings.shared` / `harbor.settings.<profileId>` storage
  scheme (`settings/profile-store.ts:5-9`); §9 below only lists the specific keys these
  rooms read, not the storage mechanics.

File paths are relative to `reference/harbor` (repo root) unless
stated otherwise. Every claim cites `file:line`; anything not found after a grep is
marked **not found** rather than guessed.

---

## 1. HOME

Component: `src/views/big-picture/bp-home.tsx` (`BpHome`). Row list is a flat
`BpRailEntry[]` array assembled in render order (`bp-home.tsx:142-263`).

### 1.1 Row order — "Harbor" layout (default, `settings.homeMode === "harbor"`)

| # | Row key / title | Data source | Card shape | Gate |
|---|---|---|---|---|
| 1 | `cw` — "Jump back in" | Continue Watching, see §1.4 | `wide` (16:9), `BpCwCard` | `bp-cw-row.tsx:249` renders `null` if empty & not loading; hidden entirely if pinned-hidden (`bp-home.tsx:41-42,58`) |
| 2 | `services` — "Your streaming" | `settings.streaming` brand tiles (TMDB watch-provider list) | custom square/brand tile | Only if `settings.tmdbKey` truthy AND ≥1 `settings.streaming[s]` true (`bp-home.tsx:49-56,172`) |
| 3 | `addons` — "Your addons" | locally installed Stremio addon catalogs | `wide` (16:9), `BpAddonCard` | `null` if no local addon entries (`bp-addon-row.tsx:92-93`); title fixed `bp-addon-row.tsx:74` |
| 4 | `live` — "Guide" | IPTV/live playlists (`use-bp-live.ts`) | custom `BpGuideCell` grid cell | Renders nothing without playlists; pushed unconditionally |
| 5–6 | catalog rows `rows[0]`, `rows[1]` | TMDB or Cinemeta, see §1.2 | `poster`, or `rank` if row key ∈ `settings.homeRows.numerals` AND ≥10 items (`bp-row.tsx:66-68`, `RANK_MAX=10` at `bp-row.tsx:48`) | `head = rows.slice(0, SERVICES_SLOT)`, `SERVICES_SLOT=2` (`bp-home.tsx:35,66`) |
| 7 | `collections` — "Collections" | TMDB collections feed | `wide` (16:9), `BpCollectionCard` | Only if `settings.tmdbKey` truthy and not pinned-hidden (`bp-collections-row.tsx:24-25,57`) |
| 8+ | catalog rows `rows[2..59]` | same catalog source, array order | same poster/rank rule | capped at `VISIBLE_ROWS=60` (`bp-home.tsx:34,67,248`) |

**Catalog row source** — `rows` = return of `useBpCatalog()` (`use-bp-catalog.ts`):
`[...extra.before, ...built.rows, ...extra.after]`, deduped by key, then
`applyHomeRowCustomization(all, settings.homeRows, false)` (`use-bp-catalog.ts:112-121`).
With Trakt/Simkl/Letterboxd off, no custom lists/favorites/watchlist rows, and a
non-Arabic/Russian locale, `extra.before`/`extra.after` are empty
(`use-bp-extra-rows.ts:173-196`), so `rows` reduces to `built.rows`:

- **TMDB present** (`settings.tmdbKey` set, `homeMode !== "classic"`):
  `buildTmdbRows(settings)` (`use-bp-catalog.ts:65-68`), row order from
  `buildTmdbSpecs` (`src/views/home/home-rows.ts:16-28`), verbatim titles:
  `"Trending This Week"` (movie, `trending/movie/week`), `"In Theaters Now"` (movie,
  `now_playing`), `"Popular Movies"` (movie, `popular`), `"Trending Series"` (series,
  `trending/tv/week`), `"On The Air"` (series, `on_the_air`), `"Popular Series"`
  (series, `popular`), `"Top Rated Series"` (series, `top_rated`), `"Top Rated Movies"`
  (movie, `top_rated`) — rows with 0 results are filtered out (`home-rows.ts:53`).
- **No TMDB key**, or the TMDB build returns 0 rows (`use-bp-catalog.ts:69`):
  `buildCinemetaRows()`, order verbatim (`home-rows.ts:115-134`): `"Top 10 on
  Stremio"`, `"Popular Movies"`, `"Top 10 Drama"`, `"Trending Series"`, `"Top 10
  Comedy"`, `"Action Hits"`, `"Sci-Fi & Fantasy"`, `"Thrillers"`, `"Animated Movies"`,
  `"Horror"`, `"Romance"`, `"Adventure"`, `"Documentaries"`, `"Mystery"`, `"Fantasy"`,
  `"Drama Series"`, `"Comedy Series"`, `"Crime Series"`.
- Installed addon catalogs are appended via `mergeRows(base.rows, usable, { dedup })`
  (`use-bp-catalog.ts:88-90`, `home-rows.ts:245-304`); Harbor mode excludes
  anime-tagged and streaming-service-named addon catalogs (`use-bp-catalog.ts:85-87`),
  `dedup = !settings.homeShowAllAddonRows` (default `true`).
- `settings.homeRows.order/hidden/renamed` can reorder/hide/rename by row key
  (`home-customization.ts:17-40`); all default empty, so no-op by default.

**`src/lib/feed/*.ts`** (sections.ts, daily-rows*.ts, hero-pool.ts, pool.ts, rank.ts,
themes.ts, genre-spotlights.ts, genre-topics.ts, preferences.ts, saved.ts, exclude.ts,
seen-ids.ts, skipped.ts, tags.ts, moods.ts, award-winners.ts, external-cw.ts (except
inside the CW merge, §1.4), external-watched.ts, locale.ts, index.ts, featured/) —
**not imported anywhere in the Home row-build path** (`bp-home.tsx`,
`use-bp-catalog.ts`, `use-bp-extra-rows.ts`, `use-bp-service-rows.ts`,
`src/views/home/home-rows.ts`) — it imports only from Discover, onboarding, and the
Discovery Queue (§2). **This whole module tree feeds Discover, not Home.**

### 1.2 Row order — "Classic" layout (`settings.homeMode === "classic"`)

There is **no separate band structure** for Classic — `bp-home.tsx` never reads
`settings.homeMode`; rows 1–4 and 7 (cw/services/addons/live/collections) are gated
identically in both modes. `homeMode` only changes the catalog-row engine inside
`useBpCatalog`:

```ts
// use-bp-catalog.ts:63-69
const classic = settings.homeMode === "classic";
let base: Built = EMPTY;
if (!classic) {
  base = settings.tmdbKey
    ? await buildTmdbRows(settings).catch(() => EMPTY)
    : await buildCinemetaRows().catch(() => EMPTY);
}
if (base.rows.length === 0) base = await buildCinemetaRows().catch(() => EMPTY);
```

In Classic mode `base` starts `EMPTY` and always falls through to
`buildCinemetaRows()` — **TMDB rows are never used in Classic, even with a TMDB key
configured.** Row order is therefore the same 18-title Cinemeta list as §1.1's
fallback. Additional Classic differences (`use-bp-catalog.ts:79-84`,
`use-bp-extra-rows.ts:60-79`):
- Addon catalogs: `dedup = classic ? false : !settings.homeShowAllAddonRows`,
  `usable = classic ? addons : addons.filter(...)` — Classic shows **every** installed
  addon catalog, unfiltered/undeduped, in install order.
- `animeRows`/`arabicRows`/`russianRows` (in `use-bp-extra-rows.ts`) are all forced off
  when `classic` is true.

Onboarding copy (`bp-step-layout.tsx:28-37`) describing the two modes to the user:
Harbor — *"A hero up top, then Top 10, Trending, In Theaters and your service rows."*
Classic — *"Continue Watching first, then your addon catalogs in install order."*

Type: `homeMode: "harbor" | "classic"` (`settings/types.ts:505`), default `"harbor"`
(`settings/defaults.ts:432`).

### 1.3 Hero/spotlight cycle

**Timing**: `HOLD_MS = 7000` (7s) (`use-bp-hero-cycle.ts:5`). Each `advance()` call
reschedules itself via `window.setTimeout(advance, HOLD_MS)` regardless of whether it
actually advanced (`use-bp-hero-cycle.ts:29-39`) — a flat 7s poll, not a guaranteed
7s-interval advance if a card is focused.

**Item source**: `heroPool = (rows[0]?.metas ?? []).slice(0, 8)` (`bp-home.tsx:73`) —
up to 8 items from the **first catalog row only** (e.g. "Trending This Week" in
Harbor/TMDB mode). The separate `hero` field `useBpCatalog()` computes is fetched but
**never used** by `bp-home.tsx` (only `{ rows, loading, failed }` are destructured,
`bp-home.tsx:38`). Cycling is enabled only when `heroPool.length > 1 && !isAndroidTv()`
(`bp-home.tsx:74`) — **disabled on Android TV**.

**Mechanism**: each tick, `atRef.current = (atRef.current + 1) % list.length`, then
`seedBpMeta(list[atRef.current])` (`use-bp-hero-cycle.ts:34-37`). `seedBpMeta`
(`bp-focus-meta.ts:53-58`) is a no-op while a card holds real ("pinned") focus — cycling
silently stops advancing whenever a rail card is focused, with no separate pause flag.

**Displayed fields** (`BpSpotlight`, `bp-spotlight.tsx`, driven by
`useBpFocusedMeta()` — spotlight always mirrors whatever `bp-focus-meta` currently
holds, whether from the hero cycle or row-card focus):
- Provider badge mark image (`meta.providerBadge.logo`) — lines 48, 101-109
- Title logo image if available, else plain `<h1>` title — lines 65, 72, 111-135
- Score chips (`BpScoreChips`) + fallback TMDB rating (only if no score chips) —
  lines 51-55, 75, 141-147
- Facts line (year/runtime/genres, `bpFacts`) — lines 61, 148-152
- Awards corner overlay (`MetaAwardsCorner`) — lines 155-157
- Overview text, `line-clamp-2` — lines 76, 159-166

**Buttons: not found.** `BpSpotlight` has no `<button>` elements or Play/More-Info
controls — a pure display surface; interaction happens on the focused row card beneath
it (action buttons exist only on the Detail-page hero, a different component —
`docs/big-picture-design.md` §8.1).

**Pause/resume conditions**:
- `cardFocused()` — an element matching `[data-bp-focus='true']` inside
  `[data-bp-tile]` reschedules the tick without advancing (`use-bp-hero-cycle.ts:7-11,
  30-33`).
- `reduced()` — `prefers-reduced-motion: reduce` skips scheduling entirely
  (`use-bp-hero-cycle.ts:13-16, 25`).
- `enabled` false when `heroPool.length <= 1` or on Android TV (`bp-home.tsx:74`).
- Timeout is cleared on unmount/dep change (`use-bp-hero-cycle.ts:42-44`).

### 1.4 Continue Watching

The Home CW row is **not** driven by `src/lib/continue-watching.ts`
(`useContinueWatching`) — that hook has zero importers under `src/views/big-picture`.
The actual source is `useMobileCw`/`useMobileCwReady` from
`src/views/mobile/mobile-cw-row.tsx` (`bp-home.tsx:7,39-40`), a structurally similar
but separate implementation.

**Merge logic** (`mobile-cw-row.tsx:133-160`, inside `useMobileCw(limit)`):

```ts
const base = hideSharedCw
  ? []
  : [...items.filter((i) => !ANIME_CLOUD_ID.test(i._id)), ...externalCw];
const merged = [...base, ...listLocalCw().map(localToLibraryItem)]
  .filter(
    (i) =>
      (i.type as string) !== "other" &&
      !i._id.startsWith("iptv:") &&
      !isCwDismissed(i) &&
      isCwMember(i) &&
      !(hideAnime && isAnimeCwItem(i)),
  )
  .map((i) => ({ i, k: cwSortKey(i) }))
  .sort((a, b) => b.k - a.k)
  .map((e) => e.i);
```

- `items` = Stremio cloud library via `library(authKey)` — `POST
  https://api.strem.io/api/datastoreMeta` then `.../datastoreGet` for `collection:
  "libraryItem"` (`stremio.ts:5, 170-182`).
- `externalCw` = Trakt/Simkl "currently watching" imports (`lib/feed/external-cw.ts`),
  gated on `settings.cwSources.trakt`/`.simkl` (`mobile-cw-row.tsx:98-100`).
- `listLocalCw()` = Harbor's local-only resume entries (`lib/local-cw.ts`), always
  appended.

**Sort key**: `cwSortKey(i)` (`stremio.ts:105-117`) — `best = max(resumeForItem(i)?.t ??
0, Date.parse(state.lastWatched), _mtime)`, **descending** (most-recent first).
`resumeForItem` (`stremio.ts:71-77`) reads Harbor's local resume record
(`readResumeEntry`, `lib/resume.ts`, localStorage key `"harbor.resume"`) — i.e. a
title's recency is the *max* of its Stremio-cloud timestamp and Harbor's own local
playback timestamp, so a local-only watch bumps a cloud item to the top before the
cloud syncs.

**Card content** (`BpCwCard`, `bp-cw-row.tsx:91-219`, meta via `useBpCwCardMeta`):
backdrop art (16:9), bottom scrim + title clear-logo or text, episode label ("S{s}
E{e}" or "Episode {n}" for anime), trailing pill (waiting-for-air countdown / "Up Next"
/ resolved episode title / remaining time), top-left badges (watched check + "+N"
new-episode pill), external-source glyph (Trakt/Simkl logo, clock, or play icon),
watcher avatar (pixel geometry: `docs/big-picture-design.md` §8.2).

**Progress bar**: `progress = dur > 0 ? Math.min(1, Math.max(0, off / dur)) : 0` where
`dur = item.state?.duration ?? 0`, `off = item.state?.timeOffset ?? 0`
(`bp-cw-row.tsx:102-104`), rendered as a filled-width track (`bp-cw-row.tsx:210-215`).

### 1.5 Settings read by Home

| Key | Type | Default | Role |
|---|---|---|---|
| `homeMode` | `"harbor" \| "classic"` | `"harbor"` | Selects catalog engine (§1.1/1.2) |
| `homeShowAllAddonRows` | `boolean` | `false` | Harbor-mode addon dedup toggle |
| `homeNewEpisodes` | `boolean` | `false` | declared (`types.ts:507`); not read in files inspected |
| `homeRows.order` | `string[]` | `[]` | row-key reorder, no-op empty |
| `homeRows.hidden` | `string[]` | `[]` | row-key hide list |
| `homeRows.renamed` | `Record<string,string>` | `{}` | per-row title override |
| `homeRows.numerals` | `string[]` | `[]` | row keys forced to `"rank"` shape if ≥10 items |
| `homeRows.heroSource` | `string\|null` | `null` | declared; **not found** wired into hero pool logic |
| `homeRows.customSources` | `SourceRow[]` | `[]` | user-defined Home rows, see §8 for `SourceRow` shape |
| `homeRows.listRows` | `string[]?` | `[]` | custom-list rows merged into `extra.before` |
| `homeRows.playButtonSquare` | `boolean?` | `false` | — |
| `homeRows.secondaryMoreInfo` | `boolean?` | `false` | — |
| `homeRows.cwTop` | `boolean?` | `false` | — |
| `tmdbKey` | `string` | `""` | gates TMDB-vs-Cinemeta build, services row, collections row |
| `region` | `string` | `"US"` | TMDB region param |
| `streaming` | `Record<Service,boolean>` | netflix/disney/hulu/prime/apple/max/paramount/peacock/crunchyroll/amcplus/starz/shudder default `true`; tubi/plutotv/roku default `false` | Services row membership |
| `cwSources` | `{library,trakt,simkl,local}` | `{library:true, trakt:false, simkl:false, local:true}` | gates external CW sources |
| `cwPerProfile` | `boolean` | `false` | if true and another profile shares the same Stremio login, CW is hidden |

---

## 2. DISCOVER

Component: `src/views/big-picture/bp-discover.tsx`. Sections built as an ordered
`entries: BpDiscoverEntry[]` array (`bp-discover.tsx:177-278`); array position is the
rail index directly (`bp-discover.tsx:49-55`).

### 2.1 Section order (verbatim titles/blurbs)

1. **"Discovery Queue"** (`bp-discover.tsx:179-190`) — `eyebrow: "Discover"`,
   `blurb: "One pick at a time, full screen, until something lands."` Node:
   `<BpQueueBand>` (`queue/bp-queue-band.tsx`). Unconditional, always first, Discover's
   only unconditional autofocus target. One "wide" fan/backdrop tile, height
   `clamp(150px,20vh,260px)`.
2. **"Awards"** (`bp-discover.tsx:195-215`) — blurb: `"{bodies} awards, {wins}
   winners, {span}, all offline"` or fallback `"Every winner Harbor ships, browsable
   offline by year and category."` Node: `<BpAwardsBand>`, self-hides via
   `empty:hidden` so its absence never shifts the array index.
3. **"Genres"** (`bp-discover.tsx:221-238`) — blurb: `"{n} shelves, one press into any
   of them"`, n = 18. Node: `<BpGenresBand>`.
4. **"Collections"** (`bp-discover.tsx:240-246`) — blurb: `"Sagas and series, gathered
   in the order they were meant to be watched."` Gated: `showCollections =
   Boolean(settings.tmdbKey)` (`bp-discover.tsx:71`).
5. **"Top People"** (`bp-discover.tsx:248-254`) — blurb: `"Top {n}, ranked by the work
   they left behind"`, n = `people.length`. Gated `showPeople = people.length > 0`.
   Data: `useBpTopPeople(24)` (`PEOPLE_COUNT=24`), seeded from
   `peekRankSnapshot("harbor","Acting",null)`, refreshed via
   `fetchRankList("harbor","Acting",null)`.
6. **N "Picked for you" rails** (`bp-discover.tsx:256-278`), `RAIL_COUNT = 8`, one per
   `useBpDiscoverRails(8)` entry. `eyebrow: "Picked for you"`, `title: t(rail.name)`
   (titles come from the daily-rows catalog, not a fixed list), `blurb: "{n} picks,
   refreshed daily"`. Node: `<BpRow>` standard poster tiles, lead tile "All shows"/"All
   movies".

Card shapes: queue = one wide fan/hero tile; awards/genres/people/collections/rails =
horizontal `BpRow`/band poster/tile shelves.

### 2.2 Taste-scoring algorithm

**Two separate scorers exist** — be precise about which feeds what:

**(A) `src/lib/discover/affinity.ts`** — general affinity engine, **not wired into any
Big Picture Discover call site** directly (no importer under `src/views/big-picture`);
its `Affinity` type is however the shared input to scorer (B) via a shared store.
- Event kinds/weights, `KIND_WEIGHT` (affinity.ts:4-12): `open:1.0, play:3.0,
  dwell:2.5, watchlist:4.0, watched:6.0, vote_up:5.0, vote_down:-5.0`.
- Recency half-life `HALF_LIFE_MS = 90 * 24 * 60 * 60 * 1000` (90 days):
  `recency = exp(-ln2 * max(0, now-ts) / HALF_LIFE_MS)`.
- Per-event weight `w = KIND_WEIGHT[kind] * recency` accumulates into
  `Affinity.cast/directors(×1.2)/creators(×1.2)/genres/keywords/decades/languages`.
- `score()` category weights, `CATEGORY_WEIGHT` (affinity.ts:14-22): `cast:1.0,
  directors:1.5, creators:1.5, genres:0.8, keywords:1.2, decade:0.4, language:0.3`.
  Cast/genres/keywords use `avgWeight` (sum ÷ √n); directors/creators use plain sum.
- Persistence: `localStorage["harbor.discover.v1"]`, max 500 events, 5s debounced
  persist.

**(B) `src/lib/feed/rank.ts`** — the scorer BP Discover's rails and Discovery Queue
actually use. `scoreItem(item, affinity, locale)` (rank.ts:35-50) reads the same
`Affinity` object (built by A's `buildAffinity`), scored differently:
- Locale penalty first: `-locale.penalty * (1 - liked)` if the item's
  `originalLanguage` isn't in the user's preferred-locale set.
- If `affinity.totalEvents === 0` → locale score only (cold start, no
  personalization).
- Genre term: `score += (affinity.genres[g] / maxAbsGenreWeight) * 4` — **weight 4**.
- Decade term: `score += (affinity.decades[decade] / maxAbsDecadeWeight) * 1.5` —
  **weight 1.5**. No cast/director/keyword terms in (B).
- `rankByAffinity(items)` sorts descending, ties broken by original index (stable).

Used by: `fetchRowWithFallback` (`lib/feed/daily-rows-select.ts:113`) backing
`selectDailyRows` (`lib/feed/daily-rows.ts:151-173`), which builds the 8 rails
(`use-bp-discover.ts:237`); and `buildOrder` (`queue/use-bp-queue.ts:46-50`), which
orders the Discovery Queue.

**Row selection** (which shelves appear, distinct from item scoring):
`lib/feed/daily-rows.ts` — `expandCandidates` filters catalog entries by
`entry.eligible(affinity, settings)`, `orderRows` pins Trending/Top Rated/Awards/one
rotating anchor and Fisher–Yates-shuffles the rest with a `mulberry32` PRNG seeded by
day index — deterministic per calendar day.

### 2.3 Discovery Queue

Full-screen, one-at-a-time swipeable stack. Opened from `BpQueueBand`
(`queue/bp-queue-band.tsx`) into overlay `BpQueue` (`queue/bp-queue.tsx`), driven by
`useBpQueue()` (`queue/use-bp-queue.ts`).

**Pool**: `getPool(tmdbKey)` (`lib/feed/pool.ts:21-40`), memoized per calendar day and
TMDB key. `buildTmdbPool` fires ~20 parallel TMDB queries: trending movies (pages 1-2),
trending tv, top-rated movies (pages 1-3), popular movies, top-rated tv (pages 1-2), 2×
"hidden gem" discover (`vote_average.gte:7.2, vote_count.gte:300,
vote_count.lte:3500, with_runtime.gte:70, sort_by:vote_average.desc`), 1 "acclaimed"
(`vote_average.gte:8.0, vote_count.gte:1000`), 1 "cult classic" (pre-2000,
`vote_average.gte:7.4`), plus 4 random genres/3 random decades/2 random languages
(daily-seeded). Results deduped, poster-filtered, then interleaved round-robin by
source category. No TMDB key → `buildFallbackPool()` (Cinemeta top movies/series + 6
hardcoded genres).

**Ordering**: `buildOrder(source) = rankByAffinity(shuffleQueuePool(filterQueuePool
(source) minus up/down-voted ids))` — shuffle first, then re-sorted by the §2.2(B)
score. Cached module-level so the Discover band peek and the opened queue show the
same sequence.

**Extension**: extends when remaining run drops to `LOW_WATER_MARK = 6` items ahead of
the cursor, calling `extendPool` (same query shape, 3 genres/2 decades, starting page
`FIRST_EXTENSION_PAGE = 2`).

**Remove paths**:
- **Snooze** ("skip for now"): `snoozeQueueItem(id)` (`lib/feed/skipped.ts:51-58`) —
  hides for `SNOOZE_MS = 14 days`, stored `localStorage["harbor.feed.skipped"]` as
  `{id: expiryTimestamp}`.
- **Block** ("don't show again"): `blockQueueItem(id)` (skipped.ts:60-67) — permanent,
  stored as an array in `localStorage["harbor.feed.blocked"]`.
- Both call `useBpQueue`'s `remove()`, dropping the item and advancing the cursor.

**Persistence**: pure `localStorage`, no server sync — `harbor.discover.v1` (events/
affinity), `harbor.feed.skipped`, `harbor.feed.blocked`.

**Status**: `"loading" | "nokey" | "unreachable" | "empty" | "ready"` — `nokey` if no
TMDB key, `unreachable` if the pool fetch returned 0 raw items, `empty` if all items
exhausted/filtered.

### 2.4 Genre grid / tiles

**Genre list (verbatim, `BP_GENRES`, `use-bp-discover.ts:152-171`)**, 18 entries,
hardcoded (not TMDB-runtime-derived):
```
["Action","Adventure","Thriller","Crime","Drama","Romance","Mystery","Sci-Fi",
 "Fantasy","Horror","Comedy","Family","Animation","Western","War","History",
 "Documentary","Music"]
```

**Tile band** (`BpGenresBand`, `bp-genre-tiles.tsx:102-131`): one tile per genre plus a
trailing "Surprise me" lead tile that opens a random genre. Content: solid
`GENRE_PALETTE[genre]` background + up to 3 skewed backdrop thumbnails under a
multiply-blend tint + label text. Art: `useBpGenreArt(genre, active)` →
`fetchGenreSample(tmdbKey, genre)`
(`lib/feed/sections.ts:234`), items with a `background` only, up to 3 unique via
`claimUniqueArt`; deferred until the Genres row has D-pad focus (so 18 art fetches
don't queue ahead of the 8 content rails).

**Genre grid (detail overlay)**: `use-bp-genre-grid.ts:20-115` — `tmdbDiscover(key,
"movie", { with_genres: id, "vote_count.gte": "180", sort_by: "popularity.desc", page
})`. Movies only, min 180 votes, sorted by popularity. `page` starts at 1, `+1` per
`more()`. Infinite scroll via `IntersectionObserver` sentinel. Statuses: `"loading" |
"ready" | "no-key" | "failed" | "filtered" | "empty"`.

**Cross-check**: `lib/feed/genre-spotlights.ts` (`GENRE_SPOTLIGHTS`) and
`lib/feed/genre-topics.ts` (`GENRE_TOPICS`) are **not imported anywhere under
`src/views/big-picture`** (confirmed independently by both the Discover and Home
research passes). They feed neither Home rows nor the Discover genre grid —
desktop-only, unused by any TV room found.

### 2.5 Catalog pagination

Scope correction: `bp-catalog-page.tsx`/`use-bp-catalog.ts` do **not** implement the
Discover-adjacent "All movies"/"All shows" pagination — `bp-catalog-page.tsx` is a
generic page shell with no fetch logic; `use-bp-catalog.ts` builds the **Home** tab row
list (§1), not Discover's.

The actual mechanics (reached via a Discover rail's lead tile → Movies/Shows catalog
page) live in:
- `use-bp-shows.ts` (`useBpCatalogPage(kind)`, shared by Movies/Shows, §3): each row
  gets `fetcher: (page:number) => Promise<Meta[]>`, `hasMore: !spec.noPaginate &&
  metas.length >= PAGINATE_THRESHOLD` where **`PAGINATE_THRESHOLD = 14`**.
- `movie-specs.ts`/`show-specs.ts` supply fetchers, e.g. `fetcher: (p) =>
  tmdbDiscover(key, "movie", { ...params, page: String(p) })` — TMDB's own **`page`**
  param (1-indexed, +1 per call), **never `skip`**.
- `bp-row.tsx` triggers loading: initial chunk `CHUNK = 10` tiles; `loadMore()` calls
  `row.fetcher(pageRef.current + 1)`. Trigger threshold: **`NEAR_END_PX = 900`** px on
  desktop, or **`TV_NEAR_END = 0.25`** (25% of visible track width) on Android TV.
  Ranked/"Top 10" rows never paginate.
- No-TMDB-key fallback uses `list-pager.ts`: `listPager(items, pageSize=40)` —
  client-side slicing of an already-fetched Cinemeta list.
- Row/catalog identity is `spec.key` (e.g. `"trending"`), not a Stremio addon catalog
  id; addon-sourced rows are handled by `use-bp-addon-row.ts`, which exposes no
  skip/page pagination for Big Picture.

---

## 3. MOVIES and SHOWS

Components: `src/views/big-picture/bp-movies.tsx` / `bp-shows.tsx`. Both wrap
`useBpCatalogPage(kind)` from `use-bp-shows.ts:243-311`.

### 3.1 Movies room rows

Build order (`use-bp-shows.ts:282-308`, kind = `"movies"`):

1. **Top 10 row** (conditional) — key `BP_TOP10_ROW_KEY = "bp-top10"`, title `"Top 10
   Movies Today"`. Source: the `"trending"` spec row (TMDB `trending/movie/week`)
   sliced to first 10 after anime-hide filtering, only shown if ≥10 items, fed through
   `useBpTop10Feed(ranked)`. Shape `"rank"` (all others `"poster"`). Always exactly 10
   long — not the desktop "numbered row" preference.
2. **User collection rows** — key `` `collection-${c.id}` ``, title = collection name,
   from `useCollectionRowsForPage("movies")` (`lib/page-collection-rows`), only if
   `c.items.length > 0`.
3. **TMDB spec rows**, order from `movieSpecs(tmdbKey, region)`
   (`src/views/movies/movie-specs.ts:78-234`):
   - `"Trending This Week"` — `trending/movie/week`
   - `"In Theaters Now"` — region-scoped `discover/movie` with release-window params
   - **Mood rows** (0+, injected via `pickMoodSpecs(new Date())`) — dynamic subset of a
     24-mood pool in `lib/feed/moods.ts:12-37`, chosen by time-of-day bucket
     (`TIME_PREFS`) plus optional seasonal override (`SEASONALS`); titles e.g.
     `"Comfort Watch"`, `"Mind Benders"`, `"After Dark"`, `"Date Night"`, `"Adrenaline
     Rush"`, `"Bring the Tissues"`, `"Feel-Good Hits"`, `"Laugh Out Loud"`, `"Heists &
     Cons"`, `"Into the Stars"`, `"Sword & Sorcery"`, `"True Crime Files"`,
     `"Slow-Burn Dramas"`, `"Neo-Noir"`, `"Coming of Age"`, `"Epic Adventures"`, `"War
     Stories"`, `"Saddle Up"`, `"Animation Night"`, `"Turn It Up"`, `"History Buff"`,
     `"Whodunit"`, `"Eye Candy"`, `"Cult Classics"` (full list `moods.ts:13-36`),
     fetched via `discover/movie` with genre/rating params.
   - `"Critics' Picks"` — `discover/movie`
   - `"All-Time Greats"` — `movie/top_rated`
   - `"Hidden Gems"` — `discover/movie`
   - `"Quick Watches Under 90"` — `fetchUnderNinety` (`lib/feed/sections`)
   - `"Coming to Theaters"` — `movie/upcoming`
   - `"Defining the 2010s"` / `"Essential 90s"` / `"80s Classics"` / `"70s Auteurs"` —
     `discover/movie`, decade-windowed
   - `"Japanese Cinema"` (`with_original_language:"ja"`), `"Korean Cinema"`
     (`"ko"`), `"French Cinema"` (`"fr"`) — `discover/movie`
   - `"Documentary Spotlight"` — `discover/movie`, `with_genres:` Documentary

   **No network/studio rows for movies** — `movieSpecs` never sets `with_networks`/
   `with_companies` (grep: only `show-specs.ts` does, §3.5).
4. **Letterboxd rows** (movies-only) — inserted by `useBpLetterboxdRows()`
   (`use-bp-movies.ts:41-81`) via `buildLetterboxdHomeRows`
   (`lib/stremboxd/home-rails`), gated on `letterboxd.isActive` + session readiness.
   Inserted right after Top-10 if present, else at the front. Catalog ids:
   `"letterboxd-watchlist"`, `"letterboxd-diary"`, `"letterboxd-liked"`,
   `"letterboxd-friends"`, `"letterboxd-recommended"`, `"letterboxd-popular"`,
   `"letterboxd-top250"`; default titles e.g. `"Letterboxd Watchlist"`, `"Recent
   Diary"`, `"Liked Films"`.

**Room-wide gating**: with `settings.tmdbKey` set, TMDB spec rows + hero are fetched
(`use-bp-shows.ts:194-217`); on total failure/empty, or no key, falls back to
`buildFallback("movies")` — Cinemeta `topMovies()` for `"Top Movies"` + per-genre `"Top
{Genre}"` over a fixed 13-genre list: `["Action","Drama","Comedy","Sci-Fi","Thriller",
"Horror","Romance","Animation","Adventure","Crime","Mystery","Fantasy",
"Documentary"]`. If even that's empty, room shows an error state.

Rows with <`MIN_ROW_METAS = 4` items after cross-row dedup are dropped; items already
in the Top-10 row are deduped out of all other rows. `VISIBLE_ROWS = 60` caps rendered
rows.

### 3.2 Shows room rows

Row list, in render order (`use-bp-shows.ts:313-332`):

1. **Continue-watching row** — key `"cw"`, title `"Jump back in"`, rendered via
   `<BpCwRow>` (not a `HomeRow`/`BpRow`). Source: `useMobileCw(CW_POOL=40)` filtered to
   `type === "series" && !isAnimeCwItem(i)`, capped `CW_LIMIT = 16`. Autofocuses once
   the CW pool + page are both ready and non-empty.
2. **Top 10 row** (conditional) — title `"Top 10 Series Today"`, shape `"rank"`, same
   mechanism as Movies.
3. **User collection rows** — same mechanism, `useCollectionRowsForPage("shows")`.
4. **TMDB spec rows** from `showSpecs(tmdbKey)` (`src/views/shows/show-specs.ts:12-227`):
   `"Trending This Week"` (`trending/tv/week`), `"On Tonight"` (`tv/on_the_air`),
   `"Premiered This Month"` (`discover/tv`, air-date window), `"From HBO"`
   (`with_networks:"49"`), `"Netflix Originals"` (`"213"`), `"Apple TV+"` (`"2552"`),
   `"AMC"` (`"174"`), `"FX"` (`"88"`), `"Disney+ Originals"` (`"2739"`), `"Prime
   Video"` (`"1024"`), `"Limited Series & Miniseries"` (`with_type:"2"`), `"Prestige
   Drama"` (genre Drama), `"Comedy Series"` (genre Comedy), `"Crime & Mystery"` (genre
   Crime), `"Sci-Fi & Fantasy"` (genre Sci-Fi & Fantasy), `"Documentary Series"` (genre
   Documentary), `"All-Time Great Series"` (`tv/top_rated`), `"Iconic Long-Runners"`
   (`discover/tv`, `first_air_date.lte 2010-12-31`), `"K-Drama"`
   (`with_origin_country:"KR"`), `"British Television"` (`"GB"`).

**Gating**: identical mechanism to Movies — TMDB key → spec rows; else Cinemeta
`topSeries()` fallback (`"Top Series"` + same 13-genre fallback list). No Letterboxd
insertion for Shows. Same `MIN_ROW_METAS=4`/`VISIBLE_ROWS=60`/Top-10-dedup rules.

Card shape: `"poster"` for all `BpRow` rows except Top-10 (`"rank"`); CW row uses its
own `BpCwRow`/`BpCwCard*` progress-pill components, not the generic tile system.

### 3.3 TV vs desktop view reuse

TV (`bp-*`) views **share the row-definition/hero-building modules directly** with
desktop; only the page/container components are independent:
- `use-bp-shows.ts:7-20` imports `buildShowHero`/`showSpecs` from
  `@/views/shows/hero-curation` / `@/views/shows/show-specs`, and
  `buildMovieHero, HERO_POOL_TARGET, movieSpecs, rotateDaily` from
  `@/views/movies/movie-specs` — the **exact same modules** desktop uses (desktop
  `shows.tsx:38-39`, `movies.tsx:23` import identically).
- Both also reuse `lib/page-collection-rows`, `lib/page-rows`, `lib/progressive-rows`,
  `lib/list-pager`, and `lib/cinemeta` (`topMovies`/`topSeries` fallback).

**Independent only in presentation**: `bp-movies.tsx`/`bp-shows.tsx`/`use-bp-movies.ts`/
`use-bp-shows.ts` (TV) vs `movies.tsx`/`shows.tsx` (desktop), each with their own hook
wrapping, row-rendering components (`BpRow`/`BpRail` vs desktop's `CatalogRows`/`Row`),
and hero/spotlight components (`BpSpotlight` vs `PeekHero`/`CinemaHero`) — no TV
component imports the desktop view files themselves, only the shared support modules.

### 3.4 PeekHero

`PeekHero` (`src/components/peek-hero.tsx:22-169`) is **desktop-only**, used only in
desktop `src/views/shows.tsx:7,313` (grep of `src/views/big-picture` and
`src/views/movies*`: no matches — not used in either TV room). Desktop `movies.tsx`
uses a different component, `CinemaHero`, not `PeekHero`.

- Data: `slides` = hero pool from `buildShowHero(tmdbKey)`
  (`views/shows/hero-curation.ts:372-380`) — up to `HERO_CANDIDATE_TARGET=240` deduped,
  art-having TMDB items from ~19 parallel TMDB queries (trending/popular/top-rated/
  on-the-air/high-vote discover by genre/region/network), cached 24h via
  `localStorage[POOL_CACHE_KEY]`, seed-shuffled daily (`seededShuffle`,
  `rotationSeed() = dayOfYear×4 + dayPartBucket`), sliced to `HERO_POOL_TARGET=6`.
- Behavior: auto-rotates every `ROTATE_MS=9500`ms unless paused/dragging/off-screen/
  tab-hidden; pointer-drag swipe with flick/snap thresholds; renders up to 3 slides at
  once (active ±1) with scale/opacity falloff; logo/title/rating/genres/Play/Episodes
  buttons only on the active slide.
- **TV equivalent**: `BpSpotlight` is **not** a rotating multi-slide carousel — it
  renders exactly one item, the currently row-focused meta (`useBpFocusedMeta()`),
  seeded initially from the hero pool's first item as a fallback (`bp-movies.tsx:31,
  37-40`: `const seed = visible[0]?.metas[0] ?? hero[0]`; `bp-shows.tsx:49`: `cw[0] ?
  cwMeta(cw[0]) : (hero[0] ?? rows[0]?.metas[0])`). Explicit code comment: **"Big
  Picture never renders a hero carousel"** (`use-bp-shows.ts:279-281`).

### 3.5 Network rows

Exist **only in Shows**, not Movies (grep: `movie-specs.ts` has no
`with_networks`/`with_companies` anywhere).

Source is **hardcoded, not data-driven**: `show-specs.ts:36-112` defines 7 fixed
`RowSpec` entries, each a literal TMDB network id passed as `with_networks` to
`discover/tv`:

| Row key | Title | `with_networks` |
|---|---|---|
| `net-hbo` | "From HBO" | `"49"` |
| `net-netflix` | "Netflix Originals" | `"213"` |
| `net-apple` | "Apple TV+" | `"2552"` |
| `net-amc` | "AMC" | `"174"` |
| `net-fx` | "FX" | `"88"` |
| `net-disney` | "Disney+ Originals" | `"2739"` |
| `net-amazon` | "Prime Video" | `"1024"` |

Each row fetches `tmdbDiscover(key, "tv", { with_networks: id, "vote_count.gte":
threshold, sort_by: "popularity.desc", page })` (`providers/tmdb/tmdb-catalogs.ts:81-96`),
same `RowSpec.fetcher(page)` contract as every other row, paginated at
`PAGINATE_THRESHOLD=14` like §2.5. HBO (`49`) and Netflix (`213`) also appear among the
~19 hero-pool source queries (`hero-curation.ts:327-339`) but only to help build the
rotating hero pool, not as separate visible rows. TV Shows room reuses the identical
`showSpecs(key)` function desktop uses — no TV-specific network list.

Note: `"network"` also appears heavily in `bp-live*.ts`/`bp-guide-order.ts` (IPTV
channel network grouping) — a completely separate Live-TV subsystem, unrelated to
these browse rooms.

---

## 4. SEARCH

Search fans out to multiple sources in parallel from a single `useEffect` in
`src/lib/search-context.tsx` (debounced body `search-context.tsx:222-404`). TV
projection: `src/views/big-picture/use-bp-search.ts`.

### 4.1 Search providers

**a) TMDB `search/multi`** (primary title/people source) — `searchAll()`
(`src/lib/search.ts:264-268`):
```ts
const data = await get<Page<MultiItem>>(key, "search/multi", {
  query: trimmed,
  include_adult: "false",
  ...(loadStoredSettings().translateTitles ? {} : { language: "en-US" }),
});
```
Full template (`providers/tmdb/tmdb-client.ts:100-111`):
`https://api.themoviedb.org/3/search/multi?api_key={key}&language={lang}&query={q}&include_adult=false`
(params alphabetically sorted). A second English-language call backfills names when
title-translation is on and UI language isn't English/Japanese. Fuzzy person fallback:
`search/person?query={longestToken}&include_adult=false&language=en-US` when a
multi-word query is ambiguous/empty. TMDB is skipped if `trimmed` is empty or no API
key configured.

**b) Cinemeta search catalog** — `searchCinemeta()` (`lib/search.ts:237-249`):
```
https://v3-cinemeta.strem.io/catalog/{movie|series}/top/search={encodeURIComponent(q)}.json
```
(the Stremio addon-catalog convention — catalog id `top`, `search=<q>` as a path
segment, not a query param), both types queried in parallel. Min length `q.length < 2`
→ `[]`. **Note**: `lib/cinemeta.ts` itself has no search function — the search call
lives only in `lib/search.ts`. Cached client-side 60s (`SECONDARY_CACHE_TTL_MS`).

**c) Installed addon catalogs with a `search` extra**:
`catalogSupportsSearch()` (`lib/search-addons.ts:21-24`) — qualifies if
`catalog.extra` contains a `"search"` entry OR `catalog.extraSupported` contains
`"search"`. `catalogIsSearchable()` denylists `type === "addon_catalog"` (case
insensitive). Two consumers:
1. `searchAddonCatalogs()` — fuses matching addon results into merged Movies/Series
   rows, round-robin one catalog per addon per pass, `MAX_CATALOGS = 24` total.
2. `searchAddonGroups()` — keeps each addon's results as its own row, up to 6
   catalogs/addon, `GROUP_CONCURRENCY = 8`, `GROUP_TIMEOUT_MS = 20_000` per catalog,
   `ALL_GROUPS_BUDGET_MS = 30_000` wall clock.

Request shape (both): `GET {addon.transportUrl minus "/manifest.json"}/catalog/{type}/
{id}/search={encodeURIComponent(q)}.json`, `Accept: application/json`. Addon list
source: `gatherCatalogAddons(authKey)`, cached per auth key, invalidated on
`"harbor:addons-changed"` window event.

**d) Addon index** (addons you *could* install) — `searchAddonIndex()`
(`lib/search-addon-index.ts:31-71`), local fuzzy substring match over installed +
`CURATED_ADDONS` metadata (name/description/id/transportUrl). Min length 2. **Not a
network call.**

**e) Anime** — three parallel providers, merged/deduped, `searchAnime()`
(`lib/search.ts:199-235`):
- AniList: `anilistAnimeSearch(q, limit)`, 1500ms timeout.
- Jikan (MAL): `jikanAnimeSearch()` — `https://api.jikan.moe/v4/anime?q={q}&order_by=
  popularity&sort=asc&limit={limit}&sfw=true`, 1200ms timeout.
- Kitsu: `kitsuAnimeSearch()` — `https://kitsu.io/api/edge/anime?filter%5Btext%5D=
  {q}&page%5Blimit%5D={limit}&sort=-userCount`, header `Accept:
  application/vnd.api+json`, 3000ms timeout.
- All min-length 2, deduped by MAL id / normalized name.

**f) Manga** — `searchManga(trimmed)` (`@/lib/manga/api`), gated
`settings.mangaEnabled && !settings.hideContent.manga`.

**g) AniList characters** — `anilistCharacterSearch(trimmed)`, gated
`animeAllowed || mangaAllowed`.

**h) Live TV channels** — `searchLiveTvChannels()` (`lib/search.ts:82-112`), purely
local match against cached IPTV playlist channels, no network call. Min length 2,
gated `!hiddenTabs.liveTv && playlists.length > 0`.

Every source is wrapped in a per-source `SOURCE_TIMEOUT_MS = 8000` race-timeout
(`guard()` helper) resolving to an empty fallback rather than blocking the others.

### 4.2 Debounce

**180ms** — `window.setTimeout(() => {...}, 180)` (`search-context.tsx:222-404`, timer
literal on line 404). Status flips `"typing"` on query change, `"loading"` once the
timer fires. A monotonic request-id guard (`search-request-guard.ts:6-13`) discards
stale in-flight results if the query changed before they resolved.

Min query length: no single global constant. TMDB `search/multi` fires for any
non-empty trimmed query; Cinemeta/anime×3/addon-index/live-TV all require `length >=
2`; the AI-mode auto-trigger requires `length >= 6`. The effect skips entirely (results
cleared, `"idle"`) if `trimmed` is empty or while `aiHold` is set (AI mode active,
§4.4).

### 4.3 Result grouping

**TV/Big Picture** grouping — `buildBpSearchSlots()` (`use-bp-search.ts:184-273`) turns
one `SearchResults` into an ordered row-section array, each with a stable `key`,
`label`, `group` filter id.
- Fixed group order (`GROUP_ORDER`): `movie, series, people, anime, manga, livetv,
  collections, characters, addons` (plus `top`/`all`).
- Group labels: Movies, Series, People, Anime, Manga, Live TV, Collections, Franchise,
  Addons.
- Row push order: **Top match** (1 row) → **People/Movies/Series** (People promoted
  ahead if the query best-matches a known person, decided once per query via a latch)
  → **Anime** → **Manga** → **Live TV** → **Collections** → **Franchise/characters**
  (one row per AniList character hit) → one row **per installed addon queried**
  (deliberately not deduped against the fused Movies/Series rows) → **"Addons you
  could install"** (local addon-index results).
- Rows are always present (never appended late) so rail indices stay stable while
  sources stream in; an unanswered row is `pending: true` with a loading skeleton.
- Filter chips = "All" + one chip per group that has ever had ≥1 result this query (a
  chip is never removed once shown).
- Movies/Series rows are themselves a merge of TMDB + per-addon catalog hits +
  Cinemeta, deduped by normalized title+year (`dedupeByTitle`) via `mergeMetas()`, then
  anime titles filtered out if matching an anime hit or if anime is hidden in settings.
  This fusion happens in `publish()` (`search-context.tsx:309-353`).

Desktop (`components/search/search-overlay.tsx`) uses a parallel but separate
rendering (`TopMatch` → `MetaList` per type → `AddonResults`/`AddonGroup` →
`AddonHits` → `AiSearchSection`) — same underlying data, different UI, not a separate
provider.

### 4.4 AI search

**Desktop-only** — an LLM natural-language "ask for titles" mode layered on top of
regular search. Grep across `src/views/big-picture` and `src/components/search` found
**no** references to `AiSearchSection`/`useAiSuggest`/`AiModeButton`/`AiSuggestButton`
in any Big Picture file. **This feature does not exist in the TV Search room.**

- Call: `aiSuggest()` (`lib/ai-search.ts:63-117`). Two providers via `isGroq`:
  OpenRouter `https://openrouter.ai/api/v1/chat/completions` (headers
  `HTTP-Referer`, `X-Title: "Harbor"`) or Groq
  `https://api.groq.com/openai/v1/chat/completions`. Both OpenAI-chat-completions POST
  bodies: `{ model, temperature: 0.4, max_tokens: 2000, messages: [{role:"system",
  content: SYSTEM_PROMPT + optional web context}, {role:"user", content: query}] }`.
  System prompt instructs the model to reply with only a JSON array of up to 12
  `{title, year, type}` objects (plus `season`/`episode`/`episodeTitle` for
  episode-specific queries), most relevant first. Response parsed defensively, deduped
  by lowercased title, capped `MAX_SUGGESTIONS = 12`.
- Optional web grounding: if `settings.aiWebSearch`, `enrichWithContent(query,
  jinaKey)` (`lib/jina-search`) fetches context appended to the system prompt first.
- Trigger: user must explicitly enable AI mode via `AiModeButton` (toggle on
  click/tap; hold ~320ms or right-click opens a model picker). Once on: Enter or
  Shift+Enter fires immediately; an auto-run fires 1600ms after typing stops if AI mode
  is on, a key is present, status is idle, and query length ≥6. Enabling AI mode
  **suspends** normal search entirely (`setAiHold(true)`) — not a no-results fallback.
- Returns: `AiResult[]` — each a resolved Cinemeta `Meta` via `resolveAiSuggestions()`
  (re-runs `searchCinemeta(s.title)` per suggestion, title/type/year-scores the best
  match) plus optional episode fields.
- Errors mapped by HTTP status (`friendlyAiError()`): 401 bad key, 402 out of credits,
  404 model gone, 413 too large, 429 rate limited, else generic.

### 4.5 On-screen keyboard (verbatim arrays)

Both arrays defined in `src/views/big-picture/bp-keyboard.tsx:7-24`:

```ts
const LETTERS = [
  "1234567890".split(""),
  "qwertyuiop".split(""),
  "asdfghjkl'".split(""),
  "zxcvbnm,.-".split(""),
];
const SYMBOLS = [
  "!@#$%^&*()".split(""),
  "+=/\\|~`°£€".split(""),
  ":;\"?<>[]{}".split(""),
  "éèáàöüñçåø".split(""),
];
```

- 4 rows each, `rows.map(...)`, each row in a `div[data-bp-row]` +
  horizontally-scrollable `div[data-bp-scroll-x]`.
- No Shift/Caps — always lowercase; a single toggle swaps the whole set between
  LETTERS and SYMBOLS (`symbols` boolean state). Toggle key label: `"abc"` when
  currently showing symbols, else `"?#+"`; part of a 5th row alongside special keys:
  - **Space**: label `"Space"`, `Space` icon (size 19), `wide={5}`, → `onChar(" ")`.
  - **Backspace**: label `"Backspace"`, `Delete` icon, `wide={2}`, → `onBackspace`.
  - **Clear**: label `"Clear"`, `X` icon, `wide={2}`, → `onClear`.
- Each key: `<button data-bp-focusable data-bp-key>`, `SFX.click()` on press; keys can
  be `disabled` (grayed, `tabIndex={-1}`, `data-bp-disabled="true"`).
- Renders `null` entirely on Android (`isAndroid()` guard) — native IME used instead.
- Props: `onChar(c: string)`, `onBackspace()`, `onClear()`, `disabled?: boolean`.

**Keyboard sheet wrapper** (`bp-keyboard-sheet.tsx`): bottom sheet
(`translate-y-full`↔`translate-y-0`), `role="dialog"`, `aria-label="On-screen
keyboard"`, `inert` when closed. On open, focus jumps to the sheet's first focusable
key. Registers a Back-button handler that closes the sheet exactly like the Done key.
`data-bp-dialog` (open only) scopes D-pad navigation to the keys until Done/Back. Below
the keys: a full-width **Done** key (`CornerDownLeft` icon + "Done" text), disabled
when the sheet is closed. Background: gradient scrim fading from solid `--bp-void` at
bottom to transparent at top so the results rail stays partly visible.

---

## 5. COLLECTIONS

There is **no single collections data source** — the room merges **five sources**,
selectable via a chip row: `all | mine | community | tvdb | tmdb`
(`bp-collection-steps.ts:19-27`):
```ts
export type BpCollectionSource = "all" | "mine" | "community" | "tvdb" | "tmdb";
export const BP_COLLECTION_SOURCES: BpCollectionSource[] = ["all","mine","community","tvdb","tmdb"];
```
Orchestration: `bp-collection-steps.ts` (`step()`, `makeCtx()`), driven by
`useBpCollectionFeed` (`use-bp-collection-feed.ts:101-257`).

### 5.1 Data sources

1. **"mine"** — user-curated local lists, `lib/collections.ts`. `useCollections()`
   reads `localStorage["harbor.collections.v1"]` (or per-profile variant) via
   `readCollections()`. Local/offline only. CRUD: `createCollection`,
   `addToCollection`, `reorderCollectionItems`, etc.
2. **"community"** — other users' shared collections from Harbor's backend.
   `fetchCommunityCollections()` (`lib/social/collections-sync.ts:143-159`) —
   `GET ${BASE}/collections/community` → `CommunityCollection[]`.
3. **"tvdb"** — TheTVDB "lists", via Harbor's proxy
   (`lib/providers/tvdb-collections.ts`). `searchTvdbCollectionsOrNull(query)` hits
   `${HARBOR_TVDB_BASE}/api/tvdb/v4/search?...&type=list`, seeded by names from the
   curated catalog. Detail: `fetchTvdbCollection(id)` → `GET /lists/{id}/extended`;
   each member resolved via `fetchTvdbEntity()` → `/movies|series/{id}/extended`.
4. **"tmdb" curated** — a bundled ~110-entry franchise catalog, `COLLECTIONS_CATALOG`
   (`lib/collections-catalog.ts:16-142`, type `CatalogCollection = { id: number; name:
   string; cats: string[] }`); many `id: 0` entries healed by name search. Resolved via
   `resolveBpCollection()` (`use-bp-collections.ts:60-78`) — TMDB `collection/{id}`
   direct hit, or `search/collection` fallback.
5. **"tmdb" open feed** — pages through TMDB's `search/collection?query=collection`
   (TMDB has no "list all collections" endpoint), capped at TMDB's `total_pages`,
   clamped to 500. A parallel category-filtered version, `useCategoryFeed()`
   (`views/collections/use-category-feed.ts`), is shared verbatim between desktop
   (`views/collections.tsx:13`) and TV (`use-bp-collection-feed.ts:5`).

### 5.2 Collection type shape (verbatim) — three distinct shapes, no unified type

**(a) User/community** (`lib/collections.ts:59-76`):
```ts
export type CollectionItemType = "movie" | "series" | "manga";

export type CollectionItem = {
  id: string;
  type: CollectionItemType;
  name: string;
  poster?: string;
};

export type Collection = {
  id: string;
  name: string;
  description?: string;
  coverImage?: string;
  bgImage?: string;
  tags?: string[];
  shared?: boolean;
  numbered?: boolean;
  sourceHandle?: string;
  sourceId?: string;
  items: CollectionItem[];
  createdAt: number;
  updatedAt: number;
};
```
Limits: `MAX_COLLECTIONS=24`, `MAX_COLLECTION_ITEMS=100`, `MAX_COLLECTION_NAME=80`,
`MAX_COLLECTION_DESCRIPTION=500`, `MAX_COLLECTION_TAGS=8`, `MAX_TAG_LENGTH=24`.

Community variant (`lib/social/collections-sync.ts:123-127`):
```ts
export type CommunityCollection = Collection & {
  handle: string;
  displayName: string;
  avatarUrl?: string;
};
```

**(b) TMDB** (`providers/tmdb/tmdb-collection.ts:5-13`):
```ts
export type TmdbCollection = {
  id: number;
  name: string;
  overview: string;
  poster?: string;
  backdrop?: string;
  parts: Meta[];
  genreCounts?: Record<number, number>;
};
```

**(c) TVDB** (`providers/tvdb-collections.ts:7-31`):
```ts
export type TvdbCollectionHit = { id: number; name: string; image: string | null; overview: string | null };
export type TvdbCollectionEntry = { kind: "movie" | "series"; tvdbId: number };
export type TvdbCollection = { id: number; name: string; overview: string | null; image: string | null; entries: TvdbCollectionEntry[] };
export type TvdbEntityCard = { kind: "movie" | "series"; tvdbId: number; name: string; year: string | null; poster: string | null; imdb: string | null };
```

**(d) Unified BP browse-grid entry** (`bp-collection-steps.ts:29-49`) — what the room
actually renders per card:
```ts
export type BpCollectionEntry = {
  key: string;
  source: Exclude<BpCollectionSource, "all">;
  name: string;
  image: string | null;
  count: number | null;
  byline: string | null;
  open: BpCollectionOpen;
};

export type BpCollectionOpen =
  | { kind: "tmdb"; collectionId: number; name: string; image: string | null }
  | { kind: "tvdb"; collectionId: number; name: string; image: string | null }
  | { kind: "items"; name: string; byline: string | null; image: string | null; items: CollectionItem[]; hidden: number };
```

### 5.3 Room layout

Routes (`bp-shell.tsx:460-480`): `collections` → `BpCollections` (main); `tmdb-
collection` → `BpCollectionDetail`; `collection` → `BpCollection` (TVDB detail).
"mine"/"community" open as an in-place `BpCollectionItems` overlay, not a route push.

**Main screen** (`bp-collections.tsx:108-260`): chip row of 5 sources with a live
`"{count} collections"` label; when source = "tmdb", a second category chip row
(`BP_COLLECTION_CATEGORIES = ["All", Sagas, Superheroes, Action, Adventure, Sci-Fi,
Fantasy, Animation, Horror, Comedy, Crime]`). Body: a **grid** (not a row) of
`BpCollectionCard`, aspect `16/9`; 8 skeleton placeholders on first load.
`BpCollectionMoreCard` ("See every TVDB list") injected after the last TVDB card when
capped (`TVDB_ALL_CAP=10` in "all" mode). No TMDB key → replaced entirely by a
`BpConnect` prompt.

**Home-screen preview rows** (reuse the same cards, separate from the main screen):
`BpCollectionsRow` (horizontal, `limit=30`, trailing "View all") and
`BpCollectionsBand` — both sourced only from the curated TMDB catalog via
`useBpCuratedRow()`.

**TMDB collection detail** (`bp-collection-detail.tsx:16-80`): poster + "Collection"
eyebrow + title + `"{n} films" · {years}"` + 2-line overview; body = poster grid
(`BP_POSTER_COLUMNS`, same as §2 genre grid). Empty text: "No films found in this
collection."

**TVDB collection detail** (`bp-collection.tsx:76-122`): same shell, no header
thumbnail, no count/year line. Up to 40 entries (`MAX_ENTRIES=40`) hydrated at
`HYDRATE_LANES=4` concurrency. Empty text: "Couldn't load this collection right now."

**"Mine"/"community" detail** (`bp-collection-items.tsx:30-124`): full-screen
`role="dialog"` overlay (`z-30`), not a route push. Header: byline (or "My
collection") + title + `"{count} items"` + optional "{n} manga items are not shown in
Big Picture." note + Close. Empty text: "This collection is empty."

**Desktop equivalents** (`views/collections.tsx`, `views/collection.tsx`) share
underlying logic (`use-category-feed.ts`, `COLLECTIONS_CATALOG`, TMDB fetch layer) but
are a simpler, TMDB-only implementation — no mine/community/tvdb sources, has a
free-text search box that the TV room does **not** have.

### 5.4 Pagination / sorting / filtering

**Pagination**: infinite-scroll via `IntersectionObserver`, no page-number UI. Step
machine pulls up to `STEPS_PER_PULL=3` phase-steps per intersection, auto-continues up
to `AUTO_PULLS=4` times with `RECHECK_MS=300` settle delay. TMDB curated phase: `24`
entries/step (`TMDB_PAGE`), hydrated at 4 concurrency. TMDB open feed: real TMDB
`page`, capped `min(total_pages, 500)`. TVDB: `TVDB_NAMES_PER_PULL=5` seed names/step,
up to `TVDB_HITS_PER_NAME=3` hits each, capped `TVDB_ALL_CAP=10` in "all" mode.
Category feed: `PAGES_PER_PULL=4` TMDB pages/step, aiming `MIN_MATCHES_PER_PULL=6`.
Community/"mine" are fetched in full, not paginated.

**Filtering**: source chip (`all|mine|community|tmdb|tvdb`); TMDB category chip (10
fixed categories, static for curated entries, heuristic `genreCounts`-based for the
open feed); curated names excluded from the open TMDB feed to avoid dupes
(`BP_CURATED_NAMES`); manga items filtered out of mine/community entries (hidden count
surfaced); minimum-size filter `parts.length >= 2` for TMDB feed entries.

**Sorting**: no explicit user sort control. "Mine" sorted by `updatedAt` descending.
TMDB collection *parts* sorted by release date ascending. TVDB entries sorted by
TVDB's `order` field ascending. Everything else is insertion/fetch order (mine →
community → curated TMDB → TVDB → open TMDB feed).

---

## 6. METADATA PROVIDERS

Every HTTP endpoint the rooms above consume, with URL templates, keys, response fields
used, caching, and budgets.

### 6.1 Cinemeta

Base (hardcoded, `cinemeta.ts:4`, duplicated in `providers/cinemeta-details.ts:7`):
`const CINEMETA = "https://v3-cinemeta.strem.io";` No API key.

- Catalog: `${CINEMETA}/catalog/${type}/top[/genre={genre}][/skip={skip}].json`
  (`cinemeta.ts:99-110`).
- Meta: `${CINEMETA}/meta/${movie|series}/${imdbId}.json` (`cinemeta.ts:134`). Also
  called with the base duplicated directly in `providers/cinemeta-details.ts:156` and
  `providers/harbor-imdb.ts:88` (parental-rating title/year resolver fallback).

`Meta` type — quoted verbatim in §8.

Fields consumed: the full `Meta` shape flows straight into rows — `poster`,
`background`, `logo`, `name`, `imdbRating`, `genres`, `videos[]` (episode list,
`firstAired`/`released`, `thumbnail`). `cinemeta-details.ts` maps a raw
`CinemetaMeta` into the same `TmdbDetail` shape TMDB produces so the detail page can
render off either source uniformly.

**Caching** (`cinemeta-cache.ts`): in-memory `Map` keyed `${type}:${id}`, max 80
entries (`MEM_MAX_ENTRIES`), LRU. Disk `localStorage["harbor.cinemeta.meta.v1"]`, max
64 entries, 20000 chars/entry, 400000 chars total, 4000ms flush debounce. TTL: movies
24h (`MOVIE_TTL_MS`), series 3h (`SERIES_TTL_MS`), negative/null 30min
(`NEGATIVE_TTL_MS`). `cinemetaDetails()` has its own separate 30-min TTL cache keyed
`${type}:${imdbId}`. Toggle: `settings.cinemetaEnabled`, default `true` when unset. No
explicit rate limit/concurrency budget (no scheduler wraps this fetch, unlike TMDB).

### 6.2 Addon catalog / meta (Stremio addon protocol)

Generic contract Harbor calls against every installed/subscribed addon's
`transportUrl`. `AddonRow` type — quoted verbatim in §8.

- Catalog: `{addonBase}/catalog/{type}/{id}[/{extraName}={extraValue}&...].json`
  (`addons.ts:351-357`).
- Paginated catalog: `{base}/catalog/{type}/{id}[/{name}={value}&...][&skip={skip}].json`
  (`addons.ts:450-469`, skip appended when >0).
- Meta: `{addonBase}/meta/{type}/{id}.json` (`addons.ts:439-448`).
- GET, no body. Response: `{ metas?: Meta[] }` (catalog) / `{ meta?: Meta }` (detail).

**Timeout/budget**: `fetchWithTimeout(url, timeoutMs=8000)` (`addons.ts:224-236`),
`AbortController`, attaches `Accept-Language` from region/language settings
(`addonAcceptLanguage()`). Concurrency: `CATALOG_LANES = 6` via `runLanes`. Row cap:
`MAX_ROWS = 24` after dedup. Per-row cache: `addon-catalog-cache.ts`, key
`${transportUrl}|${type}|${id}`, `TTL_MS = 10 * 60 * 1000` (10 min), `MAX_ENTRIES =
80`, plus in-flight de-dup. `gatherCatalogAddons` merges Stremio-account addons (`POST
https://api.strem.io/api/addonCollectionGet`) with locally installed ones.

`hydrateLibraryMeta` (`views/library/hydrate-meta.ts:32-43`) — the fallback `useBpArt`
calls when a tile has no art — retries `fetchAddonMeta` against every addon instance
matching a meta's `addonOrigin` before falling through to TMDB/Cinemeta.

### 6.3 TMDB

Base (`providers/tmdb/tmdb-client.ts:5-6`): `TMDB = "https://api.themoviedb.org/3"`,
`IMG = "https://image.tmdb.org/t/p"`. Key: `settings.tmdbKey` (default `""`), passed as
`api_key` query param inside `get()`.

**Wrapper**: `get<T>(key, path, params)` builds `${TMDB}/${path}` + sorted params,
injects `language` from `effectiveTmdbLanguage()` unless supplied; catalog-path
responses cached via `createCatalogCache()`; non-catalog requests in-flight-deduped.
`TMDB_TIMEOUT_MS = 15000`.

**Scheduler**: `createRequestScheduler({ concurrency: 6 })` (`tmdb-client.ts:8`).
Retries up to 4 attempts on 429/5xx, exponential backoff `min(2000, 250 * 2^attempt)`
ms, applied both as a local wait and via `tmdbRequests.pauseFor(backoffMs)` (stalls the
whole scheduler queue). (Other scheduler instances elsewhere: concurrency 4 for
credit-IMDb ratings, concurrency 3 for collaborators — not browse-relevant.)

**Endpoints used**: `movie|tv/{popular|top_rated|now_playing|upcoming|
airing_today|on_the_air}`, `discover/{movie|tv}`, `trending/{type}/{day|week}`,
`search/{movie|tv}`, `{movie|tv}/{id}` (detail, `append_to_response:
"credits,aggregate_credits,recommendations,similar,videos,external_ids,images,
keywords,translations"`), `find/{imdbId}?external_source=imdb_id`, `{movie|tv}/{id}/
images`, `{kind}/{id}/videos`, `{kind}/{id}/credits`, `{kind}/{id}/
aggregate_credits`, `tv/{id}/season/{season}`, `tv/{id}/episode_groups`, `tv/
episode_group/{groupId}`, `{kind}/{id}/external_ids`, `collection/{id}`, `person/
{id}`, bare `{kind}/{id}` (vote lookups).

**Image URL templates** (`providers/tmdb/tmdb-image-rungs.ts:1-27`):
```ts
export const POSTER_RUNG = "w500";
export const POSTER_THUMB_RUNG = "w342";
export const BACKDROP_RUNG = "w780";
export const LOGO_RUNG = "w500";
export const STILL_RUNG = "w300";
```
i.e. `https://image.tmdb.org/t/p/{w500|w342|w780|w300}{filePath}`. Gallery building
uses `w780` backdrops (24-cap), `w342` posters, `w500` logos (12-cap).

**Fields used**: catalog rows map `id, title/name, original_title/original_name,
overview, poster_path, backdrop_path, release_date/first_air_date, vote_average,
genre_ids, adult, original_language` → `Meta` (poster/backdrop run through
`tmdbPosterUrl`/`tmdbBackdropUrl`). Full detail (`TmdbDetail`) surfaces `poster,
backdrop, logo, year, rating, voteCount, runtime, status, genres, originalLanguage,
spokenLanguages, productionCountries/Companies, networks, trailerYtId/
trailerCandidates, extraVideos, gallery.{backdrops,posters,logos}, cast/crew/
directors/writers/creators/producers/composer/cinematography/editor,
recommendations/similar, seasons, keywords, firstAirDate/lastAirDate/releaseDate,
budget/revenue/homepage`.

**Caching**: `find/{imdbId}` → `localStorage["harbor.tmdb.find.v1"]`, cap 600, 3000ms
debounce. `fetchMovieAssets` (images) in-memory, key
`${metaId}|${originalLang}|${imageLangParam}`, cap `MOVIE_ASSETS_MAX=400`, no TTL.
`defaultPosterCache` same cap, no TTL. Generic catalog-path cache gated by
`isCatalogPath(path)`.

### 6.4 Fanart.tv

Base: `const FANART = "https://webservice.fanart.tv/v3";` Key: `settings.fanartKey`
(default `""`), passed as `key` param.
- Movie: `${FANART}/movies/${tmdbId}?api_key={key}`
- TV: `${FANART}/tv/${tvdbId}?api_key={key}`

Fields: `hdmovielogo`/`movielogo`, `moviebackground`, `movieposter`, `moviebanner`,
`moviethumb` (movie); `hdtvlogo`/`clearlogo`, `showbackground`, `tvposter`,
`tvbanner`, `tvthumb` (TV). Selection: `lang==="en"` rank 1 > `lang==="00"` rank 0.5 >
other rank 0, tiebreak by `likes` descending. Cache: in-memory `Map`, `TTL = 6h`.

**Not used by the TV browse-room art chain** — `fanartMovie`/`fanartTv` are only
referenced from `views/mobile/mobile-search.tsx` and `providers/anime-detail.ts`.

### 6.5 RPDB / poster proxies

No fixed base — configurable `posterBaseUrl` (default `""`) + `rpdbKey` (default
`""`). Templates chosen by host match (`rpdb.ts:88-120`):
- Default RatingPosterDB: `https://api.ratingposterdb.com/{key}/imdb/poster-default/
  {imdbId}.jpg?fallback=true` (also supports tmdb/tvdb variants).
- `btttr.cc` ("Better Posters"): `{base}/poster/imdb/poster-default/{imdbId}.jpg` (no
  key).
- `postersplus`/`elfhosted`: `{root}/poster?tmdb_id={tmdbId}&imdb_id={imdbId}&
  type={movie|series}`.
- Generic `{...}` template mode: substitutes `{imdbId}`, `{tmdbId}`, `{type}`, etc.

No JSON fields consumed (returns an image directly); no fetch-side caching (pure URL
construction). **Not used by TV browse rooms** — same grep scope as Fanart, mobile-
search/anime-detail only.

### 6.6 OMDb

Endpoint (inlined, no base constant): `https://www.omdbapi.com/?i={imdbId}&
apikey={key}[&type={type}]`; season variant `...&Season={season}&apikey={key}`. Key:
`settings.omdbKey` (default `""`).

Fields used: `imdbRating`, `Rated` (regex-filtered), `imdbVotes` (comma-stripped),
`Ratings[]` filtered for Rotten Tomatoes / Metacritic sources, `Awards` (free-text
regex-parsed into oscar/emmy/bafta/globe won/nominated counts), `Response`/`Error`.
`certifiedFresh` is derived (not from OMDb): `rtCritics >= 75 && imdbVotes >= 50000`
(`CERTIFIED_FRESH_MIN_VOTES=50000`).

**Caching**: score cache `localStorage["harbor.omdb.v1"]`, cap 1500, TTL 90 days
(`STALE_MS`). Miss cache `localStorage["harbor.omdb.misses"]`, cap 1000, TTL 24h. Season
ratings: in-memory LRU cap 200, no TTL. Disk persist debounced 5000ms.

**Rate limit**: daily quota `localStorage["harbor.omdb.budget"]`, `DEFAULT_LIMIT =
1000` req/day, resets next UTC midnight. Prefetch refuses at 90% used
(`PREFETCH_THRESHOLD=0.9`). 401 → `keyInvalid`; error text matching
`/limit|exceeded|daily|reached/i` → `exhausted`.

### 6.7 MDBList

Key: `settings.mdblistKey` (default `""`). Two modules:
- Single lookup (`mdblist.ts:49-76`): tries `https://api.mdblist.com/imdb/
  {movie|show}/{imdbId}?apikey={key}`, falls back to legacy `https://mdblist.com/
  api/?apikey={key}&i={imdbId}`.
- Batch (`mdblist-batch.ts:106-113`): `POST https://api.mdblist.com/imdb/{movie|show}/
  ?apikey={key}` with JSON body `{ ids: string[] }`.

Fields: `ratings[]` filtered by source (`letterboxd`, `trakt`, `metacritic`,
`tomatoesaudience`/`audience`/`popcorn` → `rtAudience`, `simkl` rescaled `/10` if
`>10`); aggregate from `score_average ?? scoreaverage ?? score`.

**Caching**: single-lookup — in-memory `Map` only, no TTL/persistence. Batch —
`localStorage["harbor.mdblist.cards"]`, cap 1500, TTL 24h, flush debounce `FLUSH_MS =
300`, `MAX_BATCH = 100` ids/POST, 429 backoff `BACKOFF_MS = 10 * 60 * 1000` (10 min).

### 6.8 Harbor's own IMDb proxy

Base: `${HARBOR_API_BASE}/api/imdb` where `HARBOR_API_BASE` = `import.meta.env.
VITE_HARBOR_API_BASE` or hardcoded fallback `"https://harbor.site"`. No API key
(first-party backend).
- `${BASE}/episodes/${seriesTt}` → per-episode ratings, `{ ratings?:
  Record<episodeKey, number> }`.
- `${BASE}/title/${tt}` → `{ rating?: number|null }`.
- `${BASE}/parental/${tt}` → `{ categories?: ParentalCategory[]; mpaRating?: string }`
  (`ParentalCategory = { category: string; severity: string }`), 3000ms
  `AbortSignal.timeout`.

**Fallback chain for parental data**: Harbor backend → on failure, resolve title
name+year via a *direct* Cinemeta call (bypassing the shared client) → then Common
Sense Media advisory (`providers/csm.ts`, out of scope here). Caching: in-memory only;
`episodeCache`/`parentalCache` LRU-capped 200; `titleCache`/`mpaRatingCache` unbounded
`Map`s, cleared only under memory pressure.

### 6.9 Region handling

`lib/region-flags.ts` — static ISO-code → flag-asset map (54 entries), purely
cosmetic. `lib/region/locale-map.ts` — `localeForRegion(region)` returns a
`LocaleProfile` (`uiLanguage, tmdbLanguage, contentLanguage, subtitleLanguage,
audioLanguage, rtl, greetingKey`) by matching hardcoded region sets (`ARAB_REGIONS` 22
codes, `LATAM_REGIONS` 18 codes, `RUSSOPHONE_REGIONS`, `LUSOPHONE_REGIONS`, `ES`,
`REGIONAL_DEFAULTS` table, else English). This `tmdbLanguage` feeds every TMDB `get()`
call; `region` (default `"US"`) feeds `discover`/row params. Addon requests separately
derive `Accept-Language` from the same settings via `addonAcceptLanguage()`.

### 6.10 Shared request-scheduler infrastructure

`lib/request-scheduler.ts` — `createRequestScheduler({ concurrency })`: FIFO queue,
concurrency cap, per-key in-flight de-dup, `pauseFor(ms)` circuit breaker that stalls
the whole queue. Concurrency is supplied per caller: TMDB `6`; credit-IMDb-ratings `4`;
collaborators `3`.

### 6.11 Art resolution order

Two distinct priority chains, at two layers.

**1. Row/tile art pick** — `pickArt()` (`use-bp-art.ts:33-54`), the function
`useBpArt` calls before any network fetch:
```ts
function pickArt(
  shape: Shape,
  width: number | undefined,
  poster?: string,
  background?: string,
  pinned?: string,
  override?: string,
): Picked {
  if (pinned) return { url: pinned, wide: true, raw: pinned };
  if (override && shape !== "wide") return { url: override, wide: false, raw: override };
  const raw = shape === "wide" ? (background ?? poster) : (poster ?? background);
  ...
}
```
Priority: (1) `pinned` (user-pinned custom image, always wide) → (2) `override`
(custom poster, non-wide tiles only) → (3) `shape==="wide"`: `background` then
`poster`; `shape==="poster"`: `poster` then `background`. `poster`/`background` are
whatever the `Meta` already carries (Cinemeta, addon, or TMDB row mapper).

If step 3 yields nothing (`missing = !stored.url`), the tile becomes visible-triggered
and calls `bpHydrateSlot` (4-lane concurrency gate, `bp-art-hydrate.ts:6-20`) to run:
- `animeKitsuMeta(id)` if id matches `/^(kitsu|mal|anilist|anidb):/`, or
- `hydrateLibraryMeta(id, narrowMediaType(type), tmdbKey)` otherwise.

`hydrateLibraryMeta` (`views/library/hydrate-meta.ts:12-90`) 3-step chain: (1) if the
`Meta` carries `addonOrigin`, try `fetchAddonMeta` against every matching addon base
URL; (2) else if `id` starts with `tmdb:` and a key is set, fetch TMDB `{movie|tv}/
{id}` directly, build poster/background via `tmdbLocalizedPoster()`; (3) else fall
through to `resolveMeta(authKey, type, id)` (`lib/meta-resource.ts:32`), which races
Cinemeta against installed/account addons (Cinemeta first unless
`preferCustomMetaAddon` is on). Result re-enters `pickArt`.

A failed sized URL isn't immediately dead: `live()` retries the untransformed raw URL
once before triggering hydration; a `dead` `Set` (LRU-capped `DEAD_CAP=400`) remembers
URLs that failed even untransformed, module-scoped for the session.

**2. Hero backdrop pick** — `prefetchBpRowNeighbours`
(`bp-art-prefetch.ts:104-135`), used to prefetch the richer TMDB-enriched hero
backdrop:
```ts
const best = [detail?.gallery?.backdrops?.[0], detail?.backdrop, m.background].find(Boolean);
```
Priority: (1) TMDB `TmdbDetail.gallery.backdrops[0]` (top-voted `w780` from the images
endpoint) → (2) `TmdbDetail.backdrop` (TMDB's own flagged primary) → (3) `m.background`
(catalog-supplied). `detail` comes from `warmBpEnrich(tmdbKey, meta)`
(`use-bp-enrich.ts:27-42`), calling `tmdbDetails()` only if a key is set, cached in a
module-scoped `Map<metaId, TmdbDetail|null>` with no TTL/eviction. No key → skips
straight to `m.background`.

**Sizing** (downstream of source selection, in `bp-art.ts`): `bpCardArt(url,
targetWidth)` and `bpHeroArt(url, shape)` rewrite URLs to the nearest size bucket for
DPR/viewport — TMDB buckets `[300, 500, 780, 1280]` or `original` (`TMDB_BUCKETS`),
Metahub `small`/`medium`/`large`, TheTVDB `_t` thumbnail suffix, AniList
`small`/`medium`/`large` path segments, MAL large-suffix stripping.

**Fanart.tv and RPDB are not part of this chain** — neither is referenced from any
`bp-*`/`use-bp-*` file.

---

## 7. CARD BADGES / STATE MARKS

Files: `bp-card-marks.tsx` (top-start "identity" chip), `bp-card-state-marks.tsx`
(top10 ribbon, watchlist, watched, local-library, score row), `use-bp-card-badges.ts`
(rating/score badge assembly). See `docs/big-picture-design.md` §8.4 for the pixel
geometry of these zones (7px insets, chip padding, circle sizing); this section covers
only the trigger rule for each mark.

**Layout model**: marks render in up to 4 corner zones + one full-bleed ribbon, all
`position: absolute`. Which corner scores/watchlist/watched land in is settings-driven
via `bpCardZones()`: `scores` = `"topEnd"` if `settings.badgePlacement==="top"` else
`"bottomEnd"`; `watchlist` = directly `settings.watchlistBadge`; `watched` = whichever
of topEnd/bottomEnd scores did *not* take.

### 7.1 Top-start identity badge (one chip, mutually exclusive priority chain)

Gated by `marks = settings.showCardBadges`; if off, none of 7.1a–7.1f render (only the
topStart watchlist bookmark can still show). Priority order (first match wins):

- **7.1a Anime award** — `isAnime && bpAnimeAward(meta)` (id matches
  `/^(kitsu|mal|anilist|anidb|simkl):/`). `bpAnimeAward` → `findTopAward(meta.name,
  parseAwardYear(meta.releaseInfo), meta.id)` (`lib/anime-awards.ts:274-281`). Label:
  `` `${animeWin.year} ${bpAwardShortLabel(animeWin, t)}` `` (e.g. "2023 Winner");
  short labels from `CR_CATEGORY_SHORT` (`lib/anime-award-labels.ts`: "Winner",
  "Continuing", "New", "Film", "Original", "Animation", "Director", "Action",
  "Fantasy", "Isekai", "Drama", "Comedy", "Romance", "Slice", "Mystery", "Horror",
  "Sports", "Supernatural", "Sci-Fi", "BG Art", "Char Design", "Cinematography", "Art
  Direction", "Score", "Song", "Opening", "Ending", "Boy", "Girl", "Hero", "Villain",
  "Main Char", "Supporting", "Couple", "Fight", "Bromance", "GL", + more). Text-only
  (no icon/PNG on browse cards).
- **7.1b Classic award** — `!isAnime`, bundled-award match only (no live Wikidata
  lookup on browse cards). Label via `bpClassicAwardLabel(type, wins, t)`: body noun if
  `wins <= 1` ("Oscar", "Emmy", "Globe", "BAFTA", "SAG", "Critics", "Cannes", "Venice",
  "Berlin", "Annie", "Spirit", "Saturn", "Cesar", "Goya", "Blue Dragon", "Baeksang",
  "BIFA", "Award" for other), else `"{n} {award}s"`.
- **7.1c Dub** — `settings.showDubBadge && isAnime && animeHasDub(metaId)`. Label:
  literal `"DUB"`.
- **7.1d New** — `!cinema && meta.releaseInfo === String(currentYear)`. Label: literal
  `"New"`.
- **7.1e Rerun** — in cinema (`meta.type==="movie" && meta.inTheaters===true`) AND
  `releaseDate` >9 months ago (`(Date.now()-released)/(1000*60*60*24*30.44) > 9`).
  Label: `` `${t("Rerun")}${releaseInfo ? " · " + releaseInfo : ""}` `` e.g. "Rerun ·
  2015".
- **7.1f In Cinema** — in cinema, not a rerun. Label: literal `"In Cinema"`.

Chip style constant `BP_MARK_CHIP`: filled `bg-[var(--color-ink)]` rounded-sm pill,
uppercase bold text in `--color-canvas`.

### 7.2 Watchlist bookmark

Lucide `Bookmark` icon, filled, inside a circular dark-translucent plate
(`BpStateCircle`), `aria-label`/`title` = `"In watchlist"`.
- **Top-start position**: `wantBookmark = settings.watchlistBadge === "topStart"`;
  renders inside `BpCardMarks`'s own span, can appear even if `showCardBadges` is off.
- **topEnd/bottomEnd/bottomStart**: computed in `useBpCardState` via
  `useInWatchlist(meta.id, [imdbId])`, gated `zones.watchlist !== "off" &&
  !== "topStart"`.
- Setting: `settings.watchlistBadge: "off" | "topStart" | "topEnd" | "bottomEnd" |
  "bottomStart"`.

### 7.3 Watched checkmark

Lucide `Check` icon, same circular plate, `aria-label` = `"Watched"`. Condition:
`useMetaWatched(showWatchedBadge ? meta.id : undefined, meta.type, imdbId)` — true if
the meta id is in the watched-flag `localStorage` set, or (movies only)
`isMovieWatchedLocal()`. Position: whichever corner scores did **not** take.

### 7.4 Local-library ("on device") mark

Lucide `HardDrive` icon, same plate, `aria-label` = `"In your local library"`.
Condition: `useInLocalLibrary(showLocalLibraryBadge ? meta.id : undefined, altIds)`.
Position: **fixed bottom-start only** — not configurable via a zone setting.

### 7.5 Top 10 ribbon

Image asset `/toptabl.png` or `/toptabr.png` (mirrored variants), `w-[27%] min-w-
[34px] max-w-[72px]`, `z-20`, flush to the card's top edge, outside the corner-zone
flex columns (can't collide with other marks). Condition: `(isAndroidTv() ||
settings.top10Ribbon) && isTop10(meta.id, meta.name)` — forced on for Android TV
regardless of the setting (desktop's toggle defaults off and TV has no UI path to it).
`isTop10()` checks a module-level id/normalized-name set populated externally via
`setTop10Metas()`. Position: left/right per `settings.top10RibbonSide`. A prior numeric
"position pill" no longer exists — this is purely the ribbon image now.

### 7.6 Score/rating chips

Row of up to 2 (poster shape) or 3 (wide shape) chips (`bpScoreLimit`), in whichever
corner `zones.scores` resolves to. Each independently gated by a `showXBadge` setting,
only fetched when the card is viewport-visible, never rendered on `surface==="tile"`
(dense rows get no score badges at all):

| Kind | Setting gate | Icon | Value format |
|---|---|---|---|
| IMDb | `showImdbBadge` | `ImdbIcon` | resolved via harborRating → OMDb → Cinemeta rating → `meta.imdbRating` fallback chain |
| MAL | `showMalBadge` | `MalLogo` | anime only; `meta.imdbRating` field repurposed for anime score |
| TMDB | `showTmdbBadge` | `tmdbLogo` PNG | non-anime only, `useTmdbVote` |
| Simkl | `showSimklBadge` | `simklLogo` PNG | `Math.round(value)` |
| Rotten Tomatoes critics | `showRtBadge` | `RtBadge` | `${Math.round(value)}%` |
| RT Audience ("Popcorn") | `showPopcornBadge` | lucide `Popcorn` | `${Math.round(value)}%` |
| Metacritic | `showMetacriticBadge` | plain text `"MC"` (no logo ships) | `Math.round(value)` |
| Letterboxd | `showLetterboxdBadge` | `letterboxdLogo` PNG | `(value/2).toFixed(1)` (10-scale → 5-scale) |
| MDBList | `showMdblistBadge` | `mdblistLogo` PNG | `Math.round(value)` |
| Trakt | `showTraktBadge` | `traktLogo` SVG | `${Math.round(value)}%` |

An anime title's IMDb+MAL never appear paired on a browse card — pairing
(`gate.pairAnimeImdb`) is only enabled on the `"detail"` surface, not `"card"`.

**Not found** in this chain (checked, absent): a "coming soon"/unreleased marker, an
addon-source badge, an HDR/4K quality badge, a community badge pack (`lib/harbor-
rank.ts` and `lib/community-badge-packs.ts` exist elsewhere but are not wired into
these three files), or a continue-watching progress bar (that lives only on `BpCwCard`,
§1.4, not on generic browse cards).

---

## 8. CORE TYPES (verbatim)

**`Meta`** — `src/lib/cinemeta.ts:6,14-56`:
```ts
export type MetaType = "movie" | "series" | "channel" | "tv" | "anime" | "other" | "manga";

export type AddonOrigin = { id: string; name: string; logo?: string; base?: string };

export type Meta = {
  id: string;
  type: MetaType;
  name: string;
  poster?: string;
  background?: string;
  logo?: string;
  description?: string;
  originalLanguage?: string;
  country?: string;
  malId?: number;
  animeFormat?: string;
  releaseInfo?: string;
  releaseDate?: string;
  inTheaters?: boolean;
  imdbRating?: string;
  adult?: boolean;
  providerBadge?: { name: string; logo: string; tint: string };
  sourceRank?: number;
  tmdbScore?: number;
  runtime?: string;
  genres?: string[];
  trailers?: Array<{ source: string; type?: string }>;
  trailerStreams?: Array<{ ytId?: string; title?: string }>;
  links?: Array<{ name: string; category: string; url: string }>;
  addonOrigin?: AddonOrigin;
  isCollection?: boolean;
  behaviorHints?: { defaultVideoId?: string | null };
  videos?: Array<{
    id?: string;
    season?: number;
    episode?: number;
    number?: number;
    released?: string;
    firstAired?: string;
    name?: string;
    title?: string;
    overview?: string;
    description?: string;
    thumbnail?: string;
    streams?: Array<Record<string, unknown>>;
  }>;
};
```

**`LibraryItem`** — `src/lib/stremio.ts:16,18-35`:
```ts
export type ExternalCwSource = "simkl" | "trakt";

export type LibraryItem = {
  _id: string;
  type: string;
  name: string;
  poster?: string;
  background?: string;
  state?: {
    timeOffset: number;
    duration: number;
    season?: number;
    episode?: number;
    timeWatched?: number;
    flaggedWatched?: number;
    timesWatched?: number;
    watched?: string;
    video_id?: string;
    lastWatched?: string;
  };
  removed: boolean;
  temp: boolean;
  _ctime: string;
  _mtime: string;
  external?: ExternalCwSource;
  isAnime?: boolean;
  upNext?: boolean;
  local?: boolean;
  manualWatched?: boolean;
};
```

**`AddonRow`** — `src/lib/addons.ts:61-74`:
```ts
export type CatalogExtra = { name: string; value: string };

export type AddonCatalogCursor = {
  base: string;
  type: string;
  id: string;
  extras?: CatalogExtra[];
};

export type AddonRow = {
  key: string;
  type: string;
  name: string;
  metas: Meta[];
  more?: AddonCatalogCursor;
};
```

**`CatalogRow`** — `src/components/catalog/catalog-rows.tsx:21-27`:
```ts
export type CatalogRow = {
  key: string;
  title: string;
  metas: Meta[];
  fetcher?: (page: number) => Promise<Meta[]>;
  hasMore?: boolean;
  variant?: "rank";
};
```

**`Stream`** — `src/lib/streams/types.ts:38-83`:
```ts
export type StreamSubtitle = {
  id?: string;
  url: string;
  lang?: string;
  m?: string;
};

export type Stream = {
  name?: string;
  title?: string;
  description?: string;
  infoHash?: string;
  fileIdx?: number;
  fileMustInclude?: string;
  url?: string;
  ytId?: string;
  externalUrl?: string;
  nzbUrl?: string;
  servers?: string[];
  rarUrls?: string[];
  zipUrls?: string[];
  tarUrls?: string[];
  tgzUrls?: string[];
  sevenZipUrls?: string[];
  subtitles?: StreamSubtitle[];
  behaviorHints?: {
    bingeGroup?: string;
    videoHash?: string;
    videoSize?: number;
    filename?: string;
    fileName?: string;
    countryWhitelist?: string[];
    notWebReady?: boolean;
    proxyHeaders?: ProxyHeaders;
    headers?: Record<string, string>;
  } & Record<string, unknown>;
  sources?: string[];
  availability?: number;
  liveStreamCheck?: boolean;
  addonId: string;
  addonName: string;
  addonUrl?: string;
  addonRanked?: boolean;
  addonPriority?: number;
  addonReturnIdx?: number;
  contributors?: Array<{ id: string; name: string }>;
};
```

**`SourceRow`** (custom Home rows, `homeRows.customSources`) —
`src/lib/custom-sources.ts:1-38`. Nested shape: `SourceRow { id, title,
backdropImageUrl?, pinToTop?, focusGlowEnabled?, viewMode?, showAllTab?, folders:
SourceFolder[] }`; `SourceFolder { id, title, coverImageUrl, focusGifUrl, coverEmoji?,
tileShape: "LANDSCAPE"|"POSTER", hideTitle?, catalogSources?: CatalogSource[],
sources?: NativeSource[] }`; `CatalogSource { addonId, type, catalogId }`;
`NativeSource { title, sortBy?, filters?, provider, mediaType, tmdbSourceType?,
tmdbId?, traktListId? }`. See file for exact field types.

**`Affinity` / `DiscoverStore`** (Discover taste profile) — `src/lib/discover/types.ts`.
`EventKind = "open"|"dwell"|"play"|"watchlist"|"watched"|"vote_up"|"vote_down"`.
`Affinity { cast, directors, creators: Record<number,number>; genres, decades,
languages: Record<string,number>; keywords: Record<number,number>; totalEvents,
lastUpdated: number }`. `DiscoverStore { events: DiscoverEvent[]; affinity: Affinity }`,
`DiscoverEvent { id, kind: EventKind, ts, meta?: ProfileSnapshot }`. See §2.2 for how
this feeds scoring.

---

## 9. SETTINGS KEYS

Storage mechanics (which localStorage key holds the `Settings` blob per profile) are
already documented in `docs/harbor-protocol.md` §6 — `harbor.settings` (legacy) /
`harbor.settings.shared` / `harbor.settings.<profileId>`, `settings/profile-store.ts:
5-9`. `STORAGE_KEY = "harbor.settings"` (`settings/defaults.ts:9`). This section lists
only the specific `Settings` keys (`settings/types.ts`) these six rooms read, with
their default values from `settings/defaults.ts`.

| Key | Type | Default | Read by |
|---|---|---|---|
| `tmdbKey` | `string` | `""` | Home, Discover, Movies, Shows, Search, Collections, all TMDB providers |
| `omdbKey` | `string` | `""` | OMDb provider (§6.6) |
| `rpdbKey` | `string` | `""` | RPDB (§6.5, not wired into TV rooms) |
| `fanartKey` | `string` | `""` | Fanart.tv (§6.4, not wired into TV rooms) |
| `region` | `string` | `"US"` | TMDB region param (movie/service rows, network rows) |
| `preferredLanguages` | `string[]` | `["English"]` | Discover locale-penalty scoring (§2.2) |
| `requirePreferredLanguage` | `boolean` | `false` | — |
| `homeMode` | `"harbor"\|"classic"` | `"harbor"` | Home catalog engine (§1.2) |
| `homeShowAllAddonRows` | `boolean` | `false` | Home addon-row dedup |
| `homeNewEpisodes` | `boolean` | `false` | declared, not found wired (§1.5) |
| `homeRows` (`order/hidden/renamed/numerals/heroSource/customSources/listRows/playButtonSquare/secondaryMoreInfo/cwTop`) | object | all empty/false/null | Home row customization (§1.1, §1.5) |
| `streaming` | `Record<Service,boolean>` | netflix/disney/hulu/prime/apple/max/paramount/peacock/crunchyroll/amcplus/starz/shudder `true`; tubi/plutotv/roku `false` | Home Services row |
| `cwSources` | `{library,trakt,simkl,local}` | `{true,false,false,true}` | Continue Watching merge (§1.4) |
| `cwPerProfile` | `boolean` | `false` | CW hidden when another profile shares login |
| `cinemetaEnabled` | `boolean` | `true` | Cinemeta fallback toggle |
| `preferCustomMetaAddon` | `boolean` | `false` | Art-hydration provider race order (§6.11) |
| `animeOnlyInAnimeRoom` | `boolean` | `true` | — |
| `cardBadgeLimit` | `number` | `3` | Score-chip row cap upstream of `bpScoreLimit` |
| `showCardBadges` | `boolean` | `true` | Gates all of §7.1 |
| `badgePlacement` | `"top"\|...` | (not read in this pass) | Which corner scores/watched land in (§7) |
| `watchlistBadge` | `"off"\|"topStart"\|"topEnd"\|"bottomEnd"\|"bottomStart"` | (not read in this pass) | §7.2 |
| `showWatchedBadge` | `boolean` | (not read in this pass) | §7.3 |
| `showLocalLibraryBadge` | `boolean` | (not read in this pass) | §7.4 |
| `top10Ribbon` | `boolean` | `false` | §7.5 (forced on for Android TV regardless) |
| `top10RibbonSide` | `"left"\|"right"` | (not read in this pass) | §7.5 |
| `showImdbBadge` / `showMalBadge` / `showTmdbBadge` / `showSimklBadge` / `showRtBadge` / `showPopcornBadge` / `showMetacriticBadge` / `showLetterboxdBadge` / `showMdblistBadge` / `showTraktBadge` | `boolean` each | see `settings/types.ts:105-135` | §7.6 per-provider score-chip gates |
| `showDubBadge` | `boolean` | (not read in this pass) | §7.1c |
| `awardTabs` | `boolean` | `false` | — |
| `aiWebSearch` | `boolean` | (not read in this pass) | AI search web grounding (§4.4, desktop-only) |
| `translateTitles` | `boolean` | (not read in this pass) | TMDB `search/multi` language param (§4.1a) |
| `mangaEnabled` | `boolean` | (not read in this pass) | Search manga provider gate (§4.1f) |
| `hideContent.manga` / `hideContent.anime` | `boolean` | (not read in this pass) | Search/Home content gating |

Default values marked "(not read in this pass)" were declared in `settings/types.ts`
but their `settings/defaults.ts` line wasn't captured by the research pass that covered
that room — cite `settings/defaults.ts` directly rather than guess if exact defaults
are needed for those keys.

---
