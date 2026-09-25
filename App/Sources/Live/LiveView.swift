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

    /// use-bp-live.ts sources: the channel sources. A "Guide data only" entry is never the one Live
    /// TV shows; its address backs every source's guide (the engine's EPG fallback list).
    @Published private(set) var playlists: [Playlist] = []
    /// Every stored source, guide-only ones included (the Sources sheet lists and removes them).
    @Published private(set) var allSources: [Playlist] = []
    /// (live sources device pass) The sources have been read once. Before that `playlists` is
    /// empty for everyone, and Live TV drew the first-run setup form for a frame on every visit
    /// (the ring could land in it and fall to the top bar as it vanished). use-bp-live reads
    /// hasPlaylists synchronously from settings.
    @Published private(set) var sourcesRead = false
    @Published private(set) var channels: [Channel] = [] { didSet { visibleCache = nil; favoriteCountCache = nil } }
    @Published private(set) var groups: [Group] = []
    @Published private(set) var guide: [String: NowNext] = [:]
    @Published private(set) var guideNote: String?
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    @Published var selectedPlaylist: String?
    @Published var category: String = LiveModel.allKey { didSet { if category != oldValue { visibleCache = nil } } }
    @Published private(set) var extraCategories: [Category] = [] { didSet { visibleCache = nil } }
    /// (live sources device pass) Settings' Live TV row opens the Sources sheet over its own model:
    /// it reads and edits the sources but never downloads a playlist nobody is looking at.
    let sourcesOnly: Bool
    /// The channel the player showed last (the player's TV Guide tunes through `played`), and a
    /// request for the guide or list to put the ring on a channel's row (returning from the player).
    private(set) var lastPlayedId: String?
    struct FocusRequest: Equatable { let channelId: String; let token = UUID() }
    @Published var focusRequest: FocusRequest?

    init(sourcesOnly: Bool = false) { self.sourcesOnly = sourcesOnly }

    /// (live sources device pass) The chosen category's channels and ids, built once per change of
    /// channels / chip / rails instead of on every render: a group chip re-filtered the whole
    /// source (6,000 channels) for each body pass, and the guide's `.task(id:)` mapped every id
    /// on each now/next merge. The ids array is kept so that id compares by storage, not by value.
    private var visibleCache: (list: [Channel], ids: [String])?
    private var favoriteCountCache: Int?
    /// The source whose channels are on screen (a pick of another one clears them first).
    private var shownPlaylist: String?
    /// How many channels the loaded guide covers (0 = nothing to match against).
    @Published private(set) var guideChannelCount = 0
    /// Bumped after a manual EPG match changes; `lastRemapped` names the channel.
    @Published private(set) var epgMapRevision = 0
    private(set) var lastRemapped: String?
    /// Bumped whenever the guide data behind the lanes changed (the XMLTV or the Xtream short EPG
    /// landed), so the grid rebuilds the lanes it drew before the guide had loaded.
    @Published private(set) var guideRevision = 0

    private var tick: Task<Void, Never>?
    private var indexById: [String: Int] = [:]
    /// Only the newest channel load applies: a slow playlist must not land over the one picked after it.
    private var loadGeneration = 0

    deinit { tick?.cancel() }

    /// `.task` runs again whenever a cover over Live TV closes (every channel the viewer backs out
    /// of): the sources are re-read, but channels and guide reload only when they changed.
    func appear() async {
        let all: [Playlist] = (try? await HarborEngine.shared.call("live.playlists", [])) ?? []
        let key = { (list: [Playlist]) in list.map { "\($0.id)|\($0.url)|\($0.epgUrl ?? "")|\($0.kind ?? "")" } }
        if !channels.isEmpty, error == nil, key(all) == key(allSources) { return }
        await load()
    }

    func load() async {
        await loadSources()
        if sourcesOnly { return }
        await loadChannels()
    }

    /// The stored sources and the one to show; no channels.
    func loadSources() async {
        let all: [Playlist] = (try? await HarborEngine.shared.call("live.playlists", [])) ?? []
        allSources = all
        playlists = all.filter { ($0.kind ?? "m3u") != "epg" }
        if selectedPlaylist == nil || !playlists.contains(where: { $0.id == selectedPlaylist }) {
            // use-bp-live readActiveId: the source picked last time, else the first.
            let remembered: String? = try? await HarborEngine.shared.call("live.activeSource", [])
            selectedPlaylist = playlists.first(where: { $0.id == remembered })?.id ?? playlists.first?.id
        }
        sourcesRead = true
    }

    /// use-bp-live setActiveId: the picked source is remembered (next launch, the Home live row).
    func select(_ id: String) async {
        selectedPlaylist = id
        _ = try? await HarborEngine.shared.callJSON("live.setActiveSource", [.string(id)])
        if sourcesOnly { return }
        await loadChannels()
    }

    func loadChannels(force: Bool = false) async {
        loadGeneration += 1
        let generation = loadGeneration
        guard let id = selectedPlaylist else {
            setChannels([]); groups = []; extraCategories = []; guide = [:]; guideNote = nil; guideChannelCount = 0; loading = false
            shownPlaylist = nil
            return
        }
        if shownPlaylist != id {
            // (live sources device pass) use-bp-live: another source starts from the loading state.
            // The old source's channels, guide note and now/next stayed up under the new source's
            // name until its playlist arrived, and could be tuned and starred meanwhile.
            setChannels([]); groups = []; extraCategories = []; guide = [:]; guideNote = nil; guideChannelCount = 0
            shownPlaylist = id
        }
        loading = true
        error = nil
        do {
            let v: View_ = try await HarborEngine.shared.call("live.channels", [id, force])
            // (bug pass) A slower load for a source picked earlier used to land over this one.
            guard generation == loadGeneration else { return }
            guard selectedPlaylist == id else { loading = false; return }
            setChannels(v.channels)
            groups = v.groups
            extraCategories = v.categories ?? []
            if category != Self.favKey && category != Self.allKey && !extraCategories.contains(where: { $0.key == category }) { category = Self.allKey }
            loading = false
            // The guide follows on its own: a big XMLTV can take a while, and "Add source", a
            // source pick and Refresh (which wait for this) must not sit on it.
            Task { [weak self] in
                await self?.loadGuide(force: force)
                guard let self, generation == self.loadGeneration else { return }
                self.startTick()
            }
        } catch {
            guard generation == loadGeneration else { return }
            self.error = error.localizedDescription; setChannels([]); groups = []; extraCategories = []
            loading = false
        }
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
        var note: String?
        do {
            let o: Out = try await HarborEngine.shared.call("live.loadEpg", [id, force])
            covered = o.channels
            note = o.url == nil ? "No guide for this source. Add an EPG URL under Sources." : (o.channels == 0 ? "The guide loaded but lists no channels." : nil)
        } catch { note = T("Guide failed: %@", error.localizedDescription) }
        // A guide that lands after another source was picked belongs to that other source.
        guard selectedPlaylist == id else { return }
        guideNote = note
        guideChannelCount = covered
        guideRevision += 1
        await refreshNowNext()
        // use-xtream-epg-fallback: an Xtream source with no usable XMLTV asks get_short_epg per channel.
        let xtream = playlists.first { $0.id == id }?.kind == "xtream"
        // (perf pass) Judged on the rows asked so far (the first screenfuls), not the whole category.
        let asked = visible.compactMap { guide[$0.id] }
        if xtream, covered == 0 || !asked.isEmpty && asked.allSatisfy({ $0.known != true }) {
            struct Hydrated: Decodable { var hydrated: Int }
            let ids = visible.map(\.id)
            if let h: Hydrated = try? await HarborEngine.shared.call("live.loadShortEpg", [id, ids]), h.hydrated > 0, selectedPlaylist == id {
                guideNote = nil
                guideChannelCount = covered + h.hydrated
                guideRevision += 1
                await refreshNowNext()
            }
        }
    }

    /// (perf pass) Now/next for the rows someone can see, not the whole category: "All" on a
    /// 6,000-channel source sent every id on each 30 s tick and got ~2.7 MB of JSON back (≈50 ms of
    /// engine time in node, far more in JavaScriptCore on an Apple TV HD, then the decode and a
    /// republish of the whole map), also under the grid, which draws its own lanes. The first
    /// `nowNextLead` rows are asked up front, rows ask for themselves as they appear (`askNowNext`),
    /// and a refresh re-asks only the rows already in `guide`.
    private static let nowNextLead = 60
    private var nowNextPending: [String] = []
    private var nowNextPendingSet: Set<String> = []
    private var nowNextFlush: Task<Void, Never>?

    func refreshNowNext() async {
        guard let id = selectedPlaylist, !visible.isEmpty else { guide = [:]; return }
        var ids: [String] = []
        for (i, ch) in visible.enumerated() where i < Self.nowNextLead || guide[ch.id] != nil { ids.append(ch.id) }
        if let list: [NowNext] = try? await HarborEngine.shared.call("live.nowNext", [id, ids]) {
            // (review) A reply for a source switched away from would merge into the new source's map.
            guard selectedPlaylist == id else { return }
            merge(list)
        }
    }

    /// Now/next for channels outside the chosen category (the player's TV Guide, the Multiview
    /// picker), merged into `guide`; 400 ids at most per ask.
    func refreshNowNext(ids: [String]) async {
        guard let id = selectedPlaylist, !ids.isEmpty else { return }
        let ask = Array(ids.prefix(400))
        if let list: [NowNext] = try? await HarborEngine.shared.call("live.nowNext", [id, ask]) {
            guard selectedPlaylist == id else { return }
            merge(list)
        }
    }

    /// A row came on screen: its now/next is asked with the others that appear in the same moment.
    func askNowNext(_ channelId: String) {
        guard guide[channelId] == nil, nowNextPendingSet.insert(channelId).inserted else { return }
        nowNextPending.append(channelId)
        guard nowNextFlush == nil else { return }
        nowNextFlush = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard let self else { return }
            let ids = self.nowNextPending
            self.nowNextPending = []
            self.nowNextPendingSet = []
            self.nowNextFlush = nil
            var start = 0
            while start < ids.count {
                await self.refreshNowNext(ids: Array(ids[start..<min(ids.count, start + 400)]))
                start += 400
            }
        }
    }

    /// Only entries that changed are written, and the map is republished only when one did (a 30 s
    /// tick where nothing rolled over redraws nothing).
    private func merge(_ list: [NowNext]) {
        var next = guide
        var changed = false
        for n in list where next[n.id] != n { next[n.id] = n; changed = true }
        if changed { guide = next }
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
            (key: Self.favKey, label: T("Favorites"), count: favoriteCount, flag: nil),
            (key: Self.allKey, label: T("All"), count: channels.count, flag: nil),
        ]
        for c in extraCategories.prefix(Self.maxCategories - 2) { out.append((key: c.key, label: c.label, count: c.count, flag: c.flag)) }
        return out
    }

    var favoriteCount: Int {
        if let n = favoriteCountCache { return n }
        var n = 0
        for ch in channels where ch.favorite { n += 1 }
        favoriteCountCache = n
        return n
    }

    /// The group behind the chosen chip, when it is a group rail.
    var currentGroup: String? { extraCategories.first(where: { $0.key == category })?.group }

    /// Channels of the chosen category, in guide order (favorites, pins, most watched, networks, rest).
    var visible: [Channel] {
        if let held = visibleCache { return held.list }
        let list = buildVisible()
        let ids: [String] = list.map(\.id)
        visibleCache = (list: list, ids: ids)
        return list
    }

    /// The ids of `visible`, in order (the guide keys its lane seeding on them).
    var visibleIds: [String] {
        if visibleCache == nil { _ = visible }
        return visibleCache?.ids ?? []
    }

    /// A loaded channel by id.
    func channel(_ id: String) -> Channel? {
        guard let i = indexById[id], i < channels.count else { return nil }
        return channels[i]
    }

    private func buildVisible() -> [Channel] {
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
        if let i = indexById[ch.id], i < channels.count, channels[i].id == ch.id { channels[i].favorite = on }
    }

    func played(_ ch: Channel) {
        lastPlayedId = ch.id
        guard let id = selectedPlaylist else { return }
        // The player's subtitle and channel card read `guide`; a grid row past the first ones may not be in it yet.
        askNowNext(ch.id)
        Task { _ = try? await HarborEngine.shared.callJSON("live.recordPlay", [.string(id), .string(ch.id)]) }
    }

    /// bp-live-setup: the structured form; kind is "m3u", "xtream" or "epg".
    func add(kind: String, name: String, url: String, epgUrl: String, server: String, username: String, password: String) async -> String? {
        struct Added: Decodable { var id: String }
        do {
            let a: Added = try await HarborEngine.shared.call("live.addStructured", [kind, name, url, epgUrl, server, username, password])
            await added(a.id)
            return nil
        } catch { return error.localizedDescription }
    }

    func add(name: String, url: String, epgUrl: String) async -> String? {
        struct Added: Decodable { var id: String }
        do {
            let a: Added = try await HarborEngine.shared.call("live.addPlaylist", [name, url, epgUrl])
            await added(a.id)
            return nil
        } catch { return error.localizedDescription }
    }

    /// bp-live onAdded setActiveId (the engine ignores a guide-only source), then bp-live-setup
    /// onDone: the sheet closes at once and the playlist loads behind it.
    /// (live sources device pass) "Adding…" used to wait for the whole playlist download (a big
    /// list or a dead server held the sheet for the length of a network timeout).
    private func added(_ id: String) async {
        _ = try? await HarborEngine.shared.callJSON("live.setActiveSource", [.string(id)])
        selectedPlaylist = id
        // The spinner from the start: between the sources arriving and loadChannels running, a
        // frame drew the empty state ("Add a playlist") and the ring could land on it.
        if !sourcesOnly { loading = true }
        await loadSources()
        if sourcesOnly { return }
        Task { [weak self] in await self?.loadChannels() }
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
    /// view-mode-toggle.tsx "Multiview"; `multiviewSeed` is the channel "Add to Multiview" brought.
    @State private var showMultiview = false
    @State private var multiviewSeed: LiveModel.Channel?
    /// Set by the player's "Add to Multiview"; Multiview opens once the player's cover is gone
    /// (a present-while-dismissing is dropped on tvOS).
    @State private var pendingMultiview: LiveModel.Channel?
    /// nav "Playlists" (views/playlist-vod.tsx): the source's movies and shows.
    @State private var showVod = false

    /// The channel the viewer opened the player on (the player's TV Guide may tune others).
    @State private var openedChannel: String?
    @FocusState private var listFocus: String?
    @FocusState private var bandFocus: String?

    var body: some View {
        ZStack(alignment: .topLeading) {
            if !model.sourcesRead {
                // (live sources device pass) Nothing until the sources are known (see sourcesRead).
                Color.clear
            } else if model.playlists.isEmpty && !model.loading {
                LiveSourcesSheet(model: model, firstRun: true, dismiss: {})
            } else {
                VStack(alignment: .leading, spacing: BP.px(14)) {
                    band
                    if model.loading && model.channels.isEmpty {
                        ProgressView().tint(BP.inkMuted).frame(maxWidth: .infinity, alignment: .center).padding(.top, BP.px(60))
                    } else if model.visible.isEmpty {
                        emptyState
                    } else if grid && model.guideNote == nil {
                        LiveGuideView(live: model, play: { ch in open(ch) }, star: { ch in Task { await model.toggleFavorite(ch) } },
                                      replay: { ch, prog in Task { await startReplay(ch, prog) } },
                                      previewSuspended: playing != nil || replaying != nil || showSources || matching != nil || showMultiview || showVod,
                                      match: { ch in matching = ch })
                    } else {
                        guideList
                    }
                }
                .padding(.horizontal, BP.gutter).padding(.top, BP.barHeight + BP.px(16))
            }
        }
        .task { await model.appear() }
        .fullScreenCover(item: $playing, onDismiss: {
            // (live sources device pass) Back from the player puts the ring on the channel that was
            // playing: after zapping in the player's TV Guide it stayed on the first channel's row.
            if let last = model.lastPlayedId, last != openedChannel, pendingMultiview == nil { model.focusRequest = LiveModel.FocusRequest(channelId: last) }
            openedChannel = nil
            guard let ch = pendingMultiview else { return }
            pendingMultiview = nil
            multiviewSeed = ch
            showMultiview = true
        }) { ch in
            PlayerScreen(title: ch.name, subtitle: model.guide[ch.id]?.now?.title ?? ch.group, url: URL(string: ch.url) ?? URL(string: "about:blank")!, headers: ch.headers ?? [:], isLive: true,
                         liveGuide: model, liveChannel: ch, onAddToMultiview: { pendingMultiview = $0 }) { _ in playing = nil }
        }
        .fullScreenCover(isPresented: $showMultiview, onDismiss: { multiviewSeed = nil }) {
            MultiviewView(live: model, seed: multiviewSeed, dismiss: { showMultiview = false })
        }
        .fullScreenCover(isPresented: $showVod) {
            PlaylistVodView(dismiss: { showVod = false })
        }
        .fullScreenCover(item: $replaying) { r in
            // A bounded replay: VOD cache profile, seekable, subtitle says so (use-live-actions.ts).
            PlayerScreen(title: r.program.title, subtitle: T("%@ · catch up", r.channel.shownName), url: URL(string: r.url) ?? URL(string: "about:blank")!, headers: r.headers, isLive: false) { _ in replaying = nil }
        }
        .fullScreenCover(isPresented: $showSources) {
            LiveSourcesSheet(model: model, firstRun: false, dismiss: { showSources = false })
        }
        .fullScreenCover(item: $matching) { ch in
            EpgMatchView(model: model, channel: ch, dismiss: { matching = nil })
        }
    }

    private func open(_ ch: LiveModel.Channel) {
        // (live sources device pass) A second Select while the cover is still coming up is ignored.
        guard playing == nil, replaying == nil else { return }
        model.played(ch)
        openedChannel = ch.id
        playing = ch
    }

    private func startReplay(_ ch: LiveModel.Channel, _ prog: LiveModel.Program) async {
        struct Out: Decodable { var url: String; var headers: [String: String]? }
        guard let id = model.selectedPlaylist,
              let out: Out? = try? await HarborEngine.shared.call("live.catchupUrl", [id, ch.id, prog.startMs, prog.endMs]), let out else {
            open(ch); return
        }
        guard playing == nil, replaying == nil else { return }
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
                        Image(systemName: "antenna.radiowaves.left.and.right").accessibilityHidden(true)
                        Text(model.playlists.first { $0.id == model.selectedPlaylist }?.name ?? T("Sources"))
                        if model.loading && !model.channels.isEmpty {
                            // (live sources device pass) Refresh now closes Sources at once: the
                            // reload shows here while the current channels stay up.
                            ProgressView().scaleEffect(0.5).frame(width: BP.px(16), height: BP.px(16))
                        }
                    }
                }
                .buttonStyle(BPActionStyle(primary: true))
                // view-mode-toggle.tsx "Multiview": up to four channels at once.
                Button { multiviewSeed = nil; showMultiview = true } label: {
                    Label("Multiview", systemImage: "rectangle.split.2x2")
                }
                .buttonStyle(BPActionStyle())
                // nav "Playlists": the movies and shows the sources carry (views/playlist-vod.tsx).
                Button { showVod = true } label: {
                    Label("Playlists", systemImage: "film.stack")
                }
                .buttonStyle(BPActionStyle())
                // bp-live-filters: star on Favorites, a flag on country groups, no count at zero.
                ForEach(model.categories, id: \.key) { c in
                    Button {
                        model.category = c.key
                        Task { await model.refreshNowNext() }
                    } label: {
                        HStack(spacing: BP.px(6)) {
                            if c.key == LiveModel.favKey {
                                Image(systemName: c.count > 0 ? "star.fill" : "star").accessibilityHidden(true)
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
                    .buttonStyle(BPActionStyle(primary: model.category == c.key)).bpSelected(model.category == c.key)
                    .focused($bandFocus, equals: "chip:" + c.key)
                }
                // (live sources device pass) Hide group and Show … leave the band under the ring; the
                // ring is moved first (to All, or to the hidden-groups toggle while some remain)
                // instead of falling out of the band to the top bar.
                if let group = model.currentGroup {
                    Button("Hide group") {
                        bandFocus = "chip:" + LiveModel.allKey
                        model.category = LiveModel.allKey
                        Task { await model.toggleGroupHidden(group) }
                    }
                    .buttonStyle(BPActionStyle())
                }
                if showHidden {
                    ForEach(model.groups.filter { $0.hidden == true }) { g in
                        Button("Show \(g.name)") {
                            bandFocus = model.hiddenGroupCount > 1 ? "hidden" : "chip:" + LiveModel.allKey
                            Task { await model.toggleGroupHidden(g.name) }
                        }
                        .buttonStyle(BPActionStyle())
                    }
                }
                if model.hiddenGroupCount > 0 {
                    Button("\(model.hiddenGroupCount) hidden") { showHidden.toggle() }.buttonStyle(BPActionStyle(primary: showHidden))
                        .focused($bandFocus, equals: "hidden")
                }
                if model.guideNote == nil {
                    Button(grid ? "List" : "Guide") { grid.toggle() }.buttonStyle(BPActionStyle())
                }
                if let note = model.guideNote { BPNote(text: note).padding(.leading, BP.px(8)) }
            }
            .padding(.vertical, BP.px(4))
        }
        // (layout pass) 7 pt of track padding against a ring 9.5 pt out: the clip shaved the top and
        // bottom of the focused chip's ring and the whole left side of the first chip's.
        .scrollClipDisabled()
        .focusSection()
    }

    private var guideList: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: BP.px(6)) {
                    ForEach(model.visible) { ch in
                        LiveChannelRow(channel: ch, nowNext: model.guide[ch.id], focus: $listFocus,
                                       play: { open(ch) },
                                       star: { Task { await model.toggleFavorite(ch) } },
                                       pin: { Task { await model.togglePin(ch) } },
                                       match: model.canMatchEpg(ch) ? { matching = ch } : nil)
                            .id(ch.id)
                            .onAppear { model.askNowNext(ch.id) }
                    }
                }
                .padding(.vertical, BP.px(8)).padding(.bottom, BP.hintHeight + BP.px(40))
                .padding(.horizontal, Self.listHeadroom)
            }
            // (layout pass) The rows fill the scroller edge to edge: a focused row (~1 310 pt wide, 1.03
            // lift) reaches ~29 pt past its sides with the ring, and the clip cut the ring's left side
            // (and the right side of the last cell). bp-grid's HEADROOM: pad inside, pull out as much.
            .padding(.horizontal, -Self.listHeadroom)
            .focusSection()
            .onChange(of: model.focusRequest) { _, request in
                guard let id = request?.channelId else { return }
                model.focusRequest = nil
                guard model.visibleIds.contains(id) else { return }
                proxy.scrollTo(id, anchor: .center)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { listFocus = id }
            }
        }
    }

    /// bp-live.tsx BpLiveEmpty: a title, a line and one action, so the ring has somewhere to go
    /// below the band. (live sources device pass) It was a bare note: a playlist that failed to
    /// load could only be retried from Sources, and an empty Favorites had no way back to All.
    private var emptyState: some View {
        let failed = model.error != nil
        let favorites = model.category == LiveModel.favKey
        let title: String = failed ? T("Couldn't load this playlist") : (favorites ? T("No favorites yet") : T("No channels here"))
        let line: String = failed
            ? (model.error ?? "")
            : (favorites ? T("Press the star on any channel to keep it at the top of the guide.") : T("This playlist came back without any live channels."))
        let action: String = failed ? T("Try again") : (favorites ? T("Show all channels") : T("Add a playlist"))
        return VStack(spacing: BP.px(10)) {
            Text(title).font(BP.display(30)).foregroundStyle(BP.ink).multilineTextAlignment(.center)
            Text(line).font(BP.sans(16, .medium)).foregroundStyle(BP.inkSubtle).multilineTextAlignment(.center).lineLimit(4)
                .frame(maxWidth: BP.px(620))
            Button(action) {
                if failed { Task { await model.loadChannels(force: true) } }
                else if favorites { model.category = LiveModel.allKey }
                else { showSources = true }
            }
            .buttonStyle(BPActionStyle(primary: true, busy: failed && model.loading))
            .padding(.top, BP.px(8))
        }
        .frame(maxWidth: .infinity)
        .padding(.top, BP.px(60))
        .focusSection()
    }

    private static let listHeadroom = BP.px(18)
}

