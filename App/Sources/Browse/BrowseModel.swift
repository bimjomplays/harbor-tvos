import Foundation
import Combine
import SwiftUI
import UIKit

/// Where a room gets its rows. The engine (upstream logic in JavaScriptCore) implements this;
/// `FixtureBrowseSource` feeds simulator screenshots without the network.
protocol BrowseSource {
    func rows(for room: Room) async throws -> [BrowseRow]
    /// The rows plus the hero slides the page's lead title comes from (the anime room's
    /// use-bp-anime `hero.slides`); a room without such a list has none.
    func page(for room: Room) async throws -> BrowsePage
    func continueWatching(for room: Room) async throws -> [ContinueItem]
    /// Distinct pages sharing a room kind (a streaming-service page) keep their own cache slot.
    var cacheId: String? { get }
}

struct BrowsePage {
    var rows: [BrowseRow]
    var hero: [Meta]
}

extension BrowseSource {
    var cacheId: String? { nil }

    func page(for room: Room) async throws -> BrowsePage {
        let rows: [BrowseRow] = try await self.rows(for: room)
        return BrowsePage(rows: rows, hero: [])
    }
}

@MainActor
final class BrowseModel: ObservableObject {
    @Published private(set) var rows: [BrowseRow] = []
    @Published private(set) var continueWatching: [ContinueItem] = []
    @Published private(set) var loading = false
    @Published private(set) var failed: String?
    @Published var spotlight: Meta?
    /// bp-hero-pips: how many titles the hero cycles through and which one it shows (0 = no cycle).
    @Published private(set) var heroCount = 0
    @Published private(set) var heroIndex = 0
    /// A tile holds focus somewhere in the room (use-bp-hero-cycle cardFocused()).
    @Published private(set) var tileHeld = false
    /// bp-home cwReady: the first Continue Watching read has answered (or the load failed). The
    /// room seeds its first focus only once both it and the rows are in.
    @Published private(set) var cwResolved = false
    /// use-bp-anime `hero.slides` (the anime room's hero pool); empty elsewhere.
    @Published private(set) var heroSlides: [Meta] = []
    /// A load has finished at least once (so an empty page is an answer, not a first frame).
    @Published private(set) var settled = false

    let room: Room
    private let source: BrowseSource
    private var heroTask: Task<Void, Never>?
    private var cardFocused = false
    private var heldRows: Set<String> = []
    /// (open-items sweep 2) Rows whose See all chip holds the ring (seeAllHold).
    private var seeAllRows: Set<String> = []

    private var unsubscribe: (() -> Void)?
    private var refreshTask: Task<Void, Never>?
    /// Numbers Continue Watching reads, so a slower older answer never replaces a newer one.
    private var cwGeneration = 0

    /// bp-restore route entry: where focus lands when this page opens again. bp-home.tsx forgets
    /// the Home position on mount (Home always opens on its first card); rows keep their memory.
    private(set) var entry: BPRestore.Position?

