import SwiftUI
import UIKit
import os

/// (owner request 2026-10-01) Siri Remote touch-surface scrubbing, as Apple's own player does it:
/// a horizontal swipe on the clickpad moves the playhead in proportion to the swipe. SwiftUI on
/// tvOS has no gesture for the remote's touch surface, so a UIKit pan recogniser for indirect
/// touches sits on the player's window while this view is in it. It never cancels touches, so focus
/// movement and clicks keep working; `enabled` gates it to the moments scrubbing makes sense (the
/// video or the scrubber holds the ring, no panel open).
struct RemoteScrubCatcher: UIViewRepresentable {
    var enabled: Bool
    /// Horizontal travel since the swipe began, as a fraction of the window's width (−1…1+).
    var onBegan: () -> Void = {}
    var onChanged: (CGFloat) -> Void
    var onEnded: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.isUserInteractionEnabled = false
        view.coordinator = context.coordinator
        return view
    }

    func updateUIView(_ uiView: CatcherView, context: Context) {
        context.coordinator.enabled = enabled
        context.coordinator.onBegan = onBegan
        context.coordinator.onChanged = onChanged
        context.coordinator.onEnded = onEnded
    }

    static func dismantleUIView(_ uiView: CatcherView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class CatcherView: UIView {
        weak var coordinator: Coordinator?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let window { coordinator?.attach(to: window) } else { coordinator?.detach() }
        }
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var enabled = false
        var onBegan: () -> Void = {}
        var onChanged: (CGFloat) -> Void = { _ in }
        var onEnded: () -> Void = {}
        private var pan: UIPanGestureRecognizer?
        private weak var host: UIView?
        private var active = false
        private var scrubbing = false
        /// The swipe's travel so far, summed from per-event steps (see `handle`).
        private var travel: CGFloat = 0
        private var lastX: CGFloat = 0
        private let log = Logger(subsystem: "com.dltnp.harbor", category: "scrub")

        func attach(to window: UIWindow) {
            guard pan == nil else { return }
            let recognizer = UIPanGestureRecognizer(target: self, action: #selector(handle(_:)))
            recognizer.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
            recognizer.cancelsTouchesInView = false
            recognizer.delaysTouchesBegan = false
            recognizer.delaysTouchesEnded = false
            recognizer.delegate = self
            window.addGestureRecognizer(recognizer)
            pan = recognizer
            host = window
        }

        func detach() {
            if let pan, let host { host.removeGestureRecognizer(pan) }
            pan = nil
            host = nil
            active = false
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }

        @objc private func handle(_ recognizer: UIPanGestureRecognizer) {
            let width: CGFloat = max(1, recognizer.view?.bounds.width ?? 1920)
            switch recognizer.state {
            case .began:
                active = enabled
                travel = 0
                lastX = recognizer.translation(in: recognizer.view).x
                if active { onBegan() }
            case .changed:
                guard active, enabled else { return }
                let t: CGPoint = recognizer.translation(in: recognizer.view)
                // (device build 328) Summed per-event steps, with any single step over a quarter of
                // the surface dropped: one remote swipe arrived with a jump that sent the film to 0:00.
                let dx: CGFloat = t.x - lastX
                lastX = t.x
                log.debug("scrub step dx=\(Double(dx), privacy: .public) tx=\(Double(t.x), privacy: .public) ty=\(Double(t.y), privacy: .public) w=\(Double(width), privacy: .public)")
                guard abs(dx) < width * 0.25 else { return }
                // A mostly vertical swipe is focus movement, not a scrub.
                guard abs(t.x) > abs(t.y) * 1.2 else { return }
                travel += dx
                // A deadzone: a click's small jiggle on the clickpad is not a scrub.
                let f: CGFloat = travel / width
                guard abs(f) > 0.02 || scrubbing else { return }
                scrubbing = true
                onChanged(f)
            case .ended, .cancelled, .failed:
                if active && scrubbing { onEnded() }
                active = false
                scrubbing = false
            default:
                break
            }
        }
    }
}
