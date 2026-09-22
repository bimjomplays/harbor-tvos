# Harbor account + profile-sync protocol reference

Reverse-engineered from `reference/harbor` (beta branch, working tree as
checked out; no `git` metadata was present in the reference checkout so no commit hash is
available). All paths below are relative to that checkout root. Every claim cites a file and line
range. Where the source did not say something, this document says "not found" rather than
guessing.

**Read this first, it corrects the task brief:** the profile-sync endpoints (`/sync/v1/state`,
`/sync/v1/push`) are **not** on `sync.harbor.site`. They hang off `HARBOR_API_BASE` (default
`https://harbor.site`) under `/themes/api`, authenticated with the same bearer token as everything
else. `sync.harbor.site` (`HARBOR_SYNC_BASE`) is a *different*, unrelated, unauthenticated service
— the anonymous subtitle-autosync "crowd database" keyed by content hash
(`src/lib/subtitles/autosync/crowd-db.ts:5,19`). The code has an explicit comment warning against
this exact confusion: "the name is a trap" (`src/lib/profile-sync/client.ts:6-10`).

---

## 1. Endpoints

All Harbor-account endpoints share one base:

```
HARBOR_API_BASE = https://harbor.site   (src/lib/config/endpoints.ts:6-9, overridable via VITE_HARBOR_API_BASE)
API = `${HARBOR_API_BASE}/themes/api`
```

There are **two parallel sign-in surfaces that write into the same client-side session
object** (`Author`/`Session` in `src/lib/theme-auth.ts`):

- **"Identity" API** — `/themes/api/identity/api/*` — used by the main Harbor-account UI
  (`src/views/account/account-auth-form.tsx`, `src/views/mobile/onboard/setup-harbor.tsx`).
  Implemented in `src/lib/account/identity.ts`, transported by `src/lib/account/client.ts`
  (`getJson`/`postJson`, base = `${API}` with path appended, so a call to
  `postJson("/identity/api/register", …)` hits `${API}/identity/api/register`
  — `src/lib/account/client.ts:6-10`).
- **"Auth" API** (legacy/"theme-author") — `/themes/api/auth/*` — used only by the theme-creator
  sign-in panel under Settings → Themes
  (`src/views/settings/theme-panel/custom-themes-section/author-account-panel/auth-form.tsx`).
  Implemented directly inside `src/lib/theme-auth.ts` (`postAuth`, `src/lib/theme-auth.ts:356-373`).

Both write through `applyAuthResult`/`setSession` in `theme-auth.ts`, so a user who signs in via
either surface ends up with one shared session, one bearer token, and one refresh token. **A
native client only needs to implement the Identity API** (`/identity/api/*`) — the Auth API exists
only for the desktop theme-marketplace login and is not part of the account/profile-sync flow a
Swift client would need to replicate, except that it is worth knowing it exists because a session
created through it has weaker properties (see the "no-refresh" note in §2).

### 1.1 Identity API — `/themes/api/identity/api/*`

All requests are JSON, `Content-Type: application/json`. Bearer-authenticated calls go through
`authenticatedFetch` (auto 401-retry with token refresh, see §2).

| Path | Method | Auth | Body | Success response | Source |
|---|---|---|---|---|---|
| `/identity/api/register` | POST | none | `{ username, password }` | `{ token, refresh, user, recoveryCode }` | `src/lib/account/identity.ts:13-22` |
| `/identity/api/login` | POST | none | `{ username, password }` | `{ token, refresh, user }` | `src/lib/account/identity.ts:24-29` |
| `/identity/api/recover` | POST | none | `{ username, recoveryCode, password }` | `{ token, refresh, user, recoveryCode }` | `src/lib/account/identity.ts:31-45` |
| `/identity/api/password/set` | POST | bearer | `{ password }` | `{ user }` | `src/lib/account/identity.ts:51-58` |
| `/identity/api/me` | GET | bearer | — | `{ user }` | `src/lib/account/identity.ts:60-65` |
| `/identity/api/token/refresh` | POST | none (refresh token is the credential) | `{ refresh }` | `{ token, refresh }` | `src/lib/theme-auth.ts:301-332` |
| `/identity/api/stremio/loopback/start` | POST | bearer | `{}` | `{ state, callbackUrl }` | `src/lib/account/stremio-link.ts:5,11` |
| `/identity/api/stremio/link` | POST | bearer | `{ state, mode: "link", authKey }` | `{ token, refresh, user }` | `src/lib/account/stremio-link.ts:12-17` |
| `/identity/api/stremio/unlink` | POST | bearer | `{}` | `{ user }` | `src/lib/account/stremio-link.ts:29-32` |

Exact request/response types, quoted verbatim from `src/lib/account/identity.ts:10-11` and
`src/lib/account/stremio-link.ts:5-6`:

```ts
type AuthResult = { token: string; refresh: string; user: RawUser };
type AuthResultWithCode = AuthResult & { recoveryCode: string };

type LoopbackStart = { state: string; callbackUrl: string };
type LinkResult = { token: string; refresh: string; user: RawUser };
```

`RawUser` (`= Author`, `src/lib/theme-auth.ts:59-73`):

```ts
export type Author = {
  id: string;
  username: string;
  avatar?: string | null;
  handle?: string | null;
  handleAuto?: boolean;
  handleChangeAvailableAt?: string | null;
  verified?: boolean;
  stremioLinked?: boolean;
  discordLinkMethod?: string | null;
  discordUsername?: string | null;
  badges?: AuthorBadge[];
};
```

Note `avatar` on the wire is a path; the client absolutizes it against `HARBOR_API_BASE` unless it
already starts with `http` (`src/lib/theme-auth.ts:79-82`).

Error envelope for all `/themes/api/*` calls (both identity and social/sync clients):
`{ error?: string, code?: string, message?: string }`, non-2xx throws an `Error` with
`.status` = HTTP status, `.code` = `code`, `.reason` = `message`
(`src/lib/account/client.ts:12-24`; `src/lib/social/client.ts:13-24` — same shape but also attaches
the raw body as `.body`, used by profile-sync to read a rejected key, see §4).

Known error `code` / `reason` values, quoted from `src/lib/account/error-messages.ts:8-48`:

