import SwiftUI

/// Stage 9 themes (lib/theme.ts presets, views/settings/theme-panel.tsx), resolved by the engine
/// (engine/themes.ts `themes.state`) into sRGB tokens, font faces and backgrounds. Applying one
/// writes `settings.theme` the way upstream's ThemeTab does, so it syncs with the profile.
/// No custom CSS/JS/HTML layers: tvOS has no web view to run them in.
@MainActor
final class ThemeStore: ObservableObject {
    static let shared = ThemeStore()

    struct Palette: Decodable, Equatable {
        var canvas, surface, elevated, raised, ink, inkMuted, inkSubtle, accent, danger: [Double]
        var void_, panel, panel2, on: [Double]
        enum CodingKeys: String, CodingKey {
            case canvas, surface, elevated, raised, ink, inkMuted, inkSubtle, accent, danger, panel, panel2, on
            case void_ = "void"
        }
    }
    struct Faces: Decodable, Equatable { var display: String; var sans: String }
    struct Stop: Decodable, Equatable { var color: [Double]; var at: Double }
    /// "linear" carries `angle` (CSS degrees); "radial" carries the ellipse radii and centre as
    /// fractions of the screen (`ellipse rx ry at cx cy`).
    struct Layer: Decodable, Equatable {
        var kind: String
        var angle: Double?
        var rx: Double?, ry: Double?, cx: Double?, cy: Double?
        var stops: [Stop]
    }
    struct Background: Decodable, Equatable { var layers: [Layer]; var imageUrl: String?; var dim: Double; var scrim: Bool }
    struct Preset: Decodable, Identifiable, Equatable {
        var id: String; var name: String; var blurb: String; var category: String
        var swatch: [[Double]]; var canvasLight: Bool
    }
    struct FontPair: Decodable, Identifiable, Equatable { var id: String; var name: String; var blurb: String; var faces: Faces }
    struct Snapshot: Decodable, Equatable {
        var active: String
        var fontPair: String
        var pickedFontPair: String
        var presetOwnsFont: Bool
        var faces: Faces
        var palette: Palette
        var light: Bool
        var layout: String
        var cardStyle: String
        var buttonStyle: String
        var bokeh: Bool
        var background: Background
        var presets: [Preset]
        var hasCustom: Bool
        var fontPairs: [FontPair]
    }

    @Published private(set) var state: Snapshot?
    /// Bumped whenever what the theme paints changes; RootView keys its tree on it so every view
    /// re-reads the BP tokens.
    @Published private(set) var revision = 0

    private var unsubscribe: (() -> Void)?
    /// Set while onboarding runs: a theme pulled in by the Harbor sign-in waits until the wizard
    /// is done, because repainting rebuilds the tree and would restart it at the first step.
    var holding = false {
        didSet { releasePending() }
    }
    /// Set while a film, channel or Multiview plays (RootView follows PlaybackState): a theme a
    /// profile-sync pull brings mid-playback waits, because the rebuild would tear the player down.
    var holdingForPlayback = false {
        didSet { releasePending() }
    }
    private var held: Bool { holding || holdingForPlayback }
    private var pending: Snapshot?

    private func releasePending() {
        if !held, let p = pending { pending = nil; adopt(p) }
    }

    private var profile: (id: String, linked: Bool) {
        let p = ProfilesStore.shared.active
        return (p?.id ?? "default", p?.linked ?? true)
    }

    func load() async {
        if unsubscribe == nil {
            // A profile-sync pull can bring a theme chosen on another device.
            unsubscribe = HarborEngine.shared.onEvent { [weak self] type, _ in
                guard type == "harbor:settings-updated" else { return }
                Task { await self?.load() }
            }
        }
        let p = profile
        if let s: Snapshot = try? await HarborEngine.shared.call("themes.state", [p.id, p.linked]) { adopt(s) }
    }

