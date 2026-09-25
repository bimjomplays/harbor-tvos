import SwiftUI

/// Playlist VOD (views/playlist-vod.tsx, playlist-vod/*): the movies and series an IPTV source
/// carries besides its live channels. Source chips, Movies / Shows tabs with counts, a search,
/// a poster grid that loads 60 more as the ring reaches the end, and a series page with season
/// chips and episode rows (progress from the local resume store). Playback goes through the
/// normal player with the VOD cache profile and resumes where the viewer left off.
@MainActor
final class PlaylistVodModel: ObservableObject {
    struct Source: Decodable, Identifiable { var id: String; var name: String; var kind: String }
    struct Sources: Decodable { var sources: [Source]; var activeId: String? }
    struct Status: Decodable {
        var playlistId: String; var kind: String; var movies: Int; var series: Int
        var moviesLoading: Bool; var seriesLoading: Bool
        var movieError: String?; var seriesError: String?
        var movieTotal: Int?; var seriesTotal: Int?; var fetchedAt: Double?
    }
    struct Item: Decodable, Identifiable, Equatable {
        var id: String; var kind: String; var title: String; var year: Int?; var logo: String?; var group: String?
        var subtitle: String?; var url: String?; var playlistName: String?; var resumeSec: Double?
    }
    struct Page: Decodable { var items: [Item]; var total: Int; var libraryTotal: Int }
    struct Episode: Decodable, Identifiable, Equatable {
        var season: Int; var episode: Int; var title: String; var url: String; var logo: String?
        var durationSec: Double?; var plot: String?; var progress: Double; var leftSec: Double; var watched: Bool; var resumeSec: Double
        var id: String { "\(season)-\(episode)-\(url)" }
    }
    struct Series: Decodable, Equatable { var id: String; var title: String; var logo: String?; var group: String?; var playlistName: String?; var seasons: [Int]; var episodes: [Episode] }
    struct Playback: Decodable, Identifiable { var meta: Meta; var url: String; var title: String; var subtitle: String; var season: Int?; var episode: Int?; var id: String { url } }

    enum Tab: String { case movies, series }
    /// playlist-vod.tsx PAGE_SIZE.
    static let pageSize = 60

    @Published private(set) var sources: [Source] = []
    @Published private(set) var activeId: String?
    @Published private(set) var status: Status?
    @Published private(set) var items: [Item] = []
    @Published private(set) var total = 0
    @Published private(set) var libraryTotal = 0
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    @Published var tab: Tab = .movies
    @Published var query = ""
    /// The open series page (playlist-vod.tsx `selected`); `loadingSeries` while Xtream fetches its episodes.
    @Published private(set) var selected: Series?
    @Published private(set) var loadingSeries = false
    @Published private(set) var seriesError: String?

    private var pageGeneration = 0
    private var loadGeneration = 0
    private var pagingInFlight = false

    var activeSource: Source? { sources.first { $0.id == activeId } }

    func start() async {
        if let s: Sources = try? await HarborEngine.shared.call("liveVod.sources", []) {
            sources = s.sources
            activeId = s.activeId
        }
        await load(force: false)
    }

    func select(_ id: String) async {
        guard id != activeId else { return }
        activeId = id
        selected = nil
        _ = try? await HarborEngine.shared.callJSON("liveVod.setActive", [.string(id)])
        items = []; total = 0; libraryTotal = 0; status = nil
        await load(force: false)
    }

