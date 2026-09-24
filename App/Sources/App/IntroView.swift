import SwiftUI

/// use-bp-intro.ts: when the poster-wall front door leaves. It shows for at least 5 s and at most
/// 8 s counted from the first splash (app launch), but never less than 3.5 s after it mounts;
/// it leaves as soon as the rows behind it have arrived (after the floor), and any press skips
/// it. The fade is 620 ms.
@MainActor
final class IntroModel: ObservableObject {
    enum Phase { case showing, leaving, done }
    /// Starts as `.showing` so the wall is on screen in the same frame the boot splash leaves;
    /// the timers only run from `start()`. UI-test fixtures pass `enabled: false`.
    @Published private(set) var phase: Phase
    /// The wall's posters, frozen at the first render so the mosaic never reshuffles mid-intro.
    @Published private(set) var posters: [String] = []

    private static let minVisible: TimeInterval = 5, maxVisible: TimeInterval = 8
    private static let minAfterMount: TimeInterval = 3.5, fade: TimeInterval = 0.62
    /// bp-intro.tsx COLUMNS × PER_COLUMN.
    static let columns = 8, perColumn = 6

    private let launchedAt = Date()
    private var mountedAt = Date()
    private var started = false
    private var left = false
    private var cap: Task<Void, Never>?
    private var leaveTimer: Task<Void, Never>?

    init(enabled: Bool) {
        phase = enabled ? .showing : .done
    }

    /// bp-shell mounts the intro once per session, the moment Big Picture is up (here: the boot
    /// splash hands over to onboarding, who's watching or the shell).
    func start() {
        guard phase == .showing, !started else { return }
        started = true
        mountedAt = Date()
        let openedFor = Date().timeIntervalSince(launchedAt)
        let capIn = max(Self.minAfterMount, Self.maxVisible - openedFor)
        cap = Task { [weak self] in
            try? await Task.sleep(for: .seconds(capIn))
            guard !Task.isCancelled else { return }
            self?.beginLeave()
        }
    }

    /// bp-intro.tsx: live posters when there are enough, else the ones remembered from last session.
    func offer(live: [String]) {
        guard phase == .showing, posters.count < Self.columns * 2 else { return }
        freeze(live)
    }

    private func freeze(_ urls: [String]) {
        guard posters.count < Self.columns * 2, urls.count >= Self.columns * 2 else { return }
        var shuffled = urls
        // bp-intro.tsx's deterministic shuffle (Knuth's multiplicative hash), no RNG.
        if shuffled.count > 1 {
            for i in stride(from: shuffled.count - 1, to: 0, by: -1) {
                let j = Int((UInt64(i) &* 2654435761) % UInt64(i + 1))
                shuffled.swapAt(i, j)
            }
        }
        posters = Array(shuffled.prefix(Self.columns * Self.perColumn))
    }

    /// contentReady: wait out the floor, then leave.
    func contentReady() {
        guard phase == .showing, started, leaveTimer == nil else { return }
        let waited = Date().timeIntervalSince(launchedAt)
        let remaining = max(0, Self.minVisible - waited)
        cap?.cancel()
        leaveTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(remaining))
            guard !Task.isCancelled else { return }
            self?.beginLeave()
        }
    }

    /// Navigation is dead while the wall is up, so the first press skips it instead of vanishing.
    func skip() {
        guard phase == .showing, started, Date().timeIntervalSince(mountedAt) > 0.3 else { return }
        beginLeave()
    }

    private func beginLeave() {
        guard !left, phase == .showing else { return }
        left = true
        cap?.cancel(); leaveTimer?.cancel()
        withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: Self.fade)) { phase = .leaving }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.fade))
            self?.phase = .done
        }
    }
}

/// bp-intro.tsx: eight columns of posters drifting up and down at their own speeds behind a
/// radial vignette, with the mark and spinner where the boot splash drew them, so the hand-off
/// from BootSplashView is a removal, not a cross-fade. Leaving scales it up, blurs and fades.
struct IntroView: View {
    @ObservedObject var model: IntroModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var bedIn = false

    private static let speeds: [Double] = [46, 62, 52, 70, 56, 66, 50, 60]
    private static let delays: [Double] = [-8, -22, -4, -31, -14, -26, -11, -18]
    private static let up: [Bool] = [true, false, true, false, true, false, true, false]

    var body: some View {
        let leaving = model.phase == .leaving
        ZStack {
            BP.void_
            GeometryReader { g in
                let gutter = BP.px(11)
                let cell = (g.size.width - CGFloat(IntroModel.columns + 1) * gutter) / CGFloat(IntroModel.columns)
                HStack(alignment: .top, spacing: gutter) {
                    ForEach(0..<IntroModel.columns, id: \.self) { col in
                        column(col, cell: cell, gutter: gutter, height: g.size.height)
                    }
                }
                .padding(.horizontal, gutter)
            }
            // bp-intro-bed: the wall settles in from 1.08 to its 50% bed.
            .opacity(bedIn ? 0.5 : 0)
            .scaleEffect(bedIn || reduceMotion ? 1 : 1.08)
            RadialGradient(stops: [
                .init(color: BP.void_.opacity(0.62), location: 0),
                .init(color: BP.void_.opacity(0.88), location: 0.52),
                .init(color: BP.void_, location: 1),
            ], center: .center, startRadius: 0, endRadius: 1100)
            // Same mark, size and spacing as BootSplashView (the settled pose, never re-assembled).
            VStack(spacing: BP.px(28)) {
                HarborMark(size: BP.px(120))
                ProgressView().tint(BP.inkMuted)
            }
        }
        .ignoresSafeArea()
        .scaleEffect(leaving && !reduceMotion ? 1.06 : 1)
        .blur(radius: leaving && !reduceMotion ? 10 : 0)
        .opacity(leaving ? 0 : 1)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear {
            withAnimation(reduceMotion ? nil : Animation.timingCurve(0.22, 1, 0.36, 1, duration: 1.4)) { bedIn = true }
        }
    }

    @ViewBuilder private func column(_ idx: Int, cell: CGFloat, gutter: CGFloat, height: CGFloat) -> some View {
        let n = IntroModel.perColumn
        let slice: [String?] = (0..<n).map { i in
            model.posters.isEmpty ? nil : model.posters[(idx * n + i) % model.posters.count]
        }
        let tile = cell * 1.5
        let half = (tile + gutter) * CGFloat(n)
        let stack = VStack(spacing: gutter) {
            ForEach(Array((slice + slice).enumerated()), id: \.offset) { _, url in
                Group {
                    if let url { RemoteImage(url: url) } else { BP.panel2 }
                }
                .frame(width: cell, height: tile)
                .clipShape(RoundedRectangle(cornerRadius: BP.rXS, style: .continuous))
            }
        }
        if reduceMotion {
            stack.frame(width: cell, height: height, alignment: .top).clipped()
        } else {
            // splash-scroll-up/down: the doubled slice slides one half-length per period; a negative
            // delay starts the column part-way through, as the CSS animation-delay does.
            TimelineView(.animation) { ctx in
                let period = Self.speeds[idx]
                let t = (ctx.date.timeIntervalSinceReferenceDate - Self.delays[idx]).truncatingRemainder(dividingBy: period) / period
                let y = Self.up[idx] ? -CGFloat(t) * half : -half + CGFloat(t) * half
                stack.offset(y: y)
            }
            .frame(width: cell, height: height, alignment: .top)
            .clipped()
        }
    }
}
