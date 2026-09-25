import Foundation
import Combine

/// The Search room's data: 180 ms debounce, then upstream's search fan-out through the engine,
/// grouped into rows in the Big Picture order (use-bp-search.ts buildBpSearchSlots).
@MainActor
final class SearchModel: ObservableObject {
    struct Results: Decodable {
        struct TopMatch: Decodable { var kind: String; var meta: Meta; var overview: String?; var backdrop: String? }
        struct Person: Decodable, Identifiable {
            var tmdbId: Int?
            var name: String
            var profile: String?
            var knownFor: String?
            var id: String { "\(tmdbId ?? 0)-\(name)" }
            private enum CodingKeys: String, CodingKey { case tmdbId = "id", name, profile, knownFor }
        }
        struct AnimeHit: Decodable { var name: String; var poster: String?; var background: String?; var malId: Int?; var kitsuId: Int?; var year: String?; var overview: String? }
        struct LiveTvHit: Decodable, Identifiable { var channelId: String; var name: String; var logo: String?; var url: String; var group: String?; var playlistId: String; var playlistName: String; var id: String { channelId } }
        struct AddonGroup: Decodable, Identifiable { var id: String; var name: String; var logo: String?; @LossyArray var metas: [Meta]; var state: String? }   // (bug pass 2) lossy
        struct CharacterRef: Decodable { var anilistId: Int; var malId: Int?; var type: String; var name: String; var poster: String?; var background: String?; var year: String?; var overview: String?; var score: Double? }
        struct Character: Decodable, Identifiable { var id: Int; var name: String; var image: String?; var anime: [CharacterRef]; var manga: [CharacterRef]? }
        struct AddonHit: Decodable, Identifiable { var id: String; var name: String; var logo: String?; var transportUrl: String?; var blurb: String?; var installed: Bool }
        /// tvdb-collections TvdbCollectionHit (use-collection-hits).
        struct CollectionHit: Decodable, Identifiable { var id: Int; var name: String; var image: String?; var overview: String? }
        var query: String
        var topMatch: TopMatch?
        var people: [Person]?
        @LossyArray var movies: [Meta]
        @LossyArray var series: [Meta]
        var anime: [AnimeHit]?
        var liveTv: [LiveTvHit]?
        var addonGroups: [AddonGroup]?
        var addonQueries: [AddonGroup]?
        var characters: [Character]?
        /// search-context manga (SR-9): the active manga source's hits, only while the reader is on.
        var manga: [MangaSummary]?
        var addons: [AddonHit]?
        var collections: [CollectionHit]?
        var requestId: Int?
    }

    @Published var query = "" { didSet { schedule() } }
    @Published private(set) var status: Status = .idle
    @Published private(set) var rows: [BrowseRow] = []
    @Published private(set) var channels: [Results.LiveTvHit] = []
    @Published private(set) var topMatch: Meta?
    @Published private(set) var people: [Results.Person] = []
    @Published private(set) var addonHits: [Results.AddonHit] = []
    @Published private(set) var collections: [Results.CollectionHit] = []
    /// Addon slots announced "pending" that have not answered yet (use-bp-search addonsPending).
    @Published private(set) var addonsPending: Set<String> = []

    // MARK: kind chips (use-bp-search.ts BpSearchFilter, GROUP_ORDER, GROUP_LABEL)

    /// use-bp-search BpSearchFilter minus "top" (never a chip), in GROUP_ORDER. "manga" only ever
    /// counts while settings.mangaEnabled is on (the engine asks no manga source otherwise).
    enum Filter: String, CaseIterable, Identifiable {
        case all, movie, series, people, anime, manga, livetv, collections, characters, addons
        var id: String { rawValue }
        var label: String {
            switch self {
            case .all: return "All"
            case .movie: return "Movies"
            case .series: return "Series"
            case .people: return "People"
            case .anime: return "Anime"
            case .manga: return "Manga"
            case .livetv: return "Live TV"
            case .collections: return "Collections"
            case .characters: return "Franchise"
            case .addons: return "Addons"
            }
        }
    }
    struct Chip: Identifiable { var filter: Filter; var count: Int; var id: String { filter.rawValue } }

