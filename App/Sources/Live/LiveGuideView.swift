import SwiftUI

/// The Big Picture guide grid (bp-guide.tsx): a channel column, a half-hour ruler, one gapless
/// lane per channel, a "now" line, and D-pad focus on programme cells. Geometry follows
/// bp-guide-geometry.ts at the TV canvas; the window seeds 60 min before now and grows by
/// 3 h when focus reaches an edge, up to 26 h.
@MainActor
final class LiveGuideModel: ObservableObject {
    struct Cell: Decodable, Identifiable, Equatable {
        var startMs: Double; var endMs: Double; var program: LiveModel.Program?
        var id: String { "\(startMs)" }
    }
    struct Lane: Decodable { var id: String; var catchup: Bool; var cells: [Cell] }

    static let slotMs: Double = 30 * 60_000
    static let pastPadMs: Double = 60 * 60_000
    static let initialWindowMs: Double = 6 * 60 * 60_000
    static let extendMs: Double = 3 * 60 * 60_000
    static let maxWindowMs: Double = 26 * 60 * 60_000

    @Published private(set) var lanes: [String: [Cell]] = [:]
    @Published private(set) var catchup: Set<String> = []
    @Published private(set) var windowStart: Double = 0
    @Published private(set) var windowEnd: Double = 0
    @Published var viewStart: Double = 0

    private var playlistId: String?
    private var channelIds: [String] = []
    private var index: [String: Int] = [:]

    // use-bp-guide-data.ts builds a lane only for a row that is mounted (laneFor, 600 cached).
    // The TV used to ask the engine for every lane of the category at once: "All" on a big
    // playlist is thousands of channels, megabytes of cells over the bridge on every open and
    // on every window extension. Lanes are now fetched for the rows on screen, a batch at a time.
    static let batch = 40
    static let cacheMax = 600
    /// Rows LazyVStack has built (onAppear … onDisappear).
    private var onScreen: Set<String> = []
    /// Lanes being fetched now (so a row coming on screen does not ask twice).
    private var pending: Set<String> = []
    /// Lanes built for an older window or older guide data: shown until the new one lands.
    private var stale: Set<String> = []
    /// Bumped when the playlist or the guide data changes: replies from before are dropped.
    private var epoch = 0

    /// bp-guide.tsx resetKey (`${activeId}:${catKey}`): the list the window was seeded for.
    private var resetKey: String?

    func seed(playlistId: String, channelIds: [String], resetKey: String) async {
        let now = Date().timeIntervalSince1970 * 1000
        if windowStart == 0 || self.resetKey != resetKey {
            // (live sources device pass) bp-guide.tsx seededRef: another source or chip opens on
            // now again. The window stayed wherever the last chip had been scrolled to (hours
            // ahead, or yesterday), so a new category opened far from what is on.
            let start = (((now - Self.pastPadMs) / Self.slotMs).rounded(.down)) * Self.slotMs
            let end = start + Self.initialWindowMs
            if windowStart != 0, start != windowStart || end != windowEnd { stale = Set(lanes.keys) }
            windowStart = start
            windowEnd = end
            viewStart = start
        }
        self.resetKey = resetKey
        if self.playlistId != playlistId { epoch += 1; pending = [] }
        let changedList = self.playlistId != playlistId || self.channelIds != channelIds
        self.playlistId = playlistId
        self.channelIds = channelIds
        if changedList {
            var idx: [String: Int] = [:]
            for (i, id) in channelIds.enumerated() where idx[id] == nil { idx[id] = i }
            index = idx
            // Rows that are still listed keep their lanes (no empty frame); the rest go.
            lanes = lanes.filter { idx[$0.key] != nil }
            catchup = catchup.filter { idx[$0] != nil }
            stale = stale.filter { idx[$0] != nil }
        }
        await fill(from: 0)
        await fillOnScreen()
    }

    func rowAppeared(_ id: String) {
        onScreen.insert(id)
        guard needsLane(id), !pending.contains(id), let i = index[id] else { return }
        Task { await fill(from: i) }
    }

    func rowDisappeared(_ id: String) { onScreen.remove(id) }

    private func needsLane(_ id: String) -> Bool { lanes[id] == nil || stale.contains(id) }

