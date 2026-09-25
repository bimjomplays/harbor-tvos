# Big Picture parity gaps

A running list of what upstream's Big Picture (TV) UI does that the tvOS port does not do, or only
partly does. Add a new dated section per audit. Earlier audits live in `parity-audit-2026-09-23.md`
and `parity-audit-2026-09-24.md`. Almost every row in those two is ported now.

## 2026-09-25 audit

Upstream is `reference/harbor` at `770ca0bd` (read-only). The port is `App/Sources/**` plus `engine/*.ts`
on `claude/determined-hopper-smvu37` at `c0ffe07` (run 234). Scope: `src/views/big-picture/**` (377
files), the components and hooks it uses, and the shared player (`views/player.tsx` and
`views/player/**`). The shared player matters because `player-overlay-layers.tsx` mounts `StageOverlays` (subtitle
offset badge, content advisory toast) and `LiveLayer` whether or not the ten-foot layer is on.
(`showChrome` in `player.tsx:1223-1227` keeps the desktop P2P chip, ad-report button and
transport off a television, so those are not gaps.)

**How this was checked**
1. **Strings.** Every `t("…")` key in `big-picture/**` (1,208 keys) was matched against Swift and
   engine glue. `{x}` placeholders could match `%@`, `%lld` or `\(…)`. That left 203 keys with no
   match, and each one was checked by hand. Most are aria-only labels, desktop-only copy, or copy
   that lives in upstream modules the engine bundles as they are (`bp-settings-catalog.ts`,
   `bp-anime-groups.ts`, `bp-sports-rows.ts`). None of those count as gaps.
2. **Files.** Every big-picture file name and every `views/player/hooks/*` name was grepped for in
   the port. The port cites upstream file names in its comments. Of the 102 files with no citation,
   most are infrastructure that SwiftUI replaces (focus core, ring motion, art hydration, routes).
   The rest were read one by one.
3. **Settings.** 214 `settings.*` keys are read by Big Picture or the player. Of those, 71 are never
   read by the port. The ones that change what a TV viewer sees or hears are listed below. The
   others are Windows, macOS or desktop-window keys.
4. Every row below was confirmed absent by grep. The "TV today" column says what the port does
   instead, with the file. Items that PROJECT_STATE records as owner decisions or deliberate
   differences are left out (see the end of this section).

Size: S = under a day, M = a few days, L = a week or more. "Worth it" is for a viewer on a sofa
with a Siri Remote.

### Top 10 to port next

| # | Gap | Size | Why it goes first |
|---|---|---|---|
| 1 | **P2 Live TV auto-reconnect** | S | IPTV streams drop often. Today one hiccup leaves the viewer on an error card. |
| 2 | **P1 Audio normalise + audio profiles** (night mode, voice, bass) | S | These settings already sync from desktop and mpv only needs one `af` string. Night mode is a real TV need. |
| 3 | **P3 Subtitle font family + ASS override** | S | Anime ASS subtitles ignore the viewer's style, and the Arabic font preset does nothing. The settings already sync. |
| 4 | **X1 Sports: search your playlists for a channel and pin it** | S-M | The TV's own copy tells the viewer to "Search your channels", but that search does not exist. |
| 5 | **D1 Synopsis "Read more"** | S | Long overviews are cut at 4 lines and cannot be opened. |
| 6 | **S3 Stream row labels** (cached on which service, Unverified / No Label, DUB/SUB) | S | Every play goes through this list. The data is already in `ScoredStream`. |
| 7 | **S2 Picker chips: Direct/debrid vs P2P only, preferred language, Refresh, source counts** | S | Completes the picker chip row. `requirePreferredLanguage` already syncs. |
| 8 | **V2 Discover Collections band** | S | A whole Discover section is missing. The Home collections row can be reused. |
| 9 | **H1 Row edge navigation** (Right off the last tile opens See all, Left off the first goes to the tabs) | S | Remote walking. Already listed as open in PROJECT_STATE. |
| 10 | **L1 Keep Search and Library state across tab switches** | S | Leaving Search to check Library currently throws away the query and the results. |

Close behind: D3 anime Filler tag (S), H2 minutes-left on Continue Watching cards (S), O1 Who's
watching on return (S), D2 hero provenance marks (S-M) and V1 award pages with playable
winners (M).

### Ported since this audit

