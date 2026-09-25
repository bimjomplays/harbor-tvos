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
        guard let build, genreArt.isEmpty, !SettingsBridge.shared.slice.tmdbKey.isEmpty else { return }
        let p = profile
        for g in build.genres {
            if let metas: LossyArray<Meta> = try? await HarborEngine.shared.call("discoverRoom.genreArtFor", [p.id, p.linked, g.genre]) {
                genreArt[g.genre] = metas.wrappedValue
            }
        }
    }

    func loadVoyage() async {
        if let s: VoyageModel.Snapshot = try? await HarborEngine.shared.call("voyageRoom.state", []) { voyage = s }
    }

    var rows: [BrowseRow] { (build?.rails ?? []).map { BrowseRow(key: $0.key, title: $0.name, metas: $0.metas) } }
}


/// Hands the bundled awards.json (4 MB, copied from upstream at build time) to the engine once.
enum AwardsCatalog {
    private static var installed = false
    @MainActor static func installIfNeeded() async {
        guard !installed else { return }
        if let already: Bool = try? await HarborEngine.shared.call("discoverRoom.awardsInstalled", []), already { installed = true; return }
        guard let url = Bundle.main.url(forResource: "awards", withExtension: "json"),
              let raw = try? String(contentsOf: url, encoding: .utf8) else { return }
        let _: Int? = try? await HarborEngine.shared.call("discoverRoom.installAwards", [raw])
        installed = true
    }
}
