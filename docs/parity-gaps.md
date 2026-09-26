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

### Where this audit stands (end of 2026-09-25)

Cross-checked against `PROJECT_STATE.md` → Status up to device-flow pass 11 (22:54 UTC). The tables below
keep what the audit found; their first column now says what happened to each row.

**Closed.** 30 of the 38 rows are fully ported: P1, P2, P3, P5, P6, P7, P8, P10, P11; S2, S3, S5
(the picker's host match and the player's duration-mismatch chip); D1-D5; V1, V2; H1, H2, H3, H6;
L1, L3; X1, X2; O1 (plus the "Startup & default" rows), O3, O4. Seven are ported in part (P9, S4, V3,
H4, H5, X3, L2; what is left is listed below) and O2 is the owner's. The same day also
closed these Big Picture behaviours that were outside the table:
- bp-view-state keys: Search and Library state across tabs (L1), `sportsMode` per profile, and
  `liveCategory` / `collectionSource` / `collectionCategory` in `ShellViewState`, kept across tabs
  and reset on a profile switch (Live TV keeps a chip only when the viewer picks it).
- use-bp-screensaver `suppressed`: no saver on Who's watching, setup, the intro wall, Live TV or an
  open stream picker; its idle clock restarts when playback starts or ends.
- use-bp-profile-reset: a profile switch opens Home.
- use-bp-hero-cycle: Home's hero keeps cycling while the ring is on a row's See all.
- See all and addon pages retry a failed page with Try again at the end of the grid.
- The music dock over the kids detail page and franchise grid (K1); the Collections offline end line
  (C1); the lyrics' 9 s give-up (music-now-playing.tsx); manga page auto-retry (page-image.tsx).
- Open-items sweep 3 (09-26): Live TV draws the kept liveCategory key again when the source has it
  (A → B → A shows A's chip; bp-live `categories.find(key) ?? All`); the Music room's own dock and
  the Spotify library page hand the ring on after Stop and close player (recoverBpFocus); Home's
  hero pips stay up while the ring is on See all and the cycle turns; the rank tile draws the
  focused scrim and title (bp-tile); Find more rows are keyed with their source
  (bp-subtitle-find `${source}:${id}:${url}`) and a repeated row is drawn once.

**Still open: parity gaps.**
- S4 (ported in part, 09-25 late): the subtitle step runs; what differs is listed under "Still open
  in this scope" below.
- Flag icons: ported (see "Flag icons (FlagStack)" below), except that the flag-icons languages are
  drawn as emoji flags and Catalan, Basque and Galician as their text chip.
- P9: use-track-autoload's automatic subtitle search and its "Search every source again" chip (the
  TV has the manual Find more lane, which shows no source counts). "{count} dl" is ported; the
  offset badge is not a TV gap.
- P8: each opening of the in-place switcher searches the addons again.
- P11: no TV control for snapshot retention, full quality or Clear (desktop only, as in Big Picture).
- H5: opening the quick panel with no title focused (a Siri Remote has no spare button; needs a
  design decision) and the Controls legend.
- H4: the poster pinned on the desktop, the TMDB id lookups some poster hosts need, and TMDB's
  localized poster.
- V3: the "Picked for you" rail headers, and the Discovery Queue band's sampled glow (the TV washes
  in the accent).
- X3: the sampled-glow wash over the Live split, and metahub channel hydration ahead of the XMLTV icon.
- L2: the addon mark on slots that already have titles.
- TMDB episode titles on Continue Watching cards (not ported with H2).
- O2: avatar and name write-back to the Harbor account (owner decision).

**Still open: smaller behaviour differences** (logged as "Open" in the Status lines; low):
- Detail's Play with no resume point starts the first episode of the season chip on screen and
  says so ("Play S3 E1"); upstream's bp-resume-mark plays the first regular episode whatever the
  chip. With a resume point both play it. Left as a TV choice (sweep 3 checked it).
- Specials and episode 0 stay in the episode strip; Big Picture drops them (they no longer
  auto-advance into S1 E1).
- eBook chapters opened from the panel or bar start at line 0; upstream restores the saved line
  (owner to decide, see HANDOFF.md).
- Discover and Collections place no first focus of their own.
- Deep links open once the covers close rather than on top of them, and an install does not close
  the player; a link page over the intro wall on a cold launch, links under the curfew lock or
  screensaver, and a theme or language rebuild dropping a re-presented page are unhandled.
- A sync-pulled theme or language drops a non-player cover.
- Watch Together: an invite to another title waits under a Detail page for the shell's toast; a
  dismissed toast hands the ring to the room's default, not the exact tile; the mismatch chip can
  show the old length for under 1 s after a guest's swap; a host swap stuck connecting holds the
  guests; PiP drops on a live reconnect.
- Up from a tile under its row's See all can land on See all (upstream's Up goes to the row above).
- Onboarding's Harbor step lacks the side cards; there is no client-side 8-character password check.
- The content advisory toast's corner when the stats overlay is up.
- Player panels: the Anime4K sidebar lets the ring reach the chrome; a reload under Subtitles does
  not re-read the offset.

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

Still open from this audit at that point: P5-P11, S4, S5, D4, V3, H4, H5, L2, L3, X2, X3, O2. Most
of these were ported later the same day; the current list is "Where this audit stands" above.

### Player / picker parity pass 2

Ported after the parity batch (player, stream picker and Live TV scope):

