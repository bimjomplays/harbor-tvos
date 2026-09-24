import Foundation
import SwiftUI

// Stage 13 eBooks: the shapes the engine's `ebook.*` calls return (engine/ebook.ts), decoded
// leniently: the shelf and favourites are stored objects upstream only loosely validates.

/// lib/ebook/api.ts EBook. Round-trips through the engine (shelf, favourites, source
/// resolution), so every field upstream sets is kept; `sourceIdentity` rides along untouched.
struct EBook: Codable, Identifiable, Hashable {
    var id: String
    var source: String?
    var providerId: String?
    var sourceItemId: String?
    var providerName: String?
    var anilistId: Double?
    var googleBooksId: String?
    var openLibraryId: String?
    var wikidataId: String?
    var isbn: String?
    var seriesTitle: String?
    var sourceAliases: [String]?
    var verifiedAliases: [String]?
    var sourceIdentity: AnyJSON?
    var books: [EBook]?
    var title: String
    var altTitle: String?
    var authors: [String]
    var cover: String?
    var internalCover: String?
    var banner: String?
    var description: String
    var year: Double?
    var publishedAt: String?
    var status: String?
    var originalLanguage: String?
    var genres: [String]
    var chapters: Double?
    var volumes: Double?
    var score: Double?
    var trendingScore: Double?
    var siteUrl: String?

    func hash(into h: inout Hasher) { h.combine(id) }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        source = try? c.decodeIfPresent(String.self, forKey: .source)
        providerId = try? c.decodeIfPresent(String.self, forKey: .providerId)
        sourceItemId = try? c.decodeIfPresent(String.self, forKey: .sourceItemId)
        providerName = try? c.decodeIfPresent(String.self, forKey: .providerName)
        anilistId = try? c.decodeIfPresent(Double.self, forKey: .anilistId)
        googleBooksId = try? c.decodeIfPresent(String.self, forKey: .googleBooksId)
        openLibraryId = try? c.decodeIfPresent(String.self, forKey: .openLibraryId)
        wikidataId = try? c.decodeIfPresent(String.self, forKey: .wikidataId)
        isbn = try? c.decodeIfPresent(String.self, forKey: .isbn)
        seriesTitle = try? c.decodeIfPresent(String.self, forKey: .seriesTitle)
        sourceAliases = try? c.decodeIfPresent([String].self, forKey: .sourceAliases)
        verifiedAliases = try? c.decodeIfPresent([String].self, forKey: .verifiedAliases)
        sourceIdentity = try? c.decodeIfPresent(AnyJSON.self, forKey: .sourceIdentity)
        books = try? c.decodeIfPresent([EBook].self, forKey: .books)
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? ""
        altTitle = try? c.decodeIfPresent(String.self, forKey: .altTitle)
        authors = (try? c.decodeIfPresent([String].self, forKey: .authors)) ?? []
        cover = try? c.decodeIfPresent(String.self, forKey: .cover)
        internalCover = try? c.decodeIfPresent(String.self, forKey: .internalCover)
        banner = try? c.decodeIfPresent(String.self, forKey: .banner)
        description = (try? c.decodeIfPresent(String.self, forKey: .description)) ?? ""
        year = try? c.decodeIfPresent(Double.self, forKey: .year)
        publishedAt = try? c.decodeIfPresent(String.self, forKey: .publishedAt)
        status = try? c.decodeIfPresent(String.self, forKey: .status)
        originalLanguage = try? c.decodeIfPresent(String.self, forKey: .originalLanguage)
        genres = (try? c.decodeIfPresent([String].self, forKey: .genres)) ?? []
        chapters = try? c.decodeIfPresent(Double.self, forKey: .chapters)
        volumes = try? c.decodeIfPresent(Double.self, forKey: .volumes)
        score = try? c.decodeIfPresent(Double.self, forKey: .score)
        trendingScore = try? c.decodeIfPresent(Double.self, forKey: .trendingScore)
        siteUrl = try? c.decodeIfPresent(String.self, forKey: .siteUrl)
    }

    /// A poster tile (BPTileView reads id, name and poster).
    var meta: Meta {
        Meta(id: id, type: "ebook", name: title, poster: cover, background: cover, description: description,
             releaseInfo: year.map { String(Int($0)) })
    }

    /// EBookCard's facts line: "{n} books · {year} · {n} vols".
    var cardFacts: String {
        var parts: [String] = []
        if let b = books, !b.isEmpty { parts.append(T("%lld books", b.count)) }
        if let y = year { parts.append(String(Int(y))) }
        if let v = volumes, v > 0 { parts.append(T("%lld vols", Int(v))) }
        return parts.joined(separator: " · ")
    }

    /// The copies a reader can open: the source routes among the book and its duplicates.
    var sourceBooks: [EBook] { (books ?? [self]).filter { $0.source == "source" } }
}

