import Foundation
import CoreGraphics
import CoreImage
import CoreVideo
import CryptoKit
import ImageIO
import Libmpv

// (P11) use-exit-snapshot.ts + lib/snapshots.ts: when the viewer leaves playback, Harbor keeps a
// frame of the spot they left, and the Continue Watching card leads with it (bp-cw-row.tsx
// BpCwCard `pinned`). Upstream keeps the frames as JPEG data URLs in localStorage; the TV keeps
// them as JPEG files in Caches (tvOS may purge them, and the card then draws its usual art).

/// settings.cwSnapshotRetentionDays (30 by default; 0 turns the frames off and clears them) and
/// settings.cwSnapshotFullQuality (off: light thumbnails), both set in desktop Settings →
/// Library → Home ("Continue Watching screenshots"). Big Picture has no control for them.
enum ExitSnapshotSettings {
    /// lib/snapshots.ts DEFAULT_RETENTION_DAYS.
    static let defaultDays = 30

    @MainActor static var current: (days: Int, full: Bool) {
        let slice = SettingsBridge.shared.slice
        return (days(slice.cwSnapshotRetentionDays), slice.cwSnapshotFullQuality ?? false)
    }

    /// snapshots.ts retentionDays(): a finite value of 0 or more, rounded; anything else is 30.
    static func days(_ raw: Double?) -> Int {
        guard let raw, raw.isFinite, raw >= 0 else { return defaultDays }
        return Int(min(raw, 100_000).rounded())
    }
}

/// snapshots.ts useSnapshotVersion: bumped after every saved frame, so a Continue Watching card on
/// screen draws the new one (ContinueCardView observes it).
@MainActor
final class ExitSnapshotVersion: ObservableObject {
    static let shared = ExitSnapshotVersion()
    @Published private(set) var version = 0

    func bump() { version &+= 1 }
}

/// lib/snapshots.ts on disk: one JPEG per title in Caches/harbor-cw-snapshots, named by a hash of
/// the id and the time it was saved (a new frame is a new file, so the image cache never serves the
/// old one), pruned by retention days, at most MAX_ENTRIES frames and MAX_TOTAL_BYTES in all
/// (oldest out first). Thread-safe: the card reads on the main thread, saves run off it.
final class ExitSnapshotStore: @unchecked Sendable {
    static let shared = ExitSnapshotStore()

    /// snapshots.ts MAX_ENTRIES.
    static let maxEntries = 80
    /// snapshots.ts MAX_TOTAL_BYTES (2.5 MB; upstream counts the data URL's characters, the TV the
    /// file bytes). Full quality frames are bigger, so fewer are kept before the oldest roll off.
    static let maxTotalBytes = 2_621_440
    /// snapshots.ts DAY_MS.
    static let daySec: Double = 86_400

    private struct Entry {
        var file: String
        var t: Date
        var bytes: Int
    }

    private let lock = NSLock()
    private let dir: URL
    /// Keyed by the id's hash; read from the folder on first use.
    private var index: [String: Entry]?