    /// theme-panel.tsx ThemeTab onSelect.
    func select(_ id: String) async {
        let p = profile
        if let s: Snapshot = try? await HarborEngine.shared.call("themes.apply", [id, p.id, p.linked]) { adopt(s) }
    }

    /// theme-panel.tsx TypographyTab onPickPair.
    func setFontPair(_ id: String) async {
        let p = profile
        if let s: Snapshot = try? await HarborEngine.shared.call("themes.setFontPair", [id, p.id, p.linked]) { adopt(s) }
    }

    private func adopt(_ s: Snapshot) {
        if held { pending = s; return }
        let old = state
        state = s
        let looksSame = old.map {
            $0.active == s.active && $0.palette == s.palette && $0.faces == s.faces && $0.background == s.background
                && $0.bokeh == s.bokeh && $0.buttonStyle == s.buttonStyle && $0.cardStyle == s.cardStyle && $0.light == s.light
        } ?? false
        if looksSame { return }
        BPThemeState.current = Self.tokens(for: s)
        // The first load at boot only replaces the default when the profile has another theme.
        if old != nil || s.active != "cool-grey" || s.faces != Faces(display: "sentient", sans: "switzer") { revision += 1 }
    }

    static func tokens(for s: Snapshot) -> BPThemeTokens {
        // Harbor default keeps the exact shipped constants; every other theme uses the engine's.
        var t = s.active == "cool-grey" ? BPThemeTokens.harbor : BPThemeTokens(
            canvas: color(s.palette.canvas), surface: color(s.palette.surface), elevated: color(s.palette.elevated),
            raised: color(s.palette.raised), ink: color(s.palette.ink), inkMuted: color(s.palette.inkMuted),
            inkSubtle: color(s.palette.inkSubtle), accent: color(s.palette.accent), danger: color(s.palette.danger),
            void_: color(s.palette.void_), panel: color(s.palette.panel), panel2: color(s.palette.panel2), on: color(s.palette.on))
        t.displayFace = BPThemeTokens.DisplayFace(rawValue: s.faces.display) ?? .sentient
        t.sansFace = BPThemeTokens.SansFace(rawValue: s.faces.sans) ?? .switzer
        t.buttonStyle = s.buttonStyle
        t.cardStyle = s.cardStyle
        return t
    }

    nonisolated static func color(_ c: [Double]) -> Color {
        guard c.count >= 3 else { return .clear }
        return Color(.sRGB, red: c[0], green: c[1], blue: c[2], opacity: c.count >= 4 ? c[3] : 1)
    }
}

/// theme-backdrop.tsx inside the Big Picture page: --bp-void, or the theme's own gradient
/// (Stremio's indigo, Aurora's sky, Velvet's theatre), an http wallpaper under its scrim, and
/// Aurora's bokeh. Harbor default has none of these, so it stays the plain void.
struct BPThemeBackdrop: View {
    @ObservedObject private var theme = ThemeStore.shared

    var body: some View {
        ZStack {
            BP.void_
            if let bg = theme.state?.background {
                if !bg.layers.isEmpty {
                    GeometryReader { g in
                        ZStack {
                            ForEach(Array(bg.layers.enumerated().reversed()), id: \.offset) { _, layer in
                                BPGradientLayer(layer: layer, size: g.size)
                            }
                        }
                    }
                } else if let url = bg.imageUrl {
                    RemoteImage(url: url)
                }
                if bg.scrim {
                    Color.black.opacity(0.45)
                    BP.canvas.opacity(bg.dim)
                }
            }
            if theme.state?.bokeh == true { BPBokehView() }
        }
        .clipped()
        .allowsHitTesting(false)
    }
}

/// One CSS gradient layer. Linear follows the CSS angle and gradient-line length; radial draws
/// the ellipse at its centre and lets the last stop cover everything outside it, as CSS does.
struct BPGradientLayer: View {
    let layer: ThemeStore.Layer
    let size: CGSize

    private var stops: [Gradient.Stop] {
        layer.stops.map { Gradient.Stop(color: ThemeStore.color($0.color), location: CGFloat(min(1, max(0, $0.at)))) }
    }

