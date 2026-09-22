import SwiftUI

/// One catalog row: header that brightens when the row holds focus, then a horizontal track.
struct BPRowView: View {
    let row: BrowseRow
    let onFocus: (Meta) -> Void
    let onSelect: (Meta) -> Void
    @FocusState private var focusedId: String?

    var body: some View {
        VStack(alignment: .leading, spacing: BP.px(10)) {
            Text(row.title)
                .font(BP.sans(19, .bold)).foregroundStyle(BP.ink.opacity(focusedId == nil ? 0.55 : 1))
                .padding(.horizontal, BP.gutter)
                .animation(.easeOut(duration: 0.26), value: focusedId == nil)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: BP.trackGap) {
                    ForEach(Array(row.metas.enumerated()), id: \.element.id) { i, meta in
                        Button { onSelect(meta) } label: {
                            BPTileView(meta: meta, shape: row.shape, rank: i + 1, focused: focusedId == meta.id)
                        }
                        .buttonStyle(BPTileStyle())
                        .focused($focusedId, equals: meta.id)
                        .accessibilityIdentifier("tile-\(row.key)-\(i)")
                    }
                }
                .padding(.horizontal, BP.gutter)
                .padding(.vertical, BP.px(14))   // room for the lift and ring
            }
            .scrollClipDisabled()
        }
        .focusSection()
        .onChange(of: focusedId) { _, id in
            if let id, let m = row.metas.first(where: { $0.id == id }) { onFocus(m) }
        }
    }
}

/// The vertical rail of rows; keeps the focused row parked near the top (use-bp-rail.ts).
struct BPRailView<Lead: View>: View {
    let rows: [BrowseRow]
    let onFocus: (Meta, BrowseRow) -> Void
    let onSelect: (Meta) -> Void
    var topInset: CGFloat = 0
    @ViewBuilder var lead: () -> Lead
    @State private var focusedRow: String?
    /// Where the focused row parks: just under the spotlight copy (bp rail "resting floor").
    private var parkAnchor: CGFloat { (topInset + BP.px(6)) / 1080 }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: BP.rowGap) {
                    Color.clear.frame(height: topInset)
                    lead().id("lead")
                    ForEach(rows) { row in
                        BPRowView(row: row, onFocus: { m in focusedRow = row.key; onFocus(m, row) }, onSelect: onSelect)
                            .id(row.key)
                    }
                    Color.clear.frame(height: BP.hintHeight + BP.px(40))
                }
            }
            // Rows scrolling up pass under the spotlight copy; fade them out there.
            .mask(
                VStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: topInset)
                    Color.black
                }
            )
            .onChange(of: focusedRow) { _, key in
                guard let key else { return }
                withAnimation(BP.easeSlow) { proxy.scrollTo(key, anchor: UnitPoint(x: 0, y: parkAnchor)) }
            }
        }
    }
}
