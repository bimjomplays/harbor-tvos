import SwiftUI

/// Detail page (bp-detail): hero with backdrop, logo/title, facts, actions, synopsis; then episodes.
struct DetailView: View {
    @StateObject private var model: DetailModel
    @State private var picker: (meta: Meta, episode: AnyJSON?)?
    @State private var playing: PlayTarget?
    @Environment(\.dismiss) private var dismiss

    struct PlayTarget: Identifiable {
        var id: String { url.absoluteString }
        var url: URL
        var headers: [String: String]
        var title: String
        var subtitle: String?
    }

    init(meta: Meta) { _model = StateObject(wrappedValue: DetailModel(meta: meta)) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            backdrop
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: BP.px(26)) {
                    hero
                    if model.isSeries { episodes }
                    Color.clear.frame(height: BP.px(60))
                }
                .padding(.horizontal, BP.gutter)
                .padding(.top, BP.px(250))
            }
        }
        .ignoresSafeArea()
        .task { await model.load() }
        .fullScreenCover(isPresented: Binding(get: { picker != nil }, set: { if !$0 { picker = nil } })) {
            if let picker {
                PlayPickerView(meta: picker.meta, episode: picker.episode) { stream, resolved in
                    guard let link = resolved.data, let url = URL(string: link.url) else { return }
                    let ep = picker.episode
                    let sub = ep.flatMap { e -> String? in
                        guard let s = e["season"]?.number, let n = e["episode"]?.number else { return nil }
                        return "S\(Int(s)) E\(Int(n))" + (e["name"]?.string.map { " · \($0)" } ?? "")
                    }
                    self.picker = nil
                    playing = PlayTarget(url: url, headers: link.headers ?? [:], title: model.meta.name, subtitle: sub)
                }
            }
        }
        .fullScreenCover(item: $playing) { t in
            PlayerScreen(title: t.title, subtitle: t.subtitle, url: t.url, headers: t.headers) { playing = nil }
        }
    }

    private var backdrop: some View {
        ZStack {
            BP.void_
            GeometryReader { g in
                RemoteImage(url: model.meta.background ?? model.meta.poster)
                    .frame(width: g.size.width * 0.76, height: g.size.height * 0.75)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .mask(LinearGradient(colors: [.clear, .black, .black], startPoint: .leading, endPoint: .init(x: 0.45, y: 0.5)))
                    .mask(LinearGradient(colors: [.black, .black, .clear], startPoint: .top, endPoint: .init(x: 0.5, y: 0.9)))
            }
            LinearGradient(colors: [BP.void_.opacity(0.85), BP.void_.opacity(0.4), .clear], startPoint: .leading, endPoint: .init(x: 0.7, y: 0.5))
        }
        .ignoresSafeArea()
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: BP.px(14)) {
            if let logo = model.meta.logo, !logo.isEmpty {
                RemoteImage(url: logo, contentMode: .fit).frame(maxWidth: BP.px(380), maxHeight: BP.px(140), alignment: .leading)
            } else {
                Text(model.meta.name).font(BP.display(52)).foregroundStyle(BP.ink).lineLimit(2).frame(maxWidth: BP.px(700), alignment: .leading)
            }
            HStack(spacing: BP.px(12)) {
                if let r = model.meta.imdbRating, !r.isEmpty {
                    HStack(spacing: BP.px(4)) {
                        Text("IMDb").font(BP.sans(9.8, .bold)).foregroundStyle(BP.canvas).padding(.horizontal, BP.px(5)).padding(.vertical, BP.px(2)).background(RoundedRectangle(cornerRadius: BP.px(4)).fill(BP.ink))
                        Text(r).font(BP.sans(13.4, .semibold)).foregroundStyle(BP.ink)
                    }
                }
                Text(model.meta.facts).font(BP.sans(13.4, .medium)).foregroundStyle(BP.inkMuted)
            }
            HStack(spacing: BP.px(8)) {
                Button {
                    if model.isSeries, let first = model.seasonEpisodes.first { picker = (model.meta, first.playEpisode) }
                    else { picker = (model.meta, nil) }
                } label: {
                    Label(model.isSeries ? "Play S\(model.season) E\(model.seasonEpisodes.first?.episode ?? 1)" : "Play", systemImage: "play.fill")
                }
                .buttonStyle(BPActionStyle(primary: true))
                .accessibilityIdentifier("detail-play")
                Button { dismiss() } label: { Label("Back", systemImage: "chevron.left") }.buttonStyle(BPActionStyle())
            }
            .focusSection()
            Text(model.meta.description ?? "").font(BP.sans(13, .regular)).foregroundStyle(BP.inkMuted).lineSpacing(4).lineLimit(4)
                .frame(maxWidth: BP.px(620), alignment: .leading)
        }
    }

    private var episodes: some View {
        VStack(alignment: .leading, spacing: BP.px(12)) {
            HStack(spacing: BP.px(8)) {
                ForEach(model.seasons, id: \.self) { s in
                    Button(s == 0 ? "Specials" : "Season \(s)") { model.season = s }
                        .buttonStyle(BPActionStyle(primary: model.season == s))
                }
            }
            .focusSection()
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: BP.trackGap) {
                    ForEach(model.seasonEpisodes) { ep in
                        Button { picker = (model.meta, ep.playEpisode) } label: { EpisodeCell(episode: ep) }
                            .buttonStyle(BPTileStyle())
                            .accessibilityIdentifier("episode-\(ep.season)-\(ep.episode)")
                    }
                }
                .padding(.vertical, BP.px(14))
            }
            .scrollClipDisabled()
            .focusSection()
        }
    }
}

struct EpisodeCell: View {
    let episode: DetailModel.Episode
    private static let size = CGSize(width: BP.px(230), height: (BP.px(230) * 9 / 16).rounded())

    var body: some View {
        VStack(alignment: .leading, spacing: BP.px(6)) {
            ZStack(alignment: .bottomLeading) {
                RemoteImage(url: episode.thumbnail)
                LinearGradient(colors: [.clear, BP.void_.opacity(0.85)], startPoint: .center, endPoint: .bottom)
                Text("E\(episode.episode)").font(BP.sans(12, .bold)).foregroundStyle(BP.ink).padding(BP.px(8))
                if let d = episode.released, d > Date() {
                    Text("Unaired").font(BP.sans(9.8, .bold)).textCase(.uppercase).foregroundStyle(BP.canvas)
                        .padding(.horizontal, BP.px(6)).padding(.vertical, BP.px(2)).background(RoundedRectangle(cornerRadius: BP.px(4)).fill(BP.ink))
                        .padding(BP.px(7)).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
            .frame(width: Self.size.width, height: Self.size.height)
            .clipShape(RoundedRectangle(cornerRadius: BP.rXS, style: .continuous))
            Text(episode.title).font(BP.sans(12, .semibold)).foregroundStyle(BP.ink).lineLimit(1)
            if let d = episode.released { Text(d.formatted(date: .abbreviated, time: .omitted)).font(BP.sans(11)).foregroundStyle(BP.inkSubtle) }
        }
        .frame(width: Self.size.width, alignment: .leading)
    }
}
