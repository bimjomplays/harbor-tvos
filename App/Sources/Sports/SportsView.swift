import SwiftUI

/// Sports room (bp-sports.tsx): chips → date band (schedule) → status note → hero + rows,
/// or the Explore grid, or the consent notice before anything else.
struct SportsView: View {
    @StateObject private var model = SportsModel()
    @State private var event: SportsModel.Game?
    @State private var personalize = false
    @State private var heroIndex = 0

    @State private var directPlay: SportsEventModel.WatchOption?
    @State private var directStream: SportsAddonPanelView.Play?

    /// useBpWatchGame: a live game with an attached stream, or an exact (or pinned) channel match,
    /// plays at once; anything else opens the event.
    private func open(_ g: SportsModel.Game) {
        guard g.state == "in" else { event = g; return }
        Task {
            let w: SportsEventModel.Watch? = try? await HarborEngine.shared.call("sports.watch", [g.wire])
            if let s = w?.attachedStream, let url = URL(string: s.url) {
                directStream = SportsAddonPanelView.Play(url: url, headers: s.headers ?? [:], title: w?.fixture ?? g.headline, subtitle: URL(string: s.page)?.host, isLive: s.kind != "file")
            } else if let best = w?.channels.first, best.tier == "exact" || best.attached {
                _ = try? await HarborEngine.shared.callJSON("sports.recordChannelWatch", [.string(best.channelId)])
                directPlay = best
            } else { event = g }
        }
    }

    var body: some View {
        Group {
            if model.consent != "accepted" {
                SportsConsentView(accept: { Task { await model.accept() } }, decline: { Task { await model.decline() } })
            } else {
                room
            }
        }
        .task { await model.start() }
        .fullScreenCover(item: $event) { g in SportsEventView(game: g, dismiss: { event = nil }) }
        .fullScreenCover(item: $directPlay) { opt in
            PlayerScreen(title: opt.name, subtitle: opt.label, url: URL(string: opt.url) ?? URL(string: "about:blank")!, headers: opt.headers ?? [:], isLive: true) { _ in directPlay = nil }
        }
        .fullScreenCover(item: $directStream) { p in
            PlayerScreen(title: p.title, subtitle: p.subtitle, url: p.url, headers: p.headers, isLive: p.isLive) { _ in directStream = nil }
        }
        .fullScreenCover(isPresented: $personalize) { SportsPersonalizeView(model: model, dismiss: { personalize = false }) }
    }

