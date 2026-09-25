import GameController
import SwiftUI

/// Game controllers, for three shell jobs: bp-controller-toast.tsx (a card when a pad
/// connects), bp-hint-bar.tsx (pad glyphs while one is connected, `useGamepads().length > 0`)
/// and use-bp-focus.ts's PageUp/PageDown (LB/RB switch tabs). A Siri Remote is also a
/// GCController, but only a micro gamepad, so "a pad" here means an extended gamepad.
@MainActor
final class GamepadMonitor: ObservableObject {
    static let shared = GamepadMonitor()

    enum Kind: Equatable { case dualsense, xbox, generic }
    struct Toast: Equatable { var kind: Kind; var key: Int }

    @Published private(set) var usingPad = false
    @Published var toast: Toast?
    /// Set by the shell: LB = −1, RB = +1.
    var onTab: ((Int) -> Void)?

    private var seq = 0
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        let center = NotificationCenter.default
        center.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] note in
            let c = note.object as? GCController
            let pad = c?.extendedGamepad != nil
            let name = [c?.vendorName, c?.productCategory].compactMap { $0 }.joined(separator: " ")
            Task { @MainActor in
                if pad { self?.announce(name) }
                self?.refresh()
            }
        }
        center.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        refresh()
    }

    /// bp-controller-toast.tsx classify(): Xbox first, because a wireless Xbox pad also reads
    /// as a "wireless controller".
    static func classify(_ name: String) -> Kind {
        let n = name.lowercased()
        if ["xbox", "xinput", "045e", "microsoft"].contains(where: { n.contains($0) }) { return .xbox }
        if ["dualsense", "dualshock", "playstation", "sony", "054c", "0ce6", "09cc", "05c4", "ps5", "ps4"].contains(where: { n.contains($0) }) { return .dualsense }
        return .generic
    }

    private func announce(_ name: String) {
        seq += 1
        toast = Toast(kind: Self.classify(name), key: seq)
    }

    private func refresh() {
        let pads = GCController.controllers().filter { $0.extendedGamepad != nil }
        usingPad = !pads.isEmpty
        for c in pads {
            guard let g = c.extendedGamepad else { continue }
            g.leftShoulder.pressedChangedHandler = { _, _, pressed in
                guard pressed else { return }
                Task { @MainActor in GamepadMonitor.shared.onTab?(-1) }
            }
            g.rightShoulder.pressedChangedHandler = { _, _, pressed in
                guard pressed else { return }
                Task { @MainActor in GamepadMonitor.shared.onTab?(1) }
            }
        }
    }
}

/// bp-controller-toast.tsx: slides a card up from the floor, holds it, drops it; a newer pad
/// restarts it. Announces connects only, as upstream does. Under Reduce Motion it cuts.
struct ControllerToastView: View {
    @ObservedObject var monitor: GamepadMonitor
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .bottom) {
            if let t = monitor.toast {
                HStack(spacing: BP.px(18)) {
                    ControllerArt(kind: t.kind).frame(width: BP.px(90), height: BP.px(64))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(T(Self.label(t.kind))).font(BP.sans(19, .semibold)).foregroundStyle(BP.ink)
                        Text("Ready to play").font(BP.sans(13.5, .medium)).foregroundStyle(BP.inkSubtle)
                    }
                    .padding(.trailing, BP.px(6))
                }
                .padding(.horizontal, BP.px(26)).padding(.vertical, BP.px(18))
                .background(RoundedRectangle(cornerRadius: BP.rLG, style: .continuous).fill(BP.panel.opacity(0.96)))
                .overlay(RoundedRectangle(cornerRadius: BP.rLG, style: .continuous).stroke(BP.edge2, lineWidth: 1))
                .shadow(color: .black.opacity(0.85), radius: 30, y: 24)
                .offset(y: shown ? 0 : BP.px(200))
                .opacity(shown ? 1 : 0)
                .animation(reduceMotion ? nil : BP.ease, value: shown)
                .padding(.bottom, BP.px(96))
                .task(id: t.key) {
                    // In, hold, out, unmount (30 ms / 3000 ms / 3360 ms).
                    shown = false
                    try? await Task.sleep(for: .milliseconds(30))
                    guard !Task.isCancelled else { return }
                    shown = true
                    try? await Task.sleep(for: .milliseconds(2970))
                    guard !Task.isCancelled else { return }
                    shown = false
                    try? await Task.sleep(for: .milliseconds(360))
                    guard !Task.isCancelled else { return }
                    if monitor.toast?.key == t.key { monitor.toast = nil }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .allowsHitTesting(false)
        .accessibilityHidden(monitor.toast == nil)
    }

    static func label(_ kind: GamepadMonitor.Kind) -> String {
        switch kind {
        case .xbox: return "Xbox controller connected"
        case .dualsense: return "DualSense connected"
        case .generic: return "Controller connected"
        }
    }
}

