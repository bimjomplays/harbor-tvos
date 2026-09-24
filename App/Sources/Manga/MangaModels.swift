import Foundation
import SwiftUI

// Stage 13 manga: the shapes the engine's `manga.*` calls return (engine/manga.ts), decoded
// leniently where upstream's stored data is only loosely validated.

/// lib/manga/model.ts MangaSummary.
struct MangaSummary: Codable, Identifiable, Hashable {
    var id: String
    var title: String
    var altTitle: String?
    var cover: String?
    var year: Double?
    var status: String?
    var description: String?
    var contentRating: String?
    var lastChapter: String?
    var author: String?

    /// manga-detail pills: the status word, capitalised ("Ongoing").
    var statusLabel: String? { status.map { $0.prefix(1).uppercased() + $0.dropFirst() } }
}

/// lib/manga/model.ts MangaChapter. Round-trips through the engine unchanged (reader order,
/// progress), so every field upstream sets is kept.
struct MangaChapter: Codable, Identifiable, Hashable {
    var id: String
    var chapter: String?
    var title: String?
    var volume: String?
    var pages: Double?
    var language: String?
    var group: String?
    var publishAt: String?
    var downloaded: Bool?
    var serverRead: Bool?
    var serverPage: Double?

    /// chapter-list chapterNum: the parsed number, or the position when there is none.
    func number(fallback index: Int) -> Double {
        if let c = chapter, let n = Double(c), n.isFinite { return n }
        return Double(index + 1)
    }

    /// manga-reader chapterLabel.
    var label: String {
        if let c = chapter, !c.isEmpty { return "Chapter \(c)" }
        return (title?.isEmpty == false ? title : nil) ?? "Oneshot"
    }

    /// chapter-list row heading: "Ch. 12" or "Oneshot".
    var shortLabel: String { chapter.map { "Ch. \($0)" } ?? "Oneshot" }

    /// chapter-list displayGroup: the scanlator without an aggregate "My Server ·" prefix.
    var displayGroup: String {
        let g = (group ?? "").trimmingCharacters(in: .whitespaces)
        guard let r = g.range(of: #"^(?:my\s+server)[\s·|:/-]*"#, options: [.regularExpression, .caseInsensitive]) else { return g }
        return String(g[r.upperBound...]).trimmingCharacters(in: .whitespaces)
    }

    /// chapter-list relativeDate.
    var relativeDate: String? {
        guard let s = publishAt, let then = MangaChapter.iso.date(from: s) ?? MangaChapter.isoPlain.date(from: s) else { return nil }
        let secs = Int(Date().timeIntervalSince(then).rounded())
        if secs < 60 { return "just now" }
        let mins = Int((Double(secs) / 60).rounded())
        if mins < 60 { return "\(mins)m ago" }
        let hours = Int((Double(mins) / 60).rounded())
        if hours < 24 { return "\(hours)h ago" }
        let days = Int((Double(hours) / 24).rounded())
        if days < 7 { return "\(days)d ago" }
        return then.formatted(date: .abbreviated, time: .omitted)
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private static let isoPlain = ISO8601DateFormatter()
}

/// The title a reader session belongs to (manga.tsx MangaMeta).
struct MangaRef: Codable, Hashable {
    var id: String
    var title: String
    var cover: String?
}

/// lib/manga-progress.ts MangaProgressEntry. Stored entries are only checked for id and
/// chapterId upstream, so everything else decodes with a default.
struct MangaProgressEntry: Codable, Identifiable, Hashable {
    var id: String
    var title: String
    var cover: String?
    var sourceId: String?
    var chapterId: String
    var chapterNumber: String?
    var chapterLabel: String
    var page: Double
    var totalPages: Double
    var scroll: Double?
    var updatedAt: Double
    var completed: Bool?
    var upNext: Bool?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        chapterId = try c.decode(String.self, forKey: .chapterId)
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? ""
        cover = try? c.decodeIfPresent(String.self, forKey: .cover)
        sourceId = try? c.decodeIfPresent(String.self, forKey: .sourceId)
        chapterNumber = try? c.decodeIfPresent(String.self, forKey: .chapterNumber)
        chapterLabel = (try? c.decodeIfPresent(String.self, forKey: .chapterLabel)) ?? ""
        page = (try? c.decodeIfPresent(Double.self, forKey: .page)) ?? 0
        totalPages = (try? c.decodeIfPresent(Double.self, forKey: .totalPages)) ?? 0
        scroll = try? c.decodeIfPresent(Double.self, forKey: .scroll)
        updatedAt = (try? c.decodeIfPresent(Double.self, forKey: .updatedAt)) ?? 0
        completed = try? c.decodeIfPresent(Bool.self, forKey: .completed)
        upNext = try? c.decodeIfPresent(Bool.self, forKey: .upNext)
    }

    /// manga-detail resumeLabel: "Resume Ch. 12 · p4" / "Resume reading".
    var resumeLabel: String {
        (chapterNumber.map { "Resume Ch. \($0)" } ?? "Resume reading") + (page > 1 ? " · p\(Int(page))" : "")
    }

    /// manga-continue card line: the chapter, and the page while mid-way.
    var cardLine: String {
        let ch = chapterLabel.isEmpty ? (chapterNumber.map { "Chapter \($0)" } ?? "") : chapterLabel
        if upNext == true { return "Up next · \(ch)" }
        return totalPages > 0 ? "\(ch) · \(Int(page))/\(Int(totalPages))" : ch
    }

    var fraction: Double { totalPages > 0 ? min(1, page / totalPages) : 0 }
}

/// lib/manga-favorites.tsx MangaFavEntry.
struct MangaFavEntry: Codable, Identifiable, Hashable {
    var id: String
    var title: String
    var cover: String?
    var addedAt: Double?
}

/// reader-types.ts ReaderPrefs: the fields the TV reader reads. The engine merges patches into
/// upstream's stored object, so the fields the TV never shows (nav position, flip sound…) survive.
struct MangaReaderPrefs: Codable, Equatable {
    var mode: String = "long"
    var fit: String = "width"
    var bg: String = "dark"
    var zoom: Double = 1
    var rtl: Bool = true
    var autoNextChapter: Bool = true

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = (try? c.decodeIfPresent(String.self, forKey: .mode)) ?? "long"
        fit = (try? c.decodeIfPresent(String.self, forKey: .fit)) ?? "width"
        bg = (try? c.decodeIfPresent(String.self, forKey: .bg)) ?? "dark"
        zoom = (try? c.decodeIfPresent(Double.self, forKey: .zoom)) ?? 1
        rtl = (try? c.decodeIfPresent(Bool.self, forKey: .rtl)) ?? true
        autoNextChapter = (try? c.decodeIfPresent(Bool.self, forKey: .autoNextChapter)) ?? true
    }

