import SwiftUI

/// "See all" for one row: a poster grid that pages through the engine (`rooms.page`).
struct CatalogPageView: View {
    let room: Room
    let row: BrowseRow
    @State private var metas: [Meta]
    @State private var page = 1
    @State private var exhausted = false
    @State private var loading = false
    /// (review 33) The last page read failed (not an empty page): paging stops there and a Try again
    /// at the end of the grid runs it again. A failed read used to mark the page exhausted, so
    /// scrolling on stopped silently for good.
    @State private var pageFailed = false
    /// use-bp-genre-grid status when a genre page has nothing to show.
    @State private var emptyNote: String?
    @State private var spotlight: Meta?
    @State private var detail: Meta?
    @FocusState private var focusedId: String?

    /// (layout pass) Six fixed 298 pt columns and five 35 pt gaps are 1 963 pt, wider than the
    /// 1 632 pt between the gutters (wider than the screen, even): the grid ran off both edges.
    /// Five fit (1 630 pt), as bp-grid's auto-fill columns always fit the page.
    private static let columns = Array(repeating: GridItem(.fixed(BPTileView.posterWidth), spacing: BP.px(21), alignment: .top), count: 5)
    /// The hero box the grid scrolls under (bp-catalog-page: the hero, z-20, then the rail below it).
    private static var heroBox: CGFloat { BP.px(200) + BP.barHeight }
    /// bp-grid HEADROOM pt-[14px]: room above the viewport for the focused tile's lift and ring.
    private static var headroom: CGFloat { BP.px(14) }

    init(room: Room, row: BrowseRow) {
        self.room = room
        self.row = row
        _metas = State(initialValue: row.metas.uniquedById())   // (bug pass) unique grid ids
        _page = State(initialValue: row.metas.isEmpty ? 0 : 1)
    }

