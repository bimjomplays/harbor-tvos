import Foundation
import Combine
import SwiftUI

/// Where a room gets its rows. The engine (upstream logic in JavaScriptCore) implements this;
/// `FixtureBrowseSource` feeds simulator screenshots without the network.
protocol BrowseSource {
    func rows(for room: Room) async throws -> [BrowseRow]
    func continueWatching() async throws -> [ContinueItem]
}

@MainActor
final class BrowseModel: ObservableObject {
    @Published private(set) var rows: [BrowseRow] = []
    @Published private(set) var continueWatching: [ContinueItem] = []
    @Published private(set) var loading = false
    @Published private(set) var failed: String?
    @Published var spotlight: Meta?

    let room: Room
    private let source: BrowseSource
    private var heroTask: Task<Void, Never>?
    private var cardFocused = false
    private var heroIndex = 0

    init(room: Room, source: BrowseSource) {
        self.room = room
        self.source = source
    }

    private var cacheKey: String { "bp.room.\(room.rawValue).\(ProfilesStore.shared.activeId ?? "none")" }
    /// Fixture rows never touch the cache, so a screenshot run cannot poison a live one.
    private var cacheable: Bool { !(source is FixtureBrowseSource) }

    func load() async {
        guard !loading else { return }
        loading = true; failed = nil
        // Last session's shelves first (bp-home-cache): a TV kills the process between
        // sessions and nobody should watch an empty screen while the live build runs.
        if cacheable, rows.isEmpty, let cached = CacheStore.shared.get([BrowseRow].self, for: cacheKey), !cached.isEmpty {
            rows = cached
            if spotlight == nil { spotlight = cached.first?.metas.first }
        }
        do {
            async let r = source.rows(for: room)
            async let cw = source.continueWatching()
            let live = try await r
            rows = live
            if cacheable { try? CacheStore.shared.set(live, for: cacheKey) }
            continueWatching = room == .anime ? [] : ((try? await cw) ?? [])
            // A stale spotlight (from the cache, or a title that fell off the rows) resets.
            let known = Set(live.flatMap { $0.metas.map(\.id) })
            if !cardFocused, spotlight.map({ !known.contains($0.id) }) ?? true { spotlight = live.first?.metas.first }
            startHeroCycle()
        } catch {
            if rows.isEmpty { failed = error.localizedDescription }
        }
        loading = false
    }

    func focus(_ meta: Meta) {
        cardFocused = true
        spotlight = meta
    }

    /// use-bp-hero-cycle.ts: every 7 s advance through the first row's first 8 items,
    /// unless a card holds focus.
    private func startHeroCycle() {
        heroTask?.cancel()
        let pool = Array((rows.first?.metas ?? []).prefix(8))
        guard pool.count > 1 else { return }
        heroTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(7))
                guard let self, !self.cardFocused else { continue }
                self.heroIndex = (self.heroIndex + 1) % pool.count
                self.spotlight = pool[self.heroIndex]
            }
        }
    }
}

/// Deterministic fake rows for the simulator.
struct FixtureBrowseSource: BrowseSource {
    func rows(for room: Room) async throws -> [BrowseRow] {
        let titles = ["Dune: Part Two", "Oppenheimer", "The Bear", "Severance", "Poor Things", "Shōgun", "Past Lives", "Fallout", "The Holdovers", "Anatomy of a Fall", "Civil War", "Ripley"]
        func metas(_ prefix: String, _ type: String) -> [Meta] {
            titles.enumerated().map { i, t in
                Meta(id: "\(prefix)-\(i)", type: type, name: t, poster: nil, background: nil, logo: nil,
                     description: "A placeholder synopsis for \(t), long enough to wrap onto a second line so the two-line clamp in the spotlight can be checked.",
                     releaseInfo: "202\(i % 5)", releaseDate: nil, inTheaters: nil, imdbRating: "8.\(i % 10)", tmdbScore: 7.0 + Double(i % 3),
                     runtime: "1h \(40 + i)m", genres: ["Drama", "Thriller"], adult: nil, isCollection: nil, providerBadge: nil, videos: nil)
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
            return [BrowseRow(key: "trending", title: "Trending This Week", metas: metas("t", "movie")),
                    BrowseRow(key: "theaters", title: "In Theaters Now", metas: metas("n", "movie")),
                    BrowseRow(key: "popular", title: "Popular Movies", metas: metas("p", "movie")),
                    BrowseRow(key: "series", title: "Trending Series", metas: metas("s", "series"))]
        }
    }

    func continueWatching() async throws -> [ContinueItem] {
        [ContinueItem(id: "cw1", type: "series", name: "Severance", poster: nil, background: nil, logo: nil, season: 2, episode: 4, progress: 0.42, lastWatched: Date()),
         ContinueItem(id: "cw2", type: "movie", name: "Dune: Part Two", poster: nil, background: nil, logo: nil, season: nil, episode: nil, progress: 0.7, lastWatched: Date())]
    }
}
