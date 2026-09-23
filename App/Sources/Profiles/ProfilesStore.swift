import Foundation
import Combine
import CryptoKit

/// Local profiles on this Apple TV. The roster comes from account sync (read-only for now);
/// PINs, the active profile and per-profile Stremio sessions are device-local, as upstream intends.
@MainActor
final class ProfilesStore: ObservableObject {
    struct Profile: Codable, Equatable, Identifiable {
        var id: String            // local id, `p_<base36>_<rand>` like upstream
        var syncId: String?
        var name: String
        var avatar: String?
        var color: String
        var isPrimary: Bool
        var kid: SyncReader.WireProfile.Kid?
        var passwordHash: String?
        var createdAt: Double
        /// Settings shared with the primary profile (upstream `settingsLinked`, default true).
        var settingsLinked: Bool? = nil
        var linked: Bool { settingsLinked ?? true }
    }

    struct StremioSession: Codable, Equatable {
        var authKey: String
        var user: StremioAPI.User
    }

    static let shared = ProfilesStore()
    static let colors = ["#7dd3fc", "#60a5fa", "#a78bfa", "#f472b6", "#fb7185", "#fb923c", "#fbbf24", "#a3e635", "#34d399", "#22d3ee"]

    @Published private(set) var profiles: [Profile]
    @Published private(set) var activeId: String?

    private static let profilesKey = "harbor.profiles.v1"
    private static let activeKey = "harbor.active-profile"
    private static let idMapKey = "harbor.sync.idmap"

    private init() {
        profiles = Prefs.get([Profile].self, for: Self.profilesKey) ?? []
        activeId = Prefs.get(String.self, for: Self.activeKey)
    }

    var active: Profile? { profiles.first { $0.id == activeId } }

    /// Adopt the synced roster: match by syncId, keep device-local fields, add new, drop tombstoned.
    func adopt(roster: [SyncReader.WireProfile]) {
        var idMap = Prefs.get([String: String].self, for: Self.idMapKey) ?? [:]   // localId -> syncId
        var next: [Profile] = []
        for w in roster {
            let localId = idMap.first { $0.value == w.syncId }?.key
            let existing = localId.flatMap { id in profiles.first { $0.id == id } }
            var p = existing ?? Profile(id: Self.newId(), syncId: w.syncId, name: w.name, avatar: w.avatar, color: w.color,
                                        isPrimary: w.isPrimary, kid: w.kid, passwordHash: nil, createdAt: w.createdAt)
            p.syncId = w.syncId; p.name = w.name; p.avatar = w.avatar; p.color = w.color; p.isPrimary = w.isPrimary; p.kid = w.kid
            p.settingsLinked = w.settingsLinked
            idMap[p.id] = w.syncId
            next.append(p)
        }
        profiles = next.sorted { ($0.isPrimary ? 0 : 1, $0.createdAt) < ($1.isPrimary ? 0 : 1, $1.createdAt) }
        try? Prefs.set(idMap, for: Self.idMapKey)
        persist()
        if active == nil { activeId = nil; Prefs.remove(Self.activeKey) }
    }

    /// Used only when the account has no roster yet: one primary profile named after the account.
    func seedIfEmpty(name: String) {
        guard profiles.isEmpty else { return }
        profiles = [Profile(id: Self.newId(), syncId: nil, name: name, avatar: nil, color: Self.colors[0], isPrimary: true,
                            kid: nil, passwordHash: nil, createdAt: Date().timeIntervalSince1970 * 1000)]
        persist()
    }

    func select(_ id: String) {
        activeId = id
        try? Prefs.set(id, for: Self.activeKey)
    }

    func deselect() {
        activeId = nil
        Prefs.remove(Self.activeKey)
    }

    func setPin(_ pin: String?, for id: String) {
        guard let i = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[i].passwordHash = pin.map(Self.hashPin)
        persist()
    }

    func verifyPin(_ pin: String, for profile: Profile) -> Bool {
        guard let hash = profile.passwordHash else { return true }
        return Self.hashPin(pin) == hash
    }

    // MARK: Stremio session per profile (harbor.auth.<localId>)

    func stremioSession(for id: String) -> StremioSession? {
        guard let raw = SecretStore.get("harbor.auth.\(id)"), let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(StremioSession.self, from: data)
    }

    func setStremioSession(_ s: StremioSession?, for id: String) {
        let key = "harbor.auth.\(id)"
        if let s, let data = try? JSONEncoder().encode(s), let raw = String(data: data, encoding: .utf8) {
            try? SecretStore.set(raw, for: key)
        } else {
            SecretStore.remove(key)
        }
        objectWillChange.send()
    }

    func reset() {
        for p in profiles { SecretStore.remove("harbor.auth.\(p.id)") }
        profiles = []; activeId = nil
        Prefs.remove(Self.profilesKey); Prefs.remove(Self.activeKey); Prefs.remove(Self.idMapKey)
    }

    func installFixture(_ list: [Profile], activeId: String?) {
        profiles = list
        self.activeId = activeId
    }

    private func persist() { try? Prefs.set(profiles, for: Self.profilesKey) }

    static func newId() -> String {
        let t = String(Int(Date().timeIntervalSince1970 * 1000), radix: 36)
        let r = String((0..<6).map { _ in "abcdefghijklmnopqrstuvwxyz0123456789".randomElement()! })
        return "p_\(t)_\(r)"
    }

    /// Same scheme as upstream src/lib/profile-password.ts, so a PIN typed here matches desktop semantics.
    static func hashPin(_ pin: String) -> String {
        let digest = SHA256.hash(data: Data("harbor-profile-v1|\(pin)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