The player, Browse and Picker/Detail parity passes (PROJECT_STATE, 2026-09-25 15:57-16:08 UTC)
ported P1, P2, P3, S2, S3, D1, D3, V2, H1, H2, L1, O1 and the "Available in" / TMDB-key half of D2.
The parity batch after them ported:

| # | What landed | Where |
|---|---|---|
| X1 | "Search your channels": name search over every playlist's sports channels (searchSportsChannels, 30 rows), Select plays, the pin square toggles "Always use for {league}"; opened from the event picker, the empty picker's primary button and the official-broadcast list; "Pinned channels are tried first for {league}." | `engine/sports.ts` `searchChannels`, `watch()` `searchable`/`attachedIds`/`leagueLabel`; `Sports/SportsChannelSearchView.swift`; `Sports/SportsEventView.swift` |
| V1 | Award page: decade and category chips with counts, header counts of what the filters leave, winner tiles (metahub poster or year) paged 90 at a time; Select opens the IMDb id or a TMDB lookup scored by use-bp-award-work ("Checking with TMDB…" / "No match found"); keyless goes to Settings. | `engine/discover.ts` `awardPage` / `awardOpen`; `Discover/AwardDetailView.swift` |
| D2 | The addon-origin mark: `Meta` decodes `addonOrigin` (kept across the Cinemeta re-read) and the hero draws the addon's logo and name. D2 is now complete. | `Browse/Meta.swift`, `Detail/DetailModel.swift`, `Detail/DetailView.swift` `AddonOriginMark` |
| D5 | Crew row role names with singular/plural (Director(s), Creator(s), Writer(s), Producers, Cinematography, Music, Editor(s)); the facts card is upstream's `bpFactRows` (credit rows first); the Person page's "Top {n}" department rank (lib/rankings over TMDB person/popular). | `engine/detailRoom.ts`, `engine/personRoom.ts`, `Detail/PersonView.swift` |
| H3 | Each room's failure copy (Home, Movies, Shows, Anime) with Try again; Movies / Shows / a service page that settles empty say why and offer Open settings. ("Anime is hidden" is not reachable on the TV: a hidden anime tab is off the bar.) | `Browse/RoomView.swift`, `Browse/BrowseModel.swift` |
| H6 | `hidePosterTitles` hides the poster title (bp-tile showTitle). `cardBadgeLimit` has nothing to cap: TV tiles carry no score chips (upstream gate). | `Settings/SettingsBridge.swift`, `Browse/BPTileView.swift` |
| O3 | The setup poster wall: two drifting columns at 7 % on the trailing side under a page wash; still under Reduce Motion. | `Onboarding/OnboardBackdropView.swift`, `Onboarding/OnboardingView.swift` |
| O4 | TMDB step: "rejected" and "could not reach TMDB" are separate answers (engine `onboarding.checkTmdbKey`, configuration endpoint), Save it anyway only for the second, a live "{n} of 32 characters" note, Verify dims rather than disables. | `engine/onboarding.ts`, `Onboarding/TmdbStep.swift` |

Still open from this audit: P5-P11, S4, S5, D4, V3, H4, H5, L2, L3, X2, X3, O2.

### Player (10)