    init(room: Room, source: BrowseSource) {
        self.room = room
        self.source = source
        let key = "\(source.cacheId ?? room.rawValue).\(ProfilesStore.shared.activeId ?? "none")"
        if room == .home && source.cacheId == nil {
            BPRestore.forget(key)
        } else {
            entry = BPRestore.position(key)
        }
        // Anime: Jikan rows land one by one; re-read the page (from memory) after each burst.
        // Home: use-bp-extra-rows' async rows (Trakt, Simkl, anime, pinned…) that missed the
        // build's grace, and Settings → Home rows edits (engine/homeExtras.ts); the engine reuses
        // the catalog rows it just built for that re-read.
        // (addons pass) home.tsx also rebuilds on harbor:addons-changed: an addon installed from a
        // stremio:// link while Home is up (or switched off / reordered) changes its rows now.
        var events: Set<String> = []
        if room == .anime {
            events = ["harbor:anime-updated"]
        } else if room == .home && source.cacheId == nil {
            events = ["harbor:home-updated", "harbor:addons-changed"]
        }
        let reloadEvents = events
        if !reloadEvents.isEmpty, !(source is FixtureBrowseSource) {
            unsubscribe = HarborEngine.shared.onEvent { [weak self] type, _ in
                guard reloadEvents.contains(type) else { return }
                self?.refreshTask?.cancel()
                self?.refreshTask = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(400))
                    guard !Task.isCancelled else { return }
                    await self?.load()
                }
            }
        }
    }

    deinit { unsubscribe?(); refreshTask?.cancel(); heroTask?.cancel() }

    /// Home itself, not a streaming-service page that reuses the Home room layout: only Home has
    /// the Live TV row and the band-owned bands (bp-home.tsx).
    var isHomePage: Bool { room == .home && source.cacheId == nil }
    /// A streaming-service page (bp-service.tsx) over the Home layout.
    var isServicePage: Bool { source is ServiceBrowseSource }
    /// The page shows a Continue Watching row (EngineBrowseSource: none on Movies or a service page).
    private var hasContinueWatchingRow: Bool {
        if source is FixtureBrowseSource { return true }
        if room == .movies { return false }
        return room != .home || isHomePage
    }

    private var cacheKey: String { "bp.room.\(restoreKey)" }
    /// The route key bp-restore remembers positions under (per page and profile).
    var restoreKey: String { "\(source.cacheId ?? room.rawValue).\(ProfilesStore.shared.activeId ?? "none")" }
    /// Fixture rows never touch the cache, so a screenshot run cannot poison a live one.
    private var cacheable: Bool { !(source is FixtureBrowseSource) }

    private var reloadPending = false

    func load() async {
        // A refresh asked for mid-load runs once this one finishes, so the last arrival is never lost.
        guard !loading else { reloadPending = true; return }
        // (regression pass) `failed` stays until this read answers, like DiscoverModel.load: the
        // failure card's Try again held the ring, and clearing the card at once swapped in the spinner
        // with nothing to focus, so the ring fell to the tab bar and a second failure brought the
        // card back without it. The card stays up (busy) until the answer (RoomView).
        loading = true
        // Last session's shelves first (bp-home-cache): a TV kills the process between
        // sessions and nobody should watch an empty screen while the live build runs.
        // (perf pass) The cached shelves (a few hundred KB of JSON) are read and decoded off the main
        // thread, and written back off it too; both ran on main at every room open and every reload.
        let key = cacheKey
        if cacheable, rows.isEmpty {
            let cached = await Task.detached(priority: .userInitiated) { CacheStore.shared.get([BrowseRow].self, for: key) }.value
            if rows.isEmpty, let cached, !cached.isEmpty {
                failed = nil
                rows = cached
                if spotlight == nil { spotlight = cached.first?.metas.first }
            }
        }
        cwGeneration += 1
        let cwMine = cwGeneration
        // (review 6) A page with no Continue Watching row (Movies, a streaming-service page) has
        // nothing to wait for: cwResolved only turned true after the live rows were built, so the
        // first focus sat on the tab bar for up to 3 s over last session's rows (bp-movies seeds on
        // its rows alone). It seeded 0.05 s after them before the home pass.
        if !hasContinueWatchingRow { cwResolved = true }
        do {
            async let r = source.page(for: room)
            async let cw = source.continueWatching(for: room)
            let page: BrowsePage = try await r
            let live: [BrowseRow] = page.rows
            if page.hero != heroSlides { heroSlides = page.hero }
            if failed != nil { failed = nil }
            // A re-read that built the same shelves (Home's harbor:home-updated, the anime bursts)
            // republishes nothing and rewrites nothing.
            if live != rows {
                rows = live
                if cacheable { Task.detached(priority: .utility) { try? CacheStore.shared.set(live, for: key) } }
            }
            let cwItems: [ContinueItem] = (try? await cw) ?? []
            if cwMine == cwGeneration, cwItems != continueWatching { continueWatching = cwItems }
            cwResolved = true
            // A row that left while holding focus never reports losing it.
            let keys = Set(live.map(\.key))
            let cwShown = !continueWatching.isEmpty
            heldRows = heldRows.filter { $0 == "cw" ? cwShown : keys.contains($0) }
            seeAllRows = seeAllRows.filter { keys.contains($0) }
            tileHeld = !heldRows.isEmpty
            // A stale spotlight (from the cache, or a title that fell off the rows) resets.
            let known = Set(live.flatMap { $0.metas.map(\.id) })
            if room == .anime {
                // bp-anime-hero seedBpMeta(lead): the hero opens on the lead title (the one Resume /
                // More Info lock to), not the first Top Picks card, until a card takes the ring.
                let seed: Meta? = heroLead ?? live.first?.metas.first
                if !cardFocused, let seed, spotlight?.id != seed.id { spotlight = seed }
            } else if !cardFocused, spotlight.map({ !known.contains($0.id) }) ?? true {
                spotlight = live.first?.metas.first
            }
            startHeroCycle()
            await CardMarksStore.shared.refresh(live.flatMap(\.metas))
        } catch {
            let why: String? = rows.isEmpty ? error.localizedDescription : nil
            if failed != why { failed = why }
            cwResolved = true
        }
        loading = false
        settled = true
        if reloadPending { reloadPending = false; await load() }
    }

    /// (home device pass) Continue Watching alone, re-read when a page over the room closes: a
    /// card removed in the quick panel stayed in the row (nothing listened for harbor:cw-dismissed),
    /// and after playback the row kept the old episode and progress, so its one-press resume went
    /// back to the episode just finished. Upstream's row follows the local resume store and the
    /// dismissals (mobile-cw-row subscribeLocalCw / useCwDismissVersion).
    func reloadContinueWatching() {
        guard !(source is FixtureBrowseSource) else { return }
        cwGeneration += 1
        let mine = cwGeneration
        let room = self.room
        let source = self.source
        Task { [weak self] in
            let items: [ContinueItem]? = try? await source.continueWatching(for: room)
            guard let self, let items, mine == self.cwGeneration else { return }
            if items != self.continueWatching { self.continueWatching = items }
            // A row that left while holding focus never reports losing it.
            if items.isEmpty { self.hold("cw", false) }
        }
    }

    func focus(_ meta: Meta) {
        cardFocused = true
        spotlight = meta
    }

    /// bp-anime-hero `lead`: heroSlide (the first hero slide with art and a logo, else with art),
    /// else the Continue Watching card with art (else the first), else the first slide, else the
    /// first Top Pick. The hero actions lock to it while they hold the ring (lockBpMeta(lead)).
    var heroLead: Meta? {
        let withLogo: Meta? = heroSlides.first { $0.background != nil && $0.logo != nil }
        let withArt: Meta? = heroSlides.first { $0.background != nil }
        if let slide = withLogo ?? withArt { return slide }
        let cwArt: ContinueItem? = continueWatching.first { $0.background != nil }
        if let item = cwArt ?? continueWatching.first { return Meta(continue: item) }
        if let first = heroSlides.first { return first }
        let picks: BrowseRow? = rows.first { $0.key == "anime-top-picks" }
        // Not upstream (its lead is null then): the first card, so the actions never vanish.
        return picks?.metas.first ?? rows.first?.metas.first
    }

    /// A row (keyed) gained or lost the focused tile. The cycle reads this on every tick the way
    /// upstream's cardFocused() asks the document whether the ring sits on a [data-bp-tile].
    func hold(_ rowKey: String, _ held: Bool) {
        if held { heldRows.insert(rowKey) } else { heldRows.remove(rowKey) }
        if tileHeld != !heldRows.isEmpty { tileHeld = !heldRows.isEmpty }
    }

    /// (open-items sweep 2) A row's See all chip holds the ring. The row still counts as held (the
    /// band and the rail follow it), but the cycle turns on: use-bp-hero-cycle cardFocused() asks
    /// for a [data-bp-tile] under the ring, and See all is not one (the hero paused there).
    func seeAllHold(_ rowKey: String, _ held: Bool) {
        if held { seeAllRows.insert(rowKey) } else { seeAllRows.remove(rowKey) }
    }

    /// Home is hidden: the saver or the curfew lock is up, the app is in the background, or a
    /// cover (the player, a Detail page, the account menu) is presented over the main window.
    /// Not while PiP browsing (PiPBrowse): the layer runs its own Home above the player's cover,
    /// and that one is on screen. (PreviewGate is stricter: it also stops previews under PiP.)
    private static var outOfSight: Bool {
        if ScreensaverModel.shared.active || CurfewState.shared.locked { return true }
        if UIApplication.shared.applicationState == .background { return true }
        if PiPBrowse.shared.isUp { return false }
        return !HarborOverlayWindow.noCoverPresented
    }

    /// use-bp-hero-cycle.ts: every 7 s (HOLD_MS) advance through the first row's first 8 items;
    /// a tick that finds a card focused just waits another hold. Never under Reduce Motion
    /// (`prefers-reduced-motion: reduce` returns before the first timer).
    private func startHeroCycle() {
        heroTask?.cancel()
        let pool = Array((rows.first?.metas ?? []).prefix(8))
        // (home device pass) Home only: bp-home is the one page that mounts useBpHeroCycle. On the
        // anime page it turned the title under Resume / More Info every 7 s while the ring sat on
        // them (those buttons are not tiles), so Resume started whichever title had rotated in.
        guard isHomePage, pool.count > 1, !UIAccessibility.isReduceMotionEnabled else {
            heroCount = 0
            return
        }
        if heroCount != pool.count || heroIndex >= pool.count { heroIndex = 0 }
        heroCount = pool.count
        heroTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(7))
                guard let self, !Task.isCancelled else { return }
                if UIAccessibility.isReduceMotionEnabled { self.heroCount = 0; return }
                // (open-items sweep 2) A row held by its See all chip alone does not hold the cycle.
                guard self.heldRows.subtracting(self.seeAllRows).isEmpty else { continue }
                // (perf/memory pass) Nobody sees Home under the player, a Detail page or any other
                // cover, the screensaver or the curfew lock: each turn there re-rendered Home and
                // decoded a new 1920 px backdrop behind the video. It picks up again on return.
                guard !Self.outOfSight else { continue }
                self.heroIndex = (self.heroIndex + 1) % pool.count
                self.spotlight = pool[self.heroIndex]
            }
        }
    }
}

