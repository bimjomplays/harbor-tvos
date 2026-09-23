# Harbor "Big Picture" — Detail Page & Stream Picker Spec (Stage 3)

All citations relative to `reference/harbor` repo root unless noted. Does not repeat
`docs/big-picture-design.md` (tokens, §8.1 hero action-button anatomy/dimensions),
`docs/browse-spec.md` (`Meta`, `LibraryItem` types §8, TMDB/Cinemeta providers §6,
Settings storage mechanics §9), or `docs/engine-report.md` (what already runs in the JS
engine). Where the task's file list named a path under `detail/` or
`big-picture/play-picker/` that does not exist, the real path is given instead — noted
inline the first time.

Path correction up front: `bp-facts.tsx`, `bp-cast-row.tsx`, `bp-gallery-row.tsx`,
`bp-collaborators.tsx`, `bp-episodes.tsx`, `bp-episode-window.tsx`, `bp-episode-still.tsx`,
`bp-episode-ids.ts`, `use-bp-enrich.ts`, `use-bp-episode-art.ts`, `bp-detail-actions.tsx`,
`bp-detail.tsx`, `use-bp-detail.ts`, `use-bp-detail-actions.ts` all live directly under
`src/views/big-picture/`, not under `detail/`. `src/views/big-picture/play-picker/` does
not exist; the TV stream-picker files (`bp-streams.tsx`, `bp-stream-row.tsx`,
`bp-stream-filters.ts`, `bp-stream-chips.tsx`, `bp-stream-menu.tsx`,
`bp-stream-dialogs.tsx`, `bp-stream-steps.tsx`, `use-bp-streams.ts`,
`use-bp-stream-play.ts`) are directly under `src/views/big-picture/`. `src/views/play-picker/`
is a separate, desktop-and-TV-shared logic layer (`use-pick-handler.ts`,
`use-pipeline-result.ts`, `use-auto-candidates.ts`, `use-auto-fire.ts`, `use-stream-ids.ts`,
`picker-utils.ts`, `stream-facets.ts`) that both `bp-streams.tsx` (TV) and the desktop
`stremio-layout.tsx` import; it is not itself a TV view.

---

## 1. DETAIL PAGE

### 1.1 Layout, top to bottom

`BpDetail` (`bp-detail.tsx:52-386`) renders one scrollable column
(`data-bp-scroll-y`, `:310-343`):

1. **`BpDetailHero`** (`detail/bp-detail-hero.tsx:18-132`) — backdrop is painted by the
   page-level ambient layer, not this component. Inside the hero, top to bottom:
   logo-or-title (`:63-74`), tagline if `detail.tagline` (`:76-83`), meta/facts row —
   `BpScoreChips` + `bpFacts(meta, detail)` strings + `BpHeroMarks` (library/media-server/
   addon-origin marks) (`:85-99`), `BpDetailActions` (Play + secondary icons + trailing
   synopsis toggle) (`:101-119`), `BpSynopsis` (`:121`), `BpTmdbKeyNote` if no TMDB key
   (`:122`), `MetaAwardsCorner` absolutely positioned (`:124-129`). Action-button pixel
   anatomy is in `docs/big-picture-design.md` §8.1 — not repeated here.
2. Below the hero, a single `flex flex-col gap-[var(--bp-row-gap)]` column
   (`bp-detail.tsx:330-339`) of rail rows, **in this literal array order**
   (`:253-304`; each entry keeps its `data-bp-rail-row` index even when it renders
   `null`, so vertical D-pad ranking depends on this exact order never changing):
   1. `episode-filters` — `BpAnimeSeasonChips` (anime) or `BpEpisodeSeasonChips` (season
      trigger chip, only if the show has >1 season) — series/anime only.
   2. `episodes` — `BpAnimeEpisodeStrip` or `BpEpisodeStrip`.
   3. `watch-on` — `BpWatchOnRow` (TMDB watch-provider marks, non-focusable).
   4. `crew` — `BpCrewRow` (Director/Creator/Writer/Producers/Cinematography/Music/Editor
      credit cells, no artwork).
   5. `cast` — `BpCastRow` (up to 20).
   6. `characters` — `BpAnimeCharactersRow` (anime only).
   7. `collection` — franchise `BpRow` if TMDB returned ≥2 collection parts.
   8. `recommendations` — `BpRow` titled `"More Like This"`.
   9. `similar` — `BpRow` titled `"You Might Also Like"`.
   10. `videos` — `BpVideosRow` (trailers/clips, up to 14).
   11. `awards` — `BpAwardsRow`.
   12. `facts` — `BpFacts` (3-row preview card opening `BpFactsDialog`).
   13. `backdrops` gallery, `posters` gallery, `logos` gallery (`BpGalleryRow`, shapes
       `"wide"`/`"tall"`/`"logo"`) — **artwork rows are deliberately last**
       (`bp-detail.tsx:298-300` comment: awards/facts answer "is this worth my time" and
       "who made it" before wallpaper).

   **Correction to the task's file list**: `bp-collaborators.tsx` (`BpCollaboratorRow`,
   "Frequent Collaborators") is **not** rendered on the detail page. It is wired only into
   the **Person** page (`bp-person.tsx:18,213`: `rows.push({ key: "collaborators",
   node: <BpCollaboratorRow people={collaborators} /> })`). There is no collaborators row
   on `BpDetail`.

### 1.2 Data loading — `useBpDetail` (`use-bp-detail.ts:25-98`)

Three sources race/chain, in this order:
1. **Seed**: `readBpMeta()` (`bp-focus-meta.ts`, a value the Home/Discover spotlight
   already locked in on dwell) seeds `meta` synchronously if its id matches (`:29-30,47-49`).
2. **`peekBpEnrich(id)`** (`use-bp-enrich.ts:23-25`) seeds `detail` synchronously from a
   140ms-dwell TMDB prefetch cache the spotlight already ran, so the page can open with
   cast/rating/tagline already present (comment `use-bp-detail.ts:31-34`).
3. On mount / metaId change, two calls run **in parallel**, each committing independently
   as it resolves (`:51-60`):
   - `resolveMeta(authKey, type, id)` (`@/lib/meta-resource`) → full `Meta` incl. `videos`
     (episode list) via an addon-meta race, falling back to Cinemeta.
   - `tmdbDetails(settings.tmdbKey, start)` → `TmdbDetail` (cast, crew, facts, gallery,
     recommendations, similar, collection ref).
   Both are awaited together only to flip `loading = false` (`:60-62`); the UI updates as
   each one lands individually via its own `.then()` (`:54-59`).
4. `TmdbDetail.recommendations`/`.similar`/collection are **not** the addon-race result —
   they come only from `tmdbDetails`. If a series' `full.videos` came back empty and TMDB
   gave an `imdbId`, a **second** `resolveMeta` call is made via the imdb id specifically
   to backfill episodes (`:75-83`, "episode backfill" comment `:65-66`).
5. Watch providers (`tmdbWatchProviders`) load **after** `loading` flips false, using the
   TMDB numeric id from `rich`/`detail`, never awaited into the loading gate — "art beats
   text on arrival and a provider list must not sit in front of the episode backfill"
   (`:64-73`).
6. Franchise collection (`tmdbCollection`) loads last, gated on `rich.collection.id`, and
   is dropped if it resolves to <2 parts (`:85-89`).
7. **Anime is a parallel, separate data path**: `useBpAnimeDetail(meta)`
   (`bp-detail.tsx:71`) supplies its own `detail`/`resume`/`owns` for kitsu/mal-rooted
   titles (a kitsu id "resolves to nothing on TMDB" — comment `:69-70`); when
   `anime.owns` is true the TMDB `detail` is fully replaced: `const detail = anime.detail
   ?? tmdbDetail` (`:77`).
8. Episode-id index: `useBpEpisodeIds(anime.owns ? null : meta)` (`:76`, from
   `bp-episode-ids.ts`) — see §1.5.

### 1.3 Action buttons

