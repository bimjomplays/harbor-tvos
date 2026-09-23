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

Scope: the **10-foot ("Big Picture") player**, `src/views/big-picture/player/*` plus its
state/wiring seam in `src/views/player/bp-ten-foot.tsx`, the shared (desktop + TV)
`src/views/player/*` playback hooks it depends on, the Rust/libmpv host in
`src-tauri/src/mpv.rs`, resume/progress persistence, subtitle sourcing, and the concrete
TypeScript types a Swift/MPVKit port needs to reproduce.

---

## 1. TV PLAYER UI (`src/views/big-picture/player/*`)

### 1.1 Integration point / shell composition

`src/views/player/bp-ten-foot.tsx` (`BpTenFoot`, `BpTenFootLayer`) is the seam: it wraps
`BpPlayerShell` (`src/views/big-picture/player/bp-player-shell.tsx`) and feeds it live
player state. `BpPlayerShell` itself contains **no playback logic** — it is a chrome/focus
layer around the existing mpv bridge; playback stays in `src/views/player`. The TV shell
mounts via `createPortal(..., document.body)` (`bp-player-shell.tsx:272-391`), outside the
hidden `[data-bp-root]` tree so it can keep focus while the normal Big Picture browse root
is `visibility:hidden`.

`BpTenFootLayer` is reached only when `p.tenFoot` is true; `player-overlay-layers.tsx:352`
explicitly suppresses the desktop `ShellLayer` (`!p.tenFoot`), and `:1580` suppresses the
desktop `LeaveConfirmModal` (`!tenFoot && <LeaveConfirmModal/>`) since `BpLeaveConfirm`
replaces it. **The desktop `StillWatchingPrompt` is NOT similarly gated** — see §1.8.

### 1.2 Chrome show/hide state machine — HUD on Select / Play-Pause / Menu

Chrome has three phases (`bp-player-context.ts:10`, `BpChromePhase = "down" | "peek" |
"up"`): `down` — chrome away, video alone. `peek` — slim scrub readout only (seek
feedback), nothing focusable. `up` — full chrome, shell owns the D-pad.

Timing constants, `use-bp-player-chrome.ts:4-7`:
```ts
const IDLE_UP_MS = 4600;          // chrome auto-hides after 4.6s idle while playing
const PEEK_MS = 1800;             // peek readout auto-hides after 1.8s
const ACTIVITY_THROTTLE_MS = 260; // throttle for controller-repeat activity pings
const FADE_MS = 320;              // opacity fade-out duration before unmount
```
A paused video never auto-hides (`playing` gates the idle timer, `use-bp-player-chrome.ts:
77-79`); a pinned panel (`pinned`) or a held direction (`held`) also suspends the countdown.
Reduced-motion skips the fade and unmounts immediately (`:84-87`).

Key routing (`use-bp-player-keys.ts`, the "idle keys" listener active only while chrome is
down/no panel open):
- **Up/Down or Space** → raise full chrome (`onSummon`/`wakeChrome`).
- **Left/Right** → `onPeek` (unless a registered `setBpPlayerKeyHandler` claims it, e.g. the
  scrub bar). Deliberately NOT consumed for direct seeking — comment at
  `use-bp-player-keys.ts:17-26`.
- **Enter (Select)** → `onSelect`; in the shell this calls `playbackRef.current.playPause()`
  then `wakeChrome()` (`bp-player-shell.tsx:203-206`).
- **Tab / ContextMenu ("Menu")** → `onOptions` (wake chrome). There is no distinct
  Menu-panel toggle beyond waking chrome; per-panel access is via rail chips once chrome is
  up.

### 1.3 Seek bar (`BpPlayerScrub`, `bp-player-scrub.tsx`)

- **No chapter marks and no trickplay thumbnail preview** — confirmed absent by a full read
  of the 188-line file; it renders buffered/played fill bars and a live "pending" tick mark
  only. Both are desktop-only features (see §6 gap note).
- Left/Right claimed by the scrub bar itself while it holds the D-pad ring, via
  `setBpPlayerKeyHandler` (`:96-113`).
