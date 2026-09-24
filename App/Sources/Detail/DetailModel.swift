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
    @Published var season: Int = 1 { didSet { if season != oldValue { Task { await loadEpisodeFacts(); await loadEpisodeArt() } } } }
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

    /// use-bp-episode-art: per episode id, the still urls to try in order (TMDB → TVDB → ani.zip → the
    /// meta's own thumbnail → metahub). Missing until the engine answers; the cell then uses the thumbnail.
    @Published private(set) var episodeArt: [String: [String]] = [:]

    func loadEpisodeArt() async {
        guard isSeries else { return }
        struct Ref: Encodable { var key: String; var season: Int; var episode: Int; var still: String? }
        let s = season
        let refs = episodes.filter { $0.season == s }.map { Ref(key: $0.id, season: $0.season, episode: $0.episode, still: $0.thumbnail) }
        guard !refs.isEmpty else { return }
        let p = ProfilesStore.shared.active
        let art: [String: [String]]? = try? await HarborEngine.shared.call("detailRoom.episodeArt", [meta, s, refs, p?.id ?? "default", p?.linked ?? true])
        if let art { episodeArt.merge(art) { _, new in new } }
    }

    func stillChain(for ep: Episode) -> [String] {
        if let chain = episodeArt[ep.id] { return chain }
        return ep.thumbnail.map { [$0] } ?? []
    }

    // MARK: hero actions (use-bp-detail-actions.ts)

    struct HeroState: Decodable, Equatable {
        var favorite: Bool; var reminder: Bool; var watchedLocal: Bool; var traktMovie: Bool; var showWatchedButton: Bool; var rating: Int?
    }
    @Published private(set) var hero: HeroState?
    /// stremio-watched stremioMovieWatched(libraryItem): flaggedWatched or timesWatched on the Stremio entry.
    @Published private(set) var stremioWatched = false
    /// use-bp-anime-detail canonicalId: trackers file against it, never the shell the viewer arrived under.
    @Published private(set) var canonicalId: String?
    /// use-bp-trackers: Simkl, plus AniList and MyAnimeList for anime, when signed in.
    struct Tracker: Decodable, Identifiable, Equatable {
        struct Choice: Decodable, Identifiable, Equatable { var id: String; var label: String }
        var key: String; var name: String; var status: String?; var statusLabel: String?; var choices: [Choice]; var canRemove: Bool
        var id: String { key }
    }
    @Published private(set) var trackers: [Tracker] = []

    var isMovie: Bool { meta.type == "movie" }
    var imdbId: String? { meta.id.hasPrefix("tt") ? meta.id : extras?.imdbId }
    /// use-bp-detail-actions `watched`: isMovieWatchedLocal || stremioMovieWatched.
    var movieWatched: Bool { isMovie && ((hero?.watchedLocal ?? false) || stremioWatched) }
    private var trackerMeta: Meta {
        guard let c = canonicalId, c != meta.id else { return meta }
        var m = meta
        m.id = c
        return m
    }

    func loadHero() async {
        let p = ProfilesStore.shared.active
        let state: HeroState? = try? await HarborEngine.shared.call("actions.heroState", [meta, imdbId, p?.id ?? "default", p?.linked ?? true])
        if let state { hero = state }
    }

    func toggleFavorite() async {
        let p = ProfilesStore.shared.active
        let _: Bool? = try? await HarborEngine.shared.call("actions.toggleFavorite", [meta, imdbId, p?.id ?? "default"]) as Bool
        await loadHero()
    }

    func toggleReminder() async {
        let _: Bool? = try? await HarborEngine.shared.call("actions.toggleReminder", [meta]) as Bool
        await loadHero()
    }

    /// "Mark watched" / "Marked watched": markMovieWatched or unmarkMovieWatched (local, Stremio, Trakt, Simkl).
    func toggleWatched() async {
        let next = !movieWatched
        let _: Bool? = try? await HarborEngine.shared.call("actions.setMovieWatched", [meta, imdbId, next]) as Bool
        if !next { stremioWatched = false }
        await loadHero()
        await CardMarksStore.shared.remark()
    }

    func traktMarkWatched() async {
        let _: Bool? = try? await HarborEngine.shared.call("actions.traktMarkWatched", [meta.id]) as Bool
    }

    func loadTrackers() async {
        let list: [Tracker]? = try? await HarborEngine.shared.call("actions.trackers", [trackerMeta, isMovie])
        trackers = list ?? []
    }

    /// bp-status-dialog choice: the label flips at once (use-bp-trackers set), the service's answer wins.
    func setTracker(_ key: String, status: String) async {
        if let i = trackers.firstIndex(where: { $0.key == key }) {
            trackers[i].status = status
            trackers[i].statusLabel = trackers[i].choices.first(where: { $0.id == status })?.label
        }
        let t: Tracker? = try? await HarborEngine.shared.call("actions.trackerSet", [key, trackerMeta, isMovie, status])
        if let t, let i = trackers.firstIndex(where: { $0.key == key }) { trackers[i] = t }
    }

    func removeTracker(_ key: String) async {
        let t: Tracker? = try? await HarborEngine.shared.call("actions.trackerRemove", [key, trackerMeta, isMovie])
        if let t, let i = trackers.firstIndex(where: { $0.key == key }) { trackers[i] = t }
    }
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
    /// detail/bp-awards-row: award bodies with counts, and every entry behind them.
    @Published private(set) var awards: TitleAwards?
    struct TitleAwards: Decodable {
        struct Group: Decodable, Identifiable { var type: String; var title: String; var wins: Int; var nominations: Int; var id: String { type } }
        struct Entry: Decodable, Identifiable { var type: String; var awardName: String; var category: String?; var year: Int?; var result: String; var recipient: String?; var id: String { "\(type)-\(awardName)-\(category ?? "")-\(year ?? 0)-\(result)" } }
        var groups: [Group]; var entries: [Entry]
    }
    func loadAwards() async {
        awards = try? await HarborEngine.shared.call("detailRoom.awards", [meta])
    }
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
        struct Video: Decodable, Identifiable { var ytId: String; var name: String; var type: String; var id: String { ytId } }
        var videos: [Video]?
    }

    /// bp-detail: TMDB's lead trailer, else the first Cinemeta trailer stream.
    var trailerYtId: String? {
        if let t = extras?.trailerYtId, !t.isEmpty { return t }
        return meta.trailerStreams?.compactMap(\.ytId).first { !$0.isEmpty }
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
                canonicalId = a.canonicalId
            }
        } else if let full: Meta = try? await HarborEngine.shared.call("cinemeta.meta", [kind, meta.id]) {
            meta = full
        }
        if !isAnimeId { buildEpisodes() }
        await loadResume()
        await loadHero()
        if isSeries, let authKey {
            let keys: [String] = (try? await HarborEngine.shared.call("player.watchedEpisodes", [authKey, meta])) ?? []
            watched = Set(keys)
        }
        await loadEpisodeArt()
        await loadExtras()
        // The favourite check also answers to the IMDb id TMDB just resolved.
        if !meta.id.hasPrefix("tt"), extras?.imdbId != nil { await loadHero() }
        await loadEpisodeFacts()
        await loadAwards()
        await loadTrackers()
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
            struct State: Decodable { var timeOffset: Double?; var duration: Double?; var season: Int?; var episode: Int?; var video_id: String?; var flaggedWatched: Double?; var timesWatched: Double? }
            var state: State?
            var removed: Bool?
        }
        canWatchlist = authKey != nil
        if let authKey,
           let item: Item? = try? await HarborEngine.shared.call("stremio.libraryGetOne", [authKey, meta.id]) {
            inWatchlist = item.map { $0.removed != true } ?? false
            stremioWatched = isMovie && ((item?.state?.flaggedWatched ?? 0) > 0 || (item?.state?.timesWatched ?? 0) > 0)
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
            if isSeries, let s = r.season, let e = r.episode { return T("Resume S%lld:E%lld", s, e) }
            if r.positionMs > 60_000 { return T("Resume") }
        }
        if isSeries, let t = playTarget { return "Play S\(t.season) E\(t.episode)" }
        return T("Play")
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
