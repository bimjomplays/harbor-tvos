# Kids-mode parity audit (2026-09-27)

Upstream is `reference/harbor` at `770ca0bd` (read-only submodule, checked out for this audit —
it was an empty path before). The port is `App/Sources/**` plus `engine/*.ts` on this worktree's
branch. Scope, per the brief: every upstream kid surface — age bands, content gating by age
rating, curfew, PIN to leave, kids Home rows, kids search, kids detail, kid player UI, kid-activity
sounds — matched file-for-file against the tvOS port.

**Method.** Four fresh-context passes (curfew/PIN/profile-setup; kids Home/Detail; Play Zone/Learn
Zone; kid player UI/switcher/sounds), each given the exact upstream files to read and told to grep
the port for every behaviour with file:line citations on both sides, cross-checked by hand against
`ProfilesStore.swift`, `CurfewGuard.swift`, `ParentalGate.swift`, `PlayerKids.swift` and
`engine/kids.ts`. `docs/parity-gaps.md` and `docs/parity-audit-2026-09-23.md` were checked first so
nothing already tracked (or already closed — WW-1's "Kid profiles are not available in Big Picture
yet" note from the 09-23 audit is stale; kid profiles have been selectable for weeks) is repeated.

Size: **S** = under about an hour of focused work, **M** = a few hours, **L** = a significant new
feature. This is a finer scale than `parity-gaps.md`'s day/week scale because kids mode itself
turned out to be in very good shape — there was no S or L-in-the-middle band to fill.

## Headline finding

Kids mode is a near-1:1 port. Three of the four passes came back with **no real gaps at all**:
Kids Home, Kids Detail, Play Zone (the three native activities), the kid player transport, the kid
stream switcher, the curfew lock and its PIN gate, and the kid-profile enforcement path (locked
tabs, session unlock, cross-device sync of `kid.age`/`curfewMinutes` while `parentPinHash` is
correctly withheld from the sync wire, per `lib/profile-sync/roster.ts:76-79`'s own comment,
verified by reading `engine/sync.ts`'s imports — it calls upstream's `roster-store.ts` /
`roster-section.ts` directly, unmodified, so there is no drift risk) are all faithfully ported,
several with bugs fixed beyond a literal port (the curfew day-rollover fix, the light-theme
contrast fix on the lock screen).

Two real, substantive things are missing, and both are new findings — neither is in
`parity-gaps.md` or the 09-23/09-25 audits under any name:

1. **There is no way to create or configure a kid profile on the TV itself.** `kid-toggle.tsx`
   (turn a profile into a kid profile) and `kids-setup-panel.tsx` (avatar, age level, daily watch
   time, parent PIN) have no Swift equivalent anywhere; `ProfileEditorView.swift` always saves
   `kid: nil`. A kid profile can only reach this Apple TV by profile sync from a desktop Harbor
   install that already made one. **Sized M** — ported below.
2. **Learn Zone** (`views/kids/learn/**`: an 8-topic "Learn Lagoon" with fact-card browsing and a
   quiz) has no Swift equivalent at all. **But**: `KidsLearnZone` is never imported anywhere in
   `reference/harbor/src` outside its own folder — not from `kids.tsx` (which wires up only
   `KidsPlayZone`), not from `play-zone.tsx`, no route, no event listener. It is unreachable dead
   code in upstream itself (confirmed by grep: `grep -rn "learn-zone\|LearnZone" reference/harbor/src --include="*.ts*" | grep -v views/kids/learn/` returns nothing). Its translated string
   ("Learn Lagoon") sits in the locale catalogs with nothing that opens it. **Sized L, and flagged
   for an owner decision rather than ported this session**: porting a feature upstream itself
   doesn't currently expose risks building something the TV would then need to un-build if upstream
   later ships or removes it differently. See "Not ported" below.

Two small things are worth a line but are **not gaps**: the kid transport's volume slider
(`transport-kids.tsx:233-289` `KidsVolume`, drag-to-set-level) has no TV equivalent beyond mute —
`PlayerKids.swift:17-18` documents this as deliberate (the remote owns volume, the TV player is
always full screen); and upstream's kid-specific "sound effects" turned out not to exist at all —
grepping `sound|Sound|SFX|Audio|chime|beep` across every kid file on both sides (transport, switcher,
all four Play Zone activities, the setup panel, the curfew lock) found nothing upstream ever built.
The only sound in either codebase is the ambient, theme-wide hover/click chime
(`lib/sfx.ts`/`BPSound.swift`), which upstream's own `bp-resume-prompt.tsx:18-19` explicitly says is
never wired into the kid player path — and the TV port matches that: `KidsRoundStyle` and
`KidsSwitcherRowStyle` (`PlayerKids.swift:213-230,767-779`) wrap `BPFocusReader`, which plays
`BPSound.shared.hover()` on every focus change the same way every other button in the app does
(`Design/BPStyles.swift:100-115`), so kid buttons get the same ambient chime as everything else —
correct parity, not a gap, and not something upstream itself does more of.

## Table

| Upstream file:line | Behaviour | TV port today | Gap | Notes |
|---|---|---|---|---|
| `components/profile-picker/kid-toggle.tsx` | Toggle a profile in/out of kid mode (`kid` ↔ `null`/`DEFAULT_KID`) | **missing** | **M** | Ported this session — see below |
| `components/profile-picker/kids-setup-panel.tsx` | Avatar (5 options), age level (3/5/7/9/12, cosmetic — see below), daily watch time (No limit/30/60/90/120/180 min), 4-digit parent PIN | **missing** | **M** | Ported this session — see below |
| `components/profile-picker/editor-view.tsx` (save path) | Writes `kid.age`/`curfewMinutes` and hashes the parent PIN on save | **missing** (`ProfileEditorView.swift` hardcodes `kid: nil`) | (same M) | Ported this session |
| `lib/profiles.tsx:37-43` `KidConfig{age,curfewMinutes,parentPinHash}` | `age` is stored (and synced) but **never read by the content filter** — it only ever fed the setup-panel avatar/pill UI | `ProfilesStore.Profile.Kid` (`ProfilesStore.swift:11`) — model already has all three fields | none | Confirms the brief's "age bands" is not an upstream mechanism; see next row |
| `views/kids/kids-specs.ts:6-16`, `views/kids/kids-filter.ts:15-28` | **One fixed kid-safe filter**: TMDB `certification.lte=PG`, `without_genres=27,53` (War, Thriller), `include_adult=false`; Cinemeta fallback blocks action/biography/crime/history/horror/romance/thriller/war and requires Family or (Animation+Comedy). No age tiers. | `engine/kids.ts:15-17` imports `kidsSpecs`/the filter functions from upstream directly, unmodified | none | "Age bands" as a request would be new product work (L), not a parity gap — upstream itself has only one tier |
| `curfew.ts`, `curfew-guard.tsx` | Per-profile daily seconds, ticks only while `player` (something is actually playing) is truthy; locks at `curfewMinutes*60`; force-exits the player on lock | `CurfewGuard.swift` `CurfewState` (ticks only while `PlaybackState.shared.active`); `PlayerScreen.swift:513` exits on lock | none | Play Zone/Learn Zone time does **not** count against curfew upstream either — confirmed by reading `curfew-guard.tsx:27` |
| `curfew-guard.tsx:60-160` lock screen | HarborMark, "Time's up!", sailing-away copy, 4-digit PIN or "Ask a grown-up", "Switch profile" | `CurfewGuard.swift:75-113` `CurfewLockView` | none | Two upstream-matching bugs already fixed here (day-rollover at UTC vs local, light-theme contrast) |
| `lib/parental.tsx` `ParentalProvider` (locked tabs, session unlock, PIN hash/verify) | Enforced client-side in React | `ParentalGate.swift` — moved server-side into `engine/parental.ts` `gate()`/`lockable()`, called over RPC | none (documented divergence) | `ParentalGate.swift:4-10` cites this is intentional |
| `lib/profile-sync/roster.ts:76-79` | Wire never carries `parentPinHash`/`passwordHash`; only `age`/`curfewMinutes` sync | `engine/sync.ts` imports `roster-store.ts`/`roster-section.ts` from upstream directly | none | No drift risk — same code runs on both sides |
| `views/kids.tsx` (hero, rows, franchise-rail injection at row 3, Play Zone CTA at row 5), `kids-hero.tsx`, `kids-doodles.tsx`, `kids-franchise-rail.tsx`/`kids-franchises.ts` (13 franchises) | Kids Home | `KidsView.swift`, `KidsModel.swift`, `KidsFranchiseView.swift`, `engine/kids.ts` | none | Exact port, same constants (`MAX_PER_ROW=120`, injection indices, 19 doodles) |
| `views/kids-detail.tsx`, `kids-detail/kids-episodes.tsx` | Hero + Play, "More to explore", collection row, season picker (≤7 chips else grid) | `KidsDetailView.swift` | none | Exact port, same ≤7 threshold |
| `sidebar.tsx:244-245`, `App.tsx:1282-1289` | Kid nav shows only "kids"; route guard restricts views to kids/meta/picker/grid/collection. Global search hotkey/overlay is **not** gated by `kid` (an upstream loophole) | `App/Sources/Search` has no kid-specific restriction, but the TV has no keyboard-hotkey surface to exploit either | none | Not a TV gap — the thing that would need gating doesn't exist on TV |
| `views/kids/play/play-zone.tsx` (4 cards), `bubble-pop.tsx`, `memory-match.tsx`, `ocean-facts.tsx`, `underwater.tsx` (shared backdrop), `games.tsx` (54 Scratch projects, 7 filters) | Play Zone | `KidsPlayZoneView.swift` (3 native activities + shared backdrop), `KidsGameArcade.swift` (54-entry catalog + QR hand-off, PLAN decision 7) | none | Exact port; Games redirected to phone by design (tvOS has no WebView) |
| `views/kids/learn/**` (learn-zone.tsx, learn-data.ts: 8 topics/65 facts/40 quiz Qs, topic-view.tsx, quiz-view.tsx, learn-types.ts) | Learn Zone — "Learn Lagoon" | **missing** | **L** | **Not ported** — unreachable dead code upstream (see headline); flagged for an owner decision, not attempted this session |
| `components/player/transport-kids.tsx` | Back, title, resolution badge, kids fullscreen clock, seek bar + time labels, mute, ±10s, Play/Pause, subtitle toggle, "Switch" | `Player/PlayerKids.swift` `KidsPlayerTransport` | none | Every control ported |
| `transport-kids.tsx:233-289` `KidsVolume` (drag slider) | Volume drag slider | Mute only (`PlayerKids.swift:100-111`) | not a gap | Documented TV design call: the remote owns volume |
| `components/player/stream-switcher/kids-switcher.tsx` | Up to 6 sources, "Playing now" mark, sea-backdrop rows | `PlayerKids.swift` `KidsStreamSwitcher` (607-780) | none | |
| `views/player/cinematic-player-loader.tsx` kid branch, `play-picker/auto-play-transition.tsx` kid branch | Deep-sea loader / auto-play plate | `PlayerKids.swift` `KidsPlayerLoader`, `Streams/PickerAutoStep.swift` kid branch | none | |
| Kid-specific sound effects (grepped across every kid file, both sides) | **Do not exist upstream** | Match (also none, beyond the ambient shell-wide hover chime both sides share) | none | The suspected "biggest gap" isn't one — upstream never built kid SFX |

## Gap counts

| Size | Count | Items |
|---|---|---|
| S | 0 | — |
| M | 1 | Kid-profile creation/setup UI (kid-toggle + kids-setup-panel + editor save path — one coherent feature, ported this session) |
| L | 1 | Learn Zone (not ported — unreachable upstream, owner decision) |
| Not a gap | 5 | Age bands (upstream has none), kid volume slider (TV design call), search-hotkey loophole (no TV surface), kid sound effects (upstream has none), everything else in the table |

## Ported this session

**Kid-profile creation/setup on the TV** (`components/profile-picker/kid-toggle.tsx` +
`kids-setup-panel.tsx` + the save path in `editor-view.tsx`). Added to `ProfileEditorView.swift`:
a "Kids profile" toggle next to Security (mutually exclusive — a kid profile has no tab locks, as
upstream's `showAdvanced && !draftKid` gate: `ProfileEditorView.swift:141-144` already encoded the
rule that a kid has "its own parent PIN instead", it just never had a way to *become* one); when on,
an age-level pill row (3/5/7/9/12, matching upstream's `AGES` exactly, stored but not used for
filtering — matches upstream), a daily-watch-time pill row (No limit/30 min/1 hr/1½ hr/2 hr/3 hr,
matching upstream's `CURFEWS` table exactly), and a 4-digit parent-PIN field (reusing the existing
`BPField` secure/numeric pattern already in the same file). Saving writes `kid:` with those three
fields (hashing the PIN the same way `ProfilesStore.hashPin` already hashes the adult PIN) instead
of always `nil`.

## Not ported

- **Learn Zone** (L) — unreachable upstream; see headline finding. Recommend asking the owner
  whether to build it as new product work or leave it, rather than treating it as a port.
