import Foundation

/// (bug pass 2) A list decoded element by element: an element that does not decode is skipped
/// instead of failing the whole list. Rows fed by synced or third-party data (the Stremio library,
/// addon catalogs, the community addon directory) went empty over one odd entry with the
/// synthesized `[T]` decoding, and silently, since the callers `try?` the engine call.
///
/// As a property wrapper on a synthesized-`Decodable` struct (`@LossyArray var metas: [Meta]`)
/// the memberwise initializer keeps its `[Meta]` parameter; a missing, `null` or non-array value
/// decodes as an empty list. As a plain type it decodes a top-level engine result:
/// `let r: LossyArray<Meta> = try await HarborEngine.shared.call(…)` then `r.wrappedValue`.
@propertyWrapper
struct LossyArray<Element: Decodable>: Decodable {
    var wrappedValue: [Element]

    init(wrappedValue: [Element]) { self.wrappedValue = wrappedValue }

    init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        var out: [Element] = []
        if let n = c.count { out.reserveCapacity(n) }
        while !c.isAtEnd {
            let at = c.currentIndex
            if let e = try? c.decode(Element.self) {
                out.append(e)
            } else if (try? c.decode(AnyJSON.self)) == nil || c.currentIndex == at {
                // Could not step past the bad element: keep what decoded so far.
                break
            }
        }
        wrappedValue = out
    }
}

extension LossyArray: Encodable where Element: Encodable {
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(wrappedValue)
    }
}

extension LossyArray: Equatable where Element: Equatable {}
extension LossyArray: Hashable where Element: Hashable {}

extension KeyedDecodingContainer {
    /// Used by synthesized decoding for `@LossyArray` properties: a missing key, `null` or a
    /// value that is not a list reads as an empty list.
    func decode<T>(_ type: LossyArray<T>.Type, forKey key: Key) throws -> LossyArray<T> {
        (try? decodeIfPresent(type, forKey: key)) ?? LossyArray(wrappedValue: [])
    }

    /// For hand-written decoders: the elements of the list at `key` that decode, skipping the
    /// rest; nil when the key is missing, `null` or not a list.
    func decodeLossy<T: Decodable>(_ type: T.Type, forKey key: Key) -> [T]? {
        (try? decodeIfPresent(LossyArray<T>.self, forKey: key))?.wrappedValue
    }
}
