import SwiftUI
import UIKit
import Combine

/// Big Picture design tokens (docs/big-picture-design.md). Upstream lays out on a 1140×641 CSS
/// canvas; tvOS lays out on 1920×1080 points, so every px value is scaled by `BP.k`.
///
/// Colours and faces read the active theme (Stage 9, `BPThemeState.current`, set by ThemeStore
/// from engine/themes.ts). They are computed, not stored, so every caller keeps its syntax; the
/// Harbor default theme resolves to exactly the constants this file always shipped.
enum BP {
    static let k: CGFloat = 1920.0 / 1140.0
    static func px(_ v: CGFloat) -> CGFloat { (v * k).rounded() }

    // Base theme "Harbor default" (cool-grey), theme.ts:124-143, or the active preset's tokens.
    static var canvas: Color { BPThemeState.current.canvas }
    static var surface: Color { BPThemeState.current.surface }
    static var elevated: Color { BPThemeState.current.elevated }
    static var raised: Color { BPThemeState.current.raised }
    static var ink: Color { BPThemeState.current.ink }
    static var inkMuted: Color { BPThemeState.current.inkMuted }
    static var inkSubtle: Color { BPThemeState.current.inkSubtle }
    static var accent: Color { BPThemeState.current.accent }
    static var danger: Color { BPThemeState.current.danger }
    /// bp-tokens.ts: --bp-live is a fixed green in every theme.
    static let live = Color(hex: 0x4ade80)

    // --bp-* derivations (bp-tokens.ts:1-18), resolved per theme.
    static var void_: Color { BPThemeState.current.void_ }
    static var panel: Color { BPThemeState.current.panel }
    static var panel2: Color { BPThemeState.current.panel2 }
    static var on: Color { BPThemeState.current.on }
    static var glass: Color { ink.opacity(0.07) }
    static var edge: Color { ink.opacity(0.11) }
    static var edge2: Color { ink.opacity(0.18) }
    static var focusStroke: Color { ink.opacity(0.86) }

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

    // Type (Switzer for UI, Sentient for hero-scale titles, Fraunces for the wordmark), or the
    // theme's font pair (lib/theme.ts FONT_PAIRS) where the app bundles it; the rest fall through
    // their CSS stacks to system-ui, which on tvOS is SF.
    static func sans(_ px: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        sans(px, weight, face: BPThemeState.current.sansFace)
    }
    static func display(_ px: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        display(px, weight, face: BPThemeState.current.displayFace)
    }
    /// A specific face, whatever the theme (the Typography tiles draw every pair in its own).
    static func sans(_ px: CGFloat, _ weight: Font.Weight, face: BPThemeTokens.SansFace) -> Font {
        if face == .system { return .system(size: Self.px(px), weight: weight) }
        let name: String
        switch weight {
        case .bold, .heavy, .black: name = "Switzer-Bold"
        case .semibold: name = "Switzer-Semibold"
        case .medium: name = "Switzer-Medium"
        default: name = "Switzer-Regular"
        }
        return .custom(name, size: Self.px(px))
    }
    static func display(_ px: CGFloat, _ weight: Font.Weight, face: BPThemeTokens.DisplayFace) -> Font {
        switch face {
        case .system: return .system(size: Self.px(px), weight: weight)
        // Only the Medium cut of Fraunces ships (it draws the wordmark).
        case .fraunces: return .custom("Fraunces-Medium", size: Self.px(px))
        case .sentient:
            let name = weight == .regular ? "Sentient-Regular" : (weight == .bold ? "Sentient-Bold" : "Sentient-Medium")
            return .custom(name, size: Self.px(px))
        }
    }
    static func wordmark(_ px: CGFloat) -> Font { .custom("Fraunces-Medium", size: Self.px(px)) }
}

/// One resolved theme: the colours and faces BP hands out, plus the preset's card/button styles.
struct BPThemeTokens {
    enum DisplayFace: String { case sentient, fraunces, system }
    enum SansFace: String { case switzer, system }

    var canvas, surface, elevated, raised, ink, inkMuted, inkSubtle, accent, danger: Color
    var void_, panel, panel2, on: Color
    var displayFace: DisplayFace = .sentient
    var sansFace: SansFace = .switzer
    /// lib/theme.ts ThemeButtonStyle / ThemeCardStyle ("flat" by default).
    var buttonStyle = "flat"
    var cardStyle = "flat"

