import UIKit
import SwiftUI
import AVFoundation
import AVKit
import CoreMedia

/// The second engine (PLAN decision 4): AVPlayer, the TV's stand-in for upstream's html5 engine
/// (src/lib/player/html5/bridge.ts). It sits under Harbor's own chrome like mpv does: an
/// AVPlayerViewController with its transport hidden, kept only because it applies the stream's
/// display criteria (Match Content: frame rate, HDR10 / Dolby Vision) by itself.
/// Reports through the same Status shape as MPVPlayerController so PlayerScreen reads one thing.
final class NativePlayerController: UIViewController {
    var onStatus: ((MPVPlayerController.Status) -> Void)?
    var url: URL?
    /// Request headers (debrid links, addon proxyHeaders), sent through AVURLAsset.
    var headers: [String: String] = [:]
    var onEnded: (() -> Void)?
    /// use-player-bridge.ts autoFallback: a decode/codec failure, or audio that cannot be decoded
    /// (html5 bridge probeAudio → snap.noAudio). "codec" | "noAudio"; PlayerScreen may retry on mpv.
    var onUnsupported: ((String) -> Void)?
    var isLive = false
    var preferredAudio: [String] = []
    var preferredSubs: [String] = []
    /// Where playback should start, applied once the item is ready.
    var startAtSeconds: Double = 0

    private let player = AVPlayer()
    private let host = AVPlayerViewController()
    private var status = MPVPlayerController.Status()
    private var observations: [NSKeyValueObservation] = []
    private var notes: [NSObjectProtocol] = []
    private var timer: Timer?
    private var wantsPlay = true
    private var readyHandled = false
    private var unsupportedSent = false
    private var tornDown = false
    private var audioGroup: AVMediaSelectionGroup?
    private var legibleGroup: AVMediaSelectionGroup?
    private var codecName = ""

    // Sideloaded subtitles (html5/bridge.ts subTracks / activeSubId / secondarySubId / subDelaySec):
    // AVPlayer cannot take an external file into its own renderer, so, like upstream's html5
    // engine, the cues are parsed (engine `subtitles.cues`) and drawn by NativeSubtitleOverlay.
    /// External tracks get ids from here up, clear of the legible options (1…n) they sit beside.
    static let externalSubBase = 1000
    private struct ExternalSub { var id: Int; var title: String; var lang: String; var format: String; var file: URL; var cues: [SubtitleCue] }
    private var externalSubs: [ExternalSub] = []
    private var nextExternalId = NativePlayerController.externalSubBase
    private var activeExternal: Int?
    private var secondaryExternal: Int?
    private var subDelaySec: Double = 0
    private var lastCueKey = ""
    private let subtitleState = NativeSubtitleState()
    private var cueObserver: Any?
    private var subtitleHost: UIViewController?

    // The file's own subtitles (the legible AVMediaSelectionGroup) come out through an
    // AVPlayerItemLegibleOutput with AVPlayer's renderer suppressed, so NativeSubtitleOverlay draws
    // them too and Sync and Look apply to every track, as on mpv. The output reports each change of
    // the showing text with the item time it takes effect; the changes are kept as a timeline and
    // read at `currentTime - delay`, like the sideloaded cues.
    private struct EmbeddedChange { var time: Double; var text: String }
    private var subtitleOutput: AVPlayerItemLegibleOutput?
    private var embeddedTimeline: [EmbeddedChange] = []
    /// How far ahead the output reports: enough for a negative (early) offset to show on time.
    private static let legibleLead: Double = 5

