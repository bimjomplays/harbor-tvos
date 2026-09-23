import Foundation

/// Rooms built by upstream's own row logic running in the engine (engine/rooms.ts).
struct EngineBrowseSource: BrowseSource {
    struct RoomBuild: Decodable {
        struct Row: Decodable {
            var key: String
            var type: String
            var name: String
            var metas: [Meta]
            var hasMore: Bool
            var shape: String
        }
        var rows: [Row]
        var hero: [Meta]
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
        struct CwExtras: Decodable { var watched: Bool; var newEpisode: Int; var upNext: Bool; var waitingForAir: Bool; var nextAirDate: String?; var watcher: String?; var external: String? }
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
        struct Card: Decodable { var key: String; var name: String; var base: String; var logo: String?; var hasCatalogs: Bool; var posters: [String] }
        let cards: [Card] = (try? await HarborEngine.shared.call("addonsRoom.cards", [authKey, true])) ?? []
        guard !cards.isEmpty else { return nil }
        let metas = cards.map { c in
            Meta(id: "addon:\(c.base)", type: "addon", name: c.name, poster: c.posters.first, background: nil, logo: nil, description: nil, releaseInfo: nil, releaseDate: nil,
                 inTheaters: nil, imdbRating: nil, tmdbScore: nil, runtime: nil, genres: nil, adult: nil, isCollection: nil,
                 providerBadge: Meta.ProviderBadge(name: c.name, logo: c.logo ?? "", tint: "#2a2b2d"), videos: nil)
        }
        return BrowseRow(key: "addons", title: "Your addons", metas: metas, shape: .brand)
    }

    func rows(for room: Room) async throws -> [BrowseRow] {
        let p = await profile
        let build: RoomBuild
        switch room {
        case .home:
            build = try await HarborEngine.shared.call("rooms.homeFor", [p.id, p.linked, p.authKey])
            // bp-home.tsx: "Your streaming" brand tiles sit after the first two catalog rows
            // (SERVICES_SLOT = 2); upstream also slots CW, addon, live and collection bands
            // around them, which this room renders elsewhere or not yet.
            struct Services: Decodable { struct Tile: Decodable { var id: String; var name: String; var tint: String }; var hasKey: Bool; var services: [Tile] }
            if let svc: Services = try? await HarborEngine.shared.call("services.list", [p.id, p.linked]), !svc.services.isEmpty {
                let metas = svc.services.map { t in
                    Meta(id: "service:\(t.id)", type: "service", name: t.name, poster: nil, background: nil, logo: nil, description: nil, releaseInfo: nil, releaseDate: nil,
                         inTheaters: nil, imdbRating: nil, tmdbScore: nil, runtime: nil, genres: nil, adult: nil, isCollection: nil,
                         providerBadge: Meta.ProviderBadge(name: t.name, logo: "", tint: t.tint), videos: nil)
                }
                var rows = build.rows.map { BrowseRow(key: $0.key, title: $0.name, metas: $0.metas, shape: $0.shape == "rank" ? .rank : .poster) }
                rows.insert(BrowseRow(key: "services", title: "Your streaming", metas: metas, shape: .brand), at: min(2, rows.count))
                if let addons = await addonsBand(p.authKey) { rows.insert(addons, at: min(3, rows.count)) }
                if build.failed && rows.isEmpty { throw BrowseError.empty }
                return rows
            }
            var rows = build.rows.map { BrowseRow(key: $0.key, title: $0.name, metas: $0.metas, shape: $0.shape == "rank" ? .rank : .poster) }
            if let addons = await addonsBand(p.authKey) { rows.insert(addons, at: min(2, rows.count)) }
            if build.failed && rows.isEmpty { throw BrowseError.empty }
            return rows
        case .movies, .shows:
            build = try await HarborEngine.shared.call("rooms.catalogFor", [room == .movies ? "movies" : "shows", p.id, p.linked])
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
        struct Row: Decodable { var key: String; var name: String; var metas: [Meta]; var shape: String; var loading: Bool }
        var rows: [Row]; var hero: [Meta]; var loading: Bool; var ready: Int; var total: Int; var failed: Bool
    }

    func continueWatching(for room: Room) async throws -> [ContinueItem] {
        let p = await profile
        // Cloud library (when signed in to Stremio) merged with this TV's own resume entries;
        // the anime room gets upstream's anime-only Continue Watching (one per franchise).
        let items: [LibraryItem]
        if room == .anime {
            struct Page: Decodable { var cw: [LibraryItem] }
            let page: Page = try await HarborEngine.shared.call("animeRoom.page", [p.id, p.linked, p.authKey])
            items = page.cw
        } else {
            items = try await HarborEngine.shared.call("rooms.continueWatchingWithExtras", [p.id, p.linked, p.authKey])
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
                                waitingForAir: i._cw?.waitingForAir ?? false, nextAirDate: i._cw?.nextAirDate, watcher: i._cw?.watcher, external: i._cw?.external)
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
        struct Row: Decodable { var key: String; var name: String; var type: String; var metas: [Meta]; var hasMore: Bool }
        var hasKey: Bool; var name: String; var tint: String; var rows: [Row]
    }

    /// bp-home "Your addons": one brand card per installed addon; Select opens its catalogs.
    private func addonsBand(_ authKey: String?) async -> BrowseRow? {
        struct Card: Decodable { var key: String; var name: String; var base: String; var logo: String?; var hasCatalogs: Bool; var posters: [String] }
        let cards: [Card] = (try? await HarborEngine.shared.call("addonsRoom.cards", [authKey, true])) ?? []
        guard !cards.isEmpty else { return nil }
        let metas = cards.map { c in
            Meta(id: "addon:\(c.base)", type: "addon", name: c.name, poster: c.posters.first, background: nil, logo: nil, description: nil, releaseInfo: nil, releaseDate: nil,
                 inTheaters: nil, imdbRating: nil, tmdbScore: nil, runtime: nil, genres: nil, adult: nil, isCollection: nil,
                 providerBadge: Meta.ProviderBadge(name: c.name, logo: c.logo ?? "", tint: "#2a2b2d"), videos: nil)
        }
        return BrowseRow(key: "addons", title: "Your addons", metas: metas, shape: .brand)
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
