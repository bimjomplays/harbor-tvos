import Foundation

/// Rooms built by upstream's own row logic running in the engine (engine/rooms.ts).
struct EngineBrowseSource: BrowseSource {
    struct RoomBuild: Decodable {
        struct Row: Decodable {
            var key: String
            var type: String
            var name: String
            @LossyArray var metas: [Meta]
            var hasMore: Bool
            var shape: String
        }
        @LossyArray var rows: [Row]
        @LossyArray var hero: [Meta]
        var failed: Bool
    }

    /// Upstream `LibraryItem`, only what the Continue Watching card needs.
    struct LibraryItem: Decodable {
        struct State: Decodable {
            var timeOffset: Double?
            var duration: Double?
            var season: Int?
            var episode: Int?
            var video_id: String?
            var lastWatched: String?
        }
        /// `anime`: lib/stremio isAnimeCwItem (engine rooms.cwExtras), which bp-cw-row's one-press resume skips.
        struct CwExtras: Decodable { var watched: Bool; var newEpisode: Int; var upNext: Bool; var waitingForAir: Bool; var nextAirDate: String?; var watcher: String?; var external: String?; var anime: Bool? }
        var _cw: CwExtras?
        var _id: String
        var type: String
        var name: String
        var poster: String?
        var background: String?
        var state: State?
        var _mtime: String?
    }

    @MainActor private var profile: (id: String, linked: Bool, authKey: String?) {
        let p = ProfilesStore.shared.active
        let id = p?.id ?? "default"
        let authKey = p.flatMap { ProfilesStore.shared.stremioSession(for: $0.id)?.authKey }
        return (id, p?.linked ?? true, authKey)
    }

    /// bp-home "Your addons": one brand card per installed addon; Select opens its catalogs.
    private func addonsBand(_ authKey: String?) async -> BrowseRow? {
        struct Card: Decodable { var key: String; var name: String; var base: String; var logo: String?; var hasCatalogs: Bool; @LossyArray var posters: [String] }
        let cardsLossy: LossyArray<Card>? = try? await HarborEngine.shared.call("addonsRoom.cards", [authKey, true])   // (bug pass 2) lossy
        let cards = cardsLossy?.wrappedValue ?? []
        guard !cards.isEmpty else { return nil }
        let metas = cards.map { c in
            Meta(id: "addon:\(c.base)", type: "addon", name: c.name, poster: c.posters.first, background: nil, logo: nil, description: nil, releaseInfo: nil, releaseDate: nil,
                 inTheaters: nil, imdbRating: nil, tmdbScore: nil, runtime: nil, genres: nil, adult: nil, isCollection: nil,
                 providerBadge: Meta.ProviderBadge(name: c.name, logo: c.logo ?? "", tint: "#2a2b2d"), videos: nil)
        }
        return BrowseRow(key: "addons", title: T("Your addons"), metas: metas, shape: .brand)
    }

    /// bp-home "Collections" (bp-collections-row.tsx): TMDB's curated franchises as 16:9 cards; the
    /// engine returns nothing without a TMDB key or when the synced layout hides "collections".
    private func collectionsRow(_ profileId: String, _ linked: Bool) async -> BrowseRow? {
        let cardsLossy: LossyArray<CollectionsModel.Card>? = try? await HarborEngine.shared.call("collectionsRoom.curatedRow", [profileId, linked, 30])   // (bug pass 2) lossy
        let cards = cardsLossy?.wrappedValue ?? []
        guard !cards.isEmpty else { return nil }
        let metas = cards.map { c in
            // bp-collection-card metaLine for a TMDB entry: "{count} films", else "Collection".
            Meta(id: "collection:tmdb:\(c.ref)", type: "collection", name: c.name, poster: nil, background: c.image, logo: nil,
                 description: c.count.map { T("%lld films", $0) } ?? T("Collection"), releaseInfo: nil, releaseDate: nil, inTheaters: nil,
                 imdbRating: nil, tmdbScore: nil, runtime: nil, genres: nil, adult: nil, isCollection: true, providerBadge: nil, videos: nil)
        }
        return BrowseRow(key: "collections", title: T("Collections"), metas: metas, shape: .collection)
    }

