# Upstream drift audit, 2026-09-27

`reference/harbor` is pinned at `770ca0bd` (2026-09-23, "ui changes"). `git fetch origin` (fetch
only, nothing checked out) shows `origin/beta-branch` (the branch `.gitmodules` tracks) at `a821e273`
(2026-09-26, merge of PR #1457 "plugin-fixes") — **11 commits ahead**, one of which
(`e28bc25d`) is a large squash: 397 files changed overall, 30,488 insertions / 226 deletions
across the whole diff.

Restricting the diff to the three areas this port actually mirrors (`src/views/big-picture`,
`src/lib`, `src/views/player`) shows **no changes at all in `big-picture` or `player`** — every
touched file under those roots is under `src/lib`, and it's all Music plus two small shared-lib
fixes:

```
$ git diff --stat 770ca0bd4..origin/beta-branch -- src/views/big-picture src/lib src/views/player
 76 files changed, 1975 insertions(+), 46 deletions(-)
```

The other ~320 changed files (the bulk of the 30k-line diff) are a brand-new top-level
`android-extension-compat/` tree plus `src/lib/streams/plugins/`, `src-tauri/`: a Kotlin/Android
extension-compatibility runtime for desktop's plugin system (stubs `ConnectivityManager`,
`NetworkRequest`, `Context.getSystemService`, ships CloudflareKiller, resolves V-Cloud/Pixeldrain/
Supervideo links, etc.). Confirmed via `grep -rn "capstan\|streams/plugins\|android-extension"
App/Sources engine`: **zero hits**. This subsystem doesn't exist on tvOS in any form and none of
its files are reachable through `engine/bundle-config.mjs`'s `@` alias.

## Per-commit table

| SHA | Subject | Port files it would touch | Size | Risk |
|---|---|---|---|---|
| `ce3c2451` | fix(plugins): give the check the same timeout as playback | None. Touches `src/lib/plugins/{kinds/stream,types}.ts` (desktop stream-plugin health check) and `src/views/settings/plugins-panel/plugin-row.tsx`. `grep "from \"@/lib/plugins\|from \"@/lib/streams/plugins" engine/*.ts` → no hits. | S | None — not applicable |
| `054d4baa` | fix(plugins): warm the bridge before a plugin deadline starts | `src/lib/streams/plugins/extension/{bridge,run}.ts` — Android-extension bridge only. Not applicable. | S | None |
| `1af5a409` | fix(plugins): create the capstan resource directory before dev starts | `scripts/capstan-stage.mjs`, dev tooling only. Not applicable. | S | None |
| `ea705d61` | fix(plugins): fetch extension archives as bytes instead of text | `src/lib/streams/plugins/install.ts`. Not applicable. | S | None |
| `1fc56b5d` | fix(capstan): resolve V-Cloud, Pixeldrain and Supervideo links | `android-extension-compat/*`. Not applicable. | M | None |
| `7155e5d3` | fix(capstan): add CloudflareKiller so extensions that attach it load | `android-extension-compat/*`. Not applicable. | S | None |
| `a9e286a7` | fix(capstan): stub ConnectivityManager, NetworkRequest, Context.getSystemService | `android-extension-compat/*`. Not applicable. | S | None |
| `d0d58d53` | fix(capstan): add the extension API members the corpus measured as missing | `android-extension-compat/*`. Not applicable. | M | None |
| `cca140dd` | fix(capstan): build the layer from paths with spaces, against current coroutines | `android-extension-compat/*`, build scripts. Not applicable. | S | None |
| `e28bc25d` | "Ui work + plugin work" (squash, 387 files) | Two unrelated bundles inside one commit — see breakdown below. | L | Mixed — see below |
| `a821e273` | Merge PR #1457 "plugin-fixes" | Merge commit; no new content beyond the above. | — | — |

### `e28bc25d` breakdown (the only commit with anything port-relevant)

