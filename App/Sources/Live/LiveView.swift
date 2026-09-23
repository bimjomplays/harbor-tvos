import SwiftUI

/// Live TV (bp-live.tsx): source + category band, then the channel guide (guide-lite: one row
/// per channel with now/next from the XMLTV guide). Sources are M3U, middleware or Xtream.
@MainActor
final class LiveModel: ObservableObject {
    struct Playlist: Decodable, Identifiable { var id: String; var name: String; var url: String; var kind: String?; var epgUrl: String? }
    struct Channel: Codable, Identifiable, Equatable {
        var id: String; var name: String; var logo: String?; var url: String; var group: String?; var tvgId: String?
        var headers: [String: String]?; var favorite: Bool
        /// bp-guide-title: cleaned name, quality badge, and a group label that is not just the name again.
        var label: String?; var badge: String?; var groupLabel: String?
        var pinned: Bool?
        /// epg-map.ts: the guide channel the viewer matched by hand (nil = automatic).
        var epgMatch: String?
        var shownName: String { label ?? name }
    }
    struct Group: Decodable, Identifiable { var name: String; var count: Int; var hidden: Bool?; var id: String { name } }
    /// bp-live.tsx chip after Favorites and All: a group rail (filter by `group`) or a rail of `ids`.
    struct Category: Decodable { var key: String; var label: String; var count: Int; var group: String?; var flag: String?; var ids: [String]? }
    struct View_: Decodable { var id: String; var name: String; var kind: String; var channels: [Channel]; var groups: [Group]; var categories: [Category]?; var total: Int; var epgUrl: String? }
    /// epg-match-modal.tsx: guide channels a playlist channel can be matched to.
    struct EpgMatchEntry: Decodable, Identifiable { var id: String; var sample: String }
    struct EpgMatchList: Decodable { var channelId: String; var channelName: String; var query: String; var total: Int; var current: String?; var entries: [EpgMatchEntry] }
    struct Program: Decodable, Equatable { var title: String; var description: String?; var startMs: Double; var endMs: Double; var category: String?; var iconUrl: String? }
    struct NowNext: Decodable, Equatable { var id: String; var now: Program?; var next: Program?; var known: Bool }

    static let favKey = "fav", allKey = "all", maxCategories = 30

    @Published private(set) var playlists: [Playlist] = []
    @Published private(set) var channels: [Channel] = []
    @Published private(set) var groups: [Group] = []
    @Published private(set) var guide: [String: NowNext] = [:]
    @Published private(set) var guideNote: String?
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    @Published var selectedPlaylist: String?
    @Published var category: String = LiveModel.allKey
    @Published private(set) var extraCategories: [Category] = []
    /// How many channels the loaded guide covers (0 = nothing to match against).
    @Published private(set) var guideChannelCount = 0
    /// Bumped after a manual EPG match changes; `lastRemapped` names the channel.
    @Published private(set) var epgMapRevision = 0
    private(set) var lastRemapped: String?

    private var tick: Task<Void, Never>?
    private var indexById: [String: Int] = [:]

    deinit { tick?.cancel() }

    func load() async {
        playlists = (try? await HarborEngine.shared.call("live.playlists", [])) ?? []
        if selectedPlaylist == nil || !playlists.contains(where: { $0.id == selectedPlaylist }) { selectedPlaylist = playlists.first?.id }
        await loadChannels()
    }

    func loadChannels(force: Bool = false) async {
        guard let id = selectedPlaylist else { setChannels([]); groups = []; extraCategories = []; guide = [:]; return }
        loading = true; defer { loading = false }
        error = nil
        do {
            let v: View_ = try await HarborEngine.shared.call("live.channels", [id, force])
            setChannels(v.channels)
            groups = v.groups
            extraCategories = v.categories ?? []
            if category != Self.favKey && category != Self.allKey && !extraCategories.contains(where: { $0.key == category }) { category = Self.allKey }
            await loadGuide(force: force)
            startTick()
        } catch { self.error = error.localizedDescription; setChannels([]); groups = []; extraCategories = [] }
    }

