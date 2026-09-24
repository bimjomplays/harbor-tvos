// HarborEngine: upstream Harbor's framework-free TypeScript running inside JavaScriptCore.
//
// This file is the ONLY place where the tvOS app's API surface is defined. Everything it
// exports comes from `reference/harbor` through the `@/` alias - no upstream code is ever
// copied into engine/, so re-running `node build.mjs` after bumping the submodule picks up
// upstream's changes automatically.
//
// The shims import MUST stay first: it installs fetch/URL/localStorage/timers/crypto on the
// global object before any upstream module's top-level code runs.
import { shims } from "./shims/index.js";

// ---------------------------------------------------------------- Stage 0.4: stream engine
import { parseStream } from "@/lib/streams/parser";
import { computeCorpusStats, scoreStream, rankAndPick } from "@/lib/streams/scoring";
import { applyTrust } from "@/lib/streams/trust";
import { ADDON_SAMPLES } from "@/lib/streams/__fixtures__/addon-samples";
import type { Stream } from "@/lib/streams/types";

// ------------------------------------------------------------------ Stage 2: browse rooms
import * as upstreamAddons from "@/lib/addons";
import * as upstreamAddonStore from "@/lib/addon-store";
import * as upstreamCinemeta from "@/lib/cinemeta";
import * as upstreamStremio from "@/lib/stremio";
import * as upstreamTmdb from "@/lib/providers/tmdb";
import { setTmdbLanguage, effectiveTmdbLanguage, tmdbLanguageIso, TMDB, IMG } from "@/lib/providers/tmdb/tmdb-client";
import * as upstreamServiceCatalog from "@/lib/providers/service-catalog";
import * as upstreamFanart from "@/lib/providers/fanart";
import * as upstreamRpdb from "@/lib/providers/rpdb";
import * as upstreamOmdb from "@/lib/providers/omdb";
import * as upstreamAnizip from "@/lib/providers/anizip";
import * as upstreamFeed from "@/lib/feed";
import { searchAll, searchCinemeta, searchAnime, searchLiveTvChannels, detectIntent } from "@/lib/search";
import { searchAddonCatalogs, searchAddonGroups, mergeMetas } from "@/lib/search-addons";
import { normalizeSearchQuery } from "@/lib/search-query";
import { fallbackShelves } from "@/lib/feed/themes";
import { affinityIsEmpty, score as discoverScore, topEntries as discoverTopEntries } from "@/lib/discover/affinity";
import { profileFromDetail, profileFromMeta } from "@/lib/discover/profile";
import { clearStore as discoverClear, getStore as discoverStore, trackEvent as discoverTrack } from "@/lib/discover/store";
import { DEFAULT as SETTINGS_DEFAULT, STORAGE_KEY as SETTINGS_KEY } from "@/lib/settings/defaults";
import { loadStoredSettings } from "@/lib/settings/load";
import {
  MIRROR_KEY,
  SHARED_KEY,
  loadEffective,
  persistEffective,
  profileKey,
  serializeSettings,
  sourceKeyFor,
} from "@/lib/settings/profile-store";
import type { Settings } from "@/lib/settings/types";
import { localeForRegion, isLocalizedRegion, localeLabel } from "@/lib/region/locale-map";
import { randomUuid } from "@/lib/uuid";
import * as upstreamSecrets from "@/lib/secret-store";
import type { Meta } from "@/lib/cinemeta";
import * as roomBuilders from "./rooms";
import * as discoverBuilders from "./discover";
import * as streamGlue from "./streams";
import * as playerGlue from "./player";
import * as subtitleGlue from "./subtitles";
import * as liveGlue from "./live";
import * as liveVodGlue from "./liveVod";
import * as accountGlue from "./account";
import * as syncGlue from "./sync";
import * as cardsGlue from "./cards";
import * as simklGlue from "./simkl";
import * as anime4kGlue from "./anime4k";
import * as sportsGlue from "./sports";
import * as sportsEventGlue from "./sportsEvent";
import * as settingsRoomGlue from "./settingsRoom";
import * as profilesRoomGlue from "./profilesRoom";
import * as libraryGlue from "./library";
import * as animeGlue from "./animeRoom";
import * as servicesGlue from "./services";
import * as trackersGlue from "./trackers";
import * as detailGlue from "./detailRoom";
import * as personGlue from "./personRoom";
import * as homeGlue from "./homeServers";
import * as searchGlue from "./search";
import * as onboardingGlue from "./onboarding";
import * as actionsGlue from "./actions";
import { scores as scoreBadges } from "./scores";
import * as addonsRoomGlue from "./addonsRoom";
import * as animeDetailGlue from "./animeDetail";
import { fetchHeroFeed } from "@/lib/feed/hero-pool";
import * as skipGlue from "./skip";
import * as traktGlue from "./trakt";
import * as collectionsGlue from "./collections";
import * as letterboxdGlue from "./letterboxd";
import * as kidsGlue from "./kids";
import * as calendarGlue from "./calendar";
import * as wrappedGlue from "./wrapped";

declare const __HARBOR_UPSTREAM_REV__: string;
declare const __HARBOR_BUILT_AT__: string;

// ============================================================================ stream engine
export { parseStream, applyTrust, computeCorpusStats, scoreStream, rankAndPick };

