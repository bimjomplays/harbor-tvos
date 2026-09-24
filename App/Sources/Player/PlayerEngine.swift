import Foundation

/// Which engine a PlayerScreen runs (upstream's `engine: "html5" | "mpv"`, use-player-bridge.ts:62).
/// `.native` is AVPlayer, the TV's stand-in for upstream's html5 engine.
enum PlayerEngineKind: String, Decodable {
    case mpv
    case native
}

/// What PlayerScreen and its dialogs drive, whichever engine is underneath (upstream's
/// lib/player/bridge.ts PlayerBridge, cut down to what the TV chrome uses). Track ids are only
/// unique per type, as with mpv. Both conformers are view controllers, so it lives on the main actor.
@MainActor
protocol PlayerEngineControlling: AnyObject {
    var engineKind: PlayerEngineKind { get }
    func togglePause()
    func setPaused(_ paused: Bool)
    func seek(_ seconds: Double)
    func seek(to seconds: Double)
    /// Position and duration in seconds, and whether playback is paused.
    func snapshot() -> (position: Double, duration: Double, paused: Bool)
    func tracks() -> [MPVPlayerController.Track]
    func select(track: MPVPlayerController.Track?, type: String)
    func setSecondarySub(_ track: MPVPlayerController.Track?)
    func setAudioDelay(_ seconds: Double)
    func setMuted(_ muted: Bool)
    func isMuted() -> Bool
    func bufferedSec() -> Double
    func streamFilename() -> String?
    func refreshSubtitleStyle()
    func setSubDelay(_ seconds: Double)
    func setShaders(_ paths: [String])
    func videoWidth() -> Int
    func addSubtitle(file: URL, title: String, lang: String)
}

extension MPVPlayerController: PlayerEngineControlling {
    var engineKind: PlayerEngineKind { .mpv }
}

extension PlayerEngineControlling {
    /// html5 bridge capabilities: no audio offset, no shaders; on the TV the native engine also has
    /// no sideloaded, restyled, shifted or second subtitles (AVPlayer renders the file's own tracks).
    var supportsMpvExtras: Bool { engineKind == .mpv }
}

/// The stream facts the Auto rule reads (engine/player.ts EngineHints), from the picked stream.
struct PlayerStreamHints: Encodable {
    var notWebReady: Bool?
    var container: String?
    var hdrFormat: String?
    var filename: String?
}

/// engine/player.ts engineFor: the profile's playerEngine setting applied to one stream.
enum PlayerEngineChoice {
    struct Choice: Decodable {
        var engine: PlayerEngineKind
        /// settings.playerEngine: "auto" | "mpv" | "html5".
        var want: String
        var reason: String
    }

    private struct Input: Encodable {
        var url: String
        var isLive: Bool
        var notWebReady: Bool?
        var container: String?
        var hdrFormat: String?
        var filename: String?
        var fallbackTried: Bool
    }

    /// Falls back to mpv, the engine that plays everything, when the engine cannot answer.
    @MainActor static func choose(url: URL, isLive: Bool, hints: PlayerStreamHints?, fallbackTried: Bool = false) async -> Choice {
        let p = ProfilesStore.shared.active
        let input = Input(url: url.absoluteString, isLive: isLive, notWebReady: hints?.notWebReady, container: hints?.container,
                          hdrFormat: hints?.hdrFormat, filename: hints?.filename, fallbackTried: fallbackTried)
        do {
            let c: Choice = try await HarborEngine.shared.call("player.engineFor", [p?.id ?? "default", p?.linked ?? true, input])
            return c
        } catch {
            return Choice(engine: .mpv, want: "auto", reason: "default")
        }
    }
}
