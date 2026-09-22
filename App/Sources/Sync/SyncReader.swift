import Foundation
import Combine

/// Read-only profile sync: pulls `/sync/v1/state`, keeps the docs, exposes the roster.
/// Pushing is deliberately absent until the write rules are ported (PLAN.md decision 6).
@MainActor
final class SyncReader: ObservableObject {
    /// Wire roster record (docs/harbor-protocol.md §4, `WireProfile`).
    struct WireProfile: Codable, Equatable, Identifiable {
        struct Kid: Codable, Equatable { var age: Int; var curfewMinutes: Int? }
        var syncId: String
        var name: String
        var avatar: String?
        var color: String
        var isPrimary: Bool
        var kid: Kid?
        var hideContent: AnyJSON?
        var lockedTabs: AnyJSON?
        var settingsLinked: Bool?
        var createdAt: Double
        var updatedAt: Double
        var deletedAt: Double?
        var id: String { syncId }
    }

    enum Phase: Equatable { case idle, pulling, failed(String) }

    static let shared = SyncReader()
    private static let cacheKey = "harbor.sync.state"

    @Published private(set) var state: HarborAPI.SyncState?
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var lastPull: Date?

    private init() {
        state = CacheStore.shared.get(HarborAPI.SyncState.self, for: Self.cacheKey)
    }

    /// Live (non-tombstoned) profiles from the account roster, or nil when no roster doc exists.
    var roster: [WireProfile]? {
        guard let doc = state?.docs.first(where: { $0.key == "account:profiles" }) else { return nil }
        struct Roster: Codable { var profiles: [WireProfile] }
        let all = (try? doc.value.decode(Roster.self))?.profiles ?? []
        return all.filter { $0.deletedAt == nil }
    }

    func doc(section: String, syncId: String? = nil) -> HarborAPI.SyncDoc? {
        let key = syncId.map { "\($0):\(section)" } ?? "account:\(section)"
        return state?.docs.first { $0.key == key }
    }

    func pull() async {
        guard phase != .pulling else { return }
        phase = .pulling
        do {
            let s = try await AccountStore.shared.withToken { try await HarborAPI.syncState(token: $0) }
            state = s
            lastPull = Date()
            try? CacheStore.shared.set(s, for: Self.cacheKey)
            phase = .idle
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func clear() {
        state = nil
        CacheStore.shared.remove(Self.cacheKey)
    }
}
