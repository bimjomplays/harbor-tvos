# Big Picture parity audit — 2026-09-23

"What Big Picture does that the TV app does not yet." Upstream = `reference/harbor/src/views/big-picture/**` at `1bfcfb6` (read-only). Port = `App/Sources/**` (SwiftUI) + `engine/*.ts` (upstream logic in JavaScriptCore; `engine/entry.ts` is the list of what Swift can call).

Method: seven read-only research passes (one per area) read every BP file in their slice, then grepped the port for an equivalent (Swift views, `entry.ts` exports, glue files). The load-bearing claims that contradict `PROJECT_STATE.md` were re-verified by hand (see "Corrections" below). No files were edited other than this one.

Fields per gap: **Upstream** file(s) · **Behaviour** (user-visible) · **Engine** = is the data/logic already in the bundle (yes / partial / no, with the export or "not found") · **Effort** S/M/L · **Impact** for a TV viewer H/M/L.

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
| SH-1 | `bp-ambient.tsx`, `bp-ambient-layers.tsx`, `bp-art*.ts`, `bp-backdrop-commit.ts` | Background cross-fades to the focused title's own art with glow tint and slow motion — BP's signature look. Port: `Theme.swift` `BPAmbientBackground` is a static gradient on every screen. | no (`grep ambient engine/` → 0) | L | H |
| SH-2 | `bp-screensaver.tsx`, `use-bp-screensaver.ts` | Idle-triggered art cycler (title/subtitle per item), delay set in Settings, suppressed during playback. Port: nothing; no setting either. | no | M | H |
| SH-3 | `bp-quick-panel.tsx`, `bp-focus-meta.ts` | Y-button / long-press overlay on the focused tile: play, watchlist, hide from CW, sound, sign-out. Port: none; actions only via Detail. | n/a (uses existing cards/watchlist) | M | M-H |
| SH-4 | `bp-hint-bar.tsx` | Hints change per surface and input (select/back/search/type/clear/toggle/phone/tabs/nav/advance). Port: `ShellView.hints` is a hardcoded `[("OK","Select"),("Menu","Back")]`. | n/a | S-M | M |
| SH-5 | `bp-status.tsx` in `bp-top-bar.tsx` | Persistent Wifi/WifiOff + CloudOff (stale sync) icon by the clock. Port: `TopBarView` has none; sync failure only shows on Who's Watching. | yes (`sync.status`) | S | M |
| SH-6 | `bp-confirm.tsx` (and `bp-exit-confirm.tsx` pattern) | Yes/No dialog before destructive actions. Port: `grep -rE "\.alert\(|confirmationDialog" App/Sources` → 0; profile delete is unconfirmed. | n/a | S | M |
| SH-7 | `bp-intro.tsx`, `bp-intro-pool.ts`, `use-bp-intro.ts` | Animated poster-wall "front door" after boot splash. Port: `RootView` goes boot → onboarding/who's-watching. | n/a | M | L-M |
| SH-8 | `bp-restore.ts` | Focus/scroll position remembered per route and row when returning. Port: relies on SwiftUI identity only. | n/a | S-M | L-M |
| SH-9 | `use-bp-sound.ts`, `lib/sfx` | UI sound theme (Off/Glass/Modern/Cinematic/Retro). Port: no SFX at all, yet Settings → Interface → Sound commits `bigPictureSound` (`settingsRoom.ts:76`) — a dead control. Also audition-on-focus (`bp-settings.tsx onCellFocus`). | partial (setting only) | S-M | L |
| SH-10 | `bp-controller-toast.tsx` | Toast on game-controller connect/disconnect. | n/a | S | L |
| SH-11 | `bp-hero-pips.tsx` | Position pips under the Home hero cycle. Port: none. | n/a | S | L |
| SH-12 | `use-bp-hero-cycle.ts:13-25` | Hero cycle stops under reduced-motion. Port: `BrowseModel.startHeroCycle` ignores `UIAccessibility.isReduceMotionEnabled`. | n/a | S | L |
| SH-13 | `bp-profile-menu.tsx`, `bp-status-dialog.tsx` | Profile / tracker status from the top bar. Port: moved to Settings (`SettingsView`, `PasteTrackerView`). Surface moved, not missing. | yes | — | — |

Phone typing (`bp-phone-typing.tsx`) is under Search (SR-7). Together/watch party: BP wraps the tree in `TogetherProvider` and badges host-matching streams in the picker, but **there is no BP UI to create or join a room**; the port has zero Together references. Not ranked.

## 2. Home

