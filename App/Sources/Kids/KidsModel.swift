import Foundation
import Combine

/// views/kids.tsx state without React: the hero pool, the kids rows (engine/kids.ts builds them
/// through upstream's kids-specs, kids-filter and page-rows), paging, and the franchise rail.
@MainActor
final class KidsModel: ObservableObject {
    struct Row: Codable, Identifiable, Equatable {
        var key: String
        var title: String
        @LossyArray var metas: [Meta]   // (bug pass 2) lossy
        var hasMore: Bool
        var id: String { key }
    }

    struct Page: Codable {
        var hasTmdb: Bool
        @LossyArray var hero: [Meta]
        @LossyArray var rows: [Row]
        var failed: Bool
    }

    /// kids-franchise-rail.tsx tile: name, gradient stops (hex), cta art, how far the art drops.
    struct Franchise: Decodable, Identifiable, Hashable {
        var key: String
        var name: String
        var stops: [String]
        var drop: Double?
        var art: String
        var id: String { key }
    }

    /// kids-hero.tsx cards: five of the hero pool, shuffled once per build.
    @Published private(set) var heroCards: [Meta] = []
    @Published private(set) var rows: [Row] = []
    @Published private(set) var franchises: [Franchise] = []
    @Published private(set) var hasTmdb = true
    @Published private(set) var loading = false
    @Published private(set) var failed = false
    /// Logos the hero cards looked up (kids-hero.tsx KidsHeroCard lookup), keyed by meta id.
    @Published private(set) var logos: [String: String] = [:]

    private var paging: Set<String> = []
    private var heroIds: [String] = []

    private var profile: (id: String, linked: Bool) {
        let p = ProfilesStore.shared.active
        return (p?.id ?? "default", p?.linked ?? true)
    }

    private var cacheKey: String { "kids.page.\(profile.id)" }

    func load() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        let p = profile
        // Last session's shelves first, like the other rooms (bp-home-cache).
        if rows.isEmpty, let cached = CacheStore.shared.get(Page.self, for: cacheKey) {
            apply(cached)
        }
        do {
            let page: Page = try await HarborEngine.shared.call("kidsRoom.page", [p.id, p.linked])
            apply(page)
            if !page.failed { try? CacheStore.shared.set(page, for: cacheKey) }
            failed = page.failed && rows.isEmpty
        } catch {
            failed = rows.isEmpty
        }
        franchises = (try? await HarborEngine.shared.call("kidsRoom.franchises", [p.id, p.linked])) ?? []
        await CardMarksStore.shared.refresh(rows.flatMap(\.metas))
        await loadLogos()
    }

    private func apply(_ page: Page) {
        hasTmdb = page.hasTmdb
        rows = page.rows
        let pool = page.hero.filter { $0.background != nil || $0.poster != nil }
        let ids = pool.map(\.id)
        // KidsHero useMemo([featured]): reshuffle only when the pool itself changed.
        if ids != heroIds || heroCards.isEmpty {
            heroIds = ids
            heroCards = Array(pool.shuffled().prefix(5))
        }
    }

    private func loadLogos() async {
        let p = profile
        for m in heroCards where logos[m.id] == nil {
            if let url: String = try? await HarborEngine.shared.call("kidsRoom.logo", [m, p.id, p.linked]) {
                logos[m.id] = url
            }
        }
    }

    /// kids.tsx loadMore: one page at a time per row, merged by the engine (capped at 120).
    func loadMore(_ rowKey: String) async {
        guard let row = rows.first(where: { $0.key == rowKey }), row.hasMore, !paging.contains(rowKey) else { return }
        paging.insert(rowKey)
        defer { paging.remove(rowKey) }
        let p = profile
        guard let next: Row = try? await HarborEngine.shared.call("kidsRoom.loadMore", [p.id, p.linked, rowKey]),
              let idx = rows.firstIndex(where: { $0.key == rowKey }) else { return }
        rows[idx] = next
        await CardMarksStore.shared.refresh(next.metas)
    }
}

/// grid.tsx paging for a franchise opened from "Pick a World" (fetch until an empty page, cap 40).
@MainActor
final class KidsFranchiseModel: ObservableObject {
    @Published private(set) var metas: [Meta] = []
    @Published private(set) var done = false
    private var page = 0
    private var busy = false
    let franchise: KidsModel.Franchise

    init(franchise: KidsModel.Franchise) { self.franchise = franchise }

    func more() async {
        guard !busy, !done else { return }
        busy = true
        defer { busy = false }
        let p = ProfilesStore.shared.active
        let next = page + 1
        let batch: [Meta] = (try? await HarborEngine.shared.call("kidsRoom.franchisePage", [p?.id ?? "default", p?.linked ?? true, franchise.key, next])) ?? []
        page = next
        if batch.isEmpty || next >= 40 { done = true; return }
        let seen = Set(metas.map(\.id))
        let fresh = batch.filter { !seen.contains($0.id) }
        if fresh.isEmpty { done = true } else { metas += fresh }
    }
}
