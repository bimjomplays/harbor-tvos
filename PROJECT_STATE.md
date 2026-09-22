# PROJECT_STATE — Harbor for tvOS

## Goal
Native Apple TV app with full Harbor (beta-branch) feature parity, same Harbor account, shipped by TestFlight, no physical Mac.

## Status (2026-09-22)
**Stage 0.1 + 0.2 done.** Private repo `bimjomplays/harbor-tvos`. CI `Build`: XcodeGen → tvOS simulator UI test → screenshot artifact `screens` (~2 Mac min). TestFlight job works: `gh workflow run Build -f testflight=true` (~2 min archive+upload; build number = run number). First build (3) uploaded and VALID.
App Store Connect: app id `<asc-app-id>` "Harbor TV dltnp", bundle `com.dltnp.harbor`, internal group "Internal" `<asc-group-id>` (all builds), tester = account holder (<account-holder-email>), invite sent. `tools/setup_signing.py` holds a working ASC API client (JWT via openssl) for automation.
Apple TV: A2737 (4K 3rd gen 2022, A15), tvOS 26.6 (23L773).

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
User confirms the app launches from TestFlight on the TV, then 0.3 mpv spike, 0.4 engine spike, 0.5 Rust spike, 0.6 sync protocol doc.
