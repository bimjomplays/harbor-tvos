# Device checklist (real Apple TV)

CI only compiles the app and runs simulator UI tests. The last hardware run was the Stage 0 spike
(mpv HEVC / HDR10 / HDR10+ / DV P5/P8 / PGS / SRT, 09-22). Everything built on 09-23, 09-24 and
09-25 has only run in the simulator. This file collects every "Needs device" / "Untested on device"
note from `PROJECT_STATE.md` → Status, the Next section and `docs/*.md` in one list, deduplicated and
grouped by area. The 2026-09-25 UTC day session's checks (tagged by commit) are in the last section,
with their own "Test first" list. **For the next TestFlight upload, start with "Next TestFlight build"
just below**: it lists what changed since build 220, highest risk first.

Each line reads **action → expected result (source)**. Sources are Status lines as `(MM-DD HH:MM)`
in the status-log clock. Lines without a date are 09-23. `(Next)` is PROJECT_STATE → Next → Then,
item 1. When something fails, note the build number, the engine (mpv or AVPlayer) and the source
type (debrid, torrent, HLS, home server, IPTV).

## Next TestFlight build (first upload since build 220)

Added 2026-09-25 for the upload retried on 2026-09-26. Build 220 carries the branch up to `37aa626`
(~11:07 UTC 09-25); this build carries everything after it (`a8ac757` onward: 2026-09-25 11:02 →
22:45 UTC in `PROJECT_STATE.md` → Status). Collected from those entries' "Device check:" lines and the
fixes they describe, deduplicated, one line each: **action → expected result (`commit`)**. The fuller
wording of the 11:02–14:19 checks is in the "2026-09-25 day session" section at the end of this file.