/** Runs the whole pipeline on upstream's own fixture streams, repeated to make timing visible. */
export function benchmark(rounds = 50): { streams: number; kept: number; best: string; ms: number } {
  const raw: Stream[] = [];
  for (let i = 0; i < rounds; i++) for (const s of ADDON_SAMPLES) raw.push(s.raw);
  const t0 = Date.now();
  const parsed = raw.map(parseStream);
  const { keep } = applyTrust(parsed, { disabled: false, strict: false });
  const opts = { activeDebrids: ["torbox" as const], mediaKind: "movie" as const };
  const corpus = computeCorpusStats(keep, opts);
  const scored = keep.map((s) => scoreStream(s, opts, corpus));
  const ranked = rankAndPick(scored, ["torbox"]);
  const best = ranked.primary ?? ranked.all[0];
  return {
    streams: raw.length,
    kept: keep.length,
    best: best ? `${best.resolution ?? "?"} ${best.parsedTitle ?? best.title ?? ""}`.trim() : "none",
    ms: Date.now() - t0,
  };
}

// ================================================================================== addons
/**
 * Stremio addon client: the catalogs behind Home / Discover / Movies / Shows, plus meta and
 * paged catalog fetches. `authKey` is the Stremio auth key (null = local addons only).
 */
export const addons = {
  gatherCatalogAddons: upstreamAddons.gatherCatalogAddons,
  loadAddonRows: upstreamAddons.loadAddonRows,
  fetchCatalogRow: upstreamAddons.fetchCatalogRow,
  fetchAddonMeta: upstreamAddons.fetchAddonMeta,
  fetchAddonCatalogPage: upstreamAddons.fetchAddonCatalogPage,
  createAddonCatalogFetcher: upstreamAddons.createAddonCatalogFetcher,
  dedupeAddonRows: upstreamAddons.dedupeAddonRows,
  contentCatalogs: upstreamAddons.contentCatalogs,
  isCollectionCatalog: upstreamAddons.isCollectionCatalog,
  addonAccepts: upstreamAddons.addonAccepts,
  addonBasesForOrigin: upstreamAddons.addonBasesForOrigin,
  normalizeName: upstreamAddons.normalizeName,
  hasTmdbProviderAddon: upstreamAddons.hasTmdbProviderAddon,
  userAddons: upstreamAddons.userAddons,
  setUserAddons: upstreamAddons.setUserAddons,
  getUserAddonsRaw: upstreamAddons.getUserAddonsRaw,
  setUserAddonsRaw: upstreamAddons.setUserAddonsRaw,
  torrentioAddonFor: upstreamAddons.torrentioAddonFor,
  torrentioBareAddon: upstreamAddons.torrentioBareAddon,
  torboxAddonFor: upstreamAddons.torboxAddonFor,
  withDebridKeys: upstreamAddons.withDebridKeys,
};

/** The locally installed-addon store (localStorage backed, per profile). */
export const addonStore = {
  loadInstalled: upstreamAddonStore.loadInstalled,
  filterEnabled: upstreamAddonStore.filterEnabled,
  isAddonEnabled: upstreamAddonStore.isAddonEnabled,
  setAddonEnabled: upstreamAddonStore.setAddonEnabled,
  isInstalled: upstreamAddonStore.isInstalled,
  transportUrlFor: upstreamAddonStore.transportUrlFor,
  parseAddonUrl: upstreamAddonStore.parseAddonUrl,
  fetchManifestAt: upstreamAddonStore.fetchManifestAt,
  installAddon: upstreamAddonStore.installAddon,
  installFromUrl: upstreamAddonStore.installFromUrl,
  uninstallAddon: upstreamAddonStore.uninstallAddon,
  fetchInstalledAddons: upstreamAddonStore.fetchInstalledAddons,
  reorderInstalled: upstreamAddonStore.reorderInstalled,
  seedDefaultAddonsIfFirstRun: upstreamAddonStore.seedDefaultAddonsIfFirstRun,
  manifestToConfigureUrl: upstreamAddonStore.manifestToConfigureUrl,
  manifestToShareUrl: upstreamAddonStore.manifestToShareUrl,
  // A Set does not survive JSON.stringify; hand Swift an array.
  loadDisabledAddons: () => Array.from(upstreamAddonStore.loadDisabledAddons()),
};

// ================================================================================ cinemeta
/** Cinemeta (v3-cinemeta.strem.io): the always-available fallback catalog and meta source. */
export const cinemeta = {
  topMovies: upstreamCinemeta.topMovies,
  topSeries: upstreamCinemeta.topSeries,
  meta: upstreamCinemeta.meta,
  enabled: upstreamCinemeta.cinemetaEnabled,
  narrowMediaType: upstreamCinemeta.narrowMediaType,
  isAddonNativeMeta: upstreamCinemeta.isAddonNativeMeta,
  hasEmbeddedStreams: upstreamCinemeta.hasEmbeddedStreams,
  persistableVideos: upstreamCinemeta.persistableVideos,
  persistableAddonOrigin: upstreamCinemeta.persistableAddonOrigin,
};

