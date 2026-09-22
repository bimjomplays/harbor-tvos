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
                case MPV_EVENT_END_FILE:
                    if let ef = UnsafePointer<mpv_event_end_file>(OpaquePointer(event.pointee.data)), ef.pointee.error < 0 {
                        self.push("end: \(String(cString: mpv_error_string(ef.pointee.error)))")
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
