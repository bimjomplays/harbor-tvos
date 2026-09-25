import SwiftUI

/// Stats (views/wrapped.tsx + views/wrapped/cards.tsx), reached from the Library's "Stats" chip
/// (views/library.tsx, gated by settings.wrappedButton). Upstream stacks the cards in a column;
/// on the TV they are a row of story cards the remote steps through with Left/Right, the top
/// titles open their detail page, and Back returns to the library.
@MainActor
final class WrappedModel: ObservableObject {
    struct TopTitle: Codable, Identifiable, Equatable { var title: String; var count: Int; var imdb: String?; var id: String; var type: String }
    struct Genre: Decodable, Equatable { var genre: String; var count: Int }
    struct Actor: Decodable, Equatable { var name: String; var count: Int; var photo: String? }
    struct Split: Decodable, Equatable { var movies: Int; var series: Int; var anime: Int }
    struct Play: Decodable, Equatable { var id: String; var title: String; var type: String; var watchedAt: Double }
    struct Binge: Decodable, Equatable { var date: String; var count: Int }
    struct Archetype: Decodable, Equatable { var id: String; var label: String; var blurb: String }
    struct HeatDay: Decodable, Equatable { var key: String; var count: Int; var level: Int }
    struct Stats: Decodable, Equatable {
        var source: String
        var year: Int?
        var totalTitles: Int
        var totalPlays: Int
        var estimatedHours: Int
        var topTitles: [TopTitle]
        var topGenres: [Genre]
        var topActors: [Actor]
        var posters: [String: String]
        var split: Split
        var firstPlay: Play?
        var lastPlay: Play?
        var longestBinge: Binge
        var archetype: Archetype
        var heatWeeks: [[HeatDay]]
        var bingeDate: String?
    }
    private struct Enriched: Decodable { var genres: [Genre]; var posters: [String: String]; var actors: [Actor] }

    @Published private(set) var stats: Stats?
    @Published private(set) var loading = true
    private var loaded = false

    func load() async {
        guard !loaded else { return }
        loaded = true
        let s: Stats? = try? await HarborEngine.shared.call("wrapped.load", [])
        stats = s
        loading = false
        // Second phase (enrichTopTitles): posters, genres and people land when TMDB / Cinemeta answer.
        guard let s, s.source != "empty", !s.topTitles.isEmpty else { return }
        let p = ProfilesStore.shared.active
        guard let e: Enriched = try? await HarborEngine.shared.call("wrapped.enrich", [s.topTitles, p?.id ?? "default", p?.linked ?? true]) as Enriched,
              var next = stats else { return }
        if !e.genres.isEmpty { next.topGenres = e.genres }
        next.topActors = e.actors
        next.posters = e.posters
        stats = next
    }
}

