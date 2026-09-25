import SwiftUI

/// Home / Movies / Shows: spotlight up top, Continue Watching, then the rail of rows.
struct RoomView: View {
    @StateObject private var model: BrowseModel
    @EnvironmentObject private var app: AppModel
    @State private var seeAll: BrowseRow?
    @State private var detail: Meta?
    @State private var quick: Meta?
    /// bp-quick-panel `cwItem`: the panel was opened on a Continue Watching card.
    @State private var quickFromCw = false
    /// bp-cw-row onPress → requestBpPlay(metaId, resumeAt): a card that can name what it would
    /// play opens the detail page playing it (the episode named, so no premiere fallback).
    @State private var cwPlay: CwPlay?
    struct CwPlay: Identifiable { var meta: Meta; var hint: (season: Int, episode: Int)?; var id: String { meta.id } }
    @State private var addonPage: AddonTarget?
    @State private var play: Meta?
    struct AddonTarget: Identifiable { var base: String; var name: String; var logo: String?; var id: String { base } }
    @State private var service: ServiceTarget?
    struct ServiceTarget: Identifiable { var id: String; var name: String }
    @State private var collection: HomeCollectionView.Target?
    /// use-bp-sections: the band focus asks for, and the one on screen once it has settled.
    @State private var bandWanted: HomeBand?
    @State private var band: HomeBand?
    /// bp-live-row `hot`: the focused Live TV cell, and whether that row's player is up.
    @State private var liveHot: LiveRowModel.Cell?
    @State private var livePlaying = false
    @Environment(\.shellFocusNamespace) private var shellNS
    @Namespace private var localNS

    init(room: Room, source: BrowseSource) {
        _model = StateObject(wrappedValue: BrowseModel(room: room, source: source))
    }

    var body: some View {
        ZStack(alignment: .top) {
            // bp-home: a band that owns the backdrop fades the spotlight out (180 ms) and its
            // identity in (300 ms after 140 ms); card-owned bands keep the spotlight.
            SpotlightView(meta: model.spotlight, boxHeight: heroHeight,
                          pips: model.heroCount > 1 && !model.tileHeld ? HeroPips(total: model.heroCount, active: model.heroIndex) : nil,
                          drift: model.room != .anime, awardsCorner: model.room != .anime)
                .opacity(band == nil ? 1 : 0)
                .animation(band == nil ? BP.easeSlow.delay(0.14) : .easeIn(duration: 0.18), value: band == nil)
            if let band {
                HomeBandBackdrop(band: band).transition(.opacity)
            }
            if model.isHomePage {
                LiveHeroPreview(channel: liveHot?.channel, suspended: previewSuspended)
            }
            if let band {
                BandIdentityView(band: band, boxHeight: heroHeight).transition(.opacity)
            }
            if let failed = model.failed {
                VStack(spacing: BP.px(10)) {
                    Text("Couldn't load this room.").font(BP.sans(19, .bold)).foregroundStyle(BP.ink)
                    BPNote(text: failed)
                }
                .padding(.top, BP.px(300)).padding(.horizontal, BP.gutter)
            } else if model.loading && model.rows.isEmpty {
                ProgressView().tint(BP.inkMuted).padding(.top, BP.px(320))
            } else {
                BPRailView(rows: model.rows, onFocus: { m, row in focusTile(m, row: row) },
                           onSelect: { m in
                               if m.id.hasPrefix("service:") { service = ServiceTarget(id: String(m.id.dropFirst(8)), name: m.name) }
                               else if m.id.hasPrefix("addon:") { addonPage = AddonTarget(base: String(m.id.dropFirst(6)), name: m.name, logo: m.providerBadge?.logo) }
                               else if m.id.hasPrefix("collection:tmdb:") {
                                   BPSound.shared.open()
                                   collection = HomeCollectionView.Target(ref: String(m.id.dropFirst(16)), name: m.name, image: m.background)
                               }
                               else { detail = m }
                           },
                           onSeeAll: { row in
                               // bp-collections-row lead: "View all" goes to the Collections tab.
                               if row.key == "collections" { app.room = .collections } else { seeAll = row }
                           },
                           onQuick: { m in
                               // bp-quick-panel acts on a title; band tiles (services, addons, collections) have none.
                               guard !["service", "addon", "collection"].contains(m.type) else { return }
                               BPSound.shared.open(); quickFromCw = false; quick = m
                           }, topInset: heroHeight,
                           restoreRoute: model.restoreKey, entry: model.entry,
                           onHold: { key, held in model.hold(key, held) }) {
                    if model.room == .anime, let hero = model.spotlight, hero.type != "service" {
                        // bp-anime-hero-actions: the focused hero's Resume / Start Watching and More Info.
                        AnimeHeroActionsView(meta: hero, resume: model.continueWatching.first { $0.id == hero.id },
                                             onPlay: { play = $0 }, onInfo: { detail = $0 })
                            .padding(.horizontal, BP.gutter)
                    }
                    if !model.continueWatching.isEmpty {
                        ContinueRowView(items: model.continueWatching,
                                        onFocus: { bandWanted = nil; model.focus(Meta(continue: $0)) }, onSelect: { openContinue($0) },
                                        onQuick: { item in BPSound.shared.open(); quickFromCw = true; quick = Meta(continue: item) },
                                        onHold: { model.hold("cw", $0) })
                    }
                    // bp-home: the Live TV row sits after Continue Watching; empty without playlists.
                    if model.isHomePage {
                        LiveRowView(onOpenGuide: { app.room = .live }, onHot: { cell in
                            liveHot = cell
                            model.hold("live", cell != nil)
                            if let cell { bandWanted = HomeBand.forChannel(cell) }
                            else if bandWanted?.id == .live { bandWanted = nil }
                        }, onPlaying: { livePlaying = $0 })
                    }
                }
                .prefersDefaultFocus(true, in: shellNS ?? localNS)
            }
        }
        .task { await model.load() }
        // Rows arrive after first render; pull focus into them so Select acts on a tile,
        // not on the tab the bar was left on (upstream autofocuses the first row too).
        .onChange(of: model.rows.isEmpty) { _, empty in
            // A restored position needs its row parked and its track scrolled (both lazy) first.
            let wait = model.entry == nil ? 0.05 : 0.3
            if !empty { DispatchQueue.main.asyncAfter(deadline: .now() + wait) { ShellFocus.shared.requestDefault() } }
        }
        // BAND_SETTLE_MS: a new band (or a new cell in it) commits once focus has rested; a later
        // record for the same cell (its posters arriving) replaces it at once.
        .task(id: bandWanted?.key) {
            let next = bandWanted
            if next != nil { try? await Task.sleep(for: HomeBand.settle) }
            guard !Task.isCancelled else { return }
            withAnimation(BP.easeFast) { band = next }
        }
        .onChange(of: bandWanted) { _, next in
            if let next, band?.key == next.key { band = next }
        }
        // Focus left every row (to the top bar): the band lets go. Row hand-offs report the old
        // row's release and the new row's hold in either order, so this waits a beat first.
        .task(id: model.tileHeld || liveHot != nil) {
            guard !model.tileHeld, liveHot == nil, bandWanted != nil else { return }
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, !model.tileHeld, liveHot == nil else { return }
            bandWanted = nil
        }
        .fullScreenCover(item: $seeAll) { row in
            CatalogPageView(room: model.room, row: row)
        }
        .fullScreenCover(item: $detail) { m in DetailView(meta: m) }
        .fullScreenCover(item: $quick) { m in QuickPanelView(meta: m, fromContinueWatching: quickFromCw) }
        .fullScreenCover(item: $service) { t in ServicePageView(service: t.id, name: t.name) }
        .fullScreenCover(item: $addonPage) { t in AddonPageView(base: t.base, name: t.name, logo: t.logo) }
        .fullScreenCover(item: $play) { m in DetailView(meta: m, autoPlay: true) }
        .fullScreenCover(item: $cwPlay) { c in DetailView(meta: c.meta, autoPlay: true, episodeHint: c.hint) }
        .fullScreenCover(item: $collection) { t in HomeCollectionView(target: t) { collection = nil } }
    }

