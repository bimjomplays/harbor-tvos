import SwiftUI

/// Detail page (bp-detail): hero with backdrop, logo/title, facts, actions, synopsis; then episodes.
struct DetailView: View {
    @StateObject private var model: DetailModel
    @State private var picker: (meta: Meta, episode: AnyJSON?)?
    /// use-bp-stream-play autoPlay: Play and auto-advance fire the best source; "Sources" never does.
    @State private var pickerAuto = false
    @State private var playing: PlayTarget?
    /// bp-player-sources: the position the next pick resumes from after "Switch source".
    @State private var switchFromSec: Double?
    @State private var related: Meta?
    @State private var listDialog = false
    @State private var factsDialog = false
    @State private var awardType: DetailModel.TitleAwards.Group?
    @State private var seasonsSheet = false
    @State private var rateDialog = false
    @State private var person: DetailModel.Extras.Cast?
    @Environment(\.dismiss) private var dismiss

    struct PlayTarget: Identifiable {
        var id: String { url.absoluteString }
        var url: URL
        var headers: [String: String]
        var title: String
        var subtitle: String?
        var context: PlaybackContext
        var upNext: String?
        var episode: AnyJSON?
    }

    /// Quick panel / Discovery Queue "Play now": open the picker as soon as the page knows what to play.
    var autoPlay = false
    init(meta: Meta, autoPlay: Bool = false) { _model = StateObject(wrappedValue: DetailModel(meta: meta)); self.autoPlay = autoPlay }

