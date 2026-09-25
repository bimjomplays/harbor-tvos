import SwiftUI

/// onboarding/bp-onboard-backdrop.tsx: two columns of posters on the trailing side of the setup
/// frame, at 7 % opacity, drifting slowly (110 s up, 132 s down; bp-mosaic-drift moves a column by
/// half its doubled height) under a page-coloured wash from the leading edge. Decor only: it holds
/// still under Reduce Motion (bp-decor-motion) and never takes focus.
struct OnboardBackdropView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // A running repeatForever animation cannot be called off in place: toggling Reduce Motion
        // rebuilds the columns (as BPMosaicView does).
        OnboardWallColumns(drift: !reduceMotion).id(reduceMotion)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

private struct OnboardWallColumns: View {
    let drift: Bool
    @State private var phase = false

    private static let img = "https://image.tmdb.org/t/p/w342"
    /// bp-onboard-backdrop WALL (the columns use the first six).
    private static let wall: [String] = [
        "/iPOn6DinuVyLY17YM9mKuPofV08.jpg",
        "/7V0Ebks0GgpKvQ7QbLAIdX5dos4.jpg",
        "/5rhTDKUhPYvpdQIijFIs5VoWsON.jpg",
        "/1g0dhYtq4irTY1GPXvft6k4YLjm.jpg",
        "/sfQtVlIHljToOwYjhe21KPGzZWK.jpg",
        "/rzpHPSEgPTpRs8EHbygwsOw7jC0.jpg",
    ]
    private struct Column { let items: [String]; let secs: Double; let up: Bool }
    /// COLUMNS: each column's three posters twice over, so the half-height drift loops seamlessly.
    private static let columns: [Column] = [
        Column(items: Array(wall[0..<3]) + Array(wall[0..<3]), secs: 110, up: true),
        Column(items: Array(wall[3..<6]) + Array(wall[3..<6]), secs: 132, up: false),
    ]

    var body: some View {
        GeometryReader { g in
            let wallWidth: CGFloat = min(g.size.width * 0.46, BP.px(760))
            let gap: CGFloat = BP.px(14)
            let colWidth: CGFloat = (wallWidth - gap) / 2
            let tileHeight: CGFloat = colWidth * 1.5
            let half: CGFloat = (tileHeight + gap) * 3
            ZStack {
                HStack(alignment: .top, spacing: gap) {
                    ForEach(0..<Self.columns.count, id: \.self) { c in
                        column(Self.columns[c], width: colWidth, tileHeight: tileHeight, gap: gap, half: half)
                    }
                }
                .frame(width: wallWidth, height: g.size.height * 1.36, alignment: .top)
                .clipped()
                .opacity(0.07)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                // linear-gradient(100deg, page 34%, page 88% 58%, page 62% 100%).
                LinearGradient(stops: [.init(color: BP.canvas, location: 0.34),
                                       .init(color: BP.canvas.opacity(0.88), location: 0.58),
                                       .init(color: BP.canvas.opacity(0.62), location: 1)],
                               startPoint: .leading, endPoint: .trailing)
                    .flipsForRightToLeftLayoutDirection(true)
            }
            .frame(width: g.size.width, height: g.size.height)
        }
        .clipped()
        .onAppear { if drift { phase = true } }
    }

    private func column(_ col: Column, width: CGFloat, tileHeight: CGFloat, gap: CGFloat, half: CGFloat) -> some View {
        // bp-mosaic-drift: 0 → −50 % of the doubled column; the second column runs in reverse.
        let start: CGFloat = col.up ? 0 : -half
        let end: CGFloat = col.up ? -half : 0
        return VStack(spacing: gap) {
            ForEach(Array(col.items.enumerated()), id: \.offset) { _, path in
                RemoteImage(url: Self.img + path)
                    .frame(width: width, height: tileHeight)
                    .clipShape(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous))
            }
        }
        .frame(width: width, alignment: .top)
        .offset(y: phase ? end : start)
        .animation(.linear(duration: col.secs).repeatForever(autoreverses: false), value: phase)
    }
}
