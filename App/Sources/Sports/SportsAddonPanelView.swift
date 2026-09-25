import SwiftUI

/// bp-sports-addon-parts: the addon mark, a title and a sub line in one wide tile.
struct SportsAddonTile: View {
    let logo: String?
    let title: String
    let sub: String
    var icon: String = "powerplug"
    var body: some View {
        HStack(spacing: BP.px(12)) {
            Group {
                if let logo, !logo.isEmpty {
                    RemoteImage(url: logo, contentMode: .fit)
                } else {
                    Image(systemName: icon).font(.system(size: BP.px(20), weight: .semibold)).foregroundStyle(BP.inkMuted)
                }
            }
            .frame(width: BP.px(44), height: BP.px(44))
            .background(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).fill(BP.panel2))
            VStack(alignment: .leading, spacing: BP.px(3)) {
                Text(title).font(BP.sans(14, .semibold)).foregroundStyle(BP.ink).lineLimit(1)
                Text(sub).font(BP.sans(11)).foregroundStyle(BP.inkMuted).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, BP.px(14)).padding(.vertical, BP.px(12))
        .frame(width: BP.px(380), alignment: .leading)
        .background(RoundedRectangle(cornerRadius: BP.rMD, style: .continuous).fill(BP.panel))
        .overlay(RoundedRectangle(cornerRadius: BP.rMD, style: .continuous).stroke(BP.edge, lineWidth: 1))
    }
}

/// bp-sports-addon-panel (+ -listings, -streams, -play): addon listings for a game, a listing's
/// streams, and the pick. A direct link plays live; an external page goes to the phone (tvOS has
/// no browser, where upstream calls openUrl); a torrent or catalogue title hands off to the
/// regular stream list for that meta (upstream's BpStreams).
struct SportsAddonPanelView: View {
    let game: SportsModel.Game
    @ObservedObject var model: SportsEventModel
    let initial: SportsEventModel.AddonRow?
    let onPlay: (Play) -> Void
    let onClose: () -> Void

    struct Play: Identifiable { let url: URL; let headers: [String: String]; let title: String; let subtitle: String?; let isLive: Bool; var id: String { url.absoluteString } }
    struct StreamRow: Decodable, Identifiable { var index: Int; var name: String; var title: String; var external: Bool; var id: Int { index } }
    struct Streams: Decodable { var status: String; var rows: [StreamRow] }
    struct Outcome: Decodable { var kind: String; var url: String?; var headers: [String: String]?; var title: String?; var subtitle: String?; var meta: Meta? }
    struct External: Identifiable { let url: String; var id: String { url } }

    private static let page = 24
    @State private var browse = false
    @State private var query = ""
    @State private var limit = SportsAddonPanelView.page
    @State private var picked: SportsEventModel.AddonRow?
    @State private var streams: [StreamRow] = []
    @State private var pending = false
    @State private var playing: Int?
    @State private var fault = ""          // "" | "stream" | "listing"
    @State private var external: External?
    @State private var handoff: Meta?
    @State private var seeded = false
    /// (bug pass) Off screen: closed, or under one of its own covers.
    @State private var gone = false

    static func matchCopy(_ row: SportsEventModel.AddonRow) -> String {
        switch row.match {
        case "event": return row.addonName + " · " + T("Event matchup found")
        case "channel": return row.addonName + " · " + T("Possible match · check the broadcast")
        default: return row.addonName
        }
    }

    private var rows: [SportsEventModel.AddonRow] { model.addons?.rows ?? [] }
    private var filtered: [SportsEventModel.AddonRow] {
        let needle = query.lowercased().trimmingCharacters(in: .whitespaces)
        return rows.filter { ($0.match != nil || browse) && (needle.isEmpty || "\($0.name) \($0.addonName)".lowercased().contains(needle)) }
    }