| # | Gap | Upstream | What it does for the viewer | TV today | Size | Worth it on TV? |
|---|---|---|---|---|---|---|
| P2 | Live auto-reconnect | `views/player/hooks/use-auto-retry.ts:111-160` | When a live channel errors, it reconnects on its own: once before the first frame, twice after playback has started (after 1.5 s or 4 s). | `PlayerScreen.swift` ports only the VOD "premature EOF" branch. A live error goes straight to the error card. PROJECT_STATE lists this as open. | S | Yes |
| P1 | Audio normalise + audio profile | `lib/player/mpv.ts:168-173,1283-1291`, `use-track-autoload.ts:755-756` | `audioNormalize` and `audioProfile` (bass, voice, bass-reduce, **night**) are applied as mpv audio filters. Both sync from desktop Settings → Audio. | `MPVPlayerController.swift` sets no `af`. `SettingsBridge.swift` has neither key. | S | Yes (mpv engine only; AVPlayer has no filter chain) |
| P3 | Subtitle font family + ASS override | `use-sub-style-apply.ts:65-67`, `lib/player/sub-presets.ts` | The viewer's subtitle font (Inter, Arabic, …) and `subAssOverride` (no, scale, force) restyle ASS/SSA subtitles too. | `MPVPlayerController.swift:485` always uses `sub-font` "Switzer". It never sets `sub-ass-override`. | S | Yes |
| P5 | Started-near-end guard | `use-started-near-end.ts`, `use-auto-end-exit.ts` | Playback that starts at 80% or later (re-watching an ending) does not auto-exit or auto-advance. | Absent. PROJECT_STATE lists this as open. | S | Yes |
| P6 | Crop / aspect mode | `use-video-fill.ts` (`cropMode`: fit, fill, stretch, zoom, 16:9, 4:3, 21:9) | The crop chosen on desktop applies in Big Picture too. Big Picture itself has no control for it. | No `panscan`, `video-zoom` or `video-aspect-override` anywhere. | S to apply the synced value; M for a TV chip (a deviation from upstream) | Yes (21:9 on 16:9), low priority |
| P7 | Content advisory toast | `use-content-advisory.ts`, `components/player/content-advisory-toast.tsx` via `stage-overlays.tsx:121` | When playback starts: the MPA rating and IMDb parental-guide categories. `contentAdvisoryToast` is off by default. | None. `harbor-imdb` is bundled, but only for episodes and scores. | S-M | Maybe (households with kids) |
| P8 | Switch source in place | `big-picture/player/bp-player-sources.tsx` ("Pick a source to swap in place. Playback keeps running.") | Opens the source list over the playing film. Picking one swaps the stream at the same position. | The Sources chip closes the player and reopens the picker at the saved spot (`PlayerScreen.swift:1148`). | M | Yes, medium |
| P9 | Subtitle small bits | `stage-overlays.tsx:85` `SubtitleOffsetIndicator`; `bp-player-subtitles.tsx:239` "Search every source again"; `bp-subtitle-parts.tsx:184` "{count} dl" | A badge on screen while a subtitle offset is set, a chip that re-runs the automatic subtitle search, and download counts on results. | `PlayerSubtitlesPanel.swift` has the offset stepper and a manual search, but none of these three. | S | Low |
| P10 | Picture EQ | `use-live-picture-eq.ts` (`mpvTweaks` brightness, contrast, saturation, gamma) | Picture adjustments set on desktop also apply on the TV. | None. | S | Low |
| P11 | Exit snapshot for Continue Watching | `use-exit-snapshot.ts` (`cwSnapshotFullQuality`, `cwSnapshotRetentionDays`) | Saves a frame at exit and uses it as the Continue Watching art. | None. | M | Low (tvOS caches can be purged) |

### Stream picker (4)

| # | Gap | Upstream | What it does for the viewer | TV today | Size | Worth it on TV? |
|---|---|---|---|---|---|---|
| S3 | Stream row labels | `bp-stream-row.tsx:265-300,379-387` | "Cached on Real-Debrid", or "In TorBox" when it is your own cloud. "Unverified" or "No Label" when the quality is guessed. DUB/SUB badge (`showDubBadge`). Quality badges follow `showQualityBadge`. | A plain "Cached" badge (`PlayPickerView.swift:686,783`). No confidence label, no DUB/SUB, no badge toggles. | S | Yes |
| S2 | Remaining picker chips | `bp-stream-chips.tsx:31-47,137-142,186`; `bp-stream-filters.ts:121`; `bp-streams.tsx:380-392` | Mode chip: All sources, Direct/debrid only, P2P only. A preferred-language chip, on by default under `requirePreferredLanguage`. A Refresh chip. A header like "N of M sources · K addons loading". "No sources found". | Only the All sources / Media servers toggle (`PlayPickerView.swift:611-614`). "Asking addons… n/m" shows only before the first result. No language chip, no Refresh. | S | Yes |
| S5 | Watch Together host match | `components/host-match-chip.tsx` (`bp-stream-row.tsx:327`); `views/player/duration-mismatch-chip.tsx` | A guest sees which rows are "Same file as host" or a "Close match". In the player, a chip warns when the file's length differs from the host's and offers to find a closer one. | `TogetherModel.swift:120` receives `hostSource`, but neither the picker nor the player uses it. PROJECT_STATE lists this as open. | S-M | Yes, for Together |
| S4 | Subtitle step before playback | `bp-subtitle-step.tsx` via `bp-streams.tsx:337`, `use-bp-stream-play.ts:145-160` | With `subtitlePreselect` on (a desktop setting, off by default), a "Choose subtitles" screen appears between the pick and the player. It has "Skip, let Harbor choose" and "Start playback". | None. The picker goes straight to the player. | M | Maybe (off by default) |

