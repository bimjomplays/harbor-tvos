# Music on tvOS (Stage 12): what ships, what cannot, and why

Upstream (`reference/harbor`, pinned `1bfcfb6`) builds music out of three layers:

- **Rust, ~26k lines** (`src-tauri/src/music/**`): every source is a `MusicConnector`
  (`connector.rs`) in a `ConnectorRegistry` (`registry.rs`) that fans out search, merges rows
  (`rows.rs`), matches a catalog track to a playable copy (`matching.rs`) and resolves a stream,
  which mpv plays (`audio.rs`, `engine.rs`). Liked tracks, recents and playlists live in SQLite
  (`library.rs`, `db/`).
- **TypeScript glue** (`src/lib/music/*`, ~13k lines): `player.ts` (queue, phase machine,
  source recovery), `sources.ts` / `catalog.ts` (thin `invoke()` wrappers), consent, liked,
  radio, lyrics, EQ, casting, video.
- **Desktop views** (`src/views/music*`, `src/components/music/*`): the music home ("For you /
  Explore / Library"), search panel, detail pages, dock, queue, Now Playing. Big Picture has
  **no** music room; the TV room adapts the desktop layout to Big Picture's rails and focus.

On the TV there is no Tauri, no child process, no web view and no user file system, so the
connectors that only need HTTPS and a direct audio URL are ported to TypeScript in the engine
(`engine/musicSources.ts`, same ids, row ids, limits and fallbacks as the Rust), the room glue
is `engine/music.ts`, and playback is AVFoundation in Swift (`App/Sources/Music/`).

## Feasibility per source

| Source | Upstream does | tvOS allows | Plan / status |
|---|---|---|---|
| **Open catalog** (`connectors/catalog`) | Deezer charts + editorial, ListenBrainz fresh releases, iTunes + Deezer search, MusicBrainz / Cover Art for credits. Browse and search only, never playable. | All plain HTTPS JSON. | **Shipped**: Deezer chart tracks / albums / artists / editorial, Deezer artist top + albums + related, iTunes song / album / artist search and lookups. ListenBrainz fresh releases and MusicBrainz credits: next batch (same shape, more endpoints). |
| **SoundCloud** (`connectors/soundcloud`) | Public `api-v2` with a `client_id` scraped from the soundcloud.com web app's script bundles (`identity.rs`), cached on disk, re-scraped on 401/403. Streams are progressive MP3 or HLS (AAC / MP3 / Opus). Gated by the source-consent dialog. | HTTPS only; AVPlayer plays progressive MP3 and AAC/MP3 HLS, **not Opus/Ogg**. | **Shipped**, behind upstream's consent (only SoundCloud is offered; YouTube is not). Transcoding choice is upstream's `select_transcoding` plus one TV rule: Opus/Ogg is never picked. **Reliability of the client id:** the same scrape upstream relies on (the home page lists `a-v2.sndcdn.com/assets/*.js`; one bundle contains `client_id:"<32 chars>"`). It has worked for years but is unofficial: SoundCloud can move or rename it at any time, and upstream would break in the same release. The id is cached in engine storage and dropped + re-scraped on 401/403, exactly as upstream. It could not be exercised from the build sandbox (egress to soundcloud.com is blocked there); the offline smoke drives the whole path against recorded shapes. |
| **Jellyfin** (`connectors/jellyfin`) | Adopts the video side's Jellyfin sign-in (`config.rs adopt`), home shelves (recent albums, instant-mix stations, playlists, favourites), typed search, InstantMix, `PlaybackInfo` + `/Audio/{id}/universal` with a device profile, play-session reports. | HTTPS/HTTP to the LAN server. AVPlayer plays MP3, AAC/ALAC (m4a), FLAC, WAV, AIFF. | **Shipped** through the existing Settings › Home servers Jellyfin connection. The direct-play container list is narrowed to what AVPlayer decodes, so Ogg/Opus/WebM/Matroska/WavPack are transcoded to MP3 by the server. Session start/stop reports are sent. |
| **Plex** (`connectors/plex`) | Finds a server with a music (`artist`) section from the plex.tv account, hub rows, hub search, direct part URLs or the MP3 universal transcoder. | Same as Jellyfin. | **Shipped** through the existing Plex PIN connection (its server origin + token); hubs, search, album/artist/playlist/station tracks, direct part for AVPlayer-playable files, MP3 transcode otherwise. No timeline scrobbles yet. |
| Emby | Not a music source upstream (Jellyfin connector only). | — | Not offered (matches upstream). |
| **Subsonic / Navidrome** (`connectors/subsonic`) | Address + user + password form, token auth, browse/search/stream. | Plain HTTPS; needs md5 (token auth) or `enc:` password form. | **Next batch**: needs its own sign-in form on the TV (BPField + phone typing), otherwise the same shape as Jellyfin. |
| **Spotify** (`music/spotify`, librespot 0.8) | Bring-your-own Spotify app client id, OAuth PKCE with a loopback redirect to `127.0.0.1:8898` in the desktop browser (`auth.rs`), then librespot streams Premium audio through its rodio/cpal sink (`player.rs`). | No browser on the TV and the loopback redirect cannot be completed on a phone; librespot's default audio backends have no tvOS sink; adding librespot to `rust/harbor-ffi` risks the tvOS cross-build (vendored `librespot-core` patch, governor/quanta and vergen pins in upstream's Cargo). | **Skipped this batch.** Plan: (1) phone hand-off completes OAuth: the phone opens the authorize URL, Spotify redirects the phone to the loopback URL, the phone page asks the viewer to paste that final URL and posts the `code` to the TV (the existing `PhoneLinkServer`); (2) add `librespot-core/-playback/-oauth` to `harbor-ffi` behind a feature, with a custom `Sink` that hands PCM to Swift (AVAudioEngine + AVAudioSourceNode), no rodio/cpal; (3) cross-build the tvOS staticlib in CI first, only then wire the UI. Premium is required (librespot), so it also needs an account to test. |
| **YouTube Music** (`connectors/youtube_music`) | InnerTube browse/search + **yt-dlp** (a downloaded helper binary, auto-updated) to extract stream URLs; the full YouTube Music web app in a native child web view. | No helper programs, no web view (PLAN §5). InnerTube player URLs without yt-dlp need signature deciphering and PO tokens that change weekly. | **Not possible** on the TV. The catalog + SoundCloud / server matching stands in: a chart track plays from whichever connected source matches it. |
| **Local files** (`connectors/local`) | Folder scan with tag reading, SQLite index. | No user-visible file system on tvOS. | **Not possible.** A home server covers "your own files". |
| Radio (`lib/music/radio.ts`) | Seeded track radio from Last.fm / Deezer radio / related lanes, re-ranked. | TS over HTTP + `invoke` for search. | Next batch (portable; needs Last.fm key handling). Jellyfin InstantMix and Plex station hubs already give radio on servers. |
| Last.fm scrobbling, lyrics, EQ, spectrum, casting, music videos, Listen Together, song ID | Various (Rust DSP, mpv filters, cast protocols, web views, microphone). | EQ/spectrum need an AVAudioEngine graph; casting is out (the TV is the target); video needs YouTube; song ID needs a mic. | Not in this batch. Lyrics (LRCLIB, plain HTTP) and Last.fm scrobbles (HTTP) are the cheapest next steps. |