| # | What landed | Where |
|---|---|---|
| P5 | use-started-near-end: the first playing reading (a length and a position) taken per stream URL; a stream that started at 80% or later stays on its end: no next episode, no Still watching, no auto-close (the sleep-timer count still runs, as upstream's hook does not read the guard). | `Player/PlayerScreen.swift` `noteStartedNearEnd`, `endedNaturally` |
| P6 | use-video-fill: the synced `cropMode` applies to each new stream. mpv gets panscan / video-aspect-override / keepaspect (Fit sets nothing); AVPlayer follows the html5 bridge (Fill = aspect fill, Stretch = resize, the rest contain). No TV control, as in Big Picture. | `Player/PictureFill.swift`, `Player/MPVPlayerController.swift`, `Player/NativePlayerController.swift`, `Settings/SettingsBridge.swift` |
| P7 | use-content-advisory + content-advisory-toast (`contentAdvisoryToast`, off by default): the IMDb parental-guide rows (known severities, None dropped, highest first, 3-step bars, colored or `contentAdvisoryTheme` monochrome) and the MPA rating, top-start once playback has started, held 28 s, again for a source swapped in place; the imdb id as use-track-autoload resolves it; titles on this device's ignore list are skipped. View-only on the TV (Big Picture's ring does not reach its Dismiss / Ignore buttons). | `engine/player.ts` `contentAdvisory`, `Player/ContentAdvisoryToast.swift` |
| P9 | "{count} dl" on subtitle results goes through t(). | `engine/subtitles.ts` `resultDetail` |
| P10 | use-live-picture-eq: `mpvTweaks` brightness, contrast, saturation, gamma, sharpen (parseFloat, 0 when unset) on the mpv player; html5 / AVPlayer ignores them as upstream's does. | `Player/PictureFill.swift`, `Player/MPVPlayerController.swift` |
| S3 | FormatBadge images: every streamBadges kind (the resolution too, beside the quality pill, as bp-stream-row draws it) as upstream's badge art at size md, less kinds the viewer hid; the badge name when an image is missing. The art is copied from `src/assets/badges` by `tools/sync_upstream_assets.sh`. | `engine/streams.ts` `pickerFormatBadges`, `Streams/StreamBadgeArt.swift`, `Streams/PlayPickerView.swift` `formatBadge`, `project.yml` |
| S5 (picker) | use-bp-streams hostMatch: a guest in a joined room whose host plays this title / episode gets scoreSourceMatch per row; rows read "Same file" / "Close match" (host-match-chip), the host match leads the order in place of the remembered pick, and the saved filter steps aside (bp-stream-filters). Follows the room live. | `engine/together.ts` `hostSourceForMedia`, `engine/streams.ts` `hostMatch`, `Streams/StreamsModel.swift`, `Streams/PlayPickerView.swift` |
| review 18 | The source chip's mode changes in the press and its saves run in order, newest answer wins (a fast double press skipped a step). `homeServers.titleServers` groups the index once per index version and enabled-server set (`mediaServerIndexVersion`), not per Detail load. | `Streams/StreamsModel.swift` `setStreamMode`, `engine/media/index-store.ts`, `engine/homeServers.ts` |

Ported after pass 2 (P8 and S5's player half):

| # | What landed | Where |
|---|---|---|
| P8 | bp-player-sources BpPlayerSources (`<BpStreams mode="switch">`): the player rail's Sources chip (and the connecting card's Switch source) opens the picker itself in its switch mode as a card over the running film, in the player's panel system (Back closes it, the ring goes back to the chip). Same search, chips, filters, host-match order, row labels and resolve path (P2P consent, debrid retries, "Debrid is down"; the dialogs drawn inline, never a cover over the player); "Switch source", "{name} · S1E2 · {shown} of {total} sources", the stream playing now first with "Now playing" (switcher-row isCurrentStream: info hash and file, else URL), no home-server copies, no instant play, footer "Pick a source to swap in place. Playback keeps running.". A pick swaps the stream in place through PlayerScreen.switchStream at use-stream-switcher's resumeAt (the last good spot; a stub's opening spot), with the stream's hints for the engine rule and its own subtitles, and is remembered (savePlayback); the panel closes on the swap and stays open with the reason on a failed resolve. Watch Together keeps the room: no host-leaving and no reopen; a started host holds the room at the swap spot until the new stream plays, the source descriptor follows the new stream (use-host-source, 1.5 s length guard; engine together.sourceDescriptor, smoke). Where the swap can't happen (a home-server copy) the chip still closes and reopens the picker at the spot, with the reopen bookkeeping as before; Live and Sports players have no Sources chip. | `Player/PlayerSourcesPanel.swift`, `Streams/PlayPickerView.swift` `switching`, `Player/PlayerScreen.swift` `switchSource` / `canSwitchInPlace`, `Together/TogetherPlayback.swift` `sourceSwitched`, `Detail/DetailView.swift` (`pickEpisode`) |
| S5 (player) | duration-mismatch-chip: a room guest whose file runs more than 4 s off the host's (hostSourceMatchesMedia on the view's hostSource, now with its episode) gets "Your copy runs {guest}, host's runs {host}. Sync may drift." with "Find closer match" (the in-place switcher, whose rows lead with the host match) and a ✕ that holds for that file pair. TV focus design: bottom-centre over the picture (above the transport while the chrome is up), a soft target like the skip pill: it never takes the ring, Up from the stage reaches it, Menu gives the ring back, and it hides under panels, prompts, error cards and a stream still opening. | `Player/PlayerSourcesPanel.swift` `DurationMismatchChip`, `Together/TogetherModel.swift` `HostSource.episode` |

