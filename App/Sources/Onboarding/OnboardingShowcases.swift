import SwiftUI

// The onboarding step surfaces upstream draws beside the copy (onboarding/bp-*-showcase.tsx,
// bp-layout-preview.tsx, bp-subtitle-preview.tsx, bp-done-flourish.tsx) and the language
// step (steps/bp-step-language.tsx). The art is the same fixed TMDB images upstream uses.

private let tmdbImg = "https://image.tmdb.org/t/p/w342"
private let tmdbStill = "https://image.tmdb.org/t/p/w780/eGX66zonvc4bXg3rM08RUxdYSDx.jpg"

/// bp-onboard-aside.tsx: every aside rises in (bp-rise: 14px up and a fade, --bp-dur-slow).
private struct OnboardRise: ViewModifier {
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : BP.px(14))
            .onAppear { withAnimation(reduceMotion ? nil : BP.easeSlow) { shown = true } }
    }
}

/// steps/bp-step-language.tsx: every UI language as a row (flag, native name, English name,
/// greeting). Picking applies at once (setUiLanguage + settings.uiLanguage through
/// settingsRoom.commit) and moves the ring to Continue; the ring opens on the current language,
/// so one OK never switches someone away from what they read.
struct OnboardLanguageStep: View {
    struct Language: Decodable, Identifiable {
        var code: String; var label: String; var nativeLabel: String; var greeting: String; var rtl: Bool; var flags: [String]
        var id: String { code }
    }
    struct Languages: Decodable { var current: String; var languages: [Language] }

    var ring: FocusState<String?>.Binding
    let done: () -> Void
    @State private var list: Languages?
    /// (onboarding device pass) A new language rebuilds the whole tree (RootView's `.id` carries the
    /// language), so this screen comes back as a fresh view and `pick`'s move to Continue landed on
    /// the old one: the ring opened on the new language's row instead of advanceBpOnboardRing's
    /// Continue. A pick made moments ago sends the rebuilt screen's ring to Continue.
    private static var pickedAt: Date?

    private var profile: (id: String, linked: Bool) { let p = ProfilesStore.shared.active; return (p?.id ?? "default", p?.linked ?? true) }

