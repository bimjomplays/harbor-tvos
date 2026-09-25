import SwiftUI

/// Discover room (bp-discover.tsx): Discovery Queue, Awards, Genres, Voyages, Collections and Top
/// People bands, then the "Picked for you" rails.
struct DiscoverView: View {
    @EnvironmentObject private var app: AppModel
    @StateObject private var model = DiscoverModel()
    /// A tab the profile's PIN locks (Profiles/ParentalGate.swift): the chip that leads to it is not offered.
    @ObservedObject private var parental = ParentalGate.shared
    @State private var detail: Meta?
    @State private var awardDetail: DiscoverModel.Awards.Summary?
    @State private var animeAward: DiscoverModel.AnimeAwardTile?
    @State private var genrePage: BrowseRow?
    @State private var queueOpen = false
    @State private var voyageOpen = false
    /// bp-collections-band.tsx: a curated collection card opens its page (tmdb-collection).
    @State private var collection: HomeCollectionView.Target?
    /// The lead band holding the ring ("queue", "awards", "genres", "voyage", "collections", "people").
    @State private var leadHeld: String?
    /// (open-items sweep) A Try again that worked hands the ring to the Discovery Queue band (the
    /// button under it went away and the ring fell to the tab bar).
    @State private var seedQueue = false
    /// (parity pass 3, V3) bp-discover `tint`: the focused cell's colour, keyed by the band that
    /// supplied it (a Genres colour never follows the ring into another band).
    /// (review 21) Held in a box only DiscoverWash observes: as @State here, every step along the
    /// Genres or Awards band re-ran this whole page's body (every band and rail) to change one colour.
    @State private var washTint = DiscoverWashTint()

