import SwiftUI
import UIKit
import ImageIO

/// Poster/backdrop loading with a memory cache on top of URLCache in the Caches folder.
/// Both are purgeable; a miss only costs a refetch.
///
/// (bug pass 2) Images are decoded downsampled (ImageIO thumbnails) to the size they are drawn at,
/// or to a 1920 px long edge when the caller gives no size: a full-size 4K backdrop is ~33 MB
/// decoded and Apple TV HD has 2 GB of RAM for everything. The decode happens here, off the main
/// thread, instead of lazily at first draw.
actor ImageLoader {
    static let shared = ImageLoader()

    /// The pixel box an image is drawn in; `fit` for `.fit` content, else `.fill`.
    struct Target: Hashable, Sendable {
        var width: Int
        var height: Int
        var fit: Bool = false
    }

    /// Long edge for callers that give no size (a full-screen backdrop on a 1080p screen).
    static let defaultMaxPixel = 1920
    /// Long edge a sized request can reach (a full-screen backdrop at 2x on Apple TV 4K).
    static let sizedMaxPixel = 3840

    private let session: URLSession
    private let urlCache: URLCache
    private let memory = NSCache<NSString, UIImage>()
    /// (perf/memory pass) One fetch + decode per key, shared by every caller asking for it.
    /// `waiters` counts the callers still waiting; when the last one is cancelled (its RemoteImage
    /// scrolled off screen, or its URL or size changed) the download and decode are cancelled too.
    /// They used to run to the end regardless, so a fast scroll through a long grid queued every
    /// poster it passed (6 downloads per host at a time) ahead of the ones actually on screen.
    private struct Flight {
        let id: Int
        let task: Task<UIImage?, Never>
        var waiters: Int
    }
    private var inflight: [String: Flight] = [:]
    private var nextFlight = 0
    private static let urlCacheMemory = 32 << 20

    init() {
        let cfg = URLSessionConfiguration.default
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("harbor-images")
        let cache = URLCache(memoryCapacity: Self.urlCacheMemory, diskCapacity: 400 << 20, directory: dir)
        urlCache = cache
        cfg.urlCache = cache
        cfg.requestCachePolicy = .returnCacheDataElseLoad
        cfg.httpMaximumConnectionsPerHost = 6
        cfg.timeoutIntervalForRequest = 15
        session = URLSession(configuration: cfg)
        memory.countLimit = 600
        // (bug pass 2) 1/16 of the device's RAM, 48...160 MB (128 MB on a 2 GB Apple TV HD).
        let ram = ProcessInfo.processInfo.physicalMemory
        memory.totalCostLimit = Int(min(UInt64(160 << 20), max(UInt64(48 << 20), ram / 16)))
    }

    func image(for url: URL, target: Target? = nil) async -> UIImage? {
        let raw = url.absoluteString
        let keyString = target.map { "\(raw)#\($0.width)x\($0.height)\($0.fit ? "f" : "c")" } ?? raw
        let key = keyString as NSString
        if let hit = memory.object(forKey: key) { return hit }
        // A caller that is already cancelled (a cell that scrolled past) starts nothing.
        if Task.isCancelled { return nil }
        let flight: Flight
        if var joined = inflight[keyString] {
            joined.waiters += 1
            inflight[keyString] = joined
            flight = joined
        } else {
            // Manga covers live on the viewer's own Suwayomi server, which may ask for Basic auth.
            var request = URLRequest(url: url)
            if let auth = ImageAuth.shared.header(for: raw) { request.setValue(auth, forHTTPHeaderField: "Authorization") }
            let session = self.session, req = request
            // Detached: fetches and decodes run side by side, not one at a time on this actor.
            let task = Task<UIImage?, Never>.detached(priority: .userInitiated) {
                guard let (data, resp) = try? await session.data(for: req),
                      (resp as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true else { return nil }
                if Task.isCancelled { return nil }
                return ImageLoader.decode(data, target: target)
            }
            nextFlight += 1
            flight = Flight(id: nextFlight, task: task, waiters: 1)
            inflight[keyString] = flight
        }
        let flightId: Int = flight.id
        let task: Task<UIImage?, Never> = flight.task
        let img: UIImage? = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            Task { await self.leave(keyString, flightId: flightId) }
        }
        // The first caller back finishes the flight: it caches the bitmap and clears the entry.
        if inflight[keyString]?.id == flightId {
            inflight[keyString] = nil
            if let img { memory.setObject(img, forKey: key, cost: Self.cost(of: img)) }
        }
        return img
    }

    /// A caller stopped waiting (its task was cancelled); the last one out cancels the fetch.
    private func leave(_ keyString: String, flightId: Int) {
        guard var flight = inflight[keyString], flight.id == flightId else { return }
        flight.waiters -= 1
        if flight.waiters > 0 {
            inflight[keyString] = flight
            return
        }
        inflight[keyString] = nil
        flight.task.cancel()
    }

    /// (perf/memory pass) On a memory warning: drop every decoded bitmap and the URL cache's RAM
    /// copy. The files on disk stay, so art shown again is a decode, not a download, and views keep
    /// the images they are drawing (only the cache lets go of its references).
    func purgeMemory() {
        memory.removeAllObjects()
        urlCache.memoryCapacity = 0
        urlCache.memoryCapacity = Self.urlCacheMemory
    }

    /// (review 21) Poster-service urls (RemoteImage `url` with a `fallback`) that failed while their
    /// fallback loaded. A failed load is never cached, so with a bad or rate-limited RPDB key every
    /// poster tile scrolled back into view asked RPDB again and sat on the bare plate for that round
    /// trip before its plain poster came back: the art blinked on every return. Session only, bounded.
    private var deadPrimaries = Set<String>()

    func isDead(_ raw: String) -> Bool { deadPrimaries.contains(raw) }

    func markDead(_ raw: String) {
        if deadPrimaries.count >= 4096 { deadPrimaries.removeAll() }
        deadPrimaries.insert(raw)
    }

    /// Decoded bytes of the bitmap (what the cache limit is about).
    private static func cost(of img: UIImage) -> Int {
        if let cg = img.cgImage { return cg.bytesPerRow * cg.height }
        return Int(img.size.width * img.scale * img.size.height * img.scale * 4)
    }

    /// Decode `data` no larger than needed: for a target box, the size at which the image covers
    /// (fill) or fits (fit) that box; never above the caps, never upscaled (ImageIO thumbnails
    /// only shrink).
    static func decode(_ data: Data, target: Target?) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions), CGImageSourceGetCount(source) > 0 else {
            return UIImage(data: data)
        }
        var maxPixel = defaultMaxPixel
        if let target, target.width > 0, target.height > 0,
           let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           var w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
           var h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue, w > 0, h > 0 {
            // EXIF orientations 5-8 are a quarter turn: the drawn width is the stored height.
            if let o = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue, (5...8).contains(o) { swap(&w, &h) }
            let sx = Double(target.width) / w, sy = Double(target.height) / h
            let s = target.fit ? min(sx, sy) : max(sx, sy)
            let edge = (max(w, h) * s).rounded(.up)
            maxPixel = edge.isFinite ? min(sizedMaxPixel, max(1, Int(edge))) : defaultMaxPixel
        }
        let thumbOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) else {
            return UIImage(data: data)
        }
        return UIImage(cgImage: cg)
    }
}

