import SwiftUI

/// Multiview (views/multiview.tsx, multiview/grid.tsx, multiview/cell.tsx, lib/multiview/store.ts):
/// up to four live channels at once in a 1 / 2 / Stacked / 3 / 2x2 layout, one tile with the
/// sound. Desktop draws each tile as a separate native window (Windows only); here every tile is
/// its own MPVPlayerController in `tile` mode: muted unless it holds the audio focus, a short live
/// cache, and it never touches the TV's display mode or HDR. The desktop drag-to-resize splits
/// are not ported (tiles split evenly); the layout is remembered like upstream's.
@MainActor
final class MultiviewModel: ObservableObject {
    typealias Channel = LiveModel.Channel

    /// bridge.ts MAX_SLOTS.
    static let maxSlots = 4
    /// multiview.tsx LAYOUTS with their titles; the chip shows the id ("Stacked" for 2v).
    static let layouts: [(id: String, title: String)] = [("1", "Single"), ("2", "Side by side"), ("2v", "Stacked"), ("3", "Triple"), ("2x2", "Quad")]

    /// store.ts layoutSlotCount.
    static func slotCount(_ layout: String) -> Int {
        switch layout {
        case "1": return 1
        case "2", "2v": return 2
        case "3": return 3
        default: return 4
        }
    }

    @Published private(set) var slots: [Channel?] = Array(repeating: nil, count: MultiviewModel.maxSlots)
    @Published private(set) var layout = "2x2"
    /// The tile with the sound; -1 = every tile muted (the cell's Mute button).
    @Published private(set) var audioFocus = 0
    @Published private(set) var bannerDismissed = true
    /// Channels of sources other than the Live room's, loaded when the picker asks for them.
    @Published private(set) var otherChannels: [String: [Channel]] = [:]
    @Published private(set) var loadingOther: Set<String> = []

    var slotCount: Int { Self.slotCount(layout) }
    var activeCount: Int { slots.prefix(slotCount).compactMap { $0 }.count }

    func loadPrefs() async {
        struct Prefs: Decodable { var layout: String; var bannerDismissed: Bool }
        if let p: Prefs = try? await HarborEngine.shared.call("live.multiviewPrefs", []) {
            layout = p.layout
            bannerDismissed = p.bannerDismissed
        } else {
            bannerDismissed = false
        }
    }

    /// store.ts setLayout (persisted).
    func setLayout(_ l: String) {
        guard Self.layouts.contains(where: { $0.id == l }) else { return }
        layout = l
        Task { _ = try? await HarborEngine.shared.callJSON("live.setMultiviewLayout", [.string(l)]) }
    }

    func dismissBanner() {
        bannerDismissed = true
        Task { _ = try? await HarborEngine.shared.callJSON("live.dismissMultiviewBanner", []) }
    }

    /// multiview.tsx ChannelPicker onPick: the first channel into an empty grid takes the sound.
    func pick(_ slot: Int, _ ch: Channel) {
        guard slots.indices.contains(slot) else { return }
        let wasEmpty = slots.allSatisfy { $0 == nil }
        slots[slot] = ch
        if wasEmpty { audioFocus = slot }
    }

    /// multiview.tsx closeSlot: the sound moves to the first other filled tile (else tile 1).
    func close(_ slot: Int) {
        guard slots.indices.contains(slot) else { return }
        slots[slot] = nil
        if audioFocus == slot {
            audioFocus = slots.indices.first { $0 != slot && slots[$0] != nil } ?? 0
        }
    }

    func setAudioFocus(_ slot: Int) { audioFocus = slot }

    /// store.ts reset ("Clear all", and when Multiview closes).
    func reset() {
        slots = Array(repeating: nil, count: Self.maxSlots)
        audioFocus = 0
    }

    /// channel-picker.tsx playlists: another source's channels, through the same engine call the Live room uses.
    func loadChannels(of playlistId: String) async {
        guard otherChannels[playlistId] == nil, !loadingOther.contains(playlistId) else { return }
        loadingOther.insert(playlistId)
        defer { loadingOther.remove(playlistId) }
        if let v: LiveModel.View_ = try? await HarborEngine.shared.call("live.channels", [playlistId, false]) {
            otherChannels[playlistId] = v.channels
        } else {
            otherChannels[playlistId] = []
        }
    }
}