    private func setChannels(_ list: [Channel]) {
        channels = list
        var index: [String: Int] = [:]
        for (i, ch) in list.enumerated() where index[ch.id] == nil { index[ch.id] = i }
        indexById = index
    }

    /// The guide is optional: no EPG URL means rows just say "Live".
    func loadGuide(force: Bool = false) async {
        guard let id = selectedPlaylist else { return }
        struct Out: Decodable { var channels: Int; var programs: Int; var url: String? }
        var covered = 0
        do {
            let o: Out = try await HarborEngine.shared.call("live.loadEpg", [id, force])
            covered = o.channels
            guideNote = o.url == nil ? "No guide for this source. Add an EPG URL under Sources." : (o.channels == 0 ? "The guide loaded but lists no channels." : nil)
        } catch { guideNote = "Guide failed: \(error.localizedDescription)" }
        guideChannelCount = covered
        await refreshNowNext()
        // use-xtream-epg-fallback: an Xtream source with no usable XMLTV asks get_short_epg per channel.
        let xtream = playlists.first { $0.id == id }?.kind == "xtream"
        if xtream, covered == 0 || !visible.isEmpty && guide.values.allSatisfy({ !$0.known }) {
            struct Hydrated: Decodable { var hydrated: Int }
            let ids = visible.map(\.id)
            if let h: Hydrated = try? await HarborEngine.shared.call("live.loadShortEpg", [id, ids]), h.hydrated > 0 {
                guideNote = nil
                guideChannelCount = covered + h.hydrated
                await refreshNowNext()
            }
        }
    }

    func refreshNowNext() async {
        guard let id = selectedPlaylist, !visible.isEmpty else { guide = [:]; return }
        let ids = visible.map(\.id)
        if let list: [NowNext] = try? await HarborEngine.shared.call("live.nowNext", [id, ids]) {
            var next = guide
            for n in list { next[n.id] = n }
            guide = next
        }
    }

