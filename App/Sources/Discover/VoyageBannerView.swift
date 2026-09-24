import SwiftUI

/// voyage-banner.tsx on the Discover room: "Harbor Voyages" (and the streak), the voyage's name or
/// "Set a course", where it stands, the call to action, and a skewed strip of backdrops drifting
/// past on the right (still under Reduce Motion). The whole banner opens the Voyage room.
struct VoyageBannerView: View {
    let snapshot: VoyageModel.Snapshot?
    /// discover.tsx voyageBannerPool (the Discover build's voyagePool).
    let pool: [Meta]
    let onOpen: () -> Void
    private let height = BP.px(172)

    var body: some View {
        let active = snapshot?.active
        let accent = active.flatMap { Color(oklch: $0.accent) } ?? BP.accent
        // voyage-banner.tsx items: the active voyage's pool when there is one, else Discover's.
        let own = active?.bannerItems ?? []
        let items = own.isEmpty ? Array(pool.prefix(8)) : own
        Button { onOpen() } label: {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    BP.canvas
                    VoyageMarquee(items: items, height: height)
                        .frame(width: geo.size.width * 0.61 + BP.px(34), height: height, alignment: .leading)
                        .clipped()
                        .transformEffect(CGAffineTransform(a: 1, b: 0, c: -0.14, d: 1, tx: height * 0.07, ty: 0))
                        .offset(x: geo.size.width * 0.39)
                    LinearGradient(stops: [.init(color: BP.canvas, location: 0), .init(color: BP.canvas, location: 0.41),
                                           .init(color: BP.canvas.opacity(0.88), location: 0.52), .init(color: BP.canvas.opacity(0.45), location: 0.64),
                                           .init(color: .clear, location: 0.78)],
                                   startPoint: .leading, endPoint: .trailing)
                    RadialGradient(colors: [accent.opacity(0.16), .clear], center: .topLeading, startRadius: 0, endRadius: geo.size.width * 0.55)
                        .opacity(0.6)
                    copy(active: active, accent: accent)
                        .padding(BP.px(28))
                        .frame(width: geo.size.width * 0.47, height: height, alignment: .leading)
                }
            }
            .frame(height: height)
            .clipShape(RoundedRectangle(cornerRadius: BP.rMD, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: BP.rMD, style: .continuous).stroke(BP.edge, lineWidth: 1))
        }
        .buttonStyle(BPTileStyle(radius: BP.rMD))
        .accessibilityIdentifier("voyage-band")
        .accessibilityLabel(Text(T("Open Voyages")))
        .padding(.horizontal, BP.gutter)
        .padding(.vertical, BP.px(14))
    }

    private func copy(active: VoyageModel.Active?, accent: Color) -> some View {
        let sailing = active?.sailing ?? false
        let ready = active.map { !$0.sailing && $0.picked >= $0.targetLength } ?? false
        let pitch: String
        let cta: String
        if let a = active {
            // voyage-banner.tsx reads playedIds for "watched so far", as upstream does.
            pitch = sailing ? T("%lld of %lld watched so far.", a.played, a.slots.count)
                : ready ? T("Your queue is full. Start whenever you're ready.")
                : T("%lld of %lld films picked.", a.picked, a.targetLength)
            cta = sailing ? T("Continue your voyage") : ready ? T("Start voyage") : T("Keep picking")
        } else {
            pitch = T("A short run of films you'll actually finish. You pick every stop.")
            cta = T("Start a voyage")
        }
        return VStack(alignment: .leading, spacing: BP.px(9)) {
            HStack(spacing: BP.px(8)) {
                Text(T("Harbor Voyages")).font(BP.sans(10.5, .bold)).textCase(.uppercase).tracking(BP.px(2.2)).foregroundStyle(accent)
                if let s = snapshot?.streak, s > 1 {
                    HStack(alignment: .firstTextBaseline, spacing: BP.px(3)) {
                        Image(systemName: "flame.fill").font(.system(size: BP.px(11), weight: .semibold)).foregroundStyle(accent)
                        Text(verbatim: "\(s)").font(BP.sans(10.5, .bold)).monospacedDigit().foregroundStyle(BP.ink)
                    }
                    .padding(.horizontal, BP.px(8)).padding(.vertical, BP.px(2))
                    .background(Capsule().fill(BP.elevated.opacity(0.7)))
                }
            }
            Text(active?.themeLabel ?? T("Set a course")).font(BP.display(28)).foregroundStyle(BP.ink).lineLimit(1)
            Text(pitch).font(BP.sans(13)).foregroundStyle(BP.inkMuted).lineLimit(2).frame(maxWidth: BP.px(340), alignment: .leading)
            Text(cta).font(BP.sans(13, .semibold)).foregroundStyle(BP.canvas)
                .padding(.horizontal, BP.px(20)).frame(height: BP.px(36))
                .background(Capsule().fill(BP.ink))
                .padding(.top, BP.px(4))
        }
    }
}