### Detail and Person (5)

| # | Gap | Upstream | What it does for the viewer | TV today | Size | Worth it on TV? |
|---|---|---|---|---|---|---|
| D1 | Synopsis "Read more" | `detail/bp-synopsis.tsx` (the toggle is the last cell of the actions row) | A long overview that is cut off can be opened in place, and closed again with "Show less". | `DetailView.swift:551` uses `.lineLimit(4)` with nothing to open it. | S | Yes |
| D3 | Anime "Filler" tag | `bp-anime-seasons.tsx:134` | Filler episodes carry a "Filler" pill in the episode strip. | `DetailModel.swift:186` decodes `filler`, but nothing draws it. | S | Yes |
| D2 | Hero provenance marks | `detail/bp-hero-notes.tsx` `BpHeroMarks`, `BpTmdbKeyNote` | Marks on the hero: the addon that served the title (its logo and name), "Available in Plex/Jellyfin/Emby" for each connected server that has it, and "Add a TMDB key in Settings to see the cast, crew, and details." | None. Nothing in the port reads `addonOrigin`, and no per-title server availability is looked up. | S-M | Yes (media servers are already ported) |
| D4 | Favourite an anime character | `bp-anime-characters.tsx:116` (`lib/character-favorites`) | Select on a character favourites them. The favourites sync to the desktop Favorites tab. | The ring is there, but Select does nothing (`DetailView.swift:659`: "that store is not ported"). | S-M | Low |
| D5 | Crew and facts labels | `detail/bp-crew-row.tsx:65-71` (Director/Directors, Creator/Creators, Writer/Writers, Producers, Cinematography, Music, Editor/Editors); `bp-facts.tsx:30-35` (the facts card opens with Directed by, Created by, Written by, Music by, Cinematography); `bp-person.tsx:333` "Top {n}" department rank | The crew row uses role names with singular or plural forms. The facts card begins with the credit rows. A person's department rank shows as a badge. | `engine/detailRoom.ts:71-78` gives the crew row the facts-style labels ("Directed by", "Written by", "Music"), and the facts card starts at Status. No rank badge. | S | Low |

### Discover and Awards (3)

| # | Gap | Upstream | What it does for the viewer | TV today | Size | Worth it on TV? |
|---|---|---|---|---|---|---|
| V2 | Collections band | `bp-discover.tsx:240-246`, `bp-collections-band.tsx` | "Sagas and series, gathered in the order they were meant to be watched." A Collections band between Genres and Top People. | `DiscoverView.swift` has sections for queue, awards, genres, voyage and people. No collections section. `HomeBands.swift` already has the collections band. | S | Yes |
| V1 | Award page | `bp-award.tsx`, `use-bp-award-work.ts` | Year and category chips ("All years", "All categories"). Every winner is a poster tile that resolves to a TMDB title and opens its page ("Checking with TMDB…" / "No match found"). The whole list pages in. | `AwardDetailView` (`DiscoverView.swift:403-475`) is text only, 12 entries per category, with nothing to open. | M | Yes |
| V3 | Discover finish | `bp-discover-wash.tsx`; `bp-discover.tsx:261-263` "{n} picks, refreshed daily"; `bp-people-band.tsx:52,74` "{n} award wins", "Start at number one" | A colour wash from the focused cell, headers on the "Picked for you" rails, and award counts on people. | None of these. | S | Low |

### Home, rooms and cards (6)

