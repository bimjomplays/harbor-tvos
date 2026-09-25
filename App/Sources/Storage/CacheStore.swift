import Foundation
import CryptoKit

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

    /// (bug pass 2) A file name is at most 255 bytes. A long key (`harbor.manga.art.<CJK title>`:
    /// CJK letters stay verbatim at 3 bytes each) made the write throw, so the value lived only in
    /// memory. Names that fit keep exactly the old form (so every existing file still reads); a
    /// longer one becomes `<readable prefix>~<sha256 hex>.json` with the key itself in a
    /// `<same>.key` sidecar for `allKeys()`. `~` is always escaped in the old form, so it marks a
    /// hashed name unambiguously.
    private static let maxNameBytes = 255
    private static let hashMarker = "~"

    private func base(_ key: String) -> (name: String, hashed: Bool) {
        let safe = key.addingPercentEncoding(withAllowedCharacters: Self.fileNameAllowed) ?? key
        if safe.utf8.count + 5 <= Self.maxNameBytes { return (safe, false) }   // + ".json"
        var prefix = ""
        for ch in safe {
            if prefix.utf8.count + String(ch).utf8.count > 60 { break }
            prefix.append(ch)
        }
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return (prefix + Self.hashMarker + digest, true)
    }

    private func url(_ key: String) -> URL {
        root.appendingPathComponent(base(key).name + ".json")
    }

    private func keyURL(_ name: String) -> URL {
        root.appendingPathComponent(name + ".key")
    }

    /// Every key currently on disk, decoded back from its file name (or, for a hashed name, read
    /// from its sidecar).
    func allKeys() -> [String] {
        queue.sync {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
            return names.compactMap { name -> String? in
                guard name.hasSuffix(".json") else { return nil }
                let encoded = String(name.dropLast(5))
                guard !encoded.isEmpty else { return nil }
                if encoded.contains(Self.hashMarker) {
                    guard let data = try? Data(contentsOf: keyURL(encoded)), let key = String(data: data, encoding: .utf8), !key.isEmpty else { return nil }
                    return key
                }
                return encoded.removingPercentEncoding ?? encoded
            }
        }
    }

    func set<T: Encodable>(_ value: T, for key: String) throws {
        let data = try encoder.encode(value)
        let b = base(key)
        try queue.sync {
            if b.hashed { try Data(key.utf8).write(to: keyURL(b.name), options: .atomic) }
            try data.write(to: root.appendingPathComponent(b.name + ".json"), options: .atomic)
        }
    }

    func get<T: Decodable>(_ type: T.Type, for key: String) -> T? {
        queue.sync {
            guard let data = try? Data(contentsOf: url(key)) else { return nil }
            return try? decoder.decode(type, from: data)
        }
    }

    func remove(_ key: String) {
        let b = base(key)
        queue.sync {
            try? FileManager.default.removeItem(at: root.appendingPathComponent(b.name + ".json"))
            if b.hashed { try? FileManager.default.removeItem(at: keyURL(b.name)) }
        }
    }

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
