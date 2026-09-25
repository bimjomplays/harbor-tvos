import SwiftUI

extension MangaSummary {
    /// A manga as a poster tile (BPTileView reads id, name and poster).
    var meta: Meta {
        Meta(id: id, type: "manga", name: title, poster: cover, background: cover, description: description,
             releaseInfo: year.map { String(Int($0)) })
    }
}

/// The Manga room's feeds (views/manga.tsx + manga-browse.tsx): the popular feed behind the hero
/// and its rail, the source tags, and the browse grid (a query and/or a source, paged).
@MainActor
final class MangaRoomModel: ObservableObject {
    struct Tag: Decodable, Identifiable, Hashable { var id: String; var name: String; var group: String? }

    @Published private(set) var popular: [MangaSummary] = []
    @Published private(set) var popularFailed = false
    @Published private(set) var tags: [Tag] = []
    @Published var tagId = "" { didSet { if tagId != oldValue { reloadBrowse() } } }
    @Published var query = "" { didSet { if query != oldValue { scheduleBrowse() } } }
    @Published private(set) var items: [MangaSummary] = []
    @Published private(set) var browseStatus: Status = .loading
    @Published private(set) var loadingMore = false
    @Published private(set) var hasMore = false
    enum Status: Equatable { case loading, ready, error }

    private var offset = 0
    private var seen: Set<String> = []
    private var req = 0
    private var debounce: Task<Void, Never>?

    /// views/manga.tsx featured: the first six popular titles that have a cover.
    var featured: [MangaSummary] { Array(popular.filter { $0.cover != nil }.prefix(6)) }

    /// (bug pass 3) views/manga.tsx drops a featured answer once the source changed (`cancelled`).
    /// A slow merged popular feed from the server switched away from could land after the new
    /// server's and replace its hero, rail and source chips.
    private var loadGeneration = 0

    func load() async {
        loadGeneration += 1
        let generation = loadGeneration
        popularFailed = false
        let fetched: [MangaSummary]? = try? await HarborEngine.shared.call("manga.popular", [0, Optional<String>.none])
        guard generation == loadGeneration else { return }
        popular = fetched ?? []
        popularFailed = fetched == nil
        let fetchedTags: [Tag] = (try? await HarborEngine.shared.call("manga.tags")) ?? []
        guard generation == loadGeneration else { return }
        tags = fetchedTags
        reloadBrowse()
    }

    private func scheduleBrowse() {
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            self?.reloadBrowse()
        }
    }

    /// manga-browse fetchPage: a query with no source picked asks every extension (one page);
    /// otherwise the source (or the merged popular feed) pages by offset.
    func reloadBrowse() {
        req += 1
        let id = req
        offset = 0
        seen = []
        items = []
        hasMore = false
        browseStatus = .loading
        Task { await fetch(id) }
    }

    func loadMore() {
        guard hasMore, !loadingMore else { return }
        loadingMore = true
        let id = req
        Task { await fetch(id); loadingMore = false }
    }

    private func fetch(_ id: Int) async {
        let q = query.trimmingCharacters(in: .whitespaces)
        let tag: String? = tagId.isEmpty ? nil : tagId
        do {
            let page: [MangaSummary]
            if !q.isEmpty && tag == nil {
                page = try await HarborEngine.shared.call("manga.searchEverywhere", [q])
            } else {
                page = try await HarborEngine.shared.call("manga.search", [q, offset, tag])
            }
            guard id == req else { return }
            let fresh = page.filter { seen.insert($0.id).inserted }
            items += fresh
            offset += page.count
            // Paged sources keep going while they answer; the merged feed and the everywhere
            // search are one page each (the provider returns nothing past offset 0).
            hasMore = !page.isEmpty && tag != nil
            browseStatus = .ready
        } catch {
            guard id == req else { return }
            if items.isEmpty { browseStatus = .error }
            hasMore = false
        }
    }
}

/// The Manga room (views/manga.tsx), for the remote: the enable gate, the "add a source" screen,
/// then the home: hero, Continue Reading, Popular Manga, your favourites and the browse grid.
@MainActor
struct MangaView: View {
    @EnvironmentObject private var settings: SettingsBridge
    @ObservedObject private var store = MangaStore.shared
    @StateObject private var model = MangaRoomModel()
    @State private var open: MangaOpen?
    @State private var reader: MangaReaderLaunch?
    @State private var sourcesOpen = false
    @State private var spotlight: MangaSummary?
    @State private var loadedFor: String?
    @State private var opening: String?

