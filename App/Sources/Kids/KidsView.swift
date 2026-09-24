import SwiftUI
import UIKit

/// The Kids page (views/kids.tsx): the kids hero over the sea art, then the kids rows with the
/// "Pick a World" franchise rail after the third row (TMDB only) and the Play Zone call to
/// action after the fifth, doodles scattered behind. Everything opens the kids detail page.
struct KidsView: View {
    let openPlay: () -> Void
    @StateObject private var model = KidsModel()
    @State private var detail: Meta?
    @State private var franchise: KidsModel.Franchise?
    @Environment(\.shellFocusNamespace) private var shellNS
    @Namespace private var localNS

    /// kids.tsx CatalogRows injectAfter={2} / injectAfter2={4}.
    private static let franchiseAfter = 2
    private static let playAfter = 4

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                KidsHeroView(cards: model.heroCards, logos: model.logos, loading: model.loading && model.heroCards.isEmpty) { detail = $0 }
                    .prefersDefaultFocus(true, in: shellNS ?? localNS)
                VStack(alignment: .leading, spacing: BP.px(30)) {
                    if !model.hasTmdb { tmdbNudge }
                    if model.failed {
                        VStack(alignment: .leading, spacing: BP.px(8)) {
                            Text("Couldn't load this room.").font(KidsTheme.font(20)).foregroundStyle(KidsTheme.deep)
                            Text("No catalog rows came back. Check the connection, or add a TMDB key in Settings.")
                                .font(KidsTheme.font(15, .semibold)).foregroundStyle(KidsTheme.inkMuted)
                        }
                        .padding(.horizontal, BP.gutter)
                    }
                    ForEach(Array(model.rows.enumerated()), id: \.element.key) { i, row in
                        KidsRowView(row: row, onOpen: { detail = $0 }) {
                            Task { await model.loadMore(row.key) }
                        }
                        if i == Self.franchiseAfter, !model.franchises.isEmpty {
                            KidsFranchiseRail(tiles: model.franchises) { franchise = $0 }
                        }
                        if i == Self.playAfter {
                            KidsPlayZoneCTA(action: openPlay).padding(.horizontal, BP.gutter)
                        }
                    }
                }
                .padding(.top, -BP.px(70))
                .padding(.bottom, BP.px(120))
                .background(alignment: .top) { KidsDoodles().padding(.top, -BP.px(70)) }
            }
        }
        .background(KidsTheme.canvas.ignoresSafeArea())
        .task { await model.load() }
        .onChange(of: model.heroCards.isEmpty) { _, empty in
            if !empty { DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { ShellFocus.shared.requestDefault() } }
        }
        .fullScreenCover(item: $detail) { m in KidsDetailView(meta: m) }
        .fullScreenCover(item: $franchise) { f in KidsFranchiseView(franchise: f) }
    }

    /// components/nudge.tsx TmdbNudge copy. A kid profile has no Settings, so there is no Set up button.
    private var tmdbNudge: some View {
        VStack(alignment: .leading, spacing: BP.px(4)) {
            Text("Add a TMDB key for the full Harbor").font(KidsTheme.font(15, .semibold)).foregroundStyle(KidsTheme.deep)
            Text("Free key unlocks Trending, In Theaters, and per-service catalogs. 60 seconds.")
                .font(KidsTheme.font(13.5, .medium)).foregroundStyle(KidsTheme.inkMuted)
        }
        .padding(.horizontal, BP.px(20)).padding(.vertical, BP.px(14))
        .background(RoundedRectangle(cornerRadius: BP.px(16), style: .continuous).fill(KidsTheme.raised.opacity(0.95)))
        .padding(.horizontal, BP.gutter)
    }
}

// MARK: - Hero

/// kids/kids-hero.tsx: "Just for kids" / "What should we watch?" over the sea art, five wide
/// cards with each title's logo (or its name) along the bottom.
struct KidsHeroView: View {
    let cards: [Meta]
    let logos: [String: String]
    let loading: Bool
    let onOpen: (Meta) -> Void

