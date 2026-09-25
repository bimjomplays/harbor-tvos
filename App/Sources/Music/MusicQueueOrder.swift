import Foundation

/// music-queue.tsx MusicRepeatMode. The raw values are what upstream stores under
/// harbor.music.repeat.v1 ("off" | "all" | "one"); REPEAT_ORDER cycles off → all → one.
enum MusicRepeatMode: String, CaseIterable {
    case off, all, one

    /// music-queue.tsx cycleMusicRepeat
    var cycled: MusicRepeatMode {
        switch self {
        case .off: return .all
        case .all: return .one
        case .one: return .off
        }
    }
}

/// lib/music/queue-order.ts MusicQueueOrder: the listening order, kept apart from the stored
/// order of the album or playlist. Shuffle deals a permutation up front (the playing track at its
/// head), so Up next can read ahead of it and show what will really play. Previous under shuffle
/// walks back through what was heard; Next after that replays the same steps forward.
///
/// Positions are queue indices here (upstream returns the track and playMusic finds its index).
final class MusicQueueOrder {
    struct Modes {
        var shuffle: Bool
        var repeatMode: MusicRepeatMode
    }

    private var visited = Set<String>()
    private var history: [String] = []
    private var forward: [String] = []
    private var order: [String] = []
    private var signature = ""

    /// queue-order.ts queueTrackKey: a source substituted for a catalog entry keeps the catalog
    /// entry's key (collectionOrigin), so a track resolving mid-queue never reshuffles the order.
    static func key(_ track: MusicTrack) -> String {
        let connector: String = track.collectionOrigin?.connectorId ?? track.connectorId ?? ""
        let id: String = track.collectionOrigin?.id ?? track.id
        return connector + ":" + id
    }

    func reset() {
        visited.removeAll()
        history.removeAll()
        forward.removeAll()
        order.removeAll()
        signature = ""
    }

    private func firstIndex(of key: String, in queue: [MusicTrack]) -> Int? {
        queue.firstIndex { Self.key($0) == key }
    }

    /// queue-order.ts byKey: each key's first queue index, built in one pass per call.
    private static func positions(_ queue: [MusicTrack]) -> [String: Int] {
        var out: [String: Int] = [:]
        for (i, track) in queue.enumerated() {
            let key = Self.key(track)
            if out[key] == nil { out[key] = i }
        }
        return out
    }

    /// queue-order.ts shuffledOrder: kept while the queue holds the same tracks, dealt again when
    /// it changes (length, first or last entry, or a key it does not know). (TV) A key the queue
    /// holds twice is dealt once: upstream's length check never settled for such a queue and dealt
    /// a new order on every read, so Up next and the next advance disagreed.
    private func shuffledOrder(_ queue: [MusicTrack], _ index: Int) -> [String] {
        var keys: [String] = []
        var unique = Set<String>()
        for track in queue {
            let key = Self.key(track)
            if unique.insert(key).inserted { keys.append(key) }
        }
        let firstKey: String = keys.first ?? ""
        let lastKey: String = keys.last ?? ""
        let sig = "\(keys.count):\(firstKey):\(lastKey)"
        let currentKey: String = queue.indices.contains(index) ? Self.key(queue[index]) : ""
        let known = Set(order)
        let stale = signature != sig || order.count != keys.count || keys.contains { !known.contains($0) }
        if !stale { return order }
        // The track already playing keeps its place at the head, the rest are dealt behind it.
        var rest: [String] = keys.filter { $0 != currentKey }
        rest.shuffle()
        order = currentKey.isEmpty ? rest : [currentKey] + rest
        signature = sig
        return order
    }

