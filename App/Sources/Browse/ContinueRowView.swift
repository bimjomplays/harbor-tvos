import SwiftUI

/// "Jump back in" row (bp-cw-row.tsx).
struct ContinueRowView: View {
    let items: [ContinueItem]
    let onFocus: (ContinueItem) -> Void
    let onSelect: (ContinueItem) -> Void
    /// bp-quick-panel on a Continue Watching card (registerBpTarget cwItem): hold Select. It is the
    /// only way to reach "Remove from Continue watching" on a card.
    var onQuick: ((ContinueItem) -> Void)? = nil
    /// The row gained (true) or lost (false) the focused card.
    var onHold: ((Bool) -> Void)? = nil
    @FocusState private var focusedId: String?

    var body: some View {
        VStack(alignment: .leading, spacing: BP.px(10)) {
            Text("Jump back in")
                .font(BP.sans(19, .bold)).foregroundStyle(BP.ink.opacity(focusedId == nil ? 0.55 : 1))
                .accessibilityAddTraits(.isHeader)
                .padding(.horizontal, BP.gutter)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: BP.trackGap) {
                    ForEach(items.uniquedById()) { item in   // (bug pass) unique ids
                        Button { onSelect(item) } label: { ContinueCardView(item: item, focused: focusedId == item.id) }
                            .buttonStyle(BPTileStyle())
                            .focused($focusedId, equals: item.id)
                            .zIndex(focusedId == item.id ? 1 : 0)
                            .accessibilityIdentifier("cw-\(item.id)")
                            .onLongPressGesture(minimumDuration: 0.6) { onQuick?(item) }
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