Button set built by `useBpDetailActions` (`use-bp-detail-actions.ts:48-231`), each entry
`{ key, label, icon, logo?, filled?, active?, badge?, onPress }`
(`BpDetailAction`, `:37-46`). Order pushed, and the exact gating condition, verbatim
labels via `t(...)`:

| # | key | condition | label(s) |
|---|---|---|---|
| 1 | `sources` | `isMovie && settings.instantPlay` (`:84-91`) | `"Sources"` |
| 2 | `watchlist` | always | `"In Watchlist"` / `"Add to Watchlist"` |
| 3 | one per tracker | `trackers.length` (Trakt/Simkl/AniList/MAL — `useBpTrackers`) | `"{name} · {status}"` or `"Add to {name}"` |
| 4 | `trakt` | `isMovie && trakt.isConnected && trakt.resolveTarget(meta.id)?.kind === "movie"` | `"Mark watched on Trakt"` |
| 5 | `favorite` | always | `"Favorited"` / `"Add to favorites"` |
| 6 | `reminder` | `isSeries` | `"Reminder on"` / `"Remind me"` |
| 7 | `rate` | always | `"Your rating {n}/10"` / `"Rate this"` |
| 8 | `lists` | always | `"Add to list"` |
| 9 | `watched` | `isMovie && settings.showWatchedButton` (default `true`) | `"Marked watched"` / `"Mark watched"` |
| 10 | `trailer` | `trailerYtId` truthy | `"Watch trailer"` |
| 11 | `download` | `isMovie` | `"Downloading {pct}% · cancel"` / `"Saved offline"` / `"Retry download"` / `"Download for offline"` |

Trailing cell (not in this array, appended by `BpDetailHero`/`BpDetailActions` itself,
`bp-detail-hero.tsx:107-117`): synopsis `"Read more"` / `"Show less"` toggle, shown only
when `useBpSynopsis` measures clamped overflow (`detail/bp-synopsis.tsx:24-48`).

**Play/Resume label logic** (`bp-detail-hero.tsx:51-59`, verbatim):
```ts
const playLabel =
  mark.resumed && mark.ep
    ? t("Resume S{s}:E{e}", {
        s: mark.ep.imdbSeason ?? mark.ep.season,
        e: mark.ep.imdbEpisode ?? mark.ep.episode,
      })
    : offset > 60000
      ? t("Resume")
      : t("Play");
```
`offset`/`duration` come from `cwEntry.state.timeOffset`/`.duration` (`:49-50`). The
progress bar under the Play button (`bp-detail-actions.tsx:123-129`) renders only when
`0.01 < progress < 0.97` where `progress = duration > 0 ? offset / duration : 0`
(`bp-detail-hero.tsx:106`).

### 1.4 Play decision logic (`bp-detail.tsx:96-101,140-159`)

`mark` = the resume target used by both the Play button and the parked episode-strip
position:
```ts
const videoMark = isSeries ? bpResumeMark(meta, cwEntry, episodeIds) : { resumed: false };
const mark = isSeries && anime.resume ? anime.resume : videoMark;
```
`bpResumeMark` (`detail/bp-resume-mark.ts:8-33`): filters `meta.videos` to entries with
`season>0 && episode>0`, sorts by (season, episode). If a `LibraryItem` (`cwEntry`) is
present, it parses `entry.state.season/episode` (or `episodeFromVideoId(state.video_id)`
if `episode` is 0) and looks for a matching video — a hit returns
`{ ep: bpPlayEpisode(hit, ids), resumed: true }`. No entry/no match falls back to
**the first sorted episode**, `{ ep: bpPlayEpisode(sorted[0], ids), resumed: false }` —
i.e. Play always has a target once any episode exists.

`play(episode?, fromStrip=false, knownResumeTarget=false)` (`bp-detail.tsx:140-159`):
```ts
const ep = episode ?? mark.ep ?? (isSeries ? bpEpisodeAt(1, 1, episodeIds) : undefined);
const onResumeTarget =
  knownResumeTarget || !ep || !mark.ep ||
  (ep.season === mark.ep.season && ep.episode === mark.ep.episode);
const auto =
  settings.playbackSourcePreference === "online" &&
  (settings.instantPlay || (fromStrip && settings.seasonSourceLock));
onSources(meta, ep, onResumeTarget, auto, /* applyPreference */ true);
```
So: **movie** → `ep` is `undefined`, `onSources` opens the picker for the movie itself.
**Series with no resolvable episode** → synthetic `S1E1` via `bpEpisodeAt(1, 1,
episodeIds)` (which still patches in imdb/kitsu ids from the index so it maps onto a real
addon-servable episode). **Series with resume data** → `mark.ep`. `resume: onResumeTarget`
tells the picker whether this press landed on the *same* episode the CW entry already
names (only then is the "remembered stream" fast-path allowed to fire — see §2). `auto`
(auto-play-best) requires `playbackSourcePreference === "online"` AND either
`instantPlay` (default `true`) globally, or (episode-strip card press) `seasonSourceLock`
(default `false`).

Explicit **Sources** button / long-press bypasses all of this: it calls `onSources` with
`resume=false, auto=false, applyPreference=false` (`bp-detail.tsx:173-183` comment: "An
explicit Sources press is the user asking to choose, so it must not unlock the remembered-
stream fast path").

Resume also arrives from an **external play-request** (`bp-detail.tsx:197-214`,
`bp-play-request.ts`): if `bpPlayPending(metaId)` (e.g. a quick-panel "Play" fired before
the detail page mounted), it waits — 500ms if series with no `cwEntry`/no hinted resume
yet, else immediate — then calls `play(bpEpisodeAt(at.season, at.episode, episodeIds),
false, true)` if the intent named an episode, or bare `play()` otherwise.

`onSources` itself is `BpDetail`'s own prop, supplied by the caller (`bp-tv-app.tsx`-level
router) — it is what opens `BpStreams` (§2).

### 1.5 Episodes / season UI

**Episode-id index** — `bp-episode-ids.ts` (`useBpEpisodeIds`, `:115-150`): for a non-anime
title with a kitsu-addon-served stream id embedded in any `meta.videos[].id`
(`bpEpisodeIdSource`, `:25-33`), fetches `fetchEpisodeList` (`@/lib/series-episodes`) and
builds a `Map` keyed `vid:{kitsuStreamId}`, `vid:{videoId}`, `se:{season}:{episode}`,
`abs:{absoluteNumber}` (`indexEpisodes`, `:40-49`) — an LRU cache of 40 series
(`indexCache`). `bpPlayEpisode(v, ids)`/`bpEpisodeAt(s, e, ids)` (`:96-113`) build a
`PlayEpisode` and patch in `kitsuStreamId`/`imdbId`/`imdbSeason`/`imdbEpisode`/
`absoluteNumber`/`tvdbEpisodeId` from a lookup that tries `vid:`, then `se:`, then `abs:`
keys in that order (`bpLookupEpisode`, `:58-72`) — **never look up by imdb pair**, only by
the meta's own source season/episode (comment `:54-57`).

**Season chips** (`BpEpisodeSeasonChips`, `bp-episodes.tsx:89-127`) — only rendered if
`state.seasons.length > 1`; a single pill button `"Season {n}"` + `"{n} episodes"` count
that opens `BpSeasonMenu` (a dialog), not an inline picker.

**Episode strip** (`BpEpisodeStrip`, `:131-180`) driven by `useBpEpisodeStrip`
(`detail/use-bp-episode-strip.ts:74-202`):
- Groups `meta.videos` by **mapped imdb season** (`v.imdbSeason ?? season`, not the raw
  kitsu/source season) so a two-cour anime title doesn't collapse into one strip
  (`collect`, `:43-64`, comment `:39-42`).
- **Windowing** (`useBpEpisodeWindow`, `bp-episode-window.tsx:19-47`): renders a sliding
  slice `[base, end)` of up to `total` episodes rather than the whole list — `end` starts
  at `BP_EPISODE_WINDOW = 60`, grows by `BP_EPISODE_GROW_STEP = 60` as focus/scroll nears
  the edge (`bp-episodes.tsx:152-155,172`), `base` follows focus with `KEEP_BACK = 60`
  kept behind it, snapped to 60-blocks (`BLOCK = 60`). A leading `BpEpisodeSpacer`
  (`bp-episode-window.tsx:53-64`) reserves the width of the un-rendered head so scroll
  position stays correct.