    // Picture in Picture (bridge.ts requestPiP / exitPiP, capabilities().pictureInPicture). The
    // AVPlayerViewController above stays for display matching; PiP lifts a plain AVPlayerLayer of
    // the same player, attached only while PiP is starting or on.
    private let pipLayerView = NativePlayerLayerView()
    private var pip: AVPictureInPictureController?
    private var pipPossibleObservation: NSKeyValueObservation?
    private var pipAttempt = 0
    private var pipStarting = false
    /// PiP is on (didStart … willStop).
    private(set) var isPictureInPictureActive = false
    /// usePipMode's pip://entered / pip://exited: true when PiP starts, false once it is stopping.
    var onPictureInPicture: ((Bool) -> Void)?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        // Harbor's chrome is drawn over this; the system transport and gestures stay off.
        host.player = player
        host.showsPlaybackControls = false
        host.appliesPreferredDisplayCriteriaAutomatically = true
        // PiP goes through NativePlayerController's own AVPictureInPictureController (below): the
        // hidden transport has no PiP button, and AVPlayerViewController has no call to start one.
        host.allowsPictureInPicturePlayback = false
        host.view.backgroundColor = .black
        host.view.isUserInteractionEnabled = false
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
        // The PiP source: the same picture, drawn only while PiP starts (see startPictureInPicture).
        pipLayerView.frame = view.bounds
        pipLayerView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        pipLayerView.backgroundColor = .clear
        pipLayerView.isUserInteractionEnabled = false
        pipLayerView.playerLayer.videoGravity = .resizeAspect
        view.addSubview(pipLayerView)
        // subtitle-overlay.tsx over the picture, under PlayerScreen's chrome; never focusable.
        let overlay = UIHostingController(rootView: NativeSubtitleOverlay(state: subtitleState))
        overlay.view.backgroundColor = .clear
        overlay.view.isUserInteractionEnabled = false
        overlay.safeAreaRegions = []
        addChild(overlay)
        overlay.view.frame = view.bounds
        overlay.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(overlay.view)
        overlay.didMove(toParent: self)
        subtitleHost = overlay
        // tickCues runs on requestAnimationFrame upstream; 20 Hz keeps a cue within 50 ms of its time.
        cueObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 20), queue: .main) { [weak self] _ in
            self?.tickCues()
        }
        // Harbor, not the system, picks the audio and subtitle options (mpv.rs:991-1007: sid=no).
        player.appliesMediaSelectionCriteriaAutomatically = false
        if let url { load(url) }
        // The main run loop fires it, as MPVPlayerController's poll timer.
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.poll() }
    }

    // Teardown is tied to the view truly leaving (NativePlayerView.dismantleUIViewController, or
    // deinit), not to viewDidDisappear: a fullScreenCover over the player must not stop it.

    /// Stop playback for good: the owner is done with this player. Safe to call more than once.
    func stop() { teardown() }

    deinit { teardown() }

    private func teardown() {
        guard !tornDown else { return }
        tornDown = true
        timer?.invalidate()
        timer = nil
        if let cueObserver { player.removeTimeObserver(cueObserver) }
        cueObserver = nil
        // Leaving the player ends PiP with it (use-player-exit.ts awaits exitPiP first).
        pipPossibleObservation?.invalidate()
        pipPossibleObservation = nil
        if isPictureInPictureActive || pipStarting { pip?.stopPictureInPicture() }
        pip?.delegate = nil
        pip = nil
        pipLayerView.playerLayer.player = nil
        isPictureInPictureActive = false
        pipStarting = false
        onPictureInPicture = nil
        subtitleOutput?.setDelegate(nil, queue: nil)
        subtitleOutput = nil
        observations.forEach { $0.invalidate() }
        observations = []
        notes.forEach { NotificationCenter.default.removeObserver($0) }
        notes = []
        player.pause()
        player.replaceCurrentItem(with: nil)
        onStatus = nil
        onEnded = nil
        onUnsupported = nil
        // The player owned the display mode while it was up (as MPVPlayerController does).
        if let window = viewIfLoaded?.window ?? HarborOverlayWindow.mainWindow {
            window.avDisplayManager.preferredDisplayCriteria = nil
        }
    }

    func load(_ url: URL) {
        readyHandled = false
        unsupportedSent = false
        audioGroup = nil
        legibleGroup = nil
        observations.forEach { $0.invalidate() }
        observations = []
        notes.forEach { NotificationCenter.default.removeObserver($0) }
        notes = []
        // The same request identity mpv sends (MPVPlayerController's user-agent default), so a
        // provider that admits one engine admits the other.
        var options: [String: Any] = [:]
        let ua = headers.first { $0.key.lowercased() == "user-agent" }?.value ?? "VLC/3.0.20 LibVLC/3.0.20"
        options["AVURLAssetHTTPUserAgentKey"] = ua
        let rest = headers.filter { $0.key.lowercased() != "user-agent" }
        if !rest.isEmpty { options["AVURLAssetHTTPHeaderFieldsKey"] = rest }
        let asset = AVURLAsset(url: url, options: options)
        let item = AVPlayerItem(asset: asset)
        // The file's own subtitles reach NativeSubtitleOverlay through this output (see subtitleOutput).
        subtitleOutput?.setDelegate(nil, queue: nil)
        let output = AVPlayerItemLegibleOutput(mediaSubtypesForNativeRepresentation: [])
        output.suppressesPlayerRendering = true
        output.advanceIntervalForDelegateInvocation = max(Self.legibleLead, 1 - subDelaySec)
        output.setDelegate(self, queue: .main)
        item.add(output)
        subtitleOutput = output
        embeddedTimeline = []
        // KVO and notification blocks may arrive off the main thread; everything hops back to it.
        observations.append(item.observe(\.status, options: [.new]) { [weak self] _, _ in
            guard let self else { return }
            Task { @MainActor in self.itemStatusChanged() }
        })
        observations.append(player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            guard let self else { return }
            Task { @MainActor in self.refreshState() }
        })
        let center = NotificationCenter.default
        notes.append(center.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.didEnd() }
        })
        notes.append(center.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self] note in
            guard let self else { return }
            let err = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? NSError
            Task { @MainActor in self.fail(err) }
        })
        player.replaceCurrentItem(with: item)
        status.state = "loading"
        status.error = nil
        push("AVPlayer: \(isHls(url) ? "HLS" : url.pathExtension.lowercased())")
        // With no start to seek to, playback starts as soon as there is enough buffered.
        if startAtSeconds <= 1, wantsPlay { player.play() }
        report()
    }

    private func isHls(_ url: URL) -> Bool {
        let lower = url.absoluteString.lowercased()
        return lower.contains("m3u8") || lower.contains("/playlist/")
    }

    private func itemStatusChanged() {
        guard let item = player.currentItem else { return }
        switch item.status {
        case .readyToPlay:
            guard !readyHandled else { return }
            readyHandled = true
            push("ready")
            if startAtSeconds > 1 {
                let target = CMTime(seconds: startAtSeconds, preferredTimescale: 600)
                startAtSeconds = 0
                player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                    guard let self else { return }
                    Task { @MainActor in
                        if self.wantsPlay, !self.tornDown { self.player.play() }
                    }
                }
            } else if wantsPlay {
                player.play()
            }
            Task { await self.loadMediaInfo(item) }
            refreshState()
        case .failed:
            fail(item.error.map { $0 as NSError })
        default:
            break
        }
    }

    /// html5 error-map.ts: decode / unsupported source are what an mpv retry can fix; a network
    /// failure would fail on mpv too.
    private func fail(_ error: NSError?) {
        guard !tornDown else { return }
        let why = error?.localizedFailureReason ?? error?.localizedDescription ?? "Playback failed."
        push("error: \(error?.domain ?? "?") \(error?.code ?? 0) \(why)")
        let network = error?.domain == NSURLErrorDomain
            || (error?.userInfo[NSUnderlyingErrorKey] as? NSError)?.domain == NSURLErrorDomain
        if !network, !unsupportedSent {
            unsupportedSent = true
            onUnsupported?("codec")
        }
        status.state = "error"
        status.error = why
        report()
    }

    private func didEnd() {
        guard !tornDown else { return }
        status.state = "ended"
        report()
        onEnded?()
    }

    /// Tracks, codec name and the no-audio probe once the asset is open.
    private func loadMediaInfo(_ item: AVPlayerItem) async {
        let asset = item.asset
        audioGroup = try? await asset.loadMediaSelectionGroup(for: .audible)
        legibleGroup = try? await asset.loadMediaSelectionGroup(for: .legible)
        guard !tornDown, player.currentItem === item else { return }
        applyTrackPreferences()
        if let video = try? await asset.loadTracks(withMediaType: .video).first,
           let desc = try? await video.load(.formatDescriptions).first {
            codecName = Self.codecName(CMFormatDescriptionGetMediaSubType(desc))
        } else if let url, isHls(url) {
            codecName = "hls"
        }
        // html5 bridge probeAudio: the file has audio but none of it can be decoded (DTS, TrueHD…).
        // HLS assets expose no tracks here, so they are never flagged.
        if let audio = try? await asset.loadTracks(withMediaType: .audio), !audio.isEmpty {
            var playable = false
            for t in audio {
                let ok = (try? await t.load(.isPlayable)) ?? false
                if ok { playable = true; break }
            }
            if !playable, !unsupportedSent, !tornDown {
                unsupportedSent = true
                push("no playable audio track")
                onUnsupported?("noAudio")
            }
        }
        report()
    }

    private static func codecName(_ type: FourCharCode) -> String {
        switch type {
        case kCMVideoCodecType_HEVC, 0x68657631 /* hev1 */: return "hevc"
        case kCMVideoCodecType_H264: return "h264"
        case kCMVideoCodecType_AV1: return "av1"
        case 0x64766831 /* dvh1 */, 0x64766865 /* dvhe */: return "dolby vision"
        case 0x64766131 /* dva1 */, 0x64766176 /* dvav */: return "dolby vision"
        default:
            let chars = [24, 16, 8, 0].map { Character(UnicodeScalar(UInt8((type >> $0) & 0xFF))) }
            return String(chars).trimmingCharacters(in: .whitespaces)
        }
    }

    // MARK: transport

    func togglePause() { setPaused(wantsPlay) }

    func setPaused(_ paused: Bool) {
        wantsPlay = !paused
        if paused { player.pause() } else { player.play() }
        refreshState()
    }

    func seek(_ seconds: Double) { seek(to: player.currentTime().seconds + seconds) }

    func seek(to seconds: Double) {
        guard seconds.isFinite else { return }
        // The output reports what shows at the new spot; what it reported for the old one is stale.
        embeddedTimeline = []
        lastCueKey = "-"
        player.seek(to: CMTime(seconds: max(0, seconds), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func snapshot() -> (position: Double, duration: Double, paused: Bool) {
        let pos = player.currentTime().seconds
        let dur = player.currentItem?.duration.seconds ?? 0
        return (pos.isFinite ? max(0, pos) : 0, dur.isFinite ? max(0, dur) : 0, !wantsPlay)
    }

    func setMuted(_ muted: Bool) { player.isMuted = muted }
    func isMuted() -> Bool { player.isMuted }

    /// The end of the loaded range the playhead is in (mpv demuxer-cache-time's meaning).
    func bufferedSec() -> Double {
        guard let item = player.currentItem else { return 0 }
        let now = player.currentTime()
        for value in item.loadedTimeRanges {
            let r = value.timeRangeValue
            if r.containsTime(now) || CMTimeCompare(r.start, now) > 0 && (r.start.seconds - now.seconds) < 1 {
                let end = r.end.seconds
                return end.isFinite ? end : 0
            }
        }
        return 0
    }

    func streamFilename() -> String? {
        guard let url else { return nil }
        let last = url.lastPathComponent
        return last.isEmpty ? nil : last
    }

    func videoWidth() -> Int { Int(player.currentItem?.presentationSize.width ?? 0) }

    // MARK: tracks (AVMediaSelectionGroup)

    func tracks() -> [MPVPlayerController.Track] {
        guard let item = player.currentItem else { return [] }
        var out: [MPVPlayerController.Track] = []
        if let g = audioGroup {
            let on = item.currentMediaSelection.selectedMediaOption(in: g)
            for (i, o) in g.options.enumerated() { out.append(track(o, id: i + 1, type: "audio", selected: o == on, group: g)) }
        }
        if let g = legibleGroup {
            let on = item.currentMediaSelection.selectedMediaOption(in: g)
            for (i, o) in g.options.enumerated() { out.append(track(o, id: i + 1, type: "sub", selected: o == on && activeExternal == nil, group: g)) }
        }
        // html5 bridge readCustomSubtitleTracks: the sideloaded files, flagged external.
        for s in externalSubs {
            var t = MPVPlayerController.Track(id: s.id, type: "sub", lang: s.lang, title: s.title, codec: Self.codecOf(format: s.format),
                                              selected: s.id == activeExternal)
            t.external = true
            t.secondary = s.id == secondaryExternal
            t.externalFilename = s.file.lastPathComponent
            out.append(t)
        }
        return out
    }

    /// The codec name mpv reports for the same file, so the track rows read alike on both engines.
    private static func codecOf(format: String) -> String {
        switch format {
        case "vtt": return "webvtt"
        case "ass": return "ass"
        case "ssa": return "ssa"
        default: return "subrip"
        }
    }

    private func track(_ o: AVMediaSelectionOption, id: Int, type: String, selected: Bool, group: AVMediaSelectionGroup) -> MPVPlayerController.Track {
        let lang = o.extendedLanguageTag ?? o.locale?.identifier
        var t = MPVPlayerController.Track(id: id, type: type, lang: lang, title: o.displayName, codec: nil, selected: selected)
        t.forced = o.hasMediaCharacteristic(.containsOnlyForcedSubtitles)
        t.hearingImpaired = o.hasMediaCharacteristic(.transcribesSpokenDialogForAccessibility)
            && o.hasMediaCharacteristic(.describesMusicAndSoundForAccessibility)
        t.isDefault = group.defaultOption == o
        return t
    }

    func select(track: MPVPlayerController.Track?, type: String) {
        if type == "sub" {
            // setSubtitleTrack(id): a sideloaded track draws from its parsed cues, the file's own from
            // the legible output; the overlay draws both.
            embeddedTimeline = []
            lastCueKey = "-"
            if let track, track.id >= Self.externalSubBase { selectExternal(track.id); return }
            if activeExternal != nil { selectExternal(nil) }
        }
        guard let item = player.currentItem, let g = type == "sub" ? legibleGroup : audioGroup else { return }
        guard let track else {
            if g.allowsEmptySelection { item.select(nil, in: g) }
            return
        }
        let i = track.id - 1
        guard g.options.indices.contains(i) else { return }
        item.select(g.options[i], in: g)
    }

    /// The same language matching as MPVPlayerController.applyTrackPreferences: the first audio
    /// option in a preferred language; subtitles stay off unless one matches a preferred language.
    private func applyTrackPreferences() {
        guard let item = player.currentItem else { return }
        func rank(_ o: AVMediaSelectionOption, _ names: [String]) -> Int? {
            guard let tag = o.extendedLanguageTag ?? o.locale?.identifier else { return nil }
            let code = String(tag.lowercased().split(separator: "-").first ?? "")
            let english = Locale(identifier: "en").localizedString(forLanguageCode: code)?.lowercased()
            for (i, name) in names.enumerated() {
                let n = name.lowercased()
                if english == n || code == n || tag.lowercased() == n { return i }
                if let first = n.split(separator: " ").first, english == String(first) { return i }
            }
            return nil
        }
        if let g = audioGroup, !preferredAudio.isEmpty,
           let best = g.options.compactMap({ o in rank(o, preferredAudio).map { ($0, o) } }).min(by: { $0.0 < $1.0 }) {
            item.select(best.1, in: g)
            push("audio: \(best.1.displayName)")
        }
        if let g = legibleGroup {
            if let best = g.options.filter({ !$0.hasMediaCharacteristic(.containsOnlyForcedSubtitles) })
                .compactMap({ o in rank(o, preferredSubs).map { ($0, o) } }).min(by: { $0.0 < $1.0 }) {
                item.select(best.1, in: g)
                push("subs: \(best.1.displayName)")
            } else if g.allowsEmptySelection {
                item.select(nil, in: g)
            }
        }
    }

    // MARK: sideloaded subtitles (html5/bridge.ts addSubtitle / setSubtitleTrack / tickCues)

    /// addSubtitle(url, lang, title, select: true): the file PlayerSubtitlesPanel prepared (decoded
    /// text, `.srt` / `.vtt` / `.ass`…) becomes a track and is shown at once, as mpv's `sub-add … select`.
    /// Its cues arrive from the engine a moment later; a file with none is dropped again (ensureLoaded
    /// → loaded false, and the selection settles back to nothing).
    func addSubtitle(file: URL, title: String, lang: String) {
        let id = nextExternalId
        nextExternalId += 1
        let format = file.pathExtension.lowercased()
        externalSubs.append(ExternalSub(id: id, title: title, lang: lang, format: format, file: file, cues: []))
        selectExternal(id)
        let p = ProfilesStore.shared.active
        Task { [weak self] in
            let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            let cues: [SubtitleCue] = (try? await HarborEngine.shared.call("subtitles.cues", [p?.id ?? "default", p?.linked ?? true, text, format])) ?? []
            guard let self, !self.tornDown, let i = self.externalSubs.firstIndex(where: { $0.id == id }) else { return }
            if cues.isEmpty {
                self.externalSubs.remove(at: i)
                if self.activeExternal == id { self.activeExternal = nil }
                if self.secondaryExternal == id { self.secondaryExternal = nil }
                self.push("subtitle: no cues in \(file.lastPathComponent)")
            } else {
                self.externalSubs[i].cues = cues
                self.push("subtitle: \(cues.count) cues")
            }
            self.lastCueKey = "-"
            self.tickCues()
        }
    }

    /// A sideloaded track replaces the file's own one (and nil hands the overlay back to it).
    private func selectExternal(_ id: Int?) {
        if id != nil, let item = player.currentItem, let g = legibleGroup, g.allowsEmptySelection {
            item.select(nil, in: g)
        }
        activeExternal = id
        if let id, secondaryExternal == id { secondaryExternal = nil }
        lastCueKey = "-"
        tickCues()
    }

    /// setSecondarySubtitleTrack: only the engine's own (sideloaded) tracks can be drawn second.
    func setSecondarySub(_ track: MPVPlayerController.Track?) {
        if let track {
            guard track.id >= Self.externalSubBase, externalSubs.contains(where: { $0.id == track.id }) else { return }
            secondaryExternal = track.id
        } else {
            secondaryExternal = nil
        }
        tickCues()
    }

    /// setSubDelay: cues are looked up at `currentTime - delay` (+ late, − early, as mpv sub-delay).
    func setSubDelay(_ seconds: Double) {
        subDelaySec = seconds
        // An early (negative) offset needs the file's own changes at least that far ahead.
        subtitleOutput?.advanceIntervalForDelegateInvocation = max(Self.legibleLead, 1 - seconds)
        lastCueKey = "-"
        tickCues()
    }

    /// The overlay reads the Look settings itself; this only redraws it.
    func refreshSubtitleStyle() { subtitleState.objectWillChange.send() }

    // MARK: the file's own subtitles (AVPlayerItemLegibleOutput)

    /// One change reported by the legible output: from `time` on, `text` shows ("" = nothing).
    /// A report replaces whatever the timeline held at or after its time (the output reports in
    /// time order, so anything later is left over from before a jump back).
    fileprivate func embeddedChange(_ text: String, at time: Double, from output: ObjectIdentifier) {
        guard !tornDown, let subtitleOutput, ObjectIdentifier(subtitleOutput) == output, time.isFinite else { return }
        if let i = embeddedTimeline.firstIndex(where: { $0.time >= time }) {
            embeddedTimeline.removeSubrange(i...)
        }
        embeddedTimeline.append(EmbeddedChange(time: time, text: text))
        if embeddedTimeline.count > 400 { embeddedTimeline.removeFirst(embeddedTimeline.count - 400) }
        tickCues()
    }

    /// outputSequenceWasFlushed (a seek, a new selection): the reports so far no longer hold.
    fileprivate func embeddedFlushed(_ output: ObjectIdentifier) {
        guard !tornDown, let subtitleOutput, ObjectIdentifier(subtitleOutput) == output else { return }
        embeddedTimeline = []
        lastCueKey = "-"
        tickCues()
    }

    /// The file's own text at `time`, as a cue that started with the last change before it.
    private func embeddedCue(at time: Double) -> SubtitleCue? {
        guard let last = embeddedTimeline.last(where: { $0.time <= time }), !last.text.isEmpty else { return nil }
        return SubtitleCue(start: last.time, end: .infinity, text: last.text)
    }

    /// AVPlayer's own renderer stays off (the overlay draws), except in PiP when the viewer wants
    /// subtitles there (settings.subShowInPip): the overlay is not part of the PiP picture, AVPlayer's
    /// rendering of the file's own track is.
    private func applyLegibleRendering() {
        let inPip = isPictureInPictureActive && (SettingsBridge.shared.slice.subShowInPip ?? true)
        subtitleOutput?.suppressesPlayerRendering = !inPip
    }

    // MARK: Picture in Picture (bridge.ts requestPiP / exitPiP)

    /// capabilities().pictureInPicture: what the device allows.
    var supportsPictureInPicture: Bool { AVPictureInPictureController.isPictureInPictureSupported() }

    /// requestPiP: the PiP layer takes the player, and PiP starts as soon as AVKit says it can
    /// (the layer needs its first frame); after 4 s without that it gives up.
    func startPictureInPicture() {
        guard !tornDown, supportsPictureInPicture, player.currentItem != nil, !isPictureInPictureActive, !pipStarting else { return }
        pipLayerView.playerLayer.player = player
        if pip == nil {
            let made = AVPictureInPictureController(playerLayer: pipLayerView.playerLayer)
            pip = made
            pip?.delegate = self
        }
        guard let pip else {
            pipLayerView.playerLayer.player = nil
            push("PiP: unavailable")
            return
        }
        pipStarting = true
        pipAttempt += 1
        let attempt = pipAttempt
        if pip.isPictureInPicturePossible {
            pip.startPictureInPicture()
            return
        }
        pipPossibleObservation?.invalidate()
        pipPossibleObservation = pip.observe(\.isPictureInPicturePossible, options: [.new]) { [weak self] _, _ in
            guard let self else { return }
            Task { @MainActor in self.pipPossibleChanged(attempt) }
        }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            self?.pipGiveUp(attempt)
        }
    }

    /// exitPiP: back to the full picture.
    func stopPictureInPicture() {
        if isPictureInPictureActive { pip?.stopPictureInPicture() }
        else if pipStarting { pipGiveUp(pipAttempt) }
    }

    private func pipPossibleChanged(_ attempt: Int) {
        guard !tornDown, pipStarting, attempt == pipAttempt, let pip, pip.isPictureInPicturePossible else { return }
        pipPossibleObservation?.invalidate()
        pipPossibleObservation = nil
        // AVKit has it from here (didStart or failedToStart); the 4 s give-up no longer applies.
        pipAttempt += 1
        pip.startPictureInPicture()
    }

    private func pipGiveUp(_ attempt: Int) {
        guard !tornDown, pipStarting, attempt == pipAttempt, !isPictureInPictureActive else { return }
        pipStarting = false
        pipPossibleObservation?.invalidate()
        pipPossibleObservation = nil
        pipLayerView.playerLayer.player = nil
        push("PiP: not possible")
        onPictureInPicture?(false)
    }

    fileprivate func pipDidStart() {
        guard !tornDown else { return }
        pipStarting = false
        pipPossibleObservation?.invalidate()
        pipPossibleObservation = nil
        isPictureInPictureActive = true
        // The picture is in the PiP window now; nothing needs drawing here meanwhile.
        host.view.isHidden = true
        subtitleHost?.view.isHidden = true
        applyLegibleRendering()
        push("PiP: on")
        onPictureInPicture?(true)
    }

    fileprivate func pipWillStop() {
        guard !tornDown else { return }
        // Back under the PiP layer before the window animates home.
        host.view.isHidden = false
        subtitleHost?.view.isHidden = false
        isPictureInPictureActive = false
        applyLegibleRendering()
        onPictureInPicture?(false)
    }

    fileprivate func pipDidStop() {
        guard !tornDown else { return }
        isPictureInPictureActive = false
        pipStarting = false
        pipLayerView.playerLayer.player = nil
        host.view.isHidden = false
        subtitleHost?.view.isHidden = false
        applyLegibleRendering()
        push("PiP: off")
        lastCueKey = "-"
        tickCues()
        refreshState()
    }

    fileprivate func pipFailed(_ error: NSError?) {
        guard !tornDown else { return }
        pipStarting = false
        pipPossibleObservation?.invalidate()
        pipPossibleObservation = nil
        pipLayerView.playerLayer.player = nil
        push("PiP failed: \(error?.localizedDescription ?? "?")")
        onPictureInPicture?(false)
    }

    /// tickCues: the active cue of the shown track (and of the second one) at the delayed time. With
    /// no sideloaded track on, the file's own track (if one is selected) is what shows.
    private func tickCues() {
        guard !tornDown else { return }
        let now = player.currentTime().seconds
        let t = (now.isFinite ? now : 0) - subDelaySec
        let shown = activeExternal.flatMap { id in externalSubs.first { $0.id == id } }
        let cue: SubtitleCue?
        if let shown { cue = SubtitleCue.active(in: shown.cues, at: t) } else { cue = embeddedCue(at: t) }
        let key = cue.map { "\($0.start)|\($0.text)" } ?? ""
        if key != lastCueKey {
            lastCueKey = key
            subtitleState.text = cue?.text ?? ""
            subtitleState.startSec = cue?.start ?? 0
        }
        let second = secondaryExternal.flatMap { id in externalSubs.first { $0.id == id } }
        let secondText = second.flatMap { SubtitleCue.active(in: $0.cues, at: t) }?.text ?? ""
        if secondText != subtitleState.secondaryText { subtitleState.secondaryText = secondText }
    }

    // MARK: what the native engine cannot do (html5 bridge: setAudioDelay() {}, setAnime4kShaders() {})

    func setAudioDelay(_ seconds: Double) {}
    func setShaders(_ paths: [String]) {}

    // MARK: status

    private func refreshState() {
        guard !tornDown, let item = player.currentItem else { return }
        // PiP's own play / pause buttons drive the player directly; the transport follows them.
        if isPictureInPictureActive {
            if player.timeControlStatus == .paused { wantsPlay = false }
            else if player.timeControlStatus == .playing { wantsPlay = true }
        }
        if status.state == "error" { return }
        guard item.status == .readyToPlay else { return }
        if status.state == "ended", player.timeControlStatus != .playing { return }
        switch player.timeControlStatus {
        case .playing: status.state = "playing"
        case .waitingToPlayAtSpecifiedRate:
            // Still opening until the first frame has been shown.
            status.state = player.currentTime().seconds > 0 || status.state != "loading" ? "buffering/paused" : "loading"
        default: status.state = "buffering/paused"
        }
        report()
    }

    private func poll() {
        guard !tornDown else { return }
        if let item = player.currentItem {
            let size = item.presentationSize
            if size.width > 0 {
                status.videoParams = "\(Int(size.width)) \(Int(size.height)) \(codecName.isEmpty ? "avplayer" : codecName)"
            }
            status.hwdec = "avplayer"
            let pos = player.currentTime().seconds
            let dur = item.duration.seconds
            status.fps = "\(pos.isFinite ? String(format: "%.1f", pos) : "0")s / \(dur.isFinite ? String(format: "%.0f", dur) : "?")s"
            if let log = item.accessLog()?.events.last {
                status.dropped = "dropped \(log.numberOfDroppedVideoFrames) · stalls \(log.numberOfStalls)"
            }
        }
        refreshState()
        report()
    }

    private func push(_ line: String) {
        status.log.append(line)
        if status.log.count > 8 { status.log.removeFirst() }
    }

    /// Delivered on the next main-queue turn, never inside a SwiftUI update (as MPVPlayerController).
    private func report() {
        guard !tornDown else { return }
        let s = status
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.tornDown else { return }
            self.onStatus?(s)
        }
    }
}