    var body: some View {
        ZStack(alignment: .top) {
            // (layout pass) The art only. The rail parks a focused row just under the top bar (topInset
            // below), right where the spotlight's title, chips and overview were bottom-anchored, and
            // it draws after them: the focused title's copy sat behind that row's header and posters.
            // bp-discover has no title copy over its rail either (its header names the band).
            SpotlightView(meta: model.spotlight, boxHeight: BP.px(160) + BP.barHeight, layer: .backdrop)
                .opacity(model.spotlight == nil ? 0 : 1)
            // bp-discover-wash: the band holding the ring washes the page in its focused cell's
            // colour (a "Picked for you" rail, or nothing held, is the 180° accent wash).
            DiscoverWash(tint: washTint, bandId: leadHeld ?? "")
            if let failed = model.failed {
                VStack(spacing: BP.px(10)) {
                    Text("Couldn't load Discover").font(BP.sans(19, .bold)).foregroundStyle(BP.ink)
                    BPNote(text: failed)
                    // (device-flow pass) The failure had nothing to press: the room stayed empty
                    // until the app was restarted or the tab reopened.
                    Button("Try again") {
                        seedQueue = true
                        Task { await model.load() }
                    }
                        .buttonStyle(BPActionStyle(primary: true, busy: model.loading))
                        .padding(.top, BP.px(6))
                }
                .padding(.top, BP.px(300)).padding(.horizontal, BP.gutter)
            } else if model.build == nil {
                ProgressView().tint(BP.inkMuted).padding(.top, BP.px(320))
            } else {
                // bp-discover.tsx: each "Picked for you" rail leads to its tab (BpRowLead action
                // "All shows" / "All movies", tab shows / movies). (device-flow pass) The rails had
                // no way on from their header.
                BPRailView(rows: model.rows, onFocus: { m, _ in model.spotlight = m }, onSelect: { detail = $0 },
                           onSeeAll: { row in app.room = Self.isSeries(row) ? .shows : .movies },
                           seeAllLabel: { row in Self.isSeries(row) ? "All shows" : "All movies" },
                           // (home device pass) Movies or Shows locked by the profile's PIN: ShellView
                           // sends a locked room straight back to Home, so the chip bounced the viewer
                           // off Discover. A locked tab is off the bar (bp-top-bar visibleTabs), and its
                           // way in from a rail goes with it.
                           seeAllShown: { row in !parental.hides(Self.isSeries(row) ? Room.shows : Room.movies) },
                           topInset: BP.barHeight + BP.px(10),
                           // bp-discover.tsx lead.tab: Left at a rail's start lands on All shows / All movies' tab.
                           rowTab: { row in Self.isSeries(row) ? Room.shows : Room.movies }) {
                    // (browse open-items pass) Each lead section parks like a rail row when it takes the
                    // ring (use-bp-rail; the bands are rail rows in bp-discover). Up from a parked rail
                    // row left the scroll to tvOS, which only brought the focused tile into view: the
                    // section's header stayed under the top bar. The lead is taller than the screen,
                    // so scrolling back to the rail top would push the focused band off it instead.
                    section("queue", "Discover", "Discovery Queue", "One pick at a time, full screen, until something lands.") {
                        QueueBandView(queue: model.build?.queue, onOpen: { queueOpen = true }, onHold: { hold("queue", $0) },
                                      seedFocus: seedQueue, onSeeded: { seedQueue = false })
                    }
                    if let aw = model.awards, !aw.summaries.isEmpty {
                        section("awards", "Discover", "Awards", aw.overview.span.isEmpty ? "Every winner Harbor ships, browsable offline by year and category." : T("%lld awards, %lld winners, %@, all offline", aw.overview.bodies, aw.overview.wins, aw.overview.span)) {
                            AwardsBandView(summaries: aw.summaries, anime: model.animeAwards,
                                           onOpen: { awardDetail = $0 }, onOpenAnime: { animeAward = $0 },
                                           onHold: { hold("awards", $0) },
                                           onTint: { washTint.set(DiscoverWash.Tint(band: "awards", colour: $0)) })
                        }
                    }
                    // bp-discover.tsx t("{n} shelves, …", { n: BP_GENRES.length }): the literal "18 …"
                    // matched no catalog key and stayed English.
                    section("genres", "Discover", "Genres", T("%lld shelves, one press into any of them", model.build?.genres.count ?? 18)) {
                        GenresBandView(genres: model.build?.genres ?? [], art: model.genreArt, onOpen: { genre in
                            genrePage = BrowseRow(key: "genre:\(genre)", title: T(genre), metas: [])
                        }, onFocus: {
                            Task { await model.loadGenreArt() }
                        }, onHold: { hold("genres", $0) },
                        onTint: { washTint.set(DiscoverWash.Tint(band: "genres", colour: $0)) })
                    }
                    // discover.tsx: the Voyages banner follows the browse tiles, once its pool holds three.
                    if let pool = model.build?.voyagePool, pool.count >= 3 {
                        VoyageBannerView(snapshot: model.voyage, pool: pool, onOpen: { voyageOpen = true }, onHold: { hold("voyage", $0) })
                            .modifier(BPRailLeadMark(key: Self.leadKey("voyage"), held: leadHeld == "voyage"))
                    }
                    // bp-discover.tsx:240-246: the Collections band follows Genres (only with a TMDB
                    // key, showCollections). Until the curated row answers it holds its place with
                    // placeholders (bp-collections-band skeletons), so nothing below it jumps; one
                    // that answered empty goes away (settled && entries.length === 0).
                    if model.showsCollections && !(model.collectionsSettled && model.collections.isEmpty) {
                        section("collections", "Discover", "Collections", "Sagas and series, gathered in the order they were meant to be watched.") {
                            CollectionsBandView(cards: model.collections, settled: model.collectionsSettled,
                                                onOpen: { openCollection($0) },
                                                onAll: collectionsLink,
                                                onHold: { hold("collections", $0) })
                        }
                    }
                    // (discover/onboarding pass 2) bp-discover.tsx entries: queue, awards, genres,
                    // collections, people, then the rails. Top People sat second, and it is the last
                    // lead to arrive (a TMDB read behind the awards install), so it dropped in above
                    // Awards and Genres after the viewer had walked down to them and pushed the band
                    // holding the ring down the screen.
                    if !model.people.isEmpty {
                        section("people", "Discover", "Top People", T("Top %lld, ranked by the work they left behind", model.people.count)) {
                            PeopleBandView(people: model.people, onHold: { hold("people", $0) })
                        }
                    }
                }
            }
        }
        .task { await model.load() }
        // Beside the rest of Discover's reads: the curated row can take a few seconds to resolve.
        .task { await model.loadCollections() }
        .fullScreenCover(item: $detail) { m in DetailView(meta: m) }
        .fullScreenCover(item: $collection) { t in HomeCollectionView(target: t) { collection = nil } }
        .fullScreenCover(item: $awardDetail) { a in
            // bp-award BpAwardWinner: a keyless press goes to Settings (pushBigPicture kind "settings").
            AwardDetailView(summary: a, onOpenSettings: {
                awardDetail = nil
                app.room = .settings
            })
        }
        .fullScreenCover(item: $animeAward) { a in AnimeAwardView(sources: model.animeAwards, initial: a.id) }
        .fullScreenCover(item: $genrePage) { r in CatalogPageView(room: .discover, row: r) }
        .fullScreenCover(isPresented: $queueOpen, onDismiss: { Task { await model.reloadQueue() } }) { QueueDeckView() }
        .fullScreenCover(isPresented: $voyageOpen, onDismiss: { Task { await model.loadVoyage() } }) { VoyageView() }
    }

