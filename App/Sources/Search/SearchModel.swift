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
        var query: String
        var topMatch: TopMatch?
        var people: [Person]?
        var movies: [Meta]
        var series: [Meta]
        var anime: [AnimeHit]?
    }

    @Published var query = "" { didSet { schedule() } }
    @Published private(set) var status: Status = .idle
    @Published private(set) var rows: [BrowseRow] = []
    @Published private(set) var topMatch: Meta?
    @Published private(set) var people: [Results.Person] = []

    enum Status: Equatable { case idle, typing, loading, done, failed(String) }

    private var timer: Task<Void, Never>?
    private var requestId = 0

    private func schedule() {
        timer?.cancel()
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { status = .idle; rows = []; topMatch = nil; return }
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
            let key = SettingsBridge.shared.slice.tmdbKey
            let results: Results
            if !key.isEmpty {
                results = try await HarborEngine.shared.call("search.all", [key, q])
            } else {
                // No TMDB key: Cinemeta + installed addon catalogs (engine, no key needed).
                struct Pair: Decodable { var movies: [Meta]; var series: [Meta] }
                let c: Pair = try await HarborEngine.shared.call("search.cinemeta", [q])
                results = Results(query: q, topMatch: nil, people: nil, movies: c.movies, series: c.series, anime: nil)
            }
            guard mine == requestId else { return }
            var out: [BrowseRow] = []
            if !results.movies.isEmpty { out.append(BrowseRow(key: "movies", title: "Movies", metas: results.movies)) }
            if !results.series.isEmpty { out.append(BrowseRow(key: "series", title: "Series", metas: results.series)) }
            if let anime = results.anime, !anime.isEmpty {
                let metas = anime.map { Meta(id: $0.kitsuId.map { "kitsu:\($0)" } ?? "mal:\($0.malId ?? 0)", type: "anime", name: $0.name, poster: $0.poster, background: $0.background, logo: nil, description: $0.overview, releaseInfo: $0.year, releaseDate: nil, inTheaters: nil, imdbRating: nil, tmdbScore: nil, runtime: nil, genres: nil, adult: nil, isCollection: nil, providerBadge: nil, videos: nil) }
                out.append(BrowseRow(key: "anime", title: "Anime", metas: metas))
            }
            rows = out
            await CardMarksStore.shared.refresh(out.flatMap(\.metas))
            people = results.people ?? []
            topMatch = results.topMatch?.meta ?? results.movies.first ?? results.series.first
            status = .done
        } catch {
            guard mine == requestId else { return }
            status = .failed(error.localizedDescription)
        }
    }
}
