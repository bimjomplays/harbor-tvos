import Foundation
import HarborFFI

/// Stage 6: the librqbit torrent engine (rust/harbor-ffi/src/torrent, a port of upstream
/// src-tauri/src/torrent_engine.rs) from Swift, plus the playback bookkeeping of upstream
/// lib/torrent/local-engine.ts:
/// - `stream(_:)` is resolve.ts tryLocalEngine: add the magnet with its trackers, pick the file
///   (the addon's fileIdx, else selectEngineFileIdx), return the loopback stream URL mpv opens.
/// - A resolved torrent is handed to the player (beginTorrentPlaybackHandoff, 60 s); the player
///   claims it when it opens (`playerOpened`) and releases it when it closes (`playerClosed`).
/// - A released or abandoned torrent is removed 1.2 s later (scheduleTorrentRemoval) with its
///   data: tvOS gives no durable disk, so the stream cache never outlives playback here.
/// Every C call blocks, so each one runs on `queue`, never on the main thread.
final class TorrentEngine {
    static let shared = TorrentEngine()

    /// engine/streams.ts P2pPlan: what resolve hands over when a torrent should play here.
    struct Plan: Decodable {
        struct Sub: Decodable { var url: String; var lang: String? }
        var infoHash: String
        var magnet: String
        var trackers: [String]
        var fileIdx: Int?
        var filename: String?
        var season: Int?
        var episode: Int?
        var notWebReady: Bool?
        var subtitles: [Sub]?
        var retentionHours: Int?
        var maxGb: Int?
        /// The debrids get their turn when the engine fails (resolve again with afterP2p).
        var debridFallback: Bool?
    }