    /// queue-order.ts upcoming: the entries that will actually play next, so a list shows the truth.
    /// (TV) Repeat all without shuffle reads one lap ahead; upstream fills the count by repeating
    /// the whole queue again, the current track and the ones already listed included.
    func upcoming(_ queue: [MusicTrack], _ index: Int, _ modes: Modes, count: Int) -> [Int] {
        if queue.isEmpty || count <= 0 { return [] }
        if modes.repeatMode == .one { return [] }
        if !modes.shuffle {
            let start = max(0, index + 1)
            var out: [Int] = []
            var i = start
            while i < queue.count, out.count < count {
                out.append(i)
                i += 1
            }
            if out.count >= count || modes.repeatMode != .all { return out }
            var j = 0
            while j < min(max(0, index), queue.count), out.count < count {
                out.append(j)
                j += 1
            }
            return out
        }
        let order = shuffledOrder(queue, index)
        let byKey = Self.positions(queue)
        let currentKey: String = queue.indices.contains(index) ? Self.key(queue[index]) : ""
        let at: Int = order.firstIndex(of: currentKey) ?? -1
        var out: [Int] = []
        var seen = Set<String>()
        // The queued "play next" picks are consumed first, so they lead the preview too.
        for key in forward.reversed() {
            if out.count >= count { break }
            if let i = firstIndex(of: key, in: queue) {
                out.append(i)
                seen.insert(key)
            }
        }
        var step = 1
        while step <= order.count, out.count < count {
            let position = at + step
            step += 1
            if position >= order.count, modes.repeatMode != .all { break }
            let key = order[position % order.count]
            if key == currentKey || seen.contains(key) { continue }
            if let i = byKey[key] {
                out.append(i)
                seen.insert(key)
            }
        }
        return out
    }

    /// queue-order.ts previous: the stored order's previous entry, or under shuffle the last one
    /// heard (the current track waits in `forward` for the next Next).
    func previous(_ queue: [MusicTrack], _ index: Int, shuffle: Bool) -> Int? {
        if !shuffle { return index - 1 >= 0 && index - 1 < queue.count ? index - 1 : nil }
        while let key = history.popLast() {
            if let i = firstIndex(of: key, in: queue) {
                if queue.indices.contains(index) { forward.append(Self.key(queue[index])) }
                return i
            }
        }
        return nil
    }

    /// queue-order.ts next. `auto` is a track ending by itself (repeat one then plays it again).
    /// `priority` is a "Play next" pick, which comes before anything else. With `commit` false the
    /// answer is only read (the gapless preload asks ahead); the advance itself commits it.
    func next(_ queue: [MusicTrack], _ index: Int, _ modes: Modes, auto: Bool, priority: MusicTrack?, commit: Bool) -> Int? {
        if queue.isEmpty { return nil }
        let hasCurrent = queue.indices.contains(index)
        if auto, modes.repeatMode == .one { return hasCurrent ? index : nil }
        var visited = self.visited
        var history = self.history
        var forward = self.forward
        let currentKey: String = hasCurrent ? Self.key(queue[index]) : ""
        func remember(_ next: Int?) -> Int? {
            if next != nil, hasCurrent {
                history.append(currentKey)
                if history.count > 500 { history.removeFirst() }
            }
            if commit {
                self.visited = visited
                self.history = history
                self.forward = forward
            }
            return next
        }
        if hasCurrent { visited.insert(currentKey) }
        if let priority {
            let wanted = Self.key(priority)
            if let i = queue.indices.first(where: { $0 != index && Self.key(queue[$0]) == wanted }) {
                forward = []
                return remember(i)
            }
        }
        if !modes.shuffle {
            if index + 1 < queue.count { return remember(max(0, index + 1)) }
            return remember(modes.repeatMode == .all ? 0 : nil)
        }
        while let key = forward.popLast() {
            if let i = firstIndex(of: key, in: queue) { return remember(i) }
        }
        let order = shuffledOrder(queue, index)
        let byKey = Self.positions(queue)
        let at: Int = order.firstIndex(of: currentKey) ?? -1
        var step = 1
        while step <= order.count {
            let position = at + step
            step += 1
            if position >= order.count, modes.repeatMode != .all { break }
            let key = order[position % order.count]
            if key == currentKey { continue }
            guard let i = byKey[key] else { continue }
            if visited.contains(key) {
                if modes.repeatMode != .all { continue }
                // A full lap under repeat-all starts the order again rather than stalling.
                visited.removeAll()
                if !currentKey.isEmpty { visited.insert(currentKey) }
            }
            return remember(i)
        }
        return remember(nil)
    }
}