    /// bp-live-tick: recompute "now" every 30 s so progress bars and now/next roll over.
    private func startTick() {
        tick?.cancel()
        tick = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                await self?.refreshNowNext()
            }
        }
    }

    /// bp-live.tsx: Favorites and All, then the engine's rails (recent, pinned groups, themes or
    /// countries, top groups); 30 chips at most.
    var categories: [(key: String, label: String, count: Int, flag: String?)] {
        var out: [(key: String, label: String, count: Int, flag: String?)] = [
            (key: Self.favKey, label: "Favorites", count: channels.filter(\.favorite).count, flag: nil),
            (key: Self.allKey, label: "All", count: channels.count, flag: nil),
        ]
        for c in extraCategories.prefix(Self.maxCategories - 2) { out.append((key: c.key, label: c.label, count: c.count, flag: c.flag)) }
        return out
    }

    /// The group behind the chosen chip, when it is a group rail.
    var currentGroup: String? { extraCategories.first(where: { $0.key == category })?.group }

    /// Channels of the chosen category, in guide order (favorites, pins, most watched, networks, rest).
    var visible: [Channel] {
        switch category {
        case Self.favKey: return channels.filter(\.favorite)
        case Self.allKey: return channels
        default:
            guard let c = extraCategories.first(where: { $0.key == category }) else { return [] }
            if let ids = c.ids {
                var out: [Channel] = []
                for id in ids { if let i = indexById[id], i < channels.count { out.append(channels[i]) } }
                return out
            }
            let group = c.group ?? ""
            return channels.filter { ($0.group ?? "Uncategorized") == group }
        }
    }

    /// usePinnedOrder: pinned channels sit in guide-order tier 2 (after favourites).
    func togglePin(_ ch: Channel) async {
        _ = try? await HarborEngine.shared.callJSON("live.toggleChannelPin", [.string(ch.id)])
        await load()
    }

    /// useGroupPrefs: hide (or show again) a whole channel group of this source.
    func toggleGroupHidden(_ group: String) async {
        guard let id = selectedPlaylist else { return }
        _ = try? await HarborEngine.shared.callJSON("live.toggleGroupHidden", [.string(id), .string(group)])
        if currentGroup == group { category = Self.allKey }
        await load()
    }

    /// epg-match-modal Match EPG: offered when the guide has channels and this one has no
    /// programmes, or already carries a manual match (so it can be changed or cleared).
    func canMatchEpg(_ ch: Channel) -> Bool {
        guideChannelCount > 0 && (ch.epgMatch != nil || guide[ch.id]?.known != true)
    }

    /// The modal's list: nil `query` starts from the channel's own name.
    func epgCandidates(for ch: Channel, query: String?) async -> EpgMatchList? {
        guard let id = selectedPlaylist else { return nil }
        let q: AnyJSON = query.map { AnyJSON.string($0) } ?? AnyJSON.null
        let args: [any Encodable] = [id, ch.id, q]
        do {
            let out: EpgMatchList = try await HarborEngine.shared.call("live.epgCandidates", args)
            return out
        } catch { return nil }
    }

    /// epg-map setEpgOverride: a guide channel id, or nil to clear; now/next and the guide lane follow.
    func setEpgMatch(_ ch: Channel, tvgId: String?) async {
        let args: [AnyJSON] = [.string(ch.id), tvgId.map { AnyJSON.string($0) } ?? AnyJSON.null]
        guard let result = try? await HarborEngine.shared.callJSON("live.setEpgMatch", args) else { return }
        var match: String? = nil
        if case .string(let s) = result { match = s }
        if let i = indexById[ch.id], i < channels.count { channels[i].epgMatch = match }
        lastRemapped = ch.id
        epgMapRevision += 1
        await refreshNowNext()
    }

    var hiddenGroupCount: Int { groups.filter { $0.hidden == true }.count }

    func toggleFavorite(_ ch: Channel) async {
        let on: Bool = (try? await HarborEngine.shared.call("live.toggleFavorite", [ch])) ?? !ch.favorite
        if let i = channels.firstIndex(where: { $0.id == ch.id }) { channels[i].favorite = on }
    }

    func played(_ ch: Channel) {
        guard let id = selectedPlaylist else { return }
        Task { _ = try? await HarborEngine.shared.callJSON("live.recordPlay", [.string(id), .string(ch.id)]) }
    }

    /// bp-live-setup: the structured form; kind is "m3u", "xtream" or "epg".
    func add(kind: String, name: String, url: String, epgUrl: String, server: String, username: String, password: String) async -> String? {
        struct Added: Decodable { var id: String }
        do {
            let a: Added = try await HarborEngine.shared.call("live.addStructured", [kind, name, url, epgUrl, server, username, password])
            selectedPlaylist = a.id
            await load()
            return nil
        } catch { return error.localizedDescription }
    }

    func add(name: String, url: String, epgUrl: String) async -> String? {
        struct Added: Decodable { var id: String }
        do {
            let a: Added = try await HarborEngine.shared.call("live.addPlaylist", [name, url, epgUrl])
            selectedPlaylist = a.id
            await load()
            return nil
        } catch { return error.localizedDescription }
    }

    func setEpgUrl(_ url: String) async {
        guard let id = selectedPlaylist else { return }
        _ = try? await HarborEngine.shared.callJSON("live.setEpgUrl", [.string(id), .string(url)])
        await load()
    }

    func remove(_ id: String) async {
        _ = try? await HarborEngine.shared.callJSON("live.removePlaylist", [.string(id)])
        if selectedPlaylist == id { selectedPlaylist = nil }
        await load()
    }
}

struct LiveView: View {
    @StateObject private var model = LiveModel()
    @State private var playing: LiveModel.Channel?
    @State private var replaying: Replay?
    struct Replay: Identifiable { var id: String { url }; var channel: LiveModel.Channel; var program: LiveModel.Program; var url: String; var headers: [String: String] }
    @State private var showSources = false
    /// bp-live shows the guide grid; the list is the fallback when a source has no guide.
    @State private var grid = true
    @State private var showHidden = false
    /// epg-match-modal: the channel whose guide match is being picked.
    @State private var matching: LiveModel.Channel?