/// Deterministic fake rows for the simulator.
struct FixtureBrowseSource: BrowseSource {
    /// `--fixtures roomfail`: every room's rows fail, after a beat like a real read, so the failure
    /// card and its Try again (RoomView) can be driven offline (NavigationTests2).
    static let failRooms: Bool = ProcessInfo.processInfo.arguments.contains("roomfail")
    /// `--fixtures calfail`: every Calendar month read fails after a beat (CalendarModel.load), for
    /// its error card's Try again (NavigationTests3).
    static let failCalendar: Bool = scenario("calfail")
    /// `--fixtures kidsfail`: the kids page build fails after a beat and no cached page is shown
    /// (KidsModel.load), for its Try again (NavigationTests3).
    static let failKids: Bool = scenario("kidsfail")
    /// `--fixtures detail`: series titles carry one season of six episodes, and DetailModel takes
    /// that list as the full meta instead of asking Cinemeta for an id it has never heard of
    /// (NavigationTests3). Every other scenario keeps its titles without videos.
    static let withEpisodes: Bool = scenario("detail")
    /// `--fixtures discfail`: every Discover build fails after a beat (DiscoverModel.load), for its
    /// failure card's Try again (NavigationTests4).
    static let failDiscover: Bool = scenario("discfail")
    /// `--fixtures bands`: Home also carries bp-home's band rows (Your streaming, Your addons,
    /// Collections), for their row leads (NavigationTests4). Every other scenario's Home is unchanged.
    static let withBands: Bool = scenario("bands")

