import SwiftUI

/// bp-sports-event.tsx: hero (league, pills, sides, score, facts, actions), then the Stats row
/// (live situation diagram, play by play, team statistics), Lineups (pitch, rosters, player
/// tables), Standings, Addon sources and Where to watch (venue + provider tiles).
@MainActor
final class SportsEventModel: ObservableObject {
    struct WatchOption: Decodable, Identifiable { var channelId: String; var name: String; var logo: String?; var url: String; var headers: [String: String]?; var tier: String; var attached: Bool; var label: String; var copy: String; var reasons: [String]; var score: Double; var id: String { channelId } }
    struct Provider: Decodable, Identifiable { var name: String; var url: String; var logo: String; var id: String { name } }
    /// bp-sports-broadcast-source: an official Twitch / YouTube / Kick broadcast (`app` is the provider's URL scheme).
    struct Broadcast: Decodable, Identifiable { var title: String; var url: String; var platform: String; var platformLabel: String; var app: String?; var id: String { url } }
    /// source-store AttachedStream (attached on desktop; the TV plays and clears it).
    struct AttachedStream: Decodable { var url: String; var title: String; var page: String; var kind: String; var headers: [String: String]?; var poster: String }
    struct Watch: Decodable {
        var plan: String; var label: String?; var fixture: String; var channels: [WatchOption]; var providers: [Provider]; var broadcasts: [Broadcast]
        var onAir: Bool?; var attachedStream: AttachedStream?; var sources: Int; var scanned: Int
    }

    // use-bp-sports-event useBpSportsEventActions (engine `sports.actions`).
    struct Reminder: Decodable { var active: Bool; var setup: Bool; var label: String }
    struct Follow: Decodable, Identifiable { var key: String; var name: String; var logo: String; var on: Bool; var label: String; var id: String { key } }
    struct Actions: Decodable { var reminder: Reminder?; var follow: [Follow]; var opendota: String? }
    struct ReminderOutcome: Decodable { var state: String }

    @Published private(set) var rows: SportsEventRows?
    @Published private(set) var loading = false
    @Published private(set) var note: String?
    @Published private(set) var watch: Watch?
    @Published private(set) var watching = false
    @Published private(set) var actions: Actions?
    struct WhoSides: Decodable { var home: Bool; var away: Bool }
    @Published private(set) var whoSides = WhoSides(home: false, away: false)

    /// bp-sports-event-hero whoOf: only sides with a profile subject are buttons.
    func loadWhoSides(_ game: SportsModel.Game) async {
        if let w: WhoSides = try? await HarborEngine.shared.call("sports.whoSides", [game.wire]) { whoSides = w }
    }

    /// bp-sports-watch.tsx: resolve what Watch can do (stream / broadcast / channel / addons / picker / setup / finished).
    /// The addon summary joins once `loadAddons` lands; neither waits on the other.
    func resolveWatch(_ game: SportsModel.Game) async {
        watchSeq += 1
        let seq = watchSeq
        watching = true; defer { if seq == watchSeq { watching = false } }
        let summary: AnyJSON = addons.map { .object(["matched": .number(Double($0.matched)), "available": .number(Double($0.available))]) } ?? .null
        let w: Watch? = try? await HarborEngine.shared.call("sports.watch", [game.wire, summary])
        // A slower earlier call (without the addon summary) must not overwrite a newer plan.
        if seq == watchSeq { watch = w }
    }
    private var watchSeq = 0

    // use-bp-sports-addon-sources: installed addons with sports catalogs, listings matched to the game.
    struct AddonRow: Decodable, Identifiable, Equatable { var key: String; var addonName: String; var addonLogo: String?; var name: String; var poster: String?; var match: String?; var id: String { key } }
    struct AddonSources: Decodable { var installed: Bool; var failed: Bool; var rows: [AddonRow]; var matched: Int; var available: Int }
    @Published private(set) var addons: AddonSources?
    @Published private(set) var addonsLoading = false
    var matchingAddons: [AddonRow] { addons?.rows.filter { $0.match != nil } ?? [] }

