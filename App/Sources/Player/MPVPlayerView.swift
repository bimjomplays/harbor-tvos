import SwiftUI

struct MPVPlayerView: UIViewControllerRepresentable {
    let url: URL
    var headers: [String: String] = [:]
    var startAt: Double = 0
    var isLive: Bool = false
    var preferredAudio: [String] = []
    var preferredSubs: [String] = []
    /// Per-show track memory key (TrackMemory.swift); nil remembers nothing.
    var trackMemory: TrackMemory? = nil
    /// view.ts PlayerSrc.subtitles: the stream's own subtitles, added unselected once it opens.
    var seedSubtitles: [SeedSubtitle] = []
    /// Muted guide preview (see MPVPlayerController.preview).
    var preview = false
    /// A Multiview tile (see MPVPlayerController.tile): never touches the display mode.
    var tile = false
    /// Muted but still decoding audio; changing it later mutes/unmutes the running player.
    var muted = false
    let onStatus: (MPVPlayerController.Status) -> Void
    var onEnded: (() -> Void)? = nil
    var onReady: ((MPVPlayerController) -> Void)? = nil

    func makeUIViewController(context: Context) -> MPVPlayerController {
        let c = MPVPlayerController()
        c.url = url
        c.headers = headers
        c.startAtSeconds = startAt
        c.isLive = isLive
        c.preview = preview
        c.tile = tile
        c.muted = muted
        c.preferredAudio = preferredAudio
        c.preferredSubs = preferredSubs
        c.trackMemory = trackMemory
        c.seedSubtitles = seedSubtitles
        c.onStatus = onStatus
        c.onEnded = onEnded
        DispatchQueue.main.async { onReady?(c) }
        return c
    }

    /// The view left the hierarchy for good (a cover over it does not count): release mpv now
    /// rather than whenever SwiftUI lets go of the controller.
    static func dismantleUIViewController(_ c: MPVPlayerController, coordinator: ()) {
        c.stop()
    }

    func updateUIViewController(_ c: MPVPlayerController, context: Context) {
        // Multiview audio focus moves between tiles without reloading the stream.
        if c.muted != muted {
            c.muted = muted
            c.setMuted(muted)
        }
    }
}
