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
    struct Lane: Decodable { var id: String; var cells: [Cell] }

    static let slotMs: Double = 30 * 60_000
    static let pastPadMs: Double = 60 * 60_000
    static let initialWindowMs: Double = 6 * 60 * 60_000
    static let extendMs: Double = 3 * 60 * 60_000
    static let maxWindowMs: Double = 26 * 60 * 60_000

    @Published private(set) var lanes: [String: [Cell]] = [:]
    @Published private(set) var windowStart: Double = 0
    @Published private(set) var windowEnd: Double = 0
    @Published var viewStart: Double = 0

    private var playlistId: String?
    private var channelIds: [String] = []

    func seed(playlistId: String, channelIds: [String]) async {
        let now = Date().timeIntervalSince1970 * 1000
        if windowStart == 0 {
            windowStart = (((now - Self.pastPadMs) / Self.slotMs).rounded(.down)) * Self.slotMs
            windowEnd = windowStart + Self.initialWindowMs
            viewStart = windowStart
        }
        let changedList = self.playlistId != playlistId || self.channelIds != channelIds
        self.playlistId = playlistId
        self.channelIds = channelIds
        if changedList { lanes = [:] }
        await load(ids: channelIds)
    }

    private func load(ids: [String]) async {
        guard let playlistId, !ids.isEmpty else { return }
        let missing = ids.filter { lanes[$0] == nil }
        guard !missing.isEmpty else { return }
        if let out: [Lane] = try? await HarborEngine.shared.call("live.lanes", [playlistId, missing, windowStart, windowEnd]) {
            var next = lanes
            for l in out { next[l.id] = l.cells }
            lanes = next
        }
    }

    /// bp-guide.tsx extendWindow / extendWindowBack: every lane is rebuilt for the new span.
    func extend(forward: Bool) async {
        guard windowEnd - windowStart < Self.maxWindowMs else { return }
        if forward { windowEnd = min(windowEnd + Self.extendMs, windowStart + Self.maxWindowMs) }
        else { windowStart = max(windowStart - Self.extendMs, windowEnd - Self.maxWindowMs) }
        lanes = [:]
        await load(ids: channelIds)
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
    @State private var now = Date().timeIntervalSince1970 * 1000
    let play: (LiveModel.Channel) -> Void
    let star: (LiveModel.Channel) -> Void

    // bp-guide-geometry.ts at 1920×1080 (w×0.155 col clamp 220–340, h×0.155 rows 88–128, slot w×0.14 clamp 150–232).
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
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: BP.px(4)) {
                    ForEach(live.visible) { ch in row(ch) }
                }
                .padding(.bottom, BP.hintHeight + BP.px(40))
            }
        }
        .task(id: live.visible.map(\.id)) {
            await model.seed(playlistId: live.selectedPlaylist ?? "", channelIds: live.visible.map(\.id))
        }
        .task {
            // bp-live-tick: the now line and airing state move every 10 s.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                now = Date().timeIntervalSince1970 * 1000
            }
        }
        .onChange(of: focused) { _, id in
            guard let id, let hit = cellFor(id) else { return }
            let cell = hit.0
            model.reveal(cellStart: cell.startMs, cellEnd: cell.endMs, visibleMs: visibleMs)
            // Reaching an edge grows the window (upstream extends on the last/first cell).
            if cell.endMs >= model.windowEnd { Task { await model.extend(forward: true) } }
            else if cell.startMs <= model.windowStart, model.windowStart > now - LiveGuideModel.maxWindowMs { Task { await model.extend(forward: false) } }
        }
    }

    private func cellFor(_ key: String) -> (LiveGuideModel.Cell, LiveModel.Channel)? {
        let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2, let ch = live.visible.first(where: { $0.id == parts[0] }),
              let cell = model.lanes[ch.id]?.first(where: { $0.id == parts[1] }) else { return nil }
        return (cell, ch)
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
                    Text(ch.name).font(BP.sans(13, .semibold)).foregroundStyle(BP.ink).lineLimit(2)
                    Spacer(minLength: 0)
                    Image(systemName: ch.favorite ? "star.fill" : "star").font(.system(size: BP.px(12), weight: .bold)).foregroundStyle(ch.favorite ? BP.ink : BP.inkSubtle)
                }
                .padding(.horizontal, BP.px(10))
                .frame(width: colPx - BP.px(8), height: rowPx - BP.px(8), alignment: .leading)
                .background(RoundedRectangle(cornerRadius: BP.rXS, style: .continuous).fill(BP.panel2))
            }
            .buttonStyle(BPTileStyle())
            .frame(width: colPx, alignment: .leading)
            ZStack(alignment: .topLeading) {
                ForEach(model.lanes[ch.id] ?? []) { cell in
                    if cell.program != nil { block(cell, ch) }
                }
                if x(now) >= 0 && x(now) <= lanePx {
                    Rectangle().fill(BP.live).frame(width: 2, height: rowPx).offset(x: x(now))
                }
            }
            .frame(width: lanePx, height: rowPx, alignment: .topLeading)
            .clipped()
        }
        .frame(height: rowPx)
    }

    // bp-guide-block: past / airing / future paint, three width tiers, chevrons when clipped.
    private func block(_ cell: LiveGuideModel.Cell, _ ch: LiveModel.Channel) -> some View {
        let width = max(BP.px(8), CGFloat(cell.endMs - cell.startMs) * pxPerMs - BP.px(6))
        let airing = cell.startMs <= now && now < cell.endMs
        let past = cell.endMs <= now
        let tier: Int = width < BP.px(44) ? 0 : (width < BP.px(150) ? 1 : 2)
        let key = "\(ch.id)|\(cell.id)"
        let p = cell.program ?? LiveModel.Program(title: "", description: nil, startMs: cell.startMs, endMs: cell.endMs, category: nil)
        return Button { play(ch) } label: {
            VStack(alignment: .leading, spacing: BP.px(3)) {
                HStack(spacing: BP.px(4)) {
                    if p.startMs < cell.startMs { Image(systemName: "chevron.left").font(.system(size: BP.px(9), weight: .bold)) }
                    if tier > 0 { Text(p.title).font(BP.sans(tier == 2 ? 13 : 11, .semibold)).lineLimit(1) }
                    if p.endMs > cell.endMs { Image(systemName: "chevron.right").font(.system(size: BP.px(9), weight: .bold)) }
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
                    .fill(focused == key ? BP.on : (airing ? BP.live.opacity(0.14) : (past ? BP.panel2.opacity(0.45) : BP.panel2)))
            )
            .overlay(RoundedRectangle(cornerRadius: BP.rXS, style: .continuous).strokeBorder(airing ? BP.live.opacity(0.45) : BP.edge2, lineWidth: 1))
            .opacity(past ? 0.55 : 1)
        }
        .buttonStyle(.plain)
        .focused($focused, equals: key)
        .offset(x: x(cell.startMs), y: BP.px(5))
    }

    private func dayHint(_ ms: Double) -> String {
        let cal = Calendar.current
        let d = Date(timeIntervalSince1970: ms / 1000)
        if cal.isDateInToday(d) { return "Today" }
        if cal.isDateInTomorrow(d) { return "Tomorrow" }
        if cal.isDateInYesterday(d) { return "Yesterday" }
        let f = DateFormatter(); f.dateFormat = "EEE, MMM d"; return f.string(from: d)
    }
}