    /// bp-discover.tsx `series = rail.metas[0]?.type === "series"`.
    private static func isSeries(_ row: BrowseRow) -> Bool { row.metas.first?.type == "series" }

    /// bp-collections-band onOpen: a TMDB entry opens its collection page (as Home's row does).
    private func openCollection(_ m: Meta) {
        let prefix = "collection:tmdb:"
        guard m.id.hasPrefix(prefix) else { return }
        BPSound.shared.open()
        collection = HomeCollectionView.Target(ref: String(m.id.dropFirst(prefix.count)), name: m.name, image: m.background)
    }

    /// bp-collections-band BpLeadTile "View all" → pushBigPicture({ kind: "collections" }). A
    /// Collections tab locked by the profile's PIN is off the bar, and its way in goes with it.
    private var collectionsLink: (() -> Void)? {
        guard !parental.hides(Room.collections) else { return nil }
        return { app.room = .collections }
    }

    /// A lead section's park key; never the same as a rail row's key.
    private static func leadKey(_ key: String) -> String { "discover-lead:" + key }

    /// A band gained (true) or lost (false) the ring. Hand-offs between bands report the old
    /// band's release and the new band's hold in either order.
    private func hold(_ key: String, _ held: Bool) {
        if held { leadHeld = key } else if leadHeld == key { leadHeld = nil }
    }

    private func section<C: View>(_ key: String, _ eyebrow: String, _ title: String, _ blurb: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: BP.px(10)) {
            VStack(alignment: .leading, spacing: BP.px(2)) {
                Text(T(eyebrow)).font(BP.sans(11, .bold)).foregroundStyle(BP.accent).textCase(.uppercase).tracking(1)
                Text(T(title)).font(BP.sans(19, .bold)).foregroundStyle(BP.ink).accessibilityAddTraits(.isHeader)
                Text(T(blurb)).font(BP.sans(13)).foregroundStyle(BP.inkMuted)
            }
            .padding(.horizontal, BP.gutter)
            content()
        }
        .modifier(BPRailLeadMark(key: Self.leadKey(key), held: leadHeld == key))
    }
}

/// bp-collections-band.tsx: the curated TMDB collections as 16:9 cards (bp-collection-card), six
/// quiet placeholders while the row resolves, and last the "View all" / "Collections" lead tile
/// (bp-lead-tile: the band's way in closes the track).
struct CollectionsBandView: View {
    let cards: [Meta]
    let settled: Bool
    let onOpen: (Meta) -> Void
    /// The lead tile's destination (the Collections tab); nil hides the tile.
    var onAll: (() -> Void)? = nil
    /// The band gained (true) or lost (false) the ring (the rail parks it).
    var onHold: ((Bool) -> Void)? = nil
    @FocusState private var focusedCard: String?
    private static let placeholders = 6

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: BP.trackGap) {
                ForEach(Array(cards.uniquedById().enumerated()), id: \.element.id) { i, m in
                    Button { onOpen(m) } label: {
                        BPTileView(meta: m, shape: .collection, focused: focusedCard == m.id)
                    }
                    .buttonStyle(BPTileStyle())
                    .focused($focusedCard, equals: m.id)
                    .accessibilityIdentifier("collection-card-\(i)")
                    .zIndex(focusedCard == m.id ? 1 : 0)
                }
                if !settled && cards.isEmpty {
                    // Not focusable: nothing to act on yet.
                    ForEach(0..<Self.placeholders, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: BP.rXS, style: .continuous)
                            .fill(BP.panel)
                            .frame(width: BPTileView.collectionSize.width, height: BPTileView.collectionSize.height)
                            .accessibilityHidden(true)
                    }
                }
                if let onAll {
                    Button {
                        BPSound.shared.click()
                        onAll()
                    } label: {
                        VStack(alignment: .leading, spacing: BP.px(2)) {
                            Spacer(minLength: 0)
                            Text(T("View all")).font(BP.display(17)).foregroundStyle(BP.ink).lineLimit(2)
                            Text(T("Collections")).font(BP.sans(10, .bold)).textCase(.uppercase).tracking(BP.px(1.5)).foregroundStyle(BP.inkSubtle).lineLimit(1)
                        }
                        .padding(BP.px(14))
                        .frame(width: BPTileView.collectionSize.width, height: BPTileView.collectionSize.height, alignment: .topLeading)
                        .background(RoundedRectangle(cornerRadius: BP.rMD, style: .continuous).fill(BP.panel))
                        .overlay(RoundedRectangle(cornerRadius: BP.rMD, style: .continuous).stroke(BP.edge, lineWidth: 1))
                    }
                    .buttonStyle(BPTileStyle(radius: BP.rMD))
                    .focused($focusedCard, equals: "lead:collections")
                    .accessibilityIdentifier("collections-view-all")
                    // bp-lead-tile aria-label `${label}, ${action}`.
                    .accessibilityLabel(Text(verbatim: "\(T("View all")), \(T("Collections"))"))
                }
            }
            .padding(.horizontal, BP.gutter).padding(.vertical, BP.px(14))
        }
        .scrollClipDisabled()
        .focusSection()
        .onChange(of: focusedCard != nil) { _, held in onHold?(held) }
    }
}