- **Resume park**: `resumeIndex` = index of the CW-matched episode in the active season's
  list, or `-1` (`rawResume`/`parkIndex`, `use-bp-episode-strip.ts:147-155`); the caller
  (`useBpParkedTrack`, `bp-episodes.tsx:37-83`) scrolls the track there on arrival (once
  per `stamp`, never moving focus itself — "Focus is never moved here").
- **Stills**: `useBpEpisodeArt` (`use-bp-episode-art.ts:139-296`) — a fallback ladder per
  episode built from, in priority order: TMDB season-episode still (if `tmdbKey`), a
  TVDB-order still (absolute-number-first for anime), a TVDB-proxy still, ani.zip art (by
  pair then by absolute number), the meta's own embedded `still`, then a metahub.space
  still URL (`out.set(ep.key, ladder([...], hd))`, `:279-291`). `BpEpisodeStill`
  (`bp-episode-still.tsx:80-134`) walks this chain on load error and falls back to a
  numbered plate (`BpEpisodeStillPlate`, `:48-73`) once exhausted.
- **Facts** (rating/runtime/name/overview/airDate): `useBpEpisodeFacts`
  (`detail/use-bp-episode-facts.ts:38-106`) merges TMDB season-episode data with
  `useBpEpisodeEnrich` (imdb rating via Harbor's own IMDb proxy, OMDb season ratings, TVDB
  episode data) — imdb rating wins over TMDB rating when present (`imdbVal ?? tmdbVal`,
  `:96`).
- **Episode card** (`detail/bp-episode-card.tsx:16-107`): still (16:9) with a centered
  Play glyph on focus, a watched checkmark badge, an `BpEpisodeRating` chip (imdb-or-tmdb,
  gated `settings.showEpisodeRating !== false`, default `true`), a bottom progress bar
  (same `0.01 < progress < 0.97` rule), tag = `"Episode {n}"` or, if the imdb mapping
  renumbered it, `"S{s} E{e}"` (`:37-41`), title, `"{aired} · {n} min"` facts line,
  2-line overview (gated `settings.showEpisodeDescription !== false`, default `true`).
- **Watched marks**: `state.watchedOf(ep)` = `isManuallyWatched(...) ||
  remoteWatchedKeys(live.id).has("{season}:{episode}")` (`use-bp-episode-strip.ts:194-196`).
- **Ordering options**: none found beyond the imdb-vs-source season/episode remap already
  described (no "sort by air date / absolute / production" control was found in this
  strip or its season menu).
- **"Unaired" handling**: **not found**. No code in `bp-episodes.tsx`,
  `bp-episode-window.tsx`, `bp-episode-still.tsx`, `bp-episode-card.tsx`, or
  `use-bp-episode-strip.ts` gates on air date being in the future — every entry in
  `meta.videos` is rendered and playable regardless of `airDate`/`released`. (Contrast:
  `bp-guide-block.tsx:25,109` has a `FUTURE` paint state, but that is the live TV guide,
  an unrelated page.)

### 1.6 Other rows (brief)

- **`BpFacts`** (`bp-facts.tsx:95-141`): a single focusable card previewing the first 3
  `bpFactRows` (Directed/Created/Written/Music/Cinematography by, Status, First/Last
  aired or Released, Length or Runtime, Network, Studio, Country, Language, Genres,
  Original title, Budget, Box office, Rating) with `"{n} more details"` / `"All details"`,
  opening `BpFactsDialog` (`detail/bp-facts-dialog.tsx`, not detailed further here).
- **`BpCastRow`** (`bp-cast-row.tsx:111-138`): up to 20 `detail.cast`; each card opens the
  Person page via `pushBigPicture({ kind: "person", ... })`, except anime cast cards
  (`anime=true`) which are non-navigable — TMDB person ids don't apply to AniList-sourced
  entries (comment `:102-106`).
- **`BpCrewRow`** (`detail/bp-crew-row.tsx:56-93`): typography-only cells (no plate),
  Director/Creator/Writer/Producers/Cinematography/Music/Editor, capped 2-4 each.
- **`BpAwardsRow`** (`detail/bp-awards-row.tsx:52-103`): merges live Wikidata awards with
  bundled awards (`mergeBundledAwards`); anime titles get no award groups
  (`isAnime` check, `:23,28`). Opens `BpAwardDetailDialog`.