**1. `src/lib/page-rows.ts` — bundled and imported directly, genuinely free.**
`engine/kids.ts` and `engine/rooms.ts` both do `import { applyPageRows, loadPageRows } from
"@/lib/page-rows"`, and `@` resolves straight into `reference/harbor/src` (`engine/bundle-config.mjs`
line 249). This upstream commit fixes `orderedRowKeys`/`applyPageRows`: a new/renamed row used to
always get appended at the *end* of a customized row order; now it's inserted near the position of
the nearest already-ordered row that precedes it (a stable "insert near where it naturally sits"
instead of "insert at the tail"). That's the Home-row and Kids-row custom ordering the TV's Settings
→ Rows editor drives. Pure function, no side effects, no signature change — a straight re-sync pick.
**Size: S. Risk: Low** (self-contained algorithm change; only worth re-checking against
`node smoke.mjs --offline`'s row-order checks after the bump).

**2. `src/lib/streams/plugins/*`, `src/lib/plugins/*`, `android-extension-compat/`, `src-tauri/` —
not applicable.** Same desktop/Android extension-runtime work as the other 9 commits, bundled into
this squash (`git show --stat e28bc25d` — the bulk of the 387 files and 30k lines). No port files
touch these; confirmed no import path.

**3. Music: a new "More Like This" feature, replacing "Start Radio" in the track menu.**
- `src/components/music/music-track-menu.tsx`: removes the `onStartRadio` handler/menu item
  entirely and replaces it with `onMoreLikeThis`, calling `musicSimilarTracks(track)` →
  `requestMusicExplore({ kind: "similar", ... })`. **Port impact:** `App/Sources/Music/MusicView.swift`
  line 340 currently cites `music-track-menu.tsx "Start radio" (radio.ts)` for its own start-radio
  menu entry — that upstream affordance no longer exists in this form, it's been folded into a
  broader "More Like This" surface. Re-syncing this needs real Swift/engine work, not a free
  re-bundle (`onMoreLikeThis` isn't just a rename; it's a new page (`music-similar-page.tsx`) and a
  new player-origin kind).
- `src/lib/music/radio.ts` adds `loadSimilarTracks` (new export) and reworks `relatedLane`'s
  artist-dedup (case-insensitive name dedup, keeps the artist with more `nb_fan`, widens the related
  pool from 8→14 candidates) plus a new `withSeedArtist` post-pass that guarantees at least 4 tracks
  by the seed's own artist in the mix. **Port impact:** `engine/musicRadio.ts` is a hand-written
  *reimplementation* of `radio.ts` (cited by comment, e.g. `musicRadio.ts:1`, `music.ts:423`), not a
  bundled import — `grep "radio.ts" engine/*.ts` only turns up citation comments, no `@/lib/music`
  import. So none of this flows in for free; the `relatedLane` dedup fix is a legitimate, worthwhile
  behavior fix to port by hand into `armTrackRadio`'s TV equivalent, and `loadSimilarTracks` /
  `withSeedArtist` are the algorithm to reimplement if "More Like This" gets built for the TV.
- `src/lib/music/{navigation,playback-origin,session-checkpoint,player}.ts` — add the `"similar"`
  origin/target kind and `recordMusicSimilarPlayback`/`recordMusicRecentContext`. Same story: these
  are reimplemented on the TV side (`MusicPlayer.swift`), not bundled, so no free pickup.
- New files with no TV counterpart yet: `music-recent-contexts-band.tsx`, `music-similar-page.tsx`,
  `music-up-next-row.tsx`, `music-video-transport.tsx`, `music-source-possible.tsx`,
  `music-playlist-chip.tsx` (rework), `lib/music/{hidden-recents,recent-context,scroll-continuity,
  taskbar-buttons,video-discovery}.ts` (all new). These are a cohesive new-feature cluster (recent
  "contexts" band on the Music home, an "Up Next" row, a video-transport surface, unhide-on-replay
  for hidden recents) with zero current references in `App/Sources` or `engine` — confirmed via
  `grep -rl` returning 0 for each basename. **Size: L** as a whole (real new UI + engine work across
  several rooms). **Risk: Medium** — no engine import means no compile-time exposure, but it's
  meaningful net-new scope, not a bug fix.
- `src/lib/plugins/index.ts` — `looksLikeAndroidExtensionRepo` now returns `{ kind: "stream", url }`
  instead of throwing `PluginError("android-extensions")`. Desktop plugin-detection only, no port
  file imports `@/lib/plugins`. Not applicable.
- `src/lib/viewport-bottom.ts` — raises the "keyboard is up" gap floor from `>0.5` to `>=24` and
  switches `Math.round` to `Math.floor`; this is a mobile/on-screen-keyboard viewport helper with
  zero references in the port (`grep viewport-bottom App/Sources engine` → 0). Not applicable
  (tvOS has no on-screen text-entry viewport to track this way — text entry is the system remote
  keyboard).

## Recommendation

**Worth re-syncing now (cheap, real value):**
- **Done (2026-09-27).** Bumped `reference/harbor` to `a821e273` and re-ran `node build.mjs` /
  `node smoke.mjs --offline`: bundle 4653 KB → 4670 KB, smoke 1152/1152 passed both before and after
  (0 failed) — no regression, no renamed/moved export under `src/lib/music`, `src/views/music`,
  `src/lib/feed` or `src/views/big-picture` that any engine glue module (`music.ts`, `musicSources.ts`,
  `musicRadio.ts`, `rooms.ts`, `kids.ts`) imports (confirmed by grep + a clean rebuild). The
  `page-rows.ts` stable-insert fix (`orderedRowKeys`/`applyPageRows`) is now in the bundle, unchanged
  function signatures, free pickup as predicted.
- **Done (2026-09-27).** Hand-ported `relatedLane`'s artist-dedup improvement into
  `engine/musicRadio.ts`'s `relatedLane`: case-insensitive name dedup keeping the higher-`nb_fan`
  artist, related pool widened 8 → 14, kept-after-dedup 6 → 12, per-artist top-tracks limit 8 → 5
  (matches upstream `radio.ts` at `a821e273` exactly, `RELATED_DEPTH` weighting included). New smoke
  check in `engine/smoke.mjs` (a case-insensitive "Justice"/"JUSTICE" duplicate with different
  `nb_fan`) asserts the lower-fan duplicate's top-tracks endpoint is never fetched and its track never
  reaches the station. `loadSimilarTracks`/`withSeedArtist` (the same upstream commit) were **not**
  ported here — they belong to "More Like This" (see below), not this dedup fix.

**Needs real port work (don't fold into a routine re-sync):**
- The "More Like This" **menu action is done (2026-09-27)**: `music-track-menu.tsx`'s replacement of
  `onStartRadio` with `onMoreLikeThis` is ported minimally — `engine/musicRadio.ts` gained
  `loadSimilarTracks`/`withSeedArtist` (ported verbatim from upstream `radio.ts`), `engine/music.ts`
  wraps it as `similarTracks()` (localizes the internal `music.radio.error` marker to
  `t("music.similar.error")`, same pattern as `radio()`), registered in `engine/entry.ts`.
  `App/Sources/Music/MusicView.swift`'s `MusicTrackMenuItems` (shared by every track row, the album
  page and Spotify library — confirmed the only Swift call site) now shows **More Like This**
  (`copy("music.card.moreLikeThis", …)`, `sparkles` icon) instead of Start Radio, calling new
  `MusicPlayer.startSimilar(_:)` (same `radioStatus` loading/failed UI as `startRadio`, but never
  arms the queue-extension — `loadSimilarTracks` is a fixed mix, not a growing station, matching
  upstream). Two copy keys added (`music.card.moreLikeThis`, `music.similar.error`); both already
  exist in every upstream locale catalog (`src/lib/i18n/locales/*/music-similar.ts`, reached through
  the same `@` alias `en.ts` → `en/music.ts` → `music-similar.ts` chain), so no translation work was
  needed. Two smoke checks added (dedup already covered above is separate; this feature's check
  proves the seed track is excluded and the mix is topped up to 4 seed-artist tracks).
  **Not built:** the new `music-similar-page.tsx` (a dedicated "Songs like X" browse page with
  Play all / Save as playlist) and `recordMusicSimilarPlayback`/`playback-origin.ts`'s `"similar"`
  kind — out of scope per the task ("keep the identifier/label pattern of the surrounding buttons");
  on the TV, tapping **More Like This** plays the mix immediately into the existing queue/Now
  Playing UI instead of opening a browse page first. `startRadio`/`radioArmed`/`extendRadioIfDue`
  (the queue-growing "armed" mechanic) are now unreferenced from any UI button, same as upstream (its
  own `startRadio`/`onStartRadio` are gone too — only `up-next.ts`'s suggestions still call the
  underlying `musicRadioTracks`/`radio()` station builder) — left in place as harmless dead code
  rather than removed, to keep this change minimal; a future pass could either wire a real "Radio"
  entry point back in or delete the mechanic.
- Recent-contexts band / up-next row / video-transport surface / hidden-recents unhide-on-replay:
  net-new Music UI, no current TV equivalent. Bundle into a future Music feature pass rather than
  this drift check.

**Skip entirely:**
- Every `fix(capstan)`/`fix(plugins)` commit (9 of the 11) and the matching ~320-file chunk of
  `e28bc25d`: the Android-extension-compatibility plugin runtime, `android-extension-compat/`,
  `src/lib/streams/plugins/`, `src/lib/plugins/`, `src-tauri/`. None of it is reachable from any
  port file; tvOS has no equivalent subsystem and isn't getting one via this port's architecture
  (JavaScriptCore engine + native Swift UI, no Tauri, no Android VM).
- `viewport-bottom.ts`'s keyboard-floor tweak: no port reference, no on-screen-keyboard viewport to
  track.

No re-sync, engine build, or code change was performed as part of this audit.