```ts
const BY_CODE = {
  username_taken, bad_credentials, banned, rate_limited, auth_required,
  recovery_invalid, refresh_invalid, handle_locked, handle_reserved,
  handle_too_short, handle_too_long, handle_invalid, handle_taken,
  handle_cooldown_other, handle_cooldown, stremio_already_bound,
  stremio_key_invalid, stremio_anonymous, stremio_unreachable,
  challenge_invalid, password_required, no_image, bad_image, slow_down,
  blocked_text, password_too_short,
} // (values are the human-facing strings; keys are the codes)

const BY_REASON = {
  password_too_short, "too-short", invalid, reserved, taken, profanity, "max-length",
}
```
A `code === "validation"` response is expected to also carry a `reason` from `BY_REASON`
(`src/lib/account/error-messages.ts:100-103`). `refresh_invalid` on `/identity/api/token/refresh`
specifically means the session has ended — see §2.

### 1.2 Handle API — `/themes/api/account/handle/*`

| Path | Method | Auth | Query/Body | Response | Source |
|---|---|---|---|---|---|
| `/account/handle/available?h=<handle>` | GET | none | — | `HandleCheck` | `src/lib/account/handle.ts:30-35` |
| `/account/handle/claim` | POST | bearer | `{ handle }` | `{ user }` | `src/lib/account/handle.ts:37-41` |

```ts
export type HandleState = "available" | "taken" | "reserved" | "invalid" | "too-short";
export type HandleCheck = { state: HandleState; reason?: string; suggestions?: string[] };
```
Handles are lower-cased client-side before submit (`normalizeHandle`,
`src/lib/account/handle.ts:15-17`); local validation (min 3 / max 24 chars, `[a-z0-9-]`, no
leading/trailing/double hyphen, at least one letter) happens before ever calling the server
(`src/lib/account/handle.ts:19-28`) and short-circuits `handleAvailable`.

### 1.3 Themes API — `/themes/api/auth/*` (legacy "theme author" identity)

| Path | Method | Auth | Body | Response | Source |
|---|---|---|---|---|---|
| `/auth/register` | POST | none | `{ username, password }` | `{ token?, refresh?, user, recoveryCode }` | `src/lib/theme-auth.ts:375-384` |
| `/auth/login` | POST | none | `{ username, password }` | `{ token, refresh?, user }` | `src/lib/theme-auth.ts:386-391` |
| `/auth/logout` | POST | bearer | `{}` | discarded | `src/lib/theme-auth.ts:393-401` |
| `/auth/recover` | POST | none | `{ username, recoveryCode, newPassword }` | `{ token, refresh?, user, recoveryCode }` | `src/lib/theme-auth.ts:404-413` |
| `/auth/change-password` | POST | bearer | `{ oldPassword, newPassword }` | discarded | `src/lib/theme-auth.ts:416-422` |
| `/auth/username-available?u=<username>` | GET | none | — | `{ available: boolean }` | `src/lib/theme-auth.ts:425-434` |

The response shape for register/login/recover is not separately typed here — it's passed straight
into `applyAuthResult`, whose parameter type is `{ token: string; refresh?: string | null; user:
RawUser }` (`src/lib/theme-auth.ts:200-204`), plus `recoveryCode` read off the same object for
register/recover (`src/lib/theme-auth.ts:383,413`). **Important:** if a login/register response has
no `refresh` field, `applyAuthResult` does *not* invent one — it keeps the previous session's
refresh only if the token and user id are unchanged, otherwise the session ends up with
`refresh: null` (`src/lib/theme-auth.ts:206-213`), which permanently disarms background refresh and
profile-sync for that session (see `syncArm()` in §4).

### 1.4 Social API — `/themes/api/social/*` (avatar, alias; adjacent to account, not core identity)

| Path | Method | Auth | Body | Response | Source |
|---|---|---|---|---|---|
| `/social/profile/avatar` | POST (multipart, field `avatar`) | bearer | image blob | `ProfileSummary` | `src/lib/social/avatar.ts:13-26` |
| `/social/profile/avatar/remove` | POST | bearer | — | `ProfileSummary` | `src/lib/social/avatar.ts:28-38` |
| `/social/me/profile` | PATCH | bearer | `{ alias }` (≤32 chars, trimmed) | — | `src/lib/account/name-sync.ts:39-51` |
| `/social/u/<handle>` | GET | bearer | — | `{ alias?: string }` | `src/lib/account/name-sync.ts:53-62` |

`ProfileSummary` type: not found in the read files (imported from
`@/views/profile/profile-types`, not read — out of the requested file set); only the field used
here, `avatarUrl: string | null | undefined`, is confirmed (`src/lib/social/avatar.ts:24,36`).

### 1.5 Profile-sync API — `/themes/api/sync/v1/*`

| Path | Method | Auth | Body | Response | Source |
|---|---|---|---|---|---|
| `/sync/v1/state` | GET | bearer | — | `SyncStateResponse` | `src/lib/profile-sync/client.ts:11,130-132` |
| `/sync/v1/push` | POST | bearer | `{ writes: PushWrite[] }` | `PushResponse` | `src/lib/profile-sync/client.ts:12,134-136` |

Both go through `socialGet`/`socialPost` (`src/lib/social/client.ts:26-44`), i.e. through
`authenticatedFetch`, so a 401 triggers one token-refresh-and-retry automatically. Full type
definitions, quoted from `src/lib/profile-sync/types.ts:35-59`:

```ts
export type SyncDoc = { key: string; rev: number; at: string; value: unknown };
export type SyncStateResponse = { rev: number; serverTime: string; docs: SyncDoc[] };

export type PushWrite =
  | { key: string; baseRev: number; value: unknown }
  | { key: string; baseRev: number; clear: true };

export type PushAccepted = { key?: string; ok: true; rev: number };
export type PushRejected = { key?: string; ok: false; current: SyncDoc };
export type PushResult = PushAccepted | PushRejected;
export type PushResponse = { serverTime: string; results: PushResult[] };
```

Client-side response parsing is defensive/paranoid — a response whose `docs` is not an array is
treated as a **failed pull**, never as "account is empty", specifically to avoid a captive-portal
or misconfigured-proxy 200 response being read as "wipe local state"
(`src/lib/profile-sync/client.ts:75-96`, comment block quoted in full there). Same for
`/sync/v1/push`: a non-array `results` throws rather than being coerced to `[]`
(`src/lib/profile-sync/client.ts:111-118`).

Known HTTP status handling on push (`src/lib/profile-sync/client.ts:28-56`):
- `429` → rate limited (`isRateLimited`)
- `401` / `403` → auth failure (`isAuthFailure`)
- `422` / `413` → **rejection**, meaning the server looked at the batch and refused it outright;
  never retried verbatim (`isRejection`). The body may carry `{ key: <offending doc key> }`
  (`rejectedKeyOf`, reads `body.key`).
