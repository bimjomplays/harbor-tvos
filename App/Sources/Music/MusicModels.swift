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
    /// spotify-library.ts spotifyTrackUri: the URI this track can be added to a Spotify playlist by.
    var spotifyTrackUri: String? {
        let prefix = "spotify:track:"
        return [sourceId, id].compactMap { $0 }.first { value in
            guard value.hasPrefix(prefix) else { return false }
            let rest = value.dropFirst(prefix.count)
            return rest.count == 22 && rest.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
        }
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
    /// artist_catalog.rs next_cursor: the shelf has more (a Spotify artist's albums), for `music.artistMore`.
    var more: String?
    var id: String { key }
}

/// engine/music.ts artistMore (views/music.tsx loadMoreArtistReleases): the next albums and cursor.
struct MusicArtistMore: Decodable {
    var cards: [MusicCard]
    var more: String?
}

/// engine/musicSpotify.ts SpotifyLibraryPlaylist (library.rs): a playlist and what the account may
/// do with it (read: owned or collaborative; editable: readable and the playlist-modify scope granted).
struct MusicSpotifyLibraryPlaylist: Decodable, Identifiable, Hashable {
    var id: String
    var connectorId: String
    var name: String
    var artwork: [String]
    var trackCount: Int?
    var subtitle: String?
    var canRead: Bool
    var editable: Bool

    /// music-spotify-library.tsx: open.spotify.com/playlist/<id>.
    var webUrl: String { "https://open.spotify.com/playlist/\(id.split(separator: ":").last.map(String.init) ?? id)" }
}

/// engine/musicSpotify.ts SpotifyLibraryPage (library.rs music_spotify_library_page).
struct MusicSpotifyLibraryPage: Decodable {
    var tracks: [MusicTrack]
    var playlists: [MusicSpotifyLibraryPlaylist]
    var nextOffset: Int?
    var total: Int?
    var skipped: Int
    var canCreate: Bool
    var writePermission: Bool
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
    /// The signed-in account (Navidrome user, Last.fm user, Spotify user), as upstream's MusicConnection.account.
    var account: String?
    /// MusicConnection.error (Spotify's recorded sign-in or session failure).
    var error: String?
    var gated: Bool
    var enabled: Bool
    var capabilities: [String]
}

struct MusicConsentState: Decodable { var accepted: Bool; var soundcloud: Bool }

/// engine/music.ts subsonicConnect: the account and server the pairing was made with.
struct MusicSubsonicConnected: Decodable { var account: String; var detail: String }

/// engine/musicSpotify.ts setup (spotify-setup.tsx: the saved client id and the redirect URI).
struct MusicSpotifySetup: Decodable { var clientId: String; var redirectUri: String; var dashboardUrl: String; var hint: String }

/// engine/musicSpotify.ts begin: the authorize URL the phone opens.
struct MusicSpotifyAuthStart: Decodable { var authorizeUrl: String; var redirectUri: String }

/// engine/musicScrobble.ts lastfmStatus (lastfm.rs status + the saved credentials).
struct MusicLastFmStatus: Decodable {
    var connected: Bool
    var username: String?
    var saved: Bool
    var apiKey: String
    var health: String
}

/// engine/musicScrobble.ts lastfmBegin (lastfm.rs LastFmAuthStart).
struct MusicLastFmAuthStart: Decodable { var token: String; var authUrl: String }

/// engine/musicScrobble.ts scrobble: "scrobbled" is upstream's music://lastfm event.
struct MusicScrobbleResult: Decodable { var status: String; var message: String? }

/// engine/music.ts lyrics: lyrics.ts LyricLine[] and the lyric-offset.ts offset for the track.
struct MusicLyrics: Decodable {
    struct Line: Decodable, Hashable { var at: Double; var text: String }
    var lines: [Line]
    var offset: Double
}

/// The room's copy, from upstream's English (or the profile's language) through lib/i18n.
@MainActor
final class MusicCopy: ObservableObject {
    static let shared = MusicCopy()
    @Published private(set) var strings: [String: String] = [:]
    func load() async {
        if let s: [String: String] = try? await HarborEngine.shared.call("music.copy") { strings = s }
    }
    /// The engine's text, else the English fallback given here (the same upstream string). A key
    /// upstream's catalogs lack comes back in English (translate.ts falls back to en), so that
    /// English goes through T(): the Swift catalog may have it (tools/locales-tvos.json).
    func callAsFunction(_ key: String, _ fallback: String) -> String {
        let text = strings[key] ?? fallback
        return text == fallback ? T(fallback) : text
    }
}
