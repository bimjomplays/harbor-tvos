import UIKit
import AVFoundation
import AVKit
import CoreMedia
import Libmpv

/// Minimal libmpv host: gpu-next over MoltenVK into a CAMetalLayer, VideoToolbox decode.
/// Adapted from MPVKit's tvOS demo. Stage 4 replaces this with the real player.
final class MPVPlayerController: UIViewController {
    struct Status {
        var state = "idle"
        var videoParams = ""
        var hwdec = ""
        var fps = ""
        var dropped = ""
        var log: [String] = []
        /// mpv's end-file error (source-error-card.tsx): the stream never opened or died mid-way.
        var error: String?
    }

    var onStatus: ((Status) -> Void)?
    var url: URL?
    /// Extra request headers for the stream (debrid links, addon proxyHeaders).
    var headers: [String: String] = [:]
    var onEnded: (() -> Void)?
    /// Live stream: upstream's live cache set instead of the VOD one (mpv.rs:889-902).
    var isLive = false
    /// Preferred audio / subtitle languages (upstream `preferredAudioLangs` / `preferredSubLangs`, names like "English").
    var preferredAudio: [String] = []
    var preferredSubs: [String] = []
    /// lib/player-prefs.ts / subtitle-memory.ts key for this playback (PlayerScreen); nil for
    /// previews, tiles and channels, which remember nothing.
    var trackMemory: TrackMemory?
    /// view.ts PlayerSrc.subtitles: the stream's own subtitles, added unselected once the file
    /// is open (mpv.ts addSeedSubtitles). Set before the view loads; one batch per controller
    /// (a retry, a switch or the move to mpv makes a new controller with its own).
    var seedSubtitles: [SeedSubtitle] = []
    /// The seed batch has started for this controller (never twice).
    private var seedsStarted = false
    /// File names of the seed tracks added (their track-list rows are flagged `seeded`).
    private var seedFiles: Set<String> = []
    /// Bumped by every audio / subtitle selection (the viewer's or the plan's): a track plan or a
    /// remembered-subtitle restore that lands after the viewer already chose leaves that choice
    /// alone (use-track-autoload's userPicked / subRestoreAddRef, review 26).
    private(set) var audioPicks = 0
    private(set) var subPicks = 0
    /// bp-guide-portal's MultiPlayer (muted, cover): a muted mini preview. It never touches the
    /// display mode or HDR, decodes no audio and keeps a small live cache.
    var preview = false
    /// A Multiview tile (views/multiview/cell.tsx MultiPlayer): like a preview it never touches
    /// the display mode or HDR and keeps a small live cache, but it decodes audio so the tile
    /// that holds the audio focus can be unmuted in place (`setMuted`).
    var tile = false
    /// Start muted (mpv `mute=yes`) while still decoding the audio track; `setMuted(false)`
    /// brings the sound back at once. Separate from `preview`, which drops audio entirely.
    var muted = false
    /// Only the full player hands tvOS display criteria (and resets them); previews and tiles never do.
    private var ownsDisplay: Bool { !preview && !tile }