- **`BpVideosRow`** (`detail/bp-videos-row.tsx:25-102`): trailers (skips index 0, already
  the hero's own trailer) + `extraVideos`, up to 14, YouTube thumbnail cards.
- **`BpWatchOnRow`** (`detail/bp-watch-on-row.tsx:9-41`): TMDB watch providers, explicitly
  non-focusable marks, not a picker.
- **`BpGalleryRow`** (`bp-gallery-row.tsx:134-191`): up to 24 images per shape, opens a
  full-screen `BpGalleryLightbox` with its own Left/Right/Escape handling.

---

## 2. STREAMS / PLAY PICKER

### 2.1 Sequence, Play press → playable URL

1. `BpDetail.play()` calls the router's `onSources(meta, episode, resume, auto,
   applyPreference)` (§1.4), which mounts `BpStreams` (`bp-streams.tsx:116-570`) in
   `mode="pick"`.
2. `useBpStreams({ meta, episode })` (`use-bp-streams.ts:86-351`) assembles everything the
   picker needs: resolves `imdbId` (`useImdbId`), builds `streamIds` (`useStreamIds` → §2.2),
   loads addons (`useAddons`), debrid clients (`useDebridClients`), then hands off to
   `usePipelineResult` (`src/views/play-picker/use-pipeline-result.ts:26-197`) which calls
   `runPipeline` (§2.3-2.4) inside a `useEffect` keyed on `streamIds`/`imdbId`/`addons`/
   `debrids`/`meta.id`/episode/season/`settings.preferredLanguages`/
   `settings.requirePreferredLanguage`/`strictMode`/`filterDisabled`/`animeTitles`/
   `refreshNonce` (`:153-171`) — a picker-config-hash cache (`getPickerCache`/
   `setPickerCache`, `lib/picker-cache.ts`) can short-circuit a repeat request entirely
   (`:78-93`).
3. `runPipeline` streams partial results back via `onProgress` (throttled to one emit per
   250ms, `pipeline.ts:153-165`) and a final `PipelineResult`; each partial/final result is
   stamped with `stampAddonOrder` and stored (`use-pipeline-result.ts:125-129,138-139`).
4. `useBpStreamPlay` (`use-bp-stream-play.ts:44-295`) wraps `usePickHandler` (§2.7),
   `useAutoCandidates`/`useAutoFire` (§2.6) to decide **if** auto-play should fire, and
   exposes `play(stream)` for a manual pick.
5. A pick (manual or auto) → `usePickHandler.onPlay` → `resolveAndOpen` → `resolveStream`
   (§2.7) → (if needed) `preflightCheck` (§2.7) → `openPlayer(src)` (native mpv handoff,
   out of scope) + `savePlayback`/`saveSeasonLock` (§5).

### 2.2 `StreamRequest` construction

`useStreamIds` (`src/views/play-picker/use-stream-ids.ts:6-44`) calls
`buildStreamIdsWithIdentity` (`@/lib/streams/anime-identity`, a wrapper around
`buildStreamIds` that also resolves anime identity ambiguity — not separately detailed
here); the core id-list logic is `buildStreamIds` (`src/lib/streams/stream-ids.ts:16-139`).
Key branches (verbatim ordering, first-pushed = first-tried since `addonSupportsStream`/
`pickIds` sort by scheme priority separately — see §2.3):
- `episode.videoId` first if present, else `defaultVideoId` for a movie/no-episode request.
- If not anime and the episode carries a resolved imdb season/episode
  (`episode.imdbSeason/imdbEpisode`), push `"{imdbId}:{imdbSeason}:{imdbEpisode}"`.
- Anime: push `episode.kitsuStreamId` if present; else, for a `kitsu:`/`mal:`/`anilist:`/
  `anidb:` meta id with an episode, push `"{scheme}:{entry}:{episode.episode}"` (source
  numbering) unless the season is unverified (`unverifiedAnimeSeasonId`, `:5-14`, only
  used for `imdbSeason >= 2` with no `kitsuStreamId` yet — season 2+ before the mapping is
  confirmed).
- Plain `tt`/`tmdb:`/other scheme ids get `"{id}:{season}:{episode}"` appended (movie: bare
  id). `tmdb:movie:123`/`tmdb:tv:123` also emit the **bare** `tmdb:123[:s:e]` form first,
  since some addons (AIOMetadata) index by the unscoped form.
- If a separate `imdbId` is known and not already used above, push it too (bare or scoped).
- Several anime-specific fallback pushes follow for split-franchise/cour-offset titles
  (entry-relative vs. provider-relative numbering disagreeing) — see `:85-134` for the
  four extra branch conditions (`courOffset`, `isSpecialWithImdb`, `synthSeason`, and the
  unconditional imdb-pair push at `:123-134` whenever imdb season/episode ≥1 are known for
  an anime episode not already covered).
- Finally the `unverifiedAnimeId` (if computed) is appended last, as the lowest-confidence
  fallback.

`buildEpisodePipelineInput` (`src/lib/streams/episode-pipeline-input.ts:50-176`) then
wraps these ids into `StreamRequest.context` (`imdbId, title, year, season, episode,
absoluteEpisode`) — used only by plugin/scraper addons (`plugins/types.ts`
`StreamRequestContext`), not the manifest-protocol ones. `requestType` is `meta.type` for
an addon-native meta (`isAddonNativeMeta`), else `"series"`/`"movie"` from whether an
`episode` was passed.

### 2.3 Which addons are queried

`fetchAddonStreams` (`src/lib/streams/addons.ts:47-174`), called from `runPipeline`
(`pipeline.ts:175-184`) with `input.addonTimeoutMs` = `clamp(8, settings.addonTimeoutSec ??
30, 120) * 1000` and `input.addonRanks` from `resolveAddonRanks(addons,
settings.streamPriority)`.
- `addonSupportsStream(addon, req)` / `pickId`/`pickIds` (`:176-236`) decide, per addon,
  which of `req.ids` it accepts, sorted by scheme priority `["kitsu","mal","anidb",
  "anilist","tt","tmdb"]` (`idPriority`, `:180-187`). If both an anime-scheme id and a
  `tt` id are accepted, normally only the anime id is queried (`pickIds`, `:229-235`) —
  **both** are queried only for a `tt{n}:0:{e}` special-episode id
  (`SPECIALS_SCOPED_TT_RX`).
- Plugin/scraper addons (`isPluginAddon`) run through `runPluginAddon` instead of an HTTP
  call (`:63-78`).
- Status-only addons (`isStatusOnlyAddon`) are skipped (`:80-83`).
- A `forcedAddonBases` id (the meta's own `addonOrigin`) overrides normal id matching for
  that specific addon base (`:84-88`, from `episode-pipeline-input.ts:74-75,142-143` —
  the addon that actually served this meta is always asked, using the meta's own id).
- Per-addon timeout: `TIMEOUT_MS_FAST = 8000` / `TIMEOUT_MS_SLOW = 22000`, escalated for
  known-slow addon name/id/url patterns (`mediafusion|comet|torrentio|knightcrawler|
  aiostreams|jackettio|torbox`, `addons.ts:12-31`), floored at `Math.max(base,
  ceilingMs)` where `ceilingMs` is the caller's `addonTimeoutMs`.
- Each addon's task settles **independently**; `onPartial`/`onProgress` fire as each one
  resolves (`:148-169`), which is what lets `runPipeline`'s `emitPartial` stream results
  into the UI before every addon has answered.
- Results are de-duped per addon (`dedupeStreams`, `:385-403`) then, in `pipeline.ts`,
  merged across library + addon streams by info-hash/url/name key (`mergeAndDedupe`,
  `pipeline.ts:366-397`), tracking `contributors` (which addons returned the same stream).

### 2.4 `runPipeline` — settings → `PipelineOptions`

`runPipeline(input: PipelineInput, signal, onProgress?, onAddonProgress?)`
(`src/lib/streams/pipeline.ts:117-342`). Stages: fetch library streams (debrid
`listLibrary`) + addon streams in parallel (`Promise.allSettled`, `:168-185`) → merge/dedupe
→ `parseStream` each → anime-episode filter (`applyAnimeEpisodeFilter`, `:72-90`, drops
streams whose parsed episode doesn't match `animeAbsoluteEpisode`/aliases) → debrid
`cacheCheck`+`listLibrary` cross-check to flag `.cached[slug]`/`.inLibrary[slug]`
(`:219-288`) → **either** a Rust core pipeline via Tauri `invoke("streams_run_pipeline",
...)` (`runCorePipeline`, `:344-364`, only when `"__TAURI_INTERNALS__" in window`) **or**
the JS fallback (`applyTrust` → `computeCorpusStats` → `scoreStream` each → `rankAndPick`)
→ `finalizeWithRescue` (rescues "early-leak" streams that were rejected as
`fresh-cinema-fake`/`new-release-stub` but are corroborated by ≥3 similar-size streams or
≥2 distinct release groups, `:20-70`) → `applyStreamPriority` (re-sorts by
`addonPriority` when `addonRanks` was supplied, `priority-partition.ts:9-53`).

`PipelineInput.trust`/`.score` are built in `buildEpisodePipelineInput`
(`episode-pipeline-input.ts:144-175`) directly from `Settings`:

| Settings key | Default | Feeds |
|---|---|---|
| `preferredLanguages` | `["English"]` | `trust.preferredLanguages`, `score.preferredLanguages` |
| `preferredAudioLangs` | `["English","Japanese"]` | `trust.preferredAudioLangs`, and (via `useBpStreamFilters`) the picker's language chip |
| `requirePreferredLanguage` | `false` | `trust.requirePreferredLanguage = strictMode && this` |
| `bandwidthMbps` | `0` | `score.bandwidthMbps` (only if `>0`) |
| `addonTimeoutSec` | `30` | `addonTimeoutMs = clamp(8,120,this)*1000` |
| `streamPriority` | `[]` | `addonRanks = resolveAddonRanks(addons, this)` |
| `streamSort` | `"addon"` | `score.respectAddonOrder = this === "addon"`; also the picker's own display sort (§2.5) |
| `playerEngine` | `"auto"` | `score.preferSingleAudioTrack = !isTauri \|\| this === "html5"` |
| `streamFilterLevel` | `"strict"` | drives `strictMode`/`filterDisabled` in `useBpStreams` (`"strict"`→strict, `"off"`→disabled) |

`strictMode` additionally sets `trust.allowSeasonPacks = !strict`,
`trust.allowSizeOutliers = !strict`; `filterDisabled` sets `trust.disabled =
filterDisabled || addonNative || embedded.length > 0` (an addon-native meta or a meta with
its own embedded `videos[].streams` skips trust filtering entirely).

`ScoreOptions` (verbatim, `src/lib/streams/scoring/scoring-types.ts:3-15`) — see §3.

### 2.5 Picker UI — grouping, not tiers

**Correction to the task's assumption**: the TV picker (`bp-streams.tsx`) does **not**
render tier headers/sections. `RankedPicker.byTier` (a `Partial<Record<Tier, ScoredStream>>`
best-per-tier map) exists in the type (§3) and is used by the desktop's
`tier-strip.tsx`/`primary-card.tsx`, but `BpStreams` renders one **flat, cached-first-
sorted, virtualized list** (`bp-streams.tsx:292-331,455-483`) of `BpStreamRow`s, windowed
60 at a time (`STREAM_PAGE = 60`, grown by an `IntersectionObserver` at a 2400px lead,
`:98-102,289-331` — a perf note at `:278-288` records a D-pad press blocking main thread
1.1-1.6s at 1017 sources before this windowing existed).

**Filter chips** (`BpStreamChips`, `bp-stream-chips.tsx:16-256`), left to right: Back,
divider, quality chips (`"All"`, `"4K UHD"`, `"1080p"`, `"720p"`, `"480p"`, `"SD"`,
`"Telecine"`, `"Telesync"`, `"CAM"` — `QUALITY_LABEL`, `quality.ts:26-35`) each with a
count, `"Cached"` toggle (only if any debrid configured), divider, addon-name chip
(opens a menu), one chip per active facet dimension (everything in `FACET_DIMS` except
`resolution`/`cached`, which the quality/cached chips already cover —
`bp-stream-filters.ts:39`), a preferred-language chip if any are hidden, a source-kind
chip (`"All sources"`/`"Local Library"`/`"Media servers"`/`"Direct/debrid only"`/`"P2P
only"`), a custom-filter chip, divider, sort toggle (`"Harbor pick"` / `"Addon order"` /
`"Addon order (locked)"` when any installed addon is itself ranked), `"Clear filters"` if
anything is active, `"Refresh"`.

