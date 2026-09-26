# Handoff: continuing Harbor tvOS with a fresh Claude Code session

This file is for a new Claude Code session (on any machine, any Claude account) that is asked to
"keep working on it". Read this, then `PROJECT_STATE.md` (the **Next** section is the pick-up
point), then `PLAN.md`. Do not read the whole `reference/` tree up front; open upstream files as
you need them.

## What this is
A native Apple TV (tvOS) port of the open-source Stremio client **Harbor** (`harborstremio/harbor`,
beta-branch). Upstream's TypeScript is bundled by esbuild (`engine/`) and runs inside the app in
JavaScriptCore; Swift (`App/Sources`) is the Big Picture UI. Nobody on this project has a Mac:
everything builds on GitHub Actions and ships to TestFlight **internal testing only**.

## Hard rules
- **No personal information in this repo, ever.** No emails, real names, App Store Connect
  app/group/team ids, home paths, API keys. Secrets live only in GitHub Actions secrets and the
  gitignored `secrets/` folder. The repo is public.
- **TestFlight internal only.** Never enable external testing or public links.
- **`reference/harbor` is read-only** (a pinned submodule). Port behaviour from it; never edit it.
- Don't sacrifice quality for speed: port upstream's behaviour, cite the upstream file in a comment
  (`// bp-foo.tsx: …`), keep names and copy the same as upstream.

## Where things stand (updated 2026-09-25, end of the UTC day)
- **Branch.** Everything is on `main` again (the 09-24/25 branch was fast-forwarded into it on
  2026-09-26). `Build` runs by itself on every push to `main`; TestFlight is
  `gh workflow run Build -f testflight=true` on `main` (owner only).
- **CI.** `Build` runs 222 through 257 and later are green (compile + simulator UI tests), apart
  from four whose failures were fixed straight after: 235, 236 and 251, where new navigation UI tests caught
  real focus bugs, and 249, one compile error (see the rules below). The simulator runs
  **33 UI tests**: `App/UITests/ScreenshotTests.swift` (12, the screen walk with screenshots) and
  `NavigationTests.swift`, `NavigationTests2.swift`, `NavigationTests3.swift`, `NavigationTests4.swift`
  (5 + 5 + 5 + 6 remote-walk tests on offline fixtures: `--fixtures shell`, `who`, `roomfail`,
  `calfail`, `detail`, `kidsfail`, `discfail`, `bands`). Engine: `node build.mjs` ≈ 4.6 MB,
  `node smoke.mjs --offline` = 1105 checks.
- **TestFlight.** Build 220 (the branch up to `37aa626`, uploaded ~11:07 UTC 09-25) is the newest on
  TestFlight. Run 221's upload hit Apple's daily upload limit (code **90382**) at 11:22 UTC 09-25, so
  every run since has been a compile check (`testflight=false`). The retry is scheduled for
  **2026-09-26 11:30 UTC** as a `Build` dispatch with `testflight=true`; that build carries everything
  since 220. What to check on the TV: `docs/device-checklist.md` → "Next TestFlight build". Nothing
  built after the Stage 0 spike has run on real hardware yet.
- **What 09-25 did.** Bug passes and device-flow passes 1–10 over every room; the parity passes from
  `docs/parity-gaps.md` (P8 switch source in place, P11 Continue Watching exit snapshot, S5 Watch
  Together host match, and most of the other rows); fresh-context reviews 5–33; performance passes
  3–5; the navigation UI tests; a pre-release crash audit. `PROJECT_STATE.md` → Status has one line
  per batch (real UTC time, commit, "Open:" and "Device check:" lists). Its Next section's run list
  stops at run 256; this section is newer.

## Next steps
1. When the 09-26 upload is on TestFlight, the owner walks `docs/device-checklist.md` → "Next
   TestFlight build" (Test first, then by area). Fix what fails before starting new features.
2. Remaining parity gaps: `docs/parity-gaps.md` → "Where this audit stands" (S4 subtitle step, flag
   icons, the automatic subtitle search, H5 open-anywhere, the X3 / V3 sampled glow, O2, and the
   smaller behaviour differences listed there).
3. Low "Open:" items from the latest Status lines, e.g. the Music room's own dock and the Spotify
   library page losing the ring on Stop and close player, Live TV showing All after an A → B → A
   source switch, a sync-pulled theme or language dropping a non-player cover.
4. Ask the owner about the decisions below before touching those areas.

