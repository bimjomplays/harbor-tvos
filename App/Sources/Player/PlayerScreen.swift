import SwiftUI

/// Full-screen playback with a minimal HUD (Stage 3). The Stage 4 player replaces the HUD.
struct PlayerScreen: View {
    let title: String
    let subtitle: String?
    let url: URL
    var headers: [String: String] = [:]
    var context: PlaybackContext? = nil
    let onClose: () -> Void
    @State private var status = MPVPlayerController.Status()
    @State private var hud = true
    @State private var hideTask: Task<Void, Never>?
    @State private var controller: MPVPlayerController?
    @State private var startAt: Double?
    @State private var lastSavedPos: Double = -10
    private let tick = Timer.publish(every: 4, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if let startAt {
                MPVPlayerView(url: url, headers: headers, startAt: startAt, onStatus: { status = $0 }, onEnded: { finish(natural: true) }, onReady: { controller = $0 })
                    .ignoresSafeArea()
            } else {
                BP.void_.ignoresSafeArea()
            }
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
        .onPlayPauseCommand { controller?.togglePause(); showHud() }
        .onExitCommand { finish(natural: false) }
        .onAppear { scheduleHide() }
        .task { startAt = await context?.startPosition() ?? 0 }
        .onReceive(tick) { _ in Task { await saveTick(flush: false) } }
        .animation(.easeOut(duration: 0.26), value: hud)
    }

    /// use-resume-autosave.ts: every 4 s while playing, only if moved ≥ 1.5 s since the last save.
    private func saveTick(flush: Bool) async {
        guard let c = controller, let context else { return }
        let snap = c.snapshot()
        guard snap.duration > 0, flush || (!snap.paused && abs(snap.position - lastSavedPos) >= 1.5) else { return }
        lastSavedPos = snap.position
        _ = await context.save(positionSec: snap.position, durationSec: snap.duration, flush: flush)
    }

    private func finish(natural: Bool) {
        Task {
            if natural, let c = controller, let context {
                let snap = c.snapshot()
                _ = await context.save(positionSec: snap.duration > 0 ? snap.duration : snap.position, durationSec: snap.duration, flush: true)
            } else {
                await saveTick(flush: true)
            }
            onClose()
        }
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
