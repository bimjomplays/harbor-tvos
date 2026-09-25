import Foundation

// (bug pass 2) Per-field lenient decoding for blobs that arrive from profile sync, the engine or
// the Watch Together relay. A synthesized Decodable fails the WHOLE value when any one field is
// null or of another type, which left the app silently on defaults (a synced settings blob with
// one stray field lost the TMDB key and the UI language) or froze a screen (one malformed
// participant dropped every room snapshot). These helpers let each field fail on its own.

/// A coding key built from any string, so a hand-written `init(from:)` can live in an extension
/// (keeping the memberwise init) without depending on the synthesized `CodingKeys`.
struct LenientKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(_ stringValue: String) { self.stringValue = stringValue }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

/// One element of a lossy array: `value` is nil when that element did not decode, so the rest
/// of the array still does.
struct LossyItem<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws {
        value = try? T(from: decoder)
    }
}

extension KeyedDecodingContainer where K == LenientKey {
    /// The key's value, or nil when it is missing, null or of another type.
    func lenient<T: Decodable>(_ key: String, as type: T.Type = T.self) -> T? {
        return try? decodeIfPresent(T.self, forKey: LenientKey(key))
    }

    /// The key's array with the elements that decode (bad ones are skipped), or nil when the key
    /// is missing, null or not an array.
    func lossyArray<T: Decodable>(_ key: String, of type: T.Type = T.self) -> [T]? {
        guard let items = try? decodeIfPresent([LossyItem<T>].self, forKey: LenientKey(key)) else { return nil }
        return items.compactMap { $0.value }
    }
}

/// (pre-release crash audit) `Int(x)` on a Double traps on NaN, ±infinity or a value past Int's
/// range, and a synced, addon, server or player value can be any of those. This is `Int(x)` (it
/// truncates toward zero) for every value that converts, clamped to ±2^53 (JavaScript's safe
/// integers, far past any real count, index or second), and 0 for NaN / ±infinity.
func clampedInt(_ value: Double) -> Int {
    guard value.isFinite else { return 0 }
    return Int(min(max(value, -9_007_199_254_740_991), 9_007_199_254_740_991))
}