    var body: some View {
        ZStack(alignment: .topLeading) {
            if model.playlists.isEmpty && !model.loading {
                LiveSourcesSheet(model: model, firstRun: true, dismiss: {})
            } else {
                VStack(alignment: .leading, spacing: BP.px(14)) {
                    band
                    if model.loading && model.channels.isEmpty {
                        ProgressView().tint(BP.inkMuted).frame(maxWidth: .infinity, alignment: .center).padding(.top, BP.px(60))
                    } else if model.visible.isEmpty {
                        BPNote(text: model.category == LiveModel.favKey ? "No favorites yet. Press the star on a channel to keep it up here." : (model.error ?? "No channels in this category."), tone: model.error == nil ? BP.inkMuted : BP.danger)
                            .padding(.top, BP.px(20))
                    } else if grid && model.guideNote == nil {
                        LiveGuideView(live: model, play: { ch in model.played(ch); playing = ch }, star: { ch in Task { await model.toggleFavorite(ch) } },
                                      replay: { ch, prog in Task { await startReplay(ch, prog) } },
                                      previewSuspended: playing != nil || replaying != nil || showSources || matching != nil,
                                      match: { ch in matching = ch })
                    } else {
                        guideList
                    }
                }
                .padding(.horizontal, BP.gutter).padding(.top, BP.barHeight + BP.px(16))
            }
        }
        .task { await model.load() }
        .fullScreenCover(item: $playing) { ch in
            PlayerScreen(title: ch.name, subtitle: model.guide[ch.id]?.now?.title ?? ch.group, url: URL(string: ch.url) ?? URL(string: "about:blank")!, headers: ch.headers ?? [:], isLive: true) { _ in playing = nil }
        }
        .fullScreenCover(item: $replaying) { r in
            // A bounded replay: VOD cache profile, seekable, subtitle says so (use-live-actions.ts).
            PlayerScreen(title: r.program.title, subtitle: "\(r.channel.shownName) · catch up", url: URL(string: r.url) ?? URL(string: "about:blank")!, headers: r.headers, isLive: false) { _ in replaying = nil }
        }
        .fullScreenCover(isPresented: $showSources) {
            LiveSourcesSheet(model: model, firstRun: false, dismiss: { showSources = false })
        }
        .fullScreenCover(item: $matching) { ch in
            EpgMatchView(model: model, channel: ch, dismiss: { matching = nil })
        }
    }

    private func startReplay(_ ch: LiveModel.Channel, _ prog: LiveModel.Program) async {
        struct Out: Decodable { var url: String; var headers: [String: String]? }
        guard let id = model.selectedPlaylist,
              let out: Out? = try? await HarborEngine.shared.call("live.catchupUrl", [id, ch.id, prog.startMs, prog.endMs]), let out else {
            model.played(ch); playing = ch; return
        }
        model.played(ch)
        replaying = Replay(channel: ch, program: prog, url: out.url, headers: out.headers ?? [:])
    }