    struct File: Decodable { var idx: Int; var name: String; var length: Double }
    /// harbor_torrent_add's answer (upstream AddResult + the file it narrowed to).
    struct Added: Decodable {
        var info_hash: String
        var files: [File]
        var stream_base: String
        var already_managed: Bool
        var file_idx: Int?
        var stream_url: String?
    }
    /// upstream TorrentEngineStats.
    struct Stats: Decodable, Equatable {
        var peers: Int
        var unchoked: Int
        var downloaded: Double
        var downloadSpeed: Double
        var streamProgress: Double
        var streamLen: Double
        var peerSearchRunning: Bool
        var finished: Bool
        var state: String
    }
    /// upstream EngineStatusDto.
    struct Status: Decodable {
        var ready: Bool
        var port: Int?
        var active_torrents: Int
        var last_error: String?
        var dht_tier: Int
        var dht_nodes: Int
    }
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
        /// resolve.ts engineFailureCode for a local-engine failure.
        var code: String { message.range(of: "metadata timed out|no peers", options: [.regularExpression, .caseInsensitive]) != nil ? "engine-no-peers" : "engine-not-ready" }
    }
    struct Streaming { var url: String; var infoHash: String; var fileIdx: Int }

    /// tvOS cap on the stream cache (GB). Data is deleted when playback ends, so this only bounds
    /// what an interrupted session can leave behind; upstream's own default is 20 GB.
    static let tvosCacheCapGb = 10
    private static let handoffSeconds: Double = 60      // beginTorrentPlaybackHandoff timeoutMs
    private static let removalDelay: Double = 1.2       // scheduleTorrentRemoval delayMs

    private let queue = DispatchQueue(label: "harbor.torrent-engine", qos: .userInitiated, attributes: .concurrent)
    private let lock = NSLock()
    private var handoffs: [String: DispatchWorkItem] = [:]
    private var removals: [String: DispatchWorkItem] = [:]
    private var owners: [String: Int] = [:]

    private init() {}

    // MARK: C calls

    private struct ErrorProbe: Decodable { var error: String? }
    private struct OK: Decodable { var ok: Bool? }

    /// Runs one blocking C call on `queue`, frees the returned string, decodes the JSON.
    private func run<T: Decodable>(_ type: T.Type, _ body: @escaping () -> UnsafeMutablePointer<CChar>?) async throws -> T {
        let text: String = await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
            queue.async {
                guard let p = body() else { cont.resume(returning: "{\"error\":\"torrent engine gave no answer\"}"); return }
                let s = String(cString: p)
                harbor_string_free(p)
                cont.resume(returning: s)
            }
        }
        let data = Data(text.utf8)
        if let e = try? JSONDecoder().decode(ErrorProbe.self, from: data), let message = e.error { throw Failure(message: message) }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private static func json<T: Encodable>(_ value: T) -> String {
        (try? JSONEncoder().encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    /// Starts the engine under Caches (or returns the running one).
    private func ensureStarted(retentionHours: Int, maxGb: Int) async throws {
        struct Config: Encodable { var dir: String; var retentionHours: Int; var maxGb: Int }
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = caches.appendingPathComponent("torrent-engine", isDirectory: true).path
        let cap = maxGb <= 0 ? Self.tvosCacheCapGb : min(maxGb, Self.tvosCacheCapGb)
        let config = Self.json(Config(dir: dir, retentionHours: max(0, retentionHours), maxGb: cap))
        let status = try await run(Status.self) { harbor_torrent_start(config) }
        guard status.ready else { throw Failure(message: status.last_error ?? "engine not ready") }
    }

    func status() async -> Status? {
        try? await run(Status.self) { harbor_torrent_status() }
    }

    func stats(infoHash: String, fileIdx: Int?) async -> Stats? {
        let hash = infoHash
        let idx = Int64(fileIdx ?? -1)
        return try? await run(Stats.self) { harbor_torrent_stats(hash, idx) }
    }

    /// upstream torrentEngineRemove.
    func remove(_ infoHash: String, deleteFiles: Bool) {
        let hash = infoHash.lowercased()
        queue.async {
            if let p = harbor_torrent_remove(hash, deleteFiles) { harbor_string_free(p) }
        }
    }

    // MARK: resolve.ts tryLocalEngine

    /// Adds the plan's torrent (waiting for metadata, up to 60 s), narrows it to the file to play
    /// and hands it to the player. Throws `Failure` (see `code`) when the engine cannot.
    func stream(_ plan: Plan) async throws -> Streaming {
        try await ensureStarted(retentionHours: plan.retentionHours ?? 12, maxGb: plan.maxGb ?? 20)
        struct Request: Encodable { var magnet: String; var trackers: [String]; var fileIdx: Int? }
        let request = Self.json(Request(magnet: plan.magnet, trackers: plan.trackers, fileIdx: plan.fileIdx.flatMap { $0 >= 0 ? $0 : nil }))
        let added = try await run(Added.self) { harbor_torrent_add(request) }
        let hash = added.info_hash.lowercased()
        guard !added.files.isEmpty else {
            if !added.already_managed { remove(hash, deleteFiles: true) }
            throw Failure(message: "torrent has no files")
        }
        var idx = plan.fileIdx.flatMap { $0 >= 0 && $0 < added.files.count ? $0 : nil } ?? added.file_idx ?? 0
        if plan.fileIdx == nil {
            // selectEngineFileIdx: the episode's file by name, else the largest video.
            let files: [AnyJSON] = added.files.map { .object(["idx": .number(Double($0.idx)), "name": .string($0.name), "length": .number($0.length)]) }
            let season: AnyJSON = plan.season.map { .number(Double($0)) } ?? .null
            let episode: AnyJSON = plan.episode.map { .number(Double($0)) } ?? .null
            // (bug pass 2) Int(_:) traps on a non-integral-range Double (a huge or non-finite
            // index from the engine); only a whole number that could be a file index is taken.
            if let n = (try? await HarborEngine.shared.callJSON("streamsRoom.p2pFileIdx", [.array(files), season, episode]))?.number,
               n.isFinite, n >= 0, n <= Double(Int32.max), n.rounded() == n {
                let pick = Int(n)
                if added.files.contains(where: { $0.idx == pick }) { idx = pick }
            }
        }
        if idx != added.file_idx {
            let fileIdx = Int64(idx)
            do {
                _ = try await run(OK.self) { harbor_torrent_select(hash, fileIdx) }
            } catch {
                if !added.already_managed { remove(hash, deleteFiles: true) }
                throw error
            }
        }
        beginHandoff(hash)
        return Streaming(url: "\(added.stream_base)/\(hash)/\(idx)", infoHash: hash, fileIdx: idx)
    }

    // MARK: playback ownership (local-engine.ts)

    /// localEngineStreamRef: the torrent behind a loopback engine URL, if it is one.
    static func streamRef(_ url: URL) -> (infoHash: String, fileIdx: Int)? {
        guard url.scheme == "http" || url.scheme == "https",
              url.host == "127.0.0.1" || url.host == "localhost" else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.count >= 3, parts[0] == "stream", parts[1].count == 40,
              parts[1].allSatisfy({ $0.isHexDigit }), let idx = Int(parts[2]), idx >= 0 else { return nil }
        return (parts[1].lowercased(), idx)
    }

    /// beginTorrentPlaybackHandoff: the player has 60 s to claim the torrent before it goes.
    private func beginHandoff(_ hash: String) {
        let item = DispatchWorkItem { [weak self] in self?.handoffExpired(hash) }
        lock.lock()
        handoffs[hash]?.cancel()
        handoffs[hash] = item
        removals.removeValue(forKey: hash)?.cancel()
        lock.unlock()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + Self.handoffSeconds, execute: item)
    }

    private func handoffExpired(_ hash: String) {
        lock.lock()
        handoffs[hash] = nil
        let owned = (owners[hash] ?? 0) > 0
        lock.unlock()
        if !owned { remove(hash, deleteFiles: true) }   // scheduleAbandonedTorrentRemoval(key, 0)
    }

    /// use-player-media retainTorrentUsage + claimTorrentPlaybackHandoff. No-op for other URLs.
    func playerOpened(url: URL) {
        guard let ref = Self.streamRef(url) else { return }
        lock.lock()
        handoffs.removeValue(forKey: ref.infoHash)?.cancel()
        removals.removeValue(forKey: ref.infoHash)?.cancel()
        owners[ref.infoHash, default: 0] += 1
        lock.unlock()
    }

    /// use-player-media releaseTorrentUsage: the last owner out removes the torrent and its data.
    func playerClosed(url: URL) {
        guard let ref = Self.streamRef(url) else { return }
        let hash = ref.infoHash
        lock.lock()
        let left = max(0, (owners[hash] ?? 0) - 1)
        owners[hash] = left == 0 ? nil : left
        guard left == 0, handoffs[hash] == nil else { lock.unlock(); return }
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let reclaimed = (self.owners[hash] ?? 0) > 0 || self.handoffs[hash] != nil
            self.removals[hash] = nil
            self.lock.unlock()
            if !reclaimed { self.remove(hash, deleteFiles: true) }
        }
        removals.removeValue(forKey: hash)?.cancel()
        removals[hash] = item
        lock.unlock()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + Self.removalDelay, execute: item)
    }
}