    /// The TV reads three of upstream's five modes: the 3D book is a two-page spread here and the
    /// horizontal strip turns pages, since a remote has no wheel to drag a strip sideways.
    var tvMode: String {
        switch mode {
        case "paged", "long-h": return "paged"
        case "double", "book": return "double"
        default: return "long"
        }
    }

    /// reader-prefs BG_HEX.
    var background: Color {
        switch bg {
        case "gray": return Color(hex: 0x262626)
        case "light": return Color(hex: 0xf5f5f5)
        default: return Color(hex: 0x0b0b0d)
        }
    }
}

/// A page to show and the headers its host needs (plugins/adapter MangaPage).
struct MangaPage: Decodable, Hashable {
    var url: String
    var headers: [String: String]?
}

/// engine manga.state().
struct MangaState: Decodable, Equatable {
    struct Source: Decodable, Identifiable, Equatable { var id: String; var name: String; var kind: String?; var host: String; var iconUrl: String? }
    struct Server: Decodable, Identifiable, Equatable { var id: String; var name: String; var host: String; var hasAuth: Bool }
    struct Auth: Decodable, Equatable { var base: String; var header: String }
    var hasSource: Bool
    var activeId: String
    var sources: [Source]
    var servers: [Server]
    var auth: [Auth]
}

/// engine manga.detail().
struct MangaDetailResult: Decodable {
    struct Lang: Decodable, Hashable, Identifiable { var code: String; var count: Int; var id: String { code } }
    var detail: MangaSummary?
    var chapters: [MangaChapter]
    var langs: [Lang]
    var defaultLang: String
    var extName: String?
}

/// What the reader opens on.
struct MangaReaderLaunch: Identifiable {
    let id = UUID()
    var manga: MangaRef
    var chapters: [MangaChapter]
    var index: Int
    var startPage: Int?
}

/// lib/manga/model.ts languageName for the codes the chip strip shows.
enum MangaLanguage {
    private static let names: [String: String] = [
        "en": "English", "ja": "Japanese", "es-la": "Spanish (LATAM)", "es": "Spanish", "pt-br": "Portuguese (BR)",
        "pt": "Portuguese", "fr": "French", "de": "German", "ru": "Russian", "id": "Indonesian", "it": "Italian",
        "pl": "Polish", "vi": "Vietnamese", "tr": "Turkish", "ar": "Arabic", "zh": "Chinese (Simp)", "zh-hk": "Chinese (Trad)",
        "ko": "Korean", "th": "Thai", "uk": "Ukrainian", "hu": "Hungarian", "nl": "Dutch", "fil": "Filipino",
    ]
    static func name(_ code: String) -> String {
        if let n = names[code.lowercased()] { return n }
        if let n = Locale(identifier: "en").localizedString(forLanguageCode: code), n.lowercased() != code.lowercased() { return n }
        return code.uppercased()
    }
}