| # | Gap | Upstream | What it does for the viewer | TV today | Size | Worth it on TV? |
|---|---|---|---|---|---|---|
| H1 | Row edge navigation | `bp-row-see-all.ts`, `use-bp-focus.ts` | Right on a row's last tile reaches the row's See all. Left from See all returns to that tile. Left at the start of a row reaches the tabs. | `BPRowView.swift` has no `onMoveCommand`. PROJECT_STATE lists this as open. | S | Yes |
| H2 | Continue Watching time left | `bp-cw-row.tsx:46-65` | "42m left", "1h 5m left", "Almost done"; anime shows "Episode 12" rather than S/E. | "NN% left" (`ContinueCardView.swift:67`). | S | Yes |
| H3 | Per-room empty and error states | `bp-movies.tsx`, `bp-shows.tsx`, `bp-anime.tsx`, `bp-service.tsx`, `bp-home.tsx` | Room-specific copy: "Add a TMDB key in Setup to power this view." with **Open Setup**, "Anime is hidden", "No movies to show yet", and the service-filter note. | One generic "Couldn't load this room." with Try again (`RoomView.swift:57`). | S | Yes |
| H4 | Poster chain | `bp-poster-chain.ts` (`useTitlePoster`, `usePosterChain`, `rpdbKey`) | Shows the poster the viewer pinned on desktop, then RPDB rating posters, then localized TMDB art. | Tiles use `meta.poster`. `entry.ts:296` exports `rpdbPoster`, but no caller uses it. | M | Yes, for RPDB users |
| H5 | Quick panel global rows | `bp-quick-panel.tsx:188-226` | Opens anywhere (Y or Tab), including with no title focused. It has Interface sounds (cycle the sound pack), Animated backdrop on/off, and a Controls legend. | `QuickPanelView.swift` opens only on a title and has only title actions. | S | Low |
| H6 | Card options | `bp-tile.tsx:144,229` (`hidePosterTitles`, `cardBadgeLimit`) | Hide the title on poster cards; cap the score chips per card. | Titles always follow the tile rules. `ScoreChipsView.swift:8` has a fixed `limit = 4`. | S | Low |

### Search and Library (3)

| # | Gap | Upstream | What it does for the viewer | TV today | Size | Worth it on TV? |
|---|---|---|---|---|---|---|
| L1 | Keep state across tabs | `lib/search-context.tsx`, `bp-view-state.ts` | The query, results and Library tab survive a trip to another tab. | `ShellView.swift:119-124` rebuilds `SearchView()` and `LibraryView()` on every switch, so their `@StateObject`s reset. PROJECT_STATE lists this as open. | S | Yes |
| L2 | Per-addon result plates | `search/bp-search-group.tsx`, `search/bp-search-results.tsx` | Every addon has a fixed slot: a quiet placeholder while it answers, "Didn't answer" with Try again when it fails. The rows do not jump. | Late rows are inserted in place. Failed addons only appear in the empty-state count (`SearchView.swift:371`). There is no retry. | S-M | Medium |
| L3 | Library auto-paging | `bp-library-sections.tsx` (sentinel) | The grid loads more as the ring nears the bottom. | A "Show more (n of m)" button (`LibraryView.swift:339`). | S | Low (the button works well on a remote) |

### Live TV and Sports (3)

| # | Gap | Upstream | What it does for the viewer | TV today | Size | Worth it on TV? |
|---|---|---|---|---|---|---|
| X1 | Search playlists for a channel and pin it | `sports/bp-sports-broadcast-search.tsx` | Type a channel name, match it across every playlist, play it, and "Always use for {league}". | The picker lists only auto-matched channels (`SportsEventView.swift:300-340`). When nothing matches, its note tells the viewer to "Search your channels", but no text search exists. Only the addon panel has a field. | S-M | Yes |
| X2 | Saved event and feed notes | `sports/bp-sports-event-hero.tsx:285-291` | "Showing saved match details." when offline, plus source notes for TheSportsDB, ONE Championship and promoter-published cards. | None. | S | Low |
| X3 | Live band art | `bp-live-split.tsx`, `use-bp-live-panels.ts` | The Home Live band shows two channels' art side by side, plus a fallback ladder of panels. | `HomeBands.swift` shows a single still or mosaic. | S-M | Low |

### Profiles, onboarding and account (4)

| # | Gap | Upstream | What it does for the viewer | TV today | Size | Worth it on TV? |
|---|---|---|---|---|---|---|
| O1 | Who's watching on return | `lib/profiles.tsx:569-580` (`profilePromptInterval` 15m / 30m) | After 15 or 30 minutes away, Who's watching comes up again when Harbor returns to the front. | `profilesRoom.launchPicker` applies the interval on a cold launch only (`AppModel.swift:316`). `AppLifecycle.swift` does not check it on foreground, and tvOS usually resumes apps rather than relaunching them. PROJECT_STATE lists this as open. | S | Yes (multi-profile homes) |
| O2 | Avatar and name write-back | `components/harbor-avatar-sync.tsx`, `harbor-name-sync.tsx` (mounted by `bp-tv-app.tsx`) | An avatar or name picked on the TV reaches the Harbor account (social, Together). | `engine/together.ts:340` reads the alias only. Nothing is pushed. | S-M | Low. It writes to the account, so it needs the same care as sync writes. |
| O3 | Setup poster wall | `onboarding/bp-onboard-backdrop.tsx` | Drifting poster columns behind the setup steps. | None. PROJECT_STATE lists this as open. | S | Low |
| O4 | TMDB step feedback | `onboarding/steps/bp-step-tmdb.tsx:156-165` | A live "{n} of 32 characters" count, and separate messages for "rejected" and "could not reach TMDB". | `TmdbStep.swift` merges the two errors and checks the length only on Verify. | S | Low |