## Owner decisions still open
- The curfew lock's "Switch profile" works without the parent PIN.
- TV collection edits are not published to the account (upstream publishes on back; collections are
  not profile-synced, and an ungated publish can overwrite the account's collections).
- A deep link under a kid profile: a kid's shell takes titles only, but any title opens.
- O2: avatar and name write-back to the Harbor account (not ported, because it writes to the account).
- Collections with no TMDB key: the TV keeps the feed (Mine, Community, TVDB lists, and the only place
  to edit collections on the TV); upstream replaces the room with BpConnect.
- eBook chapters opened from the chapter panel or bar start at line 0; upstream restores the saved line.

## How the work is done (the 09-25 subagent workflow)
- One subagent per batch, each in its own git worktree, at most ~6 at once. Before its final commit
  it merges the latest branch, greps every caller of any shared signature it changed, runs
  `node build.mjs` (check the size) and `node smoke.mjs --offline`, and commits.
- The orchestrating session merges the worktree, runs build + smoke again, logs the Status line in
  `PROJECT_STATE.md`, pushes, dispatches `Build` on the branch, and fixes a red run before anything new.
- After every feature pass comes a **review pass**: a fresh-context subagent does a compile-safety
  read of every changed file and an adversarial read against the cited upstream files, fixes what it
  finds, and lists the rest as "Open:" for the next open-items sweep.
- New focus behaviour gets a navigation UI test where the offline fixtures can reach it (these caught
  real bugs on runs 235, 236 and 251).

## Compile-safety rules (learned on 09-25; Swift can't be compiled locally)
- No code after `//` on a line: a trailing comment swallowed a button's action (HomeRowsPanel, run 183).
- Give an array literal its type before `.map`: a literal mapped into `[UnsafePointer<CChar>?]` took
  that element type and failed to compile (ExitSnapshot, run 249). Write `let args: [String] = [...]`
  first.
- A lone centred button (a failure plate's Try again) needs a full-width `.focusSection()`, or Down
  from the tab bar never reaches it (RoomView.pageMessage, run 251).
- Capture `let` copies, not `var`s, in `Task { }` closures.
- `onChange(of:)` with the two-parameter `{ old, new in }` closure needs an `Equatable` value; make
  the enum or struct Equatable first.
- Double → Int for any value the app does not control (addon, synced, player) goes through
  `clampedInt` (`App/Lenient.swift`); a bare `Int(x)` traps on NaN, infinity and out-of-range values.
- Older rules still apply: check tvOS availability (`updatesNowPlayingInfoCenter`, NSLayoutManager
  temporary attributes), keep argument order at every call site, and move focus only after an alert
  has gone (a focus set under an alert is dropped).

## Setup (once, on the new machine)
```bash
git clone --recurse-submodules https://github.com/bimjomplays/harbor-tvos
cd harbor-tvos/engine && npm install && node build.mjs && node smoke.mjs --offline
gh auth login      # a GitHub account that has push access to this repo
```
Node 20+ and the GitHub CLI are all that's needed locally. Xcode is not.

## The loop (every batch)
1. Pick the next item from "Next steps" above, `PROJECT_STATE.md` → Next, or the open gaps in
   `docs/parity-gaps.md`.
2. Engine changes: `cd engine && node build.mjs` — watch the size it prints (≈4.6 MB). A jump of
   several MB means a lazy `import()` got inlined; add a stub in `engine/bundle-config.mjs`.
   Then `node smoke.mjs --offline` (must pass) and, when network is fine, `node smoke.mjs`.
3. Swift changes can't be compiled locally; write carefully, small batches.
4. Add a timestamped line to `PROJECT_STATE.md` → Status, commit, push.
5. Wait for the `Build` workflow: `gh run list --workflow Build --limit 1`, then
   `gh run view <id>`. Red → `gh run view <id> --log-failed | grep -A3 '##\[error\]'`, fix, push.
6. Green → TestFlight: `gh workflow run Build -f testflight=true`. **This step only works for the
   repository owner** (the workflow checks `github.actor == github.repository_owner`); a
   collaborator asks the owner to run it, or the owner relaxes that condition in
   `.github/workflows/build.yml`. Apple takes only a handful of uploads a day; past that the upload
   fails with code 90382 and the next try waits about a day, so upload in batches.
7. After each feature pass, run a fresh-context review (a subagent that has not seen the work, told
   to find defects against the cited upstream files) and apply its findings.

## Where things are
- `PROJECT_STATE.md` — status log + pick-up point. `PLAN.md` — the 15 stages.
- `docs/parity-audit-2026-09-23.md` — every Big Picture gap, ranked; most S/M rows are done.
- `docs/parity-gaps.md` — the 09-25 audit and what is still open. `docs/device-checklist.md` — what
  to check on a real Apple TV, with the next TestFlight build's list first.
- `App/UITests/` — the simulator UI tests (screenshots and navigation walks on offline fixtures).
- `engine/entry.ts` — everything Swift can call (`HarborEngine.shared.call("<export>.<fn>", args)`).
  Glue modules sit beside it (`rooms.ts`, `streams.ts`, `live.ts`, `sports.ts`, …).
- `App/Sources/<Area>/` — SwiftUI rooms; `App/Sources/Engine/EngineHost.swift` is the bridge.
- `ci/` and `.github/workflows/build.yml` — the simulator build + UI screenshots, then archive/upload.

## Starter prompt for the new session
> Read HANDOFF.md, then PROJECT_STATE.md (start with the Next section) and PLAN.md. Continue the
> work in order: first make CI green, then fix whatever the owner's device check reports, then take
> the next items from HANDOFF.md → Next steps and docs/parity-gaps.md. Follow the loop in HANDOFF.md for every batch. Keep working autonomously; ask only
> when a decision genuinely needs the owner.