    /// This row's lane and the next rows' (the ones D-pad Down reaches next).
    private func fill(from i: Int) async {
        guard i >= 0, i < channelIds.count else { return }
        let ids = channelIds[i..<min(channelIds.count, i + Self.batch)].filter { needsLane($0) && !pending.contains($0) }
        await fetch(Array(ids))
    }

    private func fillOnScreen() async {
        await fetch(channelIds.filter { onScreen.contains($0) && needsLane($0) && !pending.contains($0) })
    }

    /// One `live.lanes` ask for the current window. A reply for an older window asks again for
    /// the rows still on screen; a reply from before a playlist or guide change is dropped.
    private func fetch(_ ids: [String]) async {
        guard let playlistId, !ids.isEmpty else { return }
        let mine = epoch, start = windowStart, end = windowEnd
        pending.formUnion(ids)
        let out: [Lane]? = try? await HarborEngine.shared.call("live.lanes", [playlistId, ids, start, end])
        guard mine == epoch else { return }
        pending.subtract(ids)
        guard start == windowStart, end == windowEnd else {
            await fetch(ids.filter { onScreen.contains($0) && needsLane($0) && !pending.contains($0) })
            return
        }
        guard let out else { return }
        var next = lanes
        var replay = catchup
        for l in out {
            next[l.id] = l.cells
            stale.remove(l.id)
            if l.catchup { replay.insert(l.id) } else { replay.remove(l.id) }
        }
        if next.count > Self.cacheMax {
            // laneFor's cache clears at 600; rows off screen are rebuilt when they come back.
            next = next.filter { onScreen.contains($0.key) }
            stale = stale.filter { next[$0] != nil }
        }
        lanes = next
        catchup = replay
    }

    /// bp-guide.tsx extendWindow / extendWindowBack: the window grows now; the lanes on screen
    /// are rebuilt for the new span and keep their old cells until the new ones arrive, so focus
    /// never lands on nothing. Rows off screen are rebuilt when they come back.
    func extend(forward: Bool) async {
        guard windowEnd - windowStart < Self.maxWindowMs else { return }
        var start = windowStart, end = windowEnd
        if forward { end = min(end + Self.extendMs, start + Self.maxWindowMs) }
        else { start = max(start - Self.extendMs, end - Self.maxWindowMs) }
        windowStart = start
        windowEnd = end
        stale = Set(lanes.keys)
        await fillOnScreen()
    }

    /// The guide data changed under the lanes (it finished loading, or the short EPG landed).
    func reloadAll() async {
        epoch += 1
        pending = []
        stale = Set(lanes.keys)
        await fillOnScreen()
        await fill(from: 0)
    }

    /// A manual EPG match changed one channel: rebuild its lane, keep every other one.
    func refresh(_ id: String) async {
        stale.insert(id)
        pending.remove(id)
        await fetch([id])
    }

    /// viewStartFor: pan so the focused cell is visible; a cell wider than the view pins to its start.
    func reveal(cellStart: Double, cellEnd: Double, visibleMs: Double) {
        let last = max(windowStart, windowEnd - visibleMs)
        var next = viewStart
        if cellStart < viewStart { next = cellStart }
        else if cellEnd > viewStart + visibleMs { next = min(cellStart, cellEnd - visibleMs) }
        viewStart = min(max(next, windowStart), last)
    }
}

struct LiveGuideView: View {
    @ObservedObject var live: LiveModel
    @StateObject private var model = LiveGuideModel()
    @FocusState private var focused: String?
    /// bp-guide-portal: the focused cell's channel and programme (GuidePortalView).
    @State private var portal: (channel: LiveModel.Channel, cell: LiveGuideModel.Cell)?
    @State private var now = Date().timeIntervalSince1970 * 1000
    let play: (LiveModel.Channel) -> Void
    let star: (LiveModel.Channel) -> Void
    /// A past programme on a catch-up channel: play the replay instead of the live stream.
    var replay: ((LiveModel.Channel, LiveModel.Program) -> Void)? = nil
    /// The player or a sheet is up: the preview lets go of its stream.
    var previewSuspended = false
    /// guide-view.tsx "Match EPG" (hold Select on a row): pick the guide channel by hand.
    var match: ((LiveModel.Channel) -> Void)? = nil
    /// bp-guide dimmed: the portal hides while the focused row sits under it.
    /// (perf pass) Only the hidden/shown answer is view state. The focused row's edge moves on every
    /// frame of a scroll, and keeping it in @State redrew the whole guide (every row of the category
    /// through ForEach) once per frame; it now sits in a box that redraws nothing.
    @State private var portalHidden = false
    @State private var rowEdge = RowEdge()
    @State private var listHeight: CGFloat = 0
    private final class RowEdge { var maxY: CGFloat? }