struct MultiviewView: View {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var live: LiveModel
    /// "Add to Multiview" from the player: this channel starts in tile 1 with the sound.
    let seed: LiveModel.Channel?
    let dismiss: () -> Void

    @StateObject private var model = MultiviewModel()
    @State private var pickerSlot: Int?
    /// multiview.tsx collapsed: "Hide controls, full grid"; Back brings them back.
    @State private var collapsed = false
    /// A tile promoted to the full player; every tile lets go of its stream meanwhile (IPTV
    /// accounts commonly allow one or two connections, and the full player wants the decoder).
    @State private var fullScreen: LiveModel.Channel?
    @State private var seeded = false
    /// Multiview's hold on PlaybackState (the players it opens hold their own).
    @State private var playbackClaim = UUID()
    @FocusState private var focus: Target?
    enum Target: Hashable { case cell(Int), band(String) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            BP.void_.ignoresSafeArea()
            VStack(alignment: .leading, spacing: BP.px(12)) {
                if !collapsed {
                    band
                    if !model.bannerDismissed { banner }
                }
                grid
            }
            // The picker covers everything; nothing underneath may take the ring meanwhile.
            .disabled(pickerSlot != nil)
            .padding(.horizontal, collapsed ? BP.px(16) : BP.gutter)
            .padding(.top, collapsed ? BP.px(16) : BP.px(40))
            .padding(.bottom, collapsed ? BP.px(16) : BP.px(30))
            if let slot = pickerSlot {
                MultiviewPicker(live: live, model: model, slot: slot,
                                onPick: { ch in model.pick(slot, ch); closePicker(slot) },
                                onClose: { closePicker(slot) })
                    .transition(.opacity)
            }
        }
        .animation(BP.easeFast, value: pickerSlot)
        .animation(BP.easeFast, value: collapsed)
        .onExitCommand {
            if let slot = pickerSlot { closePicker(slot) }
            else if collapsed { collapsed = false }
            else { leave() }
        }
        .task {
            await model.loadPrefs()
            if !seeded, let seed {
                seeded = true
                model.pick(0, seed)
            }
            focusLater(.cell(0))
        }
        .onAppear {
            // Opened from the PiP browse layer: the film in Picture in Picture stops first (PiPBrowse).
            PiPBrowse.shared.playbackOpening(nil)
            PlaybackState.shared.claim(playbackClaim)
        }
        // No reset here: presenting the full player can report a disappear while Multiview stays
        // underneath; the grid is cleared by leave() and goes with this view otherwise.
        .onDisappear { if fullScreen == nil { PlaybackState.shared.release(playbackClaim) } }
        .fullScreenCover(item: $fullScreen, onDismiss: { PlaybackState.shared.claim(playbackClaim) }) { ch in
            // The grid is under this player: its PiP keeps the placard rather than stepping aside.
            PlayerScreen(title: ch.name, subtitle: live.guide[ch.id]?.now?.title ?? ch.group, url: URL(string: ch.url) ?? URL(string: "about:blank")!,
                         headers: ch.headers ?? [:], isLive: true, liveGuide: live, liveChannel: ch, browseDuringPiP: false) { _ in fullScreen = nil }
        }
    }

    private func leave() {
        model.reset()
        dismiss()
    }

    private func closePicker(_ slot: Int) {
        pickerSlot = nil
        focusLater(.cell(slot))
    }

    private func focusLater(_ t: Target) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { focus = t }
    }

    // multiview.tsx toolbar: the layout segmented control, "Clear all", the collapse toggle.
    private var band: some View {
        HStack(spacing: BP.px(8)) {
            Button { leave() } label: { Label("Back", systemImage: "chevron.left") }
                .buttonStyle(BPActionStyle())
                .focused($focus, equals: .band("back"))
            Text("Multiview").font(BP.display(26)).foregroundStyle(BP.ink).padding(.horizontal, BP.px(10))
            ForEach(MultiviewModel.layouts, id: \.id) { l in
                Button { model.setLayout(l.id) } label: {
                    HStack(spacing: BP.px(6)) {
                        Image(systemName: l.id == "2x2" ? "square.grid.2x2" : l.id == "2v" ? "rectangle.split.1x2" : "square")
                        Text(l.id == "2v" ? T(l.title) : l.id)
                    }
                }
                .buttonStyle(BPActionStyle(primary: model.layout == l.id))
                .accessibilityLabel(T(l.title))
                .focused($focus, equals: .band(l.id))
            }
            Button { model.reset() } label: { Label("Clear all", systemImage: "stop.circle") }
                .buttonStyle(BPActionStyle())
            Spacer(minLength: 0)
            Button { collapsed = true; focusLater(.cell(max(0, min(model.audioFocus, model.slotCount - 1)))) } label: {
                Label("Hide controls", systemImage: "chevron.up")
            }
            .buttonStyle(BPActionStyle())
        }
        .focusSection()
    }

    private var banner: some View {
        HStack(alignment: .top, spacing: BP.px(12)) {
            Image(systemName: "info.circle").foregroundStyle(BP.inkSubtle)
            Text("Most IPTV providers cap simultaneous streams per account (commonly 1–2). If a tile drops to \"Stream offline\" while others play, your provider may be throttling. Try closing a stream and retrying.")
                .font(BP.sans(13)).foregroundStyle(BP.inkMuted).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Dismiss") { model.dismissBanner() }.buttonStyle(BPActionStyle())
        }
        .padding(.horizontal, BP.px(14)).padding(.vertical, BP.px(10))
        .background(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).fill(BP.panel2.opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).stroke(BP.edge, lineWidth: 1))
        .focusSection()
    }

    // grid.tsx: "2" columns, "2v" rows, "3" three columns, "2x2" two columns of two (tiles 1–2
    // on the left, 3–4 on the right). Only the layout's tiles mount a player.
    @ViewBuilder private var grid: some View {
        let gap = BP.px(10)
        switch model.layout {
        case "1":
            cell(0)
        case "2":
            HStack(spacing: gap) { cell(0); cell(1) }
        case "2v":
            VStack(spacing: gap) { cell(0); cell(1) }
        case "3":
            HStack(spacing: gap) { cell(0); cell(1); cell(2) }
        default:
            HStack(spacing: gap) {
                VStack(spacing: gap) { cell(0); cell(1) }
                VStack(spacing: gap) { cell(2); cell(3) }
            }
        }
    }

    private func cell(_ i: Int) -> some View {
        let ch = model.slots[i]
        // The app declares background audio for music; the tile with the sound goes quiet when
        // the viewer leaves the app instead of sounding from the home screen.
        return MultiviewCell(slot: i, channel: ch, audio: model.audioFocus == i && scenePhase != .background,
                             nowTitle: ch.flatMap { live.guide[$0.id]?.now?.title },
                             // The `audio` background mode keeps the app alive off screen: every
                             // tile lets go of its stream until the scene is active again.
                             suspended: fullScreen != nil || scenePhase != .active,
                             focus: $focus,
                             onPick: { pickerSlot = i },
                             onClose: { model.close(i); focusLater(.cell(i)) },
                             onFocus: { model.setAudioFocus(i) },
                             onMute: { model.setAudioFocus(-1) },
                             onFullScreen: { if let ch { fullScreen = ch } })
            // cell.tsx resets its status and retry count when the channel changes.
            .id("\(i)|\(ch?.url ?? "")")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// cell.tsx: an empty tile ("Add a channel"), or a channel's header (name, Change channel,
/// Mute / Unmute this cell, full screen, Close cell) over its player, with the loading /
/// "Reconnecting…" / "Stream offline" states and two automatic retries (2.5 s, then 6 s).
struct MultiviewCell: View {
    let slot: Int
    let channel: LiveModel.Channel?
    let audio: Bool
    let nowTitle: String?
    let suspended: Bool
    var focus: FocusState<MultiviewView.Target?>.Binding
    let onPick: () -> Void
    let onClose: () -> Void
    let onFocus: () -> Void
    let onMute: () -> Void
    let onFullScreen: () -> Void

    enum SlotStatus { case loading, playing, retrying, offline }
    private static let maxAutoRetries = 2
    private static let backoff: [Duration] = [.milliseconds(2500), .milliseconds(6000)]
    /// multi-player.tsx STALL_GRACE_MS: this long without playing is a dead channel.
    private static let stallGrace: TimeInterval = 12

    @State private var status: SlotStatus = .loading
    @State private var attempt = 0
    @State private var attemptsUsed = 0
    @State private var retryTask: Task<Void, Never>?
    @State private var notPlayingSince: Date?

    private var exhausted: Bool { status == .offline && attemptsUsed >= Self.maxAutoRetries }

    var body: some View {
        if let channel {
            filled(channel)
        } else {
            Button(action: onPick) {
                VStack(spacing: BP.px(12)) {
                    Image(systemName: "plus")
                        .font(.system(size: BP.px(22), weight: .semibold))
                        .foregroundStyle(BP.inkMuted)
                        .frame(width: BP.px(48), height: BP.px(48))
                        .background(Circle().fill(BP.panel2))
                    Text("Add a channel").font(BP.sans(13, .medium)).foregroundStyle(BP.inkMuted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: BP.rMD, style: .continuous).fill(BP.panel.opacity(0.4)))
                .overlay(RoundedRectangle(cornerRadius: BP.rMD, style: .continuous).strokeBorder(BP.edge2, style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])))
            }
            .buttonStyle(MultiviewTileStyle())
            .focused(focus, equals: .cell(slot))
        }
    }

    private func filled(_ ch: LiveModel.Channel) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: BP.px(6)) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(ch.shownName).font(BP.sans(12, .semibold)).foregroundStyle(BP.ink).lineLimit(1)
                    if let nowTitle { Text(nowTitle).font(BP.sans(10)).foregroundStyle(BP.inkMuted).lineLimit(1) }
                }
                Spacer(minLength: BP.px(4))
                Button(action: onPick) { Image(systemName: "arrow.2.squarepath") }
                    .buttonStyle(BPTabStyle(active: false))
                    .accessibilityLabel("Change channel")
                Button { if audio { onMute() } else { onFocus() } } label: {
                    Image(systemName: audio ? "speaker.wave.2.fill" : "speaker.slash.fill")
                }
                .buttonStyle(BPTabStyle(active: audio))
                .accessibilityLabel(audio ? "Mute" : "Unmute this cell")
                Button(action: onFullScreen) { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                    .buttonStyle(BPTabStyle(active: false))
                    .accessibilityLabel("Full screen")
                Button(action: onClose) { Image(systemName: "xmark") }
                    .buttonStyle(BPTabStyle(active: false))
                    .accessibilityLabel("Close cell")
            }
            .padding(.horizontal, BP.px(10)).padding(.vertical, BP.px(4))
            .background(BP.panel)
            .focusSection()
            ZStack {
                Color.black
                if !exhausted, !suspended, let url = URL(string: ch.url) {
                    let mine = attempt
                    MPVPlayerView(url: url, headers: ch.headers ?? [:], isLive: true, tile: true, muted: !audio,
                                  onStatus: { st in onPlayerStatus(st, attempt: mine) })
                        .id(mine)
                        .allowsHitTesting(false)
                }
                // The tile body: Select gives this tile the sound (cell.tsx onClick → onFocus).
                Button { if status == .offline { manualRetry() } else { onFocus() } } label: {
                    overlay.frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle())
                }
                .buttonStyle(MultiviewTileStyle(radius: 0))
                .focused(focus, equals: .cell(slot))
                .accessibilityLabel(audio ? ch.shownName + ", sound on" : ch.shownName)
            }
            .clipped()
        }
        .clipShape(RoundedRectangle(cornerRadius: BP.rMD, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: BP.rMD, style: .continuous).strokeBorder(audio ? BP.accent : BP.edge, lineWidth: audio ? 3 : 1))
        .onDisappear { retryTask?.cancel(); retryTask = nil }
        // Back from the full player: the tile opens its stream again from scratch.
        .onChange(of: suspended) { _, on in
            guard !on else { return }
            retryTask?.cancel()
            retryTask = nil
            notPlayingSince = nil
            status = .loading
            attempt += 1
        }
    }

    @ViewBuilder private var overlay: some View {
        if status != .playing || suspended {
            VStack(spacing: BP.px(8)) {
                if status == .offline {
                    Image(systemName: "exclamationmark.triangle").font(.system(size: BP.px(22))).foregroundStyle(BP.danger)
                    Text("Stream offline").font(BP.sans(12, .medium)).foregroundStyle(BP.inkMuted)
                    if exhausted {
                        Text("If multiple streams are running, your IPTV provider may limit concurrent connections.")
                            .font(BP.sans(11)).foregroundStyle(BP.inkSubtle).multilineTextAlignment(.center)
                            .frame(maxWidth: BP.px(300))
                    }
                    // cell.tsx Retry: Select on the tile retries while it is offline.
                    Label("Retry", systemImage: "arrow.clockwise").font(BP.sans(11.5, .medium)).foregroundStyle(BP.inkMuted)
                } else if !suspended {
                    ProgressView().tint(BP.inkMuted)
                    if status == .retrying { Text("Reconnecting…").font(BP.sans(11, .medium)).foregroundStyle(BP.inkMuted) }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black.opacity(0.3))
        } else {
            Color.clear
        }
    }

    /// mpv status → cell.tsx onPlayerPlaying / onPlayerError. A stale attempt's late report is ignored.
    private func onPlayerStatus(_ st: MPVPlayerController.Status, attempt mine: Int) {
        guard mine == attempt, !suspended else { return }
        if st.state == "playing" {
            notPlayingSince = nil
            onPlayerPlaying()
            return
        }
        if st.state == "error" { onPlayerError(); return }
        // multi-player.tsx: a stall longer than the grace window counts as a failure.
        let now = Date()
        if let since = notPlayingSince {
            if now.timeIntervalSince(since) > Self.stallGrace { notPlayingSince = nil; onPlayerError() }
        } else {
            notPlayingSince = now
        }
    }

    private func onPlayerPlaying() {
        retryTask?.cancel()
        retryTask = nil
        attemptsUsed = 0
        status = .playing
    }

    private func onPlayerError() {
        if retryTask != nil { return }
        if status == .offline { return }
        if attemptsUsed >= Self.maxAutoRetries {
            status = .offline
            return
        }
        let delay = Self.backoff[min(attemptsUsed, Self.backoff.count - 1)]
        status = .retrying
        retryTask = Task { @MainActor in
            try? await Task.sleep(for: delay)
            if Task.isCancelled { return }
            retryTask = nil
            attemptsUsed += 1
            notPlayingSince = nil
            attempt += 1
            status = .loading
        }
    }

    /// cell.tsx manualRetry.
    private func manualRetry() {
        retryTask?.cancel()
        retryTask = nil
        attemptsUsed = 0
        notPlayingSince = nil
        status = .loading
        attempt += 1
    }
}