| # | Upstream | Behaviour | Engine | Effort | Impact |
|---|---|---|---|---|---|
| HM-1 | `bp-home.tsx:186,225-246`, `addons/bp-addon-row.tsx`, `bp-collections-row.tsx` | "Your addons" band (one wide card per installed addon → addon page) and a curated "Collections" row between the catalog rows. Port: addon catalogs are merged into ordinary rows via upstream's fallback merge (`EngineBrowseSource.swift:51-53` says so). | partial (`addons.loadAddonRows`, `fetchAddonCatalogPage` exported; no curated collections source) | M | M |
| HM-2 | `bp-home.tsx:188-205`, `bp-live-row.tsx`, `bp-live-cell.tsx`, `bp-live-hero.tsx`, `bp-live-rank.ts`, `bp-live-band-art.ts`, `bp-live-split.tsx` | Ranked Live TV row on Home (junk-name filter, favourite/most-watched/network boost), ambient muted video preview behind the row when a channel is focused, split band-art tiles. Port: none. | no (`rankBpLive`, `bpCleanChannelName` not found) | L | H (IPTV users) |
| HM-3 | `bp-cw-row.tsx`, `bp-cw-card-meta.tsx`, `lib/feed/external-cw.ts` | CW card extras: watched check, "+N new episodes" pill, source glyph (Trakt/Simkl/clock/play), watcher avatar, "Up Next"/waiting-for-air/next-episode title. Trakt/Simkl "currently watching" merged into CW. Port `ContinueCardView`: backdrop, logo, `S E`/`% left` pill, progress only; `rooms.ts continueWatching` merges cloud+local only. | partial | M | M |
| HM-4 | `bp-spotlight.tsx:101-157`, `bp-score-chips.tsx`, `bp-hero-award-marks.tsx` | Hero provider-badge mark, awards corner overlay, multi-provider score chips (IMDb/MAL/TMDB/Simkl/RT/MC/Letterboxd/MDBList/Trakt, each gated). Port `SpotlightView.swift:20-24`: single TMDB-or-IMDb chip. | partial | S (badge+corner) / L (providers) | M |
| HM-5 | `bp-mosaic.tsx` | Drifting poster collage behind bands without focused art. | n/a | M | L |

Hero actions: BP's Home spotlight is a pure display surface (no buttons), same as the port — not a gap. Verified present: hero pool (row 0, first 8), 7 s cycle with focus pause, services band at slot 2, Top-10 ribbon, card-mark chip chain, network rows, `MIN_ROW_METAS`/`VISIBLE_ROWS` dedup.

## 3. Movies / Shows / Discover / genre grid / See-all grid

Verified present: separate Movies and Shows tabs (`AppModel.Room`), Top-10 row, TMDB-vs-Cinemeta fallback, genre/collection catalog rows, "See all" grid (`CatalogPageView`, paginated via `rooms.page` / `services.page` / `animeRoom.specPage`), Awards band + award detail, People band, genre-tile art on focus.

| # | Upstream | Behaviour | Engine | Effort | Impact |
|---|---|---|---|---|---|
| DS-1 | `use-bp-genre-grid.ts`, `bp-genre-grid.tsx` | Selecting a genre tile opens a paginated TMDB-discover poster grid (`with_genres`, `vote_count.gte 180`, popularity). Port: `DiscoverView.swift:136` tile is `Button {}` — inert. | no (`discover.ts` has only `genres()`/`genreArt()`) | M | H |
| DS-2 | `queue/bp-queue.tsx`, `queue/use-bp-queue.ts`, `queue/bp-queue-band.tsx` | Discovery Queue: full-screen one-card-at-a-time deck with skip-for-now / never-show, daily-seeded order, low-water refill. Port: preview band only; `DiscoverView.swift:69` `Button {}` is inert. | yes, unwired (`discoverRoom.queueFor` exported, never called) | M | H |
| DS-3 | `bp-award-tiles.tsx:153`, `bp-anime-awards.tsx` | Anime award tiles in the Awards band open the anime award overlay (year filter "All years", "Grand" winners, "No data shipped"). Port: award detail is the classic-awards shape only (`discover.ts:139`); no anime award source. | partial (bundled anime index used in `animeRoom.ts`) | S-M | L-M |
| DS-4 | `use-bp-movies.ts` `useBpLetterboxdRows` | Letterboxd rows on Movies. | no | M | L (needs Letterboxd account, see LB-3) |

## 4. Search

