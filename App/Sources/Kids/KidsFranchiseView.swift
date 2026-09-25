import SwiftUI

/// grid.tsx with `kidsHero` (opened by a "Pick a World" tile): the franchise's hero — first
/// backdrop or its gradient, the cut-out art, the name and "n titles" — over a kids card grid
/// that keeps paging while focus nears the end.
struct KidsFranchiseView: View {
    @StateObject private var model: KidsFranchiseModel
    @State private var detail: Meta?
    @Environment(\.dismiss) private var dismiss
    /// (open-items sweep 2) The card under the ring, and the last one it was on, so a dock that goes
    /// from under the ring (Stop and close player) hands it back to the grid.
    @FocusState private var cardFocus: String?
    @State private var lastCard: String?

    init(franchise: KidsModel.Franchise) {
        _model = StateObject(wrappedValue: KidsFranchiseModel(franchise: franchise))
    }

    private static let columns = 6
    private static let cardWidth = BP.px(140)

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: BP.px(32)) {
                hero
                grid.padding(.horizontal, BP.gutter)
            }
            .padding(.bottom, BP.px(100))
        }
        // App.tsx's music-dock.tsx is over the kids "grid" view too (KidsDetailView carries the
        // same dock): this cover hides the shell's.
        .musicDock(ringTo: { cardFocus = lastCard ?? model.metas.first?.id })
        .background(KidsTheme.canvas.ignoresSafeArea())
        .ignoresSafeArea(edges: .top)
        .task { await model.start() }
        .onExitCommand { dismiss() }
        .fullScreenCover(item: $detail) { m in KidsDetailView(meta: m) }
    }

    private var hero: some View {
        let f = model.franchise
        // grid.tsx bgArt: the first backdrop, upsized from w780 to w1280.
        let bgArt = model.metas.first(where: { $0.background != nil })?.background?.replacingOccurrences(of: "/t/p/w780/", with: "/t/p/w1280/")
        let count = model.metas.count
        return ZStack(alignment: .bottomLeading) {
            if let bgArt { RemoteImage(url: bgArt) } else { KidsGradient(stops: f.stops) }
            KidsGradient(stops: f.stops, start: .bottomLeading, end: .topTrailing).opacity(0.25).blendMode(.overlay)
            LinearGradient(stops: [.init(color: KidsTheme.canvas, location: 0), .init(color: KidsTheme.canvas.opacity(0.35), location: 0.5), .init(color: .clear, location: 1)],
                           startPoint: .bottom, endPoint: .top)
            LinearGradient(colors: [.black.opacity(0.45), .black.opacity(0.1), .clear], startPoint: .leading, endPoint: .trailing)
            // `bottom-0 end-0 h-[56%] max-w-[30%] object-contain object-bottom`.
            GeometryReader { geo in
                KidsArt(f.art)
                    .frame(maxWidth: geo.size.width * 0.3, maxHeight: geo.size.height * 0.56, alignment: .bottom)
                    .shadow(color: .black.opacity(0.4), radius: 14, y: 14)
                    .frame(width: geo.size.width, height: geo.size.height, alignment: .bottomTrailing)
            }
            VStack(alignment: .leading, spacing: BP.px(8)) {
                Text(f.name)
                    .font(KidsTheme.font(80, .heavy)).foregroundStyle(.white).lineLimit(2).minimumScaleFactor(0.6)
                    .shadow(color: .black.opacity(0.7), radius: 18, y: 4)
                Text(T(count == 1 ? "%lld title" : "%lld titles", count))
                    .font(KidsTheme.font(18, .heavy)).foregroundStyle(.white.opacity(0.95))
                    .shadow(color: .black.opacity(0.65), radius: 10, y: 2)
            }
            .frame(maxWidth: BP.px(700), alignment: .leading)
            .padding(.horizontal, BP.gutter)
            .padding(.bottom, BP.px(36))
        }
        .frame(height: BP.px(600))
        .frame(maxWidth: .infinity)
        .clipped()
    }

    @ViewBuilder private var grid: some View {
        if model.done && model.metas.isEmpty {
            VStack(spacing: BP.px(12)) {
                KidsArt(doodle: "lilpurpocto").frame(height: BP.px(80)).opacity(0.8)
                Text("Nothing here yet!").font(KidsTheme.font(24, .bold)).foregroundStyle(KidsTheme.deep)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, BP.px(80))
        } else if model.metas.isEmpty {
            ProgressView().tint(KidsTheme.deep).frame(maxWidth: .infinity).padding(.vertical, BP.px(80))
        } else {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(Self.cardWidth), spacing: BP.px(22)), count: Self.columns), alignment: .leading, spacing: BP.px(30)) {
                ForEach(Array(model.metas.enumerated()), id: \.element.id) { i, m in
                    Button { detail = m } label: { KidsPosterCard(meta: m, width: Self.cardWidth) }
                        .buttonStyle(KidsCardStyle(radius: BP.px(18), onFocus: {
                            if !model.done, i >= model.metas.count - Self.columns * 2 { Task { await model.more() } }
                        }))
                        .focused($cardFocus, equals: m.id)
                }
            }
            .focusSection()
            .onChange(of: cardFocus) { _, id in if let id { lastCard = id } }
        }
    }
}
