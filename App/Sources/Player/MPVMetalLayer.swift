import UIKit

/// MoltenVK briefly sets drawableSize to 1x1 to force presentation; ignoring that stops flicker.
/// https://github.com/mpv-player/mpv/pull/13651
final class MPVMetalLayer: CAMetalLayer {
    override var drawableSize: CGSize {
        get { super.drawableSize }
        set {
            // (bug pass 2) Int(_:) traps on NaN or infinity (a zero-sized or mid-teardown bounds
            // times the scale); compared as floats, `>= 2` is the same test as `Int(x) > 1`.
            let w = newValue.width, h = newValue.height
            if w.isFinite && h.isFinite && w >= 2 && h >= 2 { super.drawableSize = newValue }
        }
    }
}