    init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        dir = caches.appendingPathComponent("harbor-cw-snapshots", isDirectory: true)
    }

    /// The file a title's frame is under: its id hashed (ids carry ":" and "/").
    private static func key(_ id: String) -> String {
        let digest = SHA256.hash(data: Data(id.utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// snapshots.ts readSnapshot: the saved frame's file, or nil when there is none, it is past
    /// the retention, or the frames are off (0 days). An expired frame is dropped here.
    func url(for id: String, retentionDays: Int) -> URL? {
        guard retentionDays > 0, !id.isEmpty else { return nil }
        lock.lock()
        defer { lock.unlock() }
        var idx: [String: Entry] = loadedIndex()
        let k = Self.key(id)
        guard let e = idx[k] else { return nil }
        if Date().timeIntervalSince(e.t) > Double(retentionDays) * Self.daySec {
            drop(e.file)
            idx[k] = nil
            index = idx
            return nil
        }
        return dir.appendingPathComponent(e.file)
    }

    /// snapshots.ts saveSnapshot: the frame replaces the title's last one; expired frames go, then
    /// the oldest beyond MAX_ENTRIES, then the oldest while the total runs over MAX_TOTAL_BYTES
    /// (never the frame just saved). True when it was written.
    @discardableResult
    func save(id: String, jpeg: Data, retentionDays: Int) -> Bool {
        guard retentionDays > 0, !id.isEmpty, !jpeg.isEmpty else { return false }
        lock.lock()
        defer { lock.unlock() }
        var idx: [String: Entry] = loadedIndex()
        pruneExpired(&idx, retentionDays: retentionDays)
        let k = Self.key(id)
        if let old = idx[k] {
            drop(old.file)
            idx[k] = nil
        }
        let now = Date()
        let ms = Int64((now.timeIntervalSince1970 * 1000).rounded())
        let name = "\(k)-\(ms).jpg"
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try jpeg.write(to: dir.appendingPathComponent(name), options: .atomic)
        } catch {
            index = idx
            return false
        }
        idx[k] = Entry(file: name, t: now, bytes: jpeg.count)
        var byAge: [(key: String, value: Entry)] = idx.sorted { $0.value.t < $1.value.t }
        while byAge.count > Self.maxEntries {
            let evicted = byAge.removeFirst()
            drop(evicted.value.file)
            idx[evicted.key] = nil
        }
        var total: Int = byAge.reduce(0) { $0 + $1.value.bytes }
        while total > Self.maxTotalBytes, byAge.count > 1 {
            let evicted = byAge.removeFirst()
            total -= evicted.value.bytes
            drop(evicted.value.file)
            idx[evicted.key] = nil
        }
        index = idx
        return true
    }

    /// settings.tsx → setSnapshotRetentionDays: 0 days clears every frame, otherwise the expired
    /// ones go (pruneExpiredSnapshots).
    func prune(retentionDays: Int) {
        lock.lock()
        defer { lock.unlock() }
        if retentionDays <= 0 {
            try? FileManager.default.removeItem(at: dir)
            index = [:]
            return
        }
        var idx: [String: Entry] = loadedIndex()
        pruneExpired(&idx, retentionDays: retentionDays)
        index = idx
    }

    /// use-exit-snapshot persist(): the write and the card's refresh, off the main thread.
    static func persist(id: String, jpeg: Data, retentionDays: Int) {
        DispatchQueue.global(qos: .utility).async {
            guard shared.save(id: id, jpeg: jpeg, retentionDays: retentionDays) else { return }
            Task { @MainActor in ExitSnapshotVersion.shared.bump() }
        }
    }

    /// Prune off the main thread (a player opening, as upstream prunes when the setting loads).
    static func pruneSoon(retentionDays: Int) {
        DispatchQueue.global(qos: .utility).async { shared.prune(retentionDays: retentionDays) }
    }

    // Callers hold the lock.

    private func pruneExpired(_ idx: inout [String: Entry], retentionDays: Int) {
        let cutoff: Date = Date().addingTimeInterval(-Double(retentionDays) * Self.daySec)
        for (k, e) in idx where e.t < cutoff {
            drop(e.file)
            idx[k] = nil
        }
    }

    private func drop(_ file: String) {
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(file))
    }

    /// The folder read once: "<hash>-<ms>.jpg" files; a second file for the same hash (a save cut
    /// short) keeps the newer one. Anything else in the folder is left alone.
    private func loadedIndex() -> [String: Entry] {
        if let index { return index }
        var out: [String: Entry] = [:]
        let keys: [URLResourceKey] = [.fileSizeKey]
        let files: [URL] = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys)) ?? []
        for file in files where file.pathExtension == "jpg" {
            let base = file.deletingPathExtension().lastPathComponent
            guard let dash = base.lastIndex(of: "-") else { continue }
            let k = String(base[base.startIndex..<dash])
            guard let ms = Double(base[base.index(after: dash)...]), ms.isFinite else { continue }
            let size: Int = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let entry = Entry(file: file.lastPathComponent, t: Date(timeIntervalSince1970: ms / 1000), bytes: size)
            if let have = out[k] {
                if have.t >= entry.t { drop(entry.file); continue }
                drop(have.file)
            }
            out[k] = entry
        }
        index = out
        return out
    }
}

