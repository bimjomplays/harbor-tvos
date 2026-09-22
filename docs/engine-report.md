# HarborEngine — Stage 2 (browse rooms) bundle report

How much of upstream Harbor's `src/lib` the Apple TV app can reuse instead of re-implementing
it in Swift, what the native side has to provide for it to run, and what it exports.

- Upstream: `reference/harbor` (submodule, `beta-branch` @ `1bfcfb6`)
- Bundler: `engine/build.mjs` → `engine/dist/harbor-engine.js`
- Verified by: `cd engine && node build.mjs && node test/shims.test.mjs && node smoke.mjs`
  (117 + 50 checks, live network against Cinemeta / ani.zip / the Stremio API)

Nothing from upstream is copied into `engine/`. Every module is imported through the `@/`
alias, so bumping the submodule and re-running `node build.mjs` picks up upstream's changes.

## 1. Numbers

| | |
|---|---|
| bundle (readable) | **923 KB** (204 KB gzip) |
| bundle (minified) | **545 KB** (162 KB gzip) |
| modules in the bundle | 1,114 = 955 upstream + 130 vendor + 29 engine (11 shims, 3 Tauri stubs, 2 React stubs, 12 asset stubs, `entry.ts`) |
| evaluation in a cold JS context | **9 ms** median (Node vm; 181 ms measured on the tvOS simulator for the 89 KB Stage-0 bundle, so expect roughly 0.5–1 s there) |
| `benchmark(50)` — 850 streams parse→trust→score→rank | 58 ms |
| smoke run | 50 checks, 23 HTTP requests, 4.1 MB |

Where the bytes go (output bytes, readable build):

| area | KB | note |
|---|---|---|
| upstream `lib/theme.ts` + `theme-kawaii.ts` | 130 | **dead weight**: CSS/HTML/JS strings for desktop themes, pulled in only because `settings/defaults.ts` imports `DEFAULT_THEME` |
| upstream `lib/i18n/locales/en` | 131 | the English UI strings; useful later, free to keep |
| core-js `URL` + `URLSearchParams` | 162 | see §3 |
| upstream `lib/streams` | 70 | Stage 0.4 stream engine, still exported |
| upstream `lib/providers` | 83 | TMDB / OMDb / Fanart / RPDB / ani.zip |
| upstream `lib/feed` | 57 | Home rails |
| upstream `lib/settings` | 33 | 482-key Settings type + sanitiser |
| engine shims | 37 | §3 |

Trimming the theme strings (an esbuild stub for `@/lib/theme` that exports only the token
object) would save ~130 KB; it is not done yet because `Settings.theme` is a real part of the
sanitiser's contract.

## 2. Module survey

`react` and `@tauri-apps/*` are replaced by stubs whose every function **throws**. A module
that mixes pure helpers with a hook is imported for the helpers only; if a hook is ever
reached it raises `HarborEngine: react.useX() was called, but tvOS has no React`. No stub
returns a plausible value.