    static let cardSize = CGSize(width: BP.px(212), height: BP.px(120))
    static let height = BP.px(560)

    var body: some View {
        ZStack(alignment: .bottom) {
            // `background: url(/kids/kidbgsvg.svg) cover, center 24px`; the bundled raster twin
            // (public/kids/kidsbg.png) stands in because tvOS cannot draw the SVG.
            KidsArt("/kids/kidsbg.png", contentMode: .fill)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.top, BP.px(24))
                .clipped()
            LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: KidsTheme.canvas.opacity(0.55), location: 0.5), .init(color: KidsTheme.canvas, location: 1)],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: Self.height * 0.4)
            VStack(spacing: BP.px(20)) {
                VStack(spacing: BP.px(4)) {
                    Text("Just for kids".uppercased())
                        .font(KidsTheme.font(12, .bold)).tracking(BP.px(5)).foregroundStyle(KidsTheme.inkMuted)
                    Text("What should we watch?")
                        .font(KidsTheme.font(52, .bold)).foregroundStyle(KidsTheme.ink)
                }
                HStack(alignment: .bottom, spacing: BP.px(14)) {
                    if cards.isEmpty {
                        ForEach(0..<5, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: BP.px(22), style: .continuous).fill(.white.opacity(0.4))
                                .overlay(RoundedRectangle(cornerRadius: BP.px(22), style: .continuous).stroke(.white.opacity(0.6), lineWidth: BP.px(2)))
                                .frame(width: Self.cardSize.width, height: Self.cardSize.height)
                                .opacity(loading ? 1 : 0.6)
                        }
                    } else {
                        ForEach(cards) { m in
                            Button { onOpen(m) } label: { card(m) }
                                .buttonStyle(KidsCardStyle())
                                .accessibilityIdentifier("kids-hero-\(m.id)")
                        }
                    }
                }
                .focusSection()
            }
            .padding(.horizontal, BP.gutter)
            .padding(.bottom, BP.px(150))
        }
        .frame(height: Self.height)
        .frame(maxWidth: .infinity)
    }

    private func card(_ m: Meta) -> some View {
        ZStack(alignment: .bottom) {
            RemoteImage(url: upsized(m.background) ?? m.poster)
            LinearGradient(colors: [.black.opacity(0.75), .black.opacity(0.1), .clear], startPoint: .bottom, endPoint: .top)
            if let logo = logos[m.id] ?? m.logo {
                KidsLogoImage(url: logo)
                    .frame(maxWidth: Self.cardSize.width * 0.86, maxHeight: BP.px(44))
                    .shadow(color: .black.opacity(0.75), radius: 9, y: 2)
                    .padding(.bottom, BP.px(12))
            } else {
                Text(m.name)
                    .font(KidsTheme.font(15, .semibold)).foregroundStyle(.white).multilineTextAlignment(.center).lineLimit(2)
                    .shadow(color: .black.opacity(0.7), radius: 8, y: 2)
                    .padding(.horizontal, BP.px(10)).padding(.bottom, BP.px(10))
            }
        }
        .frame(width: Self.cardSize.width, height: Self.cardSize.height)
        .background(KidsTheme.surface)
    }

    /// kids-hero.tsx upsizeCard: TMDB w780 backdrops drop to w500 at card size.
    private func upsized(_ url: String?) -> String? { url?.replacingOccurrences(of: "/t/p/w780/", with: "/t/p/w500/") }
}

/// A title logo with no loading plate (RemoteImage paints one, which would box the logo).
struct KidsLogoImage: View {
    let url: String
    @State private var image: UIImage?
    var body: some View {
        ZStack {
            if let image { Image(uiImage: image).resizable().aspectRatio(contentMode: .fit).transition(.opacity) }
        }
        .task(id: url) {
            guard let u = URL(string: url) else { return }
            let img = await ImageLoader.shared.image(for: u)
            withAnimation(BP.easeFast) { image = img }
        }
    }
}

