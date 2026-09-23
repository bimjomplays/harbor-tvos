# PROJECT_STATE — Harbor for tvOS

## Goal
Native Apple TV app with full Harbor (beta-branch) feature parity, same Harbor account, shipped by TestFlight, no physical Mac.

## Status (2026-09-22 ~04:30, end of overnight run)
**Repo is PUBLIC since 2026-09-22 morning** (free Mac minutes were exhausted on the private repo). History was rewritten to strip the account-holder email, ASC app/group ids, a real first name in fixtures and `/home/<user>` paths; secrets live only in `secrets/` (ignored) and GitHub encrypted secrets. Never commit personal identifiers; keep ASC ids in `secrets/asc.json` only. Run 35792661029: everything compiled first try, 12 UI tests green, TestFlight build uploaded.
**Stage 1 done (simulator-verified)** and **Stage 2 mostly built**:
- Engine (JSC): Swift host `App/Sources/Engine/EngineHost.swift` (13-fn `__harbor_host` contract, JSON-string bridge `call<T>(path,args)`), verified on the simulator (selfTest ok, cinemeta.topMovies 41 ms). Bundle 969 KB. `engine/rooms.ts` (Home/Movies/Shows builds + `rooms.page`), `engine/discover.ts` (rails, queue peek, genres+palette). `cd engine && npm test` = 117 shim + 60 smoke checks green.
- Swift: Home/Movies/Shows (`RoomView`, spotlight, rail, poster/wide/rank tiles, CW card/row, per-room cache), Search (BP keyboard, 180 ms debounce, engine search, top-match panel), Discover (queue band, genre tiles with OKLCH→sRGB, daily rails), TMDB key onboarding step + Settings panel via `SettingsBridge` (engine `settings.*`).
- Not started in Stage 2: Collections room, Home services + addons rows (addon rows need a Stremio login on the TV), award/DUB card marks, Movies/Shows hero pool, Discover awards/people bands.
**Stage 3 started (2026-09-23 night):** `engine/streams.ts` (resolveImdb, gatherStreamAddons, ranked pipeline with `harbor-tvos:streams` progress events, debrid `resolve`) + Swift `StreamsModel`, `PlayPickerView` (tiers, badges, best pick), `DetailModel/DetailView` (Cinemeta meta + episodes/seasons), `PlayerScreen` (mpv + headers + minimal HUD). Every tile opens the detail page; Play → picker → resolve → player — all green in CI (run with tests 26/27), TestFlight build dispatched 2026-09-23 ~00:40. Specs: docs/detail-spec.md (944 lines), docs/player-spec.md (1489 lines).
**Stage 4 groundwork (2026-09-23 ~01:00):** `engine/player.ts` (startPosition via upstream resolveStartMs, saveProgress → resume + local CW + Stremio libraryPut, watched at 0.85 clears resume); Swift `PlaybackContext`, `PlayerScreen` chrome (Select pause, Left/Right ±10 s, 4.6 s auto-hide, Back closes chrome then player, audio/subtitle track panels from mpv track-list), mpv options from mpv.rs (VOD cache, reconnect, sub slots), header escaping. Picker is now a flat cached-first list with quality/Cached/addon chips (detail-spec §2.5).
**Also tonight:** Continue Watching merges local resume (`rooms.continueWatchingFor`), detail page shows Resume S:E / progress under Play and auto-advances to the next episode's picker, Addons manager (Settings → Manage addons: account + local, enable/disable, install by URL, remove), online subtitles (`subtitles.search/prepare` → text file → `sub-add`), player audio/subtitle panels. Every push was green; TestFlight dispatched after each (latest builds ~40+).
Review (Sonnet, fresh context) found 7 issues, all fixed 02:00: mpv teardown race, picker→player present-while-dismissing, anime video_id parsing (kitsu:id:ep = S1), episode-nil resume gate, onEvent leak, natural-end duration guard, Int32 mpv flags. Library (Stremio library rails) and Anime (Jikan) rooms added; Jikan was 504/429 from this PC tonight, so the anime smoke check skips when Jikan is down.
Second review (02:00) fixed: `loadDisabledAddons` Set→array across the bridge, audio panel focus target, `settingsLinked` carried from the roster into `ProfilesStore.Profile.linked` (all engine calls now pass it instead of isPrimary), Select on the hidden-chrome player surface toggles pause. Settings gained a subtitle-language picker; onboarding gained the Home layout step; detail page gained a Stremio watchlist toggle.
Focus rules learned: the shell owns a `focusScope`; rooms call `ShellFocus.shared.requestDefault()` when rows arrive (`prefersDefaultFocus` on the rail); from a rail the first Up lands on the row's "See all" chip, the second reaches the bar.
Docs: docs/browse-spec.md, docs/big-picture-design.md, docs/harbor-protocol.md, docs/engine-report.md.
Gotchas: never set accessibilityIdentifier on a container; initial focus lands in room content, Up reaches the top bar; UI tests use `--fixtures onboarding|who|shell|spikes|live` (+ `--query dune`); fixture rows are never cached; CI concurrency groups are per event so a TestFlight dispatch no longer cancels a push run.

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
1. User installs the new TestFlight build, signs in on the TV (Harbor + Stremio + TMDB key) and reports.
3. Stage 2 remainder: Collections room, "See all" pages (`rooms.page`), card badges, Home services/addons rows, Movies/Shows hero pool → then Stage 3 (detail page + streams). 0.3 mpv spike, 0.4 engine spike, 0.5 Rust spike, 0.6 sync protocol doc.