- Push write limits enforced **client-side** before sending, matching what the server is expected
  to enforce: `MAX_WRITES_PER_PUSH = 16`, `MAX_PUSH_BYTES = 192 * 1024`
  (`src/lib/profile-sync/limits.ts:12-13`). A server implementation should be assumed to enforce
  the same or the client's batching logic (see §5) will misbehave.

---

## 2. Session: storage, refresh, expiry, `authenticatedFetch`

### Storage
The session object (`Session = { token, refresh?, user, refreshedAt? }`,
`src/lib/theme-auth.ts:75`) is persisted to `localStorage` **per local profile**, not globally:

- Key: `harbor.theme-session.<activeProfileId>` (`SESSION_PREFIX = "harbor.theme-session."`,
  `src/lib/theme-auth.ts:7`, `sessionKey()` at `src/lib/theme-auth.ts:33-36`).
- Legacy global key `harbor.theme-session` is migrated into the primary profile's per-profile key
  on first load and then deleted (`migrateLegacyGlobal`, `src/lib/theme-auth.ts:37-49`, run once at
  module load, `theme-auth.ts:153`).
- A one-time repair pass (`repairCopiedSessions`, gated by `harbor.theme-session.repaired.v2`,
  `src/lib/theme-auth.ts:133-151`) removes any *other* profile's session key that holds the same
  `user.id` as the primary profile's session — cleanup for sessions that got copy-pasted across
  profiles.
- Which profile's key is "active" is read from `harbor.profiles.v1`'s `activeId` (or first
  `isPrimary` profile) — `activeProfileId()`, `src/lib/theme-auth.ts:22-27`.
- Switching the active profile (`harbor:active-profile-changed` / `harbor:profiles-updated`
  `window` events) makes the module re-read the session for the new profile
  (`reloadSession`, `src/lib/theme-auth.ts:173-186`).

Stored JSON shape (from `parseSession`, `src/lib/theme-auth.ts:101-123`):
```ts
{ token: string, refresh: string | null, refreshedAt?: number, user: Author }
```
A stored record missing `token`, `user.id`, or `user.username` (as strings) is treated as absent.

### Refresh
- `SESSION_REFRESH_MS = 6 * 60 * 60 * 1000` (6 hours) — a session is proactively refreshed this
  long after `refreshedAt` (`src/lib/theme-auth.ts:234,244-256`).
- `sessionRefreshDelay()` computes ms until the next refresh is due (0 if overdue), accounting for
  a per-session exponential backoff after failures (`refreshes` map keyed by profile's session
  key; backoff = `min(30000 * 2^(failures-1), 300000)`, i.e. 30s → 60s → 120s → 240s → capped at
  300s after ≥5 failures, `src/lib/theme-auth.ts:335-339`).
- `refreshToken(rejectedToken?)` (`src/lib/theme-auth.ts:258-347`) POSTs
  `{ refresh }` to `/identity/api/token/refresh`. Concurrency-safe: in-flight refresh for the same
  refresh token is shared (`state.promise`). If the token that got a 401 no longer matches the
  live session's token, it assumes another request already refreshed and returns `true` without a
  network call (`src/lib/theme-auth.ts:263`).
  - `401` with body `{ error: "refresh_invalid" }` → session is **ended** (`save(null)`,
    `src/lib/theme-auth.ts:321-324`). Any other non-OK or malformed response is treated as a
    transient failure (throws, caught, backs off — `theme-auth.ts:325-339`), i.e. does *not* log
    the user out.
  - On success, both `token` and `refresh` are rotated (`save({ ...origin, token: d.token, refresh:
    d.refresh, refreshedAt: Date.now() })`, `theme-auth.ts:333`) — refresh tokens are single-use.
  - If the active profile changed between issuing the refresh and it completing, the new
    token/refresh is written into the **originating** profile's storage key, not the now-active
    profile's (`theme-auth.ts:279-298`, comment: "Rotation consumes the old credential: retain it
    only in its unchanged origin profile").
- `startSessionRefresh()` (`src/lib/account/session-refresh-runner.ts`) is the background runner:
  schedules `refreshToken()` at the computed delay, re-arms on `subscribeAuthor` change, browser
  `online` event, `focus`, and `visibilitychange`. Minimum wait when back online is 1s, else 30s
  (`session-refresh-runner.ts:9-12`).
- **A session created without a `refresh` value can never recover from a 401** and is explicitly
  refused from arming profile-sync (`syncArm()` returns `"no-refresh"`,
  `src/lib/profile-sync/client.ts:14-26`, comment explains the legacy-author-login case).

### Expiry
No client-side JWT expiry parsing was found anywhere in the read files — the client never
decodes the token, only learns it's invalid via a `401` from the API (handled by
`authenticatedFetch`) or `refresh_invalid` from the refresh endpoint. Access-token/refresh-token
lifetimes are therefore **server-side and not documented in this codebase** ("not found").

### `authenticatedFetch`
`src/lib/account/authenticated-fetch.ts:5-31`. Wraps `fetch`/`safeFetch`:
1. Captures a "session scope" guard (`captureSessionScope`) so a slow request cannot land after the
   account changed underneath it — every checkpoint calls `assertCurrent()`, which throws
   `Error("Account changed")` if the session generation or active profile differs from when the
   request began.
2. Sends the request with `Authorization: Bearer <token>` (or no header if signed out).
3. On `401`, calls `refreshToken(token)`; if it returns true, re-sends once with the (possibly new)
   token. There is no further retry loop — one refresh attempt per request.
