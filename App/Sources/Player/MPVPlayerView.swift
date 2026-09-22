import SwiftUI

struct MPVPlayerView: UIViewControllerRepresentable {
    let url: URL
    let onStatus: (MPVPlayerController.Status) -> Void

    func makeUIViewController(context: Context) -> MPVPlayerController {
        let c = MPVPlayerController()
        c.url = url
        c.onStatus = onStatus
        return c
    }

    func updateUIViewController(_ c: MPVPlayerController, context: Context) {}
}