| # | Upstream | Behaviour | Engine | Effort | Impact |
|---|---|---|---|---|---|
| SR-1 | `lib/search-addons.ts`, `lib/search-context.tsx`, `bp-search-rows.tsx` | Addon catalog hits fused into Movies/Series plus one "From <Addon>" row per addon that answers (pending/ok/empty/failed, retry). Port: never fetched (see §0). | yes (`search.addonCatalogs`, `search.addonGroups`) | S | H |
| SR-2 | `lib/search.ts searchAnime` | Anime results (AniList + Jikan + Kitsu fusion). Port decodes `anime` and has a row, never calls it. | yes (`search.anime`) | S | M-H |
| SR-3 | `lib/search.ts searchLiveTvChannels`, `BpChannelCell` | Live TV channel hits, tunable from search. Port has `channelRow` UI that can never populate. | yes (`search.liveTv`) | S | M |
| SR-4 | `use-bp-search.ts`, `bp-search.tsx` | Kind chips (All/Movies/Series/People/Anime/Manga/Live TV/Collections/Franchise/Addons) with counts. | n/a | S | L (grows with SR-1..3) |
| SR-5 | `lib/providers/tvdb-collections.ts`, `use-collection-hits.ts` | Collection/franchise banner hits in results. | no | M | L-M |
| SR-6 | `lib/anilist/character.ts` | Character search → every anime/manga featuring them. | no | M | L |
| SR-7 | `bp-phone-typing.tsx`, `lib/tv-handoff/*` | QR → phone types into the TV over LAN (also used by Connect and onboarding "phone" step). Port: on-screen `BPKeyboardView` only (a faithful `bp-keyboard.tsx` port). | no | L | M |
| SR-8 | `lib/search-addon-index.ts` | "Addons you could install" hits. | no | S-M | L |
| SR-9 | `lib/search.ts searchManga` | Manga results. Zero manga surface in the port; needs a reader to be useful. | no | M | L |

## 5. Detail page

