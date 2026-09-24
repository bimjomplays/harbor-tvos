import SwiftUI

/// `sports.eventRows` (engine/sportsEvent.ts): the event screen's Stats and Lineups rows. The
/// engine ports the upstream data logic; these views draw it with SwiftUI shapes on upstream's
/// percentages (bp-sports-live-*.tsx, bp-sports-extra-pitch/-players.tsx, bp-sports-event-rows.tsx).
struct SportsEventRows: Decodable {
    struct Seat: Decodable { var jersey: String; var name: String; var left: Double; var top: Double }
    struct Court: Decodable { var homeName: String; var awayName: String; var home: [Seat]; var away: [Seat] }
    struct Diamond: Decodable { var bases: [Bool]; var balls: Int?; var strikes: Int?; var outs: Int?; var batter: String; var pitcher: String; var runners: String }
    struct Owner: Decodable { var name: String; var abbr: String; var logo: String }
    struct Field: Decodable { var down: Int?; var distance: Int?; var owner: Owner?; var marker: Double; var yardLine: String }
    struct Situation: Decodable { var kind: String; var caption: String; var diamond: Diamond?; var field: Field?; var court: Court? }
    struct Play: Decodable { var id: String; var time: String; var text: String; var participant: String; var icon: String; var loud: Bool }
    struct Plays: Decodable { var caption: String; var total: Int; var rows: [Play] }
    struct Line: Decodable { var label: String; var awayValue: String; var homeValue: String; var bar: Bool; var share: Double }
    struct Team: Decodable { var caption: String; var paired: Int; var lines: [Line] }
    struct Stats: Decodable { var title: String; var situation: Situation?; var plays: Plays?; var team: Team? }

    struct Spot: Decodable { var home: Bool; var jersey: String; var name: String; var left: Double; var top: Double; var goals: Int; var out: Bool }
    struct Pitch: Decodable { var homeName: String; var awayName: String; var homeFormation: String; var awayFormation: String; var spots: [Spot]; var bench: [String] }
    struct Member: Decodable { var id: String; var name: String; var jersey: String; var position: String; var starter: Bool }
    struct LineupSide: Decodable { var name: String; var formation: String; var players: [Member]; var starters: Int }
    struct TableRow: Decodable { var id: String; var name: String; var image: String?; var values: [String] }
    struct Table: Decodable { var key: String; var heading: String; var summary: String; var labels: [String]; var rows: [TableRow]; var trimmed: Int }
    struct Lineups: Decodable { var title: String; var pitch: Pitch?; var away: LineupSide?; var home: LineupSide?; var players: [Table] }

    var stats: Stats?
    var lineups: Lineups?
}

// MARK: - Panel kit (bp-sports-extra-kit BpSportsPanelRow / BpSportsPanelCell)

/// One rail of panel cells under a row title (BpSportsPanelRow).
struct SportsPanelRow<Content: View>: View {
    let title: String
    var foot: String? = nil
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: BP.px(8)) {
            Text(title).font(BP.sans(17, .semibold)).foregroundStyle(BP.ink)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: BP.px(14)) { content() }
                    .padding(.vertical, BP.px(10))
            }
            .scrollClipDisabled()
            if let foot, !foot.isEmpty { Text(foot).font(BP.sans(11)).foregroundStyle(BP.inkSubtle).frame(maxWidth: BP.px(1100), alignment: .leading) }
        }
        .focusSection()
    }
}

/// A focusable panel cell; Select runs `action` (expand / collapse, open a link), `foot` is the
/// "Show all N" / "Show less" line (BpSportsPanelCell).
struct SportsPanelCell<Content: View>: View {
    let width: CGFloat
    var foot: String = ""
    var padded = true
    var action: (() -> Void)? = nil
    @ViewBuilder let content: () -> Content
    var body: some View {
        Button { action?() } label: {
            VStack(alignment: .leading, spacing: BP.px(10)) {
                content()
                if !foot.isEmpty { Text(foot).font(BP.sans(12, .semibold)).foregroundStyle(BP.inkMuted) }
            }
            .padding(padded ? BP.px(18) : 0)
            .frame(width: width, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: BP.rMD, style: .continuous).fill(BP.panel))
            .clipShape(RoundedRectangle(cornerRadius: BP.rMD, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: BP.rMD, style: .continuous).stroke(BP.edge, lineWidth: 1))
        }
        .buttonStyle(BPTileStyle(radius: BP.rMD))
    }
}