    var body: some View {
        VStack(alignment: .leading, spacing: BP.px(14)) {
            if let list {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: BP.px(8)) {
                        ForEach(list.languages) { l in row(l, selected: l.code == list.current) }
                    }
                    .padding(.vertical, BP.px(10)).padding(.horizontal, BP.px(8))
                }
                .frame(height: BP.px(430))
                .focusSection()
            } else {
                ProgressView().tint(BP.inkMuted)
            }
            Button("Continue") { done() }
                .buttonStyle(BPActionStyle(primary: true))
                .focused(ring, equals: "primary")
        }
        .task {
            await load()
            if let at = Self.pickedAt, Date().timeIntervalSince(at) < 10 {
                Self.pickedAt = nil
                ring.wrappedValue = "primary"
            } else if let cur = list?.current {
                ring.wrappedValue = "lang:\(cur)"
            }
        }
    }

    private func load() async {
        let p = profile
        list = try? await HarborEngine.shared.call("settingsRoom.languages", [p.id, p.linked])
    }

    private func pick(_ code: String) async {
        let p = profile
        if code != list?.current { Self.pickedAt = Date() }
        _ = try? await HarborEngine.shared.callJSON("settingsRoom.commit", [.string("uiLanguage"), .string(code), .string(p.id), .bool(p.linked)])
        await SettingsBridge.shared.load()
        await load()
        ring.wrappedValue = "primary"
    }

    private func row(_ l: Language, selected: Bool) -> some View {
        Button { Task { await pick(l.code) } } label: {
            HStack(spacing: BP.px(16)) {
                ZStack {
                    Circle().fill(BP.panel2)
                    if l.flags.count == 2 {
                        // PAIRED: one circle split corner to corner between two flags.
                        Text(l.flags[0]).font(.system(size: BP.px(40))).frame(width: BP.px(48), height: BP.px(48)).mask(Triangle(lowerLeft: true))
                        Text(l.flags[1]).font(.system(size: BP.px(40))).frame(width: BP.px(48), height: BP.px(48)).mask(Triangle(lowerLeft: false))
                    } else if let flag = l.flags.first {
                        Text(flag).font(.system(size: BP.px(40)))
                    } else {
                        Text(l.code.uppercased()).font(BP.sans(14, .bold)).foregroundStyle(BP.ink)
                    }
                    if selected {
                        Circle().fill(BP.void_.opacity(0.65))
                        Image(systemName: "checkmark").font(.system(size: BP.px(18), weight: .heavy)).foregroundStyle(BP.ink)
                    }
                }
                .frame(width: BP.px(48), height: BP.px(48))
                .clipShape(Circle())
                VStack(alignment: .leading, spacing: BP.px(3)) {
                    Text(l.nativeLabel).font(BP.sans(20, .semibold)).foregroundStyle(BP.ink).lineLimit(1)
                    Text(l.label).font(BP.sans(13, .medium)).foregroundStyle(BP.ink.opacity(0.65)).lineLimit(1)
                }
                Spacer(minLength: BP.px(10))
                Text(l.greeting)
                    .font(l.rtl ? Font.system(size: BP.px(20), weight: .medium) : BP.display(20, .medium))
                    .foregroundStyle(BP.inkSubtle)
                    .lineLimit(1)
            }
            .padding(.horizontal, BP.px(20)).padding(.vertical, BP.px(12))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: BP.rMD, style: .continuous).fill(selected ? BP.glass : BP.panel))
            .overlay(RoundedRectangle(cornerRadius: BP.rMD, style: .continuous).strokeBorder(selected ? .clear : BP.edge, lineWidth: 1))
        }
        .buttonStyle(BPTileStyle(radius: BP.rMD))
        .focused(ring, equals: "lang:\(l.code)")
    }

    /// Half of the square, split along the bottom-left → top-right diagonal.
    private struct Triangle: Shape {
        let lowerLeft: Bool
        func path(in r: CGRect) -> Path {
            var p = Path()
            if lowerLeft {
                p.move(to: CGPoint(x: r.minX, y: r.minY)); p.addLine(to: CGPoint(x: r.minX, y: r.maxY)); p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
            } else {
                p.move(to: CGPoint(x: r.minX, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
            }
            p.closeSubpath()
            return p
        }
    }
}

/// bp-tmdb-showcase.tsx: what TMDB unlocks, a title's backdrop with its logo, and its cast.
struct OnboardTmdbShowcase: View {
    private static let logo = "https://image.tmdb.org/t/p/w300/7gQc9y2EORn9pZhGtAEdlEbpcpz.png"
    private static let cast: [(path: String, name: String)] = [
        ("/yoQxpUPt3le9zY4Sab3g2ANy4CE.jpg", "David Corenswet"),
        ("/piB7t3ykZaylYTRoyK46FknyF2p.jpg", "Rachel Brosnahan"),
        ("/pXm8GWTm9eIA8pUGOjvmYjlxamu.jpg", "Nicholas Hoult"),
        ("/dt8yMyycDlzxkjhmuuJJ4tXDbp4.jpg", "Edi Gathegi"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: BP.px(12)) {
            GeometryReader { g in
                ZStack(alignment: .bottomLeading) {
                    RemoteImage(url: tmdbStill).frame(width: g.size.width, height: g.size.height).clipped()
                    LinearGradient(stops: [
                        .init(color: BP.void_, location: 0.04),
                        .init(color: BP.void_.opacity(0.62), location: 0.32),
                        .init(color: BP.void_.opacity(0), location: 0.68),
                    ], startPoint: .bottom, endPoint: .top)
                    // AsyncImage, not RemoteImage: a logo floats on the art with no loading plate behind it.
                    AsyncImage(url: URL(string: Self.logo)) { img in img.resizable().scaledToFit() } placeholder: { Color.clear }
                        .frame(maxWidth: g.size.width * 0.58, maxHeight: g.size.height * 0.34, alignment: .bottomLeading)
                        .shadow(color: .black.opacity(0.8), radius: 7, y: 4)
                        .padding(.leading, g.size.width * 0.06).padding(.bottom, g.size.height * 0.09)
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .background(BP.panel2)
            .clipShape(RoundedRectangle(cornerRadius: BP.rMD, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: BP.rMD, style: .continuous).strokeBorder(BP.edge, lineWidth: 1))
            HStack(spacing: BP.px(8)) {
                ForEach(Self.cast, id: \.path) { c in
                    VStack(spacing: BP.px(5)) {
                        RemoteImage(url: "https://image.tmdb.org/t/p/w185\(c.path)")
                            .aspectRatio(1, contentMode: .fit)
                            .frame(maxWidth: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).strokeBorder(BP.edge, lineWidth: 1))
                        Text(c.name).font(BP.sans(9, .semibold)).foregroundStyle(BP.inkSubtle).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .modifier(OnboardRise())
    }
}

/// bp-stremio-showcase.tsx: a three-poster wall and the independence note. The Stremio wordmark
/// and mascot art are upstream bundle assets this app does not ship, so they are left out.
struct OnboardStremioShowcase: View {
    private static let wall = ["/iPOn6DinuVyLY17YM9mKuPofV08.jpg", "/7V0Ebks0GgpKvQ7QbLAIdX5dos4.jpg", "/1g0dhYtq4irTY1GPXvft6k4YLjm.jpg"]

    var body: some View {
        VStack(alignment: .leading, spacing: BP.px(18)) {
            HStack(alignment: .bottom, spacing: BP.px(10)) {
                ForEach(Array(Self.wall.enumerated()), id: \.offset) { i, path in
                    RemoteImage(url: "\(tmdbImg)\(path)")
                        .frame(width: BP.px(60), height: BP.px(90))
                        .clipShape(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).strokeBorder(BP.edge, lineWidth: 1))
                        .rotationEffect(.degrees(Double(i - 1) * 1.5))
                        .offset(y: CGFloat(abs(i - 1)) * 5)
                        .opacity(0.78)
                }
            }
            HStack(alignment: .top, spacing: BP.px(10)) {
                Capsule().fill(BP.edge2).frame(width: BP.px(18), height: 2).padding(.top, BP.px(7))
                Text("Harbor is an independent client. It is not affiliated with or endorsed by Stremio.")
                    .font(BP.sans(11, .medium)).foregroundStyle(BP.inkSubtle).fixedSize(horizontal: false, vertical: true)
            }
        }
        .modifier(OnboardRise())
    }
}

/// bp-layout-preview.tsx: Harbor (hero + one row) beside Classic (two labelled rows); the
/// chosen one lit and ringed, the other at 34%.
struct OnboardLayoutPreview: View {
    let mode: String
    private static let tiles = ["/iPOn6DinuVyLY17YM9mKuPofV08.jpg", "/7V0Ebks0GgpKvQ7QbLAIdX5dos4.jpg", "/1g0dhYtq4irTY1GPXvft6k4YLjm.jpg", "/rzpHPSEgPTpRs8EHbygwsOw7jC0.jpg", "/sfQtVlIHljToOwYjhe21KPGzZWK.jpg"]

    var body: some View {
        HStack(alignment: .top, spacing: BP.px(12)) {
            panel(on: mode == "harbor") {
                GeometryReader { g in
                    ZStack(alignment: .bottomLeading) {
                        RemoteImage(url: tmdbStill).frame(width: g.size.width, height: g.size.height).clipped()
                        LinearGradient(stops: [.init(color: BP.void_, location: 0.06), .init(color: BP.void_.opacity(0), location: 0.62)], startPoint: .bottom, endPoint: .top)
                        RoundedRectangle(cornerRadius: 2).fill(BP.ink.opacity(0.85))
                            .frame(width: g.size.width * 0.38, height: g.size.height * 0.13)
                            .padding(.leading, g.size.width * 0.07).padding(.bottom, g.size.height * 0.09)
                    }
                }
                .aspectRatio(16 / 7, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 3))
                posters(Array(Self.tiles.prefix(4)))
            }
            panel(on: mode == "classic") {
                Capsule().fill(BP.ink.opacity(0.45)).frame(width: BP.px(60), height: BP.px(5))
                posters(Array(Self.tiles.prefix(4)))
                Capsule().fill(BP.ink.opacity(0.45)).frame(width: BP.px(46), height: BP.px(5)).padding(.top, BP.px(3))
                posters(Array(Self.tiles.dropFirst().prefix(4)))
            }
        }
        .modifier(OnboardRise())
        .animation(BP.ease, value: mode)
    }

    private func posters(_ paths: [String]) -> some View {
        HStack(spacing: BP.px(4)) {
            ForEach(paths, id: \.self) { p in
                RemoteImage(url: "\(tmdbImg)\(p)").aspectRatio(2 / 3, contentMode: .fit).frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            }
        }
    }

    private func panel<C: View>(on: Bool, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: BP.px(6)) { content() }
            .padding(BP.px(8))
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).fill(BP.panel))
            .clipShape(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).strokeBorder(on ? BP.focusStroke : .clear, lineWidth: 2))
            .opacity(on ? 1 : 0.34)
    }
}