    func loadAddons(_ game: SportsModel.Game, force: Bool = false) async {
        guard game.state != "post" else { return }
        addonsLoading = true; defer { addonsLoading = false }
        let p = ProfilesStore.shared.active
        let authKey: AnyJSON = p.flatMap { ProfilesStore.shared.stremioSession(for: $0.id)?.authKey }.map { .string($0) } ?? .null
        addons = try? await HarborEngine.shared.call("sports.addonSources", [game.wire, authKey, force])
        await resolveWatch(game)
    }

    func togglePin(_ game: SportsModel.Game, _ option: WatchOption) async {
        _ = try? await HarborEngine.shared.callJSON("sports.toggleAttachedChannel", [.string(game.league), .string(option.channelId)])
        await resolveWatch(game)
    }

    /// bp-sports-watch pick: a chosen channel replaces the game's attached stream, then plays.
    func recordPlay(_ option: WatchOption, game: SportsModel.Game) {
        Task {
            _ = try? await HarborEngine.shared.callJSON("sports.recordChannelWatch", [.string(option.channelId)])
            if watch?.attachedStream != nil {
                _ = try? await HarborEngine.shared.callJSON("sports.clearAttachedStream", [.string(game.id)])
                await resolveWatch(game)
            }
        }
    }

    func load(_ game: SportsModel.Game) async {
        loading = true; defer { loading = false }
        // Only whether a summary exists matters here; the rows come shaped from `sports.eventRows`.
        do {
            let d = try await HarborEngine.shared.callJSON("sports.detail", [game.wire])
            note = d.isNull ? "Match details are not available right now. The scoreboard above is still live." : nil
        } catch { note = "Match details are not available right now. The scoreboard above is still live." }
        await loadRows(game)
    }

    /// Stats + Lineups rows from the (25 s cached) summary.
    func loadRows(_ game: SportsModel.Game) async {
        if let r: SportsEventRows = try? await HarborEngine.shared.call("sports.eventRows", [game.wire]) { rows = r }
    }

    func loadActions(_ game: SportsModel.Game) async {
        actions = try? await HarborEngine.shared.call("sports.actions", [game.wire])
    }

    /// The bell: "setup" means no webhook is configured yet (the caller opens the webhook fields).
    func toggleReminder(_ game: SportsModel.Game) async -> String {
        let r: ReminderOutcome? = try? await HarborEngine.shared.call("sports.toggleReminder", [game.wire])
        await loadActions(game)
        return r?.state ?? "error"
    }

    func toggleFollow(_ game: SportsModel.Game, _ key: String) async {
        _ = try? await HarborEngine.shared.callJSON("sports.toggleFollow", [game.wire, .string(key)])
        await loadActions(game)
    }
}

struct SportsEventView: View {
    let game: SportsModel.Game
    let dismiss: () -> Void
    @StateObject private var model = SportsEventModel()
    @State private var playing: SportsEventModel.WatchOption?
    @State private var picker = false
    struct WhoTarget: Identifiable { let id: String }   // "home" | "away"
    @State private var who: WhoTarget?
    /// bp-sports-addon-panel: open on the listings (row nil) or straight on one listing's streams.
    struct AddonOpen: Identifiable { let row: SportsEventModel.AddonRow?; var id: String { row?.key ?? "listings" } }
    @State private var addonPanel: AddonOpen?
    @State private var addonPlaying: SportsAddonPanelView.Play?
    @State private var broadcastsOpen = false
    @State private var link: SportsLink?
    @State private var webhookSetup = false

