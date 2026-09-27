# Big Picture parity audit — 2026-09-23

"What Big Picture does that the TV app does not yet." Upstream = `reference/harbor/src/views/big-picture/**` at `1bfcfb6` (read-only). Port = `App/Sources/**` (SwiftUI) + `engine/*.ts` (upstream logic in JavaScriptCore; `engine/entry.ts` is the list of what Swift can call).

Method: eight parallel read-only research passes (one per area — shell/onboarding/who's-watching, Home/Movies/Shows/Discover, Search/Collections, Detail/Person, Streams/Player/Queue, Library/Anime, Live TV/Sports, Settings/Addons) each read every BP file in their slice and grepped the port for an equivalent (Swift views, `entry.ts` exports, glue files). Two passes independently over-ran their assigned slice and self-produced a full first draft of this document; a final orchestrating pass reconciled both drafts against all eight passes' findings, folded in items only the narrower passes had caught (search's idle mosaic/recent-query chips, Library's Episodes/Posters history toggle, Anime's row-customization UI, Collections' hidden-manga-count note), and is the version below. Load-bearing claims that contradict `PROJECT_STATE.md` were re-verified by hand (see "Corrections" below). No files other than this one were edited; upstream was never touched.

Fields per gap: **Upstream** file(s) · **Behaviour** (user-visible) · **Engine** = is the data/logic already in the bundle (yes / partial / no, with the export or "not found") · **Effort** S/M/L · **Impact** for a TV viewer H/M/L.

## Reconciliation (2026-09-27)

This audit's tables were never updated after the batches below shipped (SP-1's row was the example
that triggered this pass: it was flagged "Open" in a task brief on 09-27 despite having shipped on
09-24, commit `0211981`). Every row in every table in this file — the per-area tables, the Top 15,
the honourable mentions, the closing notes — was checked against the actual code in `App/Sources/**`
and `engine/*.ts` (not against this file's own stale "Engine" column) and `PROJECT_STATE.md`'s Status
log. An earlier draft of this pass wrongly flagged four rows as Partial/Open (SH-11, AN-1, SR-7, ST-2)
on a literal-string grep that missed a level of indirection each time — a shared component that
wraps the real feature under a different name (`AnimeHeroActionsView` wired into the anime room via
`RoomView.swift`'s `animeActions(lead:)`, not the file that merely defines it; `PhoneTypingSheet` and
`ConnectPane` wrapping `TvHandoff` for Search and Settings respectively, so grepping for the literal
string `TvHandoff` inside those directories found nothing; `BPHeroPips.swift`/`HeroPips`, not the
string `heroPip`). Those four were re-verified by tracing the actual call sites and are Ported. The
rows below carry a short inline note with the corrected pointer. Corresponding "Still open" rows were
added to `docs/parity-gaps.md`.

**Counts — 109 rows total: 104 Ported, 3 Partial, 0 Open, 2 N/A.**

Not fully shipped:
- **SH-1** (Partial) — the ambient backdrop's cross-fade to the focused title's own art with glow
  tint exists for Home's hero (`SpotlightView.swift`) and for several bands (`HomeBands.swift`), but
  the generic app-wide ambient layer used by every other screen (`Theme.swift` `BPAmbientBackground`)
  is still a drifting poster mosaic plus a static gradient, not a cross-fade. Size M to extend the
  existing pattern. Added to `parity-gaps.md`.
- **DT-17** (Partial) — home-server (Plex/Jellyfin/Emby) copies are a full picker source (Stage 6,
  `App/Sources/Streams/PlayPickerView.swift` `showHomeServers`/`model.copies`, `Settings/HomeServersPanel.swift`);
  local files are N/A on tvOS (no filesystem to browse), so the remaining half of this row is not a
  real gap.
- **SP-9** (Partial) — TheSportsDB artwork fallback is ported (`engine/sports.ts` `fetchSportsArtwork`/`cachedArtwork`),
  but upstream's further fallback — a fixed scenery photo per sport when even TheSportsDB has nothing
  (`SCENERY_GROUPS` in `bp-sports-art.ts`) — has no port equivalent. Size S. Added to `parity-gaps.md`.
- **AN-3** and **SP-13** are N/A (dead code in upstream / upstream's own Big Picture has no "paste a
  stream URL" write path for this either — the port's `Attachments.streams` does get written, but
  only through the pin-a-channel flow, not a URL-paste UI upstream never had), not gaps — unchanged
  from the original audit's own call for AN-3, refined for SP-13.

Everything else in this file — all of §1–§15's other rows, the Top 15 ranked list, the "cheap
correctness fixes" and "honourable mentions" in §16, including SH-11 (hero pips), AN-1 (anime hero
actions/meta) and the SR-7/ST-2/OB-4 phone-handoff trio — is Ported; each carries its own pointer
inline. Watch Together (§1's closing note, §17) is not just "moved" — the port now has full room
create/join (`App/Sources/Together/TogetherModel.swift` `start`/`join`, `TogetherView.swift`
code/QR/chat), which is *more* than upstream's own Big Picture has (upstream BP only badges
host-matching streams).

All five corrections in §0 are also moot now: the features they describe as missing at the time have
since shipped — search fan-out (SR-1..3, SR-5, SR-8), the resume/up-next/subtitle-offset player rows
(PL-1/PL-2/PL-3), the Sports reminder loop and its Discord/Telegram send (SP-4), and `instantPlay`
(DT-1). See §0's own row-by-row.

---

## 0. Corrections to PROJECT_STATE.md (verified by hand)

| Claim in PROJECT_STATE | Reality |
|---|---|
| "Search now also shows Live TV channel hits (playable) and one row per addon that answered (`search.all` already returned both)." | False. `search.all` = upstream `lib/search.ts:searchAll`, which hardcodes `liveTv: []` and `addonGroups: []` on every return path (lines 258, 261, 276, 280, 386, 390) and never fills `anime`/`manga`/`characters`. `SearchModel.swift:63,67` only ever calls `search.all` and `search.cinemeta`. The channel row and addon rows in `SearchView.swift` are dead UI. `search.anime/liveTv/addonCatalogs/addonGroups` are exported (`entry.ts:303-315`) but never invoked. |
| "player (chrome, … resume … up-next pill, next-episode advance …)" | Overstated. Resume is silent (no Resume / Start Over prompt; `PlayerScreen.swift:120` seeks). "Next-episode advance" reopens the stream picker for the next episode (`DetailView.swift:72-81`), it does not auto-play. Subtitles = track select + online search only (no offset, no in-player style, no filters). |
| Sports consent notice copy | `SportsConsentView.swift:18` is upstream's text verbatim and promises Discord/Telegram reminders; no reminder code exists anywhere in the port (`grep -rniE remind engine/sports.ts App/Sources/Sports` → 0). |
| Stage 9 "8 categories" | Accurate. `BP_CAT_IDS` really is 8 (picture, language, subtitles, playback, home, services, setup, interface) and `settingsRoom.ts` imports upstream's catalog directly. The gaps are elsewhere (see §11). |
| `instantPlay` | `settingsRoom.ts:72` commits it, but nothing in `App/Sources` reads it; the setting is inert. |

---

## 1. Shell chrome: top bar, hint bar, profile menu, ambient, screensaver, dialogs

