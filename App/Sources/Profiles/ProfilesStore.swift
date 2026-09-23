import Foundation
import Combine
import CryptoKit

/// Local profiles on this Apple TV. The roster is adopted and pushed by the engine's profile
/// sync (see engine/sync.ts); PINs, the active profile and per-profile Stremio sessions are
/// device-local, as upstream intends.
@MainActor
final class ProfilesStore: ObservableObject {
    struct Profile: Codable, Equatable, Identifiable {
        struct Kid: Codable, Equatable { var age: Int; var curfewMinutes: Int?; var parentPinHash: String? }
        var id: String            // local id, `p_<base36>_<rand>` like upstream
        var syncId: String?
        var name: String
        var avatar: String?
        var color: String
        var isPrimary: Bool
        var kid: Kid?
        var passwordHash: String?
        var createdAt: Double
        /// Settings shared with the primary profile (upstream `settingsLinked`, default true).
        var settingsLinked: Bool? = nil
        var linked: Bool { settingsLinked ?? true }
        /// Upstream fields this app does not edit yet; carried so a re-save never drops them.
        var hideContent: AnyJSON? = nil
        var lockedTabs: AnyJSON? = nil
        var shareStremioWith: String? = nil
        /// The profile a fresh TV makes before sign-in. Roster adoption drops it instead of
        /// pushing it up as a duplicate (upstream planRoster, isBootstrapProfile).
        var bootstrap: Bool? = nil
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

    /// Upstream's `harbor.profiles.v1` shape (`{ activeId, profiles: [...] }`, lib/profiles.tsx),
    /// so the bundled modules that read it (addon store, settings, resume) see the same profiles.
    private struct Blob: Codable {
        var activeId: String?
        var profiles: [Profile]
    }

    private init() {
        if let raw = KeyValueStore.shared.get(Self.profilesKey), let data = raw.data(using: .utf8),
           let blob = try? JSONDecoder().decode(Blob.self, from: data) {
            profiles = blob.profiles
            activeId = blob.activeId
        } else {
            // Earlier builds stored a bare array in Prefs plus a separate active-id key.
            profiles = Prefs.get([Profile].self, for: Self.profilesKey) ?? []
            activeId = Prefs.get(String.self, for: Self.activeKey)
            if !profiles.isEmpty { persist() }
        }
        migrateIdMap()
    }

    /// Earlier builds stored the local-id → syncId map as a JSON dictionary through Prefs; the
    /// engine reads it as a JSON string through KeyValueStore. Re-save it once in that form.
    private func migrateIdMap() {
        guard KeyValueStore.shared.get(Self.idMapKey) == nil,
              let old = Prefs.get([String: String].self, for: Self.idMapKey), !old.isEmpty,
              let data = try? JSONEncoder().encode(old), let raw = String(data: data, encoding: .utf8) else { return }
        try? KeyValueStore.shared.set(raw, for: Self.idMapKey)
        HarborEngine.loaded?.syncStorage(key: Self.idMapKey, value: raw)
    }

    private var unsubscribe: (() -> Void)?

    /// Follow the engine: when profile sync adopts a roster it rewrites `harbor.profiles.v1`
    /// and says so; reload without re-persisting (that would echo a roster push).
    func attachEngine() {
        guard unsubscribe == nil else { return }
        unsubscribe = HarborEngine.shared.onEvent { [weak self] type, detail in
            guard type == "harbor:roster-applied" else { return }
            self?.reloadFromStore()
        }
    }

    func reloadFromStore() {
        guard let raw = KeyValueStore.shared.get(Self.profilesKey), let data = raw.data(using: .utf8),
              let blob = try? JSONDecoder().decode(Blob.self, from: data) else { return }
        profiles = blob.profiles
        activeId = blob.activeId
    }

    var active: Profile? { profiles.first { $0.id == activeId } }

    /// Used only when the account has no roster yet: one primary profile named after the account.
    func seedIfEmpty(name: String) {
        guard profiles.isEmpty else { return }
        profiles = [Profile(id: Self.newId(), syncId: nil, name: name, avatar: nil, color: Self.colors[0], isPrimary: true,
                            kid: nil, passwordHash: nil, createdAt: Date().timeIntervalSince1970 * 1000, bootstrap: true)]
        persist()
    }

    // MARK: Management (lib/profiles.tsx createProfile / updateProfile / deleteProfile)

    /// A new local profile; the roster push mints its syncId on the next flush.
    @discardableResult
    func create(name: String, avatar: String?, color: String) -> Profile {
        let primary = profiles.first { $0.isPrimary } ?? profiles.first
        let p = Profile(id: Self.newId(), syncId: nil, name: String(name.trimmingCharacters(in: .whitespaces).prefix(32)).isEmpty ? "Profile" : String(name.trimmingCharacters(in: .whitespaces).prefix(32)),
                        avatar: avatar, color: color, isPrimary: false, kid: nil, passwordHash: nil,
                        createdAt: Date().timeIntervalSince1970 * 1000, settingsLinked: true, shareStremioWith: primary?.id)
        profiles.append(p)
        persist()
        return p
    }

    func update(_ id: String, name: String? = nil, avatar: String?? = nil, color: String? = nil) {
        guard let i = profiles.firstIndex(where: { $0.id == id }) else { return }
        if let name { let n = String(name.trimmingCharacters(in: .whitespaces).prefix(32)); if !n.isEmpty { profiles[i].name = n } }
        if let avatar { profiles[i].avatar = avatar }
        if let color { profiles[i].color = color }
        persist()
    }

    /// Never the primary. Tombstones first (so the delete reaches other devices), then purges.
    func delete(_ id: String) async {
        guard let target = profiles.first(where: { $0.id == id }), !target.isPrimary else { return }
        _ = try? await HarborEngine.shared.callJSON("sync.profileDeleted", [.string(id)])
        _ = try? await HarborEngine.shared.callJSON("profilesRoom.purge", [.string(id)])
        SecretStore.remove("harbor.auth.\(id)")
        profiles.removeAll { $0.id == id }
        for i in profiles.indices where profiles[i].shareStremioWith == id { profiles[i].shareStremioWith = nil }
        if activeId == id { activeId = profiles.first?.id }
        persist()
    }

    func select(_ id: String) {
        activeId = id
        persist()
        HarborEngine.loaded?.emitEvent("harbor:active-profile-changed", detail: .object(["id": .string(id)]))
    }

    func deselect() {
        activeId = nil
        persist()
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
        KeyValueStore.shared.remove(Self.profilesKey); Prefs.remove(Self.activeKey); KeyValueStore.shared.remove(Self.idMapKey)
        HarborEngine.loaded?.syncStorage(key: Self.profilesKey, value: nil)
        HarborEngine.loaded?.syncStorage(key: Self.idMapKey, value: nil)
    }

    func installFixture(_ list: [Profile], activeId: String?) {
        profiles = list
        self.activeId = activeId
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(Blob(activeId: activeId, profiles: profiles)),
              let raw = String(data: data, encoding: .utf8) else { return }
        try? KeyValueStore.shared.set(raw, for: Self.profilesKey)
        HarborEngine.loaded?.syncStorage(key: Self.profilesKey, value: raw)
        HarborEngine.loaded?.emitEvent("harbor:profiles-updated")
    }

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
