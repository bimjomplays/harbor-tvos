import SwiftUI

/// Library room (bp-library.tsx): tabs (Saved / Watchlist / History / My Lists / Favorites, plus
/// Trakt / AniList / MyAnimeList / Simkl / Letterboxd when connected), filter rows (group, Media
/// Servers' Library and Genre, type, sort, grouping), search, the library repair panel, and a
/// vertical poster grid in date/title/year sections fed by the engine's use-bp-library port.
@MainActor
final class LibraryModel: ObservableObject {
    struct Tab: Decodable, Identifiable { var id: String; var label: String }
    struct Entry: Decodable, Identifiable {
        var key: String; var meta: Meta; var date: Double?; var group: String?
        var progress: Double?; var season: Int?; var episode: Int?; var watched: Bool?
        var id: String { key }
    }
    struct Section: Decodable, Identifiable { var label: String; @LossyArray var items: [Entry]; var total: Int; var id: String { label } }   // (bug pass 2) lossy: synced library
    /// A filter option (a list, server, library or genre); `count` is bp-library's option count.
    struct Group: Decodable, Identifiable { var id: String; var label: String; var count: Int? }
    struct Counts: Decodable { var all: Int; var movie: Int; var series: Int }
    struct Feed: Decodable {
        var tab: String; var sections: [Section]; var shown: Int; var matched: Int; var total: Int; var hasMore: Bool
        var groups: [Group]; var status: String; var hidden: Int; var signedIn: Bool; var sort: String; var counts: Counts
        /// bp-library `dated` / `years` over the filtered set: the View row and the Year sort.
        var dated: Bool?; var years: Bool?
        /// Media Servers only: the type, server ("" for all), library, genres, owned sort and direction
        /// the engine used (restored from the saved filter preferences when the tab opens).
        var owned: Owned?
        /// bp-library feed.entries.length: the "All" count of the group and Library rows.
        var entries: Int?
        /// Media Servers: bp-library's Library and Genre rows (feed.libraries, genreOptions).
        var libraries: [Group]?
        var genres: [Group]?
        /// Media Servers: title lookups still out (harbor:media-server-details reports each batch).
        var pending: Int?
    }
    struct Owned: Decodable {
        var type: String; var group: String; var sort: String; var dir: String
        var library: String?; var genres: [String]?
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
    /// bp-library ownedSort / sortDir: Media Servers sorts by its own key (Date added, Title, Year,
    /// Rating, Duration) in a direction, saved per profile with its type and server.
    @Published var ownedSort = "added"
    @Published var sortDir = "desc"
    /// Set when Media Servers is picked: the next feed takes type, server, sort and direction from
    /// the saved preferences (bp-library's [tab] effect) instead of the fresh-tab defaults.
    private var restoreOwned = false
    /// (review 12) Restore reads still out, and the filter picks made meanwhile: each shows at once
    /// and goes again on top of the restored filters when the read lands (see `pick`).
    private var restoreReads = 0
    private var restorePicks: [@MainActor (LibraryModel) -> Void] = []
    /// bp-library "Episodes / Posters" for History (harbor.history.view).
    @Published var episodes = Prefs.get(String.self, for: "harbor.history.view") == "episodes"
    @Published var group: String?
    /// bp-library library / genres (Media Servers): the server library and the picked genres.
    @Published var library: String?
    @Published var genres: [String] = []
    /// Bumped when a feed read because of harbor:media-server-details lands, so the grid can hand
    /// the ring on if the re-sort took its tile off the page.
    @Published private(set) var detailsLanded = 0
    private var unsubscribe: (() -> Void)?
    @Published var query = ""
    @Published var showFilters = false
    @Published var showSearch = false
    @Published var showRepair = false
    private var limit = 60

    private var profile: (id: String, linked: Bool, authKey: String?) {
        let p = ProfilesStore.shared.active
        return (p?.id ?? "default", p?.linked ?? true, p.flatMap { ProfilesStore.shared.stremioSession(for: $0.id)?.authKey })
    }

    /// bp-view-state useBpPersistedState("libraryTab"): Library opens on the tab it was left on
    /// (ShellViewState). Media Servers restores its saved filters then, as a pick of it does.
    init(tab: String? = nil) {
        if let tab, !tab.isEmpty {
            self.tab = tab
            restoreOwned = tab == "media-servers"
        }
    }

    deinit { unsubscribe?() }