4. Session generation bumps on `applyAuthResult`/logout/profile-switch-with-different-user
   (`sessionGeneration`, `src/lib/theme-auth.ts:160,205,231,399`), never on token rotation alone
   (comment at `theme-auth.ts:226`: "Token rotation preserves this scope; login, logout and profile
   switches invalidate it").

---

## 3. Stremio link

Two entry points, both eventually calling `linkWithKey(authKey)` in
`src/lib/account/stremio-link.ts:8-18`:

- **"Verify with current session"** (`verifyWithCurrentStremio`) — uses the `authKey` already held
  in Harbor's own local Stremio session (`useAuth().authKey`, from `src/lib/auth.tsx`), i.e. the
  user is already signed into Stremio inside Harbor. UI: `src/views/account/stremio-verify-card.tsx:45`.
- **"Verify in browser"** (`verifyWithStremioBrowser`) — desktop (Tauri) only, opens
  `https://www.stremio.com/login?appName=Harbor&appCallback=http://127.0.0.1:<port>/cb` in the
  system browser via `startStremioWebAuth()` (`src/lib/stremio-auth.ts:14-48`).

### The loopback flow (desktop)
1. `startStremioWebAuth()` calls the Tauri command `stremio_auth_start`
   (`src-tauri/src/stremio_auth.rs:16-66`), which binds an ephemeral local TCP listener on
   `127.0.0.1:0`, spins up an `axum` router serving `GET /cb`, and returns the bound port.
2. Client builds `callback = http://127.0.0.1:<port>/cb` and opens
   `https://www.stremio.com/login?appName=Harbor&appCallback=<url-encoded callback>` in the OS
   browser (`stremio-auth.ts:19-20,46`).
3. The user logs into Stremio's own web login; stremio.com redirects the browser to the loopback
   `callback` URL with `?key=<authKey>` (or `?authKey=<authKey>` — the Rust handler accepts either,
   `stremio_auth.rs:36-39`).
4. The Rust handler emits a Tauri event `"stremio-auth"` with the key as payload
   (`stremio_auth.rs:44`) and serves a static "you're signed in" HTML page; the listener
   self-shuts-down after handling one request or after a 300s timeout
   (`stremio_auth.rs:53-63`).
5. The JS side is `listen`ing for `"stremio-auth"` (`stremio-auth.ts:36-45`) with its own 300000ms
   (`TIMEOUT_MS`) client-side timeout; on receipt it resolves the returned Promise with the
   `authKey` string.
6. `linkWithKey(authKey)` then: (a) POSTs `/identity/api/stremio/loopback/start` with an empty body
   (bearer) to obtain a server-side `state` nonce (`callbackUrl` from that response is **not used**
   anywhere in the client — confirmed by grep, only `state` is read,
   `src/lib/account/stremio-link.ts:11`); (b) POSTs `/identity/api/stremio/link` with
   `{ state, mode: "link", authKey }` (bearer); (c) applies the returned `{ token, refresh, user }`
   as the new session via `applyAuthResult` (this **replaces** the Harbor session's token/refresh,
   presumably because linking upgrades the account's verified/linked status server-side and issues
   fresh credentials).

Errors surfaced through the shared error-code table (§1.1): `stremio_already_bound`,
`stremio_key_invalid`, `stremio_anonymous`, `stremio_unreachable`, `challenge_invalid`.

### Where the Stremio authKey lives client-side
This is a **separate credential from the Harbor account session**. It lives in
`src/lib/auth.tsx`, per local profile:
- Key: `harbor.auth.<localProfileId>` (`PROFILE_KEY_PREFIX = "harbor.auth."`, `src/lib/auth.tsx:22-26`).
- Value: `{ authKey: string, user: { _id, email, fullname?, avatar? } }`
  (`Session` type, `src/lib/auth.tsx:13`; `User` type from `src/lib/stremio.ts:9-14`).
- Obtained either via `signIn(email, password)` → `POST https://api.strem.io/api/login`
  (`src/lib/stremio.ts:154-160`, official Stremio API, not a Harbor server) or
  `signInWithKey(authKey)` which calls `getUser(authKey)` against the same official API
  (`src/lib/stremio.ts:162-164`) to hydrate the user record.
- `useAuth().authKey` (React context, `src/lib/auth.tsx:126-133`) is what `StremioVerifyCard` reads
  to feed into `verifyWithCurrentStremio` (§ above) — i.e. the "verify ownership" flow re-uses
  whatever authKey the profile is already signed in with for playback/library purposes, it does
  not fetch a fresh one.
- `readActiveStremioAuthKey()` (`src/lib/auth.tsx:49-62`) is a synchronous, non-React accessor used
  elsewhere in the app; it resolves the active profile (or its `shareStremioWith` source profile,
  via `stremioSourceProfileId`, not read in this pass) and reads that profile's `harbor.auth.<id>`
  key directly.

Note: `src/lib/stremio.ts` and its authKey are talking to Stremio's own official backend
(`https://api.strem.io/api`), not a Harbor server — included here only because it is the credential
that `/identity/api/stremio/link` consumes.

---

## 4. Profile-sync data model

### Core concepts
- **Section**: a named, independently-versioned slice of profile or account data. A section is
  identified by a `SectionKey` and stored server-side as a document keyed by
  `docKey(section, syncId) = "${syncId}:${section}"` for profile-scoped sections, or
  `"account:${section}"` for account-scoped sections (`ACCOUNT_SCOPE = "account"`,
  `src/lib/profile-sync/sections.ts:98-100`, `types.ts:27`).
- **Section registry is an allowlist, not a denylist.** Nothing reaches the wire unless its name is
  one of the declared `PROFILE_SECTIONS`/`ACCOUNT_SECTIONS` *and* something has called
  `registerSection` for it at runtime (`src/lib/profile-sync/sections.ts:14-51`). An unregistered
  but allowlisted name is simply never read or written.

All declared section names, quoted verbatim (`src/lib/profile-sync/types.ts:1-21`):
```ts
export const PROFILE_SECTIONS = [
  "home", "anime", "nav", "catalogs", "pinned", "collrows", "services",
  "manga", "detail", "lists", "page.movies", "page.shows", "page.kids",
  "page.discover", "settings", "theme", "playerlayout",
] as const;

export const ACCOUNT_SECTIONS = ["profiles", "watchedby"] as const;
```

**As of this snapshot, only some of these have an adapter actually registered** (i.e. are live).
Confirmed registrations found by tracing every `registerSection` call site:

| Section | Scope | Registered by | Payload | Merge? |
|---|---|---|---|---|
| `profiles` | account | `registerRosterSection`, `src/lib/profile-sync/roster-section.ts:157-159` | `RosterValue = { profiles: WireProfile[] }` | no (replace-whole, but conflict handling re-plans, see below) |
| `watchedby` | account | `registerLayoutSections`, `src/lib/layout-sync/sections.ts:65` | `WatchedByMap = Record<mediaId, {p:string,t:number}>` | **yes**, per-key LWW |
| `home` | profile | same, `src/lib/layout-sync/sections.ts:20,63` | `Settings["homeRows"]` (opaque object) | no |
| `anime` | profile | same, `sections.ts:21,63` | `Settings["animeRows"]` | no |
| `nav` | profile | same, `sections.ts:22,63` | `Settings["navCustomization"]` | no |
| `services` | profile | same, `sections.ts:23,63` | `Settings["streaming"]` | no |
| `settings` | profile | `registerTvSyncSections`, `src/views/settings/tv-panel/store.ts:186-201` | `TvDoc = Record<string, boolean\|string\|string[]>` | no |
| `playerlayout` | profile | same | `TvDoc` | no |
| `theme` | profile | same | `TvThemeDoc = { id: string; name: string; tokens: Record<string,string>\|null }` | no |

`catalogs`, `pinned`, `collrows`, `manga`, `detail`, `lists`, `page.movies`, `page.shows`,
`page.kids`, `page.discover` are declared in `PROFILE_SECTIONS` but **no `registerSection` call for
them was found anywhere in `src/`** — per the comment at `src/lib/layout-sync/sections.ts:11-18`,
these are "install-global stores... [with] no profile scope at all on disk yet" and are
deliberately left unregistered until they're made per-profile, specifically to avoid one device's
layout leaking onto every profile of every other device. **A second client must not assume these
sections carry data** — treat them as reserved names, not implemented.

`SectionAdapter` (the contract every registered section implements), quoted verbatim
(`src/lib/profile-sync/types.ts:61-74`):
```ts
export type SectionAdapter = {
  /** Account sections (profiles, watchedby) are handed an empty profileId. */
  read: (profileId: string) => unknown;
  /** Return false to say the value could not be applied, which withholds its rev so the next pull retries. */
  write: (profileId: string, value: unknown) => void | boolean;
  merge?: (local: unknown, incoming: unknown) => unknown;
};
```

### Roster (`profiles` section)
Wire shape, quoted verbatim (`src/lib/profile-sync/types.ts:106-121`):
```ts
export type WireProfile = {
  syncId: string;
  name: string;
  avatar: string | null;
  color: string;
  isPrimary: boolean;
  kid: { age: number; curfewMinutes: number | null } | null;
  hideContent: unknown;
  lockedTabs: unknown;
  settingsLinked: boolean;
  createdAt: number;
  updatedAt: number;
  deletedAt: number | null;
};
export type RosterValue = { profiles: WireProfile[] };
```
- `syncId` format: `s_<uuid>` (via `crypto.randomUUID()`) or fallback `s_<base36 time>_<random>`
  (`src/lib/profile-sync/roster.ts:19-28`) — minted **client-side**, once, by whichever device
  first pushes a profile; not server-issued despite what a naive spec might assume (comment at
  `roster.ts:12-18`).
- The wire record **never carries `passwordHash` or `kid.parentPinHash`** — profile PINs are
  per-device by design, because the hashing is unsalted SHA-256 over a constant string, making it a
  precomputable rainbow table if it ever left the device (`src/lib/profile-sync/types.ts:100-105`).
- Avatars only transmit if they're an internal portable path (`/avatars/...` or
  `/kids/avatars/...`); `data:` URLs and external `https:` URLs (e.g. Trakt/AniList avatars) are
  dropped to `null` on the wire (`src/lib/profile-sync/roster.ts:30-41`).
