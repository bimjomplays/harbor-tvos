import SwiftUI

/// Home / Movies / Shows: spotlight up top, Continue Watching, then the rail of rows.
struct RoomView: View {
    @StateObject private var model: BrowseModel
    @EnvironmentObject private var app: AppModel
    @State private var seeAll: BrowseRow?
    @State private var detail: Meta?
    @State private var quick: Meta?
    @State private var addonPage: AddonTarget?
    @State private var play: Meta?
    struct AddonTarget: Identifiable { var base: String; var name: String; var logo: String?; var id: String { base } }
    @State private var service: ServiceTarget?
    struct ServiceTarget: Identifiable { var id: String; var name: String }
    @Environment(\.shellFocusNamespace) private var shellNS
    @Namespace private var localNS

    init(room: Room, source: BrowseSource) {
        _model = StateObject(wrappedValue: BrowseModel(room: room, source: source))
    }

    var body: some View {
        ZStack(alignment: .top) {
            SpotlightView(meta: model.spotlight, boxHeight: heroHeight)
            if let failed = model.failed {
                VStack(spacing: BP.px(10)) {
                    Text("Couldn't load this room.").font(BP.sans(19, .bold)).foregroundStyle(BP.ink)
                    BPNote(text: failed)
                }
                .padding(.top, BP.px(300)).padding(.horizontal, BP.gutter)
            } else if model.loading && model.rows.isEmpty {
                ProgressView().tint(BP.inkMuted).padding(.top, BP.px(320))
            } else {
                BPRailView(rows: model.rows, onFocus: { m, _ in if m.type != "service" { model.focus(m) } },
                           onSelect: { m in
                               if m.id.hasPrefix("service:") { service = ServiceTarget(id: String(m.id.dropFirst(8)), name: m.name) }
                               else if m.id.hasPrefix("addon:") { addonPage = AddonTarget(base: String(m.id.dropFirst(6)), name: m.name, logo: m.providerBadge?.logo) }
                               else { detail = m }
                           },
                           onSeeAll: { seeAll = $0 }, onQuick: { quick = $0 }, topInset: heroHeight) {
                    if model.room == .anime, let hero = model.spotlight, hero.type != "service" {
                        // bp-anime-hero-actions: the focused hero's Resume / Start Watching and More Info.
                        AnimeHeroActionsView(meta: hero, resume: model.continueWatching.first { $0.id == hero.id },
                                             onPlay: { play = $0 }, onInfo: { detail = $0 })
                            .padding(.horizontal, BP.gutter)
                    }
                    if !model.continueWatching.isEmpty {
                        ContinueRowView(items: model.continueWatching,
                                        onFocus: { model.focus(Meta(continue: $0)) }, onSelect: { detail = Meta(continue: $0) })
                    }
                    // bp-home: the Live TV row sits after Continue Watching; empty without playlists.
                    if model.room == .home { LiveRowView { app.room = .live } }
                }
                .prefersDefaultFocus(true, in: shellNS ?? localNS)
            }
        }
        .task { await model.load() }
        // Rows arrive after first render; pull focus into them so Select acts on a tile,
        // not on the tab the bar was left on (upstream autofocuses the first row too).
        .onChange(of: model.rows.isEmpty) { _, empty in
            if !empty { DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { ShellFocus.shared.requestDefault() } }
        }
        .fullScreenCover(item: $seeAll) { row in
            CatalogPageView(room: model.room, row: row)
        }
        .fullScreenCover(item: $detail) { m in DetailView(meta: m) }
        .fullScreenCover(item: $quick) { m in QuickPanelView(meta: m) }
        .fullScreenCover(item: $service) { t in ServicePageView(service: t.id, name: t.name) }
        .fullScreenCover(item: $addonPage) { t in AddonPageView(base: t.base, name: t.name, logo: t.logo) }
        .fullScreenCover(item: $play) { m in DetailView(meta: m, autoPlay: true) }
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
