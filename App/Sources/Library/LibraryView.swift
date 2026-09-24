import SwiftUI

/// Library room (bp-library.tsx): tabs (Saved / Watchlist / History / My Lists / Favorites, plus
/// Trakt / AniList / MyAnimeList / Simkl / Letterboxd when connected), filter rows (type, sort,
/// grouping), search, the library repair panel, and a vertical poster grid in date/title/year
/// sections fed by the engine's use-bp-library port.
@MainActor
final class LibraryModel: ObservableObject {
    struct Tab: Decodable, Identifiable { var id: String; var label: String }
    struct Entry: Decodable, Identifiable {
        var key: String; var meta: Meta; var date: Double?; var group: String?
        var progress: Double?; var season: Int?; var episode: Int?; var watched: Bool?
        var id: String { key }
    }
    struct Section: Decodable, Identifiable { var label: String; var items: [Entry]; var total: Int; var id: String { label } }
    struct Group: Decodable, Identifiable { var id: String; var label: String }
    struct Counts: Decodable { var all: Int; var movie: Int; var series: Int }
    struct Feed: Decodable {
        var tab: String; var sections: [Section]; var shown: Int; var matched: Int; var total: Int; var hasMore: Bool
        var groups: [Group]; var status: String; var hidden: Int; var signedIn: Bool; var sort: String; var counts: Counts
    }

    @Published private(set) var tabs: [Tab] = []
    @Published private(set) var feed: Feed?
    @Published private(set) var loading = false
    @Published var tab = "library"
    @Published var type = "all"
    @Published var sort = "recent"
    @Published var flat = false
    /// bp-library "Episodes / Posters" for History (harbor.history.view).
    @Published var episodes = Prefs.get(String.self, for: "harbor.history.view") == "episodes"
    @Published var group: String?
    @Published var query = ""
    @Published var showFilters = false
    @Published var showSearch = false
    @Published var showRepair = false
    private var limit = 60

    private var profile: (id: String, linked: Bool, authKey: String?) {
        let p = ProfilesStore.shared.active
        return (p?.id ?? "default", p?.linked ?? true, p.flatMap { ProfilesStore.shared.stremioSession(for: $0.id)?.authKey })
    }

    func start() async {
        let p = profile
        tabs = (try? await HarborEngine.shared.call("libraryRoom.tabs", [p.id, p.linked])) ?? []
        if !tabs.contains(where: { $0.id == tab }) { tab = tabs.first?.id ?? "library" }
        await load()
    }

    func load(force: Bool = false) async {
        loading = true; defer { loading = false }
        let p = profile
        let input: AnyJSON = .object([
            "tab": .string(tab), "profileId": .string(p.id), "linked": .bool(p.linked), "authKey": p.authKey.map { .string($0) } ?? .null,
            "sort": .string(sort), "flat": .bool(flat), "type": .string(type), "query": .string(query), "episodes": .bool(episodes),
            "group": group.map { .string($0) } ?? .null, "limit": .number(Double(limit)), "force": .bool(force),
        ])
        if let f: Feed = try? await HarborEngine.shared.call("libraryRoom.feed", [input]) {
            feed = f
            await CardMarksStore.shared.refresh(f.sections.flatMap { $0.items.map(\.meta) })
        }
    }

    func select(tab id: String) { tab = id; group = nil; limit = 60; Task { await load() } }
    func set(type t: String) { type = t; limit = 60; Task { await load() } }
    func set(sort s: String) {
        sort = s; limit = 60
        let p = profile
        Task { _ = try? await HarborEngine.shared.callJSON("libraryRoom.setSort", [.string(s), .string(p.id), .bool(p.linked)]); await load() }
    }
    func toggleFlat() { flat.toggle(); Task { await load() } }
    func set(episodes on: Bool) { episodes = on; try? Prefs.set(on ? "episodes" : "posters", for: "harbor.history.view"); Task { await load() } }
    func set(group g: String?) { group = g; limit = 60; Task { await load() } }
    func search(_ q: String) { query = q; limit = 60; Task { await load() } }
    func more() { limit += 60; Task { await load() } }
}

