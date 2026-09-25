import SwiftUI

/// detail/bp-award-detail-dialog.tsx: the wins, then the nominations, each with category and year.
struct AwardsDialogView: View {
    let group: DetailModel.TitleAwards.Group
    let entries: [DetailModel.TitleAwards.Entry]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        // bp-award-detail-dialog: wins and nominations, each newest year first (byYear).
        // (device-flow pass 10) They kept the engine's order.
        let wins: [DetailModel.TitleAwards.Entry] = Self.byYear(entries.filter { $0.result == "won" })
        let noms: [DetailModel.TitleAwards.Entry] = Self.byYear(entries.filter { $0.result == "nominated" })
        ZStack(alignment: .trailing) {
            BP.void_.opacity(0.55).ignoresSafeArea()
            VStack(alignment: .leading, spacing: BP.px(10)) {
                Text(group.title).font(BP.sans(19, .bold)).foregroundStyle(BP.ink).accessibilityAddTraits(.isHeader)
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: BP.px(12)) {
                        if !wins.isEmpty { section(TCount(wins.count, one: "%lld win", "%lld wins"), wins) }
                        if !noms.isEmpty { section(TCount(noms.count, one: "%lld nomination", "%lld nominations"), noms) }
                    }
                }
                Button("Close") { dismiss() }.buttonStyle(BPActionStyle(primary: true))
            }
            .padding(BP.px(24))
            .frame(width: BP.px(560), alignment: .leading)
            .frame(maxHeight: .infinity)
            .background(BP.panel.opacity(0.98))
            .ignoresSafeArea()
        }
        .onExitCommand { dismiss() }
    }

    /// bp-award-detail-dialog byYear: `(b.year ?? 0) - (a.year ?? 0)` (a stable sort, as Array.sort is).
    private static func byYear(_ list: [DetailModel.TitleAwards.Entry]) -> [DetailModel.TitleAwards.Entry] {
        let sorted = list.enumerated().sorted { (a, b) -> Bool in
            let ya: Int = a.element.year ?? 0
            let yb: Int = b.element.year ?? 0
            return ya != yb ? ya > yb : a.offset < b.offset
        }
        return sorted.map { $0.element }
    }

    /// BpAwardLine: the year, then `e.category || e.awardName`. (device-flow pass 10) A win with no
    /// category read as a bare year.
    private static func line(_ e: DetailModel.TitleAwards.Entry) -> String {
        let category: String = e.category ?? ""
        let text: String = category.isEmpty ? e.awardName : category
        guard let year = e.year else { return text }
        return String(year) + " · " + text
    }

    private func section(_ label: String, _ list: [DetailModel.TitleAwards.Entry]) -> some View {
        VStack(alignment: .leading, spacing: BP.px(6)) {
            Text(label).font(BP.sans(11, .bold)).textCase(.uppercase).tracking(0.8).foregroundStyle(BP.inkSubtle)
            // (bug pass) Two nominations in one category and year (two supporting actors) share an Entry id.
            ForEach(Array(list.enumerated()), id: \.offset) { _, e in
                DialogLine {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: Self.line(e)).font(BP.sans(14, .semibold)).foregroundStyle(BP.ink)
                        if let r = e.recipient, !r.isEmpty { Text(r).font(BP.sans(12)).foregroundStyle(BP.inkMuted) }
                    }
                }
            }
        }
    }
}

/// bp-award-detail-dialog.tsx BpAwardLine / bp-facts-dialog.tsx: a line that takes focus only so Down
/// can walk (and scroll) the list; the focused one sits on --bp-glass with an --bp-edge-2 ring.
/// (detail pass) The lines were bare .focusable() views: the focus sat on them with nothing drawn.
struct DialogLine<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
        BPFocusReader { focused in
            content()
                .padding(.horizontal, BP.px(10)).padding(.vertical, BP.px(6))
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: BP.rXS, style: .continuous).fill(focused ? BP.glass : Color.clear))
                .overlay(RoundedRectangle(cornerRadius: BP.rXS, style: .continuous).stroke(focused ? BP.edge2 : Color.clear, lineWidth: 1))
        }
        // The focus stop reads as one line (year, award, result), not its fragments.
        .accessibilityElement(children: .combine)
        .focusable()
    }
}
