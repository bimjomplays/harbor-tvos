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

/// view.ts PlayerSrc.subtitles: a subtitle the resolved stream came with, handed to the player
/// (mpv.ts addSeedSubtitles), which adds it unselected once the file is open.
typealias SeedSubtitle = StreamsModel.Resolved.Link.Sub

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
    /// settings.subtitleAutoUpgrade: a later pass may replace the automatic subtitle (lockedToAuto).
    var autoUpgrade: Bool?
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
    /// mpv.ts addSeedSubtitles: a stream-bundled subtitle, prepared and added (engine TrackIn).
    var autoSelectionEligible: Bool? = nil

    static func from(_ t: MPVPlayerController.Track) -> EngineTrack {
        let eligible: Bool? = t.seeded ? true : nil
        return EngineTrack(id: t.id, type: t.type, lang: t.lang, title: t.title, codec: t.codec, channels: t.channels,
                           external: t.external, forced: t.forced, hearingImpaired: t.hearingImpaired, default: t.isDefault,
                           selected: t.selected, secondary: t.secondary, externalFilename: t.externalFilename,
                           autoSelectionEligible: eligible)
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

    // MARK: the stream's own subtitles (mpv.ts addSeedSubtitles)

    /// A remembered subtitle whose URL is one of the stream's own: the seeds bring it (see restore).
    static func isSeed(_ source: String, in seeds: [SeedSubtitle]) -> Bool {
        let wanted = source.trimmingCharacters(in: .whitespacesAndNewlines)
        return seeds.contains { $0.url.trimmingCharacters(in: .whitespacesAndNewlines) == wanted }
    }

    /// Both URLs on the same scheme, host and port: a home server's subtitle file is fetched with
    /// the stream's own headers (its token) only there.
    private static func sameOrigin(_ a: String, _ b: URL?) -> Bool {
        guard let b, let u = URL(string: a), let ha = u.host?.lowercased(), let hb = b.host?.lowercased() else { return false }
        let sa = (u.scheme ?? "").lowercased()
        let sb = (b.scheme ?? "").lowercased()
        let pa: Int = u.port ?? (sa == "https" ? 443 : 80)
        let pb: Int = b.port ?? (sb == "https" ? 443 : 80)
        return sa == sb && ha == hb && pa == pb
    }

    /// mpv.ts addSeedSubtitles for a file that just opened: each of the stream's subtitles, in
    /// order, through upstream's gate (trustedSource, else isSafeProviderSubtitleUrl: public
    /// http(s) only) and prepareSubtitle (engine subtitles.prepareSeed; the prepared copy is
    /// cached by URL like Find more's), then added UNSELECTED (`sub-add … auto`; the AVPlayer
    /// overlay's list without selecting it), so it shows in the Subtitles dialog and the plan can
    /// pick it. One that fails to download is skipped ("one unavailable subtitle must not block
    /// media startup"). A file already listed (a restore of the same URL) is not added again.
    /// `alive` is asked after every wait: a player that closed or was replaced adds nothing more.
    /// Returns how many were added.
    static func addSeeds(_ seeds: [SeedSubtitle], streamURL: URL?, streamHeaders: [String: String],
                         into c: any PlayerEngineControlling, alive: () -> Bool) async -> Int {
        struct Prepared: Decodable { var text: String; var format: String }
        var added = 0
        var seen: Set<String> = []
        for seed in seeds {
            guard alive() else { return added }
            let source = seed.url.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !source.isEmpty, !seen.contains(source) else { continue }
            seen.insert(source)
            let trusted = seed.trustedSource == true
            let lang = (seed.lang ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let allowed: Bool = (try? await HarborEngine.shared.call("subtitles.seedAllowed", [source, trusted])) ?? false
            guard allowed, alive() else { continue }
            let file: URL
            if let cached = cachedSubtitleFile(source: source) {
                file = cached
            } else {
                let serverHeaders: [String: String]? = trusted && sameOrigin(source, streamURL) ? streamHeaders : nil
                let langArg: String? = lang.isEmpty ? nil : lang
                let args: [any Encodable] = [source, trusted, langArg, serverHeaders]
                let prepared: Prepared? = try? await HarborEngine.shared.call("subtitles.prepareSeed", args)
                guard let prep = prepared, alive() else { continue }
                let out = subtitleFile(source: source, format: prep.format)
                do {
                    try FileManager.default.createDirectory(at: subsDir, withIntermediateDirectories: true)
                    try prep.text.write(to: out, atomically: true, encoding: .utf8)
                } catch {
                    continue
                }
                file = out
            }
            guard alive() else { return added }
            let name = file.lastPathComponent
            let listed = c.tracks().contains { t in
                guard t.type == "sub", t.external, let f = t.externalFilename else { return false }
                return URL(fileURLWithPath: f).lastPathComponent == name
            }
            if listed { continue }
            // noteSubtitleOrigin first: a pick of this track remembers the URL, and the plan below
            // finds a remembered one by it.
            let _: Bool? = try? await HarborEngine.shared.call("player.noteSubtitleSource", [file.path, source])
            guard alive() else { return added }
            // mpv.rs mpv_sub_add: title = the language, else "Subtitle" (upstream passes none), so
            // the dialog reads "<Language> · External subtitle" (subtitleTrackTitle).
            c.addSeedSubtitle(file: file, title: lang.isEmpty ? "Subtitle" : lang, lang: lang)
            added += 1
        }
        return added
    }

    /// use-track-autoload's track effect again, once the seeds are in (seedBatch.commit flags them
    /// autoSelectionEligible and the track list changed). Nothing changes when a subtitle was
    /// chosen since the first plan (`settled`: the viewer's pick, a remembered restore; userPicked),
    /// or when one is on and settings.subtitleAutoUpgrade is off (lockedToAuto). Otherwise the
    /// plan's subtitle is put on: the preferred language's best track (a seed only when no track
    /// of the file's own ranks above it), or the episode's remembered seed. Returns its label.
    static func applySeedPlan(memory: TrackMemory?, into c: any PlayerEngineControlling, settled: Int) async -> String? {
        guard c.subPicks == settled else { return nil }
        let list = c.tracks()
        let planned = await plan(memory: memory, tracks: list)
        guard let plan = planned, c.subPicks == settled else { return nil }
        var label: String? = nil
        var primary: MPVPlayerController.Track? = list.first { $0.type == "sub" && $0.selected }
        if plan.sub == "select", let id = plan.subId,
           let want = list.first(where: { $0.type == "sub" && String($0.id) == id }),
           primary?.id != want.id, primary == nil || plan.autoUpgrade == true {
            c.select(track: want, type: "sub")
            primary = want
            label = want.label
        }
        // (open-items sweep) use-secondary-sub.ts autoPick runs again on every track-list change, so a
        // seed in settings.secondarySubLang becomes the second subtitle as well; only the first plan
        // (the file's own tracks) picked one. Not for kid profiles, as in the first plan.
        if ProfilesStore.shared.active?.kid == nil, let sid = plan.secondaryId,
           let second = list.first(where: { $0.type == "sub" && String($0.id) == sid }),
           second.id != primary?.id, !second.secondary {
            c.setSecondarySub(second)
        }
        return label
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
                           // After an in-place switch the original release's filename no longer applies (review 26);
                           // (player regression pass) the source switcher's pick names its own (subtitleStreamKey
                           // over activeMediaSrc.streamRef), the kid and quality switches none.
                           filename: switchedInPlace ? switchedFilename : streamHints?.filename)
    }
}