    var body: some View {
        ZStack {
            BP.canvas.ignoresSafeArea()
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: BP.px(20)) {
                    hero
                    watchSection
                    if let s = model.rows?.stats { SportsStatsRowView(stats: s) }
                    if let l = model.rows?.lineups { SportsLineupsRowView(lineups: l) }
                    if model.rows == nil && model.loading { ProgressView().tint(BP.inkMuted) }
                    StandingsSection(league: game.league).padding(.top, BP.px(10))
                    addonRow
                    SportsWhereRowView(game: game)
                    if let n = model.note { BPNote(text: n) }
                    Button("Go back") { dismiss() }.buttonStyle(BPActionStyle())
                }
                .padding(.horizontal, BP.gutter).padding(.top, BP.px(40)).padding(.bottom, BP.hintHeight + BP.px(40))
            }
        }
        .task { await model.load(game) }
        .task { await model.loadWhoSides(game) }
        .task { await model.loadActions(game) }
        .task { await model.loadAddons(game) }
        .task { if game.state != "post" { await model.resolveWatch(game) } }
        .task {
            // use-match-detail: a game in progress refreshes its summary every 30 s.
            guard game.state == "in" else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { return }
                await model.loadRows(game)
            }
        }
        .onExitCommand { if picker { picker = false } else { dismiss() } }
        .fullScreenCover(item: $playing) { opt in
            PlayerScreen(title: opt.name, subtitle: model.watch?.fixture ?? game.leagueLabel, url: URL(string: opt.url) ?? URL(string: "about:blank")!, headers: opt.headers ?? [:], isLive: true) { _ in playing = nil }
        }
        .fullScreenCover(item: $who) { t in SportsWhoView(game: game, side: t.id) }
        .fullScreenCover(item: $addonPanel) { open in
            SportsAddonPanelView(game: game, model: model, initial: open.row, onPlay: { play in
                addonPanel = nil
                // Present after the panel's cover has dismissed; a present-while-dismissing is dropped on tvOS.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { addonPlaying = play }
            }, onClose: { addonPanel = nil })
        }
        .fullScreenCover(item: $addonPlaying) { p in
            PlayerScreen(title: p.title, subtitle: p.subtitle, url: p.url, headers: p.headers, isLive: p.isLive) { _ in addonPlaying = nil }
        }
        .fullScreenCover(isPresented: $broadcastsOpen) {
            SportsBroadcastsView(
                fixture: model.watch?.fixture ?? game.headline,
                broadcasts: model.watch?.broadcasts ?? [],
                onAir: model.watch?.onAir ?? false,
                channels: broadcastChannelsAction,
                addons: broadcastAddonsAction,
                onClose: { broadcastsOpen = false })
        }
        .fullScreenCover(item: $link) { l in SportsLinkView(link: l) { link = nil } }
        .fullScreenCover(isPresented: $webhookSetup) {
            ZStack {
                BP.void_.opacity(0.94).ignoresSafeArea()
                VStack(alignment: .leading, spacing: BP.px(16)) {
                    Text("Set up reminders").font(BP.display(30)).foregroundStyle(BP.ink)
                    SportsWebhooksPanel(onDone: {
                        webhookSetup = false
                        Task { await model.loadActions(game) }
                    })
                }
                .frame(maxWidth: BP.px(1100), alignment: .leading)
                .padding(BP.gutter)
            }
            .onExitCommand { webhookSetup = false; Task { await model.loadActions(game) } }
        }
    }

    // bp-sports-watch.tsx press, per plan, plus the hero's secondary actions.
    @ViewBuilder private var watchSection: some View {
        VStack(alignment: .leading, spacing: BP.px(8)) {
            HStack(spacing: BP.px(10)) {
                if game.state != "post", let w = model.watch {
                    primary(w)
                    // bp-sports-event heroActions: "Choose a channel" when there is more than one pick.
                    if (w.plan == "stream" || w.plan == "broadcast") && !w.channels.isEmpty {
                        Button("Choose a channel") { picker.toggle() }.buttonStyle(BPActionStyle())
                    }
                    if w.plan == "channel" && w.channels.count > 1 { Button("Other channels") { picker.toggle() }.buttonStyle(BPActionStyle()) }
                    if w.plan != "addons" && (model.addons?.available ?? 0) > 0 {
                        Button("Addon sources") { addonPanel = AddonOpen(row: nil) }.buttonStyle(BPActionStyle())
                    }
                } else if game.state != "post" && model.watching {
                    ProgressView().tint(BP.inkMuted)
                    Text("Checking your channels…").font(BP.sans(12)).foregroundStyle(BP.inkSubtle)
                }
                heroActions
            }
            if game.state != "post", let w = model.watch {
                if w.plan == "setup" { Text("Add a Live TV source to watch matches here.").font(BP.sans(13)).foregroundStyle(BP.inkMuted) }
                if picker || (w.plan == "picker" && w.channels.isEmpty) { channelPicker(w) }
            }
        }
        .focusSection()
    }

    @ViewBuilder private func primary(_ w: SportsEventModel.Watch) -> some View {
        switch w.plan {
        case "stream":
            Button(w.label.map { T($0) } ?? T("Watch")) { playAttached(w) }.buttonStyle(BPActionStyle(primary: true))
        case "broadcast":
            Button(w.label.map { T($0) } ?? T("Where to watch")) {
                // setAuto(pickCount > 1 ? null : shows[0]): a single broadcast opens straight away.
                if w.broadcasts.count == 1 && w.channels.isEmpty, let b = w.broadcasts.first { link = broadcastLink(b) } else { broadcastsOpen = true }
            }
            .buttonStyle(BPActionStyle(primary: true))
        case "channel":
            if let first = w.channels.first { Button((w.label.map { T($0) } ?? T("Watch")) + " · " + first.name) { play(first) }.buttonStyle(BPActionStyle(primary: true)) }
        case "picker":
            Button(w.channels.isEmpty ? T("Search your channels") : w.channels.count == 1 ? T("Watch · 1 channel found") : T("Watch · %lld channels found", w.channels.count)) { picker.toggle() }.buttonStyle(BPActionStyle(primary: true))
        case "addons":
            Button("Addon sources") { addonPanel = AddonOpen(row: nil) }.buttonStyle(BPActionStyle(primary: true))
        default:
            EmptyView()
        }
    }

    // useBpSportsEventActions: the reminder bell, follow toggles, OpenDota's match page.
    @ViewBuilder private var heroActions: some View {
        if let a = model.actions {
            if let r = a.reminder {
                Button {
                    Task {
                        if await model.toggleReminder(game) == "setup" { webhookSetup = true }
                    }
                } label: { Label(r.label, systemImage: r.active ? "bell.and.waves.left.and.right.fill" : "bell") }
                .buttonStyle(BPActionStyle(primary: r.active))
            }
            ForEach(a.follow) { f in
                Button { Task { await model.toggleFollow(game, f.key) } } label: { Label(f.label, systemImage: f.on ? "heart.fill" : "heart") }
                    .buttonStyle(BPActionStyle(primary: f.on))
            }
            if let url = a.opendota {
                Button { link = SportsLink(title: T("View match statistics"), url: url) } label: { Label("View match statistics", systemImage: "arrow.up.right.square") }
                    .buttonStyle(BPActionStyle())
            }
        }
    }

    // bp-sports-broadcast-picker: official broadcasts first, then channel matches with their tier copy.
    @ViewBuilder private func channelPicker(_ w: SportsEventModel.Watch) -> some View {
        VStack(alignment: .leading, spacing: BP.px(6)) {
            ForEach(w.broadcasts) { b in
                Button { link = broadcastLink(b) } label: {
                    HStack(spacing: BP.px(10)) {
                        Image(systemName: "dot.radiowaves.left.and.right").foregroundStyle(BP.inkMuted).frame(width: BP.px(48))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(b.title).font(BP.sans(14, .semibold)).foregroundStyle(BP.ink).lineLimit(1)
                            Text(T(b.platformLabel)).font(BP.sans(11)).foregroundStyle(BP.inkMuted).lineLimit(1)
                        }
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(BPActionStyle())
            }
            ForEach(w.channels) { opt in
                HStack(spacing: BP.px(8)) {
                    Button { play(opt) } label: {
                        HStack(spacing: BP.px(10)) {
                            RemoteImage(url: opt.logo, contentMode: .fit).frame(width: BP.px(48), height: BP.px(28))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(opt.label).font(BP.sans(14, .semibold)).foregroundStyle(BP.ink).lineLimit(1)
                                Text(T(opt.copy) + (opt.reasons.isEmpty ? "" : " · " + opt.reasons.prefix(2).map { T($0) }.joined(separator: ", "))).font(BP.sans(11)).foregroundStyle(BP.inkMuted).lineLimit(1)
                            }
                            Spacer()
                            Text(opt.tier.capitalized).font(BP.sans(11, .bold)).foregroundStyle(opt.tier == "exact" ? BP.live : BP.inkSubtle)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(BPActionStyle())
                    Button(opt.attached ? T("Unpin") : T("Always use for %@", game.leagueLabel)) { Task { await model.togglePin(game, opt) } }.buttonStyle(BPActionStyle(primary: opt.attached))
                }
            }
            if w.channels.isEmpty {
                Text(w.sources == 0 ? T("No playlists yet. Add one in Live TV and Harbor will match its channels to fixtures.")
                     : T("None of your channels match this fixture. Search your channels and pin the one that carries it.") + " (\(w.scanned) sports channels scanned)")
                    .font(BP.sans(12)).foregroundStyle(BP.inkSubtle)
            }
            // bp-sports-picker onAddons: offered whenever an addon has any listing.
            if (model.addons?.available ?? 0) > 0 { Button("Addon sources") { addonPanel = AddonOpen(row: nil) }.buttonStyle(BPActionStyle()) }
        }
        .frame(maxWidth: BP.px(900), alignment: .leading)
    }

    // bp-sports-broadcast-picker action chips: "Search your channels" (Live TV sources exist) and "Addon sources".
    private var broadcastChannelsAction: (() -> Void)? {
        guard (model.watch?.sources ?? 0) > 0 else { return nil }
        return { broadcastsOpen = false; picker = true }
    }
    private var broadcastAddonsAction: (() -> Void)? {
        guard (model.addons?.available ?? 0) > 0 else { return nil }
        return {
            broadcastsOpen = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { addonPanel = AddonOpen(row: nil) }
        }
    }

    private func broadcastLink(_ b: SportsEventModel.Broadcast) -> SportsLink {
        SportsLink(title: b.title, url: b.url, app: b.app, message: T("Official broadcast. It plays in the %@ app, or scan to watch on your phone.", b.platformLabel))
    }

    private func play(_ opt: SportsEventModel.WatchOption) {
        model.recordPlay(opt, game: game)
        playing = opt
    }

    // useBpSportsPlayStream: the attached stream plays live unless it is a file; subtitle is the page host.
    private func playAttached(_ w: SportsEventModel.Watch) {
        guard let s = w.attachedStream, let url = URL(string: s.url) else { return }
        let host = URL(string: s.page)?.host
        addonPlaying = SportsAddonPanelView.Play(url: url, headers: s.headers ?? [:], title: w.fixture, subtitle: host, isLive: s.kind != "file")
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: BP.px(10)) {
            HStack(spacing: BP.px(8)) {
                RemoteImage(url: game.leagueLogo.isEmpty ? nil : game.leagueLogo, contentMode: .fit).frame(width: BP.px(24), height: BP.px(24))
                Text(game.leagueLabel).font(BP.sans(14, .semibold)).foregroundStyle(BP.inkMuted)
                if game.live { pill("Live", BP.live) } else if game.state == "post" { pill("Final", BP.inkMuted) }
                if game.savedAt != nil { pill("Saved", BP.inkSubtle) }
            }
            if game.single || game.faceOff {
                Text(game.headline).font(BP.display(36)).foregroundStyle(BP.ink)
            } else {
                if let c = game.context, !c.name.isEmpty { Text(c.name).font(BP.sans(15, .semibold)).foregroundStyle(BP.inkMuted) }
                HStack(spacing: BP.px(24)) {
                    side(game.away, key: "away", opens: model.whoSides.away)
                    Text(game.state == "pre" ? "vs" : "\(game.away.score.isEmpty ? "0" : game.away.score) : \(game.home.score.isEmpty ? "0" : game.home.score)")
                        .font(BP.display(40)).foregroundStyle(BP.ink).monospacedDigit()
                    side(game.home, key: "home", opens: model.whoSides.home)
                }
            }
            Text(facts).font(BP.sans(13)).foregroundStyle(BP.inkMuted)
        }
    }

    private var facts: String {
        var parts: [String] = []
        if let c = game.context {
            if !c.round.isEmpty, !["standard", "std", "regular season"].contains(c.round.lowercased()) { parts.append(c.round) }
            if !c.venue.isEmpty { parts.append(c.venue) }
        }
        if !game.detail.isEmpty, game.state != "post" { parts.append(game.detail) }
        parts.append(game.startLabel)
        if let b = game.broadcasts, !b.isEmpty { parts.append(b.prefix(3).joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }

    private func pill(_ text: String, _ color: Color) -> some View {
        Text(T(text)).font(BP.sans(10, .bold)).foregroundStyle(BP.canvas).padding(.horizontal, BP.px(6)).padding(.vertical, BP.px(2)).background(Capsule().fill(color))
    }

    // bp-sports-addon-row: up to eight matching listings, then "Browse addon channels".
    @ViewBuilder private var addonRow: some View {
        if game.state != "post", let a = model.addons, a.available > 0 {
            VStack(alignment: .leading, spacing: BP.px(8)) {
                Text("Addon sources").font(BP.sans(17, .semibold)).foregroundStyle(BP.ink)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: BP.px(10)) {
                        ForEach(model.matchingAddons.prefix(8)) { row in
                            Button { addonPanel = AddonOpen(row: row) } label: { SportsAddonTile(logo: row.addonLogo, title: row.name, sub: SportsAddonPanelView.matchCopy(row)) }
                                .buttonStyle(BPTileStyle(radius: BP.rMD))
                        }
                        Button { addonPanel = AddonOpen(row: nil) } label: {
                            SportsAddonTile(logo: nil, title: T("Browse addon channels"), sub: T("%lld listings from your addons", a.rows.count), icon: "powerplug")
                        }
                        .buttonStyle(BPTileStyle(radius: BP.rMD))
                    }
                    .padding(.vertical, BP.px(8))
                }
                .scrollClipDisabled()
            }
            .focusSection()
        }
    }

    // bp-sports-event-hero BpEventSide: a side with a who subject is a button ("Open {name}") that
    // opens bp-sports-who-panel; otherwise it is plain.
    @ViewBuilder private func side(_ s: SportsModel.Side, key: String, opens: Bool) -> some View {
        let content = VStack(spacing: BP.px(6)) {
            RemoteImage(url: s.logo.isEmpty ? nil : s.logo, contentMode: .fit).frame(width: BP.px(72), height: BP.px(72))
            Text(s.name).font(BP.sans(16, .semibold)).foregroundStyle(BP.ink).lineLimit(1)
            let sub: String = ([s.rank.map { "#\($0)" }, s.record] as [String?]).compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            if !sub.isEmpty { Text(sub).font(BP.sans(12)).foregroundStyle(BP.inkSubtle) }
        }
        .frame(width: BP.px(220)).padding(.vertical, BP.px(8))
        if opens {
            Button { who = WhoTarget(id: key) } label: { content }
                .buttonStyle(BPTileStyle(radius: BP.rMD))
                .accessibilityLabel("Open \(s.name)")
        } else {
            content
        }
    }
}
