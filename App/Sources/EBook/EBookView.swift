import SwiftUI

/// views/ebook.tsx browse state: the selected provider, the catalog page(s), a search's results,
/// and the metadata pass each page gets (page.enriched), with loadMore's stale-page streak.
@MainActor
final class EBookRoomModel: ObservableObject {
    private struct Page: Decodable { var items: [EBook]; var fresh: Int; var cursor: [String: Double]; var hasMore: Bool; var token: Int }

    @Published private(set) var providerId = ""
    /// The provider's catalog (sourceItems); nil while it loads.
    @Published private(set) var items: [EBook]? { didSet { Task { await applyFilters() } } }
    /// A search's results; nil when no query is active or while one loads.
    @Published private(set) var results: [EBook]? { didSet { Task { await applyFilters() } } }
    @Published var query = "" { didSet { if query != oldValue { search() } } }
    @Published private(set) var hasMore = false
    @Published private(set) var loadingMore = false
    @Published private(set) var failed = false
    /// useEBookReadStatus per book on screen.
    @Published private(set) var statuses: [String: String] = [:]

    // MARK: browse filters (views/ebook.tsx browseStatus / browseLanguage / browseSort /
    // categoryGroup / category). The TV cycles these on chips and applies at once, instead of
    // upstream's dropdowns + Apply button (App/Sources/Streams/PlayPickerView's own facet chips).
    @Published var filterType = "All" {
        didSet {
            guard filterType != oldValue else { return }
            if !EBookRoomModel.genreOptions(for: filterType).contains(filterGenre) { filterGenre = "" }
            Task { await applyFilters() }
        }
    }
    @Published var filterGenre = "" { didSet { if filterGenre != oldValue { Task { await applyFilters() } } } }
    @Published var filterStatus = "any" { didSet { if filterStatus != oldValue { Task { await applyFilters() } } } }
    @Published var filterLanguage = "any" { didSet { if filterLanguage != oldValue { Task { await applyFilters() } } } }
    @Published var filterSort = "popular" { didSet { if filterSort != oldValue { Task { await applyFilters() } } } }
    /// `shown` (below) after ebook.applyBrowseFilters; nil while it loads, same as `shown`.
    @Published private(set) var displayed: [EBook]?
    private var filterSeq = 0

    /// browse-filters.ts EBOOK_CATEGORIES[type] (+ EBOOK_FILTER_GENRES for "All" or "Fiction"),
    /// deduped in order, like the view's own Genre dropdown options.
    static func genreOptions(for type: String) -> [String] {
        guard let cats = EBookStore.shared.browseCategories else { return [] }
        var list: [String] = []
        if type == "All" {
            for key in cats.order { list.append(contentsOf: cats.groups[key] ?? []) }
            list.append(contentsOf: cats.genres)
        } else {
            list.append(contentsOf: cats.groups[type] ?? [])
            if type == "Fiction" { list.append(contentsOf: cats.genres) }
        }
        var seen = Set<String>()
        return list.filter { seen.insert($0).inserted }
    }

    func applyFilters() async {
        filterSeq += 1
        let seq = filterSeq
        guard let items = shown else { displayed = nil; return }
        let filters = EBookBrowseFilters(type: filterType, genre: filterGenre, status: filterStatus, language: filterLanguage, sort: filterSort)
        let result: [EBook]? = try? await HarborEngine.shared.call("ebook.applyBrowseFilters", [items, filters])
        guard seq == filterSeq else { return }
        displayed = result ?? items
    }

    private var cursor: [String: Double] = [:]
    private var sourceSeq = 0
    private var searchSeq = 0
    private var staleStreak = 0
    private var loadFails = 0
    private var debounce: Task<Void, Never>?

    var searching: Bool { query.trimmingCharacters(in: .whitespaces).count >= 2 }
    /// What the grid shows: the results while searching, the catalog otherwise.
    var shown: [EBook]? { searching ? results : items }

    /// loadSources(requestedProvider): the requested provider when listed, else the first.
    func loadSources(_ providers: [EBookState.Provider], requested: String? = nil) {
        sourceSeq += 1
        let seq = sourceSeq
        let want = requested ?? providerId
        providerId = providers.contains(where: { $0.id == want }) ? want : (providers.first?.id ?? "")
        cursor = [:]
        hasMore = false
        items = nil
        failed = false
        staleStreak = 0
        loadFails = 0
        guard !providerId.isEmpty else { items = []; return }
        let provider = providerId
        Task {
            do {
                let page: Page = try await HarborEngine.shared.call("ebook.page", [Optional<String>.none, provider, Optional<[String: Double]>.none, Optional<String>.none, Optional<[EBook]>.none])
                guard seq == sourceSeq else { return }
                items = page.items
                cursor = page.cursor
                hasMore = page.hasMore
                await refreshStatuses()
                await fold(page.token, results: false) { seq == self.sourceSeq }
            } catch {
                guard seq == sourceSeq else { return }
                items = []
                failed = true
            }
        }
    }