/// queue/bp-queue-band.tsx: one wide panel, blurred bed art, a fan of the next four posters.
struct QueueBandView: View {
    let queue: DiscoverModel.Build.Queue?
    var onOpen: () -> Void = {}
    /// The band gained (true) or lost (false) the ring (the rail parks it).
    var onHold: ((Bool) -> Void)? = nil
    /// (open-items sweep) Take the ring when the band appears (after Discover's Try again).
    var seedFocus = false
    var onSeeded: (() -> Void)? = nil
    @FocusState private var focused: Bool
    private let height = BP.px(150)

    var body: some View {
        Button { onOpen() } label: {
            ZStack(alignment: .leading) {
                if let bed = queue?.backdrop ?? queue?.posters.first {
                    RemoteImage(url: bed).blur(radius: 18).opacity(queue?.backdrop == nil ? 0.45 : 0.8)
                }
                LinearGradient(colors: [BP.panel, BP.panel.opacity(0.6), .clear], startPoint: .leading, endPoint: .trailing)
                    .flipsForRightToLeftLayoutDirection(true)   // bp-queue-band.tsx --bp-scrim-side under rtl
                HStack(spacing: BP.px(24)) {
                    VStack(alignment: .leading, spacing: BP.px(6)) {
                        Text("Discovery Queue").font(BP.display(26)).foregroundStyle(BP.ink)
                        Text(T(line)).font(BP.sans(15, .semibold)).foregroundStyle(BP.inkMuted)
                        if let n = queue?.total, queue?.status == "ready" {
                            Text("\(n) waiting").font(BP.sans(13)).foregroundStyle(BP.inkSubtle)
                        }
                    }
                    Spacer()
                    ZStack {
                        ForEach(Array((queue?.posters ?? []).prefix(4).enumerated()), id: \.offset) { i, url in
                            RemoteImage(url: url)
                                .frame(width: BP.px(76), height: BP.px(114))
                                .clipShape(RoundedRectangle(cornerRadius: BP.px(6), style: .continuous))
                                .rotationEffect(.degrees(Double(i) * 18 - 27), anchor: .bottom)
                                .offset(x: CGFloat(i) * BP.px(18))
                                .opacity([1, 0.82, 0.6, 0.38][i])
                                .zIndex(Double(4 - i))
                        }
                    }
                    .frame(width: BP.px(200), height: height)
                    .padding(.trailing, BP.px(26))
                }
                .padding(.leading, BP.px(26))
            }
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background(BP.panel)
            .clipShape(RoundedRectangle(cornerRadius: BP.rLG, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: BP.rLG, style: .continuous).stroke(BP.edge, lineWidth: 1))
        }
        .buttonStyle(BPTileStyle(radius: BP.rLG))
        .focused($focused)
        .padding(.horizontal, BP.gutter)
        .padding(.vertical, BP.px(14))
        .accessibilityIdentifier("queue-band")
        .onChange(of: focused) { _, held in onHold?(held) }
        .onAppear {
            guard seedFocus else { return }
            onSeeded?()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { focused = true }
        }
    }