struct WrappedView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = WrappedModel()
    @State private var detail: Meta?
    @State private var focusPlaced = false
    @FocusState private var focus: String?

    private enum Card: String, CaseIterable { case hero, highlights, split, titles, actors, genres, heatmap }

    var body: some View {
        ZStack(alignment: .topLeading) {
            BPAmbientBackground()
            VStack(alignment: .leading, spacing: BP.px(14)) {
                VStack(alignment: .leading, spacing: BP.px(6)) {
                    Button { dismiss() } label: {
                        Label("My library", systemImage: "arrow.backward").textCase(.uppercase).font(BP.sans(10, .bold)).tracking(2.5)
                    }
                    .buttonStyle(BPActionStyle())
                    .focused($focus, equals: "back")
                    HStack(alignment: .lastTextBaseline, spacing: BP.px(14)) {
                        Text("Stats").font(BP.display(34, .medium)).foregroundStyle(BP.ink)
                        if let year = model.stats?.year { Text(String(year)).font(BP.sans(15, .semibold)).foregroundStyle(BP.inkSubtle) }
                        Spacer()
                        BPHeroPipsView(pips: HeroPips(total: cards.count, active: activeIndex))
                    }
                }
                .padding(.horizontal, BP.gutter)
                .focusSection()
                deck
            }
            .padding(.top, BP.px(40))
            .padding(.bottom, BP.hintHeight)
        }
        .ignoresSafeArea()
        .onExitCommand { dismiss() }
        .task {
            await model.load()
            // (bug pass) Only on arrival: `.task` runs again when a top title's detail cover
            // closes, and focus jumped from that title back to the first card.
            guard !focusPlaced else { return }
            focusPlaced = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { focus = cards.first.map { "card-\($0.rawValue)" } ?? "back" }
        }
        .fullScreenCover(item: $detail) { m in DetailView(meta: m) }
    }

    /// The cards wrapped.tsx renders for these stats, in its order; each card returns null upstream
    /// when it has nothing to show, so it is left out of the row here.
    private var cards: [Card] {
        guard let s = model.stats, s.source != "empty" else { return [] }
        return Card.allCases.filter { c in
            switch c {
            case .hero, .split: return true
            case .highlights: return !s.archetype.label.isEmpty || s.longestBinge.count > 1 || s.firstPlay != nil
            case .titles: return !s.topTitles.isEmpty
            case .actors: return !s.topActors.isEmpty
            case .genres: return !s.topGenres.isEmpty
            case .heatmap: return !s.heatWeeks.isEmpty
            }
        }
    }

    private var activeIndex: Int {
        guard let f = focus else { return 0 }
        return cards.firstIndex { f == "card-\($0.rawValue)" || (f.hasPrefix("title-") && $0 == .titles) } ?? 0
    }

    @ViewBuilder private var deck: some View {
        if model.loading {
            HStack(spacing: BP.px(18)) {
                ForEach(0..<3, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: BP.rLG, style: .continuous).fill(BP.elevated.opacity(0.4))
                        .frame(width: cardSize.width, height: cardSize.height)
                }
            }
            .padding(.horizontal, BP.gutter)
        } else if let s = model.stats, s.source != "empty" {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: BP.px(18)) {
                    ForEach(cards, id: \.self) { c in card(c, s) }
                }
                .padding(.horizontal, BP.gutter)
                .padding(.vertical, BP.px(16))
            }
            .focusSection()
        } else {
            empty.padding(.horizontal, BP.gutter)
        }
    }

    private var cardSize: CGSize { CGSize(width: BP.px(560), height: BP.px(400)) }

    @ViewBuilder private func card(_ c: Card, _ s: WrappedModel.Stats) -> some View {
        switch c {
        case .titles:
            // TopTitlesCard: the rows are the focus targets, each opens its title.
            shell(tint: false) { titles(s) }
        default:
            Button {} label: {
                shell(tint: c == .hero || c == .highlights) {
                    switch c {
                    case .hero: hero(s)
                    case .highlights: highlights(s)
                    case .split: split(s)
                    case .actors: actors(s)
                    case .genres: genres(s)
                    case .heatmap: heatmap(s)
                    case .titles: EmptyView()
                    }
                }
            }
            .buttonStyle(BPTileStyle(radius: BP.rLG))
            .focused($focus, equals: "card-\(c.rawValue)")
        }
    }

    /// cards.tsx Card: rounded panel, the tinted variant for Hero and Highlights.
    private func shell<C: View>(tint: Bool, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 0) { content() }
            .padding(BP.px(24))
            .frame(width: cardSize.width, height: cardSize.height, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: BP.rLG, style: .continuous)
                    .fill(tint
                          ? AnyShapeStyle(LinearGradient(colors: [BP.accent.opacity(0.15), BP.elevated.opacity(0.5), BP.elevated.opacity(0.3)], startPoint: .topLeading, endPoint: .bottomTrailing))
                          : AnyShapeStyle(BP.elevated.opacity(0.45)))
            )
            .overlay(RoundedRectangle(cornerRadius: BP.rLG, style: .continuous).stroke(BP.edge, lineWidth: 1))
    }

    private func label(_ text: String) -> some View {
        Text(T(text).uppercased()).font(BP.sans(10, .semibold)).tracking(2.5).foregroundStyle(BP.inkSubtle).padding(.bottom, BP.px(12))
    }

    // HeroCard
    private func hero(_ s: WrappedModel.Stats) -> some View {
        VStack(alignment: .leading, spacing: BP.px(18)) {
            HStack(alignment: .lastTextBaseline, spacing: BP.px(36)) {
                stat(s.estimatedHours.formatted(), "hours watched", big: true)
                stat(s.totalTitles.formatted(), "titles")
                stat(s.totalPlays.formatted(), "plays")
            }
            Spacer(minLength: 0)
            if s.source == "local" {
                Text("Estimated from your local history. Connect Trakt or Simkl for the full picture.")
                    .font(BP.sans(12)).foregroundStyle(BP.inkSubtle).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func stat(_ value: String, _ unit: String, big: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: BP.px(4)) {
            Text(value).font(BP.display(big ? 64 : 40, .medium)).foregroundStyle(BP.ink).lineLimit(1).minimumScaleFactor(0.5)
            Text(T(unit)).font(BP.sans(13)).foregroundStyle(BP.inkMuted)
        }
    }

    // HighlightsCard
    private func highlights(_ s: WrappedModel.Stats) -> some View {
        VStack(alignment: .leading, spacing: BP.px(16)) {
            label("Highlights")
            if !s.archetype.label.isEmpty { highlight("sparkles", s.archetype.label, s.archetype.blurb) }
            if s.longestBinge.count > 1 {
                let date = s.bingeDate ?? s.longestBinge.date
                highlight("flame", "Longest binge", T("%lld in a day", s.longestBinge.count) + " · " + date)
            }
            if let first = s.firstPlay { highlight("calendar.badge.clock", "Where it started", first.title) }
        }
    }

    private func highlight(_ icon: String, _ title: String, _ body: String) -> some View {
        HStack(alignment: .top, spacing: BP.px(14)) {
            Image(systemName: icon).font(.system(size: BP.px(16), weight: .semibold)).foregroundStyle(BP.accent)
                .frame(width: BP.px(36), height: BP.px(36))
                .background(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).fill(BP.canvas.opacity(0.6)))
            VStack(alignment: .leading, spacing: 2) {
                Text(T(title)).font(BP.sans(14, .semibold)).foregroundStyle(BP.ink)
                Text(body).font(BP.sans(12.5)).foregroundStyle(BP.inkMuted).lineLimit(2)
            }
        }
    }

    // SplitCard
    private struct SplitRow: Identifiable { var icon: String; var label: String; var n: Int; var color: Color; var id: String { label } }
    private func split(_ s: WrappedModel.Stats) -> some View {
        let total = max(1, s.split.movies + s.split.series + s.split.anime)
        let rows = [
            SplitRow(icon: "film", label: "Movies", n: s.split.movies, color: Color(hex: 0x38bdf8)),
            SplitRow(icon: "tv", label: "Series", n: s.split.series, color: Color(hex: 0xa78bfa)),
            SplitRow(icon: "sparkles", label: "Anime", n: s.split.anime, color: Color(hex: 0x34d399)),
        ]
        return VStack(alignment: .leading, spacing: BP.px(16)) {
            label("What you watched")
            ForEach(rows) { r in
                HStack(spacing: BP.px(12)) {
                    Image(systemName: r.icon).foregroundStyle(BP.inkMuted).frame(width: BP.px(22))
                    Text(T(r.label)).font(BP.sans(13.5)).foregroundStyle(BP.inkMuted).frame(width: BP.px(70), alignment: .leading)
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(BP.canvas.opacity(0.7))
                            Capsule().fill(r.color).frame(width: g.size.width * CGFloat(r.n) / CGFloat(total))
                        }
                    }
                    .frame(height: BP.px(10))
                    Text("\(r.n)").font(BP.sans(13, .semibold)).foregroundStyle(BP.ink).monospacedDigit().frame(width: BP.px(44), alignment: .trailing)
                }
            }
        }
    }

    // TopTitlesCard
    private func titles(_ s: WrappedModel.Stats) -> some View {
        VStack(alignment: .leading, spacing: BP.px(2)) {
            label("Top titles")
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: BP.px(4)) {
                    ForEach(Array(s.topTitles.prefix(10).enumerated()), id: \.element.id) { i, tt in
                        Button {
                            detail = Meta(id: tt.id, type: tt.type, name: tt.title, poster: s.posters[tt.id])
                        } label: {
                            HStack(spacing: BP.px(10)) {
                                Text("\(i + 1)").font(BP.display(15)).foregroundStyle(BP.inkSubtle).frame(width: BP.px(20), alignment: .trailing)
                                RemoteImage(url: s.posters[tt.id]).frame(width: BP.px(24), height: BP.px(36))
                                    .clipShape(RoundedRectangle(cornerRadius: BP.px(4), style: .continuous))
                                Text(tt.title).font(BP.sans(14.5)).foregroundStyle(BP.ink).lineLimit(1)
                                Spacer(minLength: 0)
                                Text("\(tt.count)").font(BP.sans(12.5, .semibold)).foregroundStyle(BP.inkMuted).monospacedDigit()
                            }
                            .padding(.horizontal, BP.px(8)).padding(.vertical, BP.px(3))
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(BPTileStyle(radius: BP.rSM))
                        .focused($focus, equals: "title-\(tt.id)")
                    }
                }
                .padding(BP.px(6))
            }
        }
        .focusSection()
    }

    // ActorsCard
    private func actors(_ s: WrappedModel.Stats) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            label("People you watch")
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], alignment: .leading, spacing: BP.px(12)) {
                ForEach(s.topActors, id: \.name) { a in
                    HStack(spacing: BP.px(10)) {
                        ZStack {
                            Circle().fill(BP.canvas.opacity(0.7))
                            if let photo = a.photo { RemoteImage(url: photo).clipShape(Circle()) }
                            else { Text(initials(a.name)).font(BP.display(13)).foregroundStyle(BP.inkSubtle) }
                        }
                        .frame(width: BP.px(40), height: BP.px(40))
                        .overlay(Circle().stroke(BP.edge, lineWidth: 1))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(a.name).font(BP.sans(13.5, .medium)).foregroundStyle(BP.ink).lineLimit(1)
                            Text("\(a.count) titles").font(BP.sans(11.5)).foregroundStyle(BP.inkMuted)
                        }
                    }
                }
            }
        }
    }

    /// cards.tsx initials().
    private func initials(_ name: String) -> String {
        let parts = name.split(whereSeparator: \.isWhitespace)
        let first = parts.first?.first.map(String.init) ?? ""
        let last = parts.count > 1 ? (parts.last?.first.map(String.init) ?? "") : ""
        let out = (first + last).uppercased()
        return out.isEmpty ? "?" : out
    }

    // GenresCard
    private func genres(_ s: WrappedModel.Stats) -> some View {
        let maxCount = max(1, s.topGenres.first?.count ?? 1)
        return VStack(alignment: .leading, spacing: BP.px(12)) {
            label("Top genres")
            ForEach(s.topGenres, id: \.genre) { g in
                HStack(spacing: BP.px(12)) {
                    Text(g.genre).font(BP.sans(13.5)).foregroundStyle(BP.ink).lineLimit(1).frame(width: BP.px(120), alignment: .leading)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(BP.canvas.opacity(0.7))
                            Capsule().fill(BP.accent.opacity(0.8)).frame(width: geo.size.width * CGFloat(g.count) / CGFloat(maxCount))
                        }
                    }
                    .frame(height: BP.px(8))
                }
            }
        }
    }

    // HeatmapCard: cards.tsx heatColor as the engine's level (0 empty … 4 full accent).
    private func heatmap(_ s: WrappedModel.Stats) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            label("Your watch year")
            HStack(alignment: .top, spacing: BP.px(1.8)) {
                ForEach(Array(s.heatWeeks.enumerated()), id: \.offset) { _, week in
                    VStack(spacing: BP.px(1.8)) {
                        ForEach(week, id: \.key) { d in
                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                .fill(heat(d.level))
                                .frame(width: BP.px(7.4), height: BP.px(7.4))
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func heat(_ level: Int) -> Color {
        switch level {
        case 4: return BP.accent
        case 3: return BP.accent.opacity(0.7)
        case 2: return BP.accent.opacity(0.45)
        case 1: return BP.accent.opacity(0.25)
        default: return BP.canvas.opacity(0.5)
        }
    }

    // WrappedEmpty
    private var empty: some View {
        VStack(spacing: BP.px(12)) {
            Image(systemName: "chart.bar").font(.system(size: BP.px(24))).foregroundStyle(BP.inkSubtle)
            Text("Nothing to show yet").font(BP.display(22, .medium)).foregroundStyle(BP.ink)
            Text("Connect Trakt or Simkl, or start watching, and your stats will build themselves.")
                .font(BP.sans(13.5)).foregroundStyle(BP.inkMuted).multilineTextAlignment(.center).frame(maxWidth: BP.px(380))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, BP.px(60))
        .background(RoundedRectangle(cornerRadius: BP.rLG, style: .continuous).fill(BP.canvas.opacity(0.3)))
        .overlay(RoundedRectangle(cornerRadius: BP.rLG, style: .continuous).strokeBorder(BP.edge2, style: StrokeStyle(lineWidth: 1, dash: [6, 4])))
    }
}
