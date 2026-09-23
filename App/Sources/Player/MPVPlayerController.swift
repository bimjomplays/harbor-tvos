import UIKit
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
    }

    var onStatus: ((Status) -> Void)?
    var url: URL?
    /// Extra request headers for the stream (debrid links, addon proxyHeaders).
    var headers: [String: String] = [:]
    var onEnded: (() -> Void)?

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
        if let mpv { mpv_terminate_destroy(mpv) }
        mpv = nil
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
        check(mpv_set_option_string(handle, "target-colorspace-hint", "yes")) // HDR passthrough
        // Upstream's pre-init set (src-tauri/src/mpv.rs:349-416, docs/player-spec.md §2.1).
        check(mpv_set_option_string(handle, "title", "Harbor"))
        check(mpv_set_option_string(handle, "audio-client-name", "Harbor"))
        check(mpv_set_option_string(handle, "input-default-bindings", "no"))
        check(mpv_set_option_string(handle, "osd-level", "0"))
        check(mpv_set_option_string(handle, "sub-codepage", "utf-8"))
        check(mpv_set_option_string(handle, "background-color", "#000000"))
        check(mpv_set_option_string(handle, "user-agent", headers.first { $0.key.lowercased() == "user-agent" }?.value ?? "VLC/3.0.20 LibVLC/3.0.20"))
        // VOD cache defaults (mpv.rs ~905-982, §2.3): 30 s ahead, 128 MiB, reconnecting HTTP.
        check(mpv_set_option_string(handle, "cache", "yes"))
        check(mpv_set_option_string(handle, "cache-pause", "yes"))
        check(mpv_set_option_string(handle, "cache-pause-initial", "no"))
        check(mpv_set_option_string(handle, "cache-secs", "30"))
        check(mpv_set_option_string(handle, "cache-pause-wait", "1"))
        check(mpv_set_option_string(handle, "demuxer-max-bytes", "128MiB"))
        check(mpv_set_option_string(handle, "demuxer-max-back-bytes", "32MiB"))
        check(mpv_set_option_string(handle, "demuxer-readahead-secs", "30"))
        check(mpv_set_option_string(handle, "stream-buffer-size", "16MiB"))
        check(mpv_set_option_string(handle, "network-timeout", "60"))
        check(mpv_set_option_string(handle, "stream-lavf-o", "reconnect=1,reconnect_on_network_error=1,reconnect_on_http_error=429,reconnect_delay_max=10,reconnect_delay_total_max=60"))
        // Subtitle slots start empty so Harbor, not mpv, picks the language (mpv.rs:991-1007).
        check(mpv_set_option_string(handle, "sub-auto", "all"))
        check(mpv_set_option_string(handle, "sid", "no"))
        check(mpv_set_option_string(handle, "secondary-sid", "no"))
        check(mpv_set_option_string(handle, "embeddedfonts", "yes"))
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
        var paused: Int64 = 0
        mpv_get_property(mpv, "pause", MPV_FORMAT_FLAG, &paused)
        var next: Int = paused > 0 ? 0 : 1
        mpv_set_property(mpv, "pause", MPV_FORMAT_FLAG, &next)
    }

    func seek(_ seconds: Double) { command("seek", [String(seconds), "relative"]) }
    func seek(to seconds: Double) { command("seek", [String(seconds), "absolute"]) }

    /// Position and duration in seconds, and whether playback is paused.
    func snapshot() -> (position: Double, duration: Double, paused: Bool) {
        guard let mpv else { return (0, 0, true) }
        var pos = 0.0, dur = 0.0
        var paused: Int64 = 0
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
        for i in 0..<Int(count) {
            let type = string("track-list/\(i)/type") ?? ""
            guard type == "audio" || type == "sub" else { continue }
            let id = Int(string("track-list/\(i)/id") ?? "") ?? 0
            out.append(Track(id: id, type: type, lang: string("track-list/\(i)/lang"), title: string("track-list/\(i)/title"),
                             codec: string("track-list/\(i)/codec"), selected: string("track-list/\(i)/selected") == "yes"))
        }
        return out
    }

    func select(track: Track?, type: String) {
        guard let mpv else { return }
        let prop = type == "sub" ? "sid" : "aid"
        mpv_set_property_string(mpv, prop, track.map { String($0.id) } ?? "no")
    }

    /// `sub-add <file> select <title> <lang>` (mpv.rs:1063 uses "auto"; we select the one the viewer picked).
    func addSubtitle(file: URL, title: String, lang: String) {
        command("sub-add", [file.path, "select", title, lang])
    }

    func setPaused(_ paused: Bool) {
        guard let mpv else { return }
        var v: Int = paused ? 1 : 0
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

    private func poll() {
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
                case MPV_EVENT_END_FILE:
                    if let ef = UnsafePointer<mpv_event_end_file>(OpaquePointer(event.pointee.data)) {
                        if ef.pointee.error < 0 { self.push("end: \(String(cString: mpv_error_string(ef.pointee.error)))") }
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