    private let layer = MPVMetalLayer()
    private var mpv: OpaquePointer?
    private let queue = DispatchQueue(label: "mpv", qos: .userInitiated)
    private var status = Status()
    private var timer: Timer?
    private var tornDown = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        layer.frame = view.bounds
        layer.contentsScale = UIScreen.main.nativeScale
        layer.framebufferOnly = true
        layer.backgroundColor = UIColor.black.cgColor
        view.layer.addSublayer(layer)
        setupMpv()
        if let url { load(url) }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.poll() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layer.frame = view.bounds
    }

    // Teardown is tied to the view truly leaving (MPVPlayerView.dismantleUIViewController, or
    // deinit), not to viewDidDisappear: a fullScreenCover over the player (the Watch Together
    // room, an invite) makes the view disappear without the player going away.

    /// Stop playback for good: the owner (MPVPlayerView's dismantle) is done with this player.
    /// Safe to call more than once; deinit calls it too.
    func stop() {
        timer?.invalidate()
        timer = nil
        DisplayAwake.shared.hold(self, awake: false)
        teardown()
    }

    deinit {
        timer?.invalidate()
        teardown()
    }

    /// Detach the wakeup callback and destroy on the event queue, so a pending readEvents
    /// never touches a handle mid-destroy.
    private func teardown() {
        // Once only: a second reset from a late deinit could clear the criteria the next player set.
        guard !tornDown else { return }
        tornDown = true
        // A preview or tile never set criteria; resetting here could clear the real player's.
        if ownsDisplay { resetDisplayCriteria() }
        // Like NativePlayerController: nothing reports into a view that is gone (review 22).
        onStatus = nil
        onEnded = nil
        let handle = mpv
        mpv = nil
        guard let handle else { return }
        mpv_set_wakeup_callback(handle, nil, nil)
        // (bug pass) `wid` hands mpv the layer unretained and the vo thread keeps drawing into it
        // until the destroy below returns; the controller (and its view) can be released before
        // that, so the layer stays alive until mpv is gone, and is let go on main.
        let layer = self.layer
        queue.async {
            mpv_terminate_destroy(handle)
            DispatchQueue.main.async { withExtendedLifetime(layer) {} }
        }
    }

    /// settings.mpvHwdec as mpv's hwdec (lib/player/mpv-tuning.ts: "on" → hwdec=yes, "off" → hwdec=no,
    /// "auto" → the platform's pick). tvOS has one hardware decoder, VideoToolbox, so "auto" and "on"
    /// both mean videotoolbox and "off" decodes in software. A preview or a Multiview tile keeps
    /// VideoToolbox: four software decodes at once would starve the box.
    static func hwdec(_ setting: String?, ownsDisplay: Bool) -> String {
        guard ownsDisplay, setting == "off" else { return "videotoolbox" }
        return "no"
    }

    private func setupMpv() {
        guard let handle = mpv_create() else { push("mpv_create failed"); return }
        mpv = handle
        check(mpv_request_log_messages(handle, "warn"))
        var wid = Unmanaged.passUnretained(layer).toOpaque()
        check(mpv_set_option(handle, "wid", MPV_FORMAT_INT64, &wid))
        check(mpv_set_option_string(handle, "vo", "gpu-next"))
        check(mpv_set_option_string(handle, "gpu-api", "vulkan"))
        check(mpv_set_option_string(handle, "gpu-context", "moltenvk"))
        check(mpv_set_option_string(handle, "hwdec", Self.hwdec(SettingsBridge.shared.slice.mpvHwdec, ownsDisplay: ownsDisplay)))
        check(mpv_set_option_string(handle, "target-colorspace-hint", ownsDisplay ? "yes" : "no")) // HDR passthrough (never for a preview or tile)
        // Upstream's pre-init set (src-tauri/src/mpv.rs:349-416, docs/player-spec.md §2.1).
        check(mpv_set_option_string(handle, "title", "Harbor"))
        check(mpv_set_option_string(handle, "audio-client-name", "Harbor"))
        check(mpv_set_option_string(handle, "input-default-bindings", "no"))
        check(mpv_set_option_string(handle, "osd-level", "0"))
        check(mpv_set_option_string(handle, "sub-codepage", "utf-8"))
        check(mpv_set_option_string(handle, "background-color", "#000000"))
        check(mpv_set_option_string(handle, "user-agent", headers.first { $0.key.lowercased() == "user-agent" }?.value ?? "VLC/3.0.20 LibVLC/3.0.20"))
        check(mpv_set_option_string(handle, "cache", "yes"))
        check(mpv_set_option_string(handle, "cache-pause", "yes"))
        check(mpv_set_option_string(handle, "cache-pause-initial", "no"))
        check(mpv_set_option_string(handle, "network-timeout", "60"))
        if isLive {
            // Live (mpv.rs:889-902): short cache, reconnecting, no persistent HTTP, quality filters off.
            check(mpv_set_option_string(handle, "cache-secs", "30"))
            check(mpv_set_option_string(handle, "demuxer-max-bytes", "64MiB"))
            check(mpv_set_option_string(handle, "demuxer-max-back-bytes", "16MiB"))
            check(mpv_set_option_string(handle, "demuxer-readahead-secs", "20"))
            check(mpv_set_option_string(handle, "stream-buffer-size", "16MiB"))
            check(mpv_set_option_string(handle, "stream-lavf-o", "reconnect=1,reconnect_delay_max=5,reconnect_on_network_error=1"))
            check(mpv_set_option_string(handle, "demuxer-lavf-o", "http_seekable=0,http_persistent=0"))
            check(mpv_set_option_string(handle, "deband", "no"))
            check(mpv_set_option_string(handle, "interpolation", "no"))
        } else {
            // VOD cache defaults (mpv.rs ~905-982, §2.3): 30 s ahead, 128 MiB, reconnecting HTTP.
            check(mpv_set_option_string(handle, "cache-secs", "30"))
            check(mpv_set_option_string(handle, "cache-pause-wait", "1"))
            check(mpv_set_option_string(handle, "demuxer-max-bytes", "128MiB"))
            check(mpv_set_option_string(handle, "demuxer-max-back-bytes", "32MiB"))
            check(mpv_set_option_string(handle, "demuxer-readahead-secs", "30"))
            check(mpv_set_option_string(handle, "stream-buffer-size", "16MiB"))
            check(mpv_set_option_string(handle, "stream-lavf-o", "reconnect=1,reconnect_on_network_error=1,reconnect_on_http_error=429,reconnect_delay_max=10,reconnect_delay_total_max=60"))
        }
        if tile {
            // Up to four of these decode at once: a short live cache each (multi-player.tsx keeps
            // hls.js/mpegts.js buffers small for the same reason).
            check(mpv_set_option_string(handle, "cache-secs", "8"))
            check(mpv_set_option_string(handle, "demuxer-max-bytes", "32MiB"))
            check(mpv_set_option_string(handle, "demuxer-max-back-bytes", "4MiB"))
            check(mpv_set_option_string(handle, "demuxer-readahead-secs", "8"))
            check(mpv_set_option_string(handle, "stream-buffer-size", "4MiB"))
        }
        if muted && !preview { check(mpv_set_option_string(handle, "mute", "yes")) }
        if preview {
            check(mpv_set_option_string(handle, "mute", "yes"))
            check(mpv_set_option_string(handle, "aid", "no"))
            check(mpv_set_option_string(handle, "cache-secs", "4"))
            check(mpv_set_option_string(handle, "demuxer-max-bytes", "16MiB"))
            check(mpv_set_option_string(handle, "demuxer-max-back-bytes", "1MiB"))
            check(mpv_set_option_string(handle, "demuxer-readahead-secs", "4"))
        }
        // Subtitle slots start empty so Harbor, not mpv, picks the language (mpv.rs:991-1007).
        check(mpv_set_option_string(handle, "sub-auto", "all"))
        check(mpv_set_option_string(handle, "sid", "no"))
        check(mpv_set_option_string(handle, "secondary-sid", "no"))
        check(mpv_set_option_string(handle, "embeddedfonts", "yes"))
        applySubtitleStyle(handle)
        // (player parity pass) mpv.ts applyAudioFilters, which use-track-autoload runs as each file's
        // tracks arrive (settings.audioNormalize, settings.audioProfile). A setting changed mid-file
        // takes effect with the next file there too, so it is set once per player, before init.
        // Previews decode no audio and Multiview tiles are not upstream's mpv bridge: neither gets it.
        if ownsDisplay {
            let slice = SettingsBridge.shared.slice
            let af: String = Self.audioFilter(normalize: slice.audioNormalize ?? false, profile: slice.audioProfile)
            if !af.isEmpty { check(mpv_set_option_string(handle, "af", af)) }
            // (player parity pass 2) use-video-fill.ts apply(): the synced crop mode for each new
            // stream (zoom starts at 0 per stream). Fit is mpv's own default, so nothing is set for it.
            let crop: PictureFill.Mode = PictureFill.mode(slice.cropMode)
            if crop.id != "fit" {
                check(mpv_set_option_string(handle, "panscan", crop.panscan > 0 ? "1" : "0"))
                check(mpv_set_option_string(handle, "video-aspect-override", crop.aspect))
                check(mpv_set_option_string(handle, "keepaspect", crop.stretch ? "no" : "yes"))
            }
            // use-live-picture-eq.ts: the desktop's picture look (mpvTweaks brightness, contrast,
            // saturation, gamma, sharpen).
            for eq in PictureFill.pictureEq(slice.mpvTweaks) {
                check(mpv_set_option_string(handle, eq.key, eq.value))
            }
        }
        check(mpv_set_option_string(handle, "subs-fallback", "yes"))
        check(mpv_set_option_string(handle, "keep-open", "yes"))
        check(mpv_initialize(handle))
        mpv_set_wakeup_callback(handle, { ctx in
            let me = Unmanaged<MPVPlayerController>.fromOpaque(ctx!).takeUnretainedValue()
            me.readEvents()
        }, Unmanaged.passUnretained(self).toOpaque())
        push("mpv \(string("mpv-version") ?? "?")")
    }

    func load(_ url: URL) {
        displayCriteriaApplied = false
        fileLoaded = false
        endedSent = false
        if let mpv {
            // http-header-fields is a comma list: escape like mpv.rs mpv_header_field().
            let rest = headers.filter { $0.key.lowercased() != "user-agent" }
            if !rest.isEmpty {
                let fields = rest.map { "\($0.key): \($0.value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: ",", with: "\\,"))" }.joined(separator: ",")
                check(mpv_set_option_string(mpv, "http-header-fields", fields))
            }
        }
        command("loadfile", [url.absoluteString, "replace"])
        status.state = "loading"
        report()
    }

    func togglePause() {
        guard let mpv else { return }
        var paused: Int32 = 0
        mpv_get_property(mpv, "pause", MPV_FORMAT_FLAG, &paused)
        var next: Int32 = paused > 0 ? 0 : 1
        mpv_set_property(mpv, "pause", MPV_FORMAT_FLAG, &next)
    }

    func seek(_ seconds: Double) { command("seek", [String(seconds), "relative"]) }
    func seek(to seconds: Double) {
        // (bug pass) mpv refuses `seek` until the file is open, so "Pick up where you left off"
        // pressed while a slow source still connects was lost and playback began at 0: hold the
        // spot as the start FILE_LOADED applies.
        guard fileLoaded else { startAtSeconds = seconds; return }
        command("seek", [String(seconds), "absolute"])
    }
    /// (bug pass) FILE_LOADED has arrived for the current `loadfile` (main thread only).
    private var fileLoaded = false
    /// (bug pass) onEnded went out for this file (the poll's eof-reached and END_FILE never both fire it).
    private var endedSent = false

    /// Position and duration in seconds, and whether playback is paused.
    func snapshot() -> (position: Double, duration: Double, paused: Bool) {
        guard let mpv else { return (0, 0, true) }
        var pos = 0.0, dur = 0.0
        var paused: Int32 = 0
        mpv_get_property(mpv, "time-pos", MPV_FORMAT_DOUBLE, &pos)
        mpv_get_property(mpv, "duration", MPV_FORMAT_DOUBLE, &dur)
        mpv_get_property(mpv, "pause", MPV_FORMAT_FLAG, &paused)
        return (pos, dur, paused > 0)
    }

    /// Where playback should start, applied once the file is loaded.
    var startAtSeconds: Double = 0

    struct Track: Identifiable, Equatable {
        var id: Int
        var type: String   // "audio" | "sub"
        var lang: String?
        var title: String?
        var codec: String?
        var selected: Bool
        // lib/player/mpv.ts track-list mapping: the flags the Big Picture panels filter and badge on.
        var external = false
        var forced = false
        var hearingImpaired = false
        var isDefault = false
        /// Shown as the second subtitle (mpv secondary-sid); `selected` then stays false.
        var secondary = false
        var externalFilename: String?
        var channels: String?
        /// One of the stream's own subtitles, prepared and added (engine autoSelectionEligible).
        var seeded = false
        var label: String {
            // lib/subtitles/language.ts languageName: upstream's English names (as PlayerPanelParts
            // does), not the Apple TV's own language, which leaked into an otherwise Harbor-language panel.
            let base = [title, lang.map { TrackLanguage.englishName($0) ?? $0 }].compactMap { $0 }.joined(separator: " · ")
            return base.isEmpty ? "\(T(type == "sub" ? "Subtitle" : "Audio")) \(id)" : base
        }
    }

    /// mpv's track-list for audio and subtitle tracks.
    func tracks() -> [Track] {
        guard let mpv else { return [] }
        var count: Int64 = 0
        mpv_get_property(mpv, "track-list/count", MPV_FORMAT_INT64, &count)
        var out: [Track] = []
        let secondarySid = string("secondary-sid")
        for i in 0..<Int(count) {
            let type = string("track-list/\(i)/type") ?? ""
            guard type == "audio" || type == "sub" else { continue }
            let id = Int(string("track-list/\(i)/id") ?? "") ?? 0
            let isSelected = string("track-list/\(i)/selected") == "yes"
            // mpv.ts: a selected sub whose main-selection is 1 (or, on older mpv, the secondary-sid) is the 2nd one.
            let mainSelection = string("track-list/\(i)/main-selection")
            let isSecondary = type == "sub" && isSelected && (mainSelection == "1" || (mainSelection == nil && secondarySid == String(id)))
            var t = Track(id: id, type: type, lang: string("track-list/\(i)/lang"), title: string("track-list/\(i)/title"),
                          codec: string("track-list/\(i)/codec"), selected: isSelected && !isSecondary)
            t.external = string("track-list/\(i)/external") == "yes"
            t.forced = string("track-list/\(i)/forced") == "yes"
            t.hearingImpaired = string("track-list/\(i)/hearing-impaired") == "yes"
            t.isDefault = string("track-list/\(i)/default") == "yes"
            t.secondary = isSecondary
            t.externalFilename = string("track-list/\(i)/external-filename")
            t.channels = string("track-list/\(i)/demux-channels")
            if t.external, let f = t.externalFilename, !seedFiles.isEmpty {
                t.seeded = seedFiles.contains(URL(fileURLWithPath: f).lastPathComponent)
            }
            out.append(t)
        }
        return out
    }

    /// bp-player-subtitles "2nd" (lib/player/secondary-sub.ts): mpv's secondary-sid, or off.
    func setSecondarySub(_ track: Track?) {
        guard let mpv else { return }
        subPicks += 1
        check(mpv_set_property_string(mpv, "secondary-sid", track.map { String($0.id) } ?? "no"))
    }

    /// bp-player-sources BpAudioLane "Sync Offset": mpv audio-delay in seconds.
    func setAudioDelay(_ seconds: Double) { command("set", ["audio-delay", String(format: "%.2f", seconds)]) }
    /// mpv.ts setRate: `speed` (pitch-corrected by mpv's default audio-pitch-correction).
    func setRate(_ rate: Double) { command("set", ["speed", String(format: "%.2f", rate)]) }

    /// bp-player-rail mute chip: mpv's `mute` property.
    func setMuted(_ muted: Bool) {
        guard let mpv else { return }
        check(mpv_set_property_string(mpv, "mute", muted ? "yes" : "no"))
    }

    func isMuted() -> Bool { string("mute") == "yes" }

    /// bp-player-scrub buffered fill: the last timestamp the demuxer holds (demuxer-cache-time).
    func bufferedSec() -> Double { Double(string("demuxer-cache-time") ?? "") ?? 0 }

    /// The stream's file name (mpv `filename`), the release evidence for the subtitle best match.
    func streamFilename() -> String? { string("filename") }

    /// bp-subtitle-tune BpSubtitleLook: re-apply the viewer's subtitle style to the running player.
    func refreshSubtitleStyle() {
        guard let mpv else { return }
        applySubtitleStyle(mpv, live: true)
    }

    func select(track: Track?, type: String) {
        guard let mpv else { return }
        if type == "sub" { subPicks += 1 } else { audioPicks += 1 }
        let prop = type == "sub" ? "sid" : "aid"
        mpv_set_property_string(mpv, prop, track.map { String($0.id) } ?? "no")
        if type == "sub" {
            sdhTrack = track.map { (forced: $0.forced, lang: $0.lang) }
            applySdhFilter()
            assShown = Self.isAss(codec: track?.codec, title: track?.title)
            applyAssPlacement()
        }
    }

    /// (player parity pass) use-player-media.ts assNativeActive: the shown subtitle is a styled
    /// (ASS/SSA) track, which mpv always draws itself on the TV. sub-style.ts keys the ASS margins
    /// and sub-pos off it.
    private var assShown = false

    /// lib/player/sub-format.ts isAssTrack: an ASS/SSA codec, or a title ending in .ass / .ssa.
    static func isAss(codec: String?, title: String?) -> Bool {
        let c: String = (codec ?? "").uppercased()
        if c.contains("ASS") || c.contains("SSA") || c.contains("SUBSTATION") || c.contains("SUB STATION") { return true }
        let t: String = (title ?? "").lowercased()
        return t.hasSuffix(".ass") || t.hasSuffix(".ssa")
    }

    /// sub-style.ts: sub-ass-force-margins / sub-use-margins follow `assNativeActive && override !== "no"`,
    /// and sub-pos moves with subMarginY unless an ASS track keeps its own placement.
    private func applyAssPlacement() {
        guard let mpv else { return }
        let s = SettingsBridge.shared.slice
        let placement = Self.assPlacement(mode: Self.assOverride(s.subAssOverride), assShown: assShown, marginY: s.subMarginY ?? 12)
        check(mpv_set_property_string(mpv, "sub-ass-force-margins", placement.margins))
        check(mpv_set_property_string(mpv, "sub-use-margins", placement.margins))
        check(mpv_set_property_string(mpv, "sub-pos", placement.pos))
    }

    /// sub-style.ts assMargins / reposition / sub-pos.
    static func assPlacement(mode: String, assShown: Bool, marginY: Double) -> (margins: String, pos: String) {
        let margins: String = (assShown && mode != "no") ? "yes" : "no"
        let reposition: Bool = !assShown || mode != "no"
        let y: Double = min(max(marginY, 0), 100)
        let pos: Int = reposition ? Int(min(max(100 - y, 0), 100)) : 100
        return (margins, String(pos))
    }

    /// settings.subAssOverride as mpv's sub-ass-override (settings/types.ts: no | yes | force | scale | strip).
    static func assOverride(_ value: String?) -> String {
        let v: String = value ?? "no"
        return ["no", "yes", "force", "scale", "strip"].contains(v) ? v : "no"
    }

    /// sub-style.ts mpvFontFor(subFontFamily): upstream's faces are Inter, Vazirmatn, Segoe UI,
    /// Times New Roman and Fredoka, which the TV does not carry. Each preset gets the TV's nearest
    /// face: Switzer (the app's stand-in for Inter, bundled), Sentient (the bundled serif), and
    /// tvOS's own Arabic, system and rounded faces. A custom font is a file on the desktop that
    /// never reaches the TV, so it reads as the default. A face libass cannot find falls back to
    /// the system font per glyph.
    nonisolated static func subFont(_ family: String?) -> String {
        switch family ?? "inter" {
        case "arabic": return "Geeza Pro"
        case "system": return "Helvetica Neue"
        case "serif": return "Sentient"
        case "rounded": return "Arial Rounded MT Bold"
        default: return "Switzer"
        }
    }

    /// lib/player/mpv.ts AUDIO_PROFILE_AF.
    static let audioProfileFilters: [String: String] = [
        "bass": "lavfi=[bass=g=7:f=110:w=0.6]",
        "voice": "lavfi=[equalizer=f=300:t=q:w=1:g=-3,equalizer=f=2800:t=q:w=1:g=5]",
        "bass-reduce": "lavfi=[bass=g=-8:f=110:w=0.6]",
        "night": "lavfi=[acompressor=ratio=3:threshold=-20dB:attack=20:release=300:makeup=4dB]",
    ]

    /// mpv.ts applyAudioFilters: the normalizer, then the profile, then a limiter whenever either
    /// is on; "" (no filters) otherwise.
    static func audioFilter(normalize: Bool, profile: String?) -> String {
        var parts: [String] = []
        if normalize { parts.append("dynaudnorm=f=500:g=31:p=0.9:m=4:b=1") }
        if let p = profile, let af = audioProfileFilters[p] { parts.append(af) }
        if !parts.isEmpty { parts.append("lavfi=[alimiter=limit=0.97]") }
        return parts.joined(separator: ",")
    }

    /// (player tracks pass) sub-style.ts sub-filter-sdh: settings.subHideSdh, but only while the
    /// shown subtitle allows it (use-player-media.ts sdhFilterAllowed: not a forced track, and a
    /// Latin-script language, sdh-filter.ts sdhSafeForLanguage). The option was never set, so
    /// "Hide SDH" (synced from desktop) stripped [DOOR SLAMS] on AVPlayer but not on mpv.
    private var sdhTrack: (forced: Bool, lang: String?)?
    private static let sdhUnsafeLangs: Set<String> = [
        "ar", "arb", "he", "heb", "iw", "fa", "per", "fas", "ur", "urd",
        "ru", "rus", "uk", "ukr", "bg", "bul", "sr", "srp", "mk", "mkd", "be", "bel",
        "el", "gre", "ell", "hy", "hye", "ka", "kat", "th", "tha", "km", "khm", "lo", "lao",
        "ja", "jpn", "zh", "zho", "chi", "yue", "ko", "kor",
        "hi", "hin", "bn", "ben", "ta", "tam", "te", "tel", "ml", "mal", "kn", "kan",
        "mr", "mar", "gu", "guj", "pa", "pan", "si", "sin", "am", "amh", "yi", "yid",
    ]
    private var sdhFilterOn: Bool {
        guard SettingsBridge.shared.slice.subHideSdh ?? false else { return false }
        guard let t = sdhTrack else { return true }
        if t.forced { return false }
        let code = (t.lang ?? "").trimmingCharacters(in: .whitespaces).lowercased()
            .split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? ""
        return !Self.sdhUnsafeLangs.contains(code)
    }
    private func applySdhFilter() {
        guard let mpv else { return }
        check(mpv_set_property_string(mpv, "sub-filter-sdh", sdhFilterOn ? "yes" : "no"))
    }

    /// `sub-add <file> select <title> <lang>` (mpv.rs:1063 uses "auto"; we select the one the viewer picked).
    /// Replace the post-processing shader chain (`glsl-shaders`, colon-separated like mpv.rs).
    /// bp-subtitle-tune "Manual offset": mpv sub-delay in seconds (+ late, − early).
    func setSubDelay(_ seconds: Double) { command("set", ["sub-delay", String(format: "%.2f", seconds)]) }
    func currentSubDelay() -> Double { Double(string("sub-delay") ?? "") ?? 0 }
    /// bp-subtitle-tune "Size": sub-scale multiplier.
    func setSubScale(_ scale: Double) { command("set", ["sub-scale", String(format: "%.2f", min(max(scale, 0.4), 4))]) }

    func setShaders(_ paths: [String]) {
        guard let mpv else { return }
        queue.async { [weak self] in
            guard let self, let mpv = self.mpv else { return }
            let joined = paths.joined(separator: ":")
            self.check(mpv_set_property_string(mpv, "glsl-shaders", joined))
            self.push(paths.isEmpty ? "shaders cleared" : "shaders: \(paths.count) files")
        }
        _ = mpv
    }

    /// Source width in pixels once the file is loaded (0 before).
    func videoWidth() -> Int {
        Int(string("video-params/w") ?? "") ?? 0
    }

    /// lib/player/mpv.ts chapter-list → snap.chapters: title ("" when none) and start, sorted,
    /// negative or unreadable starts dropped. Upstream's skip-intro turns "Opening" / "Ending" /
    /// "Recap" chapters into skip segments (chapters.ts).
    func chapters() -> [PlayerChapter] {
        guard let mpv else { return [] }
        var count: Int64 = 0
        mpv_get_property(mpv, "chapter-list/count", MPV_FORMAT_INT64, &count)
        guard count > 0 else { return [] }
        var out: [PlayerChapter] = []
        for i in 0..<Int(min(count, 500)) {
            guard let start = Double(string("chapter-list/\(i)/time") ?? ""), start.isFinite, start >= 0 else { continue }
            out.append(PlayerChapter(title: string("chapter-list/\(i)/title") ?? "", startSec: start))
        }
        return out.sorted { $0.startSec < $1.startSec }
    }

    func addSubtitle(file: URL, title: String, lang: String) {
        subPicks += 1
        command("sub-add", [file.path, "select", title, lang])
        sdhTrack = (forced: false, lang: lang.isEmpty ? nil : lang)
        applySdhFilter()
        assShown = Self.isAss(codec: nil, title: file.lastPathComponent)
        applyAssPlacement()
    }

    /// mpv.rs mpv_sub_add(select: false): `sub-add <file> auto <title> <lang>` lists the track
    /// without showing it ('auto' = don't select; the sid slot keeps what Harbor chose).
    func addSeedSubtitle(file: URL, title: String, lang: String) {
        guard mpv != nil else { return }
        seedFiles.insert(file.lastPathComponent)
        command("sub-add", [file.path, "auto", title, lang])
    }

    /// mpv.ts load → `void addSeedSubtitles(src.subtitles, activeLoadId)`, after the first track
    /// plan (so its audio / subtitle choice never waits on a download), then the plan once more
    /// with the seeds in (TrackPlanner.applySeedPlan).
    private func addSeeds() {
        guard !preview, !tile, !seedsStarted, !seedSubtitles.isEmpty else { return }
        seedsStarted = true
        let seeds = seedSubtitles
        let memory = trackMemory
        let streamURL = url
        let streamHeaders = headers
        Task { [weak self] in
            guard let self, !self.tornDown else { return }
            let settled = self.subPicks
            let added = await TrackPlanner.addSeeds(seeds, streamURL: streamURL, streamHeaders: streamHeaders, into: self,
                                                    alive: { !self.tornDown && self.mpv != nil })
            guard added > 0, !self.tornDown else { return }
            self.push("subs: \(added) stream subtitle\(added == 1 ? "" : "s") added")
            if let label = await TrackPlanner.applySeedPlan(memory: memory, into: self, settled: settled) {
                self.push("subs: \(label) (stream subtitle)")
            }
        }
    }

    /// src/lib/player/sub-style.ts applySubStyle → mpv sub-* options, from the viewer's settings.
    /// `live`: the player is running, so the values go through mpv_set_property_string.
    private func applySubtitleStyle(_ handle: OpaquePointer, live: Bool = false) {
        func set(_ name: String, _ value: String) {
            check(live ? mpv_set_property_string(handle, name, value) : mpv_set_option_string(handle, name, value))
        }
        let s = SettingsBridge.shared.slice
        let opacity = s.subOpacity ?? 1
        func mpvColor(_ hex: String?, _ alpha: Double) -> String {
            var h = (hex ?? "#FFFFFF").trimmingCharacters(in: .whitespaces); if h.hasPrefix("#") { h.removeFirst() }
            guard h.count == 6 else { return "#FFFFFFFF" }
            let a = String(format: "%02X", Int((min(max(alpha, 0), 1) * 255).rounded()))
            return "#\(a)\(h.uppercased())"
        }
        let style = s.subStyle ?? "shadow"
        let fontsDir = Bundle.main.bundleURL.path
        if !live { set("sub-fonts-dir", fontsDir) }
        set("sub-font", Self.subFont(s.subFontFamily))
        set("sub-font-size", "32")
        set("sub-scale", String(min(max((s.subFontSize ?? 32) / 32, 0.4), 4)))
        set("sub-color", mpvColor(s.subFontColor, opacity))
        set("sub-border-color", mpvColor(s.subBorderColor, opacity))
        set("sub-border-size", String(s.subBorderSize ?? 0))
        set("sub-back-color", style == "box" ? mpvColor(s.subBoxColor, (s.subBoxOpacity ?? 0.6) * opacity) : "#00000000")
        set("sub-shadow-color", mpvColor("#000000", opacity))
        set("sub-shadow-offset", style == "shadow" ? "1.4" : "0")
        set("sub-margin-y", String(Int(min(max(s.subMarginY ?? 12, 0), 100))))
        set("sub-align-x", s.subAlignX ?? "center")
        set("sub-spacing", String(s.subLineSpacing ?? 0))
        set("sub-bold", (s.subBold ?? false) ? "yes" : "no")
        // (player parity pass) sub-style.ts sub-ass-override (settings.subAssOverride), the ASS
        // margins and sub-pos, which an ASS track keeps as its own under "no".
        let assMode: String = Self.assOverride(s.subAssOverride)
        let placement = Self.assPlacement(mode: assMode, assShown: assShown, marginY: s.subMarginY ?? 12)
        set("sub-ass-override", assMode)
        set("sub-ass-force-margins", placement.margins)
        set("sub-use-margins", placement.margins)
        set("sub-pos", placement.pos)
        set("sub-filter-sdh", sdhFilterOn ? "yes" : "no")
        set("sub-filter-sdh-harder", "no")
    }

    /// use-track-autoload.ts's track choice, made by the engine (player.trackPlan): the preferred
    /// languages, the show's remembered audio / subtitle language and delay (lib/player-prefs.ts),
    /// this episode's remembered subtitle (subtitle-memory.ts), trackBlockWords, subtitlesOffByDefault,
    /// preferEmbeddedSubs, forcedSubsWhenNativeAudio and secondarySubLang. Subtitle slots start
    /// empty (`sid=no`, mpv.rs:991-1007), so a plan with no subtitle choice leaves them off.
    private func applyTrackPlan() {
        guard !preview, mpv != nil else { return }
        let list = tracks()
        let memory = trackMemory
        let picks = (audioPicks, subPicks)
        Task { [weak self] in
            let plan = await TrackPlanner.plan(memory: memory, tracks: list)
            guard let self, !self.tornDown, self.mpv != nil else { return }
            // What the viewer picked while the plan was on its way stays (review 26).
            let userAudio = self.audioPicks != picks.0, userSub = self.subPicks != picks.1
            guard let plan else {
                if !userAudio && !userSub { self.applyTrackPreferences() }
                self.addSeeds()
                return
            }
            self.apply(plan, to: list, audio: !userAudio, subs: !userSub)
            self.addSeeds()
        }
    }

    private func apply(_ plan: TrackPlan, to list: [Track], audio: Bool, subs: Bool) {
        func find(_ id: String?, _ type: String) -> Track? {
            guard let id else { return nil }
            return list.first { $0.type == type && String($0.id) == id }
        }
        if audio, let a = find(plan.audioId, "audio") { select(track: a, type: "audio") }
        plan.notes.forEach { push($0) }
        guard subs else { return }
        if plan.sub == "off" {
            select(track: nil, type: "sub")
        } else if plan.sub == "select", let s = find(plan.subId, "sub") {
            select(track: s, type: "sub")
        }
        // Multiview tiles and kid profiles get no automatic second subtitle (the kid toggle can't clear it).
        if !tile, ProfilesStore.shared.active?.kid == nil, let s = find(plan.secondaryId, "sub") { setSecondarySub(s) }
        if plan.subDelaySec != 0 { setSubDelay(plan.subDelaySec) }
        // A remembered subtitle that is one of the stream's own comes with the seeds (addSeeds),
        // and the plan after them selects it: restoring it here too would list it twice.
        if let r = plan.restore, !TrackPlanner.isSeed(r.source, in: seedSubtitles) {
            let settled = subPicks
            Task { [weak self] in
                guard let self, !self.tornDown else { return }
                if await TrackPlanner.restore(r, into: self, stillWanted: { self.subPicks == settled }) { self.push("subs: remembered subtitle added") }
            }
        }
    }

    /// Fallback when the engine does not answer: the first audio track matching the preferred
    /// languages (in order); subtitles stay off unless an embedded track matches a preferred
    /// language (player-spec §2.9).
    /// ISO 639-2/B and /T codes ffmpeg tags tracks with → 639-1 (upstream subsync/audio_tracks.rs LANG_ALIAS).
    private static let langAlias: [String: String] = TrackLanguage.alias

    private func applyTrackPreferences() {
        guard !preview else { return }
        let list = tracks()
        func matches(_ t: Track, _ names: [String]) -> Int? {
            guard let raw = t.lang?.lowercased() else { return nil }
            let lang = Self.langAlias[raw] ?? raw
            let english = Locale(identifier: "en").localizedString(forLanguageCode: lang)?.lowercased()
            for (i, name) in names.enumerated() {
                let n = name.lowercased()
                if english == n || lang == n || raw == n || (n.count == 2 && lang == n) { return i }
                // Names like "Portuguese (Brazil)" match on their first word.
                if let first = n.split(separator: " ").first, english == String(first) { return i }
            }
            return nil
        }
        if !preferredAudio.isEmpty {
            let audio = list.filter { $0.type == "audio" }
            if let best = audio.compactMap({ t in matches(t, preferredAudio).map { ($0, t) } }).min(by: { $0.0 < $1.0 }) {
                select(track: best.1, type: "audio")
                push("audio: \(best.1.label)")
            }
        }
        if !preferredSubs.isEmpty {
            let subs = list.filter { $0.type == "sub" }
            if let best = subs.compactMap({ t in matches(t, preferredSubs).map { ($0, t) } }).min(by: { $0.0 < $1.0 }) {
                select(track: best.1, type: "sub")
                push("subs: \(best.1.label)")
            }
        }
    }

    /// (P11) snapshots.ts captureMpvFrame (mpv.rs mpv_screenshot_data_url): the frame on screen,
    /// through `screenshot-raw` on this player's serial mpv queue, so a close right after it (the
    /// exit grab runs just before the player is torn down) destroys the handle only once the
    /// screenshot has returned. Previews and Multiview tiles take none.
    func grabFrame(fullQuality: Bool, done: @escaping (Data?) -> Void) {
        guard let handle = mpv, !tornDown, ownsDisplay, fileLoaded else {
            done(nil)
            return
        }
        queue.async {
            let data: Data? = FrameGrab.mpvFrame(handle, fullQuality: fullQuality)
            DispatchQueue.main.async { done(data) }
        }
    }

    func setPaused(_ paused: Bool) {
        guard let mpv else { return }
        var v: Int32 = paused ? 1 : 0
        mpv_set_property(mpv, "pause", MPV_FORMAT_FLAG, &v)
    }

    private func command(_ name: String, _ args: [String]) {
        guard let mpv else { return }
        var cargs: [UnsafePointer<CChar>?] = ([name] + args).map { UnsafePointer(strdup($0)) }
        cargs.append(nil)
        defer { cargs.forEach { free(UnsafeMutablePointer(mutating: $0)) } }
        check(mpv_command(mpv, &cargs))
    }

    private func string(_ name: String) -> String? {
        guard let mpv, let c = mpv_get_property_string(mpv, name) else { return nil }
        defer { mpv_free(c) }
        return String(cString: c)
    }

    /// Ask tvOS to match the display to the stream (takes effect only when the viewer has
    /// Settings → Video and Audio → Match Content on). Upstream relies on mpv for this on desktop;
    /// on Apple TV the OS owns the HDMI mode, so we hand it fps + dynamic range once known.
    private var displayCriteriaApplied = false
    /// Where the criteria went, so the reset clears that window's (not another player's).
    private weak var displayWindow: UIWindow?
    private func applyDisplayCriteria() {
        guard ownsDisplay, !displayCriteriaApplied, let fpsText = string("container-fps"), let fps = Double(fpsText), fps > 1,
              let w = Int32(string("video-params/w") ?? ""), let h = Int32(string("video-params/h") ?? ""), w > 0, h > 0 else { return }
        displayCriteriaApplied = true
        // AVDisplayCriteria(refreshRate:formatDescription:) is the public tvOS initializer; the
        // format description's colour extensions tell tvOS whether the content is HDR10 / HLG.
        let gamma = string("video-params/gamma") ?? ""
        let primaries = string("video-params/primaries") ?? ""
        let codec = (string("video-codec") ?? "").lowercased()
        var ext: [CFString: Any] = [:]
        if primaries == "bt.2020" {
            ext[kCMFormatDescriptionExtension_ColorPrimaries] = kCMFormatDescriptionColorPrimaries_ITU_R_2020
            ext[kCMFormatDescriptionExtension_YCbCrMatrix] = kCMFormatDescriptionYCbCrMatrix_ITU_R_2020
        } else {
            ext[kCMFormatDescriptionExtension_ColorPrimaries] = kCMFormatDescriptionColorPrimaries_ITU_R_709_2
            ext[kCMFormatDescriptionExtension_YCbCrMatrix] = kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2
        }
        switch gamma {
        case "pq": ext[kCMFormatDescriptionExtension_TransferFunction] = kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ
        case "hlg": ext[kCMFormatDescriptionExtension_TransferFunction] = kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG
        default: ext[kCMFormatDescriptionExtension_TransferFunction] = kCMFormatDescriptionTransferFunction_ITU_R_709_2
        }
        let codecType: CMVideoCodecType = codec.contains("hevc") || codec.contains("h265") ? kCMVideoCodecType_HEVC
            : codec.contains("av1") ? kCMVideoCodecType_AV1 : kCMVideoCodecType_H264
        var desc: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault, codecType: codecType, width: w, height: h,
                                                    extensions: ext as CFDictionary, formatDescriptionOut: &desc)
        guard status == noErr, let desc else { push("display: format description failed (\(status))"); return }
        let criteria = AVDisplayCriteria(refreshRate: Float(fps), formatDescription: desc)
        // The window this player is in: the app's own, or the PiP browse layer's (PiPBrowse) for a
        // film opened from there.
        let own = viewIfLoaded?.window
        displayWindow = own
        DispatchQueue.main.async {
            guard let window = own ?? HarborOverlayWindow.mainWindow else { return }
            window.avDisplayManager.preferredDisplayCriteria = criteria
        }
        push("display: \(fps) fps \(gamma) \(primaries)")
    }

    private func resetDisplayCriteria() {
        let own = displayWindow
        DispatchQueue.main.async {
            guard let window = own ?? HarborOverlayWindow.mainWindow else { return }
            window.avDisplayManager.preferredDisplayCriteria = nil
        }
    }

    private func poll() {
        applyDisplayCriteria()
        status.videoParams = [string("video-params/w"), string("video-params/h"), string("video-codec"), string("video-params/primaries"), string("video-params/gamma")]
            .compactMap { $0 }.joined(separator: " ")
        status.hwdec = string("hwdec-current") ?? ""
        status.fps = "\(string("estimated-vf-fps") ?? "?") fps · \(string("time-pos") ?? "0")s / \(string("duration") ?? "?")s"
        status.dropped = "dropped \(string("frame-drop-count") ?? "0") · cache \(string("demuxer-cache-duration") ?? "?")s"
        if let core = string("core-idle"), let eof = string("eof-reached"), string("time-pos") != nil {
            status.state = eof == "yes" ? "ended" : (core == "yes" ? "buffering/paused" : "playing")
            // (bug pass) keep-open=yes holds a finished file paused on its last frame and mpv never
            // sends END_FILE(eof) for it, so onEnded (next episode, watched-at-end save) never fired.
            // Upstream reads eof-reached as "ended" (lib/player/mpv.ts) and acts on a natural end
            // only (playback-end.ts isNaturalEnd: no duration, or at least 85 % through). A live
            // channel is not a title's end: PlayerScreen reloads it off the "ended" state (bug pass 2).
            if eof == "yes", !isLive, !endedSent {
                let s = snapshot()
                if PlaybackEnd.isNatural(position: s.position, duration: s.duration) { sendEnded() }
            }
        }
        // (device-flow pass 12) use-power-inhibit.ts: the screen stays on while this plays. A guide
        // preview does not hold it (it plays for as long as the ring rests on a guide cell).
        DisplayAwake.shared.hold(self, awake: !preview && !tornDown && status.state == "playing")
        report()
    }

    /// (bug pass) onEnded once per file, from the poll's eof-reached or an END_FILE(eof).
    private func sendEnded() {
        guard !tornDown, !endedSent else { return }
        endedSent = true
        onEnded?()
    }

    private func push(_ line: String) {
        // (bug pass) `status` is main-thread state (poll, load, the END_FILE error hop), but
        // readEvents and setShaders push from the mpv queue: an unsynchronised append racing the
        // poll's writes can corrupt the log array. Everything lands on main.
        guard Thread.isMainThread else { DispatchQueue.main.async { self.push(line) }; return }
        status.log.append(line)
        if status.log.count > 8 { status.log.removeFirst() }
    }

    private func report() {
        // (bug pass) Read `status` on main only (see push).
        guard Thread.isMainThread else { DispatchQueue.main.async { self.report() }; return }
        let s = status
        DispatchQueue.main.async { self.onStatus?(s) }
    }

    private func readEvents() {
        queue.async { [weak self] in
            guard let self else { return }
            while let mpv = self.mpv {
                guard let event = mpv_wait_event(mpv, 0), event.pointee.event_id != MPV_EVENT_NONE else { break }
                switch event.pointee.event_id {
                case MPV_EVENT_LOG_MESSAGE:
                    if let msg = UnsafePointer<mpv_event_log_message>(OpaquePointer(event.pointee.data)) {
                        let text = String(cString: msg.pointee.text).trimmingCharacters(in: .whitespacesAndNewlines)
                        self.push("[\(String(cString: msg.pointee.prefix))] \(text)")
                    }
                case MPV_EVENT_FILE_LOADED:
                    self.push("file loaded")
                    // (bug pass) On main, like every other read of startAtSeconds / fileLoaded, so a
                    // seek the viewer made while the file was opening lands here instead of being refused.
                    DispatchQueue.main.async {
                        guard !self.tornDown else { return }
                        self.fileLoaded = true
                        if self.startAtSeconds > 1 { self.command("seek", [String(self.startAtSeconds), "absolute"]) }
                        self.startAtSeconds = 0
                        self.applyTrackPlan()
                    }
                case MPV_EVENT_END_FILE:
                    if let ef = UnsafePointer<mpv_event_end_file>(OpaquePointer(event.pointee.data)) {
                        if ef.pointee.error < 0 {
                            let why = String(cString: mpv_error_string(ef.pointee.error))
                            self.push("end: \(why)")
                            DispatchQueue.main.async { self.status.state = "error"; self.status.error = why }
                        }
                        if ef.pointee.reason == MPV_END_FILE_REASON_EOF { DispatchQueue.main.async { self.sendEnded() } }
                    }
                default:
                    break
                }
            }
            self.report()
        }
    }

    private func check(_ status: CInt) {
        if status < 0 { push("mpv error: \(String(cString: mpv_error_string(status)))") }
    }
}