**Default sort** (`useBpStreamFilters.streams`, `bp-stream-filters.ts:258-281`, only
applied when not in addon-order mode and no host-match ordering): 1) cached-first
(applied earlier, `:151`), then, within the filtered set: WatchHub-marked streams last,
`needsDownload` streams last, then by the addon's own install-order rank
(`addonRank.get(addonUrl)`), then instant-marker streams first. No resolution/score-based
secondary sort is applied at the UI layer — the *pipeline's* `scoreStream`/`rankAndPick`
already ordered `result.picker.all` before any of this runs.

**Per-stream badges** (`BpStreamRow`, `bp-stream-row.tsx:233-422`): addon logo (`AddonLogo`),
quality label chip (`"No Label"`/`"Unverified"`/`QUALITY_LABEL[qualityKey(stream)]`, gated
`settings.showQualityBadge`, default `true`), addon/contributor name, `HostMatchChip`
(Watch-Together same/close match), dub/sub pill (gated `settings.showDubBadge`, default
`true`), `FormatBadge`s from `streamBadges(stream)` (`@/components/format-badge.tsx` —
resolution/HDR/codec/source/remux/3D/IMAX badge glyphs, function at `:603+`, not
re-derived here), `RuleBadges` (custom-filter-rule hits), edition text (Director's Cut /
Open Matte / raw), `FlagStack` for up to 4 audio languages, headline title, a detail line
(`streamSummaryParts` + de-pictographed description lines, `detailLine`, `:90-100`), an
optional raw filename line (gated `settings.pickerShowFilename`, default `false`), a
`"Now playing"` / `"Played last"` pill, then one of: `"In {name}"` / `"Cached on {name}"` /
`"Cached"` (green check), `"External"`, `"P2P"`, or `"Cache"` (queue-to-debrid), then the
resolving spinner / download / external-link / Play action icon.

### 2.6 "Auto play best" behaviour

Gated by `autoActive` (`use-bp-stream-play.ts:100-106`): `!onPick && intent !==
"download" && (autoPlay && !isLiveLike || wasInvitedTo) && !autoCancelled &&
!autoExhausted && !roomGuestPick`. `autoPlay` itself is the caller's flag, set true when
`BpDetail.play()`'s `auto` computed value (§1.4) was true.

Candidate order — `useAutoCandidates` (`src/views/play-picker/use-auto-candidates.ts:65-213`)
sorts `filteredPicker.all` by, in order: Watch-Together host-match score (if in a room),
WatchHub-last, **instant-tier** (0 = cached+exact-episode, 1 = cached-but-pack/other, 2 =
not cached), name-known (title-token match against expected title, unless
`filterDisabled`), "(your media)" flagged streams first, season-pack preference
(`preferPacks` = `seasonLock`, otherwise packs sink), needs-download last, resolution
preference for kid profiles (`prefer1080`, 1080p>720p>480p>4K>SD), strong-addon
(MediaFusion/Comet) vs. Torrentio tie-break, preferred-language match, addon install rank,
instant-marker-in-title. `sourceEntry`/`previousPlayback` matches are pushed to the front
first when instantly playable and there's no host-match ordering (`:180-183`).

Firing — `useAutoFire` (`src/views/play-picker/use-auto-fire.ts`): waits on
`waitingForHostSource` (Watch-Together, 12s cap)/`waitingForPreferredSource` (10s cap)/
`protectingPreferredSource`, then either fires immediately if the top candidate is
**high-confidence** (`hasInstantMarker && isCached && langOk && episodeQualifies &&
!nameAbsent`, held for `HIGH_CONFIDENCE_GRACE_MS = 350`ms) on the very first attempt, or
waits for `autoSettleReady`. `autoSettleReady` flips true at the earliest of: the top
candidate is instantly playable and `AUTO_SETTLE_MS = 1500`ms (or `AUTO_SETTLE_PACK_MS =
4000`ms if the request is an episode with no cached exact match yet) have passed since
first result; 80% addon quorum (`QUORUM_RATIO`) reached and `1500`ms elapsed; or a hard
`QUORUM_CAP_MS = 10000`ms since pipeline start. The actual firing effect
(`:218-270`) then plays `autoCandidates[min(attempt + autoAttemptIdx, length-1)]` if it is
instantly playable (`isCached || url || (p2pAutoConsent && engineP2pEligible)`); otherwise,
if the pipeline is done, it gives up (`setAutoCancelled(true)`). On a failed resolve,
`usePickHandler.advanceAuto()` moves to the next candidate; exhausting the list sets
`autoExhausted` → `BpAutoExhaustedDialog`.

### 2.7 `resolveStream` → resolved URL, and `preflightCheck`

`resolveStream(stream, debrids, signal, userCommitted, forceP2p, hint, allowP2pFallback,
allowCompletedDownload)` (`src/lib/streams/resolve.ts:89-238`), tried in order:
1. A matching **completed local download** (`completedTorrentDownloadFor`) — instant,
   `via: "local-download"`.
2. `forceP2p` or a hosted-torrent-server URL eligible for the local engine
   (`engineP2pEligible`) → `tryTorrentEngine` (remote Stremio server if configured and
   reachable, else the local torrent engine) → `via: "p2p"`.
3. A direct `stream.url` (non-`"#"`): for an **automatic** (non-`userCommitted`) pick
   without an info-hash and no video-file extension, a HEAD-probe (`probeIsWebPage`)
   guards against opening a watch-**page**; a manual pick skips this and lets mpv try the
   URL directly (comment `:135-138`). `validateLink` (`:244-285`) rejects filesizes
   `<80MB` unless the expected size is also small, or `<40%` of the expected size for
   files `>100MB` — these become `"stub-or-error-video"`.
4. `stream.externalUrl`/`.ytId`/`.nzbUrl` → immediate typed failure codes (external-url-
   only/youtube-only/nzb-needs-external-player), no resolution attempted.
5. No `infoHash` → `"no-source"`.
6. No debrids configured → P2P fallback (unless `!allowP2pFallback`).
7. With debrids: sorted cached-provider-first (`sortDebridsForStream`). **Uncommitted**
   (automatic) picks require *some* debrid to already report the hash cached/in-library,
   else `"uncached-not-committed"` — this is what stops auto-play from silently kicking
   off a debrid download. Then, for an uncached, marker-tagged, P2P-eligible stream that
   *is* user-committed, P2P is tried first (`:196-206`) before the debrid loop.
8. Debrid loop: `getPreparedDebridLink` (a small pre-resolve cache, `debrid/
   playback-preparation.ts`) first, else `debrid.playableUrl(magnet, fileIdx, signal,
   hint)`; each failure is pushed to `tried[]` and the next debrid is attempted; a
   suspicious link (fails `validateLink`) invalidates the prepared-link cache entry and
   also moves on.
9. If every debrid failed and `!anyCached`, one last P2P attempt.

