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

## Setup (once, on the new machine)
```bash
git clone --recurse-submodules https://github.com/bimjomplays/harbor-tvos
cd harbor-tvos/engine && npm install && node build.mjs && node smoke.mjs --offline
gh auth login      # a GitHub account that has push access to this repo
```
Node 20+ and the GitHub CLI are all that's needed locally. Xcode is not.

## The loop (every batch)
1. Pick the next item from `PROJECT_STATE.md` → Next, or the ranked gaps in
   `docs/parity-audit-2026-09-23.md`.
2. Engine changes: `cd engine && node build.mjs` — watch the size it prints (≈2.8 MB). A jump of
   several MB means a lazy `import()` got inlined; add a stub in `engine/bundle-config.mjs`.
   Then `node smoke.mjs --offline` (must pass) and, when network is fine, `node smoke.mjs`.
3. Swift changes can't be compiled locally; write carefully, small batches.
4. Add a timestamped line to `PROJECT_STATE.md` → Status, commit, push.
5. Wait for the `Build` workflow: `gh run list --workflow Build --limit 1`, then
   `gh run view <id>`. Red → `gh run view <id> --log-failed | grep -A3 '##\[error\]'`, fix, push.
6. Green → TestFlight: `gh workflow run Build -f testflight=true`. **This step only works for the
   repository owner** (the workflow checks `github.actor == github.repository_owner`); a
   collaborator asks the owner to run it, or the owner relaxes that condition in
   `.github/workflows/build.yml`.
7. After a few batches, run a fresh-context review (a subagent that has not seen the work, told to
   find defects against the cited upstream files) and apply its findings.

## Where things are
- `PROJECT_STATE.md` — status log + pick-up point. `PLAN.md` — the 15 stages.
- `docs/parity-audit-2026-09-23.md` — every Big Picture gap, ranked; most S/M rows are done.
- `engine/entry.ts` — everything Swift can call (`HarborEngine.shared.call("<export>.<fn>", args)`).
  Glue modules sit beside it (`rooms.ts`, `streams.ts`, `live.ts`, `sports.ts`, …).
- `App/Sources/<Area>/` — SwiftUI rooms; `App/Sources/Engine/EngineHost.swift` is the bridge.
- `ci/` and `.github/workflows/build.yml` — the simulator build + UI screenshots, then archive/upload.

## Starter prompt for the new session
> Read HANDOFF.md, then PROJECT_STATE.md (start with the Next section) and PLAN.md. Continue the
> work in order: first make CI green, then wire the pending WIP, then take the next items from the
> parity audit. Follow the loop in HANDOFF.md for every batch. Keep working autonomously; ask only
> when a decision genuinely needs the owner.