/// (open-items sweep) language.ts languageName: normalizeLang maps 639-2 codes (ISO_3_TO_1) before the
/// name lookup. The bibliographic codes ffmpeg tags tracks with ("ger", "fre", "dut", "chi") have no
/// name of their own here, so the audio dialog said "GER" where upstream says German. Outside the
/// controller so track labels (nonisolated) can read it.
enum TrackLanguage {
    /// ISO 639-2/B and /T codes ffmpeg tags tracks with → 639-1 (upstream subsync/audio_tracks.rs LANG_ALIAS).
    static let alias: [String: String] = [
        "eng": "en", "jpn": "ja", "ger": "de", "deu": "de", "fre": "fr", "fra": "fr", "spa": "es", "ita": "it", "por": "pt",
        "dut": "nl", "nld": "nl", "chi": "zh", "zho": "zh", "gre": "el", "ell": "el", "rum": "ro", "ron": "ro", "slo": "sk", "slk": "sk",
        "alb": "sq", "sqi": "sq", "arm": "hy", "hye": "hy", "baq": "eu", "eus": "eu", "bur": "my", "mya": "my", "geo": "ka", "kat": "ka",
        "mac": "mk", "mkd": "mk", "mao": "mi", "mri": "mi", "may": "ms", "msa": "ms", "tib": "bo", "bod": "bo", "wel": "cy", "cym": "cy",
        "ice": "is", "isl": "is", "kor": "ko", "rus": "ru", "pol": "pl", "tur": "tr", "ara": "ar", "hin": "hi", "swe": "sv", "nor": "no",
        "dan": "da", "fin": "fi", "cze": "cs", "ces": "cs", "hun": "hu", "ind": "id", "tha": "th", "vie": "vi", "ukr": "uk", "heb": "he",
        "per": "fa", "fas": "fa", "cat": "ca", "hrv": "hr", "srp": "sr", "bul": "bg", "tam": "ta", "tel": "te", "ben": "bn", "urd": "ur",
    ]