struct LibraryView: View {
    @StateObject private var model = LibraryModel()
    @State private var detail: Meta?
    @State private var draft = ""
    /// views/library.tsx "Stats" (settings.wrappedButton) opens the Wrapped view.
    @State private var statsEnabled = false
    @State private var showStats = false

    private let columns = Array(repeating: GridItem(.fixed(BPTileView.posterWidth), spacing: BP.px(14)), count: 9)

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: BP.px(16)) {
                tabRow
                if model.showFilters { filters }
                if model.showSearch { searchRow }
                if model.showRepair { LibraryRepairPanel(onRepaired: { Task { await model.load(force: true) } }) }
                if let f = model.feed {
                    if f.status == "error" { BPNote(text: errorText, tone: BP.danger) }
                    if f.sections.isEmpty {
                        emptyState(f)
                    } else {
                        ForEach(f.sections) { s in
                            VStack(alignment: .leading, spacing: BP.px(8)) {
                                if !s.label.isEmpty {
                                    HStack(spacing: BP.px(8)) {
                                        Text(s.label).font(BP.sans(17, .semibold)).foregroundStyle(BP.ink)
                                        Text("\(s.total)").font(BP.sans(12)).foregroundStyle(BP.inkSubtle)
                                    }
                                }
                                LazyVGrid(columns: columns, alignment: .leading, spacing: BP.px(18)) {
                                    ForEach(s.items) { e in
                                        Button { detail = e.meta } label: {
                                            ZStack(alignment: .bottom) {
                                                BPTileView(meta: e.meta, shape: .poster)
                                                if let p = e.progress, p > 0, p < 1 {
                                                    // history-episode-card: the watched fraction under the poster.
                                                    Capsule().fill(BP.ink).frame(width: BPTileView.posterWidth * CGFloat(p), height: BP.px(4))
                                                        .frame(width: BPTileView.posterWidth, alignment: .leading)
                                                        .offset(y: -BP.px(22))
                                                }
                                            }
                                        }
                                        .buttonStyle(BPTileStyle())
                                    }
                                }
                            }
                            .focusSection()
                        }
                        if f.hasMore {
                            Button("Show more (\(f.shown) of \(f.matched))") { model.more() }.buttonStyle(BPActionStyle())
                        }
                    }
                } else if model.loading {
                    ProgressView().tint(BP.inkMuted).padding(.top, BP.px(40))
                }
            }
            .padding(.horizontal, BP.gutter).padding(.top, BP.barHeight + BP.px(16)).padding(.bottom, BP.hintHeight + BP.px(40))
        }
        .task { await model.start() }
        .task {
            let p = ProfilesStore.shared.active
            statsEnabled = (try? await HarborEngine.shared.call("wrapped.enabled", [p?.id ?? "default", p?.linked ?? true]) as Bool) ?? false
        }
        .fullScreenCover(item: $detail) { m in DetailView(meta: m) }
        .fullScreenCover(isPresented: $showStats) { WrappedView() }
    }

    // bp-library.tsx chip row: tabs, then Filters / Search / Refresh.
    private var tabRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: BP.px(8)) {
                ForEach(model.tabs) { t in
                    Button(t.label) { model.select(tab: t.id) }.buttonStyle(BPActionStyle(primary: model.tab == t.id))
                }
                Divider().frame(height: BP.px(24)).overlay(BP.edge2)
                Button { model.showFilters.toggle() } label: { Label("Filters", systemImage: "line.3.horizontal.decrease") }.buttonStyle(BPActionStyle(primary: model.showFilters))
                Button { model.showSearch.toggle() } label: { Label("Search", systemImage: "magnifyingglass") }.buttonStyle(BPActionStyle(primary: model.showSearch))
                Button { Task { await model.load(force: true) } } label: { Label("Refresh", systemImage: "arrow.clockwise") }.buttonStyle(BPActionStyle())
                // library-repair-rows.tsx lives in desktop Settings → Advanced; the TV keeps it beside the library.
                Button { model.showRepair.toggle() } label: { Label("Repair library", systemImage: "wrench.and.screwdriver") }.buttonStyle(BPActionStyle(primary: model.showRepair))
                if statsEnabled {
                    Button { showStats = true } label: { Label("Stats", systemImage: "chart.bar") }.buttonStyle(BPActionStyle())
                }
                if let f = model.feed { Text("\(f.matched) titles").font(BP.sans(12)).foregroundStyle(BP.inkSubtle).padding(.leading, BP.px(8)) }
            }
        }
        .focusSection()
    }

    // bp-library-filters: one labelled row per kind (Up/Down between kinds, Left/Right within).
    private var filters: some View {
        VStack(alignment: .leading, spacing: BP.px(10)) {
            filterRow("Type", [("all", "All \(model.feed?.counts.all ?? 0)"), ("movie", "Movies \(model.feed?.counts.movie ?? 0)"), ("series", "Series \(model.feed?.counts.series ?? 0)")], active: model.type) { model.set(type: $0) }
            filterRow("Sort", [("recent", "Recent"), ("title", "Title"), ("year", "Year")], active: model.sort) { model.set(sort: $0) }
            filterRow("View", [("grouped", "Grouped"), ("flat", "One list")], active: model.flat ? "flat" : "grouped") { _ in model.toggleFlat() }
            if model.tab == "history" {
                filterRow("Show", [("episodes", "Episodes"), ("posters", "Posters")], active: model.episodes ? "episodes" : "posters") { model.set(episodes: $0 == "episodes") }
            }
            if let groups = model.feed?.groups, !groups.isEmpty {
                filterRow(model.tab == "lists" ? "List" : "Group", [("", "All")] + groups.map { ($0.id, $0.label) }, active: model.group ?? "") { model.set(group: $0.isEmpty ? nil : $0) }
            }
        }
    }

    private func filterRow(_ heading: String, _ options: [(String, String)], active: String, pick: @escaping (String) -> Void) -> some View {
        HStack(spacing: BP.px(8)) {
            Text(heading.uppercased()).font(BP.sans(11, .bold)).tracking(1.5).foregroundStyle(BP.inkSubtle).frame(width: BP.px(80), alignment: .leading)
            ForEach(options, id: \.0) { o in
                Button(o.1) { pick(o.0) }.buttonStyle(BPActionStyle(primary: active == o.0))
            }
        }
        .focusSection()
    }

    private var searchRow: some View {
        HStack(spacing: BP.px(8)) {
            BPField(label: "Search this tab", placeholder: "Title", text: $draft)
            Button("Go") { model.search(draft) }.buttonStyle(BPActionStyle(primary: true))
            if !model.query.isEmpty { Button("Clear") { draft = ""; model.search("") }.buttonStyle(BPActionStyle()) }
        }
        .focusSection()
    }

    // bp-library.tsx emptyCopy: a service tab names the service it could not reach.
    private var errorText: String {
        let names = ["trakt": "Trakt", "anilist": "AniList", "mal": "MyAnimeList", "simkl": "Simkl", "letterboxd": "Letterboxd"]
        if let name = names[model.tab] { return "Couldn't reach \(name). Try refreshing." }
        return "Couldn't load your library. Try refreshing."
    }

    // bp-library.tsx empty copy per tab.
    private func emptyState(_ f: LibraryModel.Feed) -> some View {
        let text: String
        if model.loading { text = "Loading…" }
        else if !model.query.isEmpty || model.type != "all" || model.group != nil { text = "No matches for these filters." }
        else if !f.signedIn && (model.tab == "library" || model.tab == "watchlist" || model.tab == "history") { text = "Sign in to Stremio in Settings to see your library here." }
        else {
            switch model.tab {
            case "watchlist": text = "Your watchlist is empty."
            case "history": text = "Nothing watched yet. Press play on something."
            case "lists": text = "You have no lists yet."
            case "favorites": text = "No favorites yet. Save a movie or show to see it here."
            case "library": text = "Nothing saved yet. Add a title from any details page."
            default: text = "Nothing here yet."
            }
        }
        return BPNote(text: text).padding(.top, BP.px(10))
    }
}
