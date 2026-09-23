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
    @Published var season: Int = 1 { didSet { if season != oldValue { Task { await loadEpisodeFacts() } } } }
    @Published private(set) var loading = false
    /// use-bp-episode-facts: per-episode rating (IMDb over TMDB) and runtime, keyed "season:episode".
    @Published private(set) var episodeFacts: [String: EpisodeFact] = [:]
    struct EpisodeFact: Decodable { var season: Int; var episode: Int; var rating: Double?; var ratingIsImdb: Bool; var runtime: Int? }

    func loadEpisodeFacts() async {
        guard isSeries, !isAnimeId else { return }
        let p = ProfilesStore.shared.active
        let list: [EpisodeFact] = (try? await HarborEngine.shared.call("detailRoom.episodeFacts", [meta, season, p?.id ?? "default", p?.linked ?? true])) ?? []
        for f in list { episodeFacts["\(f.season):\(f.episode)"] = f }
    }
    func fact(for ep: Episode) -> EpisodeFact? { episodeFacts["\(ep.season):\(ep.episode)"] }
    /// Resume state for the Play button (detail-spec §1.3/1.4): where the viewer left off.
    @Published private(set) var resume: Resume?
    /// Stremio library membership ("Add to Watchlist" / "In Watchlist", detail-spec §1.3).
    @Published private(set) var inWatchlist = false
    @Published private(set) var watchlistBusy = false
    @Published private(set) var canWatchlist = false
    /// "season:episode" keys the Stremio library marks watched.
    @Published private(set) var watched: Set<String> = []
    /// TMDB extras (detail-spec §1.2 step 3): nil without a key or for anime ids.
    @Published private(set) var extras: Extras?
    /// bp-anime-characters: AniList characters for an anime id (empty otherwise).
    @Published private(set) var characters: [AnimeCharacter] = []
    struct AnimeCharacter: Decodable, Identifiable { var id: Int; var name: String; var nativeName: String?; var image: String?; var role: String? }
    private struct AnimeDetail: Decodable {
        struct D: Decodable { var name: String?; var overview: String?; var backdrop: String?; var poster: String?; var year: String?; var genres: [String] }
        struct Ep: Decodable { var id: Int; var season: Int; var number: Int; var title: String; var synopsis: String; var thumbnail: String?; var airdate: String?; var length: Int?; var filler: Bool; var playEpisode: AnyJSON }
        var canonicalId: String; var imdbId: String?; var detail: D; var episodes: [Ep]; var showSeason: Bool; var characters: [AnimeCharacter]
    }
    var isAnimeId: Bool { ["kitsu:", "mal:", "anilist:", "anidb:"].contains { meta.id.hasPrefix($0) } }
    @Published private(set) var collectionRow: BrowseRow?

    struct Extras: Decodable {
        struct Cast: Decodable, Identifiable { var id: Int; var name: String; var character: String; var profile: String? }
        struct Crew: Decodable, Identifiable {
            struct Person: Decodable, Identifiable { var id: Int?; var name: String }
            var label: String; var names: [String]; var people: [Person]?
            var id: String { label }
        }
        struct Fact: Decodable, Identifiable { var label: String; var value: String; var id: String { label } }
        struct Provider: Decodable, Identifiable { var name: String; var logo: String; var id: String { name } }
        struct Collection: Decodable { var id: Int; var name: String }
        var kind: String; var tmdbId: Int; var imdbId: String?; var tagline: String; var overview: String
        var rating: String?; var runtime: String?; var status: String; var genres: [String]
        var cast: [Cast]; var crew: [Crew]; var recommendations: [Meta]; var similar: [Meta]
        var trailerYtId: String?; var collection: Collection?; var facts: [Fact]; var watchOn: [Provider]
    }

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
        if isAnimeId {
            // use-bp-anime-detail: a kitsu id resolves to nothing on TMDB or Cinemeta; the Kitsu chain owns it.
            let p = ProfilesStore.shared.active
            if let a: AnimeDetail = try? await HarborEngine.shared.call("animeDetail.load", [meta, p?.id ?? "default", p?.linked ?? true]) {
                var m = meta
                if let n = a.detail.name, !n.isEmpty { m.name = n }
                if let o = a.detail.overview, !o.isEmpty { m.description = o }
                if let b = a.detail.backdrop { m.background = b }
                if let po = a.detail.poster { m.poster = po }
                if let y = a.detail.year { m.releaseInfo = y }
                if !a.detail.genres.isEmpty { m.genres = a.detail.genres }
                meta = m
                let iso = ISO8601DateFormatter.dateOnly
                episodes = a.episodes.map { e in
                    Episode(id: "\(meta.id):\(e.season):\(e.number)", season: e.season, episode: e.number, title: e.title.isEmpty ? "Episode \(e.number)" : e.title,
                            overview: e.synopsis.isEmpty ? nil : e.synopsis, thumbnail: e.thumbnail, released: e.airdate.flatMap { iso.date(from: $0) }, playEpisode: e.playEpisode)
                }
                seasons = Array(Set(episodes.map(\.season))).sorted()
                if let first = seasons.first, !seasons.contains(season) { season = first }
                characters = a.characters
            }
        } else if let full: Meta = try? await HarborEngine.shared.call("cinemeta.meta", [kind, meta.id]) {
            meta = full
        }
        if !isAnimeId { buildEpisodes() }
        await loadResume()
        if isSeries, let authKey {
            let keys: [String] = (try? await HarborEngine.shared.call("player.watchedEpisodes", [authKey, meta])) ?? []
            watched = Set(keys)
        }
        await loadExtras()
        await loadEpisodeFacts()
    }

    /// use-bp-detail: TMDB lands independently of the meta; the franchise collection last.
    private func loadExtras() async {
        let p = ProfilesStore.shared.active
        let x: Extras? = try? await HarborEngine.shared.call("detailRoom.extras", [meta, p?.id ?? "default", p?.linked ?? true])
        extras = x
        if let x, !x.recommendations.isEmpty || !x.similar.isEmpty {
            await CardMarksStore.shared.refresh(x.recommendations + x.similar)
        }
        if let c = x?.collection {
            struct Col: Decodable { var name: String; var metas: [Meta] }
            let col: Col? = try? await HarborEngine.shared.call("detailRoom.collection", [c.id, p?.id ?? "default", p?.linked ?? true])
            if let col { collectionRow = BrowseRow(key: "collection", title: col.name, metas: col.metas) }
        }
    }

    func isWatched(_ ep: Episode) -> Bool { watched.contains("\(ep.season):\(ep.episode)") }

    private var authKey: String? {
        ProfilesStore.shared.active.flatMap { ProfilesStore.shared.stremioSession(for: $0.id)?.authKey }
    }

    func toggleWatchlist() async {
        guard let authKey, !watchlistBusy else { return }
        watchlistBusy = true; defer { watchlistBusy = false }
        if inWatchlist {
            _ = try? await HarborEngine.shared.callJSON("stremio.removeBookmark", [.string(authKey), .string(meta.id)])
            inWatchlist = false
        } else {
            _ = try? await HarborEngine.shared.callJSON("stremio.saveBookmark", [.string(authKey), .string(meta.id), .object(["type": .string(meta.type), "name": .string(meta.name), "poster": meta.poster.map { .string($0) } ?? .null])])
            inWatchlist = true
        }
        await CardMarksStore.shared.refreshWatchlist()
    }

    /// Cloud library entry first (Stremio), else the local resume store, like bpResumeMark.
    private func loadResume() async {
        struct Item: Decodable {
            struct State: Decodable { var timeOffset: Double?; var duration: Double?; var season: Int?; var episode: Int?; var video_id: String? }
            var state: State?
            var removed: Bool?
        }
        canWatchlist = authKey != nil
        if let authKey,
           let item: Item? = try? await HarborEngine.shared.call("stremio.libraryGetOne", [authKey, meta.id]) {
            inWatchlist = item.map { $0.removed != true } ?? false
            guard let st = item?.state, let off = st.timeOffset, off > 0 else { return await loadLocalResume() }
            var s = st.season, e = st.episode
            if (e ?? 0) == 0, let vid = st.video_id, let parsed = VideoId.seasonEpisode(vid, metaId: meta.id) { s = parsed.season; e = parsed.episode }
            resume = Resume(season: isSeries ? s : nil, episode: isSeries ? e : nil, positionMs: off, durationMs: st.duration ?? 0)
            if let s, isSeries, seasons.contains(s) { season = s }
            return
        }
        await loadLocalResume()
    }

    private func loadLocalResume() async {
        struct Local: Decodable { var ms: Double; var pct: Double? }
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
