import SwiftUI

/// Discover room (bp-discover.tsx): Discovery Queue band → Genres → "Picked for you" rails.
/// Awards, Collections and Top People bands arrive with their features.
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
    /// The lead band holding the ring ("queue", "awards", "genres", "voyage", "people").
    @State private var leadHeld: String?
    /// (open-items sweep) A Try again that worked hands the ring to the Discovery Queue band (the
    /// button under it went away and the ring fell to the tab bar).
    @State private var seedQueue = false

    var body: some View {
        ZStack(alignment: .top) {
            // (layout pass) The art only. The rail parks a focused row just under the top bar (topInset
            // below), right where the spotlight's title, chips and overview were bottom-anchored, and
            // it draws after them: the focused title's copy sat behind that row's header and posters.
            // bp-discover has no title copy over its rail either (its header names the band).
            SpotlightView(meta: model.spotlight, boxHeight: BP.px(160) + BP.barHeight, layer: .backdrop)
                .opacity(model.spotlight == nil ? 0 : 1)
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
                           topInset: BP.barHeight + BP.px(10)) {
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
                                           onHold: { hold("awards", $0) })
                        }
                    }
                    // bp-discover.tsx t("{n} shelves, …", { n: BP_GENRES.length }): the literal "18 …"
                    // matched no catalog key and stayed English.
                    section("genres", "Discover", "Genres", T("%lld shelves, one press into any of them", model.build?.genres.count ?? 18)) {
                        GenresBandView(genres: model.build?.genres ?? [], art: model.genreArt, onOpen: { genre in
                            genrePage = BrowseRow(key: "genre:\(genre)", title: T(genre), metas: [])
                        }, onFocus: {
                            Task { await model.loadGenreArt() }
                        }, onHold: { hold("genres", $0) })
                    }
                    // discover.tsx: the Voyages banner follows the browse tiles, once its pool holds three.
                    if let pool = model.build?.voyagePool, pool.count >= 3 {
                        VoyageBannerView(snapshot: model.voyage, pool: pool, onOpen: { voyageOpen = true }, onHold: { hold("voyage", $0) })
                            .modifier(BPRailLeadMark(key: Self.leadKey("voyage"), held: leadHeld == "voyage"))
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
        .fullScreenCover(item: $detail) { m in DetailView(meta: m) }
        .fullScreenCover(item: $awardDetail) { a in AwardDetailView(summary: a) }
        .fullScreenCover(item: $animeAward) { a in AnimeAwardView(sources: model.animeAwards, initial: a.id) }
        .fullScreenCover(item: $genrePage) { r in CatalogPageView(room: .discover, row: r) }
        .fullScreenCover(isPresented: $queueOpen, onDismiss: { Task { await model.reloadQueue() } }) { QueueDeckView() }
        .fullScreenCover(isPresented: $voyageOpen, onDismiss: { Task { await model.loadVoyage() } }) { VoyageView() }
    }

    /// bp-discover.tsx `series = rail.metas[0]?.type === "series"`.
    private static func isSeries(_ row: BrowseRow) -> Bool { row.metas.first?.type == "series" }

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
        .onChange(of: focusedGenre) { _, g in if g != nil { onFocus() } }
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

/// bp-people-band: portrait circles with rank and name.
struct PeopleBandView: View {
    let people: [DiscoverModel.Person]
    /// The band gained (true) or lost (false) the ring (the rail parks it).
    var onHold: ((Bool) -> Void)? = nil
    /// bp-people-band: Select opens the person page (pushBigPicture kind "person").
    @State private var person: DiscoverModel.Person?
    @FocusState private var focusedPerson: Int?
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: BP.trackGap) {
                ForEach(people.uniquedById()) { p in   // (bug pass) TMDB pages can repeat a person
                    Button { person = p } label: {
                        VStack(spacing: BP.px(8)) {
                            ZStack(alignment: .bottomLeading) {
                                RemoteImage(url: p.portrait).frame(width: BP.px(110), height: BP.px(110)).clipShape(Circle())
                                Text("#\(p.rank)").font(BP.sans(10, .bold)).foregroundStyle(BP.canvas)
                                    .padding(.horizontal, BP.px(6)).padding(.vertical, BP.px(2)).background(Capsule().fill(BP.ink))
                            }
                            Text(p.name).font(BP.sans(12, .semibold)).foregroundStyle(BP.ink).lineLimit(1)
                        }
                        .frame(width: BP.px(130))
                    }
                    .buttonStyle(BPTileStyle(radius: BP.px(55)))
                    .focused($focusedPerson, equals: p.id)
                }
            }
            .padding(.horizontal, BP.gutter).padding(.vertical, BP.px(14))
        }
        .scrollClipDisabled()
        .focusSection()
        .onChange(of: focusedPerson != nil) { _, held in onHold?(held) }
        .fullScreenCover(item: $person) { p in PersonView(personId: p.id, name: p.name) }
    }
}