- Deletion is by **tombstone**, not omission: `noteProfileDeleted(localId)` appends a
  `{ ...wireRecord, deletedAt: Date.now() }` to a local tombstone list
  (`harbor.sync.tombstones`, capped at last 64, `src/lib/profile-sync/roster-section.ts:29-65`) and
  it's merged into every subsequent roster push. A profile silently absent from an incoming roster
  (rather than tombstoned) is **kept and re-pushed**, never deleted locally — see the "DELETION
  REQUIRES A TOMBSTONE" comment (`roster.ts:229-235`).
- `updatedAt` is only bumped when a profile's *content* actually differs from what this device last
  knew the server to hold (`sameWire`, `roster.ts:148-161`, `buildRosterValue`,
  `roster.ts:171-190`) — this stabilizes the serialization so the section doesn't get flagged dirty
  on every read (which would otherwise defeat the "already matches sent" push-suppression, §5).

### `id-map` (local profile id ↔ syncId)
`localStorage["harbor.sync.idmap"]` = `Record<localProfileId, syncId>`
(`src/lib/profile-sync/id-map.ts`, key from `src/lib/profile-sync/keys.ts:4`). Local profile ids
(`p_<base36time>_<random>`, minted by `newId()` in `profiles.tsx`, not itself read in this pass but
referenced at `src/lib/profile-sync/roster.ts:4-10`) are namespaces for ~15 other localStorage keys
per profile and are **never** renamed to match the server; `syncId` is a strictly additive second
identity only this map and the wire ever see (comment, `id-map.ts:6-11`).

### Revisions (`revs`)
`localStorage["harbor.sync.revs"]` = `Record<docKey, rev:number>` (`src/lib/profile-sync/revs.ts:4,31-49`).
`rev` is **the only ordering authority — server-assigned, monotonic, per section** — `at` is
display-only and must never be used for merge/ordering decisions (comment,
`src/lib/profile-sync/types.ts:29-34`). Also tracked here, in-memory only (never persisted, reset
every process start): a `hydrated` Set of doc keys this process has successfully pulled at least
once — **a section can never be pushed before it has been hydrated in the current process**
(`isHydrated`/`markHydrated`, `revs.ts:13-29`; gate enforced at `engine.ts:297`).

A per-key FNV-1a-32 hash of the last **accepted** serialization is also stored
(`localStorage["harbor.sync.sent"]`, `sentHash`/`markSent`/`matchesSent`, `revs.ts:58-88`) so a
push is skipped entirely if the local value is byte-identical to what the server already has,
even if nothing marked it clean (prevents "phantom push loops",`revs.ts:58-63`).

### `parked` items
`localStorage["harbor.sync.parked.<docKey>"]` = `{ value, parkedAt, lostToRev }`
(`src/lib/profile-sync/parked.ts:20-25`, `ParkedWrite` type at lines 6-12). When this device's
write **loses** a conflict (rejected push, or an incoming pull that clobbers unsaved local state
during first-pull adoption), the losing value is kept here, **local only, never uploaded** by the
normal path, so the user can explicitly choose to restore and re-push it once
(`restoreParkedSection`, `src/lib/profile-sync/scheduler.ts:144-161`). Exception: a rejected
`clear` has no value to park (`engine.ts:396-398`).

### Limits
Quoted verbatim (`src/lib/profile-sync/limits.ts`):
```ts
const DEFAULT_LIMIT = 96 * 1024; // bytes, per section value
const SECTION_LIMIT = { settings: 32 * 1024, theme: 8 * 1024, playerlayout: 16 * 1024 };
export const MAX_WRITES_PER_PUSH = 16;
export const MAX_PUSH_BYTES = 192 * 1024;
```
A section value over its per-section limit is **parked locally and dropped from the push queue**,
never sent and never retried automatically (`engine.ts:332-337`). A batch is capped client-side to
`MAX_WRITES_PER_PUSH` entries and, once at least one entry is queued, to `MAX_PUSH_BYTES` total
(`capPush`, `engine.ts:357-368`) — this exists because the server refuses the **whole** batch on
overflow (413) rather than the offending write, so an uncapped client would retry an unfixable
batch forever (comment, `engine.ts:349-356`).

