import SwiftUI

/// Where a hero cycle stands: `total` titles, showing `active`.
struct HeroPips: Equatable {
    var total: Int
    var active: Int
}

/// bp-hero-pips.tsx: position only. Not focusable, and no countdown bar (upstream removed it:
/// a transition as long as the rotation keeps the render surface busy forever). Rest pips are
/// 5.3 px dots in edge-2, the live one a 10.7 px ink pill; nothing under two titles.
struct BPHeroPipsView: View {
    let pips: HeroPips
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if pips.total >= 2 {
            HStack(spacing: BP.px(12.5)) {
                ForEach(0..<pips.total, id: \.self) { i in
                    Capsule()
                        .fill(i == pips.active ? BP.ink : BP.edge2)
                        .frame(width: BP.px(i == pips.active ? 10.7 : 5.3), height: BP.px(5.3))
                }
            }
            .animation(reduceMotion ? nil : BP.ease, value: pips.active)
            .accessibilityHidden(true)
        }
    }
}