    /// views/ebook.tsx search: under two characters goes back to the catalog; otherwise the
    /// provider is searched 300 ms after the last keystroke.
    private func search() {
        searchSeq += 1
        let seq = searchSeq
        debounce?.cancel()
        results = nil
        guard searching else { return }
        cursor = [:]
        hasMore = false
        staleStreak = 0
        let term = query.trimmingCharacters(in: .whitespaces)
        let provider = providerId
        debounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self, !Task.isCancelled, seq == self.searchSeq else { return }
            do {
                let page: Page = try await HarborEngine.shared.call("ebook.page", [term, provider, Optional<[String: Double]>.none, Optional<String>.none, Optional<[EBook]>.none])
                guard seq == self.searchSeq else { return }
                self.results = page.items
                self.cursor = page.cursor
                self.hasMore = page.hasMore
                await self.refreshStatuses()
                await self.fold(page.token, results: true) { seq == self.searchSeq }
            } catch {
                if seq == self.searchSeq { self.results = [] }
            }
        }
    }

    /// views/ebook.tsx loadMore: three pages in a row with nothing new, or three failures, stop it.
    func loadMore() {
        guard hasMore, !loadingMore else { return }
        loadingMore = true
        let sSeq = sourceSeq, qSeq = searchSeq
        let term: String? = searching ? query.trimmingCharacters(in: .whitespaces) : nil
        let current = shown ?? []
        let provider = providerId
        let at = cursor
        Task {
            defer { loadingMore = false }
            do {
                let page: Page = try await HarborEngine.shared.call("ebook.page", [term, provider, at, Optional<String>.none, current])
                guard sSeq == sourceSeq, qSeq == searchSeq else { return }
                cursor = page.cursor
                loadFails = 0
                staleStreak = page.fresh > 0 ? 0 : staleStreak + 1
                hasMore = page.hasMore && staleStreak < 3
                if term != nil { results = page.items } else { items = page.items }
                await refreshStatuses()
                await fold(page.token, results: term != nil) { sSeq == self.sourceSeq && qSeq == self.searchSeq }
            } catch {
                loadFails += 1
                if loadFails >= 3 { hasMore = false }
            }
        }
    }

    /// page.enriched → updateSourceItems(current, items, true): the metadata pass folds into the
    /// list as it is by then (another page may have landed meanwhile), not the one it started from.
    private func fold(_ token: Int, results isResults: Bool, valid: () -> Bool) async {
        guard let enriched: [EBook] = try? await HarborEngine.shared.call("ebook.enriched", [token]) else { return }
        for _ in 0..<3 {
            guard valid() else { return }
            let base = (isResults ? results : items) ?? []
            guard let merged: [EBook] = try? await HarborEngine.shared.call("ebook.merge", [base, enriched, true]) else { return }
            guard valid() else { return }
            // Folded into the list still on screen: done. Otherwise fold into the newer one.
            if ((isResults ? results : items) ?? []).map(\.id) == base.map(\.id) {
                if isResults { results = merged } else { items = merged }
                return
            }
        }
    }

    func refreshStatuses() async {
        let ids = (items ?? []) + (results ?? []) + EBookStore.shared.shelf + EBookStore.shared.favorites
        statuses = await EBookStore.shared.statuses(Array(Set(ids.map(\.id))))
    }
}

/// The eBook room (views/ebook.tsx), for the remote: the setup screen until a source is added,
/// then the home: hero, Favorites, Continue your bookmarks, Popular eBooks, the Shelf, and the
/// browse grid with search and the catalog picker.
@MainActor
struct EBookView: View {
    @ObservedObject private var store = EBookStore.shared
    @StateObject private var model = EBookRoomModel()
    @State private var open: EBookOpen?
    @State private var sourcesOpen = false
    @State private var shelfOpen = false
    /// A book picked on the Shelf page, opened once that page has gone.
    @State private var shelfPick: EBookOpen?
    @State private var spotlight: EBook?
    @State private var continueRows: [EBookContinue] = []
    @State private var loadedFor: String?
    @FocusState private var gridFocus: String?
    @FocusState private var searchFocused: Bool
    /// engine ebook.nytRail(apiKey): nil while it loads or without a key and no cached snapshot.
    @State private var nyt: EBookNytRail?
    @State private var collectionsOpen = false
    /// views/ebook.tsx isNytPlaceholder → emitListToast("Not available in your sources yet").
    @State private var toast: String?
    @ObservedObject private var settingsBridge = SettingsBridge.shared

