import SwiftUI

/// Search room: keyboard on the left, query + results on the right.
struct SearchView: View {
    @StateObject private var model = SearchModel()
    @EnvironmentObject private var app: AppModel
    @State private var spotlight: Meta?
    @State private var detail: Meta?

    var body: some View {
        ZStack(alignment: .topLeading) {
            HStack(alignment: .top, spacing: BP.px(40)) {
                VStack(alignment: .leading, spacing: BP.px(16)) {
                    queryLine
                    BPKeyboardView(onChar: { model.query += $0 },
                                   onBackspace: { if !model.query.isEmpty { model.query.removeLast() } },
                                   onClear: { model.query = "" })
                    statusLine
                }
                .padding(.leading, BP.gutter)
                .padding(.top, BP.barHeight + BP.px(20))
                .frame(width: BP.px(560), alignment: .leading)
                results
            }
        }
        .onAppear {
            if let q = Fixtures.query, model.query.isEmpty { model.query = q }
            if let seed = app.searchSeed { model.query = seed; app.searchSeed = nil }
        }
        .task { await model.loadSuggestions() }
        .onChange(of: detail?.id) { _, id in if id != nil { model.commitRecent() } }
        .onChange(of: person?.id) { _, id in if id != nil { model.commitRecent() } }
        .onChange(of: channel?.id) { _, id in if id != nil { model.commitRecent() } }
        .onChange(of: collection?.id) { _, id in if id != nil { model.commitRecent() } }
        .onChange(of: addonPage?.id) { _, id in if id != nil { model.commitRecent() } }
        .fullScreenCover(item: $collection) { hit in SearchCollectionView(hit: hit) { collection = nil } }
        .fullScreenCover(item: $addonPage) { t in AddonPageView(base: t.base, name: t.name, logo: t.logo) }
        .fullScreenCover(item: $detail) { m in DetailView(meta: m) }
        .fullScreenCover(item: $person) { p in PersonView(personId: p.tmdbId ?? 0, name: p.name) }
        .fullScreenCover(item: $channel) { ch in
            PlayerScreen(title: ch.name, subtitle: ch.playlistName, url: URL(string: ch.url) ?? URL(string: "about:blank")!, isLive: true) { _ in channel = nil }
        }
    }

    private var queryLine: some View {
        HStack(spacing: BP.px(8)) {
            Image(systemName: "magnifyingglass").foregroundStyle(BP.inkMuted)
            Text(model.query.isEmpty ? "Search movies, series, anime" : model.query)
                .font(BP.sans(22, .semibold)).foregroundStyle(model.query.isEmpty ? BP.inkSubtle : BP.ink).lineLimit(1)
            Rectangle().fill(BP.ink).frame(width: 2, height: BP.px(26)).opacity(0.8)
            Spacer()
        }
        .frame(height: BP.px(44))
        .accessibilityIdentifier("search-query")
    }

    @State private var channel: SearchModel.Results.LiveTvHit?
    @State private var person: SearchModel.Results.Person?

    @State private var collection: SearchModel.Results.CollectionHit?
    @State private var addonPage: RoomView.AddonTarget?

