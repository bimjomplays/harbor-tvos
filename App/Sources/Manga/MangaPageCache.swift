import SwiftUI
import UIKit
import ImageIO

/// The reader's page loader (manga-reader/page-image.tsx), kept apart from the poster cache so a
/// chapter can never crowd posters out, and bounded so tvOS never kills the app for memory:
/// pages are decoded straight to the size they are drawn at (ImageIO thumbnails, never the full
/// bitmap), at most ~8 megapixels each, and the decoded cache holds only a few screens' worth.
/// The raw bytes sit in a purgeable disk URLCache, so paging back is a decode, not a download.
actor MangaPageCache {
    static let shared = MangaPageCache()

    private let session: URLSession
    private let memory = NSCache<NSString, UIImage>()
    private var inflight: [String: Task<UIImage?, Never>] = [:]
    /// Pixel size per URL, read from the file header (reader-utils measureAspect).
    private var sizes: [String: CGSize] = [:]

    /// Largest decoded page, in pixels (a 1500 × 5300 webtoon strip piece, or a spread page at 2×).
    private static let maxPixels: CGFloat = 8_000_000

    init() {
        let cfg = URLSessionConfiguration.default
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("harbor-manga")
        cfg.urlCache = URLCache(memoryCapacity: 8 << 20, diskCapacity: 300 << 20, directory: dir)
        cfg.requestCachePolicy = .returnCacheDataElseLoad
        cfg.httpMaximumConnectionsPerHost = 4
        cfg.timeoutIntervalForRequest = 30
        session = URLSession(configuration: cfg)
        memory.countLimit = 16
        memory.totalCostLimit = 160 << 20
    }

    private func data(_ page: MangaPage) async -> Data? {
        guard let url = URL(string: page.url) else { return nil }
        var request = URLRequest(url: url)
        for (k, v) in page.headers ?? [:] { request.setValue(v, forHTTPHeaderField: k) }
        if request.value(forHTTPHeaderField: "Authorization") == nil, let auth = ImageAuth.shared.header(for: page.url) {
            request.setValue(auth, forHTTPHeaderField: "Authorization")
        }
        guard let (data, resp) = try? await session.data(for: request),
              (resp as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true else { return nil }
        return data
    }

    /// The page decoded no wider than `maxWidth` pixels (and within the pixel budget).
    func image(_ page: MangaPage, maxWidth: CGFloat) async -> UIImage? {
        let bucket = Int((maxWidth / 128).rounded(.up)) * 128
        let key = "\(bucket)|\(page.url)"
        if let hit = memory.object(forKey: key as NSString) { return hit }
        if let task = inflight[key] { return await task.value }
        let task = Task<UIImage?, Never> { [weak self] in
            guard let self, let bytes = await self.data(page) else { return nil }
            return await self.decode(bytes, url: page.url, maxWidth: CGFloat(bucket))
        }
        inflight[key] = task
        let img = await task.value
        inflight[key] = nil
        if let img {
            let px = img.size.width * img.scale * img.size.height * img.scale
            memory.setObject(img, forKey: key as NSString, cost: Int(px * 4))
        }
        return img
    }

    private func decode(_ bytes: Data, url: String, maxWidth: CGFloat) -> UIImage? {
        guard let src = CGImageSourceCreateWithData(bytes as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let w = (props?[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue ?? 0
        let h = (props?[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue ?? 0
        if w > 0, h > 0 { sizes[url] = CGSize(width: w, height: h) }
        var scale: CGFloat = 1
        if w > 0, h > 0 {
            scale = min(1, maxWidth / CGFloat(w), (Self.maxPixels / CGFloat(w * h)).squareRoot())
        }
        let longest = max(w, h) * Double(scale)
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, Int(longest.rounded())),
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return UIImage(data: bytes) }
        return UIImage(cgImage: cg)
    }

    /// reader-utils measureAspect: height / width from the file header, without decoding pixels.
    func aspect(_ page: MangaPage) async -> Double? {
        if let s = sizes[page.url], s.width > 0 { return Double(s.height / s.width) }
        guard let bytes = await data(page),
              let src = CGImageSourceCreateWithData(bytes as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue, w > 0 else { return nil }
        sizes[page.url] = CGSize(width: w, height: h)
        return h / w
    }

    /// reader-utils detectWebtoon: the first and middle pages; a tall strip (≥ 2.2) reads as long.
    func detectWebtoon(_ pages: [MangaPage]) async -> Bool {
        guard !pages.isEmpty else { return false }
        let samples = [pages[0], pages[pages.count / 2]]
        var tallest = 0.0
        for p in samples { tallest = max(tallest, await aspect(p) ?? 1.4) }
        return tallest >= 2.2
    }

    /// The decode width for a page drawn `drawn` points wide: up to 1.5× for a sharper zoom.
    /// MangaPageImage and the prefetch share it so a warmed page is the one the view asks for.
    static func decodeWidth(_ drawn: CGFloat) -> CGFloat { min(2400, drawn * 1.5) }

    /// Warm the next pages, each at the width it is drawn at: bytes into the disk cache and a
    /// decode into memory. Stops between pages once the warm-up is cancelled.
    func prefetch(_ jobs: [(page: MangaPage, width: CGFloat)]) async {
        for job in jobs {
            if Task.isCancelled { return }
            _ = await image(job.page, maxWidth: Self.decodeWidth(job.width))
        }
    }

    /// The reader closed: drop every decoded page (the disk cache stays for next time).
    func purge() {
        memory.removeAllObjects()
        sizes.removeAll()
    }

    /// (perf/memory pass) A memory warning: drop the decoded pages (up to 160 MB) but keep the
    /// measured sizes, so an open reader's layout does not move. Pages on screen stay drawn.
    func purgeDecoded() {
        memory.removeAllObjects()
    }
}

/// One reader page (page-image.tsx): the loading plate until the bytes arrive, a retry on failure.
/// Reports the page's aspect (height / width) once known so the long strip can lay itself out.
struct MangaPageImage: View {
    let page: MangaPage
    /// Width in points the page is drawn at; decoded at up to 1.5× for a sharper zoom.
    let width: CGFloat
    var onAspect: ((Double) -> Void)? = nil
    @State private var image: UIImage?
    @State private var failed = false
    @State private var attempt = 0

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
            } else if failed {
                VStack(spacing: BP.px(6)) {
                    Image(systemName: "exclamationmark.triangle").font(.system(size: BP.px(20))).accessibilityHidden(true)
                    Text("Page failed to load").font(BP.sans(13, .semibold))
                }
                .foregroundStyle(BP.inkSubtle)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView().tint(BP.inkMuted).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: "\(page.url)|\(Int(width))|\(attempt)") {
            failed = false
            let img = await MangaPageCache.shared.image(page, maxWidth: MangaPageCache.decodeWidth(width))
            guard !Task.isCancelled else { return }
            image = img
            failed = img == nil
            if let img, img.size.width > 0 { onAspect?(Double(img.size.height / img.size.width)) }
        }
    }
}
