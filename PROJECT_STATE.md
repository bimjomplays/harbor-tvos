# PROJECT_STATE — Harbor for tvOS

## Goal
Native Apple TV app with full Harbor (beta-branch) feature parity, same Harbor account, shipped by TestFlight, no physical Mac.

## Status (2026-09-21)
Stage 0.1 + 0.2 half done. Private repo `bimjomplays/harbor-tvos`. CI `Build` workflow green: XcodeGen → tvOS simulator UI test → screenshot artifact `screens` (~2 Mac minutes/run). Bundle ID `com.dltnp.harbor`, tvOS 17.0+, Xcode 26.6 on `macos-26`.
TestFlight job written but untested: waiting on the user's App Store Connect API key, then `python3 tools/setup_signing.py` (creates bundle ID, dist cert, profile, GitHub secrets from Linux), user creates the app record, then `gh workflow run Build -f testflight=true`.
Open: Apple TV model + tvOS version.

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
Finish 0.1 (signing + first TestFlight upload), then 0.3 mpv spike, 0.4 engine spike, 0.5 Rust spike, 0.6 sync protocol doc.
