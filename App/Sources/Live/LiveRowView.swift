import SwiftUI

/// bp-live-row.tsx on Home: the active playlist's ranked channels as guide cells (logo, what's on,
/// progress, what's next); Select tunes the channel. Renders nothing without playlists.
@MainActor
final class LiveRowModel: ObservableObject {
    struct Cell: Decodable, Identifiable {
        var playlistId: String; var channel: LiveModel.Channel; var now: LiveModel.Program?; var next: LiveModel.Program?; var progress: Double?
        var id: String { channel.id }
    }
    struct Row: Decodable { var playlistId: String?; var cells: [Cell] }
    @Published private(set) var cells: [Cell] = []
    @Published private(set) var loaded = false

    func load() async {
        guard !loaded else { return }
        if let r: Row = try? await HarborEngine.shared.call("live.homeRow", []) { cells = r.cells }
        loaded = true
    }

    /// (device-flow pass 4) bp-live-cell: nowMs advances at a programme boundary, so a cell never
    /// keeps a programme that has ended. The row was read once per Home visit: a viewer left on
    /// Home saw last hour's show as "now" (with a full bar) until they left the tab. Read again
    /// when a cell's programme has ended, at most once a minute.
    private var lastRefresh = Date.distantPast
    func refreshIfEnded(nowMs: Double) async {
        guard loaded, Date().timeIntervalSince(lastRefresh) >= 60 else { return }
        guard cells.contains(where: { ($0.now?.endMs ?? Double.infinity) <= nowMs }) else { return }
        lastRefresh = Date()
        // A read that comes back empty (the source is reloading) keeps the row under the ring.
        if let r: Row = try? await HarborEngine.shared.call("live.homeRow", []), !r.cells.isEmpty { cells = r.cells }
    }

    func played(_ c: Cell) {
        Task { _ = try? await HarborEngine.shared.callJSON("live.recordPlay", [.string(c.playlistId), .string(c.channel.id)]) }
    }
}

struct LiveRowView: View {
    @StateObject private var model = LiveRowModel()
    @State private var playing: LiveRowModel.Cell?
    @FocusState private var focusedId: String?
    /// (focus pass) The header's Guide link holds the ring: the row still counts as focused, as
    /// BPRowView's See all does (bp-row-header shows the link while [data-bp-row-focus]).
    @FocusState private var guideFocused: Bool
    let onOpenGuide: () -> Void
    /// bp-live-row onHot: the focused cell (nil once focus leaves the row), for Home's band and
    /// its ambient preview (bp-live-hero); and whether this row's player is up.
    var onHot: ((LiveRowModel.Cell?) -> Void)? = nil
    var onPlaying: ((Bool) -> Void)? = nil
    /// bp-live-tick (10 s): the cells' progress bars follow the clock (BpLiveProgress).
    @State private var nowMs: Double = Date().timeIntervalSince1970 * 1000

    var body: some View {
        Group {
            if !model.cells.isEmpty {
                VStack(alignment: .leading, spacing: BP.px(10)) {
                    HStack(spacing: BP.px(14)) {
                        Text("Live TV").font(BP.sans(19, .bold)).foregroundStyle(BP.ink.opacity(focusedId == nil && !guideFocused ? 0.55 : 1)).accessibilityAddTraits(.isHeader)
                        // (focus pass) Shown only while a cell held focus, so Up onto it took the ring
                        // off every cell, the link vanished under it and the ring fell elsewhere.
                        if focusedId != nil || guideFocused {
                            Button("Guide") { onOpenGuide() }.buttonStyle(BPActionStyle())
                                .focused($guideFocused)
                        }
                    }
                    .padding(.horizontal, BP.gutter)
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: BP.trackGap) {
                            ForEach(model.cells) { c in
                                Button { model.played(c); playing = c } label: { cell(c) }
                                    .buttonStyle(BPTileStyle(radius: BP.rSM))
                                    .focused($focusedId, equals: c.id)
                                    // (layout pass) As the rail tiles and CW cards: the lifted cell's shadow
                                    // and ring draw over the opaque cell after it.
                                    .zIndex(focusedId == c.id ? 1 : 0)
                            }
                        }
                        .padding(.horizontal, BP.gutter).padding(.vertical, BP.px(14))
                    }
                    .scrollClipDisabled()
                }
                .focusSection()
            }
        }
        .task {
            await model.load()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled else { return }
                nowMs = Date().timeIntervalSince1970 * 1000
                await model.refreshIfEnded(nowMs: nowMs)
            }
        }
        .onChange(of: focusedId) { _, id in onHot?(id.flatMap { key in model.cells.first(where: { $0.id == key }) }) }
        .onChange(of: playing?.id) { _, id in onPlaying?(id != nil) }
        .fullScreenCover(item: $playing) { c in
            PlayerScreen(title: c.channel.shownName, subtitle: c.now?.title ?? c.channel.groupLabel ?? c.channel.group, url: URL(string: c.channel.url) ?? URL(string: "about:blank")!,
                         headers: c.channel.headers ?? [:], isLive: true) { _ in playing = nil }
        }
    }

    /// BpLiveProgress: (now - start) / (end - start) at the tick, else the engine's reading.
    private func progress(_ c: LiveRowModel.Cell) -> Double? {
        guard let p = c.now, p.endMs > p.startMs else { return c.progress }
        let ratio: Double = (nowMs - p.startMs) / (p.endMs - p.startMs)
        return min(1, max(0, ratio))
    }

    // bp-live-cell: logo plate, channel name with its quality badge, current programme and its progress, then next.
    private func cell(_ c: LiveRowModel.Cell) -> some View {
        VStack(alignment: .leading, spacing: BP.px(6)) {
            HStack(spacing: BP.px(8)) {
                RemoteImage(url: c.channel.logo, contentMode: .fit).frame(width: BP.px(56), height: BP.px(32))
                    .background(RoundedRectangle(cornerRadius: BP.px(5), style: .continuous).fill(BP.void_.opacity(0.6)))
                Text(c.channel.shownName).font(BP.sans(12, .semibold)).foregroundStyle(BP.ink).lineLimit(1)
                if let b = c.channel.badge { Text(b).font(BP.sans(8, .bold)).foregroundStyle(BP.inkMuted) }
                Spacer(minLength: 0)
                if c.channel.favorite { Image(systemName: "star.fill").font(.system(size: BP.px(9))).foregroundStyle(BP.ink).accessibilityLabel(Text(T("Favorite"))) }
            }
            Text(c.now?.title ?? T(c.next == nil ? "Live" : "No program info")).font(BP.sans(13, .bold)).foregroundStyle(BP.ink).lineLimit(1)
            if let p = progress(c) {
                ZStack(alignment: .leading) { Capsule().fill(BP.edge2); Capsule().fill(BP.live).frame(width: (BP.px(250) - BP.px(24)) * min(1, max(0, p))) }
                    .frame(height: BP.px(3))
            }
            if let n = c.next { Text(T("Next:") + " " + n.title).font(BP.sans(10.5)).foregroundStyle(BP.inkSubtle).lineLimit(1) }
        }
        .padding(BP.px(12))
        .frame(width: BP.px(250), height: BP.px(110), alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).fill(BP.panel))
        .overlay(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).stroke(BP.edge, lineWidth: 1))
    }
}
