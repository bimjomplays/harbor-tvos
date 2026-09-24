import Foundation

/// Which title a player shows, for lib/player-prefs.ts and lib/subtitles/subtitle-memory.ts
/// (engine/player.ts TrackMemoryKey). Upstream keys the per-show prefs (audio language, subtitle
/// language or off, subtitle delay) by src.meta.id, the series id for an episode and the movie id
/// for a film; the remembered subtitle by id + season + episode; and ties an added subtitle to the
/// release it was found for (subtitleStreamKey, here from the release file name).
struct TrackMemory: Encodable, Equatable {
    var metaId: String
    var season: Int?
    var episode: Int?
    var genres: [String]
    var filename: String?
}

/// engine player.trackPlan: use-track-autoload's choice for a file that just opened.
struct TrackPlan: Decodable {
    struct Restore: Decodable {
        var source: String
        var lang: String?
        var title: String?
    }
    var audioId: String?
    /// "select" (subId), "off", or "none" (no automatic choice).
    var sub: String
    var subId: String?
    /// subtitle-memory: an added subtitle to fetch again and show.
    var restore: Restore?
    /// use-secondary-sub.ts autoPick (settings.secondarySubLang).
    var secondaryId: String?
    var subDelaySec: Double
    var notes: [String]
}

/// A track as the engine reads it (engine/player.ts TrackIn, lib/player/mpv.ts track-list fields).
struct EngineTrack: Encodable {
    var id: Int
    var type: String
    var lang: String?
    var title: String?
    var codec: String?
    var channels: String?
    var external: Bool
    var forced: Bool
    var hearingImpaired: Bool
    var `default`: Bool
    var selected: Bool
    var secondary: Bool
    var externalFilename: String?

    static func from(_ t: MPVPlayerController.Track) -> EngineTrack {
        EngineTrack(id: t.id, type: t.type, lang: t.lang, title: t.title, codec: t.codec, channels: t.channels,
                    external: t.external, forced: t.forced, hearingImpaired: t.hearingImpaired, default: t.isDefault,
                    selected: t.selected, secondary: t.secondary, externalFilename: t.externalFilename)
    }
}

/// The engine side of track choice and memory, shared by MPVPlayerController and NativePlayerController.
@MainActor
enum TrackPlanner {
    /// player.trackPlan for the active profile. nil when the engine is not answering (the
    /// controllers then fall back to their plain language match).
    static func plan(memory: TrackMemory?, tracks: [MPVPlayerController.Track]) async -> TrackPlan? {
        let p = ProfilesStore.shared.active
        let args: [any Encodable] = [p?.id ?? "default", p?.linked ?? true, memory, tracks.map(EngineTrack.from)]
        let plan: TrackPlan? = try? await HarborEngine.shared.call("player.trackPlan", args)
        return plan
    }

    /// Fire-and-forget write (player.remember*, player.noteSubtitleSource).
    static func send(_ path: String, _ args: [any Encodable]) {
        Task {
            let _: Bool? = try? await HarborEngine.shared.call(path, args)
        }
    }

    /// Where Find more writes the subtitles it adds (PlayerSubtitlesPanel.add).
    static var subsDir: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("subs", isDirectory: true)
    }

    /// noteSubtitleOrigin: the local file maps back to the URL it was downloaded from.
    static func noteSource(file: URL, source: String) {
        send("player.noteSubtitleSource", [file.path, source])
    }

    /// use-track-autoload's restore of a remembered added subtitle ("re-adding remembered sub from
    /// source"): downloaded again through the engine (subtitles.prepare), as Find more does, and
    /// shown. A source that is a local file (its URL was not known) is re-added while it is still in
    /// the cache. Returns whether a track was added.
    static func restore(_ r: TrackPlan.Restore, into c: any PlayerEngineControlling) async -> Bool {
        struct Prepared: Decodable { var text: String; var format: String }
        let lang = r.lang ?? ""
        let title = r.title ?? lang
        if r.source.lowercased().hasPrefix("http") {
            let prepared: Prepared? = try? await HarborEngine.shared.call("subtitles.prepare", [r.source])
            guard let prep = prepared else { return false }
            let dir = subsDir
            let safe = String(String(r.source.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "_" }).suffix(80))
            let file = dir.appendingPathComponent("restore_\(safe).\(prep.format)")
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try prep.text.write(to: file, atomically: true, encoding: .utf8)
            } catch {
                return false
            }
            c.addSubtitle(file: file, title: title, lang: lang)
            noteSource(file: file, source: r.source)
            return true
        }
        // mpv lists the full path, AVPlayer the file name; the container path can move between
        // launches, so look for the name in the subtitle folder.
        let file = subsDir.appendingPathComponent(URL(fileURLWithPath: r.source).lastPathComponent)
        guard FileManager.default.fileExists(atPath: file.path) else { return false }
        c.addSubtitle(file: file, title: title, lang: lang)
        return true
    }
}

/// bp-ten-foot.tsx onAudio / onSubtitle / onSubDelay / onAddSubtitle: what the viewer picks is
/// remembered for the show (writePlayerPrefs) and the episode (rememberSubChoice). Called from the
/// player's dialogs only, never for the automatic choice.
extension PlayerEngineControlling {
    func rememberAudio(_ t: MPVPlayerController.Track) {
        guard let m = trackMemory else { return }
        TrackPlanner.send("player.rememberAudio", [m, EngineTrack.from(t)])
    }

    /// nil = subtitles off.
    func rememberSubtitle(_ t: MPVPlayerController.Track?) {
        guard let m = trackMemory else { return }
        let track: EngineTrack? = t.map(EngineTrack.from)
        TrackPlanner.send("player.rememberSubtitle", [m, track])
    }

    /// A subtitle added from Find more: remembered with the URL it came from (rememberedChoiceFromLoad).
    func rememberAddedSubtitle(file: URL, source: String, title: String, lang: String) {
        TrackPlanner.noteSource(file: file, source: source)
        guard let m = trackMemory else { return }
        let track = EngineTrack(id: 0, type: "sub", lang: lang.isEmpty ? nil : lang, title: title, codec: nil, channels: nil,
                                external: true, forced: false, hearingImpaired: false, default: false,
                                selected: true, secondary: false, externalFilename: file.path)
        TrackPlanner.send("player.rememberSubtitle", [m, track, source])
    }

    func rememberSubDelay(_ seconds: Double) {
        guard let m = trackMemory else { return }
        TrackPlanner.send("player.rememberSubDelay", [m, seconds])
    }
}

extension PlayerScreen {
    /// The memory key for this playback: a title's own stream (not a live channel).
    var trackMemory: TrackMemory? {
        guard let context, !isLive else { return nil }
        return TrackMemory(metaId: context.meta.id, season: context.season, episode: context.episode,
                           genres: context.meta.genres ?? [], filename: streamHints?.filename)
    }
}