    /// "Harbor default" exactly as Theme.swift has always drawn it.
    static let harbor = BPThemeTokens(
        canvas: Color(hex: 0x111213), surface: Color(hex: 0x191b1c), elevated: Color(hex: 0x252628), raised: Color(hex: 0x323335),
        ink: Color(hex: 0xf4f5f7), inkMuted: Color(hex: 0xa3a5a6), inkSubtle: Color(hex: 0x626365),
        accent: Color(hex: 0xf4a25c), danger: Color(hex: 0xc53637),
        void_: Color(hex: 0x0d0e0f), panel: Color(hex: 0x161819), panel2: Color(hex: 0x222325), on: Color(hex: 0x404142))
}

/// The theme every BP accessor reads. Written only by ThemeStore on the main actor; RootView
/// rebuilds its tree (ThemeStore.revision) whenever it changes, so views pick it up.
enum BPThemeState {
    static var current = BPThemeTokens.harbor
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
    /// bp-mosaic "ambient" variant behind screens with no art of their own; off when the viewer
    /// turned the animated backdrop off (settings.bigPictureMosaic).
    var mosaic = true
    /// RootView's (and the PiP browse layer's) instance: the fallback under screens that draw
    /// no background of their own, so any other instance showing in its window outranks it.
    var root = false
    @ObservedObject private var pool = AmbientPool.shared
    /// (perf pass 2) Only one mosaic in the app runs: see AmbientCoverage.
    @ObservedObject private var coverage = AmbientCoverage.shared
    /// (pass 3) Observed, not read in passing: Settings → Picture → Animated backdrop (or the quick
    /// panel's row) turned off left the mosaic drifting behind the Settings page, because nothing
    /// this view watches changed until the next cover or room switch.
    @ObservedObject private var settings = SettingsBridge.shared
    @State private var id = UUID()
    var body: some View {
        // `mosaic` can change while the instance stays up (RootView's follows the stage and the
        // room), so the fade keys on both.
        let on = mosaic && coverage.live == id
        ZStack {
            // --bp-void, or the theme's own backdrop (Stage 9); plain void on Harbor default.
            BPThemeBackdrop()
            if on, settings.slice.bigPictureMosaic ?? true, pool.posters.count >= 12 {
                BPMosaicView(posters: pool.posters).opacity(0.13).transition(.opacity)
            }
            RadialGradient(colors: [BP.accent.opacity(0.10), .clear], center: .topTrailing, startRadius: 0, endRadius: 1300)
            LinearGradient(colors: [BP.canvas.opacity(0.9), .clear], startPoint: .bottom, endPoint: .center)
        }
        .animation(BP.easeSlow, value: on)
        .background(AmbientProbe(id: id))
        .ignoresSafeArea()
        .task { await pool.load() }
        .onAppear { coverage.appeared(id, rank: root ? .root : .screen) }
        .onDisappear { coverage.disappeared(id) }
    }

    /// bp-shell.tsx:418-423 mounts no BpAmbient on search, live, sports or sports-event ("Live TV
    /// gets the flat canvas and no ambient at all"), so a shell's root instance draws no mosaic in
    /// those rooms. A sports event opens as a cover, which stands the root down by itself.
    static func shellDrawsMosaic(in room: Room) -> Bool {
        switch room {
        case .search, .live, .sports: return false
        // RoomView and DiscoverView paint SpotlightView's opaque backdrop over the whole screen, so a
        // root mosaic there drifted unseen (upstream's BpAmbient shows the title art there, never
        // the "ambient" mosaic variant). Discover only showed it for the moment before its spotlight.
        case .home, .movies, .shows, .anime, .discover: return false
        default: return true
        }
    }
}

/// A page's own stage mosaic (bp-mosaic variant "stage", painted at 32 %): Home's services and
/// addons bands (bp-ambient-layers) and Search (bp-search). It registers with AmbientCoverage
/// above every BPAmbientBackground, so the ambient mosaic under it (RootView's, or the screen's)
/// stands down while it is up: upstream never has two mosaics on screen. It keeps that rank while
/// it draws nothing (the caller passes [] below its own floor), because its caller paints an
/// opaque page over the ambient one anyway.
struct BPStageMosaic: View {
    /// The posters to draw, or [] for none yet.
    let posters: [String]
    /// A new key swaps the columns with a fade (bp-ambient MOSAIC_SWAP_MS: a new band cell).
    var key = ""
    @ObservedObject private var coverage = AmbientCoverage.shared
    @State private var id = UUID()

