# PROJECT_STATE — Harbor for tvOS

## Goal
Native Apple TV app with full Harbor (beta-branch) feature parity, same Harbor account, shipped by TestFlight, no physical Mac.

## Status (2026-09-23 09:25 EDT)
Repo public; CI green on every push tonight; TestFlight builds dispatched after each (latest ≈ build 70; check App Store Connect). User's TMDB key still unresolved (Settings → Artwork and rows → **Test saved key** prints TMDB's answer).
Built tonight (all simulator-tested, none device-tested yet): Stage 3 detail page (episodes, seasons, credits, watchlist, Resume label + progress, watched marks from the Stremio bitfield), stream picker (flat cached-first list, quality/Cached/addon chips), debrid resolve, player (chrome, seek, pause, audio/subtitle panels, online subtitles via OpenSubtitles/Wyzie/addons, up-next pill, next-episode advance, resume + 4 s progress saves to local + Stremio), Addons manager, Library room, Anime room (Jikan), Live TV slice (M3U playlists → channel grid → live mpv mode), onboarding layout + subtitles steps, subtitle-language setting. Three fresh-context Sonnet reviews applied (10 fixes incl. mpv teardown race, zlib vs raw deflate for watched bitfields, Set→array across the JSON bridge, settingsLinked).
Morning 2026-09-23 (user asleep, "keep working"): skip intro/outro/recap pill (engine `skip.segments` over AniSkip/SkipDB/TheIntroDB/IntroDB App), display-mode matching via `AVDisplayCriteria(refreshRate:formatDescription:)` + `UIWindow.avDisplayManager` (AVKit; only acts when the viewer's Match Content is on).
Also: preferred audio/subtitle language auto-select (ISO 639-2 alias table), subtitle style → mpv, Discover Awards band + award detail (offline catalog `App/Engine/awards.json` copied by tools/sync_upstream_assets.sh and installed into the engine on first use) and Top People band (harbor.site rank API).
09:00: Trakt device-code connect (Settings → Trakt; engine `trakt.*` over lib/trakt via Harbor's token proxy) + player scrobbles (start/pause/stop ≥90%); profiles now persisted in upstream's `harbor.profiles.v1` `{activeId, profiles}` shape through KeyValueStore and mirrored into the engine (`syncStorage` + `harbor:profiles-updated` / `harbor:active-profile-changed` events); upstream secret prefixes routed to the Keychain.
09:20: Collections room (Settings-free: `collectionsRoom.mine/community/all` over lib/collections; 6-col card grid → items overlay → detail). Fourth/fifth reviews applied: Trakt poll timer cleared + de-duplicated per device code, durable-tier `get` falls back to the cache store, Trakt poll loop drops stale results. All on TestFlight (`Build` run of 09:21 EDT).
Engine: `cd engine && npm test` = 117 shim + 71 smoke checks (live network; Jikan check skips when api.jikan.moe is down). Glue files: rooms.ts, discover.ts, streams.ts, player.ts, subtitles.ts, live.ts.
Docs: browse-spec, big-picture-design, harbor-protocol, engine-report, detail-spec, player-spec, livetv-spec.

## Key files
- `PLAN.md` — full plan: architecture, 15 stages (0–14), tvOS limits, open decisions.
- `reference/harbor` — shallow clone of `harborstremio/harbor` `beta-branch` @ `1bfcfb6` (will become a submodule).

## Decisions
- SwiftUI UI modelled on upstream `src/views/big-picture`.
- HarborEngine: upstream `src/lib` TS bundled into JavaScriptCore (to be proven in Stage 0.4).
- Rust (`harbor-core`, librqbit, subsync) as tvOS static libs; `aarch64-apple-tvos` present in rustup here.
- Player: MPVKit (libmpv) + AVPlayer Auto mode.
- Repo: private on GitHub to start.
- Build: XcodeGen + GitHub Actions macOS → TestFlight internal only. CI simulator screenshots for UI review.
- Harbor account API: `harbor.site/identity/api/*`, sync `sync.harbor.site/sync/v1/{state,push}`. Sync client starts read-only.

## Next
1. User: install the newest TestFlight build; sign in to Stremio + Harbor; fix the TMDB key (Test saved key); play something and report (picker, playback, resume, subtitles, Live TV with an M3U).
2. Device-only checks: HDR/display-mode switching (AVDisplayCriteria still to do), mpv performance, remote feel in the player chrome.
3. Remaining Stage 2/3/4 gaps: services/addons Home rows, TMDB/TVDB collection sources, TMDB-driven detail rows (cast cards, More Like This), skip intro/outro, Anime4K, AVPlayer engine, sync writes (still read-only), Live TV EPG/Xtream/favorites.