    private var room: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: BP.px(18)) {
                chips
                if let p = model.page {
                    if model.mode == .schedule { dateBand(p) }
                    if let note = p.status.note { BPNote(text: note) }
                    if model.mode == .explore {
                        explore(p)
                    } else {
                        if let hero = p.heroes.indices.contains(heroIndex) ? p.heroes[heroIndex] : p.heroes.first {
                            SportsHeroView(game: hero, count: p.heroes.count, index: heroIndex, open: { open(hero) })
                        }
                        ForEach(p.rows) { row in
                            SportsRowView(row: row, open: { open($0) })
                        }
                        if p.empty { emptyState(p) }
                    }
                } else if model.loading {
                    ProgressView().tint(BP.inkMuted).padding(.top, BP.px(40))
                }
            }
            .padding(.horizontal, BP.gutter).padding(.top, BP.barHeight + BP.px(16)).padding(.bottom, BP.hintHeight + BP.px(40))
        }
        .task(id: model.page?.heroes.map(\.key)) {
            // use-bp-sports-cycle.ts: next hero every 7 s.
            heroIndex = 0
            let n = model.page?.heroes.count ?? 0
            guard n > 1 else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(7))
                heroIndex = (heroIndex + 1) % n
            }
        }
    }

    // bp-sports-chips.tsx: modes, "Make it yours", Refresh, status; then groups.
    private var chips: some View {
        VStack(alignment: .leading, spacing: BP.px(8)) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: BP.px(8)) {
                    ForEach(SportsModel.Mode.allCases, id: \.rawValue) { m in
                        Button(m.label) { model.setMode(m) }.buttonStyle(BPActionStyle(primary: model.mode == m))
                    }
                    Divider().frame(height: BP.px(24)).overlay(BP.edge2)
                    Button("Make it yours") { personalize = true }.buttonStyle(BPActionStyle())
                    Button((model.page?.status.failed ?? false) || (model.page?.status.stale ?? false) ? "Retry" : "Refresh") { Task { await model.reload(force: true) } }.buttonStyle(BPActionStyle())
                    Text(statusLine).font(BP.sans(12)).foregroundStyle(BP.inkSubtle).padding(.leading, BP.px(8))
                }
            }
            .focusSection()
            if let p = model.page, p.showGroups {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: BP.px(8)) {
                        Button("Your sports") { model.setGroup("all") }.buttonStyle(BPActionStyle(primary: model.group == "all"))
                        ForEach(p.groups) { g in
                            Button(g.label) { model.setGroup(g.key) }.buttonStyle(BPActionStyle(primary: model.group == g.key))
                        }
                        Button("All sports") { model.setMode(.explore) }.buttonStyle(BPActionStyle())
                    }
                }
                .focusSection()
            }
        }
    }

    private var statusLine: String {
        guard let s = model.page?.status else { return "" }
        if s.busy { return "Updating schedules…" }
        if s.at > 0 { return "Updated \(Date(timeIntervalSince1970: s.at / 1000).formatted(date: .omitted, time: .shortened))" }
        return ""
    }

    private func dateBand(_ p: SportsModel.Page) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: BP.px(6)) {
                ForEach(model.days) { d in
                    Button {
                        model.setDay(d.key)
                    } label: {
                        VStack(spacing: BP.px(3)) {
                            Text(d.label).font(BP.sans(13, .semibold))
                            Circle().fill(p.liveDays.contains(d.key) ? BP.live : .clear).frame(width: BP.px(5), height: BP.px(5))
                        }
                    }
                    .buttonStyle(BPActionStyle(primary: (model.day ?? p.today) == d.key))
                }
            }
        }
        .focusSection()
    }

    private func explore(_ p: SportsModel.Page) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(BP.px(200)), spacing: BP.px(12)), count: 7), spacing: BP.px(12)) {
            ForEach(p.explore) { g in
                Button { model.browse(g.key) } label: {
                    VStack(spacing: BP.px(8)) {
                        Text(g.icon ?? "").font(.system(size: BP.px(30)))
                        Text(g.label).font(BP.sans(14, .semibold)).foregroundStyle(BP.ink).lineLimit(1)
                    }
                    .frame(width: BP.px(200), height: BP.px(110))
                    .background(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).fill(BP.panel2))
                }
                .buttonStyle(BPTileStyle(radius: BP.rSM))
            }
        }
        .focusSection()
    }

    // bp-sports-empty.tsx copy matrix.
    private func emptyState(_ p: SportsModel.Page) -> some View {
        let pitch = !p.status.busy && !p.personalized
        let title = p.status.busy ? "Loading your sports…" : pitch ? "Less searching. More of your sport." : (model.mode == .live ? "Nothing live right now" : model.mode == .schedule ? "Nothing scheduled" : model.mode == .hot ? "Nothing hot yet" : "Nothing here yet")
        let body = p.status.busy ? "Schedules and scores are on their way." : pitch ? "Pick your sports, leagues and teams. Harbor keeps what matters up top." : "Try another day, another sport, or refresh."
        return VStack(alignment: .leading, spacing: BP.px(10)) {
            Text(T(title)).font(BP.display(24)).foregroundStyle(BP.ink)
            Text(T(body)).font(BP.sans(14)).foregroundStyle(BP.inkMuted)
            HStack(spacing: BP.px(8)) {
                if model.mode == .schedule { Button("Today") { model.setDay(p.today) }.buttonStyle(BPActionStyle()) }
                Button("Make it yours") { personalize = true }.buttonStyle(BPActionStyle(primary: pitch))
                Button("Explore sports") { model.setMode(.explore) }.buttonStyle(BPActionStyle(primary: !pitch))
            }
        }
        .padding(.top, BP.px(20))
        .focusSection()
    }
}