- Step ramp constants (`:11-14`):
```ts
const STEP_RAMP_AT = 10;   // after 10 repeats, multiply step
const STEP_RUSH_AT = 26;   // after 26 repeats, multiply step further
const STEP_RAMP_X = 3;
const STEP_RUSH_X = 6;
```
- `COMMIT_MS = 420` (`:9`) — accumulated presses commit as one `seekTo` call 420ms after the
  last nudge (debounced so controller repeat doesn't hammer mpv).
- Uses `settings.seekBackStepSec`/`seekForwardStepSec` (default 10s each,
  `src/lib/settings/defaults.ts:367-368`).
- Live streams show a red/`--bp-live` fill and `{t("Live")}` label with a pulsing dot
  instead of remaining time (`:170-175`).
- VOD shows `"{time} left"` and `"Ends {time}"` (wall-clock ETA via
  `Intl.DateTimeFormat`) at `:176-183`.

### 1.4 Info line / identity (`BpPlayerIdentity`, `bp-player-identity.tsx`)

- Clear-logo image if available, else `<h2>{playback.title || t("Now playing")}</h2>`.
- "Quiet" line = episode + source, joined `"  ·  "`: episode format
  `S{season} E{padded episode}[ · {name}]` (`episodeLine`, `:5-10`); source format =
  `[resolution, quality, releaseGroup].join(" · ")` (`sourceLine`, `:12-17`).
- Casting indicator: `{t("Casting")}` shown when `playback.casting` true.
- **No dedicated quality-badge chip** (e.g. an HDR/4K pill) exists in
  `bp-player-identity.tsx` — only plain text in the source line. Not found elsewhere under
  `src/views/big-picture/player/*`.

### 1.5 Transport controls (`BpPlayerControls`, `bp-player-controls.tsx:76-124`)

Default row: Previous episode (if series) → Back {n}s (Rewind) → Play/Pause (primary,
autofocused) → Forward {n}s (FastForward) → Next episode (if series). Live streams hide the
back/forward seek buttons. Labels: `t("Previous episode")`, `t("Back {n}s", {n: back})`,
`t("Pause")`/`t("Play")`, `t("Forward {n}s", {n: forward})`, `t("Next episode")`.

### 1.6 Rail (`BpPlayerRail`, `bp-player-rail.tsx:51-117`)

One chip per declared panel (icon+label from the `BpPlayerSlot`), plus a permanent leading
`t("Back")` chip (icon `ArrowLeft`, calls `runBpBack()` directly, `:71-76`), plus a quick
subtitle toggle chip (`t("Subtitles on")`/`t("Subtitles off")`) shown only when no dedicated
"subtitles" panel slot exists, plus a mute toggle chip (`t("Muted")`/`t("Sound on")`).

### 1.7 Menus / panels (opened from rail chips, `bp-ten-foot.tsx:163-260`)

Panels registered for the TV player (in-place `shellNav`, driven by the shell's own focus
engine, not a portal):
1. **resume** (forced/blocking, not a rail chip) — `BpResumePrompt` (`bp-resume-prompt.tsx:
   27-172`).
2. **subtitles** — `BpPlayerSubtitles` (icon `Captions`, label `t("Subtitles")`).
3. **audio** — `BpPlayerAudio` (icon `Languages`, label `t("Audio")`).
4. **sources** — `BpPlayerSources` (icon `AllAddonsIcon`, label `t("Sources")`); hidden for
   live (`!src.isLive`). This IS the quality/stream-switch UI — wraps the shared `BpStreams`
   component in `mode="switch"` (`bp-player-sources.tsx:49-53`).
5. **home-server-quality** — only if `src.homeServer` is set (icon `Gauge`, label
   `t("Quality")`).

**No playback-speed panel/menu exists in the TV player.** Grepping `speed` across
`src/views/big-picture/player/*` and `bp-ten-foot.tsx` found nothing UI-related — desktop
has `src/components/player/transport/speed-menu.tsx`, but it is never imported into the Big
Picture tree. **No "next episode" menu/panel exists either** — next-episode is handled
entirely by the up-next/skip-pill overlay system (§1.9), not a menu.

#### Audio menu (`bp-player-sources.tsx`, `BpPlayerAudio`)

Header: `{t("Audio")}` + `"{title} · " + t("{n} tracks", {n})`. Empty-state text: mpv engine
→ `t("This file has one audio track.")`; html5 engine → `t("Track switching isn't supported
on the current engine. The file's default audio is playing.")`. Delay steps
`DELAY_STEPS = [-0.5, -0.1, 0.1, 0.5]` seconds (`:37`), rendered `"{+/-}{step}s"`, plus a
`t("Reset")` chip when `delaySec !== 0`; disabled (`opacity-45`, `data-bp-disabled`) when
`engine === "html5"`.

#### Subtitle menu (`bp-player-subtitles.tsx`)

Four lanes/tabs: `t("Tracks")`, `t("Find more")`, `t("Sync")`, `t("Look")` (icons
`Captions`, `Search`, `Timer`, `SlidersHorizontal`, `:155-160`). Header line:
`"{context} · {selected variant or t("Off")} · {offset}"`.
- **Tracks lane**: language filter chips (`t("All languages")` + count, per-language chips
  with flag), filter chips `t("All")`/`t("Embedded")`/`t("External")`/`t("Hide HI/SDH")`/
  `t("Forced only")`, re-search chip (`t("Searching…")` / `t("Search every source again")`),
  `t("Load file")` (Tauri file dialog filtered to `srt, ass, ssa, vtt, sub`; error
  `t("Couldn't load that subtitle file. Try another.")`). "Better match" row:
  `t("Better match")`. No-subs row: `t("No subtitles")`. No-match text: `t("No tracks match
  these filters. Try toggling HI/SDH or Forced.")`. Per-row secondary/dual-subtitle chip
  labeled `t("2nd")`.
- **Sync lane** (`bp-subtitle-tune.tsx`, `BpSubtitleSync`): `t("Auto sync")`/
  `t("Cancel sync")`, `t("Use it")`, `t("Revert")`; gate text `t("Needs an external
  subtitle")`; manual offset steps `DELAY_STEPS = [-1, -0.1, 0.1, 1]`; hint `t("Subtitles
  late? Nudge plus. Early? Nudge minus.")`.
- **Look lane** (`BpSubtitleLook`): presets from `loadSubPresets()`; steppers for Size
  (`subFontSize`, reset 32, range 16-120, step ±4), Height (`subMarginY`, reset 10, range
  0-100, step ±2), Opacity (`subOpacity`, reset 1, range 0.1-1, step ±0.1); backing style
  chips Shadow/Outline/Box (`settings.subStyle`) + Bold toggle (`settings.subBold`); live
  CSS preview text `t("This is how your subtitles will look.")`.

### 1.8 "Still watching?" prompt

**There is no TV-specific ("10-foot") still-watching component.** The desktop
`StillWatchingPrompt` (`src/views/player/still-watching-prompt.tsx`) is rendered
unconditionally in `src/views/player.tsx:1555-1566` — it is **not** gated by `!tenFoot`
(unlike `LeaveConfirmModal`, which IS `!tenFoot`-gated at `player.tsx:1580`). This is worth
flagging for the native port: the TV path currently falls back to the mouse-era modal for
this one prompt.
- Timeout: `TIMEOUT_SEC = 45` (`still-watching-prompt.tsx:4`) — counts down every 1000ms;
  hits 0 → `onExit()`.
- Trigger logic: `src/views/player/hooks/use-still-watching.ts`, gated by
  `settings.stillWatching` (default `false`, `defaults.ts:394`) and
  `settings.stillWatchingAfter` (default `3` — number of back-to-back auto-advanced
  episodes before prompting, `defaults.ts:395`), wired at `src/views/player.tsx:379-384`.
- Strings: heading `t("Still watching?")`; body `"{show} · {nextLabel}"` or just show name;
  buttons `t("Keep watching")` and `t("Stop ({n})", {n: secs})`.
- Keys: Enter/Space → continue; Escape → exit (`:36-50`).

### 1.9 Next-episode countdown / auto-advance, skip intro/outro (`skip-pill-container.tsx`)

`SkipPillContainer` (`src/views/player/skip-pill-container.tsx`) drives all timing and is
**shared** between desktop `SkipPill` and TV `BpSkipPill`, switched via a `tenFoot` prop
(`:147-148`, comment at `:41`).

- `nextEpisodeLead(setting, durationSec)` (`:10-14`):
```ts
export function nextEpisodeLead(setting: number, durationSec: number): number {
  if (setting === 0) return 0;
  if (setting > 0) return setting;
  return Math.min(45, Math.max(15, Math.round(durationSec * 0.04)));
}
```
  `setting` = `settings.nextEpisodeLeadSec`, default `-1` (`defaults.ts:392`) → auto lead =
  4% of duration, clamped to 15–45s. `0` disables it; a positive value is the lead window
  literally, in seconds.
- If no real "outro" skip segment exists, a **synthetic outro** is manufactured covering the
  last `leadSec` of the runtime once remaining time drops into `(0.5s, leadSec]` (`:50-65`),
  so the up-next UI always has something to key off near the end even with no provider data.
- Auto-skip (immediate jump, no pill shown) fires per-kind when `settings.autoSkipIntro`/
  `autoSkipRecap`/`autoSkipOutro`/`autoSkipAd` is true (all default `false`,
  `defaults.ts:310-313`) and the `allowAutoSkip` prop is true; guarded so each concrete
  segment auto-skips only once (`autoSkippedRef`).
- Skip-pill auto-hide: `settings.skipButtonHideSec` (default `0` = never, `defaults.ts:
  315`); when >0, `setTimeout(..., skipButtonHideSec * 1000)` hides the shown pill; manual
  dismissal (X) is remembered per segment key (`kind:startSec:endSec`) until the segment
  changes. `settings.showSkipButton` (default `true`) gates whether pills render at all.

#### Skip pill (`bp-skip-pill.tsx`) & Up Next card (`bp-up-next.tsx`)

Both render in the shell's always-on `stage` slot (independent of chrome phase) at
`BP_STAGE_BOTTOM = "var(--bp-player-dock, calc(var(--bp-safe-y, 0px) + clamp(30px, 4vh,
64px)))"` (`bp-up-next.tsx:69-70`).

Skip pill:
- **Never auto-focuses** (no `data-bp-autofocus`) — deliberate; documented at
  `bp-skip-pill.tsx:22-42`: a focused `<button>` fires on both Enter and Space, and Space is
  the pause key, so auto-seeding it would hijack pause during the intro window. Reachable
  by: (1) navigating Up twice from the transport, or (2) the dedicated `MediaFastForward`
  hotkey, which shows a hint chip reading `"A"` (gamepad) or `"Enter"` (no gamepad)
  (`:198-200`).
- `EXIT_MS = 240` (`:20`) — pill stays mounted 240ms after the segment clears, for exit fade.
- Labels by kind (`:148-157`): ad → `t("Skip injected ad?")`; intro → `t("Skip Intro")`;
  recap → `t("Skip Recap")`; outro-with-next-episode → `t("Next Episode")`; else →
  `t("Skip Credits")`. Dismiss tooltip/aria-label: `t("Hide this Skip button")`.
- When an outro segment is active, a next episode exists, and `remainingSec <= leadSec`, the
  pill **morphs into the Up Next card** instead (`asUpNext`, `:98-101,133-146`).

Up Next card:
- Header eyebrow `t("Up Next")`; title = episode name or `S{season}·E{episode}` fallback
  (spoiler-masked via `mask?.title`); meta line `"{epLabel} · {n} min"` (via
  `t("{n} min", {n})`); still image if available and not spoiler-masked (`mask?.thumb`).
- `CountdownRing` — SVG ring, `stroke-dashoffset` animation (not conic-gradient — comment at
  `bp-up-next.tsx:270-272` notes conic-gradient renders unevenly on the WebViews Harbor
  ships on), shows integer seconds remaining.
- Buttons: `t("Play now")` (Play icon) and `t("Keep watching")` (X icon, cancels
  auto-advance) — cancel, not play, gets the autofocus seed (`:223-227`): an accidental
  cancel costs one extra button press, an accidental play throws away unwatched runtime.
- Back button, while the up-next card is visible, cancels auto-advance rather than exiting
  (`pushBpBack`, `:126-131`).

#### Skip-segment data sources (`src/lib/skip-intro/*`)

Merge priority order (first match on overlap wins), `index.ts:172`:
`[adSegments, aniSkip, skipDb, introDb, introDbApp, fromChapters]`.
- **AniSkip** (`aniskip.ts`) — anime only. Kitsu→MAL mapping:
  `https://kitsu.io/api/edge/anime/{kitsuId}/mappings`; skip times:
  `https://api.aniskip.com/v2/skip-times/{malId}/{episode}?{params}`.
- **SkipDB** (`skipdb.ts:56`) — `https://api.skipdb.tv/api/segments?{key}`.
- **IntroDB** (`theintrodb.ts:79-80`) — `https://api.theintrodb.org/v2/media?{cacheKey}`
  (user-supplied API key read via `readTheIntroDbKey(settings)`).
- **IntroDB App** (`introdb-app.ts:46`) — a *different* service:
  `https://api.introdb.app/segments?{key}`.
- **AdCorpus** (`adcorpus.ts`) — hits `HARBOR_API_BASE` (`@/lib/config/endpoints`) for
  injected-ad segment fingerprints; not a third-party skip-intro provider.
- **Chapters** (`chapters.ts`) — classifies mpv chapter titles by regex
  (`INTRO_PATTERNS`/`OUTRO_PATTERNS`/`RECAP_PATTERNS`) into intro/outro/recap, synthesizing
  a `SkipSegment` per matched chapter; `endSec` = next chapter's start, or `+90s` fallback.
- Filtering (`index.ts:171-183`): drop segments starting ≥ total duration; clamp `endSec` to
  duration; require length in `[2, MAX_SEGMENT_SEC=360]` seconds; outro segments must start
  at or after `durationSec * MIN_OUTRO_START_FRACTION (0.5)`.
- `activeSegment(segments, positionSec)` (`:214-222`): active while `positionSec ∈
  [startSec, endSec - 0.75)`.
- `SkipSegment = { kind: "intro"|"outro"|"recap"|"ad"; startSec: number; endSec: number;
  source: "aniskip"|"introdb"|"skipdb"|"introdb-app"|"chapters"|"adcorpus" }` (`types.ts`).

### 1.10 Back / exit behaviour

`bp-player-key.ts` and `bp-back.ts` implement two independent, stacked handler registries:
`setBpPlayerKeyHandler`/`bpPlayerHandledKey` for directional keys, and
`pushBpBack`/`runBpBack` for the Back button specifically — both LIFO (newest handler wins;
false/no-claim falls through).

Shell's Back handling (`bp-player-shell.tsx:183-196`, `onBack`): first tries `runBpBack()`
(registered dialogs/panels get first refusal); if a panel is open, closes it and stops;
**otherwise `hideChrome()`** — Back with chrome up just hides the chrome, it does **not**
exit playback. Comment is explicit: *"Back does not leave playback from here. It puts the
chrome away, and the next Back falls through uncaught to the player's own confirm-and-exit."*
So it is genuinely a **press-Back-twice pattern**: 1st Back (chrome up) → hide chrome; 2nd
Back (chrome down, idle-keys active) → falls through uncaught to `BpTenFootLayer`'s own
`pushBpBack` (`bp-ten-foot.tsx:283-308`), which calls `p.onBack()` directly if
`!sportsDocked && !drawMode`, else routes through `requestPlayerClose(...)` with
`playerConfirmLeave: settings.playerConfirmLeave` — i.e. **the leave-confirmation dialog
only appears if that setting is enabled.**

Confirm dialog (`bp-leave-confirm.tsx`, `BpLeaveConfirm`, state from
`src/lib/player/leave-confirm.ts`): title `t("Leave the show?")`; body `t("We'll save your
spot so you can pick up right where you left off.")`; buttons `t("Keep watching")`
(autofocused), `t("Leave")`, plus a toggle `t("Don't ask again")` (Check icon when on) —
checking it flips `playerConfirmLeave` off via `state.onConfirm(remember)`. Escape/Backspace
also close it.

The rail's manual `t("Back")` chip (§1.6) provides an always-visible exit affordance in
addition to the hardware Back button.

### 1.11 Error / stall / retry UI (`bp-connecting.tsx`, `bp-p2p-status.tsx`)

Connecting/loading full-screen overlay (`bp-connecting.tsx`), shown while `!everPlayed &&
!failed && errorCode == null && status !== "ended"`.
- `STILL_LOOKING_MS = 22_000` — after 22s with zero peers, note upgrades to "still looking".
- `HEAVY_BYTES = 20 * 1024**3` (20 GB) — triggers a "large file" warning note.
- `FADE_MS = 320` — overlay fade-out on dismiss.
- P2P terminal-failure windows (`bp-p2p-status.tsx:28-29`, shared with the windowed
  player's `use-p2p-preparing-status.ts` — comment warns both must be changed together):
  `NO_PEERS_MS = 75_000` (torrent declared dead after 75s of zero peers/no data),
  `SLOW_MS = 90_000` (declared "slow" after 90s with peers but no data movement). Poll
  interval `POLL_MS = 1000`.
- Stage labels (`bpStageLabel`, `bp-p2p-status.tsx:168-180`): `t("No peers found")`
  (terminal) / `t("Buffering")` / `t("Loading")` (local file) or `t("Connecting")`
  (non-torrent stream) / `t("Found peers, no data yet")` (slow) / `t("Looking for
  peers…")` (0 peers) / `t("Preparing stream")` (default torrent state).
- Note strings (`bp-connecting.tsx:239-267`): terminal → `t("Couldn't connect to any peers
  for this torrent. It may be unreachable on your network (some ISPs and VPNs block torrent
  traffic).")`; slow → `t("Found peers but no data yet. The torrent may be slow.")`;
  buffering → `t("The player has the stream open and is waiting on the next piece.")`;
  still-looking (≥22s, 0 peers) → `t("Still looking. Some torrents take a minute to find
  their first peer.")`; peers>0 → `t("Downloading the start of the file. Playback begins
  once there is enough to keep going.")`; heavy-file → `t("Heads up: this is a large file
  for peer-to-peer streaming, so it can take a while to start. A 1080p source or a debrid
  service will load faster.")`.
- Action buttons: non-terminal → `t("Cancel")` always, plus `t("Try again")` if `slow`;
  terminal → `t("Go back")` (loud/primary) + `t("Try again")` (quiet).
- Readiness meter is monotonic-only (never regresses visually, `useMonotonicPct`,
  `bp-p2p-status.tsx:182-189`) and shows an indeterminate pulsing-bar state
  (`stremio-progress` CSS animation, 1.5s) while `pct < 1`.

### 1.12 Hint bar

`HINTS: BpAction[] = ["select", "back"]` (`bp-player-shell.tsx:32`) — labels: Select =
`t("Select")` (pad glyph `A`, remote glyph `OK`, keyboard glyph `Enter`), Back = `t("Back")`
(pad `B`, remote `Back`, keyboard `Esc`). Hidden (opacity 0) while a panel is open; shown at
full opacity only when chrome is up with no active panel (`bp-player-shell.tsx:372-379`).

### 1.13 Not found (Section 1)

- Chapter marks on the seek bar.
- Trickplay/scrubbing thumbnail preview (desktop-only concept, not present in TV source).
- A dedicated quality/resolution badge UI element (e.g. a "4K"/"HDR" chip) — only plain text.
- A playback-speed menu for TV — no TV source file for it exists.
- Any TV-specific still-watching UI — desktop modal is reused unconditionally.

---

## 2. MPV CONFIGURATION (`src-tauri/src/mpv.rs`, `src/lib/player/*`)

### 2.1 Pre-init options (`apply_pre_init`, `mpv.rs:325-478`)

Applied before `mpv_initialize` via `init.set_property` (best-effort — `PROPERTY_NOT_FOUND`
logged non-fatally, `mpv.rs:334-338`):

| mpv property | value | file:line |
|---|---|---|
| `title` | `"Harbor"` | 349 |
| `audio-client-name` | `"Harbor"` | 350 |
| `terminal` | `"no"` | 351 |
| `msg-level` | `"all=warn,vo=v,d3d11=v,gpu=v,win32=v"` | 352 |
| `ytdl` | `"yes"` if `args.is_live` else `"no"` | 353-354 |
| `user-agent` | `args.headers["user-agent"]` else default `"VLC/3.0.20 LibVLC/3.0.20"` | 355-367 |
| `http-header-fields` | comma-joined `"Name: value"` pairs for remaining headers | 368-369 |

`http-header-fields` is built by `mpv_header_field()` (`mpv.rs:319-323`), which escapes
`\`→`\\` and `,`→`\,` — mpv parses this option as a comma list, so an unescaped comma (e.g.
in `Accept-Language`) would create an invalid second header.

**`hwdec`** (mpv.rs:377-391): macOS embedded (`on_mac_embed`) → `"videotoolbox-copy"` (+
`force-window="no"`); Linux → `"auto-safe"`; Windows → `"d3d11va"` if RTX HDR or RTX VSR
requested else `"auto-safe"`; other/macOS non-embed → `"auto-safe"`.

**`force-window`**: Linux `"no"` if `args.embed` else `"yes"` (383-386); Windows
`"immediate"` (389); other `"immediate"` (392).

Other pre-init options: `video-timing-offset="0"` when embedded on macOS/Linux (mpv's render
callback normally wakes ahead of presentation time and blocks in `render()`, stalling the
WebKit overlay's UI thread — 394-401); `input-default-bindings="no"`, `input-media-keys=
"no"`, `input-cursor="no"` (403-405); `osc="no"` (best-effort; some libmpv builds, e.g.
Flatpak, lack the optional OSC Lua script, 406-409); `osd-level="0"` (410);
`cursor-autohide="200"` (411); `volume-max="600"` (412); `sub-codepage="utf-8"` (413);
`background-color="#000000"`, `background="color"`, `media-controls="no"` (414-416).
Windows embed: `wid`=HWND int; if `d3d11_flip && hdr_to_sdr`, `d3d11-flip="no"` (419-427).
Non-embed windowed overlay: `ontop="yes"`, `border="no"`; Windows-only `screen`=monitor
ordinal (434-445).

**HDR/tone-map branch** (447-480): RTX HDR active → `gpu-api="d3d11"`,
`target-colorspace-hint="yes"`, `target-peak="10000"`. Else if `hdr_to_sdr` →
`tone-mapping="spline"`, `gamut-mapping-mode="perceptual"`, `hdr-compute-peak="yes"`,
`hdr-contrast-recovery="0.30"`, `hdr-peak-percentile="99.995"`, `dither-depth="auto"`,
`target-trc="bt.1886"`, `target-prim="bt.709"`; Windows/macOS also add
`target-colorspace-hint="yes"`; Windows+RTX VSR also `gpu-api="d3d11"`. Else: Windows adds
`target-colorspace-hint="yes"` (+ `gpu-api="d3d11"` if embedded or VSR); macOS adds
`target-colorspace-hint="yes"`.

### 2.2 Video output

`vo`: when not using the native render API (macOS/Linux embed path) → `args.renderer`
(`"gpu"` or default `"gpu-next"`, mpv.rs:801-809); if `force_yuv420p`, appends
`vf-append="format=yuv420p"` (810-813); when using the render API → `vo="libmpv"` +
`force-window="no"` (815-818). **No `profile` option is ever set anywhere in `mpv.rs`.**

### 2.3 Cache / network — post-init (`mpv_start`, mpv.rs ~780-1030)

`log-file` = `<app_data_dir>/harbor-mpv.log` (797-798).

**Live streams** (`is_live`, 889-902): `cache="yes"`, `cache-secs="30"`, `cache-pause=
"yes"`, `cache-pause-initial="no"`, `demuxer-max-bytes="64MiB"`, `demuxer-max-back-bytes=
"16MiB"`, `demuxer-readahead-secs="20"`, `network-timeout="60"`, `stream-lavf-o=
"reconnect=1,reconnect_delay_max=5,reconnect_on_network_error=1"`, `demuxer-lavf-o=
"http_seekable=0,http_persistent=0"`, `stream-buffer-size="16MiB"`. Also disables quality
filters (1016-1029): `scale`/`dscale`/`cscale="bilinear"`, `dither="no"`, `deband="no"`,
`correct-downscaling="no"`, `linear-downscaling="no"`, `sigmoid-upscaling="no"`,
`hdr-compute-peak="no"`, `interpolation="no"`.

**VOD** (905-980), keyed on `full_dl = args.full_download` and `high_bitrate =
args.startup_profile == "high-bitrate"`:

| property | full_dl | high_bitrate | default |
|---|---|---|---|
| `cache-secs` | `100000` | `45` | `30` |
| `cache-pause-wait` | `10` | `2` | `1` |
| `demuxer-max-bytes` | `48GiB` | `256MiB` | `128MiB` |
| `demuxer-max-back-bytes` | `48GiB` | `64MiB` | `32MiB` |
| `demuxer-readahead-secs` | `100000` | `45` | `30` |
| `stream-buffer-size` | — | `32MiB` | `16MiB` |

`cache="yes"`, `cache-pause="yes"`, `cache-pause-initial="no"` always. `demuxer-cache-dir`
(falls back to legacy `cache-dir` if rejected — mpv 0.41 renamed it and rejects the old name)
= `<app_cache_dir>/mpv-cache` (959-969); `cache-on-disk="yes"` (972). `network-timeout` =
`network_timeout_for(url)`: `"600"` for a local-network URL (`is_local_network_url`), else
`"60"` (645-651, 973). `stream-lavf-o` = `"reconnect=1,reconnect_on_network_error=1,
reconnect_on_http_error=429,reconnect_delay_max=10,reconnect_delay_total_max=60"` —
**deliberately no `reconnect_streamed`**: comment explains AES-128 HLS segments end in a
normal EOF, ffmpeg retries from offset 0 and gets an empty body, causing 1/3/7s backoff;
measured 7 segments/55s backoff per 100s with the flag vs. 94 segments/0s backoff without it
(975-982).

Subtitle slot init (991-1007): `sub-auto="all"` (still discovers local sidecars for the
track picker), `sid="no"`, `secondary-sid="no"` (kept empty so mpv doesn't auto-pick before
Harbor applies the user's language choice); if embedding, `sub-visibility="no"`,
`secondary-sub-visibility="no"`; `sub-fonts-dir` = app font dir; `sub-font-provider=
"auto"`; `sub-font="Noto Sans JP"`; `embeddedfonts="yes"`.

`extra_options` (arbitrary user string) is applied *after* everything above via
`apply_extra_mpv_options`, so it can override anything (1009-1011).

Screenshot options: `screenshot-format="png"/"jpg"`, `screenshot-png-compression="3"`,
`screenshot-jpeg-quality="92"/"72"`, `screenshot-sw="yes"`, `screenshot-high-bit-depth=
"no"` (1931-2001, 2303-2308 — clip/GIF recorder vs. regular screenshot use different
quality). CLI fallback launch (2245-2246) uses `--cache=yes --network-timeout=60`.

### 2.4 HDR runtime toggles (platform-specific, out of scope for tvOS)

Windows: `target-peak` flips `"10000"` → 60ms sleep → `"auto"` (`reassert_hdr_colorspace`,
1088-1092). macOS EDR (`apply_mac_edr`, 1140-1157): sets `icc-profile-auto="no"`,
`target-prim="bt.2020"`/`"display-p3"` (from read `video-params/primaries`),
`target-trc="pq"`, `target-peak="auto"` when active; reverts `target-trc`/`target-prim`/
`target-peak` to `"auto"` when inactive.

### 2.5 Anime4K shader chains (`src/lib/player/anime4k-modes.ts`)

Modes `"A"|"B"|"C"|"AA"|"BB"|"CA"`, tiers `"hq"` (`VL` variant) / `"fast"` (`M` variant).
`anime4kChain(folder, mode, tier)` builds an ordered `.glsl` filename list prefixed with the
shader folder — e.g. mode `"A"`: `[Anime4K_Clamp_Highlights.glsl,
Anime4K_Restore_CNN_{VL|M}.glsl, Anime4K_Upscale_CNN_x2_{VL|M}.glsl,
Anime4K_AutoDownscalePre_x2.glsl, Anime4K_AutoDownscalePre_x4.glsl,
Anime4K_Upscale_CNN_x2_M.glsl]`; mode `"C"` swaps in
`Anime4K_Upscale_Denoise_CNN_x2_{VL|M}.glsl}`. **Not found**: the exact mpv property that
receives this chain (likely `glsl-shaders`) was not confirmed in this pass — check
`src/lib/player/shader-chain.ts` and `mpv-forward.ts`.

### 2.6 Buffer size presets (`src/lib/player/buffer-profile.ts`)

`BufferSizeId = "auto"|"small"|"medium"|"large"|"max"`:

| id | cacheSecs | readaheadSecs | maxBytes | maxBackBytes | pauseWaitSecs |
|---|---|---|---|---|---|
| small | 60 | 20 | 150MiB | 32MiB | 0 |
| medium | 300 | 120 | 512MiB | 64MiB | 4 |
| large | 600 | 600 | 1GiB | 128MiB | 10 |
| max | 1800 | 1800 | 2GiB | 256MiB | 20 |

`bufferMpvLines(id)` renders literal mpv config lines (`cache=yes`, `cache-secs=N`, …).
`bufferSizeFor(stored)` resolves `mpvBufferSize`, else `"large"` if legacy
`mpvBufferBoost` was true, else `"auto"`. **Note**: reconciliation between this preset table
and the hardcoded live/VOD numbers in §2.3 was not confirmed — appears to be a
separate/possibly-legacy config path.

### 2.7 Startup profile (`src/lib/player/startup-profile.ts`)

`PlaybackStartupProfile = "standard"|"high-bitrate"`. `playbackStartupProfile(stream)`
returns `"high-bitrate"` if `stream.size >= 12 * 1024^3` bytes OR the regex
`/(?:^|[^a-z0-9])(?:2160p?|4320p?|4k|8k|uhd|remux)(?:[^a-z0-9]|$)/i` matches the joined
resolution/quality/source/parsedTitle/title descriptor; else `"standard"`. Threaded through
as `args.startupProfile` → `mpv_start` → the `high_bitrate` branches in §2.3.

### 2.8 Subtitle style → mpv property mapping

See §4.5 (kept alongside the Settings defaults it maps from).

### 2.9 Audio/subtitle track preference

`Settings.preferredLanguages: string[]` (default `["English"]`,
`src/lib/settings/types.ts:115`, `src/lib/settings/defaults.ts:29`) is the single
language-preference list driving catalogue and player auto-selection. Subtitle candidate
scoring/eligibility lives in `src/lib/subtitles/track-selection.ts` — see §4.2 for the full
ranking algorithm. Orchestration is `src/views/player/hooks/use-track-autoload.ts` (939
lines), which wires `preferredLanguages`, per-show overrides
(`src/lib/player-prefs.ts::readPlayerPrefs`, §5.5), remembered choices
(`src/lib/subtitles/subtitle-memory.ts`), and autoload gating
(`src/lib/subtitles/autoload.ts`, `autoload-run.ts`) into the final `sid`/`aid`. Race
protection: `SubtitleSelectionCoordinator` (`src/lib/player/subtitle-selection.ts:15-70`) —
`manualMediaRevision` prevents a manual pick from being clobbered by a later automatic pick
for the same media; `selectionRevision` drops stale async loads; `settle()` falls back to
the previous id if the requested one is unavailable. mpv properties set: `aid`
(`mpv.ts:995`, `mpv-forward.ts:98`) and `sid`/`secondary-sid` (`mpv.ts:1017-1064`).

### 2.10 Stream headers (`behaviorHints.proxyHeaders`)

- Type: `proxyHeaders?: ProxyHeaders` on the stream object (`src/lib/streams/types.ts:71`);
  shape `{ request?: Record<string,string>|null; response?: Record<string,string>|null }`
  (`src/lib/streams/mode.ts:5-8`).
- Read at resolve time: `const headers = stream.behaviorHints?.proxyHeaders?.request ??
  stream.behaviorHints?.headers;` (`src/lib/streams/resolve.ts:133`).
- `hasDirectMediaEvidence()` treats presence of proxyHeaders/headers as evidence a stream is
  directly playable, not a web page (`mode.ts:37-40,60-66`).
- Adapter plugins can set `behaviorHints.proxyHeaders = { request: headers }`
  (`src/lib/streams/plugins/adapter.ts:232`).
- Flows into `DirectLink.headers` (`resolve.ts:140-146`) → `PlayerSrc.headers` → `src.headers`
  in `createMpvBridge` (`src/lib/player/mpv.ts:892,934`).
- `applyHeaderProps(headers)` (`mpv.ts:240-249`): splits headers into `user-agent`
  (case-insensitive match) vs. the rest; sets mpv props `user-agent` and
  `http-header-fields` (joined `"Key: value"`, comma-separated) via
  `invoke("mpv_set_property", …)`. Rust re-escapes via `mpv_header_field()` (§2.1).
  Applied on fresh `mpv_start` (`headers: src.headers ?? null`, `mpv.ts:934`) and on
  in-place reload (`await applyHeaderProps(src.headers)` before `loadfile`, `mpv.ts:892`).

### 2.11 Subtitle loading into mpv

External subs are added via the mpv `sub-add` command with flag `"auto"` (does not
force-select): `mpv_argv_command(&mpv_arc, &["sub-add", &url, "auto"])` (`mpv.rs:1063-1065`
on-demand; `mpv.rs:1443` adjacent/sidecar auto-discovery; lower-level manual build at
`mpv.rs:2380-2405`). TS side invokes this via `src/lib/player/mpv.ts` (warns
`"[mpv] sub-add failed"` on error, `mpv.ts:1268`); accepts SRT/VTT/ASS URLs (local paths or
http(s)).

### 2.12 "Auto engine" rule — mpv vs. HTML5

`pickBridge(want, notWebReady, mpvOpts)` — `src/views/player/player-utils.ts:54-87`:
```ts
if (want === "html5") return { bridge: createHtml5Bridge(), engine: "html5" };
if (want === "mpv") {
  // probe mpv; available -> mpv bridge, engine "mpv"
  // else -> warn, fall back to createHtml5Bridge(), engine "html5"
}
// want === "auto":
// isDesktop = "__TAURI_INTERNALS__" in window
// if (isDesktop || notWebReady) {
//   probe mpv; available -> mpv bridge, engine "mpv"
//   if (isDesktop) warn on probe failure
// }
// return createHtml5Bridge(), engine "html5"   // fallback
```
There is **no separate HLS/mpegts engine** in this codebase — only `"mpv"` (native libmpv
via Tauri) and `"html5"` (in-webview `<video>`, via `createHtml5Bridge()` in
`src/lib/player/html5.ts`). "Auto" picks mpv whenever running under Tauri desktop or when
the stream is `notWebReady` (direct/torrent/proxied stream a plain `<video>` can't play),
gated by a successful `probeMpv()`; otherwise always falls back to html5. `engine` state
lives in `src/views/player/hooks/use-player-bridge.ts:63` and gates many mpv-only features
across `src/views/player/hooks/*.ts` (grep `engine === "mpv"` for the full list). This rule
is **irrelevant to a native tvOS port** — MPVKit is always used — but is documented here for
completeness since it explains why some desktop code paths are HTML5-only.

### 2.13 Types verbatim (mpv/Rust)

`src-tauri/src/mpv.rs:41-60` — `MpvStartArgs` (serde camelCase):
```rust
pub struct MpvStartArgs {
    pub url: String,
    pub start_at_sec: Option<f64>,
    pub subtitles: Option<Vec<MpvSub>>,
    pub anime4k: Option<bool>,
    pub hdr_to_sdr: Option<bool>,
    pub rtx_hdr: Option<bool>,
    pub rtx_vsr: Option<bool>,
    pub embed: Option<bool>,
    pub anime4k_shaders: Option<Vec<String>>,
    pub d3d11_flip: Option<bool>,
    pub mac_edr: Option<bool>,
    pub is_live: Option<bool>,
    pub full_download: Option<bool>,
    pub startup_profile: Option<String>,
    pub headers: Option<HashMap<String, String>>,
    pub extra_options: Option<String>,
    pub renderer: Option<String>,
    pub force_yuv420p: Option<bool>,
}
```

`src-tauri/src/mpv.rs:64-71` — `MpvGeometry`:
```rust
pub struct MpvGeometry {
    pub css_left: f64,
    pub css_top: f64,
    pub css_width: f64,
    pub css_height: f64,
    pub css_view_w: f64,
    pub css_view_h: f64,
}
```

### 2.14 Not found / unconfirmed (Section 2)

- Exact mpv property receiving the Anime4K `.glsl` chain (likely `glsl-shaders`).
- Reconciliation between `BUFFER_PROFILES` (§2.6) and the hardcoded live/VOD cache numbers
  in §2.3.
- `src/lib/player/mpv-tuning.ts` (`mergeMpvOptions`, referenced from
  `use-player-bridge.ts:8`) was not opened in this pass.

---

## 3. PROGRESS + RESUME

### 3.1 localStorage keys and shapes

All four stores below are **per-profile**: they read `harbor.profiles.v1` to resolve
`activeProfileId()`; if the active profile shares Stremio with another profile
(`shareStremioWith`), writes redirect to that shared profile's key.

**`harbor.resume`** (`src/lib/resume.ts:3`) — single JSON object, keyed by
`entryKey(id, season?, episode?)` = `` `${id}|s${season}e${episode}` `` for episodes, else
bare `id` (`resume.ts:7-12`). Value (`resume.ts:5`):
```ts
type Entry = { ms: number; t: number; s?: number; pct?: number; source?: ExternalCwSource };
```
`ms`=position ms, `t`=`Date.now()` write timestamp, `s`=display season override,
`pct`=fraction 0-1, `source`=`"simkl"|"trakt"` when backfilled externally. Written via
`saveResumeMs`/`saveResumeBatch` (`:31,57`), read via `readResumeMs`/`readResumeEntry`
(`:88,93`), cleared via `clearResume` (`:119`). `lastPlayedEpisode(seriesId)` (`:125`) scans
keys prefixed `` `${seriesId}|s` `` and returns the most-recently-touched episode.

**`harbor.playback-history.v1.<profileId>`** (legacy key `harbor.playback-history.v1`
migrated in, `playback-history.ts:20-21,68-80`) — JSON object keyed the same way
(`entryKey`, `:89-94`). Value = `PlaybackEntry` (§5.2). TTL `30 * 24 * 60 * 60 * 1000` ms
(`:23`), cap `MAX_ENTRIES = 200`, oldest by `savedAt` evicted on write (`:24,115-121`).
Written by `savePlayback` (`:145`), read by `readPlayback`/`readLastSeriesPlayback`
(`:167,268`).

**`harbor.localcw.v1.<profileId>`** (legacy `harbor.localcw.v1`, `local-cw.ts:1-2`) — JSON
object keyed by bare meta id. Value = `LocalCwEntry` (§5.3). Cap `MAX = 60`, oldest by `t`
evicted (`:4,117-121`). `FINISHED_RATIO = 0.92` (`:5`): on `saveLocalCw`, if
`positionMs/durationMs >= 0.92` and `type === "movie"`, the entry is **deleted** rather than
stored (`:111-114`); series entries are kept regardless. Read via `listLocalCw`/
`localCwEntry` (`:126,130`).

**`harbor.moviewatched.v1.<profileId>`** (legacy `harbor.moviewatched.v1`,
`movie-watched.ts:3-4`) — JSON array of watched movie meta-id strings, loaded into a
`Set<string>`. Written via `persistCritical` in `persist()` (`:79-84`).
`setMovieWatchedLocal(id, watched)` toggles membership (`:94-101`);
`isMovieWatchedLocal` checks membership (`:86-88`).

Also a Stremio cloud-write retry queue, **`harbor.stremio.write-queue.v1`**
(`stremio-write-queue.ts:3`) — array of `{authKey, item: LibraryItem}` for failed
library-item PUTs; flushed on `online` event and every 60000ms (`:104-106`).

### 3.2 Write cadence

Two independent write loops run during playback, both driven off
`getPlaybackPosition()`/`subscribePlaybackClock` (`src/lib/player/playback-clock.ts`):

1. **Local resume/history** — `src/views/player/hooks/use-resume-autosave.ts`:
   `TICK_MS = 4000` (`:29`) — `setInterval` every **4s** while `snap.status === "playing"`
   (`:250-253`), calling `persistNow(false)`, which no-ops unless position moved ≥1500ms
   since last save (`:245-248`) or `force=true`. Also force-persists on any
   non-playing/loading/idle/ready status change, on episode/src change, and on
   `pagehide`/`beforeunload` (`:262-286`). `MIN_POSITION_SEC = 5` (`:30`).
   `STUB_MAX_SEC = 150` (`:34`) — content under 150s duration never persisted.
2. **Stremio cloud library sync** — `src/views/player/hooks/use-stremio-sync.ts`:
   `TICK_MS = 30000` (`:16`) every **30s** while playing/casting, skipped if position delta
   since last sync is <4000ms (`:264`). `MIN_POSITION_SEC = 6` (`:18`). Also flushes on
   pause/ended/error, unmount, `pagehide`/`beforeunload` (`:271-294`).
   `BASE_REFRESH_MS = 30000` (`:17`) re-polls the remote item every 30s to detect
   concurrent writes. Remote writes are dropped if a fresher remote mtime exists with a
   higher timeOffset (`:201-209`).

### 3.3 Watched thresholds — five different ratios, no single shared constant

| Constant | Value | File:line | Meaning |
|---|---|---|---|
| `END_RATIO` | 0.85 | `src/lib/player/playback-end.ts:3` | `isNaturalEnd`: mpv "ended" counts as natural end only if pos/duration ≥0.85 |
| `WATCHED_RATIO` | 0.85 | `use-resume-autosave.ts:33` | local "finished" flag: pos/duration≥0.85 OR isNaturalEnd → clears resume, marks watched |
| `CREDITS_RATIO` | 0.9 | `use-stremio-sync.ts:19` | cloud `flaggedWatched=1` threshold |
| `CW_FINISHED_RATIO` | 0.9 | `src/lib/stremio.ts:7` | item drops from Continue Watching when timeOffset/duration≥0.9 |
| `RESTART_THRESHOLD` | 0.8 | `src/lib/player/resume-start.ts:5` | remote item treated as "finished" (restart at 0) if flaggedWatched or ratio≥0.8 |
| `FINISHED_RATIO` | 0.92 | `src/lib/local-cw.ts:5` | local-cw entry for finished movie deleted rather than stored |
| Trakt `WATCHED_MARK_PCT` | 90 | `src/lib/trakt/scrobble-hook.ts:19` | scrobble becomes "stop" vs "pause" once progress%≥90 |
| Simkl (`SIMKL_WATCHED_RATIO`→pct) | 0.9 → 90 | `src/lib/simkl/config.ts:10`, `scrobble-hook.ts:28` | same for Simkl |
| `REWATCH_RESUME_SEC` | 45 | `use-resume-autosave.ts:31` | movie must resume past 45s before rewatch un-marks watched |
| cloud `meaningfulResume` offset | 45000ms | `use-stremio-sync.ts:403` | offset≥45s treated as real resume, resets flaggedWatched |
| `SYNC_RATIO` (anime trackers) | 0.7 | `use-resume-autosave.ts:32` | AniList/MAL sync-ready threshold |

**Recommendation for the native port**: pick one canonical "watched" threshold — 0.85
(`WATCHED_RATIO`/`END_RATIO`) is the most broadly used. Upstream itself is inconsistent
across 5+ different ratios for different purposes; don't try to replicate all of them
faithfully unless parity with every upstream edge case matters.

### 3.4 Building the Stremio library item (movie vs. episode)

`writeLibraryItem`, `src/views/player/hooks/use-stremio-sync.ts:350-504`. Same function for
movie and episode; differs only in `video_id`/`type`:

- `video_id`: via `videoIdFor(s, canonicalId)` (`:297-308`) — prefers the stream's threaded
  id (`s.episode.videoId ?? s.episode.kitsuStreamId`) if scheme matches `cid`; else for
  `tt`-ids with resolved imdb season/episode builds `` `${cid}:${imdbSeason}:${imdbEpisode}` ``;
  else `` `${cid}:${season}:${episode}` ``. For movies, `video_id = canonicalId`
  (`:299-300`).
- `type`: `src.episode ? "series" : (baseType ?? (isSeries ? "series" : "movie"))` (`:491`).
- `state.timeOffset`: `finaleDone ? 0 : offsetMs` — terminal write on the series finale
  resets offset to 0 (`:405-412,417`).
- `state.flaggedWatched`: `1` once `watchedRatio > CREDITS_RATIO(0.9)` and not
  errored/duration-shrunk (`nowFlagged`, `:400-404,420`); else carries forward unless
  episode changed or "meaningful resume" (≥45s, <90%) reset it to 0 (`effPrevFlagged`,
  `:404`).
- `state.timesWatched`: +1 only on transition into `nowFlagged && effPrevFlagged===0`
  (`:419`).
- `state.overallTimeWatched`: `prevOverall + (videoChanged ? prevTimeWatched : 0)`
  (`:418`).
- `state.watched` (episode bitfield string): 3-way freshest-wins merge of cache
  (`freshestWatched`), queued-but-unsent (`queuedWatched`), and a live strict fetch,
  picking newest mtime (`:456-486`); computed only when `isSeries && !isAnimeWrite`.
- Written via `cloudLibraryPut` (`stremio-write-queue.ts:51`) → `libraryPut`
  (`stremio.ts:243`, POSTs `datastorePut`); failures enqueue to the retry queue.
- Anime-scheme ids (`kitsu:`/`mal:`/`anilist:`/`anidb:`) are blocked from cloud writes
  except removals (`stremio.ts:244`).
- Guard: skipped entirely for stub-length content —
  `snap.durationSec>0 && snap.durationSec<STUB_MAX_SEC(150)` (`:360`).

### 3.5 Trakt / Simkl scrobble hooks

`src/lib/trakt/scrobble-hook.ts` (`useTraktScrobble`) and `src/lib/simkl/scrobble-hook.ts`
(`useSimklScrobble`), both invoked unconditionally (gated internally by `isConnected`) from
`src/views/player/hooks/use-player-media.ts:290-291`. Structurally identical; Simkl uses
`WATCHED_MARK_PCT = SIMKL_WATCHED_RATIO*100 = 90` (`simkl/scrobble-hook.ts:27-28`). Trakt:
- `status==="playing"`, no scrobble sent yet → `scrobble("start", {metaId, episode,
  progress})` (`:105-107`).
- `status==="paused"` after "start" → `scrobble("pause", ...)` (`:108-110`).
- `status==="ended"` (duration≥150s) → `scrobble("stop", {..., progress: endPct})`
  (`:88-99`).
- Unmount / episode-identity change / `pagehide`: `"stop"` if accumulated progress ≥90,
  else `"pause"` (`:44-56` pagehide beacon via raw `fetch(..., keepalive:true)`; `:150-175`
  unmount; `:59-75` identity-change).
- Seek-resync loop (1s interval while state="start") detects seeks (`|Δpos|>8s` in a burst)
  and re-sends `"start"` at most every 30000ms (`:126-149`).
- `STUB_MAX_SEC = 150` — no scrobbles below that duration.

### 3.6 What upstream reads on resume (local/cloud merge)

`resolveStartMs`, `src/lib/player/resume-start.ts:94-146`:
1. Reads local `readResumeEntry(metaId, season, episode)` → `local` ms.
2. No `authKey` → returns local immediately (`:99`).
3. Else fetches remote library item(s) via `resumeLibraryGetOne` (30s-TTL cache per
   account/id, `:44-64`) for both the raw meta id and, if imdb-verified, the resolved imdb
   id (`lookupIds`, `:29-37`).
4. `matchesEpisode` confirms season/episode via `openingVid`, `state.video_id`, or
   `state.season/episode` (`:107-115`).
5. If remote `timeOffset>0`: remote wins (written back to local via `saveResumeBatch`,
   returns `fromRemote:true`) if `remoteMtime > localEntry.t` OR remote ms ≥ effective local
   ms (local `pct` scaled against remote duration when durations differ); `finished` flag
   set via `RESTART_THRESHOLD(0.8)`/`flaggedWatched` (`:117-143`).
6. Otherwise falls back to local ms (`:144,146`).

---

## 4. SUBTITLES (`src/lib/subtitles/*`)

### 4.1 Sources

**OpenSubtitles v3** (`src/lib/subtitles/providers/opensubtitles-v3.ts`):
- `const ENDPOINTS = ["https://opensubtitles-v3.strem.io"]` (`:10`).
- Call: `` `${base}/subtitles/${type}/${id}.json` `` (`:34`), `type` = `"movie"|"series"`,
  `id` = `tt1234567` or `tt1234567:season:episode` for series (`:22-31`). Requires
  `imdbId`; returns `[]` otherwise (`:52-55`). Header `{Accept: "application/json"}`.
- Dedup across endpoints by `` `${lang}|${url}` `` while merging (`:66`). Result `id` =
  `` `os3:${s.id ?? s.url}` ``, synthesized title `` `OpenSubtitles V3 #{n}` `` (per-language
  counter) (`:72-90`).

**Wyzie** (`src/lib/subtitles/providers/wyzie.ts`):
- `const ENDPOINT = "https://sub.wyzie.io/search"` (`:5`).
- Params (`:29-39`): `id` = `tt`-prefixed imdbId, else `tmdbId`, else `query=title` (else
  returns `[]`); `season`, `episode`; **`source=all`** (always, verbatim); `language` =
  comma-joined normalized preferred langs, if given.
- `hearingImpaired = r.isHearingImpaired || r.hi || false` (`:75`).

**Addon subtitles** (`src/lib/subtitles/providers/addons.ts`):
- Per-addon URL: `` `${transportBase}/subtitles/${type}/${id}${extra}.json` ``
  (`:114-115`); `transportBase` strips `/manifest.json` and trailing `/` (`:33-35`).
- `id` from `contentId()`: prefers `q.stremioId`, else `tt`-prefixed imdbId; appends
  `:season:episode` for episodes (`:37-47`).
- `extra` = a `/videoHash=...&videoSize=...&filename=...` path segment when present,
  URL-encoded (`:86-92`).
- Only addons declaring a `"subtitles"` resource (or matching by id-prefix priority
  `["kitsu","mal","anidb","anilist","tt","tmdb"]`) are queried (`:49,58-84`).

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

`langScore(lang, preferred)` (`:307-319`): `0` if `preferred` empty; exact normalized-lang
match → `(preferred.length - exactIdx) * 2`; base-subtag-only match (e.g. `pt` vs `pt-BR`)
→ `(preferred.length - baseIdx) * 2 - 1`; no match → `-1`. Earlier entries in the preferred
list always outscore later ones.

`pickBestTrack(tracks, preferred)` (`:328-345`): skips `forced` tracks and any with
`langScore < 0`; picks max of `langScore*10 + (default?1:0)`.

Full auto-selection order, `rankSubtitleCandidates()` (`candidate-ranking.ts:151-206`):
filters out `langScore<0` (when preferred given), `forced`/`foreignOnly`, explicit
episode-mismatch, and `confidence === "incompatible"`; sorts by exact moviehash match →
`langScore` → strong provider confidence (`exact`/`high`) → provider match score → explicit
episode rank → local stream-match confidence/sourceRank/score → timing-status rank
(`aligned > fixed-offset > drifting > unmeasurable`) → weak provider confidence → provider
score → machine-translated penalty → `fromTrusted` boost → rating score/count → downloads
→ stable tiebreak key.

### 4.3 Dedupe (`src/lib/subtitles/search.ts`)

`deduplicateAndRankSubtitleResults()` (`:266-283`) groups by key
`` `${normalizeLang(lang)}|${url}|${title||""}|${format||""}` `` (`:270`), after dropping
unsafe URLs (`isSafeProviderSubtitleUrl`, `provider-url.ts:96`). `mergeDuplicateGroup()`
(`:242-262`) picks the best-ranked member of a duplicate group via
`compareDuplicateCandidates` (exact moviehash → has `downloadAuth` → provider confidence →
provider score → local match rank → **"metadata richness"** — count of non-null fields,
`metadataRichness()`, `:196-205` → source priority → stable key), then fills any `null`
field on the winner from the losers, and unions `providerMatch.reasons`/`matchedBy` across
the whole group. A separate `interleaveBySource()` step re-orders the deduped list for
**menu display only** — the comment at `candidate-ranking.ts:150` is explicit that
auto-selection order and menu presentation order are deliberately different passes.

### 4.4 Encoding detection (`src/lib/subtitles/encoding.ts`)

`decodeSubtitleBytesDetailed(bytes, options)` (`:233-369`):
1. **BOM check**: `FF FE`→`utf-16le`, `FE FF`→`utf-16be`, `EF BB BF`→`utf-8` (`:238-244`).
2. Strict-UTF-8 probe (`TextDecoder("utf-8", {fatal:true})`) sets `validUtf8`.
3. No BOM: builds candidate list `[declaredEncoding?, "utf-8", ...fallbacks]`, fallbacks =
   `["windows-1256","iso-8859-6","windows-1252"]` for Arabic-tagged subs else
   `["windows-1252","windows-1256","iso-8859-6"]` (`:45-46,274-291`). Each is scored by
   `assessCandidate()`.
4. `assessCandidate()` (`:150-204`) scores 0-1 from: printable-char ratio (+), U+FFFD
   replacement-char penalty, control-char penalty, mojibake regex penalty
   (`/(?:Ã.|Â.|â.|Ø.|Ù.)/gu`), SRT/ASS timestamp-pattern bonus, declared-encoding-match
   bonus, valid-UTF-8 bonus, and for Arabic-tagged content an Arabic-script-ratio +
   hardcoded lexical-plausibility bonus/penalty (`COMMON_ARABIC_WORDS`/`_SEQUENCES`,
   `:47-101`).
5. Selection: `validUtf8` → always pick the `utf-8` candidate; else pick highest score.
6. `HEALTHY_SCORE = 0.72` (`:43`); `healthy` = no ambiguous-legacy flag AND `score >= 0.72`
   AND zero replacement/control chars (`:346-350`).
7. **Ambiguous-Arabic-legacy check**: if `windows-1256` and `iso-8859-6` candidates decode
   to different text but score within `0.012` of each other, flags
   `ambiguous-legacy-encoding` (`:306-320`).

Diagnostic codes: `bom-detected, invalid-utf8, ambiguous-legacy-encoding,
declared-encoding-unavailable, legacy-encoding-selected, replacement-characters,
control-characters, low-decode-health` (`:6-19`).

### 4.5 Style settings keys and defaults

Defaults (`src/lib/settings/defaults.ts:265-293`), types (`src/lib/settings/types.ts:
319-353`):
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

All applied via Tauri `invoke("mpv_set_property", {name, value})` — **one of the
Tauri-coupled call sites a native port must replace** (see §6).

### 4.6 Dual subtitles (secondary track)

State: `src/lib/player/secondary-sub.ts` — a module-level external store (not React state),
type `SecondarySubChoice = string | null | "auto"` (`:3`), default `"auto"`.

Application: `src/views/player/hooks/use-secondary-sub.ts` — on source change, resets
choice to `"auto"` (`:26-29`). If choice is `"auto"`, calls `autoPick(tracks, lang,
primaryId)` which excludes the primary track and calls `pickBestTrack(pool, [lang])`
(`:6-9,36`); else uses the explicit choice. If the target differs from the primary track,
calls `bridge.setSecondarySubtitleTrack(target)` (`:37-44`).

**Not found**: a dedicated "secondary subtitle language" Settings key — the `lang` driving
auto-pick is passed in by the hook's caller, not read from `settings` inside this file, and
no `secondarySub*` key surfaced in `settings/types.ts`. `TrackInfo.secondary?: boolean`
flags the active secondary track (§5.6); `PlayerSnapshot.secondarySubText: string` carries
the rendered secondary-cue text for overlay rendering (default `""`).

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

### 5.1 Resume `Entry` (unexported — no type literally named `ResumeEntry` exists in
source; this is the canonical resume-record shape) — `src/lib/resume.ts:5`
```ts
type Entry = { ms: number; t: number; s?: number; pct?: number; source?: ExternalCwSource };
// ExternalCwSource — src/lib/stremio.ts:16
export type ExternalCwSource = "simkl" | "trakt";
```

### 5.2 `PlaybackEntry` — `src/lib/playback-history.ts:4-18`
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

### 5.3 `LocalCwEntry` — `src/lib/local-cw.ts:7-19`
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

### 5.4 `LibraryItem` (public shape) — `src/lib/stremio.ts:18-45`
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

`StremioLibraryItemState` / `StremioLibraryItem` — the exact shape PUT to Stremio's cloud
datastore — `src/views/player/hooks/use-stremio-sync.ts:317-343`:
```ts
type StremioBehaviorHints = {
  defaultVideoId: string | null;
  featuredVideoId: string | null;
  hasScheduledVideos: boolean;
  [extra: string]: unknown;
};

type StremioLibraryItemState = {
  lastWatched: string | null;
  timeWatched: number;
  timeOffset: number;
  overallTimeWatched: number;
  timesWatched: number;
  flaggedWatched: number;
  duration: number;
  video_id: string | null;
  watched: string | null;
  lastVidReleased: string | null;
  noNotif: boolean;
};

type StremioLibraryItem = {
  _id: string;
  name: string;
  type: string;
  poster: string | null;
  posterShape: "square" | "landscape" | "poster";
  removed: boolean;
  temp: boolean;
  _ctime: string | null;
  _mtime: string;
  state: StremioLibraryItemState;
  behaviorHints: StremioBehaviorHints;
};
```

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
Storage: `localStorage["harbor.player.prefs.v1"]`, a `Record<metaId, PerShowPrefs>`, capped
at `MAX_ENTRIES = 200` (LRU-evicted by `updatedAt`) (`player-prefs.ts:1-2,28-34`).

### 5.6 Player state — `PlayerSnapshot`, `PlayerSource`, `Chapter`, `TrackInfo`
(`src/lib/player/bridge.ts`)
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
`TrackInfo` (`bridge.ts:7-40`, fields relevant through the audio/subtitle surface — the file
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

### 5.7 Subtitle track / candidate types

See §4.7 for `SubResult`, `SubtitleLoadMetadata`, `SubSearchQuery` (kept there, next to the
provider/ranking logic they describe, to avoid duplicating a ~130-line block).

### 5.8 Buffer profile type — `src/lib/player/buffer-profile.ts:11-17`
```ts
export type BufferProfile = {
  cacheSecs: number;
  readaheadSecs: number;
  maxBytes: number;
  maxBackBytes: number;
  pauseWaitSecs: number;
};
```

### 5.9 Misc small types
```ts
// src/lib/player/subtitle-selection.ts:1-12
export type SubtitleSelectionOrigin = "manual" | "automatic" | "restore";
export type SubtitleSelectionRequest = Readonly<{
  mediaRevision: number;
  selectionRevision: number;
  requestedId: string;
  previousId: string | null;
}>;
export type SubtitleSelectionSettlement =
  | { current: false }
  | { current: true; selectedId: string | null };

// src/lib/player/secondary-sub.ts:3
export type SecondarySubChoice = string | null | "auto";

// src/lib/player/anime4k-modes.ts:1-2
export type Anime4kMode = "A" | "B" | "C" | "AA" | "BB" | "CA";
export type Anime4kTier = "hq" | "fast";
```

---

## 6. GOTCHAS FOR A NATIVE LIBMPV PORT

### 6.1 Core bridge: everything goes through Tauri IPC, not a library call

The entire mpv control surface is a thin RPC client over Tauri's `invoke`/`listen`, talking
to the Rust backend in `src-tauri/src/mpv.rs`. **This is the single biggest thing to
replace** — every mpv command/property set in `src/lib/player/mpv.ts` is
`await invoke("mpv_xxx", {...})` (e.g. `mpv_start` L918, `mpv_set_property`
L231/326/460/542/…, `mpv_command` L267/502/540/883/902, `mpv_sub_add` L388/1236,
`mpv_set_geometry` L460, `mpv_save_screenshot` L1335, `mpv_release_media` L1389,
`mpv_stop` L601/883/1397/1402/1411). Native port: replace this whole call surface with
direct MPVKit `mpv_set_property`/`mpv_command` calls — 1:1 mapping of command/property names
is straightforward, but the async invoke/catch-swallow error pattern (nearly every call does
`.catch(() => {})`) should be replaced with real Swift error handling. — **reimplement in
Swift/MPVKit**

mpv events (position, pause, end-file, property-change) arrive as Tauri `listen()` events in
`mpv.ts` (`import { listen } from "@tauri-apps/api/event"`, `mpv.ts:9`) rather than a
libmpv event-loop callback — native port drives this from `mpv_wait_event`/MPVKit's event
stream directly. — **reimplement**

### 6.2 Video surface embedding: transparent WebView + native window geometry sync
(Tauri-only, drop entirely)

Desktop mpv is NOT rendered inside the DOM. It's a separate native surface positioned
*underneath* a transparent Tauri WebView, kept in sync by polling the DOM overlay rect and
pushing it to Rust:
- `src/views/player/hooks/use-mpv-embed.ts:9-15` sets
  `document.documentElement.dataset.mpvEmbed = "1"` to make the webview background
  transparent (`needsTransparentWebView = isLinuxDesktop() || isMacDesktop()`), only when
  `engine === "mpv"` and `settings.playerMpvEmbed`.
- `use-mpv-embed.ts:19-30` imports `@tauri-apps/api/window` `getCurrentWindow()` and
  subscribes to `win.onMoved`/`win.onResized` to re-sync an overlay
  (`modalOverlaySync()` from `src/lib/modal-overlay.ts`).
- `src/lib/player/mpv.ts:440-470` runs a debounced (40ms, `mpv.ts:465`) rect-tracking loop
  that calls `opts.getEmbedRect()` and, on change, calls
  `invoke("mpv_set_geometry", { geom: r })` (`mpv.ts:460`) to tell the Rust side where to
  place the native mpv render surface in window-relative CSS pixels. Skipped entirely on
  Linux (`isLinuxDesktop()` short-circuit, `mpv.ts:440`).
- `src/lib/modal-overlay.ts:1-2,24-27` is a companion Tauri IPC channel
  (`modal_overlay_open/close/emit_state/emit_action`, plus `modal://show`/`modal://closed`
  events) used to punch through the transparent webview so native modal chrome doesn't get
  occluded by mpv's surface.

None of this exists on tvOS: MPVKit renders directly into a `CAMetalLayer`/`MTKView`
(or GL) that is a normal SwiftUI/UIKit subview, so mpv IS part of the native view hierarchy
— no geometry-sync IPC loop, no transparent-webview trick, no `modal_overlay_*` channel
needed. — **drop entirely, ports as: plain SwiftUI ZStack with mpv view + overlay UI**

### 6.3 Fullscreen / window management (Tauri window API, drop)

`src/lib/fullscreen-state.ts` wraps `@tauri-apps/api/window` `getCurrentWindow()` and calls
`win.isFullscreen()/setFullscreen()` (lines 83-85, 99-105, 136-141, 169-171, 278-305), plus
`currentMonitor`/`PhysicalPosition`/`PhysicalSize` to compute borderless-fullscreen bounds
per monitor, and two Rust-side commands `invoke("window_fullscreen_enter")` (L210, L229) /
`invoke("window_fullscreen_exit", {...})` (L254). `src/views/player/hooks/use-fullscreen.ts`
is just a thin React hook over that module (subscribe/enter/exit/toggle, L1-11). tvOS apps
are always fullscreen/single-window. — **drop entirely**

### 6.4 Picture-in-picture (`use-pip-mode.ts`) — Tauri-window-based, needs full rework

`src/views/player/hooks/use-pip-mode.ts:15` gates on `"__TAURI__" in window ||
"__TAURI_INTERNALS__" in window`; on PiP enter/exit it dispatches synthetic
`resize`/`harbor:mpv-refresh-geom` DOM events (L22-23) and calls
`invoke("hdr_overlay_sync")` (L25) — i.e. PiP is a second OS window Tauri manages, not a
video-layer PiP API. tvOS has no OS-level PiP surface for third-party apps. —
**drop / needs-rework, no tvOS equivalent**

### 6.5 System power/sleep inhibit — needs native replacement

`src/views/player/hooks/use-power-inhibit.ts:7-11` calls
`invoke("power_inhibit", { on: playing })` to stop the OS from sleeping while media plays,
and un-inhibits on unmount/pause. tvOS equivalent:
`UIApplication.shared.isIdleTimerDisabled = true` while playing. —
**reimplement (trivial)**

### 6.6 Frame grab / clip / GIF recording — Tauri filesystem + sidecar ffmpeg, needs full
rework

- `src/lib/player/capture-path.ts:38` `captureDir()` resolves an OS save directory via
  Tauri's fs/path APIs.
- `src/views/player/hooks/use-frame-grab.ts` → `mpv_save_screenshot` (`mpv.rs:1335`) writes
  a file via the Rust mpv backend directly to disk.
- `src/views/player/hooks/use-clip-recorder.ts:14` gates on `"__TAURI_INTERNALS__" in
  window`; fixed `CLIP_SECONDS = 30` (L14), likely shells out to an ffmpeg sidecar
  (`src/lib/ffmpeg-install.ts`, referenced from `use-cast-session.ts:9`).
- `src/views/player/hooks/use-gif-recorder.ts:16` same pattern, `MAX_SECONDS = 30` (L16),
  drives `invoke("mpv_gif_start")` (L78) / `invoke("mpv_gif_abort")` (L99, L114).

tvOS has no arbitrary filesystem access and can't bundle/shell an ffmpeg binary under
sandboxing. Needs its own capture path via mpv render-target readback plus AVFoundation
(`AVAssetWriter`) and the Photos framework for saving. — **needs-rework, no direct port**

### 6.7 Casting (Chromecast/DLNA-style) — desktop/browser feature, out of scope

`src/views/player/hooks/use-cast-session.ts` imports `src/lib/cast.ts`
(`castLoad/castPause/castPlay/castSeek/castStatus/castStop`, L9-19) plus `VideoAudioCast`
and `ffmpegInstallStep` (L9) for transcode profiles — Harbor acting as a cast sender,
dependent on desktop transcoding + Tauri networking. tvOS natively supports AirPlay as a
receiver already. — **out of scope / needs-rework if kept**

### 6.8 Watch-together room sync — pure WebSocket, ports cleanly

`src/views/player/hooks/use-room-sync.ts` and `src/lib/together/client.ts` are plain
state-machine logic over a raw `WebSocket` (`client.ts:32,274` `new WebSocket(...)`,
readyState checks at L130/149/189/241/247/253/406/421) — no Tauri or DOM dependency. Sync
tuning constants (`HOST_HEARTBEAT_MS`, `SEEK_APPLY_DEBOUNCE_MS`, `SYNC_DRIFT_TOLERANCE_S`,
`SYNC_MAX_AGE_S`, `SYNC_PLAY_LOOKAHEAD_S`, `SYNC_SEEK_JUMP_S`, `SYNC_SUPPRESS_MS`, imported
in `use-room-sync.ts:9` from `../player-utils`) are portable as-is. — **ports as-is
(rewrite the WebSocket client in Swift `URLSessionWebSocketTask`, keep the algorithm)**

### 6.9 Webview memory pressure trimming — Tauri/webview-only, drop

`src/views/player/hooks/use-webview-memory.ts:9-15` runs a 60s interval
(`TRIM_INTERVAL_MS = 60000`) calling `pulseWebviewMemoryLow()`/`runMaintenance(true)` to
work around WebView memory growth — no counterpart in a native app with no embedded web
renderer. — **drop entirely**

### 6.10 Content-advisory "ignored" flags — localStorage, needs native replacement

`src/lib/player/content-advisory-ignore.ts:10` reads
`JSON.parse(localStorage.getItem(KEY) ?? "[]")`. Trivial to port to `UserDefaults`/a JSON
file. — **reimplement via UserDefaults**

### 6.11 Persistence in general — profile-suffixed localStorage keys, no native analog

Every store in §3.1/§5.5 (`harbor.resume`, `harbor.playback-history.v1.<profileId>`,
`harbor.localcw.v1.<profileId>`, `harbor.moviewatched.v1.<profileId>`,
`harbor.player.prefs.v1`, `harbor.stremio.write-queue.v1`) is a plain `localStorage` JSON
blob, keyed by a profile id resolved from a separate `harbor.profiles.v1` store. A native
port needs its own small key-value store (e.g. `UserDefaults` for small blobs, or a JSON
file / SQLite for the larger/rotating ones) with the same per-profile keying scheme and the
same TTL/cap/eviction rules reproduced explicitly, since there's no drop-in
`localStorage` equivalent. — **reimplement (straightforward, but don't skip the eviction
rules — they bound file/UserDefaults size)**

### 6.12 `pagehide`/`beforeunload` flush hooks — no tvOS equivalent, use scenePhase

Several places force a final persistence/scrobble flush on `pagehide`/`beforeunload`
(`use-resume-autosave.ts:262-286`, `use-stremio-sync.ts:271-294`,
`trakt/scrobble-hook.ts:44-56` via `fetch(..., keepalive:true)`). tvOS has no page-lifecycle
events; the equivalent hook point is `ScenePhase` transitioning to `.background`/
`.inactive` (SwiftUI `@Environment(\.scenePhase)`) or `UIApplication` lifecycle
notifications — a beacon-style `fetch(keepalive:true)` also has no direct analog and should
become a synchronous best-effort write before the app suspends. — **reimplement using
scenePhase**

### 6.13 DOM/focus-driven chrome state — needs a SwiftUI focus re-implementation

All of §1's chrome/panel/rail navigation (`bp-player-key.ts`, `bp-back.ts`,
`setBpPlayerKeyHandler`, `pushBpBack`/`runBpBack`, `data-bp-autofocus`/`data-bp-focusable`
attributes referenced throughout `src/views/big-picture/player/*`) is a hand-rolled
DOM-attribute-driven spatial-navigation and key-interception system layered on top of
browser keyboard events. tvOS's native focus engine (`@FocusState`, `.focusable()`,
`onMoveCommand`/`onExitCommand`) is a different model entirely (automatic geometry-based
focus movement vs. this codebase's explicit registries) — the *behavior* (LIFO handler
stacks for Back, chrome auto-hide timers, "peek" state) should be preserved, but the
mechanism must be rebuilt from scratch in SwiftUI. — **reimplement (design work, not a
mechanical port)**

### 6.14 Not found

- No direct `localStorage`/`sessionStorage`/`indexedDB` usage found in core `use-*`
  playback hooks or `src/lib/player/*.ts` beyond `content-advisory-ignore.ts` (§6.10).
- No `always_on_top`/`alwaysOnTop` window flag usage scoped to the player.