/// BP_SPORTS_TIP caption over a cell.
private struct SportsTip: View {
    let text: String
    var body: some View {
        if !text.isEmpty { Text(T(text)).font(BP.sans(11, .bold)).textCase(.uppercase).tracking(0.8).foregroundStyle(BP.inkSubtle).lineLimit(1) }
    }
}

/// bp-sports-live-kit BpLiveFigure: a big number over its label.
private struct LiveFigure: View {
    let value: String
    let label: String
    var body: some View {
        VStack(alignment: .leading, spacing: BP.px(4)) {
            Text(value).font(BP.display(40)).foregroundStyle(BP.ink).monospacedDigit()
            Text(T(label)).font(BP.sans(11, .semibold)).foregroundStyle(BP.inkMuted).lineLimit(1)
        }
        .frame(minWidth: BP.px(70), alignment: .leading)
    }
}

/// bp-sports-live-kit BpLivePips (outs).
private struct LivePips: View {
    let filled: Int
    let total: Int
    let label: String
    var body: some View {
        VStack(alignment: .leading, spacing: BP.px(10)) {
            HStack(spacing: BP.px(8)) {
                ForEach(0..<total, id: \.self) { i in Circle().fill(i < filled ? BP.ink : BP.edge2).frame(width: BP.px(20), height: BP.px(20)) }
            }
            Text(T(label)).font(BP.sans(11, .semibold)).foregroundStyle(BP.inkMuted)
        }
    }
}

/// bp-sports-live-kit BpLiveSeat: a jersey disc and a name on percentage coordinates.
private struct LiveSeat: View {
    let jersey: String
    let name: String
    let home: Bool
    var faded = false
    var goals = 0
    var body: some View {
        VStack(spacing: 3) {
            ZStack(alignment: .topTrailing) {
                Text(jersey.isEmpty ? "-" : jersey).font(BP.sans(10, .bold)).monospacedDigit().foregroundStyle(BP.ink)
                    .frame(width: BP.px(30), height: BP.px(30))
                    .background(Circle().fill(home ? BP.on : BP.void_.opacity(0.85)))
                    .overlay(Circle().stroke(home ? Color.clear : BP.edge2, lineWidth: 1))
                if goals > 0 {
                    Text("\(goals)").font(BP.sans(9, .bold)).foregroundStyle(BP.ink)
                        .frame(width: BP.px(17), height: BP.px(17))
                        .background(Circle().fill(BP.void_)).overlay(Circle().stroke(BP.on, lineWidth: 1))
                        .offset(x: BP.px(6), y: -BP.px(6))
                }
            }
            Text(name).font(BP.sans(10, .semibold)).foregroundStyle(BP.ink).lineLimit(1).shadow(color: BP.void_, radius: 2)
        }
        .frame(width: BP.px(70))
        .opacity(faded ? 0.45 : 1)
    }
}

/// Places `content` centred on (left %, top %) of a surface of `size`.
private func placed<V: View>(_ v: V, left: Double, top: Double, in size: CGSize) -> some View {
    v.position(x: size.width * CGFloat(left / 100), y: size.height * CGFloat(top / 100))
}

// MARK: - Stats row (BpSportsStatsRow)

struct SportsStatsRowView: View {
    let stats: SportsEventRows.Stats
    @State private var playsOpen = false
    @State private var statsOpen = false

    var body: some View {
        SportsPanelRow(title: stats.title) {
            if let s = stats.situation { situationCell(s) }
            if let p = stats.plays { playsCell(p) }
            if let t = stats.team { teamCell(t) }
        }
    }

    // bp-sports-live-situation: the diamond is the narrow cell, field and court the wide one.
    @ViewBuilder private func situationCell(_ s: SportsEventRows.Situation) -> some View {
        SportsPanelCell(width: BP.px(s.kind == "diamond" ? 520 : 760)) {
            SportsTip(text: s.caption)
            if let d = s.diamond { SportsDiamondView(d: d) }
            if let f = s.field { SportsFieldView(f: f) }
            if let c = s.court { SportsCourtView(c: c) }
        }
    }