    var body: some View {
        ZStack {
            BP.void_.opacity(0.94).ignoresSafeArea()
            VStack(alignment: .leading, spacing: BP.px(14)) {
                Text(picked == nil ? "Addon sources" : "Addon streams").font(BP.sans(11, .bold)).textCase(.uppercase).tracking(1).foregroundStyle(BP.accent)
                Text(game.headline.isEmpty ? game.leagueLabel : game.headline).font(BP.display(32)).foregroundStyle(BP.ink).lineLimit(1)
                if model.addons?.failed == true { BPNote(text: "Some addons did not respond. Try again.", tone: BP.danger) }
                if let row = picked { streamsView(row) } else { listingsView }
            }
            .frame(maxWidth: BP.px(1100), alignment: .leading)
            .padding(BP.gutter).padding(.top, BP.px(30))
        }
        .onExitCommand { if picked != nil { back() } else { onClose() } }
        // Its own covers (the phone link, the stream list) hide it too; they bring it back.
        .onAppear { gone = false }
        .onDisappear { gone = true }
        .task {
            guard !seeded else { return }
            seeded = true
            if let r = initial { choose(r) }
        }
        .fullScreenCover(item: $external) { e in ExternalLinkView(url: e.url) { external = nil } }
        .fullScreenCover(item: $handoff) { meta in
            PlayPickerView(meta: meta, episode: nil) { _, resolved in
                guard let link = resolved.data, let url = PlayableURL.make(link.url) else { return }   // (bug pass 2) the picker checked it
                handoff = nil
                onPlay(Play(url: url, headers: link.headers ?? [:], title: meta.name, subtitle: picked?.addonName, isLive: !["movie", "series"].contains(meta.type)))
            }
        }
    }

    // bp-sports-addon-listings: matching listings, or every channel when browsing; a name filter; pages of 24.
    @ViewBuilder private var listingsView: some View {
        let shown = Array(filtered.prefix(limit))
        let more = filtered.count - shown.count
        let note = model.addonsLoading ? "Matching installed addons…"
            : !(model.addons?.installed ?? false) ? "No installed addon offers a sports catalog yet."
            : model.matchingAddons.isEmpty && !browse && query.isEmpty ? "No matching addon listing yet. Browse every addon channel to look for the broadcast."
            : filtered.isEmpty ? "No addon listing matches that name."
            : "Choose an addon source to see its streams."
        Text(T(note)).font(BP.sans(14)).foregroundStyle(BP.inkMuted)
        HStack(spacing: BP.px(10)) {
            TextField("Channel or event name", text: $query).frame(width: BP.px(420))
                .onChange(of: query) { _, _ in limit = Self.page }
            Button(browse ? "Matching events" : "Browse addon channels") { browse.toggle(); limit = Self.page }.buttonStyle(BPActionStyle())
            Button("Refresh") { Task { await model.loadAddons(game, force: true) } }.buttonStyle(BPActionStyle()).disabled(model.addonsLoading)
            Button("Close") { onClose() }.buttonStyle(BPActionStyle())
        }
        .focusSection()
        ScrollView(.vertical, showsIndicators: false) {
            LazyVGrid(columns: [GridItem(.fixed(BP.px(380)), spacing: BP.px(10)), GridItem(.fixed(BP.px(380)), spacing: BP.px(10))], alignment: .leading, spacing: BP.px(10)) {
                ForEach(shown) { row in
                    Button { choose(row) } label: { SportsAddonTile(logo: row.addonLogo, title: row.name, sub: Self.matchCopy(row)) }
                        .buttonStyle(BPTileStyle(radius: BP.rMD))
                }
                if more > 0 {
                    Button { limit += Self.page } label: { SportsAddonTile(logo: nil, title: T("More addon channels (%lld left)", more), sub: "", icon: "ellipsis") }
                        .buttonStyle(BPTileStyle(radius: BP.rMD))
                }
            }
            .padding(.vertical, BP.px(8))
        }
        .scrollClipDisabled()
        .focusSection()
    }