/// lib/ebook/providers.ts EBookChapter. Round-trips unchanged (position saves, bookmarks).
struct EBookChapter: Codable, Identifiable, Hashable {
    var id: String
    var title: String
    var chapter: String?
    var position: Double?
    var volume: String?
    var volumeTitle: String?
    var publishAt: String?
    var legacy: Bool?

    /// harbor-reader chapter label: "Chapter 3" when numbered, else the title.
    var label: String {
        if let c = chapter, !c.isEmpty { return T("Chapter %@", c) }
        return title.isEmpty ? T("Chapter") : title
    }
}

/// lib/ebook/reader-state.ts EBookResume.
struct EBookResume: Codable, Hashable {
    var chapterId: String
    var chapterTitle: String?
    var chapterLabel: String?
    var volumeLabel: String?
    var chapterProgress: Double?
    var bookProgress: Double?
    var chapterIndex: Double?
    var totalChapters: Double?
    var textIdentity: String?
    var updatedAt: Double?

    /// EBookCard: the book's progress, from the chapter's when the book's was never saved.
    var bookFraction: Double {
        let chapter = max(0, min(100, chapterProgress ?? 0))
        if let b = bookProgress { return max(0, min(100, b)) / 100 }
        if let i = chapterIndex, let t = totalChapters, t > 0 { return max(0, min(1, (i + chapter / 100) / t)) }
        return 0
    }
}

/// lib/ebook/reader-state.ts EBookBookmark.
struct EBookBookmark: Codable, Identifiable, Hashable {
    var id: String
    var bookId: String
    var chapterId: String
    var chapterTitle: String
    var chapterLabel: String?
    var volumeLabel: String?
    var line: Int
    var preview: String
    var createdAt: Double?
}

/// lib/ebook/reader-state.ts EBookReaderPrefs: the fields the TV reader uses. The engine merges
/// patches into the stored object, so annotation colours, the reading mode and the rest survive.
struct EBookReaderPrefs: Codable, Equatable {
    var fontSize: Double = 19
    var lineHeight: Double = 1.85
    var width: Double = 768
    var background: String = "dark"
    var brightness: Double = 100
    var font: String = "literary"
    var direction: String = "auto"
    var narrationVoice: String = "en-US-AvaNeural"

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = EBookReaderPrefs()
        fontSize = (try? c.decodeIfPresent(Double.self, forKey: .fontSize)) ?? d.fontSize
        lineHeight = (try? c.decodeIfPresent(Double.self, forKey: .lineHeight)) ?? d.lineHeight
        width = (try? c.decodeIfPresent(Double.self, forKey: .width)) ?? d.width
        background = (try? c.decodeIfPresent(String.self, forKey: .background)) ?? d.background
        brightness = (try? c.decodeIfPresent(Double.self, forKey: .brightness)) ?? d.brightness
        font = (try? c.decodeIfPresent(String.self, forKey: .font)) ?? d.font
        direction = (try? c.decodeIfPresent(String.self, forKey: .direction)) ?? d.direction
        narrationVoice = (try? c.decodeIfPresent(String.self, forKey: .narrationVoice)) ?? d.narrationVoice
    }

    /// harbor-reader `paper`: desk, page, ink and muted colours per background.
    struct Paper { var desk: UInt32; var page: UInt32; var ink: UInt32; var muted: UInt32 }
    var paper: Paper {
        switch background {
        case "dim": return Paper(desk: 0x17130f, page: 0x2d261e, ink: 0xeadbc5, muted: 0xaa9a86)
        case "light": return Paper(desk: 0xc8c0b3, page: 0xf4eddf, ink: 0x29251f, muted: 0x776f64)
        default: return Paper(desk: 0x090a0c, page: 0x17181b, ink: 0xe9e3d8, muted: 0x8f8b84)
        }
    }
}

