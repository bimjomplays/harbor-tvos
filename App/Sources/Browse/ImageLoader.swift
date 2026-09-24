import SwiftUI
import UIKit

/// Poster/backdrop loading with a memory cache on top of URLCache in the Caches folder.
/// Both are purgeable; a miss only costs a refetch.
actor ImageLoader {
    static let shared = ImageLoader()

    private let session: URLSession
    private let memory = NSCache<NSString, UIImage>()
    private var inflight: [String: Task<UIImage?, Never>] = [:]

    init() {
        let cfg = URLSessionConfiguration.default
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("harbor-images")
        cfg.urlCache = URLCache(memoryCapacity: 32 << 20, diskCapacity: 400 << 20, directory: dir)
        cfg.requestCachePolicy = .returnCacheDataElseLoad
        cfg.httpMaximumConnectionsPerHost = 6
        cfg.timeoutIntervalForRequest = 15
        session = URLSession(configuration: cfg)
        memory.countLimit = 600
        memory.totalCostLimit = 200 << 20
    }

    func image(for url: URL) async -> UIImage? {
        let key = url.absoluteString as NSString
        if let hit = memory.object(forKey: key) { return hit }
        if let task = inflight[url.absoluteString] { return await task.value }
        let task = Task<UIImage?, Never> {
            // Manga covers live on the viewer's own Suwayomi server, which may ask for Basic auth.
            var request = URLRequest(url: url)
            if let auth = ImageAuth.shared.header(for: url.absoluteString) { request.setValue(auth, forHTTPHeaderField: "Authorization") }
            guard let (data, resp) = try? await session.data(for: request),
                  (resp as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
                  let img = UIImage(data: data) else { return nil }
            return img
        }
        inflight[url.absoluteString] = task
        let img = await task.value
        inflight[url.absoluteString] = nil
        if let img { memory.setObject(img, forKey: key, cost: Int(img.size.width * img.size.height * 4)) }
        return img
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
struct RemoteImage: View {
    let url: String?
    var contentMode: ContentMode = .fill
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            BP.ink.opacity(0.07)
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: contentMode).transition(.opacity)
            }
        }
        .task(id: url) {
            image = nil; failed = false
            guard let url, let u = URL(string: url) else { return }
            let img = await ImageLoader.shared.image(for: u)
            withAnimation(BP.easeFast) { image = img }
            failed = img == nil
        }
    }
}
