# Harbor Player — Native libmpv Port Spec (Stage 4)

Source repo: `reference/harbor` (read-only reference; this document is the only file
written). All citations are `path:line` relative to that repo root. Every value below was
read directly from source; anything not found in the code is marked **"not found"** rather
than guessed.

Cross-references (not repeated here):
- Tailwind/token system, focus-ring mechanics (`data-bp-focusable`, `data-bp-chip`,
  `data-bp-autofocus`, spatial nav), canvas/viewport rules — `docs/big-picture-design.md`.
- `Meta`, `LibraryItem`-adjacent browse types, settings-key conventions —
  `docs/browse-spec.md`.
- Account/session storage key scheme (`harbor.settings*`) — `docs/harbor-protocol.md` §6.

Scope: the **10-foot ("Big Picture") player**, `src/views/big-picture/player/*` plus its
state/wiring seam in `src/views/player/bp-ten-foot.tsx`, the shared (desktop + TV)
`src/views/player/*` playback hooks it depends on, the Rust/libmpv host in
`src-tauri/src/mpv.rs`, resume/progress persistence, subtitle sourcing, and the concrete
TypeScript types a Swift/MPVKit port needs to reproduce.

---

## 1. TV PLAYER UI (`src/views/big-picture/player/*`)

### 1.1 Shell composition

`BpPlayerShell` (`src/views/big-picture/player/bp-player-shell.tsx:78-392`) is the root. It
renders in a `createPortal(..., document.body)` (`bp-player-shell.tsx:272,389-390`) because
`bp-shell.tsx` sets `visibility:hidden` on `[data-bp-root]` the instant playback opens, and a
hidden subtree cannot hold focus (`bp-player-shell.tsx:70-72`).

Layout, top to bottom inside the chrome container (`bp-player-shell.tsx:294-379`):
1. **Identity row** (`top` slot, defaults to `BpPlayerIdentity`) — only rendered while
   `phase === "up"` (`bp-player-shell.tsx:311-319`).
2. **Scrub row** (`BpPlayerScrub`) — always rendered, even when chrome is down, so the
   position bar exists as a layout row (`bp-player-shell.tsx:322-326`).
3. **Transport row** (`transport` slot, defaults to `BpPlayerControls`) — only while `up`
   (`bp-player-shell.tsx:328-345`).
4. **Rail row** (`rail` slot, defaults to `BpPlayerRail`) — only while `up`
   (`bp-player-shell.tsx:347-369`).
5. **Hint bar** (`BpHintBar`, actions `["select", "back"]` — `bp-player-shell.tsx:32,377`).

An **active panel** (subtitles/audio/sources/quality/resume) renders in its own top layer at
`z-[60]`, above the stage (`z-30`) and the chrome (`z-40`) (`bp-player-shell.tsx:284-292,
301-304,385-387`).

### 1.2 Chrome show/hide state machine

Owned by `useBpPlayerChrome` (`src/views/big-picture/player/use-bp-player-chrome.ts:29-102`),
independent of the desktop player's mouse-driven chrome timer (comment,
`use-bp-player-chrome.ts:24-28`). Phases: `"up" | "peek" | "down"` (`BpChromePhase`, imported
from `bp-player-context.ts`).

Constants (`use-bp-player-chrome.ts:4-7`):
```
IDLE_UP_MS = 4600            // chrome auto-hides 4.6s after last activity while playing
PEEK_MS = 1800               // a "peek" (arrow press while chrome is down) holds 1.8s
ACTIVITY_THROTTLE_MS = 260   // a held D-pad direction repeats faster than this; throttled
FADE_MS = 320                // opacity fade-out duration before unmount
```
Rules:
- A **paused** video is treated as a title card: the idle countdown only runs while
  `playing && !pinned && !held` (`use-bp-player-chrome.ts:77-80`). `pinned` = an open panel;
  `held` = an explicit hold flag (e.g. scrub in progress) via `holdChrome(true)`.
- `wakeChrome()` → phase `"up"`, resets the activity clock (`use-bp-player-chrome.ts:52-57`).
- `peekChrome()` → phase `"peek"` only if not already `"up"` (`use-bp-player-chrome.ts:59-63`);
  auto-returns to `"down"` after `PEEK_MS`.
- `hideChrome()` → phase `"down"` immediately (`use-bp-player-chrome.ts:65`).
- `reducedMotion()` (via `matchMedia("(prefers-reduced-motion: reduce)")`) skips the
  `FADE_MS` unmount delay and unmounts immediately (`use-bp-player-chrome.ts:9-12,84-87`).
- While `phase === "up"`, a capture-phase `keydown` listener re-notes activity without
  consuming the key, so any key press resets the idle timer even if a lower-level handler
  swallows it (`use-bp-player-chrome.ts:92-99`).

### 1.3 Key routing — Select / Play-Pause / Menu

Two mutually-exclusive key owners, one at a time (comment, `use-bp-player-keys.ts:17-19`):
- **Chrome up**: `useBpFocusRoot` in `bp-player-shell.tsx:211-222` owns arrows/Enter/Back
  through the general spatial-nav engine.
