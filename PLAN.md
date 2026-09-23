# Harbor for tvOS — full plan

Goal: a native Apple TV app with every Harbor feature that tvOS physically allows, logged in to the
same Harbor account, installed through TestFlight, built without a physical Mac.

Source of truth for features: `harborstremio/harbor`, branch `beta-branch`
(pinned at `1bfcfb6`, 2026-09-21; clone in `reference/harbor`).

## 1. What we are copying (measured, not guessed)

| Part of upstream | Size | Notes |
|---|---|---|
| `src/lib` logic (no i18n) | ~200k lines TS, 1,297 files | Mostly framework-free: streams 3/59 files touch React/Tauri/DOM, sports 12/112, profile-sync 3/21, debrid 1/8 |
| `src/lib/i18n` | 247k lines | 26 languages, reusable as data |
| `src/views` | 313k lines | Desktop UI. **`big-picture/` (60k lines) is upstream's own TV UI** and is our design reference |
| `src/components` + `chrome` | 92k lines | Desktop widgets |
| `src-tauri` Rust | ~60k lines | mpv 3.5k, music 26k, subsync 4.9k, torrent (librqbit) 2.7k, cast/dlna/roku 4k |
| `harbor-core` Rust | 5.5k lines | Stream parse → trust → score → rank |

This is a very large app (roughly half a million lines of real code). Full parity is a long
project: the plan is staged so that **every stage ends with a working TestFlight build**, and the app
is a usable daily driver after Stage 4.

## 2. Architecture decisions

1. **UI: native SwiftUI**, modelled screen-for-screen on Big Picture (same rooms, rows, hero, focus
   behaviour, hint bar). tvOS has no web view, so none of the React UI can run.
2. **Logic: "HarborEngine" = upstream's TypeScript logic running inside JavaScriptCore.**
   JavaScriptCore exists on tvOS. We bundle the framework-free parts of `src/lib` with esbuild and give
   them Swift-backed `fetch`, storage, timers, crypto and WebSocket. Why: upstream changes daily; porting
   200k lines to Swift by hand would never catch up, and re-bundling keeps us in step.
   Anything hot or UI-bound is written in Swift instead. Stage 0 proves this or kills it
   (fallback: port module by module to Swift, slower but certain).
3. **Rust compiled natively for tvOS** (`aarch64-apple-tvos` is an official rustup target, confirmed
   on this PC): `harbor-core`, the `librqbit` torrent engine (upstream already does this for Android),
   `subsync`, later `librespot`. Linked as static libraries.
4. **Player: libmpv via MPVKit** for parity (MKV, HEVC, ASS subtitles, shaders, track switching).
   AVPlayer as the second engine for HLS and Dolby Vision, with an Auto mode like upstream.
5. **Storage:** tvOS gives apps no guaranteed disk. Rules: tokens in Keychain; small settings in
   UserDefaults/iCloud key-value; everything else in the purgeable Caches folder and **rebuildable from the
   Harbor account sync**. The app must survive waking up with an empty disk.
6. **Account:** Harbor login (`harbor.site/themes/api/identity/api/*`), linked Stremio account, profile sync
   (`harbor.site/themes/api/sync/v1/state|push`, bearer; NOT sync.harbor.site, which is the subtitle crowd DB). TV sign-in by QR/short code, with typed email+password as fallback.
7. **No web view workarounds:** addon configuration pages, OAuth logins and long text entry happen on
   the phone via QR code. The TV also hosts upstream's phone remote (Stage 10) so the phone becomes its keyboard.
8. **Upstream tracking:** upstream is a git submodule pinned to a commit. A `PARITY.md` matrix lists
   every feature with status. A re-sync pass bumps the pin and re-runs engine tests.

## 3. Building and testing without a Mac

- **Project generated from text** (XcodeGen), so nothing needs the Xcode app.
- **GitHub Actions macOS runner**: build → sign with the paid team → upload to TestFlight (internal
  testers only, never external). App Store Connect API key in repo secrets.
- **My eyes:** CI boots the tvOS Simulator, walks every screen with UI tests, and uploads screenshots.
  I download and inspect them. This is how UI gets checked before it reaches the TV.
- **Logic tests on this Linux PC:** HarborEngine runs under Node with the same polyfill contract;
  pure Swift packages build with the Linux Swift toolchain; Rust tests run natively.
- **Only a real Apple TV can verify:** video playback, HDR, remote feel, performance. That is the user's
  job per stage, from a short checklist.