| # | Upstream | Behaviour | Engine | Effort | Impact |
|---|---|---|---|---|---|
| DT-1 | `bp-detail.tsx:140-159`, `use-bp-stream-play.ts`, `views/play-picker/use-auto-candidates.ts`, `use-auto-fire.ts`, `bp-stream-steps.tsx` (`BpAutoStep`) | With `instantPlay` (default on) Play skips the picker and fires the best cached/instant stream, "Trying source N…" screen, falls through candidates on failure. Port: Play always opens `PlayPickerView`; `instantPlay` unread. | no (ranking exists in `streams.ts`; no candidate/settle/auto-fire logic) | L | H |
| DT-2 | `use-bp-anime-detail.ts`, `bp-anime-seasons.tsx`, `bp-anime-season-chip.tsx`, `bp-anime-characters.tsx`, `bp-episode-ids.ts`, `use-bp-trackers.ts` | Anime detail: kitsu/mal/anilist ids → aired/absolute/TVDB episode order, season/cour chips with arc names and year ranges, filler tags, sub/dub badge, Characters row, canonical ids for tracker writes, resume from Simkl/AniList/MAL progress. Port: `DetailModel` always takes the Cinemeta + TMDB path. | no (`animeRoom.ts` serves the catalog tab only) | L | H |
| DT-3 | `use-bp-detail-actions.ts`, `bp-detail-actions.tsx` | Hero actions beyond Play/Watchlist: tracker status (AniList/MAL), Mark watched (+ on Trakt), Favourite, Remind me (upcoming), Rate this, Add to list, Watch trailer. Port `DetailView.swift:134-138`: Play + Watchlist only. | partial (`trakt`/`simkl`/`anilist`/`mal` glue exist; no ratings/lists/favourites/reminder exports) | M | M-H |
| DT-4 | `bp-stream-chips.tsx`, `bp-stream-filters.ts`, `bp-stream-menu.tsx` | Picker facets (HDR, codec, source, audio, edition, remux), addon-grouping menu, saved custom filters, preferred-language chip, sort toggle (Harbor pick vs addon order), Clear filters, Refresh. Port: quality/Cached/addon-name chips only. | partial (fields are in `ScoredStream`; no facet/sort API) | M | M-H |
| DT-5 | `use-bp-streams.ts` (`strictMode`, `forceShowAll`, `searchWider`, `showEverything`) | "Search wider" / "Show everything" ladder when filters leave nothing. Port passes empty opts and has no loosen UI. | yes (`streamsRoom.search` takes `{strictMode, filterDisabled}`) | S | L-M |
| DT-6 | `use-bp-streams.ts` (`rememberedStream`, `sourceEntry`), `bp-stream-row.tsx` "Played last" | Last-played / season-locked source pinned to the top and badged. | no | M | M |
| DT-7 | `bp-stream-dialogs.tsx` (`BpP2pDialog`, `BpDebridDownDialog`, `BpNoSourcesDialog`, `BpAutoExhaustedDialog`) | Consent before uncached P2P, debrid-down retry screen, "tried N sources" screen. Port: one generic error string in `PlayPickerView.pick()`. | partial (`streamsRoom.resolve` returns ok/code) | S-M | M |
| DT-8 | `bp-score-chips.tsx`, `use-bp-card-badges.ts` | Multi-provider score chips in the hero (each gated by `showXDetail`). Port `DetailView.swift:108-113`: Cinemeta `imdbRating` only. | no | M | M |
| DT-9 | `detail/bp-awards-row.tsx`, `detail/bp-award-detail-dialog.tsx` | Award-body marks with win/nomination counts → per-award dialog of categories and years. Port: none (plumbing exists in `personRoom.ts` and Discover). | no for titles (`grep award detailRoom.ts` → 0) | M | M |
| DT-10 | `detail/bp-videos-row.tsx` | Trailers/clips/featurettes row. Port: `detailRoom.extras` already returns `videos` (14), `DetailModel.Extras` drops the field. Playback is best-effort on tvOS (no yt-dlp). | yes | S (row) / M (playback) | M |
| DT-11 | `detail/use-bp-episode-facts.ts`, `detail/use-bp-episode-enrich.ts`, `use-bp-episode-art.ts`, `bp-episode-still.tsx` | Per-episode rating + runtime chip and a still-image fallback ladder (TMDB → TVDB → ani.zip → embedded → metahub). Port `EpisodeCell`: Cinemeta thumbnail + title only. | no | M | M |
| DT-12 | `bp-gallery-row.tsx` | Backdrops/posters/logos gallery (24 each) with a lightbox. Port: `detailRoom.ts` returns counts only. | partial | M | L-M |
| DT-13 | `detail/bp-crew-row.tsx` | Crew cells open the Person page. Port: `crew.prefix(4)` static text. | yes (`extras.crew`) | S | L-M |
| DT-14 | `detail/use-bp-episode-strip.ts`, `bp-episode-window.tsx` | Episode strip auto-scrolls to the resume episode; windowed loading (+60). Port loads the season eagerly, no scroll-to-resume. | n/a | S | L-M |
| DT-15 | `detail/bp-facts-dialog.tsx` | Facts preview → full scrollable dialog. Port: `facts.prefix(8)` inline, no dialog. | yes (`extras.facts` is uncapped) | S | L |
| DT-16 | `bp-season-menu.tsx` | Seasons as a scrollable modal. Port: inline chip row (`DetailView.swift:250-254`). | n/a | S | L |
| DT-17 | `bp-stream-row.tsx` (`BpLocalRow`, `BpHomeServerRow`) | Local files and Plex/Jellyfin/Emby copies as sources. Belongs to Stage 6, not a detail polish item. | no | L | M (Stage 6) |

`bp-hero-manga.tsx` ("Read the manga") is exported but never mounted in upstream — dead code, not a gap. `bp-subtitle-step.tsx` (pre-play subtitle pick) is covered by the port's in-player panels.

## 6. Anime room (tab)

Verified present (`animeRoom.ts`): 16 Jikan spec rows, anime CW, seeded hero, award winners merged, addon anime catalogs, collections, row customisation, AniList/MAL rails, rank tiles.

| # | Upstream | Behaviour | Engine | Effort | Impact |
|---|---|---|---|---|---|
| AN-1 | `bp-anime-hero.tsx:155-174`, `bp-anime-hero-actions.tsx`, `bp-anime-hero-meta.tsx` | Anime hero has actions (Resume / Start Watching, More Info), meta line ("Anime of the year", "New", award mark) and availability ("Sub and Dub"). Port: the anime room reuses the display-only `SpotlightView`. | partial (hero + resume data exist in `animeRoom.page`) | S-M | M |
| AN-2 | `bp-anime-badges.tsx` | Anime card badges (award, DUB). Port: covered by `cards.ts` identity chip. | yes | — | — |
| AN-3 | `bp-anime-announcement.tsx` | Never mounted in upstream (dead code). | — | — | — |

Seasons chips and Characters are on the anime **detail** page → DT-2.

## 7. Player

Verified present: transport, seek, pause, audio/subtitle track panels, online subtitle search, up-next pill, skip intro/outro/recap pill, Anime4K panel + indicator, resume seek, progress saves, Trakt/Simkl scrobbles, display-mode matching.