    // bp-sports-live-plays: newest first, 6 collapsed, 24 open; scoring plays are loud.
    @ViewBuilder private func playsCell(_ p: SportsEventRows.Plays) -> some View {
        let shown = Array(p.rows.prefix(playsOpen ? 24 : 6))
        let rest = p.rows.count - shown.count
        SportsPanelCell(width: BP.px(700), foot: playsOpen ? T("Show less") : rest > 0 ? T("Show all %lld", min(p.total, 24)) : "",
                        action: { if rest > 0 || playsOpen { playsOpen.toggle() } }) {
            SportsTip(text: p.caption)
            ForEach(Array(shown.enumerated()), id: \.offset) { _, e in
                HStack(alignment: .top, spacing: BP.px(12)) {
                    Text(e.time).font(BP.sans(11, .semibold)).foregroundStyle(BP.inkMuted).frame(width: BP.px(70), alignment: .leading)
                    Image(systemName: Self.symbol(e.icon))
                        .font(.system(size: BP.px(13), weight: .semibold))
                        .foregroundStyle(e.icon == "yellow_card" ? Color(hex: 0xf3c84d) : e.icon == "red_card" ? Color(hex: 0xe43a44) : e.loud ? BP.canvas : BP.inkSubtle)
                        .frame(width: BP.px(32), height: BP.px(32))
                        .background(Circle().fill(e.loud ? BP.ink : BP.void_.opacity(0.6)))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(e.text).font(BP.sans(13, e.loud ? .semibold : .regular)).foregroundStyle(e.loud ? BP.ink : BP.inkMuted).lineLimit(2)
                        if !e.participant.isEmpty { Text(e.participant).font(BP.sans(11)).foregroundStyle(BP.inkSubtle).lineLimit(1) }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, BP.px(8)).padding(.vertical, BP.px(6))
                .background(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).fill(e.loud ? BP.on : Color.clear))
            }
        }
    }

    // BpTeamStatsCell: 8 paired rows until opened; bars show the away share.
    @ViewBuilder private func teamCell(_ t: SportsEventRows.Team) -> some View {
        let more = t.lines.count > t.paired
        let shown = statsOpen ? t.lines : Array(t.lines.prefix(t.paired))
        SportsPanelCell(width: BP.px(shown.count <= 6 ? 560 : 820), foot: more ? (statsOpen ? T("Show less") : T("Show all %lld", t.lines.count)) : "",
                        action: { if more { statsOpen.toggle() } }) {
            SportsTip(text: t.caption)
            let columns = shown.count <= 6 ? 1 : 2
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: BP.px(28), alignment: .top), count: columns), alignment: .leading, spacing: BP.px(12)) {
                ForEach(Array(shown.enumerated()), id: \.offset) { _, line in
                    VStack(spacing: 5) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(line.awayValue).font(BP.sans(15, .semibold)).foregroundStyle(BP.ink).monospacedDigit()
                            Spacer(minLength: BP.px(8))
                            Text(line.label).font(BP.sans(11, .semibold)).foregroundStyle(BP.inkMuted).lineLimit(1)
                            Spacer(minLength: BP.px(8))
                            Text(line.homeValue).font(BP.sans(15, .semibold)).foregroundStyle(BP.ink).monospacedDigit()
                        }
                        if line.bar {
                            GeometryReader { geo in
                                HStack(spacing: 0) {
                                    Rectangle().fill(BP.on).frame(width: geo.size.width * CGFloat(max(0, min(100, line.share)) / 100))
                                    Rectangle().fill(BP.edge2)
                                }
                            }
                            .frame(height: BP.px(6))
                            .clipShape(Capsule())
                        }
                    }
                }
            }
        }
    }

    /// Stand-ins for PlayEventIcon's glyphs (views/sports/play-event-icon.tsx), by playIcon kind.
    static func symbol(_ kind: String) -> String {
        switch kind {
        case "goal": return "soccerball"
        case "yellow_card", "red_card": return "rectangle.portrait.fill"
        case "substitution": return "arrow.left.arrow.right"
        case "timeout": return "timer"
        case "interception": return "arrow.uturn.right"
        case "fumble": return "exclamationmark.circle"
        case "touchdown": return "flag.checkered"
        case "kick": return "figure.australian.football"
        case "sack": return "xmark"
        case "incomplete": return "xmark.circle"
        case "pass": return "arrow.up.right"
        case "penalty": return "flag.fill"
        case "homerun": return "house.fill"
        case "strikeout": return "k.circle"
        case "three": return "3.circle"
        case "score": return "circle.circle"
        case "save": return "shield.lefthalf.filled"
        case "run": return "figure.run"
        case "finish": return "star.fill"
        case "period": return "clock"
        default: return "play.fill"
        }
    }
}