    private var line: String {
        switch queue?.status {
        case "ready": return "Open the queue"
        case "empty": return "Nothing left in today's picks"
        case "nokey": return "Add a TMDB key for tonight's picks"
        case "unreachable": return "No picks loaded. TMDB might be unreachable."
        default: return "Building tonight's queue…"
        }
    }
}

/// bp-genre-tiles.tsx: 5:4 tiles on the genre's palette with up to three skewed backdrops.
struct GenresBandView: View {
    let genres: [DiscoverModel.Build.Genre]
    let art: [String: [Meta]]
    /// Fired the first time any genre tile takes focus (art is fetched lazily, as upstream does).
    var onOpen: (String) -> Void = { _ in }
    let onFocus: () -> Void
    /// The band gained (true) or lost (false) the ring (the rail parks it).
    var onHold: ((Bool) -> Void)? = nil
    /// bp-genre-tiles BpGenreTile onFocus: the genre's palette.from washes the page.
    var onTint: ((String) -> Void)? = nil
    @FocusState private var focusedGenre: String?
    private let cell = BP.px(178)

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: BP.px(9)) {
                // bp-genre-tiles: a "Surprise me" lead tile opens a random shelf.
                if let first = genres.first {
                    Button { onOpen(genres.randomElement()?.genre ?? first.genre) } label: {
                        VStack(alignment: .leading) {
                            Image(systemName: "dice").font(.system(size: BP.px(26), weight: .semibold)).foregroundStyle(BP.ink).accessibilityHidden(true)
                            Spacer()
                            Text("Surprise me").font(BP.sans(15, .bold)).foregroundStyle(BP.ink)
                        }
                        .padding(BP.px(14))
                        .frame(width: cell, height: cell * 0.8, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: BP.rMD, style: .continuous).fill(BP.panel2))
                        .overlay(RoundedRectangle(cornerRadius: BP.rMD, style: .continuous).stroke(BP.edge2, lineWidth: 1))
                    }
                    .buttonStyle(BPTileStyle(radius: BP.rMD))
                    .focused($focusedGenre, equals: "__surprise")
                }
                ForEach(genres, id: \.genre) { g in
                    Button { onOpen(g.genre) } label: { tile(g) }
                        .buttonStyle(BPTileStyle(radius: BP.rMD))
                        .focused($focusedGenre, equals: g.genre)
                        .accessibilityIdentifier("genre-\(g.genre)")
                }
            }
            .padding(.horizontal, BP.gutter).padding(.vertical, BP.px(14))
        }
        .scrollClipDisabled()
        .focusSection()
        .onChange(of: focusedGenre) { _, g in
            if g != nil { onFocus() }
            // The "Surprise me" lead tile has no palette and leaves the wash as it was.
            if let g, let genre = genres.first(where: { $0.genre == g }) { onTint?(genre.from) }
        }
        .onChange(of: focusedGenre != nil) { _, held in onHold?(held) }
    }

    private func tile(_ g: DiscoverModel.Build.Genre) -> some View {
        let from = Color(oklch: g.from) ?? BP.panel2
        let to = Color(oklch: g.to) ?? BP.void_
        let ink = Color(oklch: g.ink) ?? BP.ink
        return ZStack(alignment: .bottomLeading) {
            from
            if let metas = art[g.genre], !metas.isEmpty {
                HStack(spacing: 0) {
                    ForEach(Array(metas.prefix(3).enumerated()), id: \.offset) { i, m in
                        RemoteImage(url: m.background ?? m.poster)
                            .frame(width: cell / 3, height: cell * 0.8)
                            .clipped()
                            .transformEffect(CGAffineTransform(a: 1, b: 0, c: -0.14, d: 1, tx: CGFloat(i - 1) * 6, ty: 0))
                    }
                }
                to.blendMode(.multiply)
            }
            LinearGradient(colors: [.clear, to], startPoint: .center, endPoint: .bottom).frame(height: cell * 0.8 * 0.4).frame(maxHeight: .infinity, alignment: .bottom)
            Text(T(g.genre)).font(BP.display(16)).foregroundStyle(ink).padding(BP.px(14))
        }
        .frame(width: cell, height: cell * 0.8)
        .clipShape(RoundedRectangle(cornerRadius: BP.rMD, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: BP.rMD, style: .continuous).stroke(BP.edge, lineWidth: 1))
    }
}


