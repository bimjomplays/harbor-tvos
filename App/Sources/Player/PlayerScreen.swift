import SwiftUI

/// Full-screen playback with a minimal HUD (Stage 3). The Stage 4 player replaces the HUD.
struct PlayerScreen: View {
    let title: String
    let subtitle: String?
    let url: URL
    var headers: [String: String] = [:]
    let onClose: () -> Void
    @State private var status = MPVPlayerController.Status()
    @State private var hud = true
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            MPVPlayerView(url: url, headers: headers, onStatus: { status = $0 }, onEnded: onClose)
                .ignoresSafeArea()
            if hud {
                VStack(alignment: .leading, spacing: BP.px(6)) {
                    Text(title).font(BP.display(26)).foregroundStyle(BP.ink).shadow(radius: 8)
                    if let subtitle { Text(subtitle).font(BP.sans(15, .semibold)).foregroundStyle(BP.inkMuted) }
                    Text(status.state == "loading" ? "Loading…" : "\(status.fps)  ·  \(status.videoParams)")
                        .font(BP.sans(12, .medium)).foregroundStyle(BP.inkMuted)
                }
                .padding(BP.gutter)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(LinearGradient(colors: [.clear, BP.void_.opacity(0.9)], startPoint: .top, endPoint: .bottom))
                .transition(.opacity)
            }
        }
        .focusable()
        .onPlayPauseCommand { showHud() }
        .onExitCommand { onClose() }
        .onAppear { scheduleHide() }
        .animation(.easeOut(duration: 0.26), value: hud)
    }

    private func showHud() {
        hud = true
        scheduleHide()
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { hud = false }
        }
    }
}