| # | Upstream | Behaviour | Engine | Effort | Impact |
|---|---|---|---|---|---|
| PL-1 | `player/bp-resume-prompt.tsx` (via `views/player/bp-ten-foot.tsx`) | "Resume from X / Start over" dialog with progress bar before playback. Port seeks silently (`PlayerScreen.swift:120`). | partial (`player.startPosition`) | S | H |
| PL-2 | `player/bp-up-next.tsx` | "Play now" jumps straight into the next episode's already-resolved best stream, countdown ring, "Keep watching". Port reopens the picker (`DetailView.swift:72-81`). | no (no next-episode pre-resolve) | M | H |
| PL-3 | `player/bp-subtitle-tune.tsx` (`BpSubtitleSync`) | Subtitle offset ±0.1/±1.0 s with readout (auto-sync analysis is desktop-heavy; manual offset is what matters). Port: no `sub-delay` anywhere. | no | S | H |
| PL-4 | `player/bp-connecting.tsx` | Full-screen connecting state: blurred backdrop, logo, status note, stall detection, Cancel, Try again. Port: a "Loading…" label; a stuck stream just sits. | no | M | H |
| PL-5 | `player/bp-leave-confirm.tsx` | "Leave the show?" Keep watching / Leave / Don't ask again on second Back. Port: third Menu press exits immediately (`PlayerScreen.swift:114-118`). | no (no "don't ask" setting) | S | M |
| PL-6 | `player/bp-player-subtitles.tsx` | Hide HI/SDH, Forced only, Embedded/External filters, Best-match highlight, Languages rail. Port: flat list. | no | S-M | M |
| PL-7 | `player/bp-subtitle-tune.tsx` (`BpSubtitleLook`) | In-player subtitle look panel (size/height/opacity/backing/bold) with live sample. Port: only from Settings, outside playback (`applySubtitleStyle`, `MPVPlayerController.swift:231`). | partial | S | M |
| PL-8 | `player/bp-player-sources.tsx` (`BpPlayerSources`) | Switch source mid-playback (picker in `mode="switch"`). | partial (`streamsRoom`) | M | M |
| PL-9 | `player/bp-skip-pill.tsx` | Skip pill has a dismiss ("Hide this Skip button"), is reachable by FastForward, and **never steals focus**. Port `PlayerScreen.swift:185` sets `focus = .chip("skip")` on appear — a Select during an intro skips instead of pausing. | n/a | S | L-M (correctness) |
| PL-10 | `player/bp-player-controls.tsx`, `player/bp-player-scrub.tsx` | Previous-episode button; held-seek ramps 1× → 3× → 6×; buffered range fill; "Ends HH:MM". Port: flat ±10 s per press. | n/a | S | L-M |
| PL-11 | `player/bp-player-sources.tsx` (`BpAudioLane`) | Audio delay ±0.1/±0.5 s. | no | S | L-M |
| PL-12 | `player/bp-player-subtitles.tsx` (`setSecondarySub`) | Dual subtitles ("2nd" chip). | no | M | L-M |
| PL-13 | `player/bp-subtitle-find.tsx` | Search subtitles under a different title/season/episode, "Show N more". | partial (`subtitles.search` takes params) | M | L |
| PL-14 | `player/bp-player-rail.tsx` | Mute/volume chip and state. | no | S | L |

Not in Big Picture at all (nothing to port): playback speed, sleep timer, aspect ratio, stats overlay, A/B loop, chapters, trickplay thumbnails — all desktop-only chrome or non-existent upstream. PiP: AVPlayer-engine only (PLAN §5). P2P status (`bp-p2p-status.tsx`) needs the torrent engine (Stage 6).

## 8. Library

Verified present: Saved/Watchlist/History/My Lists/Favorites + Trakt/Simkl/AniList/MAL tabs, filters, search, sectioned grid.

| # | Upstream | Behaviour | Engine | Effort | Impact |
|---|---|---|---|---|---|
| LB-1 | `bp-rate-dialog.tsx`, `lib/ratings/actions.ts` | Rate 1-10, synced to Trakt/Simkl, score shown. | no (no `ratings` export) | M | M |
| LB-2 | `bp-list-dialog.tsx`, `lib/custom-lists.ts` (`createListStore`, `toggleInList`) | Create a list / add to list from the TV. Port `library.ts` imports `readLists` only. | no | M | M |
| LB-3 | `bp-library-types.ts` `"letterboxd"`, `lib/stremboxd/*` | Letterboxd tab. | no | M | L-M |
| LB-4 | `bp-library-search.tsx`, `use-bp-library-services.ts` | Library "repair"/services rail. Port has the tabs; no repair action. | partial | S | L |

## 9. Collections