/// bp-award-tiles.tsx BpAwardsBand: one tile per award body on its tint, with wins and years; past
/// a divider one BpAnimeAwardTile per bundled anime award source ("{n} winners"); last the
/// "Open the Oscars" lead tile.
struct AwardsBandView: View {
    let summaries: [DiscoverModel.Awards.Summary]
    var anime: [DiscoverModel.AnimeAwardTile] = []
    let onOpen: (DiscoverModel.Awards.Summary) -> Void
    var onOpenAnime: (DiscoverModel.AnimeAwardTile) -> Void = { _ in }
    /// The band gained (true) or lost (false) the ring (the rail parks it).
    var onHold: ((Bool) -> Void)? = nil
    /// bp-award-tiles BpAwardTile onFocus={onTint}: an award tile's tint washes the page.
    var onTint: ((String) -> Void)? = nil
    @FocusState private var focusedTile: String?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: BP.px(9)) {
                awardTiles
                if !anime.isEmpty {
                    // BpChipDivider between the classic bodies and the anime sources.
                    Rectangle().fill(BP.edge2).frame(width: 1, height: BP.px(60)).padding(.horizontal, BP.px(6))
                    ForEach(anime) { a in
                        Button { onOpenAnime(a) } label: {
                            VStack(alignment: .leading, spacing: BP.px(4)) {
                                Image(systemName: "trophy.fill").font(.system(size: BP.px(20), weight: .semibold)).foregroundStyle(BP.accent).accessibilityHidden(true)
                                Spacer(minLength: 0)
                                Text(a.name).font(BP.display(14)).foregroundStyle(BP.ink).lineLimit(2)
                                Text("\(a.wins) winners").font(BP.sans(10, .bold)).textCase(.uppercase).tracking(BP.px(1.5)).foregroundStyle(BP.inkSubtle).lineLimit(1)
                            }
                            .padding(BP.px(14))
                            .frame(width: BP.px(178), height: BP.px(120), alignment: .topLeading)
                            .background(RoundedRectangle(cornerRadius: BP.rMD, style: .continuous).fill(BP.panel))
                            .overlay(RoundedRectangle(cornerRadius: BP.rMD, style: .continuous).stroke(BP.edge, lineWidth: 1))
                        }
                        .buttonStyle(BPTileStyle(radius: BP.rMD))
                        .focused($focusedTile, equals: "anime:" + a.id)
                        .accessibilityIdentifier("anime-award-\(a.id)")
                    }
                }
                // BpLeadTile "Open the Oscars" (action "Awards"): the Oscars award page.
                if let oscars = summaries.first(where: { $0.type == "oscar" }) ?? summaries.first {
                    Button { onOpen(oscars) } label: {
                        VStack(alignment: .leading, spacing: BP.px(4)) {
                            Text("Awards").font(BP.sans(10, .bold)).textCase(.uppercase).tracking(BP.px(1.5)).foregroundStyle(BP.inkSubtle)
                            Spacer(minLength: 0)
                            Text("Open the Oscars").font(BP.display(17)).foregroundStyle(BP.ink).lineLimit(2)
                        }
                        .padding(BP.px(14))
                        .frame(width: BP.px(178), height: BP.px(120), alignment: .topLeading)
                        .background(RoundedRectangle(cornerRadius: BP.rMD, style: .continuous).fill(Color(oklch: oscars.tint) ?? Color(css: oscars.tint) ?? BP.panel2).opacity(0.55))
                        .overlay(RoundedRectangle(cornerRadius: BP.rMD, style: .continuous).stroke(BP.edge2, lineWidth: 1))
                    }
                    .buttonStyle(BPTileStyle(radius: BP.rMD))
                    .focused($focusedTile, equals: "lead:oscars")
                }
            }
            .padding(.horizontal, BP.gutter).padding(.vertical, BP.px(14))
        }
        .scrollClipDisabled()
        .focusSection()
        .onChange(of: focusedTile != nil) { _, held in onHold?(held) }
        .onChange(of: focusedTile) { _, key in
            // Only the award bodies tint (the anime tiles and the lead tile leave the wash as it was).
            guard let key, key.hasPrefix("award:") else { return }
            let type = String(key.dropFirst("award:".count))
            if let summary = summaries.first(where: { $0.type == type }) { onTint?(summary.tint) }
        }
    }

    private var awardTiles: some View {
        ForEach(summaries) { a in
            Button { onOpen(a) } label: {
                VStack(alignment: .leading, spacing: BP.px(6)) {
                    Text(a.shorthand).font(BP.display(22)).foregroundStyle(BP.ink)
                    Text(a.title).font(BP.sans(12, .semibold)).foregroundStyle(BP.ink.opacity(0.85)).lineLimit(2)
                    Spacer(minLength: 0)
                    Text("\(a.wins) winners · \(a.span)").font(BP.sans(11)).foregroundStyle(BP.ink.opacity(0.7))
                }
                .padding(BP.px(14))
                .frame(width: BP.px(178), height: BP.px(120), alignment: .topLeading)
                .background(RoundedRectangle(cornerRadius: BP.rMD, style: .continuous).fill(Color(oklch: a.tint) ?? Color(css: a.tint) ?? BP.panel2))
                .overlay(RoundedRectangle(cornerRadius: BP.rMD, style: .continuous).fill(LinearGradient(colors: [.clear, .black.opacity(0.35)], startPoint: .top, endPoint: .bottom)))
            }
            .buttonStyle(BPTileStyle(radius: BP.rMD))
            .focused($focusedTile, equals: "award:" + a.type)
            .accessibilityIdentifier("award-\(a.type)")
        }
    }
}