/// lib/img-size.ts for poster cards (components/poster.tsx): a TMDB image is asked for at the
/// smallest tier that covers the card at the screen's scale (capped at 2, as poster.tsx caps
/// devicePixelRatio) times qualityMultiplier(settings.posterQuality); "max" keeps the URL as the
/// catalog gave it. Google and Deezer artwork sizes are rewritten the same way (upgradeArtworkUrl).
enum PosterSizing {
    private static let tmdbTiers = [92, 154, 185, 300, 342, 500, 780, 1280]

    /// img-size.ts qualityMultiplier: max → 0 (no resizing), high → 1.5, balanced → 1.
    static func multiplier(_ quality: String?) -> Double {
        switch quality ?? "high" {
        case "max": return 0
        case "high": return 1.5
        default: return 1
        }
    }

    static func sized(_ url: String?, width: CGFloat, scale: CGFloat, quality: String?) -> String? {
        guard let url, !url.isEmpty else { return url }
        let mult = multiplier(quality)
        guard mult > 0, width > 0 else { return url }
        let target = Int((Double(width) * Double(min(2, max(1, scale))) * mult).rounded(.up))
        return sizeImageUrl(url, target)
    }

    /// img-size.ts sizeImageUrl.
    static func sizeImageUrl(_ url: String, _ targetPx: Int) -> String {
        guard targetPx > 0 else { return url }
        let seg = tmdbTiers.first { $0 >= targetPx }.map { "w\($0)" } ?? "original"
        if let r = url.range(of: #"/t/p/(w\d+|original)/"#, options: .regularExpression) {
            let sized = url.replacingCharacters(in: r, with: "/t/p/\(seg)/")
            if sized != url { return sized }
        }
        return upgradeArtworkUrl(url, targetPx)
    }

