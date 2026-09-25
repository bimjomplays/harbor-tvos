import SwiftUI

/// One catalog row: header that brightens when the row holds focus, then a horizontal track.
struct BPRowView: View {
    let row: BrowseRow
    let onFocus: (Meta) -> Void
    let onSelect: (Meta) -> Void
    /// Present when the row can open a "See all" page (bp-row-header.tsx chip).
    var onSeeAll: (() -> Void)? = nil
    /// bp-quick-panel: hold Select on a tile.
    var onQuick: ((Meta) -> Void)? = nil
    /// bp-restore: the route this row remembers its cell under (nil = no memory).
    var restoreRoute: String? = nil
    /// Route entry (bp-restore readBpPosition): the cell that takes focus when the page resets.
    var restoreCell: String? = nil
    /// The row gained (true) or lost (false) the focused tile.
    var onHold: ((Bool) -> Void)? = nil
    @FocusState private var focusedId: String?
    @FocusState private var seeAllFocused: Bool
    @Environment(\.shellFocusNamespace) private var shellNS
    @Namespace private var rowNS

    /// readBpRowPosition: the cell this row had last time focus left it.
    private var remembered: String? {
        guard let route = restoreRoute else { return nil }
        return BPRestore.rowCell(route, row.key)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: BP.px(10)) {
            HStack(spacing: BP.px(14)) {
                Text(row.title)
                    .font(BP.sans(19, .bold)).foregroundStyle(BP.ink.opacity(focusedId == nil && !seeAllFocused ? 0.55 : 1))
                    .accessibilityAddTraits(.isHeader)
                if let onSeeAll, focusedId != nil || seeAllFocused {
                    Button("See all", action: onSeeAll)
                        .buttonStyle(BPSeeAllStyle())
                        .focused($seeAllFocused)
                        .accessibilityIdentifier("seeall-\(row.key)")
                }
            }
            .padding(.horizontal, BP.gutter)
            .animation(.easeOut(duration: 0.26), value: focusedId == nil)
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: BP.trackGap) {
                        // (bug pass) Unique ids: a catalog that repeats a title broke ForEach and focus.
                        ForEach(Array(row.metas.uniquedById().enumerated()), id: \.element.id) { i, meta in
                            Button { onSelect(meta) } label: {
                                BPTileView(meta: meta, shape: row.shape, rank: i + 1, focused: focusedId == meta.id)
                            }
                            .buttonStyle(BPTileStyle())
                            .focused($focusedId, equals: meta.id)
                            .prefersDefaultFocus(restoreCell == meta.id, in: shellNS ?? rowNS)
                            .accessibilityIdentifier("tile-\(row.key)-\(i)")
                            .onLongPressGesture(minimumDuration: 0.6) { onQuick?(meta) }
                        }
                    }
                    .padding(.horizontal, BP.gutter)
                    .padding(.vertical, BP.px(14))   // room for the lift and ring
                }
                .scrollClipDisabled()
                .onAppear {
                    // A remembered cell further along the track is brought into view (and so into
                    // existence, the track is lazy) before focus is asked to land on it.
                    guard let target = restoreCell ?? remembered,
                          let i = row.metas.firstIndex(where: { $0.id == target }), i > 3 else { return }
                    proxy.scrollTo(target, anchor: UnitPoint(x: 0.1, y: 0.5))
                }
            }
        }
        // Entering the row from above or below lands on its remembered cell, not the nearest one.
        // With no memory the value names no tile (never nil), so the usual nearest-tile rule applies.
        .defaultFocus($focusedId, remembered ?? "bp-restore:none", priority: .userInitiated)
        .focusSection()
        .onChange(of: focusedId) { _, id in
            if let id, let m = row.metas.first(where: { $0.id == id }) {
                if let route = restoreRoute { BPRestore.remember(route: route, row: row.key, cell: id) }
                onFocus(m)
            }
        }
        .onChange(of: focusedId != nil) { _, held in onHold?(held) }
    }
}

/// The vertical rail of rows; keeps the focused row parked near the top (use-bp-rail.ts).
struct BPRailView<Lead: View>: View {
    let rows: [BrowseRow]
    let onFocus: (Meta, BrowseRow) -> Void
    let onSelect: (Meta) -> Void
    var onSeeAll: ((BrowseRow) -> Void)? = nil
    var onQuick: ((Meta) -> Void)? = nil
    var topInset: CGFloat = 0
    /// bp-restore: the route rows remember their cells under, and the position to re-enter at.
    var restoreRoute: String? = nil
    var entry: BPRestore.Position? = nil
    var onHold: ((String, Bool) -> Void)? = nil
    @ViewBuilder var lead: () -> Lead
    @State private var focusedRow: String?
    /// Where the focused row parks: just under the spotlight copy (bp rail "resting floor").
    private var parkAnchor: CGFloat { (topInset + BP.px(6)) / 1080 }

    private func parkEntry(_ proxy: ScrollViewProxy) {
        guard focusedRow == nil, let e = entry, rows.contains(where: { $0.key == e.row }) else { return }
        proxy.scrollTo(e.row, anchor: UnitPoint(x: 0, y: parkAnchor))
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: BP.rowGap) {
                    Color.clear.frame(height: topInset)
                    lead().id("lead")
                    ForEach(rows.uniquedById()) { row in   // (bug pass) duplicate row keys
                        BPRowView(row: row, onFocus: { m in focusedRow = row.key; onFocus(m, row) }, onSelect: onSelect,
                                  onSeeAll: onSeeAll.map { cb in { cb(row) } }, onQuick: onQuick,
                                  restoreRoute: restoreRoute, restoreCell: entry?.row == row.key ? entry?.cell : nil,
                                  onHold: { held in onHold?(row.key, held) })
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
            // Route entry: park the remembered row first so it exists when focus resets into it.
            .onAppear { parkEntry(proxy) }
            .onChange(of: rows.isEmpty) { _, empty in if !empty { parkEntry(proxy) } }
        }
    }
}


/// Row header "See all" chip: semibold muted text, brightens when focused.
struct BPSeeAllStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        BPFocusReader { focused in
            configuration.label
                .font(BP.sans(15, .semibold))
                .foregroundStyle(focused ? BP.ink : BP.inkMuted)
                .padding(.horizontal, BP.px(10)).padding(.vertical, BP.px(4))
                .background(RoundedRectangle(cornerRadius: BP.rXS, style: .continuous).fill(focused ? BP.on : .clear))
                .animation(BP.easeFast, value: focused)
        }
    }
}