/// bp-people-band: 2:3 portrait cards with the rank chip (top-start), the name and the sub line
/// ("{n} award wins", else the first top title), closed by the "Start at number one" lead tile
/// (parity pass 3, V3; the band drew rank-and-name circles).
struct PeopleBandView: View {
    let people: [DiscoverModel.Person]
    /// The band gained (true) or lost (false) the ring (the rail parks it).
    var onHold: ((Bool) -> Void)? = nil
    /// bp-people-band: Select opens the person page (pushBigPicture kind "person").
    @State private var person: DiscoverModel.Person?
    @FocusState private var focusedPerson: Int?
    /// bp-people-band BOX { min: 124, vw: 10, max: 196 } at 1920: 192 pt.
    private let cell = BP.px(114)
    /// The lead tile's focus id (never a TMDB person id).
    private static let leadId = -1

    var body: some View {
        let shown: [DiscoverModel.Person] = people.uniquedById()   // (bug pass) TMDB pages can repeat a person
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: BP.px(12)) {
                ForEach(shown) { p in
                    Button {
                        BPSound.shared.click()
                        person = p
                    } label: { personCell(p) }
                    .buttonStyle(BPTileStyle(radius: BP.rMD))
                    .focused($focusedPerson, equals: p.id)
                    // bp-people-band aria-label={person.name}.
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(verbatim: p.name))
                }
                // BpLeadTile label "Start at number one", action "Top People": the first person's page.
                if let first = shown.first {
                    Button {
                        BPSound.shared.click()
                        person = first
                    } label: {
                        VStack(alignment: .leading, spacing: BP.px(2)) {
                            Spacer(minLength: 0)
                            Text(T("Start at number one")).font(BP.display(17)).foregroundStyle(BP.ink).lineLimit(2)
                            Text(T("Top People")).font(BP.sans(10, .bold)).textCase(.uppercase).tracking(BP.px(1.5)).foregroundStyle(BP.inkSubtle).lineLimit(1)
                        }
                        .padding(BP.px(14))
                        .frame(width: cell, height: cell * 1.5, alignment: .topLeading)
                        .background(RoundedRectangle(cornerRadius: BP.rMD, style: .continuous).fill(BP.panel))
                        .overlay(RoundedRectangle(cornerRadius: BP.rMD, style: .continuous).stroke(BP.edge, lineWidth: 1))
                    }
                    .buttonStyle(BPTileStyle(radius: BP.rMD))
                    .focused($focusedPerson, equals: Self.leadId)
                    // bp-lead-tile aria-label `${label}, ${action}`.
                    .accessibilityLabel(Text(verbatim: "\(T("Start at number one")), \(T("Top People"))"))
                }
            }
            .padding(.horizontal, BP.gutter).padding(.vertical, BP.px(14))
        }
        .scrollClipDisabled()
        .focusSection()
        .onChange(of: focusedPerson != nil) { _, held in onHold?(held) }
        .fullScreenCover(item: $person) { p in PersonView(personId: p.id, name: p.name) }
    }

    private func personCell(_ p: DiscoverModel.Person) -> some View {
        let wins: Int = p.majorAwardWins ?? 0
        let sub: String = wins > 0 ? T("%lld award wins", wins) : (p.topTitle ?? "")
        return VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                ZStack {
                    BP.panel2
                    if let portrait = p.portrait {
                        RemoteImage(url: portrait)
                    } else {
                        Image(systemName: "person").font(.system(size: BP.px(22), weight: .regular)).foregroundStyle(BP.inkSubtle)
                    }
                }
                .frame(width: cell, height: cell * 1.5)
                .clipped()
                Text("\(p.rank)").font(BP.sans(10, .bold)).foregroundStyle(BP.ink).monospacedDigit()
                    .padding(.horizontal, BP.px(7)).padding(.vertical, BP.px(2))
                    .background(Capsule().fill(BP.void_.opacity(0.85)))
                    .padding(BP.px(7))
            }
            VStack(alignment: .leading, spacing: BP.px(2)) {
                Text(p.name).font(BP.sans(12, .semibold)).foregroundStyle(BP.ink).lineLimit(1)
                Text(sub).font(BP.sans(10.5, .medium)).foregroundStyle(BP.inkSubtle).lineLimit(1)
            }
            .padding(BP.px(8))
            .frame(width: cell, alignment: .leading)
        }
        .frame(width: cell)
        .background(BP.panel)
        .clipShape(RoundedRectangle(cornerRadius: BP.rMD, style: .continuous))
    }
}