/// The tile's focus ring (bp-tokens focus ring without the lift: a video tile does not grow).
struct MultiviewTileStyle: ButtonStyle {
    var radius: CGFloat = BP.rMD
    func makeBody(configuration: Configuration) -> some View {
        BPFocusReader { focused in
            configuration.label
                .overlay {
                    if focused {
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .inset(by: 3)
                            .stroke(BP.focusStroke, lineWidth: 5)
                    }
                }
                .opacity(configuration.isPressed ? 0.85 : 1)
        }
    }
}

/// channel-picker.tsx on the TV: "Add to tile {n}", the source scope (this source, another, or
/// all of them), a search field, the shared channel list, and a pasted stream URL.
struct MultiviewPicker: View {
    @ObservedObject var live: LiveModel
    @ObservedObject var model: MultiviewModel
    let slot: Int
    let onPick: (LiveModel.Channel) -> Void
    let onClose: () -> Void

    private static let allPlaylists = "__ALL_PLAYLISTS__"
    @State private var scope: String?
    @State private var group: String?
    @State private var query = ""
    @State private var manual = ""

    private var currentId: String? { live.selectedPlaylist }
    private var scopeId: String { scope ?? currentId ?? "" }

    private var channels: [LiveModel.Channel] {
        if scopeId == Self.allPlaylists {
            var out = live.channels
            for pl in live.playlists where pl.id != currentId { out += model.otherChannels[pl.id] ?? [] }
            return out
        }
        if scopeId == currentId { return live.channels }
        return model.otherChannels[scopeId] ?? []
    }

