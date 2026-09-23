import SwiftUI

/// bp-sports-event.tsx, ESPN branch: hero (league, pills, sides, score, facts), then team
/// statistics, play-by-play events, lineups and the official watch note.
@MainActor
final class SportsEventModel: ObservableObject {
    struct Player: Decodable, Identifiable { var id: String; var name: String; var jersey: String; var position: String; var starter: Bool }
    struct StatRow: Decodable, Identifiable { var label: String; var homeValue: String; var awayValue: String; var id: String { label } }
    struct Event: Decodable, Identifiable { var id: String; var time: String; var type: String; var text: String; var teamId: String? }
    struct Detail: Decodable {
        var homeRoster: [Player]?; var awayRoster: [Player]?
        var allStats: [StatRow]?; var events: [Event]?
        var homeFormation: String?; var awayFormation: String?
    }

    struct WatchOption: Decodable, Identifiable { var channelId: String; var name: String; var logo: String?; var url: String; var headers: [String: String]?; var tier: String; var attached: Bool; var label: String; var copy: String; var reasons: [String]; var score: Double; var id: String { channelId } }
    struct Provider: Decodable, Identifiable { var name: String; var url: String; var logo: String; var id: String { name } }
    struct Broadcast: Decodable, Identifiable { var title: String; var competition: String; var channel: String; var source: String; var id: String { channel } }
    struct Watch: Decodable { var plan: String; var fixture: String; var channels: [WatchOption]; var providers: [Provider]; var broadcasts: [Broadcast]; var sources: Int; var scanned: Int }

    @Published private(set) var detail: Detail?
    @Published private(set) var loading = false
    @Published private(set) var note: String?
    @Published private(set) var watch: Watch?
    @Published private(set) var watching = false

    /// bp-sports-watch.tsx: resolve what Watch can do (channel / picker / setup / finished).
    func resolveWatch(_ game: SportsModel.Game) async {
        watching = true; defer { watching = false }
        watch = try? await HarborEngine.shared.call("sports.watch", [game.wire])
    }

    func togglePin(_ game: SportsModel.Game, _ option: WatchOption) async {
        _ = try? await HarborEngine.shared.callJSON("sports.toggleAttachedChannel", [.string(game.league), .string(option.channelId)])
        await resolveWatch(game)
    }

    func recordPlay(_ option: WatchOption) {
        Task { _ = try? await HarborEngine.shared.callJSON("sports.recordChannelWatch", [.string(option.channelId)]) }
    }

    func load(_ game: SportsModel.Game) async {
        loading = true; defer { loading = false }
        do {
            let d: Detail? = try await HarborEngine.shared.call("sports.detail", [game.wire])
            detail = d
            if d == nil { note = "No detail feed for this provider yet. Scores and the schedule above are live." }
        } catch { note = "Detail unavailable: \(error.localizedDescription)" }
    }
}

struct SportsEventView: View {
    let game: SportsModel.Game
    let dismiss: () -> Void
    @StateObject private var model = SportsEventModel()
    @State private var playing: SportsEventModel.WatchOption?
    @State private var picker = false