/// voyage-banner.tsx `voyage-marquee`: the capsules twice over, sliding left by one set in 48 s.
struct VoyageMarquee: View {
    let items: [Meta]
    let height: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shift: CGFloat = 0
    private let cell = BP.px(236)
    private let gap = BP.px(8)

    var body: some View {
        let strip = items.count >= 2 ? items + items : items
        HStack(spacing: gap) {
            ForEach(Array(strip.enumerated()), id: \.offset) { _, m in
                VoyageCapsule(meta: m).frame(width: cell, height: height)
            }
        }
        .fixedSize()
        .offset(x: shift)
        .onAppear { drift() }
        .onChange(of: items.map(\.id)) { _, _ in drift() }
        // Upstream pauses the marquee off screen; Reduce Motion is honoured live (review 33).
        .onChange(of: reduceMotion) { _, _ in drift() }
        .onDisappear {
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) { shift = 0 }
        }
    }

    private func drift() {
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) { shift = 0 }
        guard !reduceMotion, items.count >= 2 else { return }
        let loop = CGFloat(items.count) * (cell + gap)
        DispatchQueue.main.async {
            withAnimation(.linear(duration: 48).repeatForever(autoreverses: false)) { shift = -loop }
        }
    }
}

/// voyage-banner.tsx VoyageCapsule: the small backdrop, a corner scrim, the poster and the name.
struct VoyageCapsule: View {
    let meta: Meta

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            BP.elevated
            // capsuleBg(): the small metahub backdrop.
            RemoteImage(url: (meta.background ?? meta.poster).map { $0.replacingOccurrences(of: "/background/medium/", with: "/background/small/") })
            RadialGradient(colors: [.clear, BP.canvas.opacity(0.94)], center: .topTrailing, startRadius: BP.px(60), endRadius: BP.px(300))
            HStack(alignment: .bottom, spacing: BP.px(10)) {
                RemoteImage(url: meta.poster)
                    .frame(width: BP.px(46), height: BP.px(68))
                    .clipShape(RoundedRectangle(cornerRadius: BP.px(4), style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: BP.px(4), style: .continuous).stroke(Color.white.opacity(0.15), lineWidth: 1))
                    .shadow(color: .black.opacity(0.6), radius: BP.px(8), y: BP.px(6))
                Text(meta.name).font(BP.sans(12, .semibold)).foregroundStyle(BP.ink).lineLimit(3)
                    .shadow(color: BP.canvas, radius: BP.px(6))
                    .padding(.bottom, BP.px(4))
            }
            // Counter the strip's skew so the poster and name stand upright.
            .transformEffect(CGAffineTransform(a: 1, b: 0, c: 0.14, d: 1, tx: -BP.px(10), ty: 0))
            .padding(.horizontal, BP.px(16)).padding(.bottom, BP.px(12))
        }
        .clipped()
    }
}