    var body: some View {
        ZStack(alignment: .topLeading) {
            if store.state == nil {
                ProgressView().tint(BP.inkMuted).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if store.state?.providers.isEmpty != false {
                setup
            } else {
                home
            }
            if let toast {
                Text(toast).font(BP.sans(14, .semibold)).foregroundStyle(BP.ink)
                    .padding(.horizontal, BP.px(18)).padding(.vertical, BP.px(12))
                    .background(Capsule().fill(BP.panel2))
                    .padding(.bottom, BP.px(50))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .task {
            await store.refresh()
            reloadIfNeeded()
            // views/ebook.tsx loadAnilistLibrary: warm the AniList tracking cache once per visit,
            // like the anime rails' own tracker refresh (engine/trackers.ts anilist.rails), then
            // recompute the cards' read marks in case a status only just landed from AniList.
            await store.refreshAnilistLibrary()
            await model.refreshStatuses()
        }
        .task(id: continueKey) { await refreshContinue() }
        .task(id: settingsBridge.slice.nytKey) { await loadNyt() }
        .fullScreenCover(item: $open, onDismiss: { Task { await store.refreshLists(); await model.refreshStatuses() } }) { o in
            EBookDetailView(open: o, candidates: model.shown ?? [])
        }
        .fullScreenCover(isPresented: $sourcesOpen, onDismiss: { Task { await store.refresh(); reloadIfNeeded() } }) {
            EBookSourcesView { sourcesOpen = false }
        }
        // (device-flow pass) The book opens after the Shelf cover has closed: dismissing one cover and
        // presenting another in the same update dropped the new one, so the Shelf closed and nothing opened.
        .fullScreenCover(isPresented: $shelfOpen, onDismiss: {
            if let pick = shelfPick { shelfPick = nil; open = pick }
        }) {
            EBookShelfView(onOpen: { b in shelfPick = EBookOpen(id: b.id); shelfOpen = false }, onClose: { shelfOpen = false })
        }
        .fullScreenCover(isPresented: $collectionsOpen) {
            EBookCollectionsView(
                providerId: model.providerId,
                providerIds: store.state?.providers.map(\.id) ?? [],
                seedItems: model.items ?? [],
                onOpen: { b in open = EBookOpen(id: b.id) },
                onClose: { collectionsOpen = false }
            )
        }
    }

    /// views/ebook.tsx isNytPlaceholder guard on a rail/hero open: a toast instead of a cover.
    private func showToast(_ text: String) {
        toast = text
        Task {
            try? await Task.sleep(for: .seconds(3))
            if toast == text { withAnimation { toast = nil } }
        }
    }

    /// engine ebook.nytRail: cheap to call every time the room opens (nyt.ts only refetches once
    /// the cached snapshot is a week old, and does nothing at all without a key beyond that read).
    private func loadNyt() async {
        nyt = try? await HarborEngine.shared.call("ebook.nytRail", [settingsBridge.slice.nytKey])
    }

    private func openNyt(_ ebook: EBook) {
        if ebook.isNytPlaceholder { showToast(T("Not available in your sources yet")) } else { open = EBookOpen(id: ebook.id) }
    }

    /// Feeds reload when the provider list changes (subscribeEBookSources → loadSources).
    private func reloadIfNeeded() {
        guard let s = store.state, !s.providers.isEmpty else { return }
        let key = s.providers.map(\.id).joined(separator: ",")
        guard loadedFor != key else { return }
        loadedFor = key
        spotlight = nil
        model.loadSources(s.providers)
    }

    private var continueKey: String { "\(store.resumeVersion)|\(model.items?.count ?? -1)|\(store.pid)" }

    private func refreshContinue() async {
        let candidates = (model.items ?? []) + (model.results ?? [])
        continueRows = (try? await HarborEngine.shared.call("ebook.continueList", [store.pid, candidates])) ?? []
    }

    // MARK: setup (ebook-setup.tsx)

    private var setup: some View {
        VStack(alignment: .leading, spacing: BP.px(16)) {
            Image(systemName: "books.vertical").font(.system(size: BP.px(30), weight: .semibold)).foregroundStyle(BP.ink).accessibilityHidden(true)
            Text("Read eBooks in Harbor").font(BP.display(36)).foregroundStyle(BP.ink)
            BPNote(text: "Harbor does not host any books. Open a folder on this device, install a source extension, or connect your own server. Metadata can describe a book, but a source is what lets Harbor open it.")
                .frame(maxWidth: BP.px(640), alignment: .leading)
            BPNote(text: EBookSourcesView.tvNote, tone: BP.inkSubtle).frame(maxWidth: BP.px(640), alignment: .leading)
            Button("Set up eBooks") { sourcesOpen = true }.buttonStyle(BPActionStyle(primary: true))
            Text("Harbor never hosts your books or source files.").font(BP.sans(12)).foregroundStyle(BP.inkSubtle)
        }
        .padding(.horizontal, BP.gutter).padding(.top, BP.barHeight + BP.px(80))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .focusSection()
    }

    // MARK: home

    /// views/ebook.tsx featuredBooks: popular books with a real cover (not a "default" image).
    private var featured: [EBook] {
        (model.items ?? []).filter { b in
            guard let c = b.cover else { return false }
            return c.range(of: #"(?:^|/)default(?:\.[a-z0-9]+)?(?:[?#]|$)"#, options: [.regularExpression, .caseInsensitive]) == nil
        }
    }

    /// views/ebook.tsx bestsellerHero: bestseller books with a cover, up to 5, when there are 3+
    /// of them; otherwise the popular-source fallback (featured).
    private var bestsellerHero: [EBook] {
        Array((nyt?.items ?? []).filter { $0.cover != nil }.prefix(5))
    }
    private var heroPool: [EBook] { bestsellerHero.count >= 3 ? bestsellerHero : featured }
    private var hero: EBook? { spotlight ?? heroPool.first }

    private var home: some View {
        ZStack(alignment: .top) {
            heroBackdrop
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: BP.rowGap) {
                    heroCopy.frame(height: BP.px(300), alignment: .bottomLeading)
                    // views/ebook.tsx rails: Favorites (source books), Continue your bookmarks,
                    // New York Times Bestsellers, Popular.
                    let favs = store.favorites.filter { $0.source == "source" }
                    if !favs.isEmpty {
                        rail("ebook-favorites", "Favorites", "Stories you love", favs)
                    }
                    if !continueRows.isEmpty { continueRow }
                    if let nyt, !nyt.items.isEmpty { nytRailSection(nyt) }
                    if let items = model.items, !items.isEmpty {
                        rail("ebook-popular", "Popular eBooks", "Popular titles from the installed source", Array(items.prefix(24)))
                    }
                    collectionsAndShelfRow
                    browseSection
                    Color.clear.frame(height: BP.hintHeight + BP.px(40))
                }
            }
        }
    }

    /// views/ebook.tsx EBookRail(bestsellerItems, mark: <NytMark/>, subtitle: NYT_ATTRIBUTION).
    /// The mark sits beside the attribution line instead of the row's own title (BPRowView draws
    /// the title itself, with no slot for a mark next to it) — a small, low-risk TV adaptation.
    private func nytRailSection(_ nyt: EBookNytRail) -> some View {
        VStack(alignment: .leading, spacing: BP.px(2)) {
            BPRowView(row: BrowseRow(key: "ebook-nyt", title: T("New York Times Bestsellers"), metas: nyt.items.map(\.meta)),
                      onFocus: { m in spotlight = nyt.items.first { $0.id == m.id } },
                      onSelect: { m in if let b = nyt.items.first(where: { $0.id == m.id }) { openNyt(b) } })
            HStack(spacing: BP.px(6)) {
                NytMarkView()
                Text(T(nyt.attribution)).font(BP.sans(12)).foregroundStyle(BP.inkSubtle)
            }
            .padding(.horizontal, BP.gutter)
        }
    }

    private func rail(_ key: String, _ title: String, _ subtitle: String, _ books: [EBook]) -> some View {
        VStack(alignment: .leading, spacing: BP.px(2)) {
            BPRowView(row: BrowseRow(key: key, title: T(title), metas: books.map(\.meta)),
                      onFocus: { m in spotlight = books.first { $0.id == m.id } },
                      onSelect: { m in open = EBookOpen(id: m.id) })
            Text(T(subtitle)).font(BP.sans(12)).foregroundStyle(BP.inkSubtle).padding(.horizontal, BP.gutter)
        }
    }

    private var heroBackdrop: some View {
        ZStack {
            BP.void_
            // (perf pass 2) Follows focus once it settles, pre-blurred once per cover.
            BPBlurredHeroBackdrop(url: hero?.banner ?? hero?.cover)
            LinearGradient(colors: [BP.void_.opacity(0.2), BP.void_.opacity(0.8), BP.void_], startPoint: .top, endPoint: .init(x: 0.5, y: 0.55))
        }
        .ignoresSafeArea()
    }

    /// EBookLibraryHero, still: the focused (or first featured) book, its author and blurb.
    private var heroCopy: some View {
        HStack(alignment: .bottom, spacing: BP.px(20)) {
            if let h = hero {
                RemoteImage(url: h.cover)
                    .frame(width: BP.px(110), height: BP.px(165))
                    .clipShape(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: BP.px(6)) {
                    Text("eBooks").font(BP.sans(11, .bold)).textCase(.uppercase).tracking(1.4).foregroundStyle(BP.accent)
                    Text(h.title).font(BP.display(34)).foregroundStyle(BP.ink).lineLimit(2)
                    if !h.authors.isEmpty { Text(h.authors.prefix(2).joined(separator: ", ")).font(BP.sans(13, .medium)).foregroundStyle(BP.inkMuted) }
                    if !h.description.isEmpty {
                        Text(h.description).font(BP.sans(13)).foregroundStyle(BP.inkMuted).lineLimit(3).frame(maxWidth: BP.px(620), alignment: .leading)
                    }
                }
            } else {
                Text("eBooks").font(BP.display(36)).foregroundStyle(BP.ink)
            }
            Spacer()
        }
        .padding(.horizontal, BP.gutter)
        .animation(BP.easeFast, value: hero?.id)
    }

    /// "Continue your bookmarks": Select opens the book straight into the reader (readIntent).
    private var continueRow: some View {
        VStack(alignment: .leading, spacing: BP.px(10)) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Continue your bookmarks").font(BP.sans(19, .bold)).foregroundStyle(BP.ink).accessibilityAddTraits(.isHeader)
                Text("Resume from your saved reading position").font(BP.sans(12)).foregroundStyle(BP.inkSubtle)
            }
            .padding(.horizontal, BP.gutter)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: BP.trackGap) {
                    ForEach(continueRows) { c in
                        Button { open = EBookOpen(id: c.ebook.id, autoRead: true) } label: { continueCard(c) }
                            .buttonStyle(BPTileStyle())
                    }
                }
                .padding(.horizontal, BP.gutter).padding(.vertical, BP.px(14))
            }
            .scrollClipDisabled()
        }
        .focusSection()
    }

    private func continueCard(_ c: EBookContinue) -> some View {
        VStack(alignment: .leading, spacing: BP.px(6)) {
            ZStack(alignment: .bottomLeading) {
                RemoteImage(url: c.ebook.cover)
                    .accessibilityHidden(true)
                GeometryReader { g in
                    Capsule().fill(BP.accent).frame(width: g.size.width * c.resume.bookFraction, height: BP.px(3))
                }
                .frame(height: BP.px(3))
                // ebook.tsx EBookProgressSeeker aria-label={t("Complete book")}: the whole book's progress.
                .bpProgressValue(c.resume.bookFraction, key: "%lld%% read")
            }
            .frame(width: BPTileView.posterSize.width, height: BPTileView.posterSize.height)
            .clipShape(RoundedRectangle(cornerRadius: BP.rXS, style: .continuous))
            Text(c.ebook.title).font(BP.sans(11.5, .semibold)).foregroundStyle(BP.ink).lineLimit(1)
            Text(c.resume.chapterLabel ?? c.resume.chapterTitle ?? "").font(BP.sans(10.5)).foregroundStyle(BP.inkMuted).lineLimit(1)
        }
        .frame(width: BPTileView.posterWidth, alignment: .leading)
    }

    /// views/ebook.tsx's "Collections" and "Shelf" quick-launch cards, side by side.
    private var collectionsAndShelfRow: some View {
        HStack(spacing: BP.px(14)) {
            collectionsButton
            shelfButton
        }
        .padding(.horizontal, BP.gutter)
        .focusSection()
    }

    /// The Collections card (views/ebook.tsx setScreen("collections")): series, the source's own
    /// catalog and award winners, in a page of their own.
    private var collectionsButton: some View {
        Button { collectionsOpen = true } label: {
            HStack(spacing: BP.px(14)) {
                Image(systemName: "square.stack.3d.up.fill").font(.system(size: BP.px(20), weight: .semibold)).foregroundStyle(BP.accent).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Collections").font(BP.sans(15.5, .semibold)).foregroundStyle(BP.ink)
                    Text("Shelves built from your installed source catalog").font(BP.sans(13)).foregroundStyle(BP.inkMuted).lineLimit(1)
                }
                Spacer(minLength: BP.px(20))
                Image(systemName: "chevron.forward").foregroundStyle(BP.inkSubtle).accessibilityHidden(true)
            }
            .padding(.horizontal, BP.px(20)).padding(.vertical, BP.px(14))
            .frame(width: BP.px(420), alignment: .leading)
            .background(RoundedRectangle(cornerRadius: BP.rMD, style: .continuous).fill(BP.panel))
        }
        .buttonStyle(BPTileStyle(radius: BP.rMD))
        // UI tests (NavigationTests5): opens EBookCollectionsView.
        .accessibilityIdentifier("ebook-collections")
    }

    /// The Shelf card (views/ebook.tsx): the books saved to the shelf, in a page of their own.
    private var shelfButton: some View {
        Button { shelfOpen = true } label: {
            HStack(spacing: BP.px(14)) {
                Image(systemName: "books.vertical.fill").font(.system(size: BP.px(20), weight: .semibold)).foregroundStyle(BP.accent).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Shelf").font(BP.sans(15.5, .semibold)).foregroundStyle(BP.ink)
                    // (bug pass) T(): inside a String ternary the literal was never looked up.
                    Text(store.shelf.isEmpty ? T("Books you save will appear here") : T("%lld books saved", store.shelf.count))
                        .font(BP.sans(13)).foregroundStyle(BP.inkMuted)
                }
                Spacer(minLength: BP.px(20))
                Image(systemName: "chevron.forward").foregroundStyle(BP.inkSubtle).accessibilityHidden(true)
            }
            .padding(.horizontal, BP.px(20)).padding(.vertical, BP.px(14))
            .frame(width: BP.px(420), alignment: .leading)
            .background(RoundedRectangle(cornerRadius: BP.rMD, style: .continuous).fill(BP.panel))
        }
        .buttonStyle(BPTileStyle(radius: BP.rMD))
        // UI tests (NavigationTests5): distinguishes it from the Collections card beside it.
        .accessibilityIdentifier("ebook-shelf")
    }

    // MARK: browse

    private var browseSection: some View {
        VStack(alignment: .leading, spacing: BP.px(14)) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Browse eBooks").font(BP.sans(22, .bold)).foregroundStyle(BP.ink)
                Text(store.state?.providers.first(where: { $0.id == model.providerId })?.name ?? T("Installed sources"))
                    .font(BP.sans(13)).foregroundStyle(BP.inkSubtle)
            }
            HStack(alignment: .bottom, spacing: BP.px(12)) {
                BPField(label: "Search eBooks", placeholder: "Title or author", text: $model.query, phone: true, focus: $searchFocused)
                    .frame(width: BP.px(420))
                if !model.query.isEmpty {
                    // (review 24) Clear leaves with the query it clears: the ring goes to the field.
                    Button("Clear") { searchFocused = true; model.query = "" }.buttonStyle(BPActionStyle())
                }
                Button { refresh() } label: { Label("Refresh source", systemImage: "arrow.clockwise") }
                    .buttonStyle(BPActionStyle())
                    // UI tests (NavigationTests5): Down into the browse row lands here first.
                    .accessibilityIdentifier("ebook-refresh-source")
                Button { sourcesOpen = true } label: { Label("Manage eBook sources", systemImage: "gearshape") }
                    .buttonStyle(BPActionStyle())
                    // UI tests (NavigationTests5): opens EBookSourcesView (the NYT key row lives there).
                    .accessibilityIdentifier("ebook-manage-sources")
            }
            .focusSection()
            // The Catalog dropdown: only when there is more than one to pick ("All Sources" + each).
            if let providers = store.state?.providers, providers.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: BP.px(8)) {
                        ForEach(providers) { p in
                            Button(p.name) { model.loadSources(providers, requested: p.id) }
                                .buttonStyle(BPActionStyle(primary: model.providerId == p.id)).bpSelected(model.providerId == p.id)
                                // UI tests (NavigationTests5): the walk to the browse row passes here.
                                .accessibilityIdentifier("ebook-catalog-\(p.id)")
                        }
                    }
                    .padding(.vertical, BP.px(6))
                }
                .scrollClipDisabled()
                .focusSection()
            }
            filterChips
            grid
        }
        .padding(.horizontal, BP.gutter)
        .onChange(of: gridFocus) { _, id in
            if let id, let b = model.displayed?.first(where: { $0.id == id }) { spotlight = b }
        }
    }

    private func refresh() {
        guard let providers = store.state?.providers else { return }
        if model.searching {
            let q = model.query
            model.query = ""
            model.query = q
        } else {
            model.loadSources(providers)
        }
    }

    /// views/ebook.tsx Type / Genre / Status / Language / Sort dropdowns, as chips that cycle
    /// their value and apply at once (App/Sources/Streams/PlayPickerView's own facet chips).
    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: BP.px(8)) {
                filterChip(T("Type"), T(model.filterType), Self.typeOptions, $model.filterType, testId: "ebook-filter-type")
                let genreOptions = [""] + EBookRoomModel.genreOptions(for: model.filterType)
                filterChip(T("Genre"), model.filterGenre.isEmpty ? T("All genres") : T(model.filterGenre), genreOptions, $model.filterGenre, testId: "ebook-filter-genre")
                filterChip(T("Status"), T(Self.statusLabels[model.filterStatus] ?? model.filterStatus), Self.statusOptions, $model.filterStatus, testId: "ebook-filter-status")
                filterChip(T("Language"), T(Self.languageLabels[model.filterLanguage] ?? model.filterLanguage), Self.languageOptions, $model.filterLanguage, testId: "ebook-filter-language")
                filterChip(T("Sort by"), T(Self.sortLabels[model.filterSort] ?? model.filterSort), Self.sortOptions, $model.filterSort, testId: "ebook-filter-sort")
            }
            .padding(.vertical, BP.px(4))
        }
        .scrollClipDisabled()
        .focusSection()
    }

    private static let typeOptions = ["All", "Fiction", "Non-fiction"]
    private static let statusOptions = ["any", "ongoing", "completed", "hiatus"]
    private static let statusLabels = ["any": "Any", "ongoing": "Ongoing", "completed": "Completed", "hiatus": "Hiatus"]
    private static let languageOptions = ["any", "chinese", "korean", "japanese"]
    private static let languageLabels = ["any": "Any", "chinese": "Chinese", "korean": "Korean", "japanese": "Japanese"]
    private static let sortOptions = ["popular", "name", "chapters", "rating", "trending"]
    private static let sortLabels = ["popular": "Popular", "name": "Name", "chapters": "Chapters", "rating": "Rating", "trending": "Trending"]

    /// A single cycling chip: tapping steps to the next option, wrapping to the first.
    private func filterChip(_ label: String, _ valueLabel: String, _ options: [String], _ binding: Binding<String>, testId: String) -> some View {
        let active = options.first != binding.wrappedValue
        return Button("\(label): \(valueLabel)") {
            let i = options.firstIndex(of: binding.wrappedValue) ?? 0
            binding.wrappedValue = options[(i + 1) % options.count]
        }
        .buttonStyle(BPActionStyle(primary: active))
        .bpSelected(active)
        // UI tests (NavigationTests5): each chip cycles and applies its filter at once.
        .accessibilityIdentifier(testId)
    }

    @ViewBuilder private var grid: some View {
        if let books = model.displayed {
            if books.isEmpty {
                BPNote(text: model.failed ? "This source did not answer. Try again, or try another source." : "No eBooks found.")
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: BPTileView.posterWidth, maximum: BPTileView.posterWidth), spacing: BP.trackGap)],
                          alignment: .leading, spacing: BP.px(18)) {
                    ForEach(books) { b in
                        Button { open = EBookOpen(id: b.id) } label: {
                            EBookCardView(ebook: b, status: model.statuses[b.id], focused: gridFocus == b.id)
                        }
                        .buttonStyle(BPTileStyle())
                        .focused($gridFocus, equals: b.id)
                        .onAppear { if b.id == books.last?.id { model.loadMore() } }
                    }
                }
                .focusSection()
                if model.loadingMore { ProgressView().tint(BP.inkMuted) }
            }
        } else {
            ProgressView().tint(BP.inkMuted).padding(.vertical, BP.px(30))
        }
    }
}