    var body: some View {
        ZStack(alignment: .topLeading) {
            backdrop
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: BP.px(26)) {
                    VStack(alignment: .leading, spacing: BP.px(26)) {
                        hero
                        if model.isSeries { episodes }
                    }
                    .padding(.horizontal, BP.gutter)
                    // Rail rows carry their own gutter (BPRowView), so they sit outside the padded column.
                    tmdbRows
                    Color.clear.frame(height: BP.px(60))
                }
                .padding(.top, BP.px(250))
            }
        }
        .ignoresSafeArea()
        .task {
            await model.load()
            if autoPlay, picker == nil {
                pickerAuto = SettingsBridge.shared.slice.instantPlay ?? true
                if model.isSeries, let target = model.playTarget { picker = (model.meta, target.playEpisode) } else { picker = (model.meta, nil) }
            }
        }
        .fullScreenCover(isPresented: Binding(get: { picker != nil }, set: { if !$0 { picker = nil } })) {
            if let picker {
                PlayPickerView(meta: picker.meta, episode: picker.episode, autoPlay: pickerAuto) { stream, resolved in
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
                                              imdbVerified: model.meta.id.hasPrefix("tt"), homeServer: resolved.homeServer,
                                              explicitStartSec: switchFromSec)
                    switchFromSec = nil
                    // Present after the picker's cover has dismissed; a present-while-dismissing is dropped on tvOS.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            var upNext: String?
                        if let s = ctx.season, let e = ctx.episode, let idx = model.episodes.firstIndex(where: { $0.season == s && $0.episode == e }), idx + 1 < model.episodes.count {
                            let n = model.episodes[idx + 1]
                            if n.season > 0 { upNext = "S\(n.season) E\(n.episode) · \(n.title)" }
                        }
                        playing = PlayTarget(url: url, headers: link.headers ?? [:], title: model.meta.name, subtitle: sub, context: ctx, upNext: upNext, episode: ep)
                    }
                }
            }
        }
        .fullScreenCover(item: $related) { m in DetailView(meta: m) }
        .fullScreenCover(isPresented: $listDialog) { ListDialogView(meta: model.meta) }
        .fullScreenCover(isPresented: $factsDialog) { FactsDialogView(title: model.meta.name, facts: model.extras?.facts ?? []) }
        .fullScreenCover(isPresented: $seasonsSheet) {
            SeasonsSheet(seasons: model.seasons, counts: Dictionary(grouping: model.episodes, by: \.season).mapValues(\.count), season: Binding(get: { model.season }, set: { model.season = $0 }))
        }
        .fullScreenCover(item: $awardType) { g in AwardsDialogView(group: g, entries: (model.awards?.entries ?? []).filter { $0.type == g.type }) }
        .fullScreenCover(isPresented: $rateDialog) { RateDialogView(meta: model.meta) }
        .fullScreenCover(item: $person) { c in PersonView(personId: c.id, name: c.name) }
        .fullScreenCover(item: $playing) { t in
            PlayerScreen(title: t.title, subtitle: t.subtitle, url: t.url, headers: t.headers, context: t.context, upNext: t.upNext,
                         onChooseAnother: { pickerAuto = false; DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { picker = (model.meta, t.episode) } },
                         onSwitchSource: { at in pickerAuto = false; switchFromSec = at; DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { picker = (model.meta, t.episode) } }) { natural in
                playing = nil
                // Auto-advance (player-spec §1.9, simplified): a finished episode opens the next one's picker.
                if natural, let s = t.context.season, let e = t.context.episode,
                   let idx = model.episodes.firstIndex(where: { $0.season == s && $0.episode == e }),
                   idx + 1 < model.episodes.count {
                    let next = model.episodes[idx + 1]
                    if next.season > 0 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { pickerAuto = SettingsBridge.shared.slice.instantPlay ?? true; picker = (model.meta, next.playEpisode) } }
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
                // bp-detail: every provider the detail settings allow (use-bp-card-badges "detail").
                ScoreChipsView(meta: model.meta, surface: "detail", limit: 6)
                Text(model.meta.facts).font(BP.sans(13.4, .medium)).foregroundStyle(BP.inkMuted)
            }
            HStack(spacing: BP.px(8)) {
                Button {
                    pickerAuto = SettingsBridge.shared.slice.instantPlay ?? true
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
                if SettingsBridge.shared.slice.instantPlay ?? true {
                    // bp-detail-actions "Sources": the list, never auto-fired.
                    Button { pickerAuto = false; if model.isSeries, let target = model.playTarget { picker = (model.meta, target.playEpisode) } else { picker = (model.meta, nil) } } label: { Label("Sources", systemImage: "list.bullet") }
                        .buttonStyle(BPActionStyle())
                }
                if model.canWatchlist {
                    Button { Task { await model.toggleWatchlist() } } label: {
                        Label(model.inWatchlist ? "In Watchlist" : "Add to Watchlist", systemImage: model.inWatchlist ? "bookmark.fill" : "bookmark")
                    }
                    .buttonStyle(BPActionStyle(primary: model.inWatchlist)).disabled(model.watchlistBusy)
                }
                // bp-detail-actions: rate and add to a custom list from the TV.
                Button { rateDialog = true } label: { Label("Rate", systemImage: "star") }.buttonStyle(BPActionStyle())
                Button { listDialog = true } label: { Label("Add to list", systemImage: "text.badge.plus") }.buttonStyle(BPActionStyle())
                Button { dismiss() } label: { Label("Back", systemImage: "chevron.left") }.buttonStyle(BPActionStyle())
            }
            .focusSection()
            if let tag = model.extras?.tagline, !tag.isEmpty {
                Text(tag).font(BP.sans(14, .semibold)).italic().foregroundStyle(BP.inkMuted).lineLimit(1).frame(maxWidth: BP.px(620), alignment: .leading)
            }
            Text(model.meta.description ?? model.extras?.overview ?? "").font(BP.sans(13, .regular)).foregroundStyle(BP.inkMuted).lineSpacing(4).lineLimit(4)
                .frame(maxWidth: BP.px(620), alignment: .leading)
            if let providers = model.extras?.watchOn, !providers.isEmpty { watchOn(providers) }
            credits
        }
    }

    // bp-watch-on-row: provider marks, not a picker.
    private func watchOn(_ providers: [DetailModel.Extras.Provider]) -> some View {
        HStack(spacing: BP.px(8)) {
            Text("Watch on").font(BP.sans(11, .bold)).tracking(1).foregroundStyle(BP.inkSubtle)
            ForEach(providers.prefix(8)) { p in
                RemoteImage(url: p.logo, contentMode: .fit).frame(width: BP.px(28), height: BP.px(28)).clipShape(RoundedRectangle(cornerRadius: BP.px(6), style: .continuous))
                    .accessibilityLabel(p.name)
            }
        }
    }

    /// The rows under the hero (detail-spec §1.1 order): cast, collection, More Like This, You Might Also Like, facts.
    @ViewBuilder private var tmdbRows: some View {
        if !model.characters.isEmpty { charactersRow }
        if let a = model.awards, !a.groups.isEmpty { awardsRow(a) }
        if !model.isAnimeId, !SettingsBridge.shared.slice.tmdbKey.isEmpty { GalleryRow(meta: model.meta) }
        if let x = model.extras {
            if !x.cast.isEmpty { castRow(x.cast) }
            if let col = model.collectionRow { BPRowView(row: col, onFocus: { _ in }, onSelect: { related = $0 }) }
            if !x.recommendations.isEmpty { BPRowView(row: BrowseRow(key: "recommendations", title: "More Like This", metas: x.recommendations), onFocus: { _ in }, onSelect: { related = $0 }) }
            if !x.similar.isEmpty { BPRowView(row: BrowseRow(key: "similar", title: "You Might Also Like", metas: x.similar), onFocus: { _ in }, onSelect: { related = $0 }) }
            if !x.facts.isEmpty { factsCard(x.facts) }
        }
    }

    // detail/bp-awards-row: one cell per award body; Select opens the categories and years.
    private func awardsRow(_ a: DetailModel.TitleAwards) -> some View {
        VStack(alignment: .leading, spacing: BP.px(10)) {
            Text("Awards & Recognition").font(BP.sans(19, .bold)).foregroundStyle(BP.ink).padding(.horizontal, BP.gutter)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: BP.px(10)) {
                    ForEach(a.groups) { g in
                        Button { awardType = g } label: {
                            VStack(alignment: .leading, spacing: BP.px(4)) {
                                Text(g.title).font(BP.sans(14, .bold)).foregroundStyle(BP.ink).lineLimit(1)
                                Text(g.wins > 0 ? "\(g.wins) win\(g.wins == 1 ? "" : "s")" + (g.nominations > 0 ? " · \(g.nominations) nomination\(g.nominations == 1 ? "" : "s")" : "") : "\(g.nominations) nomination\(g.nominations == 1 ? "" : "s")")
                                    .font(BP.sans(12)).foregroundStyle(BP.inkMuted)
                            }
                            .padding(BP.px(14)).frame(width: BP.px(260), alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).fill(BP.panel2))
                        }
                        .buttonStyle(BPTileStyle(radius: BP.rSM))
                    }
                }
                .padding(.horizontal, BP.gutter).padding(.vertical, BP.px(10))
            }
            .scrollClipDisabled()
        }
        .focusSection()
    }

    // bp-anime-characters: AniList characters, distinct from the cast row.
    private var charactersRow: some View {
        VStack(alignment: .leading, spacing: BP.px(10)) {
            Text("Characters").font(BP.sans(19, .bold)).foregroundStyle(BP.ink).padding(.horizontal, BP.gutter)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: BP.trackGap) {
                    ForEach(model.characters.prefix(20)) { c in
                        VStack(spacing: BP.px(8)) {
                            RemoteImage(url: c.image).frame(width: BP.px(110), height: BP.px(110)).clipShape(Circle())
                            Text(c.name).font(BP.sans(12, .semibold)).foregroundStyle(BP.ink).lineLimit(1)
                            if let r = c.role, !r.isEmpty { Text(r.capitalized).font(BP.sans(10)).foregroundStyle(BP.inkSubtle).lineLimit(1) }
                        }
                        .frame(width: BP.px(130))
                        .focusable()
                    }
                }
                .padding(.horizontal, BP.gutter).padding(.vertical, BP.px(14))
            }
            .scrollClipDisabled()
        }
        .focusSection()
    }

    // bp-cast-row: round portraits, name over character, up to 20.
    private func castRow(_ cast: [DetailModel.Extras.Cast]) -> some View {
        VStack(alignment: .leading, spacing: BP.px(10)) {
            Text("Cast").font(BP.sans(19, .bold)).foregroundStyle(BP.ink).padding(.horizontal, BP.gutter)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: BP.trackGap) {
                    ForEach(cast) { person in
                        Button { self.person = person } label: {
                            VStack(spacing: BP.px(8)) {
                                ZStack {
                                    Circle().fill(BP.panel2)
                                    if let p = person.profile { RemoteImage(url: p).clipShape(Circle()) } else { Image(systemName: "person.fill").font(.system(size: BP.px(30))).foregroundStyle(BP.inkSubtle) }
                                }
                                .frame(width: BP.px(110), height: BP.px(110))
                                Text(person.name).font(BP.sans(12, .semibold)).foregroundStyle(BP.ink).lineLimit(1)
                                Text(person.character).font(BP.sans(10)).foregroundStyle(BP.inkSubtle).lineLimit(1)
                            }
                            .frame(width: BP.px(130))
                        }
                        .buttonStyle(BPTileStyle(radius: BP.px(55)))
                    }
                }
                .padding(.horizontal, BP.gutter).padding(.vertical, BP.px(14))
            }
            .scrollClipDisabled()
        }
        .focusSection()
    }

    // bp-facts: a preview card of the first rows.
    private func factsCard(_ facts: [DetailModel.Extras.Fact]) -> some View {
        VStack(alignment: .leading, spacing: BP.px(6)) {
            Text("Details").font(BP.sans(19, .bold)).foregroundStyle(BP.ink)
            ForEach(facts.prefix(8)) { f in
                HStack(alignment: .top, spacing: BP.px(8)) {
                    Text(f.label).font(BP.sans(12, .bold)).foregroundStyle(BP.inkSubtle).frame(width: BP.px(120), alignment: .leading)
                    Text(f.value).font(BP.sans(12)).foregroundStyle(BP.inkMuted).lineLimit(2)
                }
            }
        }
        .padding(BP.px(16))
        .frame(maxWidth: BP.px(620), alignment: .leading)
        .background(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).fill(BP.panel2))
        .padding(.horizontal, BP.gutter)
        .focusable()
        // bp-facts-dialog: Select opens every row in a scrollable sheet.
        .onTapGesture { factsDialog = true }
        .onPlayPauseCommand { factsDialog = true }
    }

    /// Crew/cast lines from Cinemeta until TMDB cast cards arrive (detail-spec §1.1 rows 4-5).
    @ViewBuilder private var credits: some View {
        let director = (model.meta.director ?? []).filter { !$0.isEmpty }
        let cast = (model.meta.cast ?? []).filter { !$0.isEmpty }
        if let crew = model.extras?.crew, !crew.isEmpty {
            // bp-crew-row: each name is a cell into the Person page when TMDB knows the person.
            VStack(alignment: .leading, spacing: BP.px(6)) {
                ForEach(crew.prefix(5)) { c in
                    HStack(alignment: .top, spacing: BP.px(8)) {
                        Text(c.label).font(BP.sans(12, .bold)).foregroundStyle(BP.inkSubtle).frame(width: BP.px(80), alignment: .leading)
                        HStack(spacing: BP.px(6)) {
                            ForEach(Array((c.people ?? c.names.map { DetailModel.Extras.Crew.Person(id: nil, name: $0) }).enumerated()), id: \.offset) { _, p in
                                if let id = p.id {
                                    Button(p.name) { person = DetailModel.Extras.Cast(id: id, name: p.name, character: "", profile: nil) }.buttonStyle(BPActionStyle())
                                } else {
                                    Text(p.name).font(BP.sans(12)).foregroundStyle(BP.inkMuted)
                                }
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: BP.px(760), alignment: .leading)
            .focusSection()
        } else if !director.isEmpty || !cast.isEmpty {
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
                ForEach(model.seasons.prefix(8), id: \.self) { s in
                    Button(s == 0 ? "Specials" : "Season \(s)") { model.season = s }
                        .buttonStyle(BPActionStyle(primary: model.season == s))
                }
                // bp-season-menu: long runs open the scrollable list instead of a chip wall.
                if model.seasons.count > 8 { Button("All \(model.seasons.count) seasons") { seasonsSheet = true }.buttonStyle(BPActionStyle()) }
            }
            .focusSection()
            ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: BP.trackGap) {
                    ForEach(model.seasonEpisodes) { ep in
                        Button { picker = (model.meta, ep.playEpisode) } label: { EpisodeCell(episode: ep, watched: model.isWatched(ep), fact: model.fact(for: ep)) }
                            .buttonStyle(BPTileStyle())
                            .id(ep.id)
                            .accessibilityIdentifier("episode-\(ep.season)-\(ep.episode)")
                    }
                }
                .padding(.vertical, BP.px(14))
            }
            .scrollClipDisabled()
            // use-bp-episode-strip: land on the resume episode when the strip first shows.
            .onChange(of: model.seasonEpisodes.count) { _, n in
                guard n > 0, let r = model.resume, r.season == model.season, let e = r.episode, let target = model.seasonEpisodes.first(where: { $0.episode == e }) else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { withAnimation { proxy.scrollTo(target.id, anchor: .leading) } }
            }
            }
            .focusSection()
        }
    }
}

