import Foundation
import Combine

/// Detail page data: the full meta (Cinemeta / addon, with episodes for series) through the engine.
@MainActor
final class DetailModel: ObservableObject {
    struct Episode: Identifiable, Equatable {
        var id: String
        var season: Int
        var episode: Int
        var title: String
        var overview: String?
        var thumbnail: String?
        var released: Date?
        var playEpisode: AnyJSON
    }

    @Published private(set) var meta: Meta
    @Published private(set) var episodes: [Episode] = []
    @Published private(set) var seasons: [Int] = []
    @Published var season: Int = 1
    @Published private(set) var loading = false
    /// Resume state for the Play button (detail-spec §1.3/1.4): where the viewer left off.
    @Published private(set) var resume: Resume?

    struct Resume: Equatable {
        var season: Int?
        var episode: Int?
        var positionMs: Double
        var durationMs: Double
        var progress: Double { durationMs > 0 ? min(1, max(0, positionMs / durationMs)) : 0 }
    }

    init(meta: Meta) { self.meta = meta }

    var isSeries: Bool { meta.type == "series" || meta.type == "anime" }
    var seasonEpisodes: [Episode] { episodes.filter { $0.season == season } }

    func load() async {
        guard !loading else { return }
        loading = true; defer { loading = false }
        let kind = isSeries ? "series" : "movie"
        if let full: Meta = try? await HarborEngine.shared.call("cinemeta.meta", [kind, meta.id]) {
            meta = full
        }
        buildEpisodes()
        await loadResume()
    }

    /// Cloud library entry first (Stremio), else the local resume store, like bpResumeMark.
    private func loadResume() async {
        struct Item: Decodable {
            struct State: Decodable { var timeOffset: Double?; var duration: Double?; var season: Int?; var episode: Int?; var video_id: String? }
            var state: State?
        }
        struct Local: Decodable { var ms: Double; var pct: Double? }
        let p = ProfilesStore.shared.active
        if let authKey = p.flatMap({ ProfilesStore.shared.stremioSession(for: $0.id)?.authKey }),
           let item: Item? = try? await HarborEngine.shared.call("stremio.libraryGetOne", [authKey, meta.id]),
           let st = item?.state, let off = st.timeOffset, off > 0 {
            var s = st.season, e = st.episode
            if (s == nil || e == 0), let vid = st.video_id {
                let parts = vid.split(separator: ":")
                if parts.count >= 3, let ps = Int(parts[parts.count - 2]), let pe = Int(parts[parts.count - 1]) { s = ps; e = pe }
            }
            resume = Resume(season: isSeries ? s : nil, episode: isSeries ? e : nil, positionMs: off, durationMs: st.duration ?? 0)
            if let s, isSeries, seasons.contains(s) { season = s }
            return
        }
        if !isSeries, let local: Local? = try? await HarborEngine.shared.call("player.localResume", [meta.id, AnyJSON.null, AnyJSON.null]), let l = local {
            resume = Resume(season: nil, episode: nil, positionMs: l.ms, durationMs: l.pct.map { $0 > 0 ? l.ms / $0 : 0 } ?? 0)
        } else if isSeries {
            // Scan this season's episodes for the most recent local entry.
            var best: (Episode, Local)?
            for ep in episodes {
                if let l: Local? = try? await HarborEngine.shared.call("player.localResume", [meta.id, ep.season, ep.episode]), let l, l.ms > 0 {
                    best = (ep, l)
                }
            }
            if let (ep, l) = best {
                resume = Resume(season: ep.season, episode: ep.episode, positionMs: l.ms, durationMs: l.pct.map { $0 > 0 ? l.ms / $0 : 0 } ?? 0)
                season = ep.season
            }
        }
    }

    /// The episode Play should start with: the resume target, else the first of the current season.
    var playTarget: Episode? {
        if let r = resume, let s = r.season, let e = r.episode, let ep = episodes.first(where: { $0.season == s && $0.episode == e }) { return ep }
        return seasonEpisodes.first
    }

    var playLabel: String {
        if let r = resume {
            if isSeries, let s = r.season, let e = r.episode { return "Resume S\(s):E\(e)" }
            if r.positionMs > 60_000 { return "Resume" }
        }
        if isSeries, let t = playTarget { return "Play S\(t.season) E\(t.episode)" }
        return "Play"
    }

    private func buildEpisodes() {
        guard isSeries, let videos = meta.videos else { return }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var out: [Episode] = []
        for v in videos {
            guard let s = v["season"]?.number, let e = (v["episode"] ?? v["number"])?.number else { continue }
            let id = v["id"]?.string ?? "\(meta.id):\(Int(s)):\(Int(e))"
            let title = v["name"]?.string ?? v["title"]?.string ?? "Episode \(Int(e))"
            let rel = (v["released"] ?? v["firstAired"])?.string
            let date = rel.flatMap { iso.date(from: $0) ?? ISO8601DateFormatter().date(from: $0) }
            let play: AnyJSON = .object([
                "season": .number(s), "episode": .number(e), "name": .string(title), "videoId": .string(id),
                "imdbId": meta.id.hasPrefix("tt") ? .string(meta.id) : .null,
                "imdbSeason": meta.id.hasPrefix("tt") ? .number(s) : .null,
                "imdbEpisode": meta.id.hasPrefix("tt") ? .number(e) : .null,
            ])
            out.append(Episode(id: id, season: Int(s), episode: Int(e), title: title, overview: v["overview"]?.string ?? v["description"]?.string,
                               thumbnail: v["thumbnail"]?.string, released: date, playEpisode: play))
        }
        out.sort { ($0.season, $0.episode) < ($1.season, $1.episode) }
        episodes = out
        let all = Array(Set(out.map(\.season))).sorted()
        // Specials (season 0) go last, like upstream.
        seasons = all.filter { $0 > 0 } + all.filter { $0 == 0 }
        if let first = seasons.first, !seasons.contains(season) { season = first }
    }
}