/// EBookCard: the cover, the read mark, title, authors and the facts line.
struct EBookCardView: View {
    let ebook: EBook
    var status: String?
    var focused = false

    var body: some View {
        VStack(alignment: .leading, spacing: BP.px(5)) {
            ZStack(alignment: .topTrailing) {
                RemoteImage(url: ebook.cover)
                    .frame(width: BPTileView.posterSize.width, height: BPTileView.posterSize.height)
                    .clipShape(RoundedRectangle(cornerRadius: BP.rXS, style: .continuous))
                    .accessibilityHidden(true)
                if let status { EBookReadMark(status: status).padding(BP.px(6)) }
            }
            Text(ebook.title).font(BP.sans(11.5, .semibold)).foregroundStyle(BP.ink).lineLimit(2)
                .frame(height: BP.px(30), alignment: .topLeading)
            if !ebook.authors.isEmpty {
                Text(ebook.authors.prefix(2).joined(separator: ", ")).font(BP.sans(10.5)).foregroundStyle(BP.inkMuted).lineLimit(1)
            }
            if !ebook.cardFacts.isEmpty {
                Text(ebook.cardFacts).font(BP.sans(10)).foregroundStyle(BP.inkSubtle).lineLimit(1)
            }
        }
        .frame(width: BPTileView.posterWidth, alignment: .leading)
    }
}