| upstream module | verdict | what it touches |
|---|---|---|
| `lib/addons.ts` | **bundled** | `fetch`, `URL`, `localStorage`, timers. Pulls `addon-store.ts` → `auth.tsx` → `profiles.tsx`: the two `.tsx` files are in the bundle but only their non-hook functions are used |
| `lib/addon-store.ts` | **bundled** | `localStorage` (installed/disabled addons, per profile) |
| `lib/cinemeta.ts` | **bundled** | `fetch`, `localStorage` (`harbor.settings` for the enable flag, `harbor.cinemeta.meta.v1` cache) |
| `lib/stremio.ts` | **bundled** | `fetch` (POST JSON to `api.strem.io`), `localStorage`. Imports `anime-detect.ts` which imports React — only its pure `isDetectedAnime` is used |
| `lib/safe-fetch.ts` | **bundled, Tauri branch dead** | reads `window.location.hostname`; with the shim's hostname (`engine.harbor-tvos.local`) both the Tauri branch and the harbor.site `/api-proxy` rewrite are off, so **every request goes straight out through the host**. Upstream's tracker blocklist still applies |
| `lib/secret-store.ts` | **bundled, degrades by design** | `invoke("secrets_read")` throws → upstream's own `rustAvailable = false` branch takes over and reads/writes plain `localStorage`. On tvOS Swift routes the secret key prefixes to the Keychain, which is what we want |
| `lib/debug.ts` | **bundled** | `import.meta.env.DEV` is defined to `false`, so `dlog/dinfo/dwarn` compile to no-ops |
| `lib/uuid.ts` | **bundled** | `crypto.randomUUID` / `crypto.getRandomValues` (both shimmed) |
| `lib/view.tsx` | **not bundled** | 1,672 lines of React context, refs and a router. Its value is the `View` / `Frame` / `MetaFilter` **type** union, which SwiftUI must mirror by hand. It also owns `harbor:scroll-top` and `harbor:reset-row-scrolls` (§6) |
| `lib/settings/types.ts` | **bundled** | types only |
| `lib/settings/defaults.ts` | **bundled** | pure data; drags in `lib/theme.ts` (see §1) |
| `lib/settings/load.ts` | **bundled** | `localStorage`, `Intl`, `document.documentElement` (via `i18n/store`) |
| `lib/settings/profile-store.ts` | **bundled** | `localStorage`, per-profile settings keys |
| `lib/providers/tmdb.ts` (barrel) | **bundled** | `fetch`, `URL`, `structuredClone`, `AbortController`, timers. The barrel also re-exports four React hooks (`useTmdbImdbId`, `useTmdbIdFromImdb`, `useTmdbVote`) — they are in the bundle but throw if called |
| `lib/providers/tmdb/tmdb-client.ts` | **bundled, one caveat** | if a response arrives still gzipped it tries `new Blob(...).stream().pipeThrough(new DecompressionStream("gzip"))`. There is no `Blob` on tvOS, the `ReferenceError` is caught by upstream's own `try`, and it falls back to `TextDecoder`. **The host must therefore transparently decompress `Content-Encoding: gzip`** (NSURLSession does) |
| `lib/providers/fanart.ts`, `rpdb.ts` | **bundled** | pure + `fetch`; no imports at all |
| `lib/providers/omdb.ts` | **bundled** | `localStorage` (budget + cache); exports two React hooks that throw |
| `lib/providers/anizip.ts` | **bundled** | `fetch`, `URL` |
| `lib/providers/service-catalog.ts` | **bundled** | TMDB-backed streaming-service rails |
| `lib/region/locale-map.ts` | **bundled** | pure data over `lib/i18n/languages` |
| `lib/feed/**` | **bundled** | the whole barrel: pool, shelves, daily rows, saved, and the 11 named TMDB sections |
| `lib/discover/index.ts` | **not bundled (the barrel)** | its only own export is the `useDiscover` React hook. The three pure files beneath it — `discover/store.ts`, `discover/affinity.ts`, `discover/profile.ts` — **are** bundled and give the same data |
| `lib/search.ts`, `search-addons.ts`, `search-query.ts` | **bundled** | the Search room. `searchAll` needs a TMDB key; `searchCinemeta` and `searchAddonCatalogs` work without one |
| `lib/platform.ts` | **not bundled** | `@tauri-apps/plugin-os`; Swift knows the platform |
| `lib/i18n/store.ts` | **bundled** | writes `document.documentElement.dir/lang` at import time — the only reason `document.documentElement` exists in the shim |

### Web APIs the bundled code needs that JavaScriptCore does not have

`fetch` · `Headers` · `Request` · `Response` · `URL` · `URLSearchParams` · `TextEncoder` ·
`TextDecoder` · `AbortController` · `AbortSignal` · `DOMException` · `Event` · `CustomEvent` ·
`EventTarget` · `crypto.randomUUID` · `crypto.getRandomValues` · `crypto.subtle.digest` ·
`localStorage` · `sessionStorage` · `setTimeout` · `setInterval` · `queueMicrotask` ·
`structuredClone` · `atob` · `btoa` · `performance.now` · `console` · `window` · `document` ·
`navigator` · `location`.

`Intl` and `Promise` come from JSC itself. Not needed and not shimmed: `Blob`, `Worker`,
`WebSocket`, `indexedDB`, `FormData`, `DecompressionStream`, `MutationObserver`,
`IntersectionObserver` — every reference to them in the bundle is either inside a dead
desktop branch or inside a theme string.

## 3. Host contract — `globalThis.__harbor_host`

Swift installs this object on the `JSContext` global **before** evaluating
`harbor-engine.js`. `HarborEngine.runtime.missingHostFunctions()` must return `[]` before
anything else is called. Reference implementation for Node: `engine/shims/node-host.mjs`.

