# Parity audit, 2026-09-24

Fresh read-only audit (after the 09-23 audit's top-15 shipped) of upstream Harbor vs the tvOS port. Upstream's Android TV entry (`src/main-tv.tsx`) runs `BpTvApp`, so Big Picture + the shared `views/player.tsx` is the reference. Paths are under `reference/harbor/src/` (upstream) and `App/Sources/` / `engine/` (TV).

## Top gaps (ranked by user impact)
1. **Skip intro/recap/outro settings** (`views/player/skip-pill-container.tsx`; autoSkipIntro/Recap/Outro, showSkipButton, skipButtonHideSec) — written by settingsRoom, read nowhere. S.
2. **Home extra rows** (`big-picture/use-bp-extra-rows.ts`): Trakt/Simkl rails, Favorites, My Watchlist, custom list rows (`homeRows.listRows`), pinned rows, collection rows, anime rows, Arabic/Russian rows. M.
3. **Per-show track memory and track rules** (`lib/player-prefs.ts`, `lib/subtitles/subtitle-memory.ts`, `views/player/hooks/use-track-autoload.ts`; trackBlockWords, subtitlesOffByDefault, preferEmbeddedSubs, forcedSubsWhenNativeAudio). M.
4. **Episode watched state** (`detail/use-bp-episode-strip.ts`, `components/episode-watched-menu.tsx`): Harbor manual marks + Trakt/Simkl marks unread; no per-episode/season mark on TV. M.
5. **Anime named seasons / episode orders** (`bp-anime-seasons.tsx`, `bp-anime-season-chip.tsx`). M-L.
6. **Spoiler masking + episode detail toggles** (`lib/spoilers.ts`, `bp-episode-still.tsx`, `bp-up-next.tsx`, `bp-skip-pill.tsx`, `detail/bp-episode-card.tsx`; hideSpoilers, spoiler*, showEpisodeRating, showEpisodeDescription). S-M.
7. **Still watching? prompt** (`views/player/hooks/use-still-watching.ts`, `still-watching-prompt.tsx`). S.
8. **Addons manager** (`views/addons/*`, `addon-collection.tsx`, `lib/addon-store.ts`): community browse, configure (phone QR), reorder, adult gate. M-L.
9. **Now Playing / remote commands for video** (`lib/media-session.ts`). S-M.
10. **Home-server playback preference** (`bp-streams.tsx` decidePlaybackSource, home-server-quality panel). S-M.
11. **Picker leftovers** (`bp-stream-filters.ts` customStreamFilters/activeStreamFilterId; `bp-stream-row.tsx` pickerShowFilename/fullStreamDescription). S.
12. **Top Shelf** (PLAN Stage 14). M. Blocked on the owner (second signed target, App Group, provisioning profile).
13. **Desktop "Harbor on TV" settings mirror** (`views/settings/tv-panel/*`; stored by engine/sync.ts, applied nowhere; no upstream consumer either). M.
14. **Sleep timer** (`lib/sleep-timer-store.ts`, `views/player/hooks/use-sleep-timer.ts`). S-M.
15. **Subtitle Auto sync** (`bp-subtitle-tune.tsx`). L. Blocked: needs subsync + audio extraction in harbor-ffi.

Lower: AI search (M), X-Ray on pause (M), autoNextStreamOnStall (S), Voyage (M), animeFavoriteGenres / animeCwEnd / cwAdvanceNext / episodeHiding (S).
Blocked on tvOS: hero trailers (yt-dlp), seek thumbnails (native thumbnailer), YouTube Music (web view), "Play on" LAN receiver (none upstream).

## Settings the TV reads nowhere
- Dead TV controls: autoSkipIntro, mpvHwdec (mpv hard-codes videotoolbox), posterQuality, playbackSourcePreference, preferredMediaServerId, hideWatchedInCatalogs; tvNavigation and bigPictureAutoStart are desktop-only rows that should be hidden.
- Player: autoSkipRecap/Outro/Ad, showSkipButton, skipButtonHideSec, stillWatching(+After), trackBlockWords, subtitlesOffByDefault, preferEmbeddedSubs, forcedSubsWhenNativeAudio, secondarySubLang, autoNextStreamOnStall(+Sec), defaultPlaybackSpeed, audioNormalize, xrayEnabled, contentAdvisoryToast.
- Detail/picker: hideSpoilers, spoilerHideThumbnails/Titles/Descriptions, spoilerSkipNext, showEpisodeRating, showEpisodeDescription, customStreamFilters, activeStreamFilterId, pickerShowFilename, fullStreamDescription, episodeArcGroups.
- Home/anime: homeRows.listRows, simklHomeRailsEnabled, simklUpNextRailEnabled, simklTrendingRailEnabled, animeFavoriteGenres, animeCwEnd, cwAdvanceNext, episodeHiding, heroTrailers (blocked), webhookRules.
