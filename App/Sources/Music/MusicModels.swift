import Foundation

/// lib/music/types.ts MusicTrack. Codable both ways: Swift hands tracks back to the engine
/// (prepare, addRecent, setLiked, home's up-next), so every field upstream reads is kept.
/// Optional fields are omitted on encode, which is what the engine expects for "absent".
struct MusicTrack: Codable, Equatable, Hashable, Identifiable {
    struct Origin: Codable, Equatable, Hashable { var id: String; var connectorId: String? }
    var id: String
    var title: String
    var artist: String
    var album: String?
    var artwork: String?
    var durationSeconds: Double?
    var durationLabel: String?
    var connectorId: String?
    var sourceId: String?
    var playbackUrl: String?
    var explicit: Bool?
    var version: String?
    var mediaKind: String?
    var collectionOrigin: Origin?

    /// player.ts queueTrackKey: the same song from two sources is two queue entries.
    var queueKey: String { "\(connectorId ?? ""):\(id)" }
    var seconds: Double { durationSeconds ?? 0 }
    /// liked.ts likedIdsFor
    var likedIds: [String] {
        var out = [id]
        if let o = collectionOrigin?.id, o != id { out.append(o) }
        return out
    }
}

/// engine/music.ts MusicCard: one catalog item, flattened for display. `item` is the upstream
/// MusicCatalogItem, sent back unchanged to `music.open`.
struct MusicCard: Decodable, Identifiable {
    var key: String
    var kind: String
    var title: String
    var subtitle: String
    var artwork: String
    var artworks: [String]
    var circle: Bool
    var connectorId: String
    var track: MusicTrack?
    var item: AnyJSON
    var id: String { key }
}

/// engine/music.ts MusicBand: a home shelf (music-catalog-row.tsx layouts: covers, circles, trackGrid).
struct MusicBand: Decodable, Identifiable {
    var key: String
    var title: String
    var subtitle: String
    var layout: String
    var source: String
    var numbered: Bool
    var cards: [MusicCard]
    var notice: String?
    var id: String { key }
}

struct MusicSourceError: Decodable, Hashable { var source: String; var message: String }

struct MusicHomeData: Decodable {
    var bands: [MusicBand]
    var errors: [MusicSourceError]
    var failed: Bool
}

struct MusicSearchData: Decodable {
    var top: MusicCard?
    var tracks: [MusicCard]
    var albums: [MusicCard]
    var artists: [MusicCard]
    var playlists: [MusicCard]
    var errors: [MusicSourceError]
    var isEmpty: Bool { top == nil && tracks.isEmpty && albums.isEmpty && artists.isEmpty && playlists.isEmpty }
}

/// engine/music.ts MusicPage: an album, artist, playlist or station opened from a card.
struct MusicPageData: Decodable {
    var kind: String
    var title: String
    var subtitle: String
    var artwork: String
    var circle: Bool
    var tracks: [MusicTrack]
    var bands: [MusicBand]
}

/// engine/music.ts prepare(): the track that will actually play (a catalog entry is swapped for
/// its matched source) and the stream the source resolved.
struct MusicPrepared: Decodable {
    struct Stream: Decodable { var url: String; var mimeType: String; var bitrate: Double; var httpHeaders: [String: String]? }
    var track: MusicTrack
    var stream: Stream
    var failed: [String]
}

struct MusicLibraryState: Decodable {
    var liked: [MusicTrack]
    var likedIds: [String]
    var recents: [MusicTrack]
}

struct MusicConnectionRow: Decodable, Identifiable {
    var id: String
    var name: String
    var kind: String
    var status: String
    var health: String
    var detail: String?
    var gated: Bool
    var enabled: Bool
    var capabilities: [String]
}

struct MusicConsentState: Decodable { var accepted: Bool; var soundcloud: Bool }

/// The room's copy, from upstream's English (or the profile's language) through lib/i18n.
@MainActor
final class MusicCopy: ObservableObject {
    static let shared = MusicCopy()
    @Published private(set) var strings: [String: String] = [:]
    func load() async {
        if let s: [String: String] = try? await HarborEngine.shared.call("music.copy") { strings = s }
    }
    /// The engine's text, else the English fallback given here (the same upstream string).
    func callAsFunction(_ key: String, _ fallback: String) -> String { strings[key] ?? fallback }
}