| function | signature | semantics |
|---|---|---|
| `fetch` | `(req: HostRequest) => Promise<HostResponse>` | performs the HTTP request. **Must** follow redirects unless `req.redirect` is `"manual"`/`"error"`, transparently decompress `Content-Encoding`, and reject (not resolve) on a transport failure. Resolving with a 4xx/5xx is correct and normal |
| `abort` | `(requestId: number) => void` | cancels the in-flight request with that id. Called when an `AbortSignal` fires |
| `storageSnapshot` | `() => Record<string, string>` | **every** `harbor.*` key/value at boot. Optional but strongly preferred: it makes `localStorage` reads pure memory. Without it the shim falls back to `storageGet` per key |
| `storageGet` | `(key: string) => string \| null` | **synchronous.** Upstream reads settings and caches synchronously; there is no async escape |
| `storageSet` | `(key: string, value: string) => void` | synchronous write-through. May persist lazily, but a later `storageGet` must see it |
| `storageRemove` | `(key: string) => void` | synchronous |
| `storageClear` | `() => void` | drops every key. Only reached through an explicit reset |
| `now` | `() => number` | wall clock, epoch milliseconds, float. Backs `performance.now()` (as a delta from boot) |
| `randomUUID` | `() => string` | RFC 4122 v4, lowercase, 36 chars. If it returns anything else the shim falls back to `randomBytes` |
| `randomBytes` | `(n: number) => string` | `n` cryptographically random bytes, **base64** (a string survives the JSC↔Swift boundary; a typed array does not). Backs `crypto.getRandomValues` |
| `log` | `(level: "log"\|"info"\|"warn"\|"error"\|"debug", msg: string) => void` | every `console.*` call, already flattened to one string |
| `setTimeout` | `(delayMs: number, id: number) => void` | schedule a native timer. When it fires the host **must** call `globalThis.__harbor_timer_fire(id)` on the JS thread. Repeating timers are re-armed by the shim, so the host never repeats on its own |
| `clearTimeout` | `(id: number) => void` | cancel a scheduled timer; a stale id is a no-op |

```ts
type HostRequest = {
  requestId: number;          // pair with abort()
  url: string;
  method: string;             // already upper-cased
  headers: Record<string, string>;  // lower-cased names
  body: string | null;        // textual body
  bodyBase64: string | null;  // binary body; exactly one of the two is non-null
  responseType: "text" | "base64";
  redirect: "follow" | "manual" | "error";
  timeoutMs: number;          // default 30000
};

type HostResponse = {
  status: number;             // required
  statusText?: string;
  headers?: Record<string, string>;
  url?: string;               // final URL after redirects
  redirected?: boolean;
  body?: string | null;       // when responseType === "text"
  bodyBase64?: string | null; // when responseType === "base64"
};
```

Rejecting `fetch` with an object carrying `name: "AbortError"` or `"TimeoutError"` is
turned back into a `DOMException` with that name; anything else becomes a `TypeError`, which
is what a browser `fetch` does on a network failure — upstream's `.catch(() => null)`
handlers depend on this.

### JS → Swift

| | |
|---|---|
| `globalThis.__harbor_timer_fire(id)` | the host calls this when a native timer expires |
| `HarborEngine.runtime.onEvent(fn)` | observe every event upstream dispatches on `window`; returns an unsubscribe |
| `HarborEngine.runtime.emitEvent(type, detail?)` | dispatch an event into the bundle |
| `HarborEngine.runtime.syncStorage(key, value)` | tell the bundle a key changed underneath it (e.g. after an account sync) |
| `HarborEngine.runtime.selfTest()` | proves URL, storage, crypto, Intl, timers and a real `fetch` all work |

### What the shims deliberately do NOT fake

- `crypto.subtle` implements **only** `digest("SHA-256")` (pure JS, matches Node bit for bit).
  Any other algorithm rejects.
- `structuredClone` is a JSON round-trip and **throws** on `Map` / `Set` / `Date` / typed
  arrays rather than silently losing them.
- `Response.blob()` throws; `arrayBuffer()` works.
- `document` has `documentElement` (a no-op attribute holder, because `i18n/store` writes
  `dir`/`lang` at import time) and nothing else. `createElement`, `body` and `querySelector`
  are absent on purpose, so a UI module pulled in by mistake fails loudly.
- `setTimeout` with a string body throws (no `eval`).

### Why core-js for `URL`

`URL`/`URLSearchParams` come from `core-js/web/url` rather than a hand-written parser. It is
162 KB, which is the single biggest vendor cost, and it is worth it: it is a full WHATWG
implementation including IDNA/punycode and IPv4 canonicalisation.
`engine/test/shims.test.mjs` differential-tests it against Node's own `URL` over 32 cases —
relative resolution (`../`, `./`, `//host`, `?query`, `#hash`, empty), default-port dropping,
userinfo, backslashes, IPv6 literals, `%`-escapes, uppercase schemes, non-special schemes
(`stremio:`, `data:`, `mailto:`) and unicode (`https://日本.example/パス?検索=値` →
`https://xn--wgv71a.example/%E3%83%91%E3%82%B9?...`) — plus 12 `URLSearchParams` cases and
5 must-throw cases. All match Node exactly.

