import SwiftUI

/// addons/bp-addon.tsx: one installed addon's catalogs as chips over a poster grid that pages
/// through the engine (addonsRoom.catalogs / addonsRoom.feed).
struct AddonPageView: View {
    let base: String
    let name: String
    let logo: String?
    @Environment(\.dismiss) private var dismiss
    @State private var catalogs: [Catalog] = []
    @State private var active: Catalog?
    @State private var metas: [Meta] = []
    @State private var page = 1
    @State private var loading = false
    @State private var done = false
    @State private var loadedCatalogs = false
    @State private var detail: Meta?
    @State private var spotlight: Meta?
    @FocusState private var focusedId: String?
    struct Catalog: Decodable, Identifiable { var key: String; var name: String; var type: String; var cursor: AnyJSON; var id: String { key } }

    /// (layout pass) Six fixed 298 pt columns (1 963 pt with the gaps) overran the 1 632 pt page;
    /// five fit (1 630 pt), like bp-addon's auto-fill grid.
    private static let columns = Array(repeating: GridItem(.fixed(BPTileView.posterWidth), spacing: BP.px(21), alignment: .top), count: 5)
    /// The hero box over the scroller (bp-addon: header first, the grid scroller below it).
    private static var heroBox: CGFloat { BP.px(200) + BP.barHeight }
    /// bp-grid HEADROOM pt-[14px]: room above the viewport for the focused tile's lift and ring.
    private static var headroom: CGFloat { BP.px(14) }

    var body: some View {
        ZStack(alignment: .top) {
            BPAmbientBackground()
            SpotlightView(meta: spotlight, boxHeight: Self.heroBox).opacity(spotlight == nil ? 0 : 1)
            // (layout pass) Rows scrolling up covered the hero copy drawn under them (the focused
            // title's name and overview). The scroller now starts under the hero box, as
            // CatalogPageView's; a mask keeps `headroom` above it for the focused ring.
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: BP.px(16)) {
                    if !catalogs.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: BP.px(8)) {
                                ForEach(catalogs) { c in
                                    Button("\(c.name) · \(c.type)") {
                                        // (sports/addons pass 2) bp-addon setPickedKey: the chip already
                                        // shown does nothing. Pressed again mid-scroll, it restarted at page
                                        // 1 while the next page was loading, which then landed as the first.
                                        guard active?.key != c.key else { return }
                                        Task { await open(c) }
                                    }
                                    .buttonStyle(BPActionStyle(primary: active?.key == c.key)).bpSelected(active?.key == c.key)
                                }
                            }
                            .padding(.horizontal, BP.gutter).padding(.vertical, BP.px(6))
                        }
                        .scrollClipDisabled()
                        .focusSection()
                    }
                    LazyVGrid(columns: Self.columns, alignment: .leading, spacing: BP.px(24)) {
                        ForEach(Array(metas.enumerated()), id: \.element.id) { i, meta in
                            Button { detail = meta } label: { BPTileView(meta: meta, shape: .poster, focused: focusedId == meta.id) }
                                .buttonStyle(BPTileStyle())
                                .focused($focusedId, equals: meta.id)
                                .zIndex(focusedId == meta.id ? 1 : 0)
                                .onAppear { if i >= metas.count - 12 { Task { await loadMore() } } }
                        }
                    }
                    .padding(.horizontal, BP.gutter)
                    if loading { ProgressView().tint(BP.inkMuted).padding(.horizontal, BP.gutter) }
                    if loadedCatalogs, !loading, metas.isEmpty {
                        BPNote(text: catalogs.isEmpty
                               ? "This addon provides streams only. It has no catalog to browse, but it still works behind every title you open."
                               : "This catalog came back empty. Try another one, or check the addon in Settings.")
                            .padding(.horizontal, BP.gutter)
                        // (addons pass) bp-addon.tsx: a stream-only addon has no chips and no grid,
                        // and a page with nothing to focus is a dead end; its Back is the one control.
                        if catalogs.isEmpty {
                            Button(T("Back")) { BPSound.shared.click(); dismiss() }
                                .buttonStyle(BPActionStyle())
                                .padding(.horizontal, BP.gutter)
                        }
                    }
                    Color.clear.frame(height: BP.hintHeight + BP.px(40))
                }
                .padding(.top, Self.headroom)
            }
            .scrollClipDisabled()
            .padding(.top, Self.heroBox)
            .mask(
                VStack(spacing: 0) {
                    Color.clear.frame(height: Self.heroBox - Self.headroom)
                    Color.black
                }
            )
            HStack(spacing: BP.px(14)) {
                if let logo, !logo.isEmpty { RemoteImage(url: logo, contentMode: .fit).frame(width: BP.px(48), height: BP.px(48)).clipShape(RoundedRectangle(cornerRadius: BP.px(10))) }
                VStack(alignment: .leading, spacing: BP.px(4)) {
                    Text(name).font(BP.display(30)).foregroundStyle(BP.ink)
                    Text(loading && metas.isEmpty ? "Loading…" : metas.isEmpty ? "" : "\(metas.count) results").font(BP.sans(13)).foregroundStyle(BP.inkMuted)
                }
            }
            .padding(.horizontal, BP.gutter).padding(.top, BP.barHeight + BP.px(20))
            .opacity(spotlight == nil ? 1 : 0)
        }
        .ignoresSafeArea()
        .onExitCommand { dismiss() }
        .onChange(of: focusedId) { _, id in spotlight = metas.first { $0.id == id } }
        .fullScreenCover(item: $detail) { m in DetailView(meta: m) }
        .task {
            // (bug pass) `.task` runs again when a title's cover closes: it re-opened the first
            // catalog then, dropping the viewer's chip and scroll position.
            guard !loadedCatalogs else { return }
            catalogs = (try? await HarborEngine.shared.call("addonsRoom.catalogs", [base])) ?? []
            loadedCatalogs = true
            if let first = catalogs.first { await open(first) }
        }
    }

    private func open(_ c: Catalog) async {
        active = c; metas = []; page = 1; done = false
        await loadMore()
    }

    private func loadMore() async {
        guard let c = active, !loading, !done else { return }
        loading = true; defer { loading = false }
        let nextLossy: LossyArray<Meta>? = try? await HarborEngine.shared.call("addonsRoom.feed", [c.cursor, page, metas.count])   // (bug pass 2) lossy
        let next = nextLossy?.wrappedValue ?? []
        // (bug pass) A catalog chip pressed while this page loaded: its own first load bounced off
        // `loading`, so it runs now instead of leaving the grid on "This catalog came back empty".
        guard active?.key == c.key else { loading = false; await loadMore(); return }
        if next.isEmpty { done = true; return }
        page += 1
        // (bug pass) Also drops repeats inside the new page itself (duplicate ForEach ids).
        metas = (metas + next).uniquedById()
        await CardMarksStore.shared.refresh(metas)
    }
}

