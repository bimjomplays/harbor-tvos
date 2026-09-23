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
  r.eq("detailRoom.collection is null without a TMDB key", await engine.detailRoom.collection(10, "default", true), null);
}

// ----------------------------------------------------------------------- home servers
{
  r.eq("homeServers.connections empty", await engine.homeServers.connections(), []);
  r.eq("homeServers.copies without connections", await engine.homeServers.copies({ id: "tt0111161", type: "movie", name: "x" }, "tt0111161"), []);
  r.eq("homeServers.titles empty", await engine.homeServers.titles(), []);
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
  r.eq("live.homeRow without playlists", await engine.live.homeRow(), { playlistId: null, cells: [] });
  r.eq("onboarding.vote records an upvote", engine.onboarding.vote("tt0000001", true, "Smoke", "movie").includes("tt0000001"), true);
  r.eq("onboarding.vote clears it again", engine.onboarding.vote("tt0000001", false, "Smoke", "movie").includes("tt0000001"), false);
  r.eq("live.loadShortEpg ignores a non-Xtream playlist", await engine.live.loadShortEpg("nope", ["a"]), { hydrated: 0 });
  r.eq("discoverRoom.genrePage without a TMDB key", (await engine.discoverRoom.genrePage("default", true, "Action", 1)).status, "no-key");
  r.eq("search.fanOut with an empty query", (await engine.search.fanOut("  ", "default", true, null)).movies, []);
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

// ----------------------------------------------------------------------- profiles room
{
  const av = engine.profilesRoom.avatars();
  r.ok("profilesRoom.avatars lists upstream's catalog with bundle paths", av.length >= 4 && av[0].items[0].path === "/avatars/harbor_person_01.webp", JSON.stringify(av.map((g) => [g.group, g.items.length])));
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
    // A sports channel in the playlist should match a fixture by team names (iptv-match).
    const m3u2 = `#EXTM3U\n#EXTINF:-1 group-title="Sports",ESPN Lakers vs Celtics\nhttps://example.invalid/lakers.m3u8\n#EXTINF:-1 group-title="News",CNN\nhttps://example.invalid/cnn.m3u8\n`;
    rec.node.host.fetch = async (req) => ({ status: 200, statusText: "OK", headers: { "content-type": "audio/x-mpegurl" }, url: req.url, body: m3u2 });
    rec.engine.live.addPlaylist("Sports list", "https://sports.example.invalid/list.m3u");
    const game = { id: "g1", league: "NBA", state: "in", detail: "Q2 5:12", home: { id: "1", name: "Boston Celtics", abbr: "BOS", logo: "", score: "50", winner: false }, away: { id: "2", name: "Los Angeles Lakers", abbr: "LAL", logo: "", score: "48", winner: false }, startMs: Date.now() - 3600000 };
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
    r.ok("sports.watch plans setup without playlists and lists providers", (w.plan === "setup" || w.plan === "finished") && Array.isArray(w.providers) && typeof w.fixture === "string" && w.channels.length === 0, JSON.stringify({ plan: w.plan, fixture: w.fixture, providers: w.providers.map((p) => p.name) }));
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