    private var enabled: Bool { settings.slice.mangaEnabled ?? false }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if !enabled {
                enableGate
            } else if store.state == nil {
                ProgressView().tint(BP.inkMuted).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if store.state?.hasSource != true {
                noSource
            } else {
                home
            }
        }
        .task(id: enabled) {
            guard enabled else { return }
            await store.refresh()
            await reloadIfNeeded()
        }
        .onChange(of: store.state?.activeId) { _, _ in Task { await reloadIfNeeded() } }
        .fullScreenCover(item: $open, onDismiss: { Task { await store.refreshLists() } }) { o in MangaDetailView(mangaId: o.id) }
        .fullScreenCover(item: $reader, onDismiss: { Task { await store.refreshLists() } }) { l in
            MangaReaderView(launch: l) { reader = nil }
        }
        .fullScreenCover(isPresented: $sourcesOpen, onDismiss: { Task { await store.refresh(); await reloadIfNeeded() } }) {
            MangaSourcesView { sourcesOpen = false }
        }
    }

    /// Feeds are fetched again when the active source changes (views/manga.tsx sourceTick).
    private func reloadIfNeeded() async {
        guard let s = store.state, s.hasSource else { return }
        let key = s.activeId + "|" + s.sources.map(\.id).joined(separator: ",")
        guard loadedFor != key else { return }
        loadedFor = key
        spotlight = nil
        await model.load()
    }

    // MARK: gates

    /// views/manga.tsx EnableGate.
    private var enableGate: some View {
        VStack(alignment: .leading, spacing: BP.px(16)) {
            Image(systemName: "book").font(.system(size: BP.px(30), weight: .semibold)).foregroundStyle(BP.ink)
            Text("Read manga in Harbor").font(BP.display(36)).foregroundStyle(BP.ink)
            BPNote(text: "Harbor does not host any manga. Add a source plugin from a repository you trust, connect your own server, or open a local folder. You can turn this off anytime in Settings.")
                .frame(maxWidth: BP.px(620), alignment: .leading)
            Button("Enable manga sources") { Task { try? await settings.patch(["mangaEnabled": .bool(true)]) } }
                .buttonStyle(BPActionStyle(primary: true))
        }
        .padding(.horizontal, BP.gutter).padding(.top, BP.barHeight + BP.px(80))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .focusSection()
    }

    /// views/manga.tsx "Add a manga source". Apple TV reads Suwayomi servers only.
    private var noSource: some View {
        VStack(alignment: .leading, spacing: BP.px(16)) {
            Text("Add a manga source").font(BP.display(36)).foregroundStyle(BP.ink)
            BPNote(text: "Harbor does not host any manga or any sources. Connect your own server or open a folder you already have, and mix as many as you like.")
                .frame(maxWidth: BP.px(620), alignment: .leading)
            BPNote(text: MangaSourcesView.tvNote, tone: BP.inkSubtle).frame(maxWidth: BP.px(620), alignment: .leading)
            Button("Set up a source") { sourcesOpen = true }
                .buttonStyle(BPActionStyle(primary: true))
        }
        .padding(.horizontal, BP.gutter).padding(.top, BP.barHeight + BP.px(80))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .focusSection()
    }

    // MARK: home

    private var hero: MangaSummary? { spotlight ?? model.featured.first }

    private var home: some View {
        ZStack(alignment: .top) {
            heroBackdrop
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: BP.rowGap) {
                    heroCopy.frame(height: BP.px(300), alignment: .bottomLeading)
                    sourceBar
                    if !store.progress.isEmpty { continueRow }
                    if !model.popular.isEmpty {
                        BPRowView(row: BrowseRow(key: "manga-popular", title: T("Popular Manga"), metas: model.popular.map(\.meta)),
                                  onFocus: { m in spotlight = model.popular.first { $0.id == m.id } },
                                  onSelect: { open = MangaOpen(id: $0.id) })
                    } else if model.popularFailed {
                        BPNote(text: "Could not load results").padding(.horizontal, BP.gutter)
                    }
                    if !store.favorites.isEmpty {
                        BPRowView(row: BrowseRow(key: "manga-favorites", title: T("Library"),
                                                 metas: store.favorites.map { Meta(id: $0.id, type: "manga", name: $0.title, poster: $0.cover) }),
                                  onFocus: { _ in }, onSelect: { open = MangaOpen(id: $0.id) })
                    }
                    browseSection
                    Color.clear.frame(height: BP.hintHeight + BP.px(40))
                }
            }
        }
    }

    private var heroBackdrop: some View {
        ZStack {
            BP.void_
            // (perf pass 2) Follows focus once it settles, pre-blurred once per cover.
            BPBlurredHeroBackdrop(url: hero?.cover)
            LinearGradient(colors: [BP.void_.opacity(0.2), BP.void_.opacity(0.8), BP.void_], startPoint: .top, endPoint: .init(x: 0.5, y: 0.55))
        }
        .ignoresSafeArea()
    }

    /// manga-hero: the focused (or first featured) title's cover, name and synopsis.
    private var heroCopy: some View {
        HStack(alignment: .bottom, spacing: BP.px(20)) {
            if let h = hero {
                RemoteImage(url: h.cover)
                    .frame(width: BP.px(110), height: BP.px(165))
                    .clipShape(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous))
                VStack(alignment: .leading, spacing: BP.px(6)) {
                    Text("Manga").font(BP.sans(11, .bold)).textCase(.uppercase).tracking(1.4).foregroundStyle(BP.accent)
                    Text(h.title).font(BP.display(34)).foregroundStyle(BP.ink).lineLimit(2)
                    if let a = h.author, !a.isEmpty { Text(a).font(BP.sans(13, .medium)).foregroundStyle(BP.inkMuted) }
                    if let d = h.description, !d.isEmpty {
                        Text(d).font(BP.sans(13)).foregroundStyle(BP.inkMuted).lineLimit(3).frame(maxWidth: BP.px(620), alignment: .leading)
                    }
                }
            } else {
                Text("Manga").font(BP.display(36)).foregroundStyle(BP.ink)
            }
            Spacer()
        }
        .padding(.horizontal, BP.gutter)
        .animation(BP.easeFast, value: hero?.id)
    }

    /// Source picker (manga-browse SourceDropdown) and Manage sources.
    private var sourceBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: BP.px(8)) {
                if let s = store.state, s.sources.count > 1 {
                    ForEach(s.sources) { src in
                        Button(src.name) { Task { await store.setActive(src.id) } }
                            .buttonStyle(BPActionStyle(primary: s.activeId == src.id)).bpSelected(s.activeId == src.id)
                    }
                }
                Button { sourcesOpen = true } label: { Label("Sources", systemImage: "server.rack") }
                    .buttonStyle(BPActionStyle())
            }
            .padding(.horizontal, BP.gutter).padding(.vertical, BP.px(6))
        }
        .scrollClipDisabled()
        .focusSection()
    }

    /// manga-continue.tsx: one card per title, the chapter and page, a progress line. Select
    /// resumes in the reader; holding Select offers Remove.
    private var continueRow: some View {
        VStack(alignment: .leading, spacing: BP.px(10)) {
            Text("Continue Reading").font(BP.sans(19, .bold)).foregroundStyle(BP.ink).padding(.horizontal, BP.gutter).accessibilityAddTraits(.isHeader)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: BP.trackGap) {
                    ForEach(store.progress) { e in
                        Button { resume(e) } label: { continueCard(e) }
                            .buttonStyle(BPTileStyle())
                            .contextMenu {
                                Button("Remove from continue reading", role: .destructive) { Task { await store.removeProgress(e.id) } }
                            }
                    }
                }
                .padding(.horizontal, BP.gutter).padding(.vertical, BP.px(14))
            }
            .scrollClipDisabled()
        }
        .focusSection()
    }

    private func continueCard(_ e: MangaProgressEntry) -> some View {
        VStack(alignment: .leading, spacing: BP.px(6)) {
            ZStack(alignment: .bottomLeading) {
                RemoteImage(url: e.cover)
                if opening == e.id {
                    BP.void_.opacity(0.6)
                    ProgressView().tint(BP.ink).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if e.fraction > 0 {
                    GeometryReader { g in
                        Capsule().fill(BP.accent).frame(width: g.size.width * e.fraction, height: BP.px(3))
                    }
                    .frame(height: BP.px(3))
                }
            }
            .frame(width: BPTileView.posterSize.width, height: BPTileView.posterSize.height)
            .clipShape(RoundedRectangle(cornerRadius: BP.rXS, style: .continuous))
            Text(e.title).font(BP.sans(11.5, .semibold)).foregroundStyle(BP.ink).lineLimit(1)
            Text(e.cardLine).font(BP.sans(10.5)).foregroundStyle(BP.inkMuted).lineLimit(1)
        }
        .frame(width: BPTileView.posterWidth, alignment: .leading)
    }

    private func resume(_ e: MangaProgressEntry) {
        guard opening == nil else { return }
        opening = e.id
        Task {
            let launch = await store.resume(e)
            opening = nil
            if let launch { reader = launch } else { open = MangaOpen(id: e.id) }
        }
    }

    // MARK: browse (manga-browse.tsx)

    @FocusState private var gridFocus: String?

    private var browseSection: some View {
        VStack(alignment: .leading, spacing: BP.px(14)) {
            Text("Browse manga").font(BP.sans(22, .bold)).foregroundStyle(BP.ink)
            HStack(alignment: .bottom, spacing: BP.px(12)) {
                BPField(label: "Search", placeholder: "Search manga...", text: $model.query, phone: true)
                    .frame(width: BP.px(420))
                if !model.query.isEmpty {
                    Button("Clear") { model.query = "" }.buttonStyle(BPActionStyle())
                }
            }
            .focusSection()
            if !model.tags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: BP.px(8)) {
                        Button("All sources") { model.tagId = "" }.buttonStyle(BPActionStyle(primary: model.tagId.isEmpty))
                        ForEach(model.tags) { t in
                            Button(t.name) { model.tagId = t.id }.buttonStyle(BPActionStyle(primary: model.tagId == t.id)).bpSelected(model.tagId == t.id)
                        }
                    }
                    .padding(.vertical, BP.px(6))
                }
                .scrollClipDisabled()
                .focusSection()
            }
            switch model.browseStatus {
            case .loading:
                ProgressView().tint(BP.inkMuted).padding(.vertical, BP.px(30))
            case .error:
                BPNote(text: "Could not load results")
                Button("Try again") { model.reloadBrowse() }.buttonStyle(BPActionStyle())
            case .ready where model.items.isEmpty:
                BPNote(text: model.query.isEmpty ? "Nothing to show here yet." : T("Nothing found for \"%@\"", model.query))
            case .ready:
                LazyVGrid(columns: [GridItem(.adaptive(minimum: BPTileView.posterWidth, maximum: BPTileView.posterWidth), spacing: BP.trackGap)],
                          alignment: .leading, spacing: BP.px(18)) {
                    ForEach(model.items) { m in
                        Button { open = MangaOpen(id: m.id) } label: {
                            BPTileView(meta: m.meta, shape: .poster, focused: gridFocus == m.id)
                        }
                        .buttonStyle(BPTileStyle())
                        .focused($gridFocus, equals: m.id)
                        .onAppear { if m.id == model.items.last?.id { model.loadMore() } }
                    }
                }
                .focusSection()
                if model.loadingMore { ProgressView().tint(BP.inkMuted) }
            }
        }
        .padding(.horizontal, BP.gutter)
        .onChange(of: gridFocus) { _, id in
            if let id, let m = model.items.first(where: { $0.id == id }) { spotlight = m }
        }
    }
}