extension NativePlayerController: PlayerEngineControlling {
    var engineKind: PlayerEngineKind { .native }
}

/// The legible output reports on the main queue; the hop keeps the controller's state on the main actor.
extension NativePlayerController: AVPlayerItemLegibleOutputPushDelegate {
    nonisolated func legibleOutput(_ output: AVPlayerItemLegibleOutput, didOutputAttributedStrings strings: [NSAttributedString],
                                   nativeSampleBuffers nativeSamples: [Any], forItemTime itemTime: CMTime) {
        // parser.ts cue text: plain lines; the Look settings style them, not the file.
        let text = strings.map { $0.string.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        let time = itemTime.seconds
        let id = ObjectIdentifier(output)
        Task { @MainActor in self.embeddedChange(text, at: time, from: id) }
    }

    nonisolated func outputSequenceWasFlushed(_ output: AVPlayerItemOutput) {
        let id = ObjectIdentifier(output)
        Task { @MainActor in self.embeddedFlushed(id) }
    }
}

/// AVPictureInPictureControllerDelegate, hopping to the main actor like the output above.
extension NativePlayerController: AVPictureInPictureControllerDelegate {
    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor in self.pipDidStart() }
    }

    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                                failedToStartPictureInPictureWithError error: Error) {
        let ns = error as NSError
        Task { @MainActor in self.pipFailed(ns) }
    }

    nonisolated func pictureInPictureControllerWillStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor in self.pipWillStop() }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor in self.pipDidStop() }
    }

    /// The player screen never leaves while PiP is on, so there is nothing to bring back.
    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                                restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        completionHandler(true)
    }
}

