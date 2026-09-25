import SwiftUI

/// One catalog row: header that brightens when the row holds focus, then a horizontal track.
struct BPRowView: View {
    let row: BrowseRow
    let onFocus: (Meta) -> Void
    let onSelect: (Meta) -> Void
    /// Present when the row can open a "See all" page (bp-row-header.tsx chip).
    var onSeeAll: (() -> Void)? = nil
    /// bp-row-header BpRowLead `action`: the chip's copy ("All movies" on Discover's rails).
    var seeAllLabel = "See all"
    /// bp-quick-panel: hold Select on a tile.
    var onQuick: ((Meta) -> Void)? = nil
    /// bp-restore: the route this row remembers its cell under (nil = no memory).
    var restoreRoute: String? = nil
    /// Route entry (bp-restore readBpPosition): the cell that takes focus when the page resets.
    var restoreCell: String? = nil
    /// The row gained (true) or lost (false) the focused tile.
    var onHold: ((Bool) -> Void)? = nil
    /// use-bp-focus toNav: Left at the start of the row (Right under RTL) takes the ring to the top
    /// bar. Only rail rows pass it (a room's rows, where the bar is right above); nil does nothing.
    var onNavEdge: (() -> Void)? = nil
    /// (open-items sweep 2) The row's See all chip gained (true) or lost (false) the ring. It counts
    /// in onHold (the row holds the ring) but is not a tile: use-bp-hero-cycle cardFocused() holds
    /// the hero only on a [data-bp-tile], so Home's cycle keeps turning on See all.
    var onSeeAllHold: ((Bool) -> Void)? = nil
    @FocusState private var focusedId: String?
    @FocusState private var seeAllFocused: Bool
    /// (navigation UI test, run 258) A 2 pt catch after the last cell of a row with a see-all. On a
    /// short row (Home's three-tile Your streaming) Right off the last cell found nothing in the row,
    /// and tvOS carried the ring diagonally into another row before bpSeeAllEnter could act; the catch
    /// is the nearest thing to the right, and hands the ring on at once (see `endCatch`).
    @FocusState private var endGuard: Bool
    /// The last cell of this row that held the ring (never cleared): the catch reads it to tell a
    /// Right off the last cell (→ see-all) from an arrival out of another row (→ the last cell).
    @State private var lastHeld: String?
    /// Bumped to bring the last cell into existence (the track is lazy) before the ring goes there.
    @State private var revealLast = 0
    @Environment(\.shellFocusNamespace) private var shellNS
    @Environment(\.layoutDirection) private var layoutDirection
    @Namespace private var rowNS

    /// The row's cells, one per title (the ForEach ids).
    private var items: [Meta] { row.metas.uniquedById() }

    /// Physical directions for the row's start and end: mirrored under RTL, as upstream's are.
    private var startDir: MoveCommandDirection { layoutDirection == .rightToLeft ? .right : .left }
    private var endDir: MoveCommandDirection { layoutDirection == .rightToLeft ? .left : .right }

    /// use-bp-focus stepAcross for a cell. A press that tvOS can carry to a neighbour is left to it;
    /// only the two dead ends act. bpSeeAllEnter: Right on the last cell puts the ring on the row's
    /// own see-all (a row without one does nothing, as upstream shakes). toNav: Left on the first
    /// cell reaches the top bar, on the tab the row names (RoomView / DiscoverView pass it).
    private func tileMove(_ dir: MoveCommandDirection, at index: Int, count: Int) {
        if dir == endDir, index == count - 1, onSeeAll != nil {
            seeAllFocused = true
        } else if dir == startDir, index == 0, let onNavEdge {
            onNavEdge()
        }
    }

    /// The end catch took the ring: straight on to the see-all when it came off the last cell
    /// (bpSeeAllEnter), else back to the last cell (an arrival from a row above or below).
    private func endCatch() {
        guard let last = items.last else { return }
        let id: String = last.id
        // A runloop later: the see-all is drawn only while the row (the catch included) holds the
        // ring, so it comes into the tree in the same update the catch took focus.
        if lastHeld == id, onSeeAll != nil {
            DispatchQueue.main.async { seeAllFocused = true }
        } else {
            DispatchQueue.main.async { focusedId = id }
        }
    }