    // bp-live.tsx: source button, then Favorites / All / groups chips (max 30).
    private var band: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: BP.px(8)) {
                Button {
                    showSources = true
                } label: {
                    HStack(spacing: BP.px(6)) {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                        Text(model.playlists.first { $0.id == model.selectedPlaylist }?.name ?? "Sources")
                    }
                }
                .buttonStyle(BPActionStyle(primary: true))
                // bp-live-filters: star on Favorites, a flag on country groups, no count at zero.
                ForEach(model.categories, id: \.key) { c in
                    Button {
                        model.category = c.key
                        Task { await model.refreshNowNext() }
                    } label: {
                        HStack(spacing: BP.px(6)) {
                            if c.key == LiveModel.favKey {
                                Image(systemName: c.count > 0 ? "star.fill" : "star")
                            }
                            if let flag = c.flag {
                                RemoteImage(url: flag, contentMode: .fill)
                                    .frame(width: BP.px(18), height: BP.px(12))
                                    .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
                            }
                            Text(c.label).lineLimit(1)
                            if c.count > 0 {
                                Text("\(c.count)").opacity(0.55)
                            }
                        }
                    }
                    .buttonStyle(BPActionStyle(primary: model.category == c.key))
                }
                if let group = model.currentGroup {
                    Button("Hide group") { Task { await model.toggleGroupHidden(group) } }.buttonStyle(BPActionStyle())
                }
                if showHidden {
                    ForEach(model.groups.filter { $0.hidden == true }) { g in
                        Button("Show \(g.name)") { Task { await model.toggleGroupHidden(g.name) } }.buttonStyle(BPActionStyle())
                    }
                }
                if model.hiddenGroupCount > 0 {
                    Button("\(model.hiddenGroupCount) hidden") { showHidden.toggle() }.buttonStyle(BPActionStyle(primary: showHidden))
                }
                if model.guideNote == nil {
                    Button(grid ? "List" : "Guide") { grid.toggle() }.buttonStyle(BPActionStyle())
                }
                if let note = model.guideNote { BPNote(text: note).padding(.leading, BP.px(8)) }
            }
            .padding(.vertical, BP.px(4))
        }
        .focusSection()
    }

    private var guideList: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: BP.px(6)) {
                ForEach(model.visible) { ch in
                    LiveChannelRow(channel: ch, nowNext: model.guide[ch.id],
                                   play: { model.played(ch); playing = ch },
                                   star: { Task { await model.toggleFavorite(ch) } },
                                   pin: { Task { await model.togglePin(ch) } },
                                   match: model.canMatchEpg(ch) ? { matching = ch } : nil)
                }
            }
            .padding(.vertical, BP.px(8)).padding(.bottom, BP.hintHeight + BP.px(40))
        }
        .focusSection()
    }
}

/// One guide row: logo, name, what's on now (with a live progress bar), what's next, a star.
struct LiveChannelRow: View {
    let channel: LiveModel.Channel
    let nowNext: LiveModel.NowNext?
    let play: () -> Void
    let star: () -> Void
    var pin: (() -> Void)? = nil
    /// Opens the EPG match picker (only offered when there is something to match or clear).
    var match: (() -> Void)? = nil

    private var progress: Double? {
        guard let p = nowNext?.now else { return nil }
        let now = Date().timeIntervalSince1970 * 1000
        guard p.endMs > p.startMs else { return nil }
        return min(1, max(0, (now - p.startMs) / (p.endMs - p.startMs)))
    }