    var body: some View {
        let w: CGFloat = max(size.width, 1), h: CGFloat = max(size.height, 1)
        if layer.kind == "linear" {
            let a: CGFloat = CGFloat(layer.angle ?? 180) * .pi / 180
            let dx: CGFloat = sin(a), dy: CGFloat = -cos(a)
            let len: CGFloat = abs(w * dx) + abs(h * dy)
            let start = UnitPoint(x: (w / 2 - dx * len / 2) / w, y: (h / 2 - dy * len / 2) / h)
            let end = UnitPoint(x: (w / 2 + dx * len / 2) / w, y: (h / 2 + dy * len / 2) / h)
            LinearGradient(stops: stops, startPoint: start, endPoint: end)
        } else {
            let rx: CGFloat = CGFloat(layer.rx ?? 0.5) * w, ry: CGFloat = CGFloat(layer.ry ?? 0.5) * h
            ZStack {
                (layer.stops.last.map { ThemeStore.color($0.color) } ?? .clear)
                Rectangle()
                    .fill(EllipticalGradient(stops: stops, center: .center, startRadiusFraction: 0, endRadiusFraction: 0.5))
                    .frame(width: max(rx * 2, 1), height: max(ry * 2, 1))
                    .position(x: CGFloat(layer.cx ?? 0.5) * w, y: CGFloat(layer.cy ?? 0.5) * h)
            }
            .frame(width: w, height: h)
        }
    }
}

/// components/aurora-bokeh.tsx: seven soft orbs drifting slowly behind the Aurora theme.
struct BPBokehView: View {
    private struct Orb { var x, y, size, blur: CGFloat; var opacity, duration: Double; var color: Color }
    private static let palette: [Color] = [
        Color(.sRGB, red: 124 / 255, green: 214 / 255, blue: 1, opacity: 0.55),
        Color(.sRGB, red: 174 / 255, green: 140 / 255, blue: 1, opacity: 0.45),
        Color(.sRGB, red: 94 / 255, green: 165 / 255, blue: 247 / 255, opacity: 0.50),
        Color(.sRGB, red: 1, green: 180 / 255, blue: 220 / 255, opacity: 0.35),
        Color(.sRGB, red: 110 / 255, green: 1, blue: 210 / 255, opacity: 0.35),
    ]
    private static func seeded(_ i: Double) -> Double { let s = sin(i * 99.83) * 43758.5453; return s - s.rounded(.down) }
    private static let orbs: [Orb] = (0..<7).map { i in
        let r1 = seeded(Double(i * 3 + 1)), r2 = seeded(Double(i * 3 + 2)), r3 = seeded(Double(i * 3 + 3))
        return Orb(x: CGFloat(r1), y: CGFloat(r2), size: CGFloat(180 + r1 * 220), blur: CGFloat(24 + r3 * 28),
                   opacity: 0.4 + r2 * 0.35, duration: 28 + r3 * 24, color: palette[i % palette.count])
    }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drift = false

    var body: some View {
        GeometryReader { g in
            ZStack {
                ForEach(0..<Self.orbs.count, id: \.self) { i in
                    let o = Self.orbs[i]
                    Circle()
                        .fill(RadialGradient(colors: [o.color, .clear], center: .center, startRadius: 0, endRadius: BP.px(o.size) * 0.65))
                        .frame(width: BP.px(o.size), height: BP.px(o.size))
                        .blur(radius: BP.px(o.blur))
                        .opacity(o.opacity)
                        .scaleEffect(drift ? 1.1 : 0.95)
                        .offset(y: drift ? -BP.px(40) : BP.px(20))
                        .position(x: o.x * g.size.width, y: o.y * g.size.height)
                        .animation(reduceMotion ? nil : Animation.easeInOut(duration: o.duration).repeatForever(autoreverses: true), value: drift)
                }
            }
        }
        .onAppear { if !reduceMotion { drift = true } }
    }
}
