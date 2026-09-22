import Foundation

/// The single string key/value surface the engine's `localStorage` shim will talk to.
/// Routes by key: secrets → Keychain, small durable state → UserDefaults, the rest → Caches.
/// Upstream's own key names decide the class, so the tables here grow as modules are ported.
final class KeyValueStore {
    static let shared = KeyValueStore()

    enum Tier { case secret, durable, cache }

    private static let secretPrefixes = ["harbor.auth.", "harbor.theme-session.", "harbor.debrid.", "harbor.keys."]
    private static let durableKeys: Set<String> = ["harbor.profiles.v1", "harbor.active-profile", "harbor.settings.v1", "harbor.sync.account"]
    private static let durablePrefixes = ["harbor.sync.revs", "harbor.sync.idmap"]

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
        case .durable: value = Prefs.get(String.self, for: key)
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

    func remove(_ key: String) {
        lock.lock(); memory[key] = nil; lock.unlock()
        switch Self.tier(for: key) {
        case .secret: SecretStore.remove(key)
        case .durable: Prefs.remove(key); CacheStore.shared.remove(key)
        case .cache: CacheStore.shared.remove(key)
        }
    }
}
