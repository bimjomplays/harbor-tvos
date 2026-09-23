import Foundation

/// The single string key/value surface the engine's `localStorage` shim will talk to.
/// Routes by key: secrets → Keychain, small durable state → UserDefaults, the rest → Caches.
/// Upstream's own key names decide the class, so the tables here grow as modules are ported.
final class KeyValueStore {
    static let shared = KeyValueStore()

    enum Tier { case secret, durable, cache }

    /// Keychain-only keys: the app's own sessions plus upstream's secret-store prefixes
    /// (docs/engine-report.md §4; `secretStore.isSecretKey` is the authoritative list).
    private static let secretPrefixes = ["harbor.auth.", "harbor.theme-session", "harbor.debrid.", "harbor.keys.",
                                         "harbor.trakt.session.v1", "harbor.simkl.session.v1", "harbor.mal.session.v1", "harbor.anilist.session.v1",
                                         "harbor.lastfm.v1", "harbor.media-server.token.v1", "harbor.plex-auth.device.v1", "harbor.sports.api-sports.v1"]
    /// Small, user-authored state that must survive a cache purge: profiles, settings blobs
    /// (`harbor.settings`, `.shared`, `.<profile>`), sync bookkeeping, sports choices, consent.
    private static let durableKeys: Set<String> = ["harbor.profiles.v1", "harbor.active-profile", "harbor.settings", "harbor.settings.shared", "harbor.sync.account",
                                                   "harbor.sports.favourites.v1", "harbor.sports.sources.v1", "harbor-sports-consent", "harbor.iptv.playlists.v1",
                                                   "harbor.iptv.favorites.v2", "harbor.iptv.pins.v1", "harbor.installed-addons", "harbor.onboarding.bp", "harbor.customlists.v1",
                                                   "harbor.media-server.connections.v1", "harbor.media-server.mappings.v1", "harbor.media-server.summaries.v1"]
    private static let durablePrefixes = ["harbor.sync.revs", "harbor.sync.idmap", "harbor.settings.", "harbor.installed-addons.", "harbor.tvsettings.v1.",
                                          "harbor.favorites.v1.", "harbor.customlists.v1.", "harbor.localwatchlist.v1."]
    /// Every key the engine may own: upstream uses both `harbor.` and `harbor-` spellings.
    static func isEngineKey(_ key: String) -> Bool { key.hasPrefix("harbor.") || key.hasPrefix("harbor-") }

    private var memory: [String: String] = [:]
    private let lock = NSLock()

    static func tier(for key: String) -> Tier {
        if secretPrefixes.contains(where: key.hasPrefix) { return .secret }
        if durableKeys.contains(key) || durablePrefixes.contains(where: key.hasPrefix) { return .durable }
        return .cache
    }

    func get(_ key: String) -> String? {
        lock.lock(); if let v = memory[key] { lock.unlock(); return v }; lock.unlock()
        let value: String?
        switch Self.tier(for: key) {
        case .secret: value = SecretStore.get(key)
        case .durable: value = Prefs.get(String.self, for: key) ?? CacheStore.shared.get(String.self, for: key)
        case .cache: value = CacheStore.shared.get(String.self, for: key)
        }
        if let value { lock.lock(); memory[key] = value; lock.unlock() }
        return value
    }

    func set(_ value: String, for key: String) throws {
        lock.lock(); memory[key] = value; lock.unlock()
        switch Self.tier(for: key) {
        case .secret: try SecretStore.set(value, for: key)
        case .durable:
            do { try Prefs.set(value, for: key) } catch { try CacheStore.shared.set(value, for: key) }
        case .cache: try CacheStore.shared.set(value, for: key)
        }
    }

    /// Every `harbor.*` key/value across all three tiers, in one synchronous pass.
    /// `HarborEngine`'s `__harbor_host.storageSnapshot()` hands this to the bundle at boot so
    /// the JS `localStorage` shim can serve every read from memory. Later tiers win over
    /// earlier ones (an in-memory write is the freshest, then the Keychain / UserDefaults
    /// copy, then a possibly stale Caches copy of the same key).
    func snapshot() -> [String: String] {
        var out: [String: String] = [:]
        for key in CacheStore.shared.allKeys() where Self.isEngineKey(key) {
            if let value = CacheStore.shared.get(String.self, for: key) { out[key] = value }
        }
        for key in Prefs.allKeys() where Self.isEngineKey(key) {
            if let value = Prefs.get(String.self, for: key) { out[key] = value }
        }
        for key in SecretStore.allKeys() where Self.isEngineKey(key) {
            if let value = SecretStore.get(key) { out[key] = value }
        }
        lock.lock()
        for (key, value) in memory where Self.isEngineKey(key) { out[key] = value }
        lock.unlock()
        return out
    }

    func remove(_ key: String) {
        lock.lock(); memory[key] = nil; lock.unlock()
        switch Self.tier(for: key) {
        case .secret: SecretStore.remove(key)
        case .durable: Prefs.remove(key); CacheStore.shared.remove(key)
        case .cache: CacheStore.shared.remove(key)
        }
    }
}
