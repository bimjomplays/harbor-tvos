import Foundation
import Combine

/// Upstream's `ScoredStream`, the fields the picker shows.
struct ScoredStream: Decodable, Identifiable, Equatable {
    struct Audio: Decodable, Equatable { var codec: String?; var channels: Double? }
    var parsedTitle: String?
    var title: String?
    var name: String?
    var resolution: String?
    var hdrFormat: String?
    var codec: String?
    var source: String?
    var audio: Audio?
    var audioLanguages: [String]?
    var size: Double?
    var seeders: Double?
    var cached: [String: Bool]?
    var container: String?
    var releaseGroup: String?
    var remux: Bool?
    var score: Double
    var tier: String
    var addonName: String
    var addonId: String
    var addonUrl: String?
    /// stampAddonOrder: the stream's position in its addon's own response.
    var nativeIdx: Int?
    var url: String?
    var infoHash: String?
    /// engine/streams.ts stampPickerRows: bp-stream-row.tsx's detail line, full description and filename.
    struct RowText: Decodable, Equatable { var headline: String; var detail: String; var description: String; var filename: String }
    var tvRow: RowText?
    /// The ids of the saved stream filters (settings.customStreamFilters) this stream passes.
    var tvFilters: [String]?
    var index: Int = 0   // position in picker.all, set after decoding

    var id: String { "\(index)-\(addonId)-\(url ?? infoHash ?? parsedTitle ?? "")" }
    var isCached: Bool { cached?.values.contains(true) ?? false }
    var sizeText: String? {
        guard let s = size, s > 0 else { return nil }
        let gb = s / 1_073_741_824
        return gb >= 1 ? String(format: "%.1f GB", gb) : String(format: "%.0f MB", s / 1_048_576)
    }

    private enum CodingKeys: String, CodingKey {
        case parsedTitle, title, name, resolution, hdrFormat, codec, source, audio, audioLanguages, size, seeders, cached, container, releaseGroup, remux, score, tier, addonName, addonId, url, infoHash, tvRow, tvFilters
        // stampAddonOrder's fields: the "addon order" sort ranks by these, so they must decode.
        case addonUrl, nativeIdx
    }
}

struct RankedPicker: Decodable {
    var primary: ScoredStream?
    var all: [ScoredStream]
}

/// The Stage-3 stream search for one title through the engine (engine/streams.ts).
@MainActor
final class StreamsModel: ObservableObject {
    struct SearchResult: Decodable {
        struct Imdb: Decodable { var id: String?; var verified: Bool }
        struct Result: Decodable { var picker: RankedPicker; var debridErrors: [DebridError]? }
        struct DebridError: Decodable { var slug: String; var name: String; var code: String }
        var token: String
        var imdb: Imdb
        var streamIds: [String]
        var addonCount: Int
        var addonOrder: [String]?
        var debridCount: Int?
        var seasonLock: Bool?
        var result: Result?
        var error: String?
    }

    enum Phase: Equatable { case idle, searching, done, failed(String) }

    @Published private(set) var streams: [ScoredStream] = []
    @Published private(set) var primary: ScoredStream?
    /// Installed addon order (transport URLs) for the picker's "addon order" sort.
    @Published private(set) var addonOrder: [String] = []
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var progress: (settled: Int, total: Int) = (0, 0)
    @Published private(set) var addonCount = 0
    @Published private(set) var debridErrors: [String] = []
    /// use-bp-streams noSources half: how many debrid services are configured.
    @Published private(set) var debridCount = 0
    /// use-bp-stream-play seasonLock: auto-fire retries the same source too.
    @Published private(set) var seasonLock = false
    /// use-bp-streams rememberedStream: index into `streams` of the last pick (or season-locked source).
    @Published private(set) var rememberedIndex: Int?
    /// Home-server copies of this title (use-bp-streams homeServerCopies), loaded beside the addon search.
    @Published private(set) var copies: [HomeCopy] = []
    /// The copies lookup has answered (bp-streams waits for homeServersLoaded before its preference).
    @Published private(set) var copiesLoaded = false
    /// bp-stream-filters customFilters / activeFilterId: the saved filters synced from the desktop.
    struct SavedFilter: Decodable, Identifiable, Equatable { var id: String; var name: String; var empty: Bool }
    @Published private(set) var savedFilters: [SavedFilter] = []
    @Published private(set) var activeFilterId: String?
    /// A picked torrent is being added to the TV's engine (metadata, up to a minute).
    @Published private(set) var p2pStarting = false
    struct HomeCopy: Decodable, Identifiable { var key: String; var label: String; var sourceLabel: String; var connectionId: String; var itemId: String; var versionId: String; var quality: String?; var sizeBytes: Double?; var resolution: String?; var progressMs: Double; var id: String { key } }