// ================================================================================= stremio
/** Stremio API: login, the user record, the cloud library and continue-watching helpers. */
export const stremio = {
  login: upstreamStremio.login,
  logout: upstreamStremio.logout,
  getUser: upstreamStremio.getUser,
  library: upstreamStremio.library,
  libraryIfChanged: upstreamStremio.libraryIfChanged,
  libraryGetOne: upstreamStremio.libraryGetOne,
  libraryGetOneStrict: upstreamStremio.libraryGetOneStrict,
  libraryPut: upstreamStremio.libraryPut,
  removeLibraryItem: upstreamStremio.removeStremioLibraryItem,
  invalidateLibraryCache: upstreamStremio.invalidateLibraryCache,
  saveBookmark: upstreamStremio.saveStremioBookmark,
  removeBookmark: upstreamStremio.removeStremioBookmark,
  // continue-watching shaping
  isCwMember: upstreamStremio.isCwMember,
  cwSortKey: upstreamStremio.cwSortKey,
  cwMemberViaResume: upstreamStremio.cwMemberViaResume,
  isAnimeCwItem: upstreamStremio.isAnimeCwItem,
  episodeFromVideoId: upstreamStremio.episodeFromVideoId,
  resumeSourceForItem: upstreamStremio.resumeSourceForItem,
  libraryMetaType: upstreamStremio.libraryMetaType,
  cloudWriteId: upstreamStremio.cloudWriteId,
  CLOUD_OK: upstreamStremio.CLOUD_OK,
  ANIME_CLOUD_ID: upstreamStremio.ANIME_CLOUD_ID,
  /** library() sorted the way upstream's continue-watching rail shows it. */
  async continueWatching(authKey: string): Promise<upstreamStremio.LibraryItem[]> {
    const items = await upstreamStremio.library(authKey);
    return items.filter(upstreamStremio.isCwMember).sort((a, b) => upstreamStremio.cwSortKey(b) - upstreamStremio.cwSortKey(a));
  },
};

// ==================================================================================== TMDB
/**
 * TMDB. Upstream has no global key: every call takes the user's key as its first argument
 * (it lives in Settings.tmdbKey). Only `setLanguage` is global state.
 */
export const tmdb = {
  /** Base URLs, so Swift can build image URLs without a round trip. */
  API_BASE: TMDB,
  IMAGE_BASE: IMG,
  setLanguage: setTmdbLanguage,
  language: effectiveTmdbLanguage,
  languageIso: tmdbLanguageIso,
  // rows
  movieRow: upstreamTmdb.tmdbMovieRow,
  seriesRow: upstreamTmdb.tmdbSeriesRow,
  trending: upstreamTmdb.tmdbTrending,
  discover: upstreamTmdb.tmdbDiscover,
  searchMovie: upstreamTmdb.tmdbSearchMovie,
  searchTitle: upstreamTmdb.tmdbSearchTitle,
  // detail / art
  details: upstreamTmdb.tmdbDetails,
  seasonEpisodes: upstreamTmdb.tmdbSeasonEpisodes,
  images: upstreamTmdb.tmdbMovieImages,
  logo: upstreamTmdb.tmdbLogo,
  trailer: upstreamTmdb.tmdbTrailer,
  trailerList: upstreamTmdb.tmdbTrailerList,
  collection: upstreamTmdb.tmdbCollection,
  collectionsFeed: upstreamTmdb.tmdbCollectionsFeed,
  critic: upstreamTmdb.tmdbCriticData,
  person: upstreamTmdb.tmdbPerson,
  personIdByName: upstreamTmdb.tmdbPersonIdByName,
  creditToMeta: upstreamTmdb.creditToMeta,
  keywordIdByName: upstreamTmdb.tmdbKeywordIdByName,
  resolveKeywordIds: upstreamTmdb.tmdbResolveKeywordIds,
  companyIdByName: upstreamTmdb.tmdbCompanyIdByName,
  companyArt: upstreamTmdb.tmdbCompanyArt,
  episodeGroups: upstreamTmdb.tmdbEpisodeGroups,
  episodeGroup: upstreamTmdb.tmdbEpisodeGroup,
  episodeNames: upstreamTmdb.tmdbEpisodeNames,
  // "where to watch" rails
  watchProviders: upstreamTmdb.tmdbWatchProviders,
  // id bridges
  imdbId: upstreamTmdb.tmdbImdbId,
  imdbIdCached: upstreamTmdb.tmdbImdbCached,
  idFromImdb: upstreamTmdb.tmdbIdFromImdb,
  idFromImdbCached: upstreamTmdb.tmdbFromImdbCached,
};

/** Upstream's streaming-service rails (Netflix / Disney+ / ... rows on Discover). */
export const serviceCatalog = {
  CATEGORIES: upstreamServiceCatalog.CATEGORIES,
  MAX_PER_BUCKET: upstreamServiceCatalog.MAX_PER_BUCKET,
  fetchCategoryBatch: upstreamServiceCatalog.fetchCategoryBatch,
  dedupe: upstreamServiceCatalog.dedupe,
};

/** Poster / art / rating providers used to dress the rows. */
export const providers = {
  fanartMovie: upstreamFanart.fanartMovie,
  fanartTv: upstreamFanart.fanartTv,
  rpdbPoster: upstreamRpdb.rpdbPoster,
  rpdbSetPosterBaseUrl: upstreamRpdb.setPosterBaseUrl,
  rpdbNeedsImdb: upstreamRpdb.needsImdbForPoster,
  rpdbNeedsTmdb: upstreamRpdb.needsTmdbForPoster,
  omdbScores: upstreamOmdb.omdbScores,
  omdbScoresCached: upstreamOmdb.omdbScoresCached,
  omdbPrefetch: upstreamOmdb.omdbPrefetch,
  omdbSeasonRatings: upstreamOmdb.omdbSeasonRatings,
  omdbBudget: upstreamOmdb.omdbBudget,
  aniZipByKitsu: upstreamAnizip.aniZipByKitsu,
  aniZipByMal: upstreamAnizip.aniZipByMal,
  aniZipByAnilist: upstreamAnizip.aniZipByAnilist,
  aniZipByImdb: upstreamAnizip.aniZipByImdb,
  aniZipByTmdbTv: upstreamAnizip.aniZipByTmdbTv,
  aniZipPickEpisodeTitle: upstreamAnizip.pickEpisodeTitle,
  aniZipPickLocalizedTitle: upstreamAnizip.pickLocalizedTitle,
};

