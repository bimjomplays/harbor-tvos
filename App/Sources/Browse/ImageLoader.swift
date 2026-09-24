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