// MARK: - Rows

/// CatalogRows `kids`: title in deep teal at 1.28×, portrait kids cards (PickCard kids), paged
/// when focus nears the end of a row that has more (Row onEndReached → kids.tsx loadMore).
struct KidsRowView: View {
    let row: KidsModel.Row
    let onOpen: (Meta) -> Void
    let onNearEnd: () -> Void

    static let cardWidth = BP.px(160)

    var body: some View {
        VStack(alignment: .leading, spacing: BP.px(12)) {
            Text(T(row.title))
                .font(KidsTheme.font(19 * 1.28, .bold)).foregroundStyle(KidsTheme.deep)
                .padding(.horizontal, BP.gutter)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: BP.px(18)) {
                    ForEach(Array(row.metas.enumerated()), id: \.element.id) { i, m in
                        Button { onOpen(m) } label: { KidsPosterCard(meta: m, width: Self.cardWidth) }
                            .buttonStyle(KidsCardStyle(radius: BP.px(18), onFocus: {
                                if row.hasMore, i >= row.metas.count - 6 { onNearEnd() }
                            }))
                    }
                }
                .padding(.horizontal, BP.gutter)
                .padding(.vertical, BP.px(18))
            }
            .scrollClipDisabled()
        }
        .focusSection()
    }
}

/// PickCard `kids`: the poster with rounded corners, name under it when there is no art.
struct KidsPosterCard: View {
    let meta: Meta
    let width: CGFloat
    var body: some View {
        ZStack(alignment: .bottom) {
            KidsTheme.surface
            RemoteImage(url: meta.poster ?? meta.background)
            if meta.poster == nil && meta.background == nil {
                Text(meta.name).font(KidsTheme.font(14, .semibold)).foregroundStyle(KidsTheme.deep)
                    .multilineTextAlignment(.center).lineLimit(3).padding(BP.px(10))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: width, height: (width * 1.5).rounded())
    }
}

// MARK: - Franchises

/// kids/kids-franchise-rail.tsx: "Pick a World", landscape franchise tiles (16:10) with each
/// franchise's gradient, two soft light blobs, its cut-out art and "Explore →".
struct KidsFranchiseRail: View {
    let tiles: [KidsModel.Franchise]
    let onOpen: (KidsModel.Franchise) -> Void

    static let tileWidth = BP.px(232)

    var body: some View {
        VStack(alignment: .leading, spacing: BP.px(12)) {
            Text("Pick a World")
                .font(KidsTheme.font(19 * 1.28, .bold)).foregroundStyle(KidsTheme.deep)
                .padding(.horizontal, BP.gutter)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: BP.px(18)) {
                    ForEach(tiles) { f in
                        Button { onOpen(f) } label: { KidsFranchiseTile(franchise: f, width: Self.tileWidth) }
                            .buttonStyle(KidsCardStyle(radius: BP.px(24)))
                            .accessibilityIdentifier("kids-franchise-\(f.key)")
                    }
                }
                .padding(.horizontal, BP.gutter)
                .padding(.vertical, BP.px(18))
            }
            .scrollClipDisabled()
        }
        .focusSection()
    }
}

struct KidsFranchiseTile: View {
    let franchise: KidsModel.Franchise
    let width: CGFloat