struct EpisodeCell: View {
    let episode: DetailModel.Episode
    var watched = false
    var fact: DetailModel.EpisodeFact? = nil
    private static let size = CGSize(width: BP.px(230), height: (BP.px(230) * 9 / 16).rounded())

    var body: some View {
        VStack(alignment: .leading, spacing: BP.px(6)) {
            ZStack(alignment: .bottomLeading) {
                RemoteImage(url: episode.thumbnail)
                LinearGradient(colors: [.clear, BP.void_.opacity(0.85)], startPoint: .center, endPoint: .bottom)
                Text("E\(episode.episode)").font(BP.sans(12, .bold)).foregroundStyle(BP.ink).padding(BP.px(8))
                // use-bp-episode-facts chip: rating (IMDb mark when it is IMDb's) and runtime.
                if let f = fact, f.rating != nil || f.runtime != nil {
                    HStack(spacing: BP.px(4)) {
                        if let r = f.rating { Text((f.ratingIsImdb ? "IMDb " : "★ ") + String(format: "%.1f", r)) }
                        if let m = f.runtime { Text("\(m) min") }
                    }
                    .font(BP.sans(9.5, .bold)).foregroundStyle(BP.ink)
                    .padding(.horizontal, BP.px(6)).padding(.vertical, BP.px(3))
                    .background(RoundedRectangle(cornerRadius: BP.px(4)).fill(BP.void_.opacity(0.85)))
                    .padding(BP.px(8))
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
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