/// bp-sports-live-diamond: the infield square, three bases (filled when held), home plate, then
/// balls / strikes / outs and who is at bat and pitching.
struct SportsDiamondView: View {
    let d: SportsEventRows.Diamond
    private static let corners: [(left: Double, top: Double)] = [(88, 50), (50, 12), (12, 50)]
    var body: some View {
        VStack(alignment: .leading, spacing: BP.px(14)) {
            HStack(alignment: .bottom, spacing: BP.px(34)) {
                GeometryReader { geo in
                    let size = geo.size
                    let base = BP.px(24)
                    ZStack {
                        Rectangle().fill(BP.panel2).overlay(Rectangle().stroke(BP.edge2, lineWidth: 1))
                            .frame(width: size.width * 0.54, height: size.height * 0.54).rotationEffect(.degrees(45))
                            .position(x: size.width / 2, y: size.height / 2)
                        Circle().fill(BP.edge2).frame(width: BP.px(11), height: BP.px(11)).position(x: size.width / 2, y: size.height / 2)
                        ForEach(0..<3, id: \.self) { i in
                            let held = d.bases.indices.contains(i) && d.bases[i]
                            RoundedRectangle(cornerRadius: 3).fill(held ? BP.ink : BP.panel)
                                .overlay(RoundedRectangle(cornerRadius: 3).stroke(held ? Color.clear : BP.edge2, lineWidth: 1))
                                .frame(width: base, height: base).rotationEffect(.degrees(45))
                                .position(x: size.width * CGFloat(Self.corners[i].left / 100), y: size.height * CGFloat(Self.corners[i].top / 100))
                        }
                        RoundedRectangle(cornerRadius: 3).fill(BP.edge2).frame(width: base, height: base).rotationEffect(.degrees(45))
                            .position(x: size.width * 0.5, y: size.height * 0.88)
                    }
                }
                .frame(width: BP.px(200), height: BP.px(200))
                HStack(alignment: .bottom, spacing: BP.px(26)) {
                    if let b = d.balls { LiveFigure(value: "\(b)", label: "Balls") }
                    if let s = d.strikes { LiveFigure(value: "\(s)", label: "Strikes") }
                    if let o = d.outs { LivePips(filled: o, total: 3, label: "Outs") }
                }
            }
            if !d.batter.isEmpty || !d.pitcher.isEmpty {
                HStack(spacing: BP.px(34)) {
                    if !d.batter.isEmpty { labelled("At bat", d.batter) }
                    if !d.pitcher.isEmpty { labelled("Pitching", d.pitcher) }
                }
            }
            if !d.runners.isEmpty { Text(d.runners).font(BP.sans(12, .semibold)).foregroundStyle(BP.inkMuted).lineLimit(1) }
        }
    }
    private func labelled(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(T(label)).font(BP.sans(11, .semibold)).foregroundStyle(BP.inkMuted)
            Text(value).font(BP.sans(15, .semibold)).foregroundStyle(BP.ink).lineLimit(1)
        }
    }
}