/**
 * Session tokens. Upstream keeps these in a Rust-backed store on desktop; that path is a
 * Tauri `invoke` and throws here, so upstream's own fallback branch takes over and reads and
 * writes plain localStorage keys. On tvOS the Swift KeyValueStore routes the prefixes below
 * to the Keychain, which is exactly the behaviour we want.
 */
export const secretStore = {
  isSecretKey: upstreamSecrets.isSecretKey,
  secretKeyForProfile: upstreamSecrets.secretKeyForProfile,
  getSecret: upstreamSecrets.getSecret,
  setSecret: upstreamSecrets.setSecret,
  getAllSecrets: upstreamSecrets.getAllSecrets,
  /** Resolves even though the desktop store is unavailable; see the note above. */
  load: upstreamSecrets.loadSecrets,
};

// ================================================================================== search
/**
 * The Search room. `searchAll` needs a TMDB key (it is TMDB multi-search plus everything
 * else fused); `cinemeta` and `addonCatalogs` work with no key at all, which is what the TV
 * falls back to before the user has entered one.
 */
export const search = {
  fanOut: searchGlue.fanOut,
  /** use-collection-hits: TVDB collection hits for a query (≥3 chars). */
  collections: searchGlue.collections,
  /** bp-collection.tsx: one TVDB collection hydrated to a Collections-room card, or null. */
  collection: searchGlue.collection,
  all: searchAll,
  cinemeta: searchCinemeta,
  anime: searchAnime,
  liveTv: searchLiveTvChannels,
  addonCatalogs: searchAddonCatalogs,
  addonGroups: searchAddonGroups,
  mergeMetas,
  detectIntent,
  normalizeQuery: normalizeSearchQuery,
};

// ==================================================================================== feed
/** The Home room's editorial feed: hero pool, daily rows and the named TMDB sections. */
export const feed = {
  /** use-bp-screensaver: the hero feed's ranked art (trending / trakt / simkl). */
  hero: fetchHeroFeed,
  getPool: upstreamFeed.getPool,
  buildPool: upstreamFeed.buildPool,
  extendPool: upstreamFeed.extendPool,
  pickShelves: upstreamFeed.pickShelves,
  fallbackShelves,
  selectDailyRows: upstreamFeed.selectDailyRows,
  isSaved: upstreamFeed.isSaved,
  toggleSaved: upstreamFeed.toggleSaved,
  fetchFeatured: upstreamFeed.fetchFeatured,
  fetchCriticsPickList: upstreamFeed.fetchCriticsPickList,
  fetchUnderNinety: upstreamFeed.fetchUnderNinety,
  fetchRecentlyAdded: upstreamFeed.fetchRecentlyAdded,
  fetchComingSoon: upstreamFeed.fetchComingSoon,
  fetchInTheaters: upstreamFeed.fetchInTheaters,
  fetchTopRated: upstreamFeed.fetchTopRated,
  fetchTrendingWeek: upstreamFeed.fetchTrendingWeek,
  fetchTopSeries: upstreamFeed.fetchTopSeries,
  fetchDocumentaries: upstreamFeed.fetchDocumentaries,
  fetchGenreSample: upstreamFeed.fetchGenreSample,
};

/** Taste profile behind the Discover room. `useDiscover` (the React hook) is NOT bundled. */
export const discover = {
  trackEvent: discoverTrack,
  store: discoverStore,
  clear: discoverClear,
  score: discoverScore,
  topEntries: discoverTopEntries,
  isCold: () => affinityIsEmpty(discoverStore().affinity),
  profileFromMeta,
  profileFromDetail,
};

// ================================================================================ settings
/**
 * Settings, read and written through the localStorage shim (so they land in whatever the
 * Swift KeyValueStore routes `harbor.settings*` to). `load()` runs upstream's full
 * sanitizer, so an empty or corrupt store still yields a valid Settings object.
 */
export const settings = {
  DEFAULT: SETTINGS_DEFAULT,
  STORAGE_KEY: SETTINGS_KEY,
  SHARED_KEY,
  MIRROR_KEY,
  profileKey,
  sourceKeyFor,
  serialize: serializeSettings,
  load: (key: string = SETTINGS_KEY): Settings => loadStoredSettings(key),
  loadForProfile: (profileId: string, linked: boolean): Settings => loadEffective(profileId, linked),
  saveForProfile: (value: Settings, profileId: string, linked: boolean): string =>
    persistEffective(value, profileId, linked),
  /** Merge a patch into the stored settings and persist it under `key`. */
  patch(patch: Partial<Settings>, key: string = SETTINGS_KEY): Settings {
    const next = { ...loadStoredSettings(key), ...patch } as Settings;
    globalThis.localStorage.setItem(key, serializeSettings(next));
    syncGlue.markSettingsPatched(Object.keys(patch));
    return next;
  },
};

/** Region profiles: which TMDB language and watch-provider region a locale implies. */
export const region = { localeForRegion, isLocalizedRegion, localeLabel };