/// EBookReadMark: a check for a finished book, a half circle for one under way.
struct EBookReadMark: View {
    let status: String
    var body: some View {
        Image(systemName: status == "read" ? "checkmark" : "circle.lefthalf.filled")
            .font(.system(size: BP.px(10), weight: .bold))
            .foregroundStyle(status == "read" ? BP.canvas : BP.ink)
            .frame(width: BP.px(22), height: BP.px(22))
            .background(Circle().fill(status == "read" ? BP.accent : BP.void_.opacity(0.75)))
            .accessibilityLabel(status == "read" ? T("Read") : T("In progress"))
    }
}

/// components/icons/nyt-mark.tsx NytMark: a bordered "NYT" wordmark (no logo asset on the TV).
struct NytMarkView: View {
    var body: some View {
        Text(verbatim: "NYT")
            .font(.system(size: BP.px(10), weight: .bold, design: .serif))
            .foregroundStyle(BP.ink)
            .padding(.horizontal, BP.px(5)).padding(.vertical, BP.px(1))
            .overlay(RoundedRectangle(cornerRadius: BP.px(3), style: .continuous).stroke(BP.ink, lineWidth: 1))
            .accessibilityHidden(true)
    }
}

/// views/ebook.tsx screen "shelf": every book saved to the shelf, as a grid.
@MainActor
struct EBookShelfView: View {
    let onOpen: (EBook) -> Void
    let onClose: () -> Void
    @ObservedObject private var store = EBookStore.shared
    @State private var statuses: [String: String] = [:]