`shouldPreferP2pDownload` (`:240-242`) — true when a stream is P2P-flagged and engine-
eligible; used to route `intent === "download"` picks toward the torrent engine instead of
a debrid add.

`preflightCheck(url, signal)` (`src/lib/streams/preflight.ts:28-40,42-96`) — memoized
per-URL (`memo`/`inflight` maps). Skips entirely for HLS/DASH manifest URLs. Otherwise
does a `Range: bytes=0-1` GET with a `1200ms` timeout; a `404`/`410` or a body/`Content-
Range`/`Content-Length` under `MIN_REAL_SIZE_BYTES = 5MB` is flagged `reason: "stub"`. Only
run when `resolveStream`'s own `readiness.exactUrlValidated` wasn't already `true` and the
via isn't `p2p`/`direct`/`local-download`/download-intent (`use-pick-handler.ts:292-303`).
A `"stub"` result marks the stream dead (`markStreamDead`, 15-min TTL) and, if a P2P
fallback is possible, offers `BpP2pDialog` instead of erroring outright.

### 2.8 Debrid services — `playableUrl` per service

All implement `DebridStore` (§3). `magnetFromHash`/`hashFromMagnet`
(`debrid/types.ts:77-86`) normalize between a bare info-hash and a `magnet:` URI.

- **Real-Debrid** (`debrid/realdebrid.ts`, `BASE = "https://api.real-debrid.com/rest/1.0"`):
  `POST /torrents/addMagnet` → poll `GET /torrents/info/{id}` (`POLL_DELAY_MS=600`,
  `POLL_MAX_ATTEMPTS=18`) → on `waiting_files_selection`, `POST
  /torrents/selectFiles/{id}` with video-extension-filtered file ids (or the hinted
  `fileIdx`) → wait for `status === "downloaded"` → `POST /unrestrict/link`. A
  `downloading`/`queued` status deletes the torrent and returns `"not-cached"` (RD never
  parks an uncached add). `cacheCheck` is a no-op stub (`{ ok: true, data: {} }`,
  `:75-80` — RD dropped its public cache-check endpoint; caching is inferred only via
  `listLibrary`). Error mapping (`wrap`, `:203-240`): `401/403`→`unauthorized`/
  `not-premium` (by message match), `402`→`not-premium`, `429`→`rate-limited`,
  `509`→`traffic-limit`, `503/504`→`upstream-unavailable`.
- **AllDebrid** (`debrid/alldebrid.ts`, `BASE = "https://api.alldebrid.com/v4"`): `POST
  /magnet/upload` → poll `GET /magnet/status?id=` until `statusCode === READY_STATUS_CODE`
  → `pickAdLink` chooses a file link → `GET /link/unlock?link=` (handles a `delayed`
  response by polling further, `pollDelayed`). Reuses `TERMINAL_FAIL_STATUS`/status-code
  checks for hard failures; gives up as `"not-cached"` after `attempt >= 3` while still
  pending.
- **Premiumize** (`debrid/premiumize.ts`, `BASE = "https://www.premiumize.me/api"`):
  single-call `POST /transfer/directdl` (no add/poll cycle — PM resolves synchronously);
  empty `content[]` → `"not-cached"`. Picks a file (`pickPmFile`), prefers a transcoded
  `stream_link` when `transcode_status === "finished"`, else the raw `link`.
- **Debrid-Link** (`debrid/debridlink.ts`, `BASE = "https://debrid-link.com/api/v2"`):
  `POST /seedbox/add` (`async: true`) → poll `GET /seedbox/list?ids=` until `status === 6`
  or `downloadPercent === 100`; `status === 100` is a hard error, deletes via `DELETE
  /seedbox/{id}/remove`.
- **TorBox** (`debrid/torbox.ts`, `BASE = "https://api.torbox.app/v1/api"`): maintains an
  in-process `knownIds`/dedup cache — checks the account for an existing torrent with the
  same hash first (`findInAccount`) and reuses/cleans up duplicates before adding a new
  one via `POST /torrents/createtorrent`, so repeated plays of the same hash don't create
  redundant TorBox torrents.

`registry.ts:18-26` builds the active `DebridStore[]` from whichever of
`settings.rdKey/tbKey/adKey/pmKey/dlKey` are non-empty, in that fixed slug order
(`rd, tb, ad, pm, dl`).

### 2.9 Error strings

`translatePickerError` (`src/views/play-picker/picker-utils.ts:596-691`) — verbatim
strings for each `PlayErrorCode`: `"not-cached"` → *"This stream isn't cached on your
debrid yet. Try a different one from the list."*; `"still-downloading"` → *"Your debrid is
still adding this torrent. Give it 30-60s and hit Play again, or pick a cached source from
the list."*; `"timeout"` → *"Your debrid took too long to respond. Hit Play again, or try
another stream."*; `"stalled"` → *"Your debrid couldn't fetch this torrent (no seeders).
Pick a different source."*; `"stub-or-error-video"` → *"Your debrid served a
placeholder/error video instead of the real file. Pick another stream."*;
`"all-debrids-failed"` → *"None of your debrid services could deliver a working file. Pick
another stream."*; `"no-debrid-configured"` → *"Add a debrid provider in Settings
first."*; `"remote-server-unreachable-strict"` / `"remote-server-unreachable"`,
`"engine-no-peers"`, `"engine-not-ready"` → *"Harbor's peer-to-peer engine is warming up.
This clears on its own in a few seconds, then Play works."*; `"direct-torrent-disabled"`;
`"no-source"` → *"This stream has no playable source."*; `"addon-not-configured"`;
`"external-url-only"`; `"youtube-only"`; `"nzb-needs-external-player"`; `"unauthorized"` →
*"Your debrid key was rejected. Check it in Settings."*; `"not-premium"` → *"Your debrid
subscription has expired."*; `"rate-limited"`; `"traffic-limit"` → *"Real-Debrid is
refusing this download right now, ..."*; `"upstream-unavailable"`; `"aborted"` →
*"Cancelled."*; `"download-season-package-required"`/`"download-season-no-files"`/
`"download-season-partial"` (`"Queued {queued} of {total} episodes..."`);
`"stream-proxy-start-failed"`; `"debrid-source-not-ready"`; `"debrid-queue-unsupported"`.
Full list at `picker-utils.ts:600-690`. A pipeline-level failure (addon fetch/parse threw)
becomes `pipelineError()` → *"Couldn't load streams. Check your addons and connection."*
(`:573-576,586-589`).

---

## 3. Types (verbatim)

`StreamRequest` (`src/lib/streams/addons.ts:33-38`):
```ts
export type StreamRequest = {
  type: string;
  ids: string[];
  animeIdUnverified?: boolean;
  context?: StreamRequestContext;
};
```

`ParsedStream` / `ScoredStream` / `RankedPicker` / `Tier` (`src/lib/streams/types.ts`):
```ts
export type Resolution = "4K" | "1080p" | "720p" | "480p" | "SD";
export type HdrFormat = "HDR10" | "HDR10+" | "DV" | "DV+HDR10" | "HLG";
export type Codec = "HEVC" | "AVC" | "AV1" | "VP9" | "MPEG2" | "Other";
export type Tier = "4K_DV" | "4K_HDR" | "4K" | "1080p_HDR" | "1080p" | "720p" | "SD" | "ROUGH";
export type DebridSlug = "rd" | "tb" | "ad" | "pm" | "dl";

export type ParsedStream = Stream & {
  parsedTitle: string;
  episodeTitle: string | null;
  resolution: Resolution;
  hdrFormat: HdrFormat | null;
  codec: Codec;
  source: Source;
  audio: AudioInfo;
  audioLanguages: string[];
  size: number | null;
  seeders: number | null;
  cached: Partial<Record<DebridSlug, boolean>>;
  cacheVerified: Partial<Record<DebridSlug, boolean>>;
  inLibrary: Partial<Record<DebridSlug, boolean>>;
  container: Container | null;
  releaseGroup: string | null;
  releaseGroupNormalized: string | null;
  remux: boolean;
  edition: string | null;
  year: number | null;
  yearRange: [number, number] | null;
  season: number | null;
  episode: number | null;
  episodeEnd: number | null;
  seasonPack: boolean;
  discIndex: number | null;
  repackIteration: number;
  proper: boolean;
  hardcoded: boolean;
  animeHash: string | null;
  scamScore: number;
};

export type ScoreReason = { signal: string; delta: number };

export type ScoredStream = ParsedStream & {
  score: number;
  reasons: ScoreReason[];
  tier: Tier;
  nativeIdx?: number;
  nameAbsent?: boolean;
};

export type RankedPicker = {
  primary: ScoredStream | null;
  byTier: Partial<Record<Tier, ScoredStream>>;
  all: ScoredStream[];
};
```
(`Stream` itself, `AudioInfo`, `Container`, `Source` at `types.ts:15-92` — the raw
Stremio-addon-protocol stream shape, not reproduced here as it is standard-protocol.)

