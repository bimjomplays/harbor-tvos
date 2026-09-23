# Harbor Live TV — Native Port Spec (Stage 8)

Source repo: `reference/harbor` (read-only; this document is the only file written).
All citations are `path:line` relative to that repo root. Every value below was read
directly from source; anything not found is marked **"not found"**. Not repeated here:
`docs/big-picture-design.md` (general Big Picture shell/focus system), `docs/engine-report.md`
(what already runs in the JS engine), `docs/player-spec.md` §2.3 (mpv cache/network options
for live streams) and §2.12 (mpv vs. HTML5 engine choice — irrelevant to tvOS, MPVKit is
always used).

---

## 1. SOURCES

### 1.1 Storage — `StoredPlaylist` (verbatim)

Two structurally-identical definitions exist; the live one is `playlists-store.ts`, the
`Settings.iptvPlaylists` copy is legacy (see §1.2).

`src/lib/iptv/playlists-store.ts:4-11`:
```ts
export type StoredPlaylist = {
  id: string;
  name: string;
  url: string;
  epgUrl?: string;
  kind?: "m3u" | "xtream" | "epg";
  xtream?: { server: string; username: string; password: string };
};
```
`src/lib/settings/types.ts:661-671` (the legacy/settings-blob shape, structurally identical):
```ts
iptvPlaylists: Array<{
  id: string;
  name: string;
  url: string;
  epgUrl?: string;
  kind?: "m3u" | "xtream" | "epg";
  xtream?: { server: string; username: string; password: string };
}>;
```
Default: `[]` (`src/lib/settings/defaults.ts:557`). `src/lib/iptv/playlist-entry.ts:13`:
`export type StoredPlaylist = Settings["iptvPlaylists"][number];` — a third alias pointing at
the settings-blob shape, used only by the add/edit form's `materializePlaylistEntry`.

**localStorage key**: `harbor.iptv.playlists.v1` (`playlists-store.ts:13`), a flat JSON array
of `StoredPlaylist`. Read/write via `readPlaylists()` / `writePlaylists()`
(`playlists-store.ts:122-154`); React consumers use `usePlaylists()`
(`useSyncExternalStore`, `:165-171`).

**Migration** (`migrateLegacyPlaylists`, `playlists-store.ts:35-103`, runs once per session,
`ensureMigrated()` guards it): scans every `harbor.settings*` localStorage key
(`harbor.settings.shared`, `harbor.settings`, any `harbor.settings.<profile>`), merges their
`iptvPlaylists` arrays (dedup by `id`, first-seen/stored wins), writes the merged array to
`harbor.iptv.playlists.v1`, and **only then** strips the `iptvPlaylists` field from each
settings blob (`:93-102`) — so a failed dedicated-key write never destroys the only copy.
`adoptLegacyPlaylists()` (`:110-120`) handles a stranded legacy array found after the fact
(stored entries win on conflict).

Sources are converted to the runtime shape `IptvPlaylistSource` for loading
(`src/lib/iptv/types.ts:24-35`):
```ts
export type IptvPlaylistSource = {
  id: string;
  name: string;
  url: string;
  epgUrl?: string;
  kind?: "m3u" | "xtream" | "epg";
  xtream?: { server: string; username: string; password: string };
};
```
Identical field set to `StoredPlaylist`; Big Picture builds it straight from settings
(`src/views/big-picture/use-bp-live.ts:143-156`).

### 1.2 Adding a playlist

One entry point for both the desktop source picker and Big Picture's setup screen:
`materializePlaylistEntry(id, entry: PlaylistFormValue)`
(`src/lib/iptv/playlist-entry.ts:38-62`). `PlaylistFormValue` (`:5-11`):
```ts
export type PlaylistFormValue = {
  name: string;
  kind: PlaylistKind;              // "m3u" | "xtream" | "epg"
  url: string;
  epgUrl: string;
  xtream: { server: string; username: string; password: string };
};
```
For `kind === "xtream"` it calls `buildXtreamUrls(server, username, password)`
(`:23-31`):
```ts
m3u: `${base}/get.php?username=${u}&password=${p}&type=m3u_plus&output=ts`
epg: `${base}/xmltv.php?username=${u}&password=${p}`
```
(`base` = server with trailing slashes stripped, `u`/`p` = `encodeURIComponent`d). The
stored entry keeps `xtream: { server, username, password }` (trailing slash stripped off
`server` again) **and** the derived `url`/`epgUrl` — both a form of the same credentials are
persisted. `newPlaylistId()` = `` `pl-${Date.now()}-${Math.floor(Math.random()*1000)}` ``
(`:64-66`).

For `kind === "epg"` (an EPG-only source with no channel list): `{ id, name, url: "",
epgUrl: entry.epgUrl, kind: "epg" }` (`:58-60`).

An Xtream URL pasted directly as an M3U link is also recognized:
`parseXtreamUrl(url)` (`src/lib/iptv/xtream.ts:17-29`) requires `username` and `password`
query params and a path ending `get.php` or `player_api.php`; `credsFromServer(server,
user,pass)` (`:31-49`) builds creds from the three-field form instead. Both funnel through
`credsFromSource()` (`src/lib/iptv/ingest/xtream-creds.ts:6-12`, structured `xtream` field
wins, falls back to parsing `src.url`).

### 1.3 Provider-shape detection → what gets fetched

`detectProviderShape(src)` (`src/lib/iptv/ingest/detect.ts:14-41`) returns one of:
```ts
export type ProviderShape =
  | { kind: "xtream"; creds: XtreamCreds }
  | { kind: "m3u"; url: string; middleware: boolean }
  | { kind: "epg"; url: string }
  | { kind: "invalid"; reason: string };
```
Order: `kind === "epg"` → epg shape; else try `credsFromSource` → xtream shape (or
`invalid` if `kind === "xtream"` but creds are incomplete); else require an `http(s)://` URL.
`middleware` is set when the URL looks like a middleware/EPG-proxy path rather than a raw
`.m3u`/`.m3u8` file — `MIDDLEWARE_PATH_RE = /\/(iptv|m3u|playlist|xmltv|threadfin|xteve)\b/i`
or a bare host with no path/query (`isMiddlewareUrl`, `:43-53`). `RAW_M3U_RE =
/\.m3u8?(\?|$)/i` short-circuits detection to "not middleware" for literal `.m3u`/`.m3u8`
URLs.

`loadFromShape` (`src/lib/iptv/ingest/load.ts:69-80`) dispatches: `epg` → empty channel list
shaped from the URL; `xtream` → `loadXtream`; `m3u` → `loadM3u`. `loadM3u`
(`:99-115`) fetches the URL as text; if it isn't `#EXTM3U` **and** `middleware` was true, it
probes `MIDDLEWARE_CANDIDATES = ["/iptv/m3u", "/m3u", "/playlist.m3u",
"/get.php?type=m3u_plus"]` (`:67`, `:117-140`) against the URL's origin until one parses as
M3U.

### 1.4 Xtream → M3U/EPG URLs and live-channel fetch

`XtreamCreds = { base, username, password }` (`xtream.ts:4-8`), `base` = `${protocol}//${host}`
(no path). Live channel listing (`fetchXtreamLiveChannels`, `xtream.ts:206-264`) calls the
JSON API, not an M3U file:
- `apiUrl(creds, "get_live_categories")` and `apiUrl(creds, "get_live_streams")` in parallel
  (`:217-220`) — `apiUrl` = `${base}/player_api.php?username=…&password=…&action=…`
  (`:140-152`).
- Each stream row → `IptvChannel` with `id = `${baseId}::xt::${stream_id}`` (`:251`),
  `tvgId = epg_channel_id?.trim() || null` (`:241`), `group` from the category map,
  `url = buildLiveStreamUrl(creds, stream_id, container, streamBase)`.