    var body: some View {
        let on = coverage.live == id && posters.count >= 12 && (SettingsBridge.shared.slice.bigPictureMosaic ?? true)
        ZStack {
            Color.clear
            if on {
                BPMosaicView(posters: posters, stage: true).opacity(0.32).id(key).transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.26), value: on)
        .background(AmbientProbe(id: id))
        .allowsHitTesting(false)
        .onAppear { coverage.appeared(id, rank: .stage) }
        .onDisappear { coverage.disappeared(id) }
    }
}

/// (perf pass 2) Which BPAmbientBackground draws its mosaic. Upstream mounts one ambient layer,
/// in bp-shell outside the routed page, so one mosaic at most is ever on screen. Here the
/// background is drawn by RootView and again by ~20 screens and covers, each opaque, and every
/// one ran its 48 masked, drifting posters behind whatever covered it: the screen over RootView,
/// a fullScreenCover over the screen, the player, the screensaver. Now only the instance the
/// viewer can see runs one: in the topmost window, not under a presented cover (an alert aside),
/// a page's stage mosaic (BPStageMosaic: Home's bands, Search) over a screen's own background
/// over the root fallback, and the newest of those. None runs under the
/// screensaver or curfew lock, or while the app is in the background. Covers are not
/// observable, so presentations are polled twice a second, as PreviewGate does; the mosaic
/// leaves the tree when covered (fading back in when uncovered), so it neither animates nor draws.
@MainActor
final class AmbientCoverage: ObservableObject {
    static let shared = AmbientCoverage()
    /// The instance whose mosaic runs, if any.
    @Published private(set) var live: UUID?
    /// Within one window: a page's stage mosaic over a screen's own background over the root fallback.
    enum Rank: Int { case root = 0, screen = 1, stage = 2 }
    private struct Entry { var rank: Rank; var order: Int }
    private final class WeakView { weak var view: UIView?; init(_ v: UIView) { view = v } }
    private var entries: [UUID: Entry] = [:]
    private var probes: [UUID: WeakView] = [:]
    private var order = 0
    private var bag = Set<AnyCancellable>()

    private init() {
        // @Published fires before the value lands: read it on the next main-queue turn.
        ScreensaverModel.shared.$active.sink { [weak self] _ in Task { @MainActor in self?.refresh() } }.store(in: &bag)
        CurfewState.shared.$locked.sink { [weak self] _ in Task { @MainActor in self?.refresh() } }.store(in: &bag)
        Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &bag)
    }

    func appeared(_ id: UUID, rank: Rank) {
        order += 1
        entries[id] = Entry(rank: rank, order: order)
        refresh()
    }

    func disappeared(_ id: UUID) {
        entries[id] = nil
        refresh()
    }

    fileprivate func attach(_ id: UUID, _ view: UIView) {
        probes[id] = WeakView(view)
        // didMoveToWindow can land inside a SwiftUI update: publish on the next main-queue turn.
        Task { @MainActor [weak self] in self?.refresh() }
    }

    func refresh() {
        probes = probes.filter { $0.value.view != nil }
        var pick: UUID?
        var best: (CGFloat, Int, Int) = (-.greatestFiniteMagnitude, -1, -1)
        let blocked = ScreensaverModel.shared.active || CurfewState.shared.locked
            || UIApplication.shared.applicationState == .background
        if !blocked {
            for (id, e) in entries {
                guard let v = probes[id]?.view, let w = v.window, !w.isHidden, !Self.presentedOver(v) else { continue }
                let key: (CGFloat, Int, Int) = (w.windowLevel.rawValue, e.rank.rawValue, e.order)
                if key > best {
                    best = key
                    pick = id
                }
            }
        }
        if live != pick { live = pick }
    }

    /// Something is presented over the view controller hosting `view` (a fullScreenCover, a sheet,
    /// the player's cover). An alert or confirmation dialog leaves the screen showing around it.
    private static func presentedOver(_ view: UIView) -> Bool {
        var responder: UIResponder? = view
        var owner: UIViewController?
        while let next = responder?.next {
            if let vc = next as? UIViewController {
                owner = vc
                break
            }
            responder = next
        }
        guard var host = owner else { return false }
        while let parent = host.parent { host = parent }
        guard let presented = host.presentedViewController else { return false }
        if presented is UIAlertController { return false }
        return !presented.isBeingDismissed
    }
}