    func start() async {
        // use-bp-library useMediaServerEntries: the feed is read again as media-server details
        // land, so the owned sort (Rating, Duration) and the Genre row pick them up.
        if unsubscribe == nil {
            unsubscribe = HarborEngine.shared.onEvent { [weak self] type, _ in
                guard type == "harbor:media-server-details" else { return }
                Task { @MainActor in await self?.detailsArrived() }
            }
        }
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
    /// (review 21 fixes) The generation of the last read that got no feed while it was still the
    /// newest (a read a newer one superseded is not a failure: the newer one answers for it).
    private var failedGeneration = -1

    func load(force: Bool = false) async {
        generation += 1
        let mine = generation
        loading = true
        defer { if mine == generation { loading = false } }
        let p = profile
        var fields: [String: AnyJSON] = [
            "tab": .string(tab), "profileId": .string(p.id), "linked": .bool(p.linked), "authKey": p.authKey.map { .string($0) } ?? .null,
            "sort": sortKnown ? AnyJSON.string(sort) : AnyJSON.null, "flat": .bool(flat), "type": .string(type), "query": .string(query), "episodes": .bool(episodes),
            "group": group.map { .string($0) } ?? .null, "limit": .number(Double(limit)), "force": .bool(force),
        ]
        // Media Servers: its own sort and direction, and whether to restore the saved filters.
        let restore: Bool = restoreOwned && tab == "media-servers"
        if restore { restoreReads += 1 }
        defer { if restore { restoreReads -= 1 } }
        fields["ownedSort"] = AnyJSON.string(ownedSort)
        fields["sortDir"] = AnyJSON.string(sortDir)
        fields["restore"] = AnyJSON.bool(restore)
        fields["library"] = library.map { AnyJSON.string($0) } ?? AnyJSON.null
        fields["genres"] = AnyJSON.array(genres.map { AnyJSON.string($0) })
        let input: AnyJSON = .object(fields)
        if let f: Feed = try? await HarborEngine.shared.call("libraryRoom.feed", [input]), mine == generation {
            feed = f
            sort = f.sort
            sortKnown = true
            var restored = false
            if let o = f.owned, f.tab == tab {
                restoreOwned = false
                type = o.type
                group = o.group.isEmpty ? nil : o.group
                let lib: String = o.library ?? ""
                library = lib.isEmpty ? nil : lib
                genres = o.genres ?? []
                ownedSort = o.sort
                sortDir = o.dir
                restored = true
            }
            if restore { finishRestore(restored: restored) }
            await CardMarksStore.shared.refresh(f.sections.flatMap { $0.items.map(\.meta) })
        } else if mine == generation {
            failedGeneration = mine
            if restore { finishRestore(restored: false) }
        }
    }

    /// (review 12) A filter pick. While the Media Servers restore read is out it shows at once and
    /// is kept for that read: a pick used to start its own read with the fresh-tab defaults for
    /// everything else, which dropped the restore's answer and saved those defaults over the
    /// viewer's server, library and genres.
    private func pick(_ change: @escaping @MainActor (LibraryModel) -> Void) {
        change(self)
        limit = 60
        if restoreOwned && restoreReads > 0 && tab == "media-servers" {
            restorePicks.append(change)
            return
        }
        restoreOwned = false
        Task { await load() }
    }

    /// (review 12) The restore read landed (or failed): the picks made meanwhile go again on top of
    /// the restored filters (a genre toggles against the saved set) and the feed is read with them.
    /// After a failed read they are already on screen and go through as they are.
    private func finishRestore(restored: Bool) {
        guard !restorePicks.isEmpty else { return }
        let picks = restorePicks
        restorePicks = []
        if restored { for change in picks { change(self) } }
        restoreOwned = false
        limit = 60
        Task { await load() }
    }

    /// bp-library's [tab] effect: a new tab starts unfiltered (group, type and search cleared). The
    /// search used to carry over, filtering the next tab by a title typed for the last one, even
    /// with the search row closed and nothing on screen saying so.
    func select(tab id: String) {
        tab = id; group = nil; library = nil; genres = []; type = "all"; query = ""; limit = 60
        ownedSort = "added"; sortDir = "desc"; restoreOwned = id == "media-servers"; restorePicks = []
        // Loading from this frame on: the new tab has no feed yet (shownFeed), so the page shows
        // the spinner, not the failed-read note, until the load below starts.
        loading = true
        Task { await load() }
    }
    func set(type t: String) { pick { $0.type = t } }
    func set(sort s: String) {
        sort = s; sortKnown = true; limit = 60
        // A feed already in flight (the first one asks with no sort and answers with the saved one)
        // must not land after this pick: it set `sort` back, and the load below then asked for it.
        generation += 1
        let p = profile
        Task { _ = try? await HarborEngine.shared.callJSON("libraryRoom.setSort", [.string(s), .string(p.id), .bool(p.linked)]); await load() }
    }
    func set(ownedSort k: String) { pick { $0.ownedSort = k } }
    func set(sortDir d: String) { pick { $0.sortDir = d } }
    func toggleFlat() { flat.toggle(); Task { await load() } }
    func set(episodes on: Bool) { episodes = on; try? Prefs.set(on ? "episodes" : "posters", for: "harbor.history.view"); Task { await load() } }
    func set(group g: String?) { pick { $0.group = g } }
    func set(library l: String?) { pick { $0.library = l } }
    /// bp-library Genre group: each chip toggles its genre (a title must carry every picked one).
    func toggle(genre g: String) {
        pick { model in
            if let i = model.genres.firstIndex(of: g) { model.genres.remove(at: i) } else { model.genres.append(g) }
        }
    }
    /// (review 11) A details read is running; a batch landing meanwhile asks for one more after it.
    private var detailsReading = false
    private var detailsAgain = false

    /// A details batch landed: read the Media Servers feed again with the same filters and page.
    /// (review 11) One read at a time: a big library's read can outlast the gap between batches,
    /// and each batch used to start another whole-feed read on the engine behind the last one.
    private func detailsArrived() async {
        guard tab == "media-servers" else { return }
        if detailsReading {
            detailsAgain = true
            return
        }
        detailsReading = true
        defer { detailsReading = false }
        repeat {
            detailsAgain = false
            await load()
            detailsLanded += 1
        } while detailsAgain && tab == "media-servers"
    }
    func search(_ q: String) { query = q; limit = 60; Task { await load() } }
    /// (review 21 fixes) A failed page read gives its 60 back: `limit` stayed up, so the next page
    /// asked for 120 more than the grid showed. Only while no filter, tab or newer page has moved
    /// it since. `pageFailed` lets the grid ask for that page again (autoPage's pagedAt).
    @Published private(set) var pageFailed = 0
    func more() {
        limit += 60
        let asked: Int = limit
        Task {
            await load()
            if failedGeneration == generation && limit == asked {
                limit -= 60
                pageFailed += 1
            }
        }
    }
}

struct LibraryView: View {
    @StateObject private var model: LibraryModel
    /// The shell's store: bp-view-state's libraryTab.
    private let views: ShellViewState