    /// bp-row-see-all.ts bpSeeAllExit: back to the row's last cell, not whatever tvOS scores nearest.
    private func seeAllMove(_ dir: MoveCommandDirection) {
        guard dir == startDir, let last = items.last else { return }
        let id: String = last.id
        revealLast += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { focusedId = id }
    }

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
                if let onSeeAll, focusedId != nil || seeAllFocused || endGuard {
                    Button(T(seeAllLabel), action: onSeeAll)
                        .buttonStyle(BPSeeAllStyle())
                        .focused($seeAllFocused)
                        .accessibilityIdentifier("seeall-\(row.key)")
                        // bp-row-see-all.ts bpSeeAllExit: Left off the see-all goes straight back to
                        // the last cell of its own row (Right under RTL).
                        .onMoveCommand { dir in seeAllMove(dir) }
                }
            }
            .padding(.horizontal, BP.gutter)
            .animation(.easeOut(duration: 0.26), value: focusedId == nil)
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: BP.trackGap) {
                        // (bug pass) Unique ids: a catalog that repeats a title broke ForEach and focus.
                        ForEach(Array(items.enumerated()), id: \.element.id) { i, meta in
                            Button { onSelect(meta) } label: {
                                BPTileView(meta: meta, shape: row.shape, rank: i + 1, focused: focusedId == meta.id)
                            }
                            .buttonStyle(BPTileStyle())
                            .focused($focusedId, equals: meta.id)
                            .prefersDefaultFocus(restoreCell == meta.id, in: shellNS ?? rowNS)
                            .accessibilityIdentifier("tile-\(row.key)-\(i)")
                            .onLongPressGesture(minimumDuration: 0.6) { onQuick?(meta) }
                            // bp-row-see-all.ts / use-bp-focus stepAcross: both ends of a row lead on.
                            .onMoveCommand { dir in tileMove(dir, at: i, count: items.count) }
                            // The lifted tile, its ring, shadow and caption draw over its neighbours.
                            .zIndex(focusedId == meta.id ? 1 : 0)
                        }
                        if onSeeAll != nil, !items.isEmpty {
                            Color.clear
                                .frame(width: 2, height: BP.px(120))
                                .focusable()
                                .focused($endGuard)
                                .accessibilityHidden(true)
                        }
                    }
                    .padding(.horizontal, BP.gutter)
                    .padding(.vertical, BP.px(14))   // room for the lift and ring
                }
                .scrollClipDisabled()
                .onChange(of: revealLast) { _, _ in
                    guard let last = items.last else { return }
                    proxy.scrollTo(last.id, anchor: UnitPoint(x: 0.9, y: 0.5))
                }
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
        .onChange(of: endGuard) { _, on in
            if on { endCatch() }
        }
        .onChange(of: focusedId) { _, id in
            if let id { lastHeld = id }
            if let id, let m = row.metas.first(where: { $0.id == id }) {
                if let route = restoreRoute { BPRestore.remember(route: route, row: row.key, cell: id) }
                onFocus(m)
            }
        }
        // (regression pass) The row's own See all counts as the row holding the ring: bp-row-see-all
        // puts it inside [data-bp-row], and use-bp-rail / use-bp-sections follow the rail row that
        // contains focus. Since Right off the last tile reaches See all, the row reported losing the
        // ring there: Home's band let go (the spotlight crossfaded back in over a services or addons
        // row) and the rail dropped the row's zIndex, then both came back on Left.
        .onChange(of: focusedId != nil || seeAllFocused || endGuard) { _, held in onHold?(held) }
        .onChange(of: seeAllFocused) { _, on in onSeeAllHold?(on) }
    }
}