How to use it: run **Test first**, then the areas in order. Lines marked *(UI test: …)* are already
walked in the simulator by `App/UITests/NavigationTests*.swift` on every CI run, so check them last
(the remote feel and timing are what the simulator can't show). Prerequisites are in "Before you start".

### Test first (highest risk)

- [ ] During a film press Sources on the player rail → "Switch source" opens as a card over the playing film, the ring on the first row, Menu closes it back onto Sources. (`f819778`, `7f0d67a`)
- [ ] In that switcher pick another row, on mpv, on AVPlayer and on a P2P row (the P2P dialog draws inline) → the stream swaps in place at the same spot; the player never leaves the screen; the old torrent is released. (`f819778`)
- [ ] Pick the "Now playing" row in the switcher → it resolves again and reloads at the resume spot; a failed resolve keeps the panel open with the reason. (`0979e99`)
- [ ] Make a stream fail, press "Pick another source" on the error card → the in-place switcher opens (the card steps aside, and comes back if you close with no swap); a home-server copy or a kid profile still reopens the full picker. (`0979e99`)
- [ ] Switch source at ~85 % of a film → it still ends normally (no "started near the end": it moves on, no Still watching loop), the advisory toast does not return, and mute carries over to the new engine. (`50fa9b6`)
- [ ] Press Back while a source switch or channel tune is still settling → the player closes and no new engine starts under it (no audio after close). (`50fa9b6`)
- [ ] As a Watch Together host with a guest, swap source in place → the room stays (no host-leaving); guests hold at the swap spot until the new stream plays; a failed swap lets them play on. (`f819778`, `0979e99`)
- [ ] Play a film on mpv for a minute, press Back → the Continue Watching card leads with a frame from the film; repeat on AVPlayer (HLS and a progressive file). (`0979e99`)
- [ ] Repeat the exit frame on an HDR10 and a Dolby Vision title, on both engines → the card's colours look normal (not washed out or green); mpv under MoltenVK gives a frame; closing does not hitch. (`0979e99`, `ab86b34`)
- [ ] Watch a 4K HDR film on mpv for 6+ minutes → no periodic hitch (mpv grabs only on exit; the 4 s / 5 min grabs are AVPlayer's). (`ab86b34`)
- [ ] Relaunch Harbor → the Continue Watching cards draw their frames at once; after a stream sent back to the picker, the card keeps its earlier frame or art. (`ab86b34`, `50fa9b6`, `3378b13`)
- [ ] Set snapshot retention to 0 (or full quality) on desktop Harbor, let it sync → the TV follows it (frames cleared / sharper frames). (`ab86b34`)
- [ ] Play a film with the controls up, pause a minute, press Play → the seek bar and elapsed/remaining move while playing and stop while paused, "Ends" keeps moving, the controls hide ~4.6 s after Play. (`57bf553`, `89b9ef6`)
- [ ] From any room other than Home, switch profile on Who's watching → the new profile opens on Home; a sync that rewrites the same active profile does not send you Home. (`56796c7`, `87189d8`)
- [ ] Leave the TV idle on Who's watching, setup, the intro wall, Live TV and an open stream picker → the screensaver never comes on there. (`56796c7`, `87189d8`)
- [ ] Watch a film to its end without pressing anything → the player closes and the saver does not come up straight away (its idle clock restarts). (`56796c7`)
- [ ] Play addon series episodes, a multi-file torrent and a home-server title, scrub and open the Sources / Subtitles panels → nothing crashes (Double→Int values are clamped). (`41d5b9b`)
- [ ] With a large Plex/Jellyfin library, open Library → Media Servers, pick filters, force-quit and relaunch → launch is no slower, details show without a refetch, the filters come back. (`5f97a54`, `08b4760`, `5f6d7bd`)
- [ ] Pick a Live TV category chip and a Collections source/category, walk to another tab and back, then switch profile → the chips are kept across tabs and reset for the new profile. (`bb117ed`)
- [ ] Open a `harbor://` link while Detail, the player and the Addons cover are up → it opens once those close (after the film for the player), never twice; a link held behind a film for over 10 minutes is dropped. (`3f4da96`, `5541573`)

### Player & source switching / Continue Watching snapshot

- [ ] Let a stream sit on the Connecting card and press its Switch source → the same in-place switcher opens. (`f819778`)
- [ ] As a room guest whose file runs 4+ s off the host's → "Your copy runs … Sync may drift." shows bottom-centre, never takes the ring, Up reaches it; Find closer match opens the switcher; closing it gives the ring to the stage. (`f819778`, `0979e99`)
- [ ] As a room guest, check picker rows → the host's file reads "Same file" / "Close match" and leads the order. (`abf3055`)
- [ ] Resume a film at 80 %+ (re-watch an ending) → it stays on its end: no next episode, no Still watching, no auto-close. (`abf3055`)
- [ ] Set a crop mode (Fill, 21:9) and a picture look (incl. sharpen) on desktop → mpv and AVPlayer apply the crop; mpv applies the look. (`abf3055`, `3877ddd`)
- [ ] Turn on the content advisory toast (synced setting, off by default) and start a title → the rating and parental-guide rows show top-start for ~28 s, never take focus, and step aside for X-Ray. (`abf3055`, `50fa9b6`)
- [ ] Turn on Normalize loudness / a Sound profile (night mode) under Playback → mpv's audio changes; AVPlayer ignores it. (`feec966`)
- [ ] Pick the Arabic and Rounded subtitle fonts, and Styled (ASS) subtitles → Force on an anime release → mpv draws those faces and restyles the ASS track. (`feec966`)
- [ ] Wait for the skip-intro pill and the up-next card, let the controls hide → they animate, the countdown ticks each second, and the ring stays on the pill/card only while it is drawn. (`57bf553`, `3378b13`)
- [ ] Set a sleep timer, and resume a film to get the resume fork → the Speed & sleep chip counts down; the fork shows the right duration. (`57bf553`)
- [ ] Swap sources in place, then pick a subtitle track → the track memory is saved under the new source's release, not the old one's. (`50fa9b6`)
- [ ] Open the picker on a title with many badges and languages → rows wrap cleanly, badge art is sized right, the language chip can leave under the ring, Refresh works mid-search, chip changes update the list at once. (`ed3ac59`, `abf3055`, `8c5fd7d`)

### Home & browse (Home, Discover, Collections, Calendar)

- [ ] Press Right off a Home row's last tile and Left off its first → See all takes the ring, then the top bar on that row's tab; the hero keeps cycling while the ring is on See all. (`3ca744f`, `cdc57a6`, `bb117ed`) *(UI test: testRowSeeAllEdge covers Right/Left)*
- [ ] Look at Continue Watching cards → "S1 E3 · 42m left" / "Almost done" / "Episode 12"; air countdowns read in your language. (`3ca744f`, `cdc57a6`)
- [ ] With an RPDB key synced from desktop, browse rows including a title with no poster → RPDB posters draw, a bad key does not make posters blink back each visit, the title plate shows only when no art draws. (`c156ac3`, `ee5e7c2`, `f182d83`)
- [ ] Focus a Live channel on Home's Live band (channel with EPG titles) → the split art draws over the still without blinking. (`c156ac3`, `ee5e7c2`)
- [ ] Open See all and an addon catalog page, drop the network and scroll → a failed page shows Try again at the end of the grid; it keeps the ring and hands it to the first new title. (`ac066ca`)
- [ ] Open a streaming-service page with no TMDB key → an empty state with Open settings, not a failure with Try again. (`7a6db3e`)
- [ ] On Discover, move through the bands → the wash takes the focused band's colour; the Collections band parks like the others; Top People loads after Genres and Voyages without pushing the band holding the ring. (`c156ac3`, `3ca744f`, `a3ed212`)
- [ ] Open an award page, page through winners, pick one; open an anime award with the network down → the first winner takes the ring (not All years), "Checking with TMDB…" opens the title, the anime page ends its spinner. (`65e15ea`, `ac066ca`, `7a6db3e`)
- [ ] In Collections open a collection, open a title from it and close it; open a TVDB list → the overlay's ring stays where it was; the TVDB list hands the ring to its first tile once loaded. (`7a6db3e`)
- [ ] Offline, open Collections → the grid ends with "Community collections are unavailable right now." rather than sitting empty. (`8543889`)
- [ ] Back from a film started from a Voyage route slot → the ring is on the slot, not Play. (`bb117ed`)
- [ ] Press Calendar Previous / Next / Today, then a day → the skeleton shows until the new month answers, and the day opens that month. (`a3ed212`)
- [ ] Home band leads: Your streaming → "Manage" opens Settings, Collections → "View all", Your addons has none. (`7a6db3e`) *(UI test: testHomeBandRowLeads)*
- [ ] Discover failure: Down from the bar reaches Try again, a failing retry keeps the ring. (`7a6db3e`) *(UI test: testDiscoverFailedTryAgainReachable, testDiscoverDownReachesBands)*
- [ ] Collections: New collection under Mine, Menu closes it onto New collection. (`7a6db3e`) *(UI test: testCollectionsNewCollectionBack)*
- [ ] Failed Calendar month: Down reaches Try again, which keeps the ring. (`9ab3745`, `dcd9992`) *(UI test: testCalendarFailedTryAgain)*

### Detail / Person / Library / Search

- [ ] Play the last special of a series (and a kids special) to its end → no up-next card into S1 E1; the kids special does not run on. (`cb4164e`)
- [ ] Open a title offline, restore the network, press Try again → the ring goes to Play as soon as the message goes, not seconds later. (`12678e0`)
- [ ] Signed out of Harbor, rate a title → the dialog closes (no "Saved on this device"). (`cb4164e`)
- [ ] Open a person → the ring starts on the first Known For card; Back returns it to the tile you came from. (`cb4164e`, `a90ba7c`)
- [ ] Press Read more on a long overview; check the hero's addon mark on an addon title → it expands in place and Show less closes it; the addon's logo and name show. (`ed3ac59`, `65e15ea`)
- [ ] Select an anime character → the heart toggles; Library → Favorites notes character favourites live on the desktop. (`c156ac3`)
- [ ] Scroll Library to the bottom with the network dropped, then restored → a failed first read says so; paging retries the same page; an empty tab says Loading only on Refresh. (`cb4164e`, `f182d83`, `bb117ed`)
- [ ] On Media Servers wait for details, try each Sort / Direction and the Library / Genre rows, change UI language → Rating/Duration fill in, picks restore, details follow the new language. (`5f6d7bd`, `0438f63`, `08b4760`)
- [ ] Select the search field and dictate with the Siri Remote → the words land in the query and search; only Harbor's drawn stroke shows. (`a90ba7c`, `286c5f3`)
- [ ] Search with one slow and one answered addon, then Try again → the answered row stays, the failed one says "Didn't answer" and retries; Top match opens its title. (`c156ac3`, `f182d83`, `a90ba7c`)
- [ ] A one-season show shows Episodes (no lone Season 1 chip), one Down from Play reaches them. (`cb4164e`) *(UI test: testDetailOneSeasonEpisodesAndBack)*
- [ ] Library Filters: Menu closes the panel onto Filters, a second Menu goes Home. *(UI test: testLibraryFiltersMenuSteps)*
- [ ] Search keeps its query and the ring on the keyboard across Menu → Home → back. (`3ca744f`) *(UI test: testSearchKeyboardAcrossTabSwitch)*

### Settings / onboarding / account

- [ ] With 2+ profiles, set Settings → Startup & default ("Who's watching" interval, "Start as"), cold-launch with each value → the launch follows it; "Start as" paints its theme and language first. (`8543889`, `761d256`) *(UI test: testStartupDefaultsPills covers the pills)*
- [ ] Leave Harbor for 15+ minutes with the 15 min interval, come back → Who's watching comes up (not over a film, PiP, setup or a PIN-locked kid). (`3ca744f`)
- [ ] Sign in to Harbor / Stremio from Settings, then sign out → the ring moves to that section's Sign out, then Sign in; the column updates. (`5bbbf5e`)
- [ ] Settings → Replay walkthrough / Switch profile, then come back → the ring returns to that button; Switch profile from the PiP browse layer leaves no stray ring return for a later Settings visit. (`5bbbf5e`, `e647d54`, `56796c7`)
- [ ] Remove a home server; finish a phone Connect → the ring goes to the next server's Remove; to "Type a key on this TV" when the hand-off completes. (`e647d54`)
- [ ] Onboarding: Continue quickly into Your services and Taste → the ring lands on the first choice once it loads, and stays put once you move. (`5bbbf5e`, `e647d54`)
- [ ] Try a Harbor sign-in with the network down → the network error line (error-messages.ts wording), not a raw code. (`e647d54`)
- [ ] TMDB setup step: a wrong key, then a network that swallows requests → "rejected", then "Could not reach TMDB…" within ~12 s with Save it anyway. (`65e15ea`, `7aa8b2f`)
- [ ] Setup: Menu on Language → "Leave setup?"; Finish later then relaunch with several profiles; Replay → Do not show this again → setup resumes where it should, launch path first. (`a90ba7c`, `b9d4d84`, `286c5f3`)
- [ ] First launch after the intro wall; Create account then Later → Language ring on the current language; the recovery code is revealed. (`a3ed212`)
- [ ] Account menu signed out → "Sign in to Harbor" opens the sign-in form. (`5bbbf5e`)
- [ ] Quick panel: double-press Interface sounds / Animated backdrop; Settings → Animated backdrop off → one flip per press; the mosaic stops at once. (`c156ac3`, `60887f7`)
- [ ] Connect Trakt / Simkl / AniList / MAL → "Connected as …" in your language, green; a failed Anime4K download reads red. (`2c965bf`, `5f6d7bd`)
- [ ] Settings category Menu steps back to the column, a second Menu goes Home. *(UI test: testSettingsBackSteps)*
- [ ] Account bell → menu opens on its first item, Menu returns to the bell. *(UI test: testAccountMenuBackToBell)*

### Profiles / Kids

- [ ] Settings → Switch profile, press Back on Who's watching → the ring returns to Switch profile. (`56796c7`)
- [ ] On a kid profile hit the curfew with the return interval due → the lock ("The ship is sailing away…") comes first; Who's watching is asked after it lifts. (`56796c7`, `87189d8`, `9ab3745`)
- [ ] Profile editor → "Enter PIN to change locks" → after the pad the ring is back on that button (or the first lock tile). (`8543889`)
- [ ] Kids: play the last episode of a season → the up-next card crosses into the next season and skips unaired episodes; hero Play after picking another season still auto-advances. (`60887f7`, `5d8a86b`)
- [ ] Kids: the season stepper's ends dim (the ring stays); the music dock shows on a kid's title page and franchise grid. (`60887f7`, `8543889`)
- [ ] Kids age gate: answer a round wrong → the re-deal starts the ring on the first answer. (`9ab3745`, `dcd9992`)
- [ ] A kid profile active at launch never gets adult setup. (`286c5f3`)
- [ ] PIN pad: third miss puts the ring on Back, the end of the cool-down re-seeds 1. (`8543889`) *(UI test: testPinCooldownRing)*
- [ ] Kids Parent PIN: Menu / ‹ returns the ring to the profile chip. (`60887f7`) *(UI test: testKidsParentPinBackToChip)*
- [ ] Failed kids page: one Down from each bar item reaches Try again. (`9ab3745`) *(UI test: testKidsFailedTryAgainReachable)*

### Live TV / Sports

- [ ] Pull the network on a live channel for a few seconds → it reconnects by itself (1.5 s / 4 s); the error card only after the tries run out. (`feec966`)
- [ ] Let the guide fail late with the ring in the grid → the list opens on the same channel. (`5d8a86b`, `64ca414`)
- [ ] Leave the in-player TV Guide open a few minutes → "{n}m left" and the airing bars move each minute. (`6ac33ed`)
- [ ] Search channels in Arabic; double-press the Look steppers; zap a channel → the Arabic query matches; one step per press; the chrome line follows the guide. (`5d8a86b`)
- [ ] Press Clear in Live / Manga / eBook search → the ring goes to the field and the keyboard does not open. (`288f4df`)
- [ ] Sports event → "Search your channels": type a name, play a result, pin one → it plays; "Always use for {league}" is tried first next time; a failed first read shows the no-channel note. (`65e15ea`, `7aa8b2f`)
- [ ] Sports addon panel: pick slow listing A, Back, B, Back, A, press Play as streams show → A's stream plays, no "Could not start". (`43f6f6a`, `286c5f3`)
- [ ] Sports: open the addon panel and an addon's page; leave Sports on a mode over midnight → focus lands on the first listing / the action button; the date rolls over once and the mode is kept per profile. (`2b7f97a`)
- [ ] Open a live event, then drop the network across a 30 s refresh → "Showing saved match details."; Stats and Lineups stay. (`c156ac3`, `ee5e7c2`)
- [ ] Event → Choose a channel, play, Back; expand the standings and open a cover → the ring returns to Choose a channel; the table stays expanded with no "Loading match details..." flash. (`56d3886`)

### Music / Manga / eBook

- [ ] In an album of 5+ tracks turn on Shuffle and Repeat all, let it run past the end → gapless hand-offs, a new shuffled lap at the end; the modes survive a relaunch. (`6b01a08`)
- [ ] Repeat one on a streaming track and a Spotify track; change shuffle/repeat from Control Center → each replays, Next still moves on; the dock and Now Playing follow. (`6b01a08`)
- [ ] Play next on a heard track, under shuffle then Repeat off, and on a wrapped row → it plays next and the order carries on with nothing skipped. (`531cb93`)
- [ ] With music loaded (playing or paused), open the manga zoom and eBook narration and press Play/Pause → the reader gets it; the music does not toggle. (`7386342`, `54d217a`)
- [ ] Start eBook narration while a music track is still finding its source → the track is queued paused, not started over the narration. (`54d217a`)
- [ ] Change the eBook text size / font during narration → the highlight stays on the read paragraph. (`7386342`)
- [ ] Make a manga page fail; zoom a fit-height page and pan → it retries once after 1.5 s; the pan stays inside the page. (`7386342`)
- [ ] Make an eBook chapter fail, press Try again → the ring lands on the page. (`7386342`)
- [ ] Open Lyrics, skip tracks quickly → no "No lyrics" over the next track's lookup (9 s give-up). (`54d217a`)
- [ ] Music queue Move up / down → the ring follows the moved row. (`288f4df`)
- [ ] Stop and close the player from the music dock on a kids page, a music page and music search → the ring lands on a nearby control, not nowhere. (`bb117ed`)

### Watch Together

- [ ] As a TV guest: host buffers, give the guest a slow source, drop the TV's network ~30 s → no seek every second or heartbeat; the guest rejoins and resyncs. (`a8ac757`)
- [ ] As a guest in a paused room press Back ("Leave the show?") → the room is not paused by it; Keep watching leaves the video to the room. (`a8ac757`)
- [ ] Host moves to the next episode while the TV guest is in the player or on Detail → one invite toast (Join, 4 s auto-join), no second Back; the lobby does not read the guest ready too early. (`a8ac757`, `95f1be7`, `9a9daa1`)
- [ ] As a guest, open the invited title's Detail page before joining → "{name} started watching" with Join / Dismiss, not a picker with no way out. (`9a9daa1`)
- [ ] As a guest, hold Select on a card when an invite arrives; get a re-invite after leaving the player → the invite waits for the menu; the closed video does not reopen. (`9a9daa1`, `a8ac757`)
- [ ] Get an invite while browsing in the PiP layer; summon a title (Sure) then receive an invite in the room screen → toasts show in the right window; no unseen auto-join. (`a8ac757`, `6ac33ed`)
- [ ] Start a room / Join by code; open the in-player typing sheet and close it → the ring goes to Now watching (else Message); typing returns to its button. (`9ab3745`, `dcd9992`)
- [ ] Dismiss an invite toast, or let an auto-joined title page close → the ring goes to the room's default spot, not wherever tvOS drops it. (`bb117ed`, `fc919bc`)
- [ ] Desktop host at 1.5× with the TV as guest → the TV plays at 1.5× and returns to its own speed after leaving. (`a8ac757`)
- [ ] Watch together from the account menu: first action seeded, Back and Menu return to the item. *(UI test: testWatchTogetherFromAccountMenu)*

### Shell / lifecycle / screensaver

- [ ] Change the theme and then the language → LB/RB still switch tabs afterwards. (`56796c7`)
- [ ] Cold-launch with a big library → the boot splash animates smoothly (the engine is no longer built on the main thread). (`56796c7`)
- [ ] Watch the top-bar clock → it turns on the minute. (`56796c7`)
- [ ] Open a link under the PiP layer's page, then restore; send a list link under a kid, then pick an adult → it opens in the layer's window; the list waits for the adult shell. (`3f4da96`, `5541573`)
- [ ] Send a link while a page is still opening → it opens after, not lost and not twice. (`5541573`)
- [ ] On an Apple TV HD open the Together room QR, sign-in QR, Detail with episode stills, the picker and Lyrics → no stutter. (`8c5fd7d`)
- [ ] With VoiceOver on, walk the guide, the player's track dialogs, a tile with marks and the collection editor → labels read; picks read as selected. (`b40d1a5`)
- [ ] Switch the UI to German → the controller toast, "All addons", Play Zone names, PIN pad titles are translated. (`1cabd7e`)
- [ ] Menu on Detail returns Home with the ring on the card; the profile chip opens Who's watching and Menu closes it. *(UI test: testDetailBackKeepsHomeFocus, testProfileChipWhoBack, testWhoPinBackAndPick)*
- [ ] A failed room's Try again is reachable and keeps the ring through a failing retry. *(UI test: testRoomTryAgainKeepsRing)*

## Before you start

**Build.** Merge `claude/determined-hopper-smvu37` into `main` (or open a PR), run `Build` with
`testflight=true`, and install that build from TestFlight (internal testing). TestFlight build 220
(2026-09-25) carries the branch up to `37aa626`; later work waits for the next upload (Apple's daily
upload limit refused run 221's upload; the retry is set for 2026-09-26).

**Hardware.**
- An Apple TV 4K running the current tvOS. Multiview and Anime4K assume the A15 model.
- An HDR10 / Dolby Vision TV with Settings → Video and Audio → Match Content (Dynamic Range and
  Frame Rate) turned on.
- An iPhone on the same Wi-Fi, for phone hand-off, typing and QR codes.
- Optional: a second device or account for Watch Together, and a desktop Harbor to compare sync.

**Accounts and keys.** Use test accounts where you can. Never commit any of these.
- A Harbor account, for sign-in and profile/settings sync.
- A Stremio account with Cinemeta, one stream addon, and a few library titles with watched episodes.
- A TMDB API key. Check it first under Settings → Artwork and rows → Test saved key, because
  services, the Collections row, detail extras, X-Ray and more stay empty without it.
- Trakt and Simkl accounts. Each signs in with a device code or PIN on the TV.
- AniList and MyAnimeList accounts. Each connects by QR code, then the code is pasted back.
- A Letterboxd username for public mode.
- A Plex and/or Jellyfin/Emby server with a video library and a music library. Navidrome/Subsonic
  is optional.
- A Spotify **Premium** account and your own Spotify developer app (client ID). In development
  mode, add the listening account under Users Management.
- A Last.fm API key and secret.
- An OpenRouter and/or Groq API key for AI search.
- A debrid service (Real-Debrid, AllDebrid, TorBox, Premiumize, …) configured in a stream addon.
- An IPTV playlist, either M3U or Xtream Codes, ideally with an XMLTV guide and catch-up channels.
- A Suwayomi server for manga. Optional: an API-Sports key and a Discord or Telegram webhook.

**Test media.**
- An HEVC HDR10 MKV with 5.1 audio.
- A Dolby Vision (profile 5 or 8) MP4.
- A plain HLS stream.
- Files with embedded subtitles: tx3g, HLS WebVTT and CEA-608 for AVPlayer, PGS/ASS for mpv.
- A release with a commentary audio track.
- A multi-episode series.
- An anime series with a TVDB mapping, and one without.
- A well-seeded torrent.

## Smoke pass (30 minutes)

These are the highest-risk changes. Run them first, in this order.

- [ ] **PiP browse layer.** On the AVPlayer engine, start Picture in Picture, pick Browse Harbor,
  move between tabs, press Play/Pause, then use the PiP restore button. Then start PiP again and
  close the PiP window. → Focus and keys stay in the layer and the film keeps playing. Play/Pause
  toggles the film. Restore brings back the full player. Close stops and saves while you keep
  browsing. Menu at the layer's Home returns to the placard. (09-25 04:10, 04:30)
- [ ] **Spotify playback.** Sign in to Spotify with the phone paste-back, then play, pause, seek
  and skip a track over HDMI. → Audio plays, pause/seek respond within about 0.5 s, the next
  track starts on its own. (09-24 21:00, 22:30)
- [ ] **Stall/error skip.** With instant play on, Play a title whose first auto pick fails. →
  That source is marked dead, the picker reopens in auto mode and the next source plays. A
  fake-cached file under 3 min shows "Last source wasn't actually cached…". (09-25 02:10)
- [ ] **Track memory.** On episode 1, choose an audio and subtitle language, then let it advance
  (on mpv, then on AVPlayer). → Episode 2 opens with the same tracks. Subtitles you turned off
  stay off, and a commentary track is never auto-picked. (09-25 00:30, 01:20)
- [ ] **Now Playing on AVPlayer.** Press Siri Remote Play/Pause once during an AVPlayer film,
  then open Control Center. → Exactly one toggle, with no double pause/resume. Control Center
  shows Harbor's title and art, not AVKit's. (09-25 01:10, 01:45)
- [ ] **Music volume default for existing users.** On a profile that already had music recents
  or liked tracks before this build, open Now Playing. → Volume reads 100 %. A fresh profile
  reads 82 %. Both keep their level after relaunch. (09-25 04:20, 04:45)
- [ ] **Stremio watched-mark writes.** On Detail, hold Select on an episode, choose Mark as
  watched, then check Stremio or the desktop app. Then unmark it. → The episode shows as
  watched in Stremio, and the unmark round-trips. (09-25 00:45, 01:30)
- [ ] **AVPlayer Auto mode.** Play an HLS stream, a DV MP4 and an MKV with the engine on Auto.
  → The HLS stream and the DV MP4 open on AVPlayer and the MKV on mpv. A codec failure falls
  back to mpv once, at the same position. (09-24 15:20, Next)
- [ ] **HDR/DV matching.** Play the HDR10 MKV on mpv and the DV MP4 on AVPlayer, then close each
  one. → The TV switches to HDR10 or DV, and back to SDR after closing. The PiP second layer
  does not break DV. (09-23 morning, 09-24 20:00, 22:00)
- [ ] **Torrent streaming.** Accept P2P consent and play the torrent, seek, then close. → The
  connecting card shows peers, speed and readiness. Playback starts and seeking works.
  `Caches/torrent-engine` is emptied about 1 s after closing. (09-24 13:40, Next)
- [ ] **Phone hand-off.** Open Settings → Connect and scan the QR code. → tvOS shows the Local
  Network prompt, the phone page loads, and signing in on the phone signs the TV in.
  (09-24 12:50, Next)
- [ ] **Embedded subtitles on AVPlayer.** Play files with tx3g, HLS WebVTT and CEA-608 subtitles,
  and try Sync and Look. → Harbor's overlay draws them (not AVKit), and offset and style apply.
  (09-24 22:00)
- [ ] **Home server auto-play.** Set the play preference to Home server, press Play on a title
  your Plex/Jellyfin has, then switch Quality. → The server copy auto-plays and the quality
  switch happens in place. The transcode stops when you close the player. (09-25 01:00, 01:50)
- [ ] **Overlay windows.** Let the screensaver start, or a kid profile's curfew lock, over a
  playing film and over the account menu. → Both show on top and take focus, and the remote
  works again after you dismiss them. (09-24 20:00)
- [ ] **Language switch.** Change the UI language to German, then to Arabic. → All visible text
  changes at once without a relaunch, and Arabic lays out right to left. (09-24 17:30, Next item 2)

## Playback core: mpv and AVPlayer

- [ ] Play the HEVC 5.1 MKV and the PGS/SRT files on mpv. → They play as in the 09-22 spike
  (a regression check). (PLAN Stage 0)
- [ ] With the engine forced to AVPlayer, play something only mpv can handle. → The player offers
  "Use mpv engine". (09-24 15:20)
- [ ] Open and close the player ten times, alternating engines. → No crash, audio stops at once,
  and nothing keeps sounding. (09-24 20:00)
- [ ] During playback, open the account menu and another cover over the player. → Playback keeps
  going. (09-24 20:00)
- [ ] Press Home to leave the app during a film. → The film pauses and a Multiview tile goes
  quiet. (09-24 17:00)
- [ ] Set Settings → hwdec to Off and play an HEVC file. → mpv plays with software decoding;
  previews still use VideoToolbox. (09-25 01:00)
- [ ] Turn on Anime4K (HQ mode) for 1080p anime. → The shaders compile under MoltenVK/libplacebo,
  the corner indicator shows, and playback stays smooth. A chain that mpv rejects is dropped.
  (09-23 14:30, 16:00)
- [ ] Watch a stream stall on the connecting card. → Go back / Try again / Switch source appear
  after 8 s. (09-23 23:15)

## HDR / Dolby Vision display matching

- [ ] Close the player after an HDR film. → The TV returns to its SDR home mode. (09-24 20:00)
- [ ] Play DV on AVPlayer, then start PiP. → DV stays matched with the second AVPlayerLayer.
  (09-24 22:00)
- [ ] From the PiP browse layer, open an HDR film on mpv. → Display criteria follow the new
  player's window and the TV switches mode. (09-25 04:10)
- [ ] Switch live channels with Match Content on. → One blank at most, not two. (09-24 14:20)
- [ ] Watch Multiview tiles and the guide/Home previews. → They never change the display mode.
  (09-24 14:20, 10:45)

## Torrents

- [ ] Play a torrent. → Enough peers connect without UPnP or port forwarding, and the readout
  moves. (09-24 13:40)
- [ ] Seek far ahead in a torrent. → Range reads fetch the new position and playback resumes.
  (09-24 13:40)
- [ ] Watch a large file, then relaunch the app. → Leftovers are swept at start and disk use stays
  under the 10 GB cap. (09-24 13:40)
- [ ] On a kid profile, play a peerless torrent. → The kid loader shows the torrent readout, then
  "No peers found" with Go back / Try again. (09-24 23:45, 23:55)

## Player features

### Subtitles, tracks and track memory
- [ ] On AVPlayer, add an online subtitle (Find more), then use Sync, Look and "2nd". → All four
  work on the native engine. (09-24 18:00)
- [ ] Pick a subtitle by hand before the saved track plan loads. → Your pick stays; the late plan
  does not override it. (09-25 01:20)
- [ ] Add an external subtitle on episode 1, then play episode 2 of the same release. → The added
  subtitle is restored. (09-25 00:30)
- [ ] Play with secondarySubLang set on a kid profile, and in a Multiview tile. → No automatic
  second subtitle appears. (09-25 01:20)

### Skip, Still watching, sleep timer, speed
- [ ] With auto-skip intro on, resume an episode partway into the intro. → It skips once, only
  after playback starts, and never jumps from the pre-resume position. (09-25 01:10)
- [ ] Focus the skip pill and its ✕. → It is reachable with Up and does not steal focus, and ✕
  hides it. (09-25 01:10)
- [ ] Let three episodes auto-advance without pressing anything. → "Still watching?" takes focus
  with a 45 s Stop countdown, and Back stops. (09-25 01:10)
- [ ] Set the sleep timer to 30 min and to End of episode. → It pauses at 30 min. End of episode
  stops at the credits without advancing (a deliberate deviation). (09-25 01:10)
- [ ] Change speed to 1.5× on both engines and use Set as default. Replay the same show and a
  different one. → The speed is right on both engines. The same show keeps its own rate, other
  shows get the default, and kid profiles are always 1×. (09-25 01:10, 03:45, 03:55)

### Now Playing and remote
- [ ] On mpv, check Control Center and use the remote's play/pause and skip. → Harbor's Now
  Playing shows and the commands work, with a 350 ms double-press gate. (09-25 01:10)
- [ ] Start a film while music plays, then close it. → Music stands down during the film and its
  Now Playing comes back after. (09-25 01:10)
- [ ] Start a Spotify or music track while a film is playing. → It is queued paused and the film
  is not interrupted. (09-24 20:00, 21:30)

### Picture in Picture and the browse layer
- [ ] Start PiP, then press Home to leave Harbor. → The film keeps playing in PiP. Closing the PiP
  window while Harbor is in the background pauses it. (09-24 22:00, 23:15)
- [ ] Try a PiP start that fails or times out. → Focus stays where it was. (09-24 23:15)
- [ ] Turn on subShowInPip. → Embedded subtitles show inside the PiP window. Added subtitles do
  not (known gap). (09-24 22:00)
- [ ] Leave the layer open for 10+ minutes, with progress saves and scrobbles running. → Progress
  and scrobbles land. Memory holds with two shells (no jetsam). (09-25 04:10)
- [ ] From the layer, open another video, then a Multiview. → The PiP film stops (and saves)
  first, and the new one plays. (09-25 04:10)
- [ ] Let the PiP film end and auto-advance, or ask Still watching. → The layer lowers first. An
  end with no next episode closes the player and PiP (known). (09-25 04:10, 09-24 23:15)
- [ ] Switch profile while the layer is up. → The layer ends cleanly. (09-25 04:10)
- [ ] Open a `harbor://detail/...` deep link while the layer is up. → It opens in the layer, not
  the hidden shell. (09-25 04:40)
- [ ] Change the language in the layer, and move focus around. → The language applies at once, and
  UI sounds play while the only film is in PiP. (09-25 04:40)
- [ ] Send yourself a Watch Together invite while the layer is up. → Only the visible shell shows
  it. (09-25 04:30)
- [ ] Close Multiview while its full player is up, then play music and wait for the screensaver.
  → Music, previews and the screensaver all work (no orphaned claim). (09-25 04:30)
- [ ] Watch Still watching's countdown while PiP is on. → It waits until PiP ends (known).
  (09-25 01:45)

### X-Ray
- [ ] Pause with the chrome up, move into the cast list, open View all, and open a person page.
  Press Menu and Play/Pause at each step. → Focus moves in and back out, the person page opens
  inside the player, and Menu closes one level at a time. (09-25 03:05)
- [ ] Try X-Ray during PiP and on a kid profile. → It is hidden in both. (09-25 03:05, 03:30)

## Picker, stall skip and home servers

- [ ] Turn on autoNextStreamOnStall (synced from desktop). Test on mpv and AVPlayer. → A pick that
  hasn't started within the wait moves to the next source. The picker reopens without a long gap.
  (09-25 02:10)
- [ ] Make an auto pick fail five times. → After the 5th attempt the error/connecting card stays
  (no loop). (09-25 02:40)
- [ ] Watch the auto step during instant play, then press Back. → The blurred art, "Trying source
  n" and "Choose a source instead" show. Back cancels auto. (09-24 23:55)
- [ ] With a saved stream filter synced from desktop, cycle the filter chip in the picker. → It
  narrows the list, and the fallback banner shows when the filter is empty. (09-25 01:00)
- [ ] Take the preferred home server offline and press Play. → No auto-play (the 5 s health
  check), and the full picker opens. (09-25 03:45, 03:55)
- [ ] Compare posters at each posterQuality setting. → Higher settings look sharper. (09-25 01:00)
- [ ] Play a home-server title partway, then close it. → Progress is written back to Plex or
  Jellyfin. (09-23 21:45)

## Home, Detail and Anime

- [ ] Open Home with Trakt/Simkl connected, and with the UI set to Arabic or Russian with a TMDB
  key. → The late rows (Trakt/Simkl rails, ar/ru rows) land without moving focus. (09-25 00:50)
- [ ] In Settings → Home rows, reorder, hide, rename and reset. → Home follows each change.
  (09-25 00:50)
- [ ] Finish an episode, then return Home. → Continue Watching shows the next episode as Up Next.
  A caught-up show leaves the row, or shows a countdown with animeCwEnd, and focus holds on the
  late re-read. (09-25 02:30)
- [ ] With spoiler masking on, move focus along the episode strip. → Stills, titles and
  descriptions stay blurred until focused, and the next-up card is exempt. (09-25 00:45)
- [ ] Mark a season as watched. → The marks reach Simkl and AniList (anime). (09-25 00:45)
- [ ] On anime detail with a TVDB mapping, move from the hero to the season chips, then to the
  strip. → Named season chips show year spans and counts. Focus moves hero → chips → strip.
  (09-25 02:20)
- [ ] Switch the episode order, back out, and reopen. → The order persists, including deep in a
  detail stack. (09-25 02:20, 03:45)
- [ ] Look for a TVDB-only episode card, then mark a season from its chip. → The card plays, and
  only aired episodes of that chip are marked. (09-25 02:20, 02:40)
- [ ] Open an anime with no TVDB mapping. → It falls back to the Kitsu season buttons. (09-25 02:20)
- [ ] Press a Kitsu season before the TVDB chips arrive. → Focus hands off to the matching chip.
  (09-25 03:45, 03:55)
- [ ] Open the Anime room, then Settings → Tune anime and toggle genres. → Top Picks for You lands
  first, and it rebuilds about 1 s after the last genre toggle. (09-25 02:30, 03:45)

## Music and Spotify

- [ ] Sign in to Spotify on the phone with Safari and with Chrome. → Both browsers show the
  127.0.0.1 redirect page, and pasting it back signs the TV in. (09-24 21:00, docs/music-spec.md)
- [ ] Play Spotify over HDMI and over AirPlay audio, with Harbor in the background. → Audio plays
  on both routes and keeps playing from the TV home screen. (09-24 21:00)
- [ ] Put the TV to sleep for an hour, then play Spotify. → It signs in again from the saved
  credentials once. (09-24 21:00)
- [ ] Open Spotify library: Load more, create a private playlist, then hold Select on a track and
  choose Add to playlist. → Pages append without duplicates. Only editable playlists are enabled.
  (09-24 22:30, 23:30)
- [ ] With a sign-in from before the modify scopes, use Reconnect for permission. → The library
  and the Add sheet refresh after the sheet closes. (09-24 22:30, 23:30)
- [ ] Pause Spotify for a minute, then resume. → It resumes promptly after the output stopped.
  (09-24 22:30)
- [ ] On Now Playing, check the focus order, then step with − / + and mute. → The volume row sits
  under the transport, which stays on screen. Steps are 5 %. Spotify changes are heard within
  about 0.5 s. (09-25 04:20, 04:45)
- [ ] Play SoundCloud HLS and Jellyfin/Plex FLAC tracks. → Gapless hand-off, and play/pause from
  Control Center and the remote. (09-24 17:00, docs/music-spec.md)
- [ ] With Navidrome/Subsonic, sign in and play FLAC and an Opus file. → Raw FLAC plays, Opus falls
  back to MP3, and scrobbles appear on the server. (09-24 18:20)
- [ ] Approve Last.fm by QR, play past half of a track, then skip one quickly. → One scrobble for
  the first track, none for the skip. (09-24 18:20)
- [ ] Nudge the lyrics tab and Start radio. → LRCLIB timing is right and the queue grows near its
  end. (09-24 18:20)

## Live TV and Multiview

- [ ] Open four Multiview tiles in 2x2 on the A15. → All decode smoothly, and only the selected
  tile has sound. (09-24 14:20, Next)
- [ ] Leave the app with Multiview up, then come back. → The tiles stop, then recover.
  (09-24 20:00)
- [ ] Dwell on the guide, move away, then return to a row. → The mini preview starts. Two mpv
  instances back to back do not fail. (09-24 10:45, Next)
- [ ] Dwell on the Home Live TV row, then open a cover. → The muted preview starts after about
  1.6 s and stops under the cover. (09-24 13:20, 20:00)
- [ ] Play a past guide programme on a catch-up channel. → It plays as a seekable replay with the
  REPLAY chip. (09-23 19:30)

## Kids

- [ ] Play from a kid profile. → The deep-sea loader covers the stage until playback. Cancel and
  Back close it without a leave dialog, and it holds the focus ring. (09-24 23:45)
- [ ] Use instant play on a kid profile. → The kid auto-play screen shows, with "P2P · Searching
  sources…" after 6 s and "Stream is taking a while" after 25 s. (09-24 23:55)
- [ ] In the Play Zone, open Games, scroll the grid and open a game. → Thumbnails load, focus moves
  into and out of the panel, and the QR code opens the Scratch page on a phone. Back returns to
  the card. (09-25 04:50)
- [ ] Let the curfew allowance run out during playback. → "Time's up!" shows over the player, which
  exits. The parent PIN unlocks. (09-24 20:00, 09-23 23:45)

## Addons, AI search and Voyages

- [ ] In Addons → Organize, press Select to grab a row, move it and save. → Focus follows the row,
  and the account order reads back correctly. (09-25 01:40, 02:00)
- [ ] Configure an addon through its QR code on the phone. → The install link comes back to the TV
  and the addon is installed or updated. (09-25 01:40)
- [ ] Turn on adult addons. → The age gate takes focus. Browse on the live stremio-addons.net
  loads and pages. (09-25 01:40)
- [ ] Type an OpenRouter and a Groq key on the phone, hold Select for the models, then search. →
  Keys show masked. Real searches return picks. Keys survive a relaunch (Keychain). (09-25 03:00)
- [ ] Open an AI episode pick. → The strip lands on that episode, not the resume point. (09-25 03:45)
- [ ] On Discover, scroll to Voyages, start one, pick a film, and return. → The banner scrolls and
  a 2-item marquee loops without a gap. Focus follows the re-ranked headings, and the film
  autoplays over the voyage. (09-25 03:15, 03:20, 03:45)

## Settings, sync, profiles and Keychain

- [ ] Switch themes and turn UI sounds on. → The theme applies across the shell. Sounds play on
  focus and click, and stay silent during playback. (Next, 09-24 12:10)
- [ ] Install a newer TestFlight build over this one and relaunch. → Keychain-held sessions and
  keys (Trakt, Simkl, Spotify, AI search, trackers, API-Sports) are still there.
  (09-25 03:00, 09-23 09:00)
- [ ] Delete a profile that had AI keys. → Its AI search keys are gone. (09-25 03:30)
- [ ] Rename a profile and change a setting on the desktop, then pull on the TV. → The roster and
  settings apply on the TV, and the TV's changes reach the desktop. (09-23 11:00)
- [ ] Long-press a top-bar tab: hide it, Show all tabs, Reset layout. → The bar follows, and Home
  stays first. (09-24 19:30)

## Phone hand-off and QR

- [ ] Open a phone-typing field (Search "Type on your phone", a URL field, the TMDB key). → Text
  typed on the phone appears on the TV. (09-24 12:50)
- [ ] Connect AniList and MyAnimeList by QR code and paste the code back. → Both connect, and their
  rails show in the Anime room. (09-23 19:15)
- [ ] Scan the trailer QR code, and try Open in YouTube. → The YouTube app, or the phone link,
  plays the trailer. (09-24 09:30)

## Other rooms

- [ ] Read a long manga chapter in long-strip mode with prefetch. → Memory stays bounded and the
  app is not killed. (Next, 09-24 16:00)
- [ ] Start Watch Together on two devices, and use the Room chip mid-play. → Play, pause and seek
  sync against the live relay, and the Room chip opens during playback. (09-24 16:30, 20:00)
- [ ] Open an eBook and use narration. → Pages turn with Left/Right, and AVSpeechSynthesizer reads
  paragraph by paragraph. (09-24 19:00)

## Localization

- [ ] Change the language with a sheet (cover) open. → The sheet follows too. If `Text("…")` does
  not switch, fall back to the Bundle swizzle. (09-24 17:30)
- [ ] Check plurals in German and Arabic, including counts like "{n} results". → Plural forms are
  correct. (09-24 17:30)
- [ ] Compare the TestFlight app size against the previous build. → Locale bundles don't bloat it
  unexpectedly (36.5 MB of raw catalogs). (09-24 17:30)
- [ ] Have a native speaker read screens in each language, especially the Apple TV-only strings
  from `tools/locales-tvos.json`. → The wording reads naturally. They were machine-written and
  never reviewed. (09-24 23:00, 09-25 00:10)

## 2026-09-25 day session (device-flow passes, reviews 5–15)

Added 2026-09-25. Collected from every `2026-09-25 HH:MM UTC` entry in `PROJECT_STATE.md` → Status
(00:25 → 14:19 UTC) that ends with "Device check:" or "Needs a device check:", deduplicated and
grouped by area. The `HH:MM (09-25)` entries ran on 09-24 UTC and are covered by the sections above.
Each line reads **action → expected result (`commit`)**; the tag is the short hash of the commit that
made the change. TestFlight build 220 carries the branch up to `37aa626`; anything tagged with a later
commit (`a8ac757` onward) needs the next upload (run 221 hit Apple's daily limit).

### Test first (playback, saves, launch/setup, Watch Together sync, storage)

- [ ] Play a film, cut Wi-Fi at the router for ~20 s mid-film, then restore it → the player reloads once from where it stopped (not 0:00 or the resume point); if that fails the source error card shows (no frozen frame) and Try again resumes from that spot. (`2a72fd4`)
- [ ] Let a stream die mid-film, then press Switch source (or Sources) in the player and pick another → playback resumes at the last spot the picture reached, not at 0:00. (`f581714`)
- [ ] On a Stremio profile, disconnect the network, play a film for a minute, then press Back to close → the player pauses at once and is gone within ~2 s; a second Back does not reopen "Leave the show?"; reopening the title resumes at that spot. (`3eddbee`)
- [ ] Watch the last minutes of a series episode and of an anime episode, then return to Detail → the card shows ✓, the strip parks on the next-up card, Play names the next episode (anime after E1–E5 says S1 E6, not S1 E1), and Stremio shows the episode watched. (`e7c38bf`, `52c7828`)
- [ ] Play a film with the controls up, then pause it for a minute and press Play on the remote → seek bar and elapsed/remaining move each second while playing and stop while paused, the "Ends" time keeps moving while paused, and the controls hide ~4.6 s after Play (also after a Watch Together host's Play). (`57bf553`, `89b9ef6`)
- [ ] Open the picker on a title while slower addons and the debrid library are still answering, and pick a row the moment it appears → exactly the stream you picked plays (not a neighbour), and the focused row is not rebuilt under the ring. (`2392e15`, `cd5e678`)
- [ ] With instant play on, open a title whose auto candidate fails after the source search has finished → auto-play moves on to the next candidate instead of hanging on the auto step. (`2392e15`, `fb19d4a`)
- [ ] Press Select on a Continue Watching episode card → the picker (or instant play) opens once, right after the title's meta loads, while art and extras are still loading underneath. (`3b64ad2`)
- [ ] In a music album with 5+ tracks, turn Shuffle on and Repeat all, and let tracks end by themselves through the end of the album → each next shuffled track starts gaplessly, and at the end a new shuffled lap starts. (`6b01a08`)
- [ ] Delete and reinstall Harbor, go through first run and choose "Start watching" (or "Finish later") → you land in the app as the new profile, not on a one-face "Who's watching?"; relaunching goes straight in too. (`761d256`)
- [ ] During setup, stop on a middle step (e.g. Layout), force-quit Harbor from the app switcher and relaunch → setup resumes on that step, and a Stremio sign-in made earlier in setup is still there. (`d3bd57b`)
- [ ] With several profiles, press Menu on setup's Language step → Finish later, then relaunch → the launch path runs first ("Start as" default or Who's watching, with the PIN if any), then setup continues on the saved step for the picked adult profile. (`286c5f3`, `b9d4d84`)
- [ ] Settings → Onboarding → Replay walkthrough, then Menu → Finish later; repeat and choose Do not show this again → Finish later resumes on the same step next launch; Do not show ends setup (the next Replay opens on Language); profiles, sign-ins and settings are unchanged and leaving setup returns to the same profile. (`b9d4d84`)
- [ ] With a resumed setup pending, relaunch and pick a kid profile on Who's watching → the Kids shell opens (behind its PIN / curfew) with no adult setup over it; setup waits for an adult pick. (`b9d4d84`, `286c5f3`)
- [ ] Host a room on the TV with a guest (second TV or desktop), then press Next episode, let auto-advance run, and use Switch source → guests pause at the spot while you pick, then follow; you stay host and they get the invite. (`0d0e98a`, `4d8b324`)
- [ ] As the TV host, open Switch source / Next / wait for auto-advance, then back out of the picker without playing → guests are told the host left the video, are not held paused, and the host role passes on. (`f581714`)
- [ ] Host a room from desktop Harbor at 1.5× with the TV as guest → the TV plays at 1.5×; after leaving the room it is back at its own speed. (`0d0e98a`)
- [ ] As a TV guest, let the host's stream stall, then give the guest a slow source → the guest is not sent back once a second, and a guest still buffering after a sync seek is not re-seeked at every heartbeat. (`a8ac757`)
- [ ] As a TV guest, drop the TV's network for ~30 s mid-room, then restore it → the guest rejoins and resyncs to the host's position. (`a8ac757`)
- [ ] As a guest in a paused room, press Back ("Leave the show?"), then Play/Pause; open it again and choose Keep watching → Play/Pause closes the dialog like Back, the guest never starts playing alone, and the dialog does not pause the room. (`6622588`, `a8ac757`)
- [ ] On a profile with a large Plex/Jellyfin library, open Library → Media Servers, wait for Rating/Duration to fill, pick filters, then force-quit and relaunch → launch is no slower than before, Media Servers shows details at once without refetching, and the saved type/server/sort/direction/genre filters come back. (`5f97a54`, `08b4760`, `5f6d7bd`)

### Home / Browse

- [ ] Launch into Home → the ring lands on the first Jump back in card once Continue Watching loads, not on a catalog row with the CW row appearing above it. (`8c104a8`)
- [ ] Hold Select on a Continue Watching card and choose "Remove from Continue watching" → the panel closes, the card leaves, and the ring moves to its neighbour (an emptied row hands it to the rail). (`187aa8d`, `f829e93`, `8c104a8`)
- [ ] Watch a few minutes of a Continue Watching title, then close back to Home → its card resumes at the new spot without a relaunch. (`8c104a8`)
- [ ] Move focus down the Home rail → each row parks just under the hero copy (posters never under the title/description or in the top fade), the hero title/logo draws over the rail, and the focused tile and row draw over their neighbours. (`784f5cc`, `0c0761f`)
- [ ] On a slow network, stay on a Home row while rows above it are still arriving → the rail re-parks on the focused row as rows arrive or leave. (`8c104a8`)
- [ ] Open See all on a row and an addon catalog page, and scroll → the grid starts under the hero, five columns fit the page, and focus rings are not clipped. (`0c0761f`)
- [ ] Open the Movies tab and a streaming-service page → the ring lands on the first row at once, not held on the tab bar for ~3 s. (`fd3e5d6`)
- [ ] On a slow Home, press Up to the tab bar and walk the tabs right away → the late first-focus seed never pulls the ring back off the bar. (`fd3e5d6`)
- [ ] On Anime, move from a row up to Resume / More Info → the buttons, their meta line and the hero copy name the hero's lead title, not the last card passed. (`a716631`)
- [ ] On Home and Shows, press Up from Jump back in to the "Your library" link → it is reachable and opens Library (hidden while Library is PIN-locked). (`a716631`)

### Detail / picker

- [ ] Open a title's stream picker → the ring lands on the first row (the home-server copy, else the first stream), also after the Auto step or a dialog. (`f829e93`)
- [ ] Open a series whose resume episode is in the season already shown → the strip parks on the resume or next-up card (unless the ring is already in the strip), and cards draw their resume bar. (`52c7828`)
- [ ] Open Facts, Awards, Rate and List on Detail → every line and button shows the ring; Rate closes after a score or Remove; List's Create/Cancel keep the ring. (`52c7828`)
- [ ] Switch the season chip to a season without the resume episode → its strip opens at the first card, not at the previous season's scroll. (`2392e15`)

### Player

- [ ] Let a stream sit on the Connecting card, then press Menu → it acts as "Go back"; the card's 2 s / 8 s / 22 s steps appear on time. (`2a72fd4`, `57bf553`)
- [ ] Open the Subtitles, Audio or Quality panel from the rail, then close it; then press Menu to put the transport away → the ring returns to the chip that opened the panel, and after Menu it is on the stage so the next Select pauses. (`3eddbee`)
- [ ] Resume a film to get "Pick up where you left off" and press Play/Pause; then press Back and Play/Pause under "Leave the show?" → the fork takes the focused choice (no 0:00 start behind it) and shows the right duration; under the leave dialog Play/Pause is Keep watching. (`3eddbee`, `57bf553`)
- [ ] Let the skip-intro pill and the up-next card appear → they animate in and out and the up-next countdown ticks each second. (`57bf553`)
- [ ] Set a sleep timer → the Speed & sleep chip's countdown ticks down while playing. (`57bf553`)

### Subtitles

- [ ] Play a Stremio addon stream that ships its own subtitles, on mpv and then on AVPlayer → they appear in the Subtitles dialog (auto-picked only for your preferred language when the file has no better track), and a pick is remembered for the next episode. (`7202a85`)
- [ ] Play a Plex or Jellyfin title that has an external .srt, on both engines → the .srt is listed in the Subtitles dialog and displays when picked. (`7202a85`)

### Watch Together

- [ ] As a TV guest, hit a source error and press Try again (also after a move to mpv) → room sync keeps following the host. (`0d0e98a`)
- [ ] As a TV guest without PiP, press the TV button mid-room, wait, then return → the room did not restart a paused guest while away, and it resyncs on return. (`0d0e98a`)
- [ ] As host, switch source mid-film with a TV guest → the guest says ready again and resumes in sync. (`a8ac757`)
- [ ] As host, move to the next episode while the TV guest is in the player or on Detail → the guest follows with one invite toast (Join, 4 s auto-join), with no second Back. (`a8ac757`, `9a9daa1`)
- [ ] As a guest, open the invited title's Detail page before joining → the page shows "{name} started watching" / "Pick your source" with Join or Choose and Dismiss, not a picker with no way out. (`9a9daa1`)
- [ ] As a guest, hold Select on a card so its menu is open when an invite arrives → the invite waits until the menu closes. (`9a9daa1`)
- [ ] As a guest, leave the player and let the relay re-invite you (rejoin or reconnect) → the video you just closed does not reopen by itself. (`9a9daa1`, `a8ac757`)
- [ ] Get a room invite while browsing Harbor in the PiP layer → the toast shows in the layer's window. (`a8ac757`)
- [ ] In the room screen, summon a title (Sure), then receive an invite → the invite waits under the summon title page; no unseen auto-join, no double toast. (`6ac33ed`)

### Live TV

- [ ] In the guide, press Right from a channel cell → focus lands on the programme airing now; a new chip or source reopens the guide on now. (`ace7304`)
- [ ] Zap through a few channels in the player, then press Back → the ring is on the channel that was playing. (`ace7304`)
- [ ] Open the in-player TV Guide on a large playlist and leave it open a few minutes → focus lands on the playing channel, and "{n}m left" and the airing bars update each minute. (`2a72fd4`, `6ac33ed`)
- [ ] In Sources, press Remove on a playlist → a "Remove playlist "{name}"?" alert asks first; Cancel keeps it. (`ace7304`)
- [ ] Settings → Live TV → playlists row → the Sources sheet opens over Settings (not the Live tab), and closing it returns to Settings. (`ace7304`)
- [ ] Open Live TV → Playlists, scroll past the first 60 movies, play one and press Back → the grid keeps its length and the ring stays on that movie; open a show, press Back → the ring is on that show. (`56d3886`)
- [ ] On the Favorites chip, unstar a channel (guide and list) → the ring moves to the next favourite; unstarring the last one puts it on the Favorites chip. (`56d3886`)
- [ ] Sources → Remove a playlist → after the alert the ring is on the next source's Remove (Close when none is left). (`56d3886`)
- [ ] Leave Home on the Live TV row across a programme change → the progress bars move and the new programme shows. (`56d3886`)

### Sports

- [ ] Open Sports for the first time → the consent title stays pinned, the notice scrolls with "Read the rest", and the actions stay pinned; a viewer who already consented sees no flash of it. (`e1ecf78`)
- [ ] Focus the Sports hero and wait → the hero stops cycling while it holds focus (and with Reduce Motion on). (`e1ecf78`)
- [ ] Open an event with no channel and press Set up Live TV → the setup plan / picker opens and hands off to Live TV. (`e1ecf78`)
- [ ] Open an event's addon panel, wait for streams, then press Back → focus is on the first listing, then the first stream, then the first listing again (not the search field). (`2b7f97a`)
- [ ] In the addon panel pick a slow listing A, Back, pick B, Back, pick A again, and press Play as soon as streams show → A's stream plays; no "Could not start". (`43f6f6a`, `286c5f3`, `8314373`)
- [ ] Leave Sports open on a mode across midnight, then leave and return → the date band and "today" roll over once, and the mode is kept per profile. (`2b7f97a`)
- [ ] Open an event, press Choose a channel → the ring lands on the first entry; Menu returns it to Choose a channel; pick a channel, press Back in the player → the ring is on Choose a channel. (`56d3886`)
- [ ] Expand the standings, open Addon sources or the player, then go back → no "Loading match details..." flash, the table stays expanded. (`56d3886`)

### Addons

- [ ] Open an addon page and press Install / Update, and install one through the Install dialog → the page opens on its action button, the button changes in place and keeps the ring, Install stays busy until done, and Done takes focus. (`2f7f274`, `2b7f97a`)
- [ ] In Organize, move a row to the very top and the very bottom, then restore → focus follows the moved row, and the first row is focused after a restore. (`6d18ae2`)
- [ ] Open an addon's setup dialog and send its link from the phone → the link stays in the field after the phone sheet closes, and the success card closes itself. (`2b7f97a`)
- [ ] On Installed press Remove on a middle addon → the ring moves to the next addon's Remove (the Installed tab when the list empties). (`56d3886`)
- [ ] In Organize, press Reload list or Move all to account → the list stays on screen and the ring lands on the first row. (`56d3886`)

### Library / Media Servers

- [ ] Open Library → the grid is five columns inside the page, and tab focus rings are not clipped. (`0c0761f`)
- [ ] Open the Filters, Search or Repair panel, then press Menu → the panel closes first and the ring returns to its chip. (`9a33e87`)
- [ ] Press Show more (also on Media Servers while details are still landing) → the ring moves to the first new tile and stays there. (`9a33e87`, `08b4760`)
- [ ] Switch to the Trakt tab, then remove the last Watchlist title → the new tab shows a spinner (not the last tab's grid), and the emptied grid hands the ring to the selected tab chip. (`2392e15`)
- [ ] Switch sort and tab → the View row shows only for Recent with a dated title (never on Media Servers), and Year only when a title has one. (`9d9b369`)
- [ ] On Media Servers, try each Sort (Date added / Title / Year / Rating / Duration) with both Directions, then leave and return → order changes with missing values last, the group row is headed "Media Servers", and the picks are restored. (`5f6d7bd`)
- [ ] Wait for Media Servers details, then use the Library and Genre rows and re-sort → Rating/Duration have values, options show counts, 0-count chips are dim but focusable, picks restore on return, and a re-sort that moves the focused tile hands the ring to the tile in its place. (`0438f63`)
- [ ] Pick a filter immediately after opening Media Servers → your pick shows at once and the saved filters are not reset to defaults. (`5f97a54`)
- [ ] Change the UI language while Media Servers details are loading, then open Library → details show in the new language, never the old one. (`08b4760`, `5f97a54`)

### Search

- [ ] Open Search → the ring is on the keyboard, once per visit. (`9a33e87`)
- [ ] Select the search field and dictate with the Siri Remote mic → the words land in the query and search. (`a90ba7c`)
- [ ] Focus the search field → only Harbor's drawn stroke shows (no system field look on top), and typed text is not doubled. (`286c5f3`)
- [ ] Search, then press Select on Top match → it opens that title. (`a90ba7c`)
- [ ] Open a person from People, then press Back → the ring is back on that person tile. (`a90ba7c`)
- [ ] In AI mode, type a query and dismiss the keyboard with Menu → note whether the AI search runs (the keyboard's Search should run it); nothing runs twice. (`286c5f3`)
- [ ] Hold Select on a recent query to remove it → the chip goes and the ring lands on a neighbour or the keyboard. (`a90ba7c`, `286c5f3`)
- [ ] On a person page with no titles for the rating, press "Any rating" → the ring moves to the Rating row's chip. (`9d9b369`)

### Profiles / launch / setup

- [ ] Open Who's watching from the profile chip and press Back; with the launch prompt on, relaunch and press Back → it closes onto the active profile (the app does not close), and the ring starts on the active tile. (`fab315e`)
- [ ] Create a Harbor account on the TV → its one-time recovery code is shown. (`5e5e2af`)
- [ ] Enter a wrong PIN until the cool-down, wait it out → the keypad re-seeds on "1". (`fab315e`)
- [ ] Open a `harbor://` deep link while Who's watching is up → it waits for your pick, then opens under that profile. (`fd3e5d6`)
- [ ] On setup's Stremio or Harbor step, sign in from the phone while the step is up → it shows "Signed in as" with Continue. (`d3bd57b`)
- [ ] First launch after the intro wall → setup's Language ring is on the current language, so one OK does not switch to English. (`a3ed212`)
- [ ] On setup's Harbor step (it opens with the ring on Later), press Create account, then Later before the code arrives → setup comes back to the Harbor step and reveals the recovery code. (`a3ed212`, `a90ba7c`)
- [ ] Press Menu on setup's Language step, then Menu again → "Leave setup?" (Keep setting up / Finish later / Do not show this again) opens, and the second Menu closes it with the ring back where it was. (`a90ba7c`)
- [ ] With a resumed setup, press Back on Who's watching → no loop back into Who's watching and no dead end; setup continues for the adult profile. (`b9d4d84`, `761d256`)
- [ ] On a Who's watching with no profiles, press "Continue with a local profile" → it continues into the app. (`761d256`)
- [ ] Set a "Start as" default whose theme and language differ, then relaunch → the first screen is already in that theme and language, with no repaint. (`761d256`)

### Settings / trackers

- [ ] Pick a new Display language → after the rebuild the ring is back on that cell, not the top bar. (`4befac9`)
- [ ] Settings → Trakt → Connect, then Cancel while the code waits → the code is cancelled and the ring stays on the same button. (`4befac9`)
- [ ] Settings → Interface: audition a sound pack, then press Back → the saved pack plays again. (`ae63dfe`)
- [ ] Open the Plex server list, the Jellyfin/Emby form and a Home rows rename editor, pressing Menu in each → Menu closes the form or editor first, not Settings. (`ae63dfe`)
- [ ] Start a Jellyfin connect (or a Plex code) and walk to another section before it finishes or expires → the ring is not pulled back to Add Plex. (`cd5e678`)
- [ ] Sign out of Harbor and of Stremio; connect Letterboxd slowly and walk away, then Disconnect it → the ring follows to that section's Sign in / Connect, and stays where you went during a slow connect. (`9d9b369`, `6622588`)
- [ ] Rename a Home or Anime row while another device removes that row → the editor closes and the ring lands on the Rename of the row now in its place. (`7e017d0`)
- [ ] Trigger a failed Anime4K download → the note reads "Download failed" in red, in any language. (`5f6d7bd`)
- [ ] Press a busy button (Pull now, Test, Connect, Sync, Load more) twice quickly → it dims, keeps the ring, and runs once. (`55d98fd`)

### Kids

- [ ] Open the Play Zone, play an activity (pop bubbles, reach the win card), close it → the ring starts on the first activity, never jumps to the header's Back, and returns to the activity just closed. (`d3bd57b`)
- [ ] Play a title on a kid profile → the kid time bar moves each second. (`57bf553`)
- [ ] Play music, then switch to a kid profile → the music dock shows, and page focus is not stuck on it. (`6b01a08`)

### Music

- [ ] Set Repeat one on a streaming track and on a Spotify track → each replays when it ends by itself, and Next still moves on. (`6b01a08`)
- [ ] Use Control Center (and the remote's commands) to change shuffle and repeat → the mode changes, and the dock and Now Playing show it. (`6b01a08`)
- [ ] Without shuffle, choose Play next on a track already heard → it plays next, then the album continues after the current track (no jump back). (`531cb93`)
- [ ] With shuffle on, Play next a track, then set Repeat off and let it play out → the pick plays next, then the rest of the dealt order with nothing skipped, stopping at the real end. (`531cb93`)
- [ ] Under Repeat all after the wrap, choose Play next on a row before the current track → it moves to right after the current track. (`531cb93`)
- [ ] With the dock showing, open an album, artist or playlist page → the page opens on Play, not the dock. (`73a636e`)
- [ ] Open the Lyrics tab mid-track → it scrolls straight to the sung line. (`73a636e`)

### Manga / eBook

- [ ] Open the eBook reader bar → it is two rows with all nine buttons on screen, and the page count sits in the bar header. (`e55f015`)
- [ ] In the manga reader, raise the bar → the page count is in the bar header and fades after a chapter lands. (`e55f015`)
- [ ] Make an eBook chapter fail to load → its card takes focus with Try again / Next chapter / Close reader. (`e55f015`)
- [ ] Make a manga chapter fail, then press Retry or Next chapter → the card offers Next chapter, and focus returns to the page. (`73a636e`)
- [ ] Pick a book on the Shelf → it opens after the Shelf closes. (`e55f015`)

### Social / Collections

- [ ] Open a collection's overlay, then close it → focus starts on Close or the first TMDB tile below the top bar, and returns to the card on close. (`1124337`)
- [ ] With the overlay up, press Up and LB/RB → the top bar takes no focus, no tab changes, and the hint bar drops Tabs. (`8314373`)
- [ ] Press Delete on a collection → the prompt opens on Cancel. (`1124337`)
- [ ] Press a profile's friend button and a group's Join / Accept → the ring stays on the replacement button. (`1124337`)
- [ ] Offline, press Dismiss on a notification → the row goes at once, and the center offers Try again instead of loading forever. (`1124337`)
- [ ] Accept or Decline a friend request, then Dismiss a notification → the ring goes to the next request's profile tile, then to the row now in place. (`8314373`)
- [ ] Press Save to my collections at the 24-collection limit → it shows "Limit reached · 24 / 24". (`8314373`)
- [ ] Account menu → Groups (or Notifications), press Back → the ring stays on that item, not "View my profile". (`56d3886`)

### Discover / Calendar

- [ ] Open the Discovery Queue → the deck cell takes first focus, Left/Right step the deck only from it, and the action chips move normally. (`55d98fd`)
- [ ] In the queue press Not interested, then Save on another card → "Hide this permanently?" asks first; Save toggles Saved (also without a Stremio account). (`55f8fe3`)
- [ ] Press a Discover rail's "All movies" / "All shows" header chip → it opens that tab. (`55f8fe3`)
- [ ] Switch the Calendar source chip → the chip rows stay, the ring stays on the pressed chip, and only the grid shows the skeleton. (`55f8fe3`)
- [ ] In Calendar filters, press Clear all, a group Clear, and remove a person chip → the ring moves to a neighbour each time. (`8c104a8`)
- [ ] Press Calendar Previous / Next / Today, then a day → the grid shows the skeleton until the new month answers, and the day opens that month's releases. (`a3ed212`)
- [ ] Move up from the Discover rail into the lead bands (Queue, People, Awards, Genres, Voyage) → each band parks under the top bar. (`a716631`)
- [ ] Open Discover on a slow network → Top People loads after Genres and Voyages and never pushes down the band holding the ring. (`a3ed212`)

### Performance / memory

- [ ] Scroll fast through a long grid, then stop → the posters on screen load first. (`37aa626`)
- [ ] Open Detail or the player from Home, then close it → the hero cycle was paused underneath and resumes. (`37aa626`)
- [ ] Push memory (long manga chapter plus big grids) until tvOS sends a memory warning → no crash; images and pages reload as you move and on-screen art stays. (`37aa626`)

### VoiceOver

- [ ] With VoiceOver on, focus poster tiles and Continue Watching cards → each reads its title. (`740944f`)
- [ ] With VoiceOver on in the player, swipe up/down on the stage → it reads as the Seek slider with a time value and seeks. (`740944f`, `57bf553`)
- [ ] With VoiceOver on, walk the guide (star, programme blocks) and the player's track dialogs → labels read, and picks read as selected. (`b40d1a5`)
- [ ] With VoiceOver on, focus a watched / watchlisted tile on Home and in Library → it reads the title with "Watched" / "In watchlist" and "{n}% watched". (`b40d1a5`, `08b4760`)
- [ ] With VoiceOver on, edit a collection → its tiles read upstream's labels while editing. (`b40d1a5`)

### Localization

- [ ] Switch the UI to Arabic and browse Home, Detail, the player and the Discovery Queue → back/forward chevrons point the right way, hero side scrims flip, seek bars stay left-to-right, and Left steps the queue forward. (`72c59b9`, `77de960`)