### Queue and scheduler cadence
Queue (`localStorage["harbor.sync.queue"]` = `{ since: number, items: {key, clear?, value?}[] }`,
`src/lib/profile-sync/queue.ts`) holds **dirty keys only, coalesced to one entry per key** — never
an append-log — and the value is re-read fresh from the section's own store at flush time, so an
intermediate state can never be replayed (`queue.ts:24-41`).

Scheduler constants, quoted (`src/lib/profile-sync/scheduler.ts:14-22`):
```ts
const DEBOUNCE_MS = 2500;             // wait after a local change before pushing
const PUSH_FLOOR_MS = 5000;           // minimum gap between two pushes
const PULL_INTERVAL_MS = 15 * 60000;  // steady-state pull cadence, 15 min
const FOREGROUND_STALE_MS = 5 * 60000;// re-pull if foregrounded and last pull older than this
const PULL_BACKOFF_MS = [8000, 30000, 120000, 600000]; // pull retry backoff on failure
```
Triggers: `markSectionDirty`/`markSectionCleared` enqueue + `scheduleFlush()`
(`scheduler.ts:124-138`); tab hidden or `pagehide` → immediate synchronous-ish `flushSyncNow()`
(`scheduler.ts:169-176`, cannot be awaited across a real page teardown, hence the queue is
persisted rather than held in memory, comment at `scheduler.ts:61-63`); visibility becoming
`visible` with a stale last-pull triggers an immediate pull (`scheduler.ts:174`); coming back
`online`, gaining `focus`, or an author-session change (`subscribeAuthor`) also (re)trigger a pull.
On reconnect, order is **pull first, then push only what still differs**
(`scheduler.ts:92-97`, comment "A6 reconnect order").
A 429 push failure sets a global `rateLimitedUntil = now + 60000` that every subsequent flush
attempt respects (`RATE_LIMIT_BACKOFF_MS`, `engine.ts:50,239-241,420`); a 422/413 rejection sets a
similar `REJECT_BACKOFF_MS = 60000` cooldown after parking/dropping the offending write
(`engine.ts:51,435`).

### Conflict resolution rules
- **Default rule (every section except `watchedby` and `profiles`): server wins outright.**
  `PushWrite` carries `baseRev`; if the server's current rev for that key doesn't match, the whole
  write is rejected with `{ ok: false, current: SyncDoc }` and the section adapter is overwritten
  with the server's `current.value` (`onRejected`, `engine.ts:370-400`). The losing local value is
  parked (see above), never merged, because "two row orderings cannot be merged into a third
  ordering either person chose" (`types.ts:61-67`).
- **`watchedby`: per-key last-writer-wins**, using a **client clock** (`t` field). Deliberately
  accepted here — "the failure mode is Dad's face instead of Mum's on one card" — and explicitly
  said to be unacceptable for any other section (`src/lib/profile-sync/watched-by-merge.ts:6-16`).
  Merge logic, quoted (`watched-by-merge.ts:33-56`):
  ```ts
  export function mergeWatchedBy(local: unknown, incoming: unknown): WatchedByMap {
    const a = normalizeWatchedBy(local);
    const b = normalizeWatchedBy(incoming);
    const out: WatchedByMap = { ...a };
    for (const [mediaId, entry] of Object.entries(b)) {
      const mine = out[mediaId];
      if (!mine || entry.t > mine.t) out[mediaId] = entry;
    }
    return capWatchedBy(out, WATCHED_BY_MAX); // WATCHED_BY_MAX = 300, evicts oldest `t` first
  }
  ```