| # | Upstream | Behaviour | Engine | Effort | Impact |
|---|---|---|---|---|---|
| CL-1 | `bp-collection-steps.ts` (all/mine/community/tvdb/tmdb), `use-bp-collection-feed.ts`, `lib/collections-catalog.ts`, `providers/tvdb-collections.ts`, `bp-collection-detail.tsx` | Source chips; TMDB curated (~110 franchises), TMDB open feed, TVDB lists, each with its own detail shape (backdrop hero, overview, year range). Port: mine + community only, so the tab is near-empty without Harbor social lists. | no (`collectionsRoom = {mine, community, all}`) | L | H |
| CL-2 | `bp-collection-shell.tsx`, `bp-collection.tsx` | Collection editing (add/remove items, rename) from the TV. Port: read-only overlay. | no | M | M |

## 10. Addons

| # | Upstream | Behaviour | Engine | Effort | Impact |
|---|---|---|---|---|---|
| AD-1 | `addons/bp-addon.tsx`, `addons/use-bp-addon-catalogs.ts`, `addons/bp-addon-row.tsx`, `addons/bp-addon-posters.ts` | Open an addon → catalog chips + infinite poster grid of its own catalogs; Home band of installed addons with poster mosaics. Port: `AddonsView` is a Settings-buried install/enable/remove list. | partial-yes (`addons.loadAddonRows`, `fetchCatalogRow`, `fetchAddonCatalogPage`, `createAddonCatalogFetcher` exported, unused) | M | H |

## 11. Settings

| # | Upstream | Behaviour | Engine | Effort | Impact |
|---|---|---|---|---|---|
| ST-1 | `bp-settings.tsx:193-201` | Setup push-rows show "Connected: TMDB, Stremio…" / "{n} added" once connected. Port: `settingsRoom.controls()` returns the static `detail`; rows always say "Nothing connected yet". | partial (`facts()` has the data) | S | M (bug) |
| ST-2 | `bp-connect.tsx`, `bp-connect-parts.tsx` | Unified Connect pane: TMDB/Stremio/Harbor status in one place, QR + short code for phone setup, in-place TMDB key with live check. Port: separate sheets/sections. | no (no handoff) | M (unified) / L (QR handoff) | M-H |
| ST-3 | `bp-live-setup.tsx` | Kind picker (M3U / Xtream / Guide-data-only) and Server/Username/Password fields with masking; renders inside Settings. Port: one URL box in `LiveSourcesSheet`, and the Settings row navigates to the Live tab. | partial (`live.addPlaylist(name,url,epgUrl)`; `detectProviderShape` handles a combined URL) | M | M |
| ST-4 | `bp-settings-pane.tsx` | Right-side live preview: overscan crop, subtitle sample with flags, Harbor-vs-Classic wireframe, service logos, greeting, summary lines. Port: single column (overscan does apply live app-wide). | n/a | M | M |
| ST-5 | `bp-settings-catalog.ts` playback `home-server` + "Preferred home server" | Selecting Home server is a dead end (no media-server module). Stage 6. | no | L | L |

## 12. Onboarding

Upstream order (`onboarding/bp-onboard-steps.ts`): language → phone → tmdb → stremio → harbor → layout → streaming → subtitles → taste → done. Port (`OnboardingView.swift:13`): language, tmdb, stremio, harbor, layout, subtitles, done.

| # | Upstream | Behaviour | Engine | Effort | Impact |
|---|---|---|---|---|---|
| OB-1 | `steps/bp-step-streaming.tsx` | Pick the services you subscribe to (drives the Home services band). Missing. | yes (`services.ts`, settings) | S | M |
| OB-2 | `steps/bp-step-language.tsx` (146 lines) | Real language picker. Port: one "English" button. | partial (`region` export; locale loading stubbed in the bundle) | M | M |
| OB-3 | `steps/bp-step-taste.tsx`, `bp-taste-detail.tsx`, `use-bp-taste-titles.ts` | Pick up to 5 titles/genres to seed recommendations. Missing, and no Settings equivalent. | no | M | M |
| OB-4 | `steps/bp-step-phone.tsx`, `bp-handoff-*.ts(x)`, `lib/tv-handoff` | Pair a phone by QR so TMDB/Stremio/Harbor entry is typed there. Missing (same infra as SR-7/ST-2). | no | L | M |
| OB-5 | `bp-done-flourish.tsx`, `bp-tmdb-showcase.tsx`, `bp-stremio-showcase.tsx`, `bp-layout-preview.tsx`, `bp-subtitle-preview.tsx` | Step showcases/previews and the done flourish. Port steps are plain. | n/a | S-M | L |

