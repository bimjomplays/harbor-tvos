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

    func rows(for room: Room) async throws -> [BrowseRow] {
        let p = await profile
        let build: RoomBuild
        switch room {
        case .home:
            build = try await HarborEngine.shared.call("rooms.homeFor", [p.id, p.linked, p.authKey])
        case .movies, .shows:
            build = try await HarborEngine.shared.call("rooms.catalogFor", [room == .movies ? "movies" : "shows", p.id, p.linked])
        case .anime:
            build = try await HarborEngine.shared.call("rooms.anime", [])
        default:
            return []
        }
        if build.failed && build.rows.isEmpty { throw BrowseError.empty }
        return build.rows.map { BrowseRow(key: $0.key, title: $0.name, metas: $0.metas, shape: $0.shape == "rank" ? .rank : .poster) }
    }

    func continueWatching() async throws -> [ContinueItem] {
        let p = await profile
        // Cloud library (when signed in to Stremio) merged with this TV's own resume entries.
        let items: [LibraryItem] = try await HarborEngine.shared.call("rooms.continueWatchingFor", [p.id, p.linked, p.authKey])
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return items.map { i in
            let off = i.state?.timeOffset ?? 0, dur = i.state?.duration ?? 0
            var season = i.state?.season, episode = i.state?.episode
            if (episode ?? 0) == 0, let vid = i.state?.video_id, let parsed = VideoId.seasonEpisode(vid, metaId: i._id) { season = parsed.season; episode = parsed.episode }
            return ContinueItem(id: i._id, type: i.type, name: i.name, poster: i.poster, background: i.background, logo: nil,
                                season: season, episode: episode,
                                progress: dur > 0 ? min(1, max(0, off / dur)) : 0,
                                lastWatched: (i.state?.lastWatched ?? i._mtime).flatMap { iso.date(from: $0) ?? ISO8601DateFormatter().date(from: $0) })
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
