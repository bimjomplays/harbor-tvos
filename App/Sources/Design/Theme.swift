import SwiftUI

/// Big Picture design tokens (docs/big-picture-design.md). Upstream lays out on a 1140×641 CSS
/// canvas; tvOS lays out on 1920×1080 points, so every px value is scaled by `BP.k`.
enum BP {
    static let k: CGFloat = 1920.0 / 1140.0
    static func px(_ v: CGFloat) -> CGFloat { (v * k).rounded() }

    // Base theme "Harbor default" (cool-grey), theme.ts:124-143.
    static let canvas = Color(hex: 0x111213)
    static let surface = Color(hex: 0x191b1c)
    static let elevated = Color(hex: 0x252628)
    static let raised = Color(hex: 0x323335)
    static let ink = Color(hex: 0xf4f5f7)
    static let inkMuted = Color(hex: 0xa3a5a6)
    static let inkSubtle = Color(hex: 0x626365)
    static let accent = Color(hex: 0xf4a25c)
    static let danger = Color(hex: 0xc53637)
    static let live = Color(hex: 0x4ade80)

    // --bp-* derivations (bp-tokens.ts:1-18), resolved for the default theme.
    static let void_ = Color(hex: 0x0d0e0f)
    static let panel = Color(hex: 0x161819)
    static let panel2 = Color(hex: 0x222325)
    static let on = Color(hex: 0x404142)
    static let glass = ink.opacity(0.07)
    static let edge = ink.opacity(0.11)
    static let edge2 = ink.opacity(0.18)
    static let focusStroke = ink.opacity(0.86)

    // Radii (bp-tokens.ts:37-40).
    static let rXS = px(8), rSM = px(10), rMD = px(16), rLG = px(24)

    // Layout (bp-tokens.ts:51-94), resolved at the 1140 canvas.
    static let gutter = px(85.5)
    static let barHeight = px(72)
    static let hintHeight = px(52)
    static let rowGap = px(20)
    static let trackGap = px(21)
    static let tabItem = px(44)

    // Motion (bp-tokens.ts:42-46, 127-150).
    static let focusLift: CGFloat = 1.03
    static let press: CGFloat = 0.965
    static let ease = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.19).delay(0.07)
    static let easeFast = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.16)
    static let easeSlow = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.42)

    // Type (Switzer for UI, Sentient for hero-scale titles, Fraunces for the wordmark).
    static func sans(_ px: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        let name: String
        switch weight {
        case .bold, .heavy, .black: name = "Switzer-Bold"
        case .semibold: name = "Switzer-Semibold"
        case .medium: name = "Switzer-Medium"
        default: name = "Switzer-Regular"
        }
        return .custom(name, size: Self.px(px))
    }
    static func display(_ px: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        let name = weight == .regular ? "Sentient-Regular" : (weight == .bold ? "Sentient-Bold" : "Sentient-Medium")
        return .custom(name, size: Self.px(px))
    }
    static func wordmark(_ px: CGFloat) -> Font { .custom("Fraunces-Medium", size: Self.px(px)) }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xff) / 255, green: Double((hex >> 8) & 0xff) / 255,
                  blue: Double(hex & 0xff) / 255, opacity: alpha)
    }
    /// Parses "#rrggbb" (profile colors come over the wire as CSS hex).
    init?(css: String) {
        var s = css.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(hex: v)
    }
}

/// The page background: void with the brand-tinted wash upstream paints in the top corner.
struct BPAmbientBackground: View {
    var body: some View {
        ZStack {
            BP.void_
            RadialGradient(colors: [BP.accent.opacity(0.10), .clear], center: .topTrailing, startRadius: 0, endRadius: 1300)
            LinearGradient(colors: [BP.canvas.opacity(0.9), .clear], startPoint: .bottom, endPoint: .center)
        }
        .ignoresSafeArea()
    }
}