    /// The English name of a track language code, nil when it has none.
    static func englishName(_ code: String) -> String? {
        let raw: String = code.trimmingCharacters(in: .whitespaces).lowercased()
        let lang: String = alias[raw] ?? raw
        return Locale(identifier: "en").localizedString(forLanguageCode: lang)
    }
}

/// (device-flow pass 12) use-power-inhibit.ts (power_inhibit while the snapshot is "playing"): the
/// tvOS screen saver and sleep wait while an mpv player plays. AVPlayer does this by itself
/// (preventsDisplaySleepDuringVideoPlayback); mpv draws into a Metal layer, which tvOS does not
/// count as video, so a live channel or four Multiview tiles went to the screen saver after its
/// idle delay. Held per player (weakly), so a player that goes away lets go with it; a paused or
/// buffering player does not hold it, as upstream.
@MainActor
final class DisplayAwake {
    static let shared = DisplayAwake()
    private let holders = NSHashTable<AnyObject>.weakObjects()

    func hold(_ holder: AnyObject, awake: Bool) {
        if awake { holders.add(holder) } else { holders.remove(holder) }
        let on: Bool = !holders.allObjects.isEmpty
        if UIApplication.shared.isIdleTimerDisabled != on { UIApplication.shared.isIdleTimerDisabled = on }
    }
}
