import SwiftUI

/// Discover room (bp-discover.tsx): Discovery Queue band → Genres → "Picked for you" rails.
/// Awards, Collections and Top People bands arrive with their features.
struct DiscoverView: View {
    @StateObject private var model = DiscoverModel()
    @FocusState private var genresFocused: Bool

    var body: some View {
        ZStack(alignment: .top) {
            SpotlightView(meta: model.spotlight, boxHeight: BP.px(160) + BP.barHeight)
                .opacity(model.spotlight == nil ? 0 : 1)
            if let failed = model.failed {
                VStack(spacing: BP.px(10)) {
                    Text("Couldn't load Discover.").font(BP.sans(19, .bold)).foregroundStyle(BP.ink)
                    BPNote(text: failed)
                }
                .padding(.top, BP.px(300)).padding(.horizontal, BP.gutter)
            } else if model.build == nil {
                ProgressView().tint(BP.inkMuted).padding(.top, BP.px(320))
            } else {
                BPRailView(rows: model.rows, onFocus: { m, _ in model.spotlight = m }, onSelect: { _ in }, topInset: BP.barHeight + BP.px(10)) {
                    section("Discover", "Discovery Queue", "One pick at a time, full screen, until something lands.") {
                        QueueBandView(queue: model.build?.queue)
                    }
                    section("Discover", "Genres", "18 shelves, one press into any of them") {
                        GenresBandView(genres: model.build?.genres ?? [], art: model.genreArt)
                            .focused($genresFocused)
                    }
                }
            }
        }
        .task { await model.load() }
        .onChange(of: genresFocused) { _, on in if on { Task { await model.loadGenreArt() } } }
    }

    private func section<C: View>(_ eyebrow: String, _ title: String, _ blurb: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: BP.px(10)) {
            VStack(alignment: .leading, spacing: BP.px(2)) {
                Text(eyebrow).font(BP.sans(11, .bold)).foregroundStyle(BP.accent).textCase(.uppercase).tracking(1)
                Text(title).font(BP.sans(19, .bold)).foregroundStyle(BP.ink)
                Text(blurb).font(BP.sans(13)).foregroundStyle(BP.inkMuted)
            }
            .padding(.horizontal, BP.gutter)
            content()
        }
    }
}

/// queue/bp-queue-band.tsx: one wide panel, blurred bed art, a fan of the next four posters.
struct QueueBandView: View {
    let queue: DiscoverModel.Build.Queue?
    private let height = BP.px(150)

    var body: some View {
        Button {} label: {
            ZStack(alignment: .leading) {
                if let bed = queue?.backdrop ?? queue?.posters.first {
                    RemoteImage(url: bed).blur(radius: 18).opacity(queue?.backdrop == nil ? 0.45 : 0.8)
                }
                LinearGradient(colors: [BP.panel, BP.panel.opacity(0.6), .clear], startPoint: .leading, endPoint: .trailing)
                HStack(spacing: BP.px(24)) {
                    VStack(alignment: .leading, spacing: BP.px(6)) {
                        Text("Discovery Queue").font(BP.display(26)).foregroundStyle(BP.ink)
                        Text(line).font(BP.sans(15, .semibold)).foregroundStyle(BP.inkMuted)
                        if let n = queue?.total, queue?.status == "ready" {
                            Text("\(n) waiting").font(BP.sans(13)).foregroundStyle(BP.inkSubtle)
                        }
                    }
                    Spacer()
                    ZStack {
                        ForEach(Array((queue?.posters ?? []).prefix(4).enumerated()), id: \.offset) { i, url in
                            RemoteImage(url: url)
                                .frame(width: BP.px(76), height: BP.px(114))
                                .clipShape(RoundedRectangle(cornerRadius: BP.px(6), style: .continuous))
                                .rotationEffect(.degrees(Double(i) * 18 - 27), anchor: .bottom)
                                .offset(x: CGFloat(i) * BP.px(18))
                                .opacity([1, 0.82, 0.6, 0.38][i])
                                .zIndex(Double(4 - i))
                        }
                    }
                    .frame(width: BP.px(200), height: height)
                    .padding(.trailing, BP.px(26))
                }
                .padding(.leading, BP.px(26))
            }
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background(BP.panel)
            .clipShape(RoundedRectangle(cornerRadius: BP.rLG, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: BP.rLG, style: .continuous).stroke(BP.edge, lineWidth: 1))
        }
        .buttonStyle(BPTileStyle(radius: BP.rLG))
        .padding(.horizontal, BP.gutter)
        .padding(.vertical, BP.px(14))
        .accessibilityIdentifier("queue-band")
    }

    private var line: String {
        switch queue?.status {
        case "ready": return "Open the queue"
        case "empty": return "Nothing left in today's picks"
        case "nokey": return "Add a TMDB key for tonight's picks"
        case "unreachable": return "No picks loaded. TMDB might be unreachable."
        default: return "Building tonight's queue…"
        }
    }
}

/// bp-genre-tiles.tsx: 5:4 tiles on the genre's palette with up to three skewed backdrops.
struct GenresBandView: View {
    let genres: [DiscoverModel.Build.Genre]
    let art: [String: [Meta]]
    private let cell = BP.px(178)

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: BP.px(9)) {
                ForEach(genres, id: \.genre) { g in
                    Button {} label: { tile(g) }
                        .buttonStyle(BPTileStyle(radius: BP.rMD))
                        .accessibilityIdentifier("genre-\(g.genre)")
                }
            }
            .padding(.horizontal, BP.gutter).padding(.vertical, BP.px(14))
        }
        .scrollClipDisabled()
        .focusSection()
    }

    private func tile(_ g: DiscoverModel.Build.Genre) -> some View {
        let from = Color(oklch: g.from) ?? BP.panel2
        let to = Color(oklch: g.to) ?? BP.void_
        let ink = Color(oklch: g.ink) ?? BP.ink
        return ZStack(alignment: .bottomLeading) {
            from
            if let metas = art[g.genre], !metas.isEmpty {
                HStack(spacing: 0) {
                    ForEach(Array(metas.prefix(3).enumerated()), id: \.offset) { i, m in
                        RemoteImage(url: m.background ?? m.poster)
                            .frame(width: cell / 3, height: cell * 0.8)
                            .clipped()
                            .transformEffect(CGAffineTransform(a: 1, b: 0, c: -0.14, d: 1, tx: CGFloat(i - 1) * 6, ty: 0))
                    }
                }
                to.blendMode(.multiply)
            }
            LinearGradient(colors: [.clear, to], startPoint: .center, endPoint: .bottom).frame(height: cell * 0.8 * 0.4).frame(maxHeight: .infinity, alignment: .bottom)
            Text(g.genre).font(BP.display(16)).foregroundStyle(ink).padding(BP.px(14))
        }
        .frame(width: cell, height: cell * 0.8)
        .clipShape(RoundedRectangle(cornerRadius: BP.rMD, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: BP.rMD, style: .continuous).stroke(BP.edge, lineWidth: 1))
    }
}