    var body: some View {
        ZStack(alignment: .top) {
            BPAmbientBackground()
            SpotlightView(meta: spotlight, boxHeight: Self.heroBox).opacity(spotlight == nil ? 0 : 1)
            // (layout pass) The grid used to scroll the whole screen with the hero copy drawn under
            // it: once focus moved down a row, the rows above it covered the focused title's name,
            // chips and overview. As bp-catalog-page, the scroller now starts under the hero box, so
            // focus scrolling keeps the focused row below the copy; the clip is lifted and replaced
            // by a mask `headroom` above the viewport, so the ring of a row scrolled flush with the
            // top still shows while nothing reaches the copy.
            ScrollView(.vertical, showsIndicators: false) {
                LazyVGrid(columns: Self.columns, alignment: .leading, spacing: BP.px(24)) {
                    ForEach(Array(metas.enumerated()), id: \.element.id) { i, meta in
                        Button { detail = meta } label: {
                            BPTileView(meta: meta, shape: .poster, focused: focusedId == meta.id)
                        }
                        .buttonStyle(BPTileStyle())
                        .focused($focusedId, equals: meta.id)
                        .zIndex(focusedId == meta.id ? 1 : 0)
                        .onAppear { if i >= metas.count - 12, !pageFailed { Task { await loadMore() } } }
                    }
                }
                .padding(.horizontal, BP.gutter)
                .padding(.top, Self.headroom)
                .padding(.bottom, BP.hintHeight + BP.px(40))
                if loading && emptyNote == nil && !pageFailed { ProgressView().tint(BP.inkMuted).padding() }
                if pageFailed && !(emptyNote != nil && metas.isEmpty) {
                    // (review 33) A page that failed to load: Try again reads it again (busy while it
                    // runs, so the ring stays), and on success the ring goes to its first new title.
                    Button("Try again") {
                        guard !loading else { return }
                        let before: Int = metas.count
                        Task {
                            await loadMore(retry: true)
                            if metas.count > before {
                                let id: String = metas[before].id
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { focusedId = id }
                            }
                        }
                    }
                    .buttonStyle(BPActionStyle(primary: true, busy: loading))
                    .padding(.horizontal, BP.gutter)
                }
                if let emptyNote, metas.isEmpty {
                    // (device-flow pass 10) The note and Try again stay up (dimmed) while the retry
                    // runs: they went away under the ring, which had nothing to land on in this page,
                    // and a retry that failed again brought them back with no ring on them.
                    VStack(alignment: .leading, spacing: BP.px(10)) {
                        BPNote(text: emptyNote)
                        Button("Try again") {
                            guard !loading else { return }
                            exhausted = false; page = 0
                            Task {
                                await loadMore(retry: true)
                                // A retry that worked takes Try again away: the ring goes to the first title.
                                if let first = metas.first {
                                    let id: String = first.id
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { focusedId = id }
                                }
                            }
                        }
                        .buttonStyle(BPActionStyle(primary: true, busy: loading))
                    }
                    .padding(.horizontal, BP.gutter)
                }
            }
            .scrollClipDisabled()
            .padding(.top, Self.heroBox)
            .mask(
                VStack(spacing: 0) {
                    Color.clear.frame(height: Self.heroBox - Self.headroom)
                    Color.black
                }
            )
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

    /// `retry`: a Try again press; a page that failed is not read again on scroll alone.
    private func loadMore(retry: Bool = false) async {
        guard !loading, !exhausted, retry || !pageFailed else { return }
        loading = true; defer { loading = false }
        let kind = room == .home ? "home" : (room == .movies ? "movies" : (room == .anime ? "anime" : "shows"))
        // nil: the read failed (the engine threw, or the genre page answered "failed").
        let next: [Meta]?
        if row.key.hasPrefix("genre:") {
            // bp-genre-grid: TMDB discover pages for one genre shelf (use-bp-genre-grid).
            struct Page: Decodable { @LossyArray var metas: [Meta]; var status: String }   // (bug pass 2) lossy
            let p = ProfilesStore.shared.active
            let genre = String(row.key.dropFirst("genre:".count))
            var got: Page = (try? await HarborEngine.shared.call("discoverRoom.genrePage", [p?.id ?? "default", p?.linked ?? true, genre, page + 1])) ?? Page(metas: [], status: "failed")
            // use-bp-genre-grid: a page the anime filter emptied is not the end; skip past it (bounded).
            var skipped = 0
            while got.status == "filtered", skipped < 3 {
                page += 1; skipped += 1
                got = (try? await HarborEngine.shared.call("discoverRoom.genrePage", [p?.id ?? "default", p?.linked ?? true, genre, page + 1])) ?? Page(metas: [], status: "failed")
            }
            next = got.status == "failed" ? nil : got.metas
            if got.metas.isEmpty, metas.isEmpty {
                switch got.status {
                case "no-key": emptyNote = "Genre shelves are built from TMDB. Add a key in Setup to fill this one."
                // bp-genre-grid.tsx: format keys with the genre through t().
                case "filtered": emptyNote = T("Everything on this page of %@ is hidden by your anime filter.", T(genre))
                case "empty": emptyNote = T("Nothing in %@ right now.", T(genre))
                default: emptyNote = T("Couldn't reach TMDB for %@ titles.", T(genre))
                }
            }
        } else if row.key.hasPrefix("svc:") {
            // A streaming-service category row pages through TMDB (services.page).
            let p = ProfilesStore.shared.active
            next = try? await HarborEngine.shared.call("services.page", [row.key, page + 1, p?.id ?? "default", p?.linked ?? true])
        } else if room == .anime {
            next = try? await HarborEngine.shared.call("animeRoom.specPage", [row.key, page + 1])
        } else {
            next = try? await HarborEngine.shared.call("rooms.page", [kind, row.key, page + 1])
        }
        guard let next else { pageFailed = true; return }
        pageFailed = false
        if next.isEmpty { exhausted = true; return }
        emptyNote = nil
        page += 1
        // (bug pass) Also drops repeats inside the new page itself (duplicate ForEach ids).
        metas = (metas + next).uniquedById()
        await CardMarksStore.shared.refresh(metas)
    }
}