`Rejection` / `TrustOptions` (`src/lib/streams/trust.ts:5-27`):
```ts
export type TrustOptions = {
  kind?: "movie" | "series";
  expectedTitle?: string | null;
  expectedYear?: number | null;
  expectedSeason?: number | null;
  expectedEpisode?: number | null;
  releaseDate?: string | null;
  allowSeasonPacks?: boolean;
  allowCam?: boolean;
  allowSizeOutliers?: boolean;
  strict?: boolean;
  disabled?: boolean;
  preferredLanguages?: string[];
  preferredAudioLangs?: string[];
  requirePreferredLanguage?: boolean;
  isAnime?: boolean;
  expectedTitles?: string[] | null;
};

export type Rejection = { stream: ParsedStream; reason: string };
```

`ScoreOptions` (`src/lib/streams/scoring/scoring-types.ts:3-15`):
```ts
export type ScoreOptions = {
  activeDebrids: DebridSlug[];
  preferredLanguages?: string[];
  bandwidthMbps?: number;
  releaseDate?: string | null;
  mediaKind?: "movie" | "series";
  runtimeMinutes?: number;
  inTheaters?: boolean;
  preferSingleAudioTrack?: boolean;
  preferAddonId?: string;
  preferredReleaseGroup?: string;
  respectAddonOrder?: boolean;
};
```

`PipelineInput` / `PipelineResult` (`src/lib/streams/pipeline.ts:92-115`):
```ts
export type PipelineInput = {
  request: StreamRequest;
  query: LibraryQuery;
  addons: Addon[];
  debrids: DebridStore[];
  trust?: TrustOptions;
  score: ScoreOptions;
  isAnime?: boolean;
  animeAbsoluteEpisode?: number | null;
  animeEpisodeAliases?: Set<number> | null;
  presetStreams?: Stream[];
  addonTimeoutMs?: number;
  addonRanks?: AddonRankFn | null;
  forcedAddonBases?: Array<{ base: string; id: string }>;
};

export type DebridError = { slug: string; name: string; code: string };

export type PipelineResult = {
  picker: RankedPicker;
  rejected: Rejection[];
  raw: { addon: Stream[]; library: Stream[] };
  debridErrors?: DebridError[];
};
```
Call signature: `runPipeline(input: PipelineInput, signal: AbortSignal, onProgress?:
(partial: PipelineResult) => void, onAddonProgress?: (progress: AddonProgress) => void):
Promise<PipelineResult>` (`pipeline.ts:117-122`).

`PlayEpisode` (`src/lib/view.tsx:55-72`):
```ts
export type PlayEpisode = {
  season: number;
  episode: number;
  name?: string;
  imdbId?: string;
  imdbSeason?: number;
  imdbEpisode?: number;
  absoluteNumber?: number;
  tvdbEpisodeId?: number;
  kitsuStreamId?: string;
  sourceMetaId?: string;
  videoId?: string;
  still?: string;
  overview?: string;
  rating?: number;
  airDate?: string;
  runtime?: number;
};
```

`TmdbDetail` (`src/lib/providers/tmdb/tmdb-details.ts:64-118`) — full field list already
reproduced there; key fields for the detail page: `kind`, `id`, `imdbId`, `title`,
`tagline`, `overview`, `cast`/`crew`/`directors`/`writers`/`creators`/`producers`/
`composer`/`cinematography`/`editor`, `recommendations: Meta[]`, `similar: Meta[]`,
`collection?: { id, name }`, `gallery: GalleryImages`, `trailerYtId`, `trailerCandidates`,
`extraVideos`, `numberOfSeasons`/`numberOfEpisodes`, `firstAirDate`/`lastAirDate`/
`releaseDate`, `budget`/`revenue`. `Meta` and `LibraryItem` are in `docs/browse-spec.md`
§8 — not repeated.

`BpEpisodeStripState` (`src/views/big-picture/detail/use-bp-episode-strip.ts:15-37`):
```ts
export type BpEpisodeStripState = {
  seasons: number[];
  seasonCounts: ReadonlyMap<number, number>;
  active: number;
  onSeason: (season: number) => void;
  episodes: BpEp[];
  total: number;
  base: number;
  end: number;
  grow: (to: number) => void;
  anchor: (index: number) => void;
  resumeIndex: number;
  backdrop?: string;
  stillsOf: (ep: BpEp) => string[];
  factOf: (ep: BpEp) => BpEpisodeFact | undefined;
  watchedOf: (ep: BpEp) => boolean;
  progressOf: (ep: BpEp) => number;
};
```
`BpEp = PlayEpisode & { key: string; group: number; label: number }` (`:11`).

`BpDetailAction` (`src/views/big-picture/use-bp-detail-actions.ts:37-46`):
```ts
export type BpDetailAction = {
  key: string;
  label: string;
  icon: LucideIcon;
  logo?: string;
  filled?: boolean;
  active?: boolean;
  badge?: string;
  onPress: () => void;
};
```

`DebridStore` / `DirectLink` / `DebridResult` (`src/lib/debrid/types.ts:6-75`):
```ts
export type DebridResult<T> =
  | { ok: true; data: T }
  | { ok: false; code: string; status: number; raw?: unknown };

export type DirectLink = {
  url: string;
  fileIdx?: number | null;
  filename?: string;
  filesize?: number;
  headers?: Record<string, string>;
  notWebReady?: boolean;
  subtitles?: Array<{ url: string; lang?: string; id?: string }>;
};

export type DebridStore = {
  slug: DebridSlug;
  name: string;
  account(signal: AbortSignal): Promise<DebridResult<Account>>;
  cacheCheck(hashes: string[], signal: AbortSignal): Promise<DebridResult<CacheMap>>;
  playableUrl(
    magnet: string,
    fileIdx: number | undefined,
    signal: AbortSignal,
    hint?: EpisodeHint,
  ): Promise<DebridResult<DirectLink>>;
  queueCache?(magnet: string, signal: AbortSignal): Promise<DebridResult<{ id: string }>>;
  listLibrary(signal: AbortSignal): Promise<DebridResult<LibraryEntry[]>>;
};
```

`ResolveResult` (`src/lib/streams/resolve.ts:42-51`):
```ts
export type ResolveResult =
  | { ok: true; data: DirectLink; via: string; readiness?: LinkReadiness }
  | { ok: false; code: string; tried: Array<{ slug: string; code: string }>; webUrl?: string };

export type LinkReadiness = {
  exactUrlValidated: boolean;
  method: "provider-size" | "not-checked";
  sizeBytes: number | null;
};
```

`PreflightResult` (`src/lib/streams/preflight.ts:12-19`):
```ts
export type PreflightOk = { ok: true; sizeBytes: number | null };
export type PreflightFail = {
  ok: false;
  reason: "stub" | "unreachable" | "http-error";
  sizeBytes: number | null;
  status?: number;
};
export type PreflightResult = PreflightOk | PreflightFail;
```