    /// use-xtream-vod-library load / useIptvPlaylist: the library, with the loading line kept
    /// current while a big Xtream catalogue is still being read.
    func load(force: Bool) async {
        guard let id = activeId else { return }
        // (bug pass) Only the newest load drives the loading line: switching source mid-load let the
        // old source's poll overwrite the new one's progress and its end clear the new spinner.
        loadGeneration += 1
        let generation = loadGeneration
        loading = true
        error = nil
        let poll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
                guard let self, let s: Status = try? await HarborEngine.shared.call("liveVod.status", [id]) else { continue }
                guard !Task.isCancelled, self.loadGeneration == generation, self.activeId == id else { return }
                self.status = s
                // Batches keep arriving: fill the first screen as soon as there is something to show.
                if self.items.count < Self.pageSize { await self.reloadPage() }
            }
        }
        do {
            let s: Status = try await HarborEngine.shared.call("liveVod.load", [id, force])
            if activeId == id { status = s }
        } catch {
            if activeId == id { self.error = error.localizedDescription }
        }
        poll.cancel()
        guard loadGeneration == generation else { return }
        loading = false
        if activeId == id { await reloadPage() }
    }

    /// The first page for the current tab and query (a newer ask wins).
    func reloadPage() async {
        guard let id = activeId else { return }
        pageGeneration += 1
        let mine = pageGeneration
        guard let p: Page = try? await HarborEngine.shared.call("liveVod.page", [id, tab.rawValue, query, 0, Self.pageSize]) else { return }
        guard mine == pageGeneration else { return }
        items = p.items
        total = p.total
        libraryTotal = p.libraryTotal
    }

    /// playlist-vod.tsx loadMore: the next 60 once the ring nears the end of the grid.
    func loadMore() async {
        guard let id = activeId, !pagingInFlight, items.count < total else { return }
        pagingInFlight = true
        defer { pagingInFlight = false }
        let mine = pageGeneration
        guard let p: Page = try? await HarborEngine.shared.call("liveVod.page", [id, tab.rawValue, query, items.count, Self.pageSize]) else { return }
        guard mine == pageGeneration else { return }
        var seen = Set(items.map(\.id))
        items += p.items.filter { seen.insert($0.id).inserted }
        total = p.total
    }

    func chooseTab(_ t: Tab) async {
        tab = t
        selected = nil
        await reloadPage()
    }

    /// playlist-vod.tsx openSeries.
    func open(_ item: Item) async {
        guard let id = activeId else { return }
        seriesError = nil
        selected = Series(id: item.id, title: item.title, logo: item.logo, group: item.group, playlistName: item.playlistName, seasons: [], episodes: [])
        loadingSeries = true
        defer { loadingSeries = false }
        do {
            let s: Series = try await HarborEngine.shared.call("liveVod.series", [id, item.id])
            if selected?.id == item.id { selected = s }
        } catch {
            if selected?.id == item.id { seriesError = error.localizedDescription }
        }
    }

    /// Progress after the player closes (episode-row reads the resume store on every render).
    func refreshSelected() async {
        guard let id = activeId, let s = selected else { return }
        if let fresh: Series = try? await HarborEngine.shared.call("liveVod.series", [id, s.id]), selected?.id == s.id { selected = fresh }
    }

    func closeSeries() { selected = nil }

    func playback(movie: Item) async -> Playback? {
        guard let id = activeId else { return nil }
        return try? await HarborEngine.shared.call("liveVod.playMovie", [id, movie.id])
    }

    func playback(series: Series, episode: Episode) async -> Playback? {
        guard let id = activeId else { return nil }
        return try? await HarborEngine.shared.call("liveVod.playEpisode", [id, series.id, episode.season, episode.episode])
    }

    // MARK: copy (playlist-vod.tsx)

    var tabLoading: Bool {
        guard let s = status else { return loading }
        return tab == .movies ? s.moviesLoading : s.seriesLoading
    }

    var tabError: String? {
        if let error { return error }
        guard let s = status else { return nil }
        return tab == .movies ? s.movieError : s.seriesError
    }

    /// CatalogProgress: "Loading movies..." until the provider says how many, then "Loaded x of y movies...".
    var progressLine: String? {
        guard tabLoading else { return nil }
        let loaded = tab == .movies ? (status?.movies ?? 0) : (status?.series ?? 0)
        let providerTotal = tab == .movies ? status?.movieTotal : status?.seriesTotal
        guard let providerTotal else { return T(tab == .movies ? "Loading movies..." : "Loading shows...") }
        return T(tab == .movies ? "Loaded %@ of %@ movies..." : "Loaded %@ of %@ shows...", loaded.formatted(), max(providerTotal, loaded).formatted())
    }

    /// emptyMoviesText / emptyShowsText.
    var emptyText: String {
        let q = query.trimmingCharacters(in: .whitespaces)
        if tab == .movies {
            if !q.isEmpty { return T("No movies match \"%@\".", q) }
            if libraryTotal == 0 { return "This playlist has no movies. It may be live channels only, or an Xtream login that exposes movies separately." }
            return "No movies here."
        }
        if !q.isEmpty { return T("No shows match \"%@\".", q) }
        if libraryTotal == 0 { return "This playlist has no shows. It may be live channels only, or an Xtream login that exposes shows separately." }
        return "No shows here."
    }

    /// CapNote.
    var capNote: String? {
        guard total > items.count else { return nil }
        return T(tab == .movies ? "Showing %@ of %@ movies. Scroll to load more." : "Showing %@ of %@ shows. Scroll to load more.",
                 items.count.formatted(), total.formatted())
    }
}