- **Chrome down** (idle): `useBpPlayerIdleKeys` (`src/views/big-picture/player/use-bp-player-keys.ts:28-82`).
  - `ArrowUp`/`ArrowDown` → `onSummon` (wakes chrome fully) (`use-bp-player-keys.ts:51-56`).
  - `ArrowLeft`/`ArrowRight` → first asks the scrub bar's own handler
    (`bpPlayerHandledKey`, registered by `setBpPlayerKeyHandler` in
    `bp-player-scrub.tsx:96-113`); if declined, falls through to `onPeek`
    (`use-bp-player-keys.ts:42-59`).
  - `Enter` (Select) → `onSelect`, wired in the shell to `playback.playPause()` +
    `wakeChrome()` (`use-bp-player-keys.ts:61-66`; `bp-player-shell.tsx:203-206`).
  - `" "` (Space, arrives from a gamepad's A button too) → `onSummon` only, deliberately not
    play/pause here to avoid double-firing (`use-bp-player-keys.ts:68-71`).
  - `Tab` or `ContextMenu` (Menu) → `onOptions`, wired to `wakeChrome`
    (`use-bp-player-keys.ts:73-77`; `bp-player-shell.tsx:229`).
  - Both listeners bail if `bpOverlayOpen()` or an `<input>/<textarea>` is focused
    (`use-bp-player-keys.ts:40`).

### 1.4 Seek bar (`BpPlayerScrub`, `src/views/big-picture/player/bp-player-scrub.tsx`)

- **No chapter marks and no trickplay thumbnail.** Confirmed by grep: neither
  `chapter` nor `trickplay`/`Trickplay`/`thumb` appears anywhere under
  `src/views/big-picture/player/`. The desktop `src/components/player/transport/seek-bar.tsx`
  imports `useTrickplayState` (`seek-bar.tsx:9,41`) and `ThumbPreview`
  (`seek-bar.tsx:11,184`) — that is desktop-only; `seek-bar-visual.tsx` also has no chapter
  logic. **Chapters do exist as data** (`snap.chapters: Chapter[]`, `bridge.ts:73`, used to
  derive skip segments — §1.7) but the TV scrub bar does not render marks for them.
- Track/buffered/played bars, `pct()` helper (`bp-player-scrub.tsx:21-24`).
- **Step accumulation**: Left/Right nudge a *pending* seek target rather than seeking
  immediately; commits after `COMMIT_MS = 420`ms of inactivity (`bp-player-scrub.tsx:9,67-75`).
- **Ramp**: repeated presses scale the step size —
  `STEP_RAMP_AT = 10` presses → `STEP_RAMP_X = 3`×; `STEP_RUSH_AT = 26` → `STEP_RUSH_X = 6`×
  (`bp-player-scrub.tsx:11-14,85-94`). Base step size = `settings.seekBackStepSec` /
  `settings.seekForwardStepSec` (default `10`s each, `bp-player-scrub.tsx:58-59`).
- Flushes any pending seek on unmount so a chrome-hide mid-accumulation isn't silently
  dropped (`bp-player-scrub.tsx:77-83`).
- Live streams: scrub bar becomes non-interactive (`steppable = active && !playback.live`,
  `bp-player-scrub.tsx:60`), shows a pulsing "Live" badge instead of a duration
  (`bp-player-scrub.tsx:170-174`).
- Below the bar: current time, and either the Live badge, or
  `"{time} left"` + `"Ends {time}"` (a wall-clock ETA computed via
  `Intl.DateTimeFormat` with `hour: "numeric", minute: "2-digit"`,
  `bp-player-scrub.tsx:26-33,176-183`).

### 1.5 Transport controls (`BpPlayerControls`, `bp-player-controls.tsx:66-128`)

Order: `[Previous episode?]` `[Back {n}s]` `[Play/Pause]` (primary, larger, autofocus)
`[Forward {n}s]` `[Next episode?]`. Prev/Next episode chips only render when
`playback.hasPrevEpisode || playback.hasNextEpisode` (`bp-player-controls.tsx:71,75,116`);
Back/Forward hidden entirely on live (`bp-player-controls.tsx:85,107`). Labels (verbatim,
`t()`-wrapped i18n keys) — `"Previous episode"`, `"Back {n}s"`, `"Pause"`/`"Play"`,
`"Forward {n}s"`, `"Next episode"` (`bp-player-controls.tsx:77,87,95,109,118`).

### 1.6 Rail (`BpPlayerRail`, `bp-player-rail.tsx:51-117`)

Always-first chip: **"Back"** (`bp-player-rail.tsx:71-76`). Then one chip per declared
`BpPlayerSlot area="panel"` (label/icon are the slot's own props). Then, only if no
dedicated `"subtitles"` panel slot exists AND `playback.canToggleSubtitles`, a quick
**"Subtitles on"/"Subtitles off"** toggle chip (`bp-player-rail.tsx:63-64,87-101`). Always
last: **"Muted"/"Sound on"** toggle (`bp-player-rail.tsx:102-114`).

Panels registered by `BpTenFoot` (`src/views/player/bp-ten-foot.tsx:159-261`), each a
`<BpPlayerSlot area="panel" id=... label=... icon=... shellNav>`:
| id | label | icon | condition |
|---|---|---|---|
| `resume` (`RESUME_PANEL`) | — (forced panel, blocks everything) | — | `pendingResumeSec != null` (`bp-ten-foot.tsx:31,85,163,182-193`) |
| `subtitles` | `"Subtitles"` | `Captions` | not resuming (`bp-ten-foot.tsx:195-205`) |
| `audio` | `"Audio"` | `Languages` | not resuming (`bp-ten-foot.tsx:207-225`) |
| `sources` | `"Sources"` | `AllAddonsIcon` | not resuming, `!src.isLive` (`bp-ten-foot.tsx:227-244`) |
| `home-server-quality` | `"Quality"` | `Gauge` | not resuming, `src.homeServer` present (`bp-ten-foot.tsx:246-260`) |

**No playback-speed menu and no explicit "next episode" menu on TV.** Confirmed by grep:
no `speed`/`Speed` string appears under `src/views/big-picture/player/` outside of P2P
download-speed telemetry (`bp-p2p-status.tsx`). The desktop player has a dedicated
`src/components/player/transport/speed-menu.tsx`; there is no TV equivalent — this is a
gap the native port must decide how to fill (see §6). "Next episode" on TV is handled
entirely by the Up Next card / skip-pill flow (§1.7), not a menu.

### 1.7 Skip intro/outro, Up Next, auto-advance

Types (`src/lib/skip-intro/types.ts:1-9`, verbatim):
```ts
export type SkipKind = "intro" | "outro" | "recap" | "ad";
export type SkipSource = "aniskip" | "introdb" | "skipdb" | "introdb-app" | "chapters" | "adcorpus";

export type SkipSegment = {
  kind: SkipKind;
  startSec: number;
  endSec: number;
  source: SkipSource;
};
```

**Segment sources, in merge priority order** (`mergeSegments`, first-listed wins on overlap
— `src/lib/skip-intro/index.ts:27-39,172`): `adSegments`, then `aniSkip`, `skipDb`,
`introDb`, `introDbApp`, then `fromChapters` (chapter-title pattern match, lowest priority).

- **AniSkip** — anime only. Endpoint:
  `` `https://api.aniskip.com/v2/skip-times/${malId}/${episode}?${params}` ``
  (`aniskip.ts:94`), `types` params = `op, ed, mixed-op, mixed-ed, recap`
  (`aniskip.ts:92`), plus `episodeLength`. Requires a Kitsu→MAL id resolution first
  (`kitsuToMal`, `aniskip.ts:34-78`, cached in `localStorage["harbor.kitsu-to-mal.cache.v1"]`,
  `aniskip.ts:5`). Maps `skipType`: `"ed"`/`"mixed-ed"` → `"outro"`, `"recap"` → `"recap"`,
  else → `"intro"` (`aniskip.ts:117`).
- **TheIntroDB** — `` `https://api.theintrodb.org/v2/media?${params}` ``
  (`theintrodb.ts:80`), optional `X-API-Key` header from `settings.theIntroDbKey`
  (`theintrodb.ts:19,30-33,79-81`). Query by `tmdb_id` or `imdb_id` + `season`/`episode`
  (`theintrodb.ts:112-118`). Response fields `intro`/`recap`/`credits`/`preview` map to
  kinds `intro`/`recap`/`outro`/`outro` respectively (`theintrodb.ts:130-133`). 404 is
  cached as "no data"; any other failure triggers a 10-minute cooldown
  (`FAILURE_COOLDOWN_MS = 10 * 60 * 1000`, `theintrodb.ts:24,83-89`).
- **SkipDB** — `` `https://api.skipdb.tv/api/segments?${key}` `` (`skipdb.ts:56`).
- **IntroDB App** — `` `https://api.introdb.app/segments?${key}` `` (`introdb-app.ts:46`).
- **AdCorpus** (injected-ad segments, not intro/outro) — `` `${HARBOR_API_BASE}/updates/ad-segments.json` ``
  (`adcorpus.ts:5`), a signed corpus (`CORPUS_PUBKEY`, `adcorpus.ts:6`) keyed by a
  content+source fingerprint, only for `ih_`/`rg_`-prefixed sources
  (`adcorpus.ts:22`).
- **Chapters** — `chaptersToSegments()` (`chapters.ts:29-43`) classifies mpv chapter titles
  by regex: intro patterns `/\b(opening|op)\b/i`, `/\bintro\b/i`, `/\bopening\s*credits\b/i`,
  `/\btheme\s*song\b/i`; outro patterns `/\b(ending|ed)\b/i`, `/\b(outro|outtro)\b/i`,
  `/\bend\s*credits?\b/i`, `/\bclosing\s*credits?\b/i`, `/\bcredits?\b/i`; recap pattern
  `/\b(recap|previously)\b/i` (`chapters.ts:4-19`).

**Post-merge filters** (`index.ts:174-182`): drop segments starting at/after `durationSec`;
clamp `endSec` to `durationSec`; drop segments shorter than 2s or longer than
`MAX_SEGMENT_SEC = 360`; drop `"outro"` segments starting before
`durationSec * MIN_OUTRO_START_FRACTION` (`0.5`) (`index.ts:18-19`).

**Active segment**: `activeSegment()` returns the first segment where
`positionSec >= startSec && positionSec < endSec - 0.75` (`index.ts:214-222`) — a 0.75s
early cutoff so the pill/auto-skip doesn't re-fire right at the boundary.

**Auto-skip**: gated per-kind by settings `autoSkipIntro`/`autoSkipRecap`/`autoSkipOutro`/
`autoSkipAd` (`skip-pill-container.tsx:74-78`), fires once per segment instance via a ref
guard (`skip-pill-container.tsx:68-91`).

**Skip pill auto-hide**: `settings.skipButtonHideSec` — if `> 0`, the pill auto-dismisses
that many seconds after appearing (`skip-pill-container.tsx:106-108`); user can also
dismiss it manually and it stays dismissed until the segment key changes
(`skip-pill-container.tsx:93-121`). `settings.showSkipButton` gates whether it renders at
all.

**Skip pill button labels** (`bp-skip-pill.tsx:148-157`, verbatim `t()` keys): ad →
`"Skip injected ad?"`; intro → `"Skip Intro"`; recap → `"Skip Recap"`; outro-with-next-episode
→ `"Next Episode"`; else (plain outro) → `"Skip Credits"`. Dismiss button:
`"Hide this Skip button"` (`bp-skip-pill.tsx:213-214`). The pill deliberately never takes
autofocus (long comment, `bp-skip-pill.tsx:23-43`) — reachable only by navigating Up from
the transport, or by the `MediaFastForward` remote key (`bp-skip-pill.tsx:116-129`).

**Next-episode lead time / Up Next countdown** (`skip-pill-container.tsx:10-14`):
```ts
export function nextEpisodeLead(setting: number, durationSec: number): number {
  if (setting === 0) return 0;                                    // disabled
  if (setting > 0) return setting;                                // explicit seconds
  return Math.min(45, Math.max(15, Math.round(durationSec * 0.04)));  // auto: 4% of runtime, clamped 15-45s
}
```
Driven by `settings.nextEpisodeLeadSec`. When there's no real "outro" skip segment but
there IS a next episode and `leadSec > 0`, a **synthetic outro** is fabricated covering the
last `leadSec` of the episode (`source: "chapters"`, `skip-pill-container.tsx:50-65`) so Up
Next still appears even with no chapter/API data.

**Up Next card** (`BpUpNext`, `src/views/big-picture/player/bp-up-next.tsx:92-295`):
appears when `remainingSec <= leadSec` during an outro-with-next-episode
(`bp-skip-pill.tsx:98-101,133-146`). Countdown ring (SVG stroke-dashoffset, not
conic-gradient — cross-WebView rendering note at `bp-up-next.tsx:270-272`). Title = episode
name or `"S{season} · E{episode}"` fallback; if a spoiler mask hides the title, shows the
code only (`bp-up-next.tsx:135-139`). Buttons (verbatim): **"Play now"** (primary,
`bp-up-next.tsx:220`) and **"Keep watching"** (cancel, autofocus-seeded,
`bp-up-next.tsx:242-243`) with an `X` icon. A `Back` press on this card also triggers cancel
(`bp-up-next.tsx:125-131`).

**Natural-end auto-advance** (independent of the lead-time UI, for cases with no synthetic
outro): `useAutoNextEpisode` (`src/views/player/hooks/use-auto-next-episode.ts:9-39`) fires
`goToEpisode(nextEp)` when `isNaturalEnd(snap, pos)` OR (`errorCode` set AND within 2s of
duration) OR (not-playing AND within 1s of duration) — gated on
`snap.durationSec >= STUB_MAX_SEC (150s)` and not already fired for this `src.url`
(`use-auto-next-episode.ts:26-38`).

### 1.8 "Still watching?" prompt

**Not present in the TV/Big Picture player at all.** Grep for `StillWatching`/
`stillWatching`/`"Still watching"` under `src/views/big-picture/` returns zero matches.
It exists only on the desktop player: `src/views/player/hooks/use-still-watching.ts` +
`src/views/player/still-watching-prompt.tsx`, gated by `settings.stillWatching` (default
`false`, `defaults.ts:394`) and `settings.stillWatchingAfter` (default `3` — episodes played
back-to-back before prompting, `defaults.ts:395`). Desktop prompt: 45s countdown
(`TIMEOUT_SEC = 45`, `still-watching-prompt.tsx:4`), auto-exits at 0; buttons **"Keep
watching"** / **"Stop ({n})"**; `Enter`/`Space` continues, `Escape` exits
(`still-watching-prompt.tsx:36-50,67-81`). The reset-on-input logic
(`use-still-watching.ts:23-34`) resets the "runs" counter on any `pointerdown`/`keydown` —
i.e. if the user showed activity in the current session, the *next* auto-advance still
counts toward the threshold; threshold semantics: prompts once
`runsRef.current + 1 >= threshold` (`use-still-watching.ts:36-47`). **A native TV port has
no reference implementation to follow here** — decide whether to add TV parity or omit.

### 1.9 Back / exit behaviour

Two-stage, not a literal "press Back twice within N seconds" — it's stateful:
1. **First Back while chrome is up**: `BpPlayerShell.onBack` (`bp-player-shell.tsx:183-196`)
   — if a `runBpBack()` handler consumed it, stop; else if a panel is open, close the panel;
   else `hideChrome()`. No confirmation dialog at this stage.
2. **Back while chrome is down** (idle key listener doesn't bind Back at all — only
   arrows/Enter/Space/Tab): falls through to the registered `pushBpBack` handler in
   `BpTenFootLayer` (`src/views/player/bp-ten-foot.tsx:301-308`), which calls
   `requestPlayerClose()` (`src/views/player/request-player-close.ts:5-30`):
   - if `drawMode`, exits draw mode instead of closing (`request-player-close.ts:14-17`);
   - if `settings.playerConfirmLeave` (**default `true`**, `defaults.ts:374`), opens the
     leave-confirm dialog; else closes immediately (`request-player-close.ts:22-29`).

**Leave-confirm dialog** (`BpLeaveConfirm`, `src/views/big-picture/player/bp-leave-confirm.tsx:33-192`):
title **"Leave the show?"**, body **"We'll save your spot so you can pick up right where you
left off."** (`bp-leave-confirm.tsx:150,156`). Three chips: **"Keep watching"** (autofocus,
closes dialog), **"Leave"** (confirms exit), **"Don't ask again"** (toggle; if checked when
confirming, calls `onRememberConfirmLeave` which sets `playerConfirmLeave: false` —
`bp-ten-foot.tsx:296-297`) (`bp-leave-confirm.tsx:160-187`). `Escape`/`Backspace` also closes
it without leaving (`bp-leave-confirm.tsx:99-103`).

### 1.10 Resume prompt (`BpResumePrompt`, `bp-resume-prompt.tsx:27-172`)

Blocking fork (`forcePanel`, locks the shell, takes the remote directly — comment at
`bp-resume-prompt.tsx:18-26`). Copy: eyebrow **"Pick up where you left off"**; progress line
`"{watched} of {total} watched ({pct}%)."` + `"{time} left"` (`bp-resume-prompt.tsx:118-123`).
Buttons: **"Resume from {time}"** (primary, autofocus, `Play` icon) and **"Start Over"**
(`RotateCcw` icon) (`bp-resume-prompt.tsx:153-169`). Back press on this card resumes rather
than exiting, since there is no other escape route (`bp-resume-prompt.tsx:56-63`).

### 1.11 Info line / identity (`BpPlayerIdentity`, `bp-player-identity.tsx:24-58`)

Shows a clear-logo image if available, else the title as text (`bp-player-identity.tsx:34-45`).
Quiet metadata line below: episode line `"S{season} E{episode padded 2}"` optionally
` · {episode name}` (`bp-player-identity.tsx:5-10`); source line = `resolution · quality ·
releaseGroup` joined, filtering blanks (`bp-player-identity.tsx:12-17`). Both joined with
`"  ·  "` (`bp-player-identity.tsx:47-49`). A `"Casting"` badge appears when
`playback.casting` (`bp-player-identity.tsx:51-55`).

**Quality/HDR badges** are computed, not part of this identity component directly, in
`src/lib/player/resolution-label.ts`:
```ts
realQualityLabel(w,h): "4K" (≥2160p/3840w) | "1440p" | "1080p" | "720p" | "480p" | "SD" | null
hdrFormatLabel(hdrGamma, ...formats): "DV" | "HDR10+" | "HDR" | null
```
(`resolution-label.ts:1-29`) — DV/HDR10+ detected via regex over format strings
(`DV_TOKEN`, `HDR_TOKEN`, `resolution-label.ts:13-14`); when `hdrGamma` isn't `"pq"`/`"hlg"`
and is non-empty, returns `null` (avoids mislabeling SDR-tonemapped content).

### 1.12 Connecting / error / stall UI (`BpConnecting`, `bp-connecting.tsx:1-431`)

Timing: `STILL_LOOKING_MS = 22_000` — after 22s with zero torrent peers, switches to the
"still looking" message (`bp-connecting.tsx:30,246-248`). `HEAVY_BYTES = 20 * 1024**3` (20GiB)
triggers a separate "large file" warning line (`bp-connecting.tsx:31,238-244`).

Status note strings (verbatim, `bp-connecting.tsx:239-254`):
- Terminal (couldn't connect): *"Couldn't connect to any peers for this torrent. It may be
  unreachable on your network (some ISPs and VPNs block torrent traffic)."*
- Slow (peers but no data): *"Found peers but no data yet. The torrent may be slow."*
- Buffering (player has stream open): *"The player has the stream open and is waiting on
  the next piece."*
- Still looking (≥22s, 0 peers): *"Still looking. Some torrents take a minute to find their
  first peer."*
- Downloading with peers: *"Downloading the start of the file. Playback begins once there
  is enough to keep going."*
- Heavy-file note (non-terminal): *"Heads up: this is a large file for peer-to-peer
  streaming, so it can take a while to start. A 1080p source or a debrid service will load
  faster."*

Action buttons: terminal state → **"Go back"** (loud) + **"Try again"**
(`bp-connecting.tsx:287-300`); non-terminal → **"Cancel"** + (if slow) **"Try again"**
(`bp-connecting.tsx:302-317`).

---

## 2. MPV CONFIGURATION (`src-tauri/src/mpv.rs`, `src/lib/player/*`)

Rust host: `src-tauri/src/mpv.rs` (3483 lines). All options below are set via
`mpv.set_property(name, value)` or, pre-init, `init.set_property(...)` on an
`MpvInitializer`. Errors from optional properties are swallowed (`let _ = ...`) so the
player degrades gracefully on libmpv builds missing optional features (comment,
`mpv.rs:326-329`).

### 2.1 Pre-init options (`apply_pre_init`, `mpv.rs:325-...`)

Always set: `title="Harbor"`, `audio-client-name="Harbor"`, `terminal="no"`,
`msg-level="all=warn,vo=v,d3d11=v,gpu=v,win32=v"` (`mpv.rs:349-352`).
`ytdl` = `"yes"` if live else `"no"` (`mpv.rs:353-354`).

**User-Agent / headers** (`mpv.rs:355-368`): default UA `"VLC/3.0.20 LibVLC/3.0.20"`
(`mpv.rs:355`); any `headers` map passed in is scanned for a `User-Agent` key (case
-insensitive) to override it; all other headers become `http-header-fields`, comma-joined,
each formatted `"{name}: {value}"` with `\` and `,` escaped inside the value
(`mpv_header_field`, `mpv.rs:317-323`) — this is how upstream applies stream-proxy headers
(`behaviorHints.proxyHeaders` from the addon manifest; the header values arrive as plain
strings in `MpvStartArgs.headers: Option<Vec<(String,String)>>` and are passed through
verbatim).

**hwdec** (platform-branched, `mpv.rs:376-395`):
- macOS embedded: `"videotoolbox-copy"`, `force-window="no"`.
- Linux: `"auto-safe"`; `force-window` = `"no"` if embedded else `"yes"`.
- Windows: `"d3d11va"` if RTX Video (HDR or VSR) requested, else `"auto-safe"`;
  `force-window="immediate"`.
- Other: `"auto-safe"`, `force-window="immediate"`.

Other pre-init flags: `input-default-bindings="no"`, `input-media-keys="no"`,
`input-cursor="no"`, `osc="no"` (best-effort — not all libmpv builds ship the OSC Lua
script, `mpv.rs:398-401`), `osd-level="0"`, `cursor-autohide="200"`, `volume-max="600"`,
`sub-codepage="utf-8"`, `background-color="#000000"`, `background="color"`,
`media-controls="no"` (`mpv.rs:396-414`). Windowed (non-embedded) mode also sets
`ontop="yes"`, `border="no"` (`mpv.rs:424-436`).

**Colorspace/HDR (pre-init)**:
- RTX HDR path: `gpu-api="d3d11"`, `target-colorspace-hint="yes"`, `target-peak="10000"`
  (`mpv.rs:449-452`).
- HDR-to-SDR tonemap path: `tone-mapping="spline"`, `gamut-mapping-mode="perceptual"`,
  `hdr-compute-peak="yes"`, `hdr-contrast-recovery="0.30"`, `hdr-peak-percentile="99.995"`,
  `dither-depth="auto"`, `target-trc="bt.1886"`, `target-prim="bt.709"`; Windows/macOS also
  add `target-colorspace-hint="yes"` (`mpv.rs:453-471`); Windows VSR-while-tonemapping keeps
  `gpu-api="d3d11"` (`mpv.rs:472-474`).
- Otherwise: Windows sets `target-colorspace-hint="yes"` always, plus `gpu-api="d3d11"` if
  embedded or VSR (`mpv.rs:476-480`); macOS sets `target-colorspace-hint="yes"`
  (`mpv.rs:482-484`).

**Anime4K shaders**: if `args.anime4k_shaders` is set, paths are backslash→forward-slash
normalized and joined with `;` on Windows / `:` elsewhere into `glsl-shaders`
(`mpv.rs:486-498`).

**Start position**: `start="{sec}"` if `args.start_at_sec > 0` (`mpv.rs:500-503`).

No `"profile"` mpv option is ever set — confirmed by grep (`grep '"profile"' mpv.rs` → no
matches). Harbor configures every relevant knob individually rather than using an mpv
profile.

### 2.2 Video output

Non-embedded (or non-mac/linux-embed) path: `vo` = `"gpu"` if
`args.renderer == Some("gpu")` else default **`"gpu-next"`** (`mpv.rs:803-809`); optional
`vf-append="format=yuv420p"` if `force_yuv420p` (`mpv.rs:810-813`). Embedded macOS/Linux
render-API path: `vo="libmpv"`, `force-window="no"` (`mpv.rs:815-818`).

### 2.3 Cache / network (post-init, `mpv.rs:885-985`)

**Live streams** (`is_live == true`):
```
cache=yes, cache-secs=30, cache-pause=yes, cache-pause-initial=no
demuxer-max-bytes=64MiB, demuxer-max-back-bytes=16MiB, demuxer-readahead-secs=20
network-timeout=60
stream-lavf-o=reconnect=1,reconnect_delay_max=5,reconnect_on_network_error=1
demuxer-lavf-o=http_seekable=0,http_persistent=0
stream-buffer-size=16MiB
```
(`mpv.rs:887-901`)

**Non-live**, three tiers by `full_dl` (full-download mode) / `high_bitrate`
(`startup_profile == "high-bitrate"`) / default:
| property | full_dl | high_bitrate | default |
|---|---|---|---|
| `cache-secs` | `100000` | `45` | `30` |
| `cache-pause-wait` | `10` | `2` | `1` |
| `demuxer-max-bytes` | `48GiB` | `256MiB` | `128MiB` |
| `demuxer-max-back-bytes` | `48GiB` | `64MiB` | `32MiB` |
| `demuxer-readahead-secs` | `100000` | `45` | `30` |
| `stream-buffer-size` | `16MiB` | `32MiB` | `16MiB` |
(`mpv.rs:905-982`)

`cache=yes`, `cache-pause=yes`, `cache-pause-initial=no` always. `demuxer-cache-dir` (or
legacy `cache-dir` if the property name is rejected on mpv 0.41+) points at
`<app_cache_dir>/mpv-cache` (`mpv.rs:955-969`); `cache-on-disk=yes` (`mpv.rs:972`).
`network-timeout` = `network_timeout_for(url)`: **`600`** for a local-network URL,
**`60`** otherwise (`mpv.rs:645-651,973`). `stream-lavf-o` for non-live:
```
reconnect=1,reconnect_on_network_error=1,reconnect_on_http_error=429,reconnect_delay_max=10,reconnect_delay_total_max=60
```
Deliberately **no `reconnect_streamed`** — comment explains that on AES-128 HLS every
segment ends in a normal EOF that ffmpeg then retries from offset 0 with that flag, costing
measured 55s of backoff per 100s on a real stream vs. 0s without it (`mpv.rs:911-916`).

### 2.4 Live-stream render simplifications

When `is_live`, extra scaling/dithering is disabled for performance: `scale`/`dscale`/
`cscale = "bilinear"`, `dither="no"`, `deband="no"`, `correct-downscaling="no"`,
`linear-downscaling="no"`, `sigmoid-upscaling="no"`, `hdr-compute-peak="no"`,
`interpolation="no"` (`mpv.rs:1010-1024`).

### 2.5 Subtitle options (post-init)

```
sub-auto=all           // discover sidecar subs even for local files indexed pre-sidecar-persist
sid=no                 // both subtitle slots start empty — Harbor applies user's language choice itself
secondary-sid=no
sub-visibility=no          // only if embedding (want_embed)
secondary-sub-visibility=no
sub-fonts-dir=<app fonts dir>   // from crate::fonts::sub_fonts_dir
sub-font-provider=auto
sub-font="Noto Sans JP"
embeddedfonts=yes
```
(`mpv.rs:990-1007`)

Per-URL subtitle attach: for every `args.subtitles[]` entry, runs `sub-add <url> auto` via
`mpv_argv_command` (`mpv.rs:1060-1066`) — this is how external SRT/VTT/ASS URLs are loaded
(the `url` is backslash-normalized first). Local file sidecars are attached separately via
`attach_local_sidecars()` (`mpv.rs:1068`, not read in this pass — grep for its body if
needed).

Live-facing style properties (`sub-color`, `sub-border-size`, etc.) applied from the
**frontend** in `applySubStyle()`, `src/lib/player/sub-style.ts:48-90` — see §4 of this doc
("Style settings keys") for the full settings→mpv-property mapping; it's driven by
`invoke("mpv_set_property", {name, value})` calls (Tauri IPC, not a Rust-side batch), see §6
gotchas.

### 2.6 HDR reassert / display flip (Windows/macOS-specific, out of scope for tvOS)

`reassert_hdr_colorspace()` toggles `target-peak` `10000`→(60ms sleep)→`auto` (`mpv.rs:1087-1091`).
Windows: `restore_display_sdr_if_flipped()` uses `DisplayConfig` Win32 APIs to flip the
physical display back to SDR after mpv quits, only if this session flipped HDR on
(`mpv.rs:1105-1133`). macOS: `apply_mac_edr()` sets `icc-profile-auto=no`,
`target-prim` = `"bt.2020"` or `"display-p3"` (based on `video-params/primaries`),
`target-trc="pq"`, `target-peak="auto"` when entering EDR, and reverses all three when
leaving (`mpv.rs:1140-1160`) — this is the closest desktop analog to what a native
AVFoundation/MPVKit `tvOS` EDR path would need, but the actual display-flip mechanism
(`crate::mpv_render_mac::set_hdr_active`) is platform-specific and not portable.

### 2.7 Anime4K shader chains (`src/lib/player/anime4k-modes.ts:1-46`)

6 modes: `A, B, C, AA, BB, CA` (`anime4k-modes.ts:1,4-11`). Each mode maps to an ordered
`.glsl` filename chain built from a fixed set of building blocks
(`Anime4K_Clamp_Highlights.glsl`, `Restore_CNN[_Soft]`, `Upscale_CNN_x2`,
`AutoDownscalePre_x2/x4`) at either `"VL"` (hq tier) or `"M"` (fast tier) size
(`anime4k-modes.ts:13-39`). `anime4kChain(folder, mode, tier)` (`anime4k-modes.ts:41-46`)
prefixes every filename with the shader folder path and normalizes slashes; the resulting
list becomes `args.anime4k_shaders` → mpv's `glsl-shaders` option (§2.1). The broader shader
catalog (FSRCNNX, AMD FSR, etc. — user-selectable upscalers/tonemap shaders, not
Anime4K-specific) lives in `src/lib/player/shader-catalog.ts` with per-entry `stage`
(`prescale|restore|chroma|sharpen|tonemap`), `content` gate (`all|anime|hdr|live`), and
`conflictsWith` (e.g. a shader incompatible with `hdrToSdr`/`rtxHdr`) — not exhaustively
enumerated here; read `shader-catalog.ts` directly if the port needs the full shader list.

### 2.8 "Auto engine" rule — mpv vs. HTML5 (hls.js / mpegts.js)

`pickBridge()` (`src/views/player/player-utils.ts:54-87`):
```ts
if (want === "html5") → html5 bridge, always.
if (want === "mpv") → probe mpv; if available, mpv bridge; else fall back to html5 (warns).
// want === "auto":
if (isDesktop (Tauri) || notWebReady) → probe mpv; if available, mpv bridge.
else → html5 bridge.
```
`isDesktop` = `"__TAURI_INTERNALS__" in window` (`player-utils.ts:80`). `notWebReady` is a
per-source flag (`src.notWebReady`) for streams the `<video>` element can't play directly
(e.g. raw MPEG-TS). **On a native tvOS app there is no "web" fallback path** — the port
always uses MPVKit; this rule doesn't need porting, but its *consequence* — that some
formats route through hls.js or mpegts.js instead of mpv on non-desktop web builds — is a
web-only concern.

Inside the HTML5 bridge (`src/lib/player/html5/bridge.ts:524-548`, only relevant to the
in-browser build): `isHls` = URL ends with/contains `.m3u8` or `/playlist/`
(`html5/bridge.ts:524-525`) → `Hls` (hls.js) if `Hls.isSupported()`. Else `isTs` = URL ends
`.ts`, or `notWebReady && !isHls` and not one of `mp4|webm|mov|mkv|mpd`
(`html5/bridge.ts:526-528`) → `mpegts.js` if supported. Else plain `video.src = url`.

### 2.9 Stream headers / proxy headers (`behaviorHints.proxyHeaders`)

Not found as a literal string in `mpv.rs`; the header pipeline is generic (§2.1 — any
`headers` map passed into `MpvStartArgs` becomes `user-agent` + `http-header-fields`). The
add-on-manifest-level `behaviorHints.proxyHeaders` → per-stream headers mapping happens on
the TypeScript side before the Rust call (in the streams-resolution code, outside this
doc's file scope — see `src/lib/streams/*` if the port needs that mapping).

---

## 3. PROGRESS + RESUME

Three parallel local persistence layers plus a cloud (Stremio) library sync layer and two
optional third-party scrobblers (Trakt, Simkl). All are `localStorage`-backed on the web
build.

### 3.1 Resume (`src/lib/resume.ts`)

Storage key: **`"harbor.resume"`** (`resume.ts:3`) — a single flat JSON object, not
per-profile-scoped (unlike playback-history/local-cw/movie-watched below).

Entry key: `entryKey(id, season?, episode?)` → `` `${id}|s${season}e${episode}` `` if both
given, else bare `id` (`resume.ts:7-12`).

Entry shape (`resume.ts:5`, matches §5 `ResumeEntry` type):
```ts
type Entry = { ms: number; t: number; s?: number; pct?: number; source?: "simkl" | "trakt" };
```
`ms` = position in milliseconds, `t` = `Date.now()` write timestamp, `s` = *display* season
(may differ from the storage-key season for split-franchise anime — see
`displaySeasonFor` in §3.6), `pct` = optional fractional watched ratio (0-1, used when
merging with a remote entry of different duration — §3.6), `source` = which external
tracker last wrote this entry.

Writers: `saveResumeMs(...)` (single) and `saveResumeBatch([...])` (bulk, used by the
episode-span "mark N episodes as covered" path). Both validate `ms >= 0` and
`season >= 0, episode >= 1` before writing (`resume.ts:31-86`). `readResumeEntry`,
`readResumeMs`, `readResumeSource`, `clearResume`, and `lastPlayedEpisode(seriesId)` (scans
all `seriesId|sXeY` keys for the most-recently-touched episode, by `t`) round out the API
(`resume.ts:88-165`).

### 3.2 Write cadence / thresholds — local (`src/views/player/hooks/use-resume-autosave.ts`)

```ts
const TICK_MS = 4000;            // resume localStorage write tick while playing
const MIN_POSITION_SEC = 5;      // ignore any position below this
const TASTE_MIN_SEC = 90;        // minimum watched time before "taste"/discover tracking fires
const WATCHED_RATIO = 0.85;      // LOCAL "finished" threshold — clears resume, marks watched
const REWATCH_RESUME_SEC = 45;   // re-watching a finished movie past this re-enters Continue Watching
const SYNC_RATIO = 0.7;          // AniList/MAL sync-ready threshold
const STUB_MAX_SEC = 150;        // videos shorter than this are never persisted (stub/trailer guard)
```
(`use-resume-autosave.ts:30-36`)

Write triggers: an interval every `TICK_MS` while `snap.status === "playing"`
(`use-resume-autosave.ts:277-281`); immediately on any non-active status transition
(`use-resume-autosave.ts:283-292`); on unmount / source change (`use-resume-autosave.ts:294-300`);
on `pagehide`/`beforeunload` (`use-resume-autosave.ts:302-310`).

**"Finished" logic** (`record()`, `use-resume-autosave.ts:113-220`): `finished =
(durationSec > 0 && pos/durationSec >= WATCHED_RATIO) || isNaturalEnd(snap, pos)`
(`use-resume-autosave.ts:121-122`). If finished: `clearResume(...)` for the episode(s)
covered by this play session (handles multi-episode `episodeSpan` files); else:
`saveResumeMs(...)`. On finish, also: `setManualWatched(...)` for series/anime
(`use-resume-autosave.ts:153-167`), `setMovieWatchedLocal(id, true)` +
`clearLocalCw(id)` for movies (`use-resume-autosave.ts:171-174`), and
`recordWatchEvent(...)` (`use-resume-autosave.ts:175-185`).

**Rewatch handling**: if a movie was already flagged watched but the viewer has resumed past
`REWATCH_RESUME_SEC` (45s) and is still below `WATCHED_RATIO`, it un-flags
`setMovieWatchedLocal(id, false)` and re-adds it to local Continue Watching
(`use-resume-autosave.ts:191-220`).

Also on every persisted tick: `savePlayback(...)` (playback-history, §3.3) and, for items
not cloud-eligible or local/anime/unmapped-anime/rewatching, `saveLocalCw(...)` (§3.4)
(`use-resume-autosave.ts:147-219`).

### 3.3 Playback history (`src/lib/playback-history.ts`)

Storage key: **`"harbor.playback-history.v1." + profileId`** (falls back to legacy
un-suffixed `"harbor.playback-history.v1"` if no active profile) (`playback-history.ts:20-21,63-66`).
`TTL_MS = 30 * 24 * 60 * 60 * 1000` (30 days) — entries older than this are dropped on
every read (`playback-history.ts:23,102-110`). `MAX_ENTRIES = 200` (`playback-history.ts:24`).
Entry key: same `id` / `id|sXeY` scheme as resume (`playback-history.ts:89-94`).

`PlaybackEntry` type (verbatim, `playback-history.ts:4-18`) — see §5.

### 3.4 Local Continue-Watching cache (`src/lib/local-cw.ts`)

Storage key: **`"harbor.localcw.v1." + profileId`** (legacy fallback
`"harbor.localcw.v1"`) (`local-cw.ts:1-2`). `MAX = 60` entries, `FINISHED_RATIO = 0.92`
(`local-cw.ts:4-5`) — a *third*, slightly different watched-ratio threshold from this local
cache's own perspective (vs. `0.85` local-resume and `0.9` cloud, §3.5/3.6). `LocalCwEntry`
type at `local-cw.ts:7-17` (see §5).

### 3.5 Movie-watched flag (`src/lib/movie-watched.ts`)

Storage key: **`"harbor.moviewatched.v1." + profileId`** (legacy fallback
`"harbor.moviewatched.v1"`) (`movie-watched.ts:3-4`). Backing store is a `Set<string>` of
movie ids (`movie-watched.ts:9`), not a ratio — this is a pure boolean flag file, set by the
`WATCHED_RATIO` (0.85) check in §3.2.

### 3.6 Cloud sync — Stremio library (`src/lib/stremio.ts`, `src/views/player/hooks/use-stremio-sync.ts`)

`LibraryItem` type — verbatim, `stremio.ts:18-43` — see §5. Cloud "finished" ratio:
`CW_FINISHED_RATIO = 0.9` (`stremio.ts:6`), used by `isCwMember`/`cwMemberViaResume` to
decide if an item still counts as "in progress" for the Continue Watching row (this is a
*different* constant from the *write-side* flagged-watched ratio below).

**Cloud write** happens in `writeLibraryItem()` (`use-stremio-sync.ts:350-504`), not in
`stremio.ts` directly (`stremio.ts:libraryPut` is a thin `datastorePut` wrapper,
`stremio.ts:243-249`, that also **refuses to write anime-scheme ids**
(`kitsu:`/`mal:`/`anilist:`/`anidb:`) to the cloud unless they're being removed
(`stremio.ts:244`) — anime progress stays local/AniList/MAL only).

Write-side constants (`use-stremio-sync.ts:16-19,37`): `TICK_MS = 30000` (cloud sync poll,
**distinct from the 4s local resume tick**), `BASE_REFRESH_MS = 30000`,
`MIN_POSITION_SEC = 6`, `CREDITS_RATIO = 0.9` — **the actual "flag watched" threshold for
the Stremio cloud item** is `watchedRatio > CREDITS_RATIO (0.9)` AND `playedReal` (not an
error, not a shrunk-duration false-positive) → `nowFlagged` (`use-stremio-sync.ts:379,
399-401`). So: **local resume/movie-watched flips at 85%, the Stremio cloud item flips
at >90%.** A native port should pick one canonical threshold or reproduce both if Stremio
cloud-library parity matters.

**Episode video_id derivation** (`videoIdFor`, `use-stremio-sync.ts:297-308`): for a movie,
just the canonical id; for a series episode, prefers a pre-threaded `videoId`/
`kitsuStreamId` matching the canonical id's scheme, else `` `${cid}:${imdbSeason}:${imdbEpisode}` ``
for `tt`-scheme ids, else `` `${cid}:${season}:${episode}` ``.

**Built `LibraryItem.state` for a write** (`use-stremio-sync.ts:414-426`):
```ts
{
  lastWatched: <ISO now>,
  timeWatched: offsetMs,
  timeOffset: finaleDone ? 0 : offsetMs,     // 0 clears resume once the series finale is done
  overallTimeWatched: prevOverall + (videoChanged ? prevTimeWatched : 0),
  timesWatched: nowFlagged && effPrevFlagged===0 ? prevTimesWatched+1 : prevTimesWatched,
  flaggedWatched: nowFlagged ? 1 : effPrevFlagged,
  duration: durationMs,
  video_id: videoId,
  watched: prevWatched,          // per-episode bitfield string, merged from cache/queue/remote — see below
  lastVidReleased: prevLastVidReleased,
  noNotif: baseState.noNotif === true,
}
```
`meaningfulResume` (resets the flagged-watched bit on a real rewatch) =
`playedReal && durationMs>0 && offsetMs>=45000 && watchedRatio<CREDITS_RATIO`
(`use-stremio-sync.ts:402-404`). `finaleDone` is computed via `isFinaleEpisode()` — true
when the current episode is the highest `(season,episode)` pair in `meta.videos`
(`use-stremio-sync.ts:21-36,405-412`).

For series (non-anime), the `watched` bitfield string is resolved from whichever of
{cached (`freshestWatched`), queued (`queuedWatched`), or a fresh strict GET} has the
newest `_mtime`, so a stale local base never clobbers a newer cloud/queue value
(`use-stremio-sync.ts:449-487`).

**Offline resilience**: `cloudLibraryPut()` (`src/lib/stremio-write-queue.ts:49-...`) wraps
`libraryPut`; on failure the item is queued in `localStorage["harbor.stremio.write-queue.v1"]`
(`stremio-write-queue.ts:3`) and flushed later (`flushWriteQueue`).

### 3.7 Resume-time merge of local + cloud (`src/lib/player/resume-start.ts`)

`resolveStartMs()` (`resume-start.ts:89-147`): reads the local `Entry` first
(`readResumeEntry`). If no `authKey`, returns local only. Else fetches the remote
`LibraryItem` (by imdb id and/or raw meta id, `lookupIds`, cached 30s per id,
`REMOTE_CACHE_TTL_MS = 30_000`, `MAX_CACHE_KEYS_PER_ACCOUNT = 24` — `resume-start.ts:5-6`)
and, for the first matching remote item (`matchesEpisode`, matching on `video_id` or
season/episode):
- `finished` = `isEpisode && (flaggedWatched===1 || remoteMs/remoteDuration >= RESTART_THRESHOLD (0.8))`
  (`resume-start.ts:4,123-126`).
- Local `pct` (if present) is rescaled against the *remote's* duration to compare
  apples-to-apples across sources with different measured runtimes
  (`effectiveLocal`, `resume-start.ts:118-122`).
- If the remote write is newer (`_mtime` > local `t`) OR the remote position is further
  along, the remote value wins and is written back into local storage via
  `saveResumeBatch` (`resume-start.ts:130-143`); otherwise local wins.

### 3.8 Trakt / Simkl scrobble hooks

Both trackers mirror the same state machine (`start`/`pause`/`stop`), driven off
`snap.status` transitions, not a fixed tick — plus a `seek` re-sync when position jumps.

**Trakt** (`src/lib/trakt/scrobble-hook.ts:1-211`):
- `STUB_MAX_SEC = 150` (skip short/stub media), `WATCHED_MARK_PCT = 90`
  (`scrobble-hook.ts:16,19`) — comment: kept aligned with Harbor's own CW-drop ratio so a
  "pause" scrobble (resumable elsewhere) only becomes a "stop"/watched scrobble past the
  point Harbor itself considers the item finished (`scrobble-hook.ts:17-18`).
- `playing` → `scrobble("start", …)` (first time only); `paused` (after having started) →
  `scrobble("pause", …)`; `status==="ended"` with `durationSec >= STUB_MAX_SEC` → `scrobble("stop", …)`
  at the max of tracked progress and live position (`scrobble-hook.ts:81-116`).
- **Seek re-sync**: every 1s while playing, detects a seek (`|Δpos| > 8s` within `<1.5s`
  real time, or apparent playback rate `> 4×`) and re-sends `scrobble("start", …)` — but
  throttled to at most once per 30s (`scrobble-hook.ts:118-148`).
- **On unmount / title change**: sends a final `stop` (if progress ≥ 90%) or `pause`
  (`scrobble-hook.ts:58-75,150-168`).
- **On `pagehide`** specifically also fires a `navigator.sendBeacon`-style fire-and-forget
  POST directly to `` `${TRAKT_API_BASE}/scrobble/${action}` `` with `keepalive: true`
  (since a normal async call can be killed mid-flight on tab close), *and* still attempts
  the confirmed `scrobble("stop", …)` call for the ≥90% case (`scrobble-hook.ts:41-56,171-211`).

**Simkl** (`src/lib/simkl/scrobble-hook.ts`) mirrors this structure almost exactly:
`STUB_MAX_SEC = 150`, `WATCHED_MARK_PCT = SIMKL_WATCHED_RATIO * 100` where
`SIMKL_WATCHED_RATIO = 0.9` (`simkl/scrobble-hook.ts:27-28`; `simkl/config.ts:10`) — i.e.
**also 90%, same as Trakt**, both independent of the 85%/92% local thresholds.

### 3.9 What upstream reads on resume — summary

For a given title/episode, the resume value shown to the user is: local `Entry.ms`
(`resume.ts`) reconciled against the Stremio cloud `LibraryItem.state.timeOffset` (newer
`_mtime` or larger position wins, §3.7) — **Trakt/Simkl progress is a separate pull path**
(`src/lib/trakt/playback.ts`, `src/lib/simkl/playback.ts`, not merged into
`resolveStartMs()` directly; they write into the same local `resume.ts` store via
`saveResumeMs` when their own "playback progress" endpoint is polled, so they participate
in the *next* local-vs-cloud reconciliation rather than a three-way merge at watch-time).
`trakt/playback.ts` constants: `DURATION_MS = { movie: 6_300_000, series: 2_640_000 }`
(`trakt/playback.ts:19`) — fallback assumed durations (ms) when Trakt doesn't report one,
used to convert Trakt's `progress` percentage into an absolute `ms` value.

---

## 4. SUBTITLES (`src/lib/subtitles/*`)

### 4.1 Sources

**OpenSubtitles v3** (`src/lib/subtitles/providers/opensubtitles-v3.ts`):
- `const ENDPOINTS = ["https://opensubtitles-v3.strem.io"]` (`opensubtitles-v3.ts:10`).
- Call: `` `${base}/subtitles/${type}/${id}.json` `` (`opensubtitles-v3.ts:34`), `type` =
  `"movie"|"series"`, `id` = `tt1234567` or `tt1234567:season:episode` for series
  (`opensubtitles-v3.ts:22-31`). Requires `imdbId`; returns `[]` otherwise
  (`opensubtitles-v3.ts:52-55`). Header `{Accept: "application/json"}`.
- Dedup across endpoints by `` `${lang}|${url}` `` while merging (`opensubtitles-v3.ts:66`).
  Result `id` = `` `os3:${s.id ?? s.url}` ``, synthesized title `` `OpenSubtitles V3 #{n}` ``
  (per-language counter) (`opensubtitles-v3.ts:72-90`).

**Wyzie** (`src/lib/subtitles/providers/wyzie.ts`):
- `const ENDPOINT = "https://sub.wyzie.io/search"` (`wyzie.ts:5`).
- Params (`wyzie.ts:29-39`): `id` = `tt`-prefixed imdbId, else `tmdbId`, else `query=title`
  (else returns `[]`); `season`, `episode`; **`source=all`** (always, verbatim);
  `language` = comma-joined normalized preferred langs, if given.
- `hearingImpaired = r.isHearingImpaired || r.hi || false` (`wyzie.ts:75`).

**Addon subtitles** (`src/lib/subtitles/providers/addons.ts`):
- Per-addon URL: `` `${transportBase}/subtitles/${type}/${id}${extra}.json` ``
  (`addons.ts:114-115`); `transportBase` strips `/manifest.json` and trailing `/`
  (`addons.ts:33-35`).
- `id` from `contentId()`: prefers `q.stremioId`, else `tt`-prefixed imdbId; appends
  `:season:episode` for episodes (`addons.ts:37-47`).
- `extra` = a `/videoHash=...&videoSize=...&filename=...` path segment when present, URL-
  encoded (`addons.ts:86-92`).
- Only addons declaring a `"subtitles"` resource (or matching by id-prefix priority
  `["kitsu","mal","anidb","anilist","tt","tmdb"]`) are queried (`addons.ts:49,58-84`).

**Other pipeline sources** (used inside `src/lib/subtitles/autosync/*`; `SubResult.source`
union also lists `jimaku`, `podnapisi`, `subdl`, `gestdown`, `subsource` —
`types.ts:30-38`). Base URLs:
```
Gestdown:   https://api.gestdown.info                (autosync/sub-source-gestdown.ts:13)
Podnapisi:  https://www.podnapisi.net                (autosync/sub-source-podnapisi.ts:13)
SubDL:      https://api.subdl.com/api/v1  (dl: https://dl.subdl.com)  (autosync/sub-source-subdl.ts:27-28)
SubSource:  https://api.subsource.net/api/v1         (autosync/sub-source-subsource.ts:20)
```
Jimaku endpoint **not found** in the files searched in this pass.

### 4.2 Language ranking (`src/lib/subtitles/language.ts`)

`langScore(lang, preferred)` (`language.ts:307-319`): `0` if `preferred` empty; exact
normalized-lang match → `(preferred.length - exactIdx) * 2`; base-subtag-only match (e.g.
`pt` vs `pt-BR`) → `(preferred.length - baseIdx) * 2 - 1`; no match → `-1`. Earlier entries
in the preferred list always outscore later ones.

`pickBestTrack(tracks, preferred)` (`language.ts:328-345`): skips `forced` tracks and any
with `langScore < 0`; picks max of `langScore*10 + (default?1:0)`.

Full auto-selection order, `rankSubtitleCandidates()` (`candidate-ranking.ts:151-206`):
filters out `langScore<0` (when preferred given), `forced`/`foreignOnly`, explicit
episode-mismatch, and `confidence === "incompatible"`; sorts by exact moviehash match →
`langScore` → strong provider confidence (`exact`/`high`) → provider match score →
explicit episode rank → local stream-match confidence/sourceRank/score → timing-status rank
(`aligned > fixed-offset > drifting > unmeasurable`) → weak provider confidence → provider
score → machine-translated penalty → `fromTrusted` boost → rating score/count → downloads →
stable tiebreak key.

### 4.3 Dedupe (`src/lib/subtitles/search.ts`)

`deduplicateAndRankSubtitleResults()` (`search.ts:266-283`) groups by key
`` `${normalizeLang(lang)}|${url}|${title||""}|${format||""}` `` (`search.ts:270`), after
dropping unsafe URLs (`isSafeProviderSubtitleUrl`, `provider-url.ts:96`).
`mergeDuplicateGroup()` (`search.ts:242-262`) picks the best-ranked member of a duplicate
group via `compareDuplicateCandidates` (exact moviehash → has `downloadAuth` → provider
confidence → provider score → local match rank → **"metadata richness"** — count of
non-null fields, `metadataRichness()`, `search.ts:196-205` → source priority → stable key),
then fills any `null` field on the winner from the losers, and unions
`providerMatch.reasons`/`matchedBy` across the whole group. A separate
`interleaveBySource()` step re-orders the deduped list for **menu display only** — the
comment at `candidate-ranking.ts:150` is explicit that auto-selection order and menu
presentation order are deliberately different passes.

### 4.4 Encoding detection (`src/lib/subtitles/encoding.ts`)

`decodeSubtitleBytesDetailed(bytes, options)` (`encoding.ts:233-369`):
1. **BOM check**: `FF FE`→`utf-16le`, `FE FF`→`utf-16be`, `EF BB BF`→`utf-8`
   (`encoding.ts:238-244`).
2. Strict-UTF-8 probe (`TextDecoder("utf-8", {fatal:true})`) sets `validUtf8`.
3. No BOM: builds candidate list `[declaredEncoding?, "utf-8", ...fallbacks]`, fallbacks =
   `["windows-1256","iso-8859-6","windows-1252"]` for Arabic-tagged subs else
   `["windows-1252","windows-1256","iso-8859-6"]` (`encoding.ts:45-46,274-291`). Each is
   scored by `assessCandidate()`.
4. `assessCandidate()` (`encoding.ts:150-204`) scores 0-1 from: printable-char ratio (+),
   U+FFFD replacement-char penalty, control-char penalty, mojibake regex penalty
   (`/(?:Ã.|Â.|â.|Ø.|Ù.)/gu`), SRT/ASS timestamp-pattern bonus, declared-encoding-match
   bonus, valid-UTF-8 bonus, and for Arabic-tagged content an Arabic-script-ratio +
   hardcoded lexical-plausibility bonus/penalty (`COMMON_ARABIC_WORDS`/`_SEQUENCES`,
   `encoding.ts:47-101`).
5. Selection: `validUtf8` → always pick the `utf-8` candidate; else pick highest score.
6. `HEALTHY_SCORE = 0.72` (`encoding.ts:43`); `healthy` = no ambiguous-legacy flag AND
   `score >= 0.72` AND zero replacement/control chars (`encoding.ts:346-350`).
7. **Ambiguous-Arabic-legacy check**: if `windows-1256` and `iso-8859-6` candidates decode
   to different text but score within `0.012` of each other, flags
   `ambiguous-legacy-encoding` (`encoding.ts:306-320`).

Diagnostic codes: `bom-detected, invalid-utf8, ambiguous-legacy-encoding,
declared-encoding-unavailable, legacy-encoding-selected, replacement-characters,
control-characters, low-decode-health` (`encoding.ts:6-19`).

### 4.5 Style settings keys and defaults

Defaults (`src/lib/settings/defaults.ts:265-293`), types (`src/lib/settings/types.ts:319-353`):
```
subFontSize: 32              subFontColor: "#FFFFFF"      subBorderColor: "#000000"
subBorderSize: 0              subMarginY: 12                subAlignX: "center"
subAssOverride: "no"          subStyle: "shadow"            subFontFamily: "inter"
subBold: false                 subBoxOpacity: 0.6             subBoxColor: "#000000"
subOpacity: 1                  subLineSpacing: 0              subHideSdh: false
```
`subAlignX: "left"|"center"|"right"`; `subAssOverride: "no"|"yes"|"force"|"scale"|"strip"`;
`subStyle: "shadow"|"outline"|"box"`. A one-time migration (`_subStyleV2` flag,
`settings/load.ts:281-285`) resets `subFontSize`/`subBorderSize`/`subMarginY` from old
defaults (`55`/`3`/`22`) to the new ones above, for users who never touched these settings.

Mapping to mpv properties, `applySubStyle()` (`src/lib/player/sub-style.ts:48-90`):
| mpv property | source |
|---|---|
| `sub-filter-sdh` | `subHideSdh && sdhFilterAllowed` |
| `sub-filter-sdh-harder` | always `false` |
| `sub-font-size` | hardcoded `32` (note: **not** `subFontSize` — that setting drives `sub-scale` instead) |
| `sub-font` | `mpvFontFor(subFontFamily, customFontName)`: `custom:`→custom family; `arabic`→`Vazirmatn`; `system`→`Segoe UI`; `serif`→`Times New Roman`; `rounded`→`Fredoka`; default→`Inter` (`sub-style.ts:18-39`) |
| `sub-scale` | ASS-scale override if active (clamped 0.2-6), else `clamp(0.4, subFontSize/32, 4)` |
| `sub-color` | `mpvColor(subFontColor, opacity)` → `#AARRGGBB` string (`sub-style.ts:9-16`) |
| `sub-border-color` | `mpvColor(subBorderColor, opacity)` |
| `sub-border-size` | `subBorderSize` verbatim |
| `sub-back-color` | `subStyle==="box"` → `mpvColor(subBoxColor, boxOpacity*opacity)`, else `#00000000` |
| `sub-shadow-color` | `mpvColor("#000000", opacity)` |
| `sub-shadow-offset` | `1.4` if `subStyle==="shadow"` else `0` |
| `sub-margin-y` | `clamp(subMarginY, 0, 100)` |
| `sub-align-x` | `subAlignX` verbatim |
| `sub-ass-override` | `subAssOverride`, or `"scale"` if an ASS-scale context override is active |
| `sub-ass-force-margins` / `sub-use-margins` | `"yes"` if native-ASS-rendering active and override≠`"no"`, else `"no"` |
| `sub-spacing` | `subLineSpacing` verbatim |
| `sub-bold` | `subBold` → `"yes"`/`"no"` |
| `sub-pos` | `clamp(100-marginY, 0, 100)` if repositioning allowed, else `100` |

All applied in parallel via Tauri `invoke("mpv_set_property", {name, value})` — **this is
one of the Tauri-coupled call sites a native port must replace** (see §6).

### 4.6 Dual subtitles (secondary track)

State: `src/lib/player/secondary-sub.ts` — a module-level external store (not React state),
type `SecondarySubChoice = string | null | "auto"` (`secondary-sub.ts:3`), default `"auto"`.

Application: `src/views/player/hooks/use-secondary-sub.ts` — on source change, resets choice
to `"auto"` (`use-secondary-sub.ts:26-29`). If choice is `"auto"`, calls
`autoPick(tracks, lang, primaryId)` which excludes the primary track and calls
`pickBestTrack(pool, [lang])` (`use-secondary-sub.ts:6-9,36`); else uses the explicit
choice. If the target differs from the primary track, calls
`bridge.setSecondarySubtitleTrack(target)` (`use-secondary-sub.ts:37-44`).

**Not found**: a dedicated "secondary subtitle language" Settings key — the `lang` driving
auto-pick is passed in by the hook's caller, not read from `settings` inside this file, and
no `secondarySub*` key surfaced in `settings/types.ts`. `TrackInfo.secondary?: boolean`
flags the active secondary track (`bridge.ts:24`); `PlayerSnapshot.secondarySubText: string`
carries the rendered secondary-cue text for overlay rendering (`bridge.ts:78`, default
`""` at `bridge.ts:184`).

### 4.7 Subtitle types verbatim

`src/lib/subtitles/types.ts:5-125`, full file:
```ts
export type ProviderMatchConfidence = "exact" | "high" | "medium" | "low" | "unknown";

/** Evidence reported by the provider or implied by a provider-side exact filter. */
export type ProviderMatchEvidence = {
  score?: number;
  confidence?: ProviderMatchConfidence;
  reasons?: string[];
  matchedBy?: Array<"hash" | "filename" | "id" | "episode" | "title" | "release">;
  degraded?: boolean;
};

export type SubtitleRating = { score?: number; good?: number; bad?: number; total?: number };

export type SubResult = {
  id: string;
  url: string;
  lang: string;
  langName?: string;
  title?: string;
  displayTitle?: string;
  source:
    | "wyzie" | "addon" | "opensubtitles" | "jimaku" | "podnapisi" | "subdl"
    | "gestdown" | "subsource";
  format?: "srt" | "vtt" | "ass" | "ssa" | "sub";
  encoding?: string;
  fps?: number;
  hearingImpaired?: boolean;
  forced?: boolean;
  foreignOnly?: boolean;
  machineTranslated?: boolean;
  fromTrusted?: boolean;
  release?: string;
  downloads?: number;
  author?: string;
  uploadedAt?: string;
  rating?: SubtitleRating;
  productionType?: string;
  releaseType?: string;
  archive?: boolean;
  rawFilename?: string;
  fileSize?: number;
  checksum?: string;
  season?: number;
  episode?: number;
  langConfirmed?: boolean;
  episodeConfirmed?: boolean;
  idConfirmed?: boolean;
  providerMatch?: ProviderMatchEvidence;
  downloadAuth?: SubtitleDownloadAuth;
  upstreamProvider?: string;
  hash?: string;
  timingStatus?: SubtitleTimingStatus;
};

export type SubtitleLoadMetadata = {
  format?: "srt" | "vtt" | "ass" | "ssa" | "sub";
  encoding?: string;
  release?: string;
  provider?: string;
  fps?: number;
  downloads?: number;
  author?: string;
  uploadedAt?: string;
  rating?: SubtitleRating;
  productionType?: string;
  releaseType?: string;
  archive?: boolean;
  rawFilename?: string;
  fileSize?: number;
  checksum?: string;
  season?: number;
  episode?: number;
  langConfirmed?: boolean;
  episodeConfirmed?: boolean;
  idConfirmed?: boolean;
  hearingImpaired?: boolean;
  forced?: boolean;
  foreignOnly?: boolean;
  machineTranslated?: boolean;
  fromTrusted?: boolean;
  providerMatch?: ProviderMatchEvidence;
  downloadAuth?: SubtitleDownloadAuth;
  providerDerived?: boolean;
  prepared?: boolean;
  autoSelectionEligible?: boolean;
  originalUrl?: string;
  timingStatus?: SubtitleTimingStatus;
  timingMeasurementStatus?: "measured" | "unknown";
  matchExplanation?: SubtitleMatchExplanation;
  matchScore?: number;
  matchConfidence?: SubtitleMatchConfidence;
  matchReasons?: string[];
  subId?: string;
};

export type SubSearchQuery = {
  imdbId?: string;
  tmdbId?: string;
  stremioId?: string;
  candidateIds?: string[];
  type?: "movie" | "series";
  title?: string;
  year?: number;
  season?: number;
  episode?: number;
  langs?: string[];
  videoHash?: string;
  videoSize?: number;
  filename?: string;
};
```

Per-title subtitle preference: **not found as a dedicated type** — grepped `src/lib/` for
`perTitle`/`per-title`/`PerTitle`, zero matches. The closest analog is the general per-show
prefs store `PerShowPrefs` (§5.5), which includes `subDelaySec`/`audioLang`/`subLang`/
`subsOff` but not full subtitle *style*.

---

## 5. TYPES VERBATIM

### 5.1 `ResumeEntry` (unnamed inline type in `src/lib/resume.ts:5`)
```ts
type Entry = { ms: number; t: number; s?: number; pct?: number; source?: ExternalCwSource };
// ExternalCwSource = "simkl" | "trakt"  (src/lib/stremio.ts:16)
```

### 5.2 `PlaybackEntry` (`src/lib/playback-history.ts:4-18`)
```ts
export type PlaybackEntry = {
  infoHash?: string | null;
  fileIdx?: number | null;
  addonId?: string | null;
  url?: string | null;
  title?: string | null;
  parsedTitle?: string | null;
  resolution?: string | null;
  releaseGroup?: string | null;
  source?: string | null;
  size?: number | null;
  bingeGroup?: string | null;
  cachedSlugs?: string[];
  savedAt: number;
};
```

### 5.3 `LocalCwEntry` (`src/lib/local-cw.ts:7-17`)
```ts
export type LocalCwEntry = {
  id: string;
  type: "movie" | "series";
  name: string;
  poster?: string;
  background?: string;
  season?: number;
  episode?: number;
  videoId?: string;
  positionMs: number;
  durationMs: number;
  t: number;
};
```

### 5.4 `LibraryItem` (`src/lib/stremio.ts:18-43`)
```ts
export type LibraryItem = {
  _id: string;
  type: string;
  name: string;
  poster?: string;
  background?: string;
  state?: {
    timeOffset: number;
    duration: number;
    season?: number;
    episode?: number;
    timeWatched?: number;
    flaggedWatched?: number;
    timesWatched?: number;
    watched?: string;
    video_id?: string;
    lastWatched?: string;
  };
  removed: boolean;
  temp: boolean;
  _ctime: string;
  _mtime: string;
  external?: ExternalCwSource;
  isAnime?: boolean;
  upNext?: boolean;
  local?: boolean;
  manualWatched?: boolean;
};
```
The actual write-path shape sent to the cloud (`StremioLibraryItem`,
`use-stremio-sync.ts:317-343`) is stricter/fuller — see §3.6.

### 5.5 Per-title settings — `PerShowPrefs` (`src/lib/player-prefs.ts:4-11`)
```ts
export type PerShowPrefs = {
  rate?: number;
  subDelaySec?: number;
  audioLang?: string;
  subLang?: string;
  subsOff?: boolean;
  updatedAt: number;
};
```
Storage: `localStorage["harbor.player.prefs.v1"]`, a `Record<metaId, PerShowPrefs>`,
capped at `MAX_ENTRIES = 200` (LRU-evicted by `updatedAt`) (`player-prefs.ts:1-2,28-34`).

### 5.6 Player state — `PlayerSnapshot`, `PlayerSource`, `Chapter`, `TrackInfo` (`src/lib/player/bridge.ts`)
```ts
export type Chapter = { title: string; startSec: number };                     // bridge.ts:52-55
export type PlayerStatus = "idle" | "loading" | "ready" | "playing" | "paused" | "ended" | "error"; // bridge.ts:57

export type PlayerSnapshot = {                                                  // bridge.ts:61-86
  status: PlayerStatus;
  positionSec: number;
  durationSec: number;
  bufferedSec: number;
  buffering: boolean;
  firstFrameReady: boolean;
  volume: number;
  muted: boolean;
  rate: number;
  audioTracks: TrackInfo[];
  subtitleTracks: TrackInfo[];
  chapters: Chapter[];
  subDelaySec: number;
  audioDelaySec: number;
  subText: string;
  subStartSec: number;
  secondarySubText: string;
  audioNormalize: boolean;
  videoWidth: number;
  videoHeight: number;
  hdrGamma: string;
  errorMessage: string | null;
  errorCode: "decode" | "codec" | "network" | "source" | "unknown" | null;
  noAudio?: boolean;
};

export type PlayerSource = {                                                    // bridge.ts:88-104
  url: string;
  traceId?: string;
  startupProfile?: "standard" | "high-bitrate";
  subtitles?: {
    id?: string;
    url: string;
    lang?: string;
    m?: string;
    trustedSource?: boolean;   // came from the user's local library / a configured home server, not an addon
  }[];
  notWebReady?: boolean;
  startAtSec?: number;
  isLive?: boolean;
  headers?: Record<string, string>;
};
```
`TrackInfo` (`bridge.ts:7-40`, fields relevant through the audio/subtitle surface — file
continues past line 40 with additional metadata mirrored from `SubtitleLoadMetadata`):
```ts
export type TrackInfo = {
  id: string;
  label: string;
  lang?: string;
  kind: "audio" | "subtitle";
  selected: boolean;
  codec?: string;
  channels?: string;
  channelCount?: number;
  title?: string;
  external?: boolean;
  prepared?: boolean;
  autoSelectionEligible?: boolean;
  externalFilename?: string;
  forced?: boolean;
  default?: boolean;
  hearingImpaired?: boolean;
  secondary?: boolean;
  url?: string;
  originalUrl?: string;
  downloadAuth?: SubtitleLoadMetadata["downloadAuth"];
  format?: SubtitleLoadMetadata["format"];
  release?: string;
  provider?: string;
  providerDerived?: boolean;
  fps?: number;
  downloads?: number;
  author?: string;
  uploadedAt?: string;
  rating?: SubtitleLoadMetadata["rating"];
  productionType?: string;
  releaseType?: string;
  foreignOnly?: boolean;
  machineTranslated?: boolean;
  // ... additional fields beyond line 40 not captured in this pass
};
```

`PlayerBridge` — the abstract interface both the mpv Tauri bridge and the HTML5 bridge
implement (`bridge.ts:106-...`): `attach/detach/load/play/pause/seek/frameStep?/setVolume/
setMuted/setRate/setAudioTrack/setSubtitleTrack/setSecondarySubtitleTrack/setSubVisible/...`
— this is the seam a native MPVKit implementation should mirror as its own Swift protocol.

---

## 6. GOTCHAS FOR A NATIVE LIBMPV PORT

1. **Every mpv property write goes through Tauri IPC, not direct libmpv calls.**
   `sub-style.ts:87` calls `invoke("mpv_set_property", {name, value})` per property,
   in parallel, swallowing errors. With MPVKit in-process on tvOS this collapses to direct
   `mpv_set_property_string` calls — no round-trip, and a native port can afford to surface
   failures instead of silently ignoring them like `mpv.rs` does (`let _ = mpv.set_property(...)`
   on ~40 call sites).

2. **Chrome/panel focus is a DOM-attribute-driven spatial engine** (`data-bp-focusable`,
   `data-bp-chip`, `data-bp-autofocus`, `inert`, manual `document.activeElement.blur()` —
   `bp-player-shell.tsx:153-157`). None of it exists on tvOS; re-implement with SwiftUI
   `@FocusState`/`.focusable()`. The *behavioral rules* (idle timings, peek vs. up,
   panel-pins-chrome, re-seeding focus after a wake) are the transferable spec, not the DOM
   mechanics.

3. **`createPortal(..., document.body)`** is used pervasively (shell, leave-confirm, up-next)
   to escape a `visibility:hidden` ancestor during playback (`bp-player-shell.tsx:70-72`) —
   a browser-only workaround, but it signals these surfaces must render above/independent of
   the main content stack at all times; make sure the tvOS player overlay layer can't end up
   nested inside something hideable.

4. **Exactly one `keydown` capture-phase listener owns the remote at a time**
   (`use-bp-player-keys.ts` vs. the focus root), toggled by `enabled`, with an explicit code
   comment warning that two such listeners on one key is "the single most reliable way to
   make this surface unnavigable" (`bp-player-shell.tsx:208-210`). tvOS's focus engine
   handles exclusivity structurally, but the *intent* — exactly one owner of Left/Right
   between seek-bar, spatial-nav, and an open panel — still needs explicit modeling.

5. **`ResizeObserver`/`getBoundingClientRect()`** measure the chrome's real height at
   runtime to publish `--bp-player-dock` so stage overlays (skip pill, up next) know where
   to stop above it (`bp-player-shell.tsx:135-149`). Port the *coupling* (overlays react
   live to the transport's rendered height) via SwiftUI geometry readers, not a hardcoded
   constant.

6. **`matchMedia("(prefers-reduced-motion: reduce)")`** gates the chrome fade
   (`use-bp-player-chrome.ts:9-12,84-87`) and is checked ad hoc per-file (plus
   `motion-reduce:` Tailwind classes). tvOS's `accessibilityReduceMotion` is the equivalent,
   but there's no central switch here — every fade site needs its own check ported.

7. **All resume/history/prefs persistence is `localStorage`, profile-scoped by
   string-concatenating a profile id onto the key** (`"harbor.localcw.v1." + profileId`,
   `"harbor.moviewatched.v1." + profileId`, `"harbor.playback-history.v1." + profileId`,
   each with a legacy un-suffixed key as a one-time migration fallback). `resume.ts` itself
   is the one *not* profile-scoped (flat `"harbor.resume"` for all profiles) — decide
   deliberately whether the native port wants per-profile resume. None of this maps
   directly to `UserDefaults`/Core Data; the portable part is the schema (keys, TTLs, caps,
   thresholds) above, not the storage mechanism.

8. **`pagehide`/`beforeunload` are the last-chance flush hook** for resume
   (`use-resume-autosave.ts:302-310`), Stremio cloud sync (`use-stremio-sync.ts:284-294`),
   and Trakt scrobbling (`scrobble-hook.ts:41-56`, including a `sendBeacon`-style
   fire-and-forget POST for the case an async call gets killed on close). tvOS has no
   equivalent; use app backgrounding (`scenePhase`) and flush proactively on every tick
   rather than relying on a final-chance-on-unload pattern, since termination isn't
   guaranteed to run any code.

9. **Gamepad detection** (`useGamepads()`, `bp-skip-pill.tsx:72,199`, picks an `"A"` vs.
   `"Enter"` hint glyph) is a Web Gamepad API dependency. tvOS's `GameController`
   framework/Siri Remote has a different capability surface (e.g. a real hardware
   Play/Pause button) — the hint-glyph logic needs re-deriving, not a straight port.

10. **`SFX.click()`/`SFX.close()`** calls are on nearly every interactive element; the SFX
    system itself was out of scope for this pass — confirm whether it's meant to be ported
    1:1 before wiring up `AVAudioPlayer` equivalents everywhere.

11. **Platform-conditional Rust** (`cfg!(windows)`/`macos`/`linux`) drives `hwdec`,
    `gpu-api`, HDR/tone-mapping, and window embedding (Win32 `DisplayConfig`, GTK on Linux,
    `mpv_render_mac`/EDR on macOS) — none of it applies to tvOS. MPVKit on tvOS needs its
    own `hwdec` (VideoToolbox, closest to the existing macOS `videotoolbox-copy` embedded
    path, `mpv.rs:378`) and its own HDR path — closer to the macOS EDR flow
    (`target-trc="pq"`, bt.2020/display-p3) than the Windows `DisplayConfig` flip, since
    AVFoundation also manages EDR at the OS level. Treat §2.6 as conceptual reference only.

12. **Anime4K shader files load from a filesystem folder path**
    (`anime4kChain(folder, ...)`, `anime4k-modes.ts:41-46`) the desktop app manages
    separately. tvOS needs its own bundling/shipping strategy (App Store size limits may
    rule out the full shader catalog) and needs to verify MPVKit's `libplacebo` pipeline on
    Metal behaves like desktop mpv's `gpu-next` VO.

13. **Four different "watched" thresholds already disagree upstream**: local resume/
    movie-watched flips at **85%** (`WATCHED_RATIO`, `use-resume-autosave.ts:33`), the
    local CW cache's own check uses **92%** (`FINISHED_RATIO`, `local-cw.ts:5`), the
    Stremio cloud item flips at **>90%** (`CREDITS_RATIO`, `use-stremio-sync.ts:19`), and
    Trakt/Simkl both scrobble "stop" at **90%**. Pick one canonical threshold deliberately,
    or reproduce all four if bit-for-bit ecosystem parity matters.

14. **No TV "Still watching?" prompt exists to copy** (§1.8) — a real gap versus the
    desktop player. Decide explicitly whether Stage 4 adds TV parity (desktop
    hook/constants in §1.8 are a reasonable starting spec) or omits it.

15. **No TV playback-speed menu and no TV chapter-mark/trickplay-thumbnail seek bar exist
    to copy either** (§1.4, §1.6) — both desktop-only today. If native tvOS is meant to
    reach desktop feature parity rather than just match the existing TV web surface, these
    need original design work.