/// bp-sports-hero.tsx: subject (badges + names, face-off, or solo), meta line, CTA, pips.
struct SportsHeroView: View {
    let game: SportsModel.Game
    let count: Int
    let index: Int
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(alignment: .center, spacing: BP.px(30)) {
                VStack(alignment: .leading, spacing: BP.px(10)) {
                    HStack(spacing: BP.px(8)) {
                        RemoteImage(url: game.leagueLogo.isEmpty ? nil : game.leagueLogo, contentMode: .fit).frame(width: BP.px(22), height: BP.px(22))
                        Text(game.leagueLabel).font(BP.sans(13, .semibold)).foregroundStyle(BP.inkMuted)
                        if game.live { Text("LIVE").font(BP.sans(11, .bold)).foregroundStyle(BP.live) }
                    }
                    if game.single || game.faceOff {
                        Text(game.headline).font(BP.display(30)).foregroundStyle(BP.ink).lineLimit(2)
                    } else {
                        HStack(spacing: BP.px(18)) {
                            side(game.away)
                            Text(game.state == "pre" ? "vs" : "\(game.away.score.isEmpty ? "0" : game.away.score) : \(game.home.score.isEmpty ? "0" : game.home.score)")
                                .font(BP.display(26)).foregroundStyle(BP.ink).monospacedDigit()
                            side(game.home)
                        }
                    }
                    Text(metaLine).font(BP.sans(13)).foregroundStyle(BP.inkMuted).lineLimit(1)
                    HStack(spacing: BP.px(10)) {
                        Text(game.live ? "Watch live" : game.state == "post" ? "View result" : "View event")
                            .font(BP.sans(14, .semibold)).foregroundStyle(BP.canvas)
                            .padding(.horizontal, BP.px(14)).padding(.vertical, BP.px(6))
                            .background(Capsule().fill(BP.ink))
                        HStack(spacing: BP.px(4)) {
                            ForEach(0..<max(count, 1), id: \.self) { i in Circle().fill(i == index ? BP.ink : BP.edge2).frame(width: BP.px(5), height: BP.px(5)) }
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(BP.px(22))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                ZStack(alignment: .trailing) {
                    RoundedRectangle(cornerRadius: BP.rMD, style: .continuous).fill(BP.panel2)
                    SportsArtView(game: game, width: BP.px(420))
                }
                .clipShape(RoundedRectangle(cornerRadius: BP.rMD, style: .continuous))
            )
        }
        .buttonStyle(BPTileStyle(radius: BP.rMD))
        .focusSection()
    }

    private var metaLine: String {
        var parts = [game.leagueLabel]
        if !game.quiet.isEmpty, game.quiet != game.startLabel { parts.append(game.quiet) }
        parts.append(game.live ? (game.detail.isEmpty ? "Live" : game.detail) : game.startLabel)
        return parts.joined(separator: " · ")
    }

    private func side(_ s: SportsModel.Side) -> some View {
        VStack(spacing: BP.px(4)) {
            RemoteImage(url: s.logo.isEmpty ? nil : s.logo, contentMode: .fit).frame(width: BP.px(52), height: BP.px(52))
            Text(s.name).font(BP.sans(14, .semibold)).foregroundStyle(BP.ink).lineLimit(1)
        }
        .frame(width: BP.px(150))
    }
}

/// bp-sports-row.tsx: a titled horizontal track of game cards.
struct SportsRowView: View {
    let row: SportsModel.Row
    let open: (SportsModel.Game) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: BP.px(8)) {
            Text(row.title).font(BP.sans(17, .semibold)).foregroundStyle(BP.ink)
            if let d = row.description { Text(d).font(BP.sans(12)).foregroundStyle(BP.inkSubtle) }
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: BP.px(12)) {
                    ForEach(row.games) { g in
                        Button { open(g) } label: { SportsGameCard(game: g) }.buttonStyle(BPTileStyle(radius: BP.rSM))
                    }
                }
                .padding(.vertical, BP.px(6))
            }
        }
        .focusSection()
    }
}

/// bp-sports-card.tsx: league header + status, two sides (away above home) or one subject, quiet line.
struct SportsGameCard: View {
    let game: SportsModel.Game
    static let width = BP.px(318)

    var body: some View {
        VStack(alignment: .leading, spacing: BP.px(8)) {
            HStack(spacing: BP.px(6)) {
                RemoteImage(url: game.leagueLogo.isEmpty ? nil : game.leagueLogo, contentMode: .fit).frame(width: BP.px(16), height: BP.px(16))
                Text(game.leagueLabel).font(BP.sans(11, .semibold)).foregroundStyle(BP.inkMuted).lineLimit(1)
                Spacer()
                HStack(spacing: BP.px(4)) {
                    if game.live { Circle().fill(BP.live).frame(width: BP.px(6), height: BP.px(6)) }
                    Text(game.statusText).font(BP.sans(11, .semibold)).foregroundStyle(game.live ? BP.live : BP.inkMuted).lineLimit(1)
                }
            }
            if game.single {
                VStack(spacing: BP.px(6)) {
                    RemoteImage(url: (game.home.logo.isEmpty ? game.away.logo : game.home.logo).isEmpty ? nil : (game.home.logo.isEmpty ? game.away.logo : game.home.logo), contentMode: .fit).frame(width: BP.px(44), height: BP.px(44))
                    Text(game.headline).font(BP.sans(15, .semibold)).foregroundStyle(BP.ink).lineLimit(2).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
            } else {
                sideRow(game.away, lost: game.state == "post" && !game.away.winner && game.home.winner)
                sideRow(game.home, lost: game.state == "post" && !game.home.winner && game.away.winner)
            }
            Text(game.quiet).font(BP.sans(11)).foregroundStyle(BP.inkSubtle).lineLimit(1)
        }
        .padding(BP.px(14))
        .frame(width: Self.width, height: BP.px(170), alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).fill(BP.panel2))
    }

    private func sideRow(_ s: SportsModel.Side, lost: Bool) -> some View {
        HStack(spacing: BP.px(8)) {
            RemoteImage(url: s.logo.isEmpty ? nil : s.logo, contentMode: .fit).frame(width: BP.px(24), height: BP.px(24))
            if let r = s.rank { Text("#\(r)").font(BP.sans(11)).foregroundStyle(BP.inkSubtle) }
            Text(s.name).font(BP.sans(14, .semibold)).foregroundStyle(BP.ink).lineLimit(1)
            Spacer()
            Text(game.state == "pre" ? (s.record ?? "") : (s.score.isEmpty ? "0" : s.score))
                .font(BP.sans(14, game.state == "pre" ? .regular : .bold)).foregroundStyle(game.state == "pre" ? BP.inkSubtle : BP.ink).monospacedDigit()
        }
        .opacity(lost ? 0.55 : 1)
    }
}