## 4. `localStorage` keys

The bundle references **85** distinct `harbor.*` keys (plus three built from a template).
Swift's `KeyValueStore` must route them; the ones the browse rooms actually touch:

| key | written by | contents |
|---|---|---|
| `harbor.settings` | settings | the 482-key `Settings` blob (~13 KB serialised), also the legacy mirror |
| `harbor.settings.shared` | settings | settings shared by linked profiles |
| `harbor.settings.<profileId>` | settings | per-profile settings |
| `harbor.profiles.v1` | profiles | `{ activeId, profiles: [...] }`. Read by the addon store to scope its keys |
| `harbor.installed-addons.<profileId>` | addon-store | locally installed addons (array of `{ transportUrl, manifest? }`) |
| `harbor.installed-addons` | addon-store | legacy, migrated on first read |
| `harbor.addons.disabled.<profileId>` / `harbor.addons.disabled` | addon-store | disabled transport URLs |
| `harbor.addons.seeded.v1` | addon-store | first-run seeding marker |
| `harbor.addonOrder` | addons-store/reorder | display order |
| `harbor.cinemeta.meta.v1` | cinemeta-cache | meta LRU |
| `harbor.discover.v1`, `harbor.discover.events.v1`, `harbor.discover.rows.v1` | discover | taste profile |
| `harbor.feed-prefs.v2`, `harbor.feed.saved`, `harbor.heroPool.v1` | feed | Home rails state |
| `harbor.tmdb.imdb.v1`, `harbor.tmdb.find.v1`, `harbor.imdb.tmdb.v1` | tmdb-imdb-resolve | id bridges |
| `harbor.omdb.v1`, `harbor.omdb.budget`, `harbor.omdb.misses` | omdb | scores + the daily request budget |
| `harbor.resume`, `harbor.playback-history.v1` | resume | local progress, read by the CW helpers |
| `harbor.auth.<profileId>` | auth | the Stremio auth key |
| `harbor.parental` | parental | gate state |

Secret prefixes (`harbor.trakt.session.v1`, `harbor.simkl.session.v1`,
`harbor.mal.session.v1`, `harbor.anilist.session.v1`, `harbor.lastfm.v1`,
`harbor.media-server.token.v1`, `harbor.plex-auth.device.v1`,
`harbor.sports.api-sports.v1`, each optionally `.<profileId>`) go through
`HarborEngine.secretStore` and **must** be routed to the Keychain, not UserDefaults.
`HarborEngine.secretStore.isSecretKey(key)` is the authoritative test.

`engine/smoke.mjs` prints the exact key set a run touched.

### Settings defaults

`HarborEngine.settings.DEFAULT` is the live object — 482 keys (435 scalar, 47 structured),
13,354 characters serialised. It is data, not a copy: it is `lib/settings/defaults.ts`
itself, so it tracks upstream. The ones the browse rooms care about:

| key | default |
|---|---|
| `tmdbKey`, `omdbKey`, `fanartKey`, `rpdbKey`, `tvdbKey` | `""` (user-supplied) |
| `rdKey`, `tbKey`, `adKey`, `pmKey`, `dlKey` | `""` (debrid) |
| `cinemetaEnabled` | `true` |
| `region` | `"US"` |
| `uiLanguage` | `"en"` |
| `tmdbLanguage` | `""` (follow `uiLanguage`) |

`settings.load()` runs upstream's full sanitiser, so an empty or corrupt store still yields a
valid `Settings`. Never hand-merge a partial blob — go through `settings.patch()` or
`settings.saveForProfile()`.

## 5. Exported API — `HarborEngine.*`

Signatures are upstream's own. `Meta`, `Addon`, `AddonRow`, `CatalogDef`, `LibraryItem`,
`User` and `Settings` are re-exported as types.