## 13. Who's watching / kids / parental

| # | Upstream | Behaviour | Engine | Effort | Impact |
|---|---|---|---|---|---|
| WW-1 | `bp-who-is-watching-logic.ts` (`bpWhoKidSelectable`, `bpWhoKidStaysInBigPicture`), `lib/lockable-tabs.ts`, `lib/parental.tsx`, `lib/curfew.ts`, `bp-top-bar.tsx` `useBpTabGate`/`visibleTabs` | Kid profiles: hidden/locked tabs per profile, curfew window, parent PIN on gated actions. Port `WhoIsWatchingView.swift:60`: "Kids profiles are not available in Big Picture yet." — every kid profile is unusable. | partial (`sync.ts` mirrors `kid{age,curfewMinutes,parentPinHash}` and `lockedTabs`; nothing enforces) | L | H (households with kids) |
| WW-2 | `bp-who-is-watching-sync.ts` | Sync phase on the roster screen (pull, apply, status). Port: present (`syncNotice`, roster-applied). | yes | — | — |
| WW-3 | `bp-who-is-watching-pin.tsx` | PIN pad. Port: `PinPadView`. | yes | — | — |

## 14. Live TV (tab)

Verified present: M3U/Xtream/middleware sources, favourites, guide-lite list, XMLTV guide grid with now-line/panning/window growth, sources sheet, catch-up replay (a port extra).

| # | Upstream | Behaviour | Engine | Effort | Impact |
|---|---|---|---|---|---|
| LV-1 | `bp-guide-portal.tsx`, `bp-guide-portal-art.tsx` | Floating preview while moving through the grid: muted mini-player after 700 ms dwell, title, time range, description, progress. Port: none. | no | M | M-H |
| LV-2 | `bp-live-setup.tsx` | See ST-3 (structured Xtream, EPG-only source). | partial | S-M | M |
| LV-3 | `lib/iptv/epg-map.ts` | Manual EPG channel remap when `tvg-id` is wrong. Port only removes overrides. | no | M | L-M |
| LV-4 | `useGroupPrefs` | Hide whole channel groups. `live.ts:166` hardcodes `hiddenGroups: []`. | no | S | L |
| LV-5 | `usePinnedOrder` | Pin channels (guide order tier 2). `live.ts:139` reads pins; nothing writes them. | partial | S | L |
| LV-6 | `bp-live-filters.tsx` | Filter chips beyond Favorites/All/group. | partial | S | L |

Home Live TV row → HM-2. Multiview, DVR, in-player channel picker: not in BP.

## 15. Sports

Verified present: consent, modes/groups chips, date band, hero cycle, rows, Explore grid, event detail (stats bars, play-by-play, lineups), personalize (sports → leagues), watch flow over Live TV channels with picker + pin.

| # | Upstream | Behaviour | Engine | Effort | Impact |
|---|---|---|---|---|---|
| SP-1 | `sports/bp-sports-live-court.tsx`, `-diamond`, `-field`, `-kit`, `-plays`, `-situation` | Sport-specific live diagrams (court, diamond, field, formation, plays, situation cell) in the Stats row while live. Port: generic stat bars + text list. | no | L | H (sports fans) |
| SP-2 | `sports/bp-sports-who-*.tsx` | Tap a team/athlete → bio panel. Port: sides not tappable. | no | M | M |
| SP-3 | `sports/bp-sports-addon-*.tsx` | Stremio addon catalogs as sports sources (plan `"addons"`), fallback when no channel match. Port `watch()` plans: channel/picker/setup/finished only (`sports.ts:332`). | no | M | M |
| SP-4 | `lib/sports/reminders.ts`, `reminder-state.ts` | Bell on the event hero arms a Discord/Telegram webhook reminder. Port: none, but the consent copy promises it. | no | M | M (or edit the copy: S) |
| SP-5 | `sports/bp-sports-event-rows.tsx` (`BpSportsStandingsRow`), `bp-sports-extra-tables.tsx` | Standings table. `fetchStandings` not wired; `Detail` has no field. | partial | S | M |
| SP-6 | `sports/bp-sports-personalize.tsx` step 3 | Favourite teams → "Your teams" row. `toggleTeam` exported, never called. | yes | M | M |
| SP-7 | `sports/bp-sports-broadcast-stage.tsx`, `bp-sports-broadcast-picker.tsx` | Play official Twitch/YouTube/Kick broadcasts. Port lists them as text (`sports.ts:270-271`). | no | L | M |
| SP-8 | `sports/bp-sports-event-rows.tsx` where-to-watch, venue | Provider tiles (tappable), venue cell, UFC.com/F1 fallbacks. Port: one text line (`SportsEventView.swift:132-135`). | partial | S | L-M |
| SP-9 | `sports/bp-sports-art.ts`, `lib/sports/hub-artwork.ts`, `SCENERY_GROUPS` | TheSportsDB artwork + per-sport scenery fallback. Port shows nothing when the feed has no art (most games). | no | S | L-M |
| SP-10 | `use-bp-sports.ts` (`useBpWatchGame`) | Exact live match on a card/hero plays directly instead of opening detail. | partial | S | L-M |
| SP-11 | `sports/bp-sports-extra-players.tsx`, `-kit`, `-pitch`, `-venue`, `-odds` | Extra rows: players, kit, pitch, venue, odds (odds: upstream gates it; skip). | no | M | L |
| SP-12 | `lib/sports/api-hub-leagues.ts`, `api-credentials.ts` | api-sports key leagues (4 niche leagues). | no | S | L |
| SP-13 | attachments `streams` (paste a stream URL for a game) | `Attachments.streams` exists (`sports.ts:273`) with no write path. | partial | S | L |

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

