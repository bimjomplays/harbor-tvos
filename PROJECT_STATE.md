# PROJECT_STATE — Harbor for tvOS

## Goal
Native Apple TV app with full Harbor (beta-branch) feature parity, same Harbor account, shipped by TestFlight, no physical Mac.

## Status (2026-09-22)
Stage 0: 0.1, 0.2 done; 0.3/0.4/0.5 pass in the simulator (build 7 on TestFlight, real-TV check pending); 0.6 protocol doc written (`docs/harbor-protocol.md`, 766 lines, by a subagent, spot-checked); 0.7 storage layer not started.
- Engine (JavaScriptCore): upstream `src/lib/streams` bundled by `engine/build.mjs` (esbuild, `@/` alias, Tauri stubs) → 89 KB; loads in 181 ms, 850 streams parse+trust+score+rank in 332 ms on the simulator. GO.
- Rust: `rust/harbor-ffi` (C ABI over harbor-core, staticlib) builds for `aarch64-apple-tvos` + `-sim` on the runner via `rust/build.sh`, linked with a modulemap; pipeline works. GO.
- mpv: MPVKit 1.0.0 (SPM), gpu-next/MoltenVK into CAMetalLayer, hwdec videotoolbox; HEVC plays in the simulator. Real-TV HDR/DV/PGS check pending (Spike menu → Player).
- CI (`Build`): checkout with submodule → Rust libs → engine bundle → XcodeGen → sim UI tests (4 pass) → screenshots; TestFlight job on `workflow_dispatch testflight=true` (build number = run number).
- Protocol facts that change the plan: profile sync is at `harbor.site/themes/api/sync/v1/*` (bearer), NOT sync.harbor.site (that is the subtitle-autosync crowd DB); sessions per local profile with refresh token (6 h proactive refresh); 9 live sync sections (profiles, watchedby, home, anime, nav, services, settings, theme, playerlayout); server-wins with local parking, except watchedby (LWW merge); no client-side encryption.
- Upstream is a git submodule at `reference/harbor` pinned to `1bfcfb6` (beta-branch).
- Gotcha: never name a bundle folder `Resources` on tvOS (flat bundle breaks); engine JS lives in `App/Engine/`.

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
User tests build 7 on the TV (Player spike: HDR10, DV P5/P8, PGS/SRT clips) → record go/no-go → 0.7 storage layer → Stage 1. 0.3 mpv spike, 0.4 engine spike, 0.5 Rust spike, 0.6 sync protocol doc.