/// snapshots.ts captureFrame / captureMpvFrame + downscaleDataUrl: a frame as a JPEG no wider than
/// THUMB_WIDTH (320, quality 0.65) or, with cwSnapshotFullQuality, FULL_WIDTH (1280, quality 0.9),
/// never upscaled. Everything here runs off the main thread.
enum FrameGrab {
    static let thumbWidth = 320
    static let thumbJpegQuality: Double = 0.65
    static let fullWidth = 1280
    static let fullJpegQuality: Double = 0.9

    private static let ciContext = CIContext(options: [CIContextOption.cacheIntermediates: false])

    static func targetWidth(fullQuality: Bool) -> Int { fullQuality ? fullWidth : thumbWidth }

    /// A decoded AVPlayer frame (NativePlayerController's video output), scaled and encoded on a
    /// background queue; `done` runs on the main queue.
    static func encode(pixelBuffer: CVPixelBuffer, fullQuality: Bool, done: @escaping (Data?) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let data: Data? = jpeg(pixelBuffer: pixelBuffer, fullQuality: fullQuality)
            DispatchQueue.main.async { done(data) }
        }
    }

    static func jpeg(pixelBuffer: CVPixelBuffer, fullQuality: Bool) -> Data? {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let srcW: CGFloat = image.extent.width
        guard srcW > 0, image.extent.height > 0 else { return nil }
        let s: CGFloat = min(1, CGFloat(targetWidth(fullQuality: fullQuality)) / srcW)
        let scaled: CIImage = image.transformed(by: CGAffineTransform(scaleX: s, y: s))
        guard let cg = ciContext.createCGImage(scaled, from: scaled.extent.integral) else { return nil }
        return jpeg(cg, fullQuality: fullQuality)
    }

    /// The frame drawn at the target width (height by the frame's aspect), then JPEG.
    static func jpeg(_ image: CGImage, fullQuality: Bool) -> Data? {
        guard image.width > 0, image.height > 0 else { return nil }
        let w: Int = min(targetWidth(fullQuality: fullQuality), image.width)
        let h: Int = max(1, Int((Double(image.height) * Double(w) / Double(image.width)).rounded()))
        let info: UInt32 = CGImageAlphaInfo.noneSkipLast.rawValue
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let small = ctx.makeImage() else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out as CFMutableData, "public.jpeg" as CFString, 1, nil) else { return nil }
        let quality: Double = fullQuality ? fullJpegQuality : thumbJpegQuality
        let props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(dest, small, props as CFDictionary)
        guard CGImageDestinationFinalize(dest), out.length > 0 else { return nil }
        return out as Data
    }

    /// mpv.rs mpv_screenshot_data_url (screenshot-sw=yes, screenshot-high-bit-depth=no, "video":
    /// the decoded frame without subtitles or OSD), through libmpv's `screenshot-raw` so no file is
    /// written: bgr0 rows, drawn straight from mpv's buffer into the small context before the node
    /// is freed. Runs on the player's mpv queue (MPVPlayerController.grabFrame), which is serial
    /// with the handle's destroy.
    static func mpvFrame(_ handle: OpaquePointer, fullQuality: Bool) -> Data? {
        mpv_set_property_string(handle, "screenshot-sw", "yes")
        mpv_set_property_string(handle, "screenshot-high-bit-depth", "no")
        let words: [String] = ["screenshot-raw", "video"]
        var cargs: [UnsafePointer<CChar>?] = words.map { UnsafePointer(strdup($0)) }
        cargs.append(nil)
        defer { cargs.forEach { free(UnsafeMutablePointer(mutating: $0)) } }
        var result = mpv_node()
        guard mpv_command_ret(handle, &cargs, &result) >= 0 else { return nil }
        defer { mpv_free_node_contents(&result) }
        guard result.format == MPV_FORMAT_NODE_MAP, let list = result.u.list,
              let keys = list.pointee.keys, let values = list.pointee.values else { return nil }
        var width = 0
        var height = 0
        var stride = 0
        var format = "bgr0"
        var bytes: UnsafeMutableRawPointer?
        var size = 0
        let count = Int(list.pointee.num)
        for i in 0..<count {
            guard let keyPtr = keys[i] else { continue }
            let key = String(cString: keyPtr)
            let value: mpv_node = values[i]
            switch key {
            case "w":
                if value.format == MPV_FORMAT_INT64 { width = Int(value.u.int64) }
            case "h":
                if value.format == MPV_FORMAT_INT64 { height = Int(value.u.int64) }
            case "stride":
                if value.format == MPV_FORMAT_INT64 { stride = Int(value.u.int64) }
            case "format":
                if value.format == MPV_FORMAT_STRING, let s = value.u.string { format = String(cString: s) }
            case "data":
                if value.format == MPV_FORMAT_BYTE_ARRAY, let ba = value.u.ba {
                    bytes = ba.pointee.data
                    size = Int(ba.pointee.size)
                }
            default:
                break
            }
        }
        guard let base = bytes, width > 0, height > 0, stride >= width * 4, size >= stride * height else { return nil }
        // bgr0 / bgra: B, G, R, X in memory (32-bit little-endian XRGB); rgb0 / rgba the other way.
        let info: UInt32
        switch format {
        case "bgr0", "bgra":
            info = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue
        case "rgb0", "rgba":
            info = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.noneSkipLast.rawValue
        default:
            return nil
        }
        guard let provider = CGDataProvider(dataInfo: nil, data: UnsafeRawPointer(base), size: stride * height,
                                            releaseData: { _, _, _ in }) else { return nil }
        guard let frame = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: stride,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: info),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return nil }
        return jpeg(frame, fullQuality: fullQuality)
    }
}

