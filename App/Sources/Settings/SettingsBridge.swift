import Foundation
import Combine

/// Upstream's Settings blob, read and written through the engine so the sanitiser and the
/// per-profile / shared key rules stay upstream's. Swift only ever patches a few keys.
@MainActor
final class SettingsBridge: ObservableObject {
    static let shared = SettingsBridge()

    /// The handful of keys the TV app edits directly; everything else rides along untouched.
    struct Slice: Codable, Equatable {
        var tmdbKey: String = ""
        var region: String = "US"
        var homeMode: String = "harbor"
        var uiLanguage: String = "en"
        var animeOnlyInAnimeRoom: Bool = true
    }

    @Published private(set) var slice = Slice()
    @Published private(set) var loaded = false

    private var storageKey: String {
        get async {
            let p = ProfilesStore.shared.active
            let id = p?.id ?? "default"
            return (try? await HarborEngine.shared.call("settings.sourceKeyFor", [id, p?.isPrimary ?? true])) ?? "harbor.settings"
        }
    }

    func load() async {
        let key = await storageKey
        if let s: Slice = try? await HarborEngine.shared.call("settings.load", [key]) {
            slice = s
            loaded = true
        }
    }

    func patch(_ change: [String: AnyJSON]) async throws {
        let key = await storageKey
        let s: Slice = try await HarborEngine.shared.call("settings.patch", [AnyJSON.object(change), key])
        slice = s
    }

    /// Checks a TMDB v3 key by asking TMDB for one page of trending titles.
    /// On failure returns what the engine logged for TMDB, so the screen can say why.
    func verifyTmdb(key: String) async -> (ok: Bool, reason: String?) {
        let before = HarborEngine.shared.recentLogs.count
        do {
            let metas: [Meta] = try await HarborEngine.shared.call("tmdb.trending", [key, "movie", "week", 1])
            if !metas.isEmpty { return (true, nil) }
        } catch {
            return (false, error.localizedDescription)
        }
        let fresh = HarborEngine.shared.recentLogs.dropFirst(before)
        let tmdbLine = fresh.last { $0.contains("[tmdb]") } ?? fresh.last
        return (false, tmdbLine)
    }
}
