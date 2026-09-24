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
| **Open catalog** (`connectors/catalog`) | Deezer charts + editorial, ListenBrainz fresh releases, iTunes + Deezer search, MusicBrainz / Cover Art for credits. Browse and search only, never playable. | All plain HTTPS JSON. | **Shipped**: Deezer chart tracks / albums / artists / editorial, Deezer artist top + albums + related, iTunes song / album / artist search and lookups. **Batch 2:** ListenBrainz fresh releases (`catalog:new-releases`, albums and EPs only, Cover Art Archive thumbnails, `listenbrainz.rs`) fill the "New releases" band; ListenBrainz's sitewide artist chart stands in when Deezer's artist chart fails; MusicBrainz release / artist track lists and artist albums (`musicbrainz.rs`) open those items. Both services are paced to one call a second as upstream does. |
| **SoundCloud** (`connectors/soundcloud`) | Public `api-v2` with a `client_id` scraped from the soundcloud.com web app's script bundles (`identity.rs`), cached on disk, re-scraped on 401/403. Streams are progressive MP3 or HLS (AAC / MP3 / Opus). Gated by the source-consent dialog. | HTTPS only; AVPlayer plays progressive MP3 and AAC/MP3 HLS, **not Opus/Ogg**. | **Shipped**, behind upstream's consent (only SoundCloud is offered; YouTube is not). Transcoding choice is upstream's `select_transcoding` plus one TV rule: Opus/Ogg is never picked. **Reliability of the client id:** the same scrape upstream relies on (the home page lists `a-v2.sndcdn.com/assets/*.js`; one bundle contains `client_id:"<32 chars>"`). It has worked for years but is unofficial: SoundCloud can move or rename it at any time, and upstream would break in the same release. The id is cached in engine storage and dropped + re-scraped on 401/403, exactly as upstream. It could not be exercised from the build sandbox (egress to soundcloud.com is blocked there); the offline smoke drives the whole path against recorded shapes. |
| **Jellyfin** (`connectors/jellyfin`) | Adopts the video side's Jellyfin sign-in (`config.rs adopt`), home shelves (recent albums, instant-mix stations, playlists, favourites), typed search, InstantMix, `PlaybackInfo` + `/Audio/{id}/universal` with a device profile, play-session reports. | HTTPS/HTTP to the LAN server. AVPlayer plays MP3, AAC/ALAC (m4a), FLAC, WAV, AIFF. | **Shipped** through the existing Settings › Home servers Jellyfin connection. The direct-play container list is narrowed to what AVPlayer decodes, so Ogg/Opus/WebM/Matroska/WavPack are transcoded to MP3 by the server. Session start/stop reports are sent. |
| **Plex** (`connectors/plex`) | Finds a server with a music (`artist`) section from the plex.tv account, hub rows, hub search, direct part URLs or the MP3 universal transcoder. | Same as Jellyfin. | **Shipped** through the existing Plex PIN connection (its server origin + token); hubs, search, album/artist/playlist/station tracks, direct part for AVPlayer-playable files, MP3 transcode otherwise. No timeline scrobbles yet. |
| Emby | Not a music source upstream (Jellyfin connector only). | — | Not offered (matches upstream). |
| **Subsonic / Navidrome** (`connectors/subsonic`) | Address + user + password form, token auth, browse/search/stream. | Plain HTTP(S); md5 token auth (`engine/md5.ts`, JavaScriptCore has no MD5). | **Shipped (batch 2)**: Music › Connections › Navidrome › Connect opens upstream's form (Server URL with placeholder `https://navidrome.local`, Username, Password; every field can be typed on a phone). Same probe ladder (`https://host`, `http://host`, `http://host:4533`), Navidrome's `/auth/login` salt+token exchange first, else a random salt and `md5(password+salt)`, proven by `ping`. Only the pairing (base URL, username, salt, token) is kept, under upstream's keys `harbor.subsonic.v1.*`, which the TV routes to the Keychain tier (`KeyValueStore.secretPrefixes`); the password is never stored. Home shelves (newest / most played / random albums, starred, artists, playlists; empty ones collapse), `search3` search, album (disc then track order), artist (first four albums, 30 tracks), playlist pages. `stream?format=raw`, except that files whose suffix AVPlayer cannot decode (Ogg / Opus / WMA / APE / WavPack …, read with `getSong`) ask the server for 320k MP3. Now-playing (`scrobble submission=false`) on resolve and the submission scrobble at the threshold, as upstream. Upstream names these shelves with keys its catalogs never define (`music.row.serverNewest` …), so the desktop shows raw keys; the TV shows upstream copy with the same meaning ("On your server", "Liked tracks", "Artists", "Your playlists") and plain English for the two without one ("Most played", "Random albums"). |
| **Spotify** (`music/spotify`, librespot 0.8) | Bring-your-own Spotify app client id, OAuth PKCE with a loopback redirect to `127.0.0.1:8898` in the desktop browser (`auth.rs`), then librespot streams Premium audio through its rodio/cpal sink (`player.rs`); browse/search over the Web API with that token (`browse.rs`, `api.rs`, `tokens.rs`). | No browser on the TV and the loopback redirect cannot be caught on a phone; librespot's audio backends have no tvOS output; `open` (librespot-oauth's browser launcher) does not compile for tvOS. | **Built (batch 3), needs a Premium account on a device.** Phone hand-off for OAuth, librespot 0.8 inside `rust/harbor-ffi` with a ring-buffer sink drained by AVAudioEngine, Web API browse/search in the engine. Details in "Spotify on the TV" below. |
| **YouTube Music** (`connectors/youtube_music`) | InnerTube browse/search + **yt-dlp** (a downloaded helper binary, auto-updated) to extract stream URLs; the full YouTube Music web app in a native child web view. | No helper programs, no web view (PLAN §5). InnerTube player URLs without yt-dlp need signature deciphering and PO tokens that change weekly. | **Not possible** on the TV. The catalog + SoundCloud / server matching stands in: a chart track plays from whichever connected source matches it. |
| **Local files** (`connectors/local`) | Folder scan with tag reading, SQLite index. | No user-visible file system on tvOS. | **Not possible.** A home server covers "your own files". |
| Radio (`lib/music/radio.ts`) | Seeded track radio from Last.fm / YouTube / Deezer radio / related lanes, re-ranked by audio features, spaced by artist, extended near the end of the queue (`armTrackRadio`). | TS over HTTP. | **Shipped (batch 2)** as `engine/musicRadio.ts`: hold Select on any track › **Start radio** (music-track-menu). Same lanes, weights, variant filter, Deezer feature enrichment, ranking and spacing; the YouTube lane is left out (no YouTube source); the Last.fm lane runs when a Last.fm API key is saved. `MusicPlayer` arms the extension: within four entries of the end it asks `music.radioExtend` for 18 more seeded by the last three. Jellyfin InstantMix and Plex station hubs still give server radio. |
| Internet radio (station streams, radio-browser) | **Not in upstream** (no radio-browser / Icecast / TuneIn source anywhere in `reference/harbor`). | — | Not added: the port follows upstream. "Radio" on the TV is upstream's track radio above plus the servers' stations. |
| **Last.fm scrobbling** (`music/lastfm.rs`, `music-lastfm.tsx`) | Bring-your-own API key + shared secret, `auth.getToken`, approval in the desktop browser, `auth.getSession`; signed `track.scrobble` once a track that was heard for half its length or four minutes (`engine.rs should_scrobble`) ends. No "now playing" call. | HTTPS + md5 signatures. | **Shipped (batch 2)**: Music › Connections › Last.fm › Connect: API key and shared secret (phone typing), **Authorize Last.fm** shows the approval page as a QR code (as the tracker sign-ins do), then **Finish connection**. Keys are upstream's `harbor.lastfm.v1.*` (already Keychain tier). `MusicPlayer` counts the seconds actually heard (forward steps of at most 2 s, so seeks do not count, `listened_increment`) and scrobbles on finish, skip, stop or advance, once. Navidrome tracks also get the server-side scrobble (`accounts.rs scrobble_track`). |
| ListenBrainz scrobbling | **Not in upstream** (ListenBrainz is only a catalog source there). | — | Not added. |
| **Lyrics** (`lib/music/lyrics.ts`, `lyric-offset.ts`) | LRCLIB `get` (with album + duration) then `search`, synced lyrics only, instrumental → none; Now Playing "Lyrics" tab with the active line centred and a ±0.25 s Lyric sync nudge per track. | Plain HTTPS. | **Shipped (batch 2)**: upstream's modules run unchanged in the engine (`music.lyrics`, `music.setLyricOffset`); Now Playing has **Up next / Lyrics** tabs; the active line follows the clock and scrolls to the middle. Lines are text rather than seek buttons so the list can follow the song without the focus engine pulling it back. |
| EQ, spectrum, casting, music videos, Listen Together, song ID | Various (Rust DSP, mpv filters, cast protocols, web views, microphone). | EQ/spectrum need an AVAudioEngine graph; casting is out (the TV is the target); video needs YouTube; song ID needs a mic. | Not yet. |

