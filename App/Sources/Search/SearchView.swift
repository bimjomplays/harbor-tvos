import SwiftUI

/// Search room: keyboard on the left, query + results on the right.
struct SearchView: View {
    /// lib/search-context.tsx: the query and results outlive the page (ShellViewState), so leaving
    /// Search for another tab and coming back finds them where they were.
    @ObservedObject private var model: SearchModel
    /// search-overlay.tsx AI mode + ai-search-section.tsx (engine/aiSearch.ts).
    @ObservedObject private var ai: AISearchModel
    /// The shell's store: the models above and where the ring was in the results.
    private let views: ShellViewState
    /// ai-result-list.tsx openMeta(meta, { episodeHint }).
    @State private var aiOpen: AIOpen?
    @EnvironmentObject private var app: AppModel
    @State private var detail: Meta?
    @State private var phoneOpen = false
    /// (focus pass) Bumped to put the ring on the keyboard (BPKeyboardView.focusRequest).
    @State private var keyboardFocus = 0
    @State private var autofocused = false
    /// A manga result (SR-9) or a franchise manga opened in the manga detail page.
    @State private var mangaOpen: MangaOpen?
    /// (search pass 3) The query field holds the ring (bp-search-input's lit border).
    @FocusState private var fieldFocused: Bool
    /// (search pass 3) The recent-query chip holding the ring.
    @FocusState private var recentFocus: String?
    /// bp-restore: the result cell to put the ring back on when Search opens again (set once, on appear).
    @State private var resume: ShellViewState.SearchSpot?
    /// (parity pass 3, L2) The addon slot whose Try again tile was pressed: while the search runs
    /// again the tile stays (dimmed) under the ring; once the slot is no longer failed the tile goes,
    /// and the ring is handed to the keyboard rather than dropped.
    @State private var retriedSlot: String?