struct PlaylistVodView: View {
    let dismiss: () -> Void
    @StateObject private var model = PlaylistVodModel()
    @State private var playing: PlaylistVodModel.Playback?
    @State private var searchTask: Task<Void, Never>?

    private let columns = [GridItem(.adaptive(minimum: BP.px(150), maximum: BP.px(190)), spacing: BP.px(20), alignment: .top)]

    var body: some View {
        ZStack(alignment: .topLeading) {
            BP.canvas.ignoresSafeArea()
            VStack(alignment: .leading, spacing: BP.px(14)) {
                if let s = model.selected {
                    VodSeriesDetail(series: s, loading: model.loadingSeries, error: model.seriesError,
                                    onBack: { model.closeSeries() },
                                    onPlay: { ep in Task { playing = await model.playback(series: s, episode: ep) } })
                } else {
                    header
                    content
                }
            }
            .padding(.horizontal, BP.gutter).padding(.top, BP.px(40))
        }
        .task { await model.start() }
        .onExitCommand {
            if model.selected != nil { model.closeSeries() } else { dismiss() }
        }
        .onChange(of: model.query) { _, _ in
            // useDeferredValue: the grid follows the typing after it settles.
            searchTask?.cancel()
            searchTask = Task {
                try? await Task.sleep(for: .milliseconds(300))
                if Task.isCancelled { return }
                await model.reloadPage()
            }
        }
        .fullScreenCover(item: $playing) { p in
            PlayerScreen(title: p.title, subtitle: p.subtitle, url: URL(string: p.url) ?? URL(string: "about:blank")!,
                         context: PlaybackContext(meta: p.meta, season: p.season, episode: p.episode, playlistVod: true),
                         isLive: false) { _ in
                playing = nil
                Task {
                    await model.refreshSelected()
                    if model.selected == nil { await model.reloadPage() }
                }
            }
        }
    }

    // playlist-vod.tsx header: SourcePicker, the Movies / Shows tabs with counts, the search.
    private var header: some View {
        VStack(alignment: .leading, spacing: BP.px(12)) {
            HStack(spacing: BP.px(8)) {
                Button { dismiss() } label: { Label("Back", systemImage: "chevron.backward") }.buttonStyle(BPActionStyle())
                Text("Playlists").font(BP.display(30)).foregroundStyle(BP.ink).padding(.horizontal, BP.px(10))
                if model.sources.count > 1 {
                    ForEach(model.sources) { s in
                        Button(s.name) { Task { await model.select(s.id) } }
                            .buttonStyle(BPActionStyle(primary: model.activeId == s.id)).bpSelected(model.activeId == s.id)
                    }
                } else if let s = model.activeSource {
                    Text(s.name).font(BP.sans(14, .semibold)).foregroundStyle(BP.inkMuted)
                }
                Spacer(minLength: 0)
                Button { Task { await model.load(force: true) } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .buttonStyle(BPActionStyle())
                    .disabled(model.loading)
            }
            .focusSection()
            HStack(spacing: BP.px(10)) {
                tabButton(.movies, "Movies", "film", model.status?.movies ?? 0)
                tabButton(.series, "Shows", "tv", model.status?.series ?? 0)
                LiveSearchField(placeholder: model.tab == .movies ? "Search movies" : "Search shows", text: $model.query)
                    .frame(maxWidth: BP.px(620))
                if !model.query.isEmpty { Button("Clear") { model.query = "" }.buttonStyle(BPActionStyle()) }
            }
            .focusSection()
        }
    }

    private func tabButton(_ tab: PlaylistVodModel.Tab, _ label: String, _ icon: String, _ count: Int) -> some View {
        Button { Task { await model.chooseTab(tab) } } label: {
            HStack(spacing: BP.px(6)) {
                Image(systemName: icon)
                Text(T(label))
                if count > 0 { Text(count.formatted()).opacity(0.55) }
            }
        }
        .buttonStyle(BPActionStyle(primary: model.tab == tab)).bpSelected(model.tab == tab)
    }

    @ViewBuilder private var content: some View {
        if model.sources.isEmpty && !model.loading {
            BPNote(text: "Add an M3U or Xtream source in Live TV first. Its movies and shows appear here.").padding(.top, BP.px(20))
        } else if let e = model.tabError, model.items.isEmpty {
            VStack(alignment: .leading, spacing: BP.px(10)) {
                BPNote(text: e, tone: BP.danger)
                Button("Try again") { Task { await model.load(force: true) } }.buttonStyle(BPActionStyle())
            }
            .padding(.top, BP.px(20))
        } else if model.tabLoading && model.items.isEmpty {
            HStack(spacing: BP.px(10)) {
                ProgressView().tint(BP.inkMuted)
                Text(model.progressLine ?? T("Loading playlist...")).font(BP.sans(14)).foregroundStyle(BP.inkMuted)
            }
            .padding(.top, BP.px(20))
        } else if model.items.isEmpty {
            BPNote(text: model.emptyText).padding(.top, BP.px(20))
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: BP.px(12)) {
                    if let e = model.tabError {
                        // CatalogWarning: the list is partial, the error stays visible with a retry.
                        HStack(spacing: BP.px(12)) {
                            BPNote(text: e, tone: BP.inkMuted)
                            Button("Try again") { Task { await model.load(force: true) } }.buttonStyle(BPActionStyle())
                        }
                    }
                    if let line = model.progressLine { BPNote(text: line) }
                    if let cap = model.capNote { BPNote(text: cap) }
                    LazyVGrid(columns: columns, alignment: .leading, spacing: BP.px(26)) {
                        ForEach(model.items) { item in
                            VodCard(item: item) {
                                if item.kind == "series" { Task { await model.open(item) } }
                                else { Task { playing = await model.playback(movie: item) } }
                            }
                            .onAppear {
                                // The grid's last row is on screen: fetch the next page.
                                if item.id == model.items.last?.id { Task { await model.loadMore() } }
                            }
                        }
                    }
                }
                .padding(.vertical, BP.px(12)).padding(.horizontal, BP.px(6))
                .padding(.bottom, BP.px(60))
            }
            .focusSection()
        }
    }
}