- `buildLiveStreamUrl` (`:266-274`): `` `${base}/live/${user}/${pass}/${streamId}.${container}` ``
  (user/pass URI-encoded). `container` defaults to `"ts"`, resolved by
  `pickContainer(pref, allowedFormats)` (`:198-204`, prefers `pref`, else `"ts"`, else
  `"m3u8"`) against `fetchXtreamUserInfo`'s `allowed_output_formats`.
- Catch-up flag: if `tv_archive > 0`, `attrs.catchup = "xtream"` and
  `attrs["catchup-days"] = tv_archive_duration` (`:245-249`).
- Progress: publishes a partial channel array every 512 rows, throttled to once per 750ms
  (`:230-238`), yielding to the event loop each batch.

Auth/caps: `fetchXtreamUserInfo` (`:159-183`) hits the bare `player_api.php?username=…` and
throws `XtreamAuthError` for `auth === 0`, or status `expired`/`banned`/`disabled`.
`deriveStreamBase` (`:185-196`) rewrites the host:port to HTTPS if `server_info.server_protocol
=== "https"`, using `https_port` or `port`.

`XTREAM_UA = "IPTVSmartersPro/3.1.5"` (`:15`) — sent on every Xtream JSON request. Non-JSON
or HTML responses throw `XtreamAuthError` with a specific message
(`parseJsonStrict`, `:124-138`).

M3U-side Xtream: `deriveEpgUrls(playlistUrl)` (`m3u.ts:216-236`) — for a `get.php`/
`player_api.php` URL with `username`/`password`, returns
`[ "${base}/xmltv.php?username=…&password=…", "${base}/get.php?username=…&password=…&type=epg" ]`
(first one preferred; `deriveEpgFromGetPhp` returns just the first).

### 1.5 Fetching (headers, timeouts, error messages)