## What the TV room does

- **Tab:** `Room.music`, placed before Live TV as in upstream's `nav-items.tsx`. Upstream has no
  music on/off setting (only the generic nav hide list, which the TV does not port yet), so the
  tab is always shown.
- **Home** (`engine/music.ts home`, views/music.tsx band order): Pick up where you left off
  (recents) → On your server (Jellyfin / Plex rows, or upstream's "connect a server" notice) →
  new releases (when a source supplies them) → the track chart standing in for "Fresh" until
  there is history (upstream's `chartsInFresh`) → Your artists (from history) → Charts → Up next /
  Liked tracks → Radio and mixes → every other row (charting artists, editorial, SoundCloud
  selections). Rows are cached six hours like `rows.rs` and re-read when the library changes.
- **Search:** keyboard + phone typing, typed fan-out and merge (`registry.rs search_typed` +
  `rows.rs merge_typed_results`): top result, tracks, artists, albums, playlists.
- **Pages:** album / artist (top tracks + albums + related) / playlist / station, Play and
  Shuffle, hold Select on a track for Play next / Add to queue / Save.
- **Player** (`MusicPlayer.swift`, player.ts semantics): queue replaced on play, catalog tracks
  matched to a source first (preferring the source already playing), failed sources swapped for
  the next match (at most two alternatives, three failures), an automatic advance skips a track
  nothing can play, Previous restarts after 5 s. **Gapless:** the next entry is resolved in the
  last 30 s and queued behind the current item in an `AVQueuePlayer`. **Now Playing** and
  **remote commands** (play/pause/toggle/next/previous/seek) through `MPNowPlayingInfoCenter` /
  `MPRemoteCommandCenter`. **Background audio:** `UIBackgroundModes: [audio]` in `project.yml`,
  `.playback` audio session; upstream keeps playing with its window hidden, so the TV keeps
  playing on the home screen. A film or channel starting pauses the music, and a film now
  pauses itself when the app goes to the background and the Multiview tile with the sound goes
  quiet (mpv would otherwise keep sounding under the new background mode).
- **Library:** liked tracks and recents in engine storage (`harbor.music.liked.v1`,
  `harbor.music.recents.v1`), not the Rust SQLite database; not synced to the desktop yet
  (upstream does not sync them through the account either).

## Needs a device or an account to verify

- Everything audible: AVPlayer decoding of SoundCloud HLS and Jellyfin/Plex FLAC, the gapless
  hand-off, background playback from the TV home screen, Now Playing in Control Center and the
  Siri Remote play/pause.
- Live SoundCloud (client-id scrape) and Deezer/iTunes responses: blocked from the build sandbox,
  covered by the offline smoke with recorded shapes.
- A Jellyfin and a Plex server with a music library.
