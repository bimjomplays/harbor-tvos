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
    struct Section: Decodable, Identifiable { var label: String; @LossyArray var items: [Entry]; var total: Int; var id: String { label } }   // (bug pass 2) lossy: synced library
    struct Group: Decodable, Identifiable { var id: String; var label: String }
    struct Counts: Decodable { var all: Int; var movie: Int; var series: Int }
    struct Feed: Decodable {
        var tab: String; var sections: [Section]; var shown: Int; var matched: Int; var total: Int; var hasMore: Bool
        var groups: [Group]; var status: String; var hidden: Int; var signedIn: Bool; var sort: String; var counts: Counts
    }

    @Published private(set) var tabs: [Tab] = []
    @Published private(set) var feed: Feed?
    /// (detail/search pass 2) The feed of the tab on screen. A tab pick keeps the last tab's feed
    /// until the new one lands (Trakt, Simkl and Letterboxd go to the network): its titles and count
    /// stood under the new tab's chip and could be opened. bp-library's feed is per tab; nil here
    /// shows the spinner instead.
    var shownFeed: Feed? { feed.flatMap { $0.tab == tab ? $0 : nil } }
    @Published private(set) var loading = false
    @Published var tab = "library"
    @Published var type = "all"
    @Published var sort = "recent"
    /// bp-library reads settings.librarySort. Until the first feed says which sort it used (or the
    /// viewer picks one) the engine is asked with none, so it applies the saved one: every visit
    /// used to open on Recent, with that chip lit, whatever the viewer had chosen last time.
    private var sortKnown = false
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
        // Runs again whenever a cover (Detail, Stats) closes: a failed read keeps the tabs on screen
        // instead of emptying the chip row and dropping the viewer back on Saved.
        if let t: [Tab] = try? await HarborEngine.shared.call("libraryRoom.tabs", [p.id, p.linked]) { tabs = t }
        if !tabs.contains(where: { $0.id == tab }) { tab = tabs.first?.id ?? "library" }
        await load()
    }

    /// (bug pass) Only the newest feed request lands. Tabs, filters and "Show more" each start a
    /// load; a slow one (Trakt / Simkl / Letterboxd tabs go to the network) answering after a
    /// quicker, newer one put the old tab's titles under the new tab's chip, and the first to finish
    /// cleared `loading` while the other still ran.
    private var generation = 0

    func load(force: Bool = false) async {
        generation += 1
        let mine = generation
        loading = true
        defer { if mine == generation { loading = false } }
        let p = profile
        let input: AnyJSON = .object([
            "tab": .string(tab), "profileId": .string(p.id), "linked": .bool(p.linked), "authKey": p.authKey.map { .string($0) } ?? .null,
            "sort": sortKnown ? AnyJSON.string(sort) : AnyJSON.null, "flat": .bool(flat), "type": .string(type), "query": .string(query), "episodes": .bool(episodes),
            "group": group.map { .string($0) } ?? .null, "limit": .number(Double(limit)), "force": .bool(force),
        ])
        if let f: Feed = try? await HarborEngine.shared.call("libraryRoom.feed", [input]), mine == generation {
            feed = f
            sort = f.sort
            sortKnown = true
            await CardMarksStore.shared.refresh(f.sections.flatMap { $0.items.map(\.meta) })
        }
    }

    /// bp-library's [tab] effect: a new tab starts unfiltered (group, type and search cleared). The
    /// search used to carry over, filtering the next tab by a title typed for the last one, even
    /// with the search row closed and nothing on screen saying so.
    func select(tab id: String) {
        tab = id; group = nil; type = "all"; query = ""; limit = 60
        // Loading from this frame on: the new tab has no feed yet (shownFeed), so the page shows
        // the spinner, not the failed-read note, until the load below starts.
        loading = true
        Task { await load() }
    }
    func set(type t: String) { type = t; limit = 60; Task { await load() } }
    func set(sort s: String) {
        sort = s; sortKnown = true; limit = 60
        // A feed already in flight (the first one asks with no sort and answers with the saved one)
        // must not land after this pick: it set `sort` back, and the load below then asked for it.
        generation += 1
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

    /// (layout pass) Nine fixed 298 pt columns asked for 2 874 pt on a 1 632 pt page (1 920 less both
    /// gutters): the grid, and with it the whole page, ran off both sides of the screen. bp-library's
    /// auto-fill grid fits the page, so the column count is what fits: 5 × 298 + 4 × 24 = 1 586.
    private let columns = Array(repeating: GridItem(.fixed(BPTileView.posterWidth), spacing: BP.px(14)), count: 5)
    @FocusState private var focusedKey: String?
    /// The Filters / Search / Repair chip that takes the ring back when Menu closes its panel.
    @FocusState private var focusedChip: String?
    /// "Show more" was pressed at this many tiles: the tile at that index takes the ring once it lands.
    @State private var focusAfterMore: Int?
    /// When the ring last left the grid by its tile going away (or moving off it).
    @State private var gridFocusLostAt: Date?

    private func closePanels() {
        let chip = model.showSearch ? "search" : (model.showFilters ? "filters" : "repair")
        let inGrid = focusedKey != nil
        model.showFilters = false
        model.showSearch = false
        model.showRepair = false
        // From a tile the ring stays put (the grid only moves up); from inside a panel, which is
        // going away, it returns to the chip that opened it like a closed bp dialog.
        if !inGrid { focusedChip = chip }
    }

    /// Menu with a panel open closes it; nil lets the press through to the shell (Home).
    private var exitAction: (() -> Void)? {
        guard model.showFilters || model.showSearch || model.showRepair else { return nil }
        return { closePanels() }
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: BP.px(16)) {
                tabRow
                if model.showFilters { filters }
                if model.showSearch { searchRow }
                if model.showRepair { LibraryRepairPanel(onRepaired: { Task { await model.load(force: true) } }) }
                if let f = model.shownFeed {
                    // Over a grid kept from the cache; an empty tab says it in its own empty copy.
                    if f.status == "error" && !f.sections.isEmpty { BPNote(text: errorText, tone: BP.danger) }
                    if f.sections.isEmpty {
                        emptyState(f)
                    } else {
                        ForEach(f.sections) { s in
                            VStack(alignment: .leading, spacing: BP.px(8)) {
                                if !s.label.isEmpty {
                                    HStack(spacing: BP.px(8)) {
                                        Text(T(s.label)).font(BP.sans(17, .semibold)).foregroundStyle(BP.ink)
                                        Text("\(s.total)").font(BP.sans(12)).foregroundStyle(BP.inkSubtle)
                                    }
                                }
                                LazyVGrid(columns: columns, alignment: .leading, spacing: BP.px(18)) {
                                    ForEach(s.items) { e in
                                        Button { detail = e.meta } label: {
                                            ZStack(alignment: .bottom) {
                                                BPTileView(meta: e.meta, shape: .poster, focused: focusedKey == e.key)
                                                if let p = e.progress, p > 0, p < 1 {
                                                    // history-episode-card: the watched fraction at the poster's foot
                                                    // (the tile ends at the art now; the caption sits inside it).
                                                    Capsule().fill(BP.ink).frame(width: BPTileView.posterWidth * CGFloat(p), height: BP.px(4))
                                                        .frame(width: BPTileView.posterWidth, alignment: .leading)
                                                        .offset(y: -BP.px(3))
                                                }
                                            }
                                        }
                                        .buttonStyle(BPTileStyle())
                                        .focused($focusedKey, equals: e.key)
                                        // The lifted tile, ring and shadow draw over the next grid row.
                                        .zIndex(focusedKey == e.key ? 1 : 0)
                                    }
                                }
                            }
                            .focusSection()
                        }
                        if f.hasMore {
                            // The next page lands between the last tile and this button, so the focused
                            // button slid a page down off screen and Up then landed at the new page's
                            // end. The ring goes to the first new tile instead, where the viewer was
                            // reading (bp-library pages under the grid's end, never past it).
                            Button("Show more (\(f.shown) of \(f.matched))") { focusAfterMore = f.shown; model.more() }.buttonStyle(BPActionStyle())
                        }
                    }
                } else if model.loading {
                    ProgressView().tint(BP.inkMuted).padding(.top, BP.px(40))
                } else if model.feed != nil {
                    // The new tab's read failed outright; the last tab's grid is not its answer.
                    BPNote(text: errorText, tone: BP.danger).padding(.top, BP.px(10))
                }
            }
            .padding(.horizontal, BP.gutter).padding(.top, BP.barHeight + BP.px(16)).padding(.bottom, BP.hintHeight + BP.px(40))
        }
        .task { await model.start() }
        .task {
            let p = ProfilesStore.shared.active
            statsEnabled = (try? await HarborEngine.shared.call("wrapped.enabled", [p?.id ?? "default", p?.linked ?? true]) as Bool) ?? false
        }
        // bp-library BpChip autofocus={(showEmpty || first) && selected}: a grid that empties under
        // the ring (the last title taken off the Watchlist on its page, a filter) hands it to the
        // selected tab chip, not to wherever tvOS resets focus. (detail/search pass 2)
        .onChange(of: focusedKey) { old, new in if old != nil, new == nil { gridFocusLostAt = Date() } }
        .onChange(of: model.shownFeed?.sections.isEmpty) { old, empty in
            guard empty == true, old == false else { return }
            // Only a ring the emptying grid just dropped (not one the viewer took to a filter row).
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                guard focusedKey == nil, focusedChip == nil, let lost = gridFocusLostAt, Date().timeIntervalSince(lost) < 0.5 else { return }
                focusedChip = "tab:" + model.tab
            }
        }
        .onChange(of: model.feed?.shown) { _, _ in
            guard let i = focusAfterMore, let f = model.feed else { return }
            focusAfterMore = nil
            let keys = f.sections.flatMap { $0.items.map(\.key) }
            if i < keys.count { focusedKey = keys[i] }
        }
        // bp-library's [tab] effect clears the search; the field shows it.
        .onChange(of: model.tab) { _, _ in draft = ""; focusAfterMore = nil }
        // bp-library-filters / bp-library-search are dialogs that Back closes (pushBpBack). Here they
        // open inline, and Menu inside one left the Library for Home; it now closes them and puts
        // the ring back on the chip row. With none open, the press goes on to the shell (Home).
        .onExitCommand(perform: exitAction)
        .fullScreenCover(item: $detail) { m in DetailView(meta: m) }
        .fullScreenCover(isPresented: $showStats) { WrappedView() }
    }

    // bp-library.tsx chip row: tabs, then Filters / Search / Refresh.
    private var tabRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: BP.px(8)) {
                ForEach(model.tabs) { t in
                    Button(T(t.label)) { model.select(tab: t.id) }.buttonStyle(BPActionStyle(primary: model.tab == t.id)).bpSelected(model.tab == t.id)
                        .focused($focusedChip, equals: "tab:" + t.id)
                }
                Divider().frame(height: BP.px(24)).overlay(BP.edge2)
                // bp-library chips print their own state (the Filters chip is selected while a type
                // or group narrows the grid, the Search chip reads the query), so a closed panel
                // still says why the grid is filtered.
                Button { model.showFilters.toggle() } label: { Label("Filters", systemImage: "line.3.horizontal.decrease") }
                    .buttonStyle(BPActionStyle(primary: model.showFilters || model.type != "all" || model.group != nil))
                    .focused($focusedChip, equals: "filters")
                Button { model.showSearch.toggle() } label: {
                    Label { Text(model.query.isEmpty ? T("Search") : model.query).lineLimit(1) } icon: { Image(systemName: "magnifyingglass") }
                }
                .buttonStyle(BPActionStyle(primary: model.showSearch || !model.query.isEmpty))
                .focused($focusedChip, equals: "search")
                Button { Task { await model.load(force: true) } } label: { Label("Refresh", systemImage: "arrow.clockwise") }.buttonStyle(BPActionStyle())
                // library-repair-rows.tsx lives in desktop Settings → Advanced; the TV keeps it beside the library.
                Button { model.showRepair.toggle() } label: { Label("Repair library", systemImage: "wrench.and.screwdriver") }.buttonStyle(BPActionStyle(primary: model.showRepair))
                    .focused($focusedChip, equals: "repair")
                if statsEnabled {
                    Button { showStats = true } label: { Label("Stats", systemImage: "chart.bar") }.buttonStyle(BPActionStyle())
                }
                if let f = model.shownFeed { Text("\(f.matched) titles").font(BP.sans(12)).foregroundStyle(BP.inkSubtle).padding(.leading, BP.px(8)) }
            }
        }
        // (layout pass) The track is exactly one chip tall: the focused chip's ring (9.5 pt out) lost
        // its top, bottom and, on the first chip, its left side to the scroll view's clip.
        .scrollClipDisabled()
        .focusSection()
    }

    // bp-library-filters: one labelled row per kind (Up/Down between kinds, Left/Right within).
    private var filters: some View {
        VStack(alignment: .leading, spacing: BP.px(10)) {
            filterRow("Type", [("all", T("All") + " \(model.feed?.counts.all ?? 0)"), ("movie", T("Movies") + " \(model.feed?.counts.movie ?? 0)"), ("series", T("Series") + " \(model.feed?.counts.series ?? 0)")], active: model.type) { model.set(type: $0) }
            filterRow("Sort", [("recent", T("Recent")), ("title", T("Title")), ("year", T("Year"))], active: model.sort) { model.set(sort: $0) }
            filterRow("View", [("grouped", T("Grouped")), ("flat", T("One list"))], active: model.flat ? "flat" : "grouped") { _ in model.toggleFlat() }
            if model.tab == "history" {
                filterRow("Show", [("episodes", T("Episodes")), ("posters", T("Posters"))], active: model.episodes ? "episodes" : "posters") { model.set(episodes: $0 == "episodes") }
            }
            if let groups = model.feed?.groups, !groups.isEmpty {
                filterRow(model.tab == "lists" ? "List" : "Group", [("", T("All"))] + groups.map { ($0.id, T($0.label)) }, active: model.group ?? "") { model.set(group: $0.isEmpty ? nil : $0) }
            }
        }
    }

    private func filterRow(_ heading: String, _ options: [(String, String)], active: String, pick: @escaping (String) -> Void) -> some View {
        HStack(spacing: BP.px(8)) {
            Text(T(heading).uppercased()).font(BP.sans(11, .bold)).tracking(1.5).foregroundStyle(BP.inkSubtle).frame(width: BP.px(80), alignment: .leading)
            ForEach(options, id: \.0) { o in
                Button(o.1) { pick(o.0) }.buttonStyle(BPActionStyle(primary: active == o.0)).bpSelected(active == o.0)
            }
        }
        .focusSection()
    }

    private var searchRow: some View {
        HStack(spacing: BP.px(8)) {
            BPField(label: "Search this tab", placeholder: "Title", text: $draft)
                // bp-library-search filters as the viewer types; the TV keyboard's Done now applies
                // the query too, instead of returning to a grid that ignored it until Go.
                .onSubmit { model.search(draft) }
            Button("Go") { model.search(draft) }.buttonStyle(BPActionStyle(primary: true))
            if !model.query.isEmpty { Button("Clear") { draft = ""; model.search("") }.buttonStyle(BPActionStyle()) }
        }
        .focusSection()
    }

    // bp-library.tsx emptyCopy: a service tab names the service it could not reach.
    private var errorText: String {
        let names = ["trakt": "Trakt", "anilist": "AniList", "mal": "MyAnimeList", "simkl": "Simkl", "letterboxd": "Letterboxd"]
        if let name = names[model.tab] { return T("Couldn't reach %@. Try refreshing.", name) }
        return "Couldn't load your library. Try refreshing."
    }

    // bp-library.tsx emptyCopy per tab. Without a Stremio account or Trakt only Saved and History
    // ask the viewer to sign in: the Watchlist is Harbor's own (lib/watchlist) and works without
    // one, so an empty one was told to sign in to Stremio. An unreachable source says so instead
    // of an empty-tab line under the error.
    private func emptyState(_ f: LibraryModel.Feed) -> some View {
        let text: String
        if model.loading { text = "Loading…" }
        else if f.status == "error" { text = errorText }
        else if f.total > 0 || !model.query.isEmpty || model.type != "all" || model.group != nil { text = "No matches for these filters." }
        else {
            switch model.tab {
            case "library" where !f.signedIn: text = "Sign in to Stremio or connect Trakt in Settings to see your library here."
            case "history" where !f.signedIn: text = "Sign in to Stremio or connect Trakt in Settings to see what you have been watching."
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