/// bp-subtitle-preview.tsx: the sample line on a still, then the chosen languages' flags (up to
/// six), the first marked "1".
struct OnboardSubtitlePreview: View {
    let languages: [String]
    @State private var flags: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: BP.px(12)) {
            GeometryReader { g in
                ZStack(alignment: .bottom) {
                    RemoteImage(url: tmdbStill).frame(width: g.size.width, height: g.size.height).clipped().opacity(0.7)
                    LinearGradient(stops: [.init(color: BP.void_, location: 0.04), .init(color: BP.void_.opacity(0), location: 0.46)], startPoint: .bottom, endPoint: .top)
                    Text("This is how a subtitle will look.")
                        .font(BP.sans(12, .semibold)).foregroundStyle(BP.ink)
                        .multilineTextAlignment(.center)
                        .shadow(color: .black.opacity(0.9), radius: 3, y: 2)
                        .padding(.horizontal, g.size.width * 0.08).padding(.bottom, g.size.height * 0.09)
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .background(BP.panel2)
            .clipShape(RoundedRectangle(cornerRadius: BP.rMD, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: BP.rMD, style: .continuous).strokeBorder(BP.edge, lineWidth: 1))
            BPFlagRow(flags: flags, size: BP.px(31), limit: 6)
        }
        .modifier(OnboardRise())
        .task(id: languages) {
            // settingsRoom.pane carries flagSrc() for preferredSubLangs as emoji flags.
            let p = ProfilesStore.shared.active
            struct Sub: Decodable { var flags: [String] }
            struct PaneSubs: Decodable { var subtitle: Sub }
            if let pane: PaneSubs = try? await HarborEngine.shared.call("settingsRoom.pane", [p?.id ?? "default", p?.linked ?? true]) {
                flags = pane.subtitle.flags
            }
        }
    }
}