- CI minutes: a private repo gets ~200 Mac minutes/month (about 15 builds). A public repo is unlimited.
  Decision needed (see §7).

## 4. Stages

**Status 2026-09-23:** Stage 0 ✔, Stage 1 ✔, Stage 2 mostly ✔ (Collections room, services/addons Home rows, award/DUB marks pending), Stage 3 ✔ core (detail page, episodes, ranked picker, debrid resolve, playback; TMDB-dependent rows pending a working key), Stage 4 partial (player chrome, resume/progress, online subtitles, audio/subtitle tracks, up-next; skip-intro, shaders, AVPlayer engine, display-mode matching pending), Stage 5 partial (Library rails, Addons manager, watchlist), Stage 7 partial (Anime room rows). Read-only sync still in place (writes: Stage 4 exit criteria).

Each stage: scope → what ships → how it is verified. Settings panels ship with the feature they belong to.

### Stage 0 — Foundations and risk spikes (no features)
- 0.1 Repo, XcodeGen project, CI, signing, first "hello" build installed on the TV through TestFlight.
- 0.2 CI simulator screenshot loop.
- 0.3 Spike: MPVKit plays MKV / HEVC / HDR10 / ASS subtitles / 5.1 audio on the real Apple TV.
- 0.4 Spike: HarborEngine — bundle `streams` + addon client, run in JavaScriptCore on tvOS, measure speed and memory.
- 0.5 Spike: Rust static library on tvOS — `harbor-core` first, then `librqbit` streaming one torrent.
- 0.6 Read `account/` and `profile-sync/` completely; write `docs/harbor-protocol.md` (data format, revisions,
  conflict rules, whether anything is encrypted). A wrong write could corrupt desktop profiles, so
  the sync client starts **read-only**.
- 0.7 Storage layer per decision 5.
- Exit: go/no-go recorded for decisions 2, 3, 4.
- **Result (2026-09-22): all GO.** Engine: 850 streams ranked in 332 ms in JavaScriptCore. Rust: harbor-core static lib links and runs. mpv: HEVC, HDR10, HDR10+, DV P5/P8, PGS and SRT all play on the user's Apple TV 4K (3rd gen, tvOS 26.6). Storage: Keychain/Prefs/Caches layer with key routing in place. Protocol doc in `docs/harbor-protocol.md`.

### Stage 1 — Shell, sign-in, profiles
Design tokens from Big Picture; focus engine rules (focus ≠ activate, as upstream requires); side rail;
hint bar; boot splash; onboarding; Harbor sign-in by QR/code; Stremio link; "Who's watching" with
PINs and kid profiles; read-only profile sync; sync status indicator.

### Stage 2 — Browse
Home (hero cycle, Continue Watching, rails, classic Stremio home mode), Movies, Shows, Discover + Discovery Queue,
catalog pages, genre grid, streaming-service rows and pages, collections, brands, people/person,
awards, ratings matrix, card badges and state marks, search with on-screen keyboard and AI search.
Metadata providers: Cinemeta, TMDB, TVDB, Fanart.tv, RPDB, OMDB. Region awareness.

### Stage 3 — Detail and the stream engine
Detail page (facts, cast, gallery, collaborators, trailers best-effort), seasons/episodes with spoiler
settings, play picker, addon protocol client, stream engine (parse/trust/score/rank via Rust),
debrid: Real-Debrid, AllDebrid, Premiumize, Debrid-Link, TorBox; stream filters, priority, badges,
quality settings, addon timeouts.

### Stage 4 — Player  ← daily-driver milestone
mpv player with HUD, audio/subtitle/quality menus, resume and progress write-back (Stremio + Harbor),
watched at 85%, next/previous episode, auto-advance, "still watching", queue, skip intro/outro/recap
(AniSkip, TheIntroDB, chapters), stall/black-screen recovery, subtitle sources (OpenSubtitles, Wyzie,
addons), full subtitle styling, dual subtitles, delay, autosync (Rust `subsync`), trickplay previews,
sleep timer, A/B loop, stats overlay, frame-rate and HDR display matching, Now Playing + Siri Remote
commands, Auto engine with AVPlayer, Anime4K shaders if the chip can carry them. Sync becomes read-write here.

### Stage 5 — Library, calendar, trackers
My Library, library services, repair, Calendar, lists and shared lists, feed; Trakt (device code),
Simkl, AniList, MAL, Letterboxd, Stremboxd; scrobbling; Addons room (browse stremio-addons.net,
install by URL/QR, configure via phone, manage, reorder, age gate, addon collections).

