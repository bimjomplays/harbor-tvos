import Foundation
import CryptoKit

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

    /// (player tracks pass) The prepared (decoded, unzipped) copy of a subtitle URL: one name per
    /// URL, whatever format it turned out to be. Find more writes it and a remembered subtitle's
    /// restore reads it, so reopening an episode no longer downloads the file again every time
    /// (upstream keeps the picked subtitle in selected-subtitle-cache.ts; provider download
    /// quotas are small). Caches may be purged; the restore then downloads it once more.
    static func subtitleFile(source: String, format: String) -> URL {
        let digest = String(SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined().prefix(20))
        return subsDir.appendingPathComponent("sub_\(digest).\(format)")
    }

    /// The prepared copy of `source` still in the cache, if any.
    static func cachedSubtitleFile(source: String) -> URL? {
        for format in ["srt", "vtt", "ass", "ssa"] {
            let file = subtitleFile(source: source, format: format)
            if let size = try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int, size > 0 { return file }
        }
        return nil
    }

    /// added-subs.ts markAddedSub: the URLs added this session (Find more's "Added" check stays
    /// when the dialog is opened again, and a restored subtitle counts too, as upstream).
    static var addedSources: Set<String> = []

    /// use-track-autoload's restore of a remembered added subtitle ("re-adding remembered sub from
    /// source"): the prepared copy in the cache (subtitleFile), else downloaded again through the
    /// engine (subtitles.prepare) as Find more does, and
    /// shown. A source that is a local file (its URL was not known) is re-added while it is still in
    /// the cache. Returns whether a track was added.
    /// `stillWanted` is asked again once the download is done: a viewer who chose meanwhile keeps
    /// their choice (upstream's subRestoreAddRef check, review 26).
    static func restore(_ r: TrackPlan.Restore, into c: any PlayerEngineControlling, stillWanted: () -> Bool) async -> Bool {
        struct Prepared: Decodable { var text: String; var format: String }
        let lang = r.lang ?? ""
        let title = r.title ?? lang
        if r.source.lowercased().hasPrefix("http") {
            let file: URL
            if let cached = cachedSubtitleFile(source: r.source) {
                file = cached
            } else {
                let prepared: Prepared? = try? await HarborEngine.shared.call("subtitles.prepare", [r.source])
                guard let prep = prepared else { return false }
                file = subtitleFile(source: r.source, format: prep.format)
                do {
                    try FileManager.default.createDirectory(at: subsDir, withIntermediateDirectories: true)
                    try prep.text.write(to: file, atomically: true, encoding: .utf8)
                } catch {
                    return false
                }
            }
            guard stillWanted() else { return false }
            c.addSubtitle(file: file, title: title, lang: lang)
            noteSource(file: file, source: r.source)
            addedSources.insert(r.source)
            return true
        }
        // mpv lists the full path, AVPlayer the file name; the container path can move between
        // launches, so look for the name in the subtitle folder.
        let file = subsDir.appendingPathComponent(URL(fileURLWithPath: r.source).lastPathComponent)
        guard FileManager.default.fileExists(atPath: file.path), stillWanted() else { return false }
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
                           genres: context.meta.genres ?? [],
                           // After an in-place switch the original release's filename no longer applies (review 26).
                           filename: switchedInPlace ? nil : streamHints?.filename)
    }
}