## Spotify on the TV (batch 3)

Upstream: `src-tauri/src/music/spotify/{mod,auth,session,player,control,tokens,keystore,api,parse,browse,artist_catalog,connector}.rs`,
`src/lib/music/spotify-setup.ts`, `components/music/music-connections/spotify-setup.tsx`.

**Where each upstream piece lives**

| Upstream | TV |
|---|---|
| `auth.rs` (PKCE, the listener's own client id, 13 scopes, `http://127.0.0.1:8898/login`) | `engine/musicSpotify.ts` `begin`/`finish`: same client id key, scopes and redirect URI, S256 challenge, token exchange and refresh over `fetch` (PKCE needs no secret). |
| The loopback listener that catches the redirect | The phone: Music › Connections › Spotify › Connect shows upstream's three setup steps (dashboard as a QR code, the redirect URI, the client id typed on the phone), then **Authorize Spotify** shows the authorize page as a QR code. The phone signs in, Spotify sends it to `http://127.0.0.1:8898/login?code=…` (a page that does not load on the phone), and the viewer pastes that address back (phone typing). The `state` is checked; the pending sign-in lives ten minutes. The redirect URI is upstream's, so one Spotify app serves the desktop and the TV. |
| `keystore.rs` (`harbor.spotify.v1.credentials / deviceId / webToken / clientId`) | Same keys in engine storage; the `harbor.spotify.v1` prefix is in `KeyValueStore.secretPrefixes` (Keychain). librespot writes its reusable credentials to `Caches/spotify/session/credentials.json`; Rust reads them back, deletes the file and returns them (keystore::capture). |
| `session.rs`, `player.rs`, `control.rs` | `rust/harbor-ffi/src/spotify` behind the JSON C ABI (`harbor_spotify_*` in `include/harbor_ffi.h`): own tokio runtime, `Session::connect` with the token or saved credentials, the Premium check on the `type` attribute (8 s), 320 kbps gapless player with 250 ms position events, soft mixer, upstream's request-id guards on events, upstream's copy for Free / rejected sign-ins. Audio cache 512 MB (upstream 2 GB; tvOS Caches are purgeable). |
| rodio/cpal sink | `sink.rs`: a lock-free SPSC ring (0.5 s of 44.1 kHz stereo f32). The player thread blocks while it is full (real-time pacing) and fails the write, which pauses the player, if nobody reads for 2 s. `SpotifyAudioOutput` (Swift) pulls it from an `AVAudioSourceNode` render callback via `harbor_spotify_pcm_read` (no locks, no allocation); the mixer resamples to the output rate. A pause or skip drops the buffered half second; a natural end drains it, so the next track follows its tail. The audio session is set to playback and never deactivated (review 19). |
| `tokens.rs` probe_tier / `web_token` / `market` | Engine: `/me` `product` when the session could not tell the tier (a Free account is refused and Swift shuts the session down), refresh on expiry keeping the granted scopes, an expired refresh token is forgotten, then the session's login5 token (fetched by Swift after connect), market from the account country. |
| `browse.rs`, `api.rs`, `parse.rs`, `artist_catalog.rs` | Engine: the six personal home rows (recently played, top tracks/artists, playlists, saved albums, liked) with upstream's ids/titles/layouts, typed search with the restricted-client retry at 10 and the exact-artist top result, album / artist (403/404 falls back to an `artist:"…"` search; first album page as the Albums shelf) / playlist (`/items`, else `/tracks`) pages. |
| `commands/playback.rs` music_play_track (Spotify tracks go to the Spotify engine, the other engine stops) | `MusicPlayer`: `engine/music.ts prepare()` returns the `spotify:` URI with the marker type `audio/x-spotify-uri`; MusicPlayer stops the AVQueuePlayer and plays it through `SpotifyPlayback`, polling the events every 250 ms for time-pos, pause, end (advance + scrobble) and failure (upstream's source recovery). The queue, Now Playing, remote commands and scrobbles are shared with the other sources. Catalog tracks prefer Spotify when it is connected (matching.rs priority 0). |
| `mod.rs` initialize (sign in with the saved credentials at start) | The first Music home load (in the background, its shelves join when the session is up) and any Spotify entry that is about to play. |

**Cross-building librespot for tvOS.** Checked on the Linux host with nightly `cargo check -Zbuild-std
--target aarch64-apple-tvos` and `aarch64-apple-tvos-sim` (release profile; C sources stubbed, since
there is no Apple SDK here): the whole tree type-checks. What it took:

- `open` 5.4 (librespot-core → librespot-oauth, unconditional) stops with `compile_error!("open is
  not supported on this platform")` on tvOS. `rust/vendor/open` keeps the three entry points with
  upstream's signatures and returns `Unsupported`; the TV never runs librespot-oauth's browser flow.
- librespot-core 0.8.0 is upstream's vendored copy (`rust/vendor/librespot-core`, unchanged from
  `reference/harbor/src-tauri/vendor/librespot-core`): librqbit enables governor's quanta clock, which
  the stock rate limiter does not compile against, and the stock crate calls `process::exit(1)` on a
  Free account. Cargo.lock pins vergen 9.0.6 (as upstream): with 9.1 librespot-core's build script
  fails (two vergen-lib versions).
- No audio backend features (`default-features = false`): no rodio/cpal/alsa/portaudio. TLS is
  `rustls-tls-webpki-roots` (ring + bundled roots; no OpenSSL, no Security.framework trust); ring and
  webpki-roots were already in the tree for librqbit. getrandom uses the Apple backends.
- `sysinfo` 0.36 falls back to its "unknown" backend on tvOS (no IOKit). librespot reports tvOS to
  Spotify as a Linux desktop client (its `_` platform branch, the same spoof it uses for Android).
- No new frameworks to link (CoreFoundation was already added for librqbit).
- MSRV: librespot 0.8 declares Rust 1.85; the host has 1.94 stable and CI installs current stable.
- Staticlib (host, x86_64 release): 110 MB → 207 MB archive, code sections 11 → 21 MB (the app
  link dead-strips what is unused). CI's cache key changes with Cargo.lock, so the first CI run
  rebuilds both tvOS targets from scratch (the screens job now has 75 minutes).

**Tests.** `cargo test` (host, no network): the ring (de-interleave, wrap, back-pressure, stall,
flush, drain vs discard), account tiers, credentials choice and harvest, connect error copy, and the
C ABI before and without a session. Offline smoke: PKCE URL and challenge, state check, cancelled
consent, code exchange, token storage keys, Premium via `/me`, Free refusal, home rows, search retry
and top result, album/artist/playlist fallbacks, the playback marker, refresh and expired refresh,
disconnect.

**Needs CI and a Premium account on a device:** the real tvOS link (ring's C, the `harbor-core`
cdylib step), a sign-in end to end (the paste-back on a phone, the 127.0.0.1 page each phone browser
shows), audio through AVAudioEngine on HDMI/AirPlay routes, background playback, pause/seek latency,
end-of-track hand-off, the session surviving sleep/network changes (the TV signs in again from the
saved credentials once), and Spotify's limits on an app in development mode (only the users added under Users Management).

**Not ported:** the Spotify library page and playlist writes (`library.rs`, `music-spotify-library.tsx`),
Spotify Connect (spirc: the TV is not offered as a cast target), the paged artist catalog beyond the
first ten albums, volume (the TV's own volume applies; the soft mixer stays at full), the source
picker's "Premium · 320 kbps" label.

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
- Batch 2: a Navidrome (and a plain Subsonic) server: sign-in over the probe ladder, the shelves,
  FLAC raw streams and the MP3 fallback for Opus files, now-playing and scrobbles in the server's
  activity; a Last.fm API account (key + secret from last.fm/api/account/create): the QR approval,
  a scrobble after half a track, none after a quick skip; LRCLIB lyrics timing on a real stream;
  Start radio from a chart track with SoundCloud or a server connected, and the queue growing
  near its end; ListenBrainz / MusicBrainz responses live (offline smoke uses recorded shapes).

## Next

- Upstream's other Now Playing tabs (About the artist, Signal), the karaoke view, and the
  per-source picker (music-source-picker.tsx) for choosing which match plays.
- Library sync of liked tracks / playlists and upstream's playlists (library.rs), Plex timeline
  scrobbles, MusicBrainz credits on the track page (recording-profile.ts is already bundled).
- Spotify: the library page and playlist writes (library.rs), paged artist albums, Spotify
  Connect; EQ through an AVAudioEngine graph (the Spotify output is already an AVAudioEngine).