/// Tells AmbientCoverage where one BPAmbientBackground sits (its window and view controller).
private struct AmbientProbe: UIViewRepresentable {
    let id: UUID

    func makeUIView(context: Context) -> ProbeView {
        let v = ProbeView()
        v.id = id
        v.isUserInteractionEnabled = false
        return v
    }

    func updateUIView(_ uiView: ProbeView, context: Context) {}

    final class ProbeView: UIView {
        var id: UUID?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let id { AmbientCoverage.shared.attach(id, self) }
        }
    }
}

/// The poster pool the mosaic draws from (bp-ambient `pool`): the hero feed, fetched once.
@MainActor
final class AmbientPool: ObservableObject {
    static let shared = AmbientPool()
    @Published private(set) var posters: [String] = []
    private var loading = false
    func load() async {
        guard posters.isEmpty, !loading else { return }
        loading = true; defer { loading = false }
        struct M: Decodable { var poster: String? }
        let metas: [M] = (try? await HarborEngine.shared.call("feed.hero", ["trending"])) ?? []
        var seen: Set<String> = []
        posters = metas.compactMap(\.poster).filter { seen.insert($0).inserted }
    }
}

/// bp-mosaic.tsx: six columns of posters, rotated −14° and scaled 1.55, each column drifting
/// slowly (alternating directions) under a radial mask.
struct BPMosaicView: View {
    let posters: [String]
    /// bp-mosaic `variant="stage"`: the band mosaic behind Home's services/addons bands (wider,
    /// denser mask; the caller paints it at 32 %). The default is the "ambient" variant.
    var stage = false
    /// bp-decor-motion (useReducedMotion follows the setting live): the columns hold still under
    /// Reduce Motion.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // Toggling Reduce Motion rebuilds the columns, so a drift already running stops (or one
        // switched back on starts): a running repeatForever animation cannot be called off in place.
        BPMosaicColumns(posters: posters, stage: stage, drift: !reduceMotion).id(reduceMotion)
    }
}

private struct BPMosaicColumns: View {
    let posters: [String]
    let stage: Bool
    let drift: Bool
    private static let columns = 6, perColumn = 4
    @State private var phase = false

    var body: some View {
        GeometryReader { g in
            let colW = g.size.width * 0.11
            let gap = g.size.width * 0.016
            let tileH = colW * 1.5
            HStack(alignment: .top, spacing: gap) {
                ForEach(0..<Self.columns, id: \.self) { c in
                    let col = (0..<Self.perColumn).map { posters[(c * Self.perColumn + $0) % posters.count] }
                    VStack(spacing: gap) {
                        ForEach(Array((col + col).enumerated()), id: \.offset) { _, url in
                            RemoteImage(url: url).frame(width: colW, height: tileH).clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                    }
                    .offset(y: (phase ? -1 : 0) * (tileH + gap) * CGFloat(Self.perColumn) * (c % 2 == 0 ? 1 : -1))
                    .animation(.linear(duration: Double(74 + c * 9)).repeatForever(autoreverses: false), value: phase)
                }
            }
            .rotationEffect(.degrees(-14))
            .scaleEffect(1.55)
            .position(x: g.size.width / 2, y: g.size.height / 2)
            .mask(stage
                  ? RadialGradient(stops: [.init(color: .black, location: 0), .init(color: .black.opacity(0.72), location: 0.58), .init(color: .clear, location: 0.92)],
                                   center: .init(x: 0.5, y: 0.45), startRadius: 0, endRadius: g.size.width * 0.8)
                  : RadialGradient(colors: [.black, .black.opacity(0.55), .clear], center: .init(x: 0.5, y: 0.4), startRadius: 0, endRadius: g.size.width * 0.75))
        }
        .allowsHitTesting(false)
        .onAppear { if drift { phase = true } }
    }
}
