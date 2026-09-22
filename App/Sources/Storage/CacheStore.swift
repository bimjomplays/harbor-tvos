import Foundation

/// JSON documents in the Caches directory. tvOS may purge this whole folder at any time,
/// so everything here must be rebuildable from the Harbor account, Stremio, or a re-fetch.
final class CacheStore {
    static let shared = CacheStore()

    private let root: URL
    private let queue = DispatchQueue(label: "harbor.cache", qos: .utility)
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(directory: String = "harbor") {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        root = caches.appendingPathComponent(directory, isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    /// Everything outside this set is percent-escaped in the file name. "/" and "%" have to
    /// be escaped (they cannot appear verbatim in a path component), and escaping is
    /// reversible, which the old "/" → "_" substitution was not: `allKeys()` needs to give
    /// the engine back the exact `harbor.*` key it wrote.
    private static let fileNameAllowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))

    private func url(_ key: String) -> URL {
        let safe = key.addingPercentEncoding(withAllowedCharacters: Self.fileNameAllowed) ?? key
        return root.appendingPathComponent(safe + ".json")
    }

    /// Every key currently on disk, decoded back from its file name.
    func allKeys() -> [String] {
        queue.sync {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
            return names.compactMap { name -> String? in
                guard name.hasSuffix(".json") else { return nil }
                let encoded = String(name.dropLast(5))
                guard !encoded.isEmpty else { return nil }
                return encoded.removingPercentEncoding ?? encoded
            }
        }
    }

    func set<T: Encodable>(_ value: T, for key: String) throws {
        let data = try encoder.encode(value)
        try queue.sync { try data.write(to: url(key), options: .atomic) }
    }

    func get<T: Decodable>(_ type: T.Type, for key: String) -> T? {
        queue.sync {
            guard let data = try? Data(contentsOf: url(key)) else { return nil }
            return try? decoder.decode(type, from: data)
        }
    }

    func remove(_ key: String) { queue.sync { try? FileManager.default.removeItem(at: url(key)) } }

    func exists(_ key: String) -> Bool { FileManager.default.fileExists(atPath: url(key).path) }

    /// True when the cache folder is empty: either first launch or tvOS purged it.
    var isEmpty: Bool {
        ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).isEmpty
    }

    func usedBytes() -> Int {
        let files = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }
}
