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
    /// (device build 390) As BPRowView's See all: the link is reachable by Right off the last card
    /// only. Ungated it caught every Up from the cards, so Up from Jump back in opened onto
    /// "Your library" instead of the top bar (and a Select there opened the Library).
    @State private var libraryArmed = false

    var body: some View {
        VStack(alignment: .leading, spacing: BP.px(10)) {
            HStack(spacing: BP.px(14)) {
                Text("Jump back in")
                    .font(BP.sans(19, .bold)).foregroundStyle(BP.ink.opacity(focusedId == nil && !libraryFocused ? 0.55 : 1))
                    .accessibilityAddTraits(.isHeader)
                if let onLibrary, focusedId != nil || libraryFocused {
                    Button(T("Your library"), action: onLibrary)
                        .buttonStyle(BPSeeAllStyle())
                        // `.disabled`, not `.focusable`: a focusable modifier on a Button takes Select (BPRowView).
                        .disabled(!(libraryArmed || libraryFocused))
                        .focused($libraryFocused)
                        .accessibilityIdentifier("seeall-cw")
                        .onMoveCommand { dir in
                            // Back to the row's last card, as bpSeeAllExit.
                            guard dir == .left, let last = items.uniquedById().last else { return }
                            DispatchQueue.main.async { focusedId = last.id }
                        }
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
                            // Play/Pause opens the same quick panel (Remove, Mark watched…): a hold
                            // is easy to miss on the clickpad.
                            .onPlayPauseCommand { onQuick?(item) }
                            .onMoveCommand { dir in
                                guard dir == .right, onLibrary != nil, item.id == items.uniquedById().last?.id else { return }
                                libraryArmed = true
                                DispatchQueue.main.async { libraryFocused = true }
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { if !libraryFocused { libraryArmed = false } }
                            }
                    }
                }
                .padding(.horizontal, BP.gutter).padding(.top, BP.px(14))
                // (layout pass, 2026-09-27 device bug, build 291) Same fix as BPRowView's track: a
                // bigger bottom-only reserve so a focused card's lift/ring/shadow settles inside this
                // row before the next rail row's header starts (see BPRowView.swift for the full
                // upstream citation — bp-row.tsx's own 60px-canvas bottom padding for exactly this).
                .padding(.bottom, BP.px(26))
            }
            .scrollClipDisabled()
        }
        .focusSection()
        .onChange(of: focusedId) { _, id in
            if let id, let i = items.first(where: { $0.id == id }) { onFocus(i) }
        }
        .onChange(of: focusedId != nil) { _, held in onHold?(held) }
        .onChange(of: libraryFocused) { _, on in if !on { libraryArmed = false } }
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