### `HarborEngine.addons`
```ts
gatherCatalogAddons(authKey: string | null): Promise<Addon[]>
loadAddonRows(authKey: string | null, opts?: { dedup?: boolean; cap?: number }): Promise<AddonRow[]>
fetchCatalogRow(addon: Addon, cat: CatalogDef): Promise<AddonRow | null>
fetchAddonMeta(base: string, type: string, id: string): Promise<Meta | null>
fetchAddonCatalogPage(base: string, type: string, id: string, skip: number,
                      extras?: Array<{ name: string; value: string }>): Promise<Meta[]>
createAddonCatalogFetcher(cursor: AddonCatalogCursor,
                          opts?: { initialPageSize?: number; mapMeta?: (m: Meta) => Meta })
                          : (page: number, loaded?: number) => Promise<Meta[]>
dedupeAddonRows(rows: AddonRow[], cap: number): AddonRow[]
contentCatalogs(addon: Addon): CatalogDef[]
isCollectionCatalog(c: { type?: string; id?: string; name?: string }): boolean
addonAccepts(addon: Addon, resource: string, type: string, id: string): boolean
addonBasesForOrigin(addons: Addon[], origin: AddonOrigin | undefined): string[]
normalizeName(name: string, type: string): string
hasTmdbProviderAddon(addons: Addon[]): boolean
userAddons(authKey: string): Promise<Addon[]>
setUserAddons(authKey: string, addons: Addon[]): Promise<boolean>
getUserAddonsRaw(authKey: string): Promise<Addon[] | null>
setUserAddonsRaw(authKey: string, addons: Addon[]): Promise<boolean>
torrentioAddonFor(keys: DebridKeySet): Addon
torrentioBareAddon(): Addon
torboxAddonFor(tbKey: string): Addon | null
withDebridKeys(addons: Addon[], keys: DebridKeySet): Addon[]
```

### `HarborEngine.addonStore`
```ts
loadInstalled(): InstalledAddon[]
filterEnabled<T extends { transportUrl: string }>(items: T[]): T[]
isAddonEnabled(transportUrl: string): boolean
setAddonEnabled(transportUrl: string, enabled: boolean): void
isInstalled(id: string): boolean
transportUrlFor(id: string): string | null
parseAddonUrl(input: string): AddonUrlParse
fetchManifestAt(transportUrl: string): Promise<Addon["manifest"]>
installAddon(id: string, transportUrl: string): Promise<Addon>
installFromUrl(rawUrl: string, options?: { replaceId?: string }): Promise<InstallResult>
uninstallAddon(id: string, transportUrl?: string): Promise<void>
fetchInstalledAddons(): Promise<Addon[]>
reorderInstalled(urlSequence: string[]): void
seedDefaultAddonsIfFirstRun(): Promise<void>
manifestToConfigureUrl(transportUrl: string): string
manifestToShareUrl(transportUrl: string, scheme?: "https" | "stremio"): string
loadDisabledAddons(): Set<string>
```

### `HarborEngine.cinemeta`
```ts
topMovies(genre?: string, skip?: number): Promise<Meta[]>
topSeries(genre?: string, skip?: number): Promise<Meta[]>
meta(type: "movie" | "series", id: string, force?: boolean): Promise<Meta | null>
enabled(): boolean
narrowMediaType(t: MetaType | string | undefined): "movie" | "series"
isAddonNativeMeta(meta: Meta): boolean
hasEmbeddedStreams(videos: Meta["videos"]): boolean
persistableVideos(videos: unknown): Meta["videos"]
persistableAddonOrigin(origin: unknown): AddonOrigin | undefined
```

### `HarborEngine.stremio`
```ts
login(email: string, password: string): Promise<{ authKey: string; user: User }>
logout(authKey: string): Promise<unknown>
getUser(authKey: string): Promise<User>
library(authKey: string): Promise<LibraryItem[]>
libraryIfChanged(authKey: string): Promise<LibraryItem[]>
libraryGetOne(authKey: string, id: string): Promise<LibraryItem | null>
libraryGetOneStrict(authKey: string, id: string): Promise<LibraryItem | null>
libraryPut(authKey: string, item: LibraryItem): Promise<void>
removeLibraryItem(authKey: string, id: string): Promise<void>
invalidateLibraryCache(): void
saveBookmark(authKey: string, id: string,
             input: { type?: string; name?: string; poster?: string }): Promise<void>
removeBookmark(authKey: string, id: string): Promise<void>
continueWatching(authKey: string): Promise<LibraryItem[]>   // engine-added: filter + sort
isCwMember(i: LibraryItem): boolean
cwSortKey(i: LibraryItem): number
cwMemberViaResume(i: LibraryItem): boolean
isAnimeCwItem(i: LibraryItem): boolean
episodeFromVideoId(videoId?: string | null): { season: number; episode: number } | null
resumeSourceForItem(i: LibraryItem): "simkl" | "trakt" | undefined
libraryMetaType(t: string): MetaType
cloudWriteId(metaId: string, resolved: string | null, verified: boolean): string | null
CLOUD_OK: RegExp; ANIME_CLOUD_ID: RegExp
```

