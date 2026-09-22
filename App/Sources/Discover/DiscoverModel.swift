import Foundation
import Combine

/// Discover room data through the engine (engine/discover.ts).
@MainActor
final class DiscoverModel: ObservableObject {
    struct Build: Decodable {
        struct Rail: Decodable { var key: String; var name: String; var kicker: String?; var metas: [Meta] }
        struct Queue: Decodable { var status: String; var total: Int; var posters: [String]; var backdrop: String? }
        struct Genre: Decodable { var genre: String; var from: String; var to: String; var ink: String }
        var rails: [Rail]
        var queue: Queue
        var genres: [Genre]
    }

    @Published private(set) var build: Build?
    @Published private(set) var loading = false
    @Published private(set) var failed: String?
    @Published var spotlight: Meta?
    @Published private(set) var genreArt: [String: [Meta]] = [:]

    private var profile: (id: String, linked: Bool) {
        let p = ProfilesStore.shared.active
        return (p?.id ?? "default", p?.isPrimary ?? true)
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
    }

    /// Genre tiles fetch their three backdrops only once the Genres band has focus (upstream defers the same way).
    func loadGenreArt() async {
        guard let build, genreArt.isEmpty, !SettingsBridge.shared.slice.tmdbKey.isEmpty else { return }
        let p = profile
        for g in build.genres {
            if let metas: [Meta] = try? await HarborEngine.shared.call("discoverRoom.genreArtFor", [p.id, p.linked, g.genre]) {
                genreArt[g.genre] = metas
            }
        }
    }

    var rows: [BrowseRow] { (build?.rails ?? []).map { BrowseRow(key: $0.key, title: $0.name, metas: $0.metas) } }
}
