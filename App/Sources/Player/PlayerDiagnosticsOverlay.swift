import SwiftUI

/// (device diagnostics) Settings → Playback "Player diagnostics overlay" (settings.playerDiagnostics,
/// a TV-only key with no upstream equivalent — see SettingsBridge.Slice). The owner's Apple TV shows
/// a solid white screen when a stream starts (build 291) and there is no Mac to read
/// MPVPlayerController.status.log from, so this prints the same status PlayerScreen already keeps
/// (`applyStatus`, refreshed every second by the controller's own poll timer — no new timer here)
/// straight over the video. Off by default; the owner turns it on to see what libmpv/AVPlayer are
/// doing on the device itself.
///
/// Drawn last in PlayerScreen's ZStack so it sits over everything else, but it is never part of the
/// app's real UI: never focusable (only Text children, which take no focus on tvOS on their own),
/// hidden from VoiceOver, and out of the hit-test tree so it can never steal a remote press from the
/// transport underneath.
struct PlayerDiagnosticsOverlay: View {
    let engine: PlayerEngineKind
    let url: URL
    let status: MPVPlayerController.Status

    private var engineLabel: String { engine == .native ? "AVPlayer" : "mpv" }

    /// The source's host and file extension only — never the full URL (it can carry a debrid or
    /// addon token), matching the sourceErrorCard's own "Source said" line one screen over.
    private var sourceLabel: String {
        let host = url.isFileURL ? "file" : (url.host ?? "?")
        let ext = url.pathExtension
        return ext.isEmpty ? host : "\(host) .\(ext)"
    }

    private var stateLine: String {
        var s = "state: \(status.state)"
        if let e = status.error, !e.isEmpty { s += " — \(e)" }
        return s
    }

    /// vo / hwdec on one line; either side is blank for the AVPlayer engine (hwdec still reads
    /// "avplayer" there, vo stays "").
    private var voHwdecLine: String? {
        let parts = [status.vo.isEmpty ? nil : "vo=\(status.vo)", status.hwdec.isEmpty ? nil : "hwdec=\(status.hwdec)"]
            .compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// video-params (mpv) or width/height/codec (AVPlayer's presentationSize) plus the mpv drawable
    /// size, when either is known.
    private var videoLine: String? {
        let parts = [status.videoParams.isEmpty ? nil : status.videoParams,
                     status.drawableSize.isEmpty ? nil : "drawable \(status.drawableSize)"].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// mpv's own log lines, or (for AVPlayer) the same push() trail NativePlayerController keeps
    /// (AVPlayer: HLS/mp4, ready, error:…, subs:…): the last 10, oldest first, per the spec's "max
    /// ~14 lines" for the whole overlay (4 header lines above + up to 10 here).
    private var logLines: [String] { Array(status.log.suffix(10)) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: BP.px(2)) {
                Text("\(engineLabel) · \(sourceLabel)").bold()
                Text(stateLine)
                if let voHwdecLine { Text(voHwdecLine) }
                if let videoLine { Text(videoLine) }
                ForEach(Array(logLines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                }
            }
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(BP.px(8))
            .frame(maxWidth: max(320, UIScreen.main.bounds.width * 0.45), alignment: .leading)
            .background(Color.black.opacity(0.6))
            .cornerRadius(BP.px(6))
        }
        .font(.system(size: BP.px(11), design: .monospaced))
        .foregroundStyle(Color.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.leading, BP.px(24))
        .padding(.top, BP.px(24))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
