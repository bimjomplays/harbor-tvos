import Foundation
import Combine
import SwiftUI
import UIKit

/// Where a room gets its rows. The engine (upstream logic in JavaScriptCore) implements this;
/// `FixtureBrowseSource` feeds simulator screenshots without the network.
protocol BrowseSource {
    func rows(for room: Room) async throws -> [BrowseRow]
    func continueWatching(for room: Room) async throws -> [ContinueItem]
    /// Distinct pages sharing a room kind (a streaming-service page) keep their own cache slot.
    var cacheId: String? { get }
}

extension BrowseSource {
    var cacheId: String? { nil }
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

    let room: Room
    private let source: BrowseSource
    private var heroTask: Task<Void, Never>?
    private var cardFocused = false
    private var heldRows: Set<String> = []

    private var unsubscribe: (() -> Void)?
    private var refreshTask: Task<Void, Never>?

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
        if room == .anime, !(source is FixtureBrowseSource) {
            // Jikan rows land one by one; re-read the page (from memory) after each burst.
            unsubscribe = HarborEngine.shared.onEvent { [weak self] type, _ in
                guard type == "harbor:anime-updated" else { return }
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

    private var cacheKey: String { "bp.room.\(restoreKey)" }
    /// The route key bp-restore remembers positions under (per page and profile).
    var restoreKey: String { "\(source.cacheId ?? room.rawValue).\(ProfilesStore.shared.activeId ?? "none")" }
    /// Fixture rows never touch the cache, so a screenshot run cannot poison a live one.
    private var cacheable: Bool { !(source is FixtureBrowseSource) }

    private var reloadPending = false

    func load() async {
        // A refresh asked for mid-load runs once this one finishes, so the last arrival is never lost.
        guard !loading else { reloadPending = true; return }
        loading = true; failed = nil
        // Last session's shelves first (bp-home-cache): a TV kills the process between
        // sessions and nobody should watch an empty screen while the live build runs.
        if cacheable, rows.isEmpty, let cached = CacheStore.shared.get([BrowseRow].self, for: cacheKey), !cached.isEmpty {
            rows = cached
            if spotlight == nil { spotlight = cached.first?.metas.first }
        }
        do {
            async let r = source.rows(for: room)
            async let cw = source.continueWatching(for: room)
            let live = try await r
            rows = live
            if cacheable { try? CacheStore.shared.set(live, for: cacheKey) }
            continueWatching = (try? await cw) ?? []
            // A row that left while holding focus never reports losing it.
            let keys = Set(live.map(\.key))
            let cwShown = !continueWatching.isEmpty
            heldRows = heldRows.filter { $0 == "cw" ? cwShown : keys.contains($0) }
            tileHeld = !heldRows.isEmpty
            // A stale spotlight (from the cache, or a title that fell off the rows) resets.
            let known = Set(live.flatMap { $0.metas.map(\.id) })
            if !cardFocused, spotlight.map({ !known.contains($0.id) }) ?? true { spotlight = live.first?.metas.first }
            startHeroCycle()
            await CardMarksStore.shared.refresh(live.flatMap(\.metas))
        } catch {
            if rows.isEmpty { failed = error.localizedDescription }
        }
        loading = false
        if reloadPending { reloadPending = false; await load() }
    }

    func focus(_ meta: Meta) {
        cardFocused = true
        spotlight = meta
    }

    /// A row (keyed) gained or lost the focused tile. The cycle reads this on every tick the way
    /// upstream's cardFocused() asks the document whether the ring sits on a [data-bp-tile].
    func hold(_ rowKey: String, _ held: Bool) {
        if held { heldRows.insert(rowKey) } else { heldRows.remove(rowKey) }
        if tileHeld != !heldRows.isEmpty { tileHeld = !heldRows.isEmpty }
    }

    /// use-bp-hero-cycle.ts: every 7 s (HOLD_MS) advance through the first row's first 8 items;
    /// a tick that finds a card focused just waits another hold. Never under Reduce Motion
    /// (`prefers-reduced-motion: reduce` returns before the first timer).
    private func startHeroCycle() {
        heroTask?.cancel()
        let pool = Array((rows.first?.metas ?? []).prefix(8))
        guard pool.count > 1, !UIAccessibility.isReduceMotionEnabled else {
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
                guard self.heldRows.isEmpty else { continue }
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

    func continueWatching(for room: Room) async throws -> [ContinueItem] {
        [ContinueItem(id: "cw1", type: "series", name: "Severance", poster: nil, background: nil, logo: nil, season: 2, episode: 4, progress: 0.42, lastWatched: Date()),
         ContinueItem(id: "cw2", type: "movie", name: "Dune: Part Two", poster: nil, background: nil, logo: nil, season: nil, episode: nil, progress: 0.7, lastWatched: Date())]
    }
}