- **`profiles` (roster): "adopt, never merge" on first pull, "re-plan against the winner" on
  rejection.** Two rosters *can* converge (adopt theirs, then push back the local profiles they
  don't have), unlike two row orderings, so on a rejected roster push the engine re-runs
  `planRoster` against the server's `current` value instead of parking
  (`engine.ts:392-395`, comment at `roster-section.ts:151-155`). First-pull specifically **never
  merges** a locally-created "bootstrap" profile into the server roster — it is pushed as a
  brand-new profile, worst case a duplicate the user deletes, rather than risking planting a
  phantom empty profile onto every device (`planRoster`, comment block `roster.ts:199-204`).
- **First-pull adoption is a full overwrite, parked for recovery.** `applyDocs(docs, adopting=true)`
  applies every incoming section over local state (the single highest-risk step — "a user who has
  customised home, anime, catalogs and services over months loses all of it the moment they sign
  in") and parks the previous local value for every section where it differed
  (`engine.ts:121-174`).
- **A device can never push a section it has not first pulled in this process** (`isHydrated` gate,
  `engine.ts:297`), and a doc that arrived but failed to `write()` (adapter returned `false` or
  threw) stays **unhydrated**, so this device is never allowed to overwrite a section it failed to
  adopt (`markHydrationAfterPull`, `engine.ts:176-194`).
- **Empty is never a value.** A structurally-empty payload (`null`, `""`, `[]`, `{}`, or an object
  whose every leaf is one of those) is never pushed and never treated as "the section is empty on
  purpose" — clearing requires an explicit `{ clear: true }` write via `markSectionCleared`
  (`isStructurallyEmpty`, `sections.ts:118-127`; enforced at `engine.ts:326`). This specifically
  prevents a fresh/unloaded device from wiping the account's customization.
- Apply order on pull matters for cross-referencing sections: `lists`/`collrows` before `home`
  (because `home.listRows` holds ids resolving into those stores), full order quoted
  (`sections.ts:74-91`):
  ```ts
  const APPLY_ORDER = ["profiles","lists","collrows","pinned","catalogs","services",
    "nav","home","anime","manga","detail","page.movies","page.shows","page.kids",
    "page.discover","watchedby"];
  ```
  (`settings`/`theme`/`playerlayout` are not in this list, so they apply last/unordered relative to
  each other, per `applyRank`'s fallback of `APPLY_ORDER.length`, `sections.ts:93-96`.)

### Encryption / hashing
**No section payload is encrypted client-side.** Every adapter's `value` travels as plain JSON
inside `PushWrite`/`SyncDoc`; the only cryptographic-looking operations found are (a) an FNV-1a-32
non-cryptographic hash used purely for local push-suppression (`revs.ts:64-71`, not sent to the
server), and (b) profile PIN hashing, which is unsalted SHA-256 over a constant string and is
explicitly **excluded from the wire format** (`types.ts:100-105`) — PINs never leave the device at
all, encrypted or otherwise. Transport security is whatever TLS the `https://harbor.site` origin
provides; nothing in this codebase adds an application-layer encryption envelope on top.

---

## 5. Sequences

### 5.1 First sync on a new device (freshly signed into an existing Harbor account)

1. App starts; `ProfileSyncRunner` mounts, calling `startProfileSync()`
   (`src/lib/profile-sync/sync-runner.tsx:13-17`), which registers the roster section adapter and
   immediately schedules a pull with 0 delay (`scheduler.ts:163-190`).
2. `runPull()` checks `syncArm()`: needs a bearer token *and* a refresh token, else it reports
   `signed-out`/`no-refresh` and stops (`engine.ts:216-225`, `client.ts:22-26`).
3. `account = syncAccountId()` (current author's id). Since `boundAccount()` (last account this
   device synced) differs (or is empty), `firstPull = true`; status is patched to phase
   `"first-pull"` (`engine.ts:221-232`).
4. `GET /themes/api/sync/v1/state` is called. On failure the phase becomes `"first-pull-failed"`
   and nothing local is touched (`engine.ts:234-242`).
5. On success: because this is the *first* bind of this account on this device (not an account
   *switch*), local queue/parked/tombstone state is **kept**, only rev bookkeeping is cleared
   (`clearRevState()`, not the destructive `resetSyncState()` — `engine.ts:253-257`, and see the
   guarding comment there about not treating "request never happened" as "account has nothing").
6. `applyDocs(state.docs, firstPull=true)` runs, sorted by `APPLY_ORDER`: for each doc, resolve its
   section adapter, resolve `profileId` from its scope, `write()` the value (for `watchedby`,
   `merge()` local+incoming first), park the previous local value if it differed, record the new
   `rev`, mark the served value's hash as "sent" (`engine.ts:129-174`).
7. `settleRoster(state.docs)`: if the account's roster doc was **absent** from the pull (brand-new
   account, nobody has pushed a roster yet), `seedRosterFromLocal()` mints `syncId`s for this
   device's local profiles and the roster key is queued dirty so it gets pushed
   (`engine.ts:202-213`, `roster-section.ts:91-100`). If a roster **was** present, `planRoster()`
   (invoked from the roster adapter's `write`, step 6) either adopts it wholesale (replacing local
   profiles, applying tombstones) or, if the local roster store isn't wired yet, defers (`write()`
   returns `false`, withholding the rev so the next pull retries — `roster-section.ts:117-149`).
8. `markHydrationAfterPull` marks every section this pull didn't mention (for every known syncId) as
   hydrated anyway, since a full `GET /sync/v1/state` is authoritative that the server holds
   nothing there (`engine.ts:176-194`).
9. `bindAccount(account)`, `markPulledNow()`, `setRosterFirstPull(false)`; status →
   `{ phase: "idle", everPulled: true, ... }` (`engine.ts:266-276`).
10. Scheduler sees the pull succeeded: if anything is queued (e.g. the freshly-seeded roster), flush
    immediately; otherwise schedule the next steady-state pull in 15 minutes
    (`scheduler.ts:92-97`).
11. `runPush()` (triggered by the flush) sends the queued roster (and any other now-dirty,
    hydrated sections) via `POST /themes/api/sync/v1/push`, subject to the write/byte caps (§4).

### 5.2 Push a local change (e.g. user reorders the Home screen)

1. UI mutates local state and calls the adapter's store write directly (e.g.
   `writeSettingsFor`/`writeActive` for `home`), then the same call site calls
   `markSectionDirty("home", profileId?)` (`scheduler.ts:124-130`).
2. `scopeFor("home", profileId)` resolves the profile's `syncId` via `id-map`; if the profile has no
   `syncId` yet (never synced), the mark is silently dropped — it'll go up once the roster mints one
   (`scheduler.ts:112-123`).
3. `enqueueDirty(docKey("home", syncId))` coalesces into the persisted queue (overwrites any
   existing entry for that key, does not append) and `scheduleFlush()` computes a wait of
   `max(DEBOUNCE_MS=2500, floor-since-last-push, current-rate-limit-remaining)`
   (`scheduler.ts:36-43`).
4. On timer fire, `flush()` calls `runPush()` (`scheduler.ts:45-59`).
5. `runPush()`: re-checks `syncArm()`, checks the global rate-limit gate, then `prepareWrites()`
   walks every queued key: skips any not yet `isHydrated` (never-pulled-this-process gate); reads
   the adapter's current value fresh (not the value at enqueue time); if it's structurally empty,
   **holds** it in the queue rather than dropping or sending (store may not have finished loading);
   if it matches the last-sent hash, drops it from the queue as a no-op; if it exceeds
   `sectionLimit()`, parks it and drops it from the queue; otherwise builds a
   `{ key, baseRev: revOf(key), value }` write (`engine.ts:287-347`).
6. The prepared writes are capped to `MAX_WRITES_PER_PUSH`/`MAX_PUSH_BYTES` (`capPush`,
   `engine.ts:357-368`) and POSTed as one batch to `/sync/v1/push`.
7. Per-result handling (`engine.ts:441-460`):
   - **Accepted** (`ok: true`): store the new `rev`, mark the sent-hash, clear any park for that
     key, drop it from the queue.
   - **Rejected** (`ok: false, current`): `onRejected` — for `profiles` or any section with a
     `merge` adapter, re-derive from `merge(local, current.value)` (or just adopt `current.value`
     for non-merge sections), `write()` it locally, adopt `current.rev`, mark sent, drop from
     queue; for `profiles`/merge sections **re-enqueue dirty** (so the merged/re-planned result goes
     back up); for a plain replace-section, **park** the losing local value instead and do not
     re-enqueue.
8. Status is patched (`phase: "idle", lastPushAt, lastError`) and the UI's queue counters refresh.

---

## 6. Local storage keys

All under the browser/WebView `localStorage` used by the Tauri webview. Everything sync-related is
prefixed `harbor.sync.` (`SYNC_KEY_PREFIX`, `src/lib/profile-sync/keys.ts:9`) and enumerable via
`syncKeys()` (`keys.ts:30-41`).

