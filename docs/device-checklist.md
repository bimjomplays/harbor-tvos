# Device checklist (real Apple TV)

CI only compiles the app and runs simulator UI tests. The last hardware run was the Stage 0 spike
(mpv HEVC / HDR10 / HDR10+ / DV P5/P8 / PGS / SRT, 09-22). Everything built on 09-23, 09-24 and
09-25 has only run in the simulator. This file collects every "Needs device" / "Untested on device"
note from `PROJECT_STATE.md` → Status, the Next section and `docs/*.md` in one list, deduplicated and
grouped by area.

Each line reads **action → expected result (source)**. Sources are Status lines as `(MM-DD HH:MM)`
in the status-log clock. Lines without a date are 09-23. `(Next)` is PROJECT_STATE → Next → Then,
item 1. When something fails, note the build number, the engine (mpv or AVPlayer) and the source
type (debrid, torrent, HLS, home server, IPTV).

## Before you start

**Build.** Merge `claude/determined-hopper-smvu37` into `main` (or open a PR), run `Build` with
`testflight=true`, and install that build from TestFlight (internal testing). Nothing from 09-24
onward is on TestFlight yet.

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
