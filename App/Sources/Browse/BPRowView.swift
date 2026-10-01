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
    /// (fix 2026-09-27, docs/parity-gaps.md "Up from a tile under See all") The chip is drawn
    /// whenever the row holds the ring (`focusedId != nil`), so with no gate of its own it sat in
    /// every Up press's candidate pool the whole time a tile was focused — tvOS could resolve Up
    /// off an early tile (the header has no Spacer; a short title puts the chip over one) straight
    /// onto it instead of carrying on to the row above. Upstream never offers that choice at all:
    /// use-bp-rail.ts bpRailStep index-steps between rows without ever measuring the row's own
    /// [data-bp-row-see-all], and bp-row-header keeps it out of the geometric pool by construction.
    /// `.focusable(seeAllArmed || seeAllFocused)` below reproduces that: the chip is un-focusable
    /// (though still visible) except in the two explicit hops that mean to land on it, so plain Up
    /// from any tile never finds it as a candidate.
    @State private var seeAllArmed = false
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
            // (fix 2026-09-27) Arm now — the chip is already mounted (a tile holds the ring, which
            // alone satisfies the `if` around it in `body`), so this only flips its `.focusable`
            // gate true. Asking for focus in the SAME update as that flip is what sweep 4's revert
            // was: the focus engine had not yet registered the newly-focusable chip when the
            // FocusState assignment tried to land on it, and the hop silently dropped (testRowSeeAllEdge,
            // testHomeBandRowLeads: "did not reach seeall-… (focus: none)"). One runloop later the
            // gate has already committed, so the hop lands.
            armSeeAll()
        } else if dir == startDir, index == 0, let onNavEdge {
            onNavEdge()
        }
    }

    /// Arm the chip, hop onto it a runloop later, and self-disarm if that hop never lands
    /// (review 2026-09-27: a row rebuild or a faster second press between the arm and the
    /// deferred assignment could drop the hop, leaving `seeAllArmed` true for the row's
    /// lifetime — the always-reachable chip the arm gate exists to prevent).
    private func armSeeAll() {
        seeAllArmed = true
        DispatchQueue.main.async { seeAllFocused = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            if !seeAllFocused { seeAllArmed = false }
        }
    }

    /// The end catch took the ring: straight on to the see-all when it came off the last cell
    /// (bpSeeAllEnter), else back to the last cell (an arrival from a row above or below).
    private func endCatch() {
        guard let last = items.last else { return }
        let id: String = last.id
        // A runloop later: the see-all is drawn only while the row (the catch included) holds the
        // ring, so it comes into the tree in the same update the catch took focus. Arming here runs
        // in that same update as the catch (fine: nothing asks for focus yet), so by the time the
        // dispatched line below runs, both presence and the `.focusable` gate are already settled.
        if lastHeld == id, onSeeAll != nil {
            armSeeAll()
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
                        // (fix 2026-09-27) Out of every directional candidate pool — Up included —
                        // except the two hops that mean to land here (tileMove, endCatch), which arm
                        // this a runloop before they ask for focus. Never gates visibility: the chip
                        // still draws (and dims/brightens) exactly as before, per the `if` above.
                        // (CI fix 2026-09-27) `.disabled`, not `.focusable(gate)`: a `.focusable`
                        // modifier on a Button takes the Select press for itself on tvOS, so the ring
                        // reached Manage and Select did nothing (testHomeBandRowLeads). A disabled
                        // button is out of every focus pool the same way, keeps its identifier and
                        // label for the tests, and BPSeeAllStyle does not dim on isEnabled.
                        .disabled(!(seeAllArmed || seeAllFocused))
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
                    .padding(.top, BP.px(14))   // room for the lift and ring, growing up into this row's own header
                    // (layout pass, 2026-09-27 device bug, build 291) bp-row.tsx's own track pads
                    // 60px-canvas of room below every row for exactly this (its own comment: "room
                    // for the lift and ring"), then pulls the next row back up by 38px-canvas with a
                    // negative margin, netting ~22px-canvas of real gap plus --bp-row-gap. This track
                    // only reserved the same 14px-canvas on both edges with no such net-back reserve,
                    // so a focused tile's 1.03 lift + ring + shadow at the row's own trailing edge had
                    // only BPRailView's row-gap between it and the next row's header — on the TV this
                    // read as the "Top 10" heading and a focused tile's title overlapping and both
                    // going unreadable. A bigger bottom-only reserve here (kept off the top, which
                    // only has this row's own header above it and was never the reported side).
                    .padding(.bottom, BP.px(26))
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
        // (device build 319) initial: Home's first focus (the seed) can land on a tile in the same
        // update the row appears, before a plain onChange is listening: the rail never heard of it
        // and the focused row stayed unparked at the bottom of the screen.
        .onChange(of: focusedId, initial: true) { _, id in
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
        // initial (as above): a row that appears already holding the ring reports it; the first call
        // passes old == new, so rows appearing without it report nothing.
        .onChange(of: focusedId != nil || seeAllFocused || endGuard, initial: true) { old, held in
            if old != held || held { onHold?(held) }
        }
        .onChange(of: seeAllFocused) { _, on in
            onSeeAllHold?(on)
            // (fix 2026-09-27) Disarm the moment the ring leaves the chip (Left off it, or any other
            // way focus moves on), so a later plain Up press finds it `.focusable(false)` again
            // rather than staying reachable for the rest of the row's visit.
            if !on { seeAllArmed = false }
        }
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
    /// `leadHeld` as state, for the delayed scrolls to read its current value.
    @State private var leadNow = false
    private static var topID: String { "bp-rail-top" }
    /// (device build 291, CI screenshots 19/20/25) reference/harbor bp-catalog-page.tsx never
    /// overlaps the two at all: `data-bp-hero` is a `shrink-0` flex sibling ABOVE a `flex-1
    /// min-h-0 overflow-hidden` rail, so a row can never sit under the hero in the first place.
    /// This port draws them as ZStack layers instead (for the backdrop wash under both), so the
    /// rail fakes upstream's boundary with `topInset` + this mask; keep the two in the same
    /// neighbourhood as `railFade` below, or a parked row again lands inside the fade instead of
    /// past it.
    /// (device build 314) 60 px canvas (101 pt) left the bottom of the row above a parked one
    /// showing as faint rectangles behind the hero synopsis; the row gap above a parked row is ~44 pt,
    /// so the fade fits inside it.
    private var railFade: CGFloat { BP.px(20) }
    /// Where the focused row's top parks: just under the spotlight copy (use-bp-rail shifts the
    /// active row's top to the rail's top edge, right under the hero).
    private var parkOffset: CGFloat { topInset + BP.px(6) }
    /// (layout pass) An anchor of `parkOffset / 1080` ignored the row's own height, and the marker
    /// that replaced it (a 1 pt view parkOffset above each row's top) never worked either:
    /// (device build 303, real Apple TV + CI screenshot 19) inside a
    /// LazyVStack, scrollTo(id) on a view nested in a row's background scrolls the row itself, so
    /// every parked row landed with its top at the screen's top edge, its header and most of its
    /// posters under the spotlight copy. Parking now scrolls the row (or lead section) by its own
    /// id, with the anchor worked out from its measured height: scrollTo lines up the point at `a`
    /// of the row with the point at `a` of the viewport, so rowTop = a × (viewport − rowHeight);
    /// a = parkOffset / (viewport − rowHeight) puts the row's top exactly at parkOffset.
    @State private var heights: [String: CGFloat] = [:]
    @State private var viewport: CGFloat = 1080

    static func parkAnchor(offset: CGFloat, height: CGFloat?, viewport: CGFloat) -> UnitPoint {
        guard let h = height, h > 0, viewport > 0, abs(viewport - h) > 1 else { return .top }
        return UnitPoint(x: 0.5, y: offset / (viewport - h))
    }

    private func park(_ key: String, _ proxy: ScrollViewProxy) {
        let isRow: Bool = rows.contains { $0.key == key }
        let target: String = isRow ? key : BPRail.parkID(key)
        proxy.scrollTo(target, anchor: Self.parkAnchor(offset: parkOffset, height: heights[key], viewport: viewport))
    }

    /// What a lead section needs to park itself like a row (BPRailLeadMark): the rows' park
    /// offset, and the same focusedRow → park path the rows take.
    private var parking: BPRailParking {
        BPRailParking(offset: parkOffset, park: { key in focusedRow = key },
                      report: { key, h in if heights[key] != h { heights[key] = h } })
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
                // (layout pass, 2026-09-27 device bug, build 291) A little more than the shared
                // BP.rowGap (bp-tokens.ts --bp-row-gap's own clamp(20px, 2.6vh, 40px) allows up to
                // 40px-canvas ≈ 67pt; this rail was sitting on its 20px-canvas ≈ 34pt floor) so a
                // lifted, ringed and shadowed tile settles inside its own row's reserve (the bottom
                // padding above) before the next row's header starts, at every tile shape — poster,
                // rank and wide alike. Kept local to the rail rather than raising BP.rowGap itself,
                // which Manga/EBook/Search also read.
                LazyVStack(alignment: .leading, spacing: BP.px(26)) {
                    Color.clear.frame(height: topInset).id(Self.topID)
                    // Continue Watching / Live sit here: over the plain rows below them.
                    lead().zIndex(1)
                        .environment(\.bpRailParking, parking)
                    ForEach(rows.uniquedById()) { row in   // (bug pass) duplicate row keys
                        BPRowView(row: row, onFocus: { m in focusedRow = row.key; onFocus(m, row) }, onSelect: onSelect,
                                  onSeeAll: seeAllAction(row), seeAllLabel: seeAllLabel?(row) ?? "See all", onQuick: onQuick,
                                  restoreRoute: restoreRoute, restoreCell: entry?.row == row.key ? entry?.cell : nil,
                                  onHold: { held in
                                      if held {
                                          heldRow = row.key
                                          // Belt and braces for the seed (device build 319): holding
                                          // the ring parks the row even if no tile focus was reported.
                                          if focusedRow != row.key { focusedRow = row.key }
                                      } else if heldRow == row.key { heldRow = nil }
                                      onHold?(row.key, held)
                                  },
                                  onNavEdge: navEdge(row),
                                  onSeeAllHold: { on in onSeeAllHold?(row.key, on) })
                            .id(row.key)
                            // The row's height, for its park anchor (parkAnchor).
                            .onGeometryChange(for: CGFloat.self) { g in g.size.height } action: { [key = row.key] h in
                                if heights[key] != h { heights[key] = h }
                            }
                            // The row holding focus draws its lifted tile and caption over the row below.
                            .zIndex(heldRow == row.key ? 2 : 0)
                    }
                    Color.clear.frame(height: BP.hintHeight + BP.px(40))
                }
            }
            // (device build 291, CI screenshots 19/20/25) Rows scrolling up pass under the
            // spotlight copy; hide them there, not just fade them. A gradient over the WHOLE
            // topInset (the old code) turns close to opaque well before its bottom edge, so a row
            // parked (or merely scrolled) anywhere in the lower half of the inset was still fully
            // readable exactly where the spotlight's own title/meta/synopsis sit (Home's second
            // row, "Trending This Week", parking at y≈390 with "Jump back in" still visible at
            // y≈100–290 under the hero copy). Upstream never needs this at all — bp-catalog-page.tsx
            // stacks the hero and the rail as non-overlapping flex siblings, so a row can never be
            // under the hero in the first place — so this rebuilds that boundary instead of
            // softening it: fully hidden for the whole inset except one short `railFade` at its
            // own bottom edge, so a row is invisible until the last moment it slides into place.
            .onGeometryChange(for: CGFloat.self) { g in g.size.height } action: { h in viewport = h }
            .mask(
                VStack(spacing: 0) {
                    Color.clear.frame(height: max(0, topInset - railFade))
                    LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                        .frame(height: min(topInset, railFade))
                    Color.black
                    // (device build 303) The shell's hint bar sits over the screen's bottom edge:
                    // rows passing under it fade out first instead of running under the chips.
                    LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                        .frame(height: BP.hintHeight + BP.px(24))
                }
            )
            .onChange(of: focusedRow) { _, key in
                guard let key else { return }
                // (device build 291, CI screenshots 19/20) Deferred a runloop, matching parkEntry
                // and the rows-changed re-park below: the marker's alignment guide reads the
                // height of every lazy sibling above this row (a lead still growing into its real
                // size, or — worst case, "Top 10 Movies Today" on a fresh Movies room — nothing
                // above it having settled at all yet, this row's own first-ever paint). Calling
                // scrollTo in the SAME update that set focusedRow read that geometry before layout
                // had settled, landing the row's header far short of topInset: under the tab bar on
                // Discover's rails (topInset = barHeight + 10), under the spotlight everywhere else.
                DispatchQueue.main.async { withAnimation(BP.easeSlow) { park(key, proxy) } }
                // (device builds 307/311) A scrollTo issued while tvOS's own focus scroll is still
                // animating is dropped: the rail ended a step behind (the row before parked, the
                // focused one under the hero or below the fold). Park again once that has settled.
                for delay in [0.45, 0.9] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                        guard focusedRow == key else { return }
                        withAnimation(BP.easeSlow) { park(key, proxy) }
                    }
                }
            }
            // The parked row (or lead section) measured late or changed height (a lazy row's first
            // layout, a lead band whose cards arrived): its anchor was worked out from the old
            // height, so it parks again.
            .onChange(of: focusedRow.flatMap { heights[$0] }) { old, new in
                guard old != new, let key = focusedRow else { return }
                DispatchQueue.main.async { withAnimation(BP.easeSlow) { park(key, proxy) } }
            }
            // (device build 307) Focus left the rail altogether (Up to the top bar): the rail went on
            // showing whatever the last park or tvOS's own focus scroll left, Jump back in half under
            // the hero copy. It goes back to rest, as a page does when its first row is left upward.
            .onChange(of: heldRow == nil && !leadHeld) { _, away in
                guard away else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    // A lead section that parked itself (Discover's bands) holds focusedRow; leave it.
                    let onRow: Bool = focusedRow.map { k in rows.contains { $0.key == k } } ?? true
                    // (CI run 312, NavigationTests) Only for the top bar: a Detail page opened over the
                    // room also takes focus, and resetting under it sent the ring back to Jump back in
                    // instead of the tile it left from.
                    guard heldRow == nil, onRow, ShellFocus.shared.barHasFocus else { return }
                    focusedRow = nil
                    withAnimation(BP.easeSlow) { proxy.scrollTo(Self.topID, anchor: .top) }
                }
            }
            // use-bp-rail parks every rail row, the lead ones too. Up from a parked row onto
            // Continue Watching, Live or the anime actions left them where they were: in the top
            // band, under the spotlight copy (drawn over the rail). The rail goes back to rest.
            .onChange(of: leadHeld) { _, held in
                leadNow = held
                guard held else { return }
                focusedRow = nil
                withAnimation(BP.easeSlow) { proxy.scrollTo(Self.topID, anchor: .top) }
                // (device build 311) Dropped under tvOS's own focus scroll like a park: Jump back in
                // kept the ring while it sat under the hero copy. Again once that has settled.
                for delay in [0.45, 0.9] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                        guard leadNow, focusedRow == nil else { return }
                        withAnimation(BP.easeSlow) { proxy.scrollTo(Self.topID, anchor: .top) }
                    }
                }
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
    /// A lead section's measured height (its park anchor, BPRailView.parkAnchor).
    var report: (String, CGFloat) -> Void
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
        content
            // The section is its own lazy child of the rail: parking scrolls it by this id.
            .id(BPRail.parkID(key))
            .onGeometryChange(for: CGFloat.self) { g in g.size.height } action: { h in
                parking?.report(key, h)
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