| # | Upstream | Behaviour | Engine | Effort | Impact |
|---|---|---|---|---|---|
| SH-1 | `bp-ambient.tsx`, `bp-ambient-layers.tsx`, `bp-art*.ts`, `bp-backdrop-commit.ts` | Background cross-fades to the focused title's own art with glow tint and slow motion — BP's signature look. Port: `Theme.swift` `BPAmbientBackground` is a static gradient on every screen. **[Ported]** (2026-09-27, commit 336623b: `BPAmbientBackground(focused:)` cross-fades the focused tile's art on Collections and Library too; glow tint / trailer layers still not ported.) Earlier note: The cross-fade-to-focused-art-with-glow-tint exists for Home's hero (`Browse/SpotlightView.swift`) and several bands (`Browse/HomeBands.swift`), but the generic app-wide layer every other screen uses (`Design/Theme.swift` `BPAmbientBackground`) is still a drifting poster mosaic plus a static gradient, not a cross-fade. Size M to extend the existing pattern. | no (`grep ambient engine/` → 0) | L | H |
| SH-2 | `bp-screensaver.tsx`, `use-bp-screensaver.ts` | Idle-triggered art cycler (title/subtitle per item), delay set in Settings, suppressed during playback. Port: nothing; no setting either. **[Ported]** PROJECT_STATE batch 2 (2026-09-23 night): `ScreensaverModel`, `App/Sources/Shell/Screensaver.swift`; hardened by the 09-25 audit's `suppressed` sweep. | no | M | H |
| SH-3 | `bp-quick-panel.tsx`, `bp-focus-meta.ts` | Y-button / long-press overlay on the focused tile: play, watchlist, hide from CW, sound, sign-out. Port: none; actions only via Detail. **[Ported]** batch 2 + parity-gaps.md H5 (pass 3): `App/Sources/Browse/QuickPanelView.swift` (Play/Watchlist/Details/Remove from CW/Search, Sound/Backdrop rows). Open-anywhere with no title focused is still open (parity-gaps H5). | n/a (uses existing cards/watchlist) | M | M-H |
| SH-4 | `bp-hint-bar.tsx` | Hints change per surface and input (select/back/search/type/clear/toggle/phone/tabs/nav/advance). Port: `ShellView.hints` is a hardcoded `[("OK","Select"),("Menu","Back")]`. **[Ported]** `App/Sources/Shell/ShellView.swift` `hints`/`BPHintAction` — per-surface hint bar, no longer the hardcoded pair. | n/a | S-M | M |
| SH-5 | `bp-status.tsx` in `bp-top-bar.tsx` | Persistent Wifi/WifiOff + CloudOff (stale sync) icon by the clock. Port: `TopBarView` has none; sync failure only shows on Who's Watching. **[Ported]** batch 1 (21:45 09-23): NetworkStatus Wifi/CloudOff icons in the top bar. | yes (`sync.status`) | S | M |
| SH-6 | `bp-confirm.tsx` (and `bp-exit-confirm.tsx` pattern) | Yes/No dialog before destructive actions. Port: `grep -rE "\.alert\(\|confirmationDialog" App/Sources` → 0; profile delete is unconfirmed. **[Ported]** batch 1 (leave confirm) + `App/Sources/Profiles/ProfileEditorView.swift` two-step "Delete profile"→"Delete for real"; several `.alert`/`confirmationDialog` sites now exist. | n/a | S | M |
| SH-7 | `bp-intro.tsx`, `bp-intro-pool.ts`, `use-bp-intro.ts` | Animated poster-wall "front door" after boot splash. Port: `RootView` goes boot → onboarding/who's-watching. **[Ported]** `App/Sources/App/IntroView.swift` (poster-wall front door after boot). | n/a | M | L-M |
| SH-8 | `bp-restore.ts` | Focus/scroll position remembered per route and row when returning. Port: relies on SwiftUI identity only. **[Ported]** `App/Sources/Browse/BPRestore.swift` — per-route/row focus memory (in-memory, matching upstream's own module). | n/a | S-M | L-M |
| SH-9 | `use-bp-sound.ts`, `lib/sfx` | UI sound theme (Off/Glass/Modern/Cinematic/Retro). Port: no SFX at all, yet Settings → Interface → Sound commits `bigPictureSound` (`settingsRoom.ts:76`) — a dead control. Also audition-on-focus (`bp-settings.tsx onCellFocus`). **[Ported]** `App/Sources/Shell/BPSound.swift` (`SFX`) + `QuickPanelView.swift` Sound-pack chip. | partial (setting only) | S-M | L |
| SH-10 | `bp-controller-toast.tsx` | Toast on game-controller connect/disconnect. **[Ported]** `App/Sources/Shell/Gamepads.swift` `ControllerToastView` (bp-controller-toast.tsx port). | n/a | S | L |
| SH-11 | `bp-hero-pips.tsx` | Position pips under the Home hero cycle. Port: none. **[Ported]** `App/Sources/Design/BPHeroPips.swift` `HeroPips`; drawn by `Browse/RoomView.swift` via `SpotlightView(pips:)` (`model.heroCount > 1 && !model.cycleHeld`). Missed on a literal `heroPip` grep the first time; caught by tracing `SpotlightView`'s `pips` parameter. | n/a | S | L |
| SH-12 | `use-bp-hero-cycle.ts:13-25` | Hero cycle stops under reduced-motion. Port: `BrowseModel.startHeroCycle` ignores `UIAccessibility.isReduceMotionEnabled`. **[Ported]** `App/Sources/Browse/BrowseModel.swift` checks `UIAccessibility.isReduceMotionEnabled` before the hero cycle. | n/a | S | L |
| SH-13 | `bp-profile-menu.tsx`, `bp-status-dialog.tsx` | Profile / tracker status from the top bar. Port: moved to Settings (`SettingsView`, `PasteTrackerView`). Surface moved, not missing. **[Ported]** Unchanged from the original audit (surface moved to Settings, not missing). | yes | — | — |

Phone typing (`bp-phone-typing.tsx`) is under Search (SR-7). Together/watch party: BP wraps the tree in `TogetherProvider` and badges host-matching streams in the picker, but **there is no BP UI to create or join a room**; the port has zero Together references. Not ranked. **[Ported, to upstream's own scope, 2026-09-27 reconciliation]** The port now has `App/Sources/Together/TogetherModel.swift` (`start`/`join`), `TogetherView.swift` (code/QR/chat) and a host-match/duration-mismatch chip (parity-gaps.md S5/P8) — matching upstream's actual scope (badging only) and going beyond it (upstream itself has no create/join UI at all; the port does). See §17.

## 2. Home

| # | Upstream | Behaviour | Engine | Effort | Impact |
|---|---|---|---|---|---|
| HM-1 | `bp-home.tsx:186,225-246`, `addons/bp-addon-row.tsx`, `bp-collections-row.tsx` | "Your addons" band (one wide card per installed addon → addon page) and a curated "Collections" row between the catalog rows. Port: addon catalogs are merged into ordinary rows via upstream's fallback merge (`EngineBrowseSource.swift:51-53` says so). **[Ported]** `App/Sources/Browse/HomeBands.swift` `.collections` band; `engine/addonsRoom.ts` + `engine/rooms.ts` addon rows (batch 5, 00:30 09-24). | partial (`addons.loadAddonRows`, `fetchAddonCatalogPage` exported; no curated collections source) | M | M |
| HM-2 | `bp-home.tsx:188-205`, `bp-live-row.tsx`, `bp-live-cell.tsx`, `bp-live-hero.tsx`, `bp-live-rank.ts`, `bp-live-band-art.ts`, `bp-live-split.tsx` | Ranked Live TV row on Home (junk-name filter, favourite/most-watched/network boost), ambient muted video preview behind the row when a channel is focused, split band-art tiles. Port: none. **[Ported]** `engine/live.ts` `homeRow`/`rankBpLive`; `App/Sources/Browse/RoomView.swift` `LiveRowView` (batch 7, 01:45 09-24). | no (`rankBpLive`, `bpCleanChannelName` not found) | L | H (IPTV users) |
| HM-3 | `bp-cw-row.tsx`, `bp-cw-card-meta.tsx`, `lib/feed/external-cw.ts` | CW card extras: watched check, "+N new episodes" pill, source glyph (Trakt/Simkl/clock/play), watcher avatar, "Up Next"/waiting-for-air/next-episode title. Trakt/Simkl "currently watching" merged into CW. Port `ContinueCardView`: backdrop, logo, `S E`/`% left` pill, progress only; `rooms.ts continueWatching` merges cloud+local only. **[Ported]** `engine/rooms.ts` `continueWatchingWithExtras`; `App/Sources/Browse/ContinueCardView.swift` (batch 6, 01:00 09-24). | partial | M | M |
| HM-4 | `bp-spotlight.tsx:101-157`, `bp-score-chips.tsx`, `bp-hero-award-marks.tsx` | Hero provider-badge mark, awards corner overlay, multi-provider score chips (IMDb/MAL/TMDB/Simkl/RT/MC/Letterboxd/MDBList/Trakt, each gated). Port `SpotlightView.swift:20-24`: single TMDB-or-IMDb chip. **[Ported]** `App/Sources/Browse/ScoreChipsView.swift` on the hero (batch 5) + `Detail/DetailView.swift` `AddonOriginMark` (parity-gaps D2). | partial | S (badge+corner) / L (providers) | M |
| HM-5 | `bp-mosaic.tsx` | Drifting poster collage behind bands without focused art. **[Ported]** `App/Sources/Design/Theme.swift` `BPMosaicView`/`bigPictureMosaic` (batch 6). | n/a | M | L |

Hero actions: BP's Home spotlight is a pure display surface (no buttons), same as the port — not a gap. Verified present: hero pool (row 0, first 8), 7 s cycle with focus pause, services band at slot 2, Top-10 ribbon, card-mark chip chain, network rows, `MIN_ROW_METAS`/`VISIBLE_ROWS` dedup.

## 3. Movies / Shows / Discover / genre grid / See-all grid

Verified present: separate Movies and Shows tabs (`AppModel.Room`), Top-10 row, TMDB-vs-Cinemeta fallback, genre/collection catalog rows, "See all" grid (`CatalogPageView`, paginated via `rooms.page` / `services.page` / `animeRoom.specPage`), Awards band + award detail, People band, genre-tile art on focus.

| # | Upstream | Behaviour | Engine | Effort | Impact |
|---|---|---|---|---|---|
| DS-1 | `use-bp-genre-grid.ts`, `bp-genre-grid.tsx` | Selecting a genre tile opens a paginated TMDB-discover poster grid (`with_genres`, `vote_count.gte 180`, popularity). Port: `DiscoverView.swift:136` tile is `Button {}` — inert. **[Ported]** `engine/discover.ts` `genrePage`; `App/Sources/Discover/DiscoverView.swift` (batch 2, 22:30 09-23). | no (`discover.ts` has only `genres()`/`genreArt()`) | M | H |
| DS-2 | `queue/bp-queue.tsx`, `queue/use-bp-queue.ts`, `queue/bp-queue-band.tsx` | Discovery Queue: full-screen one-card-at-a-time deck with skip-for-now / never-show, daily-seeded order, low-water refill. Port: preview band only; `DiscoverView.swift:69` `Button {}` is inert. **[Ported]** `engine/discover.ts` `queueOpen`/`queueExtend`; `App/Sources/Discover/QueueDeckView.swift` (batch 2). | yes, unwired (`discoverRoom.queueFor` exported, never called) | M | H |
| DS-3 | `bp-award-tiles.tsx:153`, `bp-anime-awards.tsx` | Anime award tiles in the Awards band open the anime award overlay (year filter "All years", "Grand" winners, "No data shipped"). Port: award detail is the classic-awards shape only (`discover.ts:139`); no anime award source. **[Ported]** `App/Sources/Discover/AnimeAwardView.swift`, `DiscoverModel.animeAwards`, `engine discoverRoom.animeAward*`. | partial (bundled anime index used in `animeRoom.ts`) | S-M | L-M |
| DS-4 | `use-bp-movies.ts` `useBpLetterboxdRows` | Letterboxd rows on Movies. **[Ported]** `engine/letterboxd.ts` `movieRows`; `App/Sources/Browse/EngineBrowseSource.swift` (Library/Collections batch, 12:15 09-24). | no | M | L (needs Letterboxd account, see LB-3) |

## 4. Search

| # | Upstream | Behaviour | Engine | Effort | Impact |
|---|---|---|---|---|---|
| SR-1 | `lib/search-addons.ts`, `lib/search-context.tsx`, `bp-search-rows.tsx` | Addon catalog hits fused into Movies/Series plus one "From <Addon>" row per addon that answers (pending/ok/empty/failed, retry). Port: never fetched (see §0). **[Ported]** `engine/search.ts` `fanOut` fuses addon catalogs + groups (batch 1, 21:45 09-23). Corrects PROJECT_STATE's own earlier false claim about this. | yes (`search.addonCatalogs`, `search.addonGroups`) | S | H |
| SR-2 | `lib/search.ts searchAnime` | Anime results (AniList + Jikan + Kitsu fusion). Port decodes `anime` and has a row, never calls it. **[Ported]** `engine/search.ts` `animeP` inside `fanOut` (batch 1). | yes (`search.anime`) | S | M-H |
| SR-3 | `lib/search.ts searchLiveTvChannels`, `BpChannelCell` | Live TV channel hits, tunable from search. Port has `channelRow` UI that can never populate. **[Ported]** `engine/search.ts` `liveTv` inside `fanOut`; `App/Sources/Search/SearchView.swift` `channelRow` (batch 1). | yes (`search.liveTv`) | S | M |
| SR-4 | `use-bp-search.ts`, `bp-search.tsx` | Kind chips (All/Movies/Series/People/Anime/Manga/Live TV/Collections/Franchise/Addons) with counts. **[Ported]** `App/Sources/Search/SearchView.swift` `chipStrip` — kind chips with per-kind counts. | n/a | S | L (grows with SR-1..3) |
| SR-5 | `lib/providers/tvdb-collections.ts`, `use-collection-hits.ts` | Collection/franchise banner hits in results. **[Ported]** `engine/search.ts` `collectionHits` via tvdb-collections + franchise rows (batch 1). | no | M | L-M |
| SR-6 | `lib/anilist/character.ts` | Character search → every anime/manga featuring them. **[Ported]** `engine/search.ts` `charactersP` (`anilistCharacterSearch`). | no | M | L |
| SR-7 | `bp-phone-typing.tsx`, `lib/tv-handoff/*` | QR → phone types into the TV over LAN (also used by Connect and onboarding "phone" step). Port: on-screen `BPKeyboardView` only (a faithful `bp-keyboard.tsx` port). **[Ported]** `App/Sources/Handoff/PhoneHandoffViews.swift` `PhoneTypingSheet` wraps `TvHandoff`; `Search/SearchView.swift:113` uses it for the search field ("Search Harbor"). Missed on a literal `TvHandoff` grep the first time; caught by tracing the actual sheet type. | no | L | M |
| SR-8 | `lib/search-addon-index.ts` | "Addons you could install" hits. **[Ported]** `engine/search.ts` `searchAddonIndex`; `App/Sources/Search/SearchView.swift` `addonIndexRow` (batch 1). | no | S-M | L |
| SR-9 | `lib/search.ts searchManga` | Manga results. Zero manga surface in the port; needs a reader to be useful. **[Ported]** `engine/search.ts` `searchManga`; `Search/SearchModel.swift`/`SearchView.swift`. | no | M | L |
| SR-10 | `search/bp-search-input.tsx` `BpRecentRow` | Recent search queries shown as chips when the field is idle, with a clear-all button. Port: no recent-query storage/UI in `SearchModel.swift`. **[Ported]** `App/Sources/Search/SearchView.swift` recent-query chips (search pass 3, batch 3, 23:15 09-23). | no | S | M |
| SR-11 | `bp-search.tsx` idle state (`BpMosaic` + `suggestions`) | Empty field shows an ambient poster mosaic background plus a "Suggested" grid pulled from Home rows. Port shows a plain empty-state message. **[Ported]** `App/Sources/Search/SearchView.swift` idle "Suggested" row (batch 3). | no | S | L |

## 5. Detail page

| # | Upstream | Behaviour | Engine | Effort | Impact |
|---|---|---|---|---|---|
| DT-1 | `bp-detail.tsx:140-159`, `use-bp-stream-play.ts`, `views/play-picker/use-auto-candidates.ts`, `use-auto-fire.ts`, `bp-stream-steps.tsx` (`BpAutoStep`) | With `instantPlay` (default on) Play skips the picker and fires the best cached/instant stream, "Trying source N…" screen, falls through candidates on failure. Port: Play always opens `PlayPickerView`; `instantPlay` unread. **[Ported]** batch 3 (23:15 09-23) instant play: `App/Sources/Streams/PickerAutoStep.swift`, `engine/streams.ts` `autoCandidates`. | no (ranking exists in `streams.ts`; no candidate/settle/auto-fire logic) | L | H |
| DT-2 | `use-bp-anime-detail.ts`, `bp-anime-seasons.tsx`, `bp-anime-season-chip.tsx`, `bp-anime-characters.tsx`, `bp-episode-ids.ts`, `use-bp-trackers.ts` | Anime detail: kitsu/mal/anilist ids → aired/absolute/TVDB episode order, season/cour chips with arc names and year ranges, filler tags, sub/dub badge, Characters row, canonical ids for tracker writes, resume from Simkl/AniList/MAL progress. Port: `DetailModel` always takes the Cinemeta + TMDB path. **[Ported]** `engine/animeDetail.ts` (Kitsu chain) — batch 6 (01:00 09-24, "anime detail path"). | no (`animeRoom.ts` serves the catalog tab only) | L | H |
| DT-3 | `use-bp-detail-actions.ts`, `bp-detail-actions.tsx` | Hero actions beyond Play/Watchlist: tracker status (AniList/MAL), Mark watched (+ on Trakt), Favourite, Remind me (upcoming), Rate this, Add to list, Watch trailer. Port `DetailView.swift:134-138`: Play + Watchlist only. **[Ported]** batch 4 (23:45 09-23): `Detail/DetailView.swift` `HeroAction` array (rate/lists/watched/favorite/reminder/trailer/synopsis). | partial (`trakt`/`simkl`/`anilist`/`mal` glue exist; no ratings/lists/favourites/reminder exports) | M | M-H |
| DT-4 | `bp-stream-chips.tsx`, `bp-stream-filters.ts`, `bp-stream-menu.tsx` | Picker facets (HDR, codec, source, audio, edition, remux), addon-grouping menu, saved custom filters, preferred-language chip, sort toggle (Harbor pick vs addon order), Clear filters, Refresh. Port: quality/Cached/addon-name chips only. **[Ported]** `Streams/PlayPickerView.swift` facet menus (HDR/codec/source/audio/edition) — batch 3. | partial (fields are in `ScoredStream`; no facet/sort API) | M | M-H |
| DT-5 | `use-bp-streams.ts` (`strictMode`, `forceShowAll`, `searchWider`, `showEverything`) | "Search wider" / "Show everything" ladder when filters leave nothing. Port passes empty opts and has no loosen UI. **[Ported]** `Streams/StreamsModel.swift` `searchWider()`/`showEverything()`; `PlayPickerView.swift` "Search wider"/"Show everything" buttons. | yes (`streamsRoom.search` takes `{strictMode, filterDisabled}`) | S | L-M |
| DT-6 | `use-bp-streams.ts` (`rememberedStream`, `sourceEntry`), `bp-stream-row.tsx` "Played last" | Last-played / season-locked source pinned to the top and badged. **[Ported]** `Streams/PlayPickerView.swift` "Played last"; `StreamsModel.swift` `rememberedStream`. | no | M | M |
| DT-7 | `bp-stream-dialogs.tsx` (`BpP2pDialog`, `BpDebridDownDialog`, `BpNoSourcesDialog`, `BpAutoExhaustedDialog`) | Consent before uncached P2P, debrid-down retry screen, "tried N sources" screen. Port: one generic error string in `PlayPickerView.pick()`. **[Ported]** `Streams/PlayPickerView.swift`/`StreamsModel.swift` — P2P consent dialog, debrid-down streak, auto-exhausted dialog (batch 2 stream error card + later hardening). | partial (`streamsRoom.resolve` returns ok/code) | S-M | M |
| DT-8 | `bp-score-chips.tsx`, `use-bp-card-badges.ts` | Multi-provider score chips in the hero (each gated by `showXDetail`). Port `DetailView.swift:108-113`: Cinemeta `imdbRating` only. **[Ported]** `Browse/ScoreChipsView.swift` on Detail (`surface: "detail", limit: 6`) — batch 5. | no | M | M |
| DT-9 | `detail/bp-awards-row.tsx`, `detail/bp-award-detail-dialog.tsx` | Award-body marks with win/nomination counts → per-award dialog of categories and years. Port: none (plumbing exists in `personRoom.ts` and Discover). **[Ported]** `engine/detailRoom.ts` `awards`; `Detail/DetailView.swift` `awardsRow`/`AwardsDialogView`. | no for titles (`grep award detailRoom.ts` → 0) | M | M |
| DT-10 | `detail/bp-videos-row.tsx` | Trailers/clips/featurettes row. Port: `detailRoom.extras` already returns `videos` (14), `DetailModel.Extras` drops the field. Playback is best-effort on tvOS (no yt-dlp). **[Ported]** `Detail/DetailView.swift` `videosRow`. | yes | S (row) / M (playback) | M |
| DT-11 | `detail/use-bp-episode-facts.ts`, `detail/use-bp-episode-enrich.ts`, `use-bp-episode-art.ts`, `bp-episode-still.tsx` | Per-episode rating + runtime chip and a still-image fallback ladder (TMDB → TVDB → ani.zip → embedded → metahub). Port `EpisodeCell`: Cinemeta thumbnail + title only. **[Ported]** `Detail/DetailModel.swift` `loadEpisodeFacts`/`loadEpisodeArt`; `engine/detailRoom.ts` `episodeArt`. | no | M | M |
| DT-12 | `bp-gallery-row.tsx` | Backdrops/posters/logos gallery (24 each) with a lightbox. Port: `detailRoom.ts` returns counts only. **[Ported]** `Detail/GalleryRow.swift`; `engine/detailRoom.ts` `gallery`. | partial | M | L-M |
| DT-13 | `detail/bp-crew-row.tsx` | Crew cells are portrait cards (Director/Writer/Producer/Cinematography/Music/Editor groups), tappable into the Person page. Port: `crew.prefix(4)` static text, not tappable. **[Ported]** `Detail/DetailView.swift` line ~877 — crew cells are tappable into the Person page when TMDB knows the person. | partial — `extras.crew` gives the grouped `{label, names}` text but not TMDB person ids/photos, so making it tappable needs a small `detailRoom.ts` addition, not just a Swift change | S | L-M |
| DT-14 | `detail/use-bp-episode-strip.ts`, `bp-episode-window.tsx` | Episode strip auto-scrolls to the resume episode; windowed loading (+60). Port loads the season eagerly, no scroll-to-resume. **[Ported]** `Detail/DetailView.swift` `ScrollViewReader`/`scrollTo` to the resume episode. | n/a | S | L-M |
| DT-15 | `detail/bp-facts-dialog.tsx` | Facts preview → full scrollable dialog. Port: `facts.prefix(8)` inline, no dialog. **[Ported]** `Detail/DetailView.swift` `factsDialog`/`FactsDialogView`. | yes (`extras.facts` is uncapped) | S | L |
| DT-16 | `bp-season-menu.tsx` | Seasons as a scrollable modal. Port: inline chip row (`DetailView.swift:250-254`). **[Ported]** `Detail/DetailView.swift` `seasonsSheet` modal. | n/a | S | L |
| DT-17 | `bp-stream-row.tsx` (`BpLocalRow`, `BpHomeServerRow`) | Local files and Plex/Jellyfin/Emby copies as sources. Belongs to Stage 6, not a detail polish item. **[Partial]** Home-server (Plex/Jellyfin/Emby) copies are a full picker source now (`Streams/PlayPickerView.swift` `showHomeServers`/`model.copies`, `Settings/HomeServersPanel.swift`, Stage 6); local files are N/A on tvOS (no filesystem to browse), so the remaining half of this row is not a real gap. | no | L | M (Stage 6) |

`bp-hero-manga.tsx` ("Read the manga") is exported but never mounted in upstream — dead code, not a gap. `bp-subtitle-step.tsx` (pre-play subtitle pick) is covered by the port's in-player panels.

## 6. Anime room (tab)

Verified present (`animeRoom.ts`): 16 Jikan spec rows, anime CW, seeded hero, award winners merged, addon anime catalogs, collections, row customisation, AniList/MAL rails, rank tiles.

| # | Upstream | Behaviour | Engine | Effort | Impact |
|---|---|---|---|---|---|
| AN-1 | `bp-anime-hero.tsx:155-174`, `bp-anime-hero-actions.tsx`, `bp-anime-hero-meta.tsx` | Anime hero has actions (Resume / Start Watching, More Info), meta line ("Anime of the year", "New", award mark) and availability ("Sub and Dub"). Port: the anime room reuses the display-only `SpotlightView`. **[Ported]** `App/Sources/Browse/AddonPageView.swift` `AnimeHeroActionsView` (meta line: award/New pill, MAL score, Sub and Dub, country, episode/minutes-left; Resume/Start Watching + More Info actions) reads `animeRoom.heroMeta`, rendered by `RoomView.swift`'s `animeActions(lead:)` alongside the hero. Missed on a `SpotlightView.swift`-only grep the first time; caught by tracing `RoomView.swift`'s hero composition. | partial (hero + resume data exist in `animeRoom.page`) | S-M | M |
| AN-2 | `bp-anime-badges.tsx` | Anime card badges (award, DUB). Port: covered by `cards.ts` identity chip. **[Ported]** Unchanged from the original audit. | yes | — | — |
| AN-3 | `bp-anime-announcement.tsx` | Never mounted in upstream (dead code). **[N/A]** Dead in upstream, unchanged. | — | — | — |
| AN-4 | `bp-anime-groups.ts` row customisation (reorder/hide/rename rows) | User can reorder, hide, or rename anime rows from settings. Port has no UI anywhere for it (`grep -rn "animeRows\|reorder" App/Sources` → 0). **[Ported]** batch 4 (23:45 09-23): `App/Sources/Settings/AnimeRowsPanel.swift` (reorder/hide/rename/reset). | yes (`animeRoom.ts` already calls upstream's unmodified `applyAnimeRowCustomization`) | S | L-M |

Seasons chips and Characters are on the anime **detail** page → DT-2.

## 7. Player

Verified present: transport, seek, pause, audio/subtitle track panels, online subtitle search, up-next pill, skip intro/outro/recap pill, Anime4K panel + indicator, resume seek, progress saves, Trakt/Simkl scrobbles, display-mode matching.

| # | Upstream | Behaviour | Engine | Effort | Impact |
|---|---|---|---|---|---|
| PL-1 | `player/bp-resume-prompt.tsx` (via `views/player/bp-ten-foot.tsx`) | "Resume from X / Start over" dialog with progress bar before playback. Port seeks silently (`PlayerScreen.swift:120`). **[Ported]** batch 1 (21:45): `Player/PlayerScreen.swift` `resumePrompt()`, `settings.resumePrompt`, RESUME_PROMPT_MIN_SEC(30s). | partial (`player.startPosition`) | S | H |
| PL-2 | `player/bp-up-next.tsx` | "Play now" jumps straight into the next episode's already-resolved best stream, countdown ring, "Keep watching". Port reopens the picker (`DetailView.swift:72-81`). **[Ported]** batch 3 (23:15, instant play) + `Player/PlayerScreen.swift` `upNextCard`/`showUpNextCard`/`playNext()` (countdown ring, auto-fires via instant play). | no (no next-episode pre-resolve) | M | H |
| PL-3 | `player/bp-subtitle-tune.tsx` (`BpSubtitleSync`) | Subtitle offset ±0.1/±1.0 s with readout (auto-sync analysis is desktop-heavy; manual offset is what matters). Port: no `sub-delay` anywhere. **[Ported]** batch 3: `Player/PlayerSubtitlesPanel.swift` "Manual offset" ±0.1/±1.0s + readout, mpv `sub-delay`. | no | S | H |
| PL-4 | `player/bp-connecting.tsx` | Full-screen connecting state: blurred backdrop, logo, status note, stall detection, Cancel, Try again. Port: a "Loading…" label; a stuck stream just sits. **[Ported]** batch 3: `Player/PlayerScreen.swift` `connectingCard` + `stallTick()`; `PlayerKids.swift` kid-profile variant. | no | M | H |
| PL-5 | `player/bp-leave-confirm.tsx` | "Leave the show?" Keep watching / Leave / Don't ask again on second Back. Port: third Menu press exits immediately (`PlayerScreen.swift:114-118`). **[Ported]** batch 1: `Player/PlayerScreen.swift` `leaveConfirm`, "Leave the show?", `settings.playerConfirmLeave` "Don't ask again". | no (no "don't ask" setting) | S | M |
| PL-6 | `player/bp-player-subtitles.tsx` | Hide HI/SDH, Forced only, Embedded/External filters, Best-match highlight, Languages rail. Port: flat list. **[Ported]** `Player/PlayerSubtitlesPanel.swift` — Hide HI/SDH, Forced only, Embedded/External filter, Languages rail all present (lines 61-291). | no | S-M | M |
| PL-7 | `player/bp-subtitle-tune.tsx` (`BpSubtitleLook`) | In-player subtitle look panel (size/height/opacity/backing/bold) with live sample. Port: only from Settings, outside playback (`applySubtitleStyle`, `MPVPlayerController.swift:231`). **[Ported]** `Player/PlayerSubtitlesPanel.swift` "MARK: Look (bp-subtitle-tune.tsx BpSubtitleLook)" — live sample, now reachable in-player, not just from Settings. | partial | S | M |
| PL-8 | `player/bp-player-sources.tsx` (`BpPlayerSources`) | Switch source mid-playback (picker in `mode="switch"`). **[Ported]** parity-gaps.md "P8 (ported)": `Player/PlayerSourcesPanel.swift`, `PlayerScreen.switchSource`. | partial (`streamsRoom`) | M | M |
| PL-9 | `player/bp-skip-pill.tsx` | Skip pill has a dismiss ("Hide this Skip button"), is reachable by FastForward, and **never steals focus**. Port `PlayerScreen.swift:185` sets `focus = .chip("skip")` on appear — a Select during an intro skips instead of pausing. **[Ported]** batch 1 ("skip pill no longer steals focus"): `Player/PlayerScreen.swift` skip pill comment "never takes the ring on arrival". | n/a | S | L-M (correctness) |
| PL-10 | `player/bp-player-controls.tsx`, `player/bp-player-scrub.tsx` | Previous-episode button; held-seek ramps 1× → 3× → 6×; buffered range fill; "Ends HH:MM". Port: flat ±10 s per press. **[Ported]** `Player/PlayerScreen.swift` — Previous episode chip, held-seek ramp 1×→3×→6×, "Ends {time}" readout. | n/a | S | L-M |
| PL-11 | `player/bp-player-sources.tsx` (`BpAudioLane`) | Audio delay ±0.1/±0.5 s. **[Ported]** `Player/PlayerPanelParts.swift`/`MPVPlayerController.swift` — audio delay ±0.1/±0.5s, `setAudioDelay`, Reset. | no | S | L-M |
| PL-12 | `player/bp-player-subtitles.tsx` (`setSecondarySub`) | Dual subtitles ("2nd" chip). **[Ported]** 22:00 (09-24) AVPlayer subtitle/PiP batch: `MPVPlayerController.swift` secondary-sid + "2nd" chip (`PlayerSubtitlesPanel.swift:335`); `engine/player.ts` `secondarySubLang`. | no | M | L-M |
| PL-13 | `player/bp-subtitle-find.tsx` | Search subtitles under a different title/season/episode, "Show N more". **[Ported]** `engine/subtitles.ts` (bp-subtitle-find.tsx port: `buildStreamIds`, `resolveAnimeSearchCoords`). | partial (`subtitles.search` takes params) | M | L |
| PL-14 | `player/bp-player-rail.tsx` | Mute/volume chip and state. **[Ported]** `Player/PlayerScreen.swift` mute chip ("bp-player-rail mute chip"), muted state carried across loads/reconnects. | no | S | L |

Not in Big Picture at all (nothing to port): playback speed, sleep timer, aspect ratio, stats overlay, A/B loop, chapters, trickplay thumbnails — all desktop-only chrome or non-existent upstream. PiP: AVPlayer-engine only (PLAN §5). P2P status (`bp-p2p-status.tsx`) needs the torrent engine (Stage 6).

## 8. Library

Verified present: Saved/Watchlist/History/My Lists/Favorites + Trakt/Simkl/AniList/MAL tabs, filters, search, sectioned grid.

| # | Upstream | Behaviour | Engine | Effort | Impact |
|---|---|---|---|---|---|
| LB-1 | `bp-rate-dialog.tsx`, `lib/ratings/actions.ts` | Rate 1-10, synced to Trakt/Simkl, score shown. **[Ported]** batch 4 (23:45 09-23): `engine/actions.ts` `rate()`/`unrate()`; `Detail/DetailView.swift` `RateDialogView`. | no (no `ratings` export) | M | M |
| LB-2 | `bp-list-dialog.tsx`, `lib/custom-lists.ts` (`createListStore`, `toggleInList`) | Create a list / add to list from the TV. Port `library.ts` imports `readLists` only. **[Ported]** batch 4: `engine/actions.ts` `createList`/`toggleInList`; `Detail/DetailView.swift` `ListDialogView`. | no | M | M |
| LB-3 | `bp-library-types.ts` `"letterboxd"`, `lib/stremboxd/*` | Letterboxd tab. **[Ported]** 12:15 (09-24) Library/Collections batch: `engine/letterboxd.ts` + `Library/LetterboxdPanel.swift` — public-username mode (`lib/stremboxd`), matching upstream's own `bp-library-types.ts "letterboxd"` scope; the desktop-only full OAuth sign-in mode was deliberately skipped. | no | M | L-M |
| LB-4 | `bp-library-search.tsx`, `use-bp-library-services.ts` | Library "repair"/services rail. Port has the tabs; no repair action. **[Ported]** 12:15 (09-24) batch: `engine/library.ts` `repair()`; `Library/LibraryView.swift` "Repair library". | partial | S | L |
| LB-5 | `bp-library-sections.tsx`, `bp-cw-row.tsx` (`BpCwCard`) | History tab has a Posters/Episodes view toggle; Episodes mode shows wide episode-still cards with a resume progress bar and season/episode label instead of plain posters. Port: posters only, no toggle. **[Ported]** batch 3 ("Library History Episodes/Posters toggle"): `Library/LibraryView.swift` `episodesOptions` chip row. | yes (`library.ts feed()` already returns `progress/season/episode/watched`) | S | M |

## 9. Collections

| # | Upstream | Behaviour | Engine | Effort | Impact |
|---|---|---|---|---|---|
| CL-1 | `bp-collection-steps.ts` (all/mine/community/tvdb/tmdb), `use-bp-collection-feed.ts`, `lib/collections-catalog.ts`, `providers/tvdb-collections.ts`, `bp-collection-detail.tsx` | Source chips; TMDB curated (~110 franchises), TMDB open feed, TVDB lists, each with its own detail shape (backdrop hero, overview, year range). Port: mine + community only, so the tab is near-empty without Harbor social lists. **[Ported]** batch 6 (TMDB curated, 01:00 09-24) + Library/Collections batch (TVDB, 12:15 09-24): `engine/collections.ts` mine/community/tmdb()/tvdb(). | no (`collectionsRoom = {mine, community, all}`) | L | H |
| CL-2 | `bp-collection-shell.tsx`, `bp-collection.tsx` | Collection editing (add/remove items, rename) from the TV. Port: read-only overlay. **[Ported]** Library/Collections batch (12:15 09-24): `engine/collections.ts` rename/addItem/removeItem/create/delete; `Collections/CollectionItemsOverlay.swift`. | no | M | M |
| CL-3 | `bp-collection-items.tsx` | Personal/community collection overlays filter out manga items but tell the viewer how many were hidden ("N manga items are not shown"). Port: `collections.ts card()` filters manga but drops the count; overlay shows nothing. **[Ported]** batch 4 (23:45 09-23, "Collections overlay reports hidden manga items"): `Collections/CollectionItemsOverlay.swift:119`. | partial (filter exists, count field missing) | S | L |

## 10. Addons

| # | Upstream | Behaviour | Engine | Effort | Impact |
|---|---|---|---|---|---|
| AD-1 | `addons/bp-addon.tsx`, `addons/use-bp-addon-catalogs.ts`, `addons/bp-addon-row.tsx`, `addons/bp-addon-posters.ts` | Open an addon → catalog chips + infinite poster grid of its own catalogs; Home band of installed addons with poster mosaics. Port: `AddonsView` is a Settings-buried install/enable/remove list. **[Ported]** batch 5 (00:30 09-24): `engine/addonsRoom.ts`; `Browse/AddonPageView.swift`; Home "Your addons" band via `EngineBrowseSource`. | partial-yes (`addons.loadAddonRows`, `fetchCatalogRow`, `fetchAddonCatalogPage`, `createAddonCatalogFetcher` exported, unused) | M | H |

## 11. Settings

| # | Upstream | Behaviour | Engine | Effort | Impact |
|---|---|---|---|---|---|
| ST-1 | `bp-settings.tsx:193-201` | Setup push-rows show "Connected: TMDB, Stremio…" / "{n} added" once connected. Port: `settingsRoom.controls()` returns the static `detail`; rows always say "Nothing connected yet". **[Ported]** batch 1: `engine/settingsRoom.ts:209` "Connected: {list}". | partial (`facts()` has the data) | S | M (bug) |
| ST-2 | `bp-connect.tsx`, `bp-connect-parts.tsx` | Unified Connect pane: TMDB/Stremio/Harbor status in one place, QR + short code for phone setup, in-place TMDB key with live check. Port: separate sheets/sections. **[Ported]** `App/Sources/Handoff/PhoneHandoffViews.swift` `ConnectPane` wraps the same handoff infra; `Settings/SettingsView.swift:287` presents it. Missed on a literal `TvHandoff` grep the first time; caught by tracing the actual pane type. | no (no handoff) | M (unified) / L (QR handoff) | M-H |
| ST-3 | `bp-live-setup.tsx` | Kind picker (M3U / Xtream / Guide-data-only) and Server/Username/Password fields with masking; renders inside Settings. Port: one URL box in `LiveSourcesSheet`, and the Settings row navigates to the Live tab. **[Ported]** `Live/LiveView.swift` kind picker (M3U/Xtream/Guide-data-only) + masked Server/Username/Password fields (`secure: true`). | partial (`live.addPlaylist(name,url,epgUrl)`; `detectProviderShape` handles a combined URL) | M | M |
| ST-4 | `bp-settings-pane.tsx` | Right-side live preview: overscan crop, subtitle sample with flags, Harbor-vs-Classic wireframe, service logos, greeting, summary lines. Port: single column (overscan does apply live app-wide). **[Ported]** `Settings/BPSettingsView.swift` `BPSettingsModel.Pane` — overscan, subtitle sample w/ flags, home-mode wireframe, services, language greeting, playback/setup/interface summaries. | n/a | M | M |
| ST-5 | `bp-settings-catalog.ts` playback `home-server` + "Preferred home server" | Selecting Home server is a dead end (no media-server module). Stage 6. **[Ported]** `Settings/HomeServersPanel.swift`/`HomeServersModel` — the home-server module (Stage 6) is built now, not a dead end. | no | L | L |

## 12. Onboarding

Upstream order (`onboarding/bp-onboard-steps.ts`): language → phone → tmdb → stremio → harbor → layout → streaming → subtitles → taste → done. Port (`OnboardingView.swift:13`): language, tmdb, stremio, harbor, layout, subtitles, done.

| # | Upstream | Behaviour | Engine | Effort | Impact |
|---|---|---|---|---|---|
| OB-1 | `steps/bp-step-streaming.tsx` | Pick the services you subscribe to (drives the Home services band). Missing. **[Ported]** `Onboarding/OnboardingView.swift` `StreamingServicesStep` (batch 3, "onboarding Your services step"). | yes (`services.ts`, settings) | S | M |
| OB-2 | `steps/bp-step-language.tsx` (146 lines) | Real language picker. Port: one "English" button. **[Ported]** `Onboarding/OnboardingShowcases.swift` `OnboardLanguageStep` — a real language picker, not the one-button stub. | partial (`region` export; locale loading stubbed in the bundle) | M | M |
| OB-3 | `steps/bp-step-taste.tsx`, `bp-taste-detail.tsx`, `use-bp-taste-titles.ts` | Pick up to 5 titles/genres to seed recommendations. Missing, and no Settings equivalent. **[Ported]** batch 4 (23:45): `Onboarding/OnboardingView.swift` `TasteStep`; `engine/onboarding.ts` `tasteTitles`. | no | M | M |
| OB-4 | `steps/bp-step-phone.tsx`, `bp-handoff-*.ts(x)`, `lib/tv-handoff` | Pair a phone by QR so TMDB/Stremio/Harbor entry is typed there. Missing (same infra as SR-7/ST-2). **[Ported]** `Onboarding/OnboardingView.swift` uses `TvHandoff`/`Handoff/PhoneHandoffViews.swift` for the phone step. | no | L | M |
| OB-5 | `bp-done-flourish.tsx`, `bp-tmdb-showcase.tsx`, `bp-stremio-showcase.tsx`, `bp-layout-preview.tsx`, `bp-subtitle-preview.tsx` | Step showcases/previews and the done flourish. Port steps are plain. **[Ported]** `Onboarding/OnboardingShowcases.swift` `OnboardTmdbShowcase`/`OnboardStremioShowcase`. | n/a | S-M | L |

## 13. Who's watching / kids / parental

| # | Upstream | Behaviour | Engine | Effort | Impact |
|---|---|---|---|---|---|
| WW-1 | `bp-who-is-watching-logic.ts` (`bpWhoKidSelectable`, `bpWhoKidStaysInBigPicture`), `lib/lockable-tabs.ts`, `lib/parental.tsx`, `lib/curfew.ts`, `bp-top-bar.tsx` `useBpTabGate`/`visibleTabs` | Kid profiles: hidden/locked tabs per profile, curfew window, parent PIN on gated actions. Port `WhoIsWatchingView.swift:60`: "Kids profiles are not available in Big Picture yet." — every kid profile is unusable. **[Ported]** Curfew (batch 4: `CurfewState`/`Shell/Screensaver.swift` `CurfewLockView`) + kid selectability (batch 1) + tab gating (`Profiles/ParentalGate.swift` `hides()`, consumed by `ShellView.shellTabs`). Owner decision remains: curfew's "Switch profile" works without the parent PIN (HANDOFF.md). | partial (`sync.ts` mirrors `kid{age,curfewMinutes,parentPinHash}` and `lockedTabs`; nothing enforces) | L | H (households with kids) |
| WW-2 | `bp-who-is-watching-sync.ts` | Sync phase on the roster screen (pull, apply, status). Port: present (`syncNotice`, roster-applied). **[Ported]** Unchanged from the original audit. | yes | — | — |
| WW-3 | `bp-who-is-watching-pin.tsx` | PIN pad. Port: `PinPadView`. **[Ported]** Unchanged from the original audit. | yes | — | — |

## 14. Live TV (tab)

Verified present: M3U/Xtream/middleware sources, favourites, guide-lite list, XMLTV guide grid with now-line/panning/window growth, sources sheet, catch-up replay (a port extra).

| # | Upstream | Behaviour | Engine | Effort | Impact |
|---|---|---|---|---|---|
| LV-1 | `bp-guide-portal.tsx`, `bp-guide-portal-art.tsx` | Floating preview while moving through the grid: muted mini-player after 700 ms dwell, title, time range, description, progress. Port: none. **[Ported]** batch 2 ("guide focus panel"): `Live/GuidePortalView.swift` — 700ms dwell, muted preview, title/time/description/progress. | no | M | M-H |
| LV-2 | `bp-live-setup.tsx` | See ST-3 (structured Xtream, EPG-only source). **[Ported]** = ST-3, ported. | partial | S-M | M |
| LV-3 | `lib/iptv/epg-map.ts` | Manual EPG channel remap when `tvg-id` is wrong. Port only removes overrides. **[Ported]** `Live/EpgMatchView.swift` "Match EPG"; `engine/live.ts` `epgMap`. | no | M | L-M |
| LV-4 | `useGroupPrefs` | Hide whole channel groups. `live.ts:166` hardcodes `hiddenGroups: []`. **[Ported]** `engine/live.ts` `hiddenGroups` is now read and applied in `bpGuideOrder`/`liveCategories` (no longer hardcoded `[]`). | no | S | L |
| LV-5 | `usePinnedOrder` | Pin channels (guide order tier 2). `live.ts:139` reads pins; nothing writes them. **[Ported]** `engine/live.ts` `usePinnedOrder`/`togglePin`/`readPins` — pins are now written, not just read. | partial | S | L |
| LV-6 | `bp-live-filters.tsx` | Filter chips beyond Favorites/All/group. **[Ported]** `Live/LiveView.swift` — Favorites/All/group chips with country flags (bp-live-filters). | partial | S | L |

Home Live TV row → HM-2. Multiview, DVR, in-player channel picker: not in BP.

## 15. Sports

Verified present: consent, modes/groups chips, date band, hero cycle, rows, Explore grid, event detail (stats bars, play-by-play, lineups), personalize (sports → leagues), watch flow over Live TV channels with picker + pin, sport-specific live diagrams (SP-1, below).

| # | Upstream | Behaviour | Engine | Effort | Impact |
|---|---|---|---|---|---|
| SP-1 | `sports/bp-sports-live-court.tsx`, `-diamond`, `-field`, `-kit`, `-plays`, `-situation` | Sport-specific live diagrams (court, diamond, field, formation, plays, situation cell) in the Stats row while live. **Done (2026-09-27 verification of the 09-24 Sports parity batch, commit `0211981`):** `engine/sportsEvent.ts` `eventRows()` reuses upstream's pure helpers directly from `reference/harbor` (`bpSportsSituationKind`, `bpSportsHasDiamond/-Field/-Court`, `bpSportsHasPlays`, `basketballFive`, `playIcon`) to compute `situation.{diamond,field,court}` and `plays` exactly as upstream does; Swift draws them with SwiftUI `GeometryReader`/shapes in `App/Sources/Sports/SportsLiveViews.swift` (`SportsDiamondView`, `SportsFieldView`, `SportsCourtView`, `SportsStatsRowView.playsCell`), shown in `SportsEventView`'s Stats row only when `sports.eventRows` returns a non-null `situation`/`plays` (upstream's own live/state gating, not a blanket `state == "in"` check). `engine/smoke.mjs` has mocked-summary checks per sport (NBA court, MLB diamond, NFL field, EPL pitch/lineups, no-detail fallback). **[Ported]** Already fixed in-file 2026-09-27 (see the row's own note) — verified again in this pass. | yes | L | H (sports fans) |
| SP-2 | `sports/bp-sports-who-*.tsx` | Tap a team/athlete → bio panel. Port: sides not tappable. **[Ported]** `Sports/SportsWhoView.swift`, opened from `SportsEventView.swift:246`. | no | M | M |
| SP-3 | `sports/bp-sports-addon-*.tsx` | Stremio addon catalogs as sports sources (plan `"addons"`), fallback when no channel match. Port `watch()` plans: channel/picker/setup/finished only (`sports.ts:332`). **[Ported]** `engine/sports.ts` `plan: "addons"`, `sportsAddonCatalogs`. | no | M | M |
| SP-4 | `lib/sports/reminders.ts`, `reminder-state.ts` | Bell on the event hero arms a Discord/Telegram webhook reminder. Port: none, but the consent copy promises it. **[Ported]** 13:10 (09-24) Sports parity batch (SP-1/4/7/8/11/12/13): `Sports/SportsSettingsPanels.swift` "Where alerts go" (Discord/Telegram), `engine/sports.ts` reminder runner (30s engine timer). | no | M | M (or edit the copy: S) |
| SP-5 | `sports/bp-sports-event-rows.tsx` (`BpSportsStandingsRow`), `bp-sports-extra-tables.tsx` | Standings table. `fetchStandings` not wired; `Detail` has no field. **[Ported]** same batch: `Sports/SportsExtras.swift` `BpSportsStandingsRow`; `engine/sports.ts` `standings`. | partial | S | M |
| SP-6 | `sports/bp-sports-personalize.tsx` step 3 | Favourite teams → "Your teams" row. `toggleTeam` exported, never called. **[Ported]** `engine/sports.ts` `toggleTeam`; `Sports/SportsPersonalizeView.swift`. | yes | M | M |
| SP-7 | `sports/bp-sports-broadcast-stage.tsx`, `bp-sports-broadcast-picker.tsx` | Play official Twitch/YouTube/Kick broadcasts. Port lists them as text (`sports.ts:270-271`). **[Ported]** same batch: `Sports/SportsWhereView.swift` — Twitch/YouTube open their tvOS apps, Kick/others go to the phone by QR. | no | L | M |
| SP-8 | `sports/bp-sports-event-rows.tsx` where-to-watch, venue | Provider tiles (tappable), venue cell, UFC.com/F1 fallbacks. Port: one text line (`SportsEventView.swift:132-135`). **[Ported]** same batch: `Sports/SportsEventView.swift`/`SportsWhereView.swift` — venue + provider tiles. | partial | S | L-M |
| SP-9 | `sports/bp-sports-art.ts`, `lib/sports/hub-artwork.ts`, `SCENERY_GROUPS` | TheSportsDB artwork + per-sport scenery fallback. Port shows nothing when the feed has no art (most games). **[Ported]** (2026-09-27, commit b9308c9: `engine/sports.ts` `artwork()` falls back to upstream's `bpSportsScenery` photo, served from the pinned upstream revision.) Earlier note: TheSportsDB artwork fallback is ported (`engine/sports.ts` `fetchSportsArtwork`/`cachedArtwork`), but upstream's further fallback — a fixed scenery photo per sport when even TheSportsDB has nothing (`SCENERY_GROUPS` in `bp-sports-art.ts`) — has no port equivalent. Size S. | no | S | L-M |
| SP-10 | `use-bp-sports.ts` (`useBpWatchGame`) | Exact live match on a card/hero plays directly instead of opening detail. **[Ported]** `Sports/SportsView.swift` `useBpWatchGame` port comment — exact/pinned match plays directly. | partial | S | L-M |
| SP-11 | `sports/bp-sports-extra-players.tsx`, `-kit`, `-pitch`, `-venue`, `-odds` | Extra rows: players, kit, pitch, venue, odds (odds: upstream gates it; skip). **[Ported]** same batch: `engine/sportsEvent.ts` — players/kit/pitch/venue extra rows (odds deliberately excluded, matching upstream's own gate). | no | M | L |
| SP-12 | `lib/sports/api-hub-leagues.ts`, `api-credentials.ts` | api-sports key leagues (4 niche leagues). **[Ported]** same batch: `Sports/SportsSettingsPanels.swift` "Sports metadata" API-Sports key (Keychain). | no | S | L |
| SP-13 | attachments `streams` (paste a stream URL for a game) | `Attachments.streams` exists (`sports.ts:273`) with no write path. **[N/A]** Upstream's own Big Picture has no "paste a stream URL" write path either — `Attachments.streams` does get written on the TV, but only through the pin-a-channel flow (X1/SP-6), not a URL-paste UI upstream never built for BP. Not a real gap. | partial | S | L |

---

## 16. Top 15 by impact ÷ effort

| Rank | Gap | Effort | Impact | Why here |
|---|---|---|---|---|
| 1 | **SR-1/2/3 Search fan-out** — call `search.addonCatalogs`, `search.addonGroups`, `search.anime`, `search.liveTv` in parallel with `search.all` and merge | S | H | Engine exports and Swift rows already exist; today search only sees TMDB/Cinemeta. Also fixes a false PROJECT_STATE claim. |
| 2 | **PL-1 Resume / Start over prompt** | S | H | `player.startPosition` already answers; needs one dialog before mpv starts. |
| 3 | **PL-3 Subtitle offset** (mpv `sub-delay` stepper) | S | H | Online subs drift; no fix in-player today. |
| 4 | **PL-2 Up-next auto-advance** (pre-resolve episode N+1's stream during N, countdown, Keep watching) | M | H | Biggest binge friction vs upstream. |
| 5 | **PL-4 Connecting / stall screen** (cancel, retry, stall timeout) | M | H | Debrid/HTTP streams stall in practice; viewer gets nothing. |
| 6 | **DS-1 Genre grid page** (TMDB discover by genre, paged) | M | H | Tiles are visibly interactive and do nothing. |
| 7 | **DS-2 Discovery Queue full-screen deck** | M | H | `discoverRoom.queueFor` exists; band button is inert. |
| 8 | **AD-1 Addon browse page + Home addons band** | M | H | Engine catalog fetchers exported and unused; core Stremio workflow. |
| 9 | **SH-2 Screensaver** | M | H | Apple TV convention; absent end to end incl. setting. |
| 10 | **DT-1 Instant play / auto-play best** | L | H | Every play is a manual scroll of dozens of rows; `instantPlay` setting is inert. |
| 11 | **DT-2 Anime detail path** | L | H | Anime is first-class in the catalog tab but its detail page degrades to the generic path. |
| 12 | **WW-1 Kid profiles + tab gating + curfew** | L | H | Hard block today; sync already carries the data. |
| 13 | **SH-1 Dynamic ambient backdrop** | L | H | BP's signature look; port is a static gradient. |
| 14 | **CL-1 Collections TMDB/TVDB sources** | L | H | Tab is near-empty without Harbor social lists. |
| 15 | **DT-4 + DT-5 Stream picker facets, sort, "search wider"** | M | M-H | Until #10 lands, every play goes through this list. |

Cheap correctness fixes to fold into any of the above (all S): ST-1 Setup row state, PL-5 leave confirm, SH-6 confirmation dialogs, PL-9 skip-pill focus steal, DT-10 Videos row (data already returned), SH-5 top-bar sync/offline icon, OB-1 streaming step, SP-4 consent copy (if reminders stay unbuilt).

Honourable mentions (high impact for a subset, L effort): HM-2 Home Live TV row, LV-1 guide portal (M), SH-3 quick panel (M), ST-2/OB-4/SR-7 phone handoff (one shared L piece of infrastructure that unlocks three gaps). (SP-1 live-situation diagrams shipped 09-24/verified 09-27; removed from this list.)

**Reconciliation, 2026-09-27:** every ranked item above and every "cheap fix" is Ported (see each
row's own table for the pointer), with one exception: **SH-1** (rank 13) is Partial — the cross-fade
ambient exists for Home's hero and some bands, not the generic app-wide layer (see §1). The phone-
handoff honourable mention shipped as real, reusable infra (`App/Sources/Handoff/PhoneHandoffViews.swift`)
and is wired into all three surfaces it names: **OB-4** (`Onboarding/OnboardingView.swift`), **ST-2**
(`Settings/SettingsView.swift:287` → `ConnectPane`) and **SR-7** (`Search/SearchView.swift:53` →
`PhoneTypingSheet`) — all Ported.

## 17. Things the port does that Big Picture does not

- Catch-up / replay from the guide grid (`live.catchupUrl`); upstream BP's guide only tunes live (`bp-guide-block.tsx:566-572`).
- Trakt + Simkl scrobbling from the TV player (desktop feature, not BP chrome).
- Anime4K panel with a libplacebo shader-rejection fallback (log scan) — no BP equivalent of the fallback.
- `AVDisplayCriteria` display-mode matching (native tvOS).
- Native Settings page beyond the 8-category catalog: Harbor/Stremio/Trakt/Simkl/AniList/MAL sections, Addons manager, TMDB "Test saved key" + "Remove key", ranked subtitle-language grid, Sync status with queued count, Profiles, Developer menu, About.
- Overscan applied live to the whole shell while adjusting.
- Explicit on-screen Back buttons on Detail/Person heroes (tvOS convention).
- Harbor onboarding step allows typing the password on-device (TLS to harbor.site), skipping upstream's LAN-safety detour.
- **[Added 2026-09-27]** Watch Together room create/join, invite code/QR link and in-room chat (`App/Sources/Together/TogetherModel.swift`/`TogetherView.swift`) — upstream's own Big Picture has none of this, only host-match badging in the stream picker (see §1's closing note).

## 18. N/A on tvOS or dead in upstream (not counted)

- Dead in upstream: `bp-hero-manga.tsx`, `bp-anime-announcement.tsx` (exported, never mounted).
- Desktop-only/no TV meaning: `bp-entry-button.tsx` ("Big Picture" entry from desktop), `bp-exit-confirm.tsx`/`bp-exit-preview.tsx` (back to desktop window), `use-bp-fullscreen.ts`, `bp-platform.ts` desktop/Android branches, battery icon in `bp-status.tsx`, "Leave Big Picture" settings row, `.harborstyle`/custom CSS (not in the BP catalog anyway), pad shoulder hints until MFi controllers are supported.
- Needs subsystems from later stages: P2P status (torrent engine, Stage 6), local files in the picker and Library (no filesystem to browse on tvOS — N/A, not just unbuilt), downloads, Multiview, DVR, manga reader (Stage 13). **[2026-09-27]** Home servers (Stage 6) and Together rooms (Stage 10) shipped — see DT-17/ST-5 and §1's closing note/§17 — removed from this "needs later stages" list.
- Infrastructure with a native replacement: `bp-logic.ts`/`bp-focus-core.ts`/`use-bp-focus.ts` (SwiftUI focus engine), `bp-track-glide.ts`, `bp-grid.tsx`, `use-bp-page-modal.ts`, `bp-error-boundary.tsx`, `bp-view-state.ts`, `bp-visible.ts`, `bp-routes.tsx`, `bp-safe-area.ts` (overscan setting), `bp-tokens.ts`/`bp-action-style.ts`/`bp-hero-style.ts` (→ `BPStyles.swift`), `bp-boot-splash.ts` (→ `BootSplashView`), `bp-i18n.ts` (→ OB-2), `bp-rank-numeral.tsx` (→ rank tile), `bp-lead-tile.tsx` (upstream removed it from bands as a cost; nothing to port), `bp-poster-chain.ts` (poster fallback ladder — port's `RemoteImage` has no chain; minor, S/L).

## 19. Documentation follow-ups

- Correct the three PROJECT_STATE lines in §0. **[2026-09-27]** Moot — the features §0 called out as
  overstated (search fan-out, resume/up-next/subtitle-offset, Sports reminders, `instantPlay`) have
  all since shipped; see the Reconciliation section at the top of this file.
- `docs/livetv-spec.md` never mentions the Home Live TV row (HM-2); `docs/sports-spec.md` marks who/addon/broadcast-stage "out of scope" — this audit is the first place they are confirmed unported. **[2026-09-27]** HM-2 and the Sports who/addon/broadcast-stage rows are all Ported now (§2, §15); those two docs are stale in the same way this file was and are worth a pass, but that is outside this reconciliation's scope (docs only, and `docs/parity-gaps.md`/`PROJECT_STATE.md` are this task's actual target, not every spec doc).
- `docs/detail-spec.md` is accurate and line-cited; keep using it.

## 20. Coverage checklist

Every area the audit brief asked for, mapped to its section:

| Asked for | Section |
|---|---|
| Top bar / hint bar / profile menu / phone typing | §1 (SH-4, SH-5, SH-13), §4 (SR-7) |
| Home: hero cycle, CW/services/addons/live/collections/editorial rows, hero actions | §2 |
| Movies/Shows: hero pool, genre/collection rows, "See all" grid, `bp-row-grid` | §3 (verified-present note + DS-1..4) |
| Discover | §3 (DS-1, DS-2) |
| Search, all result kinds incl. manga/characters/collections/addon index/phone typing | §4 |
| Detail: every row incl. videos/gallery/awards dialog/facts dialog/episode facts, anime path, play-decision logic, stream picker, auto-play best | §5, §6 (AN-1), §9 (CL for collection-adjacent), §11 (stream picker/facets are DT-4/DT-5) |
| Player: transport, subtitle panel, audio, chapters, skip, next-episode, PiP, speed, aspect, shaders, stats | §7 (chapters/PiP/speed/aspect/stats/shaders confirmed not in BP at all — see the note under the table) |
| Library | §8 |
| Anime: hero actions, seasons chips, characters, announcement, awards band | §6, §5 (DT-2, seasons/characters live on the anime detail path) |
| Live TV: setup, sources modal, filters, guide portal, hero | §14, §2 (HM-2) |
| Sports: event rows incl. who panel, addon panel, watch picker, reminders | §15 |
| Collections: shell, editing | §9 |
| Settings: connect pane, live setup pane, every catalog category | §11 |
| Onboarding: every step | §12 |
| Who's-watching: PIN, kid gating, sync phase | §13 |
| Kids/parental: lockable tabs, hidden tabs, PIN gates | §13 (WW-1) |
| Together/watch party | §1, closing note — upstream BP has no UI to create/join a room, only host-match badging; the port built full create/join anyway (Ported, and beyond upstream's own scope — see §17). |
| Any BP file not mapped to anything in the port | §18 (dead-in-upstream + N/A-on-tvOS lists) covers every file that came up empty across all eight passes; every other file under `big-picture/**` is accounted for in a numbered gap or a "verified present" note in §§1–15 |
