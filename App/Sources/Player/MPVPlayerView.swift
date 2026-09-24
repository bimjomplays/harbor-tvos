import SwiftUI

struct MPVPlayerView: UIViewControllerRepresentable {
    let url: URL
    var headers: [String: String] = [:]
    var startAt: Double = 0
    var isLive: Bool = false
    var preferredAudio: [String] = []
    var preferredSubs: [String] = []
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
        c.onStatus = onStatus
        c.onEnded = onEnded
        DispatchQueue.main.async { onReady?(c) }
        return c
    }

    func updateUIViewController(_ c: MPVPlayerController, context: Context) {
        // Multiview audio focus moves between tiles without reloading the stream.
        if c.muted != muted {
            c.muted = muted
            c.setMuted(muted)
        }
    }
}