    var body: some View {
        HStack(spacing: BP.px(8)) {
            Button(action: play) {
                HStack(spacing: BP.px(14)) {
                    RemoteImage(url: channel.logo, contentMode: .fit)
                        .frame(width: BP.px(84), height: BP.px(46))
                        .background(RoundedRectangle(cornerRadius: BP.px(6), style: .continuous).fill(BP.void_.opacity(0.6)))
                    VStack(alignment: .leading, spacing: BP.px(2)) {
                        HStack(spacing: BP.px(6)) {
                            Text(channel.shownName).font(BP.sans(14, .semibold)).foregroundStyle(BP.ink).lineLimit(1)
                            if let b = channel.badge { Text(b).font(BP.sans(9, .bold)).foregroundStyle(BP.inkMuted).padding(.horizontal, 4).padding(.vertical, 1).overlay(RoundedRectangle(cornerRadius: 3).stroke(BP.edge2, lineWidth: 1)) }
                        }
                        if let g = channel.groupLabel ?? channel.group { Text(g).font(BP.sans(10)).foregroundStyle(BP.inkSubtle).lineLimit(1) }
                    }
                    .frame(width: BP.px(220), alignment: .leading)
                    VStack(alignment: .leading, spacing: BP.px(4)) {
                        HStack(spacing: BP.px(8)) {
                            Circle().fill(BP.live).frame(width: BP.px(6), height: BP.px(6))
                            Text(nowNext?.now?.title ?? (nowNext?.known == true ? "Nothing scheduled" : "Live"))
                                .font(BP.sans(13, .semibold)).foregroundStyle(BP.ink).lineLimit(1)
                            if let p = nowNext?.now { Text(Self.range(p)).font(BP.sans(11)).foregroundStyle(BP.inkMuted) }
                        }
                        if let progress {
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(BP.edge2)
                                    Capsule().fill(BP.live).frame(width: geo.size.width * progress)
                                }
                            }
                            .frame(height: BP.px(3))
                        }
                        if let n = nowNext?.next {
                            Text("Next · \(Self.time(n.startMs)) \(n.title)").font(BP.sans(11)).foregroundStyle(BP.inkMuted).lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, BP.px(14)).padding(.vertical, BP.px(10))
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).fill(BP.panel2))
            }
            .buttonStyle(BPTileStyle(radius: BP.rSM))
            Button(action: star) {
                Image(systemName: channel.favorite ? "star.fill" : "star")
                    .font(.system(size: BP.px(16), weight: .bold))
                    .foregroundStyle(channel.favorite ? BP.ink : BP.inkMuted)
                    .frame(width: BP.px(56), height: BP.px(56))
                    .background(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).fill(BP.panel2))
            }
            .buttonStyle(BPTileStyle(radius: BP.rSM))
            .accessibilityLabel(channel.favorite ? "Remove from favorites" : "Add to favorites")
            if let pin {
                // usePinnedOrder: a pinned channel sits just under the favourites in guide order.
                Button(action: pin) {
                    Image(systemName: channel.pinned == true ? "pin.fill" : "pin")
                        .font(.system(size: BP.px(16), weight: .bold))
                        .foregroundStyle(channel.pinned == true ? BP.ink : BP.inkMuted)
                        .frame(width: BP.px(56), height: BP.px(56))
                        .background(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).fill(BP.panel2))
                }
                .buttonStyle(BPTileStyle(radius: BP.rSM))
                .accessibilityLabel(channel.pinned == true ? "Unpin channel" : "Pin channel")
            }
            if let match {
                // guide-view.tsx "Match EPG": pick the guide channel when the tvg-id is wrong.
                Button(action: match) {
                    Image(systemName: "link")
                        .font(.system(size: BP.px(16), weight: .bold))
                        .foregroundStyle(channel.epgMatch != nil ? BP.accent : BP.inkMuted)
                        .frame(width: BP.px(56), height: BP.px(56))
                        .background(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).fill(BP.panel2))
                }
                .buttonStyle(BPTileStyle(radius: BP.rSM))
                .accessibilityLabel("Match EPG")
            }
        }
    }

    private static let clock: DateFormatter = { let f = DateFormatter(); f.timeStyle = .short; f.dateStyle = .none; return f }()
    static func time(_ ms: Double) -> String { clock.string(from: Date(timeIntervalSince1970: ms / 1000)) }
    static func range(_ p: LiveModel.Program) -> String { "\(time(p.startMs)) – \(time(p.endMs))" }
}

