import UIKit
import CoreImage.CIFilterBuiltins

/// A QR code for a link the viewer finishes on a phone (decision 7: logins, long text and anything
/// tvOS cannot open happen on the phone).
enum QRCode {
    static func image(_ text: String, scale: CGFloat = 8) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let out = filter.outputImage else { return nil }
        let scaled = out.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cg = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}