| Key | Shape | Source |
|---|---|---|
| `harbor.theme-session` | legacy global `Session`; migrated away on first load | `theme-auth.ts:6,37-49` |
| `harbor.theme-session.<profileId>` | `{ token, refresh: string\|null, refreshedAt?: number, user: Author }` | `theme-auth.ts:7,101-123` |
| `harbor.theme-session.repaired.v2` | one-shot flag, value `"1"` | `theme-auth.ts:9,133-151` |
| `harbor.profiles.v1` | `{ profiles: Array<{id, isPrimary, ...}>, activeId?: string }` | `theme-auth.ts:8`, `roster-store.ts:3`, `auth.tsx:51` |
| `harbor.auth.<localProfileId>` | `{ authKey: string, user: { _id, email, fullname?, avatar? } }` (Stremio session, not Harbor account) | `auth.tsx:13,22-47` |
| `harbor.avatar-synced.<authorId>` | opaque hash string or `"none"` | `avatar-sync.ts:4,13-31` |
| `harbor.sync.revs` | `Record<docKey, rev:number>` | `keys.ts:1`, `revs.ts:31-49` |
| `harbor.sync.account` | bound account id (plain string) | `keys.ts:2`, `revs.ts:90-100` |
| `harbor.sync.queue` | `{ since: number, items: {key, clear?, value?}[] }` | `keys.ts:3`, `queue.ts` |
| `harbor.sync.idmap` | `Record<localProfileId, syncId>` | `keys.ts:4`, `id-map.ts` |
| `harbor.sync.sent` | `Record<docKey, fnv1aHash:string>` | `keys.ts:5`, `revs.ts:73-83` |
| `harbor.sync.lastPullAt` | epoch-ms string | `keys.ts:6`, `revs.ts:102-112` |
| `harbor.sync.parked.<docKey>` | `{ value: unknown, parkedAt: number, lostToRev: number }` | `keys.ts:7`, `parked.ts:20-25` |
| `harbor.sync.tombstones` | `WireProfile[]` (only entries with `deletedAt != null`; capped to last 64) | `roster-section.ts:9,25-35` |
| `harbor.sync.roster.known` | `WireProfile[]`, last roster this device built/adopted | `roster-section.ts:13-23` |
| `harbor.watchedby.v1` | `WatchedByMap` | `watched-by.ts:9` |
| `harbor.settings` (legacy) / `harbor.settings.shared` / `harbor.settings.<profileId>` | `Settings` blob | `settings/profile-store.ts:5-9` |
| `harbor.tvsettings.v1.<profileId>` | `{ settings: TvDoc, playerlayout: TvDoc, theme: TvThemeDoc\|null }` | `tv-panel/store.ts:21-22` |

---

## 7. Risks for a second (Swift) client implementation

1. **Do not call `sync.harbor.site`.** It is a different, unauthenticated service (subtitle
   crowd-sync). Calling it for profile data will silently do nothing useful and could be mistaken
   for a working integration. Use `https://harbor.site/themes/api/sync/v1/{state,push}` with the
   bearer token. (`profile-sync/client.ts:6-13`, `subtitles/autosync/crowd-db.ts:5,19`)
2. **`baseRev` must be exact and per-key, not a global version.** Every push write carries the
   `rev` this client last observed for that specific `docKey`. Pushing with a stale or fabricated
   `baseRev` (e.g. 0, or "whatever we last pushed" instead of "whatever we last pulled") will get
   rejected by a correct server, but a *buggy* implementation that ignores the rejection and blind-
   retries the same stale write could loop forever or, worse, if the server were ever implemented
   to trust the client's rev, silently clobber a concurrent edit from another device. Always track
   rev per `docKey`, update it only from `SyncDoc.rev` in a state/pull response or a push
   **acceptance**, and on rejection adopt the server's `current` doc (value **and** rev) before
   retrying.
3. **A section must be pulled (hydrated) before it is ever pushed, for the lifetime of the process.**
   Skipping this gate is how a cold/empty device overwrites a household's real data — this is
   called out explicitly as the one guarantee protecting a "cold TV" (`revs.ts:7-12`). A Swift
   client must track "have I successfully applied at least one server doc (or an authoritative
   empty-state pull) for this key in this run" before it is allowed to send a value for that key.
4. **Never send a structurally-empty value as a normal write, and never invent a default value for
   a section whose local store hasn't finished loading.** Both read as "the user wants this
   cleared" to a naive server and both have already caused real data loss in this codebase's
   history per the comments at `sections.ts:112-117` and `engine.ts:319-326` ("held, not dropped").
   A section can only be intentionally cleared via an explicit clear-write, distinct from an
   absent/empty value.
5. **Missing sections must not be inferred as deletions**, for the roster in particular. A profile
   silently absent from a pulled roster is *kept*, not deleted; only an explicit tombstone
   (`deletedAt != null`) deletes a profile. A malformed or truncated roster response could otherwise
   wipe every profile on every device that pulls it (`roster.ts:229-235`).
6. **Id remapping: never conflate the local profile id and the wire `syncId`.** They are two
   independent identifiers by design (one device-local, namespacing ~15 other keys; one
   account-wide, shared across devices) and the mapping between them is additive-only — a `syncId`
   must never be re-minted for a local id that already has one, or every section that profile owns
   on the server becomes orphaned (comment, `roster-section.ts:102-106`).
7. **A response with a malformed `docs`/`results` array must be treated as a *failed* pull/push, not
   an empty one.** The reference client throws rather than coercing to `[]`, specifically because a
   captive portal, CDN error page, or half-deployed endpoint can return HTTP 200 with an unexpected
   body, and treating that as "account holds nothing" would then push a full account overwrite at
   `baseRev` 0 (`client.ts:75-96`).
8. **A 422/413 rejects the whole batch, not the individual write** — do not retry an unmodified
   over-limit or malformed batch; either honor the server-named offending key (if provided in the
   error body) or shrink the batch (drop the largest entry) before retrying, or every other queued
   section behind it stalls indefinitely (`engine.ts:349-356,421-435`).
9. **Session/token handling must be per-profile-aware if the Swift app has any concept of multiple
   local profiles sharing one device** — the reference client's session storage, refresh-token
   rotation target, and even its in-memory "session changed" generation counter are all scoped to
   "the currently active local profile," and a refresh completing after a profile switch writes
   into the *original* profile's storage, not the one now active (`theme-auth.ts:279-298`). A
   simpler single-account Swift client can ignore this, but should not casually assume "the" session
   the way a naive read of `theme-auth.ts` might suggest.
10. **PINs/passwordHash and any `kid.parentPinHash` must never be put on the wire.** They are
    intentionally excluded from `WireProfile`, and the unsalted-SHA-256 scheme used locally is
    explicitly documented as too weak to ever transmit (a 4-digit PIN is a 10,000-entry rainbow
    table computed once, `types.ts:100-105`). A new client must keep any profile-lock credential
    device-local by the same reasoning, not merely "because the existing client happens to."
11. **No payload is encrypted.** If a Swift implementation wants confidentiality beyond TLS for
    section contents (e.g. because it stores something more sensitive in a section than this web
    client does), that protection does not exist today and would need to be added independently on
    both ends — do not assume the existing server already decrypts anything.
