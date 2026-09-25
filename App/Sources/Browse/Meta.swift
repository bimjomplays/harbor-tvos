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
    /// cinemeta.ts AddonOrigin: the addon that served this meta (lib/addons, catalog-browse,
    /// search-addons stamp it). bp-hero-notes BpHeroMarks draws it on the Detail hero; it
    /// round-trips through the engine so watchlist/list writes keep it (persistableAddonOrigin).
    var addonOrigin: AddonOrigin? = nil
    struct AddonOrigin: Codable, Equatable, Hashable { var id: String; var name: String; var logo: String?; var base: String? }

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

/// (bug pass) Addon catalogs reach Swift as the addon wrote them: `imdbRating` or `releaseInfo` as a
/// number, `genres` / `cast` as objects, `tmdbScore` as a string. With the synthesized decoder one
/// such meta failed the whole `[Meta]` and so the whole room ("Couldn't load this room"). This
/// decoder takes numbers as strings and the reverse, and drops a field it cannot read instead.
/// It lives in an extension so the memberwise initializer stays; encoding stays synthesized.
extension Meta {
    private enum LenientKeys: String, CodingKey {
        case id, type, name, poster, background, logo, description, releaseInfo, releaseDate, inTheaters, imdbRating, tmdbScore
        case runtime, genres, adult, isCollection, providerBadge, videos, cast, director, writer, trailerStreams
        case addonOrigin
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: LenientKeys.self)
        func str(_ k: LenientKeys) -> String? {
            if let s = try? c.decodeIfPresent(String.self, forKey: k) { return s }
            if let n = try? c.decodeIfPresent(Double.self, forKey: k), n.isFinite {
                return n == n.rounded() && abs(n) < 1e15 ? String(Int64(n)) : String(n)
            }
            return nil
        }
        func strings(_ k: LenientKeys) -> [String]? {
            if let list = try? c.decodeIfPresent([AnyJSON].self, forKey: k) {
                return list.compactMap { v -> String? in
                    if case .string(let s) = v { return s }
                    if case .object(let o) = v, case .string(let s)? = o["name"] { return s }
                    return nil
                }
            }
            return nil
        }
        guard let id = str(.id), !id.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: LenientKeys.id, in: c, debugDescription: "meta without an id")
        }
        self.init(id: id, type: str(.type) ?? "", name: str(.name) ?? "",
                  poster: str(.poster), background: str(.background), logo: str(.logo), description: str(.description),
                  releaseInfo: str(.releaseInfo), releaseDate: str(.releaseDate),
                  inTheaters: try? c.decodeIfPresent(Bool.self, forKey: .inTheaters),
                  imdbRating: str(.imdbRating),
                  tmdbScore: (try? c.decodeIfPresent(Double.self, forKey: .tmdbScore)) ?? str(.tmdbScore).flatMap { Double($0) },
                  runtime: str(.runtime), genres: strings(.genres),
                  adult: try? c.decodeIfPresent(Bool.self, forKey: .adult),
                  isCollection: try? c.decodeIfPresent(Bool.self, forKey: .isCollection),
                  providerBadge: try? c.decodeIfPresent(ProviderBadge.self, forKey: .providerBadge),
                  videos: try? c.decodeIfPresent([AnyJSON].self, forKey: .videos),
                  cast: strings(.cast), director: strings(.director), writer: strings(.writer),
                  trailerStreams: try? c.decodeIfPresent([TrailerStream].self, forKey: .trailerStreams),
                  addonOrigin: Self.origin(try? c.decodeIfPresent(AnyJSON.self, forKey: .addonOrigin)))
    }

    /// An origin the addon mark can use: a name is required (BpHeroMarks checks origin?.name);
    /// the id, logo and base are kept when they are strings.
    private static func origin(_ raw: AnyJSON?) -> AddonOrigin? {
        guard case .object(let o)? = raw, case .string(let name)? = o["name"], !name.isEmpty else { return nil }
        var id = ""
        if case .string(let s)? = o["id"] { id = s }
        var logo: String? = nil
        if case .string(let s)? = o["logo"], !s.isEmpty { logo = s }
        var base: String? = nil
        if case .string(let s)? = o["base"], !s.isEmpty { base = s }
        return AddonOrigin(id: id, name: name, logo: logo, base: base)
    }
}

extension Array where Element: Identifiable {
    /// (bug pass) First occurrence of each id. ForEach and `.focused(equals:)` need unique ids;
    /// addon catalogs, TMDB credits and Cinemeta videos all repeat entries now and then.
    func uniquedById() -> [Element] {
        var seen = Set<Element.ID>()
        return filter { seen.insert($0.id).inserted }
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
    /// lib/stremio isAnimeCwItem: absolute numbering that does not map onto season and episode.
    var anime = false

    /// What Select on the card does (bp-cw-row.tsx BpCwCard onPress).
    enum Press: Equatable { case detail, resumeMovie, resumeEpisode(season: Int, episode: Int) }

    /// bp-cw-row.tsx bpCwResume: one-press resume needs positive evidence of what the card would
    /// play. No progress, an Up Next or waiting card, an anime entry, or a series without a
    /// nameable episode goes to the detail page instead.
    var press: Press {
        guard progress > 0, !upNext, !waitingForAir else { return .detail }
        if type == "movie" { return .resumeMovie }
        let animeId = ["kitsu:", "mal:", "anilist:", "anidb:"].contains { id.hasPrefix($0) }
        if anime || animeId { return .detail }
        guard let s = season, let e = episode, s > 0, e > 0 else { return .detail }
        return .resumeEpisode(season: s, episode: e)
    }
}