/// manga-sources-panel suwayomi/servers-section + server-form: the Suwayomi servers this TV reads
/// from, which one is active, and a form to add one (address, optional username and password).
@MainActor
struct MangaSourcesView: View {
    let onClose: () -> Void
    @ObservedObject private var store = MangaStore.shared
    @State private var name = ""
    @State private var address = ""
    @State private var username = ""
    @State private var password = ""
    @State private var note: (text: String, ok: Bool)?
    @State private var busy = false

    static let tvNote = "Apple TV reads from Suwayomi servers. Source plugins and local folders are added in Harbor on your computer."

    var body: some View {
        ZStack {
            BPAmbientBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: BP.px(22)) {
                    Text("Manga sources").font(BP.display(34)).foregroundStyle(BP.ink)
                    BPNote(text: T("Harbor does not host any manga or any sources. Connect your own server or open a folder you already have, and mix as many as you like.") + " " + T(Self.tvNote))
                        .frame(maxWidth: BP.px(760), alignment: .leading)
                    if let s = store.state, !s.servers.isEmpty { serverList(s) }
                    form
                    Button("Done", action: onClose).buttonStyle(BPActionStyle())
                }
                .padding(.horizontal, BP.gutter).padding(.vertical, BP.px(60))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .ignoresSafeArea()
        .onExitCommand(perform: onClose)
        .task { await store.refresh() }
    }