### `HarborEngine.tmdb`
Upstream has **no global TMDB key**: every call takes the user's key (`Settings.tmdbKey`) as
its first argument. Only `setLanguage` is global state.
```ts
API_BASE: "https://api.themoviedb.org/3";  IMAGE_BASE: "https://image.tmdb.org/t/p"
setLanguage(lang: string): void;  language(): string;  languageIso(): string
movieRow(key, endpoint: "popular"|"top_rated"|"now_playing"|"upcoming",
         region?: string, page?: number): Promise<Meta[]>
seriesRow(key, endpoint: "popular"|"top_rated"|"airing_today"|"on_the_air",
          page?: number): Promise<Meta[]>
trending(key, type: "movie"|"tv", window?: "day"|"week", page?: number): Promise<Meta[]>
discover(key, type: "movie"|"tv", params: Record<string,string>): Promise<Meta[]>
searchMovie(key, query: string, year?: number): Promise<Meta | null>
searchTitle(key, type: "movie"|"series", query: string, year?: number): Promise<Meta | null>
details(key, meta: Meta, lang?: string): Promise<TmdbDetail | null>
seasonEpisodes(key, tvId: number, seasonNumber: number, lang?: string): Promise<Episode[]>
images(key, metaId: string): Promise<string[]>
logo(key, metaId: string, originalLang?: string | null): Promise<string | undefined>
trailer / trailerList / critic / person / personIdByName / creditToMeta
keywordIdByName / resolveKeywordIds / companyIdByName / companyArt
collection(key, id: number): Promise<TmdbCollection | null>
collectionsFeed(key, page: number): Promise<{ hits: CollectionHit[]; totalPages: number }>
episodeGroups / episodeGroup / episodeNames
watchProviders(key, kind: "movie"|"tv", id: number|string, region: string): Promise<WatchProvider[]>
imdbId(key, metaId: string): Promise<string | null>
imdbIdCached(metaId?: string): string | null | undefined
idFromImdb(key, imdbId: string, type?: "movie"|"series"): Promise<string | null>
idFromImdbCached(imdbId?: string): string | null | undefined
```

### `HarborEngine.serviceCatalog`, `.providers`
```ts
serviceCatalog.CATEGORIES: Category[];  serviceCatalog.MAX_PER_BUCKET: number
serviceCatalog.fetchCategoryBatch(key, providerIds: string, region: string,
                                  cat: Category, batch: number, perBatch?: number): Promise<Bucket>
serviceCatalog.dedupe(metas: Meta[]): Meta[]

providers.fanartMovie(key, tmdbId: number): Promise<FanartArt | null>
providers.fanartTv(key, tvdbId: number): Promise<FanartArt | null>
providers.rpdbPoster(key, metaId: string, fallback?: string, altId?: string): string | undefined
providers.rpdbSetPosterBaseUrl(url: string): void
providers.rpdbNeedsImdb(key, metaId: string): boolean
providers.rpdbNeedsTmdb(key, metaId: string): boolean
providers.omdbScores(key, imdbId?: string, type?: string): Promise<OmdbScores | null>
providers.omdbScoresCached(imdbId?: string): OmdbScores | null
providers.omdbPrefetch(key, imdbId?: string, type?: string): Promise<void>
providers.omdbSeasonRatings(key, imdbId?: string, season?: number): Promise<Map<number, number>>
providers.omdbBudget(): OmdbBudget
providers.aniZipByKitsu|ByMal|ByAnilist|ByImdb|ByTmdbTv(id): Promise<AniZipMapping | null>
providers.aniZipPickEpisodeTitle(ep): string | null
providers.aniZipPickLocalizedTitle(ep, lang?: string | null): string | null
```

### `HarborEngine.search`
```ts
all(key: string, query: string, opts?: { excludeGenres?: number[] }): Promise<SearchResults>
cinemeta(query: string): Promise<{ movies: Meta[]; series: Meta[] }>   // no key needed
anime(query: string, limit?: number): Promise<AnimeHit[]>
liveTv(query: string, iptvPlaylists: StoredPlaylist[], limit?: number): LiveTvHit[]
addonCatalogs(addons: Addon[], query: string): Promise<{ movies: Meta[]; series: Meta[] }>
addonGroups(addons: Addon[], query: string,
            onGroup?: (g: AddonResultGroup) => void,
            onQuery?: (q: AddonQuery) => void): Promise<AddonResultGroup[]>
mergeMetas(primary: Meta[], extra: Meta[], cap?: number): Meta[]
detectIntent(query: string): SearchIntent
normalizeQuery(q: string): string
```