    // bp-sports-addon-streams: the listing, a status note, one tile per stream, Back.
    @ViewBuilder private func streamsView(_ row: SportsEventModel.AddonRow) -> some View {
        let note = pending ? "Checking addon streams…"
            : fault == "stream" ? "Could not start this stream. Choose another source."
            : fault == "listing" ? "Could not load the streams for this addon listing."
            : streams.isEmpty ? "No streams returned. The event may not be available yet."
            : ""
        SportsAddonTile(logo: row.addonLogo, title: row.name, sub: row.addonName)
        if !note.isEmpty { Text(T(note)).font(BP.sans(14)).foregroundStyle(fault.isEmpty ? BP.inkMuted : BP.danger) }
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: BP.px(8)) {
                ForEach(streams) { st in
                    Button { play(row, st) } label: {
                        HStack(spacing: BP.px(12)) {
                            if playing == st.index { ProgressView().tint(BP.inkMuted) }
                            else { Image(systemName: st.external ? "arrow.up.right.square" : "play.fill").foregroundStyle(BP.inkMuted) }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(st.name).font(BP.sans(14, .semibold)).foregroundStyle(BP.ink).lineLimit(1)
                                if !st.title.isEmpty { Text(st.title).font(BP.sans(11)).foregroundStyle(BP.inkMuted).lineLimit(2) }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, BP.px(14)).padding(.vertical, BP.px(10))
                        .frame(width: BP.px(780), alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: BP.rMD, style: .continuous).fill(BP.panel))
                    }
                    .buttonStyle(BPTileStyle(radius: BP.rMD))
                    .disabled(playing != nil && playing != st.index)
                }
            }
            .padding(.vertical, BP.px(8))
        }
        .scrollClipDisabled()
        Button { back() } label: { Label("Back", systemImage: "chevron.backward") }.buttonStyle(BPActionStyle())
    }

    private func choose(_ row: SportsEventModel.AddonRow) {
        picked = row; streams = []; pending = true; playing = nil; fault = ""
        Task {
            let out: Streams? = try? await HarborEngine.shared.call("sports.addonStreams", [row.key])
            guard picked?.key == row.key else { return }
            pending = false
            switch out?.status {
            case "ok": streams = out?.rows ?? []
            case "reload": back(); await model.loadAddons(game, force: false)
            default: fault = "listing"
            }
        }
    }

    private func back() { picked = nil; streams = []; pending = false; playing = nil; fault = "" }

    private func play(_ row: SportsEventModel.AddonRow, _ st: StreamRow) {
        guard playing == nil else { return }
        playing = st.index; fault = ""
        Task {
            let out: Outcome? = try? await HarborEngine.shared.call("sports.addonPlay", [row.key, st.index])
            // (bug pass) The viewer went Back to the listings, or closed the panel, while the addon
            // answered: a late "play" closed the event's covers and started the stream anyway.
            guard picked?.key == row.key, !gone else { return }
            playing = nil
            switch out?.kind {
            case "play":
                if let s = out?.url, let url = URL(string: s) {
                    onPlay(Play(url: url, headers: out?.headers ?? [:], title: out?.title ?? row.name, subtitle: out?.subtitle, isLive: true))
                } else { fault = "stream" }
            case "external":
                if let u = out?.url { external = External(url: u) } else { fault = "stream" }
            case "handoff":
                if let m = out?.meta { handoff = m } else { fault = "stream" }
            case "reload":
                back(); await model.loadAddons(game)
            default:
                fault = "stream"
            }
        }
    }
}

/// A web page an addon points at: tvOS has no browser, so the phone opens it.
struct ExternalLinkView: View {
    let url: String
    let onClose: () -> Void
    var body: some View {
        ZStack {
            BP.void_.opacity(0.94).ignoresSafeArea()
            VStack(spacing: BP.px(14)) {
                if let qr = QRCode.image(url) {
                    Image(uiImage: qr).interpolation(.none).resizable().frame(width: BP.px(240), height: BP.px(240)).accessibilityLabel(Text(T("QR code")))
                        .padding(BP.px(10)).background(Color.white).clipShape(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous))
                }
                Text("This source opens in a web browser. Scan to open it on your phone.").font(BP.sans(15, .semibold)).foregroundStyle(BP.ink)
                Text(url).font(BP.sans(11)).foregroundStyle(BP.inkSubtle).lineLimit(2).frame(maxWidth: BP.px(700))
                Button("Close") { onClose() }.buttonStyle(BPActionStyle(primary: true))
            }
            .padding(BP.gutter)
        }
        .onExitCommand { onClose() }
    }
}
