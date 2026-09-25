import Foundation

/// Small, durable values in UserDefaults. tvOS caps the whole domain at 500 KB, so only
/// settings and pointers live here; anything bulky goes to `CacheStore`.
enum Prefs {
    static let budgetBytes = 400_000
    private static let defaults = UserDefaults.standard
    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    /// (bug pass) `budgetBytes` was declared but never enforced: every durable key (playlists, custom
    /// lists, player prefs, the eBook shelf…) could land here up to 64 KB each, so a busy household
    /// could push the domain past tvOS's cap, where writes stop sticking. Over the budget a write
    /// throws, and KeyValueStore's durable tier moves the value to Caches instead. Values under 1 KB
    /// (flags, the curfew counter) always go through; the ~100 KB between the budget and the cap
    /// is their room.
    private static let lock = NSLock()
    private static var usedEstimate: Int?

    static func set<T: Encodable>(_ value: T, for key: String) throws {
        let data = try encoder.encode(value)
        guard data.count < 64_000 else { throw Failure.tooLarge(key, data.count) }
        lock.lock(); defer { lock.unlock() }
        let old = defaults.data(forKey: key)?.count ?? 0
        let used = usedEstimate ?? usedBytes()
        let next = max(0, used - old) + data.count
        if data.count >= 1024, next > budgetBytes {
            usedEstimate = used
            throw Failure.tooLarge(key, data.count)
        }
        defaults.set(data, forKey: key)
        usedEstimate = next
    }

    static func get<T: Decodable>(_ type: T.Type, for key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? decoder.decode(type, from: data)
    }

    static func remove(_ key: String) {
        lock.lock(); defer { lock.unlock() }
        if let old = defaults.data(forKey: key)?.count, let used = usedEstimate { usedEstimate = max(0, used - old) }
        defaults.removeObject(forKey: key)
    }

    /// Every key this app owns in UserDefaults (the app's own persistent domain only, so
    /// none of the system-wide defaults leak in). Used by `KeyValueStore.snapshot()`.
    static func allKeys() -> [String] {
        let domain = defaults.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "") ?? [:]
        return Array(domain.keys)
    }

    /// Approximate bytes used by everything this app stored in UserDefaults.
    static func usedBytes() -> Int {
        let dict = defaults.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "") ?? [:]
        guard let data = try? PropertyListSerialization.data(fromPropertyList: dict, format: .binary, options: 0) else { return 0 }
        return data.count
    }

    enum Failure: Error { case tooLarge(String, Int) }
}