    /// The launch named this fixture scenario (`--fixtures <name>`), and only then.
    private static func scenario(_ name: String) -> Bool {
        let args: [String] = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "--fixtures"), i + 1 < args.count else { return false }
        return args[i + 1] == name
    }

    /// Three tiles per band row, shaped as EngineBrowseSource builds them (service:, addon: and
    /// collection:tmdb: ids), placed after the first two catalog rows as bp-home slots them.
    static func bandRows() -> [BrowseRow] {
        let names: [String] = ["Harbor One", "Harbor Two", "Harbor Three"]
        let tints: [String] = ["#e50914", "#0063e5", "#1ce783"]
        func brand(_ prefix: String, _ type: String, _ i: Int) -> Meta {
            Meta(id: "\(prefix)fixture-\(i)", type: type, name: names[i], poster: nil, background: nil, logo: nil, description: nil, releaseInfo: nil, releaseDate: nil,
                 inTheaters: nil, imdbRating: nil, tmdbScore: nil, runtime: nil, genres: nil, adult: nil, isCollection: nil,
                 providerBadge: Meta.ProviderBadge(name: names[i], logo: "", tint: tints[i]), videos: nil)
        }
        let indices: [Int] = [0, 1, 2]
        let services: [Meta] = indices.map { brand("service:", "service", $0) }
        let addons: [Meta] = indices.map { brand("addon:https://addon.invalid/", "addon", $0) }
        let collections: [Meta] = indices.map { i -> Meta in
            Meta(id: "collection:tmdb:\(900 + i)", type: "collection", name: "\(names[i]) Collection", poster: nil, background: nil, logo: nil,
                 description: "3 films", releaseInfo: nil, releaseDate: nil, inTheaters: nil,
                 imdbRating: nil, tmdbScore: nil, runtime: nil, genres: nil, adult: nil, isCollection: true, providerBadge: nil, videos: nil)
        }
        return [BrowseRow(key: "services", title: "Your streaming", metas: services, shape: .brand),
                BrowseRow(key: "addons", title: "Your addons", metas: addons, shape: .brand),
                BrowseRow(key: "collections", title: "Collections", metas: collections, shape: .collection)]
    }

    /// One season of six episodes for a fixture series (Cinemeta's `videos` shape).
    static func fixtureVideos(_ id: String) -> [AnyJSON] {
        let numbers: [Int] = [1, 2, 3, 4, 5, 6]
        return numbers.map { n -> AnyJSON in
            let fields: [String: AnyJSON] = [
                "id": .string("\(id):1:\(n)"), "season": .number(1), "episode": .number(Double(n)),
                "name": .string("Episode \(n)"), "released": .string("2024-01-0\(n)T00:00:00.000Z"),
            ]
            return AnyJSON.object(fields)
        }
    }

    func rows(for room: Room) async throws -> [BrowseRow] {
        if Self.failRooms {
            try await Task.sleep(for: .seconds(2))
            throw URLError(.notConnectedToInternet)
        }
        let titles = ["Dune: Part Two", "Oppenheimer", "The Bear", "Severance", "Poor Things", "Shōgun", "Past Lives", "Fallout", "The Holdovers", "Anatomy of a Fall", "Civil War", "Ripley"]
        func metas(_ prefix: String, _ type: String) -> [Meta] {
            titles.enumerated().map { i, t -> Meta in
                let episodes: Bool = Self.withEpisodes && type == "series"
                let videos: [AnyJSON]? = episodes ? Self.fixtureVideos("\(prefix)-\(i)") : nil
                return Meta(id: "\(prefix)-\(i)", type: type, name: t, poster: nil, background: nil, logo: nil,
                     description: "A placeholder synopsis for \(t), long enough to wrap onto a second line so the two-line clamp in the spotlight can be checked.",
                     releaseInfo: "202\(i % 5)", releaseDate: nil, inTheaters: nil, imdbRating: "8.\(i % 10)", tmdbScore: 7.0 + Double(i % 3),
                     runtime: "1h \(40 + i)m", genres: ["Drama", "Thriller"], adult: nil, isCollection: nil, providerBadge: nil, videos: videos)
            }
        }
        switch room {
        case .movies:
            return [BrowseRow(key: "bp-top10", title: "Top 10 Movies Today", metas: Array(metas("m", "movie").prefix(10)), shape: .rank),
                    BrowseRow(key: "trending", title: "Trending This Week", metas: metas("t", "movie")),
                    BrowseRow(key: "theaters", title: "In Theaters Now", metas: metas("n", "movie"))]
        case .shows:
            return [BrowseRow(key: "bp-top10", title: "Top 10 Series Today", metas: Array(metas("s", "series").prefix(10)), shape: .rank),
                    BrowseRow(key: "trending", title: "Trending This Week", metas: metas("ts", "series")),
                    BrowseRow(key: "hbo", title: "From HBO", metas: metas("h", "series"))]
        default:
            var rows: [BrowseRow] = [BrowseRow(key: "trending", title: "Trending This Week", metas: metas("t", "movie")),
                                     BrowseRow(key: "theaters", title: "In Theaters Now", metas: metas("n", "movie")),
                                     BrowseRow(key: "popular", title: "Popular Movies", metas: metas("p", "movie")),
                                     BrowseRow(key: "series", title: "Trending Series", metas: metas("s", "series"))]
            if Self.withBands && room == .home { rows.insert(contentsOf: Self.bandRows(), at: 2) }
            return rows
        }
    }

    func continueWatching(for room: Room) async throws -> [ContinueItem] {
        [ContinueItem(id: "cw1", type: "series", name: "Severance", poster: nil, background: nil, logo: nil, season: 2, episode: 4, progress: 0.42, lastWatched: Date()),
         ContinueItem(id: "cw2", type: "movie", name: "Dune: Part Two", poster: nil, background: nil, logo: nil, season: nil, episode: nil, progress: 0.7, lastWatched: Date())]
    }
}