// ==================================================================================== rooms
/**
 * Finished row builds for the TV rooms (engine-added glue over upstream's row specs):
 * `home(settings, authKey)` mirrors use-bp-catalog.ts, `catalog("movies"|"shows", settings)`
 * mirrors use-bp-shows.ts. Swift caches the result and renders it.
 */
export const rooms = {
  home: roomBuilders.home,
  catalog: roomBuilders.catalog,
  homeFor: roomBuilders.homeFor,
  catalogFor: roomBuilders.catalogFor,
  page: roomBuilders.page,
  continueWatchingFor: roomBuilders.continueWatchingFor,
  continueWatchingWithExtras: roomBuilders.continueWatchingWithExtras,
  dismissContinueWatching: roomBuilders.dismissContinueWatching,
  anime: roomBuilders.anime,
  TOP10_ROW_KEY: roomBuilders.BP_TOP10_ROW_KEY,
};
export type { RoomBuild, RoomRow, RoomKind } from "./rooms";

/** Discover room: daily rails, the Discovery Queue peek/order, genre tiles (engine-added glue). */
export const discoverRoom = {
  buildFor: discoverBuilders.buildFor,
  rails: discoverBuilders.rails,
  queuePeek: discoverBuilders.queuePeek,
  queueFor: discoverBuilders.queueFor,
  genres: discoverBuilders.genres,
  genreArtFor: discoverBuilders.genreArtFor,
  genrePage: discoverBuilders.genrePage,
  queueOpen: discoverBuilders.queueOpen,
  queueExtend: discoverBuilders.queueExtend,
  queueSnooze: discoverBuilders.queueSnooze,
  queueBlock: discoverBuilders.queueBlock,
  installAwards: discoverBuilders.installAwards,
  awardsInstalled: discoverBuilders.awardsInstalled,
  awards: discoverBuilders.awards,
  awardDetail: discoverBuilders.awardDetail,
  animeAwardSources: discoverBuilders.animeAwardSources,
  animeAward: discoverBuilders.animeAward,
  animeAwardOpen: discoverBuilders.animeAwardOpen,
  people: discoverBuilders.people,
};
export type { DiscoverBuild, DiscoverRail, QueuePeek, GenreTile } from "./discover";

/** Streams for a title: imdb resolution, addon gathering, the ranked pipeline, debrid resolve. */
export const streamsRoom = {
  resolveImdb: streamGlue.resolveImdb,
  gatherStreamAddons: streamGlue.gatherStreamAddons,
  search: streamGlue.search,
  cancelSearch: streamGlue.cancelSearch,
  resolve: streamGlue.resolve,
  forget: streamGlue.forget,
  autoCandidates: streamGlue.autoCandidates,
  rememberPlayback: streamGlue.rememberPlayback,
  remembered: streamGlue.remembered,
  p2pConsentNeeded: streamGlue.p2pConsentNeeded,
  setP2pAutoConsent: streamGlue.setP2pAutoConsent,
  failureMessage: streamGlue.failureMessage,
  p2pFileIdx: streamGlue.p2pFileIdx,
};
export type { StreamSearch } from "./streams";

/** Collections: this device's collections (editable), community (harbor.site), TMDB curated, TVDB lists. */
export const collectionsRoom = {
  categories: collectionsGlue.categories,
  tmdb: collectionsGlue.tmdb,
  curatedRow: collectionsGlue.curatedRow,
  tmdbCard: collectionsGlue.tmdbCard,
  tvdb: collectionsGlue.tvdb,
  tvdbDetail: collectionsGlue.tvdbDetail,
  mine: collectionsGlue.mine,
  community: collectionsGlue.community,
  all: collectionsGlue.all,
  limits: collectionsGlue.limits,
  mineCard: collectionsGlue.mineCard,
  create: collectionsGlue.create,
  rename: collectionsGlue.rename,
  remove: collectionsGlue.remove,
  addItem: collectionsGlue.addItem,
  removeItem: collectionsGlue.removeItem,
  saveCommunity: collectionsGlue.saveCommunity,
  searchTitles: collectionsGlue.searchTitles,
};

/** Letterboxd (Stremboxd public mode): username connect, Library tab feed, Movies rows. */
export const letterboxd = {
  status: letterboxdGlue.status,
  connect: letterboxdGlue.connect,
  disable: letterboxdGlue.disable,
  watchlist: letterboxdGlue.watchlist,
  movieRows: letterboxdGlue.movieRows,
};

/** Trakt: device-code sign-in, session status, scrobbles. */
export const trakt = {
  deviceCode: traktGlue.deviceCode,
  poll: traktGlue.poll,
  status: traktGlue.status,
  disconnect: traktGlue.disconnect,
  scrobble: traktGlue.scrobble,
};

/** Harbor account session (upstream theme-auth + identity API); the bundle owns refresh. */
export const account = {
  session: accountGlue.session,
  login: accountGlue.login,
  register: accountGlue.register,
  logout: accountGlue.logout,
  token: accountGlue.token,
  refreshIfDue: accountGlue.refreshIfDue,
  reloadUser: accountGlue.reloadUser,
  adopt: accountGlue.adopt,
  start: accountGlue.start,
  stop: accountGlue.stop,
};