/// bp-sports-live-field: down, distance and possession, then a 16:4 field with 8 % end zones,
/// nine yard ticks and the ball marker on the provider's yard line.
struct SportsFieldView: View {
    let f: SportsEventRows.Field
    var body: some View {
        VStack(alignment: .leading, spacing: BP.px(12)) {
            HStack(alignment: .bottom, spacing: BP.px(30)) {
                if let down = f.down { LiveFigure(value: "\(down)", label: "Current down") }
                if let dist = f.distance { LiveFigure(value: "\(dist)", label: "Distance") }
                if let o = f.owner {
                    VStack(alignment: .leading, spacing: BP.px(4)) {
                        HStack(spacing: BP.px(10)) {
                            if !o.logo.isEmpty { RemoteImage(url: o.logo, contentMode: .fit).frame(width: BP.px(36), height: BP.px(36)) }
                            Text(o.abbr).font(BP.sans(17, .semibold)).foregroundStyle(BP.ink).lineLimit(1)
                        }
                        Text("Ball possession").font(BP.sans(11, .semibold)).foregroundStyle(BP.inkMuted)
                    }
                }
            }
            GeometryReader { geo in
                let w = geo.size.width, h = geo.size.height
                ZStack(alignment: .topLeading) {
                    Rectangle().fill(BP.panel2).frame(width: w * 0.08, height: h)
                    Rectangle().fill(BP.panel2).frame(width: w * 0.08, height: h).offset(x: w * 0.92)
                    ForEach(1..<10, id: \.self) { tick in
                        Rectangle().fill(BP.edge2).frame(width: 1, height: h * 0.72).offset(x: w * CGFloat(8 + Double(tick) * 8.4) / 100, y: h * 0.14)
                    }
                    if f.marker >= 0 {
                        Rectangle().fill(BP.ink).frame(width: BP.px(4), height: h).offset(x: w * CGFloat(f.marker / 100) - BP.px(2))
                    }
                }
            }
            .aspectRatio(16 / 4, contentMode: .fit)
            .background(BP.void_.opacity(0.55))
            .clipShape(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).stroke(BP.edge, lineWidth: 1))
            if !f.yardLine.isEmpty { Text(T("Yard line") + ": " + f.yardLine).font(BP.sans(12, .semibold)).foregroundStyle(BP.inkMuted).lineLimit(1) }
            Text("Latest reported play").font(BP.sans(12, .semibold)).foregroundStyle(BP.inkMuted)
        }
    }
}

/// bp-sports-live-court: a 16:9 court (boundary, half line, centre circle, keys, arcs) with both
/// starting fives on their lineup spots.
struct SportsCourtView: View {
    let c: SportsEventRows.Court
    var body: some View {
        VStack(alignment: .leading, spacing: BP.px(10)) {
            HStack {
                Text(c.homeName).font(BP.sans(15, .semibold)).foregroundStyle(BP.ink).lineLimit(1)
                Spacer()
                Text(c.awayName).font(BP.sans(15, .semibold)).foregroundStyle(BP.ink).lineLimit(1)
            }
            GeometryReader { geo in
                let size = geo.size, w = size.width, h = size.height
                ZStack {
                    Rectangle().stroke(BP.edge2, lineWidth: 1).frame(width: w * 0.94, height: h * 0.94).position(x: w / 2, y: h / 2)
                    Rectangle().fill(BP.edge2).frame(width: 1, height: h * 0.94).position(x: w / 2, y: h / 2)
                    Ellipse().stroke(BP.edge2, lineWidth: 1).frame(width: w * 0.15, height: h * 0.26).position(x: w / 2, y: h / 2)
                    Rectangle().stroke(BP.edge2, lineWidth: 1).frame(width: w * 0.17, height: h * 0.38).position(x: w * (0.03 + 0.085), y: h / 2)
                    Rectangle().stroke(BP.edge2, lineWidth: 1).frame(width: w * 0.17, height: h * 0.38).position(x: w * (0.97 - 0.085), y: h / 2)
                    UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 0, bottomTrailingRadius: h * 0.34, topTrailingRadius: h * 0.34)
                        .stroke(BP.edge2, lineWidth: 1).frame(width: w * 0.34, height: h * 0.68).position(x: w * (0.03 + 0.17), y: h / 2)
                    UnevenRoundedRectangle(topLeadingRadius: h * 0.34, bottomLeadingRadius: h * 0.34, bottomTrailingRadius: 0, topTrailingRadius: 0)
                        .stroke(BP.edge2, lineWidth: 1).frame(width: w * 0.34, height: h * 0.68).position(x: w * (0.97 - 0.17), y: h / 2)
                    ForEach(Array(c.home.enumerated()), id: \.offset) { _, s in placed(LiveSeat(jersey: s.jersey, name: s.name, home: true), left: s.left, top: s.top, in: size) }
                    ForEach(Array(c.away.enumerated()), id: \.offset) { _, s in placed(LiveSeat(jersey: s.jersey, name: s.name, home: false), left: s.left, top: s.top, in: size) }
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .background(BP.void_.opacity(0.55))
            .clipShape(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).stroke(BP.edge, lineWidth: 1))
            Text("Lineup positions, not live player tracking.").font(BP.sans(11)).foregroundStyle(BP.inkSubtle)
        }
    }
}