    private func serverList(_ s: MangaState) -> some View {
        VStack(alignment: .leading, spacing: BP.px(10)) {
            Text("Servers").font(BP.sans(19, .bold)).foregroundStyle(BP.ink).accessibilityAddTraits(.isHeader)
            ForEach(s.servers) { server in
                // The source a server feeds carries its host (credentials never reach the UI).
                let source = s.sources.first { $0.kind == "suwayomi" && $0.host == server.host }
                HStack(spacing: BP.px(12)) {
                    Image(systemName: server.hasAuth ? "lock.fill" : "server.rack").foregroundStyle(BP.inkMuted)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(server.name).font(BP.sans(16, .semibold)).foregroundStyle(BP.ink)
                        Text(server.host).font(BP.sans(13)).foregroundStyle(BP.inkMuted)
                    }
                    Spacer()
                    if let source {
                        if s.activeId == source.id {
                            Text("Active").font(BP.sans(13, .semibold)).foregroundStyle(BP.live)
                        } else {
                            Button("Use this server") { Task { await store.setActive(source.id) } }.buttonStyle(BPActionStyle())
                        }
                    }
                    Button("Remove") { Task { await store.removeServer(server.id) } }.buttonStyle(BPActionStyle())
                }
                .padding(BP.px(14))
                .background(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).fill(BP.panel))
                .focusSection()
            }
            if s.sources.contains(where: { $0.id == "all" }) {
                Button("All servers") { Task { await store.setActive("all") } }
                    .buttonStyle(BPActionStyle(primary: s.activeId == "all")).bpSelected(s.activeId == "all")
            }
        }
        .frame(maxWidth: BP.px(900), alignment: .leading)
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: BP.px(12)) {
            Text("Connect a Suwayomi server").font(BP.sans(19, .bold)).foregroundStyle(BP.ink).accessibilityAddTraits(.isHeader)
            BPField(label: "Server address", placeholder: "http://192.168.1.20:4567", text: $address, keyboard: .URL)
            BPField(label: "Name (optional)", placeholder: "My Server", text: $name)
            HStack(spacing: BP.px(12)) {
                BPField(label: "Username", placeholder: "", text: $username)
                BPField(label: "Password", placeholder: "", text: $password, secure: true)
            }
            HStack(spacing: BP.px(10)) {
                Button(busy ? "Checking…" : "Test connection") { Task { await test() } }
                    .buttonStyle(BPActionStyle(busy: busy)).disabled(address.isEmpty)
                Button("Add server") { Task { await add() } }
                    .buttonStyle(BPActionStyle(primary: true, busy: busy)).disabled(address.isEmpty)
            }
            if let note { BPNote(text: note.text, tone: note.ok ? BP.live : BP.danger) }
        }
        .frame(maxWidth: BP.px(900), alignment: .leading)
        .focusSection()
    }

    private func test() async {
        guard !busy else { return }
        busy = true
        let r = await store.testServer(url: address.trimmingCharacters(in: .whitespaces), username: username, password: password)
        busy = false
        if r.ok {
            note = (text: T("Connected") + " · " + (r.sources == 1 ? T("%lld source", r.sources) : T("%lld sources", r.sources)), ok: true)
        } else {
            note = (text: "Could not reach this server", ok: false)
        }
    }

    private func add() async {
        guard !busy else { return }
        busy = true
        let err = await store.addServer(name: name, url: address.trimmingCharacters(in: .whitespaces), username: username, password: password)
        busy = false
        if let err {
            note = (text: err, ok: false)
        } else {
            note = (text: "Server added.", ok: true)
            name = ""; address = ""; username = ""; password = ""
        }
    }
}