    let token = UUID().uuidString
    private var subscribed = false
    private var unsubscribe: (() -> Void)?

    deinit { unsubscribe?() }

    /// `episode` is upstream's PlayEpisode as JSON (season/episode/...); nil for movies.
    /// use-bp-streams strictMode / forceShowAll: the loosen ladder re-runs the pipeline.
    @Published private(set) var strict = (SettingsBridge.shared.slice.streamFilterLevel ?? "strict") == "strict"
    @Published private(set) var showAll = SettingsBridge.shared.slice.streamFilterLevel == "off"
    var canLoosen: Bool { strict || !showAll }
    private var lastMeta: Meta?
    private var lastEpisode: AnyJSON?

    func searchWider() async { guard let m = lastMeta else { return }; strict = false; await search(meta: m, episode: lastEpisode) }
    func showEverything() async { guard let m = lastMeta else { return }; strict = false; showAll = true; await search(meta: m, episode: lastEpisode) }

    func search(meta: Meta, episode: AnyJSON?) async {
        lastMeta = meta; lastEpisode = episode
        phase = .searching
        streams = []; primary = nil; progress = (0, 0); rememberedIndex = nil
        subscribeOnce()
        let p = ProfilesStore.shared.active
        let authKey = p.flatMap { ProfilesStore.shared.stremioSession(for: $0.id)?.authKey }
        struct Filters: Decodable { var filters: [SavedFilter]; var activeId: String? }
        if let f: Filters = try? await HarborEngine.shared.call("streamsRoom.streamFilters", [p?.id ?? "default", p?.linked ?? true]) {
            savedFilters = f.filters
            activeFilterId = f.activeId
        }
        Task { [weak self] in
            let season = episode?["season"]?.number.map { Int($0) }, ep = episode?["episode"]?.number.map { Int($0) }
            let list: [HomeCopy] = (try? await HarborEngine.shared.call("homeServers.copies", [meta, meta.id.hasPrefix("tt") ? meta.id : nil as String?, season, ep])) ?? []
            self?.copies = list
            self?.copiesLoaded = true
        }
        do {
            let r: SearchResult = try await HarborEngine.shared.call("streamsRoom.search",
                [token, p?.id ?? "default", p?.linked ?? true, authKey, meta, episode ?? AnyJSON.null, AnyJSON.object(["strictMode": .bool(strict), "filterDisabled": .bool(showAll)])])
            if let err = r.error { phase = .failed(err); return }
            addonCount = r.addonCount
            addonOrder = r.addonOrder ?? []
            debridCount = r.debridCount ?? 0
            seasonLock = r.seasonLock ?? false
            debridErrors = (r.result?.debridErrors ?? []).map { "\($0.name): \($0.code)" }
            apply(r.result?.picker)
            let season = episode?["season"]?.number.map { Int($0) }, ep = episode?["episode"]?.number.map { Int($0) }
            let pinned: Int? = try? await HarborEngine.shared.call("streamsRoom.remembered", [token, p?.id ?? "default", p?.linked ?? true, meta, season, ep])
            rememberedIndex = pinned.flatMap { streams.indices.contains($0) ? $0 : nil }
            phase = .done
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// bp-stream-filters setActiveFilterId: update({ activeStreamFilterId }), so it sticks for next time.
    func setActiveFilter(_ id: String?) async {
        activeFilterId = id
        let p = ProfilesStore.shared.active
        do {
            let saved: String? = try await HarborEngine.shared.call("streamsRoom.setActiveStreamFilter", [p?.id ?? "default", p?.linked ?? true, id])
            activeFilterId = saved
        } catch {
            // The pick still narrows this list; it just was not saved.
        }
    }

    func cancel() {
        unsubscribe?(); unsubscribe = nil; subscribed = false
        Task { _ = try? await HarborEngine.shared.callJSON("streamsRoom.cancelSearch", [.string(token)]) }
    }

    /// Debrid unrestrict / direct link for a picked stream.
    struct Resolved: Decodable {
        struct Link: Decodable {
            var url: String
            var filename: String?
            var headers: [String: String]?
            var notWebReady: Bool?
            var subtitles: [Sub]?
            struct Sub: Decodable { var url: String; var lang: String? }
        }
        var ok: Bool
        var data: Link?
        var via: String?
        var code: String?
        /// Set for a home-server copy: who to report progress to, and where the server left off.
        var homeServer: HomeServerSession? = nil
        /// picker-utils translatePickerError copy for `code` (nil when upstream has none).
        var message: String? = nil
        /// picker-utils isDebridFailure: the debrid's side failed, not the source.
        var debridFailure: Bool? = nil
        /// engine/streams.ts P2pPlan: resolve would have handed this torrent to the local engine.
        var p2p: TorrentEngine.Plan? = nil
        /// view.ts PlayerSrc.autoFired: set by the picker when instant play fired this stream on its own.
        var autoPicked: Bool? = nil
        /// view.ts PlayerSrc.streamRef (engine streamsRoom.deadRef): set by the picker for the stream it handed over.
        var streamRef: AnyJSON? = nil
    }

    /// A home-server copy resolves through the server (direct play or transcode).
    func play(copy: HomeCopy, meta: Meta) async -> Resolved {
        struct Session: Decodable { var connectionId: String; var itemId: String; var versionId: String?; var playbackSessionId: String? }
        struct Out: Decodable { var url: String; var headers: [String: String]?; var subtitle: String?; var subtitles: [Resolved.Link.Sub]; var resumeMs: Double; var session: Session }
        do {
            let o: Out = try await HarborEngine.shared.call("homeServers.play", [meta, copy.connectionId, copy.itemId, copy.versionId])
            let session = HomeServerSession(connectionId: o.session.connectionId, itemId: o.session.itemId, versionId: o.session.versionId,
                                            playbackSessionId: o.session.playbackSessionId, resumeSec: o.resumeMs / 1000)
            return Resolved(ok: true, data: Resolved.Link(url: o.url, filename: nil, headers: o.headers, notWebReady: true, subtitles: o.subtitles), via: o.subtitle, code: nil, homeServer: session)
        } catch {
            return Resolved(ok: false, data: nil, via: nil, code: error.localizedDescription, homeServer: nil)
        }
    }

    /// use-auto-candidates: indexes into `streams` worth firing without asking, best first.
    func autoCandidates(meta: Meta, episode: AnyJSON?) async -> [Int] {
        let p = ProfilesStore.shared.active
        let season = episode?["season"]?.number.map { Int($0) }, ep = episode?["episode"]?.number.map { Int($0) }
        let anime = meta.type == "anime" || ["kitsu:", "mal:", "anilist:", "anidb:"].contains { meta.id.hasPrefix($0) }
        // use-bp-stream-play prefer1080: !!kid.
        return (try? await HarborEngine.shared.call("streamsRoom.autoCandidates", [token, p?.id ?? "default", p?.linked ?? true, meta, season, ep, anime, nil as [String]?, p?.kid != nil])) ?? []
    }

    /// use-pick-handler streamRef: what lib/dead-streams fingerprints for this stream, so the player
    /// can mark it dead after this search is gone (nil when the search no longer has it).
    func deadRef(_ stream: ScoredStream) async -> AnyJSON? {
        guard let ref = try? await HarborEngine.shared.callJSON("streamsRoom.deadRef", [.string(token), .number(Double(stream.index))]) else { return nil }
        if case .null = ref { return nil }
        return ref
    }

    /// use-pick-handler savePlayback: remember what played for next time's instant play.
    func remember(_ stream: ScoredStream, meta: Meta, episode: AnyJSON?, url: String?) async {
        let p = ProfilesStore.shared.active
        let season = episode?["season"]?.number.map { Int($0) }, ep = episode?["episode"]?.number.map { Int($0) }
        _ = try? await HarborEngine.shared.callJSON("streamsRoom.rememberPlayback", [.string(token), .string(p?.id ?? "default"), .bool(p?.linked ?? true),
            (try? JSONDecoder().decode(AnyJSON.self, from: JSONEncoder().encode(meta))) ?? .null, .number(Double(stream.index)), url.map { .string($0) } ?? .null,
            season.map { .number(Double($0)) } ?? .null, ep.map { .number(Double($0)) } ?? .null])
    }

    func resolve(_ stream: ScoredStream, forceP2p: Bool = false) async -> Resolved {
        let r = await resolveInEngine(stream, forceP2p: forceP2p, afterP2p: false)
        guard !r.ok, let plan = r.p2p else { return r }
        // resolve.ts tryLocalEngine, through the TV's librqbit engine (App/Sources/Torrent).
        p2pStarting = true
        defer { p2pStarting = false }
        do {
            let s = try await TorrentEngine.shared.stream(plan)
            let subs = plan.subtitles?.map { Resolved.Link.Sub(url: $0.url, lang: $0.lang) }
            return Resolved(ok: true, data: Resolved.Link(url: s.url, filename: plan.filename, headers: nil, notWebReady: plan.notWebReady, subtitles: subs), via: "p2p", code: nil)
        } catch {
            // resolveStream's P2P-first pick continues with the debrids when the engine fails.
            if plan.debridFallback == true { return await resolveInEngine(stream, forceP2p: false, afterP2p: true) }
            let code = (error as? TorrentEngine.Failure)?.code ?? "engine-not-ready"
            let message: String? = try? await HarborEngine.shared.call("streamsRoom.failureMessage", [code])
            return Resolved(ok: false, data: nil, via: nil, code: code, message: message, debridFailure: false)
        }
    }

    private func resolveInEngine(_ stream: ScoredStream, forceP2p: Bool, afterP2p: Bool) async -> Resolved {
        let p = ProfilesStore.shared.active
        // The episode hint picks the file inside a season pack (resolve.ts selectEngineFileIdx, debrids).
        let season = lastEpisode?["season"]?.number.map { Int($0) }, ep = lastEpisode?["episode"]?.number.map { Int($0) }
        do {
            return try await HarborEngine.shared.call("streamsRoom.resolve", [p?.id ?? "default", p?.linked ?? true, token, stream.index, true, forceP2p, afterP2p, season, ep])
        } catch {
            return Resolved(ok: false, data: nil, via: nil, code: error.localizedDescription)
        }
    }

    /// use-pick-handler onPlay: whether this pick needs BpP2pDialog's consent first.
    func p2pConsentNeeded(_ stream: ScoredStream) async -> Bool {
        let p = ProfilesStore.shared.active
        let needed: Bool? = try? await HarborEngine.shared.call("streamsRoom.p2pConsentNeeded", [token, p?.id ?? "default", p?.linked ?? true, stream.index, p?.kid != nil])
        return needed ?? false
    }

    /// BpP2pDialog "Always stream P2P".
    func setP2pAutoConsent() async {
        let p = ProfilesStore.shared.active
        _ = try? await HarborEngine.shared.callJSON("streamsRoom.setP2pAutoConsent", [.string(p?.id ?? "default"), .bool(p?.linked ?? true)])
    }

    private func apply(_ picker: RankedPicker?) {
        guard let picker else { return }
        var all = picker.all
        for i in all.indices { all[i].index = i }
        streams = all
        primary = picker.primary.flatMap { prim in all.first { $0.url == prim.url && $0.infoHash == prim.infoHash && $0.addonId == prim.addonId } } ?? all.first
    }

    private func subscribeOnce() {
        guard !subscribed else { return }
        subscribed = true
        unsubscribe = HarborEngine.shared.onEvent { [weak self] type, detail in
            guard type == "harbor-tvos:streams", let self, detail?["token"]?.string == self.token else { return }
            switch detail?["phase"]?.string {
            case "progress":
                self.progress = (Int(detail?["settled"]?.number ?? 0), Int(detail?["total"]?.number ?? 0))
            case "partial":
                if let pickerJSON = detail?["picker"], let picker = try? pickerJSON.decode(RankedPicker.self) { self.apply(picker) }
                if self.phase == .searching, !self.streams.isEmpty { /* keep searching state; UI shows rows already */ }
            default: break
            }
        }
    }
}

/// view.ts PlayerSrc autoFired / attempt / streamRef: how a picker's pick reached the player, for
/// views/player.tsx's next-stream skip (a stalled or failed auto pick) and use-stub-detection.ts.
struct PlayerPickInfo {
    /// PlayerSrc.autoFired: instant play fired this stream; nobody chose it.
    var autoPicked: Bool
    /// PlayerSrc.attempt: how many times the player has sent this title back to the picker.
    var attempt: Int
    /// PlayerSrc.streamRef as engine streamsRoom.deadRef built it.
    var streamRef: AnyJSON?
}