### Counts

| Area | Gaps | S | S-M | M |
|---|---|---|---|---|
| Player | 10 | 7 | 1 | 2 |
| Stream picker | 4 | 2 | 1 | 1 |
| Detail and Person | 5 | 3 | 2 | 0 |
| Discover and Awards | 3 | 2 | 0 | 1 |
| Home, rooms and cards | 6 | 5 | 0 | 1 |
| Search and Library | 3 | 2 | 1 | 0 |
| Live TV and Sports | 3 | 1 | 2 | 0 |
| Profiles, onboarding and account | 4 | 3 | 1 | 0 |
| **Total** | **38** | **25** | **8** | **5** |

No L-sized gap remains in the Big Picture scope. The large items left are blocked on tvOS or on the
owner (see below).

### Not counted

- **Blocked on tvOS** (PROJECT_STATE Next §3): hero and ambient trailers (`use-bp-trailer.ts`,
  `bp-trailer.tsx`, need yt-dlp), seek thumbnails (`use-trickplay.ts`), subtitle Auto sync
  (`bp-subtitle-tune.tsx` "Auto sync" / "Use it" / "Revert", needs subsync + audio extraction),
  YouTube Music.
- **Owner decisions or deliberate differences** (PROJECT_STATE): TV collection edits are not
  published; curfew "Switch profile" without the parent PIN; a deep link under a kid profile; Top
  Shelf (needs a second signed target); sports odds (`bp-sports-extra-odds.tsx`, deliberately left
  out in `engine/sportsEvent.ts:178`, off by default upstream); Download for offline
  (`use-bp-detail-actions.ts`, PLAN §5); Settings "Phone setup is off / Turn on phone setup" (the
  port's LAN page starts on demand).
- **Desktop, pointer or keyboard only upstream:** `bp-exit-confirm.tsx` / `bp-exit-preview.tsx` /
  `bp-entry-button.tsx` / `use-bp-fullscreen.ts` (return to the desktop window); the subtitle "Load
  file" / "Local subtitle" options and "In your local library" marks (no local files on a TV);
  `bp-player-identity.tsx` "Casting"; the injected-ad report button and the P2P chip
  (hidden in ten-foot by `showChrome`, `player.tsx:1223-1227`; the port does honour `autoSkipAd`
  segments and shows torrent peers in its connecting card); the stats overlay (toggled only by a keyboard shortcut); `volumeBoostMax` and the
  volume HUD (the TV owns volume); `bp-onboard-keyboard.tsx` (the port uses the tvOS keyboard and
  the phone link); the "Kids profiles are not available in Big Picture yet." notice (desktop Big
  Picture only; the port supports kid profiles).
- **Infrastructure SwiftUI replaces:** `bp-focus-core.ts`, `bp-logic.ts`, `bp-ring-motion.ts`,
  `bp-track-glide.ts`, `bp-art-*.ts`, `bp-card-visible.ts`, `use-bp-auto-page.ts`,
  `bp-page-skeleton.tsx`, `bp-page-message.tsx`, `bp-empty.tsx`, `bp-routes.tsx`,
  `bp-error-boundary.tsx`, `player/bp-player-slots.tsx`, `player/use-bp-player-keys.ts`, and the
  `*-key.ts` / `*-ring.ts` helpers.
- **Checked and present** (the sweep flagged these, but the grep found them): the settings catalog
  rows (Show Sports, Picture quality, Preferred home server, Hide watched, Animated backdrop:
  `engine/settingsRoom.ts` bundles `bp-settings-catalog.ts`), the anime room rows, the sports row
  copy, the Library search, the Discovery Queue "will not come back" confirm, the sports who panel
  (`SportsWhoView.swift`), the onboarding steps (all ten), the Letterboxd rows on Movies, per-page
  row customisation, the picker kid auto-play plate, and the stream-bundled subtitles.
