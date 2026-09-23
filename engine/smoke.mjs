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

  // ------------------------------------------------------------------- rooms (no TMDB key)
  const s0 = engine.settings.load();
  const home = await r.timed("rooms.home(cinemeta fallback)", () => engine.rooms.home(s0, null));
  r.ok("rooms.home returns Cinemeta rows", home && home.rows.length >= 10 && !home.failed, JSON.stringify(home && { rows: home.rows.length, first: home.rows[0] && home.rows[0].name, n: home.rows[0] && home.rows[0].metas.length, hero: home.hero.length }));
  r.ok("rooms.home rows are poster/rank with metas", home && home.rows.every((x) => (x.shape === "poster" || x.shape === "rank") && Array.isArray(x.metas)));
  const movies = await r.timed("rooms.catalog(movies, fallback)", () => engine.rooms.catalog("movies", s0));
  r.ok("rooms.catalog(movies) returns Top Movies + genre rows", movies && movies.rows.length >= 5 && movies.rows[0].name === "Top Movies", JSON.stringify(movies && movies.rows.map((x) => x.name).slice(0, 6)));
  const shows = await r.timed("rooms.catalog(shows, fallback)", () => engine.rooms.catalog("shows", s0));
  r.ok("rooms.catalog(shows) returns Top Series + genre rows", shows && shows.rows.length >= 5 && shows.rows[0].name === "Top Series", JSON.stringify(shows && shows.rows.map((x) => x.name).slice(0, 6)));
  r.ok("rooms.catalog dedups across rows", (() => {
    if (!movies) return false;
    const seen = new Set(); let dup = 0;
    for (const row of movies.rows) for (const m of row.metas) { if (seen.has(m.id)) dup++; seen.add(m.id); }
    return dup === 0;
  })());
  const spec = engine.rooms; r.ok("rooms.TOP10_ROW_KEY", spec.TOP10_ROW_KEY === "bp-top10");
  const homeP = await r.timed("rooms.homeFor(profile)", () => engine.rooms.homeFor("p_smoke", true, null));
  r.ok("rooms.homeFor loads profile settings inside the engine", homeP && homeP.rows.length >= 10);
  const pageable = homeP.rows.find((x) => x.hasMore);
  const pagedMetas = pageable ? await r.timed(`rooms.page(home, ${pageable.key}, 2)`, () => engine.rooms.page("home", pageable.key, 2)) : [];
  const disc = await r.timed("discoverRoom.buildFor(no key)", () => engine.discoverRoom.buildFor("p_smoke", true));
  r.ok("discoverRoom rails come back without a TMDB key", disc && disc.rails.length >= 3, JSON.stringify(disc && { rails: disc.rails.map((x) => x.name), queue: disc.queue.status, genres: disc.genres.length }));
  r.ok("discoverRoom genres carry palette", disc && disc.genres.length === 18 && disc.genres[0].from.startsWith("oklch"));
  const events = [];
  const off = engine.runtime.onEvent((type, detail) => { if (type === "harbor-tvos:streams") events.push(detail); });
  const shaw = { id: "tt0111161", type: "movie", name: "The Shawshank Redemption", releaseInfo: "1994" };
  const ss = await r.timed("streamsRoom.search(tt0111161, no addons)", () => engine.streamsRoom.search("t1", "p_smoke", true, null, shaw, null));
  off();
  r.ok("streamsRoom.search returns a result shape", ss && ss.imdb.id === "tt0111161" && ss.streamIds.length > 0 && (ss.result === null || Array.isArray(ss.result.picker.all)), JSON.stringify(ss && { imdb: ss.imdb, ids: ss.streamIds, addons: ss.addonCount, all: ss.result && ss.result.picker.all.length, error: ss.error, events: events.length }));
  const prog = await r.timed("player.saveProgress(local only)", () => engine.player.saveProgress({ meta: shaw, positionMs: 600000, durationMs: 8500000, authKey: null }));
  const back = engine.player.localResume("tt0111161", null, null);
  r.ok("player.saveProgress writes harbor.resume", prog && prog.cloud === "none" && back && back.ms === 600000, JSON.stringify({ prog, back }));
  const sp = await r.timed("player.startPosition(local)", () => engine.player.startPosition(shaw, null, null, null, "tt0111161", true, null));
  r.ok("player.startPosition reads it back", sp && sp.ms === 600000, JSON.stringify(sp));
  const done = await engine.player.saveProgress({ meta: shaw, positionMs: 8000000, durationMs: 8500000, authKey: null, flush: true });
  r.ok("watched at 85% clears resume", done.watched === true && engine.player.localResume("tt0111161", null, null) === null, JSON.stringify(done));
  await engine.player.saveProgress({ meta: shaw, positionMs: 900000, durationMs: 8500000, authKey: null });
  const cwl = await r.timed("rooms.continueWatchingFor(local only)", () => engine.rooms.continueWatchingFor("p_smoke", true, null));
  r.ok("local resume shows up in Continue Watching", cwl.length === 1 && cwl[0]._id === "tt0111161" && cwl[0].state.timeOffset === 900000, JSON.stringify(cwl.map((i) => [i._id, i.state.timeOffset])));
  const subs = await r.timed("subtitles.search(tt0111161)", () => engine.subtitles.search("p_smoke", true, null, shaw, null, null, "tt0111161"));
  r.ok("subtitles.search finds English subtitles", Array.isArray(subs) && subs.length > 0 && subs[0].url, JSON.stringify(subs.slice(0, 2).map((x) => [x.source, x.lang, x.url.slice(0, 60)])));
  if (subs.length > 0) {
    const prep = await r.timed("subtitles.prepare(first)", () => engine.subtitles.prepare(subs[0].url));
    r.ok("subtitles.prepare returns text", prep && prep.text.length > 100 && ["srt", "vtt", "ass", "ssa"].includes(prep.format), JSON.stringify(prep && { format: prep.format, encoding: prep.encoding, len: prep.text.length }));
  }
  // Jikan (api.jikan.moe) is public and often 429/504s; only judge the builder when it answers.
  const jikanUp = await fetch("https://api.jikan.moe/v4/top/anime?sfw=true&filter=airing&page=1").then((x) => x.ok, () => false);
  if (jikanUp) {
    const an = await r.timed("rooms.anime()", () => engine.rooms.anime());
    r.ok("rooms.anime returns Jikan rows", an && an.rows.length >= 2 && an.rows[0].metas.length >= 6, JSON.stringify(an && an.rows.map((x) => [x.name, x.metas.length])));
  } else {
    console.log("  (skipped rooms.anime: Jikan unreachable right now)");
  }
  r.eq("player.watchedEpisodes without auth", await engine.player.watchedEpisodes(null, shaw), []);
  // Round-trip a synthetic Stremio watched bitfield (zlib-framed like DecompressionStream("deflate")).
  {
    const zlib = await import("node:zlib");
    const vids = Array.from({ length: 10 }, (_, i) => ({ id: `tt1:1:${i + 1}`, season: 1, episode: i + 1, released: `2020-01-${String(i + 1).padStart(2, "0")}T00:00:00Z` }));
    const bits = new Uint8Array(2); bits[0] |= 1 << 0; bits[0] |= 1 << 3; bits[1] |= 1 << 1; // episodes 1, 4, 10
    const field = `tt1:1:10:10:${zlib.deflateSync(Buffer.from(bits)).toString("base64")}`;
    r.eq("player.decodeWatchedField decodes a zlib bitfield", engine.player.decodeWatchedField(field, vids), ["1:1", "1:4", "1:10"]);
  }
  const pl = engine.live.addPlaylist("iptv-org US", "https://iptv-org.github.io/iptv/countries/us.m3u");
  r.ok("live.addPlaylist stores in harbor.iptv.playlists.v1", engine.live.playlists().some((p) => p.id === pl.id));
  const ch = await r.timed("live.channels(iptv-org US)", () => engine.live.channels(pl.id));
  r.ok("live.channels parses groups and channels", ch && ch.groups.length > 3 && ch.total > 100 && ch.groups[0].channels[0].url.startsWith("http"), JSON.stringify(ch && { groups: ch.groups.length, total: ch.total, first: ch.groups[0] && [ch.groups[0].name, ch.groups[0].channels.length] }));
  engine.live.removePlaylist(pl.id);
  const sk = await r.timed("skip.segments(Breaking Bad S1E1)", () => engine.skip.segments("p_smoke", true, { id: "tt0903747", type: "series", name: "Breaking Bad" }, { season: 1, episode: 1, imdbId: "tt0903747", imdbSeason: 1, imdbEpisode: 1 }, 3480));
  r.ok("skip.segments returns a (possibly empty) segment list", Array.isArray(sk) && sk.every((x) => x.startSec < x.endSec), JSON.stringify(sk.slice(0, 3)));
  const fs = await import("node:fs");
  const awardsRaw = fs.readFileSync(new URL("../reference/harbor/src/data/awards.json", import.meta.url), "utf8");
  const t0aw = Date.now(); const ver = engine.discoverRoom.installAwards(awardsRaw);
  r.ok("discoverRoom.installAwards accepts the 4 MB catalog", ver > 0, `${(awardsRaw.length / 1048576).toFixed(1)} MB in ${Date.now() - t0aw} ms`);
  const aw = engine.discoverRoom.awards();
  r.ok("discoverRoom.awards has bundled bodies", aw.summaries.length >= 5 && aw.overview.wins > 100, JSON.stringify({ n: aw.summaries.length, first: aw.summaries[0] && aw.summaries[0].title, overview: aw.overview }));
  const ad = engine.discoverRoom.awardDetail(aw.summaries[0].type);
  r.ok("discoverRoom.awardDetail has categories with winners", ad.groups.length > 0 && ad.groups[0].entries.length > 0, JSON.stringify({ title: ad.title, groups: ad.groups.length, first: ad.groups[0] && ad.groups[0].entries[0] }));
  const pp = await r.timed("discoverRoom.people(24)", () => engine.discoverRoom.people(24));
  r.ok("discoverRoom.people returns ranked people (or [] if harbor.site is unreachable)", Array.isArray(pp), JSON.stringify(pp.slice(0, 2)));
  r.eq("trakt.status when signed out", engine.trakt.status(), { authenticated: false, username: null });
  const dc = await r.timed("trakt.deviceCode()", () => engine.trakt.deviceCode().catch((e) => ({ error: e.message })));
  r.ok("trakt.deviceCode returns a user code (or a clear error)", (dc && dc.userCode && dc.userCode.length >= 6) || (dc && dc.error), JSON.stringify(dc && { code: dc.userCode, url: dc.verificationUrl, error: dc.error }));
  const scrob = await engine.trakt.scrobble("start", "tt0111161", null, 5);
  r.eq("trakt.scrobble skips when not connected", scrob, { sent: false, reason: "not-connected" });
  r.ok("rooms.page returns a second page for a pageable row", !pageable || (Array.isArray(pagedMetas) && pagedMetas.length > 0), JSON.stringify({ key: pageable && pageable.key, n: pagedMetas.length }));
}

// --------------------------------------------------------------------------- report
console.log(`\nbundle ${(app.bytes / 1024).toFixed(0)} KB, evaluated in ${app.loadMs.toFixed(0)} ms`);
console.log(`localStorage keys reaching the host: ${JSON.stringify([...app.node.storage.keys()].sort())}`);
console.log(`host: ${app.node.stats.requests} requests, ${(app.node.stats.bytes / 1024).toFixed(0)} KB downloaded`);
app.dispose();
r.finish();