/// use-exit-snapshot.ts useExitSnapshot for one PlayerScreen. While the video plays, a frame is
/// taken WARM_MS (4 s) in and then checked every CACHE_MS (60 s), refreshed when the last one is
/// older than REFRESH_MS (5 min), and kept as the last good frame (saved at once, as upstream's
/// tick persists). On the way out (captureOnExit) a fresh frame is taken and saved, or the last
/// good one when there is no picture to take (no position, near the end, a dead stream).
/// Upstream awaits the exit grab for up to EXIT_GRAB_MS / GRAB_FULL_MS before it closes; the TV
/// never holds the close for it: the grab starts at once (before the engine is torn down) and is
/// scaled, encoded and written off the main thread whenever it lands.
/// A plain class held in @State (like PlayerClock); every method runs on the main actor.
final class ExitSnapshotter {
    static let cacheS: Double = 60
    static let refreshS: Double = 300
    static let warmS: Double = 4
    /// use-exit-snapshot END_RATIO: from 92 % on the frame is the credits, not the spot.
    static let endRatio = 0.92

    private var lastGood: (jpeg: Data, id: String)?
    private var lastGrabAt = Date.distantPast
    private var capturedKey: String?
    private var nextCheck: Date?
    private var grabbing = false

    /// use-exit-snapshot snapshotId: no frame for a live channel; the id is lib/stremio cloudWriteId
    /// (a tt id as is, an anime catalogue id as is, a verified IMDb id for another id), else the
    /// meta id: the id the Continue Watching entry is kept under.
    static func snapshotId(metaId: String, imdbId: String?, verified: Bool) -> String? {
        guard !metaId.isEmpty, !metaId.hasPrefix("iptv:") else { return nil }
        if metaId.hasPrefix("tt") { return metaId }
        let anime: Bool = ["kitsu:", "mal:", "anilist:", "anidb:"].contains { metaId.hasPrefix($0) }
        if !anime, verified, let r = imdbId, r.hasPrefix("tt") { return r }
        return metaId
    }