/// One guide row: logo, name, what's on now (with a live progress bar), what's next, a star.
struct LiveChannelRow: View {
    let channel: LiveModel.Channel
    let nowNext: LiveModel.NowNext?
    /// The list's ring, keyed by channel id on the row's main button (restored after the player).
    let focus: FocusState<String?>.Binding
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
                            Text(nowNext?.now?.title ?? T(nowNext?.known == true ? "No program info" : "Live"))
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
                            Text(T("Next %@", Self.time(n.startMs)) + " · " + n.title).font(BP.sans(11)).foregroundStyle(BP.inkMuted).lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, BP.px(14)).padding(.vertical, BP.px(10))
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).fill(BP.panel2))
            }
            .buttonStyle(BPTileStyle(radius: BP.rSM))
            .focused(focus, equals: channel.id)
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
    /// bp-live-sources seeds the ring on the active source; Settings opens on the form (bp-settings
    /// renders BpLiveSetup itself).
    var seedActive = true
    @State private var name = ""
    @State private var url = ""
    @State private var epg = ""
    @State private var kind = "m3u"
    @State private var server = ""
    @State private var username = ""
    @State private var password = ""
    @State private var busy = false
    @State private var error: String?
    /// source-picker.tsx confirmDialog('Remove playlist "{name}"?') before a source goes.
    @State private var removing: LiveModel.Playlist?
    @FocusState private var focus: String?

    /// bp-live-setup complete(): what each kind needs before Add is offered.
    private var ready: Bool {
        switch kind {
        case "xtream": return server.trimmingCharacters(in: .whitespaces).count >= 4 && !username.trimmingCharacters(in: .whitespaces).isEmpty && !password.isEmpty
        case "epg": return epg.trimmingCharacters(in: .whitespaces).count >= 8
        default: return url.trimmingCharacters(in: .whitespaces).count >= 8
        }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if !firstRun { BP.canvas.ignoresSafeArea() }
            HStack(alignment: .top, spacing: BP.px(40)) {
                VStack(alignment: .leading, spacing: BP.px(14)) {
                    Text(firstRun ? "Live TV" : "Sources").font(BP.display(36)).foregroundStyle(BP.ink)
                    BPNote(text: "Paste an M3U or M3U8 playlist URL, an IPTV middleware address, or an Xtream Codes login URL (get.php with username and password). Xtream guides are found automatically.")
                    // bp-live-setup kind picker: M3U link, Xtream Codes login, or guide data only.
                    HStack(spacing: BP.px(8)) {
                        ForEach([("m3u", "M3U playlist"), ("xtream", "Xtream Codes"), ("epg", "Guide data only")], id: \.0) { k, label in
                            Button(T(label)) { kind = k; error = nil }.buttonStyle(BPActionStyle(primary: kind == k)).bpSelected(kind == k)
                        }
                    }
                    BPField(label: "Name", placeholder: "My provider", text: $name)
                    if kind == "xtream" {
                        BPField(label: "Server", placeholder: "http://host:port", text: $server, keyboard: .URL)
                        BPField(label: "Username", placeholder: "Username", text: $username)
                        BPField(label: "Password", placeholder: "Password", text: $password, secure: true)
                    } else if kind == "m3u" {
                        BPField(label: "Playlist address", placeholder: "https://…/playlist.m3u", text: $url, keyboard: .URL)
                        BPField(label: "EPG URL (optional)", placeholder: "https://…/guide.xml.gz", text: $epg, keyboard: .URL)
                    } else {
                        BPField(label: "XMLTV address", placeholder: "https://…/guide.xml.gz", text: $epg, keyboard: .URL)
                    }
                    HStack(spacing: BP.px(12)) {
                        Button(busy ? "Adding…" : "Add source") {
                            guard !busy, ready else { return }
                            busy = true
                            Task {
                                // (live sources device pass) An M3U always goes through addPlaylist
                                // (detectProviderShape: http(s) check, Xtream login URLs, middleware).
                                // A server typed under Xtream before switching to M3U sent it through
                                // the unchecked structured path instead.
                                let failure: String? = kind == "m3u"
                                    ? await model.add(name: name, url: url, epgUrl: epg)
                                    : await model.add(kind: kind, name: name, url: url, epgUrl: epg, server: server, username: username, password: password)
                                error = failure
                                if failure == nil {
                                    // busy stays on while the sheet goes (a second press added the source
                                    // twice). First run has no sheet to close: a channel source has already
                                    // replaced the form (the sources were re-read), a guide-only one keeps it.
                                    name = ""; url = ""; epg = ""; server = ""; username = ""; password = ""
                                    if firstRun { busy = false }
                                    dismiss()
                                } else {
                                    busy = false
                                }
                            }
                        }
                        .buttonStyle(BPActionStyle(primary: true, busy: busy)).disabled(!ready)
                        if !firstRun { Button("Close") { dismiss() }.buttonStyle(BPActionStyle()) }
                    }
                    if let e = error ?? model.error { BPNote(text: e, tone: BP.danger) }
                }
                .frame(maxWidth: BP.px(560))
                if !model.allSources.isEmpty {
                    VStack(alignment: .leading, spacing: BP.px(10)) {
                        Text("Your sources").font(BP.sans(16, .semibold)).foregroundStyle(BP.ink)
                        ForEach(model.allSources) { pl in
                            let guideOnly = pl.kind == "epg"
                            let detail: String = guideOnly
                                ? T("Guide data only") + " · " + (pl.epgUrl ?? pl.url)
                                : (pl.epgUrl.map { T("Guide: %@", $0) } ?? T("No guide URL"))
                            HStack(spacing: BP.px(8)) {
                                // A guide-only source has no channels to show: it backs every source's guide.
                                Button(pl.name) {
                                    // bp-live-sources onPick + onClose: the sheet closes now and the
                                    // source loads behind it. (live sources device pass) It waited for the
                                    // whole playlist, and a late close shut a Sources sheet opened again.
                                    let id = pl.id
                                    dismiss()
                                    Task { await model.select(id) }
                                }
                                .buttonStyle(BPActionStyle(primary: model.selectedPlaylist == pl.id)).bpSelected(model.selectedPlaylist == pl.id)
                                .disabled(guideOnly)
                                .focused($focus, equals: "src:\(pl.id)")
                                Button("Remove") { removing = pl }.buttonStyle(BPActionStyle())
                            }
                            Text(detail).font(BP.sans(10)).foregroundStyle(BP.inkSubtle).lineLimit(1)
                        }
                        if model.selectedPlaylist != nil {
                            Button("Use the EPG URL above for the selected source") {
                                let value = epg
                                Task { await model.setEpgUrl(value); epg = "" }
                            }
                            .buttonStyle(BPActionStyle()).disabled(kind == "xtream" || epg.count < 8)
                            Button("Refresh channels and guide") {
                                dismiss()
                                Task { await model.loadChannels(force: true) }
                            }
                            .buttonStyle(BPActionStyle())
                        }
                    }
                    .frame(maxWidth: BP.px(520))
                }
            }
            .padding(.horizontal, BP.gutter).padding(.top, BP.barHeight + BP.px(20))
        }
        .focusSection()
        .alert(T("Remove playlist \"%@\"?", removing?.name ?? ""), isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), presenting: removing) { pl in
            Button("Remove", role: .destructive) {
                let id = pl.id
                Task { await model.remove(id) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .task {
            guard !firstRun else { return }
            if !model.sourcesRead { await model.load() }
            // bp-live-sources: the ring starts on the active source (it started on the kind picker).
            guard seedActive, let id = model.selectedPlaylist else { return }
            try? await Task.sleep(for: .milliseconds(150))
            if focus == nil { focus = "src:\(id)" }
        }
    }
}

/// Settings' Live TV row (bp-settings.tsx pane "live" renders BpLiveSetup in place): the Sources
/// sheet over its own model. (live sources device pass) The row used to leave Settings for the
/// Live TV tab, where a viewer with sources landed on the guide, not on the form.
struct LiveSourcesCover: View {
    let dismiss: () -> Void
    @StateObject private var model = LiveModel(sourcesOnly: true)

    var body: some View {
        LiveSourcesSheet(model: model, firstRun: false, dismiss: dismiss, seedActive: false)
    }
}