    var body: some View {
        let height = (width * 10 / 16).rounded()
        ZStack(alignment: .bottomLeading) {
            KidsGradient(stops: franchise.stops, start: .topLeading, end: .bottomTrailing)
            Circle().fill(.white.opacity(0.25)).frame(width: BP.px(128), height: BP.px(128)).blur(radius: 8)
                .position(x: width + BP.px(40) - BP.px(64), y: -BP.px(48) + BP.px(64))
            Circle().fill(.white.opacity(0.15)).frame(width: BP.px(96), height: BP.px(96)).blur(radius: 8)
                .position(x: -BP.px(24) + BP.px(48), y: height + BP.px(40) - BP.px(48))
            // `bottom-0 end-0 h-[122%] w-[80%] object-contain object-bottom`, dropped by `drop`%.
            KidsArt(franchise.art)
                .frame(width: width * 0.8, height: height * 1.22, alignment: .bottom)
                .shadow(color: .black.opacity(0.3), radius: 9, y: 10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .offset(y: height * CGFloat(franchise.drop ?? 0) / 100)
            LinearGradient(colors: [.black.opacity(0.45), .black.opacity(0.1), .clear], startPoint: .leading, endPoint: .trailing)
            VStack(alignment: .leading, spacing: BP.px(4)) {
                Text(franchise.name)
                    .font(KidsTheme.font(19, .semibold)).foregroundStyle(.white).lineLimit(2)
                    .shadow(color: .black.opacity(0.5), radius: 8, y: 2)
                HStack(spacing: BP.px(4)) {
                    Text("Explore")
                    Image(systemName: "arrow.right")
                }
                .font(KidsTheme.font(11, .semibold)).foregroundStyle(.white.opacity(0.9))
            }
            .frame(maxWidth: width * 0.52, alignment: .leading)
            .padding(.leading, BP.px(14)).padding(.bottom, BP.px(12))
        }
        .frame(width: width, height: height)
    }
}

/// A Tailwind `bg-gradient-to-*` from the engine's hex stops.
struct KidsGradient: View {
    let stops: [String]
    var start: UnitPoint = .topLeading
    var end: UnitPoint = .bottomTrailing
    var body: some View {
        let colors = stops.compactMap { Color(css: $0) }
        LinearGradient(colors: colors.isEmpty ? [KidsTheme.teal, KidsTheme.sail] : colors, startPoint: start, endPoint: end)
    }
}

// MARK: - Play Zone call to action

/// kids.tsx playZoneCta: the deep-sea banner that opens the Play Zone.
struct KidsPlayZoneCTA: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: BP.px(24)) {
                KidsArt(doodle: "lilbluewhale").frame(height: BP.px(80))
                VStack(alignment: .leading, spacing: BP.px(4)) {
                    Text("Play Zone").font(KidsTheme.font(30, .medium)).foregroundStyle(.white)
                        .shadow(color: Color(hex: 0x001428).opacity(0.45), radius: 10, y: 2)
                    Text("Games, puzzles and amazing ocean facts. Dive in!")
                        .font(KidsTheme.font(15.5, .semibold)).foregroundStyle(.white.opacity(0.8))
                }
                Spacer(minLength: BP.px(12))
                KidsArt(doodle: "lilpurpocto").frame(height: BP.px(64))
                Text("Let's play!")
                    .font(KidsTheme.font(17, .bold)).foregroundStyle(KidsTheme.sunnyInk)
                    .padding(.horizontal, BP.px(28)).frame(height: BP.px(56))
                    .background(Capsule().fill(KidsTheme.sunny))
            }
            .padding(.horizontal, BP.px(32)).padding(.vertical, BP.px(24))
            .frame(maxWidth: .infinity)
            .background(
                LinearGradient(stops: [.init(color: Color(hex: 0x1a7d9e), location: 0), .init(color: Color(hex: 0x10618a), location: 0.55), .init(color: Color(hex: 0x0a4062), location: 1)],
                               startPoint: UnitPoint(x: 0, y: 0.3), endPoint: UnitPoint(x: 1, y: 0.7))
            )
            .overlay(RoundedRectangle(cornerRadius: BP.px(16), style: .continuous).stroke(.white.opacity(0.4), lineWidth: BP.px(4)))
        }
        .buttonStyle(KidsCardStyle(radius: BP.px(16), ring: 0))
        .accessibilityIdentifier("kids-play-zone")
    }
}

// MARK: - Doodles