    init(views: ShellViewState) {
        self.views = views
        _model = StateObject(wrappedValue: LibraryModel(tab: views.libraryTab))
    }
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
    /// (parity pass 3, L3) bp-library-sections: the page count the ring last asked more at, so one
    /// page is asked for once however the ring walks the last rows while it loads.
    @State private var pagedAt: Int?
    /// When the ring last left the grid by its tile going away (or moving off it).
    @State private var gridFocusLostAt: Date?
    /// Where in the grid the ring last was: a details re-sort that takes that tile off the page
    /// hands the ring to the tile now at the same place.
    @State private var ringIndex: Int?
    /// (review 11) The tile the ring was last on: the hand-off runs only when that tile has left the
    /// page, not when the viewer moved on to Show more, Refresh or the search field (no focus id).
    @State private var ringKey: String?
    /// The filter chip ("filter:<row>:<option>") the ring was last on, kept when the chip goes away
    /// under it so the ring can be handed on (handOnFilterRing).
    @State private var lastFilterChip: String?

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
                                        // (review 11) The bar's "{n}% watched" and the tile's marks together.
                                        .accessibilityValue(Text(verbatim: tileValue(e)))
                                        // The lifted tile, ring and shadow draw over the next grid row.
                                        .zIndex(focusedKey == e.key ? 1 : 0)
                                    }
                                }
                            }
                            .focusSection()
                        }
                        // (parity pass 3, L3) bp-library-sections has no button: a sentinel under the
                        // grid pages in as the ring nears the end (autoPage). The "Show more" button
                        // it replaces is gone.
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
        // bp-view-state: the tab is kept for the next visit (the filters are this visit's own).
        .onChange(of: model.tab) { _, t in views.libraryTab = t }
        .task {
            let p = ProfilesStore.shared.active
            statsEnabled = (try? await HarborEngine.shared.call("wrapped.enabled", [p?.id ?? "default", p?.linked ?? true]) as Bool) ?? false
        }
        // bp-library BpChip autofocus={(showEmpty || first) && selected}: a grid that empties under
        // the ring (the last title taken off the Watchlist on its page, a filter) hands it to the
        // selected tab chip, not to wherever tvOS resets focus. (detail/search pass 2)
        .onChange(of: focusedKey) { old, new in
            if old != nil, new == nil { gridFocusLostAt = Date() }
            if let key = new {
                ringIndex = gridKeys.firstIndex(of: key)
                ringKey = key
                lastFilterChip = nil
                autoPage(key)
            }
        }
        // use-bp-library re-sorts as media-server details land. A tile the re-sort moved past the
        // page's end took the ring with it; the tile now in its place takes it instead.
        .onChange(of: model.detailsLanded) { _, _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                guard focusedKey == nil, focusedChip == nil, detail == nil, let i = ringIndex,
                      let lost = gridFocusLostAt, Date().timeIntervalSince(lost) < 0.6 else { return }
                let keys: [String] = gridKeys
                guard !keys.isEmpty else { return }
                // (review 11) A tile still on the page was left by the viewer, not taken by the re-sort.
                if let was = ringKey, keys.contains(was) { return }
                focusedKey = keys[min(i, keys.count - 1)]
            }
        }
        .onChange(of: focusedChip) { _, new in
            guard let chip = new else { return }
            lastFilterChip = chip.hasPrefix("filter:") ? chip : nil
        }
        .onChange(of: filterChipIds) { old, new in handOnFilterRing(old: old, new: new) }
        .onChange(of: model.shownFeed?.sections.isEmpty) { old, empty in
            guard empty == true, old == false else { return }
            // Only a ring the emptying grid just dropped (not one the viewer took to a filter row).
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                guard focusedKey == nil, focusedChip == nil, let lost = gridFocusLostAt, Date().timeIntervalSince(lost) < 0.5 else { return }
                focusedChip = "tab:" + model.tab
            }
        }
        // (parity pass 3, L3) A page that landed with the ring still in the last rows (a short page,
        // or the ring walked on while it loaded) asks for the next one, as the sentinel's recheck.
        .onChange(of: model.shownFeed?.shown) { _, _ in
            // A new page count (a page landed, or a filter / sort / search started over) re-arms it.
            pagedAt = nil
            guard let key = focusedKey else { return }
            autoPage(key)
        }
        // (review 21 fixes) A failed page read re-arms the next-page ask for the same page.
        .onChange(of: model.pageFailed) { _, _ in pagedAt = nil }
        // bp-library's [tab] effect clears the search; the field shows it.
        .onChange(of: model.tab) { _, _ in draft = ""; pagedAt = nil }
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
                    .buttonStyle(BPActionStyle(primary: filtersLit))
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
            // bp-library filterGroups order: the tab's own groups first, headed by the tab's label
            // ("My Lists", "Media Servers", "Trakt"...), then Media Servers' Library, Type, Genre
            // (owned tab), Sort (plus Direction on the owned tab), View, Episodes. Every option
            // carries bp-library's count; "All" counts every entry of the tab.
            if !groupOptions.isEmpty {
                filterRow("group", tabLabel, allOption + groupOptions, active: model.group ?? "") { model.set(group: $0.isEmpty ? nil : $0) }
            }
            // bp-library: Media Servers' Library group ("All libraries", then each server library).
            if showLibraryRow {
                filterRow("library", "Library", allLibrariesOption + libraryOptions, active: model.library ?? "") { model.set(library: $0.isEmpty ? nil : $0) }
            }
            // (device-flow pass 3) bp-library TYPES / SORTS labels ("Shows", "A-Z"); Year only when a
            // shown title has a release year; View only for the Recent sort with a dated title,
            // outside the owned (Media Servers) tab; the History row is upstream's "Episodes" group.
            filterRow("type", "Type", typeOptions, active: model.type) { model.set(type: $0) }
            // bp-library Genre group (owned tab, once a title has genres): chips toggle, several at once.
            if showGenreRow {
                filterRow("genre", "Genre", genreOptions, active: "", selected: Set(model.genres)) { model.toggle(genre: $0) }
            }
            if ownedTab {
                // bp-library OWNED_SORTS and the Direction group.
                filterRow("sort", "Sort", ownedSortOptions, active: model.ownedSort) { model.set(ownedSort: $0) }
                filterRow("direction", "Direction", directionOptions, active: model.sortDir) { model.set(sortDir: $0) }
            } else {
                filterRow("sort", "Sort", sortOptions, active: model.sort) { model.set(sort: $0) }
            }
            if showViewRow {
                filterRow("grouping", "View", viewOptions, active: model.flat ? "flat" : "grouped") { _ in model.toggleFlat() }
            }
            if model.tab == "history" {
                filterRow("cards", "Episodes", episodesOptions, active: model.episodes ? "episodes" : "posters") { model.set(episodes: $0 == "episodes") }
            }
        }
    }

    /// bp-library's Filters chip is selected while a group, library, genre or type narrows the grid.
    private var filtersLit: Bool { model.showFilters || narrowed }

    /// (review 11) A grid tile's VoiceOver value: the resume bar (bpProgressValue's "{n}% watched",
    /// 1–99 % only) and BPTileView's marks. The button's own value replaced the tile's, so a
    /// watched or bookmarked title read no mark in the Library.
    @MainActor private func tileValue(_ e: LibraryModel.Entry) -> String {
        let fraction: Double = e.progress ?? 0
        let pct: Int = Int((fraction * 100).rounded())
        let bar: String = pct >= 1 && pct <= 99 ? T("%lld%% watched", pct) : ""
        let marks: String = BPTileView.markValue(e.meta.id)
        let parts: [String] = [bar, marks].filter { !$0.isEmpty }
        return parts.joined(separator: ", ")
    }

    /// A group, library, genre or type pick narrows the grid (the empty copy says "No matches").
    private var narrowed: Bool {
        if model.type != "all" || model.group != nil { return true }
        return model.library != nil || !model.genres.isEmpty
    }

    /// bp-library `ownedTab`: local files do not exist on tvOS, so Media Servers is the one.
    private var ownedTab: Bool { model.tab == "media-servers" }

    /// bp-library `tabLabel`: the group row's heading (filterRow translates it).
    private var tabLabel: String {
        let label: String? = model.tabs.first(where: { $0.id == model.tab })?.label
        return label ?? ""
    }

    /// One chip of a filter row: bp-library-filters BpFilterOption (id, label, optional count).
    struct FilterOption {
        var id: String
        var label: String
        var count: Int?
    }

    private static func plain(_ pairs: [(String, String)]) -> [FilterOption] {
        pairs.map { FilterOption(id: $0.0, label: $0.1, count: nil) }
    }

    /// bp-library feed.entries.length (an engine without it: the type row's count).
    private var allCount: Int {
        let n: Int? = model.shownFeed?.entries
        let fallback: Int = model.shownFeed?.counts.all ?? 0
        return n ?? fallback
    }

    private var allOption: [FilterOption] { [FilterOption(id: "", label: T("All"), count: allCount)] }
    private var allLibrariesOption: [FilterOption] { [FilterOption(id: "", label: T("All libraries"), count: allCount)] }

    private var groupOptions: [FilterOption] {
        let groups: [LibraryModel.Group] = model.shownFeed?.groups ?? []
        return groups.map { FilterOption(id: $0.id, label: T($0.label), count: $0.count) }
    }

    /// Server library names are the server's own, so they are not translated (upstream neither).
    private var libraryOptions: [FilterOption] {
        let libs: [LibraryModel.Group] = model.shownFeed?.libraries ?? []
        return libs.map { FilterOption(id: $0.id, label: $0.label, count: $0.count) }
    }

    /// bp-library genreOptions: the engine lists them most titles first (a picked genre stays at 0).
    private var genreOptions: [FilterOption] {
        let genres: [LibraryModel.Group] = model.shownFeed?.genres ?? []
        return genres.map { FilterOption(id: $0.id, label: $0.label, count: $0.count) }
    }

    private var typeOptions: [FilterOption] {
        let c: LibraryModel.Counts? = model.feed?.counts
        let all: Int = c?.all ?? 0
        let movie: Int = c?.movie ?? 0
        let series: Int = c?.series ?? 0
        return [
            FilterOption(id: "all", label: T("All"), count: all),
            FilterOption(id: "movie", label: T("Movies"), count: movie),
            FilterOption(id: "series", label: T("Shows"), count: series),
        ]
    }

    private var directionOptions: [FilterOption] { Self.plain([("asc", T("Ascending")), ("desc", T("Descending"))]) }
    private var viewOptions: [FilterOption] { Self.plain([("grouped", T("Grouped")), ("flat", T("One list"))]) }
    private var episodesOptions: [FilterOption] { Self.plain([("posters", T("Posters")), ("episodes", T("Episodes"))]) }

    /// bp-library: `tab === "media-servers" && feed.libraries.length > 0`.
    private var showLibraryRow: Bool { model.tab == "media-servers" && !libraryOptions.isEmpty }

    /// bp-library: `ownedTab && genreOptions.length > 0`.
    private var showGenreRow: Bool { ownedTab && !genreOptions.isEmpty }

    /// bp-library OWNED_SORTS: every key offered (upstream does not hide Year on the owned tab).
    private var ownedSortOptions: [FilterOption] {
        Self.plain([("added", T("Date added")), ("title", T("Title")), ("year", T("Year")), ("rating", T("Rating")), ("runtime", T("Duration"))])
    }

    /// bp-library `sorts`: Year only while a shown title has a release year.
    private var sortOptions: [FilterOption] {
        var out: [(String, String)] = [("recent", T("Recent")), ("title", T("A-Z"))]
        let years: Bool = model.shownFeed?.years ?? true
        if years { out.append(("year", T("Year"))) }
        return Self.plain(out)
    }

    /// The grid's tile keys in order (what ringIndex counts).
    private var gridKeys: [String] {
        let sections: [LibraryModel.Section] = model.shownFeed?.sections ?? []
        return sections.flatMap { s in s.items.map { $0.key } }
    }

    /// (parity pass 3, L3) bp-library-sections: a sentinel under the grid asks for the next page
    /// (onMore) once it comes near the viewport. On the TV the ring is what moves the page, so the
    /// ring on a tile in the grid's last two rows is "near": the next page is asked for once per
    /// page (pagedAt), and lands under the ring without moving it.
    private func autoPage(_ key: String) {
        guard let f = model.shownFeed, f.hasMore, pagedAt != f.shown else { return }
        let keys: [String] = gridKeys
        guard let at = keys.firstIndex(of: key) else { return }
        let near: Int = columns.count * 2
        guard at >= keys.count - near else { return }
        pagedAt = f.shown
        model.more()
    }

    /// Focus ids of the filter chips on screen ("filter:<row>:<option>"), in bp-library's order.
    private var filterChipIds: [String] {
        guard model.showFilters else { return [] }
        var rows: [(String, [FilterOption])] = []
        if !groupOptions.isEmpty { rows.append(("group", allOption + groupOptions)) }
        if showLibraryRow { rows.append(("library", allLibrariesOption + libraryOptions)) }
        rows.append(("type", typeOptions))
        if showGenreRow { rows.append(("genre", genreOptions)) }
        rows.append(("sort", ownedTab ? ownedSortOptions : sortOptions))
        if ownedTab { rows.append(("direction", directionOptions)) }
        if showViewRow { rows.append(("grouping", viewOptions)) }
        if model.tab == "history" { rows.append(("cards", episodesOptions)) }
        var out: [String] = []
        for row in rows {
            for o in row.1 { out.append("filter:" + row.0 + ":" + o.id) }
        }
        return out
    }

    /// "filter:<row>:<option>" → "<row>".
    private static func rowOf(_ chip: String) -> String {
        let parts: [Substring] = chip.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        return parts.count >= 2 ? String(parts[1]) : ""
    }

    /// The chip a row hands the ring to: its active option (the first picked genre), else its first.
    private func activeChip(row: String, among ids: [String]) -> String? {
        let active: String
        switch row {
        case "group": active = model.group ?? ""
        case "library": active = model.library ?? ""
        case "type": active = model.type
        case "genre": active = model.genres.first ?? ""
        case "sort": active = ownedTab ? model.ownedSort : model.sort
        case "direction": active = model.sortDir
        case "grouping": active = model.flat ? "flat" : "grouped"
        default: active = model.episodes ? "episodes" : "posters"
        }
        let want: String = "filter:" + row + ":" + active
        if ids.contains(want) { return want }
        let prefix: String = "filter:" + row + ":"
        return ids.first(where: { $0.hasPrefix(prefix) })
    }

    /// A chip (or its whole row) went away under the ring: the Genre row comes and goes with the
    /// details, a Library or server with the index, Year with the dated titles. The ring goes to
    /// the same row's active chip, else the next row down (else up), not wherever tvOS drops it.
    private func handOnFilterRing(old: [String], new: [String]) {
        guard !new.isEmpty, let lost = lastFilterChip, old.contains(lost), !new.contains(lost) else { return }
        guard focusedChip == nil || focusedChip == lost, focusedKey == nil else { return }
        let row: String = Self.rowOf(lost)
        var target: String? = activeChip(row: row, among: new)
        if target == nil {
            var order: [String] = []
            for id in old {
                let r: String = Self.rowOf(id)
                if order.last != r { order.append(r) }
            }
            let remaining: Set<String> = Set(new.map { Self.rowOf($0) })
            if let i = order.firstIndex(of: row) {
                let after: String? = order[(i + 1)...].first(where: { remaining.contains($0) })
                let before: String? = order[..<i].last(where: { remaining.contains($0) })
                if let r = after ?? before { target = activeChip(row: r, among: new) }
            }
        }
        guard let chip = target else { return }
        DispatchQueue.main.async {
            guard focusedKey == nil, focusedChip == nil || focusedChip == lost else { return }
            focusedChip = chip
        }
    }

    /// bp-library: the View group needs the Recent sort and a dated title, on a tab that is not
    /// owned media (local / media-servers).
    private var showViewRow: Bool {
        let dated: Bool = model.shownFeed?.dated ?? true
        return !ownedTab && model.sort == "recent" && dated
    }

    /// One bp-library-filters group: heading, then its chips (Left/Right within, Up/Down between).
    /// `selected` makes it a multi-pick row (Genre). A chip counting 0 is dimmed, never disabled:
    /// it stays focusable, so a picked genre that left the scope can still be cleared.
    private func filterRow(_ key: String, _ heading: String, _ options: [FilterOption], active: String, selected: Set<String>? = nil, pick: @escaping (String) -> Void) -> some View {
        HStack(spacing: BP.px(8)) {
            Text(T(heading).uppercased()).font(BP.sans(11, .bold)).tracking(1.5).foregroundStyle(BP.inkSubtle).frame(width: BP.px(120), alignment: .leading)
            // A Genre or Library row can hold more chips than the page is wide.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: BP.px(8)) {
                    ForEach(options, id: \.id) { o in
                        filterChip(key, o, on: selected.map { $0.contains(o.id) } ?? (active == o.id), pick: pick)
                    }
                }
            }
            // The focused chip's ring must not be clipped by the track (as tabRow).
            .scrollClipDisabled()
        }
        .focusSection()
    }

    private func filterChip(_ key: String, _ o: FilterOption, on: Bool, pick: @escaping (String) -> Void) -> some View {
        let title: String = o.count.map { o.label + " " + String($0) } ?? o.label
        let dim: Bool = o.count == 0 && !on
        return Button(title) { pick(o.id) }
            .buttonStyle(BPActionStyle(primary: on))
            .bpSelected(on)
            .opacity(dim ? 0.45 : 1)
            .focused($focusedChip, equals: "filter:" + key + ":" + o.id)
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
        else if f.total > 0 || !model.query.isEmpty || narrowed { text = "No matches for these filters." }
        else {
            switch model.tab {
            case "library" where !f.signedIn: text = "Sign in to Stremio or connect Trakt in Settings to see your library here."
            case "history" where !f.signedIn: text = "Sign in to Stremio or connect Trakt in Settings to see what you have been watching."
            case "watchlist": text = "Your watchlist is empty."
            case "history": text = "Nothing watched yet. Press play on something."
            case "lists": text = "You have no lists yet."
            // bp-library emptyMessage: the character and manga favourites the grid does not draw.
            case "favorites" where f.hidden > 0: text = T("Your %lld character and manga favorites live on the desktop Favorites tab.", f.hidden)
            case "favorites": text = "No favorites yet. Save a movie or show to see it here."
            case "library": text = "Nothing saved yet. Add a title from any details page."
            default: text = "Nothing here yet."
            }
        }
        return BPNote(text: text).padding(.top, BP.px(10))
    }
}
