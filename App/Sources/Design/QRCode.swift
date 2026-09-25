import UIKit
import CoreImage.CIFilterBuiltins

/// A QR code for a link the viewer finishes on a phone (decision 7: logins, long text and anything
/// tvOS cannot open happen on the phone).
enum QRCode {
    /// (perf pass 5) One Core Image context for every code. `CIContext()` sets up a Metal device,
    /// command queue and caches each time it is made (tens of milliseconds on an Apple TV HD), and
    /// most callers ask from a view body (the Watch Together room re-renders on every room event,
    /// up to ~6 a second while cursors move), so each redraw paid for a new context. CIContext is
    /// thread-safe.
    private static let context = CIContext(options: [CIContextOption.cacheIntermediates: false])
    /// (perf pass 5) The finished image per text and scale: the same link asked again from a body
    /// is a lookup, not a new filter pass and CGImage. A few dozen small bitmaps at most.
    private static let cache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 24
        return c
    }()

    static func image(_ text: String, scale: CGFloat = 8) -> UIImage? {
        let key = "\(scale)|\(text)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let out = filter.outputImage else { return nil }
        let scaled = out.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cg = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        let image = UIImage(cgImage: cg)
        cache.setObject(image, forKey: key)
        return image
    }
}