    private func updatePortalHidden() {
        var hide = false
        if let y = rowEdge.maxY, listHeight > 0 { hide = y > listHeight - GuidePortalView.height - BP.hintHeight - BP.px(24) }
        if hide != portalHidden { portalHidden = hide }
    }

    // bp-guide-geometry.ts at 1920×1080 (w×0.155 col clamp 220–340, h×0.155 rows 88–128, slot w×0.14 clamp 150–232).
    /// Room inside the list scroller for the channel cell's focus ring (BPTileStyle: 9.5 pt + lift).
    private static let headroom = BP.px(14)
    private let colPx = BP.px(300)
    private let rowPx = BP.px(84)
    private let rulerPx = BP.px(40)
    private let slotPx = BP.px(232)
    private var lanePx: CGFloat { 1920 - BP.gutter * 2 - colPx }
    private var pxPerMs: CGFloat { slotPx / LiveGuideModel.slotMs }
    private var visibleMs: Double { Double(lanePx / pxPerMs) }

    var body: some View {
        VStack(spacing: 0) {
            ruler
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: BP.px(4)) {
                        ForEach(live.visible) { ch in
                            row(ch)
                                .id(ch.id)
                                .onAppear { model.rowAppeared(ch.id) }
                                .onDisappear { model.rowDisappeared(ch.id) }
                        }
                    }
                    .padding(.bottom, BP.px(150) + BP.hintHeight)
                    .padding(.top, BP.px(4))
                    .padding(.horizontal, Self.headroom)
                }
                .onChange(of: live.focusRequest) { _, request in
                    guard let id = request?.channelId else { return }
                    live.focusRequest = nil
                    restoreFocus(to: id, proxy: proxy)
                }
            }
            // (layout pass) The channel cells sit flush with the scroller's left edge, so its clip cut
            // the focused cell's ring and lift (~17 pt out) off its whole left side, and the top of
            // the first row's. bp-grid's HEADROOM: pad inside, pull the scroller out as much; the
            // rows stay where they were.
            .padding(.horizontal, -Self.headroom)
            .coordinateSpace(name: "guideList")
            .background(GeometryReader { g in
                Color.clear
                    .onAppear { listHeight = g.size.height; updatePortalHidden() }
                    .onChange(of: g.size.height) { _, h in listHeight = h; updatePortalHidden() }
            })
            .onPreferenceChange(GuideFocusRowKey.self) { y in MainActor.assumeIsolated { rowEdge.maxY = y; updatePortalHidden() } }
            .overlay(alignment: .bottomTrailing) {
                if let portal, !portalHidden {
                    GuidePortalView(channel: portal.channel, program: portal.cell.program, startMs: portal.cell.startMs, endMs: portal.cell.endMs, now: now, suspended: previewSuspended)
                        .padding(.trailing, BP.px(8) + Self.headroom).padding(.bottom, BP.hintHeight + BP.px(12))
                }
            }
        }
        .task(id: live.visibleIds) {
            let key: String = (live.selectedPlaylist ?? "") + ":" + live.category
            await model.seed(playlistId: live.selectedPlaylist ?? "", channelIds: live.visibleIds, resetKey: key)
        }
        .onChange(of: live.category) { _, _ in portal = nil }
        .task {
            // bp-live-tick: the now line and airing state move every 10 s.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                now = Date().timeIntervalSince1970 * 1000
            }
        }
        .onChange(of: model.windowStart) { _, _ in
            // The window grew backwards: every cell moved; re-assert the focused key so the ring stays put.
            if let f = focused { let keep = f; DispatchQueue.main.async { focused = keep } }
        }
        .onChange(of: live.guideRevision) { _, _ in
            // (bug pass) The lanes were drawn before the guide finished loading; they never refreshed.
            Task { await model.reloadAll() }
        }
        .onChange(of: live.epgMapRevision) { _, _ in
            guard let id = live.lastRemapped else { return }
            Task {
                await model.refresh(id)
                if let f = focused, let hit = cellFor(f) { portal = (hit.1, hit.0) }
                else if portal?.channel.id == id { portal = nil }
            }
        }
        .onChange(of: focused) { old, id in
            // (live sources device pass) use-bp-guide-nav: Right from the channel cell lands on what is
            // airing now. The focus engine took the ring to the lane's left edge (an hour back at
            // first, wherever the lane had been scrolled after that): no way back to now.
            if let old, let id, let chId = Self.starChannel(old), !id.hasSuffix(Self.starSuffix), Self.channelOf(id) == chId,
               let nowKey = airingKey(chId), nowKey != id {
                DispatchQueue.main.async { focused = nowKey }
                return
            }
            guard let id, let hit = cellFor(id) else { return }
            let cell = hit.0
            portal = (hit.1, cell)
            model.reveal(cellStart: cell.startMs, cellEnd: cell.endMs, visibleMs: visibleMs)
            // Reaching an edge grows the window (upstream extends on the last/first cell).
            if cell.endMs >= model.windowEnd { Task { await model.extend(forward: true) } }
            else if cell.startMs <= model.windowStart, model.windowStart > now - LiveGuideModel.maxWindowMs { Task { await model.extend(forward: false) } }
        }
    }

    private static func clock(_ ms: Double) -> String {
        Date(timeIntervalSince1970: ms / 1000).formatted(date: .omitted, time: .shortened)
    }

    private func cellFor(_ key: String) -> (LiveGuideModel.Cell, LiveModel.Channel)? {
        let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2, let ch = live.channel(parts[0]),
              let cell = model.lanes[ch.id]?.first(where: { $0.id == parts[1] }) else { return nil }
        return (cell, ch)
    }

    /// The channel cell's focus key (its star button) is the channel id with this suffix.
    private static let starSuffix = "|\u{2605}"

    private static func starChannel(_ key: String) -> String? {
        guard key.hasSuffix(starSuffix) else { return nil }
        return String(key.dropLast(starSuffix.count))
    }

    private static func channelOf(_ key: String) -> String {
        key.split(separator: "|", maxSplits: 1).first.map(String.init) ?? key
    }

    /// The focus key of the cell airing now on a channel's lane (nil before its lane is built).
    private func airingKey(_ channelId: String) -> String? {
        guard let cells = model.lanes[channelId], let first = cells.first, let last = cells.last else { return nil }
        let t: Double = Date().timeIntervalSince1970 * 1000
        let airing: LiveGuideModel.Cell? = cells.first(where: { $0.startMs <= t && t < $0.endMs })
        let cell: LiveGuideModel.Cell = airing ?? (t < first.startMs ? first : last)
        return channelId + "|" + cell.id
    }

    /// Back from the player after zapping: scroll the playing channel's row in and ring its airing
    /// cell once the lane is there (a row far down is built, and its lane asked, by the scroll).
    private func restoreFocus(to channelId: String, proxy: ScrollViewProxy) {
        guard live.visibleIds.contains(channelId) else { return }
        proxy.scrollTo(channelId, anchor: .center)
        Task { @MainActor in
            for _ in 0..<30 {
                try? await Task.sleep(for: .milliseconds(100))
                if let key = airingKey(channelId) { focused = key; return }
            }
            focused = channelId + Self.starSuffix
        }
    }

    private func x(_ ms: Double) -> CGFloat { CGFloat(ms - model.viewStart) * pxPerMs }

    // bp-guide-ruler: one tick per half hour with a day hint, and the now pill.
    private var ruler: some View {
        HStack(spacing: 0) {
            Text(dayHint(model.viewStart)).font(BP.sans(11, .semibold)).foregroundStyle(BP.inkMuted)
                .frame(width: colPx, alignment: .leading)
            ZStack(alignment: .topLeading) {
                ForEach(ticks, id: \.self) { ms in
                    Text(LiveChannelRow.time(ms)).font(BP.sans(11)).foregroundStyle(BP.inkSubtle)
                        .offset(x: x(ms) + BP.px(4))
                }
                if x(now) >= 0 && x(now) <= lanePx {
                    Text("Now").font(BP.sans(10, .bold)).foregroundStyle(BP.canvas)
                        .padding(.horizontal, BP.px(6)).padding(.vertical, BP.px(2))
                        .background(Capsule().fill(BP.live))
                        .offset(x: max(0, x(now) - BP.px(18)), y: BP.px(16))
                }
            }
            .frame(width: lanePx, height: rulerPx, alignment: .topLeading)
            .clipped()
        }
        .frame(height: rulerPx)
    }

    private var ticks: [Double] {
        var out: [Double] = []
        var ms = model.windowStart
        while ms < model.windowEnd { out.append(ms); ms += LiveGuideModel.slotMs }
        return out
    }

    private func row(_ ch: LiveModel.Channel) -> some View {
        HStack(spacing: 0) {
            // bp-guide-row: the only focusable in the column is the star (Left must mean "earlier").
            Button { star(ch) } label: {
                HStack(spacing: BP.px(10)) {
                    RemoteImage(url: ch.logo, contentMode: .fit).frame(width: BP.px(64), height: BP.px(36))
                    Text(ch.shownName).font(BP.sans(13, .semibold)).foregroundStyle(BP.ink).lineLimit(2)
                    Spacer(minLength: 0)
                    Image(systemName: ch.favorite ? "star.fill" : "star").font(.system(size: BP.px(12), weight: .bold)).foregroundStyle(ch.favorite ? BP.ink : BP.inkSubtle)
                }
                .padding(.horizontal, BP.px(10))
                .frame(width: colPx - BP.px(8), height: rowPx - BP.px(8), alignment: .leading)
                .background(RoundedRectangle(cornerRadius: BP.rXS, style: .continuous).fill(BP.panel2))
            }
            .buttonStyle(BPTileStyle())
            .focused($focused, equals: ch.id + Self.starSuffix)
            .onLongPressGesture(minimumDuration: 0.6) { requestMatch(ch) }
            .frame(width: colPx, alignment: .leading)
            ZStack(alignment: .topLeading) {
                ForEach(model.lanes[ch.id] ?? []) { cell in
                    block(cell, ch)
                }
                if x(now) >= 0 && x(now) <= lanePx {
                    Rectangle().fill(BP.live).frame(width: 2, height: rowPx).offset(x: x(now))
                }
                if showsMatchHint(ch) {
                    // guide-view.tsx: "No program info" + "Match EPG" on a lane the guide cannot fill.
                    HStack(spacing: BP.px(10)) {
                        Text("No program info")
                        HStack(spacing: BP.px(5)) {
                            Image(systemName: "link")
                            Text("Match EPG")
                        }
                        .padding(.horizontal, BP.px(8)).padding(.vertical, BP.px(3))
                        .overlay(RoundedRectangle(cornerRadius: BP.px(6), style: .continuous).stroke(BP.edge2, lineWidth: 1))
                        Text("Hold Select").foregroundStyle(BP.inkSubtle)
                    }
                    .font(BP.sans(11, .medium))
                    .foregroundStyle(BP.inkMuted)
                    .padding(.leading, BP.px(12))
                    .frame(height: rowPx)
                    .allowsHitTesting(false)
                }
            }
            .frame(width: lanePx, height: rowPx, alignment: .topLeading)
            .clipped()
        }
        .frame(height: rowPx)
        .background(GeometryReader { g in
            Color.clear.preference(key: GuideFocusRowKey.self, value: focused?.hasPrefix(ch.id + "|") == true ? g.frame(in: .named("guideList")).maxY : nil)
        })
    }

    // bp-guide-block: past / airing / future paint, three width tiers, chevrons when clipped.
    private func block(_ cell: LiveGuideModel.Cell, _ ch: LiveModel.Channel) -> some View {
        // bp-guide-block: gutter on the inline end only, a 24 px floor for degenerate slices.
        let width = max(BP.px(24), CGFloat(cell.endMs - cell.startMs) * pxPerMs - BP.px(10))
        let empty = cell.program == nil
        let airing = cell.startMs <= now && now < cell.endMs
        let past = cell.endMs <= now
        let tier: Int = width < BP.px(44) ? 0 : (width < BP.px(150) ? 1 : 2)
        let key = "\(ch.id)|\(cell.id)"
        let p = cell.program ?? LiveModel.Program(title: "", description: nil, startMs: cell.startMs, endMs: cell.endMs, category: nil)
        let canReplay = past && !empty && model.catchup.contains(ch.id) && replay != nil
        return Button { if canReplay { replay?(ch, p) } else { play(ch) } } label: {
            VStack(alignment: .leading, spacing: BP.px(3)) {
                HStack(spacing: BP.px(4)) {
                    if p.startMs < cell.startMs { Image(systemName: "chevron.backward").font(.system(size: BP.px(9), weight: .bold)) }
                    if tier > 0 { Text(p.title).font(BP.sans(tier == 2 ? 13 : 11, .semibold)).lineLimit(1) }
                    if canReplay && tier == 2 { Text("Replay").textCase(.uppercase).font(BP.sans(9, .bold)).foregroundStyle(BP.live) }
                    if p.endMs > cell.endMs { Image(systemName: "chevron.forward").font(.system(size: BP.px(9), weight: .bold)) }
                }
                if tier == 2 {
                    Text(LiveChannelRow.range(p)).font(BP.sans(10)).lineLimit(1)
                    if airing {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(BP.edge2)
                                Capsule().fill(BP.live).frame(width: geo.size.width * CGFloat(min(1, max(0, (now - p.startMs) / max(1, p.endMs - p.startMs)))))
                            }
                        }
                        .frame(height: BP.px(3))
                    }
                }
            }
            .foregroundStyle(focused == key ? BP.ink : (airing ? BP.inkMuted : BP.inkSubtle))
            .padding(.horizontal, BP.px(10)).padding(.vertical, BP.px(6))
            .frame(width: width, height: rowPx - BP.px(10), alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: BP.rXS, style: .continuous)
                    .fill(focused == key ? BP.on : empty ? .clear : (airing ? BP.live.opacity(0.14) : (past ? BP.panel2.opacity(0.45) : BP.panel2)))
            )
            .overlay(RoundedRectangle(cornerRadius: BP.rXS, style: .continuous).strokeBorder(empty ? (focused == key ? BP.edge2 : .clear) : (airing ? BP.live.opacity(0.45) : BP.edge2), lineWidth: 1))
            .opacity(past && !empty ? 0.55 : 1)
        }
        .buttonStyle(.plain)
        .focused($focused, equals: key)
        .onLongPressGesture(minimumDuration: 0.6) { requestMatch(ch) }
        .offset(x: x(cell.startMs), y: BP.px(5))
    }

    /// Hold Select anywhere on a row opens the EPG match picker (the guide must list channels).
    private func requestMatch(_ ch: LiveModel.Channel) {
        guard let match, live.guideChannelCount > 0 else { return }
        match(ch)
    }

    /// A lane the guide cannot fill: every cell is a gap.
    private func showsMatchHint(_ ch: LiveModel.Channel) -> Bool {
        guard match != nil, live.guideChannelCount > 0, let cells = model.lanes[ch.id], !cells.isEmpty else { return false }
        return cells.allSatisfy { $0.program == nil }
    }

    private func dayHint(_ ms: Double) -> String {
        let cal = Calendar.current
        let d = Date(timeIntervalSince1970: ms / 1000)
        if cal.isDateInToday(d) { return T("Today") }
        if cal.isDateInTomorrow(d) { return T("Tomorrow") }
        if cal.isDateInYesterday(d) { return T("Yesterday") }
        let f = DateFormatter(); f.locale = L10n.locale; f.setLocalizedDateFormatFromTemplate("EEEMMMd"); return f.string(from: d)
    }
}

/// The focused guide row's bottom edge in the list's viewport (nil when no cell has focus).
private struct GuideFocusRowKey: PreferenceKey {
    static var defaultValue: CGFloat? = nil
    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) { if let n = nextValue() { value = n } }
}