/// bp-controller-toast.tsx BpControllerArt: one batwing body (viewBox 128×92), per-pad buttons.
struct ControllerArt: View {
    let kind: GamepadMonitor.Kind

    var body: some View {
        Canvas { ctx, size in
            let s = min(size.width / 128, size.height / 92)
            ctx.translateBy(x: (size.width - 128 * s) / 2, y: (size.height - 92 * s) / 2)
            ctx.scaleBy(x: s, y: s)
            let body = Self.bodyPath()
            ctx.fill(body, with: .color(BP.panel2))
            ctx.stroke(body, with: .color(BP.edge2), lineWidth: 2.5)
            func stick(_ x: CGFloat, _ y: CGFloat) {
                let p = Path(ellipseIn: CGRect(x: x - 8, y: y - 8, width: 16, height: 16))
                ctx.fill(p, with: .color(BP.void_))
                ctx.stroke(p, with: .color(BP.edge2), lineWidth: 2)
            }
            func dot(_ x: CGFloat, _ y: CGFloat, _ color: Color) {
                ctx.fill(Path(ellipseIn: CGRect(x: x - 3.4, y: y - 3.4, width: 6.8, height: 6.8)), with: .color(color))
            }
            func bar(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) {
                ctx.fill(Path(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerRadius: 2), with: .color(BP.void_))
            }
            switch kind {
            case .xbox:
                stick(43, 40); stick(78, 60)
                bar(36, 55, 16, 6); bar(41, 50, 6, 16)
                dot(92, 33, BP.void_); dot(101, 42, BP.void_); dot(83, 42, BP.void_); dot(92, 51, BP.void_)
                // The guide button, the one saturated mark.
                ctx.fill(Path(ellipseIn: CGRect(x: 58, y: 28, width: 12, height: 12)), with: .color(BP.live))
            case .dualsense:
                let pad = Path(roundedRect: CGRect(x: 49, y: 21, width: 30, height: 19), cornerRadius: 4)
                ctx.fill(pad, with: .color(BP.panel))
                ctx.stroke(pad, with: .color(BP.accent), lineWidth: 2)
                stick(51, 63); stick(77, 63)
                bar(26, 43, 15, 6); bar(30.5, 38.5, 6, 15)
                dot(99, 38, BP.void_); dot(108, 46, BP.void_); dot(90, 46, BP.void_); dot(99, 54, BP.void_)
            case .generic:
                stick(51, 60); stick(77, 60)
                bar(26, 42, 15, 6); bar(30.5, 37.5, 6, 15)
                dot(99, 37, BP.void_); dot(108, 45, BP.void_); dot(90, 45, BP.void_); dot(99, 53, BP.void_)
            }
        }
        .accessibilityHidden(true)
    }

    /// BODY: "M64 15 C 41 15 35 17 29 23 … Z".
    private static func bodyPath() -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 64, y: 15))
        let curves: [(CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat)] = [
            (41, 15, 35, 17, 29, 23), (21, 31, 9, 52, 8, 66), (6, 79, 16, 84, 27, 80),
            (37, 77, 45, 67, 55, 65), (61, 64, 68, 64, 74, 65), (84, 67, 92, 77, 102, 80),
            (113, 84, 123, 79, 121, 66), (120, 52, 108, 31, 100, 23), (94, 17, 88, 15, 64, 15),
        ]
        for c in curves {
            p.addCurve(to: CGPoint(x: c.4, y: c.5), control1: CGPoint(x: c.0, y: c.1), control2: CGPoint(x: c.2, y: c.3))
        }
        p.closeSubpath()
        return p
    }
}