Picker row/item types are not separate DTOs on the TV surface — `BpStreamRow` takes the
`ScoredStream` directly plus UI-only booleans (`cached`, `cachedOn`, `isCurrent`,
`remembered`, `resolving`, `failed`, `hostMatch`, `autofocus`, `download`) as props
(`bp-stream-row.tsx:233-265`); there is no intermediate "picker row" type.

---

## 4. Local state written

| What | Storage | Key(s) | Shape | Written from |
|---|---|---|---|---|
| **Resume position** | `localStorage` | `harbor.resume` (`resume.ts:3`) | `Record<"{id}"\|"{id}\|s{s}e{e}", { ms, t, s?, pct?, source? }>` | **Not** written from the detail page or the stream picker. `saveResumeMs`/`saveResumeBatch` are called only from the player (`src/views/player/hooks/use-resume-autosave.ts`, `use-player-exit.ts`, `src/lib/player/resume-start.ts`) and from Trakt/Simkl progress sync (`lib/trakt/playback.ts`, `lib/simkl/playback.ts`). The detail page only **reads** it indirectly via `LibraryItem.state`/`cwEntry`. |
| **Playback source history** | `localStorage` | `harbor.playback-history.v1.{profileId}` (`playback-history.ts:20-22`, profile-scoped, 30-day TTL, 200-entry cap) | `PlaybackEntry` per `"{metaId}"`/`"{metaId}\|s{s}e{e}"` key — `{ infoHash?, fileIdx?, addonId?, url?, title?, parsedTitle?, resolution?, releaseGroup?, source?, size?, bingeGroup?, cachedSlugs?, savedAt }` (`:4-18`) | **`savePlayback`** — written from `use-pick-handler.ts:417-434`, immediately after `openPlayer(src)` succeeds (i.e. every successful Play, not just resumes). Powers `settings.rememberLastStream`'s "Played last" pill and the next visit's `previousPlayback` auto-candidate. |
| **Season source lock** | `localStorage` (via `season-lock.ts`, not read in this pass) | — | same shape as a `PlaybackEntry` | **`saveSeasonLock`** — `use-pick-handler.ts:435-438`, same call site, gated on `settings.seasonSourceLock && episode` (anime titles lock across the whole series, `null` season key; others lock per-season). |
| **Watched (movies)** | `localStorage` | `harbor.moviewatched.v1.{profileId}` (`movie-watched.ts:3-4`) | `Set<string>` of meta ids (serialized array) | `setMovieWatchedLocal`, called from the detail page's **Mark watched** action (`use-bp-detail-actions.ts:189-193`, via `markMovieWatched`/`unmarkMovieWatched` in `lib/mark-watched.ts`, not itself read in this pass). |
| **Watched (episodes)** | `localStorage`, 6 separate prefixes | `harbor.manualwatched.v1.{p}` / `harbor.manualunwatched.v1.{p}` / `harbor.manualwatched.meta.v1.{p}` / `harbor.manualwatched.dismissed.v1.{p}` / `harbor.manualunwatched.at.v1.{p}` / `harbor.manualwatched.fromremote.v1.{p}` (`manual-watched.ts:6-13`) | per-key sets/maps of `"{season}:{episode}"` | Not called directly from the detail/picker files read in this pass; the episode strip only **reads** via `isManuallyWatched`/`remoteWatchedKeys` (`use-bp-episode-strip.ts:194-196`). Writers (`setManualWatched`/`setManualWatchedUpTo`/`setManualWatchedMany`) live in `manual-watched.ts` itself, invoked from card/row long-press menus elsewhere. |
| **Stremio cloud library (CW progress)** | Stremio API, `datastorePut` | collection `"libraryItem"` | `LibraryItem` (`stremio.ts:18-45`, see also `docs/browse-spec.md` §8) | `libraryPut` (`stremio.ts:243-250`) is not called from the detail/picker flow either — progress sync during playback goes through `cloudLibraryPut`/`flushWriteQueue` (`src/lib/stremio-write-queue.ts`), in the player, out of this research's scope. The detail page only reads a `cwEntry` via `useBpLibraryItem`. |

**Summary**: the detail page and stream picker are almost entirely **read**-only against
this local state (`cwEntry`, resume marks, watched flags all feed the UI); the two writes
that *do* happen directly in the picker's pick-handler are `savePlayback` and
`saveSeasonLock`, both fired the instant `openPlayer` is called — i.e. optimistically, not
after any confirmed watch progress.

---

## 5. Risks / gotchas for a native SwiftUI port

1. **Rust fast path is invisible to our engine, and most of the orchestration is not
   exported.** `runPipeline` prefers a Tauri `invoke("streams_run_pipeline", ...)` call
   (`pipeline.ts:344-364`) whenever `"__TAURI_INTERNALS__" in window`; our JS engine is
   not Tauri, so it always falls to the JS path — but the engine currently exports only
   `parseStream, applyTrust, computeCorpusStats, scoreStream, rankAndPick`
   (`engine-report.md:441-452`), not `runPipeline`, `fetchAddonStreams`,
   `mergeAndDedupe`, `finalizeWithRescue`, or `applyStreamPriority`. §2.4's orchestration
   needs new engine exports or a Swift re-implementation calling the five primitives.
2. **DOM/fetch surface beyond the shimmed basics**: real `fetch` with `Response.headers`
   and streaming `body.cancel()` (`preflight.ts:91`), `document`/`window.matchMedia` in
   the UI layer (`bp-detail-actions.tsx:22`) — SwiftUI-only, not logic, but confirm the
   `fetch` shim supports header/streaming access. The `@tauri-apps/plugin-http` import in
   `preflight.ts:1` is dead on our engine (`isTauri` always false) — confirm it's stubbed.
3. **No native torrent engine.** `tryTorrentEngine`/`tryLocalEngine`/`tryRemoteEngine`
   (`resolve.ts:340-441`) assume a bundled Rust torrent client or a user-configured remote
   Stremio server. Without one, P2P-eligible, no-debrid infoHash streams
   (`engineP2pEligible`) simply cannot resolve — likely unplayable on tvOS until a remote
   streaming server option exists (itself unimplemented Stage-3+ scope).
4. **`registerStreamProxy`/`unregisterStreamProxy`** (`use-pick-handler.ts:279-291`) — a
   local HTTP proxy for resolved links needing custom request headers
   (`proxyHeaders`/`behaviorHints.headers`). No Rust proxy on tvOS; mpv/AVPlayer needs a
   native header-injection equivalent or this class of stream fails silently.
5. **Download flow** (`intent === "download"`, `enqueueDownload`, `downloadSeasonFromPack`,
   `completedTorrentDownloadFor` checked first in every resolve at `resolve.ts:101-117`)
   is desktop-offline-storage-shaped — confirm explicitly deferred rather than ported.
6. **Profile-scoped `localStorage` keys everywhere** (`harbor.resume`,
   `harbor.playback-history.v1.{profileId}`, `harbor.moviewatched.v1.{profileId}`,
   `harbor.manualwatched.*.v1.{profileId}`) resolve the active profile via
   `harbor.profiles.v1`, including a `shareStremioWith` redirect
   (`playback-history.ts:28-48`). A native "who's watching" rewrite must replicate this
   exactly or per-profile watched/resume state points at the wrong bucket.
7. **`parse-torrent-title`** is used directly in `library.ts` (matching cached-library
   entries) — confirm this npm package is pure JS and bundles cleanly; separate from
   Harbor's own `parseStream`/`parser.ts`.
8. **Auto-play timing constants are wall-clock**, tuned for a Fire TV/Shield-class device
   (`AUTO_SETTLE_MS`, `HIGH_CONFIDENCE_GRACE_MS`, `QUORUM_CAP_MS`,
   `PREFLIGHT_TIMEOUT_MS = 1200ms`, `ERROR_VIDEO_MAX_BYTES`, `MIN_REAL_SIZE_BYTES`) —
   reasonable starting values, but re-validate against Apple TV network/JSC latency.
9. **The episode-strip "unaired" gap** (§1.5) is confirmed upstream behavior, not a
   documentation gap. Flag to design/product rather than silently adding unaired-graying
   in the native rebuild, which would be new, undocumented behavior vs. upstream.