    /// bp-cw-row.tsx BpCwCard onPress: resume in one press when the card can name what it would
    /// play (bpCwResume), else the detail page, which takes its time resolving the right episode.
    private func openContinue(_ item: ContinueItem) {
        let meta = Meta(continue: item)
        switch item.press {
        case .detail: detail = meta
        case .resumeMovie: cwPlay = CwPlay(meta: meta, hint: nil)
        case .resumeEpisode(let s, let e): cwPlay = CwPlay(meta: meta, hint: (season: s, episode: e))
        }
    }

    /// A rail tile took focus. On Home, a tile of a band-owned row (services, addons, collections)
    /// raises that band instead of the spotlight; any other tile hands the hero back to the title.
    private func focusTile(_ m: Meta, row: BrowseRow) {
        if model.isHomePage, let id = HomeBand.band(forRow: row.key) {
            let record = HomeBand.forTile(m, in: id)
            bandWanted = record
            if id == .services || id == .addons { loadPosters(for: record, meta: m) }
            return
        }
        bandWanted = nil
        if m.type != "service" { model.focus(m) }
    }

    /// The band mosaic's posters resolve long after the focus that asked for them, so the record
    /// is republished when they land (bp-service-row / bp-addon-row).
    private func loadPosters(for record: HomeBand, meta: Meta) {
        Task {
            let p = ProfilesStore.shared.active
            let posters: [String]
            if record.id == .services {
                posters = (try? await HarborEngine.shared.call("services.posters", [String(meta.id.dropFirst(8)), p?.id ?? "default", p?.linked ?? true])) ?? []
            } else {
                posters = (try? await HarborEngine.shared.call("addonsRoom.bandPosters", [String(meta.id.dropFirst(6))])) ?? []
            }
            guard !posters.isEmpty, bandWanted?.key == record.key else { return }
            bandWanted?.posters = posters
        }
    }

    /// bp-live-hero `mountVideo`: never while this row's player or any page over Home is up.
    private var previewSuspended: Bool {
        livePlaying || detail != nil || quick != nil || seeAll != nil || service != nil || addonPage != nil || play != nil || cwPlay != nil
            || collection != nil || app.room != .home
    }

    /// Home hero box: clamp(260px, 34vh, 380px) − 56px give (bp-tokens.ts:227-228, 172-175).
    private var heroHeight: CGFloat { BP.px(260 - 56) + BP.barHeight }
}

extension Meta {
    init(continue c: ContinueItem) {
        self.init(id: c.id, type: c.type, name: c.name, poster: c.poster, background: c.background, logo: c.logo,
                  description: nil, releaseInfo: nil, releaseDate: nil, inTheaters: nil, imdbRating: nil, tmdbScore: nil,
                  runtime: nil, genres: nil, adult: nil, isCollection: nil, providerBadge: nil, videos: nil)
    }
}


/// The service page (bp-service.tsx): the same room layout over the service's category rows.
struct ServicePageView: View {
    let service: String
    let name: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .topLeading) {
            BPAmbientBackground()
            RoomView(room: .home, source: ServiceBrowseSource(service: service))
            Text(name).font(BP.display(26)).foregroundStyle(BP.ink).padding(.horizontal, BP.gutter).padding(.top, BP.px(20))
        }
        .onExitCommand { dismiss() }
    }
}