    var body: some View {
        ZStack {
            BPAmbientBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: BP.px(22)) {
                    VStack(alignment: .leading, spacing: BP.px(4)) {
                        Text("Shelf").font(BP.display(34)).foregroundStyle(BP.ink)
                        Text(store.shelf.isEmpty ? T("Books you add to your shelf will appear here.") : T("%lld books saved to your shelf", store.shelf.count))
                            .font(BP.sans(14)).foregroundStyle(BP.inkMuted)
                    }
                    if store.shelf.isEmpty {
                        VStack(alignment: .leading, spacing: BP.px(8)) {
                            Text("Your shelf is waiting").font(BP.sans(19, .semibold)).foregroundStyle(BP.ink)
                            BPNote(text: "Open any eBook and choose Bookmark to add it to your shelf.")
                        }
                        Button("Back", action: onClose).buttonStyle(BPActionStyle())
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: BPTileView.posterWidth, maximum: BPTileView.posterWidth), spacing: BP.trackGap)],
                                  alignment: .leading, spacing: BP.px(18)) {
                            ForEach(store.shelf) { b in
                                Button { onOpen(b) } label: { EBookCardView(ebook: b, status: statuses[b.id]) }
                                    .buttonStyle(BPTileStyle())
                            }
                        }
                        .focusSection()
                    }
                }
                .padding(.horizontal, BP.gutter).padding(.vertical, BP.px(60))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .ignoresSafeArea()
        .onExitCommand(perform: onClose)
        .task {
            await store.refreshLists()
            statuses = await store.statuses(store.shelf.map(\.id))
        }
    }
}

