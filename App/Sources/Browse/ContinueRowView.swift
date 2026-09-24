import SwiftUI

/// "Jump back in" row (bp-cw-row.tsx).
struct ContinueRowView: View {
    let items: [ContinueItem]
    let onFocus: (ContinueItem) -> Void
    let onSelect: (ContinueItem) -> Void
    /// The row gained (true) or lost (false) the focused card.
    var onHold: ((Bool) -> Void)? = nil
    @FocusState private var focusedId: String?

    var body: some View {
        VStack(alignment: .leading, spacing: BP.px(10)) {
            Text("Jump back in")
                .font(BP.sans(19, .bold)).foregroundStyle(BP.ink.opacity(focusedId == nil ? 0.55 : 1))
                .padding(.horizontal, BP.gutter)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: BP.trackGap) {
                    ForEach(items) { item in
                        Button { onSelect(item) } label: { ContinueCardView(item: item, focused: focusedId == item.id) }
                            .buttonStyle(BPTileStyle())
                            .focused($focusedId, equals: item.id)
                            .accessibilityIdentifier("cw-\(item.id)")
                    }
                }
                .padding(.horizontal, BP.gutter).padding(.vertical, BP.px(14))
            }
            .scrollClipDisabled()
        }
        .focusSection()
        .onChange(of: focusedId) { _, id in
            if let id, let i = items.first(where: { $0.id == id }) { onFocus(i) }
        }
        .onChange(of: focusedId != nil) { _, held in onHold?(held) }
    }
}
