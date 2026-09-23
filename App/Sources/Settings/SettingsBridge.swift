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
        var preferredSubLangs: [String] = ["English"]
        var preferredAudioLangs: [String]? = nil
        // Subtitle style (settings/defaults.ts:265-293), mapped to mpv in MPVPlayerController.
        var subFontSize: Double? = 32
        var subFontColor: String? = "#FFFFFF"
        var subBorderColor: String? = "#000000"
        var subBorderSize: Double? = 0
        var subMarginY: Double? = 12
        var subAlignX: String? = "center"
        var subStyle: String? = "shadow"
        var subBold: Bool? = false
        var subBoxOpacity: Double? = 0.6
        var subBoxColor: String? = "#000000"
        var subOpacity: Double? = 1
        var subLineSpacing: Double? = 0
        // Anime4K (settings/defaults.ts:235-261), applied by the player through the engine's gates.
        var playerAnime4k: Bool? = false
        var playerAnime4kAnimeOnly: Bool? = true
        var playerAnime4kIndicator: Bool? = true
        var playerAnime4kMode: String? = "A"
        var playerAnime4kTier: String? = "hq"
        var playerAnime4kOverride: String? = "auto"
    }

    @Published private(set) var slice = Slice()
    @Published private(set) var loaded = false

    private var storageKey: String {
        get async {
            let p = ProfilesStore.shared.active
            let id = p?.id ?? "default"
            return (try? await HarborEngine.shared.call("settings.sourceKeyFor", [id, p?.linked ?? true])) ?? "harbor.settings"
        }
    }

    private var unsubscribe: (() -> Void)?

    func load() async {
        if unsubscribe == nil {
            // Profile sync applied a settings section (home rows, services…): re-read the slice.
            unsubscribe = HarborEngine.shared.onEvent { [weak self] type, _ in
                guard type == "harbor:settings-updated" else { return }
                Task { await self?.load() }
            }
        }
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
