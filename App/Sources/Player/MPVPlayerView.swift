import SwiftUI

struct MPVPlayerView: UIViewControllerRepresentable {
    let url: URL
    var headers: [String: String] = [:]
    let onStatus: (MPVPlayerController.Status) -> Void
    var onEnded: (() -> Void)? = nil

    func makeUIViewController(context: Context) -> MPVPlayerController {
        let c = MPVPlayerController()
        c.url = url
        c.headers = headers
        c.onStatus = onStatus
        c.onEnded = onEnded
        return c
    }

    func updateUIViewController(_ c: MPVPlayerController, context: Context) {}
}