    private var loading: Bool {
        if scopeId == Self.allPlaylists { return !model.loadingOther.isEmpty }
        if scopeId == currentId { return live.loading }
        return model.loadingOther.contains(scopeId)
    }

    /// channel-picker.tsx groups: first-seen order over the scoped channels.
    private var groups: [String] {
        if scopeId == currentId { return live.groups.map(\.name) }
        var seen = Set<String>(), out: [String] = []
        for c in channels { if let g = c.group, !seen.contains(g) { seen.insert(g); out.append(g) } }
        return out
    }

    private var placeholder: String {
        if loading && channels.isEmpty { return "Loading channels…" }
        return channels.count == 1 ? T("Search %lld channel", 1) : T("Search %lld channels", channels.count)
    }

    /// Now/next is only known for the Live room's source.
    private var guideLoader: (([String]) async -> Void)? {
        guard scopeId == currentId else { return nil }
        let live = self.live
        return { ids in await live.refreshNowNext(ids: ids) }
    }

    private var manualValid: Bool {
        manual.trimmingCharacters(in: .whitespaces).range(of: "^https?://", options: [.regularExpression, .caseInsensitive]) != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: BP.px(14)) {
            HStack(spacing: BP.px(12)) {
                Text("Add to tile \(slot + 1)").font(BP.display(26)).foregroundStyle(BP.ink)
                LiveSearchField(placeholder: placeholder, text: $query).frame(maxWidth: BP.px(560))
                if !query.isEmpty { Button("Clear") { query = "" }.buttonStyle(BPActionStyle()) }
                Spacer(minLength: 0)
                Button(action: onClose) { Label("Close", systemImage: "xmark") }.buttonStyle(BPActionStyle())
            }
            .focusSection()
            if live.playlists.count > 1 {
                // PlaylistDropdown: All playlists, then each source with its channel count.
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: BP.px(8)) {
                        scopeChip(id: Self.allPlaylists, label: T("All playlists"), sub: nil)
                        ForEach(live.playlists) { pl in
                            let n = pl.id == currentId ? live.channels.count : model.otherChannels[pl.id]?.count
                            scopeChip(id: pl.id, label: pl.name, sub: n.map { $0 == 1 ? T("%lld channel", 1) : T("%lld channels", $0) } ?? (model.loadingOther.contains(pl.id) ? T("Loading…") : nil))
                        }
                    }
                    .padding(.vertical, BP.px(4))
                }
                .focusSection()
            }
            LiveChannelBrowser(channels: channels, groups: groups, guide: live.guide, currentId: nil, copy: .multiview,
                               group: $group, query: $query, loading: loading,
                               loadGuide: guideLoader,
                               onPick: onPick)
            HStack(spacing: BP.px(10)) {
                LiveSearchField(placeholder: "Or paste a stream URL", text: $manual).frame(maxWidth: BP.px(760))
                Button("Add") {
                    let v = manual.trimmingCharacters(in: .whitespaces)
                    guard manualValid else { return }
                    onPick(LiveModel.Channel(id: "custom:\(v)", name: "Custom stream", url: v, favorite: false))
                }
                .buttonStyle(BPActionStyle(primary: manualValid))
                .disabled(!manualValid)
            }
            .focusSection()
        }
        .padding(.horizontal, BP.gutter).padding(.top, BP.px(40)).padding(.bottom, BP.px(30))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(BP.canvas.ignoresSafeArea())
    }

    private func scopeChip(id: String, label: String, sub: String?) -> some View {
        Button {
            scope = id
            group = nil
            Task {
                if id == Self.allPlaylists {
                    for pl in live.playlists where pl.id != currentId { await model.loadChannels(of: pl.id) }
                } else if id != currentId {
                    await model.loadChannels(of: id)
                }
            }
        } label: {
            HStack(spacing: BP.px(6)) {
                Text(label).lineLimit(1)
                if let sub { Text(sub).opacity(0.55) }
            }
        }
        .buttonStyle(BPActionStyle(primary: scopeId == id))
    }
}