    var body: some View {
        ZStack {
            BP.canvas.ignoresSafeArea()
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: BP.px(20)) {
                    hero
                    watchSection
                    if let d = model.detail {
                        if let stats = d.allStats, !stats.isEmpty { statsRow(stats, title: game.live ? "Live now" : "Key statistics") }
                        if let ev = d.events, !ev.isEmpty { eventsRow(ev) }
                        if (d.homeRoster?.isEmpty == false) || (d.awayRoster?.isEmpty == false) { lineups(d) }
                    } else if model.loading {
                        ProgressView().tint(BP.inkMuted)
                    }
                    if let n = model.note { BPNote(text: n) }
                    Text("Availability and subscriptions are set by each provider. Harbor does not bypass access restrictions.")
                        .font(BP.sans(11)).foregroundStyle(BP.inkSubtle)
                    Button("Go back") { dismiss() }.buttonStyle(BPActionStyle())
                }
                .padding(.horizontal, BP.gutter).padding(.top, BP.px(40)).padding(.bottom, BP.hintHeight + BP.px(40))
            }
        }
        .task { await model.load(game) }
        .task { if game.state != "post" { await model.resolveWatch(game) } }
        .onExitCommand { if picker { picker = false } else { dismiss() } }
        .fullScreenCover(item: $playing) { opt in
            PlayerScreen(title: opt.name, subtitle: model.watch?.fixture ?? game.leagueLabel, url: URL(string: opt.url) ?? URL(string: "about:blank")!, headers: opt.headers ?? [:], isLive: true) { _ in playing = nil }
        }
    }

    // bp-sports-watch.tsx press → play the exact match, or open the picker, or point at Live TV.
    private var watchSection: some View {
        VStack(alignment: .leading, spacing: BP.px(8)) {
            if game.state == "post" {
                EmptyView()
            } else if let w = model.watch {
                HStack(spacing: BP.px(10)) {
                    switch w.plan {
                    case "channel":
                        Button("Watch on \(w.channels[0].name)") { play(w.channels[0]) }.buttonStyle(BPActionStyle(primary: true))
                        if w.channels.count > 1 { Button("Other channels") { picker.toggle() }.buttonStyle(BPActionStyle()) }
                    case "picker":
                        Button(w.channels.isEmpty ? "Search your channels" : "Watch · \(w.channels.count) channel\(w.channels.count == 1 ? "" : "s") found") { picker.toggle() }.buttonStyle(BPActionStyle(primary: true))
                    case "setup":
                        Text("Add a Live TV source to watch matches here.").font(BP.sans(13)).foregroundStyle(BP.inkMuted)
                    default:
                        EmptyView()
                    }
                }
                if picker || (w.plan == "picker" && w.channels.isEmpty) {
                    VStack(alignment: .leading, spacing: BP.px(6)) {
                        ForEach(w.channels) { opt in
                            HStack(spacing: BP.px(8)) {
                                Button { play(opt) } label: {
                                    HStack(spacing: BP.px(10)) {
                                        RemoteImage(url: opt.logo, contentMode: .fit).frame(width: BP.px(48), height: BP.px(28))
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(opt.label).font(BP.sans(14, .semibold)).foregroundStyle(BP.ink).lineLimit(1)
                                            Text(opt.copy + (opt.reasons.isEmpty ? "" : " · " + opt.reasons.prefix(2).joined(separator: ", "))).font(BP.sans(11)).foregroundStyle(BP.inkMuted).lineLimit(1)
                                        }
                                        Spacer()
                                        Text(opt.tier.capitalized).font(BP.sans(11, .bold)).foregroundStyle(opt.tier == "exact" ? BP.live : BP.inkSubtle)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .buttonStyle(BPActionStyle())
                                Button(opt.attached ? "Unpin" : "Pin for \(game.leagueLabel)") { Task { await model.togglePin(game, opt) } }.buttonStyle(BPActionStyle(primary: opt.attached))
                            }
                        }
                        if w.channels.isEmpty { Text("No channel in your \(w.sources) source\(w.sources == 1 ? "" : "s") looks like this fixture (\(w.scanned) sports channels scanned).").font(BP.sans(12)).foregroundStyle(BP.inkSubtle) }
                    }
                    .frame(maxWidth: BP.px(900), alignment: .leading)
                }
                if !w.providers.isEmpty || !w.broadcasts.isEmpty {
                    // bp-sports-event-rows where-to-watch: provider tiles with their marks, then official broadcasts.
                    VStack(alignment: .leading, spacing: BP.px(6)) {
                        Text("Where to watch").font(BP.sans(11, .bold)).textCase(.uppercase).tracking(0.8).foregroundStyle(BP.inkSubtle)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: BP.px(8)) {
                                ForEach(Array(w.providers.enumerated()), id: \.offset) { _, p in
                                    HStack(spacing: BP.px(6)) {
                                        if !p.logo.isEmpty { RemoteImage(url: p.logo, contentMode: .fit).frame(width: BP.px(22), height: BP.px(22)) }
                                        Text(p.name).font(BP.sans(12, .semibold)).foregroundStyle(BP.ink)
                                    }
                                    .padding(.horizontal, BP.px(10)).padding(.vertical, BP.px(6))
                                    .background(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).fill(BP.panel2))
                                }
                                ForEach(Array(w.broadcasts.enumerated()), id: \.offset) { _, b in
                                    Text("\(b.title) · \(b.source.capitalized) \(b.channel)").font(BP.sans(12)).foregroundStyle(BP.inkMuted)
                                        .padding(.horizontal, BP.px(10)).padding(.vertical, BP.px(6))
                                        .background(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).fill(BP.panel2))
                                }
                            }
                        }
                        .scrollClipDisabled()
                        Text("Official apps and broadcasts open on your other devices; Harbor lists them here.").font(BP.sans(10.5)).foregroundStyle(BP.inkSubtle)
                    }
                }
            } else if model.watching {
                HStack(spacing: BP.px(8)) { ProgressView().tint(BP.inkMuted); Text("Checking your channels…").font(BP.sans(12)).foregroundStyle(BP.inkSubtle) }
            }
        }
        .focusSection()
        StandingsSection(league: game.league).padding(.top, BP.px(10))
    }

    private func play(_ opt: SportsEventModel.WatchOption) {
        model.recordPlay(opt)
        playing = opt
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
                    side(game.away)
                    Text(game.state == "pre" ? "vs" : "\(game.away.score.isEmpty ? "0" : game.away.score) : \(game.home.score.isEmpty ? "0" : game.home.score)")
                        .font(BP.display(40)).foregroundStyle(BP.ink).monospacedDigit()
                    side(game.home)
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
        Text(text).font(BP.sans(10, .bold)).foregroundStyle(BP.canvas).padding(.horizontal, BP.px(6)).padding(.vertical, BP.px(2)).background(Capsule().fill(color))
    }

    private func side(_ s: SportsModel.Side) -> some View {
        VStack(spacing: BP.px(6)) {
            RemoteImage(url: s.logo.isEmpty ? nil : s.logo, contentMode: .fit).frame(width: BP.px(72), height: BP.px(72))
            Text(s.name).font(BP.sans(16, .semibold)).foregroundStyle(BP.ink).lineLimit(1)
            if let r = s.record { Text(r).font(BP.sans(12)).foregroundStyle(BP.inkSubtle) }
        }
        .frame(width: BP.px(220))
    }

    private func statsRow(_ stats: [SportsEventModel.StatRow], title: String) -> some View {
        VStack(alignment: .leading, spacing: BP.px(8)) {
            Text(title).font(BP.sans(17, .semibold)).foregroundStyle(BP.ink)
            ForEach(stats.prefix(12)) { row in
                let a = Double(row.awayValue.replacingOccurrences(of: "%", with: "")) ?? 0
                let h = Double(row.homeValue.replacingOccurrences(of: "%", with: "")) ?? 0
                let total = max(a + h, 1)
                HStack(spacing: BP.px(10)) {
                    Text(row.awayValue).font(BP.sans(13, .semibold)).foregroundStyle(BP.ink).frame(width: BP.px(60), alignment: .trailing).monospacedDigit()
                    GeometryReader { geo in
                        HStack(spacing: 2) {
                            Capsule().fill(BP.ink.opacity(0.7)).frame(width: geo.size.width * CGFloat(a / total))
                            Capsule().fill(BP.edge2)
                        }
                    }
                    .frame(width: BP.px(300), height: BP.px(6))
                    Text(row.homeValue).font(BP.sans(13, .semibold)).foregroundStyle(BP.ink).frame(width: BP.px(60), alignment: .leading).monospacedDigit()
                    Text(row.label).font(BP.sans(12)).foregroundStyle(BP.inkMuted)
                }
            }
        }
    }

    private func eventsRow(_ events: [SportsEventModel.Event]) -> some View {
        VStack(alignment: .leading, spacing: BP.px(6)) {
            Text("Play by play").font(BP.sans(17, .semibold)).foregroundStyle(BP.ink)
            ForEach(events.suffix(10).reversed()) { e in
                HStack(spacing: BP.px(8)) {
                    Text(e.time).font(BP.sans(12, .semibold)).foregroundStyle(BP.inkMuted).frame(width: BP.px(48), alignment: .trailing)
                    Image(systemName: e.type == "goal" ? "soccerball" : e.type == "yellow_card" ? "rectangle.portrait.fill" : e.type == "red_card" ? "rectangle.portrait.fill" : e.type == "substitution" ? "arrow.left.arrow.right" : "circle.fill")
                        .font(.system(size: BP.px(10))).foregroundStyle(e.type == "yellow_card" ? .yellow : e.type == "red_card" ? BP.danger : BP.inkMuted)
                    Text(e.text).font(BP.sans(13)).foregroundStyle(BP.ink).lineLimit(1)
                }
            }
        }
    }

    private func lineups(_ d: SportsEventModel.Detail) -> some View {
        HStack(alignment: .top, spacing: BP.px(30)) {
            roster(game.away.name, d.awayRoster ?? [], d.awayFormation)
            roster(game.home.name, d.homeRoster ?? [], d.homeFormation)
        }
    }

    private func roster(_ title: String, _ players: [SportsEventModel.Player], _ formation: String?) -> some View {
        VStack(alignment: .leading, spacing: BP.px(4)) {
            Text(formation.map { "\(title) · \($0)" } ?? title).font(BP.sans(15, .semibold)).foregroundStyle(BP.ink)
            ForEach(players.filter(\.starter).prefix(11)) { p in
                HStack(spacing: BP.px(6)) {
                    Text(p.jersey).font(BP.sans(11)).foregroundStyle(BP.inkSubtle).frame(width: BP.px(24), alignment: .trailing)
                    Text(p.name).font(BP.sans(13)).foregroundStyle(BP.ink).lineLimit(1)
                    Text(p.position).font(BP.sans(11)).foregroundStyle(BP.inkSubtle)
                }
            }
        }
        .frame(width: BP.px(420), alignment: .leading)
    }
}
