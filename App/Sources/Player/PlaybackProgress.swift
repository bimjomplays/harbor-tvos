import Foundation

/// What the player needs to know about the title it is playing, and the progress bridge
/// to the engine (engine/player.ts): start position, 4-second saves, final flush.
struct PlaybackContext {
    var meta: Meta
    var season: Int?
    var episode: Int?
    var videoId: String?
    var imdbId: String?
    var imdbVerified: Bool = false

    private var profile: (id: String, authKey: String?) {
        let p = ProfilesStore.shared.active
        return (p?.id ?? "default", p.flatMap { ProfilesStore.shared.stremioSession(for: $0.id)?.authKey })
    }

    struct Start: Decodable { var ms: Double; var fromRemote: Bool; var finished: Bool }
    struct Saved: Decodable { var watched: Bool; var cloud: String }

    @MainActor func startPosition() async -> Double {
        let p = profile
        let s: Start? = try? await HarborEngine.shared.call("player.startPosition",
            [meta, season, episode, p.authKey, imdbId ?? (meta.id.hasPrefix("tt") ? meta.id : nil), imdbVerified || meta.id.hasPrefix("tt"), videoId])
        guard let s, !s.finished else { return 0 }
        return s.ms / 1000
    }

    @MainActor func save(positionSec: Double, durationSec: Double, flush: Bool) async -> Saved? {
        let p = profile
        var input: [String: AnyJSON] = [
            "meta": (try? JSONDecoder().decode(AnyJSON.self, from: JSONEncoder().encode(meta))) ?? .null,
            "positionMs": .number((positionSec * 1000).rounded()),
            "durationMs": .number((durationSec * 1000).rounded()),
            "flush": .bool(flush),
        ]
        if let season { input["season"] = .number(Double(season)) }
        if let episode { input["episode"] = .number(Double(episode)) }
        if let videoId { input["videoId"] = .string(videoId) }
        if let a = p.authKey { input["authKey"] = .string(a) }
        return try? await HarborEngine.shared.call("player.saveProgress", [AnyJSON.object(input)])
    }
}
