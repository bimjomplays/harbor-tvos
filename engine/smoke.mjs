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
  const files = [{ idx: 0, name: "sample.mkv", length: 10 }, { idx: 1, name: "Show.S01E02.1080p.mkv", length: 900 }, { idx: 2, name: "Show.S01E03.1080p.mkv", length: 1000 }, { idx: 3, name: "info.nfo", length: 5000 }];
  r.eq("P2P: p2pFileIdx picks the episode's file, else the largest video", [e.streamsRoom.p2pFileIdx(files, 1, 2), e.streamsRoom.p2pFileIdx(files, null, null), e.streamsRoom.p2pFileIdx([{ idx: 0, name: "a.nfo", length: 3 }], 1, 1)], [1, 2, 0]);
  rec.dispose();
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
  r.ok("parental.gate: PIN + locked tabs hide the Big Picture tabs that carry the key (live TV has none)", g1.locked && g1.hasPin && g1.anyLocked && JSON.stringify(g1.hiddenRooms) === JSON.stringify(["anime", "manga", "movies"]) && g1.hiddenTabs.liveTv === true && !("bogus" in g1.hiddenTabs), JSON.stringify(g1));
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

// ------------------------------------------ themes, language picker, settings preview, done facts
{
  const near = (a, hex) => [16, 8, 0].every((sh, i) => Math.abs(Math.round(a[i] * 255) - ((hex >> sh) & 0xff)) <= 1) && a[3] === 1;
  const st = engine.themes.state("default", true);
  r.eq("themes.state: upstream's library, built-in then featured", st.presets.map((p) => p.id), ["cool-grey", "nord", "stremio", "tokyo-night", "dracula", "forest", "noir", "velvet", "crunch", "kawaii", "aurora", "minui"]);
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
  r.eq("settingsRoom.pane: subtitle sample at 0.55x, flags, line groups", [pane.subtitle.px, pane.subtitle.flags.length > 0, pane.playback.length, pane.setup.length, pane.interface.length, pane.overscanLabel], [18, true, 6, 3, 3, "Off"]);
  r.ok("settingsRoom.pane: services carry name and tint", pane.services.length > 0 && pane.services.every((s) => s.label && s.tint.startsWith("#")));
  const setupKey = engine.settings.sourceKeyFor("default", true);
  const before = engine.settingsRoom.pane("default", true).setup[1][1];
  engine.settings.patch({ tmdbKey: "0123456789abcdef0123456789abcdef" }, setupKey);
  const smokeList = engine.live.addPlaylist("Smoke setup", "https://example.invalid/setup.m3u", null);
  const after = String(Number(before) + 1);
  const setupRows = engine.settingsRoom.controls("setup", "default", true);
  r.eq("ST-1: setup push rows report what is connected and how many playlists", setupRows.filter((c) => c.kind === "push").map((c) => c.detail), ["Connected: TMDB", `${after} added`]);
  r.eq("settingsRoom.pane(setup) lines follow", engine.settingsRoom.pane("default", true).setup, [["TMDB", "On"], ["Live TV playlists", after], ["Setup", "TMDB"]]);
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
  r.eq("player.prefs: upstream defaults (auto lead, auto-advance on, 10 s steps)", e.player.prefs("default", true), { autoPlayNextEpisode: true, nextEpisodeLeadSec: -1, seekBackStepSec: 10, seekForwardStepSec: 10 });
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