/** Profile sync, both directions, on upstream's engine (see sync.ts for the host contract). */
export const sync = {
  start: syncGlue.start,
  stop: syncGlue.stop,
  status: syncGlue.status,
  pullNow: syncGlue.pullNow,
  pushNow: syncGlue.pushNow,
  requestPull: syncGlue.requestPull,
  markDirty: syncGlue.markDirty,
  markCleared: syncGlue.markCleared,
  profileDeleted: syncGlue.profileDeleted,
  syncedSettingsFields: syncGlue.syncedSettingsFields,
  parked: syncGlue.parked,
  restoreParked: syncGlue.restoreParked,
};

/** Card marks for browse tiles (identity chip, watchlist, watched, Top 10 ribbon). */
export const cards = {
  marks: cardsGlue.marks,
  heroAwards: cardsGlue.heroAwards,
  setTop10: cardsGlue.setTop10,
  refreshWatchlist: cardsGlue.refreshWatchlist,
};

/** Simkl: PIN sign-in, session status, scrobbles (same wire shapes as `trakt`). */
export const simkl = {
  deviceCode: simklGlue.deviceCode,
  poll: simklGlue.poll,
  status: simklGlue.status,
  disconnect: simklGlue.disconnect,
  scrobble: simklGlue.scrobble,
};

/** Anime4K: which shader chain applies to a title (settings gates), and the files to fetch. */
export const anime4k = {
  files: anime4kGlue.files,
  modes: anime4kGlue.modes,
  choose: anime4kGlue.choose,
};

/** Sports room (upstream hub feeds, rows, discovery, consent, personalization, detail). */
export const sports = {
  standings: sportsGlue.standings,
  teamLeagues: sportsGlue.teamLeagues,
  who: sportsGlue.who,
  whoSides: sportsGlue.whoSides,
  addonSources: sportsGlue.addonSources,
  addonStreams: sportsGlue.addonStreams,
  addonPlay: sportsGlue.addonPlay,
  whoPlayer: sportsGlue.whoPlayer,
  teams: sportsGlue.teams,
  favouriteTeams: sportsGlue.favouriteTeams,
  artwork: sportsGlue.artwork,
  consent: sportsGlue.consent,
  accept: sportsGlue.accept,
  decline: sportsGlue.decline,
  catalog: sportsGlue.catalog,
  setLeagues: sportsGlue.setLeagues,
  toggleTeam: sportsGlue.toggleTeam,
  page: sportsGlue.page,
  days: sportsGlue.days,
  detail: sportsGlue.detail,
  watch: sportsGlue.watch,
  toggleAttachedChannel: sportsGlue.toggleAttachedChannel,
  recordChannelWatch: sportsGlue.recordChannelWatch,
  clearAttachedStream: sportsGlue.clearAttachedStream,
  officialBroadcasts: sportsGlue.officialBroadcasts,
  // Event rows, where-to-watch, hero actions, reminders, api-sports key (engine/sportsEvent.ts).
  eventRows: sportsEventGlue.eventRows,
  where: sportsEventGlue.where,
  actions: sportsEventGlue.actions,
  toggleFollow: sportsEventGlue.toggleFollow,
  toggleReminder: sportsEventGlue.toggleReminder,
  reminders: sportsEventGlue.reminders,
  runReminders: sportsEventGlue.runReminders,
  startReminders: sportsEventGlue.startReminders,
  webhooks: sportsEventGlue.webhooks,
  setWebhooks: sportsEventGlue.setWebhooks,
  testWebhook: sportsEventGlue.testWebhook,
  apiSports: sportsEventGlue.apiSports,
  setApiSportsKey: sportsEventGlue.setApiSportsKey,
};

/** Big Picture settings catalog: categories, controls per category, commit. */
export const settingsRoom = {
  categories: settingsRoomGlue.categories,
  controls: settingsRoomGlue.controls,
  commit: settingsRoomGlue.commit,
};

/** Profiles: upstream's avatar catalog, brand colours, per-profile storage purge. */
export const profilesRoom = {
  avatars: profilesRoomGlue.avatars,
  colors: profilesRoomGlue.colors,
  pickColor: profilesRoomGlue.pickColor,
  purge: profilesRoomGlue.purge,
};

/** Library room: tabs and one filtered/sorted/grouped feed per tab (use-bp-library). */
export const libraryRoom = {
  tabs: libraryGlue.tabs,
  feed: libraryGlue.feed,
  setSort: libraryGlue.setSort,
  repair: libraryGlue.repair,
  animeScan: libraryGlue.animeScan,
  animeHeal: libraryGlue.animeHeal,
};

/** Anime room: progressive Jikan spec rows, anime CW, hero, awards, addon rows (use-bp-anime). */
export const animeRoom = {
  heroMeta: animeGlue.heroMeta,
  page: animeGlue.page,
  loadMore: animeGlue.loadMore,
  refresh: animeGlue.refresh,
  specPage: animeGlue.specPage,
};

/** Streaming services: the Home band tiles, poster mosaics and the per-service page rows. */
export const services = {
  list: servicesGlue.list,
  all: servicesGlue.all,
  posters: servicesGlue.posters,
  rows: servicesGlue.rows,
  page: servicesGlue.page,
};

/** AniList and MyAnimeList: paste-code sign-in, status, disconnect, list rails. */
export const anilist = trackersGlue.anilist;
export const mal = trackersGlue.mal;

/** Detail page extras from TMDB: tagline, cast, crew, similar, recommendations, watch-on, collection. */
export const detailRoom = {
  videoClips: detailGlue._videoClips,
  episodeFacts: detailGlue.episodeFacts,
  awards: detailGlue.awards,
  gallery: detailGlue.gallery,
  extras: detailGlue.extras,
  collection: detailGlue.collection,
  episodeArt: detailGlue.episodeArt,
};