/// kids/kids-doodles.tsx: sea doodles scattered behind the rows (percent positions, px widths).
struct KidsDoodles: View {
    private struct Doodle { var src: String; var top: CGFloat?; var bottom: CGFloat?; var left: CGFloat?; var right: CGFloat?; var w: CGFloat; var rot: Double; var op: Double; var flip = false }

    private static let doodles: [Doodle] = [
        Doodle(src: "lilbluewhale", top: 49, right: 1, w: 66, rot: 6, op: 0.9, flip: true),
        Doodle(src: "lilwhale1", bottom: 2, left: 8, w: 62, rot: 4, op: 0.9),
        Doodle(src: "liloctored", top: 29, left: 1, w: 60, rot: -8, op: 0.9),
        Doodle(src: "lilpurpocto", top: 75, right: 0.8, w: 58, rot: 8, op: 0.9),
        Doodle(src: "lilwhitestar", top: 33, right: 2, w: 28, rot: 0, op: 0.8),
        Doodle(src: "lilpurplestar", top: 45, left: 2.5, w: 24, rot: 0, op: 0.8),
        Doodle(src: "lilorangestar2", top: 64, right: 3.5, w: 24, rot: 0, op: 0.8),
        Doodle(src: "lilwhitestar2", top: 79, left: 3.5, w: 22, rot: 0, op: 0.78),
        Doodle(src: "lilwhitestar", top: 95, right: 4, w: 26, rot: 0, op: 0.8),
        Doodle(src: "lilwhitestar2", top: 30, left: 48, w: 20, rot: 0, op: 0.72),
        Doodle(src: "lilorangestar2", top: 39, left: 61, w: 22, rot: 0, op: 0.72),
        Doodle(src: "lilpurplestar", top: 47, left: 36, w: 22, rot: 0, op: 0.7),
        Doodle(src: "lilwhitestar", top: 56, left: 53, w: 22, rot: 0, op: 0.72),
        Doodle(src: "lilwhitestar2", top: 63, left: 31, w: 20, rot: 0, op: 0.68),
        Doodle(src: "lilorangestar2", top: 71, left: 58, w: 22, rot: 0, op: 0.72),
        Doodle(src: "lilpurplestar", top: 80, left: 44, w: 22, rot: 0, op: 0.7),
        Doodle(src: "lilwhitestar", top: 87, left: 35, w: 22, rot: 0, op: 0.7),
        Doodle(src: "bubbles", top: 16, left: 3, w: 50, rot: -4, op: 0.9),
        Doodle(src: "stardots", top: 58, left: 3, w: 40, rot: -6, op: 0.88),
    ]

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                // `.kids-page-glow`: warm and cool washes, deepening towards the bottom.
                LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .clear, location: 0.24),
                                       .init(color: Color(red: 58 / 255, green: 138 / 255, blue: 156 / 255).opacity(0.16), location: 0.54),
                                       .init(color: Color(red: 34 / 255, green: 102 / 255, blue: 128 / 255).opacity(0.3), location: 0.8),
                                       .init(color: Color(red: 20 / 255, green: 78 / 255, blue: 104 / 255).opacity(0.44), location: 1)],
                               startPoint: .top, endPoint: .bottom)
                ForEach(Array(Self.doodles.enumerated()), id: \.offset) { _, d in
                    let w: CGFloat = BP.px(d.w)
                    let x: CGFloat = d.left.map { l -> CGFloat in geo.size.width * l / 100 + w / 2 } ?? (geo.size.width * (1 - (d.right ?? 0) / 100) - w / 2)
                    let y: CGFloat = d.top.map { tp -> CGFloat in geo.size.height * tp / 100 + w / 2 } ?? (geo.size.height * (1 - (d.bottom ?? 0) / 100) - w / 2)
                    KidsArt(doodle: d.src)
                        .frame(width: w)
                        .scaleEffect(x: d.flip ? -1 : 1, y: 1)
                        .rotationEffect(.degrees(d.rot))
                        .opacity(d.op)
                        .position(x: x, y: y)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