### Stage 6 — Torrents and home servers
librqbit streaming with the local stream proxy and cache limits; P2P settings; Plex, Jellyfin, Emby
(connect, discovery, library index, versions, progress sync, playback policy). Local library becomes
"network shares" (SMB) since a TV has no files of its own.

### Stage 7 — Anime and Kids
Anime room (Kitsu, AniZip, seasons, characters, awards, announcements, anime CW rules, numbering),
anime settings; Kids mode and kids detail.

### Stage 8 — Live TV
M3U / Xtream / XMLTV sources, EPG grid guide, categories, favourites, channel picker in player,
catch-up, reconnect, playlist VOD, Multiview (up to 4, as many as the chip decodes), live settings.

### Stage 9 — Settings and themes to full parity
Every remaining settings panel; the 11 theme presets, fonts, card/button styles, backgrounds, bokeh,
`.harborstyle` import (tokens only); player layout presets; 26 languages; webhooks and Telegram/Discord
notifications; privacy; storage; bug reporter; backup/restore through the account or QR.

### Stage 10 — Social, watch parties, phone remote
Account menu, profile page, handle, avatar, banner, activity feed, groups, notifications; Together
(rooms, synced playback, chat, invites, others' cursors and drawings shown view-only); relay settings;
TV handoff (receive a title from phone/desktop); remote host so upstream's phone remote controls the TV
and types for it; Wrapped; Voyage.

### Stage 11 — Sports
The sports room (22k lines logic, 31k UI): leagues, schedules, scores, streams, sports settings.

### Stage 12 — Music
Spotify (librespot, Rust), YouTube Music, SoundCloud, Plex music, Listen Together, song ID,
background audio, music screens.

### Stage 13 — Manga and ebooks
Manga reader and sources, phone-as-page-turner; ebook library, native EPUB renderer, narration (TTS).

### Stage 14 — Apple TV extras, polish, parity audit
Top Shelf Continue Watching on the Apple TV home screen, `harbor://` and `stremio://` deep links,
ambient screensaver, game controllers, keyboard, accessibility, performance pass, final walk through
`PARITY.md`, upstream re-sync routine.

## 5. What tvOS cannot do (and what replaces it)

| Upstream feature | On tvOS |
|---|---|
| Custom CSS / JS / HTML layers, custom HTML chrome | Not possible (no web view). Colours, fonts, layouts, backgrounds still work |
| Drag-and-drop Player Editor, custom seek-bar JS | Preset layouts chosen with the remote |
| Face ID profile unlock | No camera. PIN only |
| Downloads, auto-download, DVR recording, yt-dlp | No lasting disk, no background running. Offer "send to desktop Harbor" through the account |
| ffmpeg transcode, Stremio Server fallback | No helper programs. mpv + AVPlayer cover it; use a desktop/media-server transcoder when present |
| Casting out (Chromecast, DLNA, Roku, AirPlay sender) | The TV is the target. Replaced by TV handoff (Stage 10) |
| Picture in picture | Only on the AVPlayer engine |
| Discord Rich Presence, tray, hotkey editor, updater, rollback, installer | Not applicable. Webhooks still work; updates come from TestFlight |
| On-screen cursors and drawing in watch parties | View-only |
| Addon config pages, OAuth web logins | Done on the phone via QR |
| YouTube trailers | Best effort; no yt-dlp |

## 6. How the work gets done

- One stage at a time, on a branch, merged when its TestFlight checklist passes.
- Subagents where work splits cleanly (separate screens, separate providers, separate trackers),
  each in its own git worktree, **at most ~6 at once** and in resumable batches. Cheap models for
  mechanical screens and ports; the strong model for the player, sync, engine bridge and focus system.
- `PROJECT_STATE.md` updated at every milestone; `PARITY.md` is the feature checklist.

## 7. Decisions needed before Stage 0

1. (Answered 2026-09-21: no modified Harbor exists; copy upstream beta as-is.)
2. (Answered 2026-09-21: Apple TV 4K 3rd gen A2737, tvOS 26.6. HDR10/DV, A15: shaders and 4-way Multiview are realistic.)
3. (Decided 2026-09-21: **private** repo to start; flip to public or pay per build if the free Mac minutes run out.)
4. (Dropped: no need to ask the Harbor developers. Code is MIT. We behave like the official client toward their servers and keep sync read-only until the format is understood.)
5. (Decided 2026-09-21: app name **Harbor**; bundle ID chosen in Stage 0.1.)