// MARK: - Lineups row (BpSportsLineupsRow)

struct SportsLineupsRowView: View {
    let lineups: SportsEventRows.Lineups
    @State private var benchOpen = false
    @State private var openSides: Set<String> = []
    @State private var openTables: Set<String> = []

    var body: some View {
        SportsPanelRow(title: lineups.title) {
            if let p = lineups.pitch { pitchCell(p) }
            if let a = lineups.away { sideCell(a, key: "away") }
            if let h = lineups.home { sideCell(h, key: "home") }
            ForEach(lineups.players, id: \.key) { t in tableCell(t) }
        }
    }

    // bp-sports-extra-pitch: horizontal pitch, both formations, the bench on Select.
    @ViewBuilder private func pitchCell(_ p: SportsEventRows.Pitch) -> some View {
        SportsPanelCell(width: BP.px(1060), foot: p.bench.isEmpty ? "" : T(benchOpen ? "Hide bench" : "Show bench"), action: { benchOpen.toggle() }) {
            HStack(alignment: .firstTextBaseline) {
                Text(p.homeName).font(BP.sans(15, .semibold)).foregroundStyle(BP.ink).lineLimit(1)
                Spacer()
                SportsTip(text: "On the pitch")
                Spacer()
                Text(p.awayName).font(BP.sans(15, .semibold)).foregroundStyle(BP.ink).lineLimit(1)
            }
            HStack {
                Text(p.homeFormation).font(BP.sans(11, .semibold)).foregroundStyle(BP.inkMuted)
                Spacer()
                Text(p.awayFormation).font(BP.sans(11, .semibold)).foregroundStyle(BP.inkMuted)
            }
            GeometryReader { geo in
                let size = geo.size, w = size.width, h = size.height
                ZStack {
                    // Grass: alternating 7.5 % stripes.
                    HStack(spacing: 0) {
                        ForEach(0..<14, id: \.self) { i in Rectangle().fill(i.isMultiple(of: 2) ? BP.panel2 : BP.panel) }
                    }
                    Rectangle().stroke(BP.edge2, lineWidth: 1).frame(width: w * 0.95, height: h * 0.95).position(x: w / 2, y: h / 2)
                    Rectangle().fill(BP.edge2).frame(width: 1, height: h * 0.95).position(x: w / 2, y: h / 2)
                    Ellipse().stroke(BP.edge2, lineWidth: 1).frame(width: w * 0.14, height: h * 0.22).position(x: w / 2, y: h / 2)
                    Rectangle().stroke(BP.edge2, lineWidth: 1).frame(width: w * 0.13, height: h * 0.46).position(x: w * (0.025 + 0.065), y: h / 2)
                    Rectangle().stroke(BP.edge2, lineWidth: 1).frame(width: w * 0.13, height: h * 0.46).position(x: w * (0.975 - 0.065), y: h / 2)
                    Rectangle().stroke(BP.edge2, lineWidth: 1).frame(width: w * 0.05, height: h * 0.22).position(x: w * (0.025 + 0.025), y: h / 2)
                    Rectangle().stroke(BP.edge2, lineWidth: 1).frame(width: w * 0.05, height: h * 0.22).position(x: w * (0.975 - 0.025), y: h / 2)
                    ForEach(Array(p.spots.enumerated()), id: \.offset) { _, s in
                        placed(LiveSeat(jersey: s.jersey, name: s.name, home: s.home, faded: s.out, goals: s.goals), left: s.left, top: s.top, in: size)
                    }
                }
            }
            .aspectRatio(16 / 10, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous))
            Text("Positions are illustrative from the published lineup, not live tracking.").font(BP.sans(11)).foregroundStyle(BP.inkSubtle)
            if benchOpen && !p.bench.isEmpty {
                Text(T("Bench") + ": " + p.bench.joined(separator: ", ")).font(BP.sans(11)).foregroundStyle(BP.inkSubtle).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // BpLineupCell: the starters, then everyone on Select.
    @ViewBuilder private func sideCell(_ side: SportsEventRows.LineupSide, key: String) -> some View {
        let open = openSides.contains(key)
        let shown = open ? side.players : Array(side.players.prefix(side.starters))
        let rest = side.players.count - shown.count
        SportsPanelCell(width: BP.px(480), foot: rest > 0 ? T("Show all %lld", side.players.count) : open ? T("Show less") : "",
                        action: { if open { _ = openSides.remove(key) } else { _ = openSides.insert(key) } }) {
            HStack(alignment: .firstTextBaseline) {
                Text(side.name).font(BP.sans(15, .semibold)).foregroundStyle(BP.ink).lineLimit(1)
                Spacer()
                if !side.formation.isEmpty { Text(side.formation).font(BP.sans(11, .semibold)).foregroundStyle(BP.inkMuted) }
            }
            ForEach(Array(shown.enumerated()), id: \.offset) { _, p in
                HStack(spacing: BP.px(10)) {
                    Text(p.jersey).font(BP.sans(11)).foregroundStyle(BP.inkSubtle).frame(width: BP.px(34), alignment: .leading).monospacedDigit()
                    Text(p.name).font(BP.sans(13, .semibold)).foregroundStyle(BP.ink).lineLimit(1)
                    Spacer(minLength: 0)
                    Text(p.position).font(BP.sans(11)).foregroundStyle(BP.inkSubtle)
                }
            }
        }
    }

    // bp-sports-extra-players BpPlayerStatCell: six columns, six rows until opened.
    @ViewBuilder private func tableCell(_ t: SportsEventRows.Table) -> some View {
        let open = openTables.contains(t.key)
        let shown = open ? t.rows : Array(t.rows.prefix(6))
        let rest = t.rows.count - shown.count
        SportsPanelCell(width: BP.px(900), foot: rest > 0 ? T("Show all %lld", t.rows.count) : open ? T("Show less") : "",
                        action: { if open { _ = openTables.remove(t.key) } else { _ = openTables.insert(t.key) } }) {
            SportsTip(text: "Player statistics")
            Text(t.heading).font(BP.sans(15, .semibold)).foregroundStyle(BP.ink).lineLimit(1)
            if !t.summary.isEmpty { Text(t.summary).font(BP.sans(11)).foregroundStyle(BP.inkSubtle).lineLimit(2) }
            HStack(spacing: BP.px(12)) {
                Spacer().frame(maxWidth: .infinity)
                ForEach(Array(t.labels.enumerated()), id: \.offset) { _, l in
                    Text(l).font(BP.sans(11, .semibold)).foregroundStyle(BP.inkMuted).lineLimit(1).frame(width: BP.px(60), alignment: .trailing)
                }
            }
            ForEach(Array(shown.enumerated()), id: \.offset) { _, row in
                HStack(spacing: BP.px(12)) {
                    HStack(spacing: BP.px(8)) {
                        Group {
                            if let img = row.image, !img.isEmpty { RemoteImage(url: img) }
                            else { Image(systemName: "person.fill").font(.system(size: BP.px(13))).foregroundStyle(BP.inkSubtle) }
                        }
                        .frame(width: BP.px(30), height: BP.px(30)).background(Circle().fill(BP.void_.opacity(0.7))).clipShape(Circle())
                        Text(row.name).font(BP.sans(13, .semibold)).foregroundStyle(BP.ink).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    ForEach(Array(row.values.enumerated()), id: \.offset) { _, v in
                        Text(v).font(BP.sans(13)).foregroundStyle(BP.inkMuted).monospacedDigit().lineLimit(1).frame(width: BP.px(60), alignment: .trailing)
                    }
                }
            }
            if t.trimmed > 0 { Text("\(t.trimmed) more columns are on the desktop box score").font(BP.sans(11)).foregroundStyle(BP.inkSubtle) }
        }
    }
}