    static func nearEnd(_ cur: Double, _ dur: Double) -> Bool {
        dur > 0 && cur >= dur * endRatio
    }

    /// use-exit-snapshot's playing effect (status "playing" and snapshots on), on the player's 1 s tick.
    @MainActor
    func tick(controller: (any PlayerEngineControlling)?, context: PlaybackContext?, playing: Bool, position: Double, duration: Double) {
        let settings = ExitSnapshotSettings.current
        guard playing, settings.days > 0, let c = controller, let context else {
            nextCheck = nil
            return
        }
        // (review 23) mpv's screenshot-raw copies the frame off the decoder and converts it in
        // software on the core thread (tens to hundreds of ms on 4K HDR), which can drop frames
        // mid-play. The periodic grab is AVPlayer's only; mpv takes its frame on exit, when the
        // player is closing anyway.
        guard c.engineKind == .native else {
            nextCheck = nil
            return
        }
        let now = Date()
        guard let due = nextCheck else {
            nextCheck = now.addingTimeInterval(Self.warmS)
            return
        }
        guard now >= due else { return }
        nextCheck = now.addingTimeInterval(Self.cacheS)
        guard !grabbing, let id = Self.snapshotId(metaId: context.meta.id, imdbId: context.imdbId, verified: context.imdbVerified) else { return }
        if let good = lastGood, good.id == id, now.timeIntervalSince(lastGrabAt) < Self.refreshS { return }
        guard position.isFinite, position > 0, !Self.nearEnd(position, duration) else { return }
        grabbing = true
        let days: Int = settings.days
        c.grabFrame(fullQuality: settings.full) { [weak self] img in
            guard let self else { return }
            self.grabbing = false
            guard let img else { return }
            self.lastGrabAt = Date()
            self.lastGood = (img, id)
            ExitSnapshotStore.persist(id: id, jpeg: img, retentionDays: days)
        }
    }

    /// use-exit-snapshot captureExitSnapshot (use-player-exit.ts closePlayer runs it first). Once per
    /// title and whole second; the save is never waited on.
    @MainActor
    func captureOnExit(controller: (any PlayerEngineControlling)?, context: PlaybackContext?, position: Double, duration: Double) {
        let settings = ExitSnapshotSettings.current
        guard settings.days > 0 else { return }
        let days: Int = settings.days
        guard let context, let id = Self.snapshotId(metaId: context.meta.id, imdbId: context.imdbId, verified: context.imdbVerified) else {
            persistLastGood(days)
            return
        }
        guard position.isFinite, position > 0 else {
            persistLastGood(days)
            return
        }
        var ep = ""
        if let s = context.season, let e = context.episode { ep = ":\(s):\(e)" }
        let key = "\(context.meta.id)\(ep)|\(clampedInt(position.rounded()))"
        if capturedKey == key { return }
        capturedKey = key
        guard !Self.nearEnd(position, duration), let c = controller else {
            persistLastGood(days)
            return
        }
        c.grabFrame(fullQuality: settings.full) { img in
            if let img { self.lastGood = (img, id) }
            self.persistLastGood(days)
        }
    }

    @MainActor
    private func persistLastGood(_ days: Int) {
        guard let good = lastGood else { return }
        ExitSnapshotStore.persist(id: good.id, jpeg: good.jpeg, retentionDays: days)
    }
}