    @StateObject private var addons = AddonsModel()

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
            Text("Addons you could install").font(BP.sans(19, .bold)).foregroundStyle(BP.ink).padding(.horizontal, BP.gutter)
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
                                        if hit.installed { Image(systemName: "checkmark").font(.system(size: BP.px(10), weight: .bold)) }
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
            Text("Collections").font(BP.sans(19, .bold)).foregroundStyle(BP.ink).padding(.horizontal, BP.gutter)
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
        if model.busy { return "Searching" }
        let total = model.distinctCount(model.filter == .all ? nil : model.filter)
        return model.settled && total > 0 ? "\(total) results" : ""
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
                                Text(chip.filter.label)
                                Text("\(chip.count)").font(BP.sans(11, .bold)).opacity(0.6)
                            }
                        }
                        .buttonStyle(BPActionStyle(primary: model.filter == chip.filter))
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

    private static func isCoreRow(_ key: String) -> Bool { key == "movies" || key == "series" || key == "anime" }
    /// Movies, Series and Anime rows under the active chip.
    private var coreRows: [BrowseRow] { model.rows.filter { Self.isCoreRow($0.key) && model.shows(SearchModel.group(ofRow: $0.key)) } }
    /// Franchise and per-addon rows under the active chip.
    private var laterRows: [BrowseRow] { model.rows.filter { !Self.isCoreRow($0.key) && model.shows(SearchModel.group(ofRow: $0.key)) } }

    // bp-search-rows BpChannelCell: a channel from your Live TV sources, Select tunes it.
    private var channelRow: some View {
        VStack(alignment: .leading, spacing: BP.px(10)) {
            Text("Live TV").font(BP.sans(19, .bold)).foregroundStyle(BP.ink).padding(.horizontal, BP.gutter)
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
        case .done where model.settled && model.distinctCount(nil) == 0: BPNote(text: "Nothing found for “\(model.query)”.")
        default: EmptyView()
        }
    }

    private var results: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: BP.rowGap) {
                Color.clear.frame(height: BP.barHeight + BP.px(20))
                if model.status == .idle {
                    // bp-search idle: recent queries as chips, then a "Suggested" row from the hero feed.
                    if !model.recent.isEmpty {
                        VStack(alignment: .leading, spacing: BP.px(10)) {
                            Text("Recent").font(BP.sans(19, .bold)).foregroundStyle(BP.ink).padding(.horizontal, BP.gutter)
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: BP.px(8)) {
                                    ForEach(model.recent, id: \.self) { q in Button(q) { model.query = q }.buttonStyle(BPActionStyle()) }
                                    Button { model.clearRecent() } label: { Image(systemName: "trash") }.buttonStyle(BPActionStyle()).accessibilityLabel("Clear recent searches")
                                }
                                .padding(.horizontal, BP.gutter).padding(.vertical, BP.px(6))
                            }
                            .scrollClipDisabled()
                        }
                        .focusSection()
                    }
                    if !model.suggestions.isEmpty {
                        BPRowView(row: BrowseRow(key: "suggested", title: "Suggested", metas: model.suggestions), onFocus: { spotlight = $0 }, onSelect: { detail = $0 })
                    }
                }
                if model.status != .idle { chipStrip }
                if model.filterStale {
                    // bp-search-empty filterStale
                    BPNote(text: "Nothing in this filter. Choose All to see everything that answered.").padding(.horizontal, BP.gutter)
                }
                if model.filter == .all, let top = spotlight ?? model.topMatch {
                    TopMatchPanel(meta: top).padding(.horizontal, BP.gutter)
                }
                if model.shows(.people) && !model.people.isEmpty {
                    VStack(alignment: .leading, spacing: BP.px(10)) {
                        Text("People").font(BP.sans(19, .bold)).foregroundStyle(BP.ink).padding(.horizontal, BP.gutter)
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
                // use-bp-search slot order: Movies, Series, Anime, Live TV, Collections, Franchise,
                // one row per addon, then "Addons you could install".
                ForEach(coreRows) { row in
                    BPRowView(row: row, onFocus: { spotlight = $0 }, onSelect: { detail = $0 })
                }
                if model.shows(.livetv) && !model.channels.isEmpty { channelRow }
                if model.shows(.collections) && !model.collections.isEmpty { collectionRow }
                ForEach(laterRows) { row in
                    BPRowView(row: row, onFocus: { spotlight = $0 }, onSelect: { detail = $0 })
                }
                if model.shows(.addons) && model.addonHits.contains(where: { $0.transportUrl != nil }) { addonIndexRow }
                Color.clear.frame(height: BP.hintHeight + BP.px(40))
            }
        }
        .frame(maxWidth: .infinity)
        .focusSection()
    }
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
                CollectionItemsOverlay(card: card, onClose: onClose) { item in
                    detail = Meta(id: item.id, type: item.type, name: item.name, poster: item.poster, background: nil, logo: nil, description: nil, releaseInfo: nil, releaseDate: nil, inTheaters: nil, imdbRating: nil, tmdbScore: nil, runtime: nil, genres: nil, adult: nil, isCollection: nil, providerBadge: nil, videos: nil)
                }
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
            card = try? await HarborEngine.shared.call("search.collection", [hit.id, hit.name, hit.image])
            loaded = true
        }
        .fullScreenCover(item: $detail) { m in DetailView(meta: m) }
    }
}