Ported after P8 (P11 and review 22's open items):

| # | What landed | Where |
|---|---|---|
| P11 | use-exit-snapshot + lib/snapshots: while the video plays a frame is taken 4 s in and checked every 60 s (refreshed after 5 min, never from 92 % on), and on the way out a fresh one is taken (the last good one when there is no picture: no position, near the end, a dead stream). AVPlayer copies it from an AVPlayerItemVideoOutput on the item (HLS and progressive alike; no pixel format asked, so nothing is converted until a copy), mpv through `screenshot-raw` with screenshot-sw on the player's serial mpv queue (ordered before the handle's destroy). Scaled to 320 px (quality 0.65) or, with `cwSnapshotFullQuality`, up to 1280 px (0.9), JPEG, off the main thread; the close never waits for it. Kept in Caches/harbor-cw-snapshots under the id upstream keys it by (cloudWriteId, else the meta id; none for `iptv:`), pruned by `cwSnapshotRetentionDays` (30 by default; 0 keeps none and clears them), 80 frames and 2.5 MB at most, oldest out. The Continue Watching card leads with the frame and falls back to its own art when the file is gone or will not load; not on an Up Next card (continue-card.tsx). | `Player/ExitSnapshot.swift`, `Player/NativePlayerController.swift` `frameOutput` / `grabFrame`, `Player/MPVPlayerController.swift` `grabFrame`, `Player/PlayerEngine.swift`, `Player/PlayerScreen.swift` (tick, `finish`), `Browse/ContinueCardView.swift`, `Settings/SettingsBridge.swift` |
| P8 | The source error card's "Pick another source" opens the in-place switcher (use-stream-switcher pickAnother: "Always open the in-place switcher overlay"); the card steps aside while it is open and comes back when it closes with no swap. Where the switcher cannot swap (a home-server copy, a playlist item, a kid profile) the picker still reopens after the close. | `Player/PlayerScreen.swift` `pickAnotherSource` |
| P8 | Picking the "Now playing" row resolves it again and reloads it in place at the resume spot (use-stream-switcher onSwitchStream has no special case for it), which brings a stalled or dead copy back; the switcher used to just close. | `Streams/PlayPickerView.swift` `row` |
| P8 / Together | A room host's swap in place that fails lets go of the room's hold: upstream never pauses the room for a swap (its heartbeat only goes quiet), so the guests play on from the held spot when the room was playing, rather than wait paused while the host sits on the error card. | `Together/TogetherPlayback.swift` `sourceFailed`, `Player/PlayerScreen.swift` |
| S5 | Closing a switcher opened from the duration-mismatch chip gives the ring to the stage: the chip is a soft target that never takes the ring on its own (as Menu from it does), so Select pauses again instead of reopening the switcher. | `Player/PlayerScreen.swift` `open` |

Still open in this scope:
- P11: no TV control for the retention, full quality or "Clear" (desktop Settings → Library → Home only, as in Big Picture); the hero keeps the title's own backdrop ahead of the frame, as bp-cw-row cwMeta does, so it was left alone. Device check: the AVPlayer frame on HDR and Dolby Vision (the copy is tone-mapped to SDR), mpv's screenshot under MoltenVK with VideoToolbox, the frame's colours on HDR passthrough.
- P9: "Search every source again" belongs to use-track-autoload's automatic subtitle search, which the TV does not run (it has the manual Find more lane). The SubtitleOffsetIndicator only shows for 1.8 s after a keyboard shortcut (use-keyboard-shortcuts), so it is not a TV gap.
- S4 subtitle step, ported (`Streams/SubtitleStep.swift`, engine `subtitles.choices`, the
  `preselect` field of `player.trackPlan`'s memory key). With `subtitlePreselect` on, a manual pick
  in the Detail or Kids picker (addon stream or home-server copy) opens "Choose subtitles": the
  use-subtitle-choices search for the picked stream, language chips with counts, "No subtitles"
  seeded, the best match selected once the list loads, Back / Menu to the list (ring on the row
  picked), Skip (no preselect) and Start playback. Gated as openPlayerGated: not in a Watch Together
  session, not for instant play's auto-fired stream, not for iptv / live, movie / series / anime
  only, never in the in-player switcher (upstream's `mode="switch"` goes through `onPick`, not
  `openPlayerGated`); kid profiles get it too, as upstream. The player hands the choice to the
  engine's track plan, which turns subtitles off or fetches and shows the URL (the remembered
  restore path) in place of the automatic choice and the remembered subtitle. Left:
  - The chosen result's `subtitleLoadMetadataOf` (provider label, classification) is not carried
    into the player's track list; the added track shows its title and language only.
  - Row icons are the language's flag emoji (settingsRoom.flagEmoji), not upstream's `<Flag>` SVG.
  - A stream swapped in place (the source switcher, the kid switcher, a home-server quality change)
    drops the preselect and gets the plan's automatic choice. Upstream keeps `src.subtitlePreselect`:
    a quality change re-applies it on the new URL, and a source switch suppresses the automatic
    choice without re-applying it.
  - A retry or the move to mpv applies the choice again (upstream's preselectAppliedRef keeps it to
    the first open of `src.url`).
  - Sports addon pickers do not offer the step (their players take no preselect).