Playlist text fetch: `fetchM3uText` (`src/lib/iptv/store.ts:203-219`) →
`fetchBoundedText` (bounded limits, §1.7) → `iptvFetch` (`:221-248`): under Tauri, uses
`@tauri-apps/plugin-http`'s `fetch` with `User-Agent: "VLC/3.0.20 LibVLC/3.0.20"`, `Accept:
"audio/x-mpegurl, application/x-mpegURL, application/octet-stream, */*"`,
`connectTimeout: 30_000`ms, `maxRedirections: 5`; falls back to `safeFetch` (CSP-scoped
fetch) on a Tauri scope error; in-browser uses plain `fetch(url, {cache:"no-store"})`.
Xtream JSON fetch uses the same pattern with `User-Agent: XTREAM_UA` and
`Accept: "application/json, */*"` (`xtream.ts:91-122`). XMLTV fetch uses `User-Agent:
"VLC/3.0.20 LibVLC/3.0.20"`, `Accept: "application/xml, text/xml, application/octet-stream,
*/*"` (`xmltv.ts:7-34`).

User-facing HTTP error strings (`store.ts:250-267`, verbatim): 401 → `"HTTP 401: bad
username or password. Check the URL credentials with your provider."`; 403 → `"HTTP 403:
your IP or device is blocked from this playlist. Some providers geo-restrict or
device-limit accounts."`; 404 → `"HTTP 404: playlist URL not found on this server. Check
the URL for typos."`; 429 → `"HTTP 429: provider is rate-limiting your account. Wait a
minute and try again."`; 503 → `"HTTP 503: provider is refusing service right now. Most
common cause: account is at its max-connections limit (other devices/players still logged
in). Close other sessions, or contact your provider if the credentials are valid."`.
Network-error strings (`:269-285`): abort/cancel → `` `Server did not respond (gave up
after ${CONNECT_TIMEOUT_S}s). The provider may be rate-limiting your IP or down.` ``
(`CONNECT_TIMEOUT_S = 30`); DNS → `"Could not resolve playlist hostname. Check the URL for
typos."`; refused → `"Playlist server refused the connection."`; reset → `"Playlist server
reset the connection. Some providers reject generic clients; try with their official app to
confirm credentials work."`.

### 1.6 Refresh cadence and caching

Two independent caches, both keyed by playlist `id`:

**In-memory + IndexedDB** (`src/lib/iptv/store.ts` + `src/lib/iptv/persistent-cache.ts`):
- `IPTV_CACHE_TTL_MS = 6 * 60 * 60 * 1000` (6h) — `isPersistentCacheFresh`
  (`persistent-cache.ts:3,45-50`) gates whether `loadPlaylist` triggers a background
  refetch after returning the cached/restored playlist (`store.ts:80-85`: if stale,
  `fetchPlaylist(src)` fires but the caller isn't blocked on it).
- IndexedDB `harbor-iptv-cache` (v1) / store `entries`, key = `` `${kind}:${sourceId}` ``,
  `kind ∈ {"playlist","xtream-vod","epg"}` (`persistent-cache.ts:5-10,41-43`). Entry shape
  `PersistentIptvCacheEntry<T> = { sourceSignature, savedAt, value }` plus an on-disk
  `schemaVersion: 1` (`:12-20`).
- `iptvSourceSignature(source)` (`:52-67`) = FNV-1a hash (as `` `v1:${hex8}` ``) over
  `[kind, url, epgUrl, xtream.server, xtream.username, xtream.password]` — restoring from
  disk is rejected if the signature no longer matches the current source
  (`store.ts:99-102`).
- A restored/cached playlist is served instantly (`restorePlaylist`, `store.ts:89-112`);
  `loadPlaylist({force:true})` (pull-to-refresh) always refetches and bypasses both caches
  (`:73`).
- Fetch has a hard 5-minute abort timer per attempt (`store.ts:127-133`).
- On success, `writeIptvCache("playlist", …)` persists to IndexedDB (`:153-157`); a
  same-`id` reload while a fetch is in flight reuses the in-flight promise
  (`inflight` map, `:114-117`) unless `force`.
- No periodic/interval auto-refresh was found — refresh only happens on mount (stale-cache
  background refetch), explicit user retry, or the boundary clock (§3, `TICK_MS = 30_000`)
  driving `nowMs` (which does **not** refetch, only recomputes "now").

**EPG** (`src/lib/iptv/epg-store.ts`): in-memory `TTL_MS = 60 * 60 * 1000` (1h,
`:237`, gates `loadEpg` returning the cached index without refetching, `:296-299`);
IndexedDB `DISK_TTL_MS = 12 * 60 * 60 * 1000` (12h, `:238`, gates whether a disk-restored
index is even considered, `restoreFromDisk`, `:277-288` — also requires the restored map to
be no smaller than what's already in memory). EPG fetch progress is streamed into the live
cache every `PROGRESS_PUBLISH_MS = 300`ms so the guide can render partial EPG data while a
multi-MB XMLTV file is still downloading (`:239,305-329`).

### 1.7 Limits

- Generic bounded text fetch (`fetchBoundedText`, `src/lib/iptv/bounded-response.ts:12-20`):
  default `maxBytes = 80 * 1024 * 1024` (80MB), `idleMs = 45_000` (abort if no data for
  45s), `totalMs = 5 * 60_000` (5-minute hard cap) — used for both M3U and Xtream JSON
  fetches (no override passed by either caller, so both get the 80MB/45s/5min defaults).
- XMLTV/EPG fetch (`xmltv.ts:3-5`): `MAX_BYTES = 200 * 1024 * 1024` (200MB),
  `CONNECT_TIMEOUT_MS = 30_000`, `STALL_TIMEOUT_MS = 25_000` (re-armed on every chunk,
  `armStall()`, `:42-49`). Transparent gzip: if the first chunk starts with `0x1f 0x8b`, the
  body is piped through `DecompressionStream("gzip")` (`:72-98`).
- Xtream short-EPG fallback subset: `MAX_CHANNELS = 120` — only the first 120 channels get
  `get_short_epg` calls when the XMLTV source returns nothing
  (`src/views/live/hooks/use-xtream-epg-fallback.ts:6,20`).
- `fetchXtreamShortEpg` limits results server-side via `limit: "8"` query param
  (`xtream.ts:282`).

---

## 2. PARSING

### 2.1 M3U parser (`src/lib/iptv/m3u.ts`)

Entry points: `parseM3u(text, baseId): IptvChannel[]` (`:8-10`, materializes the generator)
and the streaming form `iterateM3uChannels(text, baseId): Generator<IptvChannel>`
(`:12-70`) — a single-pass line scanner (`text.matchAll(/[^\r\n]+/g)`), no external XML/INI
library. Recognized directives: `#EXTM3U` (skipped), `#EXTINF:` (`parseExtinf`, `:87-118`),
`#EXTGRP:` (sets a sticky group carried onto every following entry until reassigned,
`:24-28`), `#EXTVLCOPT:` (`captureVlcOpt`, `:155-166`, only `http-user-agent` →
`attrs["vlcopt-user-agent"]` and `http-referrer` → `attrs["vlcopt-referrer"]`),
`#KODIPROP:` (`captureKodiProp`, `:190-198`, only
`inputstream.adaptive.license_type`/`license_key` → `kodiprop-license-type`/`-key`), any
other `#`-line ignored. A non-`#` line is the stream URL, optionally with a legacy
`url|key=val&key=val` pipe-suffix (`capturePipeOpts`, `:176-188`, recognizes
`user-agent`→`vlcopt-user-agent`, `referer`/`referrer`→`vlcopt-referrer`,
`cookie`→`vlcopt-cookie`, URI-decoded, first-wins if already set by `#EXTVLCOPT`).

`#EXTINF` attribute parsing (`parseExtinf`, `:87-118`) is a token scanner, not regex-per-key:
splits on whitespace outside quotes, `key=value` pairs are lower-cased on the key only,
quoted values may contain spaces (re-joins tokens until the quote closes,
`isClosedQuoted`/`countQuotes`, `:120-130`). The leading bare number (duration in seconds) is
kept only if `i === 0` and parses `> 0`. Title is whatever follows the **last unquoted
comma** in the attrs section (`attrTitleSplit`/`firstUnquotedComma`, `:132-153` — searches
after the last quote close first, then falls back to the raw string).

Attributes read into `IptvChannel.attrs` verbatim (lower-cased keys): `tvg-id`, `tvg-name`,
`tvg-logo` (also plain `logo`), `tvg-chno`, `group-title` (also plain `group`),
`catchup`, `catchup-type`, `catchup-source`, `catchup-days`, `tvg-shift` (read later by the
EPG resolver, §2.3), plus whatever else is present (stored generically — the parser doesn't
allow-list keys). Field derivation per channel (`:57-67`):
- `id` = `` `${baseId}::${tvgId || tvg-name || title || `ch-${autoIndex}`}::${autoIndex}` ``
- `tvgId` = `attrs["tvg-id"] || attrs["tvg-chno"] || null`
- `name` = `attrs["tvg-name"] || title || `Channel ${autoIndex}`` (also used as the
  decorative-row check subject)
- `logo` = `attrs["tvg-logo"] || attrs["logo"] || null`
- `group` = `attrs["group-title"] || attrs["group"] || stickyGroup || null`
- `catchupSource` = `attrs["catchup-source"] || attrs["catchup"] || null`
- `durationSec` = the leading `#EXTINF` number, or `null`

**Decorative-row filtering**: `isDecorativeRow(name)` (`:72-79`) drops an entry whose display
name is empty, is entirely punctuation/box-drawing characters
(`/^[#=─━▓█▀▄░♦◆■▼▲★☆\-_*+~|·•:.\s]+$/`), or has zero letters/digits — playlists routinely
insert `━━━ SPORTS ━━━`-style separator "channels", and these never become `IptvChannel`s.

### 2.2 Channel type

`IptvChannel` has no `type` field; liveness is inferred at consumption time by
`isLiveChannel(ch)` (`src/lib/iptv/vod-classify.ts:11-15`): `false` if `tvg-type`/`type`
attr is `"movie"`/`"series"`, else `false` if the URL matches `/\/(movie|series)\//i`, else
`true`. A finer classifier, `classifyChannel(ch): "live"|"movie"|"series"`
(`:17-41`), is used by the VOD library, not Live TV: checks declared `tvg-type`/`type`
first, then URL path segments (`/series/`, `/movie/`, `/live/`), then file extension
(`VOD_EXT_RE` = `mkv|mp4|avi|m4v|mov|flv|wmv|mpg|mpeg|webm` vs. `LIVE_EXT_RE` = `ts|m3u8`),
then group-name regexes (`MOVIE_GROUP_RE`, `SERIES_GROUP_RE`), then
`parseSeriesEpisode(name)` (SxxEyy-style title detection).

### 2.3 XMLTV parser (`src/lib/iptv/xmltv.ts`)

Hand-written streaming block scanner, not a DOM/SAX library: `drainBlocks(buffer, out,
channelMeta)` (`:153-180`) repeatedly finds the next `<channel ` or `<programme` tag by
`indexOf`, slices out a complete `<channel>…</channel>` or `<programme…>…</programme>`
block once its closing tag is present, and leaves an incomplete trailing block in the
buffer for the next chunk (`trimLeftover`, `:182-184`, keeps at most the last 64 chars when
nothing is pending). Field readers `attr()` (regex `` `\b${name}="([^"]*)"` ``),
`childText()` and `childAttr()` (`:214-246`) walk substrings, not a parser.

`parseChannel` (`:186-193`) reads `id` (required — block dropped if absent), `display-name`
(first `<display-name>`'s text) and `<icon src="…">` → `EpgChannelMeta {displayName, icon}`
(`src/lib/iptv/types.ts:47-50`). A later block for the same `id` is ignored if it has no
name and no icon (`:191`).

`parseProgramme` (`:195-212`) requires `start`, `stop`, `channel` attrs (block dropped if
any missing), builds `EpgProgram` (`types.ts:37-45`):
```ts
export type EpgProgram = {
  channelTvgId: string;
  title: string;
  description: string | null;
  startMs: number;
  endMs: number;
  category: string | null;
  iconUrl: string | null;
};
```
`title` falls back to `"Untitled"` if the `<title>` element is empty/absent; a programme
where `endMs <= startMs` or either bound isn't finite is dropped (`:202`).

**Time format**: `parseXmltvTime(s)` (`:258-271`) — regex
`^(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})\s*([+-]\d{4})?`, i.e. XMLTV's
`YYYYMMDDHHMMSS ±HHMM`. Builds `Date.UTC(...)` from the digits then subtracts the timezone
offset in minutes×60000 to land on a UTC epoch-ms value. No timezone → treated as UTC
(offset 0).

Entity decoding (`decode`, `:247-256`) handles `&lt; &gt; &quot; &apos; &#xHH; &#DD; &amp;`
(amp last, deliberately, since earlier substitutions can introduce literal `&`).
`<![CDATA[...]]>` is unwrapped before decoding (`stripCdata`, `:243-245`).

Streaming fetch (`fetchAndParseXmltv`, `:36-144`) detects gzip by magic bytes on the first
chunk (not by content-type), decodes incrementally with a `TextDecoder`, and calls
`onProgress(delta, channelMeta)` at most once per iteration once 3s has elapsed since the
last emit (`:127-134`).

`indexProgramsByChannel(programs)` (`:273-284`) groups into `Map<tvgId, EpgProgram[]>`
sorted by `startMs`. `findCurrent(arr, nowMs)` (`:286-308`) binary-searches for the program
containing `nowMs`; if none contains it, returns `{current: null, next: arr[lo]}` (the next
upcoming one).

### 2.4 Matching channels → EPG ids (`src/lib/iptv/epg-resolver.ts`)

`epgProgramsForChannel(channel, epg, tvgIdCounts, offsetHours?)` (`:179-209`) resolution
order:
1. **Manual override** — `getEpgOverride(channel.id)` from `epg-map.ts` (localStorage key
   `harbor.iptv.epgmap.v1`, `Record<channelId, tvgId>`, set by the desktop EPG-match modal;
   set/cleared via `setEpgOverride`, cleared per-source via
   `removeEpgOverridesForSource` on `sourceId::` prefix match).
2. **Direct `tvgId` match**, but only if that `tvgId` is unique across the playlist
   (`tvgIdCounts.get(tvgId) <= 1`, computed by `computeTvgIdCounts`, `:225-232`). If it's
   duplicated (multiple channels share one `tvg-id`, common with regional variants), the
   candidate is accepted only if every normalized token of the `tvgId`
   (`normalizeTvgId` splits `._-:` and camelCase, then `tokenize` lower-cases, strips
   non-alnum, drops words < 2 chars and the `NOISE_WORDS` set — `hd fhd uhd 4k sd raw alt
   backup channel channels network tv the and of for us usa uk ca mx br am fm`) either
   appears as a whole word in the channel's own tokenized name, or (if ≥4 chars) as a
   substring of the channel name's alnum-only form (`:198-207`) — otherwise the match is
   rejected (`return undefined`, i.e. no programs at all rather than a wrong guess).
3. **Name fallback** (`nameFallback`, `:211-223`) when there's no `tvgId` or the direct
   lookup found nothing: builds/caches (`WeakMap<EpgIndex, Map<nameKey, tvgId>>`,
   `nameIndexFor`, `:116-136`) an index from every `channelMeta.displayName` and every raw
   `tvgId` in the EPG, keyed by `nameKey()` — Arabic text is normalized+stripped of spaces
   (`hasArabic`/`normalizeArabic` from `rtl.ts`), everything else is lower-cased with
   non-alphanumerics stripped. Requires `nameKey(channel.name).length >= 3`.

**Time shift**: `shiftHours(channel, globalOffset)` (`:143-148`) = channel's own
`attrs["tvg-shift"]` (parsed float) plus the global `iptvEpgOffsetHours` setting
(`epgOffsetHoursPref()` from `settings-bridge.ts`, reads `harbor.settings` directly, default
`0`). Applied via `applyShift` (`:173-177`), which also runs `sanitize()` (`:153-171`) —
dedupes/collapses overlapping programme entries from merged EPG sources by keeping the
longer of two overlapping runs, since duplicate/near-duplicate entries from combined XMLTV
feeds otherwise stack visually in the guide.

---

## 3. LIVE ROOM UI (Big Picture, `src/views/big-picture/bp-live*.tsx`, `bp-guide*`)

### 3.1 Screen composition (`bp-live.tsx`)

`BpLive()` (`:44-248`) renders, top to bottom: a source button + category filter chips band
(hidden during first-run setup), then either `BpLiveSetup` (first run, no playlists yet,
`showSetup = !live.loading && !live.hasPlaylists`, `:137`), or `BpGuide` (the grid, when
channels exist), or an empty-state / loading skeleton grid. `BpLiveSources` is a modal
sheet layered **over** the live guide (never replaces it) for switching/adding playlists
after the first one exists (`:235-245`) — the comment at `:133-136` explicitly warns against
folding the "add" flow back into `showSetup`, since that previously blanked the guide.

Categories (`BpLiveCategory[]`, `:35-91`): slot 0 is always `"Favorites"` (`FAV_KEY = "fav"`,
pinned regardless of rail order so it can't move/vanish), slot 1 is always `"All"`
(`ALL_KEY = "all"`, all live channels), then up to `MAX_CATEGORIES = 30`
(`:24`) more from `live.rails` + `live.categoryRails` (theme rails and per-group rails from
`useLiveHome`), skipping any group the user hid (`useGroupPrefs`, localStorage
`harbor.iptv.groupPrefs.v1`). Group-rail channel lists are **re-derived from the full
channel list** here rather than reused from the rail (a rail caps at 30 channels for the
home-screen carousel; re-deriving avoids silently truncating e.g. a 400-channel "Sports"
category, `:73-81`).

Selected category persists via `useBpPersistedState<string>("liveCategory", ALL_KEY)`
(`:52`) — a Big Picture view-state key, not raw localStorage (see `bp-view-state.ts`, not
opened in this pass).

Channel ordering within a category: `bpGuideOrder()` (`src/views/big-picture/bp-guide-order.ts:24-66`),
five bands, first-match-wins (`taken` set dedupes across bands):
1. Favorites, in their *existing relative order* (deliberately not by star date — `:20-23`
   explains a star-order re-sort would move the row under an active D-pad cursor).
2. Pinned (`usePinnedOrder`, localStorage `harbor.iptv.pins.v1`), in pinned-list order.
3. "Most watched" — `channelPlayCount(ch.id) >= MOST_WATCHED_MIN` (from
   `channel-stats.ts`, localStorage `harbor.iptv.stats.v1`), sorted by play count desc then
   original index.
4. Region-promoted top networks (`rowsForRegion(region)` / `promoteTopChannelsToFront`,
   only when `promoteNetworks` — i.e. only on the "All" category, `bp-live.tsx:110`).
5. Everything else, original order.
Hidden groups are filtered out last, whole-list.

### 3.2 Guide grid layout & geometry (`bp-guide.tsx`, `bp-guide-geometry.ts`)

`guideMetrics(w, h, safe)` (`bp-guide-geometry.ts:41-59`) — recomputed on every
`ResizeObserver` tick of the guide root (`use-bp-guide-layout.ts:15-42`), safe-area aware:
```
colPx    = round(clamp((w - safe.x) * 0.155, 220, 340)) + safe.x   // channel column width
lanePx   = max(1, w - colPx)                                       // guide-row track width
rulerPx  = round(clamp(h * 0.075, 44, 64))                         // time-ruler height
rowPx    = round(clamp(h * 0.155, 88, 128))                        // channel row height
rowsVisible = max(1, floor((h - rulerPx - safe.y) / rowPx))
slotPx   = clamp(w * 0.14, 150, 232)                                // px width of one 30-min slot
pxPerMs  = slotPx / SLOT_MS
visibleMs = max(1, lanePx - safe.x) / pxPerMs
```
Constants (`bp-guide-geometry.ts:1-13`): `SLOT_MS = 30 * 60_000` (30-minute grid slots),
`PAST_PAD_MIN = 60` (window seeds 60 minutes before "now"), `INITIAL_WINDOW_MS = 6h`,
`EXTEND_MS = 3h` (per Right-edge/Left-edge extension step), `MAX_WINDOW_MS = 26h`,
`MIN_CELL_PX = 8` (visual floor for a degenerate empty slice, never applied to `left`),
`CELL_PAD_MS = SLOT_MS` (mount padding on each side of the viewport for virtualization),
`ROW_OVERSCAN = 2` (rows mounted above/below the visible window).

Window management (`bp-guide.tsx:97-116`): `extendWindow()` grows `end` by `EXTEND_MS`
(capped at `MAX_WINDOW_MS` total span); `extendWindowBack()` grows `start` backward by the
same amount and **remounts every lane in the guide** in one commit (every cached lane is
keyed by `${channel.id}:${windowStart}:${windowEnd}`, so a `start` change invalidates
everything — noted as an intentional tradeoff at `:106-108`, with cursor focus restored via
a `pendingRef` re-query pass). Time window seeds via `startOfWindow(Date.now(),
PAST_PAD_MIN)` (`src/views/live/guide/guide-utils.ts`, not opened — rounds to the desktop
guide's own slot boundary function) on first data (`seededRef`, resets on `resetKey` change
= `` `${activeId}:${catKey}` ``, i.e. switching source or category reseeds the window/cursor).

Row virtualization: `bpMountRange(cursorRow, total, rowsVisible)`
(`use-bp-guide-layout.ts:44-56`) centers the viewport on the cursor row (`viewTopRow`), then
mounts `[viewTopRow - ROW_OVERSCAN, viewTopRow + rowsVisible + ROW_OVERSCAN]` clamped to
keep the cursor row itself always mounted. Cell virtualization within a row:
`bpVisibleCells(cells, viewStartMs, visibleMs, keepStart)` (`:58-69`) keeps cells overlapping
`[viewStartMs - CELL_PAD_MS, viewStartMs + visibleMs + CELL_PAD_MS]`, plus the
currently-focused cell even if it's just scrolled out of that range.

Lane building (`use-bp-guide-data.ts`): `buildLane(programs, windowStart, windowEnd)`
(`:33-54`) produces a **gapless, contiguous** cell array — every empty stretch is filled
with synthetic `{program: null}` cells sliced on `SLOT_MS` boundaries (`closeGap`,
`:19-31`, merges gaps under `MIN_GAP_MS = 1000`ms into the previous cell rather than
creating a sliver). This guarantees `cellIndexAt` (binary search, `bp-guide-lane.ts:7-17`)
never returns "nothing" for D-pad nav, and that a no-EPG row still behaves like a normal
timeline (Right/Left pan it 3h at a time instead of jumping across one giant cell). Lane
cache: `Map<string, BpGuideCell[]>` keyed by `${channel.id}:${windowStart}:${windowEnd}`,
capped at `CACHE_MAX = 600` entries (cleared wholesale, not LRU-evicted, on overflow).

### 3.3 Guide cell states (`bp-guide-block.tsx`)

Three paint classes by program timing relative to `nowMs` (`:25-33`, `airing =
startMs<=now<endMs`, `past = cell.endMs<=now`):
- `FUTURE` = `"border border-[--bp-edge-2] bg-[--bp-panel-2] text-ink-subtle"`
- `AIRING` = `"border border-[color-mix(...,--bp-live 45%,transparent)]
  bg-[color-mix(...,--bp-live 14%,--bp-panel-2)] text-ink-muted"`
- `PAST` = `"border border-[--bp-edge] bg-[color-mix(...,--bp-panel-2 45%,transparent)]
  text-ink-subtle opacity-[0.55]"`
Cells with `program == null` (the synthetic gap-fill cells) paint nothing (empty string) and
render no content, so a run of them butts seamlessly.

Width tiers (`:9-10,95-96`): `NARROW_PX = 44` and `FULL_PX = 150` — `width < NARROW_PX` →
`"narrow"` (icon-only chevrons, smaller title font), `< FULL_PX` → `"title"` (title only, no
time range), else `"full"` (title + time range + a live progress bar). `leadsIn`/`runsOut`
chevrons (lucide `ChevronLeft`/`ChevronRight`) show when the program's real bounds extend
past the visible cell slice (a program spanning a window edge or a multi-slot movie). Title
is suppressed if it string-equals the channel name (`bpSameText`, `bp-guide-title.ts`) — an
EPG title that just echoes the channel name is treated as noise; the rectangle still
renders (empty) so lane indexing never breaks.

Live progress bar (`BlockProgress`, `:42-66`) — only rendered when `tier === "full" &&
airing` — is a DOM-only width tween updated on `subscribeBpTick` (10s interval, `bp-live-tick.ts:1`,
`BP_TICK_MS = 10_000`), not React state, to avoid re-rendering the whole grid every tick.

### 3.4 "Now" line and ruler

`BpGuideNowLine` (`bp-guide.tsx:24-54`) is a 2px vertical bar (`background:
var(--bp-live)`) positioned by direct DOM `transform`/`opacity` writes on the same 10s tick
subscription, hidden (`opacity: 0`) when `now` is scrolled outside the visible lane.
`BpGuideRuler` (`bp-guide-ruler.tsx`) draws `slotTicks(windowStart, windowEnd)`
(`bp-guide-geometry.ts:61-65`, one tick per `SLOT_MS`) with `formatTimeLabel` time strings
and day hints (`"Today"`/`"Tomorrow"`/`"Yesterday"`/weekday-short, `dayHint`,
`bp-guide-ruler.tsx:18-27`), plus a `BpGuideNowPill` — a floating "now" label that stays
clamped inside the lane bounds by its own half-width so it's never half-clipped at either
edge (`:29-58`).

### 3.5 Focus / D-pad navigation (`use-bp-guide-nav.ts`)

The channel column has exactly one focusable element per row — the favorite-star button,
never the row/name itself (`bp-guide-row.tsx:17-22`: "a real ten-foot guide has no
focusable channel column, because Left has to mean 'earlier' without a dead end"; Enter on
any program cell tunes the channel regardless of which cell the ring is on). Cell DOM
carries `data-bp-guide-row`, `data-bp-guide-cell="channel"|"program"`, `data-bp-cell-start`/
`-end` (ms) for `queryCell`/`guideMove` to re-locate the target after a remount.

D-pad repeat acceleration (`:34-38`): `RUN_GAP_MS = 260` (press-repeat reset window),
`RUN_SLOT_AT = 4` (after 4 repeats, held Right/Left starts skipping the ruler's slot
granularity), `RUN_BIG_AT = 10` (after 10, jumps `BIG_JUMP_MS = 2h` per step) — "held Left"
acceleration is explicitly disabled in the channel column (`:77-79` comment: "never in the
channel column: a held Left there would [land nowhere in ~800 presses]").
`guideMove` (`:189-218`) is gated off entirely when an overlay/dialog is open
(`bpOverlayOpen()`, `[data-bp-dialog]`) or the guide root is hidden
(`checkVisibility()`-based `rootHidden`, `:43-46`).

Mouse-wheel (`onWheel`, `:257-269`): horizontal wheel deltas pan the view directly
(`panView`); vertical deltas accumulate and convert to discrete `up`/`down` guide moves at
`WHEEL_STEP_PX = 100` per step (`:34`).

### 3.6 Now/next portal, cursor info

`BpGuidePortal` (`bp-guide-portal.tsx`, not fully read — referenced at `bp-guide.tsx:281-291`)
receives the currently-focused channel/program, a formatted title/time-range string built
in `BpGuide` itself (`cursorRange`, `:211-219`, `` `${startLabel} – ${endLabel}${category ? " · "+category : ""}` ``,
or `t("Live")` when there's no program data), and a `dimmed` flag when the cursor sits in
the bottom two on-screen rows (so the portal never covers the row the cursor is actually
on: comment at `bp-guide.tsx:287-289`).

### 3.7 Favorites

`FavoritesProvider`/`useFavorites()` (`src/lib/iptv/favorites.tsx`). Storage key
`harbor.iptv.favorites.v2` (`:4`), legacy read-migrate from `harbor.iptv.favorites.v1`
(id-only array, `:69-89`, merged on read but not deleted — the v1 key is left in place).
`StoredFavorite` (`:8-16`):
```ts
export type StoredFavorite = {
  id: string; name: string; logo: string | null; group: string | null;
  url: string; tvgId: string | null; sourceId: string;
};
```
`sourceId` is derived from the channel id's `::`-prefix (`sourceOf`, `:30-32`). `toggle()`
add/removes by `channel.id`; `hydrate(channels)` backfills a favorite's `url` if it was
empty (covers a favorite added while the playlist was still loading, `:111-124`);
`removeForSource(sourceId)` drops every favorite whose `sourceId` matches or whose id has
that `sourceId::` prefix (called when a playlist source is deleted). Persisted to
localStorage on every `items` change via a plain `useEffect` (`:96-100`), not debounced.

### 3.8 Catch-up / replay — **not wired into Big Picture**

`buildCatchupUrl(ch, startMs, endMs, nowMs?)` (`src/lib/iptv/catchup.ts:98-136`) and
`detectCatchupType(ch)` (`:24-33`, reads `attrs.catchup`/`catchup-type` = `flussonic|fs`,
`xc|xtream`, `append`, `shift|timeshift`, `default`, or infers `xtream` from a URL matching
`XTREAM_LIVE_RX = /^(https?:\/\/[^/]+)\/(?:live\/)?([^/]+)\/([^/]+)\/(\d+)\.(\w+)(?:\?|$)/i`)
exist and are fully implemented (flussonic path-rewrite, Xtream `/timeshift/` URL, and a
generic `${start}`/`${end}`/`${duration}`-template substitution for `catchup-source`), but
`grep` finds these only imported by `src/views/live/guide/guide-view.tsx` and
`src/views/live/hooks/use-live-actions.ts` — the **desktop** live guide.
`handlePlayCatchup` (`use-live-actions.ts:47-64`) builds the catch-up URL and opens the
player with `subtitle: "${ch.name} · catch up"`, still setting `isLive: true` (so mpv still
gets the live cache profile even though it's really a bounded catch-up segment — worth
re-deciding for the native port).

Big Picture's `BpGuideBlock.onPlay` (`bp-guide-block.tsx:125`, wired from
`bp-guide-row.tsx:198`, `onPlay={() => onPlay(row.channel, cell.program)}`) **always** calls
`live.play(channel, program)` → `useBpLivePlay()` (`use-bp-live.ts:68-87`), which always
plays `ch.url` (the live stream) regardless of whether the tapped cell is in the past —
`cell.program` is passed through only as display metadata (`liveProgram: current?.title`),
never used to build a catch-up URL. Tapping a past program in the TV guide currently just
tunes the live channel. `channelHasCatchup`/replay-badge UI (`guide-program-block.tsx:121-183`,
verbatim string `t("Replay")` at `:183`) is desktop-only.

### 3.9 Channel picker inside the player — **desktop only**

`useLiveChannelOverlay` (`src/views/player/hooks/use-live-channel-overlay.ts`) is used only
by `src/views/player.tsx:501` (the desktop player), not by any Big Picture player file
(`src/views/big-picture/player/*` — verified no `channel`/`dvr`/`live`-named file exists
there, and no `isLive`/`liveProgram` reference beyond `use-bp-playback.ts:99` and the "Live"
badge in `bp-player-scrub.tsx:173`). It provides: an in-player source/channel browser
(`open`/`setOpen`, `group`/`query` filter state), `switchChannel(channel, program?)`
(replaces the player src in place, `:104-130`), and `goPrevChannel()` — a 12-entry undo
stack of previously-played `PlayerSrc`s (`prevStackRef`, capped at 12, `:81-102`), bound to
the desktop hotkey `playerPrevChannel` (`use-player-hotkeys.ts:124`,
`use-keyboard-shortcuts.ts:372-375`). **No forward/next-channel cycling exists anywhere in
the codebase** — only "jump back to the previously-tuned channel." Big Picture's player HUD
has no channel picker, no prev/next-channel action, and does not display `liveProgram` at
all (see §4.2) — it's a pure playback shell for live streams beyond the "LIVE" badge.

### 3.10 Multiview — **desktop/Windows only, not Big Picture**

`src/views/multiview.tsx` (251 lines) is a standalone desktop view (imports
`WindowControls`, `useWindowFullscreen`, lucide icons for window chrome) — no Big Picture
import references it. `multiviewSupported()` (`src/lib/multiview/bridge.ts:25-28`) gates on
`isWindowsDesktop()` — **Windows only**, not macOS/Linux Tauri. Each slot is a **separate
native window** layered over the app window at CSS-derived screen coordinates
(`mvOpen(slot, rect, url, userAgent)` → Tauri command `multiview_open` with
`cssLeft/cssTop/cssWidth/cssHeight/cssViewW/cssViewH`), not a single shared render surface;
`mvGeometry`/`mvAudioFocus`/`mvClose`/`mvVisibility`/`mvStopAll` round-trip to
`src-tauri/src/multiview.rs` (not opened in this pass). `MAX_SLOTS = 4`
(`bridge.ts:4`). `Layout = "1"|"2"|"2v"|"3"|"2x2"` (`store.ts:4`), persisted to
localStorage (`harbor.multiview.layout`, `harbor.multiview.split*` — 6 separate numeric
split keys for the various layouts' divider positions, `store.ts:19-24`). `layoutSlotCount`
maps `"1"→1, "2"/"2v"→2, "3"→3, "2x2"→4`. **This entire mechanism is Windows-multi-window
based and has no analog to port** — a tvOS multiview would need a from-scratch design (e.g.
multiple libmpv render contexts composited in one Metal layer), not a translation of this
code.

### 3.11 DVR (record) — desktop only, Tauri-backed

`DvrProvider`/`useDvr()` (`src/lib/dvr/provider.tsx`) is a thin wrapper over Tauri
`invoke`/`listen`, gated by `IS_TAURI` (`:6`) — inert entirely outside Tauri (no web/BP
fallback). `DvrSession`/`DvrStartArgs` (`src/lib/dvr/types.ts:1-21`, verbatim):
```ts
export type DvrSession = {
  id: string; outputPath: string; channelName: string; programTitle: string | null;
  startedAtMs: number; plannedDurationSec: number; bytesWritten: number;
  elapsedSec: number; state: "recording" | "done" | "error"; error: string | null;
};
export type DvrStartArgs = {
  url: string; outputDir: string; filename: string; durationSec: number;
  channelName: string; programTitle: string | null;
};
```
Commands: `dvr_list`, `dvr_start(args)` → session id, `dvr_stop(id)`, `dvr_reveal(path)`,
`dvr_default_dir()`. Events: `dvr://progress` (upsert into `sessions`), `dvr://done` /
`dvr://error` (move from `sessions` to a locally-held `terminal` list, dismissible via
`dismiss(id)`, not synced back to Rust). No Big Picture UI consumes `useDvr()` — the
recording button lives in `src/components/player/live-channel-dvr.tsx` and
`src/components/player/dvr-modal/*` (desktop player transport rail only, not opened further
in this pass beyond confirming the import graph is desktop-scoped).

---

## 4. PLAYBACK

### 4.1 Channel URL → player hand-off

Two call sites build the same shape, both `notWebReady: true`, `isLive: true`:

Big Picture (`src/views/big-picture/use-bp-live.ts:68-87`, `useBpLivePlay`):
```ts
openPlayer({
  meta: synthChannelMeta(ch),
  url: ch.url,
  title: ch.name,
  subtitle: ch.group ?? "Live",
  notWebReady: true,
  isLive: true,
  headers: headersFromChannel(ch),
  liveProgram: current?.title || undefined,
});
```
Desktop (`src/lib/iptv/playback-source.ts:142-166`, `liveChannelSource`, shared by Live TV
and Sports) — identical fields, via a `PlayerSrc` object rather than `openPlayer(...)` args
directly (same downstream shape either way, `src/lib/view.tsx:74-120`).

`headersFromChannel(ch)` (`src/lib/iptv/channel-headers.ts:3-12`) maps M3U-sourced
attributes to HTTP headers, returning `undefined` if none apply: `attrs["vlcopt-user-agent"]
|| attrs["http-user-agent"]` → `User-Agent`; `attrs["vlcopt-referrer"] ||
attrs["http-referrer"]` → `Referer`; `attrs["vlcopt-cookie"]` → `Cookie`.

`isLivePlaybackSrc(src)` (`src/lib/player/live-src.ts:6-11`) — the canonical "is this a live
stream" test used elsewhere in the player stack — is `true` if `isLive === true`, OR
`meta.id` starts with `"iptv:"`, OR `meta.type` (lower-cased) is `"tv"` or `"channel"`. Note
this means **Sports live streams** (which also set `meta.type: "tv"` and route through the
same `liveChannelSource`) are treated identically to IPTV for cache/engine purposes.

### 4.2 Engine choice — no format-based routing at the app level

Per `docs/player-spec.md` §2.12: there is no separate "HLS engine" vs. "mpegts engine"
choice at the Harbor app layer — only `"mpv"` (native, via Tauri) vs. `"html5"` (in-webview
`<video>`, desktop-web fallback only). A native tvOS port with MPVKit always uses the mpv
path; libmpv itself demuxes `.ts`/`.m3u8`/HLS transparently, so there's no
format-dispatch logic to port from the app side. **Exception**: the in-webview HTML5 bridge
(`src/lib/player/html5/bridge.ts:522-550`, web-only, not relevant to tvOS) does its own
sniffing when `notWebReady` — `hls.js` for `.m3u8`/`playlist/` URLs (with
`liveDurationInfinity: true, backBufferLength: 30` when `notWebReady || isLive`), else
`mpegts.js` for `.ts` or any `notWebReady` URL without a recognized container extension
(`mpegts.createPlayer({ type: "mpegts", isLive: true, cors: true }, {
liveBufferLatencyChasing: true, lazyLoadMaxDuration: 4 })`) — dead weight for the tvOS port,
cited only because it's the one place format-sniffing logic exists at all in this codebase.

mpv-side live options (cache, reconnect, quality-filter disabling for live) are fully
documented in `docs/player-spec.md` §2.3 — not repeated here. `MpvStartArgs.is_live:
Option<bool>` (`docs/player-spec.md` §2.13, `src-tauri/src/mpv.rs:41-60`) is the single flag
that selects that whole live cache/reconnect profile; it's set from `PlayerSrc.isLive`
(same field populated by both call sites above).

### 4.3 Player HUD for live — minimal

`use-bp-playback.ts:99`: `live = Boolean(src?.isLive) || Boolean(src?.meta.id?.startsWith("iptv:"))`.
The **only** live-specific HUD element found is the scrub bar (`bp-player-scrub.tsx:140-183`):
the progress-bar fill uses `var(--bp-live)` instead of the plain "ink" color when
`playback.live`, and the time-remaining/ends-at text is replaced with a red-dot **"LIVE"**
badge (`t("Live")`, uppercase, `tracking-[0.16em]`, `var(--bp-live)` color, `:170-176`). No
seek bar interaction was checked beyond that scope. `BpPlayerIdentity`
(`bp-player-identity.tsx:24-58`) shows the channel's clear-logo/title (from `meta.logo`/
`meta.name`) exactly like any other media type — it has no now/next-programme line; the
`episodeLine`/`sourceLine` "quiet" metadata row shows episode code or
resolution/quality/release-group, neither of which applies to live channels, so that row is
typically just empty for live playback. `PlayerSrc.liveProgram` (the current EPG program
title, populated by both call sites in §4.1) is **not read anywhere in the Big Picture
player UI** — its only consumer is `src/views/player/hooks/use-playback-presence.ts:58-94`
(Discord Rich Presence: `` `${liveProgram || meta.name || "Live TV"}` `` as the presence
line, `subtitle: liveProgram ? meta.name : undefined`). **No channel logo, no "now/next
programme" panel, and no channel-up/down control exist in the Big Picture player for live
content** — see §3.9 for the desktop-only channel overlay/hotkey that does show this
context.

---

## 5. TYPES VERBATIM

`src/lib/iptv/types.ts` (full file):
```ts
export type IptvChannel = {
  id: string;
  tvgId: string | null;
  name: string;
  logo: string | null;
  group: string | null;
  url: string;
  catchupSource: string | null;
  durationSec: number | null;
  attrs: Record<string, string>;
};

export type IptvPlaylist = {
  loading?: boolean;
  id: string;
  name: string;
  url: string;
  epgUrl: string | null;
  channels: IptvChannel[];
  fetchedAt: number;
  groups: string[];
};

export type IptvPlaylistSource = {
  id: string;
  name: string;
  url: string;
  epgUrl?: string;
  kind?: "m3u" | "xtream" | "epg";
  xtream?: { server: string; username: string; password: string };
};

export type EpgProgram = {
  channelTvgId: string;
  title: string;
  description: string | null;
  startMs: number;
  endMs: number;
  category: string | null;
  iconUrl: string | null;
};

export type EpgChannelMeta = { displayName: string | null; icon: string | null };

export type EpgIndex = {
  byChannel: Map<string, EpgProgram[]>;
  channelMeta?: Map<string, EpgChannelMeta>;
  fetchedAt: number;
};

export type XmltvParseResult = { programs: EpgProgram[]; channelMeta: Map<string, EpgChannelMeta> };
```

Guide row/cell (`src/views/big-picture/use-bp-guide-data.ts:7`,
`src/views/big-picture/bp-guide-lane.ts:3`, `src/views/big-picture/use-bp-guide-layout.ts:6,8`):
```ts
export type BpGuideRow = { channel: IptvChannel };
export type BpGuideCell = { startMs: number; endMs: number; program: EpgProgram | null };
export type BpGuideCursor = { row: number; kind: "channel" | "program"; cellStart: number };
export type BpGuideMountRange = { viewTopRow: number; mountStart: number; mountEnd: number };
```

Favorites (`src/lib/iptv/favorites.tsx:8-16`):
```ts
export type StoredFavorite = {
  id: string; name: string; logo: string | null; group: string | null;
  url: string; tvgId: string | null; sourceId: string;
};
```

Catch-up (`src/lib/iptv/catchup.ts:15`): `export type CatchupType = "default" | "append" |
"shift" | "flussonic" | "xtream";`

DVR (`src/lib/dvr/types.ts`, full file — see §3.11).

Multiview (`src/lib/multiview/store.ts:4,6-17`, `src/lib/multiview/bridge.ts:6-23`):
```ts
export type Layout = "1" | "2" | "2v" | "3" | "2x2";
export type SlotChannel = { name: string; url: string; userAgent?: string };
export type MultiviewState = {
  slots: (SlotChannel | null)[]; layout: Layout; audioFocus: number;
  split: number; splitRow: number; splitRow2: number; split3a: number; split3b: number;
};
export type CellRect = { slot: number; cssLeft: number; cssTop: number; cssWidth: number;
  cssHeight: number; cssViewW: number; cssViewH: number };
export type OpenRect = { cssLeft: number; cssTop: number; cssWidth: number; cssHeight: number;
  cssViewW: number; cssViewH: number };
```

Provider detection (`src/lib/iptv/ingest/detect.ts:5-9`):
```ts
export type ProviderShape =
  | { kind: "xtream"; creds: XtreamCreds }
  | { kind: "m3u"; url: string; middleware: boolean }
  | { kind: "epg"; url: string }
  | { kind: "invalid"; reason: string };
```

Xtream (`src/lib/iptv/xtream.ts:4-8,10,73-76`):
```ts
export type XtreamCreds = { base: string; username: string; password: string };
export type XtreamContainer = "ts" | "m3u8";
export type XtreamServerCaps = { allowedFormats: string[]; streamBase: string };
```

Playlist form (`src/lib/iptv/playlist-entry.ts:3,5-11`):
```ts
export type PlaylistKind = "m3u" | "xtream" | "epg";
export type PlaylistFormValue = {
  name: string; kind: PlaylistKind; url: string; epgUrl: string;
  xtream: { server: string; username: string; password: string };
};
```

Guide metrics (`src/views/big-picture/bp-guide-geometry.ts:15-24`):
```ts
export type GuideMetrics = {
  pxPerMs: number; lanePx: number; colPx: number; visibleMs: number;
  rowPx: number; rowsVisible: number; rulerPx: number; slotPx: number;
};
```

---

## 6. FRAMEWORK-FREE vs. REACT/DOM/TAURI-BOUND

**Bundleable as-is in the JS engine** (pure TS, no `react`/DOM/`@tauri-apps` imports — only
`type`-only imports of React-adjacent types don't count against this):
- `src/lib/iptv/m3u.ts` — pure string parsing, imports only `type IptvChannel` (`:1`).
- `src/lib/iptv/xmltv.ts` — uses `fetch`/`ReadableStream`/`TextDecoder`/`DecompressionStream`
  (standard Web APIs, no DOM/React) plus one dynamic `import("@tauri-apps/plugin-http")` and
  one dynamic `import("@/lib/safe-fetch")` gated behind `"__TAURI_INTERNALS__" in window`
  (`:8`) — the parsing functions (`parseXmltv`, `drainBlocks`, `parseXmltvTime`,
  `indexProgramsByChannel`, `findCurrent`) have zero framework dependency; only
  `fetchAndParseXmltv`'s transport half touches Tauri, and does so defensively (falls back
  to plain `fetch`).
- `src/lib/iptv/xtream.ts` — same pattern: `xtreamFetchText` has the same Tauri-optional
  dynamic import (`:94`); every other function (URL building, response parsing, base64
  short-EPG decoding) is pure.
- `src/lib/iptv/catchup.ts`, `src/lib/iptv/channel-headers.ts`, `src/lib/iptv/epg-resolver.ts`
  (imports `epg-map.ts` for overrides and `settings-bridge.ts`/`rtl.ts`, both plain
  `localStorage`+regex, no React), `src/lib/iptv/ingest/detect.ts`,
  `src/lib/iptv/ingest/xtream-creds.ts`, `src/lib/iptv/vod-classify.ts` — all pure functions
  over plain data.
- `src/lib/iptv/bounded-response.ts` — Web Streams API only (`fetch`, `AbortController`,
  `ReadableStreamDefaultReader`), no framework.
- `src/lib/iptv/playlists-store.ts`, `src/lib/iptv/epg-map.ts`, `src/lib/iptv/favorites.tsx`
  (the non-JSX exports), `src/lib/iptv/group-order.ts`, `src/lib/iptv/pins.ts`,
  `src/lib/iptv/channel-stats.ts`, `src/lib/iptv/country-prefs.ts` — the read/write/persist
  logic is plain `localStorage` + `JSON`; each additionally exports a
  `useSyncExternalStore`-based React hook (`usePlaylists`, `useEpgMapVersion`,
  `useFavorites`) that is **not** bundleable, but the underlying functions are trivially
  separable (the hooks are thin wrappers, not load-bearing logic).
- `src/lib/iptv/persistent-cache.ts` — `indexedDB` only, no framework.
- `src/lib/iptv/playback-source.ts` — pure object construction; its only import besides
  `IptvChannel` is `type PlayerSrc` (type-only, erased at build time).
- `src/lib/player/live-src.ts` — pure predicate function.

**React/DOM-bound** (would need a from-scratch native-UI reimplementation, not a bundle):
- Every `src/views/big-picture/bp-*.tsx` / `use-bp-*.ts` file — all React components/hooks,
  many reading `ResizeObserver`, `document.querySelector`, DOM `dataset` attributes for
  focus management (`bp-guide-block.tsx`, `use-bp-guide-nav.ts`), or CSS custom
  properties/`clamp()` for ten-foot-safe sizing. None of this transfers to a native
  SwiftUI/UIKit tvOS focus engine — port the **geometry constants and algorithms**
  (§3.2–3.5), not the components.
- `src/lib/dvr/provider.tsx`, `src/lib/multiview/bridge.ts`, `src/lib/multiview/store.ts` —
  Tauri `invoke`/`listen`-bound (desktop-only IPC to Rust); `store.ts`'s pure `clampSplit*`
  helpers and the `Layout`/slot-count constants are the only portable fragments.
- `src/lib/iptv/store.ts`, `src/lib/iptv/epg-store.ts`, `src/lib/iptv/ingest/load.ts` — the
  caching/orchestration logic itself is framework-free, but each has a Tauri-conditional
  fetch branch (same pattern as xmltv.ts/xtream.ts) and is designed around the module-level
  singleton-cache-plus-`useSyncExternalStore` pattern; portable as algorithms, would need
  re-wiring for a different state/subscription model.
- `src/views/player/hooks/use-live-channel-overlay.ts`,
  `src/views/player/live-layer.tsx`, `src/components/player/live-channel-overlay/*`,
  `src/components/player/dvr-modal/*`, `src/components/player/live-channel-dvr.tsx` — all
  React, all desktop-player-only per §3.9/§3.11.

---

## 7. GOTCHAS FOR A NATIVE PORT

1. **Catch-up/replay is desktop-only dead code from Big Picture's perspective.** The
   builder (`buildCatchupUrl`) is complete and framework-free, but nothing in the TV guide
   calls it — tapping a past program just tunes live (§3.8). Decide explicitly whether the
   tvOS guide should wire this up (it would be new integration work, not a port) or
   deliberately match current TV behavior (past cell → live).
2. **No channel up/down exists anywhere**, only "jump back to the last channel" (a 12-entry
   undo stack), and it's desktop-keyboard-only (§3.9). A tvOS remote channel-up/down control
   is new UX, not a port.
3. **The live HUD is nearly bare**: no channel logo, no now/next programme panel, just a red
   "LIVE" badge on the scrub bar (§4.2). `liveProgram` is threaded all the way from channel
   selection into `PlayerSrc` but is only ever read by the Discord presence hook — if the
   Stage 8 design wants a now/next overlay in the native player, that's fresh design work;
   the *data* (`liveProgram`, and full EPG lookups via `epgProgramsForChannel`) is already
   available at hand-off time.
4. **Multiview has no portable implementation.** It's Windows-only, built from N separate
   OS-level windows geometrically stacked over the app window and driven by Tauri IPC per
   frame of movement (§3.10). A tvOS "up to 4" grid needs a genuinely new design — most
   likely N libmpv render contexts composited into one view — with only the layout
   constants (`MAX_SLOTS=4`, the four `Layout` variants, split-ratio bounds) as reusable
   reference.
5. **DVR is 100% Tauri `invoke`/`listen` IPC** to a Rust recorder with no in-JS recording
   logic to port (§3.11) — the tvOS equivalent will need its own native recording pipeline
   (e.g. writing the mpv demux stream to disk, or a parallel HTTP pull), with only the
   `DvrSession`/`DvrStartArgs` shape and event semantics (`progress`/`done`/`error`) as a
   contract reference.
6. **`isLive: true` is set for catch-up playback too** (`use-live-actions.ts:59`) — i.e. the
   existing code conflates "should use the mpv live cache/reconnect profile" with "is a live
   channel." A catch-up/VOD-from-timeshift stream is finite and seekable; reusing the live
   cache profile for it (`cache-secs=30`, no seeking assumptions, aggressive reconnect) may
   be wrong for a native catch-up player and is worth re-deciding rather than copying as-is.
7. **Xtream credentials are stored in two places for the same playlist**: both structured
   (`xtream: {server,username,password}`) and pre-built into `url`/`epgUrl` query strings
   (§1.2) — the native port's storage model should decide which is the source of truth
   rather than keeping both in sync by convention as Harbor does.
8. **EPG channel matching can silently return zero programs** for a channel whose `tvg-id`
   is duplicated across the playlist and whose name doesn't share tokens with that id
   (§2.4, step 2) — this is deliberate (avoids a wrong-channel EPG match) but means "channel
   has an EPG id" doesn't guarantee "channel shows programme data"; the guide's `null`
   program / gap-cell path (§3.2) must be exercised for real playlists, not just for
   genuinely EPG-less channels.
9. **The lane cache invalidates completely on `extendWindowBack`** (§3.2) — scrolling
   backward in time remounts the entire visible guide in one commit. On tvOS this is worth
   watching for frame drops with large channel counts; the JS implementation accepts this
   and recovers focus via a deferred re-query rather than avoiding the remount.
10. **Decorative/separator rows in M3U playlists are silently dropped** during parsing
    (`isDecorativeRow`, §2.1) — a common IPTV playlist convention (channels named `━━━
    SPORTS ━━━` as section headers) that a from-scratch parser would need to replicate or
    channel counts/ordering will visibly differ from Harbor's.
11. **`favicon`/logo, catch-up, and EPG override UI (the "match channel to EPG id" modal,
    `src/views/live/guide/epg-match-modal.tsx`) were not opened in this pass** — only its
    storage contract (`epg-map.ts`) was read. If the native port needs a manual
    EPG-remapping UI, that screen's UX is **not found** in this document and needs a
    separate pass.
12. **No periodic background refresh** of playlists or EPG was found (§1.6) — a native
    tvOS app that wants channel-list/EPG data to self-heal while idle (e.g. overnight)
    would need to add its own scheduler; Harbor relies entirely on next-open staleness
    checks and manual retry.
