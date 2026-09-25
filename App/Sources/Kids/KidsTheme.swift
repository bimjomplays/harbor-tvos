import SwiftUI
import UIKit

/// index.css `[data-kids="on"]`: the light sea palette every kids surface paints with, plus the
/// literal colours the kids views use (kids.tsx, kids-detail.tsx, play-zone.tsx).
enum KidsTheme {
    static let canvas = Color(hex: 0xb6dee4)
    static let surface = Color(hex: 0xc6e8ed)
    static let elevated = Color(hex: 0xd6f0f3)
    static let raised = Color(hex: 0xe9f7f9)
    /// oklch(0.4 0.07 205), oklch(0.52 0.06 205), oklch(0.63 0.045 205) in sRGB.
    static let ink = Color(hex: 0x00525a)
    static let inkMuted = Color(hex: 0x3b7379)
    static let inkSubtle = Color(hex: 0x699196)
    /// `text-[#0e3a43]`: row titles, chips, episode names.
    static let deep = Color(hex: 0x0e3a43)
    /// `bg-[#1f8f88]`: the kids Play button and the chosen season.
    static let teal = Color(hex: 0x1f8f88)
    /// `bg-[#ffd166]` / `text-[#4a3200]`: "Let's play!", "Another one!", the active filter.
    static let sunny = Color(hex: 0xffd166)
    static let sunnyInk = Color(hex: 0x4a3200)
    /// Play Zone copy on white cards.
    static let sea = Color(hex: 0x123a52)
    static let seaMuted = Color(hex: 0x3c6a84)
    /// `[data-kids="on"] [data-harbor-sidebar]`: the kids chrome background.
    static let bar = Color(hex: 0xe5f5f5)
    /// `.harbor-mark-sail` / `.harbor-mark-hull` under kids.
    static let sail = Color(hex: 0x6bc5ca)

    /// Upstream sets kids type in "Fredoka", "Baloo 2"; SF Rounded is the nearest face on tvOS.
    static func font(_ px: CGFloat, _ weight: Font.Weight = .bold) -> Font {
        .system(size: BP.px(px), weight: weight, design: .rounded)
    }

    /// The kids card shadow (`shadow-[0_16px_40px_-14px_rgba(20,40,60,0.45)]`).
    static let shadow = Color(red: 20 / 255, green: 40 / 255, blue: 60 / 255)

    private static let cache = NSCache<NSString, UIImage>()

    /// Upstream's `/kids/...` public art, bundled from App/Upstream/kids by
    /// tools/sync_upstream_assets.sh (the folder lands at the bundle root as `kids/`).
    static func art(_ path: String) -> UIImage? {
        let rel = path.hasPrefix("/") ? String(path.dropFirst()) : path
        if let hit = cache.object(forKey: rel as NSString) { return hit }
        let url = Bundle.main.bundleURL.appendingPathComponent(rel)
        guard let img = UIImage(contentsOfFile: url.path) else { return nil }
        cache.setObject(img, forKey: rel as NSString)
        return img
    }

    /// `/kids/doodles/<name>.png`.
    static func doodle(_ name: String) -> UIImage? { art("/kids/doodles/\(name).png") }
}

/// A bundled kids image, aspect-fit; nothing when the art is missing (a build without assets).
struct KidsArt: View {
    let image: UIImage?
    var contentMode: ContentMode = .fit

    init(_ path: String, contentMode: ContentMode = .fit) {
        self.image = KidsTheme.art(path)
        self.contentMode = contentMode
    }

    init(doodle name: String) {
        self.image = KidsTheme.doodle(name)
    }

    var body: some View {
        if let image {
            Image(uiImage: image).resizable().aspectRatio(contentMode: contentMode).accessibilityHidden(true)
        } else {
            Color.clear
        }
    }
}

/// A kids card button: white ring always, lifts forward with a sunny ring and a deeper shadow on
/// focus (upstream's `ring-2 ring-white` + `hover:-translate-y-1.5 hover:shadow-[…]`).
struct KidsCardStyle: ButtonStyle {
    var radius: CGFloat = BP.px(22)
    var ring: CGFloat = BP.px(2)
    var onFocus: (() -> Void)? = nil
    func makeBody(configuration: Configuration) -> some View {
        BPFocusReader(onFocus: onFocus) { focused in
            configuration.label
                .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(focused ? KidsTheme.sunny : .white, lineWidth: focused ? ring + 3 : ring))
                .shadow(color: KidsTheme.shadow.opacity(focused ? 0.55 : 0.4), radius: focused ? 24 : 14, y: focused ? 20 : 12)
                .scaleEffect(focused ? (configuration.isPressed ? 1.04 : 1.07) : 1)
                .offset(y: focused ? -BP.px(6) : 0)
                .animation(BP.ease, value: focused)
                .animation(.timingCurve(0.5, 0, 0.75, 0, duration: 0.09), value: configuration.isPressed)
        }
    }
}

/// A rounded kids pill (Back, Shuffle, filters, season chips): its own fill, a ring on focus.
struct KidsPillStyle: ButtonStyle {
    var fill: Color = .white.opacity(0.9)
    var focusedFill: Color? = nil
    var ink: Color = KidsTheme.sea
    var height: CGFloat = BP.px(46)
    func makeBody(configuration: Configuration) -> some View {
        BPFocusReader { focused in
            configuration.label
                .font(KidsTheme.font(16, .bold))
                .foregroundStyle(ink)
                .padding(.horizontal, BP.px(22))
                .frame(minHeight: height)
                .background(Capsule().fill(focused ? (focusedFill ?? fill) : fill))
                .overlay(Capsule().stroke(focused ? KidsTheme.sunny : .white.opacity(0.4), lineWidth: focused ? 5 : 3))
                .shadow(color: KidsTheme.shadow.opacity(focused ? 0.5 : 0.25), radius: focused ? 18 : 10, y: focused ? 12 : 6)
                .scaleEffect(focused ? (configuration.isPressed ? 1.0 : 1.05) : 1)
                .animation(BP.easeFast, value: focused)
        }
    }
}
