# Parity audit, 2026-09-24

Fresh read-only audit (after the 09-23 audit's top-15 shipped) of upstream Harbor vs the tvOS port. Upstream's Android TV entry (`src/main-tv.tsx`) runs `BpTvApp`, so Big Picture + the shared `views/player.tsx` is the reference. Paths are under `reference/harbor/src/` (upstream) and `App/Sources/` / `engine/` (TV).

## Reconciliation (2026-09-27)

Every item in this file was checked against the current code (`App/Sources/**`, `engine/*.ts`) and,
for the "upstream doesn't read this either" calls, against `reference/harbor/src` directly (the
submodule was not checked out earlier in this pass — `git submodule update --init` fixed that before
these calls were made, so they are grep-verified, not assumed).

**Counts — 27 tracked items (the 15 ranked gaps + the 8 named "Lower" items + the 4 "Blocked on
tvOS" items): 20 Ported, 0 Partial, 7 Open** (3 ranked items blocked on the owner/on tvOS tooling,
plus the 4 "Blocked on tvOS" items — all pre-existing, correctly still blocked, not new gaps). Of the
~49 individual keys in "Settings the TV reads nowhere": 42 Ported, 6 N/A (real upstream settings that
upstream's own Big Picture never reads either — not a TV-vs-BP gap), 1 Open (`heroTrailers`, blocked
on tvOS, already tracked above).

**Still open (all pre-existing, none new):**
- **#12 Top Shelf** (M) — blocked on the owner: needs a second signed target, an App Group, and its
  provisioning profile in App Store Connect (HANDOFF.md, PLAN Stage 14).
- **#13 Desktop "Harbor on TV" settings mirror** (M) — `views/settings/tv-panel/*` is still stored by
  `engine/sync.ts` and applied nowhere on the TV; unlike most rows below, upstream's own Big Picture
  has no consumer for it either, so this is a low-priority loose end rather than a visible gap.
- **#15 Subtitle Auto sync** (L) — blocked: needs subsync + audio extraction in harbor-ffi (unchanged).
- **Blocked on tvOS** (unchanged): hero trailers (`use-bp-trailer.ts`, needs yt-dlp), seek thumbnails
  (`use-trickplay.ts`, needs a native thumbnailer), YouTube Music (needs a web view), "Play on" LAN
  receiver (upstream itself has none).

All added to `docs/parity-gaps.md` → "Still open" (they were already there; this just confirms none
of them quietly shipped).

## Top gaps (ranked by user impact)
1. **Skip intro/recap/outro settings** (`views/player/skip-pill-container.tsx`; autoSkipIntro/Recap/Outro, showSkipButton, skipButtonHideSec) — written by settingsRoom, read nowhere. S. **[Ported]** `App/Sources/Player/PlayerScreen.swift` reads all five (`autoSkipIntro`/`Recap`/`Outro`, `showSkipButton`, `skipButtonHideSec`) in its skip-pill auto-skip/hide logic (PROJECT_STATE "Parity audit batch 1", 21:45 09-23).
2. **Home extra rows** (`big-picture/use-bp-extra-rows.ts`): Trakt/Simkl rails, Favorites, My Watchlist, custom list rows (`homeRows.listRows`), pinned rows, collection rows, anime rows, Arabic/Russian rows. M. **[Ported]** `engine/homeExtras.ts` `extraRows` is a direct port of `use-bp-extra-rows.ts` (`before`/`after` row sets, Trakt via `buildTraktHomeRows`, `simklHomeRailsEnabled`, `homeRows.listRows`, `collectionHomeRows`, Letterboxd rails).
3. **Per-show track memory and track rules** (`lib/player-prefs.ts`, `lib/subtitles/subtitle-memory.ts`, `views/player/hooks/use-track-autoload.ts`; trackBlockWords, subtitlesOffByDefault, preferEmbeddedSubs, forcedSubsWhenNativeAudio). M. **[Ported]** `engine/player.ts` reads all four (`trackBlockWords`, `subtitlesOffByDefault`, `preferEmbeddedSubs`, `forcedSubsWhenNativeAudio`); `App/Sources/Player/TrackMemory.swift` carries the per-show memory.
4. **Episode watched state** (`detail/use-bp-episode-strip.ts`, `components/episode-watched-menu.tsx`): Harbor manual marks + Trakt/Simkl marks unread; no per-episode/season mark on TV. M. **[Ported]** `engine/episodeWatched.ts` (state/mark/load/upNextMask); `App/Sources/Detail/DetailModel.swift`/`DetailView.swift` (hold-Select episode-watched menu, season toggle).
5. **Anime named seasons / episode orders** (`bp-anime-seasons.tsx`, `bp-anime-season-chip.tsx`). M-L. **[Ported]** `engine/animeSeasons.ts` (`chipsFor`, `seasonYears`, `activeSeasonKey`); `App/Sources/Detail/DetailView.swift` `animeSeasonChips`/`AnimeSeasonChipLabel` — named season chips with year ranges, exactly per the cited upstream files.
6. **Spoiler masking + episode detail toggles** (`lib/spoilers.ts`, `bp-episode-still.tsx`, `bp-up-next.tsx`, `bp-skip-pill.tsx`, `detail/bp-episode-card.tsx`; hideSpoilers, spoiler*, showEpisodeRating, showEpisodeDescription). S-M. **[Ported]** `App/Sources/Settings/SpoilersPanel.swift` + `Detail/DetailModel.swift` `SpoilerMask`; `hideSpoilers`/`spoilerHideThumbnails`/`spoilerHideTitles`/`spoilerHideDescriptions`/`spoilerSkipNext`/`showEpisodeRating`/`showEpisodeDescription` are all read (2-3 call sites each).
7. **Still watching? prompt** (`views/player/hooks/use-still-watching.ts`, `still-watching-prompt.tsx`). S. **[Ported]** `App/Sources/Player/PlayerTimers.swift` `StillWatching`/`stillPrompt`, "Keep watching".
8. **Addons manager** (`views/addons/*`, `addon-collection.tsx`, `lib/addon-store.ts`): community browse, configure (phone QR), reorder, adult gate. M-L. **[Ported]** `App/Sources/Addons/` (`AddonsView.swift` — Discover/community rail/categories/browse, `showAdultAddons` gate with an age-gate sheet; `AddonConfigureView.swift`; `AddonOrganizeView.swift` — reorder).
9. **Now Playing / remote commands for video** (`lib/media-session.ts`). S-M. **[Ported]** `App/Sources/Player/VideoNowPlaying.swift` (`MPNowPlayingInfoCenter`, `MPRemoteCommandCenter`).
10. **Home-server playback preference** (`bp-streams.tsx` decidePlaybackSource, home-server-quality panel). S-M. **[Ported]** `engine/homeServers.ts` `decidePlaybackSource` port; `App/Sources/Streams/PlayPickerView.swift` reads `settings.playbackSourcePreference`.
11. **Picker leftovers** (`bp-stream-filters.ts` customStreamFilters/activeStreamFilterId; `bp-stream-row.tsx` pickerShowFilename/fullStreamDescription). S. **[Ported]** `engine/streams.ts` (`customStreamFilters`, `setActiveFilterId`); `App/Sources/Streams/PlayPickerView.swift` reads `pickerShowFilename`/`fullStreamDescription`.
12. **Top Shelf** (PLAN Stage 14). M. Blocked on the owner (second signed target, App Group, provisioning profile). **Still open** — unchanged, see the Reconciliation note above.
13. **Desktop "Harbor on TV" settings mirror** (`views/settings/tv-panel/*`; stored by engine/sync.ts, applied nowhere; no upstream consumer either). M. **Still open** — unchanged, see the Reconciliation note above.
14. **Sleep timer** (`lib/sleep-timer-store.ts`, `views/player/hooks/use-sleep-timer.ts`). S-M. **[Ported]** `App/Sources/Player/PlayerTimers.swift` `SleepTimer` (`PlayerClock.swift` hosts it).
15. **Subtitle Auto sync** (`bp-subtitle-tune.tsx`). L. Blocked: needs subsync + audio extraction in harbor-ffi. **Still open** — unchanged, confirmed still blocked.

Lower: AI search (M), X-Ray on pause (M), autoNextStreamOnStall (S), Voyage (M), animeFavoriteGenres / animeCwEnd / cwAdvanceNext / episodeHiding (S). **[All Ported]** `App/Sources/Search/AISearchModel.swift`/`AISearchSection.swift`; `App/Sources/Player/PlayerXRay.swift`; `autoNextStreamOnStall`(+`Sec`) read in `PlayerScreen.swift`; `App/Sources/Discover/VoyageView.swift`/`VoyageModel.swift`; `animeFavoriteGenres`/`animeCwEnd`/`cwAdvanceNext`/`episodeHiding` all read (3-5 call sites each in `engine/animeRoom.ts`/Swift).
Blocked on tvOS: hero trailers (yt-dlp), seek thumbnails (native thumbnailer), YouTube Music (web view), "Play on" LAN receiver (none upstream). **Still open** — unchanged; these need native tooling the platform doesn't have, not a port gap in the ordinary sense.

## Settings the TV reads nowhere
- Dead TV controls: autoSkipIntro **[Ported, see #1]**, mpvHwdec (mpv hard-codes videotoolbox) **[N/A, correct as-is: this is deliberate, not a gap]**, posterQuality **[Ported]** (`App/Sources/Browse/ImageLoader.swift`/`BPTileView.swift`), playbackSourcePreference **[Ported, see #10]**, preferredMediaServerId **[Ported]** (`Settings/HomeServersPanel.swift`), hideWatchedInCatalogs **[N/A]** (`engine/settingsRoom.ts:91`'s own comment: "read only by the desktop's `views/home.tsx`, never by Big Picture" — confirmed against `reference/harbor/src` too, so this was never a TV-vs-BP gap); tvNavigation and bigPictureAutoStart are desktop-only rows that should be hidden **[Ported/fixed]** — `engine/settingsRoom.ts` explicitly excludes both ("Rows the TV leaves out").
- Player: autoSkipRecap/Outro/Ad, showSkipButton, skipButtonHideSec, stillWatching(+After), trackBlockWords, subtitlesOffByDefault, preferEmbeddedSubs, forcedSubsWhenNativeAudio, secondarySubLang, autoNextStreamOnStall(+Sec), defaultPlaybackSpeed, audioNormalize, xrayEnabled, contentAdvisoryToast. **[All Ported]** — every key above has at least one real call site in `App/Sources/Player/*` or `engine/player.ts` (grep-verified 2026-09-27; `audioNormalize`/`contentAdvisoryToast` per parity-gaps.md P1/P7).
- Detail/picker: hideSpoilers, spoilerHideThumbnails/Titles/Descriptions, spoilerSkipNext, showEpisodeRating, showEpisodeDescription, customStreamFilters, activeStreamFilterId, pickerShowFilename, fullStreamDescription, episodeArcGroups. **[All Ported except episodeArcGroups]** `episodeArcGroups` is real upstream (`lib/settings/types.ts:225`, used by `components/player/cast-modal/episode-picker.tsx` and `views/detail/series-episodes.tsx`) but `grep -rn episodeArcGroups reference/harbor/src/views/big-picture` → 0: **upstream's own Big Picture never reads it either** (desktop-only arc-grouped episode picker), so this is **N/A**, not a TV gap. Everything else in this line is Ported (grep-verified).
- Home/anime: homeRows.listRows, simklHomeRailsEnabled, simklUpNextRailEnabled, simklTrendingRailEnabled, animeFavoriteGenres, animeCwEnd, cwAdvanceNext, episodeHiding, heroTrailers (blocked), webhookRules. **[All Ported except heroTrailers and webhookRules]** `heroTrailers` — still blocked on tvOS (yt-dlp), unchanged. `webhookRules` is real upstream (`lib/settings/types.ts:647`, a general cross-content notification-rules engine — new releases, watchlist alerts, etc., configured from `views/settings/webhooks-panel.tsx`) but `grep -rn webhookRules reference/harbor/src/views/big-picture reference/harbor/src/lib/sports` → 0: **upstream's own Big Picture never reads it either**, so it is **N/A**. The port's *Sports* reminders (SP-4 in `parity-audit-2026-09-23.md`, Discord/Telegram via `engine/sports.ts` + `Sports/SportsSettingsPanels.swift`) are a separate, narrower mechanism (`lib/sports/reminders.ts` upstream) that Big Picture's sports views do read — that one was correctly identified as a real gap in the 09-23 audit, and it shipped.