/// engine ebook.state().
struct EBookState: Decodable, Equatable {
    struct Provider: Decodable, Identifiable, Equatable { var id: String; var name: String }
    struct Source: Decodable, Identifiable, Equatable { var id: String; var name: String; var kind: String; var readable: Bool }
    var providers: [Provider]
    var sources: [Source]
    var hasGutendex: Bool
}

/// engine ebook.continueList() rows.
struct EBookContinue: Decodable, Identifiable, Hashable {
    var ebook: EBook
    var resume: EBookResume
    var id: String { ebook.id }
}

/// Whether the eBook tab shows. Upstream's desktop sidebar always lists eBooks and gates the
/// room behind its setup screen; on the TV the tab stays hidden, like Manga, until it is turned
/// on in Settings. A device choice, kept with the app's own preferences.
enum EBookGate {
    static let key = "harbor.tv.ebooks-tab"
}

/// The room's shared state: sources, the shelf and favourites.
@MainActor
final class EBookStore: ObservableObject {
    static let shared = EBookStore()

    @Published private(set) var state: EBookState?
    @Published private(set) var shelf: [EBook] = []
    @Published private(set) var favorites: [EBook] = []
    /// Bumped whenever a reading position may have changed (harbor:ebook-resume).
    @Published private(set) var resumeVersion = 0

    /// reader-state keys position by the active profile ("default" without one).
    var pid: String { ProfilesStore.shared.active?.id ?? "default" }

    func refresh() async {
        state = try? await HarborEngine.shared.call("ebook.state")
        await refreshLists()
    }

    func refreshLists() async {
        struct Lists: Decodable { var shelf: [EBook]; var favorites: [EBook] }
        if let l: Lists = try? await HarborEngine.shared.call("ebook.library") {
            shelf = l.shelf
            favorites = l.favorites
        }
        resumeVersion += 1
    }

    func addGutendex() async {
        if let s: EBookState = try? await HarborEngine.shared.call("ebook.addGutendex") { state = s }
    }

    func removeSource(_ id: String) async {
        if let s: EBookState = try? await HarborEngine.shared.call("ebook.removeSource", [id]) { state = s }
    }

    /// Returns whether the book is on the shelf afterwards.
    func toggleShelf(_ book: EBook) async -> Bool {
        let on: Bool = (try? await HarborEngine.shared.call("ebook.toggleShelf", [book])) ?? false
        await refreshLists()
        return on
    }

    func toggleFavorite(_ book: EBook) async -> Bool {
        let on: Bool = (try? await HarborEngine.shared.call("ebook.toggleFavorite", [book])) ?? false
        await refreshLists()
        return on
    }

    func statuses(_ ids: [String]) async -> [String: String] {
        guard !ids.isEmpty else { return [:] }
        return (try? await HarborEngine.shared.call("ebook.statuses", [pid, ids])) ?? [:]
    }
}

/// An eBook id opened from outside the room (the anime hero): shown as a full-screen detail.
struct EBookOpen: Identifiable, Hashable {
    var id: String
    /// EBookView readIntent: open straight into the reader (Continue your bookmarks).
    var autoRead = false
}