    init(views: ShellViewState) {
        self.views = views
        _model = ObservedObject(wrappedValue: views.search)
        _ai = ObservedObject(wrappedValue: views.ai)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            HStack(alignment: .top, spacing: BP.px(40)) {
                VStack(alignment: .leading, spacing: BP.px(16)) {
                    queryLine
                    BPKeyboardView(onChar: { model.query += $0 },
                                   onBackspace: { if !model.query.isEmpty { model.query.removeLast() } },
                                   onClear: { model.query = "" },
                                   focusRequest: keyboardFocus,
                                   // bp-restore remembers whatever held the ring last: back on the
                                   // keyboard, a return to Search starts there, not on a result.
                                   onHold: { held in if held { views.searchSpot = nil } })
                    HStack(spacing: BP.px(10)) {
                        // bp-phone-typing.tsx: on search, Options (here Play/Pause) opens it too.
                        Button { phoneOpen = true } label: { Label("Type on your phone", systemImage: "iphone") }
                            .buttonStyle(BPActionStyle())
                            .accessibilityIdentifier("search-phone")
                        if ai.available { aiButton }
                    }
                    .focusSection()
                    if !ai.aiMode { statusLine }
                }
                .padding(.leading, BP.gutter)
                .padding(.top, BP.barHeight + BP.px(20))
                .frame(width: BP.px(560), alignment: .leading)
                results
            }
        }
        // bp-search: the page, its own stage mosaic and the washes (RootView's mosaic is off here).
        .background(SearchStageBackdrop(idle: model.status == .idle))
        .onAppear {
            if let q = Fixtures.query, model.query.isEmpty { model.query = q }
            if let seed = app.searchSeed { model.query = seed; app.searchSeed = nil }
            // bp-search-input data-bp-autofocus: opening Search puts the ring on the field (here the
            // keyboard), not on the tab it was opened from. Once: a closing cover hands focus back
            // to the result that opened it. After ShellView's LB/RB default-focus reset (0.1 s).
            if !autofocused {
                autofocused = true
                // use-bp-search: the chip filter is the page's own state (bp-view-state keeps nothing
                // for Search), so a visit opens on All for the kept query.
                model.filter = .all
                if let spot = resumeSpot() {
                    // use-bp-focus route restore: a remembered cell wins over the autofocus seed. The
                    // results scroll to its row and the row to its cell before the shell resets focus.
                    resume = spot
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { ShellFocus.shared.requestDefault() }
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { keyboardFocus += 1 }
                }
            }
        }
        .task { await model.loadSuggestions() }
        // Once per visit: this re-ran on every cover close (a Detail page closing), refetching the
        // model catalog, and a failed read there turned AI mode off under the viewer's AI picks.
        .task { if ai.state == nil { await ai.load() } }
        .onChange(of: model.query) { _, q in
            ai.queryChanged(q)
            retriedSlot = nil
        }
        .onChange(of: model.addonSlots) { _, slots in
            guard let id = retriedSlot else { return }
            let state: String? = slots.first(where: { $0.id == id })?.state
            if state == "failed" {
                // Still failed after the new answer: the tile (and the ring on it) stays.
                if model.status == .done { retriedSlot = nil }
                return
            }
            retriedSlot = nil
            keyboardFocus += 1
        }
        .onChange(of: fieldFocused) { _, on in if on { views.searchSpot = nil } }
        .onPlayPauseCommand { phoneOpen.toggle() }
        .fullScreenCover(isPresented: $phoneOpen) {
            // search-overlay.tsx: Enter in AI mode asks the model straight away.
            PhoneTypingSheet(label: "Search", placeholder: "Search Harbor", text: $model.query,
                             onSubmit: { ai.queryChanged(model.query); if ai.aiMode { ai.runNow() } }, onClose: { phoneOpen = false })
        }
        .onChange(of: detail?.id) { _, id in if id != nil { model.commitRecent() } }
        .onChange(of: person?.id) { _, id in if id != nil { model.commitRecent() } }
        .onChange(of: channel?.id) { _, id in if id != nil { model.commitRecent() } }
        .onChange(of: collection?.id) { _, id in if id != nil { model.commitRecent() } }
        .onChange(of: addonPage?.id) { _, id in if id != nil { model.commitRecent() } }
        .onChange(of: mangaOpen?.id) { _, id in if id != nil { model.commitRecent() } }
        .onChange(of: aiOpen?.id) { _, id in if id != nil { model.commitRecent() } }
        .fullScreenCover(item: $aiOpen) { o in DetailView(meta: o.meta, episodeHint: o.hint) }
        .fullScreenCover(item: $mangaOpen) { o in MangaDetailView(mangaId: o.id) }
        .fullScreenCover(item: $collection) { hit in SearchCollectionView(hit: hit) { collection = nil } }
        .fullScreenCover(item: $addonPage) { t in AddonPageView(base: t.base, name: t.name, logo: t.logo) }
        .fullScreenCover(item: $detail) { m in DetailView(meta: m) }
        .fullScreenCover(item: $person) { p in PersonView(personId: p.tmdbId ?? 0, name: p.name) }
        .fullScreenCover(item: $channel) { ch in
            PlayerScreen(title: ch.name, subtitle: ch.playlistName, url: URL(string: ch.url) ?? URL(string: "about:blank")!, isLive: true) { _ in channel = nil }
        }
    }

    /// bp-search-input.tsx BpSearchField: the field is a real input (data-tv-text-auto), so the
    /// TV's own keyboard types into it. (search pass 3) The line was only a label: nothing on the
    /// page took the system keyboard, so Siri Remote dictation (hold the mic with the keyboard up)
    /// could never fill the query. Select on the field opens the tvOS keyboard; what it types or
    /// dictates lands in the query and searches like the on-screen keys (the 180 ms debounce).
    /// The drawn line stays on top, so a long query keeps its end in view.
    private var queryLine: some View {
        ZStack(alignment: .leading) {
            TextField(T("Search Harbor"), text: $model.query)
                .textFieldStyle(.plain)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .foregroundStyle(Color.clear)
                .tint(Color.clear)
                .focused($fieldFocused)
                // search-overlay.tsx: Enter in AI mode asks the model straight away.
                .onSubmit {
                    ai.queryChanged(model.query)
                    if ai.aiMode { ai.runNow() }
                }
                .padding(.horizontal, BP.px(16))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // bp-search-input.tsx aria-label t("Search Harbor").
                .accessibilityLabel(Text(T("Search Harbor")))
                .accessibilityIdentifier("search-query")
            queryDisplay
                .padding(.horizontal, BP.px(16))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: BP.rMD, style: .continuous).fill(BP.panel))
                .overlay(RoundedRectangle(cornerRadius: BP.rMD, style: .continuous)
                    .stroke(fieldFocused ? BP.focusStroke : BP.edge2, lineWidth: fieldFocused ? 3 : 1))
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .frame(height: BP.px(56))
    }

    private var queryDisplay: some View {
        HStack(spacing: BP.px(8)) {
            Image(systemName: "magnifyingglass").foregroundStyle(ai.aiMode ? BP.accent : BP.inkMuted).accessibilityHidden(true)
            if ai.aiMode && model.query.isEmpty {
                // search-overlay.tsx AiExampleHint: a sample request in place of the placeholder, every 6 s.
                TimelineView(.periodic(from: .now, by: 6)) { ctx in
                    let examples = AISearchModel.examples
                    Text(T(examples[Int(ctx.date.timeIntervalSince1970 / 6) % examples.count]))
                        .font(BP.sans(22, .semibold)).foregroundStyle(BP.accent.opacity(0.8)).lineLimit(1)
                }
            } else {
                Text(model.query.isEmpty ? T("Search Harbor") : model.query)
                    .font(BP.sans(22, .semibold)).foregroundStyle(model.query.isEmpty ? BP.inkSubtle : BP.ink).lineLimit(1)
                    // (detail/search pass 2) A long query keeps its end in view, where the caret is
                    // (an input scrolls to it); the tail was cut, so the letters being typed never showed.
                    .truncationMode(model.query.isEmpty ? .tail : .head)
            }
            Rectangle().fill(BP.ink).frame(width: 2, height: BP.px(26)).opacity(0.8)
            Spacer()
        }
    }

    /// ai-mode-button.tsx: Select toggles AI mode; holding it (the TV's long press, upstream's
    /// hold or right-click) opens the model menu, and picking a model turns AI mode on.
    private var aiButton: some View {
        Button { ai.aiMode.toggle() } label: {
            Label(T("AI search"), systemImage: "sparkles")
        }
        .buttonStyle(BPActionStyle(primary: ai.aiMode))
        .accessibilityIdentifier("search-ai")
        .bpSelected(ai.aiMode)
        .contextMenu {
            Section(T("AI model")) {
                ForEach(ai.menu) { m in
                    Button { Task { await ai.selectModel(m.id) } } label: {
                        if m.id == ai.state?.model {
                            Label(m.label, systemImage: "checkmark")
                        } else {
                            Text(verbatim: m.free ? "\(m.label) · \(m.provider == "groq" ? T("Free tier") : T("Free"))" : m.label)
                        }
                    }
                }
            }
        }
    }

    @State private var channel: SearchModel.Results.LiveTvHit?
    @State private var person: SearchModel.Results.Person?

    @State private var collection: SearchModel.Results.CollectionHit?
    @State private var addonPage: RoomView.AddonTarget?

    @StateObject private var addons = AddonsModel()

    /// bp-search-cells: a manga hit opens the manga detail. A franchise row's manga carries an
    /// AniList id, which the reader cannot open, so it is resolved back by title first
    /// (search-manga-resolve resolveMangaIdByTitle); nothing found opens nothing.
    @MainActor private func select(_ m: Meta) {
        guard m.type == "manga" else { detail = m; return }
        guard m.id.hasPrefix("anilist:") else { mangaOpen = MangaOpen(id: m.id); return }
        let asked = model.query
        Task {
            let id: String? = try? await HarborEngine.shared.call("manga.resolveTitle", [m.name])
            // (detail/search pass 2) A late answer opens nothing once the viewer has moved on (a new
            // query, or another page already up: a second cover could not present and stayed pending).
            guard let id, model.query == asked, detail == nil, aiOpen == nil, mangaOpen == nil, person == nil, collection == nil, addonPage == nil, channel == nil else { return }
            mangaOpen = MangaOpen(id: id)
        }
    }

    /// (search pass 3) One recent query off the list. The ring moves to the chip that takes its
    /// place (or the one before it), and to the keyboard once the row is gone, as Clear does.
    @MainActor private func removeRecent(_ q: String) {
        let at: Int = model.recent.firstIndex(of: q) ?? 0
        model.removeRecent(q)
        let rest = model.recent
        guard !rest.isEmpty else {
            keyboardFocus += 1
            return
        }
        let next = rest[min(at, rest.count - 1)]
        DispatchQueue.main.async { recentFocus = next }
    }

    /// bp-search-cells addonBase: the transport url without its manifest.json.
    private static func addonBase(_ transportUrl: String) -> String {
        transportUrl.hasSuffix("/manifest.json") ? String(transportUrl.dropLast("/manifest.json".count)) : transportUrl
    }

    /// Hold Select on a hit that is not installed yet: the existing addon install path.
    @MainActor private func install(_ hit: SearchModel.Results.AddonHit) {
        guard !hit.installed, let url = hit.transportUrl else { return }
        Task { if await addons.install(url: url) { model.markInstalled(hit.id) } }
    }

    // use-bp-search "Addons you could install" (bp-search-rows BpAddonHitCell): Select opens the
    // addon's own page (bp-search-cells pushBigPicture kind "addon"); a hit with no transport url
    // has nothing to browse and is dropped. Holding Select offers Install.
    private var addonIndexRow: some View {
        VStack(alignment: .leading, spacing: BP.px(10)) {
            Text("Addons you could install").font(BP.sans(19, .bold)).foregroundStyle(BP.ink).padding(.horizontal, BP.gutter).accessibilityAddTraits(.isHeader)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: BP.trackGap) {
                    ForEach(model.addonHits.filter { $0.transportUrl != nil }) { hit in
                        Button {
                            guard let url = hit.transportUrl else { return }
                            addonPage = RoomView.AddonTarget(base: Self.addonBase(url), name: hit.name, logo: hit.logo)
                        } label: {
                            HStack(spacing: BP.px(10)) {
                                RemoteImage(url: hit.logo, contentMode: .fit).frame(width: BP.px(36), height: BP.px(36)).clipShape(RoundedRectangle(cornerRadius: BP.px(8)))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(hit.name).font(BP.sans(13, .semibold)).foregroundStyle(BP.ink).lineLimit(1)
                                    HStack(spacing: BP.px(4)) {
                                        if hit.installed { Image(systemName: "checkmark").font(.system(size: BP.px(10), weight: .bold)).accessibilityLabel(Text(T("Installed"))) }
                                        Text(hit.blurb ?? "").lineLimit(1)
                                    }
                                    .font(BP.sans(10)).foregroundStyle(BP.inkSubtle)
                                }
                            }
                            .padding(.horizontal, BP.px(12)).padding(.vertical, BP.px(8))
                            .frame(width: BP.px(280), alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).fill(BP.panel))
                        }
                        .buttonStyle(BPTileStyle(radius: BP.rSM))
                        .contextMenu {
                            if !hit.installed {
                                Button("Install") { install(hit) }
                            }
                        }
                    }
                }
                .padding(.horizontal, BP.gutter).padding(.vertical, BP.px(14))
            }
            .scrollClipDisabled()
        }
        .focusSection()
    }

    // bp-search-rows BpCollectionCell: a 16:9 banner (art at 70 %, scrim, Layers mark and the
    // name); Select opens the collection (bp-collection.tsx, a TVDB list).
    private var collectionRow: some View {
        VStack(alignment: .leading, spacing: BP.px(10)) {
            Text("Collections").font(BP.sans(19, .bold)).foregroundStyle(BP.ink).padding(.horizontal, BP.gutter).accessibilityAddTraits(.isHeader)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: BP.trackGap) {
                    ForEach(model.collections) { hit in
                        Button { collection = hit } label: { SearchCollectionCell(hit: hit) }
                            .buttonStyle(BPTileStyle(radius: BP.rMD))
                    }
                }
                .padding(.horizontal, BP.gutter).padding(.vertical, BP.px(14))
            }
            .scrollClipDisabled()
        }
        .focusSection()
    }

    /// bp-search chip strip label: never a running total. "Searching" while anything is still
    /// answering, "{n} results" once settled.
    private var resultsLabel: String {
        if model.busy { return T("Searching") }
        let total = model.distinctCount(model.filter == .all ? nil : model.filter)
        return model.settled && total > 0 ? T("%lld results", total) : ""
    }

    // bp-search kind chips (use-bp-search chips): All plus each group that found something,
    // with counts. The strip is held for the whole query so counts landing never shove the rail.
    private var chipStrip: some View {
        HStack(spacing: BP.px(8)) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: BP.px(8)) {
                    ForEach(model.chips) { chip in
                        Button { model.filter = chip.filter } label: {
                            HStack(spacing: BP.px(6)) {
                                if model.filter == chip.filter { Circle().frame(width: BP.px(8), height: BP.px(8)) }
                                Text(T(chip.filter.label))
                                Text("\(chip.count)").font(BP.sans(11, .bold)).opacity(0.6)
                            }
                        }
                        .buttonStyle(BPActionStyle(primary: model.filter == chip.filter))
                        .bpSelected(model.filter == chip.filter)
                    }
                }
                .padding(.horizontal, BP.gutter).padding(.vertical, BP.px(6))
            }
            .scrollClipDisabled()
            Text(resultsLabel)
                .font(BP.sans(11, .semibold)).textCase(.uppercase).tracking(1.6).foregroundStyle(BP.inkSubtle)
                .lineLimit(1).fixedSize()
                .padding(.trailing, BP.gutter)
        }
        .frame(minHeight: BP.px(56))
        .focusSection()
    }

    private static func isCoreRow(_ key: String) -> Bool { key == "movies" || key == "series" || key == "anime" || key == "manga" }
    /// Movies and Series rows under the active chip.
    private var titleRows: [BrowseRow] { model.rows.filter { ($0.key == "movies" || $0.key == "series") && model.shows(SearchModel.group(ofRow: $0.key)) } }
    /// Anime and Manga rows under the active chip.
    private var mediaRows: [BrowseRow] { model.rows.filter { ($0.key == "anime" || $0.key == "manga") && model.shows(SearchModel.group(ofRow: $0.key)) } }
    /// Franchise rows under the active chip (the per-addon rows go through their slots, addonSlotRows).
    private var laterRows: [BrowseRow] { model.rows.filter { !Self.isCoreRow($0.key) && !$0.key.hasPrefix("addon:") && model.shows(SearchModel.group(ofRow: $0.key)) } }
    /// Addon rows that answered with no announced slot (an engine without addonQueries).
    private var unslottedAddonRows: [BrowseRow] {
        let slotted: Set<String> = Set(model.addonSlots.map { "addon:" + $0.id })
        return model.rows.filter { $0.key.hasPrefix("addon:") && !slotted.contains($0.key) }
    }

    /// (parity pass 3, L2) bp-search-results: one fixed slot per addon, in installed order. A slot
    /// with titles is its row; pending holds quiet plates, failed says "Didn't answer" with Try
    /// again; one that settled empty collapses (bpGroupRenders).
    @ViewBuilder private var addonSlotRows: some View {
        if model.shows(.addons) {
            ForEach(model.addonSlots) { slot in
                if let row = model.rows.first(where: { $0.key == "addon:" + slot.id }) {
                    BPRowView(row: row, onFocus: { note(row.key, $0) }, onSelect: { select($0) }, restoreCell: resumeCell(row.key))
                        .id(row.key)
                } else if slot.state == "pending" || slot.state == "failed" {
                    SearchAddonPlate(slot: slot, retrying: model.status == .loading, onRetry: {
                        retriedSlot = slot.id
                        model.retry()
                    })
                        .id("addon:" + slot.id)
                }
            }
            ForEach(unslottedAddonRows) { row in
                BPRowView(row: row, onFocus: { note(row.key, $0) }, onSelect: { select($0) }, restoreCell: resumeCell(row.key))
                    .id(row.key)
            }
        }
    }

    // bp-search-rows BpChannelCell: a channel from your Live TV sources, Select tunes it.
    private var channelRow: some View {
        VStack(alignment: .leading, spacing: BP.px(10)) {
            Text("Live TV").font(BP.sans(19, .bold)).foregroundStyle(BP.ink).padding(.horizontal, BP.gutter).accessibilityAddTraits(.isHeader)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: BP.trackGap) {
                    ForEach(model.channels) { ch in
                        Button { channel = ch } label: {
                            VStack(spacing: BP.px(6)) {
                                RemoteImage(url: ch.logo, contentMode: .fit).frame(width: BP.px(120), height: BP.px(60))
                                Text(ch.name).font(BP.sans(12, .semibold)).foregroundStyle(BP.ink).lineLimit(2).multilineTextAlignment(.center)
                                Text(ch.group ?? ch.playlistName).font(BP.sans(10)).foregroundStyle(BP.inkSubtle).lineLimit(1)
                            }
                            .padding(BP.px(10))
                            .frame(width: BP.px(190), height: BP.px(130))
                            .background(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).fill(BP.panel2))
                        }
                        .buttonStyle(BPTileStyle(radius: BP.rSM))
                    }
                }
                .padding(.horizontal, BP.gutter).padding(.vertical, BP.px(14))
            }
            .scrollClipDisabled()
        }
        .focusSection()
    }

    @ViewBuilder private var statusLine: some View {
        switch model.status {
        case .loading: BPNote(text: "Searching…")
        case .failed(let why): BPNote(text: why, tone: BP.danger)
        case .done where model.settled && model.distinctCount(nil) == 0:
            VStack(alignment: .leading, spacing: BP.px(10)) {
                BPNote(text: emptyMessage)
                // bp-search-empty action: t("Try again") when addons did not answer (onAction retry).
                if !model.addonsFailed.isEmpty {
                    // The note and this button give way to "Searching…": the ring goes to the keyboard
                    // first (as Clear does) instead of wherever tvOS resets it.
                    Button {
                        keyboardFocus += 1
                        model.retry()
                    } label: { Label(T("Try again"), systemImage: "arrow.clockwise") }
                        .buttonStyle(BPActionStyle())
                }
            }
        default: EmptyView()
        }
    }

    /// (search pass 3) bp-search-empty.tsx bpSearchEmptyMessage: TMDB down (offline) and addons
    /// that never answered are said as such, not as a query that exists nowhere.
    private var emptyMessage: String {
        let q = model.query.trimmingCharacters(in: .whitespaces)
        if model.tmdbUnavailable { return T("TMDB is temporarily unavailable. Try your search again shortly.") }
        let failed = model.addonsFailed.count
        if failed > 0 { return T("Nothing found for \"%@\". %lld of your addons did not answer.", q, failed) }
        return T("Nothing found for \"%@\"", q)
    }

    /// bp-restore rememberBpPosition for Search: the result cell the ring is on, under this query.
    private func note(_ row: String, _ m: Meta) {
        views.searchSpot = ShellViewState.SearchSpot(query: model.query, row: row, cell: m.id)
    }

    /// The remembered cell when Search opens again, if its row still holds it under the same query
    /// (idle, the Suggested row). A query changed elsewhere (the quick panel's Search) starts over.
    private func resumeSpot() -> ShellViewState.SearchSpot? {
        // In AI mode the AI section stands in for the rows.
        guard !ai.aiMode, let spot = views.searchSpot, spot.query == model.query else { return nil }
        let metas: [Meta]
        if spot.row == "suggested" {
            guard model.status == .idle else { return nil }
            metas = model.suggestions
        } else {
            guard model.status != .idle, let row = model.rows.first(where: { $0.key == spot.row }) else { return nil }
            metas = row.metas
        }
        return metas.contains(where: { $0.id == spot.cell }) ? spot : nil
    }

    /// The row's cell that takes the ring when the shell resets focus on a return (BPRowView restoreCell).
    private func resumeCell(_ row: String) -> String? {
        guard let resume, resume.row == row else { return nil }
        return resume.cell
    }

    private var results: some View {
        ScrollViewReader { proxy in
            resultsScroll
                // The remembered row is brought into existence (the results are lazy) and into view
                // before focus is asked to land on it; the row itself scrolls to the cell.
                .onChange(of: resume) { _, spot in
                    guard let spot else { return }
                    proxy.scrollTo(spot.row, anchor: .center)
                    // Once the ring has had its chance, the tile stops preferring default focus.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { resume = nil }
                }
        }
    }

    private var resultsScroll: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: BP.rowGap) {
                Color.clear.frame(height: BP.barHeight + BP.px(20))
                // search-overlay.tsx: in AI mode the AI section replaces the regular results.
                if ai.aiMode && !model.query.trimmingCharacters(in: .whitespaces).isEmpty {
                    AISearchSection(ai: ai, query: model.query.trimmingCharacters(in: .whitespaces),
                                    onOpen: { r in aiOpen = AIOpen(meta: r.meta, season: r.season, episode: r.episode) },
                                    onRun: { keyboardFocus += 1 })
                    .padding(.horizontal, BP.gutter)
                } else {
                    regularResults
                }
                Color.clear.frame(height: BP.hintHeight + BP.px(40))
            }
        }
        .frame(maxWidth: .infinity)
        .focusSection()
    }

    @ViewBuilder private var regularResults: some View {
        if model.status == .idle {
            // bp-search idle: recent queries as chips, then a "Suggested" row from the hero feed.
            if !model.recent.isEmpty {
                VStack(alignment: .leading, spacing: BP.px(10)) {
                    Text("Recent").font(BP.sans(19, .bold)).foregroundStyle(BP.ink).padding(.horizontal, BP.gutter).accessibilityAddTraits(.isHeader)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: BP.px(8)) {
                            // (focus pass) bp-search BpRecentRow onPick / onClear: setBpFocus(input) first.
                            // Either press takes the whole row away (the query leaves idle, or the list
                            // empties) from under the ring, leaving it to wherever tvOS resets focus.
                            ForEach(model.recent, id: \.self) { q in
                                Button(q) { keyboardFocus += 1; model.query = q }
                                    .buttonStyle(BPActionStyle())
                                    .focused($recentFocus, equals: q)
                                    // (search pass 3) search-context removeRecent (the desktop chip's
                                    // X, t("Remove {name}")): hold Select to take one query off.
                                    .contextMenu {
                                        Button(T("Remove %@", q), role: .destructive) { removeRecent(q) }
                                    }
                            }
                            Button { keyboardFocus += 1; model.clearRecent() } label: { Image(systemName: "trash") }.buttonStyle(BPActionStyle()).accessibilityLabel("Clear recent searches")
                        }
                        .padding(.horizontal, BP.gutter).padding(.vertical, BP.px(6))
                    }
                    .scrollClipDisabled()
                }
                .focusSection()
            }
            if !model.suggestions.isEmpty {
                BPRowView(row: BrowseRow(key: "suggested", title: T("Suggested"), metas: model.suggestions), onFocus: { note("suggested", $0) }, onSelect: { detail = $0 },
                          restoreCell: resumeCell("suggested"))
                    .id("suggested")
            } else if model.suggestionsLoaded {
                // bp-search idle showEmpty (suggestions.length === 0): the right side was blank.
                BPNote(text: "Start typing to search movies, series and everything your addons carry.").padding(.horizontal, BP.gutter)
            }
        }
        if model.status != .idle { chipStrip }
        resultNotes
        // bp-search: the Top match slot belongs to a query's results. Idle, a focused Suggested
        // poster was drawn under the row as a "Top match" for a search nobody typed.
        // (search pass 3) use-bp-search slot "top" is r.topMatch alone, a card Select opens
        // (bp-search-cells titleCell HERO). The panel showed whichever tile last had the ring, and
        // kept showing it after the ring left the rows; it could not be opened either.
        if model.status != .idle, model.filter == .all, let top = model.topMatch {
            Button { select(top) } label: { TopMatchPanel(meta: top) }
                .buttonStyle(BPTileStyle(radius: BP.rMD))
                .padding(.horizontal, BP.gutter)
                .focusSection()
        }
        leadRows
        // use-bp-search slot order: Movies, Series, People, Anime, Manga, Live TV, Collections,
        // Franchise, one row per addon, then "Addons you could install".
        ForEach(mediaRows) { row in
            BPRowView(row: row, onFocus: { note(row.key, $0) }, onSelect: { select($0) }, restoreCell: resumeCell(row.key))
                .id(row.key)
        }
        if model.shows(.livetv) && !model.channels.isEmpty { channelRow }
        if model.shows(.collections) && !model.collections.isEmpty { collectionRow }
        ForEach(laterRows) { row in
            BPRowView(row: row, onFocus: { note(row.key, $0) }, onSelect: { select($0) }, restoreCell: resumeCell(row.key))
                .id(row.key)
        }
        addonSlotRows
        if model.shows(.addons) && model.addonHits.contains(where: { $0.transportUrl != nil }) { addonIndexRow }
    }

    @ViewBuilder private var resultNotes: some View {
        // (search pass 3) bp-search: TMDB did not answer but something else did (offline, or TMDB down).
        if model.status == .done, model.tmdbUnavailable, model.distinctCount(nil) > 0 {
            BPNote(text: "TMDB is temporarily unavailable, so these results may be incomplete.").padding(.horizontal, BP.gutter)
        }
        if model.filterStale {
            // bp-search-empty filterStale
            BPNote(text: "Nothing in this filter. Choose All to see everything that answered.").padding(.horizontal, BP.gutter)
        }
    }

    /// (search pass 3) use-bp-search buildBpSearchSlots: People follows Series unless the query
    /// names the first person found (promotePerson), then it leads Movies. It always led.
    @ViewBuilder private var leadRows: some View {
        if model.promotePerson { peopleRow }
        ForEach(titleRows) { row in
            BPRowView(row: row, onFocus: { note(row.key, $0) }, onSelect: { select($0) }, restoreCell: resumeCell(row.key))
                .id(row.key)
        }
        if !model.promotePerson { peopleRow }
    }

    @ViewBuilder private var peopleRow: some View {
        if model.shows(.people) && !model.people.isEmpty {
            VStack(alignment: .leading, spacing: BP.px(10)) {
                Text("People").font(BP.sans(19, .bold)).foregroundStyle(BP.ink).padding(.horizontal, BP.gutter).accessibilityAddTraits(.isHeader)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: BP.trackGap) {
                        ForEach(model.people) { person in
                            Button { if person.tmdbId != nil { self.person = person } } label: {
                                VStack(spacing: BP.px(8)) {
                                    RemoteImage(url: person.profile).frame(width: BP.px(110), height: BP.px(110)).clipShape(Circle())
                                    Text(person.name).font(BP.sans(12, .semibold)).foregroundStyle(BP.ink).lineLimit(1)
                                    if let k = person.knownFor, !k.isEmpty { Text(k).font(BP.sans(10)).foregroundStyle(BP.inkSubtle).lineLimit(1) }
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
    }
}

/// An AI pick opened on its detail page; an episode pick carries its season and episode.
struct AIOpen: Identifiable {
    var meta: Meta
    var season: Int?
    var episode: Int?
    var hint: (season: Int, episode: Int)? {
        guard let season, let episode else { return nil }
        return (season, episode)
    }
    var id: String { "\(meta.id):\(season ?? 0):\(episode ?? 0)" }
}


/// Top match (use-bp-search.ts slot 1): art on the right, title, facts and overview.
struct TopMatchPanel: View {
    let meta: Meta
    var body: some View {
        HStack(alignment: .top, spacing: BP.px(18)) {
            VStack(alignment: .leading, spacing: BP.px(6)) {
                Text("Top match").font(BP.sans(11, .bold)).foregroundStyle(BP.accent).textCase(.uppercase).tracking(1)
                Text(meta.name).font(BP.display(26)).foregroundStyle(BP.ink).lineLimit(2)
                if !meta.facts.isEmpty { Text(meta.facts).font(BP.sans(13, .medium)).foregroundStyle(BP.inkMuted) }
                Text(meta.description ?? "").font(BP.sans(14)).foregroundStyle(BP.inkMuted).lineLimit(3)
            }
            Spacer(minLength: 0)
            RemoteImage(url: meta.background ?? meta.poster)
                .frame(width: BP.px(200), height: BP.px(112))
                .clipShape(RoundedRectangle(cornerRadius: BP.rXS, style: .continuous))
        }
        .padding(BP.px(16))
        .background(RoundedRectangle(cornerRadius: BP.rMD, style: .continuous).fill(BP.panel))
        .overlay(RoundedRectangle(cornerRadius: BP.rMD, style: .continuous).stroke(BP.edge, lineWidth: 1))
        .animation(.easeOut(duration: 0.26), value: meta.id)
    }
}

/// bp-search-rows BpCollectionCell face: 16:9 art at 70 % under a bottom scrim, a Layers mark
/// and the collection's name.
struct SearchCollectionCell: View {
    let hit: SearchModel.Results.CollectionHit
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            BP.panel
            RemoteImage(url: hit.image).opacity(0.7)
            LinearGradient(colors: [BP.void_.opacity(0.92), BP.void_.opacity(0.45), .clear], startPoint: .bottom, endPoint: .top)
            HStack(spacing: BP.px(8)) {
                Image(systemName: "square.stack.3d.up").font(.system(size: BP.px(15), weight: .semibold)).foregroundStyle(BP.inkSubtle)
                    .accessibilityHidden(true)
                Text(hit.name).font(BP.sans(14, .semibold)).foregroundStyle(BP.ink).lineLimit(1)
            }
            .padding(BP.px(12))
        }
        .frame(width: BP.px(300), height: BP.px(169))
        .clipShape(RoundedRectangle(cornerRadius: BP.rMD, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: BP.rMD, style: .continuous).stroke(BP.edge, lineWidth: 1))
    }
}

/// bp-collection.tsx for a search hit: the TVDB list's entries hydrated through the engine, shown
/// in the Collections room's items overlay; "Couldn't load this collection right now." otherwise.
struct SearchCollectionView: View {
    let hit: SearchModel.Results.CollectionHit
    let onClose: () -> Void
    @State private var card: CollectionsModel.Card?
    @State private var loaded = false
    @State private var detail: Meta?

    var body: some View {
        ZStack {
            if let card, !card.items.isEmpty {
                // A search hit is someone else's list: default limits, nothing to reload on change.
                CollectionItemsOverlay(card: card, limits: CollectionsModel.Limits(collections: 24, items: 100),
                                       onClose: onClose, onChanged: { _ in }, onOpen: { item in detail = item.meta })
            } else {
                BP.void_.opacity(0.97).ignoresSafeArea()
                VStack(alignment: .leading, spacing: BP.px(14)) {
                    Text("Collection").font(BP.sans(12, .bold)).foregroundStyle(BP.accent).textCase(.uppercase).tracking(1)
                    Text(hit.name).font(BP.display(32)).foregroundStyle(BP.ink)
                    if let o = hit.overview, !o.isEmpty {
                        Text(o).font(BP.sans(14)).foregroundStyle(BP.inkMuted).lineLimit(2).frame(maxWidth: BP.px(700), alignment: .leading)
                    }
                    if loaded {
                        BPNote(text: "Couldn't load this collection right now.")
                    } else {
                        ProgressView().tint(BP.inkMuted)
                    }
                    Button("Close", action: onClose).buttonStyle(BPActionStyle())
                }
                .padding(.horizontal, BP.gutter).padding(.top, BP.px(60))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .onExitCommand { onClose() }
            }
        }
        .task {
            guard card == nil else { return }   // (bug pass) re-runs when a title's cover closes
            card = try? await HarborEngine.shared.call("search.collection", [hit.id, hit.name, hit.image])
            loaded = true
        }
        .fullScreenCover(item: $detail) { m in DetailView(meta: m) }
    }
}

/// bp-search.tsx behind the room: the page (--bp-page, the canvas), the stage mosaic, the idle
/// wash, and over it the results wash, which fades in once there is a query: the mosaic sinks
/// under results rather than leaving, so it neither pops nor rebuilds on the next empty field.
/// Upstream fills it from the Home catalog rows; the port uses the hero feed, as the ambient
/// mosaic and the idle "Suggested" row do.
struct SearchStageBackdrop: View {
    var idle: Bool
    @ObservedObject private var pool = AmbientPool.shared

    var body: some View {
        ZStack {
            BP.canvas
            BPStageMosaic(posters: pool.posters, key: "search")
            LinearGradient(stops: [.init(color: BP.canvas.opacity(0.74), location: 0), .init(color: BP.canvas.opacity(0.82), location: 0.46),
                                   .init(color: BP.canvas.opacity(0.92), location: 1)], startPoint: .top, endPoint: .bottom)
            LinearGradient(stops: [.init(color: BP.canvas.opacity(0.92), location: 0), .init(color: BP.canvas.opacity(0.95), location: 0.46),
                                   .init(color: BP.canvas.opacity(0.98), location: 1)], startPoint: .top, endPoint: .bottom)
                .opacity(idle ? 0 : 1)
        }
        .animation(BP.easeSlow, value: idle)
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .task { await pool.load() }
    }
}

/// (parity pass 3, L2) bp-search-group.tsx for an addon slot with nothing to show yet: the head (the
/// addon's mark and name, "Didn't answer" once it failed) over the track. Pending draws eight quiet
/// poster plates (never focusable, so the ring steps over the row); failed draws the Try again
/// tile, which asks the whole search again (search-context retry). While that runs the tile dims
/// and keeps the ring rather than going away under it.
struct SearchAddonPlate: View {
    let slot: SearchModel.AddonSlot
    var retrying = false
    let onRetry: () -> Void
    /// bp-search-group SHAPE.poster.n.
    private static let plates = 8

    private var failed: Bool { slot.state == "failed" }

    var body: some View {
        VStack(alignment: .leading, spacing: BP.px(10)) {
            HStack(spacing: BP.px(10)) {
                AddonLogoView(url: slot.logo, name: slot.name, side: BP.px(24))
                    .accessibilityHidden(true)
                Text(slot.name).font(BP.sans(19, .bold)).foregroundStyle(BP.ink).lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                if failed {
                    Text(T("Didn't answer"))
                        .font(BP.sans(10, .semibold)).textCase(.uppercase).tracking(BP.px(1.4)).foregroundStyle(BP.inkSubtle)
                        .padding(.horizontal, BP.px(9)).padding(.vertical, BP.px(2))
                        .overlay(Capsule().stroke(BP.edge, lineWidth: 1))
                }
            }
            .padding(.horizontal, BP.gutter)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: BP.trackGap) {
                    if failed {
                        retryTile
                    } else {
                        ForEach(0..<Self.plates, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: BP.rXS, style: .continuous)
                                .fill(BP.panel)
                                .frame(width: BPTileView.posterSize.width, height: BPTileView.posterSize.height)
                        }
                        .accessibilityHidden(true)
                    }
                }
                .padding(.horizontal, BP.gutter).padding(.vertical, BP.px(14))
            }
            .scrollClipDisabled()
        }
        .focusSection()
    }

    /// BpGroupRetry: a poster-sized tile with RotateCw and t("Try again").
    private var retryTile: some View {
        Button {
            guard !retrying else { return }
            BPSound.shared.click()
            onRetry()
        } label: {
            HStack(spacing: BP.px(8)) {
                Image(systemName: "arrow.clockwise").font(.system(size: BP.px(14), weight: .semibold))
                Text(T("Try again")).font(BP.sans(13, .semibold))
            }
            .foregroundStyle(BP.inkMuted)
            .padding(.horizontal, BP.px(14))
            .frame(width: BPTileView.posterSize.width, height: BPTileView.posterSize.height)
            .background(RoundedRectangle(cornerRadius: BP.rMD, style: .continuous).fill(BP.panel))
            .overlay(RoundedRectangle(cornerRadius: BP.rMD, style: .continuous).stroke(BP.edge2, lineWidth: 1))
            .opacity(retrying ? 0.45 : 1)
        }
        .buttonStyle(BPTileStyle(radius: BP.rMD))
    }
}