/// (review 21) DiscoverView's wash colour, set from the Awards / Genres focus callbacks. DiscoverView
/// keeps it in @State (which does not observe a reference), so a new colour re-renders the wash alone.
final class DiscoverWashTint: ObservableObject {
    @Published private(set) var tint: DiscoverWash.Tint?

    func set(_ next: DiscoverWash.Tint) {
        if tint != next { tint = next }
    }
}

/// bp-discover-wash.tsx: each Discover band reads as its own portal while the page stays one
/// surface. The wash is the only thing that changes: a radial bloom from the top-start corner and a
/// linear wash at the band's own angle, both in the focused cell's colour (the accent when the band
/// supplied none). A new colour or angle crossfades rather than interpolating the gradients.
/// (parity pass 3, V3) The port's page and spotlight art stand in for upstream's BASE layer.
struct DiscoverWash: View {
    struct Tint: Equatable { var band: String; var colour: String }
    /// (review 21) The focused cell's colour (DiscoverWashTint); only this view re-renders on it.
    @ObservedObject var tint: DiscoverWashTint
    let bandId: String

    /// bp-discover `tint && tint.band === band?.key ? tint.colour : null`, as a colour.
    private var colour: Color? {
        guard let t = tint.tint, t.band == bandId else { return nil }
        let parsed: Color? = Color(oklch: t.colour) ?? Color(css: t.colour)
        return parsed
    }

    /// bp-discover-wash BAND_ANGLE (CSS degrees; anything else 180deg).
    private static let angles: [String: Double] = ["queue": 120, "awards": 140, "genres": 200, "collections": 160, "people": 220]

    private struct Wash: Hashable {
        var colour: Color
        var angle: Double
    }

    var body: some View {
        let wash = Wash(colour: colour ?? BP.accent, angle: Self.angles[bandId] ?? 180)
        ZStack {
            layer(wash)
                .id(wash)
                .transition(.opacity)
        }
        .animation(BP.easeSlow, value: wash)
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// washOf: radial-gradient(120% 78% at 12% 0%, colour 17% → transparent 58%) over
    /// linear-gradient(angle, colour 9% → transparent 46%).
    private func layer(_ w: Wash) -> some View {
        GeometryReader { g in
            let size: CGSize = g.size
            let rad: Double = w.angle * Double.pi / 180
            let dx: Double = sin(rad)
            let dy: Double = -cos(rad)
            let half: Double = 0.5 * (abs(dx) + abs(dy))
            let start = UnitPoint(x: 0.5 - dx * half, y: 0.5 - dy * half)
            let end = UnitPoint(x: 0.5 + dx * half, y: 0.5 + dy * half)
            ZStack(alignment: .topLeading) {
                LinearGradient(stops: [.init(color: w.colour.opacity(0.09), location: 0), .init(color: .clear, location: 0.46)],
                               startPoint: start, endPoint: end)
                // An ellipse 120 % × 78 % of the page, centred at 12 % across the top edge.
                EllipticalGradient(stops: [.init(color: w.colour.opacity(0.17), location: 0), .init(color: .clear, location: 0.58)],
                                   center: .center, startRadiusFraction: 0, endRadiusFraction: 0.5)
                    .frame(width: size.width * 2.4, height: size.height * 1.56)
                    .offset(x: size.width * 0.12 - size.width * 1.2, y: -size.height * 0.78)
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .clipped()
        }
    }
}
