import SwiftUI

/// "See all" for one row: a poster grid that pages through the engine (`rooms.page`).
struct CatalogPageView: View {
    let room: Room
    let row: BrowseRow
    @State private var metas: [Meta]
    @State private var page = 1
    @State private var exhausted = false
    @State private var loading = false
    /// use-bp-genre-grid status when a genre page has nothing to show.
    @State private var emptyNote: String?
    @State private var spotlight: Meta?
    @State private var detail: Meta?
    @FocusState private var focusedId: String?

    private static let columns = Array(repeating: GridItem(.fixed(BPTileView.posterWidth), spacing: BP.px(21), alignment: .top), count: 6)

    init(room: Room, row: BrowseRow) {
        self.room = room
        self.row = row
        _metas = State(initialValue: row.metas)
        _page = State(initialValue: row.metas.isEmpty ? 0 : 1)
    }

    var body: some View {
        ZStack(alignment: .top) {
            BPAmbientBackground()
            SpotlightView(meta: spotlight, boxHeight: BP.px(200) + BP.barHeight).opacity(spotlight == nil ? 0 : 1)
            ScrollView(.vertical, showsIndicators: false) {
                LazyVGrid(columns: Self.columns, alignment: .leading, spacing: BP.px(24)) {
                    ForEach(Array(metas.enumerated()), id: \.element.id) { i, meta in
                        Button { detail = meta } label: {
                            BPTileView(meta: meta, shape: .poster, focused: focusedId == meta.id)
                        }
                        .buttonStyle(BPTileStyle())
                        .focused($focusedId, equals: meta.id)
                        .onAppear { if i >= metas.count - 12 { Task { await loadMore() } } }
                    }
                }
                .padding(.horizontal, BP.gutter)
                .padding(.top, BP.px(200) + BP.barHeight)
                .padding(.bottom, BP.hintHeight + BP.px(40))
                if loading { ProgressView().tint(BP.inkMuted).padding() }
                if let emptyNote, metas.isEmpty, !loading {
                    VStack(alignment: .leading, spacing: BP.px(10)) {
                        BPNote(text: emptyNote)
                        Button("Try again") { exhausted = false; page = 0; Task { await loadMore() } }.buttonStyle(BPActionStyle(primary: true))
                    }
                    .padding(.horizontal, BP.gutter)
                }
            }
            VStack(alignment: .leading, spacing: BP.px(4)) {
                Text(row.title).font(BP.display(30)).foregroundStyle(BP.ink)
                Text("\(metas.count) titles").font(BP.sans(13)).foregroundStyle(BP.inkMuted)
            }
            .padding(.horizontal, BP.gutter).padding(.top, BP.barHeight + BP.px(20))
            .opacity(spotlight == nil ? 1 : 0)
        }
        .ignoresSafeArea()
        .onChange(of: focusedId) { _, id in spotlight = metas.first { $0.id == id } }
        .task { if metas.isEmpty { await loadMore() } }
        .fullScreenCover(item: $detail) { m in DetailView(meta: m) }
    }

    private func loadMore() async {
        guard !loading, !exhausted else { return }
        loading = true; defer { loading = false }
        let kind = room == .home ? "home" : (room == .movies ? "movies" : (room == .anime ? "anime" : "shows"))
        let next: [Meta]
        if row.key.hasPrefix("genre:") {
            // bp-genre-grid: TMDB discover pages for one genre shelf (use-bp-genre-grid).
            struct Page: Decodable { var metas: [Meta]; var status: String }
            let p = ProfilesStore.shared.active
            let genre = String(row.key.dropFirst("genre:".count))
            var got: Page = (try? await HarborEngine.shared.call("discoverRoom.genrePage", [p?.id ?? "default", p?.linked ?? true, genre, page + 1])) ?? Page(metas: [], status: "failed")
            // use-bp-genre-grid: a page the anime filter emptied is not the end; skip past it (bounded).
            var skipped = 0
            while got.status == "filtered", skipped < 3 {
                page += 1; skipped += 1
                got = (try? await HarborEngine.shared.call("discoverRoom.genrePage", [p?.id ?? "default", p?.linked ?? true, genre, page + 1])) ?? Page(metas: [], status: "failed")
            }
            next = got.metas
            if next.isEmpty, metas.isEmpty {
                switch got.status {
                case "no-key": emptyNote = "Genre shelves are built from TMDB. Add a key in Setup to fill this one."
                case "filtered": emptyNote = "Everything on this page of \(genre) is hidden by your anime filter."
                case "empty": emptyNote = "Nothing in \(genre) right now."
                default: emptyNote = "Couldn't reach TMDB for \(genre) titles."
                }
            }
        } else if row.key.hasPrefix("svc:") {
            // A streaming-service category row pages through TMDB (services.page).
            let p = ProfilesStore.shared.active
            next = (try? await HarborEngine.shared.call("services.page", [row.key, page + 1, p?.id ?? "default", p?.linked ?? true])) ?? []
        } else if room == .anime {
            next = (try? await HarborEngine.shared.call("animeRoom.specPage", [row.key, page + 1])) ?? []
        } else {
            next = (try? await HarborEngine.shared.call("rooms.page", [kind, row.key, page + 1])) ?? []
        }
        if next.isEmpty { exhausted = true; return }
        page += 1
        let known = Set(metas.map(\.id))
        metas += next.filter { !known.contains($0.id) }
        await CardMarksStore.shared.refresh(metas)
    }
}