    /// bp-home.tsx: `head` (the first SERVICES_SLOT = 2 catalog rows), then the Collections row,
    /// then the tail, so the row lands just before the third catalog row (or last).
    private static func insertCollections(_ row: BrowseRow?, into rows: inout [BrowseRow], build: RoomBuild) {
        // Never the only row: the hero pool reads the first catalog row.
        guard let row, !build.rows.isEmpty else { return }
        let third: String? = build.rows.count > 2 ? build.rows[2].key : nil
        let at = third.flatMap { key in rows.firstIndex(where: { $0.key == key }) }
        rows.insert(row, at: at ?? rows.count)
    }

    func rows(for room: Room) async throws -> [BrowseRow] {
        let p = await profile
        let build: RoomBuild
        switch room {
        case .home:
            // bp-collections-row: resolved alongside the catalogs so it never delays them much.
            async let curated = collectionsRow(p.id, p.linked)
            build = try await HarborEngine.shared.call("rooms.homeFor", [p.id, p.linked, p.authKey])
            // bp-home.tsx: "Your streaming" brand tiles sit after the first two catalog rows
            // (SERVICES_SLOT = 2); upstream also slots CW, addon, live and collection bands
            // around them, which this room renders elsewhere or not yet.
            struct Services: Decodable { struct Tile: Decodable { var id: String; var name: String; var tint: String }; var hasKey: Bool; @LossyArray var services: [Tile] }
            if let svc: Services = try? await HarborEngine.shared.call("services.list", [p.id, p.linked]), !svc.services.isEmpty {
                let metas = svc.services.map { t in
                    Meta(id: "service:\(t.id)", type: "service", name: t.name, poster: nil, background: nil, logo: nil, description: nil, releaseInfo: nil, releaseDate: nil,
                         inTheaters: nil, imdbRating: nil, tmdbScore: nil, runtime: nil, genres: nil, adult: nil, isCollection: nil,
                         providerBadge: Meta.ProviderBadge(name: t.name, logo: "", tint: t.tint), videos: nil)
                }
                var rows = build.rows.map { BrowseRow(key: $0.key, title: $0.name, metas: $0.metas, shape: $0.shape == "rank" ? .rank : .poster) }
                rows.insert(BrowseRow(key: "services", title: T("Your streaming"), metas: metas, shape: .brand), at: min(2, rows.count))
                if let addons = await addonsBand(p.authKey) { rows.insert(addons, at: min(3, rows.count)) }
                Self.insertCollections(await curated, into: &rows, build: build)
                if build.failed && rows.isEmpty { throw BrowseError.empty }
                return rows
            }
            var rows = build.rows.map { BrowseRow(key: $0.key, title: $0.name, metas: $0.metas, shape: $0.shape == "rank" ? .rank : .poster) }
            if let addons = await addonsBand(p.authKey) { rows.insert(addons, at: min(2, rows.count)) }
            Self.insertCollections(await curated, into: &rows, build: build)
            if build.failed && rows.isEmpty { throw BrowseError.empty }
            return rows
        case .movies, .shows:
            build = try await HarborEngine.shared.call("rooms.catalogFor", [room == .movies ? "movies" : "shows", p.id, p.linked])
            if room == .movies {
                // use-bp-movies.ts: Letterboxd rows (public username through Stremboxd) sit right
                // after the Top 10 row, or first when there is none.
                struct LetterboxdRow: Decodable { var key: String; var name: String; @LossyArray var metas: [Meta] }
                let extraLossy: LossyArray<LetterboxdRow>? = try? await HarborEngine.shared.call("letterboxd.movieRows", [p.id, p.linked])   // (bug pass 2) lossy
                let extra = extraLossy?.wrappedValue ?? []
                if !extra.isEmpty {
                    var rows = build.rows.map { BrowseRow(key: $0.key, title: $0.name, metas: $0.metas, shape: $0.shape == "rank" ? .rank : .poster) }
                    let at = build.rows.first?.shape == "rank" ? 1 : 0
                    rows.insert(contentsOf: extra.map { BrowseRow(key: $0.key, title: $0.name, metas: $0.metas, shape: .poster) }, at: min(at, rows.count))
                    return rows
                }
            }
        case .anime:
            // use-bp-anime port: returns at once with whatever Jikan rows have landed; the room
            // re-reads on `harbor:anime-updated`. Rows still loading carry no metas yet.
            let anime: AnimeBuild = try await HarborEngine.shared.call("animeRoom.page", [p.id, p.linked, p.authKey])
            if anime.failed { throw BrowseError.empty }
            return anime.rows.filter { !$0.metas.isEmpty }.map { BrowseRow(key: $0.key, title: $0.name, metas: $0.metas, shape: $0.shape == "rank" ? .rank : .poster) }
        default:
            return []
        }
        if build.failed && build.rows.isEmpty { throw BrowseError.empty }
        return build.rows.map { BrowseRow(key: $0.key, title: $0.name, metas: $0.metas, shape: $0.shape == "rank" ? .rank : .poster) }
    }

