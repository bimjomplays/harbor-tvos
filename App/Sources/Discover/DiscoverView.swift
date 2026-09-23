import SwiftUI

/// Discover room (bp-discover.tsx): Discovery Queue band → Genres → "Picked for you" rails.
/// Awards, Collections and Top People bands arrive with their features.
struct DiscoverView: View {
    @StateObject private var model = DiscoverModel()
    @State private var detail: Meta?
    @State private var awardDetail: DiscoverModel.Awards.Summary?

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
                BPRailView(rows: model.rows, onFocus: { m, _ in model.spotlight = m }, onSelect: { detail = $0 }, topInset: BP.barHeight + BP.px(10)) {
                    section("Discover", "Discovery Queue", "One pick at a time, full screen, until something lands.") {
                        QueueBandView(queue: model.build?.queue)
                    }
                    if !model.people.isEmpty {
                        section("Discover", "Top People", "Top \(model.people.count), ranked by the work they left behind") {
                            PeopleBandView(people: model.people)
                        }
                    }
                    if let aw = model.awards, !aw.summaries.isEmpty {
                        section("Discover", "Awards", aw.overview.span.isEmpty ? "Every winner Harbor ships, browsable offline by year and category." : "\(aw.overview.bodies) awards, \(aw.overview.wins) winners, \(aw.overview.span), all offline") {
                            AwardsBandView(summaries: aw.summaries) { awardDetail = $0 }
                        }
                    }
                    section("Discover", "Genres", "18 shelves, one press into any of them") {
                        GenresBandView(genres: model.build?.genres ?? [], art: model.genreArt) {
                            Task { await model.loadGenreArt() }
                        }
                    }
                }
            }
        }
        .task { await model.load() }
        .fullScreenCover(item: $detail) { m in DetailView(meta: m) }
        .fullScreenCover(item: $awardDetail) { a in AwardDetailView(summary: a) }
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
    /// Fired the first time any genre tile takes focus (art is fetched lazily, as upstream does).
    let onFocus: () -> Void
    @FocusState private var focusedGenre: String?
    private let cell = BP.px(178)

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: BP.px(9)) {
                ForEach(genres, id: \.genre) { g in
                    Button {} label: { tile(g) }
                        .buttonStyle(BPTileStyle(radius: BP.rMD))
                        .focused($focusedGenre, equals: g.genre)
                        .accessibilityIdentifier("genre-\(g.genre)")
                }
            }
            .padding(.horizontal, BP.gutter).padding(.vertical, BP.px(14))
        }
        .scrollClipDisabled()
        .focusSection()
        .onChange(of: focusedGenre) { _, g in if g != nil { onFocus() } }
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


/// bp-awards-band: one tile per award body on its tint, with wins and years.
struct AwardsBandView: View {
    let summaries: [DiscoverModel.Awards.Summary]
    let onOpen: (DiscoverModel.Awards.Summary) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: BP.px(9)) {
                ForEach(summaries) { a in
                    Button { onOpen(a) } label: {
                        VStack(alignment: .leading, spacing: BP.px(6)) {
                            Text(a.shorthand).font(BP.display(22)).foregroundStyle(BP.ink)
                            Text(a.title).font(BP.sans(12, .semibold)).foregroundStyle(BP.ink.opacity(0.85)).lineLimit(2)
                            Spacer(minLength: 0)
                            Text("\(a.wins) winners · \(a.span)").font(BP.sans(11)).foregroundStyle(BP.ink.opacity(0.7))
                        }
                        .padding(BP.px(14))
                        .frame(width: BP.px(178), height: BP.px(120), alignment: .topLeading)
                        .background(RoundedRectangle(cornerRadius: BP.rMD, style: .continuous).fill(Color(oklch: a.tint) ?? Color(css: a.tint) ?? BP.panel2))
                        .overlay(RoundedRectangle(cornerRadius: BP.rMD, style: .continuous).fill(LinearGradient(colors: [.clear, .black.opacity(0.35)], startPoint: .top, endPoint: .bottom)))
                    }
                    .buttonStyle(BPTileStyle(radius: BP.rMD))
                    .accessibilityIdentifier("award-\(a.type)")
                }
            }
            .padding(.horizontal, BP.gutter).padding(.vertical, BP.px(14))
        }
        .scrollClipDisabled()
        .focusSection()
    }
}