/// bp-live-sources / bp-live-setup: add an M3U, middleware or Xtream URL, an optional EPG URL,
/// switch between sources, remove one.
struct LiveSourcesSheet: View {
    @ObservedObject var model: LiveModel
    let firstRun: Bool
    let dismiss: () -> Void
    @State private var name = ""
    @State private var url = ""
    @State private var epg = ""
    @State private var kind = "m3u"
    @State private var server = ""
    @State private var username = ""
    @State private var password = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        ZStack(alignment: .topLeading) {
            if !firstRun { BP.canvas.ignoresSafeArea() }
            HStack(alignment: .top, spacing: BP.px(40)) {
                VStack(alignment: .leading, spacing: BP.px(14)) {
                    Text(firstRun ? "Live TV" : "Sources").font(BP.display(36)).foregroundStyle(BP.ink)
                    BPNote(text: "Paste an M3U or M3U8 playlist URL, an IPTV middleware address, or an Xtream Codes login URL (get.php with username and password). Xtream guides are found automatically.")
                    // bp-live-setup kind picker: M3U link, Xtream Codes login, or guide data only.
                    HStack(spacing: BP.px(8)) {
                        ForEach([("m3u", "M3U playlist"), ("xtream", "Xtream Codes"), ("epg", "Guide only")], id: \.0) { k, label in
                            Button(label) { kind = k }.buttonStyle(BPActionStyle(primary: kind == k))
                        }
                    }
                    BPField(label: "Name", placeholder: "My provider", text: $name)
                    if kind == "xtream" {
                        BPField(label: "Server", placeholder: "http://host:port", text: $server, keyboard: .URL)
                        BPField(label: "Username", placeholder: "Username", text: $username)
                        BPField(label: "Password", placeholder: "Password", text: $password, secure: true)
                    } else if kind == "m3u" {
                        BPField(label: "Playlist or login URL", placeholder: "https://…/playlist.m3u", text: $url, keyboard: .URL)
                        BPField(label: "EPG URL (optional, XMLTV)", placeholder: "https://…/guide.xml.gz", text: $epg, keyboard: .URL)
                    } else {
                        BPField(label: "Guide address (XMLTV)", placeholder: "https://…/guide.xml.gz", text: $epg, keyboard: .URL)
                    }
                    HStack(spacing: BP.px(12)) {
                        Button(busy ? "Adding…" : "Add source") {
                            busy = true
                            Task {
                                error = kind == "m3u" && !url.isEmpty && server.isEmpty
                                    ? await model.add(name: name, url: url, epgUrl: epg)
                                    : await model.add(kind: kind, name: name, url: url, epgUrl: epg, server: server, username: username, password: password)
                                busy = false
                                if error == nil { name = ""; url = ""; epg = ""; dismiss() }
                            }
                        }
                        .buttonStyle(BPActionStyle(primary: true)).disabled(busy || (kind == "m3u" ? url.count < 8 : kind == "xtream" ? (server.count < 8 || username.isEmpty) : epg.count < 8))
                        if !firstRun { Button("Close") { dismiss() }.buttonStyle(BPActionStyle()) }
                    }
                    if let e = error ?? model.error { BPNote(text: e, tone: BP.danger) }
                }
                .frame(maxWidth: BP.px(560))
                if !model.playlists.isEmpty {
                    VStack(alignment: .leading, spacing: BP.px(10)) {
                        Text("Your sources").font(BP.sans(16, .semibold)).foregroundStyle(BP.ink)
                        ForEach(model.playlists) { pl in
                            HStack(spacing: BP.px(8)) {
                                Button(pl.name) {
                                    model.selectedPlaylist = pl.id
                                    Task { await model.loadChannels(); dismiss() }
                                }
                                .buttonStyle(BPActionStyle(primary: model.selectedPlaylist == pl.id))
                                Button("Remove") { Task { await model.remove(pl.id) } }.buttonStyle(BPActionStyle())
                            }
                            Text(pl.epgUrl.map { "Guide: \($0)" } ?? "No guide URL").font(BP.sans(10)).foregroundStyle(BP.inkSubtle).lineLimit(1)
                        }
                        if model.selectedPlaylist != nil {
                            Button("Use the EPG URL above for the selected source") {
                                Task { await model.setEpgUrl(epg); epg = "" }
                            }
                            .buttonStyle(BPActionStyle()).disabled(epg.count < 8)
                            Button("Refresh channels and guide") { Task { await model.loadChannels(force: true); dismiss() } }.buttonStyle(BPActionStyle())
                        }
                    }
                    .frame(maxWidth: BP.px(520))
                }
            }
            .padding(.horizontal, BP.gutter).padding(.top, BP.barHeight + BP.px(20))
        }
        .focusSection()
    }
}