/// vod-card.tsx: a poster (the playlist's logo, or the title over a plain face), the title,
/// the year or subtitle; a movie with a saved spot shows how far in it is.
struct VodCard: View {
    let item: PlaylistVodModel.Item
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: BP.px(6)) {
                ZStack(alignment: .bottomLeading) {
                    RoundedRectangle(cornerRadius: BP.rXS, style: .continuous).fill(BP.panel2)
                    if let logo = item.logo, !logo.isEmpty {
                        RemoteImage(url: logo)
                    } else {
                        Text(item.title).font(BP.sans(14, .semibold)).foregroundStyle(BP.inkMuted)
                            .multilineTextAlignment(.center).padding(BP.px(10))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    if let r = item.resumeSec, r > 0 {
                        HStack(spacing: BP.px(4)) {
                            Image(systemName: "play.fill")
                            Text(Self.clock(r))
                        }
                        .font(BP.sans(10, .bold)).foregroundStyle(BP.ink)
                        .padding(.horizontal, BP.px(6)).padding(.vertical, BP.px(3))
                        .background(Capsule().fill(BP.void_.opacity(0.8)))
                        .padding(BP.px(6))
                    }
                }
                .aspectRatio(2 / 3, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: BP.rXS, style: .continuous))
                Text(item.title).font(BP.sans(13, .semibold)).foregroundStyle(BP.ink).lineLimit(2)
                if let sub = item.subtitle ?? item.year.map({ String($0) }) {
                    Text(sub).font(BP.sans(11)).foregroundStyle(BP.inkSubtle).lineLimit(1)
                }
            }
        }
        .buttonStyle(BPTileStyle())
    }

    /// episode-row.tsx clock(): "1h 5m" / "42m".
    static func clock(_ sec: Double) -> String {
        let s = max(0, Int(sec))
        let h = s / 3600, m = (s % 3600) / 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }
}

/// series-detail.tsx + episode-row.tsx: poster, title, "{n} episodes · {n} seasons · group",
/// season chips when there is more than one, and one row per episode of the chosen season.
struct VodSeriesDetail: View {
    let series: PlaylistVodModel.Series
    let loading: Bool
    let error: String?
    let onBack: () -> Void
    let onPlay: (PlaylistVodModel.Episode) -> Void

    @State private var season: Int?