    struct AnimeBuild: Decodable {
        struct Row: Decodable { var key: String; var name: String; @LossyArray var metas: [Meta]; var shape: String; var loading: Bool }
        @LossyArray var rows: [Row]; @LossyArray var hero: [Meta]; var loading: Bool; var ready: Int; var total: Int; var failed: Bool
    }

    func continueWatching(for room: Room) async throws -> [ContinueItem] {
        let p = await profile
        // Cloud library (when signed in to Stremio) merged with this TV's own resume entries;
        // the anime room gets upstream's anime-only Continue Watching (one per franchise).
        let items: [LibraryItem]
        if room == .anime {
            struct Page: Decodable { @LossyArray var cw: [LibraryItem] }
            let page: Page = try await HarborEngine.shared.call("animeRoom.page", [p.id, p.linked, p.authKey])
            items = page.cw
        } else {
            let all: LossyArray<LibraryItem> = try await HarborEngine.shared.call("rooms.continueWatchingWithExtras", [p.id, p.linked, p.authKey])
            items = all.wrappedValue   // (bug pass 2) one odd synced item no longer empties the row
        }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return items.map { i in
            let off = i.state?.timeOffset ?? 0, dur = i.state?.duration ?? 0
            var season = i.state?.season, episode = i.state?.episode
            if (episode ?? 0) == 0, let vid = i.state?.video_id, let parsed = VideoId.seasonEpisode(vid, metaId: i._id) { season = parsed.season; episode = parsed.episode }
            return ContinueItem(id: i._id, type: i.type, name: i.name, poster: i.poster, background: i.background, logo: nil,
                                season: season, episode: episode,
                                progress: dur > 0 ? min(1, max(0, off / dur)) : 0,
                                lastWatched: (i.state?.lastWatched ?? i._mtime).flatMap { iso.date(from: $0) ?? ISO8601DateFormatter().date(from: $0) },
                                durationMs: dur, timeOffsetMs: off,
                                watched: i._cw?.watched ?? false, newEpisode: i._cw?.newEpisode ?? 0, upNext: i._cw?.upNext ?? false,
                                waitingForAir: i._cw?.waitingForAir ?? false, nextAirDate: i._cw?.nextAirDate, watcher: i._cw?.watcher, external: i._cw?.external,
                                anime: room == .anime || (i._cw?.anime ?? false))
        }
    }

    enum BrowseError: Error, LocalizedError {
        case empty
        var errorDescription: String? { "No catalog rows came back. Check the connection, or add a TMDB key in Settings." }
    }
}


/// Upstream stremio.ts:70-76 + episodeFromVideoId: "tt123:2:5" → S2E5; anime "kitsu:123:7" → S1E7.
enum VideoId {
    static func seasonEpisode(_ vid: String, metaId: String) -> (season: Int, episode: Int)? {
        let parts = vid.split(separator: ":")
        let anime = ["kitsu:", "mal:", "anilist:", "anidb:"].contains { metaId.hasPrefix($0) || vid.hasPrefix($0) }
        if anime, parts.count == 3, let e = Int(parts[2]) { return (1, e) }
        guard parts.count >= 3, let s = Int(parts[parts.count - 2]), let e = Int(parts[parts.count - 1]) else { return nil }
        return (s, e)
    }
}


/// bp-service.tsx: one streaming service's category rows, through the engine's TMDB fetch.
struct ServiceBrowseSource: BrowseSource {
    let service: String
    var cacheId: String? { "service.\(service)" }

