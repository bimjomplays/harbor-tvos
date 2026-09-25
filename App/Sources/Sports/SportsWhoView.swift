import SwiftUI

/// bp-sports-who-panel.tsx: a team or athlete profile for one side of a game; roster players open
/// as athletes (Back returns to the team).
struct SportsWhoView: View {
    let game: SportsModel.Game
    let side: String          // "home" | "away"
    @Environment(\.dismiss) private var dismiss
    @State private var stack: [Who] = []
    @State private var loading = true
    /// The roster player whose page is loading (openPlayer).
    @State private var openingPlayer: String?
    struct Who: Decodable, Identifiable {
        struct Stat: Decodable { var name: String; var value: String }
        struct Fact: Decodable { var label: String; var value: String }
        struct Link: Decodable { var label: String; var url: String }
        struct Player: Decodable, Identifiable { var id: String; var name: String; var image: String?; var position: String?; var jersey: String?; var source: String }
        var kind: String; var key: String; var name: String; var art: String; var eyebrow: String; var lead: String; var body: String; var note: String
        var figures: [Stat]; var facts: [Fact]; var link: Link?; var roster: [Player]
        var id: String { key }
    }

    var body: some View {
        ZStack {
            BP.void_.opacity(0.94).ignoresSafeArea()
            if let w = stack.last {
                HStack(alignment: .top, spacing: BP.px(30)) {
                    VStack(alignment: .leading, spacing: BP.px(12)) {
                        Text([T(w.eyebrow), game.leagueLabel].filter { !$0.isEmpty }.joined(separator: " · ")).font(BP.sans(11, .bold)).textCase(.uppercase).tracking(1).foregroundStyle(BP.accent)
                        Text(w.name).font(BP.display(40)).foregroundStyle(BP.ink).lineLimit(2)
                        if !w.lead.isEmpty { Text(w.lead).font(BP.sans(15, .medium)).foregroundStyle(BP.inkMuted) }
                        if !w.figures.isEmpty {
                            HStack(spacing: BP.px(18)) {
                                ForEach(Array(w.figures.enumerated()), id: \.offset) { _, f in
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(f.value).font(BP.display(26)).foregroundStyle(BP.ink).monospacedDigit()
                                        Text(f.name).font(BP.sans(11)).foregroundStyle(BP.inkSubtle)
                                    }
                                }
                            }
                        }
                        ScrollView(.vertical, showsIndicators: false) {
                            VStack(alignment: .leading, spacing: BP.px(10)) {
                                if !w.body.isEmpty { Text(w.body).font(BP.sans(14)).foregroundStyle(BP.inkMuted).lineLimit(8).focusable() }
                                ForEach(Array(w.facts.enumerated()), id: \.offset) { _, f in
                                    HStack(alignment: .top, spacing: BP.px(8)) {
                                        Text(T(f.label)).font(BP.sans(12, .bold)).foregroundStyle(BP.inkSubtle).frame(width: BP.px(150), alignment: .leading)
                                        Text(f.value).font(BP.sans(12)).foregroundStyle(BP.inkMuted)
                                    }
                                }
                                if !w.roster.isEmpty {
                                    Text("Roster").font(BP.sans(15, .bold)).foregroundStyle(BP.ink).padding(.top, BP.px(6))
                                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(BP.px(250)), spacing: BP.px(8)), count: 3), spacing: BP.px(8)) {
                                        ForEach(w.roster) { p in
                                            Button { Task { await openPlayer(p) } } label: {
                                                HStack(spacing: BP.px(8)) {
                                                    RemoteImage(url: p.image).frame(width: BP.px(30), height: BP.px(30)).clipShape(Circle())
                                                    VStack(alignment: .leading, spacing: 1) {
                                                        Text(p.name).font(BP.sans(12, .semibold)).foregroundStyle(BP.ink).lineLimit(1)
                                                        Text([p.jersey.map { "#\($0)" }, p.position].compactMap { $0 }.joined(separator: " · ")).font(BP.sans(10)).foregroundStyle(BP.inkSubtle).lineLimit(1)
                                                    }
                                                }
                                                .frame(width: BP.px(250), alignment: .leading).padding(.horizontal, BP.px(10)).padding(.vertical, BP.px(6))
                                                .background(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).fill(BP.panel2))
                                            }
                                            .buttonStyle(BPTileStyle(radius: BP.rSM))
                                        }
                                    }
                                }
                                if !w.note.isEmpty { BPNote(text: w.note) }
                                if let l = w.link { Text(T(l.label) + ": " + l.url).font(BP.sans(11)).foregroundStyle(BP.inkSubtle) }
                            }
                        }
                        HStack(spacing: BP.px(10)) {
                            if stack.count > 1 { Button("Back") { _ = stack.popLast() }.buttonStyle(BPActionStyle()) }
                            Button("Close") { dismiss() }.buttonStyle(BPActionStyle(primary: true))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if !w.art.isEmpty { RemoteImage(url: w.art, contentMode: .fit).frame(width: BP.px(420), height: BP.px(520)).clipShape(RoundedRectangle(cornerRadius: BP.rMD, style: .continuous)) }
                }
                .padding(BP.gutter).padding(.top, BP.px(40))
            } else if loading {
                ProgressView().tint(BP.inkMuted)
            } else {
                VStack(spacing: BP.px(12)) {
                    Text("Profile details could not be loaded.").font(BP.sans(16)).foregroundStyle(BP.inkMuted)
                    Button("Close") { dismiss() }.buttonStyle(BPActionStyle(primary: true))
                }
            }
        }
        .onExitCommand { if stack.count > 1 { _ = stack.popLast() } else { dismiss() } }
        .task {
            if let w: Who = try? await HarborEngine.shared.call("sports.who", [game.wire, side]) { stack = [w] }
            loading = false
        }
    }

    private func openPlayer(_ p: Who.Player) async {
        struct Out: Encodable { var id: String; var name: String; var image: String?; var source: String }
        // (bug pass) The athlete fetch runs up to its timeout: a second press pushed the athlete
        // twice (Back then showed the same page), and an answer landing after Back or on another
        // player's page stacked on the wrong one. Only the page that asked, once.
        guard openingPlayer == nil else { return }
        openingPlayer = p.id
        let depth = stack.count
        let top = stack.last?.key
        defer { openingPlayer = nil }
        if let w: Who = try? await HarborEngine.shared.call("sports.whoPlayer", [game.league, Out(id: p.id, name: p.name, image: p.image, source: p.source)]),
           stack.count == depth, stack.last?.key == top {
            stack.append(w)
        }
    }
}