/// ebook-sources-panel.tsx "Library sources", as far as a TV goes: Project Gutenberg's quick add
/// and the sources already connected. Folders, HTML sources and extensions need the desktop app.
@MainActor
struct EBookSourcesView: View {
    let onClose: () -> Void
    @ObservedObject private var store = EBookStore.shared
    @ObservedObject private var settings = SettingsBridge.shared
    @State private var nytDraft = ""
    /// (device-flow pass style) "Saved" flashes for a moment after a save, like AISearchPanel.
    @State private var nytFlash = false

    static let tvNote = "Apple TV reads Project Gutenberg's public-domain library. Local folders, site sources and extensions are available in Harbor on your computer."

    var body: some View {
        ZStack {
            BPAmbientBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: BP.px(22)) {
                    Text("eBook source settings").font(BP.display(34)).foregroundStyle(BP.ink)
                    BPNote(text: T("Harbor never hosts your books.") + " " + T(Self.tvNote)).frame(maxWidth: BP.px(760), alignment: .leading)
                    if let s = store.state, !s.sources.isEmpty {
                        VStack(alignment: .leading, spacing: BP.px(10)) {
                            Text("Your sources").font(BP.sans(19, .bold)).foregroundStyle(BP.ink).accessibilityAddTraits(.isHeader)
                            ForEach(s.sources) { src in
                                HStack(spacing: BP.px(12)) {
                                    Image(systemName: src.kind == "gutendex" ? "building.columns" : (src.kind == "local" ? "folder" : "globe"))
                                        .foregroundStyle(BP.inkMuted)
                                        .accessibilityHidden(true)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(src.name).font(BP.sans(16, .semibold)).foregroundStyle(BP.ink)
                                        if !src.readable {
                                            Text("Not readable on Apple TV").font(BP.sans(13)).foregroundStyle(BP.inkMuted)
                                        }
                                    }
                                    Spacer()
                                    Button("Remove") { Task { await store.removeSource(src.id) } }.buttonStyle(BPActionStyle())
                                }
                                .padding(BP.px(14))
                                .background(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).fill(BP.panel))
                                .focusSection()
                            }
                        }
                        .frame(maxWidth: BP.px(900), alignment: .leading)
                    }
                    VStack(alignment: .leading, spacing: BP.px(10)) {
                        Text("Bring your own").font(BP.sans(19, .bold)).foregroundStyle(BP.ink).accessibilityAddTraits(.isHeader)
                        // GutenbergQuickAdd.
                        let added = store.state?.hasGutendex == true
                        Button { if !added { Task { await store.addGutendex() } } } label: {
                            HStack(spacing: BP.px(14)) {
                                Image(systemName: "building.columns.fill").font(.system(size: BP.px(20))).foregroundStyle(BP.accent).accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(verbatim: "Project Gutenberg").font(BP.sans(16, .semibold)).foregroundStyle(BP.ink)
                                    Text(verbatim: "75,000 free public domain books, no account needed").font(BP.sans(13)).foregroundStyle(BP.inkMuted)
                                }
                                Spacer(minLength: BP.px(20))
                                Image(systemName: added ? "checkmark" : "plus").foregroundStyle(BP.inkMuted)
                                    .accessibilityLabel(Text(T("Added")))
                                    .accessibilityHidden(!added)
                            }
                            .padding(.horizontal, BP.px(18)).padding(.vertical, BP.px(14))
                            .frame(width: BP.px(640), alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: BP.rMD, style: .continuous).fill(BP.panel))
                        }
                        .buttonStyle(BPTileStyle(radius: BP.rMD))
                        // (device-flow pass) GutenbergQuickAdd disables itself once added; here it stays
                        // focusable (a disabled focused tile threw the ring off the page) and does nothing.
                    }
                    .focusSection()
                    nytKeyRow
                    Button("Done", action: onClose).buttonStyle(BPActionStyle())
                }
                .padding(.horizontal, BP.gutter).padding(.vertical, BP.px(60))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .ignoresSafeArea()
        .onExitCommand(perform: onClose)
        .task {
            await store.refresh()
            nytDraft = settings.slice.nytKey
        }
    }

    /// views/settings/library-panel/provider-keys.tsx's NYT KeyField, moved to the eBook room's
    /// own Sources page (the TV has no general "library keys" settings panel): the free NYT
    /// Books API key for the bestseller rail and hero (engine ebook.nytRail).
    private var nytKeyRow: some View {
        VStack(alignment: .leading, spacing: BP.px(10)) {
            Text(verbatim: "New York Times bestsellers").font(BP.sans(19, .bold)).foregroundStyle(BP.ink).accessibilityAddTraits(.isHeader)
            Text(T("Adds the New York Times bestseller lists to the eBook page, on the hero and as a row, with rank and weeks on the list. Free key at") + " developer.nytimes.com. " + T("Enable the Books API on your app. Lists refresh weekly."))
                .font(BP.sans(13)).foregroundStyle(BP.inkMuted).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: BP.px(760), alignment: .leading)
            BPField(label: "New York Times · bestseller lists", placeholder: "NYT Books API key", text: $nytDraft, secure: true, phone: true)
                .frame(width: BP.px(520))
            HStack(spacing: BP.px(10)) {
                let empty = nytDraft.trimmingCharacters(in: .whitespaces).isEmpty
                Button(T("Save")) {
                    guard !empty else { return }
                    Task {
                        try? await settings.patch(["nytKey": .string(nytDraft.trimmingCharacters(in: .whitespaces))])
                        nytFlash = true; DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { nytFlash = false }
                    }
                }
                .buttonStyle(BPActionStyle(primary: true, busy: empty))
                // UI tests (NavigationTests5): proves the NYT key row itself takes focus (a
                // SecureField has no `hasFocus` button match; this row's own Save does).
                .accessibilityIdentifier("ebook-nyt-save")
                if !settings.slice.nytKey.isEmpty {
                    Button(T("Remove")) {
                        Task {
                            try? await settings.patch(["nytKey": .string("")])
                            nytDraft = ""
                        }
                    }
                    .buttonStyle(BPActionStyle())
                    Text(T("Saved")).font(BP.sans(13, .semibold)).foregroundStyle(nytFlash ? BP.accent : BP.inkSubtle)
                }
            }
            // (CI fix 2026-09-27) Full width: Down from the key field's phone button found no overlap
            // with the Save row below (run 36310907311); a full-width section takes the move.
            .frame(maxWidth: .infinity, alignment: .leading)
            .focusSection()
        }
        .focusSection()
    }
}

