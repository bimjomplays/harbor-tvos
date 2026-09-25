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

// ------------------------------------------------------------ sports addon sources (SP-3)
{
  const base = "https://sportsaddon.example.invalid";
  const manifest = { id: "org.example.sportslive", version: "1.0.0", name: "Sports Live", resources: ["catalog", "stream"], types: ["tv"], idPrefixes: ["ev"], catalogs: [{ type: "tv", id: "live", name: "Live Events" }] };
  const rec = loadEngine({ storage: new Map([
    ["harbor.profiles.v1", JSON.stringify({ activeId: "default", profiles: [{ id: "default", isPrimary: true }] })],
    ["harbor.installed-addons.default", JSON.stringify([{ transportUrl: `${base}/manifest.json`, manifest }])],
  ]) });
  const hits = [];
  rec.node.host.fetch = async (req) => {
    hits.push(req.url);
    const json = (body) => ({ status: 200, statusText: "OK", headers: { "content-type": "application/json" }, url: req.url, body: JSON.stringify(body) });
    if (req.url === `${base}/manifest.json`) return json(manifest);
    if (req.url.startsWith(`${base}/catalog/tv/live`)) return json({ metas: [
      { id: "ev1", type: "tv", name: "Los Angeles Lakers vs Boston Celtics" },
      { id: "ev2", type: "tv", name: "Some Other Channel" },
    ] });
    if (req.url === `${base}/stream/tv/ev1.json`) return json({ streams: [
      { name: "HD", title: "Main feed", url: "https://cdn.example.invalid/ev1.m3u8" },
      { name: "Web", externalUrl: "https://watch.example.invalid/ev1" },
      { name: "P2P", infoHash: "0123456789abcdef0123456789abcdef01234567" },
    ] });
    return { status: 404, statusText: "Not Found", headers: {}, url: req.url, body: "" };
  };
  const game = { id: "g-addon", league: "NBA", state: "in", detail: "Q2", home: { id: "1", name: "Boston Celtics", abbr: "BOS", logo: "", score: "50", winner: false }, away: { id: "2", name: "Los Angeles Lakers", abbr: "LAL", logo: "", score: "48", winner: false }, startMs: Date.now() - 3600000 };
  const before = await rec.engine.sports.addonSources(game, null);
  r.eq("sports.addonSources is empty before sports consent", [before.available, before.installed], [0, false]);
  rec.engine.sports.accept();
  const src = await rec.engine.sports.addonSources(game, null);
  r.ok("sports.addonSources finds the matching addon listing first", src.installed && src.available >= 1 && src.matched >= 1 && /lakers/i.test(src.rows[0].name) && src.rows[0].match !== null && src.rows[0].addonName === "Sports Live", JSON.stringify(src));
  const w = await rec.engine.sports.watch(game, { matched: src.matched, available: src.available });
  r.eq("sports.watch plans addons when an addon listing matches and no Live TV source exists", w.plan, "addons");
  r.eq("sports.watch without addons and no source plans setup", (await rec.engine.sports.watch(game, null)).plan, "setup");
  const st = await rec.engine.sports.addonStreams(src.rows[0].key);
  r.ok("sports.addonStreams lists the listing's streams", st.status === "ok" && st.rows.length === 3 && st.rows[0].name === "HD" && st.rows[0].title === "Main feed" && st.rows[1].external === true, JSON.stringify(st));
  const play = await rec.engine.sports.addonPlay(src.rows[0].key, 0);
  r.ok("sports.addonPlay resolves a direct link to play", play.kind === "play" && play.url === "https://cdn.example.invalid/ev1.m3u8" && play.subtitle === "Sports Live", JSON.stringify(play));
  const ext = await rec.engine.sports.addonPlay(src.rows[0].key, 1);
  r.eq("sports.addonPlay sends an external page to the phone", [ext.kind, ext.url], ["external", "https://watch.example.invalid/ev1"]);
  r.eq("sports.addonPlay hands a torrent off to the stream list", (await rec.engine.sports.addonPlay(src.rows[0].key, 2)).kind, "handoff");
  const post = await rec.engine.sports.addonSources({ ...game, id: "g-post", state: "post" }, null);
  r.eq("sports.addonSources is empty for a finished game", post.available, 0);
}

// ------------------------------------ episode watched state, marks, spoiler masks (audit 4 + 6)
{
  const zlib = await import("node:zlib");
  const id = "tt7000001";
  const vids = Array.from({ length: 8 }, (_, i) => ({ id: `${id}:1:${i + 1}`, season: 1, episode: i + 1, released: `2020-01-${String(i + 1).padStart(2, "0")}T00:00:00Z` }));
  vids.push({ id: `${id}:2:1`, season: 2, episode: 1, released: "2099-01-01T00:00:00Z" });
  const meta = { id, type: "series", name: "Smoke Show", videos: vids };
  const refs = vids.map((v) => ({ season: v.season, episode: v.episode, released: v.released }));
  const bits = new Uint8Array(2); bits[0] |= 1 << 0; bits[0] |= 1 << 1; bits[0] |= 1 << 4; // S1E1, S1E2, S1E5
  const libField = `${id}:1:5:5:${zlib.deflateSync(Buffer.from(bits)).toString("base64")}`;
  let libItem = { _id: id, type: "series", name: "Smoke Show", state: { watched: libField, timeOffset: 0, duration: 0 }, removed: false, temp: false, _ctime: "2024-01-01T00:00:00.000Z", _mtime: "2024-01-01T00:00:00.000Z" };
  const puts = [];
  const ew = loadEngine({ storage: new Map([
    ["harbor.profiles.v1", JSON.stringify({ activeId: "default", profiles: [{ id: "default", isPrimary: true }] })],
    ["harbor.resume", JSON.stringify({ [`${id}|s1e7`]: { ms: 120000, t: 1 } })],
  ]) });
  ew.node.host.fetch = async (req) => {
    const json = (body) => ({ status: 200, statusText: "OK", headers: { "content-type": "application/json" }, url: req.url, body: JSON.stringify(body) });
    if (req.url.endsWith("/api/datastoreGet")) return json({ result: libItem ? [libItem] : [] });
    if (req.url.endsWith("/api/datastorePut")) { const b = JSON.parse(req.body); puts.push(b.changes[0]); libItem = b.changes[0]; return json({ result: { success: true } }); }
    return { status: 404, statusText: "Not Found", headers: {}, url: req.url, body: "" };
  };
  const E = ew.engine;
  const st = () => E.episodeWatched.state(id, refs, 1, "default", true);
  const sorted = (a) => [...a].sort();

  const enc = E.player.encodeWatchedField(["1:1", "1:4", "1:8"], vids);
  r.eq("player.encodeWatchedField round-trips through decodeWatchedField", E.player.decodeWatchedField(enc, vids), ["1:1", "1:4", "1:8"]);
  r.ok("player.encodeWatchedField anchors on the last watched video", typeof enc === "string" && enc.startsWith(`${id}:1:8:8:`), enc);

  r.eq("episodeWatched.state is empty before any source", st().watched, []);
  await E.episodeWatched.load("AUTH", meta, id);
  r.eq("episodeWatched.load adopts the Stremio library bitfield as remote marks", sorted(st().watched), ["1:1", "1:2", "1:5"]);
  r.eq("episodeWatched.state: an unwatched episode with a resume entry reads started", st().started, ["1:7"]);
  r.eq("episodeWatched.state: no masks and both detail toggles on by default", [Object.keys(st().masks).length, st().showEpisodeRating, st().showEpisodeDescription], [0, true, true]);

  E.episodeWatched.mark("AUTH", meta, id, { season: 1, episode: 2 }, "episode", false, refs, "default", true);
  r.eq("episodeWatched.mark unwatched drops a library-sourced mark at once", sorted(st().watched), ["1:1", "1:5"]);
  await E.episodeWatched.settle();
  const pushed = puts.at(-1);
  r.ok("episodeWatched.mark pushes the merged bitfield into the library entry", pushed && pushed._id === id && pushed.name === "Smoke Show" && JSON.stringify(E.player.decodeWatchedField(pushed.state.watched, vids)) === JSON.stringify(["1:1", "1:5"]), JSON.stringify(pushed && pushed.state));
  // A later pull of the same (older than the unmark) library write must not bring it back.
  E.episodeWatched.reconcileLibraryWatched({ ...libItem, state: { watched: libField }, _mtime: "2024-01-01T00:00:00.000Z" }, meta);
  r.eq("a library write older than the unmark does not re-add it", sorted(st().watched), ["1:1", "1:5"]);

  E.episodeWatched.mark("AUTH", meta, id, { season: 1, episode: 3 }, "upTo", true, refs, "default", true);
  r.eq("episodeWatched.mark upTo marks every aired episode up to here", sorted(st().watched), ["1:1", "1:2", "1:3", "1:5"]);
  await E.episodeWatched.settle();
  r.eq("episodeWatched.mark upTo reaches the library bitfield", E.player.decodeWatchedField(puts.at(-1).state.watched, vids), ["1:1", "1:2", "1:3", "1:5"]);
  E.episodeWatched.mark(null, meta, id, { season: 1, episode: 7 }, "episode", true, refs, "default", true);
  r.eq("episodeWatched.mark watched adds one episode", st().watched.includes("1:7") && !st().started.includes("1:7"), true);
  E.episodeWatched.mark(null, meta, id, { season: 2, episode: 1 }, "season", true, refs, "default", true);
  r.eq("episodeWatched.mark season watched skips unaired episodes", E.episodeWatched.state(id, refs, 2, "default", true).watched.includes("2:1"), false);
  E.episodeWatched.mark(null, meta, id, { season: 1, episode: 1 }, "season", false, refs, "default", true);
  r.eq("episodeWatched.mark season unwatched clears the season", st().watched, []);
  E.episodeWatched.mark(null, meta, id, { season: 1, episode: 2 }, "upTo", true, refs, "default", true);

  // lib/spoilers.ts spoilerMaskFor: watched and next-up (spoilerSkipNext) cards stay clear.
  const base = E.settings.loadForProfile("default", true);
  E.settings.saveForProfile({ ...base, hideSpoilers: true, spoilerHideDescriptions: false, showEpisodeRating: false }, "default", true);
  const masked = st();
  r.eq("spoilers: watched episodes and the next-up are clear, later ones masked", sorted(Object.keys(masked.masks)), ["1:4", "1:5", "1:6", "1:7", "1:8"]);
  r.eq("spoilers: the mask follows the per-part toggles", masked.masks["1:4"], { thumb: true, title: true, desc: false });
  r.eq("showEpisodeRating off reaches the strip", masked.showEpisodeRating, false);
  E.settings.saveForProfile({ ...base, hideSpoilers: true, spoilerSkipNext: false }, "default", true);
  r.ok("spoilers: spoilerSkipNext off masks the next-up card too", "1:3" in st().masks);
  r.eq("episodeWatched.upNextMask masks an unwatched next episode", E.episodeWatched.upNextMask("default", true, false), { thumb: true, title: true, desc: true });
  r.eq("episodeWatched.upNextMask leaves a watched next episode clear", E.episodeWatched.upNextMask("default", true, true), { thumb: false, title: false, desc: false });
  E.settings.saveForProfile({ ...base, hideSpoilers: true, spoilerSkipNext: true }, "default", true);
  r.eq("episodeWatched.upNextMask: spoilerSkipNext keeps the up-next clear", E.episodeWatched.upNextMask("default", true, false), { thumb: false, title: false, desc: false });
  E.settings.saveForProfile({ ...base, hideSpoilers: false }, "default", true);
  r.eq("spoilers: hideSpoilers off clears every mask", Object.keys(st().masks).length, 0);
  await E.episodeWatched.settle();
  ew.dispose();
}

// ------------------------- anime named seasons + episode orders (audit 5), TVDB proxy fixtures
{
  const TVDB = "https://harbor.site/api/tvdb/v4";
  // TVDB series 100: aired S1E1-3 (2019), S2E1-2 (2020-10 → 2021-01), a special S0E1; absolute 1-5.
  const tv = [
    { id: 201, seasonNumber: 1, number: 1, absoluteNumber: 1, name: "Arrival", aired: "2019-01-06" },
    { id: 202, seasonNumber: 1, number: 2, absoluteNumber: 2, name: "The Road", aired: "2019-01-13" },
    { id: 203, seasonNumber: 1, number: 3, absoluteNumber: 3, name: "Harbor Lights", aired: "2019-03-24" },
    { id: 204, seasonNumber: 2, number: 1, absoluteNumber: 4, name: "Return", aired: "2020-10-04" },
    { id: 205, seasonNumber: 2, number: 2, absoluteNumber: 5, name: "The Long Night", aired: "2021-01-10", image: "/banners/ep205.jpg" },
    { id: 290, seasonNumber: 0, number: 1, name: "Recap Special", aired: "2019-06-01" },
  ];
  const extended = { seasons: [
    { number: 1, name: "Part One", type: { type: "official", name: "Aired Order" } },
    { number: 2, name: "The Second Arc", type: { type: "official", name: "Aired Order" } },
    { number: 0, name: "Specials", type: { type: "official", name: "Aired Order" } },
    { number: 1, name: "Absolute", type: { type: "absolute", name: "Absolute Order" } },
  ] };
  const kitsuEps = [
    { id: 11, number: 1, seasonNumber: 1, title: "Arrival", synopsis: "", thumbnail: null, airdate: "2019-01-06", length: 24, imdbSeason: 1, imdbEpisode: 1, absoluteNumber: 1 },
    { id: 12, number: 2, seasonNumber: 1, title: "The Road", synopsis: "", thumbnail: null, airdate: "2019-01-13", length: 24, imdbSeason: 1, imdbEpisode: 2, absoluteNumber: 2 },
    { id: 13, number: 3, seasonNumber: 1, title: "Harbor Lights", synopsis: "", thumbnail: null, airdate: "2019-03-24", length: 24, imdbSeason: 1, imdbEpisode: 3, absoluteNumber: 3 },
    { id: 14, number: 4, seasonNumber: 1, title: "Return", synopsis: "", thumbnail: null, airdate: "2020-10-04", length: 24, imdbSeason: 2, imdbEpisode: 1, absoluteNumber: 4 },
    { id: 15, number: 99, seasonNumber: 1, title: "Picture Drama", synopsis: "", thumbnail: null, airdate: "2021-05-01", length: 5, absoluteNumber: 99 },
  ];
  const an = loadEngine({ storage: new Map([
    ["harbor.profiles.v1", JSON.stringify({ activeId: "default", profiles: [{ id: "default", isPrimary: true }] })],
  ]) });
  const hits = [];
  an.node.host.fetch = async (req) => {
    hits.push(req.url);
    const json = (body) => ({ status: 200, statusText: "OK", headers: { "content-type": "application/json" }, url: req.url, body: JSON.stringify(body) });
    if (req.url === "https://api.ani.zip/mappings?kitsu_id=1") return json({ mappings: { kitsu_id: 1, thetvdb_id: 100 } });
    if (req.url === `${TVDB}/series/100/extended?short=true`) return json({ data: extended });
    const m = /\/series\/100\/episodes\/(default|absolute)(?:\/eng)?\?page=(\d+)$/.exec(req.url);
    if (m && req.url.startsWith(TVDB)) return json({ data: { episodes: m[2] === "0" ? tv : [] } });
    return { status: 404, statusText: "Not Found", headers: {}, url: req.url, body: "" };
  };
  const A = an.engine;
  const input = { metaId: "kitsu:1", kitsuId: 1, imdbId: null, canonicalId: "kitsu:1", episodes: kitsuEps };
  const key = A.settings.sourceKeyFor("default", true);

  r.eq("animeSeasons.seasonYears spans a two cour run", [A.animeSeasons.seasonYears({ from: "2020-10-04", to: "2021-01-10" }), A.animeSeasons.seasonYears({ year: "2019" }), A.animeSeasons.seasonYears({ from: "2019-01-06", to: "2019-03-24" })], ["2020-2021", "2019", "2019"]);
  r.eq("animeSeasons.shortOrderLabel drops the trailing Order", ["Aired Order", "TVDB Absolute Order", "DVD"].map(A.animeSeasons.shortOrderLabel), ["Aired", "TVDB Absolute", "DVD"]);
  r.eq("animeSeasons.intentSeasonKey: an entry that is all one later season opens on it", [A.animeSeasons.intentSeasonKey([{ id: 1, number: 1, imdbSeason: 3 }], 0), A.animeSeasons.intentSeasonKey(kitsuEps, 0), A.animeSeasons.intentSeasonKey(kitsuEps, 2)], ["3", null, "2"]);
  r.eq("animeSeasons.activeSeasonKey: a touched pick, then intent, then preferred", [["1", "2", "2"], ["gone", "2", "1"], [null, null, "2"], ["gone", null, null]].map(([s, i, p]) => A.animeSeasons.activeSeasonKey([{ key: "1" }, { key: "2" }], s, i, p)), ["1", "2", "2", "1"]);
  r.eq("animeSeasons.effectiveOrderType: official reads as aired, a missing type falls back", [A.animeSeasons.effectiveOrderType([{ value: "aired" }, { value: "absolute" }], "official"), A.animeSeasons.effectiveOrderType([{ value: "aired" }], "dvd"), A.animeSeasons.effectiveOrderType([{ value: "dvd" }], "absolute")], ["aired", "aired", "dvd"]);

  const v = await A.animeDetail.seasonsFor(input, "default", true, null, null);
  r.eq("animeDetail.seasons: the TVDB panel resolves through the Kitsu → TVDB mapping", v.source, "panel");
  r.eq("animeDetail.seasons: named chips in order, specials and extras last", v.seasons.map((s) => [s.key, s.name]), [["1", "Part One"], ["2", "The Second Arc"], ["0", "Specials"], ["specials", "Extras"]]);
  r.eq("animeDetail.seasons: year spans + episode counts on the chip (bp-anime-season-chip meta)", v.seasons.slice(0, 2).map((s) => s.meta), ["2019 · 3 episodes", "2020-2021 · 2 episodes"]);
  r.eq("animeDetail.seasons: one divider before the first extra", v.seasons.map((s) => s.divider), [false, false, true, false]);
  r.eq("animeDetail.seasons: the non-empty TVDB orders, short labels", v.orderTypes.map((o) => [o.value, o.short]), [["aired", "Aired"], ["absolute", "Absolute"], ["tvdbabsolute", "TVDB Absolute"]]);
  r.eq("animeDetail.seasons: aired order by default, opening on the first unwatched season", [v.orderType, v.seasonKey, v.hasChips], ["aired", "1", true]);
  const s2 = v.groups.find((g) => g.key === "2");
  r.ok("animeDetail.seasons: a Kitsu episode joins its TVDB season by S:E pair, TVDB fills the gap", s2 && s2.episodes.length === 2 && s2.episodes[0].id === 14 && s2.episodes[0].season === 1 && s2.episodes[0].number === 4
    && s2.episodes[1].id === -205 && s2.episodes[1].title === "The Long Night" && s2.episodes[1].thumbnail === "https://artworks.thetvdb.com/banners/ep205.jpg"
    && s2.episodes[1].playEpisode.season === 2 && s2.episodes[1].playEpisode.episode === 2 && s2.episodes[1].playEpisode.absoluteNumber === 5, JSON.stringify(s2));
  r.eq("animeDetail.seasons: an unclaimed Kitsu episode lands under Extras", v.groups.find((g) => g.key === "specials")?.episodes.map((e) => e.id), [15]);

  // The preferred season follows the viewer: S1 watched → the chip opens on season 2.
  const refs = kitsuEps.map((e) => ({ season: 1, episode: e.number, released: e.airdate }));
  A.episodeWatched.mark(null, { id: "kitsu:1", type: "anime", name: "Smoke Anime" }, null, { season: 1, episode: 3 }, "upTo", true, refs, "default", true);
  r.eq("animeDetail.seasons: with season 1 watched it opens on season 2", (await A.animeDetail.seasonsFor(input, "default", true, null, null)).seasonKey, "2");
  r.eq("animeDetail.seasons: a picked chip wins over the preferred one", (await A.animeDetail.seasonsFor(input, "default", true, "0", null)).seasonKey, "0");
  const shown = A.episodeWatched.state("kitsu:1", refs, null, "default", true, ["1:4"]);
  r.eq("episodeWatched.state scopes started / masks to the shown chip", [shown.watched.includes("1:1"), shown.started], [true, []]);
  A.episodeWatched.mark(null, { id: "kitsu:1", type: "anime", name: "Smoke Anime" }, null, { season: 1, episode: 4 }, "shown", true, [refs[3], refs[4]], "default", true);
  r.eq("episodeWatched.mark shown marks exactly the chip's episodes (markMany)", [...A.episodeWatched.state("kitsu:1", refs, null, "default", true).watched].sort(), ["1:1", "1:2", "1:3", "1:4", "1:99"]);
  A.episodeWatched.mark(null, { id: "kitsu:1", type: "anime", name: "Smoke Anime" }, null, { season: 1, episode: 4 }, "shown", false, [refs[3], refs[4]], "default", true);

  // The order toggle writes tvdbSeasonType (use-bp-anime-detail onOrderType); absolute joins the run.
  A.settings.patch({ tvdbSeasonType: "absolute" }, key);
  const abs = await A.animeDetail.seasonsFor(input, "default", true, "2", null);
  r.eq("animeDetail.seasons: absolute order is one All Episodes season plus Extras", abs.seasons.map((s) => [s.key, s.name, s.count]), [["1", "All Episodes", 5], ["specials", "Extras", 1]]);
  r.eq("animeDetail.seasons: a pick the new order lacks falls back, the toggle stays", [abs.orderType, abs.seasonKey, abs.orderTypes.length, abs.hasChips], ["absolute", "1", 3, true]);
  r.eq("animeDetail.seasons: absolute keeps the aired season:episode pairs apart", abs.groups[0].episodes.map((e) => e.imdbSeason + ":" + e.imdbEpisode), ["1:1", "1:2", "1:3", "2:1", "2:2"]);
  r.eq("animeDetail.seasons: the strip shows seasons when one chip spans several", abs.groups[0].showSeason, true);

  // tvdbOrderPanel off: buildAnimeOrder names the seasons without a toggle.
  A.settings.patch({ tvdbSeasonType: "aired", tvdbOrderPanel: false }, key);
  const ord = await A.animeDetail.seasonsFor(input, "default", true, null, null);
  r.eq("animeDetail.seasons: panel off → buildAnimeOrder seasons, Specials for the rest, no toggle", [ord.source, ord.seasons.map((s) => s.name), ord.orderTypes.length], ["order", ["Part One", "The Second Arc", "Specials"], 0]);
  A.settings.patch({ tvdbOrderPanel: true }, key);
  const none = await A.animeDetail.seasonsFor({ ...input, metaId: "kitsu:2", kitsuId: 2, canonicalId: "kitsu:2" }, "default", true, null, null);
  r.eq("animeDetail.seasons: no TVDB mapping → nothing, the page keeps its own grouping", [none.source, none.seasons.length, none.hasChips], ["none", 0, false]);
  r.eq("animeDetail.seasons before load → null", await A.animeDetail.seasons("kitsu:3", "default", true, null, null), null);
  // Review 31: a page that fell out of the 8-page cache reloads from its meta instead of answering null.
  const beforeReload = hits.length;
  r.eq("animeDetail.seasons: a cache miss with the page's meta runs load again (null when that fails too)",
    await A.animeDetail.seasons("kitsu:3", "default", true, null, null, { id: "kitsu:3", type: "anime", name: "Evicted" }), null);
  r.ok("animeDetail.seasons: the reload asked the Kitsu chain", hits.length > beforeReload && hits.slice(beforeReload).some((u) => /kitsu/i.test(u)), JSON.stringify(hits.slice(beforeReload, beforeReload + 6)));
  const beforeOther = hits.length;
  r.eq("animeDetail.seasons: a meta for another id doesn't reload", [await A.animeDetail.seasons("kitsu:4", "default", true, null, null, { id: "kitsu:5", type: "anime", name: "Other" }), hits.length - beforeOther], [null, 0]);
  r.ok("animeDetail.seasons asked only the TVDB proxy and ani.zip-style mappings", hits.some((u) => u.startsWith(`${TVDB}/series/100/episodes/default`)), JSON.stringify(hits.slice(0, 8)));
  await A.episodeWatched.settle();
  an.dispose();
}

// --------------------------------------- Home extra rows (use-bp-extra-rows.ts), fixtures only
{
  const pinBase = "https://pinned.example.invalid";
  const fixtureMetas = (prefix, n) => Array.from({ length: n }, (_, i) => ({ id: `${prefix}${i}`, type: "movie", name: `${prefix} ${i}`, poster: `https://img.example.invalid/${prefix}${i}.jpg` }));
  const rec = loadEngine({ storage: new Map([
    ["harbor.profiles.v1", JSON.stringify({ activeId: "default", profiles: [{ id: "default", isPrimary: true }] })],
    ["harbor.customlists.v1", JSON.stringify([
      { id: "L1", name: "Date night", createdAt: 1, updatedAt: 1, items: [{ id: "tt0000101", type: "movie", name: "One", addedAt: 1 }, { id: "tt0000102", type: "series", name: "Two", addedAt: 2 }] },
      { id: "L2", name: "Empty list", createdAt: 1, updatedAt: 1, items: [] },
    ])],
    ["harbor.collections.v1", JSON.stringify([
      { id: "C1", name: "Heists", createdAt: 1, updatedAt: 1, items: [{ id: "tt0000201", type: "movie", name: "Heat" }] },
      { id: "C2", name: "Nothing yet", createdAt: 1, updatedAt: 2, items: [] },
    ])],
    ["harbor.pagecollrows.v1", JSON.stringify({ home: ["C2", "C1"], movies: [], shows: [], anime: [] })],
    ["harbor.pinnedcatalogs.v1", JSON.stringify([
      { id: "pin1", source: "catalog", name: "Pinned Picks", params: { base: pinBase, type: "movie", id: "picks" } },
      { id: "pin2", source: "mal", name: "MAL watching", params: { railKey: "watching" } },
    ])],
    ["harbor.favorites.v1.default", JSON.stringify([{ id: "tt0000301", type: "movie", name: "Older fave", addedAt: 1 }, { id: "tt0000302", type: "series", name: "Newer fave", addedAt: 9 }])],
    ["harbor.localwatchlist.v1.default", JSON.stringify(["tt0000401"])],
  ]) });
  let pinDelay = 0;
  const hits = [];
  rec.node.host.fetch = async (req) => {
    hits.push(req.url);
    const json = (body) => ({ status: 200, statusText: "OK", headers: { "content-type": "application/json" }, url: req.url, body: JSON.stringify(body) });
    if (req.url.startsWith(`${pinBase}/catalog/movie/picks`)) {
      if (pinDelay) await new Promise((r) => setTimeout(r, pinDelay));
      return json({ metas: fixtureMetas(req.url.includes("skip=") ? "pinB" : "pinA", 20) });
    }
    if (req.url.startsWith("https://v3-cinemeta.strem.io/catalog/")) return json({ metas: fixtureMetas(`cm${hits.length}-`, 12) });
    return { status: 404, statusText: "Not Found", headers: {}, url: req.url, body: "" };
  };
  const E = rec.engine;
  const events = [];
  E.runtime.onEvent((type) => { if (type === "harbor:home-updated") events.push(type); });
  const base = E.settings.loadForProfile("default", true);
  const s = { ...base, hideContent: { ...base.hideContent, anime: true }, homeRows: { ...base.homeRows, listRows: ["L1", "L2", "L-missing"] } };
  E.settings.saveForProfile(s, "default", true);

  const plan = (over, env) => E.rooms.homeExtraPlan({ ...s, ...over }, { uiLang: "en", trakt: false, simkl: false, letterboxd: false, ...env });
  r.eq("home extras: hideContent.anime turns the anime rows off", plan({}, {}).anime, false);
  r.eq("home extras: anime rows run by default", plan({ hideContent: { ...s.hideContent, anime: false } }, {}).anime, true);
  r.eq("home extras: classic mode drops anime / Arabic / Russian rows", (() => { const p = plan({ homeMode: "classic", tmdbKey: "k", hideContent: { ...s.hideContent, anime: false } }, { uiLang: "ar" }); return [p.anime, p.arabic, p.russian]; })(), [false, false, false]);
  r.eq("home extras: Arabic rows need the ar UI language and a TMDB key", [plan({ tmdbKey: "k" }, { uiLang: "ar" }).arabic, plan({ tmdbKey: "" }, { uiLang: "ar" }).arabic, plan({ tmdbKey: "k" }, { uiLang: "ru" }).russian], [true, false, true]);
  r.eq("home extras: Trakt rails follow the connection", [plan({}, { trakt: true }).trakt, plan({}, {}).trakt], [true, false]);
  r.eq("home extras: Simkl rails need simklHomeRailsEnabled", [plan({ simklHomeRailsEnabled: false }, { simkl: true }).simkl, plan({ simklHomeRailsEnabled: true }, { simkl: true }).simkl, plan({ simklHomeRailsEnabled: true }, {}).simkl], [false, true, false]);

  const built = await r.timed("rooms.homeFor(extra rows, fixtures)", () => E.rooms.homeFor("default", true, null));
  const keys = built ? built.rows.map((x) => x.key) : [];
  const extraKeys = new Set(["list-L1", "collection-C1", "pinned:pin1", "harbor-favorites", "harbor-watchlist"]);
  const catalogKeys = keys.filter((k) => !extraKeys.has(k));
  r.ok("home extras: list, collection and pinned rows lead, Favorites and My Watchlist follow the catalog rows",
    keys[0] === "list-L1" && keys[1] === "collection-C1" && keys[2] === "pinned:pin1" && catalogKeys.length > 0 &&
    keys.indexOf(catalogKeys[catalogKeys.length - 1]) < keys.indexOf("harbor-favorites") && keys[keys.length - 1] === "harbor-watchlist" && keys[keys.length - 2] === "harbor-favorites",
    JSON.stringify(keys));
  r.ok("home extras: empty list / collection, a missing list and an unconnected MAL pin make no row", !keys.some((k) => k === "list-L2" || k === "list-L-missing" || k === "collection-C2" || k === "pinned:pin2"), JSON.stringify(keys));
  const row = (k) => built && built.rows.find((x) => x.key === k);
  r.eq("home extras: Favorites are newest first", row("harbor-favorites") && row("harbor-favorites").metas.map((m) => m.id), ["tt0000302", "tt0000301"]);
  r.eq("home extras: a bare-id watchlist entry becomes a movie tile", row("harbor-watchlist") && row("harbor-watchlist").metas.map((m) => [m.id, m.type]), [["tt0000401", "movie"]]);
  r.eq("home extras: list rows keep the list's items and name", row("list-L1") && [row("list-L1").name, row("list-L1").metas.map((m) => m.type)], ["Date night", ["movie", "series"]]);
  r.ok("home extras: the pinned catalog row is capped at 30 and pages through its addon", row("pinned:pin1") && row("pinned:pin1").metas.length === 20 && row("pinned:pin1").hasMore === true, JSON.stringify(row("pinned:pin1") && row("pinned:pin1").metas.length));
  const more = await E.rooms.page("home", "pinned:pin1", 2);
  r.ok("home extras: rooms.page pages a pinned row", Array.isArray(more) && more.length > 0 && more[0].id.startsWith("pinB"), JSON.stringify(more && more.slice(0, 2)));
  r.ok("home extras: anime rows were never asked for with anime hidden", !hits.some((u) => /jikan/i.test(u)), JSON.stringify(hits.filter((u) => /jikan/i.test(u)).slice(0, 2)));

  // Settings → Home rows over lib/home-customization.
  const st = E.rooms.homeRowsState("default", true);
  r.ok("homeRowsState lists every built row and the custom lists", st.rows.length === keys.length && st.rows[0].key === "list-L1" && st.lists.length === 2 && st.lists.find((l) => l.id === "L1").onHome && st.simkl.connected === false, JSON.stringify({ n: st.rows.length, lists: st.lists }));
  events.length = 0;
  E.rooms.homeRowToggleHidden("default", true, "harbor-watchlist");
  E.rooms.homeRowRename("default", true, "list-L1", "Tonight");
  const fi0 = st.rows.findIndex((x) => x.key === "harbor-favorites");
  let after = E.rooms.homeRowMove("default", true, "harbor-favorites", -1);
  r.ok("homeRowMove swaps with the row above", after.rows[fi0 - 1].key === "harbor-favorites" && after.rows[fi0].key === st.rows[fi0 - 1].key, JSON.stringify(after.rows.map((x) => x.key)));
  E.rooms.homeListRowToggle("default", true, "L2");
  const offL2 = E.settings.loadForProfile("default", true).homeRows.listRows;
  after = E.rooms.homeListRowToggle("default", true, "L2");
  r.eq("homeListRowToggle removes, then re-adds a list in homeRows.listRows", [offL2, E.settings.loadForProfile("default", true).homeRows.listRows, after.lists.find((l) => l.id === "L2").onHome], [["L1", "L-missing"], ["L1", "L-missing", "L2"], true]);
  await new Promise((res) => setTimeout(res, 400));
  r.ok("row edits raise harbor:home-updated", events.length >= 1, JSON.stringify(events));
  const edited = await E.rooms.homeFor("default", true, null);
  const ek = edited.rows.map((x) => x.key);
  r.ok("a hidden row leaves Home, a renamed row shows its new name", !ek.includes("harbor-watchlist") && edited.rows[0].name === "Tonight", JSON.stringify(edited.rows.slice(0, 2).map((x) => x.name)));
  r.ok("homeRowsState keeps the hidden row listed", E.rooms.homeRowsState("default", true).rows.some((x) => x.key === "harbor-watchlist" && x.hidden), "");
  E.rooms.homeRowsReset("default", true);
  r.eq("homeRowsReset clears homeRows", (() => { const h = E.settings.loadForProfile("default", true).homeRows; return [h.hidden, h.order, h.listRows]; })(), [[], [], []]);

  // A slow async row lands after the grace: Home is told to re-read.
  E.rooms.resetHomeExtras();
  E.settings.saveForProfile({ ...E.settings.loadForProfile("default", true), homeRows: { ...s.homeRows, listRows: [] } }, "default", true);
  pinDelay = 2500;
  events.length = 0;
  const early = await E.rooms.homeFor("default", true, null);
  r.ok("a slow pinned row is not waited for past the grace", !early.rows.some((x) => x.key === "pinned:pin1"), JSON.stringify(early.rows.map((x) => x.key).slice(0, 4)));
  await new Promise((res) => setTimeout(res, 2000));
  r.ok("its arrival raises harbor:home-updated", events.length >= 1, JSON.stringify(events));
  const late = await E.rooms.homeFor("default", true, null);
  r.ok("the next read has it in its upstream slot", late.rows[1] && late.rows[1].key === "pinned:pin1", JSON.stringify(late.rows.map((x) => x.key).slice(0, 4)));
  rec.dispose();
}

// ------------------------ Continue Watching advance (use-cw-advance.ts), fixtures only
{
  const now = Date.now();
  const past = new Date(now - 30 * 864e5).toISOString();
  const future = new Date(now + 3 * 864e5).toISOString();
  const recent = new Date(now - 3600e3).toISOString();
  const eps = (n, extra = []) => [...Array.from({ length: n }, (_, k) => ({ season: 1, episode: k + 1, released: past, name: `Ep ${k + 1}` })), ...extra];
  const metas = {
    tt9000001: eps(3), tt9000002: eps(3, [{ season: 1, episode: 4, released: future }]), tt9000003: eps(3), tt9000004: eps(2),
    tt9000005: eps(3), tt9000007: eps(3), tt9000008: eps(3), tt9000011: eps(3),
  };
  const local = (id, s, e, pos) => ({ id, type: "series", name: `Show ${id}`, season: s, episode: e, videoId: `${id}:${s}:${e}`, positionMs: pos, durationMs: 2800000, t: now - 60000 });
  const cwEngine = (localCw, slowId) => {
    const eng = loadEngine({ storage: new Map([
      ["harbor.profiles.v1", JSON.stringify({ activeId: "default", profiles: [{ id: "default", isPrimary: true }] })],
      ["harbor.manualwatched.v1.default", JSON.stringify(["tt9000007|1|2"])],
      ["harbor.localcw.v1.default", JSON.stringify(localCw)],
    ]) });
    eng.node.host.fetch = async (req) => {
      const m = req.url.match(/^https:\/\/v3-cinemeta\.strem\.io\/meta\/series\/(tt\d+)\.json$/);
      if (m && metas[m[1]]) {
        if (m[1] === slowId) await new Promise((res) => setTimeout(res, 2500));
        return { status: 200, statusText: "OK", headers: { "content-type": "application/json" }, url: req.url, body: JSON.stringify({ meta: { id: m[1], type: "series", name: m[1], videos: metas[m[1]] } }) };
      }
      return { status: 404, statusText: "Not Found", headers: {}, url: req.url, body: "" };
    };
    return eng;
  };
  const rec = cwEngine({ tt9000001: local("tt9000001", 1, 1, 2750000) }, null);
  const E = rec.engine;
  const item = (id, s, e, off, dur, flagged = 0) => ({ _id: id, type: "series", name: `Show ${id}`, state: { timeOffset: off, duration: dur, season: s, episode: e, video_id: `${id}:${s}:${e}`, flaggedWatched: flagged, lastWatched: recent }, removed: false, temp: false, _ctime: recent, _mtime: recent });
  const done = (id, s, e) => item(id, s, e, 2700000, 2800000);
  const cw = [done("tt9000001", 1, 1), done("tt9000002", 1, 3), item("tt9000003", 1, 2, 600000, 2800000), done("tt9000004", 1, 2), done("tt9000007", 1, 1), done("tt9000008", 1, 9)];
  const lib = [...cw, item("tt9000005", 1, 1, 0, 2800000, 1)];
  const byId = (out) => Object.fromEntries(out.items.map((i) => [i._id, i]));

  const a = await r.timed("cwAdvance.advance(fixtures)", () => E.cwAdvance.advance(cw, { library: lib }));
  const got = byId(a);
  r.eq("cw advance: a finished episode's card moves to the next aired one as Up Next", got.tt9000001 && [got.tt9000001.state.season, got.tt9000001.state.episode, got.tt9000001.state.video_id, got.tt9000001.state.timeOffset, got.tt9000001.upNext], [1, 2, "tt9000001:1:2", 0, true]);
  r.eq("cw advance: a manually watched next episode is skipped", got.tt9000007 && got.tt9000007.state.episode, 3);
  r.ok("cw advance: a caught-up show (next not aired) leaves the row by default", !got.tt9000002 && a.removed.includes("tt9000002"), JSON.stringify(a.removed));
  r.ok("cw advance: a show with no next episode leaves the row", !got.tt9000004, JSON.stringify(Object.keys(got)));
  r.ok("cw advance: an entry past its list's last episode (phantom) is dropped", !got.tt9000008, JSON.stringify(Object.keys(got)));
  r.ok("cw advance: a mid-episode card is untouched", got.tt9000003 && got.tt9000003.state.episode === 2 && got.tt9000003.state.timeOffset === 600000 && !got.tt9000003.upNext, JSON.stringify(got.tt9000003 && got.tt9000003.state));
  r.ok("cw advance: a recently finished library show resurfaces at its next episode, after the row", a.items[a.items.length - 1]._id === "tt9000005" && a.items[a.items.length - 1].state.episode === 2 && a.items[a.items.length - 1].upNext === true, JSON.stringify(a.items.map((i) => i._id)));

  const timer = await E.cwAdvance.advance(cw, { animeCwEnd: "timer" });
  const tb = byId(timer).tt9000002;
  r.ok("cw advance: animeCwEnd timer keeps a caught-up show with the next air date", tb && tb.waitingForAir === true && tb.nextAirDate === future && timer.soonestAir === Date.parse(future), JSON.stringify({ tb: tb && [tb.waitingForAir, tb.nextAirDate], soonest: timer.soonestAir }));
  const keep = await E.cwAdvance.advance(cw, { hideCaughtUp: false });
  r.ok("cw advance: cwHideCaughtUp off keeps a caught-up show as it was", byId(keep).tt9000002 && byId(keep).tt9000002.state.episode === 3 && !byId(keep).tt9000002.upNext && !byId(keep).tt9000004, JSON.stringify(Object.keys(byId(keep))));
  const off = await E.cwAdvance.advance(cw, { enabled: false, library: lib });
  r.eq("cw advance: cwAdvanceNext off returns the row unchanged", off.items.map((i) => `${i._id}:${i.state.episode}`), cw.map((i) => `${i._id}:${i.state.episode}`));

  // rooms.continueWatchingWithExtras runs the pass over the TV's own resume entries.
  const home = await r.timed("rooms.continueWatchingWithExtras(advance)", () => E.rooms.continueWatchingWithExtras("default", true, null));
  const h1 = home.find((i) => i._id === "tt9000001");
  r.ok("Home Continue Watching shows the next episode with the Up Next extra", h1 && h1.state.episode === 2 && h1._cw.upNext === true, JSON.stringify(h1 && { ep: h1.state.episode, cw: h1._cw }));
  r.eq("homeRowsState carries the Continue Watching settings (upstream defaults)", E.rooms.homeRowsState("default", true).cw, { advanceNext: true, hideCaughtUp: true, animeCwEnd: "hide" });
  const st = E.rooms.homeCwSetting("default", true, "advanceNext", false);
  E.rooms.homeCwSetting("default", true, "animeCwEnd", "timer");
  r.eq("homeCwSetting writes cwAdvanceNext / animeCwEnd", [st.cw.advanceNext, E.settings.loadForProfile("default", true).cwAdvanceNext, E.settings.loadForProfile("default", true).animeCwEnd], [false, false, "timer"]);
  const raw = await E.rooms.continueWatchingWithExtras("default", true, null);
  const r1 = raw.find((i) => i._id === "tt9000001");
  r.ok("with cwAdvanceNext off Home keeps the finished episode", r1 && r1.state.episode === 1 && r1._cw.upNext === false, JSON.stringify(r1 && r1.state));
  rec.dispose();

  // A slow episode list: the row comes back raw within the grace, then Home is told to re-read.
  const slow = cwEngine({ tt9000011: local("tt9000011", 1, 1, 2750000) }, "tt9000011");
  const events = [];
  slow.engine.runtime.onEvent((type) => { if (type === "harbor:home-updated") events.push(Date.now()); });
  const t0 = Date.now();
  const first = await slow.engine.rooms.continueWatchingWithExtras("default", true, null);
  const f1 = first.find((i) => i._id === "tt9000011");
  r.ok("a slow advance pass does not hold the row (it comes back raw after the grace)", f1 && f1.state.episode === 1, JSON.stringify({ ms: Date.now() - t0, ep: f1 && f1.state.episode }));
  await new Promise((res) => setTimeout(res, 2200));
  r.ok("its late answer raises harbor:home-updated", events.length >= 1, JSON.stringify(events.length));
  const second = await slow.engine.rooms.continueWatchingWithExtras("default", true, null);
  const s1 = second.find((i) => i._id === "tt9000011");
  r.ok("the re-read has the advanced card", s1 && s1.state.episode === 2 && s1._cw.upNext === true, JSON.stringify(s1 && s1.state));
  slow.dispose();
}

// ------------------- Anime Top Picks (lib/use-anime-top-picks.ts, use-bp-anime-hero.ts), fixtures
{
  const jikan = (mal_id, title, genres = []) => ({ mal_id, title, title_english: title, type: "TV", year: 2020, score: 8, images: { jpg: { image_url: `https://img.example.invalid/${mal_id}.jpg` } }, genres: genres.map((name) => ({ name })) });
  const list = (prefix, from, n, genres) => Array.from({ length: n }, (_, k) => jikan(from + k, `${prefix} ${k + 1}`, genres));
  const hits = [];
  const rec = loadEngine({ storage: new Map([
    ["harbor.profiles.v1", JSON.stringify({ activeId: "default", profiles: [{ id: "default", isPrimary: true }] })],
  ]) });
  rec.node.host.fetch = async (req) => {
    const json = (body) => ({ status: 200, statusText: "OK", headers: { "content-type": "application/json" }, url: req.url, body: JSON.stringify(body) });
    if (!req.url.startsWith("https://api.jikan.moe/v4/")) return { status: 404, statusText: "Not Found", headers: {}, url: req.url, body: "" };
    hits.push({ url: req.url, at: Date.now() });
    const u = req.url;
    if (u.includes("/anime/900/recommendations")) return json({ data: [{ entry: jikan(901, "Rec Pick"), votes: 40 }, { entry: jikan(902, "Seed Show"), votes: 30 }] });
    if (u.includes("q=Seed")) return json({ data: [{ mal_id: 900 }] });
    if (u.includes("filter=airing")) return json({ data: [jikan(5, "Hero Show"), jikan(6, "Seed Show"), ...list("Airing", 100, 20)] });
    if (u.includes("order_by=start_date")) return json({ data: list("Fresh", 200, 6) });
    if (u.includes("genres=22")) return json({ data: list("Romance", 300, 8, ["Romance"]) });
    if (u.includes("genres=14")) return json({ data: list("Mystery", 500, 8, ["Mystery"]) });
    if (u.includes("genres=1&") || u.includes("genres=1")) return json({ data: list("Action", 400, 8, ["Action"]) });
    return json({ data: [] });
  };
  const E = rec.engine;
  const input = (genres) => ({
    libItems: [],
    continueWatching: [{ _id: "kitsu:77", type: "series", name: "Seed Show", state: { timeOffset: 600000, duration: 1400000, season: 1, episode: 3 }, removed: false, temp: false, _ctime: "", _mtime: "" }],
    heroMetas: [{ id: "mal:5", type: "series", name: "Hero Show" }],
    favoriteGenres: genres,
  });
  const events = [];
  E.runtime.onEvent((type) => { if (type === "harbor:anime-updated") events.push(type); });
  r.eq("top picks: nothing cached on a first visit", E.animeRoom.topPicks(input([22]), {}).length, 0);
  await r.timed("animeRoom.topPicksSettled(fixtures)", () => E.animeRoom.topPicksSettled());
  const picks = E.animeRoom.topPicks(input([22]), {});
  const names = picks.map((m) => m.name);
  r.ok("top picks: a watch-history recommendation leads", names[0] === "Rec Pick", JSON.stringify(names.slice(0, 5)));
  r.ok("top picks: animeFavoriteGenres genre titles outrank new and airing ones", names.indexOf("Romance 1") > 0 && names.indexOf("Romance 1") < names.indexOf("Fresh 1") && names.indexOf("Fresh 1") < names.findIndex((n) => n.startsWith("Airing")), JSON.stringify(names));
  r.ok("top picks: the hero and Continue Watching franchises are left out, capped at 24", !names.includes("Hero Show") && !names.includes("Seed Show") && picks.length === 24, JSON.stringify({ n: picks.length }));
  r.ok("top picks: the favourite genre was asked of Jikan, sfw", hits.some((h) => h.url.includes("genres=22") && h.url.includes("sfw=true")), JSON.stringify(hits.map((h) => h.url).slice(0, 6)));
  const gaps = hits.slice(1).map((h, k) => h.at - hits[k].at);
  r.ok("top picks: Jikan requests go through the 400 ms queue", gaps.length >= 3 && Math.min(...gaps) >= 380, JSON.stringify(gaps));
  r.ok("top picks: an update event fired as picks landed", events.length >= 1, JSON.stringify(events.length));
  // The MAL-id / recs caches save on a 400 ms debounce after the last write (recs now land with the pages).
  await new Promise((res) => setTimeout(res, 500));
  const store = rec.node.storage;
  r.ok("top picks: picks, recs and the MAL id are cached", JSON.parse(store.get("harbor.anime.toppicks.cache.v2") ?? "[]").length === 24 && "900" in JSON.parse(store.get("harbor.anime.recs_by_mal.v1") ?? "{}") && Object.values(JSON.parse(store.get("harbor.anime.mal_id_by_franchise.v1") ?? "{}")).includes(900), JSON.stringify([...store.keys()].filter((k) => k.startsWith("harbor.anime."))));
  const before = hits.length;
  E.animeRoom.topPicks(input([22]), {});
  await E.animeRoom.topPicksSettled();
  r.eq("top picks: the same inputs do not rebuild", hits.length, before);
  E.animeRoom.topPicks(input([22, 1]), {});
  await E.animeRoom.topPicksSettled();
  r.ok("top picks: a new favourite genre rebuilds with it", hits.slice(before).some((h) => h.url.includes("genres=1&") || /genres=1(&|$)/.test(h.url)) && !hits.slice(before).some((h) => h.url.includes("recommendations")), JSON.stringify(hits.slice(before).map((h) => h.url)));
  // Review 32: the TV writes genres per toggle, so a genre-only change waits ~1 s after the last one.
  const beforeToggles = hits.length;
  E.animeRoom.topPicks(input([10]), {});
  E.animeRoom.topPicks(input([14]), {});
  await new Promise((res) => setTimeout(res, 400));
  r.eq("top picks: genre toggles don't rebuild until ~1 s after the last change", hits.length, beforeToggles);
  await E.animeRoom.topPicksSettled();
  const toggled = hits.slice(beforeToggles).map((h) => h.url);
  r.ok("top picks: one debounced rebuild with the final genres only", toggled.some((u) => /genres=14(&|$)/.test(u)) && !toggled.some((u) => /genres=10(&|$)/.test(u)), JSON.stringify(toggled));

  // Settings: the Tune anime picker (favourite genres, origins, hide watched).
  const tune = E.actions.animeTune("default", true);
  r.ok("animeTune lists the 16 genres and 3 origins at upstream defaults (CN hidden, watched hidden)", tune.genres.length === 16 && tune.origins.length === 3 && tune.genres.every((g) => !g.on) && tune.origins.find((o) => o.code === "CN").on && tune.hideWatched === true, JSON.stringify(tune));
  const t1 = E.actions.animeTuneGenre("default", true, 22);
  const s1 = E.settings.loadForProfile("default", true);
  r.ok("animeTuneGenre writes animeFavoriteGenres and stamps animePicksDismissedAt", t1.genres.find((g) => g.id === 22).on && s1.animeFavoriteGenres.join(",") === "22" && s1.animePicksDismissedAt > 0, JSON.stringify(s1.animeFavoriteGenres));
  E.actions.animeTuneGenre("default", true, 22);
  E.actions.animeTuneOrigin("default", true, "CN");
  E.actions.animeTuneHideWatched("default", true, false);
  const s2 = E.settings.loadForProfile("default", true);
  r.eq("animeTune toggles a genre off again, CN back in, hide-watched off", [s2.animeFavoriteGenres, s2.animeExcludeOrigins, s2.animeHideWatchedPicks], [[], [], false]);
  // Review 32: "Hide anime I've already watched" reads the Simkl / AniList maps (use-bp-anime-watched).
  const isW = E.animeRoom.watchedFrom({
    simklWatched: new Map([["kitsu:1", new Set(["1:1"])], ["kitsu:2", new Set()]]),
    simklStatus: new Map([["mal:3", "completed"], ["mal:4", "watching"]]),
    anilistWatched: new Map([["anilist:5", new Set(["1:1", "1:2"])]]),
  });
  r.eq("animeRoom watched filter: Simkl episodes, Simkl completed, AniList progress count; empty sets and watching don't",
    ["kitsu:1", "kitsu:2", "mal:3", "mal:4", "anilist:5", "kitsu:9"].map(isW), [true, false, true, false, true, false]);
  r.eq("animeRoom watched filter: missing maps read as nothing watched", E.animeRoom.watchedFrom({})("kitsu:1"), false);
  // Bug pass: late hero / picks ids are per profile and LRU-evicted at the cap (not frozen).
  E.animeRoom.lateIds("pA", ["kitsu:1", "mal:2", "tt123", "anilist:3"], 3);
  r.eq("animeRoom late ids: anime ids only, per profile", [E.animeRoom.lateIds("pA", [], 3), E.animeRoom.lateIds("pB", [], 3)], [["kitsu:1", "mal:2", "anilist:3"], []]);
  E.animeRoom.lateIds("pA", ["kitsu:1"], 3); // touch: kitsu:1 becomes newest
  r.eq("animeRoom late ids: the oldest id is evicted at the cap, a re-seen id is kept", E.animeRoom.lateIds("pA", ["kitsu:4"], 3), ["anilist:3", "kitsu:1", "kitsu:4"]);
  rec.dispose();

  // A later session: the cached picks show at once as the room's first row.
  const again = loadEngine({ storage: new Map([
    ["harbor.profiles.v1", JSON.stringify({ activeId: "default", profiles: [{ id: "default", isPrimary: true }] })],
    ["harbor.anime.toppicks.cache.v2", store.get("harbor.anime.toppicks.cache.v2")],
  ]) });
  again.node.host.fetch = async (req) => ({ status: 404, statusText: "Not Found", headers: {}, url: req.url, body: "" });
  const pg = await again.engine.animeRoom.page("default", true, null);
  r.ok("animeRoom.page: cached Top Picks for You lead the rows at once", pg.rows[0] && pg.rows[0].key === "anime-top-picks" && pg.rows[0].name === "Top Picks for You" && pg.rows[0].metas.length === 24 && pg.picks.length === 24, JSON.stringify(pg.rows.slice(0, 2).map((x) => [x.key, x.name, x.metas.length])));
  again.dispose();
}

// --------------------------- X-Ray while paused (components/player/xray, use-xray-cast.ts), fixtures
{
  const TMDB = "https://api.themoviedb.org/3";
  const TVDB = "https://harbor.site/api/tvdb/v4";
  const hits = [];
  const rec = loadEngine({ storage: new Map([
    ["harbor.profiles.v1", JSON.stringify({ activeId: "default", profiles: [{ id: "default", isPrimary: true }] })],
  ]) });
  rec.node.host.fetch = async (req) => {
    hits.push(req.url);
    const json = (body) => ({ status: 200, statusText: "OK", headers: { "content-type": "application/json" }, url: req.url, body: JSON.stringify(body) });
    const u = req.url;
    if (u.startsWith(`${TMDB}/movie/603?`)) return json({
      id: 603, title: "The Matrix", original_title: "The Matrix", original_language: "en", overview: "A hacker learns the truth.", tagline: "Welcome to the Real World.",
      release_date: "1999-03-31", runtime: 136, vote_average: 8.2, vote_count: 26543, status: "Released", genres: [{ id: 28, name: "Action" }],
      backdrop_path: "/bd.jpg", poster_path: "/p.jpg", spoken_languages: [{ iso_639_1: "en", english_name: "English", name: "English" }],
      production_countries: [{ iso_3166_1: "US", name: "United States of America" }], production_companies: [{ id: 1, name: "Village Roadshow" }],
      external_ids: { imdb_id: "tt0133093" },
      images: { logos: [{ file_path: "/logo.png", iso_639_1: "en", vote_average: 5 }], backdrops: [{ file_path: "/b1.jpg", vote_average: 5 }, { file_path: "/b2.jpg", vote_average: 4 }], posters: [] },
      videos: { results: [{ key: "vKQi3bBA1y8", site: "YouTube", type: "Trailer", official: true, name: "Official Trailer" }, { key: "extra123", site: "YouTube", type: "Behind the Scenes", name: "Making Of" }] },
      credits: {
        cast: [
          { id: 6384, name: "Keanu Reeves", character: "Neo", profile_path: "/keanu.jpg", order: 0 },
          { id: 2975, name: "Laurence Fishburne", character: "Morpheus", profile_path: null, order: 1 },
          { id: 6384, name: "Keanu Reeves", character: "Neo", profile_path: "/keanu.jpg", order: 2 },
        ],
        crew: [
          { id: 9340, name: "Lana Wachowski", job: "Director", department: "Directing", profile_path: "/lana.jpg" },
          { id: 9340, name: "Lana Wachowski", job: "Writer", department: "Writing", profile_path: null },
          { id: 9339, name: "Lilly Wachowski", job: "Director", department: "Directing", profile_path: null },
          { id: 5, name: "Don Davis", job: "Original Music Composer", department: "Sound", profile_path: null },
          { id: 6, name: "Grip Person", job: "Key Grip", department: "Crew", profile_path: null },
        ],
      },
    });
    if (u.startsWith(`${TVDB}/search/remoteid/tt9100001`)) return json({ data: [{ series: { id: 777 } }] });
    if (u.startsWith(`${TVDB}/series/777/extended`)) return json({ data: { characters: [
      { name: "Captain", personName: "Ann Actor", peopleId: 42, peopleType: "Actor", personImgURL: "/person/42.jpg", sort: 2 },
      { name: "Pilot", personName: "Bob Player", peopleId: 43, peopleType: "Actor", image: "https://artworks.thetvdb.com/c/43.jpg", sort: 1 },
      { name: "", personName: "Dee Director", peopleId: 44, peopleType: "Director", sort: 0 },
    ] } });
    return { status: 404, statusText: "Not Found", headers: {}, url: u, body: "" };
  };
  const E = rec.engine;
  r.eq("xray.enabled: off by default (settings.xrayEnabled)", E.xray.enabled("default", true), false);
  const pb = () => E.settingsRoom.controls("playback", "default", true);
  const row = pb().find((c) => c.id === "xray");
  r.ok("settingsRoom.controls(playback): the TV's X-Ray row follows Instant play, Off", row && row.kind === "options" && row.value === "off" && row.label === "X-Ray" && pb().findIndex((c) => c.id === "xray") === pb().findIndex((c) => c.id === "instantPlay") + 1, JSON.stringify(pb().map((c) => c.id)));
  r.eq("settingsRoom.controls: X-Ray is a Playback row only", E.settingsRoom.controls("interface", "default", true).some((c) => c.id === "xray"), false);
  r.eq("settingsRoom.commit xray on writes settings.xrayEnabled", [E.settingsRoom.commit("xray", "on", "default", true).ok, E.xray.enabled("default", true), E.settings.loadForProfile("default", true).xrayEnabled], [true, true, true]);
  r.ok("settingsRoom.pane(playback) reports X-Ray", E.settingsRoom.pane("default", true).playback.some(([k, v]) => k === "X-Ray" && v === "On"));

  // No TMDB key: use-xray-cast still asks TVDB (no key needed), sorted by TVDB's sort, actors only.
  const series = { id: "tt9100001", type: "series", name: "Fixture Show", description: "A crew in space." };
  const noKey = await r.timed("xray.load(no key, TVDB fixtures)", () => E.xray.load(series, "default", true));
  r.eq("xray.load without a key: rail from TVDB actors in sort order, negative ids", noKey.rail.map((p) => [p.id, p.name, p.sub]), [[-43, "Bob Player", "Pilot"], [-42, "Ann Actor", "Captain"]]);
  r.eq("xray.load: TVDB photos become artworks URLs", noKey.rail.map((p) => p.photo), ["https://artworks.thetvdb.com/c/43.jpg", "https://artworks.thetvdb.com/person/42.jpg"]);
  r.ok("xray.load without a key: no details, no TMDB call, the browser's key note, About from the meta", noKey.needsTmdbKey && !noKey.hasDetails && noKey.cast.length === 0 && noKey.crew.length === 0 && noKey.about?.overview === "A crew in space." && noKey.tabs.map((x) => x.id).join() === "about" && noKey.empty.details === "Add a TMDB key in Settings to see the cast, crew, and details." && !hits.some((h) => h.startsWith(TMDB)), JSON.stringify(noKey));
  r.eq("xray.load: the rail needs no status line when it has people", noKey.railStatus, null);

  // With a key: TMDB details (cast, crew, about).
  E.settings.saveForProfile({ ...E.settings.loadForProfile("default", true), tmdbKey: "0123456789abcdef0123456789abcdef" }, "default", true);
  const movie = { id: "tmdb:movie:603", type: "movie", name: "The Matrix" };
  const x = await r.timed("xray.load(TMDB fixture)", () => E.xray.load(movie, "default", true));
  r.eq("xray.load: cast cards (w185 photo, character, initials) deduped by id:character", x.cast.map((p) => [p.id, p.name, p.sub, p.photo, p.initials]), [[6384, "Keanu Reeves", "Neo", "https://image.tmdb.org/t/p/w185/keanu.jpg", "KR"], [2975, "Laurence Fishburne", "Morpheus", null, "LF"]]);
  r.eq("xray.load: the rail is TMDB's cast when there is one", x.rail.map((p) => p.id), [6384, 2975]);
  r.eq("xray.load: crew by CREW_PRIORITY with jobs merged per person, unlisted jobs left out", x.crew.map((p) => [p.name, p.sub]), [["Lana Wachowski", "Director, Writer"], ["Lilly Wachowski", "Director"], ["Don Davis", "Original Music Composer"]]);
  r.eq("xray.load: tabs Cast / Crew / About, opening on Cast", [x.tabs.map((t) => t.id), x.initialTab], [["cast", "crew", "about"], "cast"]);
  const a = x.about;
  r.ok("xray.load about: title, tagline, rating + votes, year, runtime, status, genres", a.title === "The Matrix" && a.tagline === "Welcome to the Real World." && a.rating === "8.2" && a.votes === "27K" && a.year === "1999" && a.runtime === "136 min" && a.status === "Released" && a.genres.join() === "Action", JSON.stringify(a));
  r.eq("xray.load about: facts (Director, Writers, Network, Language, Country)", a.facts.map((f) => f.label), ["Director", "Writers", "Network", "Language", "Country"]);
  r.ok("xray.load about: lead trailer then extras; the backdrop leads the stills", a.videos.map((v) => v.ytId).join() === "vKQi3bBA1y8,extra123" && a.videos[0].name === "The Matrix trailer" && a.videos[0].thumb === "https://img.youtube.com/vi/vKQi3bBA1y8/mqdefault.jpg" && a.hero.endsWith("/bd.jpg") && a.strip[0] === a.hero && a.showStrip, JSON.stringify({ v: a.videos, hero: a.hero, strip: a.strip }));
  const before = hits.length;
  await E.xray.load(movie, "default", true);
  r.eq("xray.load: a second pause is served from the cache", hits.length, before);
  r.eq("xray.fmtVotes / initials follow xray-about / xray-actor-card", [E.xray.fmtVotes(1_250_000), E.xray.fmtVotes(1_000_000), E.xray.fmtVotes(999), E.xray.initials("  Cher "), E.xray.initials("")], ["1.3M", "1M", "999", "C", "?"]);
  const none = E.xray.assemble({ id: "x", type: "movie", name: "Nothing" }, null, [], true);
  r.eq("xray.assemble: nothing found says so on the rail and has no tabs", [none.railStatus, none.tabs.length, none.initialTab], ["No cast information for this title.", 0, null]);
  rec.dispose();
}

// ---------------------------- Harbor Voyages (lib/voyage/*, components/voyage/*), fixtures only
{
  const CM = "https://v3-cinemeta.strem.io";
  const hits = [];
  const vy = loadEngine({ storage: new Map([
    ["harbor.profiles.v1", JSON.stringify({ activeId: "default", profiles: [{ id: "default", isPrimary: true }] })],
    // A film already watched never enters a voyage (store.ts buildExclude).
    ["harbor.moviewatched.v1.default", JSON.stringify(["tt9000002"])],
  ]) });
  const film = (id, genre, extra = {}) => ({ id, type: "movie", name: `Film ${id}`, poster: `https://img.example.invalid/${id}.jpg`, background: `https://img.example.invalid/${id}-bg.jpg`, genres: genre ? [genre] : ["Drama"], runtime: "2h", releaseInfo: "2001", ...extra });
  const top = (genre, from, n) => Array.from({ length: n }, (_, k) => film(`tt${from + k}`, genre));
  let catalogDown = false;
  vy.node.host.fetch = async (req) => {
    const json = (body) => ({ status: 200, statusText: "OK", headers: { "content-type": "application/json" }, url: req.url, body: JSON.stringify(body) });
    const miss = { status: 404, statusText: "Not Found", headers: {}, url: req.url, body: "" };
    const u = req.url;
    hits.push(u);
    if (u.startsWith(`${CM}/meta/movie/`)) return catalogDown ? miss : json({ meta: film(u.split("/").pop().replace(".json", ""), "Crime") });
    if (u.startsWith(`${CM}/catalog/movie/top/genre=Crime.json`)) return catalogDown ? miss : json({ metas: [...top("Crime", 9000001, 10), film("tt9000099", "Comedy"), { id: "tt9000098", type: "movie", name: "No poster" }] });
    if (u.startsWith(`${CM}/catalog/movie/top.json`)) return json({ metas: top("Drama", 9100001, 12) });
    if (u.startsWith("https://api.themoviedb.org/3/find/")) {
      const n = Number(u.match(/find\/tt(\d+)/)[1]);
      return json({ movie_results: [{ id: n }], tv_results: [] });
    }
    const credits = { cast: [{ id: 1, name: "Lead Actor", profile_path: "/lead.jpg", order: 0 }, { id: 2, name: "Second Actor", profile_path: null, order: 1 }], crew: [{ id: 3, name: "The Director", job: "Director", department: "Directing" }] };
    if (/\/3\/movie\/\d+\/credits/.test(u)) return json(credits);
    if (/\/3\/movie\/\d+\?/.test(u)) {
      const recs = Array.from({ length: 4 }, (_, k) => ({ id: 700 + k, title: `Rec ${k}`, poster_path: `/rec${k}.jpg`, backdrop_path: `/recbg${k}.jpg`, release_date: "2010-01-01" }));
      return json({ id: 1, title: "x", credits, recommendations: { results: recs }, similar: { results: [] } });
    }
    return miss;
  };
  const E = vy.engine;
  E.settings.patch({ tmdbKey: "0123456789abcdef0123456789abcdef" }, E.settings.sourceKeyFor("default", true));
  const V = E.voyageRoom;
  const stored = () => JSON.parse(vy.node.storage.get("harbor.voyage.v1") ?? "null");

  const themes = V.themes();
  r.ok("voyage: the six upstream themes with their palette", themes.length === 6 && themes[0].id === "heist" && themes[0].genre === "Crime" && themes[0].from.startsWith("oklch(") && themes.find((t) => t.id === "uncharted").genre === null, JSON.stringify(themes.map((t) => [t.id, t.genre])));
  r.eq("voyage: no voyage and no streak on a first visit", V.state(), { active: null, streak: 0 });

  const started = await r.timed("voyageRoom.start(heist, 3, fixtures)", () => V.start("default", true, "heist", 3));
  const a0 = started.state.active;
  r.ok("voyage.start charts a building voyage with three headings and a streak of one", started.ok && a0.phase === "building" && a0.targetLength === 3 && a0.headings.length === 3 && a0.slots.length === 3 && a0.picked === 0 && started.state.streak === 1, JSON.stringify({ ok: started.ok, phase: a0 && a0.phase, h: a0 && a0.headings.length }));
  const pool = stored().active.pool.map((m) => m.id);
  r.ok("voyage.start pool: curated seeds and the genre's top titles, watched and posterless ones left out", pool.includes("tt0240772") && pool.includes("tt9000001") && !pool.includes("tt9000002") && !pool.includes("tt9000098") && pool.length <= 40, JSON.stringify(pool.slice(0, 8)));
  r.ok("voyage.start: headings come from the pool and the voyage persists under harbor.voyage.v1", a0.headings.every((m) => pool.includes(m.id)) && stored().active.headingIds.length === 3 && stored().streak === 1);

  const first = a0.headings[0].id;
  const s1 = V.choose("default", true, first);
  r.ok("voyage.choose adds the pick to the route and offers three new headings", s1.active.picked === 1 && s1.active.slots[0].meta.id === first && s1.active.headings.length === 3 && !s1.active.headings.some((m) => m.id === first), JSON.stringify(s1.active.headings.map((m) => m.id)));
  const s1b = await V.settle("default", true, first);
  r.ok("voyage.settle: TMDB titles off the genre never join a genre theme's pool", s1b.active.picked === 1 && !stored().active.pool.some((m) => m.id.startsWith("tmdb:")), JSON.stringify(stored().active.enrichedPicks));
  const u1 = V.undo("default", true);
  r.ok("voyage.undo drops the last pick", u1.active.picked === 0 && u1.active.slots.every((s) => s.meta === null));
  const before = new Set(u1.active.headings.map((m) => m.id));
  const rr = V.reroll("default", true);
  r.ok("voyage.reroll shows three others", rr.active.headings.length === 3 && rr.active.headings.every((m) => !before.has(m.id)), JSON.stringify([...before, "|", ...rr.active.headings.map((m) => m.id)]));

  let s = rr;
  for (let i = 0; i < 3; i++) s = V.choose("default", true, s.active.headings[0].id);
  r.ok("voyage: a full route is ready, with no headings left", s.active.ready && !s.active.stuck && s.active.headings.length === 0 && s.active.picked === 3 && s.active.current === 3, JSON.stringify({ ready: s.active.ready, picked: s.active.picked }));
  const route = stored().active.routeIds;
  const launched = V.launch();
  r.ok("voyage.launch sails and hands back the first film", launched.first.id === route[0] && launched.state.active.phase === "sailing" && launched.state.active.next.id === route[0] && launched.state.active.nextPosition === 1);

  // progress.ts: 90 % of the runtime counts as watched; a started film is next before an untouched one.
  vy.run(`localStorage.setItem("harbor.resume", ${JSON.stringify(JSON.stringify({ [route[0]]: { ms: 6900000, t: 1, pct: 0.96 }, [route[2]]: { ms: 1200000, t: 2, pct: 0.2 } }))})`);
  const sp = V.state().active;
  r.ok("voyage.state: the watched film is done and the started one is up next", sp.slots[0].done && sp.watched === 1 && sp.next.id === route[2] && sp.nextPosition === 3 && Math.abs(sp.slots[2].progress - 0.2) < 1e-9 && sp.current === 1, JSON.stringify(sp.slots.map((x) => [x.done, x.progress, x.current])));
  vy.run(`localStorage.setItem("harbor.resume", ${JSON.stringify(JSON.stringify(Object.fromEntries(route.map((id) => [id, { ms: 7000000, t: 1, pct: 0.99 }]))))})`);
  const done = V.state().active;
  r.ok("voyage.state: every film watched completes the voyage", done.next === null && done.watched === 3 && done.current === -1, JSON.stringify({ next: done.next, watched: done.watched }));
  r.eq("voyage.end clears the voyage and keeps the streak", V.end(), { active: null, streak: 1 });

  // store.ts mergeRelated: a theme without a genre takes the pick's TMDB recommendations in.
  const wild = await V.start("default", true, "uncharted", 5);
  const pick = wild.state.active.headings[0].id;
  V.choose("default", true, pick);
  const settled = await r.timed("voyageRoom.settle(uncharted pick, fixtures)", () => V.settle("default", true, pick));
  const st = stored().active;
  r.ok("voyage.settle: the pick's recommendations join the pool and are voted up", st.pool.some((m) => m.id === "tmdb:movie:700") && st.recVotes["tmdb:movie:700"] === 1 && st.enrichedPicks.includes(pick) && settled.active.headings.length === 3, JSON.stringify({ n: st.pool.length, votes: st.recVotes, enriched: st.enrichedPicks }));
  r.ok("voyage.settle: voted recommendations lead the next headings", settled.active.headings.filter((m) => m.id.startsWith("tmdb:movie:7")).length >= 2, JSON.stringify(settled.active.headings.map((m) => m.id)));
  r.ok("voyage: the banner strip reads the active pool's backdrops", settled.active.bannerItems.length === 8 && settled.active.bannerItems.every((m) => m.background && m.background !== m.poster));
  V.end();

  catalogDown = true;
  const failed = await V.start("default", true, "edge", 5);
  r.ok("voyage.start: a pool under four titles does not chart", failed.ok === false && failed.state.active === null, JSON.stringify(failed));
  catalogDown = false;

  const cr = await r.timed("voyageRoom.credits(fixtures)", () => V.credits("default", true, "tt9000001", "movie"));
  r.ok("voyage.credits: the director and cast faces for the focused heading", cr && cr.director === "The Director" && cr.cast[0].name === "Lead Actor" && cr.cast[0].profile === "https://image.tmdb.org/t/p/w185/lead.jpg" && cr.cast[1].profile === null, JSON.stringify(cr));
  r.eq("voyage.credits: nothing for a non-IMDb id", await V.credits("default", true, "tmdb:movie:700", "movie"), null);
  const rails = [{ key: "a", name: "A", metas: [film("tt11"), { ...film("tt12"), poster: undefined }, { ...film("tt13"), background: film("tt13").poster }] }, { key: "b", name: "B", metas: [film("tt11"), ...top("Drama", 20, 9)] }];
  const vp = E.discoverRoom.voyagePool(rails).map((m) => m.id);
  r.ok("discoverRoom.voyagePool: each rail title once, with a poster and its own backdrop, eight at most", vp.length === 8 && vp[0] === "tt11" && !vp.includes("tt12") && !vp.includes("tt13") && new Set(vp).size === 8, JSON.stringify(vp));
  r.eq("voyage.bannerItems: backdrops that are not the poster, eight at most", V.bannerItems([film("tt1"), { ...film("tt2"), background: "https://img.example.invalid/tt2.jpg", poster: "https://img.example.invalid/tt2.jpg" }, { ...film("tt3"), background: undefined }]).map((m) => m.id), ["tt1"]);

  // store.ts adopt(): a pre-phase voyage with a route reads as sailing, all of it played.
  const legacy = loadEngine({ storage: new Map([
    ["harbor.profiles.v1", JSON.stringify({ activeId: "default", profiles: [{ id: "default", isPrimary: true }] })],
    ["harbor.voyage.v1", JSON.stringify({ active: { id: "v-1", themeId: "heist", themeLabel: "The Heist Line", tagline: "t", accent: "oklch(0.72 0.13 45)", createdAt: 1, targetLength: 5, pool: [film("tt1"), film("tt2")], routeIds: ["tt1", "tt2"], headingIds: [], seen: [] }, streak: 4, lastSail: "2000-1-1" })],
  ]) });
  const la = legacy.engine.voyageRoom.state();
  r.ok("voyage.state adopts a stored voyage from before phases", la.streak === 4 && la.active.phase === "sailing" && la.active.targetLength === 2 && la.active.played === 2 && la.active.slots.length === 2, JSON.stringify(la.active && { phase: la.active.phase, len: la.active.targetLength }));
  legacy.dispose();
  vy.dispose();
}

// ------------------------------------------------ music (Stage 12): sources, rows, matching, library
{
  const jf = "http://jf.example.invalid";
  const rec = loadEngine({ storage: new Map([
    ["harbor.profiles.v1", JSON.stringify({ activeId: "default", profiles: [{ id: "default", isPrimary: true }] })],
    // Jellyfin adopts the home-server connection the video side saved (added mid-test below).
  ]) });
  const hits = [];
  let jellyfinOn = false;
  const json = (req, body, status = 200) => ({ status, statusText: "OK", headers: { "content-type": "application/json" }, url: req.url, body: typeof body === "string" ? body : JSON.stringify(body) });
  const chartTrack = { id: 3135556, title: "Harder, Better, Faster, Stronger", duration: 224, explicit_lyrics: false, artist: { id: 27, name: "Daft Punk" }, album: { title: "Discovery", cover_big: "https://cdn.example.invalid/discovery.jpg" } };
  const scTrack = (id, title, user, ms) => ({ id, title, duration: ms, full_duration: ms, policy: "ALLOW", streamable: true, user: { id: 9, username: user, avatar_url: "https://i1.sndcdn.com/avatars-large.jpg" }, artwork_url: "https://i1.sndcdn.com/art-large.jpg",
    media: { transcodings: [
      { url: `https://api-v2.soundcloud.com/media/${id}/opus/stream/hls`, preset: "opus_0_0", format: { protocol: "hls", mime_type: "audio/ogg; codecs=\"opus\"" } },
      { url: `https://api-v2.soundcloud.com/media/${id}/aac/stream/hls`, preset: "aac_160k", format: { protocol: "hls", mime_type: "audio/mp4; codecs=\"mp4a.40.2\"" } },
    ] }, track_authorization: "auth-token" });
  rec.node.host.fetch = async (req) => {
    hits.push(`${req.method} ${req.url}`);
    const u = new URL(req.url);
    if (u.host === "api.deezer.com") {
      if (u.pathname === "/chart/0/tracks") return json(req, { data: [chartTrack] });
      if (u.pathname === "/chart/0/albums") return json(req, { data: [{ id: 302127, title: "Discovery", cover_big: "https://cdn.example.invalid/discovery.jpg", release_date: "2001-03-07", nb_tracks: 14, artist: { id: 27, name: "Daft Punk" } }] });
      if (u.pathname === "/chart/0/artists") return json(req, { data: [{ id: 27, name: "Daft Punk", picture_big: "https://cdn.example.invalid/dp.jpg", position: 1 }] });
      if (u.pathname === "/editorial/0/selection") return json(req, { error: { code: 800, message: "no data" } });
      if (u.pathname === "/search/artist") return json(req, { data: [{ id: 27, name: "Daft Punk" }] });
      if (u.pathname === "/artist/27/top") return json(req, { data: [chartTrack] });
      if (u.pathname === "/artist/27/albums") return json(req, { data: [{ id: 302127, title: "Discovery", cover_big: "x", release_date: "2001-03-07" }] });
      if (u.pathname === "/artist/27/related") return json(req, { data: [{ id: 28, name: "Justice" }] });
    }
    if (u.host === "itunes.apple.com") return json(req, { results: [
      { kind: "song", trackId: 11, trackName: "One More Time", artistName: "Daft Punk", collectionName: "Discovery", trackTimeMillis: 320000, artworkUrl100: "https://is1.example.invalid/100x100bb.jpg" },
      { collectionId: 22, collectionName: "Homework", artistName: "Daft Punk", releaseDate: "1997-01-20T08:00:00Z", trackCount: 16 },
    ] });
    if (u.host === "soundcloud.com") return { status: 200, statusText: "OK", headers: { "content-type": "text/html" }, url: req.url, body: '<script src="https://a-v2.sndcdn.com/assets/0-abc.js"></script><script src="https://a-v2.sndcdn.com/assets/49-def.js"></script>' };
    if (u.host === "a-v2.sndcdn.com") return { status: 200, statusText: "OK", headers: {}, url: req.url, body: u.pathname.includes("49-def") ? 'x={client_id:"ABCDEFGHIJKLMNOPQRSTUVWXYZ012345",y:1}' : "nothing here" };
    if (u.host === "api-v2.soundcloud.com") {
      if (u.searchParams.get("client_id") !== "ABCDEFGHIJKLMNOPQRSTUVWXYZ012345") return json(req, {}, 401);
      if (u.pathname === "/search/tracks") return json(req, { collection: [scTrack(1, "Harder Better Faster Stronger (cover)", "Some Band", 200000), scTrack(2, "Harder, Better, Faster, Stronger", "Daft Punk", 226000)] });
      if (u.pathname === "/search/users" || u.pathname === "/search/playlists") return json(req, { collection: [] });
      if (u.pathname === "/tracks") return json(req, [scTrack(Number(u.searchParams.get("ids")), "Harder, Better, Faster, Stronger", "Daft Punk", 226000)]);
      if (u.pathname === "/media/2/aac/stream/hls") return json(req, { url: u.searchParams.get("track_authorization") === "auth-token" ? "https://playback.media-streaming.soundcloud.cloud/x/aac_160k/playlist.m3u8?sig=1" : "https://evil.example.invalid/x.m3u8" });
      if (u.pathname === "/mixed-selections") return json(req, { collection: [] });
    }
    if (jellyfinOn && u.origin === jf) {
      if (u.pathname === "/UserViews") return json(req, { Items: [{ Id: "lib1", Name: "Music", CollectionType: "music" }] });
      if (u.pathname === "/Items" && u.searchParams.get("includeItemTypes") === "MusicAlbum" && !u.searchParams.get("searchTerm")) return json(req, { Items: [{ Id: "alb1", Name: "Random Access Memories", Type: "MusicAlbum", AlbumArtist: "Daft Punk", ProductionYear: 2013, ChildCount: 13, ImageTags: { Primary: "t1" } }] });
      if (u.pathname === "/Items" && u.searchParams.get("parentId") === "alb1") return json(req, { Items: [{ Id: "trk1", Name: "Give Life Back to Music", Type: "Audio", Artists: ["Daft Punk"], Album: "Random Access Memories", AlbumId: "alb1", AlbumPrimaryImageTag: "t1", RunTimeTicks: 2750000000 }] });
      if (u.pathname === "/Items") return json(req, { Items: [] });
      if (u.pathname === "/Items/trk1/PlaybackInfo") return json(req, { MediaSources: [{ Id: "src1", Container: "flac", SupportsDirectPlay: true, Bitrate: 900000 }], PlaySessionId: "ps1" });
      if (u.pathname.startsWith("/Sessions/Playing")) return { status: 204, statusText: "No Content", headers: {}, url: req.url, body: "" };
    }
    return { status: 404, statusText: "Not Found", headers: {}, url: req.url, body: "" };
  };
  const m = rec.engine.music;
  r.eq("music.copy speaks upstream's English", [m.copy()["music.title"], m.copy()["music.row.upNext"]], ["Music", "Up next"]);
  r.eq("music.copy carries the dock's volume copy", [m.copy()["music.volume"], m.copy()["music.mute"], m.copy()["music.unmute"]], ["Music volume", "Mute", "Unmute"]);
  const conns = m.connections();
  r.ok("music.connections lists catalog, Jellyfin, Plex, Navidrome, SoundCloud, Spotify and Last.fm; SoundCloud waits for consent, Spotify for a sign-in", conns.map((c) => c.id).join(",") === "catalog,jellyfin,plex,subsonic,soundcloud,spotify,lastfm" && conns.find((c) => c.id === "soundcloud").status === "disconnected" && conns.find((c) => c.id === "spotify").status === "disconnected" && conns.find((c) => c.id === "spotify").detail === "Bring your own Spotify app" && conns.find((c) => c.id === "catalog").status === "connected", JSON.stringify(conns.map((c) => [c.id, c.status])));
  const h = await m.home(true, null);
  const keys = h.bands.map((b) => b.key);
  r.ok("music.home: server notice, charts stand in for fresh (numbered), artists, catalog extras", keys[0] === "server" && h.bands[0].notice && keys.includes("fresh") && h.bands.find((b) => b.key === "fresh").numbered && h.bands.find((b) => b.key === "fresh").cards[0].track.connectorId === "catalog" && keys.includes("home:catalog:charting-artists") && keys.includes("home:catalog:charts") && !hits.some((x) => x.includes("soundcloud")), JSON.stringify({ keys, errors: h.errors }));
  r.ok("music.home cards carry display fields and the item to open", h.bands.find((b) => b.key === "home:catalog:charting-artists").cards[0].circle === true && h.bands.find((b) => b.key === "home:catalog:charts").cards[0].subtitle === "Daft Punk · 2001", JSON.stringify(h.bands.map((b) => [b.key, b.cards[0] && b.cards[0].subtitle])));
  const s = await m.search("daft punk", null);
  r.ok("music.search merges iTunes songs/albums with Deezer artists", s.tracks[0].title === "One More Time" && s.albums[0].title === "Homework" && s.artists[0].title === "Daft Punk" && s.tracks[0].track.durationLabel === "5:20", JSON.stringify({ t: s.tracks.map((x) => x.title), a: s.albums.map((x) => x.title), ar: s.artists.map((x) => x.title), e: s.errors }));
  const artist = await m.open(s.artists[0].item);
  r.ok("music.open(artist) loads top tracks, albums and related artists", artist.tracks.length === 1 && artist.bands.map((b) => b.title).join("|") === "Albums|Related artists", JSON.stringify({ t: artist.tracks.length, b: artist.bands.map((b) => b.title) }));
  const catalogTrack = h.bands.find((b) => b.key === "fresh").cards[0].track;
  const none = await m.prepare(catalogTrack, null, null).then(() => "played", (e) => e.message);
  r.eq("music.prepare: a catalog track with no playable source says so", none, "No matching source is available right now.");
  r.eq("music.acceptSoundCloud records consent", m.acceptSoundCloud(), { accepted: true, soundcloud: true });
  const p = await m.prepare(catalogTrack, null, null);
  r.ok("music.prepare matches the chart track to the SoundCloud upload (not the cover) and resolves AAC HLS, never Opus", p.track.connectorId === "soundcloud" && p.track.sourceId === "2" && p.track.collectionOrigin.id === catalogTrack.id && p.stream.mimeType === "application/vnd.apple.mpegurl" && p.stream.url.startsWith("https://playback.media-streaming.soundcloud.cloud/") && p.stream.bitrate === 160000, JSON.stringify(p));
  r.ok("SoundCloud client id is scraped from the web app's bundle and cached", hits.some((x) => x.includes("a-v2.sndcdn.com/assets/49-def.js")) && rec.node.storage.get("harbor.music.soundcloud-client-id") === "ABCDEFGHIJKLMNOPQRSTUVWXYZ012345");
  const lib = m.setLiked(p.track, true);
  r.ok("music.setLiked / isLiked follow liked.ts (the playing copy answers to its catalog origin)", lib.liked.length === 1 && m.isLiked(p.track) && !m.isLiked(catalogTrack) && m.setLiked(p.track, false).liked.length === 0);
  m.addRecent(p.track);
  const h2 = await m.home(false, [catalogTrack]);
  r.ok("music.home with history: recents first, charts leave fresh, up next from the queue", h2.bands[0].key === "recents" && !h2.bands.some((b) => b.key === "fresh") && h2.bands.some((b) => b.key === "charts") && h2.bands.find((b) => b.key === "liked").title === "Up next" && h2.bands.some((b) => b.key === "artists" && b.cards[0].title === "Daft Punk"), JSON.stringify(h2.bands.map((b) => b.key)));
  jellyfinOn = true;
  for (const [k, v] of [["harbor.media-server.connections.v1", JSON.stringify([{ id: "ms1", profileId: "default", provider: "jellyfin", name: "Jellyfin · den", origin: jf, userId: "u1", enabled: true }])], ["harbor.media-server.token.v1.default.ms1", "tok1"]]) {
    rec.node.storage.set(k, v);
    rec.engine.runtime.syncStorage(k, v);
  }
  const h3 = await m.home(true, null);
  const server = h3.bands.find((b) => b.key === "server:jellyfin:home:recent");
  r.ok("music.home shows the Jellyfin shelf once a Jellyfin server is connected", !!server && server.title === "On your server" && server.subtitle === "Jellyfin · den" && server.cards[0].artwork.startsWith(`${jf}/Items/alb1/Images/Primary?`) && !h3.bands.some((b) => b.key === "server"), JSON.stringify(h3.bands.map((b) => b.key)));
  const album = server ? await m.open(server.cards[0].item) : { tracks: [] };
  const jp = album.tracks[0] ? await m.prepare(album.tracks[0], null, null) : { stream: { url: "", mimeType: "" } };
  r.ok("Jellyfin album opens and a FLAC track resolves to the universal URL with its session", album.tracks[0] && album.tracks[0].durationLabel === "4:35" && jp.stream.mimeType === "audio/flac" && jp.stream.url.includes("/Audio/trk1/universal?") && jp.stream.url.includes("playSessionId=ps1") && !/opus|ogg/.test(new URL(jp.stream.url).searchParams.get("container")) && hits.some((x) => x.startsWith("POST") && x.endsWith("/Sessions/Playing")), JSON.stringify(jp));
  rec.dispose();
}

// ------------------------- music, second batch: Navidrome, Last.fm, ListenBrainz, radio, lyrics
{
  const { createHash } = await import("node:crypto");
  const md5 = (s) => createHash("md5").update(s, "utf8").digest("hex");
  const nd = "http://nd.example.invalid";
  const rec = loadEngine({ storage: new Map([
    ["harbor.profiles.v1", JSON.stringify({ activeId: "default", profiles: [{ id: "default", isPrimary: true }] })],
  ]) });
  const hits = [];
  const scrobbles = [];
  const fmCalls = [];
  let fmScrobbleReply = { scrobbles: { "@attr": { accepted: 1 } } };
  const json = (req, body, status = 200) => ({ status, statusText: "OK", headers: { "content-type": "application/json" }, url: req.url, body: typeof body === "string" ? body : JSON.stringify(body) });
  const ok = (extra = {}) => ({ "subsonic-response": { status: "ok", version: "1.16.1", type: "navidrome", ...extra } });
  const mbRelease = "1b6c4560-1234-4e7c-bd9f-a5f31d5cfe1a";
  const seedTrack = { id: "deezer:track:3135556", connectorId: "catalog", sourceId: "3135556", title: "Harder, Better, Faster, Stronger", artist: "Daft Punk", album: "Discovery", artwork: "", durationSeconds: 224, durationLabel: "3:44" };
  const dzTrack = (id, title, artistId, artist) => ({ id, title, duration: 200, artist: { id: artistId, name: artist }, album: { title: `${title} LP`, cover_big: "https://cdn.example.invalid/c.jpg" } });
  rec.node.host.fetch = async (req) => {
    hits.push(`${req.method} ${req.url}`);
    const u = new URL(req.url);
    if (u.origin === nd) {
      if (u.pathname === "/auth/login") return json(req, { error: "not navidrome" }, 404);
      const q = u.searchParams;
      const authed = q.get("u") === "alice" && q.get("t") === md5(`sesame${q.get("s")}`) && q.get("v") === "1.16.1" && q.get("c") === "Harbor";
      if (!authed) return json(req, { "subsonic-response": { status: "failed", version: "1.16.1", error: { code: 40, message: "Wrong username or password" } } });
      const m = u.pathname.replace(/^\/rest\//, "");
      if (m === "ping") return json(req, ok());
      if (m === "getAlbumList2") return json(req, ok({ albumList2: q.get("type") === "newest" ? { album: [{ id: "al-1", name: "Absolution", artist: "Muse", coverArt: "al-1_2c", songCount: 14, year: 2003 }] } : {} }));
      if (m === "getStarred2") return json(req, ok({ starred2: { song: [{ id: "mf-1", title: "Hysteria", artist: "Muse", album: "Absolution", coverArt: "mf-1_9f", duration: 227 }] } }));
      if (m === "getArtists") return json(req, ok({ artists: { ignoredArticles: "The", index: [{ name: "M", artist: [{ id: "ar-1", name: "Muse" }] }, { name: "R", artist: [{ id: "ar-2", name: "Radiohead", artistImageUrl: "https://example.invalid/r.jpg" }] }] } }));
      if (m === "getPlaylists") return json(req, ok({ playlists: {} }));
      if (m === "getAlbum") return json(req, ok({ album: { song: [{ id: "c", title: "C", track: 1, discNumber: 2 }, { id: "mf-2", title: "B", track: 2, artist: "Muse" }, { id: "mf-1", title: "A", track: 1, artist: "Muse", duration: 227 }] } }));
      if (m === "getSong") return json(req, ok({ song: { id: q.get("id"), suffix: q.get("id") === "mf-2" ? "opus" : "flac", bitRate: 900 } }));
      if (m === "search3") return json(req, ok({ searchResult3: { song: [{ id: "mf-1", title: "Hysteria", artist: "Muse", duration: 227 }] } }));
      if (m === "scrobble") { scrobbles.push([q.get("id"), q.get("submission"), q.get("time")]); return json(req, ok()); }
      return json(req, ok());
    }
    if (u.host === "ws.audioscrobbler.com") {
      const form = Object.fromEntries(new URLSearchParams(req.body || ""));
      fmCalls.push(form);
      const { api_sig, format, ...signed } = form;
      const expected = md5(Object.keys(signed).sort().map((k) => `${k}${signed[k]}`).join("") + "shh");
      if (api_sig !== expected || format !== "json") return json(req, { error: 13, message: "Invalid method signature supplied" }, 403);
      if (form.method === "auth.getToken") return json(req, { token: "tok123" });
      if (form.method === "auth.getSession") return json(req, { session: { name: "alice", key: "sk1", subscriber: 0 } });
      if (form.method === "track.scrobble") return json(req, fmScrobbleReply);
    }
    if (u.host === "api.listenbrainz.org" && u.pathname === "/1/explore/fresh-releases/") return json(req, { payload: { releases: [
      { artist_credit_name: "Someone", caa_id: 11, caa_release_mbid: "aa21d4e9-af51-4e7c-bd9f-a5f31d5cfe1a", release_date: "2026-08-30", release_group_mbid: "6e335887-60ba-38f0-95af-fae7774336bf", release_group_primary_type: "Single", release_mbid: "bb21d4e9-af51-4e7c-bd9f-a5f31d5cfe1a", release_name: "A single" },
      { artist_credit_name: "Bonobo", caa_id: 34059386237, caa_release_mbid: "cd21d4e9-af51-4e7c-bd9f-a5f31d5cfe1a", release_date: "2026-08-29", release_group_mbid: "6e335887-60ba-38f0-95af-fae7774336bf", release_group_primary_type: "Album", release_mbid: mbRelease, release_name: "Fragments" },
    ] } });
    if (u.host === "musicbrainz.org" && u.pathname === `/ws/2/release/${mbRelease}`) return json(req, { media: [{ tracks: [{ id: "11111111-2222-3333-4444-555555555555", title: "Polyghost", recording: { id: "99999999-2222-3333-4444-555555555555", title: "Polyghost", length: 245000, "artist-credit": [{ name: "Bonobo", joinphrase: " & " }, { name: "Jacob Lusk" }] } }] }] });
    if (u.host === "lrclib.net") {
      if (u.pathname === "/api/get") return json(req, { id: 1, duration: 224, instrumental: false, plainLyrics: "Work it", syncedLyrics: "[00:01.50]Work it\n[00:03.2]Make it\n[00:05.00][00:07.00]Do it" });
      return json(req, []);
    }
    if (u.host === "api.deezer.com") {
      if (u.pathname === "/track/3135556") return json(req, { id: 3135556, type: "track", title: "Harder, Better, Faster, Stronger", duration: 224, bpm: 123, release_date: "2001-03-07", artist: { id: 27, name: "Daft Punk" }, album: { id: 302127, title: "Discovery" } });
      if (u.pathname === "/album/302127") return json(req, { id: 302127, release_date: "2001-03-07", genres: { data: [{ id: 113 }] } });
      if (u.pathname === "/artist/27/radio") return json(req, { data: [dzTrack(1, "Da Funk", 27, "Daft Punk"), dzTrack(2, "D.A.N.C.E.", 28, "Justice"), dzTrack(3, "Music Sounds Better", 29, "Stardust"), dzTrack(4, "Karaoke Version of Around", 30, "Karaoke Kings"), dzTrack(5, "Genesis", 28, "Justice")] });
      if (u.pathname === "/artist/27/related") return json(req, { data: [{ id: 28, name: "Justice" }, { id: 31, name: "Cassius" }] });
      if (u.pathname === "/artist/28/top") return json(req, { data: [dzTrack(2, "D.A.N.C.E.", 28, "Justice"), dzTrack(6, "Phantom", 28, "Justice")] });
      if (u.pathname === "/artist/31/top") return json(req, { data: [dzTrack(7, "1999", 31, "Cassius"), dzTrack(8, "Feeling for You", 31, "Cassius")] });
    }
    return { status: 404, statusText: "Not Found", headers: {}, url: req.url, body: "" };
  };
  const m = rec.engine.music;
  const store = rec.node.storage;

  // Navidrome sign-in (subsonic/mod.rs sign_in + client.rs pair: no /auth/login, so md5 token auth)
  const bad = await m.subsonicConnect(nd, "alice", "wrong").then(() => "connected", (e) => e.message);
  r.eq("music.subsonicConnect: a rejected sign-in reads as upstream's reconnect prompt", bad, "Your music server rejected this sign in. Connect it again.");
  const conn = await m.subsonicConnect(`${nd}/`, " alice ", "sesame");
  const salt = store.get("harbor.subsonic.v1.salt");
  r.ok("music.subsonicConnect pairs with salt + md5(password+salt) and never stores the password", conn.account === "alice" && conn.detail === nd && salt && salt.length === 16 && store.get("harbor.subsonic.v1.token") === md5(`sesame${salt}`) && store.get("harbor.subsonic.v1.baseUrl") === nd && ![...store.values()].some((v) => String(v).includes("sesame")), JSON.stringify({ conn, salt }));
  const nconn = m.connections();
  r.ok("music.connections: Navidrome connected as alice, Last.fm listed as a scrobbler", nconn.find((c) => c.id === "subsonic").status === "connected" && nconn.find((c) => c.id === "subsonic").account === "alice" && nconn.find((c) => c.id === "lastfm").kind === "scrobbler" && nconn.find((c) => c.id === "lastfm").status === "disconnected", JSON.stringify(nconn.map((c) => [c.id, c.status, c.account])));
  const h = await m.home(true, null);
  const newest = h.bands.find((b) => b.key === "server:subsonic:home:newest");
  const starred = h.bands.find((b) => b.key === "server:subsonic:home:starred");
  r.ok("music.home: Navidrome shelves (newest, starred, artists) with sized cover art; empty lists collapse", !!newest && newest.title === "On your server" && newest.cards[0].artwork.includes("/rest/getCoverArt?") && newest.cards[0].artwork.includes("size=512") && !newest.cards[0].artwork.includes("f=json") && !!starred && starred.title === "Liked tracks" && h.bands.some((b) => b.key === "server:subsonic:home:artists" && b.cards[1].artwork === "https://example.invalid/r.jpg") && !h.bands.some((b) => b.key.includes("subsonic:home:frequent") || b.key.includes("subsonic:home:playlists")) && !h.bands.some((b) => b.key === "server"), JSON.stringify(h.bands.map((b) => [b.key, b.title])));
  const album = await m.open(newest.cards[0].item);
  r.eq("Navidrome album opens in disc then track order", album.tracks.map((t) => t.sourceId), ["mf-1", "mf-2", "c"]);
  const p1 = await m.prepare(album.tracks[0], null, null);
  const u1 = new URL(p1.stream.url);
  r.ok("Navidrome resolves a raw stream URL with token auth and reports now playing", u1.pathname === "/rest/stream" && u1.searchParams.get("format") === "raw" && u1.searchParams.get("id") === "mf-1" && u1.searchParams.get("u") === "alice" && !u1.searchParams.has("f") && scrobbles.some((s) => s[0] === "mf-1" && s[1] === "false"), JSON.stringify({ url: p1.stream.url, scrobbles }));
  // Liked / recents live in plain storage: Subsonic's u/t/s never go in; the room gets them back.
  const artTrack = { ...p1.track, artwork: newest.cards[0].artwork };
  m.addRecent(artTrack);
  m.setLiked(artTrack, true);
  const rawRecents = store.get("harbor.music.recents.v1") ?? "";
  const rawLiked = store.get("harbor.music.liked.v1") ?? "";
  const shownArt = m.library().recents[0].artwork;
  r.ok("music liked/recents store Navidrome cover art without u/t/s and sign it again for the room", rawRecents.includes("/rest/getCoverArt?") && !/[?&](u|t|s)=/.test(rawRecents) && !/[?&](u|t|s)=/.test(rawLiked) && !rawRecents.includes(store.get("harbor.subsonic.v1.token")) && new URL(shownArt).searchParams.get("t") === store.get("harbor.subsonic.v1.token") && new URL(shownArt).searchParams.get("u") === "alice" && new URL(shownArt).searchParams.get("id") === new URL(artTrack.artwork).searchParams.get("id") && new URL(artTrack.artwork).searchParams.get("t") !== null, JSON.stringify({ rawRecents: rawRecents.slice(0, 300), shownArt }));
  const p2 = await m.prepare(album.tracks[1], null, null);
  r.ok("Navidrome asks the server for MP3 when the file is Opus (AVPlayer cannot decode it)", new URL(p2.stream.url).searchParams.get("format") === "mp3" && new URL(p2.stream.url).searchParams.get("maxBitRate") === "320", p2.stream.url);
  const ns = await m.search("hysteria", "subsonic");
  r.ok("music.search scoped to Navidrome uses search3", ns.tracks[0] && ns.tracks[0].track.id === "subsonic:mf-1" && ns.tracks[0].track.durationLabel === "3:47", JSON.stringify(ns.tracks));

  // Last.fm (lastfm.rs): signed auth.getToken -> phone approval -> auth.getSession, then scrobbles
  r.eq("music.shouldScrobble uses half the track or four minutes (engine.rs)", [m.shouldScrobble(149, 300), m.shouldScrobble(150, 300), m.shouldScrobble(239, 900), m.shouldScrobble(240, 900)], [false, true, false, true]);
  const skipped = await m.scrobble({ ...seedTrack }, 1700000000);
  r.eq("music.scrobble without a Last.fm session is skipped", skipped.status, "skipped");
  const begin = await m.lastfmBegin(" key ", "shh");
  r.ok("music.lastfmBegin signs auth.getToken and returns the phone link", begin.token === "tok123" && begin.authUrl === "https://www.last.fm/api/auth/?api_key=key&token=tok123" && fmCalls[0].method === "auth.getToken" && store.get("harbor.lastfm.v1.apiKey") === "key", JSON.stringify({ begin, fmCalls }));
  const fin = await m.lastfmFinish(begin.token);
  r.ok("music.lastfmFinish stores the session and reports the account", fin.connected && fin.username === "alice" && store.get("harbor.lastfm.v1.sessionKey") === "sk1" && m.connections().find((c) => c.id === "lastfm").status === "connected", JSON.stringify(fin));
  const sc = await m.scrobble(album.tracks[0], 1700000000);
  const call = fmCalls[fmCalls.length - 1];
  r.ok("music.scrobble: Navidrome submission with its time, then a signed track.scrobble", sc.status === "scrobbled" && call.method === "track.scrobble" && call.sk === "sk1" && call.timestamp === "1700000000" && call.chosenByUser === "1" && call.duration === "227" && call.artist === "Muse" && scrobbles.some((s) => s[0] === "mf-1" && s[1] === "true" && s[2] === "1700000000000"), JSON.stringify({ sc, call, scrobbles }));
  fmScrobbleReply = { error: 9, message: "Invalid session key - Please re-authenticate" };
  const failed = await m.scrobble(seedTrack, 1700000001);
  r.ok("music.scrobble reports a Last.fm error and marks the connection", failed.status === "error" && failed.message === "Last.fm error 9: Invalid session key - Please re-authenticate", JSON.stringify(failed));
  const gone = m.lastfmDisconnect();
  r.ok("music.lastfmDisconnect clears all four secrets", !gone.connected && !store.has("harbor.lastfm.v1.apiKey") && !store.has("harbor.lastfm.v1.sessionKey"), JSON.stringify(gone));

  // ListenBrainz fresh releases (catalog/listenbrainz.rs) opening through MusicBrainz
  const fresh = h.bands.find((b) => b.key === "new-releases");
  r.ok("music.home: ListenBrainz fresh releases fill New releases (albums and EPs only, Cover Art Archive art)", !!fresh && fresh.title === "New releases" && fresh.cards.length === 1 && fresh.cards[0].title === "Fragments" && fresh.cards[0].artwork === "https://archive.org/download/mbid-cd21d4e9-af51-4e7c-bd9f-a5f31d5cfe1a/mbid-cd21d4e9-af51-4e7c-bd9f-a5f31d5cfe1a-34059386237_thumb500.jpg", JSON.stringify(fresh));
  const release = fresh ? await m.open(fresh.cards[0].item) : { tracks: [] };
  r.ok("a ListenBrainz release opens with MusicBrainz's track list", release.tracks[0] && release.tracks[0].id === "musicbrainz:track:11111111-2222-3333-4444-555555555555" && release.tracks[0].artist === "Bonobo & Jacob Lusk" && release.tracks[0].durationLabel === "4:05" && release.tracks[0].album === "Fragments", JSON.stringify(release.tracks));

  // Lyrics (lyrics.ts: LRCLIB synced lines) and the per-track offset (lyric-offset.ts)
  const ly = await m.lyrics(seedTrack);
  r.eq("music.lyrics parses LRCLIB synced lyrics, repeated stamps included", ly.lines.map((l) => [l.at, l.text]), [[1.5, "Work it"], [3.2, "Make it"], [5, "Do it"], [7, "Do it"]]);
  r.eq("music.setLyricOffset clamps to 0.25 s steps and is read back", [m.setLyricOffset(seedTrack, 0.3), m.setLyricOffset(seedTrack, 99), (await m.lyrics(seedTrack)).offset], [0.25, 8, 8]);
  const none = await m.lyrics({ ...seedTrack, id: "x", album: undefined, title: "Unknown", artist: "Nobody" });
  r.eq("music.lyrics is empty when LRCLIB has nothing", none.lines.length, 0);

  // Track radio (radio.ts): Deezer radio + related-artist lanes, variants dropped, spaced by artist
  const station = await m.radio(seedTrack);
  r.ok("music.radio seeds the station with the track, then ranked Deezer picks without karaoke variants", station.length >= 6 && station[0].id === seedTrack.id && !station.some((t) => /karaoke/i.test(t.title)) && station.slice(1).every((t) => t.connectorId === "catalog" && t.mediaKind === "audio"), JSON.stringify(station.map((t) => `${t.artist} - ${t.title}`)));
  const more = await m.radioExtend(station, station.length - 2);
  r.ok("music.radioExtend never repeats a queued track", Array.isArray(more) && more.every((t) => !station.some((s) => s.title === t.title && s.artist === t.artist)), JSON.stringify(more.map((t) => t.title)));
  // up-next.ts (upstream 770ca0bd): Now Playing's Up next when nothing follows the current track
  const suggested = await m.upNext(seedTrack);
  r.ok("music.upNext offers the track's radio without the track itself", suggested.length === station.length - 1 && suggested.length > 0 && !suggested.some((t) => t.connectorId === seedTrack.connectorId && t.id === seedTrack.id) && suggested[0].id === station[1].id, JSON.stringify(suggested.map((t) => t.id)));
  const noSuggestions = await m.upNext({ ...seedTrack, id: "deezer:track:0", sourceId: "0", title: "Nothing Like It", artist: "Nobody At All" });
  r.eq("music.upNext is empty (not an error) when no station can be built", noSuggestions, []);
  r.eq("music.copy carries up-next.ts's loading line", m.copy()["music.now.queueBuilding"], "Building up next");

  m.subsonicDisconnect();
  r.ok("music.subsonicDisconnect forgets the pairing", !store.has("harbor.subsonic.v1.token") && m.connections().find((c) => c.id === "subsonic").status === "disconnected");
  r.ok("after the disconnect a stored Navidrome track shows no artwork (no stale credentials to sign it with)", m.library().recents.find((x) => x.id === p1.track.id)?.artwork === "", JSON.stringify(m.library().recents.map((x) => x.artwork)));
  // A list an older build wrote with Plex's X-Plex-Token (outer and inner) is rewritten clean on read.
  const plexArt = "https://10.0.0.5:32400/photo/:/transcode?url=%2Flibrary%2Fmetadata%2F7%2Fthumb%2F9%3FX-Plex-Token%3Dsecret1&width=480&height=480&minSize=1&upscale=1&format=jpg&quality=-1&X-Plex-Token=secret1";
  const legacyList = JSON.stringify([{ id: "plex:7", connectorId: "plex", sourceId: "7", title: "Song", artist: "Band", artwork: plexArt, durationSeconds: 60, durationLabel: "1:00" }]);
  rec.run(`localStorage.setItem("harbor.music.liked.v1", ${JSON.stringify(legacyList)})`);
  const legacy = m.library();
  const rawLegacy = store.get("harbor.music.liked.v1") ?? "";
  r.ok("music: an older liked list with X-Plex-Token is scrubbed in storage; without the Plex server it shows no art", !rawLegacy.includes("secret1") && rawLegacy.includes("/photo/:/transcode") && rawLegacy.includes("thumb") && legacy.liked[0].artwork === "" && legacy.likedIds[0] === "plex:7", rawLegacy);
  rec.dispose();
}

// ---------------------------------- music: Spotify (music/spotify: auth.rs PKCE, tokens.rs, browse.rs)
{
  const { createHash } = await import("node:crypto");
  const rec = loadEngine({ storage: new Map([
    ["harbor.profiles.v1", JSON.stringify({ activeId: "default", profiles: [{ id: "default", isPrimary: true }] })],
  ]) });
  const hits = [];
  const forms = [];
  let meProduct = "premium";
  let tokenReply = null;
  const json = (req, body, status = 200) => ({ status, statusText: "OK", headers: { "content-type": "application/json" }, url: req.url, body: typeof body === "string" ? body : JSON.stringify(body) });
  const img = (w) => ({ url: `https://i.scdn.co/image/${w}`, width: w, height: w });
  const spTrack = (id, name, extra = {}) => ({ uri: `spotify:track:${id}`, name, duration_ms: 227000, explicit: false, artists: [{ name: "Muse" }], album: { name: "Absolution", images: [img(64), img(640)] }, ...extra });
  // library.rs ids are 22 base62 characters
  const lid = (n) => `track${String(n).padStart(17, "0")}`;
  const OWN = "OwnPlaylist00000000000", PUB = "PublicPlaylist00000000", FOLLOWED = "FollowedPlaylist000000", COLLAB = "CollabPlaylist00000000", BADPAGE = "BadPagePlaylist0000000", NEWPL = "NewPlaylist00000000000";
  const posts = [];
  rec.node.host.fetch = async (req) => {
    const u = new URL(req.url);
    hits.push(`${req.method} ${u.host}${u.pathname}?${u.searchParams.toString()} ${(req.headers && (req.headers.Authorization || req.headers.authorization)) || ""}`);
    if (u.host === "api.spotify.com") {
      const p = u.pathname.replace(/^\/v1/, "");
      const pl = (id, name, owner, extra = {}) => ({ uri: `spotify:playlist:${id}`, name, images: [img(300)], owner: { id: owner, display_name: owner }, items: { total: 3 }, ...extra });
      if (req.method === "POST") {
        const body = JSON.parse(req.body || "{}");
        posts.push({ path: p, body });
        if (p === "/me/playlists") return json(req, pl(NEWPL, body.name, "alice", { public: false }), 201);
        if (p === `/playlists/${OWN}/items`) return json(req, { snapshot_id: "snap-1" }, 201);
        return json(req, { error: { status: 403 } }, 403);
      }
      // library.rs pages ask for 50; the home rows ask for 20
      if (u.searchParams.get("limit") === "50" && p === "/me/tracks") {
        if (u.searchParams.get("offset") === "0")
          return json(req, { items: [{ track: spTrack(lid(1), "Liked one") }, { track: spTrack(lid(2), "Local file", { is_local: true }) }, { track: { uri: `spotify:episode:${lid(3)}`, name: "Episode", type: "episode" } }, { track: null }], next: "https://api.spotify.com/v1/me/tracks?offset=4&limit=50", total: 5 });
        return json(req, { items: [{ track: spTrack(lid(4), "Liked two") }], next: null, total: 5 });
      }
      if (u.searchParams.get("limit") === "50" && p === "/me/playlists")
        return json(req, { items: [pl(OWN, "Mine", "alice", { public: false }), pl(PUB, "Mine in public", "alice", { public: true }), pl(FOLLOWED, "Followed", "someone", { public: true }), pl(COLLAB, "Together", "bob", { public: false, collaborative: true }), null], next: null, total: 5 });
      if (p === `/playlists/${OWN}/items`) return json(req, { items: [{ item: spTrack(lid(5), "In mine") }], next: null, total: 1 });
      if (p === `/playlists/${BADPAGE}/items`) return json(req, { items: [{ item: spTrack(lid(6), "Elsewhere") }], next: "https://example.test/v1/playlists/x/items?offset=50", total: 60 });
      if (p === `/playlists/${OWN}`) return json(req, pl(OWN, "Mine", "alice", { public: false }));
      if (p === `/playlists/${FOLLOWED}`) return json(req, pl(FOLLOWED, "Followed", "someone", { public: true }));
      if (p === "/artists/muse/albums") {
        if (u.searchParams.get("offset") === "10") return json(req, { items: [{ uri: "spotify:album:showbiz", name: "Showbiz", artists: [{ name: "Muse" }], images: [img(640)], release_date: "1999-10-04" }], next: null, total: 11 });
        return json(req, { items: [{ uri: "spotify:album:abs", name: "Absolution", artists: [{ name: "Muse" }], images: [img(640)] }], next: "https://api.spotify.com/v1/artists/muse/albums?offset=10&limit=10", total: 11 });
      }
    }
    if (u.host === "accounts.spotify.com" && u.pathname === "/api/token") {
      const form = Object.fromEntries(new URLSearchParams(req.body || ""));
      forms.push(form);
      if (tokenReply) return json(req, tokenReply.body, tokenReply.status);
      if (form.grant_type === "authorization_code") return json(req, { access_token: "web-1", token_type: "Bearer", expires_in: 3600, refresh_token: "refresh-1", scope: "streaming user-library-read user-top-read" });
      if (form.grant_type === "refresh_token") return json(req, { access_token: "web-2", token_type: "Bearer", expires_in: 3600, scope: "streaming" });
    }
    if (u.host === "api.spotify.com") {
      const p = u.pathname.replace(/^\/v1/, "");
      if (p === "/me") return json(req, { product: meProduct, country: "GB", id: "alice" });
      if (p === "/me/player/recently-played") return json(req, { items: [{ played_at: "now", track: spTrack("r1", "Hysteria") }] });
      if (p === "/me/top/tracks") return json(req, { items: [spTrack("t1", "Starlight")] });
      if (p === "/me/top/artists") return json(req, { items: [{ uri: "spotify:artist:muse", name: "Muse", genres: ["rock"], images: [img(320)] }] });
      if (p === "/me/playlists") return json(req, { items: [{ uri: "spotify:playlist:pl1", name: "Road trip", images: [img(300)], owner: { display_name: "alice" }, items: { total: 12 } }] });
      if (p === "/me/albums") return json(req, { error: { status: 500 } }, 500);
      if (p === "/me/tracks") return json(req, { items: [] });
      if (p === "/search") {
        if (u.searchParams.get("limit") !== "10") return json(req, { error: { status: 400, message: "Invalid limit" } }, 400);
        return json(req, { tracks: { items: [spTrack("s1", "Hysteria")] }, albums: { items: [{ uri: "spotify:album:abs", name: "Absolution", artists: [{ name: "Muse" }], images: [img(640)], release_date: "2003-09-15", total_tracks: 14 }] }, artists: { items: [{ uri: "spotify:artist:muse", name: "Muse", images: [] }] }, playlists: { items: [null, { uri: "spotify:playlist:pl2", name: "This Is Muse", images: [], tracks: { total: 50 } }] } });
      }
      if (p === "/albums/abs/tracks") return json(req, { items: [{ uri: "spotify:track:a1", name: "Apocalypse Please", duration_ms: 252000, artists: [] }] });
      if (p === "/artists/muse/top-tracks") return json(req, { error: { status: 403 } }, 403);
      if (p === "/playlists/pl1/items") return json(req, { error: { status: 404 } }, 404);
      if (p === "/playlists/pl1/tracks") return json(req, { items: [{ added_at: "now", track: spTrack("p1", "Uprising") }, { added_at: "now", track: null }] });
    }
    return { status: 404, statusText: "Not Found", headers: {}, url: req.url, body: "" };
  };
  const m = rec.engine.music;
  const store = rec.node.storage;

  // auth.rs: no client id yet -> upstream's walkthrough; with one -> a PKCE S256 authorize URL
  const missing = await m.spotifyBegin("").then(() => "begun", (e) => e.message);
  r.eq("music.spotifyBegin without a client id asks for one with upstream's setup hint", missing, "Spotify needs your own client id. Create an app at developer.spotify.com/dashboard, add http://127.0.0.1:8898/login as a redirect URI, then paste the client id here.");
  const begun = await m.spotifyBegin(" abc123client ");
  const au = new URL(begun.authorizeUrl);
  r.ok("music.spotifyBegin saves the client id and builds the authorize URL with upstream's redirect and scopes", au.origin === "https://accounts.spotify.com" && au.pathname === "/authorize" && au.searchParams.get("client_id") === "abc123client" && au.searchParams.get("redirect_uri") === "http://127.0.0.1:8898/login" && au.searchParams.get("code_challenge_method") === "S256" && /^[A-Za-z0-9_-]{43}$/.test(au.searchParams.get("code_challenge")) && au.searchParams.get("scope").split(" ").includes("streaming") && au.searchParams.get("scope").split(" ").length === 13 && store.get("harbor.spotify.v1.clientId") === "abc123client", begun.authorizeUrl);
  const state = au.searchParams.get("state");
  const wrongState = await m.spotifyFinish(`http://127.0.0.1:8898/login?code=AQBcode1234567890&state=other`).then(() => "ok", (e) => e.message);
  r.eq("music.spotifyFinish refuses an address from another sign-in", wrongState, "That address belongs to another sign in. Authorize Spotify again.");
  const denied = await m.spotifyFinish(`http://127.0.0.1:8898/login?error=access_denied&state=${state}`).then(() => "ok", (e) => e.message);
  r.eq("music.spotifyFinish: a declined consent reads as upstream's cancelled sign-in", denied, "Spotify sign in was cancelled before it finished.");
  const done = await m.spotifyFinish(`  http://127.0.0.1:8898/login?code=AQBcode1234567890&state=${state}  `);
  const exchange = forms[forms.length - 1];
  const challenge = createHash("sha256").update(exchange.code_verifier).digest("base64url");
  r.ok("music.spotifyFinish exchanges the code with the PKCE verifier (no secret) and keeps the web token", done.accessToken === "web-1" && /^[0-9a-f-]{36}$/.test(done.deviceId) && exchange.grant_type === "authorization_code" && exchange.code === "AQBcode1234567890" && exchange.client_id === "abc123client" && exchange.redirect_uri === "http://127.0.0.1:8898/login" && challenge === au.searchParams.get("code_challenge") && !("client_secret" in exchange) && JSON.parse(store.get("harbor.spotify.v1.webToken")).refreshToken === "refresh-1", JSON.stringify({ done, exchange }));
  r.eq("the Spotify keys live under harbor.spotify.v1 (the Keychain tier on the TV)", [...store.keys()].filter((k) => k.includes("spotify")).sort(), ["harbor.spotify.v1.clientId", "harbor.spotify.v1.deviceId", "harbor.spotify.v1.webToken"]);
  const replay = await m.spotifyFinish(`http://127.0.0.1:8898/login?code=AQBcode1234567890&state=${state}`).then(() => "ok", (e) => e.message);
  r.eq("a used sign-in cannot be finished twice", replay, "Spotify sign in timed out. Authorize Spotify again.");

  // Before the librespot session reports in, Spotify is not browsable and asks for Premium
  r.eq("Spotify stays out of search until the session is up (tokens.rs CONNECT_FIRST)", m.connections().find((c) => c.id === "spotify").status, "disconnected");

  // The Rust session answered (Premium unknown): tokens.rs probe_tier via /me; credentials kept
  const rust = { connected: true, username: "alice", country: "gb", premium: false, accountType: null, error: null, credentials: "{\"username\":\"alice\",\"auth_type\":1,\"auth_data\":\"c2VjcmV0\"}" };
  const ready = await m.spotifySessionReady(rust, { accessToken: "session-1", expiresAt: Math.floor(Date.now() / 1000) + 3600 });
  r.ok("music.spotifySessionReady keeps the reusable sign-in and reads Premium from /me", ready.connected && ready.premium && ready.accountType === "Premium" && !ready.shutdown && store.get("harbor.spotify.v1.credentials") === rust.credentials && m.spotifyRestore().credentials === rust.credentials, JSON.stringify(ready));
  const row = m.connections().find((c) => c.id === "spotify");
  r.ok("music.connections: Spotify connected as alice (Premium)", row.status === "connected" && row.account === "alice" && row.detail === "Premium" && row.capabilities.join(",") === "search,browse,play", JSON.stringify(row));

  // browse.rs home: six rows in parallel; a failed row and an empty row drop out
  const h = await m.home(true, null);
  const keys = h.bands.map((b) => b.key);
  r.ok("music.home carries Spotify's personal rows (recent, top tracks/artists, playlists) and drops the failed/empty ones", keys.includes("home:spotify:home:recently-played") && keys.includes("home:spotify:home:top-artists") && keys.includes("home:spotify:home:playlists") && !keys.some((k) => k.includes("saved-albums") || k.includes("saved-tracks")) && h.bands.find((b) => b.key === "home:spotify:home:recently-played").cards[0].artwork === "https://i.scdn.co/image/640" && h.bands.find((b) => b.key === "home:spotify:home:playlists").cards[0].subtitle === "alice", JSON.stringify(keys));
  r.ok("Spotify Web API calls carry the OAuth token and the account's market", hits.some((x) => x.includes("/v1/me/albums?") && x.includes("market=GB") && x.endsWith("Bearer web-1")), hits.filter((x) => x.includes("api.spotify.com")).join("\n"));

  // api.rs search: a restricted client (400) is retried at 10; browse.rs top_result prefers the exact artist
  const s = await m.search("muse", "spotify");
  r.ok("music.search scoped to Spotify retries at ten and the exact artist is the top result", s.top && s.top.kind === "artist" && s.top.title === "Muse" && s.tracks[0].track.sourceId === "spotify:track:s1" && s.albums[0].subtitle === "Muse · 2003" && s.playlists.length === 1 && hits.filter((x) => x.includes("/v1/search?")).length === 2, JSON.stringify(s));
  const albumPage = await m.open(s.albums[0].item);
  r.ok("a Spotify album opens with its tracks inheriting the album's artist and cover", albumPage.tracks[0].title === "Apocalypse Please" && albumPage.tracks[0].artist === "Muse" && albumPage.tracks[0].artwork === "https://i.scdn.co/image/640" && albumPage.tracks[0].durationLabel === "4:12", JSON.stringify(albumPage.tracks));
  const artistPage = await m.open(s.artists[0].item);
  r.ok("a Spotify artist whose top tracks are refused falls back to an artist: search, with the albums shelf", artistPage.tracks.length === 1 && hits.some((x) => x.includes("/v1/search?") && x.includes("q=artist%3A%22Muse%22")) && artistPage.bands[0] && artistPage.bands[0].title === "Albums", JSON.stringify(artistPage));
  const playlistPage = await m.open(h.bands.find((b) => b.key === "home:spotify:home:playlists").cards[0].item);
  r.eq("a Spotify playlist falls back from /items to /tracks and skips removed entries", playlistPage.tracks.map((t) => t.sourceId), ["spotify:track:p1"]);

  // artist_catalog.rs: the albums shelf carries a cursor bound to the artist; the next page follows it
  const albumsBand = artistPage.bands[0];
  const moreAlbums = await m.artistMore(s.artists[0].item, albumsBand.more);
  r.ok("a Spotify artist's albums shelf pages ten at a time with an artist-bound cursor (artist_catalog.rs)", JSON.parse(albumsBand.more).offset === 10 && JSON.parse(albumsBand.more).artist === "muse" && moreAlbums.cards.map((c) => c.title).join() === "Showbiz" && moreAlbums.more === null && hits.some((x) => x.includes("/v1/artists/muse/albums?") && x.includes("offset=10") && x.includes("include_groups=album%2Csingle%2Cappears_on%2Ccompilation")), JSON.stringify({ more: albumsBand.more, moreAlbums }));
  const otherCursor = await m.artistMore(s.artists[0].item, JSON.stringify({ artist: "other", collection: "albums", offset: 10 })).then(() => "ok", (e) => e.message);
  const extraField = await m.artistMore(s.artists[0].item, JSON.stringify({ artist: "muse", collection: "albums", offset: 10, limit: 50 })).then(() => "ok", (e) => e.message);
  r.ok("an album cursor for another artist, or with unknown fields, is refused", otherCursor === "Spotify album cursor does not match this artist" && extraField === "Spotify album cursor is invalid", JSON.stringify({ otherCursor, extraField }));

  // library.rs: Liked songs 50 a page with the market, local files / episodes / removed entries skipped
  const liked = await m.spotifyLibraryPage("liked", null, null);
  r.ok("music.spotifyLibraryPage liked: playable tracks only, skipped count, next offset from Spotify's link, total", liked.tracks.map((t) => t.sourceId).join() === `spotify:track:${lid(1)}` && liked.skipped === 3 && liked.nextOffset === 4 && liked.total === 5 && hits.some((x) => x.includes("/v1/me/tracks?") && x.includes("limit=50") && x.includes("offset=0") && x.includes("market=GB")), JSON.stringify(liked));
  const liked2 = await m.spotifyLibraryPage("liked", 4, null);
  r.ok("the next Liked songs page ends the list", liked2.tracks[0].title === "Liked two" && liked2.nextOffset === null, JSON.stringify(liked2));
  r.ok("without the playlist-modify scopes nothing can be created or changed", !liked.canCreate && !liked.writePermission, JSON.stringify(liked));
  const lists = await m.spotifyLibraryPage("playlists", 0, null);
  const access = Object.fromEntries(lists.playlists.map((x) => [x.name, `${x.canRead}/${x.editable}`]));
  r.ok("music.spotifyLibraryPage playlists: owned and collaborative ones are readable, nothing editable without the scopes, no market on /me/playlists", JSON.stringify(access) === JSON.stringify({ Mine: "true/false", "Mine in public": "true/false", Followed: "false/false", Together: "true/false" }) && lists.skipped === 1 && hits.some((x) => x.includes("/v1/me/playlists?") && x.includes("limit=50") && !x.includes("market=")), JSON.stringify(lists));
  const noScope = await m.spotifyCreatePlaylist("Road").then(() => "ok", (e) => e.message);
  r.eq("creating a playlist without playlist-modify-private asks to reconnect for permission", noScope, "music.spotifyLibrary.permission");
  const badPage = await m.spotifyLibraryPage("playlist", 0, `spotify:playlist:${BADPAGE}`).then(() => "ok", (e) => e.message);
  const badId = await m.spotifyLibraryPage("playlist", 0, "../me").then(() => "ok", (e) => e.message);
  r.ok("a next link off Spotify's endpoint, or a playlist id that could change the path, is refused (library.rs)", badPage === "music.spotifyLibrary.error" && badId === "music.spotifyLibrary.error" && !hits.some((x) => x.includes("/v1/../me") || x.includes("/v1/me/items")), JSON.stringify({ badPage, badId }));

  // Sign in again with playlist-modify-private (upstream's "Reconnect for permission")
  const again = new URL((await m.spotifyBegin("")).authorizeUrl);
  tokenReply = { status: 200, body: { access_token: "web-3", token_type: "Bearer", expires_in: 3600, refresh_token: "refresh-3", scope: "streaming user-library-read playlist-read-private playlist-modify-private" } };
  await m.spotifyFinish(`http://127.0.0.1:8898/login?code=AQBcode0987654321&state=${again.searchParams.get("state")}`);
  tokenReply = null;
  const lists2 = await m.spotifyLibraryPage("playlists", 0, null);
  const access2 = Object.fromEntries(lists2.playlists.map((x) => [x.name, x.editable]));
  r.ok("with playlist-modify-private: private playlists you own or share are editable, public ones need the public scope", lists2.canCreate && lists2.writePermission && access2.Mine === true && access2["Mine in public"] === false && access2.Together === true && access2.Followed === false, JSON.stringify(access2));
  const created = await m.spotifyCreatePlaylist("  Road trip  ");
  r.ok("music.spotifyCreatePlaylist posts a private playlist with the trimmed name", created.name === "Road trip" && created.id === `spotify:playlist:${NEWPL}` && created.canRead && created.editable && JSON.stringify(posts[posts.length - 1]) === JSON.stringify({ path: "/me/playlists", body: { name: "Road trip", public: false } }), JSON.stringify({ created, post: posts[posts.length - 1] }));
  const tooLong = await m.spotifyCreatePlaylist("x".repeat(101)).then(() => "ok", (e) => e.message);
  r.eq("a playlist name over 100 characters is refused before any request", tooLong, "music.spotifyLibrary.error");
  const catalogTrack = { id: "catalog:1", connectorId: "catalog", title: "Hysteria", artist: "Muse", artwork: "", durationSeconds: 1, durationLabel: "0:01" };
  const notSpotify = await m.spotifyAddToPlaylist(`spotify:playlist:${OWN}`, catalogTrack).then(() => "ok", (e) => e.message);
  r.eq("only a Spotify track can go into a Spotify playlist", notSpotify, "music.spotifyLibrary.spotifyTrackOnly");
  const followedAdd = await m.spotifyAddToPlaylist(`spotify:playlist:${FOLLOWED}`, liked.tracks[0]).then(() => "ok", (e) => e.message);
  r.eq("adding to a playlist you only follow is refused with upstream's copy", followedAdd, "music.spotifyLibrary.restricted");
  const added = await m.spotifyAddToPlaylist(`spotify:playlist:${OWN}`, liked.tracks[0]);
  r.ok("music.spotifyAddToPlaylist posts the track URI to /items and needs Spotify's snapshot id", added === true && JSON.stringify(posts[posts.length - 1]) === JSON.stringify({ path: `/playlists/${OWN}/items`, body: { uris: [`spotify:track:${lid(1)}`] } }) && hits.some((x) => x.startsWith(`GET api.spotify.com/v1/playlists/${OWN}?`)), JSON.stringify(posts));
  const inMine = await m.spotifyLibraryPage("playlist", 0, `spotify:playlist:${OWN}`);
  r.ok("a readable playlist opens from /playlists/{id}/items with the market", inMine.tracks[0].title === "In mine" && inMine.nextOffset === null && hits.some((x) => x.includes(`/v1/playlists/${OWN}/items?`) && x.includes("market=GB")), JSON.stringify(inMine));
  const keys2 = m.copy();
  r.ok("the library page's copy comes from upstream's catalog", keys2["music.spotifyLibrary.title"] === "Spotify library" && keys2["music.spotifyLibrary.permission"] === "Reconnect Spotify to allow playlist changes." && keys2["music.library.loadMore"] === "Load more", JSON.stringify([keys2["music.spotifyLibrary.title"], keys2["music.library.loadMore"]]));

  // Playback: prepare() hands Swift the librespot marker instead of a URL (music_play_track routing)
  const prep = await m.prepare(s.tracks[0].track, null, null);
  r.ok("music.prepare of a Spotify track returns the spotify: URI for the native player", prep.track.connectorId === "spotify" && prep.stream.url === "spotify:track:s1" && prep.stream.mimeType === "audio/x-spotify-uri", JSON.stringify(prep));

  // tokens.rs: an expired web token is refreshed with the refresh token (scopes kept)
  const stale = JSON.parse(store.get("harbor.spotify.v1.webToken"));
  store.set("harbor.spotify.v1.webToken", JSON.stringify({ ...stale, expiresAt: 10 }));
  rec.engine.runtime.syncStorage("harbor.spotify.v1.webToken", JSON.stringify({ ...stale, expiresAt: 10 }));
  const rec2 = await m.spotifyDisconnect();
  r.ok("music.spotifyDisconnect forgets the sign-in and web token, keeps the client id", !rec2.connected && !store.has("harbor.spotify.v1.webToken") && !store.has("harbor.spotify.v1.credentials") && store.get("harbor.spotify.v1.clientId") === "abc123client" && m.connections().find((c) => c.id === "spotify").status === "disconnected", JSON.stringify(rec2));

  // A Free account: /me says free -> upstream's copy and the session is shut down
  meProduct = "free";
  const free = await m.spotifySessionReady({ ...rust, credentials: null }, { accessToken: "session-2", expiresAt: Math.floor(Date.now() / 1000) + 3600 });
  r.ok("a Spotify Free account is refused with upstream's copy and Swift is told to shut the session down", !free.connected && free.shutdown && free.error === "Spotify Free cannot stream through third party apps. Connect a Spotify Premium account." && m.connections().find((c) => c.id === "spotify").status === "error" && m.connections().find((c) => c.id === "spotify").error === free.error, JSON.stringify(free));

  // A refresh with an expired grant (auth.rs describe invalid_grant) drops the stored web token
  meProduct = "premium";
  await m.spotifyBegin("");
  store.set("harbor.spotify.v1.webToken", JSON.stringify({ accessToken: "old", refreshToken: "refresh-old", expiresAt: 10, scopes: ["streaming"] }));
  rec.engine.runtime.syncStorage("harbor.spotify.v1.webToken", JSON.stringify({ accessToken: "old", refreshToken: "refresh-old", expiresAt: 10, scopes: ["streaming"] }));
  await m.spotifySessionReady({ ...rust, credentials: null, accountType: "Premium", premium: true }, null);
  tokenReply = { status: 400, body: { error: "invalid_grant", error_description: "Refresh token revoked" } };
  const expired = await m.search("muse", "spotify").then(() => "ok", (e) => e.message);
  r.ok("an expired refresh token is dropped and Spotify asks to connect again", /Connect Spotify Premium to use Spotify/.test(expired) && !store.has("harbor.spotify.v1.webToken") && forms[forms.length - 1].grant_type === "refresh_token" && forms[forms.length - 1].refresh_token === "refresh-old", JSON.stringify({ expired, form: forms[forms.length - 1] }));
  tokenReply = null;
  store.set("harbor.spotify.v1.webToken", JSON.stringify({ accessToken: "old", refreshToken: "refresh-old", expiresAt: 10, scopes: ["streaming", "user-top-read"] }));
  rec.engine.runtime.syncStorage("harbor.spotify.v1.webToken", JSON.stringify({ accessToken: "old", refreshToken: "refresh-old", expiresAt: 10, scopes: ["streaming", "user-top-read"] }));
  await m.search("muse", "spotify");
  const refreshed = JSON.parse(store.get("harbor.spotify.v1.webToken"));
  r.ok("a stale web token is refreshed; the old refresh token and the granted scopes are kept (tokens.rs)", refreshed.accessToken === "web-2" && refreshed.refreshToken === "refresh-old" && refreshed.scopes.join(",") === "streaming,user-top-read" && hits.some((x) => x.includes("/v1/search?") && x.endsWith("Bearer web-2")), JSON.stringify(refreshed));
  // (bug pass) Several Spotify calls at once with a stale token spend the refresh token once.
  await m.spotifyDisconnect();
  store.set("harbor.spotify.v1.webToken", JSON.stringify({ accessToken: "old", refreshToken: "refresh-once", expiresAt: 10, scopes: ["streaming"] }));
  rec.engine.runtime.syncStorage("harbor.spotify.v1.webToken", JSON.stringify({ accessToken: "old", refreshToken: "refresh-once", expiresAt: 10, scopes: ["streaming"] }));
  await m.spotifySessionReady({ ...rust, credentials: null, accountType: "Premium", premium: true }, null);
  const formsBefore = forms.length;
  await Promise.all([m.search("muse", "spotify"), m.search("daft punk", "spotify"), m.search("air", "spotify")]);
  const spent = forms.slice(formsBefore).filter((f) => f.grant_type === "refresh_token");
  r.ok("concurrent Spotify calls share one token refresh (a rotated refresh token is never spent twice)", spent.length === 1 && spent[0].refresh_token === "refresh-once" && JSON.parse(store.get("harbor.spotify.v1.webToken")).accessToken === "web-2", JSON.stringify({ spent, stored: store.get("harbor.spotify.v1.webToken") }));
  rec.dispose();
}

// ----------------------------------- sports event rows, where, bell, broadcasts, api key (SP-1/4/7/8/11/12/13)
{
  const posts = [];
  const rec = loadEngine({ storage: new Map([
    ["harbor.profiles.v1", JSON.stringify({ activeId: "default", profiles: [{ id: "default", isPrimary: true }] })],
    ["harbor.sports.sources.v1", JSON.stringify({ channels: {}, streams: { "g-att": { url: "https://cdn.example.invalid/att.m3u8", kind: "hls", page: "https://page.example.invalid/x", title: "Attached", poster: "" } } })],
  ]) });
  rec.node.host.fetch = async (req) => {
    if (req.method === "POST") posts.push(req);
    return { status: req.method === "POST" ? 204 : 404, statusText: "", headers: {}, url: req.url, body: "" };
  };
  const S = rec.engine.sports;
  S.accept();
  const side = (id, name, abbr, score = "0") => ({ id, name, abbr, logo: "", score, winner: false });
  const p = (id, name, position, starter, extra = {}) => ({ id, name, jersey: String(id).slice(-2), position, starter, goals: 0, yellowCards: 0, redCards: 0, ...extra });
  const base = (league, extra) => ({ id: "g-" + league, league, state: "in", detail: "Live", home: side("h", "Home Side", "HOM", "2"), away: side("a", "Away Side", "AWY", "1"), startMs: Date.now() - 3600000, ...extra });
  const det = (game, extra) => ({ ...game, homeRoster: [], awayRoster: [], homeStats: {}, awayStats: {}, allStats: [], events: [], ...extra });

  const nba = base("NBA");
  const five = (pre) => ["PG", "SG", "SF", "PF", "C"].map((pos, i) => p(`${pre}${i}`, `${pre.toUpperCase()} Player${i}`, pos, true));
  const nbaRows = await S.eventRows(nba, det(nba, {
    homeRoster: five("h"), awayRoster: five("a"),
    allStats: [{ label: "Rebounds", homeValue: "30", awayValue: "10" }],
    events: [{ id: "e1", time: "Q1 10:00", type: "other", text: "Jump ball won" }, { id: "e2", time: "Q1 9:40", type: "other", text: "Smith makes three point jumper" }],
  }));
  r.ok("sports.eventRows: live NBA shows the court, newest play first (a three is loud), stat share", nbaRows.stats && nbaRows.stats.title === "Live now" && nbaRows.stats.situation.kind === "court" && nbaRows.stats.situation.court.home.length === 5 && nbaRows.stats.situation.court.away[0].left === 63 && nbaRows.stats.plays.rows[0].id === "e2" && nbaRows.stats.plays.rows[0].loud === true && nbaRows.stats.plays.rows[0].icon === "three" && nbaRows.stats.team.lines[0].share === 25, JSON.stringify(nbaRows.stats && { t: nbaRows.stats.title, s: nbaRows.stats.situation, p: nbaRows.stats.plays && nbaRows.stats.plays.rows[0], l: nbaRows.stats.team }));
  r.ok("sports.eventRows: rosters make the Lineups row, starters first", nbaRows.lineups && nbaRows.lineups.title === "Lineups" && nbaRows.lineups.home.starters === 5 && nbaRows.lineups.pitch === null, JSON.stringify(nbaRows.lineups && { t: nbaRows.lineups.title, s: nbaRows.lineups.home && nbaRows.lineups.home.starters }));

  const mlb = base("MLB");
  const mlbRows = await S.eventRows(mlb, det(mlb, { state: "in", homeRoster: [p("b1", "Babe Batter", "RF", true)], awayRoster: [p("p1", "Pat Pitcher", "P", true)], baseball: { balls: 2, strikes: 1, outs: 2, batterId: "b1", pitcherId: "p1", onSecondId: "b1" } }));
  const dia = mlbRows.stats && mlbRows.stats.situation && mlbRows.stats.situation.diamond;
  r.ok("sports.eventRows: live MLB shows the diamond (bases, count, batter, pitcher)", dia && JSON.stringify(dia.bases) === "[false,true,false]" && dia.balls === 2 && dia.outs === 2 && dia.batter === "Babe Batter" && dia.pitcher === "Pat Pitcher" && dia.runners === "Second base: Babe Batter" && mlbRows.stats.situation.caption === "On the diamond", JSON.stringify(mlbRows.stats));

  const nfl = base("NFL");
  const nflRows = await S.eventRows(nfl, det(nfl, { football: { source: "situation", down: 3, distance: 7, possessionTeamId: "a", yardLine: 50, yardLineText: "AWY 50" } }));
  const fld = nflRows.stats && nflRows.stats.situation && nflRows.stats.situation.field;
  r.ok("sports.eventRows: NFL shows the field with the ball marker at midfield", fld && fld.down === 3 && fld.distance === 7 && fld.owner.abbr === "AWY" && fld.marker === 50 && fld.yardLine === "AWY 50", JSON.stringify(nflRows.stats));

  const epl = base("EPL");
  const xi = (pre) => [p(`${pre}0`, `${pre} Keeper`, "G", true), ...Array.from({ length: 10 }, (_, i) => p(`${pre}${i + 1}`, `${pre} Out${i}`, i < 4 ? "D" : i < 7 ? "M" : "F", true)), p(`${pre}99`, `${pre} Bench`, "F", false)];
  const eplRows = await S.eventRows(epl, det(epl, {
    homeRoster: xi("h"), awayRoster: xi("a"), homeFormation: "4-3-3", awayFormation: "4-3-3",
    playerStats: [{ teamId: "h", name: "Batting", labels: ["A", "B", "C", "D", "E", "F", "G"], descriptions: [], rows: [{ player: p("h1", "Hank One", "D", true), values: ["1", "2", "3", "4", "5", "6", "7"] }] }],
    events: [{ id: "g1", time: "12'", type: "goal", text: "Goal! h Out8 scores", teamId: "h", participantName: "h Out8" }],
  }));
  const pitch = eplRows.lineups && eplRows.lineups.pitch;
  r.ok("sports.eventRows: soccer lineups draw the pitch (22 spots, formations, bench) and player tables", pitch && pitch.spots.length === 22 && pitch.homeFormation === "4-3-3" && pitch.bench.length === 2 && pitch.spots.every((s) => s.left >= 0 && s.left <= 100) && eplRows.lineups.title === "Lineups and player statistics" && eplRows.lineups.players[0].labels.length === 6 && eplRows.lineups.players[0].trimmed === 1 && eplRows.lineups.players[0].heading === "Home Side · Batting", JSON.stringify(eplRows.lineups && { pitch: pitch && [pitch.spots.length, pitch.homeFormation, pitch.bench], players: eplRows.lineups.players }));
  r.eq("sports.eventRows: no detail, no rows", await S.eventRows({ ...base("NBA"), id: "none", source: "nowhere" }, null).then((x) => [x.stats, x.lineups]).catch(() => "threw"), [null, null]);

  const ufc = base("UFC", { state: "pre", startMs: Date.now() + 3600000, context: { id: "c", name: "UFC 999", round: "", draw: "", venue: "T-Mobile Arena", major: true } });
  const wh = await S.where(ufc);
  r.ok("sports.where: UFC lists Fight Pass (so no guide fallback) and the venue cell", wh && wh.marks.some((m) => m.id === "ufc" && m.note === "Check event availability") && !wh.marks.some((m) => m.url === "https://www.ufc.com/watch") && wh.venue && wh.venue.name === "T-Mobile Arena" && wh.title === "Venue and where to watch" && /does not bypass/.test(wh.note), JSON.stringify(wh));
  const f1w = await S.where(base("F1", { home: side("", "", ""), away: side("", "", ""), context: { id: "r", name: "Monaco Grand Prix", round: "", draw: "", venue: "", major: true } }));
  r.ok("sports.where: F1 adds the country broadcaster guide tile", f1w && f1w.marks.some((m) => m.id === "f1" && m.name === "Find your country's F1 broadcaster"), JSON.stringify(f1w && f1w.marks));

  // SP-4: the bell asks for a webhook first, then arms a 15 minute reminder the loop delivers once.
  const soon = base("NBA", { id: "g-soon", state: "pre", startMs: Date.now() + 60 * 60000 });
  const a0 = S.actions(soon);
  r.ok("sports.actions: the bell says Set up reminders without a webhook; both NBA sides can be followed", a0.reminder && a0.reminder.setup === true && a0.reminder.label === "Set up reminders" && a0.follow.length === 2 && a0.follow[0].label === "Follow Away Side", JSON.stringify(a0));
  r.eq("sports.toggleReminder without a webhook asks for setup", S.toggleReminder(soon).state, "setup");
  S.setWebhooks("https://discord.example.invalid/api/webhooks/1/x", "");
  r.eq("sports.setWebhooks keeps the rest of settings.webhooks", [S.webhooks().discordUrl !== "", rec.engine.settings.load("harbor.settings.shared").webhooks.notifyMovies], [true, true]);
  r.eq("sports.toggleReminder arms a reminder", S.toggleReminder(soon).state, "set");
  r.eq("sports.actions shows Reminder set", S.actions(soon).reminder.label, "Reminder set");
  r.eq("sports.runReminders sends nothing before the 15 minute lead", await S.runReminders(), 0);
  const stored = JSON.parse(rec.run('localStorage.getItem("harbor.sports.reminders.v1")'));
  stored[0].startMs = Date.now() + 5 * 60000;
  rec.run(`localStorage.setItem("harbor.sports.reminders.v1", ${JSON.stringify(JSON.stringify(stored))})`);
  r.eq("sports.runReminders delivers the due Discord webhook once", [await S.runReminders(), await S.runReminders()], [1, 0]);
  r.ok("the Discord webhook carries upstream's reminder text", posts.length === 1 && /Harbor Sports · NBA/.test(posts[0].body) && /Starts in 5 minutes/.test(posts[0].body), JSON.stringify(posts.map((x) => x.body)));
  r.eq("sports.testWebhook sends upstream's test message; Telegram without a URL says so", [await S.testWebhook("discord"), /Harbor test message \(Discord\)/.test(posts[1] && posts[1].body), (await S.testWebhook("telegram")).message], [{ ok: true, message: "Sent. Check your channel." }, true, "No URL configured"]);
  r.eq("sports.toggleReminder clears a set reminder", [S.toggleReminder(soon).state, S.reminders().length], ["cleared", 0]);
  r.eq("sports.toggleFollow follows a side", [S.toggleFollow(soon, "home"), S.actions(soon).follow[1].label], [true, "Following Home Side"]);

  // SP-7 / SP-13: the watch plan follows bp-sports-watch (attached stream, official broadcasts).
  const att = await S.watch({ ...base("NBA"), id: "g-att" }, null);
  r.ok("sports.watch plays an attached stream first", att.plan === "stream" && att.label === "Watch" && att.attachedStream.url === "https://cdn.example.invalid/att.m3u8", JSON.stringify({ plan: att.plan, s: att.attachedStream }));
  r.eq("sports.clearAttachedStream drops it (a channel pick replaces it)", [S.clearAttachedStream("g-att"), (await S.watch({ ...base("NBA"), id: "g-att" }, null)).plan], [true, "setup"]);
  const rl = await S.watch(base("RLCS", { home: side("1", "Team One", "ONE"), away: side("2", "Team Two", "TWO") }), null);
  r.ok("sports.watch: RLCS plans the official broadcast; Twitch opens its Apple TV app", rl.plan === "broadcast" && rl.broadcasts[0].platform === "twitch" && rl.broadcasts[0].app === "twitch://stream/RocketLeague" && rl.broadcasts[0].platformLabel === "Twitch", JSON.stringify({ plan: rl.plan, label: rl.label, b: rl.broadcasts }));

  // SP-12: the api-sports key lives in the secret tier key and is additive.
  const api0 = S.apiSports();
  r.ok("sports.apiSports lists the four key leagues with no key saved", api0.saved === false && api0.leagues.length === 4, JSON.stringify(api0));
  r.eq("sports.setApiSportsKey saves under the secret-store key and clears", [S.setApiSportsKey(" abc123 ").ok, S.apiSports().length, rec.run('localStorage.getItem("harbor.sports.api-sports.v1")'), S.setApiSportsKey("").ok, S.apiSports().saved], [true, 6, "abc123", true, false]);
  rec.dispose();
}

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

// ------------------------------------------------- account + profile sync (recorded host)
// A fake Harbor: the state GET returns a two-profile roster plus a home-rows doc, the push
// POST accepts everything. Proves the bundle adopts a roster into harbor.profiles.v1, tells the
// host, hydrates, and pushes a settings change with the right doc key.
{
  const events = [];
  const pushes = [];
  const seededSession = JSON.stringify({ token: "tok_smoke", refresh: "ref_smoke", refreshedAt: Date.now(), user: { id: "u_smoke", username: "skipper" } });
  const rec = loadEngine({
    storage: new Map([
      // p_local1 was adopted earlier (id map binds it); p_guest is the auto-seeded bootstrap
      // profile a fresh TV makes before sign-in, which a first pull must drop, not duplicate.
      ["harbor.profiles.v1", JSON.stringify({ activeId: "p_guest", profiles: [
        { id: "p_local1", name: "Me", avatar: null, color: "#60a5fa", isPrimary: true, kid: null, passwordHash: "abc", createdAt: 1000, settingsLinked: true },
        { id: "p_guest", name: "Harbor", avatar: null, color: "#a78bfa", isPrimary: false, kid: null, passwordHash: null, createdAt: 900, settingsLinked: true, bootstrap: true },
      ] })],
      ["harbor.sync.idmap", JSON.stringify({ p_local1: "s_aaa" })],
      ["harbor.auth.p_guest", JSON.stringify({ authKey: "x", user: {} })],
      // (bug pass) Keys only upstream's full purge list names (sessions, history, addons).
      ["harbor.simkl.session.v1.p_guest", JSON.stringify({ token: "s" })],
      ["harbor.watchlist.v1.p_guest", "[]"],
      ["harbor.installed-addons.p_guest", "[]"],
      // The session was stored while the bootstrap profile was active (Settings → Sign in).
      ["harbor.theme-session.p_guest", seededSession],
    ]),
  });
  const SERVER_ROSTER = { profiles: [
    { syncId: "s_aaa", name: "Me", avatar: null, color: "#60a5fa", isPrimary: true, kid: null, hideContent: null, lockedTabs: null, settingsLinked: true, createdAt: 1000, updatedAt: 2000, deletedAt: null },
    { syncId: "s_bbb", name: "Kiddo", avatar: "/kids/avatars/fox.png", color: "#fbbf24", isPrimary: false, kid: { age: 8, curfewMinutes: null }, hideContent: null, lockedTabs: null, settingsLinked: false, createdAt: 1500, updatedAt: 2500, deletedAt: null },
  ] };
  let homeDoc = { rev: 2, value: { order: ["continue", "trending"], hidden: [] } };
  rec.node.host.fetch = async (req) => {
    const json = (body, status = 200) => ({ status, statusText: "OK", headers: { "content-type": "application/json" }, url: req.url, body: JSON.stringify(body) });
    if (req.url.endsWith("/sync/v1/state")) {
      return json({ rev: 7, serverTime: new Date().toISOString(), docs: [
        { key: "account:profiles", rev: 3, at: "", value: SERVER_ROSTER },
        { key: "s_aaa:home", rev: homeDoc.rev, at: "", value: homeDoc.value },
      ] });
    }
    if (req.url.endsWith("/sync/v1/push")) {
      const body = JSON.parse(req.body || "{}");
      pushes.push(body);
      return json({ serverTime: new Date().toISOString(), results: body.writes.map((w, i) => ({ key: w.key, ok: true, rev: 10 + i })) });
    }
    return json({ error: "not_found" }, 404);
  };
  rec.engine.runtime.onEvent((type, detail) => events.push([type, detail]));
  const sess = rec.engine.account.session();
  r.ok("account.session reads upstream's per-profile session key", sess && sess.user.username === "skipper" && sess.hasRefresh === true, JSON.stringify(sess));
  r.eq("sync.status before start", rec.engine.sync.status().phase, "off");
  const pulled = await rec.engine.sync.pullNow();
  r.ok("sync.pullNow succeeds on a first pull", pulled.ok === true && pulled.firstPull === true, JSON.stringify(pulled));
  const blob = JSON.parse(rec.node.storage.get("harbor.profiles.v1"));
  r.ok("roster adopted into harbor.profiles.v1 (2 profiles, local id kept, PIN kept)", blob.profiles.length === 2 && blob.profiles[0].id === "p_local1" && blob.profiles[0].passwordHash === "abc" && blob.profiles[1].name === "Kiddo" && blob.profiles[1].settingsLinked === false, JSON.stringify(blob));
  r.ok("bootstrap profile dropped and its per-profile keys purged", !blob.profiles.some((p) => p.id === "p_guest") && !rec.node.storage.has("harbor.auth.p_guest"), JSON.stringify([...rec.node.storage.keys()].filter((k) => k.includes("p_guest"))));
  r.ok("(bug pass) roster drop purges upstream's whole per-profile key list (Simkl session, watchlist, addons)", !["harbor.simkl.session.v1.p_guest", "harbor.watchlist.v1.p_guest", "harbor.installed-addons.p_guest"].some((k) => rec.node.storage.has(k)), JSON.stringify([...rec.node.storage.keys()].filter((k) => k.includes("p_guest"))));
  r.ok("roster-applied event names the dropped id", events.some(([t, d]) => t === "harbor:roster-applied" && d && d.dropped && d.dropped[0] === "p_guest"));
  r.eq("active profile cleared when the active one was dropped", blob.activeId, null);
  r.ok("account session survives the drop (moved onto the new primary)", rec.engine.account.session() && rec.engine.account.session().user.username === "skipper" && !!rec.node.storage.get("harbor.theme-session.p_local1"), JSON.stringify([...rec.node.storage.keys()].filter((k) => k.startsWith("harbor.theme-session"))));
  const idmap = JSON.parse(rec.node.storage.get("harbor.sync.idmap") || "{}");
  r.eq("id map binds the local id to the server syncId", idmap.p_local1, "s_aaa");
  r.ok("host told: harbor:roster-applied", events.some(([t]) => t === "harbor:roster-applied"), JSON.stringify(events.map(([t]) => t)));
  const home = rec.engine.settings.loadForProfile("p_local1", true);
  r.ok("home rows doc applied into the linked settings blob", home && home.homeRows && Array.isArray(home.homeRows.order) && home.homeRows.order[1] === "trending", JSON.stringify(home && home.homeRows));
  // The viewer picks the adopted profile (what Swift does after who-is-watching), the server
  // moves on, and the next pull lands on the ACTIVE profile: the host must hear about it.
  rec.node.storage.set("harbor.profiles.v1", JSON.stringify({ ...blob, activeId: "p_local1" }));
  rec.engine.runtime.syncStorage("harbor.profiles.v1", rec.node.storage.get("harbor.profiles.v1"));
  rec.engine.runtime.emitEvent("harbor:active-profile-changed", { id: "p_local1" });
  homeDoc = { rev: 3, value: { order: ["trending", "continue", "new"], hidden: ["x"] } };
  const pulled2 = await rec.engine.sync.pullNow();
  r.ok("second pull applies the newer home doc", pulled2.ok && rec.engine.settings.loadForProfile("p_local1", true).homeRows.order[2] === "new", JSON.stringify(pulled2));
  r.ok("host told: harbor:settings-updated for the active profile", events.some(([t, d]) => t === "harbor:settings-updated" && d && d.profileId === "p_local1" && d.fields.includes("homeRows")), JSON.stringify(events.filter(([t]) => t === "harbor:settings-updated")));
  // A local edit to a synced field goes up with the right key.
  rec.engine.sync.start();
  rec.engine.settings.patch({ homeRows: { order: ["continue", "trending", "new"], hidden: [] } }, rec.engine.settings.sourceKeyFor("p_local1", true));
  rec.engine.sync.pushNow();
  await new Promise((res) => setTimeout(res, 200));
  const sent = pushes.flatMap((p) => p.writes);
  r.ok("settings.patch on homeRows pushed s_aaa:home at baseRev 3", sent.some((w) => w.key === "s_aaa:home" && w.baseRev === 3 && w.value && w.value.order[0] === "continue"), JSON.stringify(sent.map((w) => [w.key, w.baseRev])));
  r.ok("no roster re-push when unchanged (sent-hash suppression)", !sent.some((w) => w.key === "account:profiles"), JSON.stringify(sent.map((w) => w.key)));
  r.ok("sync status reached idle with a pull time", rec.engine.sync.status().phase === "idle" && rec.engine.sync.status().lastPullAt > 0, JSON.stringify(rec.engine.sync.status()));
  rec.engine.sync.stop();
  rec.engine.account.stop();
  rec.dispose();
}

// ------------------------------------------- TV hand-off: account.adopt (recorded host)
{
  const rec = loadEngine({ storage: new Map([
    ["harbor.profiles.v1", JSON.stringify({ activeId: "default", profiles: [{ id: "default", isPrimary: true }] })],
  ]) });
  const seen = [];
  rec.node.host.fetch = async (req) => {
    seen.push([req.url, JSON.stringify(req.headers || {})]);
    const json = (body, status = 200) => ({ status, statusText: status === 200 ? "OK" : "Unauthorized", headers: { "content-type": "application/json" }, url: req.url, body: JSON.stringify(body) });
    if (req.url.endsWith("/identity/api/me")) {
      return JSON.stringify(req.headers || {}).includes("tok_phone")
        ? json({ user: { id: "u_phone", username: "deckhand", handle: "deckhand" } })
        : json({ error: "unauthorized" }, 401);
    }
    return json({ error: "not_found" }, 404);
  };
  const adopted = await rec.engine.account.adopt("tok_phone", "deckhand", "ref_phone");
  r.ok("account.adopt applies the phone's session with the server's user", adopted && adopted.user.id === "u_phone" && adopted.token === "tok_phone" && adopted.hasRefresh === true, JSON.stringify(adopted));
  r.ok("account.adopt asked /identity/api/me with the delivered bearer", seen.some(([u, h]) => u.endsWith("/themes/api/identity/api/me") && h.includes("Bearer tok_phone")), JSON.stringify(seen));
  const refused = await rec.engine.account.adopt("tok_bad", "deckhand", null).then(() => "applied", (e) => String(e && e.message));
  r.ok("account.adopt refuses a token that does not resolve to a user", refused.includes("harbor-api:") && refused.includes("401"), refused);
  r.ok("a refused adopt leaves the earlier session in place", rec.engine.account.session() && rec.engine.account.session().user.id === "u_phone");
  rec.dispose();
}

// ------------------------------------------------------------------------- anime4k
{
  r.eq("anime4k.files lists the 11 shaders", engine.anime4k.files().length, 11);
  r.ok("anime4k.files urls point at bloc97/Anime4K glsl", engine.anime4k.files().every((f) => f.url.startsWith("https://raw.githubusercontent.com/bloc97/Anime4K/master/glsl/") && f.local.endsWith(".glsl")));
  const offDefault = engine.anime4k.choose("default", true, { id: "kitsu:1", genres: ["Anime"] }, 1920, 3840);
  r.eq("anime4k.choose is off until playerAnime4k is on (upstream default)", offDefault.active, false);
  engine.settings.patch({ playerAnime4k: true });
  const a = engine.anime4k.choose("default", true, { id: "kitsu:1", genres: ["Anime"] }, 1920, 3840);
  r.ok("anime4k.choose auto → mode A hq chain for anime", a.active && a.mode === "A" && a.tier === "hq" && a.files[0] === "Anime4K_Clamp_Highlights.glsl" && a.files.includes("Anime4K_Restore_CNN_VL.glsl") && a.files.length === 6, JSON.stringify(a));
  const notAnime = engine.anime4k.choose("default", true, { id: "tt0111161", genres: ["Drama"] }, 1920, 3840);
  r.eq("anime4k.choose auto skips non-anime when AnimeOnly", notAnime.active, false);
  engine.settings.patch({ playerAnime4kMode: "AA", playerAnime4kTier: "fast" });
  const gated = engine.anime4k.choose("default", true, { id: "kitsu:1" }, 3840, 3840);
  r.ok("anime4k.choose drops the secondary pass at display width (AA → A) and honours fast tier", gated.mode === "A" && gated.tier === "fast" && gated.files.includes("Anime4K_Restore_CNN_M.glsl"), JSON.stringify(gated));
  engine.settings.patch({ playerAnime4kOverride: "C" });
  r.eq("anime4k.choose override C wins over auto", engine.anime4k.choose("default", true, { id: "tt1", genres: [] }, 1920, 3840).mode, "C");
  engine.settings.patch({ playerAnime4k: false, playerAnime4kMode: "A", playerAnime4kTier: "hq", playerAnime4kOverride: "auto" });
}

// ------------------------------------------------------------------------ detail room
{
  const none = await engine.detailRoom.extras({ id: "tt0111161", type: "movie", name: "The Shawshank Redemption" }, "default", true);
  r.eq("detailRoom.extras is null without a TMDB key", none, null);
  {
    const clips = engine.detailRoom.videoClips(["aaa", "bbb", "aaa"], [{ ytId: "bbb", name: "Dup", type: "Clip" }, { ytId: "ccc", name: "", type: "Featurette" }]);
    r.eq("detailRoom.videoClips: other trailers first, deduped, names fall back to type", clips.map((c) => [c.ytId, c.name, c.type]), [["bbb", "Trailer", "Trailer"], ["aaa", "Trailer", "Trailer"], ["ccc", "Featurette", "Featurette"]]);
  }
  r.eq("detailRoom.collection is null without a TMDB key", await engine.detailRoom.collection(10, "default", true), null);
}

// ------------------------------------------- detail hero actions, picker outcomes, still ladder
// DT-3 (use-bp-detail-actions state + writes), DT-6/DT-7 (remembered pick, resolve copy, P2P
// gate), DT-11 (use-bp-episode-art ladder) on a recording host: nothing leaves the machine.
{
  const rec = loadEngine({ storage: new Map([["harbor.profiles.v1", JSON.stringify({ activeId: "default", profiles: [{ id: "default", isPrimary: true }] })]]) });
  const artHits = [];
  rec.node.host.fetch = async (req) => {
    artHits.push(req.url);
    const json = (body) => ({ status: 200, statusText: "OK", headers: { "content-type": "application/json" }, url: req.url, body: JSON.stringify(body) });
    if (req.url.includes("/api/tvdb/images")) return json({ images: { s1e2: "https://artworks.thetvdb.com/banners/episodes/1/2.jpg" } });
    if (req.url.includes("ani.zip")) return json({ episodes: { "2": { seasonNumber: 1, episodeNumber: 2, image: "https://img.anizip.example/2.jpg" } }, mappings: { imdb_id: "tt0903747" } });
    return { status: 404, statusText: "Not Found", headers: {}, url: req.url, body: "" };
  };
  const e = rec.engine;
  const film = { id: "tt0111161", type: "movie", name: "The Shawshank Redemption", poster: "https://example.invalid/p.jpg" };
  const show = { id: "tt0903747", type: "series", name: "Breaking Bad" };
  const hs = e.actions.heroState(film, "tt0111161", "default", true);
  r.eq("actions.heroState: a fresh movie", [hs.favorite, hs.reminder, hs.watchedLocal, hs.traktMovie, hs.showWatchedButton, hs.rating], [false, false, false, false, true, null]);
  r.eq("actions.toggleFavorite adds then removes", [e.actions.toggleFavorite(film, "tt0111161", "default"), e.actions.heroState(film, null, "default", true).favorite, e.actions.toggleFavorite(film, "tt0111161", "default")], [true, true, false]);
  r.eq("actions.toggleReminder on a series (heroState follows)", [e.actions.toggleReminder(show), e.actions.heroState(show, null, "default", true).reminder, e.actions.toggleReminder(show), e.actions.heroState(film, null, "default", true).reminder], [true, true, false, false]);
  r.eq("actions.trackers without a Simkl/AniList/MAL session", await e.actions.trackers({ id: "kitsu:1", type: "anime", name: "Cowboy Bebop" }, false), []);
  r.eq("actions.traktMarkWatched without a Trakt session", await e.actions.traktMarkWatched("tt0111161"), false);
  r.eq("streamsRoom.remembered with an unknown token", e.streamsRoom.remembered("nope", "default", true, film, null, null), null);
  r.eq("streamsRoom.p2pConsentNeeded with an unknown token", e.streamsRoom.p2pConsentNeeded("nope", "default", true, 0, false), false);
  r.ok("streamsRoom.failureMessage carries picker-utils copy", /isn't cached on your debrid/.test(e.streamsRoom.failureMessage("not-cached") ?? "") && e.streamsRoom.failureMessage("some-new-code") === null, e.streamsRoom.failureMessage("not-cached"));
  const miss = await e.streamsRoom.resolve("default", true, "nope", 0, true);
  r.eq("streamsRoom.resolve of an unknown stream carries message + debridFailure", [miss.ok, miss.code, miss.message, miss.debridFailure], [false, "no-such-stream", null, false]);
  const art = await e.detailRoom.episodeArt(show, 1, [
    { key: "a", season: 1, episode: 1, still: "https://example.invalid/s1e1.jpg" },
    { key: "b", season: 1, episode: 2 },
  ], "default", true);
  r.ok("detailRoom.episodeArt: the meta's still leads an episode no provider has, metahub last", art.a[0] === "https://example.invalid/s1e1.jpg" && /episodes\.metahub\.space\/tt0903747\/1\/1\//.test(art.a[art.a.length - 1]), JSON.stringify(art.a));
  r.ok("detailRoom.episodeArt: TVDB proxy before ani.zip before metahub for a gap", /thetvdb/.test(art.b[0]) && art.b[1] === "https://img.anizip.example/2.jpg" && /metahub/.test(art.b[2]) && art.b.length === 3, JSON.stringify(art.b));
  rec.dispose();
}

// ------------------------------------------------ P2P handoff to the TV's torrent engine (Stage 6)
// resolveStream's local-engine attempt has no Tauri here; the outcome carries a P2pPlan instead.
{
  const base = "https://torrents.example.invalid";
  const manifest = { id: "org.example.torrents", version: "1.0.0", name: "Torrents", resources: ["stream"], types: ["movie"], idPrefixes: ["tt"], catalogs: [] };
  const hash = "0123456789abcdef0123456789abcdef01234567";
  const rec = loadEngine({ storage: new Map([
    ["harbor.profiles.v1", JSON.stringify({ activeId: "default", profiles: [{ id: "default", isPrimary: true }] })],
    ["harbor.installed-addons.default", JSON.stringify([{ transportUrl: `${base}/manifest.json`, manifest }])],
  ]) });
  rec.node.host.fetch = async (req) => {
    const json = (body) => ({ status: 200, statusText: "OK", headers: { "content-type": "application/json" }, url: req.url, body: JSON.stringify(body) });
    if (req.url === `${base}/manifest.json`) return json(manifest);
    if (req.url.startsWith(`${base}/stream/movie/tt0111161`)) return json({ streams: [
      { name: "Torrents\n1080p", title: "The.Shawshank.Redemption.1994.1080p.BluRay.x264-GRP\n👤 42 💾 2.1 GB", infoHash: hash, fileIdx: 1, sources: [`tracker:udp://tracker.example.invalid:1337/announce`, `dht:${hash}`] },
    ] });
    return { status: 404, statusText: "Not Found", headers: {}, url: req.url, body: "" };
  };
  const e = rec.engine;
  const film = { id: "tt0111161", type: "movie", name: "The Shawshank Redemption" };
  const found = await e.streamsRoom.search("p2p", "default", true, null, film, null);
  const idx = (found.result?.picker.all ?? []).findIndex((s) => s.infoHash === hash);
  r.ok("P2P: the addon's torrent reaches the picker", idx >= 0, JSON.stringify(found.result?.picker.all?.map((s) => s.infoHash) ?? found.error));
  if (idx >= 0) {
    r.eq("P2P: an uncached torrent with no debrid asks for consent", e.streamsRoom.p2pConsentNeeded("p2p", "default", true, idx, false), true);
    r.eq("P2P: a kid profile never asks", e.streamsRoom.p2pConsentNeeded("p2p", "default", true, idx, true), false);
    const out = await e.streamsRoom.resolve("default", true, "p2p", idx, true, true);
    r.ok("P2P: resolve hands the torrent to the TV engine with a plan", out.ok === false && out.code === "engine-not-ready" && out.p2p?.infoHash === hash && out.p2p.fileIdx === 1 && out.p2p.trackers[0] === "udp://tracker.example.invalid:1337/announce" && out.p2p.magnet === `magnet:?xt=urn:btih:${hash}` && out.p2p.debridFallback === false, JSON.stringify(out));
    const plain = await e.streamsRoom.resolve("default", true, "p2p", idx, true, false);
    r.ok("P2P: the no-debrid fallback carries the plan too", plain.ok === false && plain.p2p?.infoHash === hash, JSON.stringify(plain));
    e.settings.patch({ torrentsDisabled: true });
    const off = await e.streamsRoom.resolve("default", true, "p2p", idx, true, true);
    r.ok("P2P: torrentsDisabled leaves no plan and no consent", off.ok === false && off.p2p === undefined && e.streamsRoom.p2pConsentNeeded("p2p", "default", true, idx, false) === false, JSON.stringify(off));
    e.settings.patch({ torrentsDisabled: false, directTorrentStream: false });
    const direct = await e.streamsRoom.resolve("default", true, "p2p", idx, true, false);
    r.ok("P2P: directTorrentStream off leaves no plan", direct.ok === false && direct.p2p === undefined, JSON.stringify(direct));
    e.settings.patch({ directTorrentStream: true });
  }
  e.settings.patch({ customStreamFilters: [{ id: "hd", name: "1080p", resolution: ["1080p"] }, { id: "uhd", name: "4K", resolution: ["4K"] }, { id: "seeded", name: "Seeded", minSeeders: 100 }] });
  const stamped = (await e.streamsRoom.search("rows", "default", true, null, film, null)).result?.picker.all.find((s) => s.infoHash === hash);
  r.ok("streamsRoom.search stamps each row's text (pictographs gone, first title line as filename)", stamped?.tvRow?.filename === "The.Shawshank.Redemption.1994.1080p.BluRay.x264-GRP" && stamped.tvRow.description.split("\n")[1] === "42 2.1 GB" && stamped.tvRow.detail.includes("42 2.1 GB"), JSON.stringify(stamped?.tvRow));
  r.eq("streamsRoom.search stamps the saved filters each stream passes", stamped?.tvFilters, ["hd"]);
  e.settings.patch({ customStreamFilters: [] });
  // Bug pass: a search superseded on the same token answers "aborted" and leaves the newer
  // search's results (which resolve / deadRef index into) alone.
  {
    let calls = 0;
    const prev = rec.node.host.fetch;
    rec.node.host.fetch = async (req) => {
      if (req.url.startsWith(`${base}/stream/movie/tt0111161`)) {
        calls += 1;
        if (calls === 1) await new Promise((res) => setTimeout(res, 300));
      }
      return prev(req);
    };
    const older = e.streamsRoom.search("race", "default", true, null, film, null);
    await new Promise((res) => setTimeout(res, 20));
    const newer = await e.streamsRoom.search("race", "default", true, null, film, null, { strictMode: false });
    const old = await older;
    r.ok("streamsRoom.search: the superseded search answers aborted, the newer keeps the token's results", old.error === "aborted" && old.result === null && newer.result?.picker.all.length > 0 && e.streamsRoom.deadRef("race", 0) !== null, JSON.stringify({ old: old.error, newer: newer.result?.picker.all.length }));
    rec.node.host.fetch = prev;
  }
  const files = [{ idx: 0, name: "sample.mkv", length: 10 }, { idx: 1, name: "Show.S01E02.1080p.mkv", length: 900 }, { idx: 2, name: "Show.S01E03.1080p.mkv", length: 1000 }, { idx: 3, name: "info.nfo", length: 5000 }];
  r.eq("P2P: p2pFileIdx picks the episode's file, else the largest video", [e.streamsRoom.p2pFileIdx(files, 1, 2), e.streamsRoom.p2pFileIdx(files, null, null), e.streamsRoom.p2pFileIdx([{ idx: 0, name: "a.nfo", length: 3 }], 1, 1)], [1, 2, 0]);
  rec.dispose();
}

// ------------------------------------- dead streams (lib/dead-streams, views/player.tsx stall skip)
{
  const base = "https://direct.example.invalid";
  const manifest = { id: "org.example.direct", version: "1.0.0", name: "Direct", resources: ["stream"], types: ["movie"], idPrefixes: ["tt"], catalogs: [] };
  const hash = "89abcdef0123456789abcdef0123456789abcdef";
  const rec = loadEngine({ storage: new Map([
    ["harbor.profiles.v1", JSON.stringify({ activeId: "default", profiles: [{ id: "default", isPrimary: true }] })],
    ["harbor.installed-addons.default", JSON.stringify([{ transportUrl: `${base}/manifest.json`, manifest }])],
  ]) });
  rec.node.host.fetch = async (req) => {
    const json = (body) => ({ status: 200, statusText: "OK", headers: { "content-type": "application/json" }, url: req.url, body: JSON.stringify(body) });
    if (req.url === `${base}/manifest.json`) return json(manifest);
    if (req.url.startsWith(`${base}/stream/movie/tt0111161`)) return json({ streams: [
      { name: "Direct\n1080p", title: "The.Shawshank.Redemption.1994.1080p.WEB-DL.x264-AAA\n💾 2.1 GB", url: "https://cdn.example.invalid/a.mp4" },
      { name: "Direct\n720p", title: "The.Shawshank.Redemption.1994.720p.WEB-DL.x264-BBB\n💾 1.1 GB", url: "https://cdn.example.invalid/b.mp4" },
      { name: "Direct\n1080p", title: "The.Shawshank.Redemption.1994.1080p.BluRay.x264-CCC\n💾 2.4 GB", url: "https://cdn.example.invalid/c.mp4", infoHash: hash, fileIdx: 2 },
    ] });
    return { status: 404, statusText: "Not Found", headers: {}, url: req.url, body: "" };
  };
  const e = rec.engine;
  const film = { id: "tt0111161", type: "movie", name: "The Shawshank Redemption", runtime: "142 min" };
  const found = await e.streamsRoom.search("dead", "default", true, null, film, null);
  const all = found.result?.picker.all ?? [];
  const at = (tag) => all.findIndex((s) => (s.url ?? "").endsWith(`/${tag}.mp4`));
  const [ia, ib, ic] = [at("a"), at("b"), at("c")];
  const auto = () => e.streamsRoom.autoCandidates("dead", "default", true, film, null, null, false, null);
  r.ok("dead streams: the three direct links are auto candidates", ia >= 0 && ib >= 0 && ic >= 0 && [ia, ib, ic].every((i) => auto().includes(i)), JSON.stringify({ all: all.map((s) => s.url), auto: auto() }));
  const refA = e.streamsRoom.deadRef("dead", ia), refC = e.streamsRoom.deadRef("dead", ic);
  r.ok("streamsRoom.deadRef carries what dead-streams fingerprints (url, infoHash + fileIdx, addon, title)", refA?.url === "https://cdn.example.invalid/a.mp4" && refA.infoHash === null && refA.addonId === manifest.id && typeof refA.title === "string" && refC?.infoHash === hash && refC.fileIdx === 2, JSON.stringify({ refA, refC }));
  r.eq("streamsRoom.deadRef with an unknown token or index", [e.streamsRoom.deadRef("nope", 0), e.streamsRoom.deadRef("dead", 99)], [null, null]);
  r.eq("deadStreams.markDead refuses a ref with nothing to fingerprint", [e.deadStreams.markDead(null), e.deadStreams.markDead({ addonId: "x" })], [false, false]);
  r.eq("deadStreams.isDead before any mark", e.deadStreams.isDead(refA), false);
  r.eq("deadStreams.markDead (the player's stall / load-failed skip)", e.deadStreams.markDead(refA, "load-failed"), true);
  r.ok("the picker's auto candidates skip the stalled stream, the rest stay in order", !auto().includes(ia) && auto().includes(ib) && auto().includes(ic) && e.deadStreams.isDead(refA), JSON.stringify(auto()));
  const stored = JSON.parse(rec.node.storage.get("harbor.dead-streams.v1") ?? "{}");
  r.ok("the mark is stored under harbor.dead-streams.v1 with the 4 h stub TTL", stored["u:https://cdn.example.invalid/a.mp4"]?.reason === "load-failed" && stored["u:https://cdn.example.invalid/a.mp4"].ttl === 4 * 60 * 60 * 1000, JSON.stringify(stored));
  e.deadStreams.markDead(refC);
  r.ok("a torrent-backed stream is marked by infoHash + fileIdx and skipped too", !auto().includes(ic) && e.deadStreams.isDead({ infoHash: hash.toUpperCase(), fileIdx: 2 }) && !e.deadStreams.isDead({ infoHash: hash, fileIdx: 3 }), JSON.stringify(auto()));
  const stub = (over) => e.deadStreams.flagStub({ meta: film, url: "https://cdn.example.invalid/b.mp4", title: film.name, ref: e.streamsRoom.deadRef("dead", ib), durationSec: 42, playing: true, season: null, episode: null, ...over });
  r.eq("deadStreams.flagStub: not a stub when long, paused, HLS, a channel or a short film", [
    stub({ durationSec: 200 }), stub({ playing: false }), stub({ url: "https://cdn.example.invalid/b.m3u8" }),
    stub({ meta: { ...film, id: "iptv:1" } }), stub({ meta: { ...film, type: "tv" } }), stub({ meta: { ...film, runtime: "1 min" } }),
  ], [false, false, false, false, false, false]);
  r.eq("deadStreams.consumeStubEvent: nothing recorded yet", e.deadStreams.consumeStubEvent(8000), null);
  e.streamsRoom.rememberPlayback("dead", "default", true, film, ib, "https://cdn.example.invalid/b.mp4", null, null);
  r.eq("the stub's stream was the remembered pick", e.streamsRoom.remembered("dead", "default", true, film, null, null), ib);
  r.eq("deadStreams.flagStub: a 42 s file of a 142 min film is a stub", stub({}), true);
  r.ok("the stub is marked dead, its remembered pick forgotten, and no auto candidate is left", !auto().includes(ib) && auto().length === 0 && e.streamsRoom.remembered("dead", "default", true, film, null, null) === null, JSON.stringify({ auto: auto() }));
  r.eq("deadStreams.consumeStubEvent: the next picker reads the stub once", [e.deadStreams.consumeStubEvent(8000), e.deadStreams.consumeStubEvent(8000)], ["stub_42s", null]);
  e.deadStreams.clear();
  r.ok("deadStreams.clear brings every stream back", [ia, ib, ic].every((i) => auto().includes(i)) && !e.deadStreams.isDead(refA), JSON.stringify(auto()));
  rec.dispose();
}

// ----------------------------------------------------------------------- home servers
{
  r.eq("homeServers.connections empty", await engine.homeServers.connections(), []);
  // bp-stream-row.tsx: plainLine / detailLine / torrentFilename for the TV's rows.
  const rowText = engine.streamsRoom.pickerRowText({ name: "", title: "\u{1F525} Line one\n\u{1F464} 12  \u{1F4BE}\nLine one", addonId: "x", addonName: "X", audio: { codec: "Other", channels: 2 }, codec: "Other", size: null, seeders: null, hdrFormat: null, audioLanguages: [], behaviorHints: { filename: "Movie.2020.mkv" } }, "Movie", null);
  r.eq("streamsRoom.pickerRowText: glyphs dropped, lines deduped, filename from behaviorHints", rowText, { headline: "Movie.2020.mkv", detail: "Line one · 12", description: "Line one\n12\nLine one", filename: "Movie.2020.mkv" });
  // bp-stream-filters.ts customStreamFilters / activeStreamFilterId.
  r.eq("streamsRoom.streamFilters: none saved", engine.streamsRoom.streamFilters("default", true), { filters: [], activeId: null });
  engine.settings.patch({ customStreamFilters: [{ id: "f4k", name: " 4K only ", resolution: ["4K"] }, { id: "fany", name: "Anything" }], activeStreamFilterId: "gone" });
  r.eq("streamsRoom.streamFilters: saved filters, a dangling active id reads as none", engine.streamsRoom.streamFilters("default", true), { filters: [{ id: "f4k", name: "4K only", empty: false }, { id: "fany", name: "Anything", empty: true }], activeId: null });
  r.eq("streamsRoom.setActiveStreamFilter: an unknown id clears it", engine.streamsRoom.setActiveStreamFilter("default", true, "bogus"), null);
  r.eq("streamsRoom.setActiveStreamFilter: a saved id sticks", [engine.streamsRoom.setActiveStreamFilter("default", true, "f4k"), engine.settings.load().activeStreamFilterId, engine.streamsRoom.streamFilters("default", true).activeId], ["f4k", "f4k", "f4k"]);
  engine.settings.patch({ customStreamFilters: [], activeStreamFilterId: null });
  r.eq("homeServers.copies without connections", await engine.homeServers.copies({ id: "tt0111161", type: "movie", name: "x" }, "tt0111161"), []);
  r.eq("homeServers.titles empty", await engine.homeServers.titles(), []);
  // bp-streams.tsx applyPreference + playback-policy.ts decidePlaybackSource.
  const pref = (copies) => engine.homeServers.preferredSource("default", true, copies);
  const one = [{ key: "k1", connectionId: "c1" }], two = [{ key: "k1", connectionId: "c1" }, { key: "k2", connectionId: "c2" }];
  r.eq("homeServers.preferredSource: online preference leaves the list alone", await pref(two), { action: "none" });
  const commitPref = (id, v) => engine.settingsRoom.commit(id, v, "default", true);
  commitPref("playbackSource", "local");
  r.eq("settingsRoom.commit playbackSource sticks across loads (migration flags kept)", [engine.settings.loadForProfile("default", true).playbackSourcePreference, engine.settings.loadForProfile("default", true).playbackSourcePreference], ["local", "local"]);
  r.eq("homeServers.preferredSource: local with no Local Library shows everything", await pref(two), { action: "show-all" });
  // Review 29: the TV has no Local Library, so the row drops it and a synced "local" reads as Ask.
  const psRow = engine.settingsRoom.controls("playback", "default", true).find((c) => c.id === "playbackSource");
  r.eq("settingsRoom.controls(playback): no Local Library option on the TV; a synced local shows as Ask", [psRow?.options.map((o) => o.value), psRow?.value, engine.settings.loadForProfile("default", true).playbackSourcePreference], [["ask", "online", "home-server"], "ask", "local"]);
  r.ok("settingsRoom.pane: a synced local reads as Ask every time", engine.settingsRoom.pane("default", true).playback.some(([k, v]) => k === "Play button behavior" && v === "Ask every time"));
  commitPref("playbackSource", "home-server"); commitPref("preferredMediaServer", "");
  r.eq("homeServers.preferredSource: home server, no preferred server → the Media servers list", await pref(one), { action: "show-media-server" });
  r.eq("homeServers.preferredSource: home server, no copy of this title → every source", await pref([]), { action: "show-all" });
  commitPref("preferredMediaServer", "c2");
  r.eq("homeServers.preferredSource: the preferred server's one copy plays", await pref(two), { action: "play", copyKey: "k2" });
  r.eq("homeServers.preferredSource: two copies on the preferred server → ask", await pref([...two, { key: "k3", connectionId: "c2" }]), { action: "none" });
  r.eq("homeServers.preferredSource: the preferred server has no copy → ask", await pref(one), { action: "none" });
  // Review 29: bp-streams availableHomeServerCopies — a server known offline never auto-plays.
  engine.homeServers.markInactive("c2");
  r.eq("homeServers.preferredSource: the preferred server is offline → no auto-play", await pref(two), { action: "none" });
  commitPref("playbackSource", "ask");
  r.eq("homeServers.preferredSource: ask never plays by itself", await pref(two), { action: "none" });
  commitPref("playbackSource", "online"); commitPref("preferredMediaServer", "");
  const qo = engine.homeServers.qualityOptions("nope", "x");
  r.ok("homeServers.qualityOptions: MEDIA_SERVER_QUALITIES, Original when nothing plays", qo.current === "original" && qo.options.length === 7 && qo.options[0].id === "original" && qo.options[0].label === "Original" && qo.options[4].id === "720p-4", JSON.stringify(qo));
  const sq = await engine.homeServers.switchQuality("nope", "x", null, "720p-4", 1000, true, null).then(() => "ok", (e) => e.message);
  r.eq("homeServers.switchQuality: a copy that is gone says so", sq, "This home-server copy is no longer available.");
  r.eq("streamsRoom.autoCandidates with an unknown token", engine.streamsRoom.autoCandidates("nope", "default", true, { id: "tt1", type: "movie", name: "x" }, null, null, false, null), []);
  r.eq("streamsRoom.rememberPlayback with an unknown token", engine.streamsRoom.rememberPlayback("nope", "default", true, { id: "tt1", type: "movie", name: "x" }, 0, null, null, null), false);
  const lid = engine.actions.newList("Smoke list");
  r.ok("actions.newList creates a list", typeof lid === "string" && engine.actions.lists(null).some((l) => l.id === lid), JSON.stringify(engine.actions.lists(null)));
  r.eq("actions.toggleList adds a title", engine.actions.toggleList(lid, { id: "tt0111161", type: "movie", name: "Shawshank" }), true);
  r.eq("actions.lists reports membership", engine.actions.lists("tt0111161").find((l) => l.id === lid).contains, true);
  engine.actions.removeList(lid);
  r.eq("actions.rating unknown item", engine.actions.rating("tt0000009"), null);
  r.eq("actions.animeRows before any room build", engine.actions.animeRows("default", true), []);
  const ac = await engine.addonsRoom.cards(null, false);
  r.ok("addonsRoom.cards lists installed addons as cards", Array.isArray(ac) && ac.every((c) => typeof c.base === "string" && typeof c.name === "string"), JSON.stringify(ac.map((c) => c.name)));
  r.eq("addonsRoom.catalogs for an unknown base", await engine.addonsRoom.catalogs("https://nowhere.invalid"), []);
  const hm = await engine.animeRoom.heroMeta({ id: "tt0388629", type: "anime", name: "One Piece", releaseInfo: "1999", imdbRating: "9.0" }, "default", true, { season: 1, episode: 3 });
  r.ok("animeRoom.heroMeta falls back to the inline score and formats the episode", hm.score === "9.0" && hm.episode === "S1 E3", JSON.stringify(hm));
  const cwx = await engine.rooms.continueWatchingWithExtras("default", true, null);
  r.ok("rooms.continueWatchingWithExtras attaches _cw to every item", Array.isArray(cwx) && cwx.every((i) => i._cw && typeof i._cw.watched === "boolean"), JSON.stringify(cwx.length));
  r.eq("animeDetail.load ignores a non-anime id", await engine.animeDetail.load({ id: "tt0111161", type: "movie", name: "x" }, "default", true), null);
  r.eq("collectionsRoom.tmdb without a TMDB key", await engine.collectionsRoom.tmdb("default", true, "All", 1), { cards: [], done: true });
  r.ok("collectionsRoom.categories starts with All", engine.collectionsRoom.categories()[0] === "All" && engine.collectionsRoom.categories().includes("Sagas"), JSON.stringify(engine.collectionsRoom.categories()));
  r.eq("live.toggleChannelPin pins and unpins", [engine.live.toggleChannelPin("src::ch1"), engine.live.toggleChannelPin("src::ch1")], [true, false]);
  r.eq("live.toggleGroupHidden hides then shows a group", [engine.live.toggleGroupHidden("src", "News"), engine.live.toggleGroupHidden("src", "News")], [["News"], []]);
  const xt = engine.live.addStructured("xtream", "Smoke Xtream", "", "", "http://xt.example.invalid", "user", "pass");
  r.ok("live.addStructured builds an Xtream playlist", xt.kind === "xtream" && /get\.php/.test(xt.url) && xt.xtream.username === "user", JSON.stringify(xt));
  engine.live.removePlaylist(xt.id);
  const aw2 = await engine.detailRoom.awards({ id: "kitsu:1", type: "anime", name: "Cowboy Bebop", releaseInfo: "1998" });
  r.ok("detailRoom.awards answers without an imdb id", aw2 && Array.isArray(aw2.groups) && Array.isArray(aw2.entries), JSON.stringify(aw2.groups));
  r.ok("sports.teamLeagues keeps team sports only", engine.sports.teamLeagues(["nba", "ufc"]).every((l) => l.key !== "ufc"), JSON.stringify(engine.sports.teamLeagues(["nba", "ufc"])));
  r.eq("sports.favouriteTeams starts empty", engine.sports.favouriteTeams(), []);
  r.eq("live.homeRow without playlists", await engine.live.homeRow(), { playlistId: null, cells: [] });
  r.eq("onboarding.vote records an upvote", engine.onboarding.vote("tt0000001", true, "Smoke", "movie").includes("tt0000001"), true);
  r.eq("onboarding.vote clears it again", engine.onboarding.vote("tt0000001", false, "Smoke", "movie").includes("tt0000001"), false);
  r.eq("live.loadShortEpg ignores a non-Xtream playlist", await engine.live.loadShortEpg("nope", ["a"]), { hydrated: 0 });
  r.eq("discoverRoom.genrePage without a TMDB key", (await engine.discoverRoom.genrePage("default", true, "Action", 1)).status, "no-key");
  r.eq("search.fanOut with an empty query", (await engine.search.fanOut("  ", "default", true, null)).movies, []);
  // Search: TVDB collection hits (use-collection-hits) and one hydrated collection (bp-collection).
  r.eq("search.collections skips queries under three characters", await engine.search.collections("st"), []);
  {
    const rec = loadEngine({});
    const seen = [];
    rec.node.host.fetch = async (req) => {
      seen.push(req.url);
      const json = (data) => ({ status: 200, statusText: "OK", headers: { "content-type": "application/json" }, url: req.url, body: JSON.stringify({ data }) });
      if (req.url.includes("/api/tvdb/v4/search?query=star%20wars&type=list")) return json([{ tvdb_id: "101", name: "Star Wars Collection", image_url: "/lists/101.jpg", overview: "A galaxy." }, { name: "no id" }]);
      if (req.url.endsWith("/api/tvdb/v4/lists/101/extended")) return json({ id: 101, name: "Star Wars Collection", overview: "A galaxy.", image: null, entities: [{ seriesId: 7, order: 2 }, { movieId: 5, order: 1 }] });
      if (req.url.endsWith("/api/tvdb/v4/movies/5/extended")) return json({ name: "A New Hope", image: "/p/5.jpg", year: 1977, remoteIds: [{ id: "tt0076759" }] });
      if (req.url.endsWith("/api/tvdb/v4/series/7/extended")) return json({ name: "Andor", image: null, year: "2022", remoteIds: [] });
      return { status: 404, statusText: "Not Found", headers: {}, url: req.url, body: "" };
    };
    const hits = await rec.engine.search.collections("Star Wars");
    r.eq("search.collections maps TVDB list hits (absolute art, rows without an id dropped)", hits, [{ id: 101, name: "Star Wars Collection", image: "https://artworks.thetvdb.com/lists/101.jpg", overview: "A galaxy." }]);
    const card = await rec.engine.search.collection(101, "Star Wars", hits[0].image);
    r.ok("search.collection hydrates entries in list order (imdb id, else tvdb:kind:id)", card && card.key === "tvdb:101" && card.count === 2 && card.image === hits[0].image
      && JSON.stringify(card.items) === JSON.stringify([{ id: "tt0076759", type: "movie", name: "A New Hope", poster: "https://artworks.thetvdb.com/p/5.jpg" }, { id: "tvdb:series:7", type: "series", name: "Andor", poster: null }]), JSON.stringify(card));
    r.eq("search.collection is null when TVDB has no such list", await rec.engine.search.collection(999, "Gone", null), null);
    rec.dispose();
  }
  r.eq("libraryRoom.tabs hides Media Servers without connections", engine.libraryRoom.tabs().some((t) => t.id === "media-servers"), false);
  const rec = loadEngine({ storage: new Map([["harbor.profiles.v1", JSON.stringify({ activeId: "p1", profiles: [{ id: "p1", isPrimary: true }] })]]) });
  const calls = [];
  let approved = false;
  rec.node.host.fetch = async (req) => {
    calls.push(req.url);
    const json = (body, status = 200) => ({ status, statusText: "OK", headers: { "content-type": "application/json" }, url: req.url, body: JSON.stringify(body) });
    if (req.url === "https://plex.tv/api/v2/pins?strong=true") return json({ id: 77, code: "ABCD", expiresAt: new Date(Date.now() + 300000).toISOString() });
    if (req.url === "https://plex.tv/api/v2/pins/77") return json({ id: 77, code: "ABCD", authToken: approved ? "tok" : null });
    if (req.url.startsWith("https://plex.tv/api/v2/resources")) return json([{ name: "Den", provides: "server", owned: true, presence: true, accessToken: "srvtok", clientIdentifier: "srv1", connections: [{ uri: "https://10-0-0-5.x.plex.direct:32400", local: true, relay: false }] }]);
    if (req.url.startsWith("https://10-0-0-5.x.plex.direct:32400/library/sections")) return json({ MediaContainer: { Directory: [] } });
    return json({ error: "not_found" }, 404);
  };
  const pin = await rec.engine.homeServers.plexPinStart();
  r.ok("homeServers.plexPinStart returns the code and the link", pin.pinId === 77 && pin.code === "ABCD" && /app\.plex\.tv\/auth#\?clientID=/.test(pin.url), JSON.stringify(pin));
  r.eq("homeServers.plexPinPoll pending before approval", (await rec.engine.homeServers.plexPinPoll(77)).kind, "pending");
  approved = true;
  const done = await rec.engine.homeServers.plexPinPoll(77);
  r.ok("homeServers.plexPinPoll authorized lists servers", done.kind === "authorized" && done.servers.length === 1 && done.servers[0].name === "Den" && !("token" in done.servers[0]), JSON.stringify(done));
  const conn = rec.engine.homeServers.plexAdd(77, "srv1");
  r.ok("homeServers.plexAdd saves a Plex connection with the token in the secret store", conn.provider === "plex" && (await rec.engine.homeServers.connections()).length === 1 && rec.node.storage.has("harbor.media-server.token.v1.p1." + conn.id), JSON.stringify(conn.name));
  r.eq("libraryRoom.tabs shows Media Servers with a connection", rec.engine.libraryRoom.tabs().some((t) => t.id === "media-servers"), true);
  const bad = await rec.engine.homeServers.connect("jellyfin", "nowhere.invalid", "u", "p").then(() => "ok", (e) => e.message);
  r.ok("homeServers.connect reports a clear failure for an unreachable Jellyfin", typeof bad === "string" && bad !== "ok", bad);
  rec.engine.homeServers.update(conn.id, { preferredQuality: "720p-4", refreshInterval: "manual" });
  const upd = (await rec.engine.homeServers.connections())[0];
  r.ok("homeServers.update patches quality and refresh interval", upd.preferredQuality === "720p-4" && upd.refreshInterval === "manual", JSON.stringify({ q: upd.preferredQuality, i: upd.refreshInterval }));
  r.eq("homeServers.runDueSyncs skips a manual connection", await rec.engine.homeServers.runDueSyncs(), []);
  await rec.engine.homeServers.sync(conn.id).catch(() => undefined);
  const after = (await rec.engine.homeServers.connections())[0];
  r.ok("homeServers.sync persists a lastSyncResult on the connection", !!after.lastSyncResult && typeof after.lastSyncResult.ok === "boolean" && typeof after.lastSyncResult.message === "string", JSON.stringify(after.lastSyncResult));
  r.eq("homeServers.reportProgress ignores an unindexed item", await rec.engine.homeServers.reportProgress(conn.id, "nope", 1000, 2000, false), false);
  rec.engine.homeServers.remove(conn.id);
  r.eq("homeServers.remove clears the connection", (await rec.engine.homeServers.connections()).length, 0);
  rec.dispose();
}

// ------------------------------------------------------------------------ person room
r.eq("personRoom.page without a TMDB key", await engine.personRoom.page(287, "default", true), { hasKey: false, person: null });
// Bug pass: a collaborators run whose title credits all fail must not re-fire forever (the page
// re-reads on harbor:person-updated; an unwritten or empty list used to start another run).
{
  const pr = loadEngine({ storage: new Map([["harbor.profiles.v1", JSON.stringify({ activeId: "default", profiles: [{ id: "default", isPrimary: true }] })]]) });
  const creditHits = [];
  pr.node.host.fetch = async (req) => {
    const json = (body) => ({ status: 200, statusText: "OK", headers: { "content-type": "application/json" }, url: req.url, body: JSON.stringify(body) });
    if (/\/3\/person\/287\b/.test(req.url)) return json({ id: 287, name: "Brad Pitt", known_for_department: "Acting", biography: "", combined_credits: {
      cast: [1, 2, 3].map((n) => ({ id: 500 + n, media_type: "movie", title: `Film ${n}`, character: "Lead", popularity: 10 - n, vote_average: 7, vote_count: 900, release_date: "2001-01-01", order: 0 })), crew: [] } });
    if (/\/credits/.test(req.url)) creditHits.push(req.url);
    return { status: 404, statusText: "Not Found", headers: {}, url: req.url, body: "" };
  };
  pr.engine.settings.patch({ tmdbKey: "0123456789abcdef0123456789abcdef" }, pr.engine.settings.sourceKeyFor("default", true));
  const pings = [];
  pr.engine.runtime.onEvent((type) => { if (type === "harbor:person-updated") pings.push(type); });
  const first = await pr.engine.personRoom.page(287, "default", true);
  for (let i = 0; i < 120 && pings.length === 0; i++) await new Promise((res) => setTimeout(res, 25));
  const second = await pr.engine.personRoom.page(287, "default", true);
  await new Promise((res) => setTimeout(res, 200));
  r.ok("personRoom: a failed collaborators run answers once and the re-read does not fetch again", first.person?.name === "Brad Pitt" && pings.length === 1 && Array.isArray(second.collaborators) && second.collaborators.length === 0 && creditHits.length > 0 && creditHits.length <= 3, JSON.stringify({ pings: pings.length, hits: creditHits.length }));
  pr.dispose();
}

// --------------------------------------------------------------------- anilist / mal
{
  r.ok("anilist.authorizeUrl carries the client id and the pin redirect", /anilist\.co\/api\/v2\/oauth\/authorize\?client_id=42941&redirect_uri=.*pin/.test(engine.anilist.authorizeUrl()), engine.anilist.authorizeUrl());
  r.ok("mal.authorizeUrl carries a PKCE challenge", /myanimelist\.net\/v1\/oauth2\/authorize\?response_type=code&client_id=[0-9a-f]+&code_challenge=[^&]{60,}&code_challenge_method=plain/.test(engine.mal.authorizeUrl()), engine.mal.authorizeUrl());
  r.eq("anilist.status signed out", engine.anilist.status(), { authenticated: false, username: null });
  r.eq("mal.status signed out", engine.mal.status(), { authenticated: false, username: null });
  r.ok("anilist.complete rejects an empty paste", await engine.anilist.complete("").then(() => false, (e) => /Paste the code/.test(e.message)));
  r.ok("mal.complete rejects an empty paste", await engine.mal.complete("").then(() => false, (e) => /Paste the code/.test(e.message)));
  r.eq("anilist.rails signed out", engine.anilist.rails(), { rails: [], loading: false, error: false });
  r.eq("libraryRoom.tabs hides tracker tabs while signed out", engine.libraryRoom.tabs().some((t) => t.id === "anilist" || t.id === "mal"), false);
}

// --------------------------------------------------------------------------- services
{
  const none = engine.services.list("default", true);
  r.ok("services.list is empty without a TMDB key", none.hasKey === false && none.services.length === 0, JSON.stringify(none));
  r.ok("services.all lists every brand with a tint", engine.services.all().length >= 18 && engine.services.all().every((x) => /^#[0-9A-Fa-f]{6}$/.test(x.tint)));
  engine.settings.patch({ tmdbKey: "0123456789abcdef0123456789abcdef" }, engine.settings.sourceKeyFor("default", true));
  const some = engine.services.list("default", true);
  r.ok("services.list with a key returns the switched-on services (netflix first by default)", some.hasKey && some.services.length >= 10 && some.services[0].id === "netflix", JSON.stringify(some.services.map((x) => x.id).slice(0, 5)));
  engine.settings.patch({ tmdbKey: "" }, engine.settings.sourceKeyFor("default", true));
  const noRows = await engine.services.rows("netflix", "default", true);
  r.ok("services.rows without a key: hasKey false, no rows", noRows.hasKey === false && noRows.rows.length === 0 && noRows.name === "Netflix");
}

// ------------------------------------------ parental gating (lockedTabs, hideContent)
{
  const locks = { anime: true, movies: true, liveTv: true, library: false, bogus: true };
  const hide = { anime: true, liveTv: false, sports: false, adult: false, manga: false };
  const blob = { activeId: "p2", profiles: [
    { id: "p1", name: "Parent", isPrimary: true, passwordHash: "abc", lockedTabs: locks, hideContent: hide, settingsLinked: false, createdAt: 1 },
    { id: "p2", name: "Open", isPrimary: false, passwordHash: null, lockedTabs: { movies: true }, hideContent: null, createdAt: 2 },
  ] };
  const pg = loadEngine({ storage: new Map([["harbor.profiles.v1", JSON.stringify(blob)]]) });
  const urls = [];
  pg.node.host.fetch = async (req) => { urls.push(req.url); return { status: 404, statusText: "Not Found", headers: {}, url: req.url, body: "" }; };
  const P = pg.engine.parental;
  const g1 = P.gate("p1", false, false);
  r.ok("parental.gate: PIN + locked tabs hide the Big Picture tabs that carry the key (live TV has none)", g1.locked && g1.hasPin && g1.anyLocked && JSON.stringify(g1.hiddenRooms) === JSON.stringify(["anime", "manga", "ebook", "movies"]) && g1.hiddenTabs.liveTv === true && !("bogus" in g1.hiddenTabs), JSON.stringify(g1));
  const g1u = P.gate("p1", false, true);
  r.ok("parental.gate: a session unlock shows every tab", !g1u.locked && g1u.hiddenRooms.length === 0, JSON.stringify(g1u));
  const g2 = P.gate("p2", true, false);
  r.ok("parental.gate: locks without a PIN stay inert, hiddenTabs still reports them", !g2.locked && !g2.hasPin && g2.anyLocked && g2.hiddenRooms.length === 0 && g2.hiddenTabs.movies === true, JSON.stringify(g2));
  r.eq("parental.hiddenTabsFor an unknown profile is DEFAULT_HIDDEN", Object.values(P.hiddenTabsFor("nope")).some(Boolean), false);
  r.ok("parental.lockable lists upstream's nine tabs in order", P.lockable().length === 9 && P.lockable()[0].key === "discover" && P.lockable()[5].label === "Live TV", JSON.stringify(P.lockable()));
  const lv = P.lockedTabsValue({ calendar: true, junk: true });
  r.ok("parental.lockedTabsValue: full HiddenTabs when any tab is locked, null when none", lv && lv.calendar === true && lv.movies === false && Object.keys(lv).length === 9 && !("junk" in lv) && P.lockedTabsValue({ movies: false }) === null && P.lockedTabsValue(null) === null, JSON.stringify(lv));
  r.eq("parental.syncIdentity: nothing to copy for a profile without hideContent", P.syncIdentity(), false);
  // Before the switch below: afterwards p2 (linked, no shared blob yet) reads the harbor.settings mirror.
  urls.length = 0;
  await pg.engine.search.fanOut("naruto", "p2", true, null);
  r.ok("search.fanOut still asks anime sources for a profile that allows anime", urls.some((u) => /anilist|jikan|kitsu/.test(u)), JSON.stringify(urls.slice(0, 6)));
  let seen = 0;
  pg.engine.runtime.onEvent((type, detail) => { if (type === "harbor:settings-updated" && detail && detail.fields && detail.fields.includes("hideContent")) seen++; });
  pg.engine.runtime.syncStorage("harbor.profiles.v1", JSON.stringify({ ...blob, activeId: "p1" }));
  pg.engine.runtime.emitEvent("harbor:active-profile-changed", { id: "p1" });
  const eff = pg.engine.settings.loadForProfile("p1", false);
  const mirror = JSON.parse(pg.node.storage.get("harbor.settings") || "{}");
  r.ok("profile switch copies the profile's hideContent into its settings and the adult-filter mirror", eff.hideContent.anime === true && eff.hideContent.adult === false && mirror.hideContent && mirror.hideContent.adult === false && seen === 1, JSON.stringify({ hide: eff.hideContent, mirror: mirror.hideContent, seen }));
  r.eq("parental.syncIdentity is idempotent once settings match", P.syncIdentity(), false);
  const g3 = P.gate("p1", false, true);
  r.ok("parental.gate: hideContent.anime hides the Anime tab even when unlocked", g3.animeHidden && JSON.stringify(g3.hiddenRooms) === JSON.stringify(["anime"]), JSON.stringify(g3));
  urls.length = 0;
  const hidden = await pg.engine.search.fanOut("naruto", "p1", false, null);
  const animeHits = urls.filter((u) => /anilist|jikan|kitsu/.test(u));
  r.ok("search.fanOut skips anime sources for a profile that locks or hides anime", animeHits.length === 0 && hidden.anime.length === 0 && hidden.liveTv.length === 0, JSON.stringify(animeHits.slice(0, 3)));
  pg.dispose();
}

// -------------------------- tab editing (settings/load.ts _navHideMigrateV1, chrome/nav-items.tsx)
{
  // A blob saved before the retired switches: Live TV and Manga hidden through hideContent,
  // Music already hidden from the sidebar.
  const legacy = { hideContent: { anime: false, liveTv: true, sports: false, adult: true, manga: true }, navCustomization: { order: [], hidden: ["music"], renamed: {} } };
  const hideOnly = { anime: false, liveTv: true, sports: true, adult: false, manga: true };
  const blob = { activeId: "p1", profiles: [{ id: "p1", name: "One", isPrimary: true, passwordHash: null, lockedTabs: null, hideContent: hideOnly, createdAt: 1 }] };
  const ne = loadEngine({ storage: new Map([["harbor.settings.shared", JSON.stringify(legacy)], ["harbor.profiles.v1", JSON.stringify(blob)]]) });
  const E = ne.engine;
  const tabs = ["home", "discover", "anime", "manga", "shows", "movies", "music", "live", "sports", "search", "calendar", "library", "collections"];
  const eff = E.settings.loadForProfile("p1", true);
  r.ok("settings load moves the retired manga / liveTv switches into navCustomization.hidden once", JSON.stringify(eff.navCustomization.hidden) === JSON.stringify(["music", "manga", "live"]) && !("manga" in eff.hideContent) && !("liveTv" in eff.hideContent) && eff.hideContent.adult === true, JSON.stringify({ nav: eff.navCustomization, hide: eff.hideContent }));
  const l0 = E.navEdit.layout(tabs, "p1", true);
  r.ok("navEdit.layout: default order, the migrated hides reach the TV's Manga and Live TV tabs", JSON.stringify(l0.order) === JSON.stringify(tabs) && JSON.stringify(l0.hidden) === JSON.stringify(["manga", "music", "live"]), JSON.stringify(l0));
  const l1 = E.navEdit.move("calendar", "discover", "before", tabs, "p1", true);
  r.ok("navEdit.move: moveNavItem before a neighbour; Home and Search keep their slots", l1.order[0] === "home" && l1.order[1] === "calendar" && l1.order[2] === "discover" && l1.order[9] === "search" && l1.order.length === tabs.length && new Set(l1.order).size === tabs.length, JSON.stringify(l1.order));
  r.eq("navEdit.move refuses Home (pinned) and Search (no nav item)", [E.navEdit.move("home", "discover", "after", tabs, "p1", true).order, E.navEdit.move("search", "discover", "before", tabs, "p1", true).order], [l1.order, l1.order]);
  r.eq("navEdit.toggleHidden shows a hidden tab and keeps the order", [E.navEdit.toggleHidden("manga", tabs, "p1", true).hidden, E.navEdit.layout(tabs, "p1", true).order], [["music", "live"], l1.order]);
  r.eq("navEdit.toggleHidden never hides Home", E.navEdit.toggleHidden("home", tabs, "p1", true).hidden, ["music", "live"]);
  const stored = E.settings.loadForProfile("p1", true);
  r.ok("navEdit writes settings.navCustomization (order from effectiveNavOrder, the desktop's full list)", stored.navCustomization.order.length >= tabs.length - 1 && stored.navCustomization.order[0] === "home" && stored.navCustomization.order.indexOf("calendar") < stored.navCustomization.order.indexOf("discover"), JSON.stringify(stored.navCustomization));
  r.eq("navEdit.showAll clears hidden, keeps order", [E.navEdit.showAll(tabs, "p1", true).hidden, E.navEdit.layout(tabs, "p1", true).order], [[], l1.order]);
  r.eq("navEdit.reset: upstream's default layout", E.navEdit.reset(tabs, "p1", true), { order: tabs, hidden: [] });
  // profile-identity-sync.tsx: only anime / sports / adult are copied from the profile now.
  E.parental.syncIdentity();
  const after = E.settings.loadForProfile("p1", true);
  ne.node.host.fetch = async (req) => ({ status: 404, statusText: "Not Found", headers: {}, url: req.url, body: "" });
  r.eq("cards.removeFromWatchlist: every cloud form of a title (watchlist.ts twin sweep)", [await E.cards.removeFromWatchlist("k", "tmdb:movie:603", "tt0133093"), await E.cards.removeFromWatchlist("k", "tt0133093", null), await E.cards.removeFromWatchlist("k", "kitsu:1", "tt1")], [["tt0133093", "tmdb:movie:603"], ["tt0133093"], ["kitsu:1"]]);
  r.ok("parental.syncIdentity copies anime/sports/adult and leaves the retired keys behind", after.hideContent.sports === true && after.hideContent.adult === false && !("manga" in after.hideContent) && !("liveTv" in after.hideContent) && after.navCustomization.hidden.length === 0, JSON.stringify({ hide: after.hideContent, nav: after.navCustomization }));
  ne.dispose();
}

// ------------------------------------------------------------------------- kids room
{
  const profiles = JSON.stringify({ activeId: "k1", profiles: [{ id: "k1", isPrimary: true, kid: { age: 7, curfewMinutes: null, parentPinHash: null } }] });
  const json = (url, body) => ({ status: 200, statusText: "OK", headers: { "content-type": "application/json" }, url, body: JSON.stringify(body) });
  // Cinemeta fallback (no TMDB key): Animation and Family top lists through the kid filters.
  const cm = loadEngine({ storage: new Map([["harbor.profiles.v1", profiles]]) });
  cm.node.host.fetch = async (req) => {
    const mk = (prefix, genres) => Array.from({ length: 10 }, (_, i) => ({ id: `tt${prefix}${i}`, type: "movie", name: `${prefix} ${i}`, releaseInfo: "2001", background: `https://img.invalid/${prefix}${i}.jpg`, genres }));
    if (req.url.includes("/catalog/movie/top/genre=Animation")) return json(req.url, { metas: [...mk("91", ["Animation", "Comedy"]), { id: "tt9900", type: "movie", name: "Scary", releaseInfo: "2001", genres: ["Animation", "Horror", "Family"] }, { id: "tt9901", type: "movie", name: "Later", releaseInfo: "2999", genres: ["Family"] }] });
    if (req.url.includes("/catalog/movie/top/genre=Family")) return json(req.url, { metas: [...mk("92", ["Family"]), { id: "tt9902", type: "movie", name: "Drama only", releaseInfo: "2001", genres: ["Drama"] }] });
    return { status: 404, statusText: "Not Found", headers: {}, url: req.url, body: "" };
  };
  const plain = await cm.engine.kidsRoom.page("k1", true);
  const plainIds = plain.rows.flatMap((x) => x.metas.map((m) => m.id));
  r.ok("kidsRoom.page without TMDB: Cinemeta Animated/Family rows, hero from Animation", !plain.hasTmdb && plain.hero.length === 5 && JSON.stringify(plain.rows.map((x) => [x.key, x.title])) === JSON.stringify([["cinemeta-animation", "Animated Movies"], ["cinemeta-family", "Family Movies"]]), JSON.stringify({ hero: plain.hero.length, rows: plain.rows.map((x) => [x.key, x.metas.length]) }));
  r.ok("kidsRoom.page drops unsafe genres, unreleased and non-family titles, and hero repeats", !plainIds.some((id) => ["tt9900", "tt9901", "tt9902"].includes(id)) && !plain.hero.some((h) => plainIds.includes(h.id)), JSON.stringify(plainIds));
  r.eq("kidsRoom.franchises is empty without a TMDB key (the rail renders nothing)", cm.engine.kidsRoom.franchises("k1", true), []);
  r.eq("kidsRoom.episodes without a TMDB key", await cm.engine.kidsRoom.episodes(1, 1, "k1", true), []);
  cm.dispose();

  // TMDB: kidsSpecs rows and the hero, with the US certification ceiling on movie discovers.
  const tm = loadEngine({ storage: new Map([["harbor.profiles.v1", profiles]]) });
  tm.engine.settings.patch({ tmdbKey: "0123456789abcdef0123456789abcdef" }, tm.engine.settings.sourceKeyFor("k1", true));
  const urls = [];
  let serial = 0;
  tm.node.host.fetch = async (req) => {
    urls.push(req.url);
    if (req.url.includes("api.themoviedb.org/3/discover/")) {
      const tv = req.url.includes("/discover/tv");
      const results = Array.from({ length: 20 }, () => {
        serial += 1;
        return tv
          ? { id: serial, name: `Show ${serial}`, first_air_date: "2010-01-01", backdrop_path: "/b.jpg", poster_path: "/p.jpg", genre_ids: [10762] }
          : { id: serial, title: `Film ${serial}`, release_date: "2010-01-01", backdrop_path: "/b.jpg", poster_path: "/p.jpg", genre_ids: [10751], adult: serial % 20 === 1 };
      });
      return json(req.url, { page: 1, total_pages: 5, results });
    }
    return { status: 404, statusText: "Not Found", headers: {}, url: req.url, body: "" };
  };
  const built = await tm.engine.kidsRoom.page("k1", true);
  const ids = built.rows.flatMap((x) => x.metas.map((m) => m.id));
  r.ok("kidsRoom.page with TMDB builds kidsSpecs rows in upstream order", built.hasTmdb && built.rows.length >= 5 && built.rows.map((x) => x.key).join(",").startsWith("trending-kids,animated-movies,g-pg-picks,kids-tv"), JSON.stringify(built.rows.map((x) => [x.key, x.metas.length])));
  r.ok("kidsRoom.page hero: at most 10, no adult titles, never repeated in the rows", built.hero.length > 0 && built.hero.length <= 10 && built.hero.every((m) => !m.adult) && !built.hero.some((h) => ids.includes(h.id)) && new Set(ids).size === ids.length, JSON.stringify(built.hero.map((m) => m.id)));
  r.ok("kidsRoom movie discovers carry certification.lte=PG, US and no horror/thriller", urls.filter((u) => u.includes("/discover/movie")).every((u) => u.includes("certification.lte=PG") && u.includes("certification_country=US") && /without_genres=(16%2C)?27%2C53/.test(u)), urls.filter((u) => u.includes("/discover/movie")).slice(0, 2).join(" "));
  const before = built.rows.find((x) => x.key === "trending-kids").metas.length;
  const more = await tm.engine.kidsRoom.loadMore("k1", true, "trending-kids");
  r.ok("kidsRoom.loadMore appends the next page of a row", more && more.key === "trending-kids" && more.metas.length > before && urls.some((u) => u.includes("/discover/movie") && u.includes("page=2")), JSON.stringify({ before, after: more && more.metas.length }));
  r.eq("kidsRoom.loadMore for an unknown row", await tm.engine.kidsRoom.loadMore("k1", true, "nope"), null);
  const tiles = tm.engine.kidsRoom.franchises("k1", true);
  r.ok("kidsRoom.franchises: every Pick a World tile has three gradient stops and its cta art", tiles.length === 14 && tiles[0].key === "toy-story" && tiles.every((t) => t.stops.length === 3 && t.stops.every((c) => /^#[0-9a-f]{6}$/.test(c)) && t.art === `/kids/cta/${t.key}.webp`) && tiles.find((t) => t.key === "hotel-t").drop === 18, JSON.stringify(tiles.filter((t) => t.stops.length !== 3).map((t) => t.key)));
  r.eq("kidsRoom.gradStops maps Tailwind classes to hex", tm.engine.kidsRoom.gradStops("from-sky-400 via-sky-300 to-amber-300"), ["#38bdf8", "#7dd3fc", "#fcd34d"]);
  const lego = await tm.engine.kidsRoom.franchisePage("k1", true, "lego", 1);
  r.ok("kidsRoom.franchisePage (keyword franchise) filters adult titles", Array.isArray(lego) && lego.every((m) => !m.adult), JSON.stringify(lego.length));
  r.eq("kidsRoom.franchisePage for an unknown franchise", await tm.engine.kidsRoom.franchisePage("k1", true, "nope", 1), []);
  const det = await tm.engine.kidsRoom.detail({ id: "tmdb:movie:5", type: "movie", name: "Film 5", releaseInfo: "2010", poster: "https://img.invalid/p.jpg" }, "k1", true);
  r.ok("kidsRoom.detail falls back to the meta when TMDB and Cinemeta have nothing", det.name === "Film 5" && det.backdrop === "https://img.invalid/p.jpg" && det.year === "2010" && det.tvId === null && det.recs.length === 0 && det.collection === null, JSON.stringify(det));
  tm.dispose();
}

// ------------------------------------------------------------------------ library room
{
  r.eq("libraryRoom.tabs (signed out of trackers)", engine.libraryRoom.tabs().map((t) => t.id), ["library", "watchlist", "history", "lists", "favorites"]);
  const empty = await engine.libraryRoom.feed({ tab: "library", profileId: "default", linked: true, authKey: null });
  r.ok("libraryRoom.feed(library) with no Stremio session is ready and empty", empty.status === "ready" && empty.sections.length === 0 && empty.signedIn === false, JSON.stringify(empty));
  app.node.storage.set("harbor.favorites.v1.default", JSON.stringify([{ id: "tt0111161", type: "movie", name: "The Shawshank Redemption", addedAt: Date.now() - 3600000 }, { id: "tt0903747", type: "series", name: "Breaking Bad", addedAt: Date.now() - 40 * 86400000 }]));
  engine.runtime.syncStorage("harbor.favorites.v1.default", app.node.storage.get("harbor.favorites.v1.default"));
  const fav = await engine.libraryRoom.feed({ tab: "favorites", profileId: "default", linked: true, authKey: null });
  r.ok("libraryRoom.feed(favorites) groups by date bucket", fav.total === 2 && fav.sections.map((x) => x.label).join("|") === "Today|This month" || fav.sections.map((x) => x.label).join("|") === "Today|" + String(new Date().getFullYear()), JSON.stringify(fav.sections.map((x) => [x.label, x.items.length])));
  const onlySeries = await engine.libraryRoom.feed({ tab: "favorites", profileId: "default", linked: true, authKey: null, type: "series", sort: "title" });
  r.ok("libraryRoom.feed filters by type and sorts by title", onlySeries.matched === 1 && onlySeries.sections[0].label === "A to Z" && onlySeries.sections[0].items[0].meta.name === "Breaking Bad", JSON.stringify(onlySeries.sections));
  const q = await engine.libraryRoom.feed({ tab: "favorites", profileId: "default", linked: true, authKey: null, query: "shaw" });
  r.eq("libraryRoom.feed search", q.matched, 1);
  engine.libraryRoom.setSort("year", "default", true);
  r.eq("libraryRoom.setSort persists", engine.settings.load().librarySort, "year");
  engine.libraryRoom.setSort("recent", "default", true);
}

// -------------------------------------------- calendar, reminders, stats (recorded host)
{
  const T0 = Date.now();
  const d = new Date();
  const y = d.getFullYear(), m = d.getMonth();
  const iso = (dt) => `${dt.getFullYear()}-${String(dt.getMonth() + 1).padStart(2, "0")}-${String(dt.getDate()).padStart(2, "0")}`;
  const mid = iso(new Date(y, m, 15));
  const thisMonth = `gte=${iso(new Date(y, m, 1))}`;
  const cal = loadEngine({ storage: new Map([
    ["harbor.profiles.v1", JSON.stringify({ activeId: "default", profiles: [{ id: "default", isPrimary: true }] })],
    ["harbor.playback-history.v1.default", JSON.stringify({
      "tt0903747|1:1": { savedAt: T0 - 86400000, title: "Breaking Bad" },
      "tt0903747|1:2": { savedAt: T0 - 86000000, title: "Breaking Bad" },
      "tt0111161": { savedAt: T0 - 3600000, title: "The Shawshank Redemption" },
    })],
  ]) });
  cal.node.host.fetch = async (req) => {
    const json = (body) => ({ status: 200, statusText: "OK", headers: { "content-type": "application/json" }, url: req.url, body: JSON.stringify(body) });
    if (req.url.includes("api.themoviedb.org/3/discover/movie") && req.url.includes("page=1") && req.url.includes(thisMonth)) return json({ results: [
      { id: 101, title: "Future Film", release_date: mid, poster_path: "/p.jpg", vote_average: 7.2, genre_ids: [28], overview: "A film." },
    ] });
    if (req.url.includes("api.themoviedb.org/3/discover/tv") && req.url.includes("page=1") && req.url.includes(thisMonth)) return json({ results: [
      { id: 202, name: "New Show", first_air_date: mid, poster_path: null, vote_average: 0, genre_ids: [18] },
    ] });
    if (req.url.includes("api.themoviedb.org")) return json({ results: [] });
    if (req.url === "https://v3-cinemeta.strem.io/meta/series/tt9999999.json") return json({ meta: { id: "tt9999999", type: "series", name: "Remind Show", videos: [
      { season: 1, episode: 1, released: new Date(T0 - 30 * 86400000).toISOString() },
      { season: 1, episode: 2, released: new Date(T0 + 3600000).toISOString() },
    ] } });
    return { status: 404, statusText: "Not Found", headers: {}, url: req.url, body: "" };
  };
  const E = cal.engine;
  const signedOut = await E.calendar.month({ profileId: "default", linked: true, authKey: null, year: y, month: m });
  r.ok("calendar.month: My library signed out asks to sign in, 42 cells, 7 weekdays", signedOut.source === "library" && signedOut.status === "not-signed-in" && signedOut.cells.length === 42 && signedOut.weekdays.length === 7 && signedOut.weekdays[0] === "Sun", JSON.stringify({ s: signedOut.status, c: signedOut.cells.length, w: signedOut.weekdays }));
  r.eq("calendar.month: switcher hides My Trakt / My Simkl / Simkl premieres while disconnected", signedOut.sources.map((s) => s.id), ["library", "all", "anticipated", "anime", "custom"]);
  E.calendar.setPref("default", true, { calendarSource: "all", weekStartsMonday: true });
  const noKey = await E.calendar.month({ profileId: "default", linked: true, year: y, month: m });
  r.ok("calendar.month: All upcoming without a TMDB key shows the key state; week starts Monday", noKey.status === "no-key" && noKey.weekdays[0] === "Mon" && noKey.watchlistToggle === true, JSON.stringify({ s: noKey.status, w: noKey.weekdays[0] }));
  E.settings.patch({ tmdbKey: "k" }, E.settings.sourceKeyFor("default", true));
  const all = await E.calendar.month({ profileId: "default", linked: true, year: y, month: m });
  const day = all.cells.find((c) => c.iso === mid);
  r.ok("calendar.month: All upcoming groups TMDB releases on their day with Meta and tag", all.status === "ready" && all.total === 2 && day && day.inMonth && day.items.length === 2 && day.items.some((i) => i.meta.id === "tmdb:movie:101" && i.meta.type === "movie" && i.tag === "Movie" && i.poster.endsWith("/p.jpg")) && day.items.some((i) => i.meta.type === "series" && i.poster === null), JSON.stringify(day));
  r.eq("calendar.month: filter chips (no Anime on All upcoming) with counts", all.filters.map((f) => `${f.id}:${f.count}`), ["all:2", "movie:1", "tv:1"]);
  const movies = await E.calendar.month({ profileId: "default", linked: true, year: y, month: m, filter: "movie" });
  r.ok("calendar.month: the Movies filter narrows the grid", movies.total === 1 && movies.filter === "movie", JSON.stringify({ t: movies.total }));
  const later = await E.calendar.month({ profileId: "default", linked: true, year: y + 1, month: 0 });
  r.eq("calendar.month: an empty month carries upstream's empty copy", [later.status, later.emptyHeading], ["empty", "Nothing this month"]);
  r.ok("calendar.month: month label and 0-based month", later.monthLabel === `January ${y + 1}` && later.month === 0, later.monthLabel);

  E.calendar.setPref("default", true, { calendarSource: "custom" });
  let rail = E.calendar.customRail("default", true);
  r.ok("calendar.customRail: no filters yet, three media types on, Trakt watchlist needs Trakt", rail.activeCount === 0 && rail.summary === "No filters yet" && rail.mediaTypes.every((c) => c.selected) && rail.trakt[1].disabled === true && rail.groups.map((g) => g.id).join() === "genres,providers,countries,people", JSON.stringify(rail.summary));
  rail = E.calendar.customToggle("default", true, "genre:movie:28");
  rail = E.calendar.customToggle("default", true, "prov:8");
  rail = E.calendar.customToggle("default", true, "media:anime");
  r.ok("calendar.customToggle: genre + provider count, media type flips", rail.activeCount === 2 && rail.groups[0].count === 1 && rail.groups[0].chips.find((c) => c.key === "genre:movie:28").selected && rail.mediaTypes[2].selected === false && /1 genre/.test(rail.summary), JSON.stringify(rail.summary));
  r.ok("calendar.customToggle: the stored genre keeps upstream's shape", JSON.stringify(E.settings.loadForProfile("default", true).customCalendar.genres) === JSON.stringify([{ id: 28, name: "Action", mediaType: "movie" }]), JSON.stringify(E.settings.loadForProfile("default", true).customCalendar.genres));
  const custom = await E.calendar.month({ profileId: "default", linked: true, year: y, month: m });
  r.ok("calendar.month: Custom source reports the rail summary", custom.source === "custom" && custom.custom && custom.custom.activeCount === 2, JSON.stringify(custom.custom));
  rail = E.calendar.customToggle("default", true, "clear");
  r.eq("calendar.customToggle clear resets the filters", rail.activeCount, 0);
  {
    const found = await E.calendar.customPeopleSearch("default", true, "nolan");
    const blank = await E.calendar.customPeopleSearch("default", true, "  ");
    r.ok("calendar.customPeopleSearch answers with the key present (people list, blank query empty)", found.needsKey === false && Array.isArray(found.people) && blank.people.length === 0, JSON.stringify({ found, blank }));
    let pr = E.calendar.customAddPerson("default", true, { id: 525, name: "Christopher Nolan", profile: null });
    pr = E.calendar.customAddPerson("default", true, { id: 525, name: "Christopher Nolan", profile: null });
    const people = pr.groups.find((g) => g.id === "people");
    r.ok("calendar.customAddPerson adds once (config-rail addPerson, role any)", people.count === 1 && people.chips[0].key === "person:525" && JSON.stringify(E.settings.loadForProfile("default", true).customCalendar.trackedPeople) === JSON.stringify([{ id: 525, name: "Christopher Nolan", profile: null, role: "any" }]), JSON.stringify(people));
    pr = E.calendar.customToggle("default", true, "person:525");
    r.eq("calendar.customToggle person:<id> removes the tracked person", pr.groups.find((g) => g.id === "people").count, 0);
  }

  r.eq("calendar.reminders starts empty", E.calendar.reminders().length, 0);
  E.actions.toggleReminder({ id: "tt9999999", type: "series", name: "Remind Show" });
  const rem = E.calendar.reminders();
  r.ok("calendar.reminders lists the Detail reminder with the manager's summary", rem.length === 1 && rem[0].summary === "Episodes + Seasons · Chime" && rem[0].unseen === false, JSON.stringify(rem));
  const fired = [];
  const off = E.runtime.onEvent((type, detail) => { if (type === "harbor:reminder-fired") fired.push(detail); });
  const first = await E.calendar.checkReminders("default", true, T0 + 1000);
  r.eq("calendar.checkReminders: the first check only records what already aired", [first, fired.length], [0, 0]);
  const second = await E.calendar.checkReminders("default", true, T0 + 2 * 3600000);
  off();
  r.ok("calendar.checkReminders: a new episode inside the day window fires once", second === 1 && fired.length === 1 && fired[0].text === "Remind Show: S1 E2 is out now", JSON.stringify(fired));
  const un = E.calendar.unseen();
  r.ok("calendar.unseen counts it and keeps the message", un.count === 1 && un.fired[0].body === "S1 E2 is out now" && E.calendar.reminders()[0].unseen === true, JSON.stringify(un));
  const cleared = E.calendar.clearUnseen();
  r.ok("calendar.clearUnseen hands the messages over once", cleared.length === 1 && E.calendar.unseen().count === 0, JSON.stringify(cleared));
  r.eq("calendar.removeReminder", E.calendar.removeReminder("tt9999999").length, 0);
  r.eq("calendar.remaining formats a countdown like use-now", E.calendar.remaining((2 * 1440 + 3 * 60 + 5) * 60000), "2d 3h 5m");

  const stats = await E.wrapped.load();
  r.ok("wrapped.load aggregates local history (plays, titles, split, heatmap weeks)", stats && stats.source === "local" && stats.totalPlays === 3 && stats.totalTitles === 2 && stats.split.series === 3 && stats.topTitles[0].id === "tt0903747" && stats.topTitles[0].count === 2 && stats.heatWeeks.length === 52 && stats.heatWeeks[0].length === 7, JSON.stringify(stats && { s: stats.source, p: stats.totalPlays, t: stats.totalTitles, split: stats.split }));
  r.ok("wrapped.load: archetype and highlights come from upstream's rules", stats && stats.archetype.id === "serialist" && stats.archetype.label === "The Series Slayer" && stats.longestBinge.count >= 1 && typeof stats.bingeDate === "string", JSON.stringify(stats && stats.archetype));
  r.eq("wrapped.enabled follows settings.wrappedButton", E.wrapped.enabled("default", true), true);
  cal.dispose();
}

// ---------------------------- collections editing, TVDB lists, Letterboxd, library repair
// One recorded host: Harbor's TVDB proxy, Stremboxd and Stremio's datastore, all mocked.
{
  const rec = loadEngine({});
  const E = rec.engine;
  let tvdbDown = false;
  let lbWatchlist = true;
  let stremioPhase = "repair";
  const puts = [];
  rec.node.host.fetch = async (req) => {
    const json = (body, status = 200) => ({ status, statusText: status === 200 ? "OK" : "Error", headers: { "content-type": "application/json" }, url: req.url, body: JSON.stringify(body) });
    const u = req.url;
    if (u.includes("/api/tvdb/v4/")) {
      if (tvdbDown) return json({ error: "down" }, 502);
      if (u.includes("/search?")) return json({ data: [{ tvdb_id: "123", name: "Smoke Saga Collection", image_url: "/lists/123.jpg", overview: "Every Smoke film." }] });
      if (u.includes("/lists/123/extended")) return json({ data: { id: 123, name: "Smoke Saga Collection", overview: "Every Smoke film.", image: null, entities: [{ movieId: 5, order: 2 }, { seriesId: 7, order: 1 }, { movieId: 9, order: 3 }] } });
      if (u.includes("/movies/5/extended")) return json({ data: { name: "Smoke Film", year: 2001, image: "/p5.jpg", remoteIds: [{ id: "tt0000005" }] } });
      if (u.includes("/series/7/extended")) return json({ data: { name: "Smoke Show", year: "1999", image: null, remoteIds: [] } });
      return json({ data: null }, 404);
    }
    if (u.startsWith("https://api.stremboxd.com/")) {
      if (u.endsWith("/manifest.json")) return json({ id: "community.stremboxd", catalogs: [...(lbWatchlist ? [{ id: "letterboxd-watchlist", name: "smoke's Watchlist" }] : []), { id: "letterboxd-popular", name: "Popular This Week" }] });
      if (u.includes("/catalog/movie/letterboxd-watchlist")) return json({ metas: [1, 2, 3, 4, 5].map((n) => ({ id: `tt000010${n}`, type: "movie", name: `Watch ${n}`, year: 2020 + n, imdbRating: "7.1", links: [{ name: "x", category: "Letterboxd", url: "https://letterboxd.com/film/x/" }] })) });
      return json({ metas: [] });
    }
    if (u.startsWith("https://api.strem.io/api/")) {
      const path = u.slice("https://api.strem.io/api/".length);
      if (path === "datastoreMeta") return json({ result: [["tt1", "1"], ["tt2", "2"], ["tt3", "3"]] });
      if (path === "datastoreGet") {
        if (stremioPhase === "repair") return json({ result: [{ _id: "tt1", name: "Needs repair", type: "movie" }, { name: "No id" }] });
        return json({ result: [
          { _id: "tt3", name: "Mislabelled Anime", type: "series", removed: false, temp: false, state: { video_id: "kitsu:1:1" } },
          { _id: "tt2", name: "Fine", type: "movie", removed: false, temp: false, state: { video_id: "tt2" } },
        ] });
      }
      if (path === "datastorePut") { puts.push(1); return json({ result: { success: true } }); }
    }
    return json({ error: "not_found" }, 404);
  };

  // CL-2: own collections from the TV.
  const made = E.collectionsRoom.create("Smoke picks");
  r.ok("collectionsRoom.create makes an editable collection", made && made.source === "mine" && made.name === "Smoke picks" && made.count === 0, JSON.stringify(made));
  const added = E.collectionsRoom.addItem(made.ref, { id: "tt0111161", type: "movie", name: "The Shawshank Redemption", poster: null });
  r.ok("collectionsRoom.addItem adds a title once", added.count === 1 && E.collectionsRoom.addItem(made.ref, { id: "tt0111161", type: "movie", name: "x" }).count === 1, JSON.stringify(added.items));
  r.eq("collectionsRoom.rename", E.collectionsRoom.rename(made.ref, "  Smoke favourites ").name, "Smoke favourites");
  r.eq("collectionsRoom.removeItem", E.collectionsRoom.removeItem(made.ref, "tt0111161").count, 0);
  r.eq("collectionsRoom.create with no name uses upstream's default", E.collectionsRoom.create("  ").name, "Untitled collection");
  E.collectionsRoom.remove(made.ref);
  r.ok("collectionsRoom.remove deletes it", !E.collectionsRoom.mine().some((c) => c.ref === made.ref) && E.collectionsRoom.mine().length === 1, JSON.stringify(E.collectionsRoom.mine().map((c) => c.name)));
  r.eq("collectionsRoom.searchTitles ignores a one-letter query", await E.collectionsRoom.searchTitles("a", "default", true), []);

  // CL-1: TVDB lists through Harbor's proxy, no key.
  const t1 = await E.collectionsRoom.tvdb("all", 0);
  r.ok("collectionsRoom.tvdb pulls five seed names and dedupes hits", t1.next === 5 && !t1.done && !t1.failed && t1.cards.length === 1 && t1.cards[0].key === "tvdb:123" && t1.cards[0].count === null && t1.cards[0].image === "https://artworks.thetvdb.com/lists/123.jpg", JSON.stringify(t1));
  const t2 = await E.collectionsRoom.tvdb("all", 5);
  r.ok("collectionsRoom.tvdb 'all' stops at ten names and says more exist", t2.done && t2.capped && t2.next === 10, JSON.stringify({ ...t2, cards: t2.cards.length }));
  const td = await E.collectionsRoom.tvdbDetail(123, "Fallback");
  r.ok("collectionsRoom.tvdbDetail hydrates entries in list order and drops unknown ones", !td.failed && td.name === "Smoke Saga Collection" && td.items.map((i) => i.id).join(",") === "tvdb:series:7,tt0000005" && td.items[1].poster === "https://artworks.thetvdb.com/p5.jpg", JSON.stringify(td));
  tvdbDown = true;
  const t3 = await E.collectionsRoom.tvdb("tvdb", 40);
  r.ok("collectionsRoom.tvdb reports an unreachable TVDB", t3.failed && t3.cards.length === 0, JSON.stringify(t3));
  r.ok("collectionsRoom.tvdbDetail of an unknown list fails softly", (await E.collectionsRoom.tvdbDetail(999, "Fallback")).failed === true);
  tvdbDown = false;

  // LB-3 / DS-4: Letterboxd public mode.
  r.eq("letterboxd.status off by default", E.letterboxd.status("default", true).active, false);
  r.eq("libraryRoom.tabs hides Letterboxd until connected", E.libraryRoom.tabs("default", true).some((t) => t.id === "letterboxd"), false);
  lbWatchlist = false;
  const lbBad = await E.letterboxd.connect("default", true, "smoke");
  r.ok("letterboxd.connect refuses a username with no public watchlist", lbBad.ok === false && /watchlist/.test(lbBad.message) && E.letterboxd.status("default", true).active === false, JSON.stringify(lbBad));
  lbWatchlist = true;
  const lbOk = await E.letterboxd.connect("default", true, "@smoke");
  r.ok("letterboxd.connect turns public mode on", lbOk.ok && lbOk.catalogs === 2 && E.letterboxd.status("default", true).active && E.letterboxd.status("default", true).username === "smoke", JSON.stringify(lbOk));
  r.eq("libraryRoom.tabs shows Letterboxd once connected", E.libraryRoom.tabs("default", true).some((t) => t.id === "letterboxd"), true);
  const lbFeed = await E.libraryRoom.feed({ tab: "letterboxd", profileId: "default", linked: true, authKey: null });
  r.ok("libraryRoom.feed(letterboxd) lists the watchlist", lbFeed.status === "ready" && lbFeed.total === 5 && lbFeed.sections[0].items[0].meta.type === "movie", JSON.stringify({ status: lbFeed.status, total: lbFeed.total }));
  const lbRows = await E.letterboxd.movieRows("default", true);
  r.ok("letterboxd.movieRows keeps rows with four titles or more, named from the manifest", lbRows.length === 1 && lbRows[0].key === "letterboxd-letterboxd-watchlist" && lbRows[0].name === "smoke's Watchlist" && lbRows[0].metas.length === 5, JSON.stringify(lbRows.map((x) => [x.key, x.name, x.metas.length])));
  E.letterboxd.disable("default", true);
  r.eq("letterboxd.disable hides the tab again", E.libraryRoom.tabs("default", true).some((t) => t.id === "letterboxd"), false);
  r.eq("letterboxd.movieRows empty when off", await E.letterboxd.movieRows("default", true), []);

  // LB-4: library repair.
  r.ok("libraryRoom.repair needs a Stremio session", await E.libraryRoom.repair(null).then(() => false, (e) => /Sign in to Stremio first/.test(e.message)));
  const rep = await E.libraryRoom.repair("auth_smoke");
  r.ok("libraryRoom.repair rewrites dirty items and counts unrepairable ones", rep.total === 2 && rep.repaired === 1 && rep.unrepairable === 1 && rep.alreadyClean === 0 && puts.length === 1, JSON.stringify(rep));
  stremioPhase = "anime";
  const scan = await E.libraryRoom.animeScan("auth_smoke");
  r.eq("libraryRoom.animeScan finds anime saved under a tt id", scan, [{ id: "tt3", name: "Mislabelled Anime" }]);
  r.eq("libraryRoom.animeHeal removes what the scan found", await E.libraryRoom.animeHeal("auth_smoke"), 1);
  r.eq("libraryRoom.animeHeal with nothing scanned", await E.libraryRoom.animeHeal("auth_smoke"), 0);
  rec.dispose();
}

// ----------------------------------------------------------------------- profiles room
{
  const av = engine.profilesRoom.avatars();
  r.ok("profilesRoom.avatars lists upstream's catalog with bundle paths", av.length >= 4 && av[0].items[0].path === "/avatars/harbor_person_01.webp", JSON.stringify(av.map((g) => [g.group, g.items.length])));
  {
    // (bug pass) profilesRoom.purge (a profile deleted on this TV) clears the same list.
    const keys = ["harbor.mal.session.v1.p_del", "harbor.anilist.session.v1.p_del", "harbor.playback-history.v1.p_del", "harbor.settings.p_del"];
    for (const k of [...keys, "harbor.settings.p_keep"]) { app.node.storage.set(k, "x"); engine.runtime.syncStorage(k, "x"); }
    engine.profilesRoom.purge("p_del");
    r.ok("(bug pass) profilesRoom.purge removes MAL/AniList sessions and history with the profile, nothing else", keys.every((k) => !app.node.storage.has(k)) && app.node.storage.get("harbor.settings.p_keep") === "x", JSON.stringify([...app.node.storage.keys()].filter((k) => k.includes("p_del") || k.includes("p_keep"))));
    app.node.storage.delete("harbor.settings.p_keep");
    engine.runtime.syncStorage("harbor.settings.p_keep", null);
  }
  r.ok("profilesRoom.colors + pickColor", engine.profilesRoom.colors().length >= 6 && engine.profilesRoom.pickColor([engine.profilesRoom.colors()[0]]) === engine.profilesRoom.colors()[1]);
}

// ------------------------------------------------------------------ settings room
{
  const cats = engine.settingsRoom.categories("default", true);
  r.eq("settingsRoom.categories: the 8 Big Picture categories in order", cats.categories.map((c) => c.id), ["picture", "language", "subtitles", "playback", "home", "services", "setup", "interface"]);
  r.ok("settingsRoom.categories carry summaries", cats.categories.every((c) => typeof c.summary === "string" && c.summary.length > 0), JSON.stringify(cats.categories.map((c) => c.summary)));
  const pb = engine.settingsRoom.controls("playback", "default", true);
  r.ok("settingsRoom.controls(playback): options rows incl. instantPlay", pb.some((c) => c.id === "instantPlay" && c.kind === "options" && c.options.length === 2), JSON.stringify(pb.map((c) => [c.id, c.kind])));
  const sv = engine.settingsRoom.controls("services", "default", true);
  r.ok("settingsRoom.controls(services): multi row with tints", sv[0].kind === "multi" && sv[0].items.length > 10 && sv[0].items.every((i) => typeof i.tint === "string"), JSON.stringify(sv[0].items.slice(0, 2)));
  r.eq("settingsRoom.commit skipIntro off", engine.settingsRoom.commit("skipIntro", "off", "default", true).ok, true);
  r.eq("settings.load reflects the commit", engine.settings.load().autoSkipIntro, false);
  engine.settingsRoom.commit("service", "netflix", "default", true);
  r.eq("commit service toggles streaming.netflix", engine.settings.load().streaming.netflix, false);
  engine.settingsRoom.commit("subLang", "French", "default", true);
  r.ok("commit subLang appends", engine.settings.load().preferredSubLangs.includes("French"));
  r.eq("commit sportsTab off declines consent", engine.settingsRoom.commit("sportsTab", "off", "default", true).sportsShown, false);
  r.eq("commit sportsTab on resets consent", engine.settingsRoom.commit("sportsTab", "on", "default", true).sportsShown, true);
  engine.settingsRoom.commit("skipIntro", "on", "default", true); engine.settingsRoom.commit("service", "netflix", "default", true); engine.settingsRoom.commit("subLang", "French", "default", true);
  // Desktop-only rows stay off the TV; Hardware acceleration offers what tvOS can do.
  const ids = (cat) => engine.settingsRoom.controls(cat, "default", true).map((c) => c.id);
  r.ok("settingsRoom.controls: no Controller navigation / Open in Big Picture / Hide watched on the TV", !ids("interface").includes("controller") && !ids("interface").includes("autoStart") && ids("interface").includes("sound") && !ids("home").includes("hideWatched") && ids("home").includes("homeMode"), JSON.stringify([ids("interface"), ids("home")]));
  const hw = () => engine.settingsRoom.controls("playback", "default", true).find((c) => c.id === "hwdec");
  r.eq("settingsRoom.controls(hwdec): Auto and Off only", hw().options.map((o) => o.value), ["auto", "off"]);
  engine.settingsRoom.commit("hwdec", "on", "default", true);
  r.eq("settingsRoom: a synced hwdec \"on\" reads as Auto (VideoToolbox either way)", [hw().value, engine.settingsRoom.pane("default", true).playback.find((l) => l[0] === "Hardware acceleration")[1]], ["auto", "Auto"]);
  engine.settingsRoom.commit("hwdec", "off", "default", true);
  r.eq("settingsRoom: hwdec Off commits and reads back", [hw().value, engine.settings.load().mpvHwdec], ["off", "off"]);
  engine.settingsRoom.commit("hwdec", "auto", "default", true);
}

// ------------------------------------------ themes, language picker, settings preview, done facts
{
  const near = (a, hex) => [16, 8, 0].every((sh, i) => Math.abs(Math.round(a[i] * 255) - ((hex >> sh) & 0xff)) <= 1) && a[3] === 1;
  const st = engine.themes.state("default", true);
  r.eq("themes.state: upstream's library, built-in then featured", st.presets.map((p) => p.id), ["cool-grey", "nord", "stremio", "tokyo-night", "dracula", "forest", "noir", "velvet", "crunch", "kawaii", "aurora", "minui", "minui-dark"]);
  r.eq("themes.state: default is Harbor default in Sentient + Switzer", [st.active, st.fontPair, st.faces.display, st.faces.sans, st.light], ["cool-grey", "sentient-switzer", "sentient", "switzer", false]);
  const shipped = { canvas: 0x111213, surface: 0x191b1c, elevated: 0x252628, raised: 0x323335, ink: 0xf4f5f7, inkMuted: 0xa3a5a6, inkSubtle: 0x626365, accent: 0xf4a25c, danger: 0xc53637, void: 0x0d0e0f, panel: 0x161819, panel2: 0x222325, on: 0x404142 };
  r.ok("themes.state: default palette matches Theme.swift's shipped tokens", Object.entries(shipped).every(([k, hex]) => near(st.palette[k], hex)), JSON.stringify(st.palette));
  r.eq("themes.parseColor: #rrggbbaa and rgba()", [engine.themes.parseColor("#88c0d02e")[3].toFixed(2), engine.themes.parseColor("rgba(255,255,255,0.9)")[3]], ["0.18", 0.9]);
  r.ok("themes.parseColor: oklch", near(engine.themes.parseColor("oklch(0.18 0.004 260)"), 0x111213));
  const aurora = engine.themes.parseGradient("radial-gradient(ellipse 90% 70% at 20% 0%, #2e7fd6 0%, #14397f 30%, #0a1c4e 60%, #050d28 100%), radial-gradient(ellipse 70% 60% at 80% 100%, #5e36b8 0%, transparent 60%)");
  r.eq("themes.parseGradient: two radial layers, top first", aurora.map((l) => [l.kind, l.rx, l.ry, l.cx, l.cy, l.stops.length]), [["radial", 0.9, 0.7, 0.2, 0, 4], ["radial", 0.7, 0.6, 0.8, 1, 2]]);
  r.eq("themes.parseGradient: data: or url images give no layers", engine.themes.parseGradient("url(x.png)"), []);
  const stremio = engine.themes.apply("stremio", "default", true);
  r.eq("themes.apply(stremio): preset font, gradient backdrop", [stremio.active, stremio.fontPair, stremio.faces.sans, stremio.background.layers[0].kind, stremio.background.layers[0].angle, stremio.cardStyle], ["stremio", "plus-jakarta", "system", "linear", 41, "stremio"]);
  r.eq("themes.apply writes settings.theme", engine.settings.load().theme.preset, "stremio");
  r.eq("themes.apply ignores an unknown id", engine.themes.apply("not-a-theme", "default", true).active, "stremio");
  r.eq("themes.apply(minui) is a light theme", [engine.themes.apply("minui", "default", true).light, engine.themes.state("default", true).bokeh], [true, false]);
  const minuiDark = engine.themes.apply("minui-dark", "default", true);
  r.eq("themes.apply(minui-dark): MinUI's card and button styles on a dark canvas", [minuiDark.light, minuiDark.cardStyle, minuiDark.buttonStyle, minuiDark.fontPair, minuiDark.bokeh], [false, "minui", "minui", "general-sans", false]);
  r.eq("themes.apply(aurora) carries bokeh", engine.themes.apply("aurora", "default", true).bokeh, true);
  r.eq("themes.setFontPair: picked pair kept, preset without one uses it", (engine.themes.apply("nord", "default", true), engine.themes.setFontPair("fraunces-inter", "default", true).fontPair), "fraunces-inter");
  engine.themes.setFontPair("sentient-switzer", "default", true);
  r.eq("themes.apply back to the default", engine.themes.apply("cool-grey", "default", true).active, "cool-grey");
  const langs = engine.settingsRoom.languages("default", true);
  r.eq("settingsRoom.languages: upstream's 16 in order, English first", [langs.languages.length, langs.languages[0].code, langs.languages[0].flags, langs.current], [16, "en", ["\u{1F1FA}\u{1F1F8}"], "en"]);
  r.eq("settingsRoom.languages: Indonesian has no flag (upstream shows its code)", langs.languages.find((l) => l.code === "id").flags, []);
  r.eq("settingsRoom.flagEmoji(Portuguese (Brazil))", engine.settingsRoom.flagEmoji("Portuguese (Brazil)"), "\u{1F1E7}\u{1F1F7}");
  engine.settingsRoom.commit("uiLanguage", "fr", "default", true);
  r.eq("commit uiLanguage fr reaches settings, i18n and the pane", [engine.settingsRoom.languages("default", true).current, engine.settingsRoom.applyUiLanguage("default", true), engine.settingsRoom.pane("default", true).language.greeting], ["fr", "fr", "Bonjour"]);
  r.eq("installUiCatalog registers a host-fed catalog and t() follows it", [engine.settingsRoom.uiCatalogInstalled("fr"), engine.settingsRoom.installUiCatalog("fr", JSON.stringify({ "This is how a subtitle will look.": "Voici un sous-titre." })), engine.settingsRoom.uiCatalogInstalled("fr"), engine.settingsRoom.pane("default", true).subtitle.text], [false, true, true, "Voici un sous-titre."]);
  engine.settingsRoom.commit("uiLanguage", "en", "default", true);
  const pane =engine.settingsRoom.pane("default", true);
  r.eq("settingsRoom.pane: subtitle sample at 0.55x, flags, line groups", [pane.subtitle.px, pane.subtitle.flags.length > 0, pane.playback.length, pane.setup.length, pane.interface.length, pane.overscanLabel], [18, true, 7, 4, 1, "Off"]); // playback: six upstream lines + the TV's X-Ray; setup: + AI search
  r.ok("settingsRoom.pane: services carry name and tint", pane.services.length > 0 && pane.services.every((s) => s.label && s.tint.startsWith("#")));
  const setupKey = engine.settings.sourceKeyFor("default", true);
  const before = engine.settingsRoom.pane("default", true).setup[1][1];
  engine.settings.patch({ tmdbKey: "0123456789abcdef0123456789abcdef" }, setupKey);
  const smokeList = engine.live.addPlaylist("Smoke setup", "https://example.invalid/setup.m3u", null);
  const after = String(Number(before) + 1);
  const setupRows = engine.settingsRoom.controls("setup", "default", true);
  r.eq("ST-1: setup push rows report what is connected and how many playlists", setupRows.filter((c) => c.kind === "push").map((c) => c.detail), ["Connected: TMDB", `${after} added`, "Add an OpenRouter or Groq key from your phone"]);
  r.eq("settingsRoom.pane(setup) lines follow", engine.settingsRoom.pane("default", true).setup, [["TMDB", "On"], ["Live TV playlists", after], ["AI search", "None"], ["Setup", "TMDB"]]);
  engine.live.removePlaylist(smokeList.id);
  engine.settings.patch({ tmdbKey: "" }, setupKey);
  const f = engine.onboarding.facts("default", true);
  r.eq("onboarding.facts: counts and the stock fan with no picks", [typeof f.servicesOn, f.art.length, f.art[0].startsWith("https://image.tmdb.org/t/p/w342/")], ["number", 5, true]);
  r.eq("intro.poolSave refuses fewer than 16 urls", [engine.intro.poolSave(["https://x/1.jpg"]), engine.intro.poolLoad()], [0, []]);
  const urls = Array.from({ length: 120 }, (_, i) => `https://x/${i}.jpg`);
  r.eq("intro.poolSave keeps 96, poolLoad reads them back", [engine.intro.poolSave(urls), engine.intro.poolLoad()[95]], [96, "https://x/95.jpg"]);
}

// ------------------------------------------------------------- live EPG (recorded host)
{
  const now = Date.now();
  const fmt = (ms) => { const d = new Date(ms); const p = (n) => String(n).padStart(2, "0"); return `${d.getUTCFullYear()}${p(d.getUTCMonth() + 1)}${p(d.getUTCDate())}${p(d.getUTCHours())}${p(d.getUTCMinutes())}${p(d.getUTCSeconds())} +0000`; };
  const xml = `<?xml version="1.0"?><tv><channel id="cnn.us"><display-name>CNN</display-name></channel>
<programme start="${fmt(now - 20 * 60000)}" stop="${fmt(now + 40 * 60000)}" channel="cnn.us"><title>Newsroom</title><desc>Live news.</desc><category>News</category></programme>
<programme start="${fmt(now + 40 * 60000)}" stop="${fmt(now + 100 * 60000)}" channel="cnn.us"><title>The Lead</title></programme></tv>`;
  const m3u = `#EXTM3U\n#EXTINF:-1 tvg-id="cnn.us" tvg-logo="https://x/cnn.png" group-title="News",CNN\nhttps://example.invalid/cnn.m3u8\n#EXTINF:-1 group-title="Sports",ESPN\nhttps://example.invalid/espn.m3u8\n`;
  const rec = loadEngine({});
  rec.node.host.fetch = async (req) => {
    const ok = (body, type) => ({ status: 200, statusText: "OK", headers: { "content-type": type }, url: req.url, body });
    if (req.url.endsWith("/list.m3u")) return ok(m3u, "audio/x-mpegurl");
    if (req.url.endsWith("/guide.xml")) return ok(xml, "application/xml");
    return { status: 404, statusText: "Not Found", headers: {}, url: req.url, body: "" };
  };
  const pl = rec.engine.live.addPlaylist("Test", "https://epg.example.invalid/list.m3u", "https://epg.example.invalid/guide.xml");
  const view = await rec.engine.live.channels(pl.id);
  r.eq("live.channels (recorded M3U) groups", view.groups.map((g) => g.name), ["News", "Sports"]);
  const epg = await rec.engine.live.loadEpg(pl.id);
  r.ok("live.loadEpg parses XMLTV", epg.channels === 1 && epg.programs === 2, JSON.stringify(epg));
  const nn = rec.engine.live.nowNext(pl.id, view.channels.map((c) => c.id), now);
  const cnn = nn.find((x) => x.id === view.channels.find((c) => c.name === "CNN").id);
  r.ok("nowNext matches tvg-id and picks the airing programme", cnn && cnn.known && cnn.now && cnn.now.title === "Newsroom" && cnn.next && cnn.next.title === "The Lead", JSON.stringify(cnn));
  const espn = nn.find((x) => x.id !== cnn.id);
  r.ok("nowNext: unmatched channel is unknown, not guessed", espn && espn.known === false);
  const sched = rec.engine.live.schedule(pl.id, cnn.id, now, now + 3 * 3600000);
  r.eq("live.schedule returns the window's programmes", sched.map((p) => p.title), ["Newsroom", "The Lead"]);
  const slot = 30 * 60000;
  const ws = Math.floor((now - 60 * 60000) / slot) * slot;
  const lanesOut = rec.engine.live.lanes(pl.id, [cnn.id, espn.id], ws, ws + 6 * 3600000);
  const cnnLane = lanesOut[0].cells, espnLane = lanesOut[1].cells;
  r.ok("live.lanes: gapless, contiguous, ends at the window edge", cnnLane[0].startMs === ws && cnnLane[cnnLane.length - 1].endMs === ws + 6 * 3600000 && cnnLane.every((c, i) => i === 0 || c.startMs === cnnLane[i - 1].endMs), JSON.stringify(cnnLane.map((c) => [c.program && c.program.title, (c.endMs - c.startMs) / 60000])));
  r.eq("live.lanes reports catch-up capability per channel (none in this playlist)", lanesOut.map((l) => l.catchup), [false, false]);
  r.eq("live.catchupUrl is null without catch-up attrs", rec.engine.live.catchupUrl(pl.id, cnn.id, now - 3600000, now - 1800000), null);
  {
    // An Xtream-shaped live URL infers xtream catch-up: /timeshift/<user>/<pass>/<minutes>/<YYYY-MM-DD:HH-MM>/<id>.<ext>
    const m3u3 = `#EXTM3U\n#EXTINF:-1 tvg-id="x" group-title="Sports" catchup="xc" catchup-days="3",ESPN X\nhttp://host.invalid:8080/live/user1/pass1/555.ts\n`;
    rec.node.host.fetch = async (req) => ({ status: 200, statusText: "OK", headers: { "content-type": "audio/x-mpegurl" }, url: req.url, body: m3u3 });
    const plx = rec.engine.live.addPlaylist("XC", "https://xc.example.invalid/list.m3u");
    const vx = await rec.engine.live.channels(plx.id);
    const cu = rec.engine.live.catchupUrl(plx.id, vx.channels[0].id, Date.UTC(2026, 8, 23, 18, 0), Date.UTC(2026, 8, 23, 19, 0));
    r.ok("live.catchupUrl builds an Xtream timeshift URL", cu && /\/timeshift\/user1\/pass1\/60\/2026-09-23:18-00\/555\.ts/.test(cu.url), JSON.stringify(cu));
    r.eq("live.lanes marks the catch-up channel", rec.engine.live.lanes(plx.id, [vx.channels[0].id], now, now + 3600000)[0].catchup, true);
  }
  r.ok("live.lanes: programmes keep exact bounds, gaps are half-hour slices", cnnLane.some((c) => c.program && c.program.title === "Newsroom" && Math.abs(c.startMs - (now - 20 * 60000)) < 1000) && espnLane.every((c) => c.program === null && c.endMs - c.startMs <= slot));
  {
    // epg-match-modal + epg-map: ESPN has no tvg-id and no name match; the viewer matches it by hand.
    const espnId = view.channels.find((c) => c.name === "ESPN").id;
    const seeded = rec.engine.live.epgCandidates(pl.id, espnId, null);
    r.ok("live.epgCandidates seeds the search with the channel name (no hit for ESPN)", seeded.query === "ESPN" && seeded.total === 1 && seeded.entries.length === 0 && seeded.current === null, JSON.stringify(seeded));
    const all = rec.engine.live.epgCandidates(pl.id, espnId, "");
    r.eq("live.epgCandidates with an empty query lists every guide channel with a sample title", all.entries, [{ id: "cnn.us", sample: "Newsroom" }]);
    r.eq("live.epgCandidates matches the sample programme title too", rec.engine.live.epgCandidates(pl.id, espnId, "zzz newsroom").entries.map((e) => e.id), ["cnn.us"]);
    r.eq("live.setEpgMatch stores the match", rec.engine.live.setEpgMatch(espnId, "cnn.us"), "cnn.us");
    const mapped = rec.engine.live.nowNext(pl.id, [espnId], now)[0];
    r.ok("nowNext honours the manual match", mapped.known && mapped.now && mapped.now.title === "Newsroom", JSON.stringify(mapped));
    r.ok("live.lanes honour the manual match", rec.engine.live.lanes(pl.id, [espnId], ws, ws + 6 * 3600000)[0].cells.some((c) => c.program && c.program.title === "The Lead"));
    const again = await rec.engine.live.channels(pl.id);
    r.eq("live.channels reports the channel's match", again.channels.find((c) => c.id === espnId).epgMatch, "cnn.us");
    r.eq("live.epgCandidates reports the current match", rec.engine.live.epgCandidates(pl.id, espnId, "").current, "cnn.us");
    r.eq("live.setEpgMatch(null) clears the match", rec.engine.live.setEpgMatch(espnId, null), null);
    r.eq("nowNext falls back to automatic matching after clearing", rec.engine.live.nowNext(pl.id, [espnId], now)[0].known, false);
    rec.engine.live.setEpgMatch(espnId, "cnn.us");
    rec.engine.live.removePlaylist(pl.id);
    r.eq("live.removePlaylist drops the source's EPG matches", rec.engine.live.epgCandidates(pl.id, espnId, "").current, null);
  }
  {
    // bp-live.tsx chips from use-live-home rails: themes (3+ matches), big groups (4+), VOD lines dropped.
    const names = ["CNN", "BBC News", "Sky News", "Fox News"].map((n) => `#EXTINF:-1 group-title="News",${n}\nhttps://example.invalid/${n.replace(/ /g, "")}.m3u8`);
    const vod = `#EXTINF:-1 group-title="Movies",Some Film\nhttp://host.invalid:8080/movie/u/p/1.mkv`;
    const m3uc = `#EXTM3U\n${names.join("\n")}\n#EXTINF:-1 group-title="Sports",ESPN\nhttps://example.invalid/espn.m3u8\n${vod}\n`;
    rec.node.host.fetch = async (req) => ({ status: 200, statusText: "OK", headers: { "content-type": "audio/x-mpegurl" }, url: req.url, body: m3uc });
    const plc = rec.engine.live.addPlaylist("Cats", "https://cats.example.invalid/list.m3u");
    const vc = await rec.engine.live.channels(plc.id);
    r.ok("live.channels drops VOD lines (isLiveChannel)", vc.channels.length === 5 && !vc.channels.some((c) => c.name === "Some Film"), JSON.stringify(vc.channels.map((c) => c.name)));
    const news = vc.categories.find((c) => c.key === "theme:news");
    r.ok("live.channels categories: News theme rail with ids, then the News group rail", news && news.ids.length === 4 && news.group === null && vc.categories.some((c) => c.key === "cat:News" && c.group === "News" && c.count === 4) && !vc.categories.some((c) => c.group === "Sports"), JSON.stringify(vc.categories.map((c) => [c.key, c.count])));
    rec.engine.live.toggleGroupHidden(plc.id, "News");
    const hid = await rec.engine.live.channels(plc.id);
    r.ok("a hidden group loses its chip and its channels leave theme rails", !hid.categories.some((c) => c.group === "News") && !hid.categories.some((c) => c.key === "theme:news"), JSON.stringify(hid.categories.map((c) => [c.key, c.count])));
    rec.engine.live.removePlaylist(plc.id);
  }
  {
    // A sports channel in the playlist should match a fixture by team names (iptv-match).
    const m3u2 = `#EXTM3U\n#EXTINF:-1 group-title="Sports",ESPN Lakers vs Celtics\nhttps://example.invalid/lakers.m3u8\n#EXTINF:-1 group-title="News",CNN\nhttps://example.invalid/cnn.m3u8\n`;
    rec.node.host.fetch = async (req) => ({ status: 200, statusText: "OK", headers: { "content-type": "audio/x-mpegurl" }, url: req.url, body: m3u2 });
    rec.engine.live.addPlaylist("Sports list", "https://sports.example.invalid/list.m3u");
    const game = { id: "g1", league: "NBA", state: "in", detail: "Q2 5:12", home: { id: "1", name: "Boston Celtics", abbr: "BOS", logo: "", score: "50", winner: false }, away: { id: "2", name: "Los Angeles Lakers", abbr: "LAL", logo: "", score: "48", winner: false }, startMs: Date.now() - 3600000 };
    const ws = rec.engine.sports.whoSides(game);
    r.ok("sports.whoSides: both NBA teams open a team profile", ws.home === true && ws.away === true, JSON.stringify(ws));
    r.eq("sports.whoSides: a TBD side has no profile", rec.engine.sports.whoSides({ ...game, home: { ...game.home, id: "", name: "TBD" } }).home, false);
    const w = await rec.engine.sports.watch(game);
    r.ok("sports.watch matches a Lakers/Celtics channel by team names", w.sources >= 1 && w.channels.length >= 1 && /lakers/i.test(w.channels[0].name) && ["exact", "likely", "possible"].includes(w.channels[0].tier), JSON.stringify({ plan: w.plan, first: w.channels[0] && [w.channels[0].name, w.channels[0].tier, w.channels[0].copy, w.channels[0].reasons] }));
    r.ok("sports.watch does not offer the news channel", !w.channels.some((c) => /cnn/i.test(c.name)));
    r.eq("sports.toggleAttachedChannel pins", rec.engine.sports.toggleAttachedChannel("NBA", w.channels[0].channelId), true);
    const w2 = await rec.engine.sports.watch(game);
    r.ok("an attached channel is exact-tier and plans direct play", w2.plan === "channel" && w2.channels[0].attached === true && w2.channels[0].copy === "Your pick for this competition", JSON.stringify(w2.channels[0]));
  }
  r.ok("xtream login URL is detected and stored with creds + derived EPG", (() => {
    const x = rec.engine.live.addPlaylist("X", "http://host.invalid:8080/get.php?username=u&password=p&type=m3u_plus");
    return x.kind === "xtream" && x.xtream && x.xtream.username === "u" && /xmltv\.php/.test(x.epgUrl || "");
  })());
  {
    // Stage 8 remainder: Multiview prefs (lib/multiview/store.ts) and Playlist VOD (views/playlist-vod.tsx).
    const L = rec.engine.live, V = rec.engine.liveVod;
    r.eq("live.multiviewPrefs defaults to the 2x2 layout, four slots, banner shown", L.multiviewPrefs(), { layout: "2x2", slotCount: 4, maxSlots: 4, bannerDismissed: false });
    r.eq("live.setMultiviewLayout stores a layout and its slot count", L.setMultiviewLayout("2v"), { layout: "2v", slotCount: 2 });
    r.eq("live.setMultiviewLayout ignores an unknown layout", L.setMultiviewLayout("9x9"), { layout: "2v", slotCount: 2 });
    L.dismissMultiviewBanner();
    r.ok("live.dismissMultiviewBanner is remembered", L.multiviewPrefs().bannerDismissed === true && L.multiviewPrefs().layout === "2v");
    const m3uv = [
      "#EXTM3U",
      '#EXTINF:-1 group-title="News",CNN', "https://example.invalid/cnn.m3u8",
      '#EXTINF:-1 tvg-type="movie" tvg-logo="https://x/dune.jpg" group-title="Movies",EN - Dune Part Two (2024) 1080p', "http://host.invalid:8080/movie/u/p/11.mkv",
      '#EXTINF:-1 group-title="Movies",Arrival 2016', "http://host.invalid:8080/movie/u/p/12.mp4",
      '#EXTINF:-1 group-title="Series",Severance S02E01', "http://host.invalid:8080/series/u/p/21.mkv",
      '#EXTINF:-1 group-title="Series",Severance S01E02', "http://host.invalid:8080/series/u/p/22.mkv",
      '#EXTINF:-1 group-title="Series",Severance S01E01', "http://host.invalid:8080/series/u/p/23.mkv",
    ].join("\n") + "\n";
    rec.node.host.fetch = async (req) => ({ status: 200, statusText: "OK", headers: { "content-type": "audio/x-mpegurl" }, url: req.url, body: m3uv });
    const plv = L.addPlaylist("VOD list", "https://vod.example.invalid/list.m3u");
    const lv = await L.channels(plv.id);
    r.eq("the live list still holds only the live channel", lv.channels.map((c) => c.name), ["CNN"]);
    const srcs = V.sources();
    r.ok("liveVod.sources lists the playlist and keeps an active one", srcs.sources.some((s) => s.id === plv.id && s.kind === "m3u") && typeof srcs.activeId === "string", JSON.stringify(srcs));
    V.setActive(plv.id);
    r.eq("liveVod.setActive remembers the source", V.sources().activeId, plv.id);
    const st = await V.load(plv.id);
    r.ok("liveVod.load classifies an M3U: two movies, one series", st.movies === 2 && st.series === 1 && !st.moviesLoading && st.movieError === null, JSON.stringify(st));
    const mp = V.page(plv.id, "movies", "", 0, 60);
    r.eq("liveVod.page(movies): cleaned titles, A-Z, years", mp.items.map((m) => [m.title, m.year]), [["Arrival", 2016], ["Dune Part Two", 2024]]);
    r.eq("liveVod.page filters with the query (normalizeArabic, substring)", V.page(plv.id, "movies", "DUNE", 0, 60).items.map((m) => m.title), ["Dune Part Two"]);
    const sp = V.page(plv.id, "series", "", 0, 60);
    r.ok("liveVod.page(series): grouped by show with an episode count", sp.total === 1 && sp.items[0].title === "Severance" && sp.items[0].subtitle === "3 episodes", JSON.stringify(sp));
    const sd = await V.series(plv.id, sp.items[0].id);
    r.eq("liveVod.series: seasons and episodes in order", [sd.seasons, sd.episodes.map((e) => [e.season, e.episode])], [[1, 2], [[1, 1], [1, 2], [2, 1]]]);
    const pm = V.playMovie(plv.id, mp.items[1].id);
    r.ok("liveVod.playMovie: vod: meta, the file, the year underneath", pm.meta.id.startsWith("vod:") && pm.meta.type === "movie" && pm.url.endsWith("/11.mkv") && pm.subtitle === "2024" && pm.meta.poster === "https://x/dune.jpg", JSON.stringify(pm));
    const pe = V.playEpisode(plv.id, sd.id, 1, 2);
    r.ok("liveVod.playEpisode: series meta and the S/E line", pe.meta.id === sd.id && pe.season === 1 && pe.episode === 2 && pe.subtitle === "Severance · S1 · E2", JSON.stringify(pe));
    r.eq("liveVod.saveProgress keeps a local spot only", V.saveProgress({ meta: pe.meta, season: 1, episode: 2, positionMs: 600000, durationMs: 2400000 }), { watched: false, cloud: "none" });
    r.eq("liveVod.startPosition reads it back", V.startPosition(pe.meta.id, 1, 2).ms, 600000);
    r.eq("a watched episode clears its spot", [V.saveProgress({ meta: pe.meta, season: 1, episode: 2, positionMs: 2300000, durationMs: 2400000 }).watched, V.startPosition(pe.meta.id, 1, 2).ms], [true, 0]);
    r.eq("a VOD id is kept only in the resume store (no Continue Watching, no watched flags)", [...rec.node.storage.entries()].filter(([k, v]) => k !== "harbor.resume" && /vod:series/.test(String(v))).map(([k]) => k), []);
    // Xtream: the VOD and series APIs, episodes fetched when a series opens (xtream-vod.ts).
    rec.node.host.fetch = async (req) => {
      const json = (body) => ({ status: 200, statusText: "OK", headers: { "content-type": "application/json" }, url: req.url, body: JSON.stringify(body) });
      const action = new URL(req.url).searchParams.get("action");
      if (action === "get_vod_categories") return json([{ category_id: "1", category_name: "Action" }]);
      if (action === "get_vod_streams") return json([{ stream_id: 7, name: "Heat (1995)", stream_icon: "https://x/heat.jpg", category_id: "1", container_extension: "mp4" }, { stream_id: 8, name: "Live thing", stream_type: "live" }]);
      if (action === "get_series_categories") return json([{ category_id: "5", category_name: "Drama" }]);
      if (action === "get_series") return json([{ series_id: 44, name: "The Wire", cover: "https://x/wire.jpg", category_id: "5" }]);
      if (action === "get_series_info") return json({ episodes: { "1": [{ id: 901, episode_num: 1, title: "The Target", container_extension: "mkv", info: { duration_secs: 3600, plot: "Pilot." } }, { id: 902, episode_num: 2, title: "The Detail", container_extension: "mkv" }] } });
      return { status: 404, statusText: "Not Found", headers: {}, url: req.url, body: "" };
    };
    const xv = L.addStructured("xtream", "XV", "", "", "http://xv.example.invalid:8080", "user", "pass");
    const xs = await V.load(xv.id);
    r.ok("liveVod.load (Xtream): one movie (live rows dropped), one series, totals", xs.kind === "xtream" && xs.movies === 1 && xs.series === 1 && xs.movieTotal === 2 && xs.seriesTotal === 1 && typeof xs.fetchedAt === "number", JSON.stringify(xs));
    const xm = V.page(xv.id, "movies", "", 0, 60).items[0];
    r.ok("Xtream movie: /movie/<user>/<pass>/<id>.<ext>, category as group", xm.url === "http://xv.example.invalid:8080/movie/user/pass/7.mp4" && xm.group === "Action" && xm.year === 1995, JSON.stringify(xm));
    const xsr = V.page(xv.id, "series", "", 0, 60).items[0];
    r.eq("Xtream series card says its category until opened", xsr.subtitle, "Drama");
    const xd = await V.series(xv.id, xsr.id);
    r.ok("liveVod.series (Xtream): get_series_info episodes with titles, plot and runtime", xd.episodes.length === 2 && xd.episodes[0].title === "The Target" && xd.episodes[0].plot === "Pilot." && xd.episodes[0].durationSec === 3600 && xd.episodes[1].url === "http://xv.example.invalid:8080/series/user/pass/902.mkv", JSON.stringify(xd.episodes));
    V.saveProgress({ meta: { id: xd.id }, season: 1, episode: 1, positionMs: 1800000, durationMs: 3600000 });
    const xd2 = await V.series(xv.id, xsr.id);
    r.ok("episode progress follows the saved spot (episode-row episodeProgressOf)", Math.abs(xd2.episodes[0].progress - 0.5) < 1e-9 && xd2.episodes[0].leftSec === 1800 && xd2.episodes[1].progress === 0, JSON.stringify(xd2.episodes.map((e) => [e.progress, e.leftSec])));
    L.removePlaylist(xv.id);
    r.eq("live.removePlaylist drops the VOD library too", V.page(xv.id, "movies", "", 0, 60).libraryTotal, 0);
    L.removePlaylist(plv.id);
  }
  rec.dispose();
}

// -------------------------------- Home / Discover / Anime bands (HM-1, HM-4, HM-5, DS-3)
{
  r.eq("collectionsRoom.curatedRow is empty without a TMDB key (bp-home showCollections)", await engine.collectionsRoom.curatedRow("default", true, 30), []);
  r.eq("collectionsRoom.tmdbCard is null without a TMDB key", await engine.collectionsRoom.tmdbCard("default", true, 10, "Star Wars Collection"), null);
  r.eq("addonsRoom.bandPosters for an unknown base is empty (below the 14-poster mosaic floor)", await engine.addonsRoom.bandPosters("https://nowhere.invalid"), []);
  const srcs = engine.discoverRoom.animeAwardSources();
  r.ok("discoverRoom.animeAwardSources: five bundled sources, Crunchyroll first, with winners", srcs.length === 5 && srcs[0].id === "crunchyroll" && srcs[0].name === "Crunchyroll Anime Awards" && srcs.every((x) => typeof x.wins === "number") && srcs[0].wins > 20, JSON.stringify(srcs));
  const cr = engine.discoverRoom.animeAward("crunchyroll");
  r.ok("discoverRoom.animeAward: the Grand category first, winners newest first", cr.categories[0].isAOTY && cr.categories[0].winners.every((w, i, a) => i === 0 || a[i - 1].year >= w.year), JSON.stringify(cr.categories[0].winners.slice(0, 3)));
  r.ok("discoverRoom.animeAward: per-year counts add up to the recorded winners", cr.perYear.reduce((n, y) => n + y.count, 0) === cr.totalWins && cr.years.length === cr.perYear.length && /^\d{4} - \d{4}$/.test(cr.yearSpan), JSON.stringify({ total: cr.totalWins, span: cr.yearSpan }));
  r.eq("discoverRoom.animeAward falls back to Crunchyroll for an unknown source", engine.discoverRoom.animeAward("nope").id, "crunchyroll");
  r.ok("discoverRoom.animeAward marks winners that map to an anime id", cr.categories[0].winners.some((w) => w.mapped));
  const opened = await engine.discoverRoom.animeAwardOpen("Demon Slayer: Kimetsu no Yaiba", 2020, "default", true);
  r.ok("discoverRoom.animeAwardOpen opens a mapped winner by its kitsu id without TMDB", opened && opened.id === "kitsu:41370" && opened.type === "series", JSON.stringify(opened));
  r.eq("discoverRoom.animeAwardOpen: an unmapped winner without a TMDB key stays inert", await engine.discoverRoom.animeAwardOpen("Some Unknown Short Film", 2019, "default", true), null);
  const corner = await engine.cards.heroAwards({ id: "kitsu:41370", type: "series", name: "Demon Slayer: Kimetsu no Yaiba", releaseInfo: "2019" });
  r.ok("cards.heroAwards: an anime winner reads the bundled anime wins", corner && corner.kind === "anime" && / Winner$/.test(corner.headline) && corner.won && corner.lines.length >= 1, JSON.stringify(corner));
  r.eq("cards.heroAwards: a title with no awards has no corner", await engine.cards.heroAwards({ id: "tmdb:movie:1", type: "movie", name: "Nothing Won Here", releaseInfo: "2001" }), null);
}

// ----------------------------------------------- player chrome + subtitle panel (recorded host)
// bp-player-subtitles / bp-subtitle-find / bp-subtitle-tune: track rows, Find more over a fake
// Cinemeta + OpenSubtitles v3, presets; player.prefs for the up-next lead and seek steps.
{
  const rec = loadEngine({ storage: new Map([["harbor.profiles.v1", JSON.stringify({ activeId: "default", profiles: [{ id: "default", isPrimary: true }] })]]) });
  const hits = [];
  rec.node.host.fetch = async (req) => {
    hits.push(req.url);
    const json = (body) => ({ status: 200, statusText: "OK", headers: { "content-type": "application/json" }, url: req.url, body: JSON.stringify(body) });
    if (req.url.startsWith("https://v3-cinemeta.strem.io/catalog/series/top/search=")) return json({ metas: [{ id: "tt0903747", type: "series", name: "Breaking Bad", releaseInfo: "2008-2013" }] });
    if (req.url.startsWith("https://v3-cinemeta.strem.io/catalog/movie/top/search=")) return json({ metas: [{ id: "tt1000001", type: "movie", name: "Breaking Bad Movie", releaseInfo: "2019" }] });
    if (req.url === "https://opensubtitles-v3.strem.io/subtitles/series/tt0903747:2:5.json") return json({ subtitles: [
      { id: "1", url: "https://subs.example.invalid/a.srt", lang: "eng" },
      { id: "2", url: "https://subs.example.invalid/b.srt", lang: "eng", m: "Breaking.Bad.S02E05.SDH.HI" },
      { id: "3", url: "https://subs.example.invalid/c.srt", lang: "fre" },
    ] });
    return { status: 404, statusText: "Not Found", headers: {}, url: req.url, body: "" };
  };
  const e = rec.engine;
  r.eq("player.prefs: upstream defaults (auto lead, auto-advance on, 10 s steps)", e.player.prefs("default", true), { autoPlayNextEpisode: true, nextEpisodeLeadSec: -1, seekBackStepSec: 10, seekForwardStepSec: 10, autoNextStreamOnStall: false, autoNextStreamOnStallSec: 10, instantPlay: true });
  e.settings.patch({ autoNextStreamOnStall: true, autoNextStreamOnStallSec: 400 });
  r.eq("player.prefs: autoNextStreamOnStall with the wait clamped like stall-wait.ts (5–120 s)", [e.player.prefs("default", true).autoNextStreamOnStall, e.player.prefs("default", true).autoNextStreamOnStallSec], [true, 120]);
  e.settings.patch({ autoNextStreamOnStall: false, autoNextStreamOnStallSec: 10 });
  // Auto / mpv / native (AVPlayer): use-player-bridge.ts chosenEngine + player-utils.ts pickBridge, TV mapping.
  const pe = (want, h) => e.player.pickEngine(want, h).engine;
  r.eq("player.pickEngine: Auto keeps MKV / not-web-ready / raw TS live on mpv", [
    pe("auto", { url: "https://cdn.example.invalid/Movie.2160p.DV.mkv", hdrFormat: "DV", container: "mkv" }),
    pe("auto", { url: "https://cdn.example.invalid/master.m3u8", notWebReady: true }),
    pe("auto", { url: "http://iptv.example.invalid/live/1/2/3.ts", isLive: true }),
  ], ["mpv", "mpv", "mpv"]);
  r.eq("player.pickEngine: Auto hands web-ready HLS (live or not) and DV MP4 to AVPlayer", [
    pe("auto", { url: "https://cdn.example.invalid/hls/master.m3u8?token=1" }),
    pe("auto", { url: "http://iptv.example.invalid/live/ch.m3u8", isLive: true }),
    pe("auto", { url: "https://cdn.example.invalid/dl/abc", filename: "Movie.2019.2160p.WEB-DL.DV.HEVC.mp4" }),
    pe("auto", { url: "https://cdn.example.invalid/dl/abc.mp4", hdrFormat: "DV+HDR10", container: "mp4" }),
  ], ["native", "native", "native", "native"]);
  r.eq("player.pickEngine: explicit settings win; a native failure retries on mpv", [
    pe("html5", { url: "https://cdn.example.invalid/a.mkv" }),
    pe("mpv", { url: "https://cdn.example.invalid/master.m3u8", isLive: true }),
    pe("auto", { url: "https://cdn.example.invalid/master.m3u8", fallbackTried: true }),
    e.player.engineFor("default", true, { url: "https://cdn.example.invalid/a.mkv" }).want,
  ], ["native", "mpv", "mpv", "auto"]);
  // Per-show track memory + track rules (use-track-autoload.ts, lib/player-prefs.ts, subtitle-memory.ts).
  {
    const D = e.settings.DEFAULT;
    const A = (id, lang, title, extra = {}) => ({ id, type: "audio", lang, title, ...extra });
    const S = (id, lang, title, extra = {}) => ({ id, type: "sub", lang, title, ...extra });
    const commentary = [A(1, "eng", "Director's Commentary", { selected: true, default: true }), A(2, "eng", "Main"), A(3, "jpn", null)];
    const p1 = e.player.trackPlan("default", true, null, commentary);
    r.eq("player.trackPlan: trackBlockWords (default commentary) skips the commentary track", [p1.audioId, D.trackBlockWords], ["2", ["commentary"]]);
    r.eq("player.planTracks: an empty block list keeps the default commentary track", e.player.planTracks({ ...D, trackBlockWords: [] }, null, commentary).audioId, null);
    const subs = [A(1, "eng", null, { selected: true }), S(1, "eng", "English"), S(2, "eng", "English Forced", { forced: true }), S(3, "spa", "Spanish")];
    const p2 = e.player.planTracks(D, null, subs);
    r.eq("player.planTracks: picks the preferred-language full subtitle, never the forced one", [p2.sub, p2.subId, p2.subDelaySec], ["select", "1", 0]);
    r.eq("player.planTracks: subtitlesOffByDefault turns subtitles off", e.player.planTracks({ ...D, subtitlesOffByDefault: true }, null, subs).sub, "off");
    const forced = e.player.planTracks({ ...D, forcedSubsWhenNativeAudio: true }, null, subs);
    r.eq("player.planTracks: forcedSubsWhenNativeAudio picks the forced track under native audio", [forced.sub, forced.subId], ["select", "2"]);
    const foreignAudio = e.player.planTracks({ ...D, forcedSubsWhenNativeAudio: true, preferredAudioLangs: ["Japanese"] }, null, [A(1, "jpn", null), ...subs.slice(1)]);
    r.eq("player.planTracks: forcedSubsWhenNativeAudio keeps full subtitles under foreign audio", foreignAudio.subId, "1");
    r.eq("player.planTracks: secondarySubLang auto-picks the second subtitle", e.player.planTracks({ ...D, secondarySubLang: "Spanish" }, null, subs).secondaryId, "3");
    // Memory round trip: episode 1's picks carry to episode 2 of the same show.
    const ep1 = { metaId: "tt7000001", season: 1, episode: 1, genres: ["Drama"] };
    const ep2 = { ...ep1, episode: 2 };
    r.ok("player.remember*: audio language, subtitle language and delay are saved", e.player.rememberAudio(ep1, A(3, "jpn", null)) &&
      e.player.rememberSubtitle(ep1, S(3, "spa", "Spanish")) && e.player.rememberSubDelay(ep1, 1.5), "");
    const mem = e.player.trackMemory(ep2);
    r.eq("player.trackMemory: per-show prefs are keyed by the series id", [mem.prefs.audioLang, mem.prefs.subLang, mem.prefs.subsOff, mem.prefs.subDelaySec, mem.subtitle], ["jpn", "spa", false, 1.5, null]);
    r.ok("player prefs persist under upstream's key", JSON.parse(rec.node.storage.get("harbor.player.prefs.v1") ?? "{}").tt7000001?.audioLang === "jpn", "");
    const next = e.player.trackPlan("default", true, ep2, [A(1, "eng", null, { selected: true }), A(2, "jpn", null), S(1, "eng", "English"), S(2, "spa", "Spanish")]);
    r.eq("player.trackPlan: the next episode gets the show's audio, subtitle language and delay", [next.audioId, next.sub, next.subId, next.subDelaySec], ["2", "select", "2", 1.5]);
    e.player.rememberSubtitle(ep2, null);
    r.eq("player.trackPlan: subtitles turned off stay off for the show", e.player.trackPlan("default", true, { ...ep1, episode: 3 }, subs).sub, "off");
    // Per-episode subtitle memory: the exact embedded track comes back on a revisit.
    const movie = { metaId: "tt7000002" };
    const movieSubs = [S(1, "eng", "English"), S(4, "eng", "English SDH", { hearingImpaired: true })];
    e.player.rememberSubtitle(movie, movieSubs[1]);
    const back = e.player.trackPlan("default", true, movie, movieSubs);
    r.eq("player.trackPlan: a revisit restores the exact remembered track", [back.sub, back.subId], ["select", "4"]);
    // An added subtitle remembers its download URL, and comes back as a restore on the next visit.
    const film = { metaId: "tt7000003", filename: "Film.2020.1080p.WEB-DL.x264-GRP.mkv" };
    e.player.noteSubtitleSource("/caches/subs/os_1.srt", "https://subs.example.invalid/os_1.srt");
    e.player.rememberSubtitle(film, S(1001, "en", "Film.2020.1080p", { external: true, externalFilename: "os_1.srt" }));
    const again = e.player.trackPlan("default", true, film, [S(1, "fre", "French")]);
    r.eq("player.trackPlan: a remembered added subtitle is fetched again (same release)", again.restore && again.restore.source, "https://subs.example.invalid/os_1.srt");
    const otherRelease = e.player.trackPlan("default", true, { ...film, filename: "Film.2020.2160p.BluRay.x265-OTHER.mkv" }, [S(1, "fre", "French")]);
    r.eq("player.trackPlan: another release does not restore it (subtitle-memory streamKey)", otherRelease.restore, null);
    // Per-show speed (shell-layer.tsx onRate → player-prefs rate; use-track-autoload applies it on load).
    const rateShow = { metaId: "tt7000004", season: 1, episode: 1 };
    r.eq("player.startRate: nothing remembered → 1 at the default settings", e.player.startRate("default", true, rateShow), 1);
    e.settings.patch({ defaultPlaybackSpeed: 1.25 });
    r.eq("player.startRate: nothing remembered → settings.defaultPlaybackSpeed", e.player.startRate("default", true, rateShow), 1.25);
    r.eq("player.rememberRate: bad rates are refused", [e.player.rememberRate(rateShow, 0), e.player.rememberRate(null, 1.5), e.player.rememberRate(rateShow, Number.NaN)], [false, false, false]);
    r.ok("player.rememberRate saves the show's speed", e.player.rememberRate(rateShow, 1.5), "");
    r.eq("player.startRate: the show's rate beats the default, on any episode; other shows keep the default",
      [e.player.startRate("default", true, { ...rateShow, episode: 5 }), e.player.startRate("default", true, { metaId: "tt7000005" }), e.player.startRate("default", true, null)], [1.5, 1.25, 1.25]);
    r.eq("player.trackMemory carries the rate beside the track prefs", e.player.trackMemory(rateShow).prefs.rate, 1.5);
    e.settings.patch({ defaultPlaybackSpeed: 1 });
  }
  r.ok("settingsRoom: the html5 engine option reads AVPlayer on the TV", e.settingsRoom.controls("playback", "default", true).some((c) => c.id === "engine" && c.options.some((o) => o.value === "html5" && o.label === "AVPlayer") && c.options.some((o) => o.value === "auto")), "");
  r.eq("subtitles.presets: the three seed presets", e.subtitles.presets().map((p) => p.name), ["English", "Foreign", "Arabic"]);
  const tv = e.subtitles.trackView("default", true, [
    { id: 1, lang: "eng", title: null, codec: "subrip", external: false },
    { id: 2, lang: "fre", title: "French", codec: "ass", external: false, forced: true },
    { id: 3, lang: "en", title: "Show.S01E02.1080p.WEB-DL.x264-GRP", external: true, hearingImpaired: true, externalFilename: "/c/a.srt" },
    { id: 4, lang: "ger", title: "German", external: false, secondary: true },
  ], "Show.S01E02.1080p.WEB-DL.x264-GRP.mkv", 1, 2);
  const row = (id) => tv.tracks.find((t) => t.id === id);
  r.ok("subtitles.trackView keeps preferred languages plus the secondary track", row("1").keep && !row("2").keep && row("3").keep && row("4").keep, JSON.stringify(tv.tracks.map((t) => [t.id, t.keep])));
  r.ok("subtitles.trackView labels rows like bp-subtitle-parts", row("1").title === "Embedded 1 · SUBRIP" && row("3").detail === "External · English" && row("3").tags.join() === "HI/SDH" && row("2").tags.join() === "Forced" && row("1").langDisplay === "English", JSON.stringify(tv.tracks));
  r.ok("subtitles.trackView ranks the release-matched external track as the best match", tv.ranked[0] && tv.ranked[0].id === "3" && tv.ranked[0].eligible === true, JSON.stringify(tv.ranked));
  // subtitles.cues: upstream's parser.ts for the AVPlayer overlay (html5 bridge ensureLoaded).
  const srt = "1\n00:00:01,500 --> 00:00:03,000\n<i>Hello</i> &amp; welcome\n\n2\n00:00:04,000 --> 00:00:05,250\n[DOOR SLAMS]\n\n3\n00:00:06,000 --> 00:00:07,000\nJOHN: Line one\nLine two\n";
  r.eq("subtitles.cues parses SRT (tags and entities cleaned, sorted)", e.subtitles.cues("default", true, srt, "srt"),
    [{ start: 1.5, end: 3, text: "Hello & welcome" }, { start: 4, end: 5.25, text: "[DOOR SLAMS]" }, { start: 6, end: 7, text: "JOHN: Line one\nLine two" }]);
  r.eq("subtitles.cues sniffs WebVTT without hours", e.subtitles.cues("default", true, "WEBVTT\n\n00:01.000 --> 00:02.500 line:90%\n<b>Hi</b> there\n", null),
    [{ start: 1, end: 2.5, text: "Hi there" }]);
  const ass = "[Script Info]\nTitle: x\n\n[Events]\nFormat: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\nDialogue: 0,0:00:02.50,0:00:04.00,Default,,0,0,0,,{\\an8}Top, with comma\\Nsecond line\n";
  r.eq("subtitles.cues reduces ASS to its dialogue text", e.subtitles.cues("default", true, ass, "ass"), [{ start: 2.5, end: 4, text: "Top, with comma\nsecond line" }]);
  e.settings.patch({ subHideSdh: true });
  r.eq("subtitles.cues strips SDH lines when subHideSdh is on", e.subtitles.cues("default", true, srt, "srt").map((c) => c.text), ["Hello & welcome", "Line one\nLine two"]);
  e.settings.patch({ subHideSdh: false });
  const target = await e.subtitles.titleTarget("breaking bad s2e5", { imdbId: "tt0111161", type: "movie", title: "The Shawshank Redemption" });
  r.eq("subtitles.titleTarget parses S2E5 and picks the Cinemeta series", target, { imdbId: "tt0903747", type: "series", title: "Breaking Bad", season: 2, episode: 5 });
  r.eq("subtitles.titleTarget: a one-letter query re-runs the current target", await e.subtitles.titleTarget("b", { imdbId: "", type: "movie", title: "x" }), null);
  const found = await e.subtitles.find("default", true, null, target, null, null, null);
  r.ok("subtitles.find searches the other title's episode with provider details and HI flags", found.tooNew === false && found.results.length === 3 && found.results[1].hearingImpaired === true && found.results[1].tags.join() === "HI/SDH" && found.results[0].provider === "OpenSubtitles" && found.results[2].langName === "French" && hits.includes("https://opensubtitles-v3.strem.io/subtitles/series/tt0903747:2:5.json"), JSON.stringify(found));
  rec.dispose();
}

// ------------------------------- Stage 10: social + Watch Together (recorded host, mock relay)
// A fake harbor.site answers upstream's social client; a fake relay answers the WebSocket
// shim through the optional wsOpen/wsSend/wsClose host functions. Proves the TV reads the
// same endpoints desktop Harbor does, and that upstream's TogetherClient runs on the shim.
{
  const session = JSON.stringify({ token: "tok_social", refresh: "ref_social", refreshedAt: Date.now(), user: { id: "u_social", username: "skipper", handle: "skipper" } });
  const rec = loadEngine({ storage: new Map([
    ["harbor.profiles.v1", JSON.stringify({ activeId: "default", profiles: [{ id: "default", isPrimary: true }] })],
    ["harbor.theme-session.default", session],
  ]) });
  const S = rec.engine.social;
  const T = rec.engine.together;
  const calls = [];
  const SUMMARY = (handle, extra = {}) => ({ handle, alias: handle === "skipper" ? "Skipper" : "Mate", verified: false, featured: false, level: 3, xp: 10, xpToNext: 90, online: true, memberSince: "2025-01-01T00:00:00Z", isOwner: handle === "skipper", counts: { watched: 12, moviesWatched: 4, episodesWatched: 30, friends: 2, badges: 1, hoursWatched: 0, minutesWatched: 3000 }, featuredLists: [{ id: "l1", name: "Cozy", items: [{ id: "tt1", name: "One", poster: "https://img.example.invalid/1.jpg", type: "movie" }], likeCount: 2, liked: false }], ...extra });
  rec.node.host.fetch = async (req) => {
    const u = new URL(req.url);
    calls.push([req.method || "GET", u.pathname + u.search, req.body || null]);
    const json = (body, status = 200) => ({ status, statusText: status === 200 ? "OK" : "Error", headers: { "content-type": "application/json" }, url: req.url, body: JSON.stringify(body) });
    const p = u.pathname;
    if (p === "/themes/api/social/u/skipper") return json(SUMMARY("skipper"));
    if (p === "/themes/api/social/u/mate") return json(SUMMARY("mate", { private: true, friendStatus: "incoming", friendEdgeId: "e9" }));
    if (p === "/themes/api/social/u/ghost") return json({ error: "not_found" }, 404);
    if (p === "/themes/api/social/u/skipper/friends") return json([{ handle: "mate", alias: "Mate", online: true }]);
    if (p === "/themes/api/social/u/skipper/badges") return json([{ id: "og", name: "OG", description: "Early", tier: "gold" }]);
    if (p === "/themes/api/social/u/skipper/activity") return json([{ id: "a1", kind: "rated", title: "One", rating: 9, at: "2026-01-01T00:00:00Z", metaId: "tt1" }]);
    if (p.startsWith("/themes/api/social/u/mate/")) return json([]);
    if (p === "/themes/api/me/notifications") return json({ notifications: [{ id: "t1", type: "downloads", themeName: "Nightfall", count: 100, read: true, createdAt: "2026-01-01T00:00:00Z" }], unread: 0 });
    if (p === "/themes/api/social/me/notifications") return json({ notifications: [
      { id: "n1", type: "group-added", read: false, createdAt: "2026-02-01T00:00:00Z", entityType: "group", entityId: "g1", title: "" },
      { id: "n2", type: "friend-request", read: false, createdAt: "2026-02-02T00:00:00Z", entityType: "friendEdge", entityId: "e1" },
      { id: "n3", type: "badge-received", read: false, createdAt: "2026-02-03T00:00:00Z", body: "og", data: { name: "og" } },
    ], unread: 3 });
    if (p === "/themes/api/social/friends/pending") return json({ pending: [{ edgeId: "e1", from: { handle: "mate", alias: "Mate" }, createdAt: "2026-02-02T00:00:00Z" }] });
    if (p === "/themes/api/social/friends/request") return json({ edge: { id: "e2", status: "pending" } });
    if (p === "/themes/api/social/me/feed") return json({ items: [{ id: "f1", kind: "watched", title: "Frieren", at: "2026-02-01T00:00:00Z", metaId: "kitsu:46474", actor: { handle: "mate", alias: "Mate" } }], nextCursor: "c2", friendCount: 3, sharingCount: 1 });
    if (p === "/themes/api/social/groups/mine") return json({ groups: [{ id: "g1", name: "Crew", visibility: "invite", tags: [], ownerId: "u_social", memberCount: 2, createdAt: "", isOwner: true, isMember: true }] });
    if (p === "/themes/api/social/groups/invites") return json([]);
    if (p === "/themes/api/social/groups/discover") return json({ groups: [{ id: "g1", name: "Crew", visibility: "invite", tags: [], ownerId: "u_social", memberCount: 2, createdAt: "", isOwner: true, isMember: true }, { id: "g2", name: "Anime Club", visibility: "public", tags: ["anime"], ownerId: "x", memberCount: 40, createdAt: "", isOwner: false, isMember: false }], topTags: ["anime"], total: 2 });
    if (p === "/themes/api/social/groups/g2/join") return json({ id: "g2", name: "Anime Club", visibility: "public", tags: ["anime"], ownerId: "x", memberCount: 41, createdAt: "", isOwner: false, isMember: true, members: [], myRole: "member" });
    if (p === "/themes/api/social/groups/g2/posts") return json({ posts: [
      { id: "p1", groupId: "g2", body: "plain", pinned: false, createdAt: "2026-02-02T00:00:00Z", likeCount: 0, liked: false, canDelete: false, canPin: false },
      { id: "p2", groupId: "g2", body: "[b]Welcome[/b] aboard & hi", pinned: true, createdAt: "2026-02-01T00:00:00Z", likeCount: 3, liked: true, canDelete: false, canPin: false },
    ], canPost: true });
    return json({ error: "not_found" }, 404);
  };

  // ---- social
  r.ok("social.me reads the signed-in author", S.me().signedIn === true && S.me().handle === "skipper", JSON.stringify(S.me()));
  const own = await S.profile(null);
  r.ok("social.profile(null) opens the member's own profile with friends, badges, activity", own.state === "ready" && own.summary.isOwner && own.friends.length === 1 && own.badges[0].iconUrl.endsWith("/badges/og.webp") && own.activity[0].rating === 9, JSON.stringify(own).slice(0, 300));
  r.eq("social.profile hero stats follow STAT_ORDER minus the default-hidden friends/badges", own.stats.map((s) => s.key), ["watchTime", "episodes", "movies", "read"]);
  r.eq("social.profile watch time pill (3000 min = 2 days 2 hours)", own.stats[0].value, "M 00 D 02 H 02");
  const locked = await S.profile("mate");
  r.ok("a private profile shows only the hero (no friends/badges/activity requests)", locked.state === "ready" && locked.locked === true && locked.friends.length === 0 && !calls.some(([, path]) => path.startsWith("/themes/api/social/u/mate/")) && locked.summary.friendStatus === "incoming" && locked.summary.friendEdgeId === "e9", JSON.stringify(locked).slice(0, 200));
  r.eq("social.profile of a missing handle is empty", (await S.profile("ghost")).state, "empty");
  const nc = await S.notifications();
  r.ok("social.notifications merges theme + social, hides friend requests, lists them as pending", nc.authed && nc.items.length === 3 && !nc.items.some((n) => n.kind === "friend-request") && nc.pending.length === 1 && nc.pending[0].edgeId === "e1", JSON.stringify(nc).slice(0, 300));
  r.ok("notification titles and targets follow notification-rows/center", nc.items[0].title === "You earned the Og badge" && nc.items[0].target.open === "profile" && nc.items[1].title === "Group invite" && nc.items[1].target.open === "group" && nc.items[1].target.id === "g1" && nc.items[2].title === "Downloads milestone", JSON.stringify(nc.items.map((n) => [n.title, n.target])));
  r.eq("social.notifications badge = unread + pending", nc.badge, 3);
  await S.notificationsDismiss(["s:n1"], false);
  r.ok("a dismissed notification stays hidden (harbor.nc.dismissed.v1)", !(await S.notifications()).items.some((n) => n.id === "s:n1") && rec.node.storage.has("harbor.nc.dismissed.v1"));
  const fr = await S.friendRequest("Mate");
  const frCall = calls.find(([m, path]) => m === "POST" && path === "/themes/api/social/friends/request");
  r.ok("social.friendRequest posts upstream's body (lower-cased handle)", fr.friendStatus === "outgoing" && frCall && JSON.parse(frCall[2]).handle === "mate", JSON.stringify(frCall));
  const fd = await S.feed(null);
  r.ok("social.feed maps friends' items (anime ids open as series) and the cursor", fd.items[0].type === "series" && fd.items[0].actor.handle === "mate" && fd.nextCursor === "c2" && fd.sharingCount === 1, JSON.stringify(fd));
  const gs = await S.groups(null, null, null);
  r.ok("social.groups lists mine first and leaves them out of discover", gs.mine.length === 1 && gs.groups.length === 1 && gs.groups[0].id === "g2" && gs.topTags[0] === "anime" && gs.phase === "ready", JSON.stringify(gs));
  const gj = await S.groupJoin("g2");
  r.ok("social.groupJoin returns the group with member perms", gj.isMember && gj.role === "member" && gj.can.post === true && gj.can.kick === false, JSON.stringify(gj));
  const gp = await S.groupPosts("g2", null);
  r.ok("social.groupPosts: pinned first, BBCode shown as text", gp.posts[0].id === "p2" && gp.posts[0].text === "Welcome aboard & hi" && gp.canPost, JSON.stringify(gp.posts.map((p) => [p.id, p.text])));
  const bad = await S.comment("skipper", "see https://spam.example").then(() => "posted", (e) => e.message);
  r.eq("social.comment refuses a link like comment-compose (text-safety)", bad, "Links are not allowed in comments.");
  r.eq("social.parseListLink: harbor:// deep link", S.parseListLink("harbor://list/skipper/l1"), { handle: "skipper", listId: "l1" });
  r.eq("social.parseListLink: share URL", S.parseListLink("https://harbor.site/list/Skipper/l1?x=1"), { handle: "Skipper", listId: "l1" });
  r.eq("social.parseListLink: typed handle/id", S.parseListLink("@skipper/l1"), { handle: "skipper", listId: "l1" });
  r.eq("social.parseListLink: junk", S.parseListLink("https://evil.example/list/a/b"), null);
  const sl = await S.sharedList("skipper", "l1");
  r.ok("social.sharedList finds the list among the maker's featured lists", sl.state === "ready" && sl.list.items.length === 1 && sl.owner.alias === "Skipper" && sl.list.likeCount === 2, JSON.stringify(sl));
  r.eq("social.sharedList of an unknown list is missing", (await S.sharedList("skipper", "nope")).state, "missing");
  r.ok("social writes only what the viewer asked for (friend request, group join)", calls.filter(([m]) => m !== "GET").every(([, path]) => path === "/themes/api/social/friends/request" || path === "/themes/api/social/groups/g2/join"), JSON.stringify(calls.filter(([m]) => m !== "GET")));

  // ---- Watch Together over the WebSocket shim
  const opened = [];
  const frames = [];
  const closed = [];
  const events = [];
  rec.engine.runtime.onEvent((type, detail) => { if (type.startsWith("harbor:together")) events.push([type, detail]); });
  rec.node.host.wsOpen = (url, id) => opened.push([url, id]);
  rec.node.host.wsSend = (id, text) => frames.push([id, JSON.parse(text)]);
  rec.node.host.wsClose = (id) => closed.push(id);
  const wsEvent = rec.run("__harbor_ws_event");
  const sent = (t) => frames.filter(([, f]) => f.t === t).map(([, f]) => f);
  const wait = (ms) => new Promise((res) => setTimeout(res, ms));
  r.eq("runtime reports the WebSocket host functions as present", rec.engine.runtime.missingOptionalHostFunctions(), []);
  const id = { profileId: "default", linked: true, avatar: "/avatars/local.png", color: "#60a5fa" };
  r.eq("together.configure without a relay is disabled", T.configure(id).enabled, false);
  const v0 = T.setRelay(id, "wss://relay.example.invalid");
  r.ok("together.setRelay writes togetherRelayUrl and enables the room", v0.enabled && rec.engine.settings.loadForProfile("default", true).togetherRelayUrl === "wss://relay.example.invalid", JSON.stringify(v0).slice(0, 200));
  const code = T.start();
  r.ok("together.start opens <relay>/r/<CODE> with a 6-letter room code", /^[A-Z2-9]{6}$/.test(code) && opened.length === 1 && opened[0][0] === `wss://relay.example.invalid/r/${code}`, JSON.stringify(opened));
  const sock = opened[0][1];
  wsEvent(sock, "open", null);
  const hello = sent("hello")[0];
  r.ok("on open the client pings, then says hello (bundled avatar art is not shared; harborColor wins)", sent("ping").length === 1 && hello && hello.room === code && typeof hello.clientId === "string" && hello.avatar === null && hello.color === (rec.engine.settings.loadForProfile("default", true).harborColor || "#60a5fa"), JSON.stringify(frames));
  const me = hello.clientId;
  const hostState = { mediaId: "tt0111161", mediaTitle: "The Shawshank Redemption", episode: null, posterUrl: null, positionSeconds: 120, playing: true, updatedAt: Date.now(), updatedBy: "host1", hostClientId: "host1", source: { resolution: "1080p", infoHash: "0123456789abcdef0123456789abcdef01234567" } };
  wsEvent(sock, "message", JSON.stringify({ t: "joined", room: code, participants: [{ id: "host1", name: "Ana", joinedAt: 1, ready: true }, { id: me, name: hello.name, joinedAt: 2, ready: false }], state: hostState, hostClientId: "host1", started: true, srvAt: Date.now(), relayVersion: 11 }));
  await wait(220);
  const v1 = T.view();
  r.ok("joined: in a room of two as a guest, host's source derived", v1.state === "joined" && v1.inRoom && !v1.isHost && v1.participants[0].name === "Ana" && v1.participants[0].host && v1.hostSource && v1.hostSource.descriptor.resolution === "1080p", JSON.stringify(v1).slice(0, 400));
  r.ok("joined with media playing turns into an invite (client.ts joined → invite)", v1.incomingInvite && v1.incomingInvite.invite.mediaId === "tt0111161" && v1.incomingInvite.name === "Ana" && T.wasInvitedTo("tt0111161||"), JSON.stringify(v1.incomingInvite));
  r.ok("incoming state reaches the host as harbor:together-sync at once", events.some(([t, d]) => t === "harbor:together-sync" && d.kind === "state" && d.state.mediaId === "tt0111161"), JSON.stringify(events.map(([t, d]) => [t, d && d.kind])));
  r.ok("the view reaches the host as a throttled harbor:together event", events.some(([t, d]) => t === "harbor:together" && d && d.state === "joined"));
  wsEvent(sock, "message", JSON.stringify({ t: "chat", from: "host1", name: "Ana", text: "popcorn ready?", at: Date.now() }));
  wsEvent(sock, "message", JSON.stringify({ t: "cmd", from: "host1", command: { action: "pause" } }));
  wsEvent(sock, "message", JSON.stringify({ t: "draw", from: "host1", name: "Ana", strokeId: "s1", phase: "start", x: 0.2, y: 0.3, color: "#f00", path: "player:tt0111161" }));
  wsEvent(sock, "message", JSON.stringify({ t: "draw", from: "host1", name: "Ana", strokeId: "s1", phase: "point", x: 0.25, y: 0.35, path: "player:tt0111161" }));
  wsEvent(sock, "message", JSON.stringify({ t: "cursor", from: "host1", name: "Ana", x: 0.5, y: 0.5, visible: true, path: "player:tt0111161" }));
  wsEvent(sock, "message", JSON.stringify({ t: "presence", from: "host1", activeAt: Date.now(), location: { kind: "player", meta: { id: "tt0111161", type: "movie", name: "The Shawshank Redemption" } } }));
  await wait(220);
  const v2 = T.view();
  r.ok("chat, strokes, cursors and presence land in the view", v2.chat.length === 1 && v2.chat[0].text === "popcorn ready?" && v2.strokes.length === 1 && v2.strokes[0].points.length === 2 && v2.cursors.length === 1 && v2.participants[0].locationLabel === "Watching The Shawshank Redemption", JSON.stringify({ chat: v2.chat, strokes: v2.strokes, cursors: v2.cursors, loc: v2.participants[0].locationLabel }));
  r.ok("a room command reaches the host as harbor:together-sync", events.some(([t, d]) => t === "harbor:together-sync" && d.kind === "command" && d.command.action === "pause" && d.from === "host1"));
  T.sendChat("  hi all  ");
  T.sendCommand({ action: "seek", positionSeconds: 10 });
  T.sendCommand({ action: "seek", positionSeconds: 20 });
  T.sendCommand({ action: "seek", positionSeconds: 30 });
  r.ok("chat is trimmed; the first seek goes out at once", sent("chat")[0].text === "hi all" && sent("cmd").length === 1 && sent("cmd")[0].command.positionSeconds === 10, JSON.stringify(sent("cmd")));
  await wait(320);
  r.ok("rapid seeks coalesce to the last position (seek-coalesce 250 ms)", sent("cmd").length === 2 && sent("cmd")[1].command.positionSeconds === 30 && sent("cmd")[1].command.seq > sent("cmd")[0].command.seq, JSON.stringify(sent("cmd")));
  const role = T.playerOpened({ id: "tt0111161", type: "movie", name: "The Shawshank Redemption" }, null, { resolution: "1080p", infoHash: "0123456789ABCDEF0123456789abcdef01234567", size: 2e9 }, 8520);
  r.ok("a guest opening the invited title does not claim host; the source descriptor is built", role.invited === false && sent("claim-host").length === 0 && role.source.resolution === "1080p" && role.source.infoHash === "0123456789abcdef0123456789abcdef01234567" && role.source.durationSec === 8520, JSON.stringify(role));
  T.dismiss("invite");
  r.eq("together.dismiss clears the invite", T.view().incomingInvite, null);
  r.eq("together.parseJoin: a bare code", T.parseJoin("abc-d23"), { relay: null, room: "ABCD23" });
  r.eq("together.parseJoin: an invite link carries its relay", T.parseJoin("https://pub.harbor.site/?harbor-relay=wss%3A%2F%2Fother.example.invalid&harbor-room=zzzz22"), { relay: "wss://other.example.invalid", room: "ZZZZ22" });
  r.eq("together.parseJoin: junk", T.parseJoin("https://example.invalid/nothing"), null);
  const joined = T.join(id, "https://pub.harbor.site/?harbor-relay=wss%3A%2F%2Fother.example.invalid&harbor-room=zzzz22");
  r.ok("joining from a link switches the relay setting and opens the new room", joined.ok && closed.includes(sock) && opened.length === 2 && opened[1][0] === "wss://other.example.invalid/r/ZZZZ22" && rec.engine.settings.loadForProfile("default", true).togetherRelayUrl === "wss://other.example.invalid", JSON.stringify({ joined: joined.ok, opened, closed }));
  const sock2 = opened[1][1];
  wsEvent(sock2, "open", null);
  const me2 = sent("hello").slice(-1)[0].clientId;
  wsEvent(sock2, "message", JSON.stringify({ t: "joined", room: "ZZZZ22", participants: [{ id: me2, name: "x", joinedAt: 1, ready: false }, { id: "friend", name: "Bo", joinedAt: 2, ready: false }], state: null, hostClientId: null, started: false, srvAt: Date.now(), relayVersion: 3 }));
  const hosted = T.playerOpened({ id: "tt0068646", type: "movie", name: "The Godfather", poster: "https://img.example.invalid/g.jpg" }, null, null, 0);
  const inv = sent("invite").slice(-1)[0];
  r.ok("with no host, the TV playing a title claims host and invites the room (use-room-invite)", hosted.invited && sent("claim-host").slice(-1)[0].fresh === true && inv && inv.invite.mediaId === "tt0068646" && inv.invite.proto === 2 && inv.invite.mediaType === "movie", JSON.stringify(inv));
  await wait(220);
  r.ok("a self-hosted relay below v11 is reported outdated; the invite link names the room", T.view().relayOutdated === true && typeof T.view().inviteUrl === "string" && T.view().inviteUrl.includes("harbor-room=ZZZZ22"), JSON.stringify({ o: T.view().relayOutdated, u: T.view().inviteUrl }));
  T.publishState({ mediaId: "tt0068646", mediaTitle: "The Godfather", episode: null, posterUrl: null, positionSeconds: 5, playing: true });
  const st = sent("state").slice(-1)[0];
  r.ok("together.publishState stamps updatedBy with this client", st && st.state.updatedBy === me2 && st.state.positionSeconds === 5 && st.state.hostClientId === null, JSON.stringify(st));
  // attachClient: the old client's leave() lands after its listener is gone, so the relay change
  // itself must drop the room (else the view stays "joined" with the old roster and timers).
  const leavesBefore = sent("leave").length;
  const vRelay = T.setRelay(id, "wss://third.example.invalid");
  r.ok("a relay change while joined leaves the old room and drops it from the view at once", sent("leave").length === leavesBefore + 1 && vRelay.state === "disconnected" && vRelay.room === null && vRelay.participants.length === 0 && !vRelay.inRoom, JSON.stringify({ state: vRelay.state, room: vRelay.room, participants: vRelay.participants.map((p) => p.name) }));
  const left = T.leave();
  r.ok("together.leave says leave and drops the room", sent("leave").some((f) => f.room === code) && sent("leave").slice(-1)[0].room === "ZZZZ22" && left.state === "disconnected" && left.room === null && left.chat.length === 0, JSON.stringify({ leave: sent("leave"), state: left.state }));
  T.reset();
  rec.dispose();
}

// ------------------------------------------- manga: Suwayomi server, reader, progress (Stage 13)
{
  const base = "https://manga.example.invalid";
  const rec = loadEngine({ storage: new Map([
    ["harbor.profiles.v1", JSON.stringify({ activeId: "default", profiles: [{ id: "default", isPrimary: true }] })],
  ]) });
  const hits = [];
  rec.node.host.fetch = async (req) => {
    hits.push({ url: req.url, method: req.method ?? "GET", auth: (req.headers ?? {}).authorization ?? (req.headers ?? {}).Authorization ?? null });
    const json = (body) => ({ status: 200, statusText: "OK", headers: { "content-type": "application/json" }, url: req.url, body: JSON.stringify(body) });
    const u = new URL(req.url);
    if (u.origin !== base) return { status: 404, statusText: "Not Found", headers: {}, url: req.url, body: "" };
    const p = u.pathname;
    if (p === "/api/v1/source/list") return json([{ id: "101", name: "Example Source", lang: "en" }, { id: "102", name: "Autre", lang: "fr" }]);
    if (p === "/api/v1/source/101/popular/1") return json({ mangaList: [{ id: 5, title: "Test Manga" }, { id: 6, title: "Second" }], hasNextPage: false });
    if (p === "/api/v1/source/102/popular/1") return json({ mangaList: [], hasNextPage: false });
    if (p === "/api/v1/source/101/search") return json({ mangaList: [{ id: 5, title: "Test Manga" }], hasNextPage: false });
    if (p === "/api/v1/source/102/search") return json({ mangaList: [], hasNextPage: false });
    if (p === "/api/v1/manga/5/full") return json({ id: 5, title: "Test Manga", description: "A test.", status: "ONGOING", author: "Someone" });
    if (p === "/api/v1/manga/5/chapters") return json([
      { index: 2, chapterNumber: 2, name: "Two", pageCount: 2, scanlator: "G" },
      { index: 1, chapterNumber: 1, name: "One", pageCount: 3, scanlator: "G", lastPageRead: 2, read: false },
    ]);
    if (p === "/api/v1/manga/5/chapter/1") return json({ pageCount: 3 });
    if (p === "/api/v1/manga/5/library") return json({});
    // provider.search with no source picked searches the server's library (as upstream does).
    if (p === "/api/v1/library") return json([{ id: 5, title: "Test Manga", sourceId: "101" }]);
    return json({});
  };
  const me = rec.engine.manga;
  r.eq("manga.state starts with no source", [me.state().hasSource, me.state().sources.length], [false, 0]);
  r.eq("manga.addServer rejects a non-http address", me.addServer("", "ftp://nope", null, null).ok, false);
  const added = me.addServer("Home", `${base}/api/v1`, "reader", "secret");
  const st = me.state();
  r.ok("manga.addServer links and activates a Suwayomi source (suffix stripped, no credentials in the UI)", added.ok && st.hasSource && st.sources.length === 1 && st.sources[0].kind === "suwayomi" && st.activeId === st.sources[0].id && st.servers[0].host === "manga.example.invalid" && st.servers[0].hasAuth && !JSON.stringify(st.sources).includes("secret"), JSON.stringify(st));
  r.ok("manga.state hands the image loader the server's Basic auth", st.auth.length === 1 && st.auth[0].base === base && st.auth[0].header.startsWith("Basic "), JSON.stringify(st.auth));
  const test = await me.testServer(base, "reader", "secret");
  r.eq("manga.testServer counts the server's sources", [test.ok, test.sources], [true, 2]);
  const pop = await me.popular(0, null);
  r.ok("manga.popular merges the server's sources, covers on the server", pop.length === 2 && pop.every((m) => m.cover.startsWith(`${base}/api/v1/manga/`)) && pop.some((m) => m.id === "101~5"), JSON.stringify(pop));
  r.ok("Suwayomi requests carry the Basic auth", hits.filter((h) => h.url.startsWith(base)).every((h) => h.auth === st.auth[0].header));
  const tagsList = await me.tags();
  r.ok("manga.tags lists the server's sources (non-English tagged)", tagsList.length === 2 && tagsList[1].name === "Autre (FR)", JSON.stringify(tagsList));
  const found = await me.search("test", 0, "101");
  r.eq("manga.search in one source", found.map((m) => m.id), ["101~5"]);
  const d = await me.detail("101~5");
  r.ok("manga.detail: summary, chapters sorted ascending, English by default, extension name", d.detail?.title === "Test Manga" && d.chapters.map((c) => c.chapter).join() === "1,2" && d.defaultLang === "en" && d.extName === "Example Source", JSON.stringify({ ...d, chapters: d.chapters.length }));
  const pages = await me.pages(d.chapters[0].id);
  r.ok("manga.pages: one URL per page, each with the server's auth header", pages.length === 3 && pages[2].url === `${base}/api/v1/manga/5/chapter/1/page/2` && pages.every((pg) => pg.headers?.authorization === st.auth[0].header), JSON.stringify(pages));
  const order = me.readerOrder(d.chapters, 0);
  r.eq("manga.readerOrder walks one copy per chapter, ascending", order.order, [0, 1]);
  const mm = { id: "101~5", title: "Test Manga", cover: d.detail.cover };
  r.eq("manga.startPage: the server's lastPageRead when nothing local", me.startPage("default", mm, d.chapters[0], null), 2);
  r.ok("manga.recordPage saves Continue Reading", me.recordPage("default", mm, d.chapters[0], 3, 3, null) && me.progress("default")[0].page === 3 && me.progress("default")[0].chapterLabel === "Chapter 1");
  me.markComplete("default", mm, d.chapters, 0, 1, 3);
  const prog = me.progress("default");
  r.ok("manga.markComplete marks the chapter read and queues the next as up next", prog[0].upNext === true && prog[0].chapterId === d.chapters[1].id && me.readChapters("default", mm.id).includes(d.chapters[0].id), JSON.stringify(prog));
  r.eq("manga.matchChapter finds the saved chapter", me.matchChapter(prog[0], d.chapters), 1);
  const res = await me.resume(prog[0]);
  r.ok("manga.resume opens the reader on the saved chapter", res && res.index === 1 && res.chapters.length === 2 && res.manga.title === "Test Manga", JSON.stringify(res));
  me.closeReader();
  await new Promise((ok) => setTimeout(ok, 50));
  r.ok("closeReader flushes reading progress to the server", hits.some((h) => h.url.includes("/api/v1/manga/5/chapter/") && h.method !== "GET"), JSON.stringify(hits.slice(-3)));
  r.eq("manga.toggleFavorite adds then removes", [me.toggleFavorite("default", { id: mm.id, title: mm.title }), me.favorites("default").length, me.toggleFavorite("default", { id: mm.id }), me.favorites("default").length], [true, 1, false, 0]);
  const pf = me.savePrefs({ mode: "paged", zoom: 9 });
  r.ok("manga.savePrefs keeps upstream's defaults and clamps the zoom", pf.mode === "paged" && pf.zoom === 3 && pf.rtl === true && me.prefs().mode === "paged", JSON.stringify(pf));
  r.eq("manga.openByTitle finds the title in the active source", await me.openByTitle("Test Manga", "default"), "101~5");
  r.eq("manga.resolveTitle opens a franchise manga through every extension (search-manga-resolve)", await me.resolveTitle("Test Manga"), "101~5");
  r.eq("manga.firstByTitle: bp-hero-manga's first source hit", await me.firstByTitle("Test Manga"), "101~5");
  const off = await rec.engine.search.fanOut("test", "default", true, null);
  r.eq("search.fanOut asks for no manga while the reader is off", off.manga.length, 0);
  rec.engine.settings.saveForProfile({ ...rec.engine.settings.loadForProfile("default", true), mangaEnabled: true }, "default", true);
  const on = await rec.engine.search.fanOut("test", "default", true, null);
  r.eq("search.fanOut returns manga results once the reader is on (SR-9)", on.manga.map((m) => m.id), ["101~5"]);
  me.removeServer(st.servers[0].id);
  r.eq("manga.removeServer drops its source", me.state().hasSource, false);
  rec.dispose();
}

// ------------------------------------------ ebooks: Gutendex source, reading position (Stage 13)
{
  const rec = loadEngine({ storage: new Map([
    ["harbor.profiles.v1", JSON.stringify({ activeId: "default", profiles: [{ id: "default", isPrimary: true }] })],
  ]) });
  const raw = (id, title, author, subjects) => ({
    id, title, authors: [{ name: author }], subjects, bookshelves: [], download_count: 100 - id,
    formats: { "application/epub+zip": `https://www.gutenberg.org/ebooks/${id}.epub3.images`, "image/jpeg": `https://www.gutenberg.org/cache/epub/${id}/cover.jpg` },
  });
  const pride = raw(1342, "Pride and Prejudice", "Austen, Jane", ["Love stories", "England -- Fiction"]);
  const emma = raw(158, "Emma", "Austen, Jane", ["Love stories", "Humorous stories"]);
  const hits = [];
  rec.node.host.fetch = async (req) => {
    hits.push(req.url);
    const json = (body) => ({ status: 200, statusText: "OK", headers: { "content-type": "application/json" }, url: req.url, body: JSON.stringify(body) });
    const u = new URL(req.url);
    if (u.origin !== "https://gutendex.com") return { status: 404, statusText: "Not Found", headers: {}, url: req.url, body: "" };
    if (u.pathname === "/books/1342") return json(pride);
    if (u.pathname === "/books/158") return json(emma);
    if (u.pathname === "/books" && u.searchParams.get("search")) {
      const q = u.searchParams.get("search").toLowerCase();
      // Gutendex matches every word against titles and author names.
      return json({ results: [pride, emma].filter((b) => q.split(/\s+/).every((w) => `${b.title} ${b.authors[0].name}`.toLowerCase().includes(w))) });
    }
    if (u.pathname === "/books") return json({ results: u.searchParams.get("page") === "1" ? [pride, emma] : [] });
    return json({});
  };
  const eb = rec.engine.ebook;
  const s0 = await eb.state();
  r.eq("ebook.state starts with no source (views/ebook.tsx shows EBookSetup)", [s0.providers.length, s0.hasGutendex], [0, false]);
  const s1 = await eb.addGutendex();
  r.ok("ebook.addGutendex adds Project Gutenberg as the one readable source", s1.hasGutendex && s1.providers.length === 1 && s1.providers[0].name === "Project Gutenberg" && s1.sources[0].kind === "gutendex" && s1.sources[0].readable, JSON.stringify(s1));
  const pid = s1.providers[0].id;
  const p1 = await eb.page(null, pid, null, null, null);
  const route = `source:${encodeURIComponent(pid)}:1342`;
  r.ok("ebook.page: Gutendex popular page, authors as 'First Last', a cursor and a metadata token", p1.items.length === 2 && p1.items.some((b) => b.id === route && b.authors[0] === "Jane Austen" && b.cover?.endsWith("/cover.jpg")) && p1.cursor[pid] === 2 && p1.hasMore && p1.fresh === 2 && p1.token > 0, JSON.stringify(p1).slice(0, 400));
  const en = await eb.enriched(p1.token);
  r.ok("ebook.enriched returns the page after the metadata pass (and only once)", Array.isArray(en) && en.length === 2 && (await eb.enriched(p1.token)) === null, JSON.stringify(en).slice(0, 200));
  const folded = eb.merge(p1.items, [{ ...p1.items[0], description: "Enriched." }], true);
  r.ok("ebook.merge replaces a book by id (updateSourceItems replace) and keeps the rest", folded.length === 2 && folded.find((b) => b.id === p1.items[0].id).description === "Enriched.", JSON.stringify(folded).slice(0, 200));
  const p2 = await eb.page(null, pid, p1.cursor, null, p1.items);
  // gutendexPage(offset) is offset/32 + 1, so a short catalog answers page 1 again: nothing new,
  // which the room counts toward loadMore's stale-page streak.
  r.eq("ebook.page past a short catalog: no new books", [p2.fresh, p2.items.length], [0, 2]);
  const sr = await eb.page("pride", pid, null, null, null);
  r.eq("ebook.page with a query searches the source", sr.items.map((b) => b.title), ["Pride and Prejudice"]);
  const d = await eb.detail(route);
  r.ok("ebook.detail of a source route: the provider's book, subjects as the description", d?.title === "Pride and Prejudice" && d.description.includes("Love stories") && d.providerName === "Project Gutenberg", JSON.stringify(d).slice(0, 300));
  const opts = await eb.resolveSources(d, p1.items);
  r.ok("ebook.resolveSources keeps the route among the book's readable copies", opts.some((b) => b.id === route), JSON.stringify(opts.map((b) => b.id)));
  const more = await eb.moreByAuthor(d);
  r.ok("ebook.moreByAuthor finds the author's other books in the source", more.some((b) => b.title === "Emma") && !more.some((b) => b.id === route), JSON.stringify(more.map((b) => b.title)));
  const rec2 = await eb.recommended(d);
  r.ok("ebook.recommended: same-genre picks, never the book itself", !rec2.failed && rec2.items.every((b) => b.id !== route), JSON.stringify(rec2).slice(0, 200));
  r.eq("ebook.epub: the Gutendex EPUB behind a route", await eb.epub(route), { bookId: "1342", url: "https://www.gutenberg.org/ebooks/1342.epub3.images" });
  r.eq("ebook.epub: nothing for a route the TV cannot read", await eb.epub("source:plugin%3Ax:1"), null);
  const chs = eb.chapters("1342", [{ path: "OEBPS/ch1.xhtml#c1", title: "Chapter I" }, { path: "OEBPS/ch2.xhtml#", title: "Chapter II" }]);
  r.eq("ebook.chapters: gutendexProvider ids ([bookId, path] as JSON) and positions", chs.map((c) => [c.id, c.position]), [['["1342","OEBPS/ch1.xhtml#c1"]', 0], ['["1342","OEBPS/ch2.xhtml#"]', 1]]);
  r.eq("ebook.cleanSourceText cuts leaked CSS and drops text with no letters", [eb.cleanSourceText("It is a truth.\n\n.x { color: red; }"), eb.cleanSourceText(" ... ")], ["It is a truth.", ""]);
  const text = "It is a truth universally acknowledged.\n\nHowever little known\nthe feelings.\n\nMy dear Mr. Bennet.";
  const o1 = eb.openChapter("default", route, chs[0], text);
  r.ok("ebook.openChapter: paragraphs (single newlines joined), line 0, a text identity; the resume points at the chapter", o1.paragraphs.length === 3 && o1.paragraphs[1] === "However little known the feelings." && o1.line === 0 && /^\d+:\d+$/.test(o1.identity) && eb.resume("default", route)?.chapterId === chs[0].id, JSON.stringify(o1));
  const saved = eb.savePosition("default", route, chs[0], 1, 3, 0, 2, o1.identity);
  r.ok("ebook.savePosition: harbor-reader's chapter and book progress", saved.chapterProgress === 50 && saved.bookProgress === 25 && saved.textIdentity === o1.identity && eb.openChapter("default", route, chs[0], text).line === 1, JSON.stringify(saved));
  r.eq("ebook.statuses: a started book is partial", eb.statuses("default", [route, "source:x:2"]), { [route]: "partial" });
  eb.savePosition("default", route, chs[1], 2, 3, 1, 2, o1.identity);
  r.eq("ebook.statuses: the last chapter at its end is read", eb.statuses("default", [route])[route], "read");
  r.ok("ebook.toggleShelf / toggleFavorite / flags", eb.toggleShelf(d) === true && eb.toggleFavorite(d) === true && eb.flags(route).shelf && eb.flags(route).favorite && eb.library().shelf.length === 1);
  const cont = eb.continueList("default", []);
  r.ok("ebook.continueList: shelved books with a resume, newest first", cont.length === 1 && cont[0].ebook.id === route && cont[0].resume.chapterId === chs[1].id, JSON.stringify(cont).slice(0, 200));
  r.eq("ebook.toggleShelf removes again", [eb.toggleShelf(d), eb.library().shelf.length], [false, 0]);
  const pf = eb.savePrefs({ fontSize: 24, background: "light" });
  r.ok("ebook.savePrefs merges into upstream's reader prefs", pf.fontSize === 24 && pf.background === "light" && pf.lineHeight === 1.85 && pf.narrationVoice === "en-US-AvaNeural" && eb.prefs().fontSize === 24, JSON.stringify(pf));
  const bms = eb.addBookmark("default", route, chs[0], 1, o1.paragraphs[1]);
  r.ok("ebook.addBookmark then removeBookmark", bms.length === 1 && bms[0].line === 1 && bms[0].preview === o1.paragraphs[1] && eb.removeBookmark("default", route, bms[0].id).length === 0, JSON.stringify(bms));
  const s2 = await eb.removeSource(pid);
  r.eq("ebook.removeSource drops Project Gutenberg", [s2.providers.length, s2.hasGutendex], [0, false]);
  rec.dispose();
}

// ---------------------------------------- Addons manager (views/addons.tsx, recorded host, fixtures)
{
  const SA = "https://stremio-addons.net/api/v0";
  const now = Date.now();
  const mk = (id, name, extra = {}) => ({ id, version: "1.2.3", name, description: `${name} does things. More text.`, resources: ["catalog", "stream"], types: ["movie", "series"], idPrefixes: ["tt"], catalogs: [{ type: "movie", id: "top", name: "Top" }], logo: "/logo.png", ...extra });
  const plain = mk("org.example.plain", "Plain Streams", { background: "https://img.example.invalid/plain-bg.jpg" });
  const conf = mk("org.example.conf", "Configurable Streams", { behaviorHints: { configurable: true, configurationRequired: true } });
  const adult = mk("org.example.adult", "Adult Things", { behaviorHints: { adult: true } });
  const fresh = mk("org.example.fresh", "Fresh Catalog", { resources: ["catalog"] });
  const sa = (m, url, stars, extra = {}) => ({ uuid: `u-${m.id}`, url: `https://stremio-addons.net/addons/${m.id}`, manifestUrl: url, manifest: m, slug: m.id.replace(/\./g, "-"), stars, categories: [{ name: "movies", slug: "movies" }], configureUrl: null, createdAt: new Date(now - 30 * 864e5).toISOString(), updatedAt: "", ...extra });
  const plainUrl = "https://plain.example.invalid/manifest.json";
  const confUrl = "https://conf.example.invalid/cfg-A/manifest.json";
  const confUrlB = "https://conf.example.invalid/cfg-B/manifest.json";
  const listing = [
    sa(plain, plainUrl, 420),
    sa(conf, confUrl, 300),
    sa(adult, "https://adult.example.invalid/manifest.json", 200, { categories: [{ name: "nsfw", slug: "nsfw" }] }),
    sa(fresh, "https://fresh.example.invalid/manifest.json", 5, { createdAt: new Date(now - 2 * 864e5).toISOString() }),
  ];
  const manifests = new Map([[plainUrl, plain], [confUrl, conf], [confUrlB, { ...conf, version: "2.0.0" }], ["https://fresh.example.invalid/manifest.json", fresh]]);
  let cloud = [
    { transportUrl: "https://one.example.invalid/manifest.json", transportName: "", manifest: mk("org.example.one", "One"), flags: { official: false, protected: false } },
    { transportUrl: "https://two.example.invalid/manifest.json", transportName: "", manifest: mk("org.example.two", "Two"), flags: { official: false, protected: false } },
  ];
  const hits = [];
  const rec = loadEngine({ storage: new Map([
    ["harbor.profiles.v1", JSON.stringify({ activeId: "default", profiles: [{ id: "default", isPrimary: true }] })],
  ]) });
  const json = (req, body, status = 200) => ({ status, statusText: "OK", headers: { "content-type": "application/json" }, url: req.url, body: JSON.stringify(body) });
  rec.node.host.fetch = async (req) => {
    hits.push(`${req.method} ${req.url}`);
    const u = new URL(req.url);
    if (req.url.startsWith(`${SA}/addons?`)) {
      const nsfw = u.searchParams.get("nsfw");
      const search = (u.searchParams.get("search") ?? "").toLowerCase();
      const cat = u.searchParams.getAll("category");
      let list = listing.filter((a) => nsfw !== "exclude" || !a.manifest.behaviorHints?.adult);
      if (search) list = list.filter((a) => a.manifest.name.toLowerCase().includes(search));
      if (cat.length) list = list.filter((a) => a.categories.some((c) => cat.includes(c.slug)));
      if (u.searchParams.get("sort_by") === "createdAt") list = [...list].sort((a, b) => (a.createdAt > b.createdAt ? -1 : 1));
      const page = Number(u.searchParams.get("page") ?? 1);
      return json(req, { addons: page > 1 ? [] : list, pagination: { page, limit: 50, total: list.length, totalPages: 1, hasNextPage: false, hasPreviousPage: page > 1 } });
    }
    if (req.url === `${SA}/rising`) return json(req, { addons: [{ ...listing[0], recentStars: 7 }] });
    if (req.url === `${SA}/categories`) return json(req, { categories: [{ name: "movies", slug: "movies" }, { name: "nsfw", slug: "nsfw" }, { name: "anime", slug: "anime" }] });
    if (req.url.startsWith(`${SA}/addons/`)) {
      const slug = decodeURIComponent(u.pathname.split("/").pop());
      const hit = listing.find((a) => a.slug === slug);
      return hit ? json(req, { ...hit, instances: [], documentation: "## Setup\nPick a **debrid** service." }) : json(req, {}, 404);
    }
    if (u.host === "v3-cinemeta.strem.io" || req.url === "https://api.strem.io/addonsofficialcollection.json") return json(req, { addons: [] });
    if (req.url === "https://api.strem.io/api/addonCollectionGet") return json(req, { result: { addons: cloud } });
    if (req.url === "https://api.strem.io/api/addonCollectionSet") {
      const body = JSON.parse(req.body || "{}");
      cloud = body.addons;
      return json(req, { result: { success: true } });
    }
    if (manifests.has(req.url)) return json(req, manifests.get(req.url));
    return { status: 404, statusText: "Not Found", headers: {}, url: req.url, body: "" };
  };
  const am = rec.engine.addonsManager;
  const cats = await am.categories(false);
  r.eq("addonsManager.categories hides nsfw until adult addons are on", cats.map((c) => c.slug), ["movies", "anime"]);
  r.eq("addonsManager.categories keeps nsfw with adult addons on", (await am.categories(true)).map((c) => c.slug), ["movies", "nsfw", "anime"]);
  const top = await am.browse("top", null, null, false, 1);
  r.ok("addonsManager.browse top: nsfw excluded, stars and the 24h rising badge", top.items.length === 3 && !top.items.some((i) => i.id === adult.id) && top.items[0].stars === 420 && top.items[0].rising === 7 && top.items[0].risingWindow === 1 && top.hasMore === false && hits.some((h) => h.includes("nsfw=exclude")), JSON.stringify(top.items.map((i) => [i.id, i.stars, i.rising])));
  r.ok("addonsManager.browse resolves relative logos against the manifest URL", top.items[0].logo === "https://plain.example.invalid/logo.png", top.items[0].logo);
  const adultTop = await am.browse("top", "nsfw", null, false, 1);
  r.ok("addonsManager.browse: the nsfw category lifts the exclusion (community-browse-list)", adultTop.items.length === 1 && adultTop.items[0].id === adult.id, JSON.stringify(adultTop.items.map((i) => i.id)));
  const nw = await am.browse("new", null, null, false, 1);
  r.ok("addonsManager.browse new: newest first, New badge inside 14 days", nw.items[0].id === fresh.id && nw.items[0].isNew === true && nw.items.filter((i) => i.isNew).length === 1, JSON.stringify(nw.items.map((i) => [i.id, i.isNew])));
  const found = await am.browse("top", "movies", "config", false, 1);
  r.ok("addonsManager.browse search ignores the category and matches names", found.items.length === 1 && found.items[0].id === conf.id && hits.some((h) => h.includes("search=config") && !h.includes("category=")), JSON.stringify(found.items.map((i) => i.id)));
  const rising = await am.browse("rising", null, null, false, 1);
  r.ok("addonsManager.browse rising: the official 24h list", rising.items.length === 1 && rising.items[0].id === plain.id && rising.items[0].rising === 7, JSON.stringify(rising));
  const spot = await am.spotlight(false);
  r.ok("addonsManager.spotlight: a trending addon with a background", spot && spot.trending === true && spot.addon.id === plain.id && !!spot.addon.background, JSON.stringify(spot));
  const railTop = await am.rail("stars", false);
  r.ok("addonsManager.rail Top rated: no adult addons", railTop.length === 3 && !railTop.some((c) => c.id === adult.id), JSON.stringify(railTop.map((c) => c.id)));
  const loaded0 = await am.load(null, false);
  r.ok("addonsManager.load: community catalog, nothing installed yet, adult addon hidden", loaded0.installed.length === 0 && loaded0.installedCount === 0 && loaded0.total === 3, JSON.stringify(loaded0));
  const cfg = await am.install(conf.id, confUrl);
  r.ok("addonsManager.install sends a configurable addon to its setup page", cfg.kind === "configure" && cfg.configureUrl === "https://conf.example.invalid/cfg-A/configure", JSON.stringify(cfg));
  const ins = await am.install(plain.id, plainUrl);
  r.ok("addonsManager.install installs a plain addon", ins.kind === "installed" && ins.id === plain.id && ins.toast === "Installed", JSON.stringify(ins));
  const dflt = await am.installDefault(conf.id, confUrl);
  r.eq("addonsManager.installDefault installs the published manifest", dflt.kind, "installed");
  const loaded1 = await am.load(null, false);
  r.ok("addonsManager.load: installed tab in install order with positions and switches", loaded1.installed.map((c) => [c.id, c.position, c.enabled]).join("|") === `${plain.id},1,true|${conf.id},2,true`, JSON.stringify(loaded1.installed.map((c) => [c.id, c.position, c.enabled])));
  const match = await am.resolveUrl("stremio://conf.example.invalid/cfg-B/manifest.json", { id: conf.id, name: conf.name });
  r.ok("addonsManager.resolveUrl (manage): a same-id link is an update", match.matchKind === "id-match" && match.url === confUrlB && match.version === "2.0.0", JSON.stringify(match));
  const hostMatch = await am.resolveUrl("https://conf.example.invalid/cfg-A/configure", null);
  r.ok("addonsManager.resolveUrl strips /configure and sees an installed id", hostMatch.matchKind === "id-match" && hostMatch.url === confUrl, JSON.stringify(hostMatch));
  r.ok("addonsManager.resolveUrl reports a bad link", !!(await am.resolveUrl("ftp://nope", null)).error);
  const upd = await am.installUrl(confUrlB, null);
  const afterUpd = rec.engine.addonStore.loadInstalled();
  r.ok("addonsManager.installUrl replaces the configured copy in place", upd.ok && upd.replaced && upd.toast === "Updated" && afterUpd.length === 2 && afterUpd.some((a) => a.transportUrl === confUrlB) && !afterUpd.some((a) => a.transportUrl === confUrl), JSON.stringify({ upd, afterUpd: afterUpd.map((a) => a.transportUrl) }));
  const det = await am.detail(conf.id, null, false);
  const statLabels = det ? det.stats.map((s) => s.label) : [];
  r.ok("addonsManager.detail: manifest facts, configure URL, masked URL, stremio link", det && det.configurable && det.configurationRequired && det.card.installed && det.version === "2.0.0" && ["Version", "Resources", "Types", "ID prefixes", "Catalogs", "ID"].every((l) => statLabels.includes(l)) && det.configureUrl === "https://conf.example.invalid/cfg-B/configure" && det.maskedUrl === "https://conf.example.invalid/…/manifest.json" && det.stremioUrl === "stremio://conf.example.invalid/cfg-B/manifest.json" && det.catalogs[0].name === "Top", JSON.stringify(det && { stats: det.stats, configureUrl: det.configureUrl, masked: det.maskedUrl, version: det.version }));
  r.ok("addonsManager.detail: community stars, documentation, eyebrow, recommendations", det && det.community && det.community.stars === 300 && /debrid/.test(det.documentation ?? "") && /^Community · /.test(det.eyebrow) && Array.isArray(det.related) && Array.isArray(det.recommended), JSON.stringify(det && { community: det.community, eyebrow: det.eyebrow, doc: det.documentation, related: det.related.map((x) => x.id) }));
  r.eq("addonsManager.detail returns null for an unknown id", await am.detail("org.example.nothing-at-all", null, false), null);
  // Organize without an account: the device list, reordered and mirrored into the install order.
  const orgLocal = await am.organizeLoad(null);
  r.ok("addonsManager.organizeLoad without Stremio lists this device", orgLocal.ok && !orgLocal.signedIn && orgLocal.device.length === 2 && orgLocal.cloud.length === 0, JSON.stringify(orgLocal));
  const savedLocal = await am.organizeSave([], [orgLocal.device[1].key, orgLocal.device[0].key]);
  r.ok("addonsManager.organizeSave (device) rewrites the install order and the display order", savedLocal.ok && savedLocal.scope === "local" && rec.engine.addonStore.loadInstalled()[0].transportUrl === confUrlB && JSON.parse(rec.node.storage.get("harbor.addonOrder"))[0] === confUrlB, JSON.stringify(savedLocal));
  r.eq("addonsManager.load follows the saved order", (await am.load(null, false, true)).installed.map((c) => c.id), [conf.id, plain.id]);
  // Organize with an account: saveCollectionOrder writes, reads back, and backs up once.
  const orgCloud = await am.organizeLoad("auth-1");
  r.ok("addonsManager.organizeLoad with Stremio: account order + device-only addons", orgCloud.ok && orgCloud.signedIn && orgCloud.cloud.map((c) => c.name).join(",") === "One,Two" && orgCloud.device.length === 2, JSON.stringify(orgCloud));
  const savedCloud = await am.organizeSave([orgCloud.cloud[1].key, orgCloud.cloud[0].key], orgCloud.device.map((d) => d.key));
  r.ok("addonsManager.organizeSave (account) writes the new order and verifies it", savedCloud.ok && savedCloud.scope === "cloud" && cloud.map((a) => a.manifest.name).join(",") === "Two,One" && am.organizeBackups().length === 1, JSON.stringify({ savedCloud, order: cloud.map((a) => a.manifest.name) }));
  const org2 = await am.organizeLoad("auth-1");
  cloud = [...cloud, { transportUrl: "https://three.example.invalid/manifest.json", transportName: "", manifest: mk("org.example.three", "Three"), flags: { official: false, protected: false } }];
  const stale = await am.organizeSave([org2.cloud[1].key, org2.cloud[0].key], []);
  r.ok("addonsManager.organizeSave refuses when the account changed elsewhere", !stale.ok && stale.reload === true && /another device/.test(stale.text), JSON.stringify(stale));
  const org3 = await am.organizeLoad("auth-1");
  const restored = am.organizeRestore(0);
  r.ok("addonsManager.organizeRestore lays a backup over the loaded list (newer addons stay at the end)", restored && restored.keys.length === 3 && restored.keys.map((k) => org3.cloud.find((c) => c.key === k).name).join(",") === "One,Two,Three", JSON.stringify({ restored, org3: org3.cloud }));
  const moved = await am.organizeMoveAll();
  r.ok("addonsManager.organizeMoveAll puts device-only addons on the account", moved.ok && cloud.length === 5 && /Moved 2 addons/.test(moved.text), JSON.stringify({ moved, n: cloud.length }));
  const rm = await am.uninstall(plain.id, plainUrl);
  r.ok("addonsManager.uninstall removes the install", rm.ok && rm.toast === "Removed" && !rec.engine.addonStore.loadInstalled().some((a) => a.transportUrl === plainUrl), JSON.stringify(rm));
  // Age gate: upstream's banks, read from the component source.
  const src = (await import("node:fs")).readFileSync(new URL("../reference/harbor/src/components/age-gate-modal.tsx", import.meta.url), "utf8");
  const arStart = src.indexOf("AR_QUESTION_BANK");
  const enCount = (src.slice(src.indexOf("QUESTION_BANK"), arStart).match(/\n\s+q:\s/g) ?? []).length;
  const arCount = (src.slice(arStart).match(/\n\s+q:\s/g) ?? []).length;
  const gate = am.ageGate("en", 12345);
  r.ok("addonsManager.ageGate reads every upstream question (English bank)", gate.bankSize === enCount && enCount >= 10, JSON.stringify({ bank: gate.bankSize, enCount }));
  r.ok("addonsManager.ageGate: three distinct questions of four options, answer in range", gate.questions.length === 3 && new Set(gate.questions.map((q) => q.q)).size === 3 && gate.questions.every((q) => q.options.length === 4 && q.correct >= 0 && q.correct < 4 && src.includes(q.options[q.correct])), JSON.stringify(gate.questions));
  r.eq("addonsManager.ageGate is deterministic for a seed (pickThree)", am.ageGate("en", 12345).questions.map((q) => q.q), gate.questions.map((q) => q.q));
  const ar = am.ageGate("ar", 777);
  r.ok("addonsManager.ageGate uses the Arabic bank for Arabic", ar.bankSize === arCount && arCount >= 10 && /[\u0600-\u06FF]/.test(ar.questions[0].q), JSON.stringify({ bank: ar.bankSize, arCount, q: ar.questions[0].q }));
  rec.dispose();
}

// --------------------- (bug pass 2) odd community manifests; Detail's one-call local resume read
{
  const SA = "https://stremio-addons.net/api/v0";
  const good = { id: "org.example.good", version: "1.0.0", name: "Good Addon", description: "Fine. More.", resources: ["stream"], types: ["movie"], catalogs: [] };
  // A directory entry as a careless author could publish it: every field the cards read has the wrong type.
  const odd = { id: "org.example.odd", version: 2, name: 42, description: { text: "object" }, logo: 7, background: ["x"], resources: ["stream", 5, { name: "meta" }], types: ["movie", 5, null, { t: 1 }], idPrefixes: "tt", catalogs: [null, { type: "movie", id: "c", name: "C" }], behaviorHints: "yes" };
  const listing = [
    { uuid: "u-good", url: "", manifestUrl: "https://good.example.invalid/manifest.json", manifest: good, slug: "good", stars: 10, categories: [], configureUrl: null, createdAt: "", updatedAt: "" },
    { uuid: 77, url: "", manifestUrl: "https://odd.example.invalid/manifest.json", manifest: odd, slug: 99, stars: "12", categories: [], configureUrl: null, createdAt: "", updatedAt: "" },
  ];
  const rec = loadEngine({ storage: new Map([
    ["harbor.profiles.v1", JSON.stringify({ activeId: "default", profiles: [{ id: "default", isPrimary: true }] })],
    ["harbor.resume", JSON.stringify({
      "tt1|s1e1": { ms: 60000, t: 5, pct: 0.1 },
      "tt1|s1e2": { ms: 90000, t: 9 },
      "tt1|s2e1": { ms: 0, t: 12 },
      "tt1|sXe1": { ms: 1000, t: 20 },
      "tt10|s1e1": { ms: 1000, t: 30 },
      "tt1": { ms: 5000, t: 40 },
    })],
  ]) });
  const json = (req, body, status = 200) => ({ status, statusText: "OK", headers: { "content-type": "application/json" }, url: req.url, body: JSON.stringify(body) });
  rec.node.host.fetch = async (req) => {
    if (req.url.startsWith(`${SA}/addons?`)) return json(req, { addons: listing, pagination: { page: 1, limit: 50, total: 2, totalPages: 1, hasNextPage: false, hasPreviousPage: false } });
    if (req.url === `${SA}/rising`) return json(req, { addons: [] });
    if (req.url === `${SA}/categories`) return json(req, { categories: [] });
    if (new URL(req.url).host === "v3-cinemeta.strem.io" || req.url === "https://api.strem.io/addonsofficialcollection.json") return json(req, { addons: [] });
    return { status: 404, statusText: "Not Found", headers: {}, url: req.url, body: "" };
  };
  const am = rec.engine.addonsManager;
  // Every AddonCard field has the type engine/addonsManager.ts declares (the Swift Card decode is strict).
  const cardOk = (c) => ["key", "id", "name", "description", "subtitle", "transportUrl", "configureUrl"].every((k) => typeof c[k] === "string")
    && ["logo", "background", "slug"].every((k) => c[k] === null || typeof c[k] === "string")
    && ["installed", "configurable", "isNew", "enabled"].every((k) => typeof c[k] === "boolean")
    && Array.isArray(c.types) && c.types.every((x) => typeof x === "string")
    && typeof c.stars === "number" && Number.isInteger(c.position)
    && (c.rising === null || typeof c.rising === "number") && (c.risingWindow === null || typeof c.risingWindow === "number");
  const top = await am.browse("top", null, null, true, 1);
  const oddCard = top.items.find((c) => c.id === odd.id);
  r.ok("addonsManager.browse survives a manifest with odd field types (bug pass 2)", top.items.length === 2 && top.items.every(cardOk) && oddCard && oddCard.name === "42" && oddCard.description === "" && oddCard.logo === null && oddCard.stars === 12 && oddCard.slug === "99" && oddCard.types.join(",") === "movie,5", JSON.stringify(top.items));
  const railCards = await am.rail("stars", true);
  r.ok("addonsManager.rail survives it too", railCards.length === 2 && railCards.every(cardOk), JSON.stringify(railCards));
  const loaded = await am.load(null, true, true);
  r.ok("addonsManager.load: the catalog build survives it (normalizeAddonName on a numeric name)", loaded && loaded.total >= 2, JSON.stringify(loaded));
  const det = await am.detail(odd.id, null, true);
  r.ok("addonsManager.detail: odd manifest gives string types / resources and a clean card", det && cardOk(det.card) && det.types.every((x) => typeof x === "string") && det.resources.every((x) => typeof x === "string") && det.stats.every((s) => typeof s.value === "string"), JSON.stringify(det && { types: det.types, resources: det.resources, card: det.card }));
  const res = rec.engine.player.localResumes("tt1");
  r.eq("player.localResumes: one title's episode entries with a position, newest first (bug pass 2)", res.map((x) => [x.season, x.episode, x.ms, x.t, x.pct ?? null]), [[1, 2, 90000, 9, null], [1, 1, 60000, 5, 0.1]]);
  r.eq("player.localResumes: nothing for an unknown title", rec.engine.player.localResumes("tt404"), []);
  rec.dispose();
}

// ------------------------------------------ AI search (lib/ai-search.ts, mocked provider, no network)
{
  const store = new Map([["harbor.profiles.v1", JSON.stringify({ activeId: "default", profiles: [{ id: "default", isPrimary: true }] })]]);
  const rec = loadEngine({ storage: store });
  const ai = rec.engine.aiSearch;
  const calls = [];
  let reply = null;
  const hdr = (req, name) => { const h = req.headers ?? {}; const k = Object.keys(h).find((x) => x.toLowerCase() === name); return k ? h[k] : undefined; };
  rec.node.host.fetch = async (req) => {
    calls.push(req);
    const json = (body, status = 200) => ({ status, statusText: status === 200 ? "OK" : "Error", headers: { "content-type": "application/json" }, url: req.url, body: typeof body === "string" ? body : JSON.stringify(body) });
    if (req.url === "https://openrouter.ai/api/v1/chat/completions" || req.url === "https://api.groq.com/openai/v1/chat/completions") return reply(req);
    if (req.url === "https://openrouter.ai/api/v1/models") return json({ data: [{ id: "google/gemma-4-26b-a4b-it:free" }, { id: "anthropic/claude-haiku-4.5" }] });
    if (req.url.startsWith("https://v3-cinemeta.strem.io/catalog/movie/top/search=Heat")) return json({ metas: [{ id: "tt0113277", type: "movie", name: "Heat", releaseInfo: "1995", imdbRating: "8.3", poster: "https://img.example.invalid/heat.jpg" }, { id: "tt9999999", type: "movie", name: "Heat Wave", releaseInfo: "2022" }] });
    if (req.url.startsWith("https://v3-cinemeta.strem.io/catalog/series/top/search=South%20Park")) return json({ metas: [{ id: "tt0121955", type: "series", name: "South Park", releaseInfo: "1997-" }] });
    if (req.url === "https://v3-cinemeta.strem.io/meta/series/tt0121955.json") return json({ meta: { id: "tt0121955", type: "series", name: "South Park", videos: [{ id: "tt0121955:13:5", season: 13, episode: 5, name: "Fishsticks" }] } });
    if (req.url.startsWith("https://v3-cinemeta.strem.io/catalog/")) return json({ metas: [] });
    return { status: 500, statusText: "Error", headers: {}, url: req.url, body: "" };
  };
  const picks = '```json\n[{"title":"Heat","year":1995,"type":"movie"},{"title":"South Park","type":"series","season":13,"episode":5,"episodeTitle":"The Kanye one"},{"title":"heat"},{"title":"Nothing Like This Exists"}]\n```';
  const ok = (content) => () => ({ status: 200, statusText: "OK", headers: { "content-type": "application/json" }, url: "", body: JSON.stringify({ choices: [{ message: { content } }] }) });

  const s0 = ai.state("default", true);
  r.ok("aiSearch.state: no key, OpenRouter tab, upstream's default model", !s0.anyKey && !s0.hasKey && s0.tab === "openrouter" && s0.model === "google/gemma-4-26b-a4b-it:free", JSON.stringify(s0));
  const nokey = await ai.run("the movie where a hitman spares a kid", "default", true);
  r.ok("aiSearch.run without a key asks for the OpenRouter key (ai-search-section copy)", nokey.status === "nokey" && nokey.message === "Add your OpenRouter API key in Settings, AI search to use this model." && calls.length === 0, JSON.stringify(nokey));

  const saved = ai.saveKey("openrouter", "  test-openrouter-key-abcd1234  ", "default", true);
  const stored = JSON.parse(store.get("harbor.ai-search.keys.v1.shared") ?? "{}");
  r.ok("aiSearch.saveKey keeps the trimmed key under the Keychain prefix, never in the settings blob", stored.openrouter === "test-openrouter-key-abcd1234" && !/test-openrouter-key/.test(store.get("harbor.settings.shared") ?? "") && saved.hasKey && saved.anyKey && saved.saved.openrouter === "••••1234", JSON.stringify({ stored, saved }));
  r.ok("aiSearch.keysPrefix is a KeyValueStore secret prefix (Keychain tier)", (await import("node:fs")).readFileSync(new URL("../App/Sources/Storage/KeyValueStore.swift", import.meta.url), "utf8").includes(`"${ai.keysPrefix}"`));

  reply = ok(picks);
  const done = await ai.run("heat and the south park kanye episode", "default", true);
  const post = calls.find((c) => c.url === "https://openrouter.ai/api/v1/chat/completions");
  const body = JSON.parse(post?.body ?? "{}");
  r.ok("aiSearch.run posts upstream's request to OpenRouter (key, model, Harbor title, system prompt, query)", post?.method === "POST" && hdr(post, "authorization") === "Bearer test-openrouter-key-abcd1234" && hdr(post, "x-title") === "Harbor" && body.model === "google/gemma-4-26b-a4b-it:free" && body.temperature === 0.4 && body.messages?.[0]?.role === "system" && /discovery engine/.test(body.messages[0].content) && body.messages?.[1]?.content === "heat and the south park kanye episode", JSON.stringify({ method: post?.method, headers: post?.headers, body }));
  r.ok("aiSearch.run parses the fenced JSON, drops the duplicate and the unmatched title, resolves Cinemeta metas", done.status === "done" && done.results.length === 2 && done.results[0].meta.id === "tt0113277" && done.results[0].meta.imdbRating === "8.3" && done.results[0].season === undefined, JSON.stringify(done));
  r.ok("aiSearch.run keeps the episode pick with Cinemeta's own episode title", done.results[1]?.meta.id === "tt0121955" && done.results[1].season === 13 && done.results[1].episode === 5 && done.results[1].episodeTitle === "Fishsticks", JSON.stringify(done.results[1]));

  reply = () => ({ status: 401, statusText: "Unauthorized", headers: {}, url: "", body: "No auth credentials found" });
  const denied = await ai.run("anything at all", "default", true);
  r.ok("aiSearch.run: a 401 is upstream's rejected-key message plus the provider's detail", denied.status === "error" && denied.message === "Your API key was rejected. Check it in Settings, AI search." && denied.detail === "No auth credentials found", JSON.stringify(denied));
  reply = () => ({ status: 200, statusText: "OK", headers: {}, url: "", body: JSON.stringify({ error: { code: 429, message: "slow down" } }) });
  const limited = await ai.run("anything at all", "default", true);
  r.ok("aiSearch.run: an error body with code 429 reads as rate-limited", limited.status === "error" && /rate-limited/.test(limited.message) && limited.detail === "slow down", JSON.stringify(limited));
  reply = () => ({ status: 503, statusText: "Unavailable", headers: {}, url: "", body: "" });
  r.eq("aiSearch.run: another status is \"AI search failed ({status}).\"", (await ai.run("anything at all", "default", true)).message, "AI search failed (503).");
  reply = ok("I cannot help with that.");
  const empty = await ai.run("anything at all", "default", true);
  r.ok("aiSearch.run: prose without a JSON array is an empty result", empty.status === "done" && empty.results.length === 0, JSON.stringify(empty));
  reply = ok("   ");
  r.ok("aiSearch.run: a blank reply is upstream's nothing-usable error", /nothing usable/.test((await ai.run("anything at all", "default", true)).message ?? ""));

  const mdl = ai.setModel("anthropic/claude-haiku-4.5", null, "default", true);
  r.ok("aiSearch.setModel (model menu) keeps the model's own provider tab and labels it", mdl.tab === "openrouter" && mdl.model === "anthropic/claude-haiku-4.5" && mdl.label === "Claude Haiku 4.5" && mdl.providerName === "Anthropic", JSON.stringify(mdl));
  const list = await ai.models("default", true);
  r.ok("aiSearch.models prunes OpenRouter's list to the live catalog; no Groq models without a Groq key", list.openrouter.map((m) => m.id).join() === "google/gemma-4-26b-a4b-it:free,anthropic/claude-haiku-4.5" && list.menu.every((m) => m.provider !== "groq") && list.defaults.openrouter === "google/gemma-4-26b-a4b-it:free", JSON.stringify(list));

  const groq = await ai.setProvider("groq", "default", true);
  r.ok("aiSearch.setProvider(groq) switches to Groq's first model and has no Groq key yet", groq.tab === "groq" && groq.model === "llama-3.3-70b-versatile" && !groq.hasKey && groq.anyKey, JSON.stringify(groq));
  r.eq("aiSearch.run on Groq without its key asks for the Groq key", (await ai.run("anything at all", "default", true)).message, "Add your Groq API key in Settings, AI search to use this model.");
  ai.saveKey("groq", "test-groq-key-5678", "default", true);
  calls.length = 0;
  reply = ok('[{"title":"Heat","type":"movie"}]');
  const g = await ai.run("a heist movie", "default", true);
  const gpost = calls.find((c) => c.url === "https://api.groq.com/openai/v1/chat/completions");
  r.ok("aiSearch.run on Groq posts to Groq with the Groq key and no OpenRouter headers", g.status === "done" && g.results.length === 1 && hdr(gpost, "authorization") === "Bearer test-groq-key-5678" && hdr(gpost, "x-title") === undefined && JSON.parse(gpost.body).model === "llama-3.3-70b-versatile", JSON.stringify({ g, headers: gpost?.headers }));
  const back = await ai.setProvider("openrouter", "default", true);
  r.eq("aiSearch.setProvider(openrouter) goes back to upstream's default model", [back.tab, back.model], ["openrouter", "google/gemma-4-26b-a4b-it:free"]);

  ai.setWebSearch(true, "default", true);
  calls.length = 0;
  reply = ok('[{"title":"Heat","type":"movie"}]');
  const web = await ai.run("a heist movie", "default", true);
  r.ok("aiSearch.run with live web context asks Jina Reader first and still answers when it fails", web.status === "done" && web.results.length === 1 && calls.some((c) => c.url.startsWith("https://r.jina.ai/")), JSON.stringify(calls.map((c) => c.url)));

  // A settings blob that still carries a key (a restored backup) hands it to the Keychain once.
  const blob = JSON.parse(store.get("harbor.settings.shared") ?? "{}");
  store.set("harbor.settings.shared", JSON.stringify({ ...blob, aiSearchKey: "test-key-from-backup-9999", jinaKey: "jina_abc" }));
  const legacy = loadEngine({ storage: store });
  const moved = legacy.engine.aiSearch.state("default", true);
  const keys = JSON.parse(store.get("harbor.ai-search.keys.v1.shared") ?? "{}");
  r.ok("aiSearch: a key left in the settings blob moves to the Keychain entry and leaves the blob", keys.openrouter === "test-openrouter-key-abcd1234" && keys.jina === "jina_abc" && moved.saved.jina === "••••" && !/test-key-from-backup|jina_abc/.test(store.get("harbor.settings.shared") ?? ""), JSON.stringify({ keys, blob: store.get("harbor.settings.shared")?.slice(0, 80) }));
  legacy.dispose();

  const setup = rec.engine.settingsRoom.controls("setup", "default", true);
  const liveAt = setup.findIndex((c) => c.pane === "live");
  const row = setup[liveAt + 1];
  r.ok("settingsRoom.controls(setup) has the AI search push row after Live TV playlists", row?.id === "aiSearch" && row.kind === "push" && row.pane === "ai" && row.label === "AI search" && row.detail === "OpenRouter · Gemma 4 26B", JSON.stringify(row));
  const other = loadEngine({ storage: new Map([["harbor.profiles.v1", JSON.stringify({ activeId: "default", profiles: [{ id: "default", isPrimary: true }] })]]) });
  const fresh = other.engine.settingsRoom.controls("setup", "default", true).find((c) => c.id === "aiSearch");
  r.eq("settingsRoom AI search row without a key says how to start", fresh?.detail, "Add an OpenRouter or Groq key from your phone");
  r.ok("settingsRoom.pane setup lists AI search", other.engine.settingsRoom.pane("default", true).setup.some((l) => l[0] === "AI search" && l[1] === "None"));
  other.dispose();
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
  const adl = await r.timed("animeDetail.load(kitsu:1)", () => engine.animeDetail.load({ id: "kitsu:1", type: "anime", name: "Cowboy Bebop" }, "default", true));
  r.ok("animeDetail.load returns Kitsu episodes with PlayEpisodes", adl && adl.episodes.length > 0 && typeof adl.episodes[0].playEpisode.episode === "number" && adl.canonicalId === "kitsu:1", JSON.stringify(adl && { eps: adl.episodes.length, chars: adl.characters.length, name: adl.detail.name }));
  const sb = await r.timed("scores.forMeta(tt0111161, card)", () => engine.scores.forMeta({ id: "tt0111161", type: "movie", name: "The Shawshank Redemption", imdbRating: "9.3" }, "default", true, "card"));
  r.ok("scores.forMeta returns an IMDb chip for a tt id", Array.isArray(sb) && sb.some((b) => b.kind === "rating" && b.source === "imdb"), JSON.stringify(sb));
  const fo = await r.timed("search.fanOut('blade runner')", () => engine.search.fanOut("blade runner", "default", true, null));
  r.ok("search.fanOut fuses Cinemeta into Movies without a TMDB key", fo && fo.movies.length > 0 && typeof fo.requestId === "number" && Array.isArray(fo.addonQueries), JSON.stringify(fo && { movies: fo.movies.length, series: fo.series.length, anime: fo.anime.length, queries: fo.addonQueries.length, addons: fo.addons.length }));
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
  r.ok("discoverRoom.buildFor carries the Voyages banner pool (backdrops that are not the poster)", disc && Array.isArray(disc.voyagePool) && disc.voyagePool.length <= 8 && disc.voyagePool.every((m) => m.background && m.background !== m.poster), JSON.stringify(disc && disc.voyagePool.length));
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
  r.ok("live.channels loads through upstream's playlist store, grouped + ordered", ch && ch.groups.length > 3 && ch.total > 100 && ch.channels[0].url.startsWith("http"), JSON.stringify(ch && { groups: ch.groups.length, total: ch.total, first: ch.channels[0] && [ch.channels[0].name, ch.channels[0].group] }));
  const pick = ch.channels[Math.min(40, ch.channels.length - 1)];
  r.eq("live.toggleFavorite adds", engine.live.toggleFavorite(pick), true);
  const ch2 = await engine.live.channels(pl.id);
  r.ok("favorites lead the guide order (bp-guide-order band 1)", ch2.channels[0].id === pick.id && ch2.channels[0].favorite === true, JSON.stringify(ch2.channels[0]));
  r.eq("live.toggleFavorite removes", engine.live.toggleFavorite(pick), false);
  r.eq("live.nowNext without a guide reports unknown", engine.live.nowNext(pl.id, [pick.id])[0].known, false);
  engine.live.removePlaylist(pl.id);
  r.ok("live.removePlaylist clears favorites for the source", !engine.live.favorites().some((f) => f.sourceId === pl.id));
  const sk = await r.timed("skip.segments(Breaking Bad S1E1)", () => engine.skip.segments("p_smoke", true, { id: "tt0903747", type: "series", name: "Breaking Bad" }, { season: 1, episode: 1, imdbId: "tt0903747", imdbSeason: 1, imdbEpisode: 1 }, 3480));
  r.ok("skip.segments returns a (possibly empty) segment list", Array.isArray(sk) && sk.every((x) => x.startSec < x.endSec), JSON.stringify(sk.slice(0, 3)));
  const fs = await import("node:fs");
  const awardsRaw = fs.readFileSync(new URL("../reference/harbor/src/data/awards.json", import.meta.url), "utf8");
  const t0aw = Date.now(); const ver = engine.discoverRoom.installAwards(awardsRaw);
  r.ok("discoverRoom.installAwards accepts the 4 MB catalog", ver > 0, `${(awardsRaw.length / 1048576).toFixed(1)} MB in ${Date.now() - t0aw} ms`);
  {
    const yr = String(new Date().getFullYear());
    engine.cards.setTop10([{ id: "tt0111161", name: "The Shawshank Redemption" }]);
    const cm = engine.cards.marks([
      { id: "tt15398776", type: "movie", name: "Oppenheimer", releaseInfo: "2023" },
      { id: "tt0111161", type: "movie", name: "The Shawshank Redemption", releaseInfo: "1994" },
      { id: "tt9999999", type: "series", name: "Brand New Show", releaseInfo: yr },
      { id: "tt8888888", type: "movie", name: "Cinema Now", releaseInfo: yr, releaseDate: new Date().toISOString(), inTheaters: true },
      { id: "tt7777777", type: "movie", name: "Old Rerun", releaseInfo: "2015", releaseDate: "2015-01-01", inTheaters: true },
    ], "default", true);
    r.ok("cards.marks: bundled Oscar chip", /Oscar/.test(cm[0].chip || ""), JSON.stringify(cm[0]));
    r.eq("cards.marks: Top 10 ribbon (right by default)", cm[1].top10, "right");
    r.eq("cards.marks: New chip", cm[2].chip, "New");
    r.eq("cards.marks: In Cinema chip", cm[3].chip, "In Cinema");
    r.eq("cards.marks: Rerun chip", cm[4].chip, "Rerun · 2015");
    // The saveProgress check above ran Shawshank to the credits, which sets the local movie flag.
    r.eq("cards.marks: watched check for the title just finished (topEnd, opposite the score corner)", cm[1].watched, "topEnd");
    r.ok("cards.marks: no bookmark/watched without state", cm.slice(2).every((m) => m.bookmark === null && m.watched === null));
    engine.settings.patch({ badgePlacement: "top" }, engine.settings.sourceKeyFor("default", true));
    const cm2 = engine.cards.marks([{ id: "tt0111161", type: "movie", name: "x" }], "default", true);
    r.eq("cards.marks: watched zone follows badgePlacement", cm2[0].watched, "bottomEnd");
    engine.settings.patch({ badgePlacement: "bottom" }, engine.settings.sourceKeyFor("default", true));
  }
  const aw = engine.discoverRoom.awards();
  r.ok("discoverRoom.awards has bundled bodies", aw.summaries.length >= 5 && aw.overview.wins > 100, JSON.stringify({ n: aw.summaries.length, first: aw.summaries[0] && aw.summaries[0].title, overview: aw.overview }));
  const ad = engine.discoverRoom.awardDetail(aw.summaries[0].type);
  r.ok("discoverRoom.awardDetail has categories with winners", ad.groups.length > 0 && ad.groups[0].entries.length > 0, JSON.stringify({ title: ad.title, groups: ad.groups.length, first: ad.groups[0] && ad.groups[0].entries[0] }));
  const pp = await r.timed("discoverRoom.people(24)", () => engine.discoverRoom.people(24));
  r.ok("discoverRoom.people returns ranked people (or [] if harbor.site is unreachable)", Array.isArray(pp), JSON.stringify(pp.slice(0, 2)));
  {
    const first = await engine.animeRoom.page("default", true, null);
    r.ok("animeRoom.page returns at once while Jikan rows load", Array.isArray(first.rows) && first.total >= 16 && typeof first.loading === "boolean", JSON.stringify({ rows: first.rows.length, ready: first.ready, loading: first.loading }));
    let waited = 0;
    while (waited < 60000) { await new Promise((res) => setTimeout(res, 2000)); waited += 2000; const p = await engine.animeRoom.page("default", true, null); if (!p.loading) break; }
    const done = await engine.animeRoom.page("default", true, null);
    r.ok("animeRoom rows fill in (or Jikan is down and every row reported)", done.ready === done.total, JSON.stringify({ ready: done.ready, rows: done.rows.map((x) => [x.key, x.metas.length, x.shape]).slice(0, 8), hero: done.hero.length }));
    r.ok("animeRoom ranked rows carry at most 10 and the rank shape", done.rows.filter((x) => x.shape === "rank").every((x) => x.metas.length <= 10), JSON.stringify(done.rows.filter((x) => x.shape === "rank").map((x) => [x.key, x.metas.length])));
  }
  r.eq("trakt.status when signed out", engine.trakt.status(), { authenticated: false, username: null });
  const dc = await r.timed("trakt.deviceCode()", () => engine.trakt.deviceCode().catch((e) => ({ error: e.message })));
  r.ok("trakt.deviceCode returns a user code (or a clear error)", (dc && dc.userCode && dc.userCode.length >= 6) || (dc && dc.error), JSON.stringify(dc && { code: dc.userCode, url: dc.verificationUrl, error: dc.error }));
  // ---- sports (ESPN public feeds, no key)
  r.eq("sports.consent starts unknown", engine.sports.consent().status, "unknown");
  r.eq("sports.accept persists", engine.sports.accept().status, "accepted");
  const scat = engine.sports.catalog();
  r.ok("sports.catalog lists groups, leagues and the starter selection", scat.groups.length > 8 && scat.leagues.length > 60 && scat.selected.length > 30 && scat.personalized === false, JSON.stringify({ g: scat.groups.length, l: scat.leagues.length, s: scat.selected.length }));
  const quick = await r.timed("sports.page(for-you, no wait) returns from cache at once", () => engine.sports.page({ mode: "for-you", group: "all" }));
  r.ok("sports.page without wait reports busy while feeds load", quick.status.busy === true && Array.isArray(quick.rows), JSON.stringify(quick.status));
  const sdays = engine.sports.days();
  r.ok("sports.days: 14 cells with Today at index 3", sdays.length === 14 && sdays[3].today && sdays[3].label === "Today", JSON.stringify(sdays.slice(2, 5)));
  const spg = await r.timed("sports.page(for-you)", () => engine.sports.page({ mode: "for-you", group: "all", wait: true }));
  r.ok("sports.page for-you returns groups, rows and a status", Array.isArray(spg.rows) && spg.groups.length > 3 && spg.status && typeof spg.status.failed === "boolean", JSON.stringify({ rows: spg.rows.map((x) => [x.key, x.games.length]), heroes: spg.heroes.length, note: spg.status.note, failed: spg.status.failedKeys.slice(0, 4) }));
  const anyGame = spg.rows.flatMap((x) => x.games)[0] ?? spg.heroes[0];
  r.ok("sports game view carries display fields", !anyGame || (typeof anyGame.leagueLabel === "string" && typeof anyGame.statusText === "string" && typeof anyGame.quiet === "string" && typeof anyGame.key === "string"), JSON.stringify(anyGame && { league: anyGame.leagueLabel, status: anyGame.statusText, quiet: anyGame.quiet, home: anyGame.home.name, away: anyGame.away.name }));
  const ssl = await r.timed("sports.page(live)", () => engine.sports.page({ mode: "live", group: "all", wait: true }));
  r.ok("sports.page live groups by league (may be empty off-hours)", Array.isArray(ssl.rows) && ssl.rows.every((x) => x.key.startsWith("live:")), JSON.stringify(ssl.rows.map((x) => [x.title, x.games.length]).slice(0, 5)));
  const ssc = await r.timed("sports.page(schedule, cached)", () => engine.sports.page({ mode: "schedule", group: "all", wait: true }));
  r.ok("sports.page schedule rows keyed by league", Array.isArray(ssc.rows) && ssc.rows.every((x) => x.key.startsWith("schedule:")), JSON.stringify(ssc.rows.slice(0, 3).map((x) => [x.title, x.games.length])));
  if (anyGame) {
    const det = await r.timed("sports.detail(first game)", () => engine.sports.detail(anyGame).catch((e) => ({ error: e.message })));
    r.ok("sports.detail returns a summary (or null/err for non-ESPN sources)", det === null || (det && (det.error || Array.isArray(det.homeRoster))), JSON.stringify(det && { err: det.error, roster: det.homeRoster && det.homeRoster.length, events: det.events && det.events.length }));
  }
  if (anyGame) {
    const w = await r.timed("sports.watch(first game, no Live TV source)", () => engine.sports.watch(anyGame));
    r.ok("sports.watch plans setup without playlists and lists providers", ["setup", "finished", "broadcast"].includes(w.plan) && Array.isArray(w.providers) && typeof w.fixture === "string" && w.channels.length === 0, JSON.stringify({ plan: w.plan, fixture: w.fixture, providers: w.providers.map((p) => p.name) }));
  }
  engine.sports.setLeagues(["NBA", "EPL"]);
  r.ok("sports.setLeagues personalizes both stores", engine.sports.catalog().selected.join(",") === "NBA,EPL" && engine.sports.catalog().personalized === true);
  r.eq("sports.decline", engine.sports.decline().status, "declined");
  r.eq("simkl.status when signed out", engine.simkl.status(), { authenticated: false, username: null });
  const spin = await r.timed("simkl.deviceCode()", () => engine.simkl.deviceCode().catch((e) => ({ error: e.message })));
  r.ok("simkl.deviceCode returns a PIN (or a clear error)", (spin && spin.userCode && spin.userCode.length >= 4 && spin.verificationUrl) || (spin && spin.error), JSON.stringify(spin));
  r.eq("simkl.scrobble skips when not connected", await engine.simkl.scrobble("start", "tt0111161", null, 5), { sent: false, reason: "not-connected" });
  const scrob = await engine.trakt.scrobble("start", "tt0111161", null, 5);
  r.eq("trakt.scrobble skips when not connected", scrob, { sent: false, reason: "not-connected" });
  const col = await r.timed("collectionsRoom.all()", () => engine.collectionsRoom.all());
  r.ok("collectionsRoom.all returns community collections (or [] when harbor.site is down)", col && Array.isArray(col.community) && Array.isArray(col.mine), JSON.stringify({ mine: col.mine.length, community: col.community.length, first: col.community[0] && [col.community[0].name, col.community[0].count, col.community[0].byline] }));
  r.ok("rooms.page returns a second page for a pageable row", !pageable || (Array.isArray(pagedMetas) && pagedMetas.length > 0), JSON.stringify({ key: pageable && pageable.key, n: pagedMetas.length }));
}

// --------------------------------------------------------------------------- report
console.log(`\nbundle ${(app.bytes / 1024).toFixed(0)} KB, evaluated in ${app.loadMs.toFixed(0)} ms`);
console.log(`localStorage keys reaching the host: ${JSON.stringify([...app.node.storage.keys()].sort())}`);
console.log(`host: ${app.node.stats.requests} requests, ${(app.node.stats.bytes / 1024).toFixed(0)} KB downloaded`);
app.dispose();
r.finish();