/// The vertical rail of rows; keeps the focused row parked near the top (use-bp-rail.ts).
struct BPRailView<Lead: View>: View {
    let rows: [BrowseRow]
    let onFocus: (Meta, BrowseRow) -> Void
    let onSelect: (Meta) -> Void
    var onSeeAll: ((BrowseRow) -> Void)? = nil
    /// The See all chip's copy per row (bp-row-header BpRowLead `action`).
    var seeAllLabel: ((BrowseRow) -> String)? = nil
    /// Whether a row offers its See all chip at all (nil = every row does). bp-row-header renders
    /// the chip only when it has somewhere to go.
    var seeAllShown: ((BrowseRow) -> Bool)? = nil
    var onQuick: ((Meta) -> Void)? = nil
    var topInset: CGFloat = 0
    /// bp-restore: the route rows remember their cells under, and the position to re-enter at.
    var restoreRoute: String? = nil
    var entry: BPRestore.Position? = nil
    var onHold: ((String, Bool) -> Void)? = nil
    /// (open-items sweep 2) A row's See all chip gained or lost the ring (BPRowView onSeeAllHold).
    var onSeeAllHold: ((String, Bool) -> Void)? = nil
    /// A lead row (Continue Watching, Live, the anime hero actions) holds focus.
    var leadHeld = false
    /// bp-row data-bp-row-tab: the tab a row belongs to, where Left at its start lands the ring
    /// (use-bp-focus toNav); nil (or no closure) lands on the active tab.
    var rowTab: ((BrowseRow) -> Room?)? = nil
    @ViewBuilder var lead: () -> Lead
    /// The shell's way to put the ring on its top bar (ShellView); absent outside a shell.
    @Environment(\.bpFocusTopBar) private var focusTopBar
    @State private var focusedRow: String?
    /// The row that holds focus right now (focusedRow keeps the last one after focus moves on).
    @State private var heldRow: String?
    private static var topID: String { "bp-rail-top" }
    /// Where the focused row's top parks: just under the spotlight copy (use-bp-rail shifts the
    /// active row's top to the rail's top edge, right under the hero).
    private var parkOffset: CGFloat { topInset + BP.px(6) }
    /// (layout pass) scrollTo(id, anchor: UnitPoint(y: a)) lines up the point at `a` of the ROW's
    /// own height with the point at `a` of the viewport, so the old `parkOffset / 1080` anchor put
    /// a ~580 pt poster row's top ~250 pt higher than meant: its header and posters sat under the
    /// hero title and description, and in the rail's top fade. Each row now carries a marker
    /// `parkOffset` above its top; scrolling that marker to the top parks the row's top exactly.
    private static func parkID(_ key: String) -> String { BPRail.parkID(key) }

    private func park(_ key: String, _ proxy: ScrollViewProxy) {
        proxy.scrollTo(Self.parkID(key), anchor: .top)
    }

    /// What a lead section needs to park itself like a row (BPRailLeadMark): the rows' park
    /// offset, and the same focusedRow → park path the rows take.
    private var parking: BPRailParking {
        BPRailParking(offset: parkOffset, park: { key in focusedRow = key })
    }

    private func seeAllAction(_ row: BrowseRow) -> (() -> Void)? {
        guard let onSeeAll else { return nil }
        let shown: Bool = seeAllShown?(row) ?? true
        guard shown else { return nil }
        return { onSeeAll(row) }
    }

    /// use-bp-focus toNav for a rail row: Left at its start goes up to the bar, on the row's tab.
    private func navEdge(_ row: BrowseRow) -> (() -> Void)? {
        guard let focusTopBar else { return nil }
        let tab: Room? = rowTab?(row)
        return { focusTopBar(tab) }
    }