    struct Build: Decodable {
        struct Row: Decodable { var key: String; var name: String; var type: String; @LossyArray var metas: [Meta]; var hasMore: Bool }
        var hasKey: Bool; var name: String; var tint: String; @LossyArray var rows: [Row]
    }

    /// bp-home "Your addons": one brand card per installed addon; Select opens its catalogs.
    private func addonsBand(_ authKey: String?) async -> BrowseRow? {
        struct Card: Decodable { var key: String; var name: String; var base: String; var logo: String?; var hasCatalogs: Bool; @LossyArray var posters: [String] }
        let cardsLossy: LossyArray<Card>? = try? await HarborEngine.shared.call("addonsRoom.cards", [authKey, true])   // (bug pass 2) lossy
        let cards = cardsLossy?.wrappedValue ?? []
        guard !cards.isEmpty else { return nil }
        let metas = cards.map { c in
            Meta(id: "addon:\(c.base)", type: "addon", name: c.name, poster: c.posters.first, background: nil, logo: nil, description: nil, releaseInfo: nil, releaseDate: nil,
                 inTheaters: nil, imdbRating: nil, tmdbScore: nil, runtime: nil, genres: nil, adult: nil, isCollection: nil,
                 providerBadge: Meta.ProviderBadge(name: c.name, logo: c.logo ?? "", tint: "#2a2b2d"), videos: nil)
        }
        return BrowseRow(key: "addons", title: T("Your addons"), metas: metas, shape: .brand)
    }

    func rows(for room: Room) async throws -> [BrowseRow] {
        // ProfilesStore is main-actor bound; this source runs off it.
        let p = await MainActor.run { ProfilesStore.shared.active }
        let build: Build = try await HarborEngine.shared.call("services.rows", [service, p?.id ?? "default", p?.linked ?? true])
        if !build.hasKey { throw ServiceError.noKey }
        return build.rows.map { BrowseRow(key: $0.key, title: $0.name, metas: $0.metas, shape: .poster) }
    }

    func continueWatching(for room: Room) async throws -> [ContinueItem] { [] }

    enum ServiceError: Error, LocalizedError {
        case noKey
        var errorDescription: String? { "Add a TMDB key in Settings to browse this service." }
    }
}

// (bug pass 2) Library items come from the Stremio sync as other clients wrote them; a stray
// `name: null`, a string `season` or an odd `_cw` no longer drops the item (or, with the
// array decoded strictly, the whole Continue Watching row). An item still needs `_id` and
// `type` to open. In extensions so the memberwise initializers stay.
extension EngineBrowseSource.LibraryItem {
    private enum LenientKeys: String, CodingKey { case _cw, _id, type, name, poster, background, state, _mtime }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: LenientKeys.self)
        func str(_ k: LenientKeys) -> String? { try? c.decodeIfPresent(String.self, forKey: k) }
        guard let id = str(._id), !id.isEmpty, let type = str(.type), !type.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: LenientKeys._id, in: c, debugDescription: "library item without _id or type")
        }
        self.init(_cw: try? c.decodeIfPresent(CwExtras.self, forKey: ._cw),
                  _id: id, type: type, name: str(.name) ?? "",
                  poster: str(.poster), background: str(.background),
                  state: try? c.decodeIfPresent(State.self, forKey: .state),
                  _mtime: str(._mtime))
    }
}

extension EngineBrowseSource.LibraryItem.State {
    private enum LenientKeys: String, CodingKey { case timeOffset, duration, season, episode, video_id, lastWatched }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: LenientKeys.self)
        func num(_ k: LenientKeys) -> Double? {
            if let n = try? c.decodeIfPresent(Double.self, forKey: k) { return n.isFinite ? n : nil }
            if let s = try? c.decodeIfPresent(String.self, forKey: k) { return Double(s).flatMap { $0.isFinite ? $0 : nil } }
            return nil
        }
        func int(_ k: LenientKeys) -> Int? { num(k).flatMap { abs($0) < 1e9 ? Int($0) : nil } }
        self.init(timeOffset: num(.timeOffset), duration: num(.duration), season: int(.season), episode: int(.episode),
                  video_id: try? c.decodeIfPresent(String.self, forKey: .video_id),
                  lastWatched: try? c.decodeIfPresent(String.self, forKey: .lastWatched))
    }
}