### `HarborEngine.feed`, `.discover`
```ts
feed.getPool(tmdbKey: string): Promise<FeedItem[]>
feed.buildPool(tmdbKey: string): Promise<FeedItem[]>
feed.extendPool(tmdbKey: string, page: number): Promise<FeedItem[]>
feed.pickShelves(tmdbKey: string, n?: number): Shelf[]
feed.fallbackShelves(): Shelf[]                           // works with no TMDB key
feed.selectDailyRows(tmdbKey: string, affinity: Affinity, settings: Settings,
                     count?: number, now?: Date): RailDef[]
feed.isSaved(id: string): boolean;  feed.toggleSaved(id: string): boolean
feed.fetchFeatured | fetchCriticsPickList(tmdbKey, settings?): Promise<Meta[]>
feed.fetchUnderNinety | fetchRecentlyAdded | fetchComingSoon | fetchInTheaters |
    fetchTopRated | fetchTrendingWeek | fetchTopSeries | fetchDocumentaries(tmdbKey, page?)
feed.fetchGenreSample(tmdbKey: string, genre: string): Promise<Meta[]>

discover.trackEvent(id: string, kind: EventKind, meta?: ProfileSnapshot, ts?: number): void
discover.store(): DiscoverStore
discover.clear(): void
discover.score(profile: ProfileSnapshot, affinity: Affinity): number
discover.topEntries<K>(weights: Record<K, number>, n: number): Array<[K, number]>
discover.isCold(): boolean
discover.profileFromMeta(m: Meta): ProfileSnapshot
discover.profileFromDetail(d: TmdbDetail): ProfileSnapshot
```

### `HarborEngine.settings`, `.secretStore`, `.region`
```ts
settings.DEFAULT: Settings;  settings.STORAGE_KEY / SHARED_KEY / MIRROR_KEY: string
settings.profileKey(id: string): string
settings.sourceKeyFor(profileId: string, linked: boolean): string
settings.serialize(s: Settings): string
settings.load(key?: string): Settings
settings.loadForProfile(profileId: string, linked: boolean): Settings
settings.saveForProfile(value: Settings, profileId: string, linked: boolean): string
settings.patch(patch: Partial<Settings>, key?: string): Settings

secretStore.isSecretKey(key: string): boolean
secretStore.secretKeyForProfile(key: string, profileId: string): string
secretStore.getSecret(key: string): string | null
secretStore.setSecret(key: string, value: string | null): void
secretStore.getAllSecrets(): Record<string, string>
secretStore.load(): Promise<void>

region.localeForRegion(region: string): LocaleProfile
region.isLocalizedRegion(region: string): boolean
region.localeLabel(profile: LocaleProfile): string
```

### `HarborEngine.runtime` and the Stage-0 stream engine
```ts
runtime.upstreamRev: string;  runtime.builtAt: string
runtime.missingHostFunctions(): string[];  runtime.hostFunctions: string[]
runtime.onEvent(fn: (type: string, detail?: unknown) => void): () => void
runtime.emitEvent(type: string, detail?: unknown): void
runtime.storageKeys(): string[]
runtime.syncStorage(key: string, value: string | null): void
runtime.randomUuid(): string
runtime.pendingTimers(): number
runtime.selfTest(): Promise<{ ok: boolean; checks: Record<string, string> }>

parseStream, applyTrust, computeCorpusStats, scoreStream, rankAndPick   // unchanged
benchmark(rounds?: number): { streams: number; kept: number; best: string; ms: number }
```

## 6. DOM events the Swift side must replace

Upstream uses `window.dispatchEvent(new CustomEvent("harbor:…"))` as its cross-module bus.
The shim gives `window` a real `EventTarget` and mirrors every dispatch to
`HarborEngine.runtime.onEvent`, so the mechanism works inside the bundle — but the
**producers and consumers on the UI side are React and do not exist on tvOS**. These are the
ones that matter for the browse rooms:

| event | dispatched by | what Swift must do instead |
|---|---|---|
| `harbor:addons-changed` | `views/addons.tsx`, `views/addons/installed-pane.tsx`, `components/installer-viewport.tsx` after install / uninstall / enable / reorder; consumed by `lib/addons-store/store.ts` and `lib/search-context.tsx` | **Swift is the producer**: after any `addonStore.install*/uninstall*/setAddonEnabled/reorderInstalled` call, `runtime.emitEvent("harbor:addons-changed", …)` so the bundled listeners refresh, then reload `addons.loadAddonRows()` |
| `harbor:profiles-updated` | `lib/profiles.tsx` | re-read `harbor.profiles.v1` and rebuild the profile list |
| `harbor:active-profile-changed` | `lib/profiles.tsx` | reload settings, addons, library and every cache keyed by profile — `local-cw`, `movie-watched`, `manual-watched`, `theme-auth`, `collections`, `custom-lists` all listen for it. **`profiles.tsx` itself is not usable on tvOS** (React), so Swift owns profile switching and must emit this with `runtime.emitEvent` so the bundled listeners still fire |
| `harbor:title-logos` / `harbor:title-posters` / `harbor:title-backdrops` | `lib/title-logo.ts`, `title-poster.ts`, `title-backdrop.ts` when late art arrives | replace with a SwiftUI observable; the rows re-render themselves |
| `harbor:reset-row-scrolls`, `harbor:scroll-top` | `lib/view.tsx`, `components/row.tsx` | pure UI — SwiftUI focus/scroll state, no engine involvement |
| `harbor:open-search` | `lib/remote/session.ts` (the phone remote) | Stage 10; route to the Search room |
| `harbor:user-activity`, `harbor:controller-activity` | `lib/keyboard-navigation.ts` | screensaver idle timer — pure tvOS |
| `harbor:deeplink-open`, `harbor:deeplink-install`, `harbor:stremio-deeplink` | deep-link handling | Stage 2 does not need them; later they come from the tvOS URL handler |

There are 47 `harbor:*` events in upstream in total (`grep -rhoE '"harbor:[a-z0-9:_-]+"'
reference/harbor/src/lib`); the rest belong to music, manga, sports, the player and ebooks.

No bundled module dispatches or listens to a `harbor:*` event **at runtime** today — the only
two producers in the bundle (`profiles.tsx`, `auth.tsx`) are React files we import for their
pure helpers. So the bus is a Swift↔Swift concern for now, with `runtime.emitEvent` available
the moment a bundled listener does appear.

## 7. What could not be bundled

1. **`lib/view.tsx`** — 1,672 lines that are React context, refs and routing. Only its type
   union is reusable, by hand, in Swift.
2. **`lib/discover/index.ts`** (the barrel) — its own export is a React hook. The three pure
   files under it are bundled and give the same data.
3. **React hooks re-exported through barrels** — `useTmdbImdbId`, `useTmdbIdFromImdb`,
   `useTmdbVote`, `useOmdbScores`, `useOmdbBudget`, `useDiscover`. They are in the bundle
   (unavoidable without forking the barrel) and throw if called. Use the non-hook twin:
   every one of them has an `xCached()` / `xAsync()` sibling.
4. **`lib/platform.ts`** — `@tauri-apps/plugin-os`.
5. **`lib/secret-store.ts`'s Rust path** — `invoke("secrets_read"/"secrets_write")` throws;
   upstream's own fallback handles it, and Swift routes the keys to the Keychain.
6. **`safe-fetch`'s Tauri and web-proxy branches** — both are dead in this configuration,
   which is correct: a native tvOS app has no CORS and must not route through the VPS.
7. **gzip self-decompression in `tmdb-client`** — needs `Blob` + `DecompressionStream`. The
   host must decompress instead (NSURLSession already does).

## 8. Files

| file | role |
|---|---|
| `engine/entry.ts` | the entire API surface; the only file to edit when adding an export |
| `engine/bundle-config.mjs` | shared esbuild config: the Tauri / React / Vite-asset stubs, the JSC-shaped options, the upstream-rev define |
| `engine/build.mjs` | `node build.mjs [--min]` → `dist/harbor-engine.js`, `dist/shims-test.js`, `dist/metafile.json` |
| `engine/shims/index.js` | installs every polyfill; **must** be `entry.ts`'s first import |
| `engine/shims/{host,fetch,text,base64,events,crypto,storage,timers,dom}.js` | the polyfills |
| `engine/shims/node-host.mjs` | the `__harbor_host` contract on Node — the reference for the Swift implementation |
| `engine/test/harness.mjs` | loads the bundle in a bare `vm` context (the JSC analogue) |
| `engine/test/shims.test.mjs` | 117 checks, differential against Node's `URL`/`TextEncoder`/`crypto` |
| `engine/smoke.mjs` | 50 checks against the real API surface, live network |
| `engine/test/probe.mjs` | `node test/probe.mjs lib/foo` — can this module be bundled, and what does it drag in |

`npm test` inside `engine/` runs build + both suites.