    /// img-size.ts upgradeArtworkUrl: Google (=wN-hN, up to 1200) and Deezer (/NxN-, up to 1000) art.
    static func upgradeArtworkUrl(_ url: String, _ targetPx: Int) -> String {
        if let r = url.range(of: #"=w\d+-h\d+"#, options: .regularExpression) {
            let size = min(1200, max(targetPx, 1))
            return url.replacingCharacters(in: r, with: "=w\(size)-h\(size)")
        }
        if url.contains("dzcdn.net"), let r = url.range(of: #"/\d+x\d+-"#, options: .regularExpression) {
            let size = min(1000, max(targetPx, 1))
            return url.replacingCharacters(in: r, with: "/\(size)x\(size)-")
        }
        return url
    }
}

/// Art with upstream's loading plate; fades in when the bytes arrive.
/// (bug pass 2) The plate measures itself and asks for the image at that size (ImageLoader.Target).
struct RemoteImage: View {
    let url: String?
    var contentMode: ContentMode = .fill
    /// (parity pass 3, H4) components/poster.tsx usePosterChain onError: when `url` cannot be
    /// loaded, the next candidate (the plain poster behind an RPDB / poster-service url) is shown.
    var fallback: String? = nil
    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?
    @State private var failed = false
    @State private var box: CGSize = .zero
    @State private var shownURL: String?

    private struct LoadKey: Hashable { var url: String?; var fallback: String?; var width: Int; var height: Int }

    /// The box in pixels, rounded up to 64 px steps so small layout changes reuse the cached decode.
    private var loadKey: LoadKey {
        let scale = Double(max(1, displayScale))
        func px(_ v: CGFloat) -> Int {
            let d = Double(v) * scale
            guard d.isFinite, d > 0 else { return 0 }
            return (Int(min(d, 16_384)) / 64 + 1) * 64
        }
        return LoadKey(url: url, fallback: fallback, width: px(box.width), height: px(box.height))
    }

    var body: some View {
        ZStack {
            BP.ink.opacity(0.07)
            if let image {
                // (accessibility pass) Art is decoration: VoiceOver said "image" on every poster and
                // backdrop. A caller that names the picture wraps it in its own labelled element.
                Image(uiImage: image).resizable().aspectRatio(contentMode: contentMode).transition(.opacity)
                    .accessibilityHidden(true)
            }
        }
        .background(GeometryReader { g in
            Color.clear
                .onAppear { box = g.size }
                .onChange(of: g.size) { _, size in box = size }
        })
        .task(id: loadKey) {
            let key = loadKey
            // A new URL clears the old art; a new size keeps it up until the sharper decode lands.
            if shownURL != key.url { image = nil; failed = false; shownURL = key.url }
            // Nothing is asked for until the plate has a size (the first layout pass sets it).
            guard let url = key.url, key.width > 0, key.height > 0 else { return }
            let target = ImageLoader.Target(width: key.width, height: key.height, fit: contentMode == .fit)
            // (review 21) A primary that cannot be a URL (a poster template or key with a stray
            // character) went straight to the empty plate without trying the fallback; one that
            // already failed with its fallback loading is skipped (ImageLoader.deadPrimaries).
            var dead = false
            if key.fallback != nil { dead = await ImageLoader.shared.isDead(url) }
            var img: UIImage?
            if !dead, let u = URL(string: url) { img = await ImageLoader.shared.image(for: u, target: target) }
            guard !Task.isCancelled else { return }
            if img == nil, let next = key.fallback, next != url, let nu = URL(string: next) {
                img = await ImageLoader.shared.image(for: nu, target: target)
                guard !Task.isCancelled else { return }
                if img != nil, !dead { await ImageLoader.shared.markDead(url) }
            }
            if image == nil { withAnimation(BP.easeFast) { image = img } } else if let img { image = img }
            failed = img == nil
        }
    }
}