    /// bp-search: the chosen chip belongs to one query; a new query starts back on All.
    @Published var filter: Filter = .all
    /// use-bp-search QueryLatch.groups: a chip is never withdrawn mid-query.
    private var latched: Set<Filter> = []
    private var latchedQuery = ""

    /// Which chip a result row belongs to (use-bp-search buildBpSearchSlots `group`).
    static func group(ofRow key: String) -> Filter {
        if key == "movies" { return .movie }
        if key == "series" { return .series }
        if key == "anime" { return .anime }
        if key == "manga" { return .manga }
        if key.hasPrefix("character:") { return .characters }
        return .addons
    }

    func shows(_ group: Filter) -> Bool { filter == .all || filter == group }

    /// use-bp-search counts: bpSectionCount summed per group ("top" excluded).
    func count(_ group: Filter) -> Int {
        switch group {
        case .all: return distinctCount(nil)
        case .people: return people.count
        case .livetv: return channels.count
        case .collections: return collections.count
        case .addons: return addonHits.count + rows.filter { Self.group(ofRow: $0.key) == .addons }.reduce(0) { $0 + $1.metas.count }
        default: return rows.filter { Self.group(ofRow: $0.key) == group }.reduce(0) { $0 + $1.metas.count }
        }
    }

    /// use-bp-search bpDistinctCount: distinct things found, not cells drawn. Title rows count
    /// each meta id once across rows; every other kind counts its length. nil = every group.
    func distinctCount(_ only: Filter?) -> Int {
        var seen: Set<String> = []
        var n = 0
        let keep: (Filter) -> Bool = { g in only == nil || only == g }
        if keep(.people) { n += people.count }
        if keep(.livetv) { n += channels.count }
        if keep(.collections) { n += collections.count }
        if keep(.addons) { n += addonHits.count }
        for row in rows where keep(Self.group(ofRow: row.key)) {
            if row.key == "anime" || row.key == "manga" { n += row.metas.count; continue }
            for m in row.metas where seen.insert(m.id).inserted { n += 1 }
        }
        return n
    }

    /// use-bp-search chips: none until something counted; then All plus every group that has
    /// counted anything this query (or is the active one), in GROUP_ORDER.
    var chips: [Chip] {
        guard status != .idle, !latched.isEmpty else { return [] }
        var out = [Chip(filter: .all, count: distinctCount(nil))]
        for g in Filter.allCases where g != .all && (latched.contains(g) || g == filter) {
            out.append(Chip(filter: g, count: count(g)))
        }
        return out
    }

    /// Settled: the fixed sources returned and no addon slot is still pending.
    var settled: Bool { status == .done && addonsPending.isEmpty }
    var busy: Bool { status == .typing || status == .loading || (status == .done && !addonsPending.isEmpty) }
    /// use-bp-search filterStale: a chip that outlived its results.
    var filterStale: Bool { settled && filter != .all && count(filter) == 0 }

    private func latchGroups() {
        for g in Filter.allCases where g != .all && count(g) > 0 { latched.insert(g) }
    }
    /// search-context RECENT_KEY: the last eight queries that found something.
    @Published private(set) var recent: [String] = Prefs.get([String].self, for: "harbor.search.recent") ?? []
    /// bp-search idle "Suggested": posters from the hero feed while the field is empty.
    @Published private(set) var suggestions: [Meta] = []
    /// The Suggested read has answered: an empty field with nothing to suggest says so (bp-search showEmpty).
    @Published private(set) var suggestionsLoaded = false

    func loadSuggestions() async {
        guard suggestions.isEmpty else { return }
        defer { suggestionsLoaded = true }
        // bp-search: the first 60 unique posters across the Home rows, in row order.
        struct Build: Decodable { struct Row: Decodable { @LossyArray var metas: [Meta] }; @LossyArray var rows: [Row] }
        let p = ProfilesStore.shared.active
        let authKey = p.flatMap { ProfilesStore.shared.stremioSession(for: $0.id)?.authKey }
        var metas: [Meta] = []
        if let b: Build = try? await HarborEngine.shared.call("rooms.homeFor", [p?.id ?? "default", p?.linked ?? true, authKey]) { metas = b.rows.flatMap(\.metas) }
        if metas.isEmpty { metas = (try? await HarborEngine.shared.call("feed.hero", ["trending"])) ?? [] }
        var seen: Set<String> = []
        suggestions = metas.filter { $0.poster != nil && seen.insert($0.id).inserted }.prefix(60).map { $0 }
        await CardMarksStore.shared.refresh(suggestions)
    }

