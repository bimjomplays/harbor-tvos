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
        var context: PlaybackContext
        var upNext: String?
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
                    let ctx = PlaybackContext(meta: model.meta,
                                              season: ep?["season"]?.number.map { Int($0) }, episode: ep?["episode"]?.number.map { Int($0) },
                                              videoId: ep?["videoId"]?.string, imdbId: model.meta.id.hasPrefix("tt") ? model.meta.id : nil,
                                              imdbVerified: model.meta.id.hasPrefix("tt"))
                    // Present after the picker's cover has dismissed; a present-while-dismissing is dropped on tvOS.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            var upNext: String?
                        if let s = ctx.season, let e = ctx.episode, let idx = model.episodes.firstIndex(where: { $0.season == s && $0.episode == e }), idx + 1 < model.episodes.count {
                            let n = model.episodes[idx + 1]
                            if n.season > 0 { upNext = "S\(n.season) E\(n.episode) · \(n.title)" }
                        }
                        playing = PlayTarget(url: url, headers: link.headers ?? [:], title: model.meta.name, subtitle: sub, context: ctx, upNext: upNext)
                    }
                }
            }
        }
        .fullScreenCover(item: $playing) { t in
            PlayerScreen(title: t.title, subtitle: t.subtitle, url: t.url, headers: t.headers, context: t.context, upNext: t.upNext) { natural in
                playing = nil
                // Auto-advance (player-spec §1.9, simplified): a finished episode opens the next one's picker.
                if natural, let s = t.context.season, let e = t.context.episode,
                   let idx = model.episodes.firstIndex(where: { $0.season == s && $0.episode == e }),
                   idx + 1 < model.episodes.count {
                    let next = model.episodes[idx + 1]
                    if next.season > 0 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { picker = (model.meta, next.playEpisode) } }
                }
            }
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
                    if model.isSeries, let target = model.playTarget { picker = (model.meta, target.playEpisode) }
                    else { picker = (model.meta, nil) }
                } label: {
                    VStack(spacing: 0) {
                        Label(model.playLabel, systemImage: "play.fill")
                        // Progress under Play, only mid-way through (0.01 < progress < 0.97).
                        if let r = model.resume, r.progress > 0.01, r.progress < 0.97 {
                            GeometryReader { g in
                                Capsule().fill(BP.accent).frame(width: g.size.width * r.progress, height: BP.px(3))
                            }
                            .frame(height: BP.px(3))
                        }
                    }
                }
                .buttonStyle(BPActionStyle(primary: true))
                .accessibilityIdentifier("detail-play")
                if model.canWatchlist {
                    Button { Task { await model.toggleWatchlist() } } label: {
                        Label(model.inWatchlist ? "In Watchlist" : "Add to Watchlist", systemImage: model.inWatchlist ? "bookmark.fill" : "bookmark")
                    }
                    .buttonStyle(BPActionStyle(primary: model.inWatchlist)).disabled(model.watchlistBusy)
                }
                Button { dismiss() } label: { Label("Back", systemImage: "chevron.left") }.buttonStyle(BPActionStyle())
            }
            .focusSection()
            Text(model.meta.description ?? "").font(BP.sans(13, .regular)).foregroundStyle(BP.inkMuted).lineSpacing(4).lineLimit(4)
                .frame(maxWidth: BP.px(620), alignment: .leading)
            credits
        }
    }

    /// Crew/cast lines from Cinemeta until TMDB cast cards arrive (detail-spec §1.1 rows 4-5).
    @ViewBuilder private var credits: some View {
        let director = (model.meta.director ?? []).filter { !$0.isEmpty }
        let cast = (model.meta.cast ?? []).filter { !$0.isEmpty }
        if !director.isEmpty || !cast.isEmpty {
            VStack(alignment: .leading, spacing: BP.px(3)) {
                if !director.isEmpty { creditLine(model.isSeries ? "Created by" : "Directed by", director.prefix(3).joined(separator: ", ")) }
                if !cast.isEmpty { creditLine("Cast", cast.prefix(6).joined(separator: ", ")) }
            }
            .frame(maxWidth: BP.px(620), alignment: .leading)
        }
    }

    private func creditLine(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: BP.px(8)) {
            Text(label).font(BP.sans(12, .bold)).foregroundStyle(BP.inkSubtle).frame(width: BP.px(80), alignment: .leading)
            Text(value).font(BP.sans(12)).foregroundStyle(BP.inkMuted).lineLimit(2)
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
                        Button { picker = (model.meta, ep.playEpisode) } label: { EpisodeCell(episode: ep, watched: model.isWatched(ep)) }
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
    var watched = false
    private static let size = CGSize(width: BP.px(230), height: (BP.px(230) * 9 / 16).rounded())

    var body: some View {
        VStack(alignment: .leading, spacing: BP.px(6)) {
            ZStack(alignment: .bottomLeading) {
                RemoteImage(url: episode.thumbnail)
                LinearGradient(colors: [.clear, BP.void_.opacity(0.85)], startPoint: .center, endPoint: .bottom)
                Text("E\(episode.episode)").font(BP.sans(12, .bold)).foregroundStyle(BP.ink).padding(BP.px(8))
                if watched {
                    Image(systemName: "checkmark").font(.system(size: BP.px(10), weight: .bold)).foregroundStyle(BP.canvas)
                        .frame(width: BP.px(21), height: BP.px(21)).background(Circle().fill(BP.ink))
                        .padding(BP.px(7)).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                }
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
