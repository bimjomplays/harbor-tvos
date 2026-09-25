import SwiftUI

/// bp-sports-extra-tables BpSportsStandingsRow: the table of the group the game's teams play in
/// (useBpSportsEvent standingsGroup), a window of six rows around them with the teams in bold, and
/// "Show all {n}" / "Show less" in one focusable cell. (device-flow pass) It drew every group as a
/// chip in a header that ran off the page and 20 rows that each took the focus with no ring, so
/// Down walked through invisible stops before reaching the addon and venue rows.
struct StandingsSection: View {
    let league: String
    /// The game's two team ids (bold in the table; the table opens on their group).
    var highlight: [String] = []
    @State private var table: Table?
    @State private var expanded = false
    @State private var shownLeague: String?
    struct Row: Decodable, Identifiable {
        var teamId: String; var name: String; var shortName: String?; var abbr: String?; var logo: String?; var rank: Double?; var note: String?
        /// standings.ts StandingsRow: the fixed stat fields the Big Picture table shows.
        var played: Double?; var wins: Double?; var draws: Double?; var losses: Double?; var points: Double?
        var id: String { teamId }
    }
    struct Group: Decodable, Identifiable { var id: String; var name: String; var rows: [Row] }
    struct Table: Decodable { var groups: [Group] }

    private static let shownCount = 6

    /// use-bp-sports-event standingsGroup: the group holding the home team, else the away team, else the first.
    private var group: Group? {
        guard let t = table else { return nil }
        for id in highlight where !id.isEmpty {
            if let g = t.groups.first(where: { $0.rows.contains { $0.teamId == id } }) { return g }
        }
        return t.groups.first
    }

    /// bp-sports-extra-tables windowRows.
    private static func windowRows(_ rows: [Row], _ highlight: [String]) -> [Row] {
        let hits = rows.indices.filter { !rows[$0].teamId.isEmpty && highlight.contains(rows[$0].teamId) }
        guard let first = hits.min(), let last = hits.max() else { return Array(rows.prefix(shownCount)) }
        let start = max(0, min(first - 1, rows.count - shownCount))
        let end = min(rows.count, max(start + shownCount, last + 1))
        return Array(rows[start..<end])
    }

    private static func cell(_ v: Double?) -> String {
        guard let v else { return "-" }
        return v == v.rounded() ? String(Int(v)) : String(v)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .task(id: league) {
            // (device-flow pass 4) The task also runs when a cover over the event closes (the player,
            // Addon sources): only another league folds the table back or drops it, not every return
            // (a re-read that failed on return took the table off the page).
            let changed: Bool = shownLeague != league
            if changed { expanded = false; shownLeague = league }
            let fresh: Table? = try? await HarborEngine.shared.call("sports.standings", [league])
            if let fresh { table = fresh } else if changed { table = nil }
        }
    }

    @ViewBuilder private var content: some View {
        if let g = group, !g.rows.isEmpty {
            let shown = expanded ? g.rows : Self.windowRows(g.rows, highlight)
            let rest = g.rows.count - shown.count
            let drawn = g.rows.contains { $0.draws != nil }
            let heads: [String] = drawn ? ["Played", "Won", "Drawn", "Lost", "Points"] : ["Played", "Won", "Lost", "Points"]
            SportsPanelRow(title: g.name.isEmpty ? "Standings" : g.name) {
                SportsPanelCell(width: BP.px(680),
                                foot: rest > 0 ? T("Show all %lld", g.rows.count) : expanded ? T("Show less") : "",
                                action: { if rest > 0 || expanded { expanded.toggle() } }) {
                    VStack(alignment: .leading, spacing: BP.px(7)) {
                        HStack(spacing: BP.px(12)) {
                            Color.clear.frame(width: BP.px(30), height: 1)
                            Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
                            ForEach(heads, id: \.self) { h in
                                Text(T(h)).font(BP.sans(10, .bold)).textCase(.uppercase).tracking(0.8).foregroundStyle(BP.inkSubtle)
                                    .lineLimit(1).minimumScaleFactor(0.7).frame(width: BP.px(58), alignment: .trailing)
                            }
                        }
                        ForEach(shown) { r in
                            let on = highlight.contains(r.teamId)
                            let values: [Double?] = drawn ? [r.played, r.wins, r.draws, r.losses, r.points] : [r.played, r.wins, r.losses, r.points]
                            HStack(spacing: BP.px(12)) {
                                Text(verbatim: r.rank.map { Self.cell($0) } ?? "").font(BP.sans(12, .bold)).monospacedDigit().foregroundStyle(BP.inkSubtle)
                                    .frame(width: BP.px(30), alignment: .leading)
                                Text(verbatim: (r.shortName ?? "").isEmpty ? r.name : (r.shortName ?? r.name)).font(BP.sans(14, on ? .bold : .semibold))
                                    .foregroundStyle(on ? BP.ink : BP.inkMuted).lineLimit(1)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                ForEach(Array(values.enumerated()), id: \.offset) { _, v in
                                    Text(verbatim: Self.cell(v)).font(BP.sans(13.5, on ? .bold : .semibold)).monospacedDigit()
                                        .foregroundStyle(on ? BP.ink : BP.inkMuted).frame(width: BP.px(58), alignment: .trailing)
                                }
                            }
                        }
                    }
                }
            }
            .padding(.top, BP.px(10))
        }
    }
}

/// lib/sports/hub-artwork through the engine: a card with no art of its own asks TheSportsDB.
struct SportsArtView: View {
    let game: SportsModel.Game
    var width: CGFloat
    @State private var url: String?
    struct Art: Decodable { var backdrop: String?; var poster: String? }
    var body: some View {
        Group {
            if let u = url ?? game.artwork ?? game.poster {
                RemoteImage(url: u).frame(width: width).clipped().opacity(0.5)
                    .mask(LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing))
            }
        }
        .task(id: game.id) {
            // (bug pass) The hero reuses this view as it cycles games every 7 s: the art fetched for
            // the previous game stayed in `url` and won over the next game's own art (and stayed
            // when the next game's lookup found nothing).
            url = nil
            guard game.artwork == nil, game.poster == nil else { return }
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let a: Art = try? await HarborEngine.shared.call("sports.artwork", [game.wire]),
                  !Task.isCancelled else { return }
            url = a.backdrop ?? a.poster
        }
    }
}
