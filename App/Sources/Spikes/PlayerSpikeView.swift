import SwiftUI

/// Picks a test clip, plays it with mpv, and overlays what mpv reports.
struct PlayerSpikeView: View {
    private static let base = "https://github.com/mpvkit/video-test/raw/master/resources/"
    private let clips: [(String, String)] = [
        ("H.265 MP4 (3 MB)", "h265.mp4"),
        ("MKV + SRT subtitles", "subrip.mkv"),
        ("MKV + PGS subtitles", "pgs_subtitle.mkv"),
        ("HDR10 MKV (61 MB)", "hdr.mkv"),
        ("HDR10+ MP4", "HDR10+.mp4"),
        ("HDR10 tone-map test", "HDR10_ToneMapping_Test_240_1000_nits.mp4"),
        ("Dolby Vision P5", "DolbyVision_P5.mp4"),
        ("Dolby Vision P8", "DolbyVision_P8.mp4"),
        ("Big Buck Bunny 1080p H.264", "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4"),
    ]
    @State private var selected: URL?
    @State private var status = MPVPlayerController.Status()
    @State private var showOverlay = true

    var body: some View {
        if let selected {
            ZStack(alignment: .topLeading) {
                MPVPlayerView(url: selected) { status = $0 }
                    .ignoresSafeArea()
                if showOverlay {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(status.state).font(.title3.weight(.semibold))
                        Text(status.videoParams)
                        Text("hwdec: \(status.hwdec)")
                        Text(status.fps)
                        Text(status.dropped)
                        ForEach(Array(status.log.enumerated()), id: \.offset) { Text($0.element).foregroundStyle(.secondary) }
                    }
                    .font(.system(size: 22, design: .monospaced))
                    .padding(20)
                    .background(.black.opacity(0.6))
                    .padding(40)
                }
            }
            .focusable()
            .onPlayPauseCommand { showOverlay.toggle() }
            .onExitCommand { self.selected = nil }
        } else {
            ZStack {
                HarborBackground()
                VStack(alignment: .leading, spacing: 20) {
                    Text("Player · mpv test clips").font(.largeTitle.weight(.semibold))
                    Text("Select a clip. Play/Pause toggles the overlay, Menu returns here.").foregroundStyle(.secondary)
                    ForEach(clips, id: \.1) { clip in
                        Button {
                            selected = URL(string: clip.1.hasPrefix("http") ? clip.1 : Self.base + clip.1)
                        } label: {
                            Text(clip.0).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(80)
            }
        }
    }
}
