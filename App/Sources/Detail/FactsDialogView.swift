import SwiftUI

/// detail/bp-facts-dialog.tsx: every fact row, scrollable.
struct FactsDialogView: View {
    let title: String
    let facts: [DetailModel.Extras.Fact]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .trailing) {
            BP.void_.opacity(0.55).ignoresSafeArea()
            VStack(alignment: .leading, spacing: BP.px(10)) {
                Text("Details").font(BP.sans(19, .bold)).foregroundStyle(BP.ink)
                Text(title).font(BP.sans(13)).foregroundStyle(BP.inkMuted).lineLimit(1)
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: BP.px(8)) {
                        ForEach(facts) { f in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(T(f.label)).font(BP.sans(11, .bold)).foregroundStyle(BP.inkSubtle).textCase(.uppercase)
                                Text(f.value).font(BP.sans(14)).foregroundStyle(BP.ink)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .focusable()
                        }
                    }
                }
                Button("Close") { dismiss() }.buttonStyle(BPActionStyle(primary: true))
            }
            .padding(BP.px(24))
            .frame(width: BP.px(520), alignment: .leading)
            .frame(maxHeight: .infinity)
            .background(BP.panel.opacity(0.98))
            .ignoresSafeArea()
        }
        .onExitCommand { dismiss() }
    }
}
