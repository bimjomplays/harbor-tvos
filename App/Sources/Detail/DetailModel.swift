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
    func loadAwards() async {
        awards = try? await HarborEngine.shared.call("detailRoom.awards", [meta])
    }
    struct AnimeCharacter: Decodable, Identifiable { var id: Int; var name: String; var nativeName: String?; var image: String?; var role: String? }
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
                       watchMetaId: e.sourceMetaId, tag: tag, absoluteLabel: abs)
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
                episodes = a.episodes.map { animeEpisode($0, showSeason: false) }.uniquedById()   // (bug pass)
                seasons = Array(Set(episodes.map(\.season))).sorted()
                if let first = seasons.first, !seasons.contains(season) { season = first }
                characters = a.characters
                canonicalId = a.canonicalId
                // The TVDB panel lands after the Kitsu list, like use-anime-tvdb-panel's effects; until
                // then (or when it never resolves) the strip groups by Kitsu season.
                Task { await loadAnimeSeasons() }
            }
        } else if let full: Meta = try? await HarborEngine.shared.call("cinemeta.meta", [kind, meta.id]) {
            meta = full
        }
        if !isAnimeId { buildEpisodes() }
        await loadResume()
        await loadHero()
        if isSeries {
            // Local marks at once; the library pull and Trakt/Simkl history land after.
            await loadWatchedState()
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
            // Trakt history is keyed by the IMDb id, which a TMDB-sourced series only has now (review 27).
            if isSeries {
                let _: Bool? = try? await HarborEngine.shared.call("episodeWatched.load", [authKey, meta, imdbId])
                await loadWatchedState()
            }
        }
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

    func toggleWatchlist() async {
        guard let authKey, !watchlistBusy else { return }
        watchlistBusy = true; defer { watchlistBusy = false }
        if inWatchlist {
            // watchlist.ts removal (upstream ec6a696d): every cloud form of the title goes, tt… and
            // tmdb:… alike, so a twin saved elsewhere cannot keep the card alive.
            _ = try? await HarborEngine.shared.callJSON("cards.removeFromWatchlist", [.string(authKey), .string(meta.id), imdbId.map { .string($0) } ?? .null])
            inWatchlist = false
        } else {
            _ = try? await HarborEngine.shared.callJSON("stremio.saveBookmark", [.string(authKey), .string(meta.id), .object(["type": .string(meta.type), "name": .string(meta.name), "poster": meta.poster.map { .string($0) } ?? .null])])
            inWatchlist = true
        }
        await CardMarksStore.shared.refreshWatchlist()
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
        }
        canWatchlist = authKey != nil
        guard let authKey else { return await loadLocalResume() }
        var found: Item?
        var answered = false
        for cid in libraryCandidates {
            guard let item: Item? = try? await HarborEngine.shared.call("stremio.libraryGetOne", [authKey, cid]) else { continue }
            answered = true
            if let item { found = item; break }
        }
        guard answered else { return await loadLocalResume() }
        inWatchlist = found.map { $0.removed != true } ?? false
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
        if let r = resume, let s = r.season, let e = r.episode, let ep = episodes.first(where: { $0.season == s && $0.episode == e }) { return ep }
        return seasonEpisodes.first
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
        if let r = resume, let s = r.season, let e = r.episode { return (s, e) }
        return nil
    }

    var playLabel: String {
        // A hinted episode other than the resume point plays from its start ("Play S E").
        if let r = resume, !hintElsewhere {
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
        // (bug pass) Cinemeta / addon video lists can repeat an id; the strip's ForEach needs unique ones.
        episodes = out.uniquedById()
        let all = Array(Set(out.map(\.season))).sorted()
        // Specials (season 0) go last, like upstream.
        seasons = all.filter { $0 > 0 } + all.filter { $0 == 0 }
        if let first = seasons.first, !seasons.contains(season) { season = first }
    }
}
