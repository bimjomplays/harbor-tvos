# Harbor tvOS — instructions for Claude Code
Read `HANDOFF.md` first, then `PROJECT_STATE.md` (Next section) and `PLAN.md`.
Hard rules: no personal info in the repo (it is public); TestFlight internal only; `reference/harbor` is read-only.
Every batch: engine `node build.mjs` (check the size) + `node smoke.mjs --offline`, log in PROJECT_STATE.md, commit, push, watch the `Build` workflow, fix red builds before starting anything new.