/// views/ebook.tsx screen "collections" (lib/ebook/collections.ts): series, the installed
/// source's own catalog, and award-winner shelves built from books it already has. Data-only
/// (docs/ebook-spec.md §6): no AniList list tracking here, just what the source catalog gives.
@MainActor
struct EBookCollectionsView: View {
    let providerId: String
    let providerIds: [String]
    /// Whatever the room's Popular rail already loaded, so the page has something at once while
    /// it pages the source further (views/ebook.tsx's own loadCatalog effect).
    let seedItems: [EBook]
    let onOpen: (EBook) -> Void
    let onClose: () -> Void

    @State private var collections: [EBookCollection] = []
    @State private var loading = true

    private var series: [EBookCollection] { collections.filter { $0.kind == "series" } }
    private var catalog: [EBookCollection] { collections.filter { $0.kind == "catalog" } }
    private var awards: [EBookCollection] { collections.filter { $0.kind == "award" } }

    var body: some View {
        ZStack {
            BPAmbientBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: BP.px(28)) {
                    Text("Collections").font(BP.display(34)).foregroundStyle(BP.ink)
                    if !series.isEmpty { collectionSection("Book Series", series) }
                    if !catalog.isEmpty { collectionSection("From the Installed Source", catalog) }
                    if !awards.isEmpty { collectionSection("Award Winners", awards) }
                    if loading && collections.isEmpty {
                        HStack(spacing: BP.px(10)) {
                            ProgressView().tint(BP.inkMuted)
                            Text("Loading book collections…").font(BP.sans(14)).foregroundStyle(BP.inkMuted)
                        }
                    } else if collections.isEmpty {
                        BPNote(text: "No collections were found in the installed source catalog.")
                    }
                    // UI tests (NavigationTests5): Menu already closes this page (onExitCommand); Back
                    // does the same by remote select.
                    Button("Back", action: onClose).buttonStyle(BPActionStyle())
                        .accessibilityIdentifier("ebook-collections-back")
                }
                .padding(.horizontal, BP.gutter).padding(.vertical, BP.px(60))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .ignoresSafeArea()
        .onExitCommand(perform: onClose)
        .task { await load() }
    }

    private func collectionSection(_ title: String, _ items: [EBookCollection]) -> some View {
        VStack(alignment: .leading, spacing: BP.px(20)) {
            Text(T(title)).font(BP.display(24)).foregroundStyle(BP.ink)
            ForEach(items) { collection in
                VStack(alignment: .leading, spacing: BP.px(2)) {
                    BPRowView(row: BrowseRow(key: collection.id, title: T(collection.name), metas: collection.books.map(\.meta)),
                              onFocus: { _ in },
                              onSelect: { m in if let b = collection.books.first(where: { $0.id == m.id }) { onOpen(b) } })
                    Text(T(collection.subtitle)).font(BP.sans(12)).foregroundStyle(BP.inkSubtle).padding(.horizontal, BP.gutter)
                }
            }
        }
    }

    private func load() async {
        // views/ebook.tsx loadCatalog: up to 4 pages ahead of what the room's Popular rail has,
        // stopping once a page brings nothing new.
        var items = seedItems
        var cursor: [String: Double]?
        for _ in 0..<4 {
            struct Page: Decodable { var items: [EBook]; var fresh: Int; var cursor: [String: Double]; var hasMore: Bool }
            guard let page: Page = try? await HarborEngine.shared.call("ebook.page", [Optional<String>.none, providerId, cursor, Optional<String>.none, items]) else { break }
            items = page.items
            cursor = page.cursor
            if page.fresh == 0 || !page.hasMore { break }
        }
        let scope: String = (try? await HarborEngine.shared.call("ebook.collectionScope", [providerId, providerIds])) ?? ""
        struct Result: Decodable { var collections: [EBookCollection]; var token: Int? }
        guard let result: Result = try? await HarborEngine.shared.call("ebook.collections", [scope, providerId, items]) else {
            loading = false
            return
        }
        collections = result.collections
        loading = false
        if let token = result.token, let resolved: [EBookCollection] = try? await HarborEngine.shared.call("ebook.collectionsResolved", [token]) {
            collections = resolved
        }
    }
}