/// bp-done-flourish.tsx: the viewer's own five picks dealt into a fan (or a stock five when they
/// picked nothing), then the live-green check drawing itself on.
struct OnboardDoneFlourish: View {
    let art: [String]
    @State private var dealt = false
    @State private var checked = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            let n = art.count
            ForEach(Array(art.enumerated()), id: \.offset) { i, url in
                let off = Double(i) - Double(n - 1) / 2
                RemoteImage(url: url)
                    .frame(width: BP.px(75), height: BP.px(112))
                    .clipShape(RoundedRectangle(cornerRadius: BP.rMD, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: BP.rMD, style: .continuous).strokeBorder(BP.edge, lineWidth: 1))
                    .shadow(color: .black.opacity(0.9), radius: 20, y: 18)
                    .rotationEffect(.degrees(off * 5), anchor: .bottom)
                    .offset(y: CGFloat(abs(off) * 7) + (dealt ? 0 : BP.px(26)))
                    .scaleEffect(dealt ? 1 : 0.92, anchor: .bottom)
                    .opacity(dealt ? 1 : 0)
                    .padding(.leading, i == 0 ? 0 : -BP.px(75) * 0.11)
                    .zIndex(Double(n) - abs(off))
                    .animation(reduceMotion ? nil : BP.easeSlow.delay(Double(i) * 0.08), value: dealt)
            }
            ZStack {
                Circle().fill(BP.live.opacity(0.26)).background(Circle().fill(BP.void_))
                CheckStroke()
                    .trim(from: 0, to: checked ? 1 : 0)
                    .stroke(BP.live, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                    .padding(BP.px(11))
            }
            .frame(width: BP.px(40), height: BP.px(40))
            .overlay(Circle().strokeBorder(BP.canvas, lineWidth: 3))
            .padding(.leading, -BP.px(20))
            .padding(.bottom, -BP.px(4))
            .zIndex(20)
            .opacity(dealt ? 1 : 0)
            .animation(reduceMotion ? nil : BP.easeSlow.delay(0.48), value: dealt)
        }
        .padding(.bottom, BP.px(20))
        .onAppear {
            dealt = true
            if reduceMotion { checked = true } else {
                withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.52).delay(0.56)) { checked = true }
            }
        }
    }

    /// The check path from the flourish SVG (M5 12.5 L10 17.5 L19 7 in a 24 box).
    private struct CheckStroke: Shape {
        func path(in r: CGRect) -> Path {
            var p = Path()
            let s = min(r.width, r.height) / 24
            p.move(to: CGPoint(x: r.minX + 5 * s, y: r.minY + 12.5 * s))
            p.addLine(to: CGPoint(x: r.minX + 10 * s, y: r.minY + 17.5 * s))
            p.addLine(to: CGPoint(x: r.minX + 19 * s, y: r.minY + 7 * s))
            return p
        }
    }
}
