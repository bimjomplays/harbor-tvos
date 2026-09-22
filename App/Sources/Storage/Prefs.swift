import Foundation

/// Small, durable values in UserDefaults. tvOS caps the whole domain at 500 KB, so only
/// settings and pointers live here; anything bulky goes to `CacheStore`.
enum Prefs {
    static let budgetBytes = 400_000
    private static let defaults = UserDefaults.standard
    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    static func set<T: Encodable>(_ value: T, for key: String) throws {
        let data = try encoder.encode(value)
        guard data.count < 64_000 else { throw Failure.tooLarge(key, data.count) }
        defaults.set(data, forKey: key)
    }

    static func get<T: Decodable>(_ type: T.Type, for key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? decoder.decode(type, from: data)
    }

    static func remove(_ key: String) { defaults.removeObject(forKey: key) }

    /// Approximate bytes used by everything this app stored in UserDefaults.
    static func usedBytes() -> Int {
        let dict = defaults.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "") ?? [:]
        guard let data = try? PropertyListSerialization.data(fromPropertyList: dict, format: .binary, options: 0) else { return 0 }
        return data.count
    }

    enum Failure: Error { case tooLarge(String, Int) }
}
