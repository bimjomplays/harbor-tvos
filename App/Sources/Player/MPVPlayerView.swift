import SwiftUI

struct MPVPlayerView: UIViewControllerRepresentable {
    let url: URL
    var headers: [String: String] = [:]
    var startAt: Double = 0
    let onStatus: (MPVPlayerController.Status) -> Void
    var onEnded: (() -> Void)? = nil
    var onReady: ((MPVPlayerController) -> Void)? = nil

    func makeUIViewController(context: Context) -> MPVPlayerController {
        let c = MPVPlayerController()
        c.url = url
        c.headers = headers
        c.startAtSeconds = startAt
        c.onStatus = onStatus
        c.onEnded = onEnded
        DispatchQueue.main.async { onReady?(c) }
        return c
    }

    func updateUIViewController(_ c: MPVPlayerController, context: Context) {}
}