/// bp-anime-hero-actions + bp-anime-hero-meta: Resume / Start Watching, More Info, and the meta
/// line (award pill or "New", MAL score, Sub and Dub, country) for the anime room's hero.
struct AnimeHeroActionsView: View {
    let meta: Meta
    let resume: ContinueItem?
    let onPlay: (Meta) -> Void
    let onInfo: (Meta) -> Void
    /// The actions gained (true) or lost (false) focus (the rail parks back at rest for them).
    var onHold: ((Bool) -> Void)? = nil
    @State private var info: HeroMeta?
    @FocusState private var focus: Int?
    struct HeroMeta: Decodable { var topLine: String; var score: String?; var fromMal: Bool?; var dub: Bool; var country: String; var episode: String; var minutesLeft: String }

    var body: some View {
        VStack(alignment: .leading, spacing: BP.px(8)) {
            HStack(spacing: BP.px(10)) {
                if let i = info {
                    if !i.topLine.isEmpty { Text(i.topLine).font(BP.sans(11, .bold)).textCase(.uppercase).tracking(0.8).foregroundStyle(BP.accent) }
                    if let s = i.score, !s.isEmpty { Text(i.fromMal == true ? "MAL \(s)" : s).font(BP.sans(12, .semibold)).foregroundStyle(BP.ink) }
                    if i.dub { Text("Sub and Dub").font(BP.sans(12)).foregroundStyle(BP.inkMuted) }
                    if !i.country.isEmpty { Text(i.country).font(BP.sans(12)).foregroundStyle(BP.inkMuted) }
                    if resume != nil, !i.episode.isEmpty { Text(i.episode + (i.minutesLeft.isEmpty ? "" : " · \(i.minutesLeft)")).font(BP.sans(12)).foregroundStyle(BP.inkMuted) }
                }
            }
            HStack(spacing: BP.px(10)) {
                // bp-anime-hero-actions: RotateCcw for Resume, the filled Play for Start Watching.
                Button { onPlay(meta) } label: { Label(resume != nil ? "Resume" : "Start Watching", systemImage: resume != nil ? "arrow.counterclockwise" : "play.fill") }.buttonStyle(BPActionStyle(primary: true))
                    .focused($focus, equals: 0)
                Button { onInfo(meta) } label: { Label("More Info", systemImage: "info.circle") }.buttonStyle(BPActionStyle())
                    .focused($focus, equals: 1)
            }
        }
        .onChange(of: focus != nil) { _, held in onHold?(held) }
        .onDisappear { onHold?(false) }
        .task(id: meta.id) {
            let p = ProfilesStore.shared.active
            let cw: AnyJSON = resume.map { r in .object(["season": r.season.map { .number(Double($0)) } ?? .null, "episode": r.episode.map { .number(Double($0)) } ?? .null,
                                                          "duration": .number(r.durationMs), "timeOffset": .number(r.timeOffsetMs)]) } ?? .null
            let got: HeroMeta? = try? await HarborEngine.shared.call("animeRoom.heroMeta", [meta, p?.id ?? "default", p?.linked ?? true, cw])
            // The hero cycles every 7 s: a slow answer for the last title must not replace the
            // line of the title now on screen.
            guard !Task.isCancelled else { return }
            info = got
        }
    }
}
