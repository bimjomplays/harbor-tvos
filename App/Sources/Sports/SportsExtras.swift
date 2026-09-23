import SwiftUI

/// bp-sports-event-rows BpSportsStandingsRow: the league table (rank, team, the league's columns).
struct StandingsSection: View {
    let league: String
    @State private var table: Table?
    @State private var loaded = false
    @State private var group = 0
    struct Column: Decodable, Identifiable { var name: String; var label: String; var abbr: String; var id: String { name } }
    struct Cell: Decodable { var name: String; var display: String? ; var value: AnyJSON? }
    struct Row: Decodable, Identifiable {
        var teamId: String; var name: String; var shortName: String?; var abbr: String?; var logo: String?; var rank: Int?; var note: String?
        /// standings.ts: the per-column stats live in `cells`, keyed by the column's raw name (league-guide.tsx).
        var cells: [Cell]?
        var id: String { teamId }
        func value(for column: Column) -> String {
            guard let cell = cells?.first(where: { $0.name == column.name }) else { return "–" }
            if let d = cell.display, !d.isEmpty { return d }
            if let v = cell.value { return v.string ?? v.number.map { $0 == $0.rounded() ? String(Int($0)) : String(format: "%.1f", $0) } ?? "–" }
            return "–"
        }
    }
    struct Group: Decodable, Identifiable { var id: String; var name: String; var rows: [Row] }
    struct Table: Decodable { var leagueTag: String; var leagueName: String; var season: String; var columns: [Column]; var groups: [Group] }

    var body: some View {
        VStack(alignment: .leading, spacing: BP.px(8)) {
            if let t = table, !t.groups.isEmpty {
                HStack(spacing: BP.px(10)) {
                    Text("Standings").font(BP.sans(17, .bold)).foregroundStyle(BP.ink)
                    Text(t.season).font(BP.sans(12)).foregroundStyle(BP.inkSubtle)
                    if t.groups.count > 1 {
                        ForEach(Array(t.groups.enumerated()), id: \.offset) { i, g in Button(g.name) { group = i }.buttonStyle(BPActionStyle(primary: group == i)) }
                    }
                }
                let cols = Array(t.columns.prefix(6))
                let rows = t.groups[min(group, t.groups.count - 1)].rows
                HStack(spacing: BP.px(8)) {
                    Text("#").frame(width: BP.px(28), alignment: .trailing)
                    Text("Team").frame(width: BP.px(280), alignment: .leading)
                    ForEach(cols) { c in Text(c.abbr.isEmpty ? c.label : c.abbr).frame(width: BP.px(56), alignment: .trailing) }
                }
                .font(BP.sans(10.5, .bold)).foregroundStyle(BP.inkSubtle).textCase(.uppercase)
                ForEach(rows.prefix(20)) { r in
                    HStack(spacing: BP.px(8)) {
                        Text("\(r.rank ?? 0)").frame(width: BP.px(28), alignment: .trailing).foregroundStyle(BP.inkMuted)
                        HStack(spacing: BP.px(8)) {
                            if let l = r.logo, !l.isEmpty { RemoteImage(url: l, contentMode: .fit).frame(width: BP.px(20), height: BP.px(20)) }
                            Text(r.name).lineLimit(1)
                            if let n = r.note, !n.isEmpty { Text(n).font(BP.sans(10)).foregroundStyle(BP.inkSubtle) }
                        }
                        .frame(width: BP.px(280), alignment: .leading)
                        ForEach(cols) { c in
                            Text(r.value(for: c)).frame(width: BP.px(56), alignment: .trailing).monospacedDigit()
                        }
                    }
                    .font(BP.sans(13, .medium)).foregroundStyle(BP.ink)
                }
                .focusable()
            } else if loaded {
                EmptyView()
            }
        }
        .task(id: league) {
            table = try? await HarborEngine.shared.call("sports.standings", [league])
            loaded = true
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
            guard game.artwork == nil, game.poster == nil else { return }
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let a: Art = try? await HarborEngine.shared.call("sports.artwork", [game]) else { return }
            url = a.backdrop ?? a.poster
        }
    }
}
