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
        struct AddonGroup: Decodable, Identifiable { var id: String; var name: String; var logo: String?; var metas: [Meta]; var state: String? }
        struct CharacterRef: Decodable { var anilistId: Int; var malId: Int?; var type: String; var name: String; var poster: String?; var background: String?; var year: String?; var overview: String?; var score: Double? }
        struct Character: Decodable, Identifiable { var id: Int; var name: String; var image: String?; var anime: [CharacterRef] }
        struct AddonHit: Decodable, Identifiable { var id: String; var name: String; var logo: String?; var transportUrl: String?; var blurb: String?; var installed: Bool }
        var query: String
        var topMatch: TopMatch?
        var people: [Person]?
        var movies: [Meta]
        var series: [Meta]
        var anime: [AnimeHit]?
        var liveTv: [LiveTvHit]?
        var addonGroups: [AddonGroup]?
        var addonQueries: [AddonGroup]?
        var characters: [Character]?
        var addons: [AddonHit]?
        var requestId: Int?
    }

    @Published var query = "" { didSet { schedule() } }
    @Published private(set) var status: Status = .idle
    @Published private(set) var rows: [BrowseRow] = []
    @Published private(set) var channels: [Results.LiveTvHit] = []
    @Published private(set) var topMatch: Meta?
    @Published private(set) var people: [Results.Person] = []
    @Published private(set) var addonHits: [Results.AddonHit] = []
    /// search-context RECENT_KEY: the last eight queries that found something.
    @Published private(set) var recent: [String] = Prefs.get([String].self, for: "harbor.search.recent") ?? []
    /// bp-search idle "Suggested": posters from the hero feed while the field is empty.
    @Published private(set) var suggestions: [Meta] = []

    func loadSuggestions() async {
        guard suggestions.isEmpty else { return }
        let metas: [Meta] = (try? await HarborEngine.shared.call("feed.hero", ["trending"])) ?? []
        var seen: Set<String> = []
        suggestions = metas.filter { $0.poster != nil && seen.insert($0.id).inserted }.prefix(60).map { $0 }
        await CardMarksStore.shared.refresh(suggestions)
    }

    private func noteRecent(_ q: String) {
        var list = recent.filter { $0.caseInsensitiveCompare(q) != .orderedSame }
        list.insert(q, at: 0)
        recent = Array(list.prefix(8))
        try? Prefs.set(recent, for: "harbor.search.recent")
    }

    func clearRecent() { recent = []; try? Prefs.set([String](), for: "harbor.search.recent") }
    private var engineRequestId = 0
    private var unsubscribe: (() -> Void)?

    init() {
        // Slow addons answer after the fan-out returned; each answer replaces its own row in place.
        unsubscribe = HarborEngine.shared.onEvent { [weak self] type, detail in
            guard type == "harbor:search-addon-group", let self, let detail,
                  Int(detail["requestId"]?.number ?? -1) == self.engineRequestId,
                  let group = try? detail["group"]?.decode(Results.AddonGroup.self) else { return }
            self.upsert(group)
        }
    }
    deinit { unsubscribe?() }

    private func upsert(_ g: Results.AddonGroup) {
        let key = "addon:\(g.id)"
        var out = rows.filter { $0.key != key }
        if !g.metas.isEmpty {
            let row = BrowseRow(key: key, title: "From \(g.name)", metas: g.metas)
            if let at = out.firstIndex(where: { $0.key.hasPrefix("addon:") }) { out.insert(row, at: at) } else { out.append(row) }
        }
        rows = out
        Task { await CardMarksStore.shared.refresh(g.metas) }
    }

    enum Status: Equatable { case idle, typing, loading, done, failed(String) }

    private var timer: Task<Void, Never>?
    private var requestId = 0

    private func schedule() {
        timer?.cancel()
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { status = .idle; rows = []; channels = []; topMatch = nil; addonHits = []; engineRequestId = 0; return }
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
            var out: [BrowseRow] = []
            if !results.movies.isEmpty { out.append(BrowseRow(key: "movies", title: "Movies", metas: results.movies)) }
            if !results.series.isEmpty { out.append(BrowseRow(key: "series", title: "Series", metas: results.series)) }
            if let anime = results.anime, !anime.isEmpty {
                let metas = anime.map { Meta(id: $0.kitsuId.map { "kitsu:\($0)" } ?? "mal:\($0.malId ?? 0)", type: "anime", name: $0.name, poster: $0.poster, background: $0.background, logo: nil, description: $0.overview, releaseInfo: $0.year, releaseDate: nil, inTheaters: nil, imdbRating: nil, tmdbScore: nil, runtime: nil, genres: nil, adult: nil, isCollection: nil, providerBadge: nil, videos: nil) }
                out.append(BrowseRow(key: "anime", title: "Anime", metas: metas))
            }
            // use-bp-search: one franchise row per character hit (AniList), its titles as anime metas.
            for c in results.characters ?? [] where !c.anime.isEmpty {
                let metas = c.anime.map { r in Meta(id: "anilist:\(r.anilistId)", type: r.type == "manga" ? "manga" : "anime", name: r.name, poster: r.poster, background: r.background ?? r.poster, logo: nil, description: r.overview, releaseInfo: r.year, releaseDate: nil, inTheaters: nil, imdbRating: (r.score ?? 0) > 0 ? String(format: "%.1f", r.score ?? 0) : nil, tmdbScore: nil, runtime: nil, genres: nil, adult: nil, isCollection: nil, providerBadge: nil, videos: nil) }
                out.append(BrowseRow(key: "character:\(c.id)", title: c.name, metas: metas))
            }
            // bp-search-rows: one row per addon that answered ("From <addon>"), after the catalogs.
            // addonQueries keeps every slot's own hits (never stripped against the fused rows).
            for g in results.addonQueries ?? results.addonGroups ?? [] where !g.metas.isEmpty {
                out.append(BrowseRow(key: "addon:\(g.id)", title: "From \(g.name)", metas: g.metas))
            }
            addonHits = results.addons ?? []
            rows = out
            channels = results.liveTv ?? []
            await CardMarksStore.shared.refresh(out.flatMap(\.metas))
            people = results.people ?? []
            topMatch = results.topMatch?.meta ?? results.movies.first ?? results.series.first
            status = .done
            if !out.isEmpty || !(results.liveTv ?? []).isEmpty || !(results.people ?? []).isEmpty { noteRecent(q) }
        } catch {
            guard mine == requestId else { return }
            status = .failed(error.localizedDescription)
        }
    }
}