/** Person page: facts, Known For, IMDb Top, collaborators, awards, filmography sections. */
export const personRoom = { page: personGlue.page };

/** Home media servers: Plex (PIN), Jellyfin, Emby — connect, index, copies, playback. */
export const homeServers = {
  connections: homeGlue.connectionsWithSummaries,
  connect: homeGlue.connect,
  plexPinStart: homeGlue.plexPinStart,
  plexPinPoll: homeGlue.plexPinPoll,
  plexAdd: homeGlue.plexAdd,
  remove: homeGlue.remove,
  update: homeGlue.update,
  libraries: homeGlue.libraries,
  sync: homeGlue.sync,
  titles: homeGlue.titles,
  copies: homeGlue.copies,
  play: homeGlue.play,
  runDueSyncs: homeGlue.runDueSyncs,
  startRunner: homeGlue.startRunner,
  reportProgress: homeGlue.reportProgress,
  stopPlayback: homeGlue.stopPlayback,
};

/** Kids mode (views/kids.tsx, kids-franchise-rail, grid kidsHero, kids-detail.tsx): the kid profile's surface. */
export const kidsRoom = {
  page: kidsGlue.page,
  loadMore: kidsGlue.loadMore,
  logo: kidsGlue.logo,
  franchises: kidsGlue.franchises,
  franchisePage: kidsGlue.franchisePage,
  detail: kidsGlue.detail,
  episodes: kidsGlue.episodes,
  gradStops: kidsGlue.gradStops,
};

/** use-bp-anime-detail: the Kitsu chain for anime ids (episodes as PlayEpisodes, characters). */
export const animeDetail = { load: animeDetailGlue.load };

/** bp-home "Your addons" band and the addon page: cards, catalogs, paged feeds. */
export const addonsRoom = {
  cards: addonsRoomGlue.cards,
  bandPosters: addonsRoomGlue.bandPosters,
  catalogs: addonsRoomGlue.catalogs,
  feed: addonsRoomGlue.feed,
};

/** use-bp-card-badges: provider score chips for a hero ("card" gates) or a detail page ("detail" gates). */
export const scores = { forMeta: scoreBadges };

/** Detail / quick-panel actions: custom lists, ratings, anime row customisation. */
export const actions = {
  lists: actionsGlue.lists,
  toggleList: actionsGlue.toggleList,
  newList: actionsGlue.newList,
  removeList: actionsGlue.removeList,
  renameList: actionsGlue.renameListTo,
  rating: actionsGlue.rating,
  rate: actionsGlue.rate,
  unrate: actionsGlue.unrate,
  animeRows: actionsGlue.animeRows,
  animeRowMove: actionsGlue.animeRowMove,
  animeRowToggleHidden: actionsGlue.animeRowToggleHidden,
  animeRowRename: actionsGlue.animeRowRename,
  animeRowsReset: actionsGlue.animeRowsReset,
  heroState: actionsGlue.heroState,
  toggleFavorite: actionsGlue.toggleFavorite,
  toggleReminder: actionsGlue.toggleReminder,
  setMovieWatched: actionsGlue.setMovieWatched,
  traktMarkWatched: actionsGlue.traktMarkWatched,
  trackers: actionsGlue.trackers,
  trackerSet: actionsGlue.trackerSet,
  trackerRemove: actionsGlue.trackerRemove,
};

/** Onboarding taste step (onboarding/use-bp-taste-titles + bp-step-taste): titles to pick, votes. */
export const onboarding = {
  tasteTitles: onboardingGlue.tasteTitles,
  vote: onboardingGlue.vote,
  upvoted: onboardingGlue.upvoted,
};

/** Skip intro/outro/recap segments (AniSkip, SkipDB, TheIntroDB, IntroDB App). */
export const skip = { segments: skipGlue.segments };

/** Live TV: M3U / Xtream / middleware sources, favorites, guide order, XMLTV now/next. */
export const live = {
  playlists: liveGlue.playlists,
  addPlaylist: liveGlue.addPlaylist,
  addStructured: liveGlue.addStructured,
  setEpgUrl: liveGlue.setEpgUrl,
  loadShortEpg: liveGlue.loadShortEpg,
  homeRow: liveGlue.homeRow,
  toggleGroupHidden: liveGlue.toggleGroupHidden,
  toggleChannelPin: liveGlue.toggleChannelPin,
  removePlaylist: liveGlue.removePlaylist,
  channels: liveGlue.channels,
  favorites: liveGlue.favorites,
  toggleFavorite: liveGlue.toggleFavorite,
  recordPlay: liveGlue.recordPlay,
  loadEpg: liveGlue.loadEpg,
  nowNext: liveGlue.nowNext,
  schedule: liveGlue.schedule,
  lanes: liveGlue.lanes,
  catchupUrl: liveGlue.catchupUrl,
  epgCandidates: liveGlue.epgCandidates,
  setEpgMatch: liveGlue.setEpgMatch,
  /** Multiview (lib/multiview/store.ts): the remembered layout and the info banner. */
  multiviewPrefs: liveGlue.multiviewPrefs,
  setMultiviewLayout: liveGlue.setMultiviewLayout,
  dismissMultiviewBanner: liveGlue.dismissMultiviewBanner,
};

