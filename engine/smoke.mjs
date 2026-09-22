// Exercises the whole engine bundle inside a bare vm context - the JavaScriptCore analogue -
// with the Node implementation of the __harbor_host contract. Real network is used where
// the endpoint is public (Cinemeta, Stremio API); TMDB is driven through a recording host
// so the URL builders are tested without a key.
//
//   node smoke.mjs            full run
//   node smoke.mjs --offline  skip the live-network section
import { loadEngine, createReporter } from "./test/harness.mjs";

const OFFLINE = process.argv.includes("--offline");
const r = createReporter("smoke");

// ---------------------------------------------------------------------------- boot
const seeded = new Map([
  // One installed addon so gatherCatalogAddons()/loadAddonRows() have something to do
  // without a Stremio account. This is the exact shape upstream's addon-store writes.
  [
    "harbor.installed-addons.default",
    JSON.stringify([{ transportUrl: "https://v3-cinemeta.strem.io/manifest.json" }]),
  ],
  ["harbor.profiles.v1", JSON.stringify({ activeId: "default", profiles: [{ id: "default", isPrimary: true }] })],
]);
const tmdbRequests = [];
const app = loadEngine({ storage: seeded, onFetch: (req) => tmdbRequests.push(req.url) });
const { engine, run } = app;

r.ok("bundle loads in a bare context", true);
r.eq("host contract satisfied", engine.runtime.missingHostFunctions(), []);
r.ok("benchmark still works", (() => {
  const b = engine.benchmark(50);
  return b.streams === 850 && b.kept > 0 && typeof b.best === "string";
})(), JSON.stringify(engine.benchmark(1)));

// ------------------------------------------------------------------------ settings
const defaults = engine.settings.DEFAULT;
r.ok("settings.DEFAULT is a populated object", Object.keys(defaults).length > 50, `${Object.keys(defaults).length} keys`);
r.eq("settings.STORAGE_KEY", engine.settings.STORAGE_KEY, "harbor.settings");
const loaded = engine.settings.load();
r.ok("settings.load() with empty storage returns defaults", loaded.tmdbKey === defaults.tmdbKey && loaded.uiLanguage === defaults.uiLanguage);
const patched = engine.settings.patch({ cinemetaEnabled: false });
r.eq("settings.patch writes through", [patched.cinemetaEnabled, JSON.parse(app.node.storage.get("harbor.settings")).cinemetaEnabled], [false, false]);
r.eq("cinemeta honours the stored flag", engine.cinemeta.enabled(), false);
engine.settings.patch({ cinemetaEnabled: true });
r.eq("cinemeta re-enabled", engine.cinemeta.enabled(), true);

// --------------------------------------------------------------- pure browse helpers
r.eq("narrowMediaType", [engine.cinemeta.narrowMediaType("series"), engine.cinemeta.narrowMediaType("anime")], ["series", "movie"]);
r.eq("libraryMetaType", engine.stremio.libraryMetaType("series"), "series");
r.eq("episodeFromVideoId", engine.stremio.episodeFromVideoId("tt0944947:3:9"), { season: 3, episode: 9 });
r.eq("cwSortKey orders by recency", (() => {
  const a = { _id: "a", state: { timeOffset: 10, lastWatched: "2026-01-02T00:00:00.000Z" } };
  const b = { _id: "b", state: { timeOffset: 10, lastWatched: "2026-01-01T00:00:00.000Z" } };
  return engine.stremio.cwSortKey(a) > engine.stremio.cwSortKey(b);
})(), true);
r.eq("addonAccepts", [
  engine.addons.addonAccepts({ manifest: { resources: ["catalog", "meta"], types: ["movie"], idPrefixes: ["tt"] } }, "meta", "movie", "tt1234567"),
  engine.addons.addonAccepts({ manifest: { resources: ["catalog"], types: ["movie"] } }, "meta", "movie", "tt1"),
], [true, false]);
r.eq("isCollectionCatalog", engine.addons.isCollectionCatalog({ type: "movie", id: "tmdb.collections", name: "Collections" }), true);
r.ok("normalizeName keeps something printable", typeof engine.addons.normalizeName("Top - movie", "movie") === "string");
r.ok("discover starts cold", engine.discover.isCold() === true);
// trackEvent(id, kind, meta?, ts?) - upstream's real signature.
engine.discover.trackEvent("tt0111161", "open", engine.discover.profileFromMeta({ id: "tt0111161", type: "movie", name: "The Shawshank Redemption", genres: ["Drama"] }));
r.ok("discover.trackEvent records an event", engine.discover.store().events.length === 1 && engine.discover.store().events[0].id === "tt0111161", JSON.stringify(engine.discover.store().events));
r.ok("discover warms up after an event", engine.discover.isCold() === false);
r.ok("discover.score ranks a matching profile above an unrelated one", (() => {
  const aff = engine.discover.store().affinity;
  const drama = engine.discover.score(engine.discover.profileFromMeta({ id: "tt1", type: "movie", name: "x", genres: ["Drama"] }), aff);
  const other = engine.discover.score(engine.discover.profileFromMeta({ id: "tt2", type: "movie", name: "y", genres: ["Horror"] }), aff);
  return drama > other;
})());
r.ok("serviceCatalog exposes categories", Array.isArray(engine.serviceCatalog.CATEGORIES) && engine.serviceCatalog.CATEGORIES.length > 0);
r.ok("feed.fallbackShelves returns shelves", Array.isArray(engine.feed.fallbackShelves()) && engine.feed.fallbackShelves().length > 0);
r.ok("region.localeForRegion", typeof engine.region.localeForRegion("US") === "object");
r.ok("rpdbPoster builds a RatingPosterDB url", (() => {
  const p = engine.providers.rpdbPoster("t0-free-rpdb", "tt0111161");
  return typeof p === "string" && p.includes("ratingposterdb.com") && p.includes("tt0111161");
})(), String(engine.providers.rpdbPoster("t0-free-rpdb", "tt0111161")));
r.eq("rpdbPoster falls back on an unknown id", engine.providers.rpdbPoster("t0-free-rpdb", "weird:id", "FALLBACK"), "FALLBACK");