    private func parkEntry(_ proxy: ScrollViewProxy) {
        guard focusedRow == nil, let e = entry, rows.contains(where: { $0.key == e.row }) else { return }
        // The rail is lazy: bring the row into existence by its own id, then park it by its marker.
        proxy.scrollTo(e.row, anchor: .top)
        DispatchQueue.main.async { park(e.row, proxy) }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: BP.rowGap) {
                    Color.clear.frame(height: topInset).id(Self.topID)
                    // Continue Watching / Live sit here: over the plain rows below them.
                    lead().id("lead").zIndex(1)
                        .environment(\.bpRailParking, parking)
                    ForEach(rows.uniquedById()) { row in   // (bug pass) duplicate row keys
                        BPRowView(row: row, onFocus: { m in focusedRow = row.key; onFocus(m, row) }, onSelect: onSelect,
                                  onSeeAll: seeAllAction(row), seeAllLabel: seeAllLabel?(row) ?? "See all", onQuick: onQuick,
                                  restoreRoute: restoreRoute, restoreCell: entry?.row == row.key ? entry?.cell : nil,
                                  onHold: { held in
                                      if held { heldRow = row.key } else if heldRow == row.key { heldRow = nil }
                                      onHold?(row.key, held)
                                  },
                                  onNavEdge: navEdge(row),
                                  onSeeAllHold: { on in onSeeAllHold?(row.key, on) })
                            .id(row.key)
                            .background(alignment: .top) {
                                // The park marker: parkOffset above the row's top edge.
                                Color.clear.frame(width: 1, height: 1)
                                    .alignmentGuide(.top) { [off = parkOffset] _ in off }
                                    .id(Self.parkID(row.key))
                                    .accessibilityHidden(true)
                            }
                            // The row holding focus draws its lifted tile and caption over the row below.
                            .zIndex(heldRow == row.key ? 2 : 0)
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
                withAnimation(BP.easeSlow) { park(key, proxy) }
            }
            // use-bp-rail parks every rail row, the lead ones too. Up from a parked row onto
            // Continue Watching, Live or the anime actions left them where they were: in the top
            // band, under the spotlight copy (drawn over the rail). The rail goes back to rest.
            .onChange(of: leadHeld) { _, held in
                guard held, focusedRow != nil else { return }
                focusedRow = nil
                withAnimation(BP.easeSlow) { proxy.scrollTo(Self.topID, anchor: .top) }
            }
            // (home device pass) Rows that arrive or leave above the focused one (Home's late extra
            // rows, a synced row edit, the anime bursts) moved it off its park: down under the hint
            // bar or off the screen, or up under the spotlight copy, with the ring still on it.
            .onChange(of: rows.map(\.key)) { _, _ in
                guard let key = heldRow else { return }
                DispatchQueue.main.async { withAnimation(BP.easeSlow) { park(key, proxy) } }
            }
            // Route entry: park the remembered row first so it exists when focus resets into it.
            .onAppear { parkEntry(proxy) }
            .onChange(of: rows.isEmpty) { _, empty in if !empty { parkEntry(proxy) } }
        }
    }
}


/// The rail's park marker id, for a row or a parkable lead section.
enum BPRail {
    static func parkID(_ key: String) -> String { "bp-park:" + key }
}

/// Handed by BPRailView to its lead: where a row's top parks, and the rail's own park request.
struct BPRailParking {
    var offset: CGFloat
    var park: (String) -> Void
}

private struct BPRailParkingKey: EnvironmentKey { static let defaultValue: BPRailParking? = nil }
extension EnvironmentValues {
    var bpRailParking: BPRailParking? {
        get { self[BPRailParkingKey.self] }
        set { self[BPRailParkingKey.self] = newValue }
    }
}

/// use-bp-rail parks every rail row, lead sections included (bp-discover's queue, awards, genres
/// and people bands are rail rows upstream). A lead section wearing this carries the same park
/// marker as a BPRailView row and parks when it takes the ring (`held` turns true), so Up from a
/// parked row onto it puts its header just under the top bar instead of wherever tvOS's own
/// scroll left it. Outside a BPRailView it does nothing.
struct BPRailLeadMark: ViewModifier {
    let key: String
    let held: Bool
    @Environment(\.bpRailParking) private var parking

    func body(content: Content) -> some View {
        let off: CGFloat = parking?.offset ?? 0
        return content
            .background(alignment: .top) {
                Color.clear.frame(width: 1, height: 1)
                    .alignmentGuide(.top) { _ in off }
                    .id(BPRail.parkID(key))
                    .accessibilityHidden(true)
            }
            .onChange(of: held) { _, now in
                guard now, let rail = parking else { return }
                rail.park(key)
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