/// bp-people-band: portrait circles with rank and name.
struct PeopleBandView: View {
    let people: [DiscoverModel.Person]
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: BP.trackGap) {
                ForEach(people) { p in
                    Button {} label: {
                        VStack(spacing: BP.px(8)) {
                            ZStack(alignment: .bottomLeading) {
                                RemoteImage(url: p.portrait).frame(width: BP.px(110), height: BP.px(110)).clipShape(Circle())
                                Text("#\(p.rank)").font(BP.sans(10, .bold)).foregroundStyle(BP.canvas)
                                    .padding(.horizontal, BP.px(6)).padding(.vertical, BP.px(2)).background(Capsule().fill(BP.ink))
                            }
                            Text(p.name).font(BP.sans(12, .semibold)).foregroundStyle(BP.ink).lineLimit(1)
                        }
                        .frame(width: BP.px(130))
                    }
                    .buttonStyle(BPTileStyle(radius: BP.px(55)))
                }
            }
            .padding(.horizontal, BP.gutter).padding(.vertical, BP.px(14))
        }
        .scrollClipDisabled()
        .focusSection()
    }
}

/// Award body detail: categories with winners by year (offline catalog).
struct AwardDetailView: View {
    let summary: DiscoverModel.Awards.Summary
    @State private var detail: Detail?
    @Environment(\.dismiss) private var dismiss

    struct Detail: Decodable {
        struct Category: Decodable { var id: String?; var label: String?; var name: String? }
        struct Entry: Decodable { var year: Int; var title: String?; var recipients: [String]? }
        struct Group: Decodable, Identifiable { var category: Category; var entries: [Entry]; var id: String { category.id ?? category.label ?? category.name ?? UUID().uuidString } }
        var title: String
        var wins: Int
        var span: String
        var groups: [Group]
    }

    var body: some View {
        ZStack {
            BPAmbientBackground()
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: BP.px(18)) {
                    Text(summary.title).font(BP.display(36)).foregroundStyle(BP.ink)
                    Text("\(summary.wins) winners · \(summary.span)").font(BP.sans(14)).foregroundStyle(BP.inkMuted)
                    Button("Back") { dismiss() }.buttonStyle(BPActionStyle())
                    if let detail {
                        ForEach(detail.groups) { g in
                            VStack(alignment: .leading, spacing: BP.px(6)) {
                                Text(g.category.label ?? g.category.name ?? g.category.id ?? "Category").font(BP.sans(17, .bold)).foregroundStyle(BP.ink)
                                ForEach(Array(g.entries.prefix(12).enumerated()), id: \.offset) { _, e in
                                    HStack(alignment: .top, spacing: BP.px(10)) {
                                        Text(String(e.year)).font(BP.sans(13, .semibold)).foregroundStyle(BP.accent).frame(width: BP.px(46), alignment: .leading)
                                        Text([e.title, e.recipients?.joined(separator: ", ")].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " — ")).font(BP.sans(13)).foregroundStyle(BP.inkMuted).lineLimit(2)
                                    }
                                }
                            }
                            .padding(BP.px(16))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: BP.rMD, style: .continuous).fill(BP.panel))
                            .focusable()
                        }
                    } else {
                        ProgressView().tint(BP.inkMuted)
                    }
                }
                .padding(.horizontal, BP.gutter).padding(.vertical, BP.px(50))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .ignoresSafeArea()
        .task { detail = try? await HarborEngine.shared.call("discoverRoom.awardDetail", [summary.type]) }
    }
}