// --------------------------------------------------- TMDB URL builders (no live TMDB)
// The recording host answers every TMDB call with an empty page, so we can assert the URL
// upstream actually builds without needing a key.
{
  const captured = [];
  const rec = loadEngine({
    onFetch: (req) => captured.push(req.url),
  });
  rec.node.host.fetch = async (req) => {
    captured.push(req.url);
    return { status: 200, statusText: "OK", headers: { "content-type": "application/json" }, url: req.url, body: JSON.stringify({ results: [], parts: [], results_by_region: {} }) };
  };
  const KEY = "0123456789abcdef0123456789abcdef";
  await rec.engine.tmdb.trending(KEY, "movie", "week");
  await rec.engine.tmdb.movieRow(KEY, "top_rated", "GB", 2);
  await rec.engine.tmdb.movieRow(KEY, "now_playing", "US", 1);
  await rec.engine.tmdb.watchProviders(KEY, "movie", 278, "DE");
  await rec.engine.tmdb.searchTitle(KEY, "movie", "Amélie & Co");
  await rec.engine.tmdb.idFromImdb(KEY, "tt0111161").catch(() => null);
  const find = (frag) => captured.find((u) => u.includes(frag));
  r.eq("tmdb trending url", find("trending/"), `https://api.themoviedb.org/3/trending/movie/week?api_key=${KEY}&page=1`);
  r.eq("tmdb top_rated url", find("movie/top_rated"), `https://api.themoviedb.org/3/movie/top_rated?api_key=${KEY}&page=2&region=GB`);
  r.ok("tmdb now_playing becomes a discover query", /discover\/movie\?.*with_release_type=3/.test(find("discover/movie") ?? ""), find("discover/movie"));
  r.eq("tmdb watch providers url", find("watch/providers"), `https://api.themoviedb.org/3/movie/278/watch/providers?api_key=${KEY}`);
  r.ok("tmdb search percent-encodes unicode + reserved chars", /search\/movie\?api_key=[0-9a-f]+&include_adult=false&query=Am%C3%A9lie\+%26\+Co/.test(find("search/movie") ?? ""), find("search/movie"));
  r.ok("tmdb imdb resolve url", (find("find/tt0111161") ?? "").includes("external_source=imdb_id"), find("find/tt0111161"));
  r.ok("TMDB API_BASE/IMAGE_BASE exported", rec.engine.tmdb.API_BASE === "https://api.themoviedb.org/3" && rec.engine.tmdb.IMAGE_BASE === "https://image.tmdb.org/t/p");
  rec.dispose();
}