    private var currentSeason: Int { season ?? series.seasons.first ?? 1 }
    private var episodes: [PlaylistVodModel.Episode] { series.episodes.filter { $0.season == currentSeason } }

    private var facts: String {
        var parts: [String] = []
        parts.append(loading ? T("Loading episodes...") : (series.episodes.count == 1 ? T("1 episode") : T("%lld episodes", series.episodes.count)))
        if series.seasons.count > 1 { parts.append(T("%lld seasons", series.seasons.count)) }
        if let g = series.group, !g.isEmpty { parts.append(g) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: BP.px(18)) {
            HStack(alignment: .top, spacing: BP.px(18)) {
                Button(action: onBack) { Image(systemName: "chevron.backward") }
                    .buttonStyle(BPActionStyle())
                    .accessibilityLabel("Back to library")
                RemoteImage(url: series.logo)
                    .frame(width: BP.px(80), height: BP.px(120))
                    .clipShape(RoundedRectangle(cornerRadius: BP.rXS, style: .continuous))
                VStack(alignment: .leading, spacing: BP.px(6)) {
                    Text(series.title).font(BP.display(30)).foregroundStyle(BP.ink).lineLimit(1)
                    Text(facts).font(BP.sans(14)).foregroundStyle(BP.inkMuted)
                    if let error { BPNote(text: error, tone: BP.danger) }
                }
            }
            .focusSection()
            if series.seasons.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: BP.px(8)) {
                        ForEach(series.seasons, id: \.self) { s in
                            Button("Season \(s)") { season = s }.buttonStyle(BPActionStyle(primary: currentSeason == s)).bpSelected(currentSeason == s)
                        }
                    }
                    .padding(.vertical, BP.px(4))
                }
                .focusSection()
            }
            if loading {
                HStack(spacing: BP.px(10)) {
                    ProgressView().tint(BP.inkMuted)
                    Text("Loading episodes...").font(BP.sans(14)).foregroundStyle(BP.inkMuted)
                }
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: BP.px(8)) {
                        ForEach(episodes) { ep in VodEpisodeRow(episode: ep, fallbackLogo: series.logo) { onPlay(ep) } }
                    }
                    .padding(.vertical, BP.px(8)).padding(.horizontal, BP.px(6)).padding(.bottom, BP.px(60))
                }
                .focusSection()
            }
        }
    }
}

/// episode-row.tsx: thumbnail with the watched share along its foot, number, title, runtime or
/// time left, a check once 90 % in, and the plot.
struct VodEpisodeRow: View {
    let episode: PlaylistVodModel.Episode
    let fallbackLogo: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: BP.px(16)) {
                ZStack(alignment: .bottomLeading) {
                    RemoteImage(url: episode.logo ?? fallbackLogo)
                    if episode.progress > 0 {
                        GeometryReader { g in
                            ZStack(alignment: .leading) {
                                Rectangle().fill(BP.canvas.opacity(0.7))
                                Rectangle().fill(BP.accent).frame(width: g.size.width * min(1, episode.progress))
                            }
                        }
                        .frame(height: 3)
                    }
                }
                .frame(width: BP.px(150), height: BP.px(84))
                .clipShape(RoundedRectangle(cornerRadius: BP.rXS, style: .continuous))
                VStack(alignment: .leading, spacing: BP.px(4)) {
                    HStack(alignment: .firstTextBaseline, spacing: BP.px(8)) {
                        Text("\(episode.episode)").font(BP.sans(12, .semibold)).foregroundStyle(BP.inkSubtle).monospacedDigit()
                        Text(episode.title).font(BP.sans(14, .medium)).foregroundStyle(BP.ink).lineLimit(1)
                        Spacer(minLength: 0)
                        if episode.watched {
                            Image(systemName: "checkmark").foregroundStyle(BP.accent)
                        } else if episode.leftSec > 0 {
                            Text("\(VodCard.clock(episode.leftSec)) left").font(BP.sans(12)).foregroundStyle(BP.inkMuted)
                        } else if let d = episode.durationSec, d > 0 {
                            Text(VodCard.clock(d)).font(BP.sans(12)).foregroundStyle(BP.inkMuted)
                        }
                    }
                    if let plot = episode.plot, !plot.isEmpty {
                        Text(plot).font(BP.sans(12)).foregroundStyle(BP.inkMuted).lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(BP.px(10))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).fill(BP.panel2))
        }
        .buttonStyle(BPTileStyle(radius: BP.rSM))
    }
}
