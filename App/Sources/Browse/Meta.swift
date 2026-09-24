import Foundation

/// Upstream `Meta` (src/lib/cinemeta.ts:14-56), decoded leniently: unknown fields are kept
/// in `extra` so nothing an addon sent is lost when the value round-trips through the engine.
struct Meta: Codable, Identifiable, Equatable, Hashable {
    var id: String
    var type: String
    var name: String
    var poster: String?
    var background: String?
    var logo: String?
    var description: String?
    var releaseInfo: String?
    var releaseDate: String?
    var inTheaters: Bool?
    var imdbRating: String?
    var tmdbScore: Double?
    var runtime: String?
    var genres: [String]?
    var adult: Bool?
    var isCollection: Bool?
    var providerBadge: ProviderBadge?
    var videos: [AnyJSON]?
    // Cinemeta extras (not in upstream's Meta type, but present on its responses).
    var cast: [String]?
    var director: [String]?
    var writer: [String]?
    /// Cinemeta's YouTube trailers; bp-detail falls back to the first when TMDB has none.
    var trailerStreams: [TrailerStream]?
    struct TrailerStream: Codable, Equatable, Hashable { var ytId: String?; var title: String? }

    struct ProviderBadge: Codable, Equatable, Hashable { var name: String; var logo: String; var tint: String }

    static func == (a: Meta, b: Meta) -> Bool { a.id == b.id && a.name == b.name && a.poster == b.poster }
    func hash(into h: inout Hasher) { h.combine(id) }

    /// "2024 · 1h 52m · Action, Drama" as upstream's `bpFacts` reads.
    var facts: String {
        var parts: [String] = []
        if let y = releaseInfo, !y.isEmpty { parts.append(y) }
        if let r = runtime, !r.isEmpty { parts.append(r) }
        if let g = genres, !g.isEmpty { parts.append(g.prefix(3).joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }
}

/// `collection`: bp-collection-card's 16:9 plate (Home "Collections" row).
enum TileShape: String, Codable { case poster, wide, rank, brand, collection }

/// One horizontal row in a room.
struct BrowseRow: Identifiable, Equatable, Codable {
    var key: String
    var title: String
    var metas: [Meta]
    var shape: TileShape = .poster
    var id: String { key }
}

/// A Continue Watching entry (upstream `LibraryItem` + local resume), reduced to what the card shows.
struct ContinueItem: Identifiable, Equatable {
    var id: String
    var type: String
    var name: String
    var poster: String?
    var background: String?
    var logo: String?
    var season: Int?
    var episode: Int?
    var progress: Double   // 0...1
    var lastWatched: Date?
    var durationMs: Double = 0
    var timeOffsetMs: Double = 0
    // bp-cw-card-meta extras
    var watched = false
    var newEpisode = 0
    var upNext = false
    var waitingForAir = false
    var nextAirDate: String? = nil
    var watcher: String? = nil
    var external: String? = nil
}