/** Playlist VOD (views/playlist-vod.tsx): an IPTV source's movies and series, paged, with local resume. */
export const liveVod = {
  sources: liveVodGlue.sources,
  setActive: liveVodGlue.setActive,
  load: liveVodGlue.load,
  status: liveVodGlue.status,
  page: liveVodGlue.page,
  series: liveVodGlue.series,
  playMovie: liveVodGlue.playMovie,
  playEpisode: liveVodGlue.playEpisode,
  startPosition: liveVodGlue.startPosition,
  saveProgress: liveVodGlue.saveProgress,
};

/** Online subtitles: OpenSubtitles v3 / Wyzie / subtitle addons, ranked by the viewer's languages. */
export const subtitles = {
  search: subtitleGlue.search,
  prepare: subtitleGlue.prepare,
  /** bp-player-subtitles: track rows (language groups, badges, best-match order). */
  trackView: subtitleGlue.trackView,
  /** bp-subtitle-find: search a target title / season / episode, and parse a typed title. */
  find: subtitleGlue.find,
  titleTarget: subtitleGlue.titleTarget,
  /** bp-subtitle-tune BpSubtitleLook presets. */
  presets: subtitleGlue.presets,
};

/** Playback progress: where to start, and the 4-second progress write (local + Stremio). */
export const player = {
  startPosition: playerGlue.startPosition,
  saveProgress: playerGlue.saveProgress,
  localResume: playerGlue.localResume,
  watchedEpisodes: playerGlue.watchedEpisodes,
  decodeWatchedField: playerGlue.decodeWatchedField,
  /** Up-next lead, auto-advance and seek steps for the Big Picture chrome. */
  prefs: playerGlue.prefs,
};

/** Calendar room (views/calendar.tsx): one month per call, header prefs, the Custom rail, reminders. */
export const calendar = {
  month: calendarGlue.month,
  setPref: calendarGlue.setPref,
  customRail: calendarGlue.customRail,
  customToggle: calendarGlue.customToggle,
  reminders: calendarGlue.reminders,
  removeReminder: calendarGlue.removeReminder,
  unseen: calendarGlue.unseen,
  clearUnseen: calendarGlue.clearUnseen,
  checkReminders: calendarGlue.checkReminders,
  startReminders: calendarGlue.startReminders,
  stopReminders: calendarGlue.stopReminders,
  remaining: calendarGlue.remaining,
};

/** Stats / Wrapped (views/wrapped.tsx): the year's stats, then posters/genres/people. */
export const wrapped = {
  load: wrappedGlue.load,
  enrich: wrappedGlue.enrich,
  enabled: wrappedGlue.enabled,
};

// ================================================================================== runtime
/**
 * The bridge between Swift and the bundle: host health, the `window` CustomEvent bus that
 * upstream uses for cross-module signals, and direct storage access for debugging.
 */
export const runtime = {
  upstreamRev: typeof __HARBOR_UPSTREAM_REV__ === "string" ? __HARBOR_UPSTREAM_REV__ : "unknown",
  builtAt: typeof __HARBOR_BUILT_AT__ === "string" ? __HARBOR_BUILT_AT__ : "unknown",
  /** Everything the host still has to implement; must be empty before anything else is called. */
  missingHostFunctions: shims.missingHostFunctions,
  hostFunctions: shims.hostFunctions,
  /** Observe every event upstream dispatches on `window`. Returns an unsubscribe function. */
  onEvent: shims.events.on,
  /** Dispatch an event into the bundle (Swift -> JS). */
  emitEvent: shims.events.emit,
  storageKeys: () => shims.localStorage.__harborKeys(),
  /** Tell the bundle a key changed underneath it (e.g. after an account sync). */
  syncStorage: (key: string, value: string | null) => shims.localStorage.__harborSync(key, value),
  randomUuid,
  pendingTimers: () => shims.timers.pending(),
  /** Self-check: proves fetch, URL, storage, crypto and timers all work through the host. */
  async selfTest(): Promise<{ ok: boolean; checks: Record<string, string> }> {
    const checks: Record<string, string> = {};
    const note = (k: string, fn: () => unknown) => {
      try {
        checks[k] = String(fn());
      } catch (e) {
        checks[k] = `THREW ${(e as Error).message}`;
      }
    };
    note("url", () => new URL("../b?x=1 2", "https://a.com/p/q").href);
    note("uuid", () => randomUuid().length);
    note("storage", () => {
      globalThis.localStorage.setItem("harbor.engine.selftest", "1");
      const v = globalThis.localStorage.getItem("harbor.engine.selftest");
      globalThis.localStorage.removeItem("harbor.engine.selftest");
      return v;
    });
    note("intl", () => new Intl.NumberFormat("en-US").format(1234.5));
    try {
      const res = await fetch("https://v3-cinemeta.strem.io/catalog/movie/top.json");
      const json = (await res.json()) as { metas?: Meta[] };
      checks.fetch = `${res.status} ${json.metas?.length ?? 0} metas`;
    } catch (e) {
      checks.fetch = `THREW ${(e as Error).message}`;
    }
    await new Promise<void>((r) => setTimeout(r, 1));
    checks.timers = "fired";
    return { ok: Object.values(checks).every((v) => !v.startsWith("THREW")), checks };
  },
};

export type { Meta, Settings };
export type { Addon, AddonRow, CatalogDef, AddonCatalogCursor } from "@/lib/addons";
export type { LibraryItem, User } from "@/lib/stremio";
