# PROJECT_STATE — Harbor for tvOS

## Goal
Native Apple TV app with full Harbor (beta-branch) feature parity, same Harbor account, shipped by TestFlight, no physical Mac.

## Status (2026-09-22, overnight run; user asleep)
**Stage 1 built and screenshot-verified in the simulator** (not yet on the TV): onboarding (language, TMDB, Stremio, Harbor, done), Harbor account login + refresh, read-only sync roster → profiles, who's watching + PIN pad, Big Picture shell (top bar, hint bar, fonts Switzer/Sentient/Fraunces bundled), Settings (account, Stremio, TMDB key, sync, profiles, dev spikes).
**Stage 2 in progress:** engine bundle now covers browse (923 KB, `engine/`, `npm test` = 117 shim + 57 smoke checks, docs/engine-report.md); `engine/rooms.ts` = Home/Movies/Shows row builders mirroring use-bp-catalog/use-bp-shows; Swift tiles/rows/rail/spotlight/RoomView done with fixture rows (screens 18-20 OK); `EngineBrowseSource` + `SettingsBridge` written but **uncompiled** — they depend on `App/Sources/Engine/EngineHost.swift` (JSC host, 13-function `__harbor_host` contract) which a subagent is writing. Next push must include it or CI fails.
Docs: docs/browse-spec.md (rooms/providers/badges/types), docs/big-picture-design.md, docs/harbor-protocol.md, docs/engine-report.md.
Gotchas: never set accessibilityIdentifier on a container (children inherit it); initial focus lands in room content, Up reaches the top bar; UI tests use `--fixtures onboarding|who|shell|spikes`.

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
1. Land EngineHost.swift, push, fix compile errors, verify Home/Movies/Shows with real Cinemeta rows in the simulator (fixtures off: add a `--live` UI test scenario).
2. TestFlight build for the user: sign in on the TV, check roster + rows + TMDB key entry.
3. Stage 2 remainder: Search (engine `search.*`, on-screen keyboard rows from browse-spec §4.5), Discover, Collections, Continue Watching card (design §8.2), card badges (§7), catalog "see all" pages, Home services/addons rows. 0.3 mpv spike, 0.4 engine spike, 0.5 Rust spike, 0.6 sync protocol doc.
