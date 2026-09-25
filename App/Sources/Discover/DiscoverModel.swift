import Foundation
import Combine

/// Discover room data through the engine (engine/discover.ts).
@MainActor
final class DiscoverModel: ObservableObject {
    struct Build: Decodable {
        struct Rail: Decodable { var key: String; var name: String; var kicker: String?; @LossyArray var metas: [Meta] }   // (bug pass 2) lossy
        struct Queue: Decodable { var status: String; var total: Int; var posters: [String]; var backdrop: String? }
        struct Genre: Decodable { var genre: String; var from: String; var to: String; var ink: String }
        @LossyArray var rails: [Rail]
        var queue: Queue
        var genres: [Genre]
        /// discover.tsx voyageBannerPool: the Voyages banner shows once it holds three titles.
        var voyagePool: [Meta]?
    }

    @Published private(set) var build: Build?
    @Published private(set) var loading = false
    @Published private(set) var failed: String?
    @Published var spotlight: Meta?
    @Published private(set) var genreArt: [String: [Meta]] = [:]
    private var genreArtLoading = false
    @Published private(set) var awards: Awards?
    @Published private(set) var people: [Person] = []
    /// bp-award-tiles BpAnimeAwardTile: one tile per bundled anime award source.
    @Published private(set) var animeAwards: [AnimeAwardTile] = []
    /// voyage-banner.tsx: the voyage in progress (or none) and the streak (engine/voyage.ts).
    @Published private(set) var voyage: VoyageModel.Snapshot?
    struct AnimeAwardTile: Decodable, Identifiable { var id: String; var name: String; var shortName: String; var wins: Int }

    struct Awards: Decodable {
        struct Summary: Decodable, Identifiable { var type: String; var title: String; var shorthand: String; var tint: String; var wins: Int; var span: String; var id: String { type } }
        struct Overview: Decodable { var bodies: Int; var wins: Int; var span: String }
        var summaries: [Summary]
        var overview: Overview
    }
    struct Person: Decodable, Identifiable { var id: Int; var rank: Int; var name: String; var profilePath: String?; var country: String?
        var portrait: String? { profilePath.map { "https://image.tmdb.org/t/p/w185\($0)" } }
    }

    private var profile: (id: String, linked: Bool) {
        let p = ProfilesStore.shared.active
        return (p?.id ?? "default", p?.linked ?? true)
    }

    func load() async {
        guard build == nil, !loading else { return }
        loading = true; failed = nil
        do {
            let p = profile
            build = try await HarborEngine.shared.call("discoverRoom.buildFor", [p.id, p.linked])
        } catch {
            failed = error.localizedDescription
        }
        loading = false
        await loadVoyage()
        await AwardsCatalog.installIfNeeded()
        awards = try? await HarborEngine.shared.call("discoverRoom.awards", [])
        animeAwards = (try? await HarborEngine.shared.call("discoverRoom.animeAwardSources", [])) ?? []
        people = (try? await HarborEngine.shared.call("discoverRoom.people", [24])) ?? []
    }

    /// Genre tiles fetch their three backdrops only once the Genres band has focus (upstream defers the same way).
    func loadGenreArt() async {
        // (device-flow pass) Every focus move in the band asks; until the first genre answered,
        // genreArt was still empty and each move started another pass over all eighteen genres.
        guard let build, genreArt.isEmpty, !genreArtLoading, !SettingsBridge.shared.slice.tmdbKey.isEmpty else { return }
        genreArtLoading = true
        defer { genreArtLoading = false }
        let p = profile
        for g in build.genres {
            if let metas: LossyArray<Meta> = try? await HarborEngine.shared.call("discoverRoom.genreArtFor", [p.id, p.linked, g.genre]) {
                genreArt[g.genre] = metas.wrappedValue
            }
        }
    }

    /// (device-flow pass) The band reads the deck's order again when the Discovery Queue closes: it
    /// kept counting, fanning and backdropping the titles just skipped or hidden there (upstream's
    /// band redraws off the shared order when the overlay closes).
    func reloadQueue() async {
        guard build != nil else { return }
        let p = profile
        if let q: Build.Queue = try? await HarborEngine.shared.call("discoverRoom.queuePeekFor", [p.id, p.linked]) {
            build?.queue = q
        }
    }

    func loadVoyage() async {
        if let s: VoyageModel.Snapshot = try? await HarborEngine.shared.call("voyageRoom.state", []) { voyage = s }
    }

    /// bp-discover.tsx title={t(rail.name)}: the daily shelves' titles are English source keys.
    var rows: [BrowseRow] { (build?.rails ?? []).map { BrowseRow(key: $0.key, title: T($0.name), metas: $0.metas) } }
}


/// Hands the bundled awards.json (4 MB, copied from upstream at build time) to the engine once.
enum AwardsCatalog {
    private static var installed = false
    /// (perf pass) The install under way. The Home hero asks on every settled focus, and while the first
    /// install was still crossing (read, JSON-encoded, parsed twice by the engine: a second or more on
    /// an Apple TV HD) each of those asks read and sent the 4 MB again. They now wait for that one.
    @MainActor private static var running: Task<Void, Never>?

    @MainActor static func installIfNeeded() async {
        guard !installed else { return }
        if let running { await running.value; return }
        let task = Task { @MainActor in
            if let already: Bool = try? await HarborEngine.shared.call("discoverRoom.awardsInstalled", []), already { installed = true; return }
            // (perf pass) Read off the main thread: 4 MB of UTF-8 held the UI while it was read and validated.
            let raw: String? = await Task.detached(priority: .utility) { () -> String? in
                guard let url = Bundle.main.url(forResource: "awards", withExtension: "json") else { return nil }
                return try? String(contentsOf: url, encoding: .utf8)
            }.value
            guard let raw else { return }
            let _: Int? = try? await HarborEngine.shared.call("discoverRoom.installAwards", [raw])
            installed = true
        }
        running = task
        await task.value
        running = nil
    }
}
