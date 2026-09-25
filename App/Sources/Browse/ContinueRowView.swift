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
    /// bp-home / bp-shows lead `{ action: "Your library", tab: "library" }`: the row header's
    /// see-all, shown while the row holds the ring (bp-row-header BpRowSeeAll). nil = no link.
    var onLibrary: (() -> Void)? = nil
    @FocusState private var focusedId: String?
    @FocusState private var libraryFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: BP.px(10)) {
            HStack(spacing: BP.px(14)) {
                Text("Jump back in")
                    .font(BP.sans(19, .bold)).foregroundStyle(BP.ink.opacity(focusedId == nil && !libraryFocused ? 0.55 : 1))
                    .accessibilityAddTraits(.isHeader)
                if let onLibrary, focusedId != nil || libraryFocused {
                    Button(T("Your library"), action: onLibrary)
                        .buttonStyle(BPSeeAllStyle())
                        .focused($libraryFocused)
                        .accessibilityIdentifier("seeall-cw")
                }
            }
            .padding(.horizontal, BP.gutter)
            .animation(.easeOut(duration: 0.26), value: focusedId == nil)
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
        // (focus pass) "Remove from Continue watching" (the quick panel): the ring comes back to the
        // card as the panel closes and the row re-reads a moment later without it. The card that
        // takes its place (or the one before it, at the end) takes the ring rather than tvOS
        // resetting focus somewhere else on the page.
        .onChange(of: items.map(\.id)) { old, new in
            guard let gone = focusedId, !new.contains(gone), let at = old.firstIndex(of: gone), !new.isEmpty else { return }
            let next = new[min(at, new.count - 1)]
            DispatchQueue.main.async { focusedId = next }
        }
    }
}