// ------------------------------------------------------------------- live network
if (!OFFLINE) {
  const self = await r.timed("runtime.selfTest()", () => engine.runtime.selfTest());
  r.ok("selfTest all green", self && self.ok, JSON.stringify(self));

  const top = await r.timed("cinemeta.topMovies()", () => engine.cinemeta.topMovies());
  r.ok("cinemeta.topMovies returns metas", Array.isArray(top) && top.length >= 20, `${top && top.length} rows`);
  r.ok("cinemeta meta shape", top && top[0] && typeof top[0].id === "string" && top[0].id.startsWith("tt") && typeof top[0].name === "string", JSON.stringify(top && top[0] && { id: top[0].id, name: top[0].name, type: top[0].type }));

  const genre = await r.timed("cinemeta.topMovies('Science Fiction')", () => engine.cinemeta.topMovies("Science Fiction"));
  const sameIds = genre && top && JSON.stringify(genre.map((m) => m.id)) === JSON.stringify(top.map((m) => m.id));
  r.ok("cinemeta genre row differs from the default row", genre && genre.length > 0 && !sameIds, `${genre && genre.length} rows, first=${genre && genre[0] && genre[0].id}`);

  const series = await r.timed("cinemeta.topSeries()", () => engine.cinemeta.topSeries());
  r.ok("cinemeta.topSeries returns series", series && series.length > 0 && series[0].type === "series");

  const meta = await r.timed("cinemeta.meta(movie, tt0111161)", () => engine.cinemeta.meta("movie", "tt0111161"));
  r.ok("cinemeta.meta returns the film", meta && meta.name === "The Shawshank Redemption", JSON.stringify(meta && { id: meta.id, name: meta.name, year: meta.releaseInfo }));
  const cached = await r.timed("cinemeta.meta (cached)", () => engine.cinemeta.meta("movie", "tt0111161"));
  r.ok("cinemeta.meta is memoized", cached && cached.id === "tt0111161");

  const gathered = await r.timed("addons.gatherCatalogAddons(null)", () => engine.addons.gatherCatalogAddons(null));
  r.ok("gatherCatalogAddons finds the seeded addon", Array.isArray(gathered) && gathered.length === 1 && gathered[0].manifest.id === "com.linvo.cinemeta", JSON.stringify(gathered && gathered.map((a) => a.manifest && a.manifest.id)));
  r.ok("manifest carries catalogs", gathered && gathered[0] && gathered[0].manifest.catalogs.length > 0, String(gathered && gathered[0] && gathered[0].manifest.catalogs.length));

  const rows = await r.timed("addons.loadAddonRows(null)", () => engine.addons.loadAddonRows(null, { cap: 8 }));
  r.ok("loadAddonRows returns populated rows", Array.isArray(rows) && rows.length > 0 && rows.every((row) => Array.isArray(row.metas)), `${rows && rows.length} rows: ${rows && rows.slice(0, 4).map((x) => `${x.title}(${x.metas.length})`).join(", ")}`);

  const page = await r.timed("addons.fetchAddonCatalogPage(skip=100)", () =>
    engine.addons.fetchAddonCatalogPage("https://v3-cinemeta.strem.io", "movie", "top", 100),
  );
  r.ok("catalog paging works", Array.isArray(page) && page.length > 0 && page[0].id !== (top && top[0].id), `${page && page.length} metas, first=${page && page[0] && page[0].id}`);

  const addonMeta = await r.timed("addons.fetchAddonMeta()", () =>
    engine.addons.fetchAddonMeta("https://v3-cinemeta.strem.io", "series", "tt0944947"),
  );
  r.ok("fetchAddonMeta returns videos", addonMeta && addonMeta.name === "Game of Thrones" && Array.isArray(addonMeta.videos) && addonMeta.videos.length > 60, JSON.stringify(addonMeta && { name: addonMeta.name, videos: addonMeta.videos && addonMeta.videos.length }));

  const fetcher = engine.addons.createAddonCatalogFetcher({ base: "https://v3-cinemeta.strem.io", type: "series", id: "top" });
  const p1 = await r.timed("createAddonCatalogFetcher page 1", () => fetcher(1));
  const p2 = await r.timed("createAddonCatalogFetcher page 2", () => fetcher(2, p1 ? p1.length : 0));
  r.ok("fetcher pages do not repeat", p1 && p2 && p1.length > 0 && p2.length > 0 && p1[0].id !== p2[0].id, `${p1 && p1[0] && p1[0].id} vs ${p2 && p2[0] && p2[0].id}`);

  // Stremio API transport: a deliberately wrong login must come back as the API's own
  // error, which proves POST + JSON + error unwrapping all work end to end.
  const loginErr = await r.timed("stremio.login (expected failure)", () =>
    engine.stremio.login("harbor-tvos-smoke@example.invalid", "definitely-not-a-password").then(() => null, (e) => e.message),
  );
  r.ok("stremio.login surfaces the API error", typeof loginErr === "string" && loginErr.length > 0, String(loginErr));

  const sc = await r.timed("search.cinemeta('blade runner')", () => engine.search.cinemeta("blade runner"));
  r.ok("search.cinemeta finds movies and series", sc && sc.movies.length > 0 && Array.isArray(sc.series), JSON.stringify(sc && { movies: sc.movies.length, series: sc.series.length, first: sc.movies[0] && sc.movies[0].name }));
  const sa = await r.timed("search.addonCatalogs(seeded)", () => engine.search.addonCatalogs(gathered ?? [], "inception"));
  r.ok("search.addonCatalogs uses the installed addon", sa && (sa.movies.length > 0 || sa.series.length > 0), JSON.stringify(sa && { movies: sa.movies.length, series: sa.series.length }));
  r.eq("search.detectIntent('1994')", engine.search.detectIntent("1994").kind, "year");

  const anizip = await r.timed("providers.aniZipByMal(1535)", () => engine.providers.aniZipByMal(1535));
  r.ok("anizip returns a mapping", anizip && anizip.mappings && typeof anizip.mappings === "object", JSON.stringify(anizip && Object.keys(anizip)));
}

// --------------------------------------------------------------------------- report
console.log(`\nbundle ${(app.bytes / 1024).toFixed(0)} KB, evaluated in ${app.loadMs.toFixed(0)} ms`);
console.log(`localStorage keys reaching the host: ${JSON.stringify([...app.node.storage.keys()].sort())}`);
console.log(`host: ${app.node.stats.requests} requests, ${(app.node.stats.bytes / 1024).toFixed(0)} KB downloaded`);
app.dispose();
r.finish();
