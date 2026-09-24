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
    /// bp-guide-portal's MultiPlayer (muted, cover): a muted mini preview. It never touches the
    /// display mode or HDR, decodes no audio and keeps a small live cache.
    var preview = false

    private let layer = MPVMetalLayer()
    private var mpv: OpaquePointer?
    private let queue = DispatchQueue(label: "mpv", qos: .userInitiated)
    private var status = Status()
    private var timer: Timer?

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

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        timer?.invalidate()
        teardown()
    }

    deinit { teardown() }

    /// Detach the wakeup callback and destroy on the event queue, so a pending readEvents
    /// never touches a handle mid-destroy.
    private func teardown() {
        // A preview never set criteria; resetting here could clear the real player's.
        if !preview { resetDisplayCriteria() }
        let handle = mpv
        mpv = nil
        guard let handle else { return }
        mpv_set_wakeup_callback(handle, nil, nil)
        queue.async { mpv_terminate_destroy(handle) }
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
        check(mpv_set_option_string(handle, "hwdec", "videotoolbox"))
        check(mpv_set_option_string(handle, "target-colorspace-hint", preview ? "no" : "yes")) // HDR passthrough (never for a preview)
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
    func seek(to seconds: Double) { command("seek", [String(seconds), "absolute"]) }

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
        var label: String {
            let base = [title, lang.map { Locale.current.localizedString(forLanguageCode: $0) ?? $0 }].compactMap { $0 }.joined(separator: " · ")
            return base.isEmpty ? "\(type == "sub" ? "Subtitle" : "Audio") \(id)" : base
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
            out.append(t)
        }
        return out
    }

    /// bp-player-subtitles "2nd" (lib/player/secondary-sub.ts): mpv's secondary-sid, or off.
    func setSecondarySub(_ track: Track?) {
        guard let mpv else { return }
        check(mpv_set_property_string(mpv, "secondary-sid", track.map { String($0.id) } ?? "no"))
    }

    /// bp-player-sources BpAudioLane "Sync Offset": mpv audio-delay in seconds.
    func setAudioDelay(_ seconds: Double) { command("set", ["audio-delay", String(format: "%.2f", seconds)]) }

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
        let prop = type == "sub" ? "sid" : "aid"
        mpv_set_property_string(mpv, prop, track.map { String($0.id) } ?? "no")
    }

    /// `sub-add <file> select <title> <lang>` (mpv.rs:1063 uses "auto"; we select the one the viewer picked).
    /// Replace the post-processing shader chain (`glsl-shaders`, colon-separated like mpv.rs).
    /// bp-subtitle-tune "Manual offset": mpv sub-delay in seconds (+ late, − early).
    func setSubDelay(_ seconds: Double) { command("set", ["sub-delay", String(format: "%.2f", seconds)]) }
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

    func addSubtitle(file: URL, title: String, lang: String) {
        command("sub-add", [file.path, "select", title, lang])
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
        set("sub-font", "Switzer")
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
        set("sub-pos", String(Int(min(max(100 - (s.subMarginY ?? 12), 0), 100))))
    }

    /// Pick the first audio track matching the preferred languages (in order); subtitles stay
    /// off unless an embedded track matches a preferred language (upstream keeps `sid=no` until
    /// its own choice; mpv.rs:991-1007, player-spec §2.9).
    /// ISO 639-2/B and /T codes ffmpeg tags tracks with → 639-1 (upstream subsync/audio_tracks.rs LANG_ALIAS).
    private static let langAlias: [String: String] = [
        "eng": "en", "jpn": "ja", "ger": "de", "deu": "de", "fre": "fr", "fra": "fr", "spa": "es", "ita": "it", "por": "pt",
        "dut": "nl", "nld": "nl", "chi": "zh", "zho": "zh", "gre": "el", "ell": "el", "rum": "ro", "ron": "ro", "slo": "sk", "slk": "sk",
        "alb": "sq", "sqi": "sq", "arm": "hy", "hye": "hy", "baq": "eu", "eus": "eu", "bur": "my", "mya": "my", "geo": "ka", "kat": "ka",
        "mac": "mk", "mkd": "mk", "mao": "mi", "mri": "mi", "may": "ms", "msa": "ms", "tib": "bo", "bod": "bo", "wel": "cy", "cym": "cy",
        "ice": "is", "isl": "is", "kor": "ko", "rus": "ru", "pol": "pl", "tur": "tr", "ara": "ar", "hin": "hi", "swe": "sv", "nor": "no",
        "dan": "da", "fin": "fi", "cze": "cs", "ces": "cs", "hun": "hu", "ind": "id", "tha": "th", "vie": "vi", "ukr": "uk", "heb": "he",
        "per": "fa", "fas": "fa", "cat": "ca", "hrv": "hr", "srp": "sr", "bul": "bg", "tam": "ta", "tel": "te", "ben": "bn", "urd": "ur",
    ]

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
    private func applyDisplayCriteria() {
        guard !preview, !displayCriteriaApplied, let fpsText = string("container-fps"), let fps = Double(fpsText), fps > 1,
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
        DispatchQueue.main.async {
            guard let window = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first else { return }
            window.avDisplayManager.preferredDisplayCriteria = criteria
        }
        push("display: \(fps) fps \(gamma) \(primaries)")
    }

    private func resetDisplayCriteria() {
        DispatchQueue.main.async {
            guard let window = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first else { return }
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
        }
        report()
    }

    private func push(_ line: String) {
        status.log.append(line)
        if status.log.count > 8 { status.log.removeFirst() }
    }

    private func report() {
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
                    if self.startAtSeconds > 1 { self.seek(to: self.startAtSeconds); self.startAtSeconds = 0 }
                    self.applyTrackPreferences()
                case MPV_EVENT_END_FILE:
                    if let ef = UnsafePointer<mpv_event_end_file>(OpaquePointer(event.pointee.data)) {
                        if ef.pointee.error < 0 {
                            let why = String(cString: mpv_error_string(ef.pointee.error))
                            self.push("end: \(why)")
                            DispatchQueue.main.async { self.status.state = "error"; self.status.error = why }
                        }
                        if ef.pointee.reason == MPV_END_FILE_REASON_EOF { DispatchQueue.main.async { self.onEnded?() } }
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
