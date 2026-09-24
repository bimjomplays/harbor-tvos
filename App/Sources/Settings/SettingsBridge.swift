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
        var simklScrobbleEnabled: Bool? = true
        // Player forks (settings/defaults.ts): resume automatically, ask first, confirm on Back.
        // Instant play (use-bp-stream-play): Play fires the best source; "Sources" forces the list.
        var instantPlay: Bool? = true
        /// use-bp-streams strictMode: "strict" starts narrow; "Search wider" / "Show everything" loosen.
        var streamFilterLevel: String? = "strict"
        var rememberLastStream: Bool? = true
        var seasonSourceLock: Bool? = false
        var resumePlayback: Bool? = true
        var resumePrompt: Bool? = false
        var playerConfirmLeave: Bool? = true
        // Screensaver (settings/defaults.ts:122-126) and the hero feed it draws from.
        var screensaver: Bool? = true
        var screensaverDelayMin: Double? = 5
        var heroFeed: String? = "trending"
        /// bp-settings "Animated backdrop": the drifting poster mosaic behind screens without art.
        var bigPictureMosaic: Bool? = true
        /// bp-settings "Edge margin": a fraction of the screen kept clear on every edge.
        var bigPictureOverscan: Double? = 0
        /// use-bp-sound.ts: the Big Picture sound theme (none/glass/modern/retro/cinematic) and
        /// bp-tv-app.tsx's SFX volume (0-100); played by BPSound.
        var bigPictureSound: String? = "cinematic"
        var sfxVolume: Double? = 50
    }

    /// The Sports tab hides when the viewer declined the notice (bp-top-bar useBpTabGate).
    @Published var sportsDeclined = false

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