    /// search-context recordRecent: only when the viewer commits (opens a result), never mid-typing;
    /// magnets and direct video links are never kept.
    func commitRecent() {
        let q = query.trimmingCharacters(in: .whitespaces)
        // isMagnetInput / isDirectVideoUrl: magnets, bare infohashes and links never become recents.
        guard q.count >= 2, !q.lowercased().hasPrefix("magnet:"), q.range(of: #"^https?://"#, options: [.regularExpression, .caseInsensitive]) == nil,
              q.range(of: #"^([0-9a-fA-F]{40}|[A-Za-z2-7]{32})$"#, options: .regularExpression) == nil else { return }
        noteRecent(q)
    }

    private func noteRecent(_ q: String) {
        var list = recent.filter { $0.caseInsensitiveCompare(q) != .orderedSame }
        list.insert(q, at: 0)
        recent = Array(list.prefix(8))
        try? Prefs.set(recent, for: "harbor.search.recent")
    }

    func clearRecent() { recent = []; try? Prefs.set([String](), for: "harbor.search.recent") }

    /// After an install from "Addons you could install", the hit shows its tick straight away.
    func markInstalled(_ id: String) {
        for i in addonHits.indices where addonHits[i].id == id { addonHits[i].installed = true }
    }
    private var engineRequestId = 0
    private var unsubscribe: (() -> Void)?
    /// Addon answers that crossed before this side learned the request id they belong to.
    private var early: [(Int, Results.AddonGroup)] = []

    init() {
        // Slow addons answer after the fan-out returned; each answer replaces its own row in place.
        unsubscribe = HarborEngine.shared.onEvent { [weak self] type, detail in
            guard type == "harbor:search-addon-group", let self, let detail,
                  let group = try? detail["group"]?.decode(Results.AddonGroup.self) else { return }
            let rid = Int(detail["requestId"]?.number ?? -1)
            if rid == self.engineRequestId { self.upsert(group) }
            else if rid > self.engineRequestId, self.status == .loading { self.early = Array((self.early + [(rid, group)]).suffix(64)) }
        }
    }
    deinit { unsubscribe?() }

    private func upsert(_ g: Results.AddonGroup) {
        let key = "addon:\(g.id)"
        var out = rows.filter { $0.key != key }
        if !g.metas.isEmpty {
            let row = BrowseRow(key: key, title: T("From %@", g.name), metas: g.metas)
            if let at = out.firstIndex(where: { $0.key.hasPrefix("addon:") }) { out.insert(row, at: at) } else { out.append(row) }
        }
        rows = out
        addonsPending.remove(g.id)
        latchGroups()
        Task { await CardMarksStore.shared.refresh(g.metas) }
    }

    enum Status: Equatable { case idle, typing, loading, done, failed(String) }

    private var timer: Task<Void, Never>?
    private var requestId = 0

    private func schedule() {
        timer?.cancel()
        // (bug pass) Any edit retires the run in flight: it re-checks this after each await, so a
        // cleared field (or a newer query) never gets the old query's people / top match / status.
        requestId += 1
        let q = query.trimmingCharacters(in: .whitespaces)
        // search-display-state getSearchDisplayState: results only ever show under the query that
        // asked for them. The last query's rows, people and top match stayed up (and could be
        // opened, filing the new query as a recent) until the new fan-out answered, or for good
        // when it failed.
        if q != latchedQuery {
            latchedQuery = q; latched = []; filter = .all; engineRequestId = 0; addonsPending = []
            rows = []; channels = []; topMatch = nil; addonHits = []; collections = []; people = []; early = []
        }
        guard !q.isEmpty else { status = .idle; rows = []; channels = []; topMatch = nil; addonHits = []; collections = []; addonsPending = []; people = []; early = []; engineRequestId = 0; return }
        status = .typing
        timer = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            await self?.run(q)
        }
    }

    private func run(_ q: String) async {
        requestId += 1
        let mine = requestId
        status = .loading
        do {
            // search-context.tsx fan-out in the engine: TMDB (when keyed), anime, addon catalogs fused
            // into Movies/Series, Cinemeta, Live TV channels, franchise characters, addon index.
            let p = ProfilesStore.shared.active
            let authKey = p.flatMap { ProfilesStore.shared.stremioSession(for: $0.id)?.authKey }
            let results: Results = try await HarborEngine.shared.call("search.fanOut", [q, p?.id ?? "default", p?.linked ?? true, authKey])
            guard mine == requestId else { return }
            engineRequestId = results.requestId ?? 0
            addonsPending = Set((results.addonQueries ?? []).filter { $0.state == "pending" }.map(\.id))
            var out: [BrowseRow] = []
            if !results.movies.isEmpty { out.append(BrowseRow(key: "movies", title: T("Movies"), metas: results.movies)) }
            if !results.series.isEmpty { out.append(BrowseRow(key: "series", title: T("Series"), metas: results.series)) }
            if let anime = results.anime, !anime.isEmpty {
                let metas = anime.map { Meta(id: $0.kitsuId.map { "kitsu:\($0)" } ?? "mal:\($0.malId ?? 0)", type: "anime", name: $0.name, poster: $0.poster, background: $0.background, logo: nil, description: $0.overview, releaseInfo: $0.year, releaseDate: nil, inTheaters: nil, imdbRating: nil, tmdbScore: nil, runtime: nil, genres: nil, adult: nil, isCollection: nil, providerBadge: nil, videos: nil) }
                out.append(BrowseRow(key: "anime", title: T("Anime"), metas: metas))
            }
            // use-bp-search slot "manga" (bp-search-rows BpMangaCell): after Anime, before Live TV.
            if let manga = results.manga, !manga.isEmpty {
                // Covers sit on the viewer's own server: its image auth must be known first.
                if MangaStore.shared.state == nil { await MangaStore.shared.refresh() }
                guard mine == requestId else { return }
                out.append(BrowseRow(key: "manga", title: T("Manga"), metas: manga.map(\.meta)))
            }
            // use-bp-search: one franchise row per character hit (AniList), its titles as anime metas.
            for c in results.characters ?? [] where !(c.anime + (c.manga ?? [])).isEmpty {
                let metas = (c.anime + (c.manga ?? [])).map { r in Meta(id: "anilist:\(r.anilistId)", type: r.type == "manga" ? "manga" : "anime", name: r.name, poster: r.poster, background: r.background ?? r.poster, logo: nil, description: r.overview, releaseInfo: r.year, releaseDate: nil, inTheaters: nil, imdbRating: (r.score ?? 0) > 0 ? String(format: "%.1f", r.score ?? 0) : nil, tmdbScore: nil, runtime: nil, genres: nil, adult: nil, isCollection: nil, providerBadge: nil, videos: nil) }
                out.append(BrowseRow(key: "character:\(c.id)", title: c.name, metas: metas))
            }
            // bp-search-rows: one row per addon that answered ("From <addon>"), after the catalogs.
            // addonQueries keeps every slot's own hits (never stripped against the fused rows).
            for g in results.addonQueries ?? results.addonGroups ?? [] where !g.metas.isEmpty {
                out.append(BrowseRow(key: "addon:\(g.id)", title: T("From %@", g.name), metas: g.metas))
            }
            addonHits = results.addons ?? []
            collections = results.collections ?? []
            rows = out
            channels = results.liveTv ?? []
            // With the rows, not after the marks read: People and Top match landing a beat later
            // pushed rows already on screen down under the ring (use-bp-search latch.decided).
            people = results.people ?? []
            topMatch = results.topMatch?.meta ?? results.movies.first ?? results.series.first
            await CardMarksStore.shared.refresh(out.filter { $0.key != "manga" }.flatMap(\.metas))
            guard mine == requestId else { return }
            status = .done
            latchGroups()
            let late = early.filter { $0.0 == engineRequestId }.map { $0.1 }
            early = []
            for g in late { upsert(g) }
        } catch {
            guard mine == requestId else { return }
            status = .failed(error.localizedDescription)
        }
    }
}