/// A view whose layer is an AVPlayerLayer: the source AVPictureInPictureController lifts.
final class NativePlayerLayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

/// PlayerScreen's native surface, the counterpart of MPVPlayerView.
struct NativePlayerView: UIViewControllerRepresentable {
    let url: URL
    var headers: [String: String] = [:]
    var startAt: Double = 0
    var isLive: Bool = false
    var preferredAudio: [String] = []
    var preferredSubs: [String] = []
    let onStatus: (MPVPlayerController.Status) -> Void
    var onEnded: (() -> Void)? = nil
    var onUnsupported: ((String) -> Void)? = nil
    var onReady: ((NativePlayerController) -> Void)? = nil
    /// Picture in Picture started (true) or is ending (false).
    var onPictureInPicture: ((Bool) -> Void)? = nil

    func makeUIViewController(context: Context) -> NativePlayerController {
        let c = NativePlayerController()
        c.url = url
        c.headers = headers
        c.startAtSeconds = startAt
        c.isLive = isLive
        c.preferredAudio = preferredAudio
        c.preferredSubs = preferredSubs
        c.onStatus = onStatus
        c.onEnded = onEnded
        c.onUnsupported = onUnsupported
        c.onPictureInPicture = onPictureInPicture
        DispatchQueue.main.async { onReady?(c) }
        return c
    }

    func updateUIViewController(_ c: NativePlayerController, context: Context) {}

    /// The view left the hierarchy for good (a cover over it does not count).
    static func dismantleUIViewController(_ c: NativePlayerController, coordinator: ()) {
        c.stop()
    }
}
