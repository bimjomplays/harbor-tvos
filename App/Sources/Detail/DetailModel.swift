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
        /// anime franchise entries (KitsuEpisode.sourceMetaId): the id this card's watched marks live under.
        var watchMetaId: String? = nil
        /// bp-anime-seasons.tsx BpAnimeEpisodeCard tag: "S{s} E{e}" when the strip spans seasons.
        var tag: String? = nil
        /// bp-anime-seasons.tsx facts: "Abs E{n}" when the absolute number is not the episode number.
        var absoluteLabel: String? = nil
        /// bp-anime-seasons.tsx BpAnimeEpisodeCard: a filler episode wears the "Filler" pill.
        var filler: Bool = false
    }

    @Published private(set) var meta: Meta
    @Published private(set) var episodes: [Episode] = []
    @Published private(set) var seasons: [Int] = []
    @Published var season: Int = 1 { didSet { if season != oldValue { Task { await loadWatchedState(); await loadEpisodeFacts(); await loadEpisodeArt() } } } }
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
        let refs = seasonEpisodes.map { Ref(key: $0.id, season: $0.season, episode: $0.episode, still: $0.thumbnail) }
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
        /// (detail pass) useInWatchlist(meta.id, [imdbId]): Harbor's own watchlist or the synced aggregate.
        var watchlist: Bool?
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
        // (detail pass) A failed reload keeps the tracker cells (one could hold the ring).
        if let list { trackers = list }
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
    /// "Add to Watchlist" / "In Watchlist" (use-bp-detail-actions useInWatchlist): Harbor's own
    /// watchlist or the synced aggregate (heroState), or the title's Stremio library entry while the
    /// aggregate has not caught up with it. (detail pass) It was the Stremio entry alone, so the
    /// action was missing without a Stremio account and never reached Trakt, Simkl or the Library
    /// room's own watchlist.
    var inWatchlist: Bool { (hero?.watchlist ?? false) || (libraryBookmarked && !watchlistCleared) }
    @Published private(set) var watchlistBusy = false
    /// The Stremio library entry under the page's ids (not removed, not temp).
    @Published private(set) var libraryBookmarked = false
    /// The viewer took the title off the watchlist on this page: a library entry read before the
    /// removal reached Stremio no longer counts.
    @Published private(set) var watchlistCleared = false
    /// use-bp-episode-strip watchedOf: "season:episode" keys that read watched (Harbor's manual marks,
    /// the Stremio library bitfield, Trakt/Simkl history; a manual unmark wins). engine/episodeWatched.ts.
    @Published private(set) var watched: Set<String> = []
    /// episode-watched-menu `started`: unwatched episodes of this season with a local resume entry.
    @Published private(set) var started: Set<String> = []
    /// lib/spoilers.ts spoilerMaskFor per card of this season (absent = nothing hidden).
    struct SpoilerMask: Decodable, Equatable { var thumb: Bool; var title: Bool; var desc: Bool }
    @Published private(set) var spoilerMasks: [String: SpoilerMask] = [:]
    /// bp-episode-card.tsx: settings.showEpisodeRating / showEpisodeDescription.
    @Published private(set) var showEpisodeRating = true
    @Published private(set) var showEpisodeDescription = true
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
    /// hooks/use-title-media-servers.ts: the connected home servers whose index holds this title
    /// (detail/bp-hero-notes.tsx BpHeroMarks "Available in {name}").
    struct TitleServer: Decodable, Identifiable, Equatable { var id: String; var name: String; var provider: String; var providerName: String }
    @Published private(set) var titleServers: [TitleServer] = []
    func loadTitleServers() async {
        let list: [TitleServer]? = try? await HarborEngine.shared.call("homeServers.titleServers", [meta.id, imdbId])
        // A failed read keeps the marks already drawn (the page reloads under every cover).
        if let list, list != titleServers { titleServers = list }
    }

    func loadAwards() async {
        // (detail pass) A failed reload keeps the row on screen (see loadExtras).
        if let a: TitleAwards = try? await HarborEngine.shared.call("detailRoom.awards", [meta]) { awards = a }
    }
    struct AnimeCharacter: Decodable, Identifiable { var id: Int; var name: String; var nativeName: String?; var image: String?; var role: String?; var favourites: Int? }

    /// (parity pass 3, D4) lib/character-favorites: the ids this profile favourited (bp-anime-characters
    /// `has(String(c.id))`), read with the characters and flipped on Select.
    @Published private(set) var favoriteCharacters: Set<String> = []

    func loadFavoriteCharacters() async {
        let pid: String = ProfilesStore.shared.active?.id ?? "default"
        if let ids: [String] = try? await HarborEngine.shared.call("characterFavorites.ids", [pid]) { favoriteCharacters = Set(ids) }
    }

    /// bp-anime-characters onToggle: toggle({ id: String(c.id), name: c.name, image: c.image }). The
    /// heart flips at once; the store's answer settles it.
    func toggleCharacter(_ c: AnimeCharacter) async {
        let id = String(c.id)
        let wasOn: Bool = favoriteCharacters.contains(id)
        if wasOn { favoriteCharacters.remove(id) } else { favoriteCharacters.insert(id) }
        let pid: String = ProfilesStore.shared.active?.id ?? "default"
        var input: [String: AnyJSON] = ["id": .string(id), "name": .string(c.name)]
        if let image = c.image { input["image"] = .string(image) }
        let args: [AnyJSON] = [.string(pid), .object(input)]
        guard let on = (try? await HarborEngine.shared.callJSON("characterFavorites.toggle", args))?.bool else {
            if wasOn { favoriteCharacters.insert(id) } else { favoriteCharacters.remove(id) }
            return
        }
        if on { favoriteCharacters.insert(id) } else { favoriteCharacters.remove(id) }
    }
    private struct AnimeDetail: Decodable {
        struct D: Decodable { var name: String?; var overview: String?; var backdrop: String?; var poster: String?; var year: String?; var genres: [String] }
        struct Ep: Decodable {
            var id: Int; var season: Int; var number: Int; var title: String; var synopsis: String; var thumbnail: String?; var airdate: String?; var length: Int?; var filler: Bool
            var absoluteNumber: Int?; var imdbSeason: Int?; var imdbEpisode: Int?; var playEpisode: AnyJSON; var sourceMetaId: String?
        }
        var canonicalId: String; var imdbId: String?; var detail: D; var episodes: [Ep]; var showSeason: Bool; var characters: [AnimeCharacter]
    }
    var isAnimeId: Bool { ["kitsu:", "mal:", "anilist:", "anidb:"].contains { meta.id.hasPrefix($0) } }

    // MARK: anime named seasons and episode orders (bp-anime-seasons.tsx, engine/animeSeasons.ts)

    /// bp-anime-season-chip.tsx: a named season, its year span and episode count ("2020-2021 · 12 episodes").
    struct AnimeSeasonChip: Decodable, Equatable, Identifiable {
        var key: String; var name: String; var count: Int; var years: String; var meta: String; var extra: Bool; var badge: String?
        /// BpChipDivider before the first special / extra that follows a regular season.
        var divider: Bool
        var id: String { key }
    }
    /// The TVDB order types of the panel (Aired, Absolute, TVDB Absolute, DVD …), short labels as upstream draws them.
    struct AnimeOrderChip: Decodable, Equatable, Identifiable {
        var value: String; var label: String; var short: String
        var id: String { value }
    }
    private struct AnimeSeasonsWire: Decodable {
        struct Group: Decodable { var key: String; var showSeason: Bool; var episodes: [AnimeDetail.Ep] }
        var source: String; var seasons: [AnimeSeasonChip]; var seasonKey: String; var orderTypes: [AnimeOrderChip]; var orderType: String; var hasChips: Bool; var groups: [Group]
    }
    @Published private(set) var animeChips: [AnimeSeasonChip] = []
    @Published private(set) var animeOrders: [AnimeOrderChip] = []
    @Published private(set) var animeOrderType = "aired"
    /// bp-anime-seasons.tsx hasSeasonChips: more than one season or more than one order.
    @Published private(set) var animeHasChips = false
    /// The chip on screen; nil while the TVDB order has not resolved (the strip then groups by Kitsu season).
    @Published private(set) var animeSeasonKey: String?
    @Published private(set) var animeGroups: [String: [Episode]] = [:]
    /// use-anime-tvdb-panel `touched` + `sel`: the viewer's pick survives an order change while it exists.
    private var animeSeasonPicked: String?
    /// use-bp-anime-detail episodeHint: the season the viewer arrived for (a Watch Together room episode).
    var episodeHintSeason: Int?
    /// views/detail.tsx lastPlay: an episodeHint (an AI search episode pick) comes before any resume point.
    var episodeHint: (season: Int, episode: Int)?

    private func animeEpisode(_ e: AnimeDetail.Ep, showSeason: Bool) -> Episode {
        let released = e.airdate.flatMap { ISO8601DateFormatter.dateOnly.date(from: $0) }
        var tag: String?
        if showSeason, let s = e.imdbSeason, let n = e.imdbEpisode { tag = T("S%lld E%lld", s, n) }
        var abs: String?
        if let a = e.absoluteNumber, a != e.number { abs = T("Abs E%lld", a) }
        // Keyed by the Kitsu / TVDB episode id: a TVDB-only card can share a season:episode pair with a Kitsu one.
        return Episode(id: "\(meta.id):k\(e.id)", season: e.season, episode: e.number, title: e.title.isEmpty ? T("Episode %lld", e.number) : e.title,
                       overview: e.synopsis.isEmpty ? nil : e.synopsis, thumbnail: e.thumbnail, released: released, playEpisode: e.playEpisode,
                       watchMetaId: e.sourceMetaId, tag: tag, absoluteLabel: abs, filler: e.filler)
    }

    /// use-bp-anime-detail seasons / orderTypes: asked once the Kitsu episodes are in, again on every order change.
    func loadAnimeSeasons() async {
        guard isAnimeId, !episodes.isEmpty else { return }
        animeSeasonsGen += 1
        let gen = animeSeasonsGen
        let p = ProfilesStore.shared.active
        // A Kitsu season button the viewer pressed before the chips arrived seeds the pick (TVDB keys
        // seasons by number, "0" for Specials), so the chips open where the viewer already was.
        let picked = animeSeasonPicked ?? kitsuSeasonPicked.map { String($0) }
        // The page's meta rides along: a page evicted from the engine's 8-page cache reloads (review 31).
        guard let w: AnimeSeasonsWire = try? await HarborEngine.shared.call("animeDetail.seasons", [meta.id, p?.id ?? "default", p?.linked ?? true, picked, episodeHintSeason, meta]) else { return }
        // A newer order toggle's reply wins; an empty one leaves the current order on screen (review 31).
        guard gen == animeSeasonsGen, w.source != "none", !w.groups.isEmpty else { return }
        var groups: [String: [Episode]] = [:]
        for g in w.groups { groups[g.key] = g.episodes.map { animeEpisode($0, showSeason: g.showSeason) }.uniquedById() }   // (bug pass)
        animeGroups = groups
        animeChips = w.seasons
        if !w.orderTypes.isEmpty { animeOrders = w.orderTypes }
        animeOrderType = w.orderType
        animeHasChips = w.hasChips
        // A Kitsu season pressed while this request was out wins over the engine's default (review 35).
        let seeded = animeSeasonPicked ?? kitsuSeasonPicked.map { String($0) }
        animeSeasonKey = seeded.flatMap { groups[$0] != nil ? $0 : nil } ?? (groups[w.seasonKey] != nil ? w.seasonKey : w.groups.first?.key)
        await loadWatchedState()
        await loadEpisodeArt()
    }

    /// A Kitsu season button pressed before the TVDB chips arrived.
    private var kitsuSeasonPicked: Int?

    /// The Kitsu season buttons (before or without TVDB chips): the pick is remembered for the chips.
    func pickKitsuSeason(_ s: Int) {
        if animeSeasonKey == nil, isAnimeId { kitsuSeasonPicked = s }
        season = s
    }

    /// BpAnimeSeasonChip onSelect.
    func selectAnimeSeason(_ key: String) {
        guard animeGroups[key] != nil, key != animeSeasonKey else { return }
        animeSeasonPicked = key
        animeSeasonKey = key
        Task { await loadWatchedState(); await loadEpisodeArt() }
    }

    /// use-bp-anime-detail onOrderType: settings.tvdbSeasonType, then the seasons of that order.
    /// The chip shows the order the engine answers with (review 31: not set ahead of the reload).
    func setAnimeOrder(_ value: String) async {
        guard value != animeOrderType else { return }
        try? await SettingsBridge.shared.patch(["tvdbSeasonType": .string(value)])
        await loadAnimeSeasons()
    }
    @Published private(set) var collectionRow: BrowseRow?
    private var animeSeasonsGen = 0

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
        var cast: [Cast]; var crew: [Crew]; @LossyArray var recommendations: [Meta]; @LossyArray var similar: [Meta]   // (bug pass 2) lossy
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
    /// The strip: the anime season chip's episodes when the TVDB order resolved, else this season's.
    var seasonEpisodes: [Episode] {
        if let k = animeSeasonKey, let g = animeGroups[k] { return g }
        return episodes.filter { $0.season == season }
    }

    /// How far `load()` has got, for a one-press play (bp-detail's pending-play effect fires as soon
    /// as the page has its meta and knows the episode, not after the rest of the page). It only
    /// moves forward: a reload after a cover closes starts from the top, the stage stays put.
    enum LoadStage: Int, Comparable {
        /// Nothing yet.
        case none
        /// The full meta and (for a series) its episode list are in, or the fetch failed.
        case meta
        /// The Stremio library / local resume point under the page's own ids has been read.
        case resume
        /// The resume point under the IMDb id TMDB resolved has been read too (non-tt pages).
        case library
        static func < (a: LoadStage, b: LoadStage) -> Bool { a.rawValue < b.rawValue }
    }
    @Published private(set) var loadStage: LoadStage = .none
    /// (detail/search pass 2) The last load could not read the full meta (offline, catalog down).
    /// A series then has no episodes: the page says so with Try again (bp-detail's "Couldn't load
    /// this title." page), where it showed an empty strip and nothing else.
    @Published private(set) var metaFailed = false

    /// bp-detail play(): "A series with no resolvable episode still must not ask addons for
    /// series-level streams, so it falls back to the premiere" (bpEpisodeAt(1, 1)). (detail/search
    /// pass 2) Play on a series whose episodes never loaded opened the picker with no episode.
    var premiereEpisode: AnyJSON {
        var ep: [String: AnyJSON] = ["season": .number(1), "episode": .number(1)]
        if meta.id.hasPrefix("tt") {
            ep["imdbId"] = .string(meta.id)
            ep["imdbSeason"] = .number(1)
            ep["imdbEpisode"] = .number(1)
        }
        return .object(ep)
    }
    private func reach(_ stage: LoadStage) { if loadStage < stage { loadStage = stage } }

    /// An episodeHint that names an episode on this page (a Continue Watching resume, an AI pick).
    var hintOnPage: Bool {
        guard let h = episodeHint else { return false }
        return episodes.contains { $0.season == h.season && $0.episode == h.episode }
    }

    /// Whether Play already knows what it would start, so an autoPlay page can open the picker now
    /// (bp-detail: a caller that named the episode has nothing to wait for). A movie needs only its
    /// meta (the player reads its own resume point); a series needs its episode: the hint or the
    /// room's episode names it at once, else the resume point decides, and a page without an IMDb
    /// id only has every library candidate once TMDB resolved one (use-bp-library-item). Firing
    /// before the resume point is known restarts a series at its premiere (bp-play-request.ts).
    func knowsPlayTarget(roomEpisode: Bool) -> Bool {
        switch loadStage {
        case .none: return false
        case .meta: return !isSeries || roomEpisode || hintOnPage
        case .resume: return !isSeries || roomEpisode || hintOnPage || imdbId != nil || isAnimeId
        case .library: return true
        }
    }

    func load() async {
        guard !loading else { return }
        loading = true
        // However it ended, a finished load is all Play will get.
        defer { loading = false; reach(.library) }
        let kind = isSeries ? "series" : "movie"
        var fetched = false
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
                fetched = true
                episodes = a.episodes.map { animeEpisode($0, showSeason: false) }.uniquedById()   // (bug pass)
                seasons = Array(Set(episodes.map(\.season))).sorted()
                if let first = seasons.first, !seasons.contains(season) { season = first }
                characters = a.characters
                if !a.characters.isEmpty { await loadFavoriteCharacters() }
                canonicalId = a.canonicalId
                // The TVDB panel lands after the Kitsu list, like use-anime-tvdb-panel's effects; until
                // then (or when it never resolves) the strip groups by Kitsu season.
                Task { await loadAnimeSeasons() }
            }
        } else if let full: Meta = try? await HarborEngine.shared.call("cinemeta.meta", [kind, meta.id]) {
            // The addon that served the title (bp-hero-notes' mark) comes with the meta that opened
            // the page; Cinemeta's record never carries one.
            var merged = full
            if merged.addonOrigin == nil { merged.addonOrigin = meta.addonOrigin }
            meta = merged
            fetched = true
        }
        metaFailed = !fetched
        if !isAnimeId { buildEpisodes() }
        reach(.meta)
        await loadResume()
        // Local marks at once (an anime's Play follows its next-up, so they come before Play can
        // fire); the library pull and Trakt/Simkl history land after.
        if isSeries { await loadWatchedState() }
        reach(.resume)
        await loadHero()
        if isSeries {
            let _: Bool? = try? await HarborEngine.shared.call("episodeWatched.load", [authKey, meta, imdbId])
            await loadWatchedState()
        }
        await loadEpisodeArt()
        await loadExtras()
        // The favourite check also answers to the IMDb id TMDB just resolved.
        if !meta.id.hasPrefix("tt"), extras?.imdbId != nil {
            await loadHero()
            // use-bp-library-item: the library entry may sit under that IMDb id (resume, watchlist).
            await loadResume()
            reach(.library)
            // Trakt history is keyed by the IMDb id, which a TMDB-sourced series only has now (review 27).
            if isSeries {
                let _: Bool? = try? await HarborEngine.shared.call("episodeWatched.load", [authKey, meta, imdbId])
                await loadWatchedState()
            }
        }
        // Episode facts, awards and trackers never change what Play starts.
        reach(.library)
        await loadEpisodeFacts()
        await loadAwards()
        await loadTrackers()
        await loadTitleServers()
    }

    /// use-bp-detail: TMDB lands independently of the meta; the franchise collection last.
    private func loadExtras() async {
        let p = ProfilesStore.shared.active
        let x: Extras? = try? await HarborEngine.shared.call("detailRoom.extras", [meta, p?.id ?? "default", p?.linked ?? true])
        // (detail pass) The page reloads every time a cover over it closes: a TMDB miss on a reload
        // (offline, or the 10-minute cache running out mid-visit) no longer takes the cast,
        // recommendations and facts rows away from under the viewer's focus.
        if let x { extras = x }
        if let x, !x.recommendations.isEmpty || !x.similar.isEmpty {
            await CardMarksStore.shared.refresh(x.recommendations + x.similar)
        }
        if let c = x?.collection {
            struct Col: Decodable { var name: String; @LossyArray var metas: [Meta] }
            let col: Col? = try? await HarborEngine.shared.call("detailRoom.collection", [c.id, p?.id ?? "default", p?.linked ?? true])
            if let col { collectionRow = BrowseRow(key: "collection", title: col.name, metas: col.metas) }
        }
    }

    func isWatched(_ ep: Episode) -> Bool { watched.contains("\(ep.season):\(ep.episode)") }
    func isStarted(_ ep: Episode) -> Bool { started.contains("\(ep.season):\(ep.episode)") }
    func spoilerMask(for ep: Episode) -> SpoilerMask? { spoilerMasks["\(ep.season):\(ep.episode)"] }

    // MARK: episode watched marks (episode-watched-menu.tsx, use-mark-season.ts)

    private struct EpisodeRef: Encodable { var season: Int; var episode: Int; var metaId: String?; var released: String? }
    private var episodeRefs: [EpisodeRef] {
        let iso = ISO8601DateFormatter()
        // The anime chips can hold TVDB-only episodes the Kitsu list lacks; their marks count too.
        var seen = Set<String>()
        var all: [Episode] = []
        for e in episodes + animeGroups.values.flatMap({ $0 }) where seen.insert("\(e.watchMetaId ?? "")|\(e.season):\(e.episode)").inserted { all.append(e) }
        return all.map { EpisodeRef(season: $0.season, episode: $0.episode, metaId: $0.watchMetaId, released: $0.released.map { iso.string(from: $0) }) }
    }
    /// The strip's cards as refs (anime-episodes.tsx displayEpisodes).
    private var shownRefs: [EpisodeRef] {
        let iso = ISO8601DateFormatter()
        return seasonEpisodes.map { EpisodeRef(season: $0.season, episode: $0.episode, metaId: $0.watchMetaId, released: $0.released.map { iso.string(from: $0) }) }
    }

    /// engine/episodeWatched.ts state: the whole title's refs, this season's started keys and masks.
    func loadWatchedState() async {
        guard isSeries, !episodes.isEmpty else { return }
        struct WatchedState: Decodable {
            var watched: [String]; var started: [String]; var masks: [String: SpoilerMask]
            var showEpisodeRating: Bool; var showEpisodeDescription: Bool
            var nextUp: String?
        }
        let p = ProfilesStore.shared.active
        // An anime chip of the TVDB order mixes Kitsu seasons: started / next-up / masks follow the strip itself.
        let chip = animeSeasonKey
        let asked = season
        let shown: [String]? = chip == nil ? nil : seasonEpisodes.map { "\($0.season):\($0.episode)" }
        guard let s: WatchedState = try? await HarborEngine.shared.call("episodeWatched.state", [meta.id, episodeRefs, asked, p?.id ?? "default", p?.linked ?? true, shown]) else { return }
        // A chip change (or the TVDB order landing) started its own read; this one is stale.
        // (bug pass) So is a read for a season the viewer already left: started / masks are per season.
        guard chip == animeSeasonKey, asked == season else { return }
        watched = Set(s.watched)
        started = Set(s.started)
        spoilerMasks = s.masks
        showEpisodeRating = s.showEpisodeRating
        showEpisodeDescription = s.showEpisodeDescription
        nextUpKey = s.nextUp
    }

    /// episodeWatched.state nextUp: the first unwatched card of the strip ("season:episode").
    @Published private(set) var nextUpKey: String?

    /// use-bp-anime-detail resume: an anime page plays the strip's next-up episode once any card of
    /// the strip reads watched ("Resume S:E"), whatever the local resume entry says. (detail pass)
    /// The port only followed the local resume point, which a finished episode clears, so after
    /// watching episodes 1-5 Play said "Play S1 E1" again. Nil when a caller's hint names an episode.
    var animeNextUp: Episode? {
        guard isAnimeId, !hintOnPage, let k = nextUpKey else { return nil }
        let strip = seasonEpisodes
        guard strip.contains(where: { isWatched($0) }) else { return nil }
        return strip.first { "\($0.season):\($0.episode)" == k }
    }

    /// use-bp-episode-strip progressOf: the resume episode's card carries its progress bar.
    func progress(for ep: Episode) -> Double {
        guard let r = resume, r.season == ep.season, r.episode == ep.episode else { return 0 }
        return r.progress
    }

    enum WatchedMark: String { case episode, upTo, season }

    /// episode-grid-controls OptionsMenu allWatched: every aired episode of this season reads watched.
    var seasonAllWatched: Bool {
        let now = Date()
        let aired = seasonEpisodes.filter { ($0.released ?? .distantPast) <= now }
        return !aired.isEmpty && aired.allSatisfy { isWatched($0) }
    }

    /// The manual store is written before the engine answers; Simkl, AniList/MAL and the Stremio
    /// library follow in the background (engine/episodeWatched.ts mark).
    func markWatched(_ ep: Episode, _ scope: WatchedMark, watched on: Bool) async {
        let p = ProfilesStore.shared.active
        let target = EpisodeRef(season: ep.season, episode: ep.episode, metaId: ep.watchMetaId, released: nil)
        // anime-episodes.tsx markSeason = markMany(displayEpisodes): the chip on screen, not the Kitsu season.
        let chip = scope == .season && animeSeasonKey != nil
        let _: Bool? = try? await HarborEngine.shared.call("episodeWatched.mark", [authKey, meta, imdbId, target, chip ? "shown" : scope.rawValue, on, chip ? shownRefs : episodeRefs, p?.id ?? "default", p?.linked ?? true])
        await loadWatchedState()
    }

    /// views/player.tsx nextEpMask (watched = the next episode's mark, isNextUp): bp-up-next.tsx
    /// shows the episode label alone when the title is masked. The TV card draws no still.
    func upNextText(_ n: Episode) async -> String {
        let p = ProfilesStore.shared.active
        let mask: SpoilerMask? = try? await HarborEngine.shared.call("episodeWatched.upNextMask", [p?.id ?? "default", p?.linked ?? true, isWatched(n)])
        let label = "S\(n.season) E\(n.episode)"
        return mask?.title == true ? label : "\(label) · \(n.title)"
    }

    private var authKey: String? {
        ProfilesStore.shared.active.flatMap { ProfilesStore.shared.stremioSession(for: $0.id)?.authKey }
    }

    /// use-bp-detail-actions watchlist: toggleWatchlist({ ...seed, imdbId }) (engine actions.setWatchlist):
    /// Harbor's own watchlist at once, then Trakt, Simkl and the Stremio library (every cloud form of
    /// the title on removal, watchlist.ts ec6a696d) in the background.
    func toggleWatchlist() async {
        guard !watchlistBusy else { return }
        watchlistBusy = true; defer { watchlistBusy = false }
        let on = !inWatchlist
        let _: Bool? = try? await HarborEngine.shared.call("actions.setWatchlist", [authKey, meta, imdbId, on])
        watchlistCleared = !on
        await loadHero()
        // The cloud writes are still running: re-mark from the local answer, not a library re-read.
        await CardMarksStore.shared.remark()
    }

    /// The resume point whose season the strip was last moved to. The page reloads every time a
    /// cover over it closes (a trailer, a dialog, the cast page), and re-applying the same point
    /// each time threw away the season the viewer had picked.
    private var resumeSeasonApplied: String?

    /// The strip opens on the resume point's season once per resume point (use-bp-episode-strip
    /// defaultSeason follows resumeAt only while it has progress; the viewer's pick wins after).
    private func applyResumeSeason() {
        guard isSeries, let r = resume, r.positionMs > 0, let s = r.season, seasons.contains(s) else { return }
        let key = "\(s):\(r.episode ?? 0)"
        guard key != resumeSeasonApplied else { return }
        resumeSeasonApplied = key
        season = s
    }

    /// use-bp-library-item.ts: the ids the Stremio library entry may sit under, in upstream's order
    /// (a tt id, the IMDb id TMDB resolved, then a cloud-writable non-tt id). A tmdb:… page whose
    /// title the viewer watched under its tt id found nothing (no Resume, no "In Watchlist").
    private var libraryCandidates: [String] {
        guard !meta.id.hasPrefix("simkl:") else { return [] }
        var out: [String] = []
        if meta.id.hasPrefix("tt") { out.append(meta.id) }
        if let i = imdbId, i.hasPrefix("tt"), !out.contains(i) { out.append(i) }
        let cloudOk = ["kitsu:", "mal:", "anilist:", "anidb:", "tmdb:"].contains { meta.id.hasPrefix($0) }
        if !meta.id.hasPrefix("tt"), cloudOk { out.append(meta.id) }
        // Any other id last: "Add to Watchlist" (stremio.saveBookmark) files the page under it.
        if !out.contains(meta.id) { out.append(meta.id) }
        return out
    }

    /// Cloud library entry first (Stremio), else the local resume store, like bpResumeMark.
    private func loadResume() async {
        struct Item: Decodable {
            struct State: Decodable { var timeOffset: Double?; var duration: Double?; var season: Int?; var episode: Int?; var video_id: String?; var flaggedWatched: Double?; var timesWatched: Double? }
            var state: State?
            var removed: Bool?
            var temp: Bool?
        }
        guard let authKey else { return await loadLocalResume() }
        var found: Item?
        var answered = false
        for cid in libraryCandidates {
            guard let item: Item? = try? await HarborEngine.shared.call("stremio.libraryGetOne", [authKey, cid]) else { continue }
            answered = true
            if let item { found = item; break }
        }
        guard answered else { return await loadLocalResume() }
        // watchlist-sync refreshWatchlistAggregates: the library minus removed / temp entries.
        libraryBookmarked = found.map { $0.removed != true && $0.temp != true } ?? false
        stremioWatched = isMovie && ((found?.state?.flaggedWatched ?? 0) > 0 || (found?.state?.timesWatched ?? 0) > 0)
        guard let st = found?.state else { return await loadLocalResume() }
        let off = st.timeOffset ?? 0
        var s = st.season, e = st.episode
        if (e ?? 0) == 0, let vid = st.video_id, let parsed = VideoId.seasonEpisode(vid, metaId: meta.id) { s = parsed.season; e = parsed.episode }
        if isSeries, !isAnimeId {
            // bp-resume-mark.ts: the entry's episode is the Play target when it is on this page,
            // with or without a position (a finished episode resumes there too); one that is not
            // on the page is no resume point at all (it labelled "Resume S3:E4" over a Play that
            // started the season's first episode).
            guard let es = s, let ee = e, ee > 0, episodes.contains(where: { $0.season == es && $0.episode == ee }) else { return await loadLocalResume() }
            resume = Resume(season: es, episode: ee, positionMs: off, durationMs: st.duration ?? 0)
        } else {
            guard off > 0 else { return await loadLocalResume() }
            resume = Resume(season: isSeries ? s : nil, episode: isSeries ? e : nil, positionMs: off, durationMs: st.duration ?? 0)
        }
        applyResumeSeason()
    }

    private func loadLocalResume() async {
        struct Local: Decodable { var ms: Double; var pct: Double? }
        // Built aside and assigned once: nothing found clears a point left from an earlier load of
        // this page (it reloads after every cover), without the label flickering meanwhile.
        var next: Resume?
        if !isSeries, let local: Local? = try? await HarborEngine.shared.call("player.localResume", [meta.id, AnyJSON.null, AnyJSON.null]), let l = local {
            next = Resume(season: nil, episode: nil, positionMs: l.ms, durationMs: l.pct.map { $0 > 0 ? l.ms / $0 : 0 } ?? 0)
        } else if isSeries {
            // (bug pass 2) One engine read for every local entry of the title (newest first), not one
            // bridge call per episode (~1000 for a long anime). The newest entry on this page wins,
            // as upstream's lastPlayedEpisode picks by time (views/detail.tsx lastPlay).
            struct EpisodeResume: Decodable { var season: Int; var episode: Int; var ms: Double; var t: Double; var pct: Double? }
            let loaded: LossyArray<EpisodeResume>? = try? await HarborEngine.shared.call("player.localResumes", [meta.id])
            var byKey: [String: Episode] = [:]
            for ep in episodes where byKey["\(ep.season):\(ep.episode)"] == nil { byKey["\(ep.season):\(ep.episode)"] = ep }
            var best: (Episode, Local)?
            for r in loaded?.wrappedValue ?? [] where r.ms > 0 {
                if let ep = byKey["\(r.season):\(r.episode)"] { best = (ep, Local(ms: r.ms, pct: r.pct)); break }
            }
            if let (ep, l) = best {
                next = Resume(season: ep.season, episode: ep.episode, positionMs: l.ms, durationMs: l.pct.map { $0 > 0 ? l.ms / $0 : 0 } ?? 0)
            }
        }
        resume = next
        applyResumeSeason()
    }

    /// The episode Play should start with: the resume target, else the first of the current season.
    var playTarget: Episode? {
        if let h = episodeHint, let ep = episodes.first(where: { $0.season == h.season && $0.episode == h.episode }) { return ep }
        if let n = animeNextUp { return n }
        if let r = resume, let s = r.season, let e = r.episode, let ep = episodes.first(where: { $0.season == s && $0.episode == e }) { return ep }
        return seasonEpisodes.first
    }

    /// The hero's progress bar belongs to the resume point only while Play starts it.
    var resumeIsPlayTarget: Bool {
        guard let r = resume, !hintElsewhere else { return false }
        guard isSeries, let s = r.season, let e = r.episode else { return true }
        return playTarget.map { $0.season == s && $0.episode == e } ?? false
    }

    /// views/player.tsx airedNext: the episode after this one when it has aired
    /// (isNextAired(false, airDate): no date counts as aired). Specials never follow. An unaired
    /// next episode used to get the up-next card and an auto-advance into a picker with no streams.
    func airedNext(season s: Int, episode e: Int) -> Episode? {
        guard let idx = episodes.firstIndex(where: { $0.season == s && $0.episode == e }), idx + 1 < episodes.count else { return nil }
        let next = episodes[idx + 1]
        guard next.season > 0, (next.released ?? .distantPast) <= Date() else { return nil }
        return next
    }

    /// An episodeHint that names an episode on the page other than the resume point: Play starts it
    /// from the beginning, so the resume label and progress bar stand down (review 34).
    var hintElsewhere: Bool {
        episodeHint.map { h in
            episodes.contains { $0.season == h.season && $0.episode == h.episode } && (resume?.season != h.season || resume?.episode != h.episode)
        } ?? false
    }

    /// The episode the strip lands on when it first shows: the hinted episode when it is on the page,
    /// else the resume point (use-bp-episode-strip initial focus follows views/detail.tsx lastPlay).
    var stripTarget: (season: Int, episode: Int)? {
        if let h = episodeHint, episodes.contains(where: { $0.season == h.season && $0.episode == h.episode }) { return h }
        if let n = animeNextUp { return (n.season, n.episode) }
        if let r = resume, let s = r.season, let e = r.episode { return (s, e) }
        return nil
    }

    var playLabel: String {
        if let n = animeNextUp { return T("Resume S%lld:E%lld", n.season, n.episode) }
        // A hinted episode other than the resume point plays from its start ("Play S E").
        if let r = resume, !hintElsewhere {
            if isSeries, let s = r.season, let e = r.episode { return T("Resume S%lld:E%lld", s, e) }
            if r.positionMs > 60_000 { return T("Resume") }
        }
        if isSeries, let t = playTarget { return "\(T("Play")) S\(t.season) E\(t.episode)" }
        return T("Play")
    }

    private func buildEpisodes() {
        guard isSeries, let videos = meta.videos else { return }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        // (perf pass) One fallback formatter for the whole list, not a new one per episode whose date
        // has no fractional seconds (a long anime built a thousand of them on the main thread).
        let isoPlain = ISO8601DateFormatter()
        var out: [Episode] = []
        for v in videos {
            guard let s = v["season"]?.number, let e = (v["episode"] ?? v["number"])?.number else { continue }
            let id = v["id"]?.string ?? "\(meta.id):\(Int(s)):\(Int(e))"
            let title = v["name"]?.string ?? v["title"]?.string ?? T("Episode %lld", Int(e))
            let rel = (v["released"] ?? v["firstAired"])?.string
            let date = rel.flatMap { iso.date(from: $0) ?? isoPlain.date(from: $0) }
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
        // (bug pass) Cinemeta / addon video lists can repeat an id; the strip's ForEach needs unique ones.
        episodes = out.uniquedById()
        let all = Array(Set(out.map(\.season))).sorted()
        // Specials (season 0) go last, like upstream.
        seasons = all.filter { $0 > 0 } + all.filter { $0 == 0 }
        if let first = seasons.first, !seasons.contains(season) { season = first }
    }
}
