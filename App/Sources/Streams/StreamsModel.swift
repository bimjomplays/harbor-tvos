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
    var url: String?
    var infoHash: String?
    var index: Int = 0   // position in picker.all, set after decoding

    var id: String { "\(index)-\(addonId)-\(url ?? infoHash ?? parsedTitle ?? "")" }
    var isCached: Bool { cached?.values.contains(true) ?? false }
    var sizeText: String? {
        guard let s = size, s > 0 else { return nil }
        let gb = s / 1_073_741_824
        return gb >= 1 ? String(format: "%.1f GB", gb) : String(format: "%.0f MB", s / 1_048_576)
    }

    private enum CodingKeys: String, CodingKey {
        case parsedTitle, title, name, resolution, hdrFormat, codec, source, audio, audioLanguages, size, seeders, cached, container, releaseGroup, remux, score, tier, addonName, addonId, url, infoHash
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
        var result: Result?
        var error: String?
    }

    enum Phase: Equatable { case idle, searching, done, failed(String) }

    @Published private(set) var streams: [ScoredStream] = []
    @Published private(set) var primary: ScoredStream?
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var progress: (settled: Int, total: Int) = (0, 0)
    @Published private(set) var addonCount = 0
    @Published private(set) var debridErrors: [String] = []
    /// Home-server copies of this title (use-bp-streams homeServerCopies), loaded beside the addon search.
    @Published private(set) var copies: [HomeCopy] = []
    struct HomeCopy: Decodable, Identifiable { var key: String; var label: String; var sourceLabel: String; var connectionId: String; var itemId: String; var versionId: String; var quality: String?; var sizeBytes: Double?; var resolution: String?; var progressMs: Double; var id: String { key } }

    let token = UUID().uuidString
    private var subscribed = false
    private var unsubscribe: (() -> Void)?

    deinit { unsubscribe?() }

    /// `episode` is upstream's PlayEpisode as JSON (season/episode/...); nil for movies.
    func search(meta: Meta, episode: AnyJSON?) async {
        phase = .searching
        streams = []; primary = nil; progress = (0, 0)
        subscribeOnce()
        let p = ProfilesStore.shared.active
        let authKey = p.flatMap { ProfilesStore.shared.stremioSession(for: $0.id)?.authKey }
        Task { [weak self] in
            let season = episode?["season"]?.number.map { Int($0) }, ep = episode?["episode"]?.number.map { Int($0) }
            let list: [HomeCopy] = (try? await HarborEngine.shared.call("homeServers.copies", [meta, meta.id.hasPrefix("tt") ? meta.id : nil as String?, season, ep])) ?? []
            self?.copies = list
        }
        do {
            let r: SearchResult = try await HarborEngine.shared.call("streamsRoom.search",
                [token, p?.id ?? "default", p?.linked ?? true, authKey, meta, episode ?? AnyJSON.null, AnyJSON.object([:])])
            if let err = r.error { phase = .failed(err); return }
            addonCount = r.addonCount
            debridErrors = (r.result?.debridErrors ?? []).map { "\($0.name): \($0.code)" }
            apply(r.result?.picker)
            phase = .done
        } catch {
            phase = .failed(error.localizedDescription)
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
        var homeServer: HomeServerSession?
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

    func resolve(_ stream: ScoredStream) async -> Resolved {
        let p = ProfilesStore.shared.active
        do {
            return try await HarborEngine.shared.call("streamsRoom.resolve", [p?.id ?? "default", p?.linked ?? true, token, stream.index, true])
        } catch {
            return Resolved(ok: false, data: nil, via: nil, code: error.localizedDescription)
        }
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