- Flag icons for stream languages (FlagStack): ported later; see "Flag icons (FlagStack)" below.
- X3 Live band art: ported in parity pass 3 below, except the sampled-glow wash and the channel hydration.

### Flag icons (FlagStack)

components/flag.tsx FlagStack as bp-stream-row.tsx draws it: last in the row's META line, the
stream's `audioLanguages` without "unknown", `max={4} size="md"` (16 px tall, 1.5 x as wide,
radius 2, the faint ring and drop shadow, 4 px apart), "Multi" as the accent "M" chip, a language
with no flag as its first two letters in a quiet chip, then "+{n}". The P8 switcher reuses the row
(upstream's `<BpStreams mode="switch">` reuses bp-stream-row), so it shows the flags too. No setting
hides them upstream.

- **Upstream's own art** (flag.tsx FLAG, 29 languages over 27 files): `src/assets/flags/*.svg` is
  in the upstream repo, not in node_modules. `tools/sync_upstream_assets.sh` writes each one as a
  single-scale imageset with "Preserves Vector Data" into the gitignored
  `App/Upstream/Flags.xcassets` (adding `width`/`height` from the viewBox, which the files lack);
  `project.yml` compiles that catalog with the app's own. The SVGs use only rect, circle, polygon,
  g and one clipPath (Korea), all within CoreSVG.
- **The flag-icons set** (flag.tsx LANG_COUNTRY, 53 languages, `fi fi-{cc}`): that is an npm
  package (`flag-icons`, CSS plus SVGs) which neither CI nor the engine installs; adding it to
  `engine/package.json` would change the lockfile hash and throw away CI's Rust cache. These are
  drawn as the country's emoji flag (Apple Color Emoji: regional-indicator pairs, Wales's tag
  sequence). Catalan, Basque and Galician (`es-ct`, `es-pv`, `es-ga`) have no emoji flag and get
  the text chip ("CA", "BA", "GA").
- A build whose sync step did not run draws the emoji twin of each upstream flag (flag-eng is the
  US flag), so nothing is blank.
- Smoke compares both Swift tables with flag.tsx (5 checks).

Device check: the flags on a stream row (English, a "Multi" release, an Indian-language anime or
film for an emoji flag), Korea's taeguk (the clipPath), and that a long language list wraps with
the other pills rather than squeezing them.

### Parity pass 3 (outside the player and picker)

Ported after pass 2, outside `Player/*`, `Streams/*` and the row navigation files:

| # | What landed | Where |
|---|---|---|
| D4 | lib/character-favorites: Select on an anime character card toggles it in `harbor.charfavorites.v1.<profile>` (upstream's key and entry shape, so the desktop Favorites tab and profile export read it; durable on the TV). The cell is bp-anime-characters' BpCharacterCell: a 2:3 portrait card, the name, the raw role and the compact AniList favourites count, a heart that shows the state always and the affordance under the ring. The Library's Favorites tab says "Your {n} character and manga favorites live on the desktop Favorites tab." when those are all it holds (use-bp-library `hidden`). | `engine/characterFavorites.ts`, `engine/library.ts`, `Detail/DetailModel.swift`, `Detail/DetailView.swift` `characterCell`, `Library/LibraryView.swift`, `Storage/KeyValueStore.swift` |
| V3 | bp-discover-wash: the band holding the ring washes the page in its focused cell's colour (award tile tint, genre palette.from; the accent otherwise) at the band's angle, crossfading. bp-people-band: 2:3 cards with the rank chip and "{n} award wins" (else the first top title), closed by the "Start at number one" / "Top People" lead tile. | `engine/discover.ts` `people`, `Discover/DiscoverView.swift` `DiscoverWash`, `PeopleBandView` |
| H4 | The URL-building half of bp-poster-chain: poster and rank tiles ask `rpdbPoster(settings.rpdbKey, meta.id, meta.poster)` under `settings.posterBaseUrl` (RPDB, BetterPosters, PostersPlus or a template), never resized, and fall back to the sized poster when it fails (usePosterChain onError). | `Browse/PosterChain.swift`, `Browse/BPTileView.swift`, `Browse/ImageLoader.swift` `RemoteImage.fallback`, `Settings/SettingsBridge.swift` |
| H5 | The quick panel's global rows: Interface sounds (Off / Glass, "Sound pack: {name}") and Animated backdrop (On / Off). | `Browse/QuickPanelView.swift` |
| L2 | bp-search-group slots: every addon the query announced keeps its place in installed order; a pending addon holds eight quiet poster plates (not focusable), a failed one says "Didn't answer" with a Try again tile that runs the search again (dimmed while it runs; the ring goes to the keyboard if the tile goes away), an empty one collapses. Addon rows are titled with the addon's name, as upstream. The empty state's Try again (bp-search-empty) is there too. | `Search/SearchModel.swift` `addonSlots` / `retry`, `Search/SearchView.swift` `addonSlotRows`, `SearchAddonPlate` |
| L3 | bp-library-sections: the next page loads as the ring reaches the grid's last two rows (once per page); the "Show more" button is gone. | `Library/LibraryView.swift` `autoPage` |
| X2 | bp-sports-event-hero notes under the actions: "Loading match details...", "Showing saved match details." (a held summary the last refresh could not renew, or a saved match; the Saved pill follows the same rule), the promoter / ONE Championship / TheSportsDB hub provenance, and "Match details are not available right now…" only when nothing is held. The 30 s refresh of a live game re-reads the summary. | `Sports/SportsEventView.swift` |
| X3 | use-bp-live-panels + bp-live-split: 220 ms after a Live channel takes the ring, panel A (the programme's XMLTV icon, else TMDB's backdrop for the programme on now) and panel B (that title's second backdrop) are resolved once per channel (session memory); once both decode the band draws B full, A clipped to the diagonal, the hairline seam, both toned; otherwise the XMLTV icon is the still. | `engine/live.ts` `bandPanels`, `Browse/HomeBands.swift` `LiveSplitArt`, `Browse/RoomView.swift` |

Offline smoke 1096 (14 new checks: character favourites, the Favorites hidden count, the people sub line, the Live panels ladder).

Left in this scope:
- V3: the "Picked for you" eyebrow and "{n} picks, refreshed daily" blurb belong to the rail headers (`BPRailView` in `Browse/BPRowView.swift`, a row navigation file). The Discovery Queue band's wash colour is a sampled glow of its bed art (use-art-glow); the TV samples no art colour, so that band washes in the accent.
- H4: the poster pinned on the desktop detail page (lib/title-poster, a desktop-local store the TV never receives), the TMDB id lookups some hosts need (useRpdbAltId for tmdb ids on a BetterPosters / PostersPlus base, the anime kitsu → imdb/tvdb mapping) and TMDB's localized poster (useLocalizedPoster). Those ids show the plain poster.
- H5: opening the panel with no title focused (upstream's Y / Tab; a Siri Remote has no spare button, so it needs a design decision) and the Controls legend (gamepad / keyboard bindings with no Siri Remote counterpart).
- L2: the addon mark sits on the pending / failed plates only; a slot with titles is drawn by `BPRowView` (row navigation file), whose header has no mark.
- X3: the sampled-glow wash over the split (no art colour sampling on the TV) and the metahub channel hydration ahead of the XMLTV icon (useChannelHydration).
- O2 avatar and name write-back: not ported on purpose. It writes to the viewer's Harbor account, so it is left for the owner.

### Profiles, Kids and Collections pass

Closes the two items device-flow pass 3 left open (no TV rows for the launch prompt options, no music dock on the kids detail page), plus the Collections room offline path:

| # | What landed | Where |
|---|---|---|
| O1 (rows) | views/settings/account/startup-defaults.tsx: a "Startup & default" section after Profiles, shown only with more than one profile (StartupDefaults returns null for one). "Who's watching" (Every launch / Every 15 min / Every 30 min / Never → `profilePromptInterval`) and "Start as" (No default profile, then every profile without a PIN → `defaultProfileId`), with upstream's descriptions. Written through `settings.patchFor` (the active profile's effective settings, as `update()` does); the launch and return prompts already read both keys (engine `profilesRoom.launchPicker` / `returnPicker`, AppModel). | `Settings/StartupDefaultsPanel.swift`, `Settings/SettingsView.swift`, `Settings/SettingsBridge.swift` |
| K1 | App.tsx mounts music-dock.tsx over every view but the player and picker, the kid's "meta" (KidsDetailView) and "grid" (franchise) views included. The kids detail page and the franchise grid are covers over the kids shell (which hid its dock), so each carries the dock and its Now Playing. | `Kids/KidsDetailView.swift`, `Kids/KidsFranchiseView.swift` |
| C1 | bp-collections offline: the community step's failure is reported (`collectionsRoom.all` → `communityFailed`), so the end line is "Community collections are unavailable right now." / "That's everything we could reach. Some sources are unavailable right now." instead of "Nobody has shared a collection yet."; a pull walks pages until one adds a card (STEPS_PER_PULL) and pulls again while nothing was added (AUTO_PULLS), so an offline curated walk (every franchise fails to resolve) reaches TVDB and the end line instead of an empty grid with no spinner and no message. Picking a source again re-runs a failed community / TVDB / curated feed (upstream rebuilds its feed on every source pick). | `engine/collections.ts`, `Collections/CollectionsView.swift` |
| F1 | Focus: the PIN pad sends the ring to Back when the third miss starts the cool-down (it sat on a disabled digit); the profile editor's "Enter PIN to change locks" gets the ring back from the pad (or the first lock tile once unlocked) instead of the Name field. | `Profiles/PinPadView.swift`, `Profiles/ProfileEditorView.swift` |

Left:
- Collections: upstream has no Try again in the room (bp-collections.tsx; retrying is picking a source again), so none was added. With no TMDB key upstream replaces the room with BpConnect; the TV keeps it (Mine, Community and TVDB lists, and the only place to edit collections on the TV).
- "Who's watching background" (account/picker-background.tsx): an image uploaded on the desktop for the desktop picker; Big Picture's chooser does not draw it.
- The "Start as" launch stamps `harbor.profile.lastSelectAt` (ProfilesStore.select); upstream's launchDefault does not, so its first timed prompt counts from the last hand-picked profile. Left as is: without the stamp a TV resumed a minute after launch could ask at once.
- Checked, not a gap: the Play Zone has no dock, as upstream's (kids/play/play-zone.tsx is `fixed z-[150]`, over the dock's `z-[120]`).

### Player (10)

| # | Gap | Upstream | What it does for the viewer | TV today | Size | Worth it on TV? |
|---|---|---|---|---|---|---|
| P2 (ported) | Live auto-reconnect | `views/player/hooks/use-auto-retry.ts:111-160` | When a live channel errors, it reconnects on its own: once before the first frame, twice after playback has started (after 1.5 s or 4 s). | `PlayerScreen.swift` ports only the VOD "premature EOF" branch. A live error goes straight to the error card. PROJECT_STATE lists this as open. | S | Yes |
| P1 (ported) | Audio normalise + audio profile | `lib/player/mpv.ts:168-173,1283-1291`, `use-track-autoload.ts:755-756` | `audioNormalize` and `audioProfile` (bass, voice, bass-reduce, **night**) are applied as mpv audio filters. Both sync from desktop Settings → Audio. | `MPVPlayerController.swift` sets no `af`. `SettingsBridge.swift` has neither key. | S | Yes (mpv engine only; AVPlayer has no filter chain) |
| P3 (ported) | Subtitle font family + ASS override | `use-sub-style-apply.ts:65-67`, `lib/player/sub-presets.ts` | The viewer's subtitle font (Inter, Arabic, …) and `subAssOverride` (no, scale, force) restyle ASS/SSA subtitles too. | `MPVPlayerController.swift:485` always uses `sub-font` "Switzer". It never sets `sub-ass-override`. | S | Yes |
| P5 (ported, pass 2) | Started-near-end guard | `use-started-near-end.ts`, `use-auto-end-exit.ts` | Playback that starts at 80% or later (re-watching an ending) does not auto-exit or auto-advance. | Absent. PROJECT_STATE lists this as open. | S | Yes |
| P6 (ported, pass 2) | Crop / aspect mode | `use-video-fill.ts` (`cropMode`: fit, fill, stretch, zoom, 16:9, 4:3, 21:9) | The crop chosen on desktop applies in Big Picture too. Big Picture itself has no control for it. | No `panscan`, `video-zoom` or `video-aspect-override` anywhere. | S to apply the synced value; M for a TV chip (a deviation from upstream) | Yes (21:9 on 16:9), low priority |
| P7 (ported, pass 2) | Content advisory toast | `use-content-advisory.ts`, `components/player/content-advisory-toast.tsx` via `stage-overlays.tsx:121` | When playback starts: the MPA rating and IMDb parental-guide categories. `contentAdvisoryToast` is off by default. | None. `harbor-imdb` is bundled, but only for episodes and scores. | S-M | Maybe (households with kids) |
| P8 (ported) | Switch source in place | `big-picture/player/bp-player-sources.tsx` ("Pick a source to swap in place. Playback keeps running.") | Opens the source list over the playing film. Picking one swaps the stream at the same position. | Ported: `PlayerSourcesPanel.swift` (the picker's switch mode) swaps in place through `PlayerScreen.switchSource`; a home-server copy keeps the close-and-reopen path. | M | Yes, medium |
| P9 ("{count} dl" ported; the rest open or not a TV gap) | Subtitle small bits | `stage-overlays.tsx:85` `SubtitleOffsetIndicator`; `bp-player-subtitles.tsx:239` "Search every source again"; `bp-subtitle-parts.tsx:184` "{count} dl" | A badge on screen while a subtitle offset is set, a chip that re-runs the automatic subtitle search, and download counts on results. | `PlayerSubtitlesPanel.swift` has the offset stepper and a manual search, but none of these three. | S | Low |
| P10 (ported, pass 2) | Picture EQ | `use-live-picture-eq.ts` (`mpvTweaks` brightness, contrast, saturation, gamma) | Picture adjustments set on desktop also apply on the TV. | None. | S | Low |
| P11 (ported) | Exit snapshot for Continue Watching | `use-exit-snapshot.ts` (`cwSnapshotFullQuality`, `cwSnapshotRetentionDays`) | Saves a frame at exit and uses it as the Continue Watching art. | Ported: `Player/ExitSnapshot.swift` (both engines), frames in Caches; the card falls back to its own art. | M | Low (tvOS caches can be purged) |

### Stream picker (4)

| # | Gap | Upstream | What it does for the viewer | TV today | Size | Worth it on TV? |
|---|---|---|---|---|---|---|
| S3 (ported) | Stream row labels | `bp-stream-row.tsx:265-300,379-387` | "Cached on Real-Debrid", or "In TorBox" when it is your own cloud. "Unverified" or "No Label" when the quality is guessed. DUB/SUB badge (`showDubBadge`). Quality badges follow `showQualityBadge`. | A plain "Cached" badge (`PlayPickerView.swift:686,783`). No confidence label, no DUB/SUB, no badge toggles. | S | Yes |
| S2 (ported) | Remaining picker chips | `bp-stream-chips.tsx:31-47,137-142,186`; `bp-stream-filters.ts:121`; `bp-streams.tsx:380-392` | Mode chip: All sources, Direct/debrid only, P2P only. A preferred-language chip, on by default under `requirePreferredLanguage`. A Refresh chip. A header like "N of M sources · K addons loading". "No sources found". | Only the All sources / Media servers toggle (`PlayPickerView.swift:611-614`). "Asking addons… n/m" shows only before the first result. No language chip, no Refresh. | S | Yes |
| S5 (ported: picker pass 2, player with P8) | Watch Together host match | `components/host-match-chip.tsx` (`bp-stream-row.tsx:327`); `views/player/duration-mismatch-chip.tsx` | A guest sees which rows are "Same file as host" or a "Close match". In the player, a chip warns when the file's length differs from the host's and offers to find a closer one. | `TogetherModel.swift:120` receives `hostSource`, but neither the picker nor the player uses it. PROJECT_STATE lists this as open. | S-M | Yes, for Together |
| S4 (ported in part, see "Still open in this scope") | Subtitle step before playback | `bp-subtitle-step.tsx` via `bp-streams.tsx:337`, `use-bp-stream-play.ts:145-160` | With `subtitlePreselect` on (a desktop setting, off by default), a "Choose subtitles" screen appears between the pick and the player. It has "Skip, let Harbor choose" and "Start playback". | None. The picker goes straight to the player. | M | Maybe (off by default) |

### Detail and Person (5)

| # | Gap | Upstream | What it does for the viewer | TV today | Size | Worth it on TV? |
|---|---|---|---|---|---|---|
| D1 (ported) | Synopsis "Read more" | `detail/bp-synopsis.tsx` (the toggle is the last cell of the actions row) | A long overview that is cut off can be opened in place, and closed again with "Show less". | `DetailView.swift:551` uses `.lineLimit(4)` with nothing to open it. | S | Yes |
| D3 (ported) | Anime "Filler" tag | `bp-anime-seasons.tsx:134` | Filler episodes carry a "Filler" pill in the episode strip. | `DetailModel.swift:186` decodes `filler`, but nothing draws it. | S | Yes |
| D2 (ported) | Hero provenance marks | `detail/bp-hero-notes.tsx` `BpHeroMarks`, `BpTmdbKeyNote` | Marks on the hero: the addon that served the title (its logo and name), "Available in Plex/Jellyfin/Emby" for each connected server that has it, and "Add a TMDB key in Settings to see the cast, crew, and details." | None. Nothing in the port reads `addonOrigin`, and no per-title server availability is looked up. | S-M | Yes (media servers are already ported) |
| D4 (ported, pass 3) | Favourite an anime character | `bp-anime-characters.tsx:116` (`lib/character-favorites`) | Select on a character favourites them. The favourites sync to the desktop Favorites tab. | The ring is there, but Select does nothing (`DetailView.swift:659`: "that store is not ported"). | S-M | Low |
| D5 (ported) | Crew and facts labels | `detail/bp-crew-row.tsx:65-71` (Director/Directors, Creator/Creators, Writer/Writers, Producers, Cinematography, Music, Editor/Editors); `bp-facts.tsx:30-35` (the facts card opens with Directed by, Created by, Written by, Music by, Cinematography); `bp-person.tsx:333` "Top {n}" department rank | The crew row uses role names with singular or plural forms. The facts card begins with the credit rows. A person's department rank shows as a badge. | `engine/detailRoom.ts:71-78` gives the crew row the facts-style labels ("Directed by", "Written by", "Music"), and the facts card starts at Status. No rank badge. | S | Low |

### Discover and Awards (3)

| # | Gap | Upstream | What it does for the viewer | TV today | Size | Worth it on TV? |
|---|---|---|---|---|---|---|
| V2 (ported) | Collections band | `bp-discover.tsx:240-246`, `bp-collections-band.tsx` | "Sagas and series, gathered in the order they were meant to be watched." A Collections band between Genres and Top People. | `DiscoverView.swift` has sections for queue, awards, genres, voyage and people. No collections section. `HomeBands.swift` already has the collections band. | S | Yes |
| V1 (ported) | Award page | `bp-award.tsx`, `use-bp-award-work.ts` | Year and category chips ("All years", "All categories"). Every winner is a poster tile that resolves to a TMDB title and opens its page ("Checking with TMDB…" / "No match found"). The whole list pages in. | `AwardDetailView` (`DiscoverView.swift:403-475`) is text only, 12 entries per category, with nothing to open. | M | Yes |
| V3 (ported except the rail headers, pass 3) | Discover finish | `bp-discover-wash.tsx`; `bp-discover.tsx:261-263` "{n} picks, refreshed daily"; `bp-people-band.tsx:52,74` "{n} award wins", "Start at number one" | A colour wash from the focused cell, headers on the "Picked for you" rails, and award counts on people. | None of these. | S | Low |

### Home, rooms and cards (6)

| # | Gap | Upstream | What it does for the viewer | TV today | Size | Worth it on TV? |
|---|---|---|---|---|---|---|
| H1 (ported) | Row edge navigation | `bp-row-see-all.ts`, `use-bp-focus.ts` | Right on a row's last tile reaches the row's See all. Left from See all returns to that tile. Left at the start of a row reaches the tabs. | `BPRowView.swift` has no `onMoveCommand`. PROJECT_STATE lists this as open. | S | Yes |
| H2 (ported) | Continue Watching time left | `bp-cw-row.tsx:46-65` | "42m left", "1h 5m left", "Almost done"; anime shows "Episode 12" rather than S/E. | "NN% left" (`ContinueCardView.swift:67`). | S | Yes |
| H3 (ported) | Per-room empty and error states | `bp-movies.tsx`, `bp-shows.tsx`, `bp-anime.tsx`, `bp-service.tsx`, `bp-home.tsx` | Room-specific copy: "Add a TMDB key in Setup to power this view." with **Open Setup**, "Anime is hidden", "No movies to show yet", and the service-filter note. | One generic "Couldn't load this room." with Try again (`RoomView.swift:57`). | S | Yes |
| H4 (RPDB / poster-host URLs ported, pass 3) | Poster chain | `bp-poster-chain.ts` (`useTitlePoster`, `usePosterChain`, `rpdbKey`) | Shows the poster the viewer pinned on desktop, then RPDB rating posters, then localized TMDB art. | Tiles use `meta.poster`. `entry.ts:296` exports `rpdbPoster`, but no caller uses it. | M | Yes, for RPDB users |
| H5 (rows ported, pass 3; open-anywhere and the Controls legend open) | Quick panel global rows | `bp-quick-panel.tsx:188-226` | Opens anywhere (Y or Tab), including with no title focused. It has Interface sounds (cycle the sound pack), Animated backdrop on/off, and a Controls legend. | `QuickPanelView.swift` opens only on a title and has only title actions. | S | Low |
| H6 (ported) | Card options | `bp-tile.tsx:144,229` (`hidePosterTitles`, `cardBadgeLimit`) | Hide the title on poster cards; cap the score chips per card. | Titles always follow the tile rules. `ScoreChipsView.swift:8` has a fixed `limit = 4`. | S | Low |

### Search and Library (3)

| # | Gap | Upstream | What it does for the viewer | TV today | Size | Worth it on TV? |
|---|---|---|---|---|---|---|
| L1 (ported) | Keep state across tabs | `lib/search-context.tsx`, `bp-view-state.ts` | The query, results and Library tab survive a trip to another tab. | `ShellView.swift:119-124` rebuilds `SearchView()` and `LibraryView()` on every switch, so their `@StateObject`s reset. PROJECT_STATE lists this as open. | S | Yes |
| L2 (ported, pass 3) | Per-addon result plates | `search/bp-search-group.tsx`, `search/bp-search-results.tsx` | Every addon has a fixed slot: a quiet placeholder while it answers, "Didn't answer" with Try again when it fails. The rows do not jump. | Late rows are inserted in place. Failed addons only appear in the empty-state count (`SearchView.swift:371`). There is no retry. | S-M | Medium |
| L3 (ported, pass 3) | Library auto-paging | `bp-library-sections.tsx` (sentinel) | The grid loads more as the ring nears the bottom. | A "Show more (n of m)" button (`LibraryView.swift:339`). | S | Low (the button works well on a remote) |

### Live TV and Sports (3)

| # | Gap | Upstream | What it does for the viewer | TV today | Size | Worth it on TV? |
|---|---|---|---|---|---|---|
| X1 (ported) | Search playlists for a channel and pin it | `sports/bp-sports-broadcast-search.tsx` | Type a channel name, match it across every playlist, play it, and "Always use for {league}". | The picker lists only auto-matched channels (`SportsEventView.swift:300-340`). When nothing matches, its note tells the viewer to "Search your channels", but no text search exists. Only the addon panel has a field. | S-M | Yes |
| X2 (ported, pass 3) | Saved event and feed notes | `sports/bp-sports-event-hero.tsx:285-291` | "Showing saved match details." when offline, plus source notes for TheSportsDB, ONE Championship and promoter-published cards. | None. | S | Low |
| X3 (ported, pass 3, except the sampled glow) | Live band art | `bp-live-split.tsx`, `use-bp-live-panels.ts` | The Home Live band shows two channels' art side by side, plus a fallback ladder of panels. | `HomeBands.swift` shows a single still or mosaic. | S-M | Low |

### Profiles, onboarding and account (4)

| # | Gap | Upstream | What it does for the viewer | TV today | Size | Worth it on TV? |
|---|---|---|---|---|---|---|
| O1 (ported, with the Startup & default rows) | Who's watching on return | `lib/profiles.tsx:569-580` (`profilePromptInterval` 15m / 30m) | After 15 or 30 minutes away, Who's watching comes up again when Harbor returns to the front. | `profilesRoom.launchPicker` applies the interval on a cold launch only (`AppModel.swift:316`). `AppLifecycle.swift` does not check it on foreground, and tvOS usually resumes apps rather than relaunching them. PROJECT_STATE lists this as open. | S | Yes (multi-profile homes) |
| O2 (owner decision) | Avatar and name write-back | `components/harbor-avatar-sync.tsx`, `harbor-name-sync.tsx` (mounted by `bp-tv-app.tsx`) | An avatar or name picked on the TV reaches the Harbor account (social, Together). | `engine/together.ts:340` reads the alias only. Nothing is pushed. | S-M | Low. It writes to the account, so it needs the same care as sync writes. |
| O3 (ported) | Setup poster wall | `onboarding/bp-onboard-backdrop.tsx` | Drifting poster columns behind the setup steps. | None. PROJECT_STATE lists this as open. | S | Low |
| O4 (ported) | TMDB step feedback | `onboarding/steps/bp-step-tmdb.tsx:156-165` | A live "{n} of 32 characters" count, and separate messages for "rejected" and "could not reach TMDB". | `TmdbStep.swift` merges the two errors and checks the length only on Verify. | S | Low |

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
- **Owner decisions or deliberate differences** (PROJECT_STATE, HANDOFF.md): TV collection edits are
  not published; curfew "Switch profile" without the parent PIN; a deep link under a kid profile
  opening any title; Collections with no TMDB key keeps the feed (upstream shows BpConnect); Top
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