Honourable mentions (high impact for a subset, L effort): HM-2 Home Live TV row, SP-1 live-situation diagrams, LV-1 guide portal (M), SH-3 quick panel (M), ST-2/OB-4/SR-7 phone handoff (one shared L piece of infrastructure that unlocks three gaps).

## 17. Things the port does that Big Picture does not

- Catch-up / replay from the guide grid (`live.catchupUrl`); upstream BP's guide only tunes live (`bp-guide-block.tsx:566-572`).
- Trakt + Simkl scrobbling from the TV player (desktop feature, not BP chrome).
- Anime4K panel with a libplacebo shader-rejection fallback (log scan) — no BP equivalent of the fallback.
- `AVDisplayCriteria` display-mode matching (native tvOS).
- Native Settings page beyond the 8-category catalog: Harbor/Stremio/Trakt/Simkl/AniList/MAL sections, Addons manager, TMDB "Test saved key" + "Remove key", ranked subtitle-language grid, Sync status with queued count, Profiles, Developer menu, About.
- Overscan applied live to the whole shell while adjusting.
- Explicit on-screen Back buttons on Detail/Person heroes (tvOS convention).
- Harbor onboarding step allows typing the password on-device (TLS to harbor.site), skipping upstream's LAN-safety detour.

## 18. N/A on tvOS or dead in upstream (not counted)

- Dead in upstream: `bp-hero-manga.tsx`, `bp-anime-announcement.tsx` (exported, never mounted).
- Desktop-only/no TV meaning: `bp-entry-button.tsx` ("Big Picture" entry from desktop), `bp-exit-confirm.tsx`/`bp-exit-preview.tsx` (back to desktop window), `use-bp-fullscreen.ts`, `bp-platform.ts` desktop/Android branches, battery icon in `bp-status.tsx`, "Leave Big Picture" settings row, `.harborstyle`/custom CSS (not in the BP catalog anyway), pad shoulder hints until MFi controllers are supported.
- Needs subsystems from later stages: P2P status (torrent engine, Stage 6), local files / home servers in the picker and Library (Stage 6), downloads, Multiview, DVR, Together rooms (Stage 10), manga reader (Stage 13).
- Infrastructure with a native replacement: `bp-logic.ts`/`bp-focus-core.ts`/`use-bp-focus.ts` (SwiftUI focus engine), `bp-track-glide.ts`, `bp-grid.tsx`, `use-bp-page-modal.ts`, `bp-error-boundary.tsx`, `bp-view-state.ts`, `bp-visible.ts`, `bp-routes.tsx`, `bp-safe-area.ts` (overscan setting), `bp-tokens.ts`/`bp-action-style.ts`/`bp-hero-style.ts` (→ `BPStyles.swift`), `bp-boot-splash.ts` (→ `BootSplashView`), `bp-i18n.ts` (→ OB-2), `bp-rank-numeral.tsx` (→ rank tile), `bp-lead-tile.tsx` (upstream removed it from bands as a cost; nothing to port), `bp-poster-chain.ts` (poster fallback ladder — port's `RemoteImage` has no chain; minor, S/L).

## 19. Documentation follow-ups

- Correct the three PROJECT_STATE lines in §0.
- `docs/livetv-spec.md` never mentions the Home Live TV row (HM-2); `docs/sports-spec.md` marks who/addon/broadcast-stage "out of scope" — this audit is the first place they are confirmed unported.
- `docs/detail-spec.md` is accurate and line-cited; keep using it.
