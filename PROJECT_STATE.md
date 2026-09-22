# PROJECT_STATE — Harbor for tvOS

## Goal
Native Apple TV app with full Harbor (beta-branch) feature parity, same Harbor account, shipped by TestFlight, no physical Mac.

## Status (2026-09-22 ~04:30, end of overnight run)
**BLOCKER: GitHub Actions free macOS minutes are exhausted** (private repo). Every run since ~03:58 fails with "The job was not started because recent account payments have failed or your spending limit needs to be increased". Nothing compiles or ships until the user either makes the repo public (unlimited) or raises the Actions spending limit. Last green CI: run 35684169889 + the following fix run (all 10 UI tests passed, real Cinemeta rows + Search + engine host verified). TestFlight build 7 (Stage 0 spikes) is still the newest on the TV; builds 8+ never uploaded.
**Stage 1 done (simulator-verified)** and **Stage 2 mostly built**:
- Engine (JSC): Swift host `App/Sources/Engine/EngineHost.swift` (13-fn `__harbor_host` contract, JSON-string bridge `call<T>(path,args)`), verified on the simulator (selfTest ok, cinemeta.topMovies 41 ms). Bundle 969 KB. `engine/rooms.ts` (Home/Movies/Shows builds + `rooms.page`), `engine/discover.ts` (rails, queue peek, genres+palette). `cd engine && npm test` = 117 shim + 60 smoke checks green.
- Swift: Home/Movies/Shows (`RoomView`, spotlight, rail, poster/wide/rank tiles, CW card/row, per-room cache), Search (BP keyboard, 180 ms debounce, engine search, top-match panel), Discover (queue band, genre tiles with OKLCH→sRGB, daily rails), TMDB key onboarding step + Settings panel via `SettingsBridge` (engine `settings.*`).
- **Uncompiled since the last green run:** `App/Sources/Discover/*` (3 files), ShellView `.discover` case, `CatalogPageView` + "See all" chip in `BPRowView`/`BPRailView`/`RoomView`, `CardMark` in `BPTileView`, the Discover UI test. Expect small compile fixes on the first run.
- Not started in Stage 2: Collections room, Home services + addons rows (addon rows need a Stremio login on the TV), award/DUB card marks, Movies/Shows hero pool, Discover awards/people bands.
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
1. User unblocks CI (public repo or spending limit). Then: `gh workflow run Build -f testflight=true`, fix any Discover compile errors, review screens 24/25.
2. User signs in on the TV (Harbor + Stremio + TMDB key) and reports.
3. Stage 2 remainder: Collections room, "See all" pages (`rooms.page`), card badges, Home services/addons rows, Movies/Shows hero pool → then Stage 3 (detail page + streams). 0.3 mpv spike, 0.4 engine spike, 0.5 Rust spike, 0.6 sync protocol doc.