/// Authorization headers for images on the viewer's own manga servers (engine manga.state auth),
/// read by ImageLoader and the reader's page cache from any thread.
final class ImageAuth: @unchecked Sendable {
    static let shared = ImageAuth()
    private let lock = NSLock()
    private var byBase: [(base: String, header: String)] = []

    func set(_ list: [MangaState.Auth]) {
        lock.lock(); defer { lock.unlock() }
        byBase = list.map { ($0.base.hasSuffix("/") ? String($0.base.dropLast()) : $0.base, $0.header) }
    }

    /// auth-registry suwayomiAuthFor: the longest base the URL sits under.
    func header(for url: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        var best: (len: Int, header: String)?
        for (base, header) in byBase where url == base || url.hasPrefix(base + "/") {
            if best == nil || base.count > best!.len { best = (base.count, header) }
        }
        return best?.header
    }
}

/// The room's shared state: sources, Continue Reading and favourites for the active profile.
@MainActor
final class MangaStore: ObservableObject {
    static let shared = MangaStore()

    @Published private(set) var state: MangaState?
    @Published private(set) var progress: [MangaProgressEntry] = []
    @Published private(set) var favorites: [MangaFavEntry] = []

    /// manga-progress / manga-favorites key their data by the active profile ("default" without one).
    var pid: String { ProfilesStore.shared.active?.id ?? "default" }

    func refresh() async {
        if let s: MangaState = try? await HarborEngine.shared.call("manga.state") { apply(s) }
        await refreshLists()
    }

    func refreshLists() async {
        progress = (try? await HarborEngine.shared.call("manga.progress", [pid])) ?? []
        favorites = (try? await HarborEngine.shared.call("manga.favorites", [pid])) ?? []
    }

    private func apply(_ s: MangaState) {
        ImageAuth.shared.set(s.auth)
        state = s
    }

    /// server-form submit. Returns an error line, or nil when the server was added.
    func addServer(name: String, url: String, username: String, password: String) async -> String? {
        struct Added: Decodable { var ok: Bool }
        let user: String? = username.isEmpty ? nil : username, pass: String? = password.isEmpty ? nil : password
        let added: Added? = try? await HarborEngine.shared.call("manga.addServer", [name, url, user, pass])
        await refresh()
        return added?.ok == true ? nil : "Enter the server address, starting with http:// or https://."
    }

    func testServer(url: String, username: String, password: String) async -> (ok: Bool, sources: Int) {
        struct Tested: Decodable { var ok: Bool; var sources: Int }
        let user: String? = username.isEmpty ? nil : username, pass: String? = password.isEmpty ? nil : password
        let t: Tested? = try? await HarborEngine.shared.call("manga.testServer", [url, user, pass])
        return (t?.ok ?? false, t?.sources ?? 0)
    }

    func removeServer(_ id: String) async {
        if let s: MangaState = try? await HarborEngine.shared.call("manga.removeServer", [id]) { apply(s) }
    }

    func setActive(_ id: String) async {
        if let s: MangaState = try? await HarborEngine.shared.call("manga.setActive", [id]) { apply(s) }
    }

    func removeProgress(_ id: String) async {
        progress = (try? await HarborEngine.shared.call("manga.removeProgress", [pid, id])) ?? progress
    }

    /// Returns whether the title is a favourite afterwards.
    func toggleFavorite(_ ref: MangaRef) async -> Bool {
        let on: Bool = (try? await HarborEngine.shared.call("manga.toggleFavorite", [pid, ref])) ?? false
        favorites = (try? await HarborEngine.shared.call("manga.favorites", [pid])) ?? favorites
        return on
    }

    /// views/manga.tsx resume(): the reader launch for a Continue Reading entry, or nil to open the detail.
    func resume(_ entry: MangaProgressEntry) async -> MangaReaderLaunch? {
        struct Resumed: Decodable { var manga: MangaRef; var chapters: [MangaChapter]; var index: Int; var startPage: Int }
        guard let r: Resumed = try? await HarborEngine.shared.call("manga.resume", [entry]) else { return nil }
        await refresh()
        return MangaReaderLaunch(manga: r.manga, chapters: r.chapters, index: r.index, startPage: r.startPage)
    }
}

/// A manga id opened from outside the room (Search, the anime hero): shown as a full-screen detail.
struct MangaOpen: Identifiable, Hashable { var id: String }
