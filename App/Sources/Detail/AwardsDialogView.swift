import SwiftUI

/// detail/bp-award-detail-dialog.tsx: the wins, then the nominations, each with category and year.
struct AwardsDialogView: View {
    let group: DetailModel.TitleAwards.Group
    let entries: [DetailModel.TitleAwards.Entry]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let wins = entries.filter { $0.result == "won" }
        let noms = entries.filter { $0.result != "won" }
        ZStack(alignment: .trailing) {
            BP.void_.opacity(0.55).ignoresSafeArea()
            VStack(alignment: .leading, spacing: BP.px(10)) {
                Text(group.title).font(BP.sans(19, .bold)).foregroundStyle(BP.ink)
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: BP.px(12)) {
                        if !wins.isEmpty { section("\(wins.count) win\(wins.count == 1 ? "" : "s")", wins) }
                        if !noms.isEmpty { section("\(noms.count) nomination\(noms.count == 1 ? "" : "s")", noms) }
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

    private func section(_ label: String, _ list: [DetailModel.TitleAwards.Entry]) -> some View {
        VStack(alignment: .leading, spacing: BP.px(6)) {
            Text(label).font(BP.sans(11, .bold)).textCase(.uppercase).tracking(0.8).foregroundStyle(BP.inkSubtle)
            // (bug pass) Two nominations in one category and year (two supporting actors) share an Entry id.
            ForEach(Array(list.enumerated()), id: \.offset) { _, e in
                VStack(alignment: .leading, spacing: 2) {
                    Text([e.year.map(String.init), e.category].compactMap { $0 }.joined(separator: " · ")).font(BP.sans(14, .semibold)).foregroundStyle(BP.ink)
                    if let r = e.recipient, !r.isEmpty { Text(r).font(BP.sans(12)).foregroundStyle(BP.inkMuted) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .focusable()
            }
        }
    }
}