/// Award body detail: categories with winners by year (offline catalog).
struct AwardDetailView: View {
    let summary: DiscoverModel.Awards.Summary
    @State private var detail: Detail?
    /// The engine answered (or failed): a failed read says so instead of spinning forever.
    @State private var loaded = false
    @Environment(\.dismiss) private var dismiss

    struct Detail: Decodable {
        struct Category: Decodable { var id: String?; var label: String?; var name: String? }
        /// awards-history.ts CategoryWinner: the film or show is `workTitle` (there is no `title`,
        /// so the winners list showed recipients alone, and nothing for a title with none).
        struct Entry: Decodable {
            var year: Int; var workTitle: String?; var title: String?; var recipients: [String]?
            /// bp-award.tsx winner tile: the work, then the recipients.
            var line: String {
                let parts: [String?] = [workTitle ?? title, recipients?.joined(separator: ", ")]
                return parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " — ")
            }
        }
        struct Group: Decodable, Identifiable { var category: Category; var entries: [Entry]; var id: String { category.id ?? category.label ?? category.name ?? UUID().uuidString } }
        var title: String
        var wins: Int
        var span: String
        var groups: [Group]
    }

    var body: some View {
        ZStack {
            BPAmbientBackground()
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: BP.px(18)) {
                    Text(summary.title).font(BP.display(36)).foregroundStyle(BP.ink)
                    Text("\(summary.wins) winners · \(summary.span)").font(BP.sans(14)).foregroundStyle(BP.inkMuted)
                    Button("Back") { dismiss() }.buttonStyle(BPActionStyle())
                    if let detail {
                        // (bug pass) Group.id falls back to a fresh UUID on every read (and labels can
                        // repeat): unstable ids for ForEach. The catalog's order is stable, so key by position.
                        ForEach(Array(detail.groups.enumerated()), id: \.offset) { _, g in
                            VStack(alignment: .leading, spacing: BP.px(6)) {
                                Text(g.category.label ?? g.category.name ?? g.category.id ?? "Category").font(BP.sans(17, .bold)).foregroundStyle(BP.ink)
                                ForEach(Array(g.entries.prefix(12).enumerated()), id: \.offset) { _, e in
                                    HStack(alignment: .top, spacing: BP.px(10)) {
                                        Text(String(e.year)).font(BP.sans(13, .semibold)).foregroundStyle(BP.accent).frame(width: BP.px(46), alignment: .leading)
                                        Text(e.line).font(BP.sans(13)).foregroundStyle(BP.inkMuted).lineLimit(2)
                                    }
                                }
                            }
                            .padding(BP.px(16))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: BP.rMD, style: .continuous).fill(BP.panel))
                            // One focus stop, one reading: the category and its winners, not a line at a time.
                            .accessibilityElement(children: .combine)
                            .focusable()
                        }
                    } else if loaded {
                        BPNote(text: "Couldn't load this award right now.")
                    } else {
                        ProgressView().tint(BP.inkMuted)
                    }
                }
                .padding(.horizontal, BP.gutter).padding(.vertical, BP.px(50))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .ignoresSafeArea()
        .task {
            guard detail == nil else { return }
            detail = try? await HarborEngine.shared.call("discoverRoom.awardDetail", [summary.type])
            loaded = true
        }
    }
}
