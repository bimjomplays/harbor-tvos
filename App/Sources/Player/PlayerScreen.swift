import SwiftUI

/// Full-screen playback with Big Picture's player chrome (docs/player-spec.md §1):
/// chrome wakes on any press and hides after 4.6 s; Select = play/pause; Left/Right seek;
/// Menu closes the chrome first, then the player.
struct PlayerScreen: View {
    let title: String
    let subtitle: String?
    let url: URL
    var headers: [String: String] = [:]
    var context: PlaybackContext? = nil
    /// `true` when the file played to its end (next-episode logic keys off this).
    let onClose: (_ endedNaturally: Bool) -> Void

    @State private var status = MPVPlayerController.Status()
    @State private var chrome = true
    @State private var hideTask: Task<Void, Never>?
    @State private var controller: MPVPlayerController?
    @State private var startAt: Double?
    @State private var lastSavedPos: Double = -10
    @State private var snap: (position: Double, duration: Double, paused: Bool) = (0, 0, false)
    @State private var panel: Panel?
    @State private var tracks: [MPVPlayerController.Track] = []
    @State private var online: [OnlineSubtitle] = []
    @State private var onlineState: String?
    @FocusState private var focus: FocusTarget?

    struct OnlineSubtitle: Decodable, Identifiable {
        var id: String
        var url: String
        var lang: String
        var langName: String?
        var title: String?
        var displayTitle: String?
        var source: String
    }

    enum Panel { case audio, subtitles }
    enum FocusTarget: Hashable { case surface, chip(String), track(Int) }

    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    private static let hideAfter: Double = 4.6   // use-bp-player-chrome.ts

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if let startAt {
                MPVPlayerView(url: url, headers: headers, startAt: startAt, onStatus: { status = $0 }, onEnded: { finish(natural: true) }, onReady: { controller = $0 })
                    .ignoresSafeArea()
            } else {
                BP.void_.ignoresSafeArea()
            }
            // The invisible surface holds focus while the chrome is down so remote presses reach us.
            Button { togglePause() } label: { Color.clear.contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .disabled(panel != nil)
                .focused($focus, equals: .surface)
                .onMoveCommand { dir in
                    switch dir {
                    case .left: controller?.seek(-10); wake()
                    case .right: controller?.seek(10); wake()
                    default: wake()
                    }
                }
            if chrome { chromeView.transition(.opacity) }
            if let panel { panelView(panel).transition(.move(edge: .trailing).combined(with: .opacity)) }
        }
        .onPlayPauseCommand { togglePause() }
        .onExitCommand {
            if panel != nil { panel = nil; focus = .surface }
            else if chrome { chrome = false }
            else { finish(natural: false) }
        }
        .onAppear { focus = .surface; scheduleHide() }
        .task { startAt = await context?.startPosition() ?? 0 }
        .onReceive(tick) { _ in
            if let c = controller { snap = c.snapshot() }
            Task { await saveTick(flush: false) }
        }
        .animation(.easeOut(duration: 0.32), value: chrome)
        .animation(.easeOut(duration: 0.32), value: panel == nil)
    }

    // MARK: chrome

    private var chromeView: some View {
        VStack(alignment: .leading, spacing: BP.px(14)) {
            Spacer()
            HStack(alignment: .lastTextBaseline, spacing: BP.px(14)) {
                VStack(alignment: .leading, spacing: BP.px(4)) {
                    Text(title).font(BP.display(26)).foregroundStyle(BP.ink)
                    if let subtitle { Text(subtitle).font(BP.sans(15, .semibold)).foregroundStyle(BP.inkMuted) }
                }
                Spacer()
                Text(status.state == "loading" ? "Loading…" : status.videoParams.split(separator: " ").prefix(3).joined(separator: " "))
                    .font(BP.sans(12, .medium)).foregroundStyle(BP.inkSubtle)
            }
            seekBar
            HStack(spacing: BP.px(10)) {
                chip("Back", "chevron.left") { finish(natural: false) }
                chip(snap.paused ? "Play" : "Pause", snap.paused ? "play.fill" : "pause.fill") { togglePause() }
                chip("Subtitles", "captions.bubble") { open(.subtitles) }
                chip("Audio", "waveform") { open(.audio) }
                Spacer()
                Text("\(fmt(snap.position)) / \(fmt(snap.duration))").font(BP.sans(14, .semibold)).foregroundStyle(BP.ink).monospacedDigit()
            }
            .focusSection()
        }
        .padding(BP.gutter)
        .padding(.bottom, BP.px(10))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .background(LinearGradient(colors: [.clear, BP.void_.opacity(0.75), BP.void_.opacity(0.95)], startPoint: .init(x: 0.5, y: 0.45), endPoint: .bottom))
        .ignoresSafeArea()
    }

    private var seekBar: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(BP.edge2).frame(height: BP.px(4))
            Capsule().fill(BP.ink).frame(width: max(0, progressWidth), height: BP.px(4))
        }
        .frame(height: BP.px(10))
    }

    private var progressWidth: CGFloat {
        guard snap.duration > 0 else { return 0 }
        return (1920 - 2 * BP.gutter) * CGFloat(snap.position / snap.duration)
    }

    private func chip(_ label: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: { action(); wake() }) { Label(label, systemImage: icon) }
            .buttonStyle(BPActionStyle())
            .focused($focus, equals: .chip(label))
    }

    // MARK: panels (audio / subtitle tracks)

    private func panelView(_ which: Panel) -> some View {
        let kind = which == .subtitles ? "sub" : "audio"
        let list = tracks.filter { $0.type == kind }
        return HStack {
            Spacer()
            VStack(alignment: .leading, spacing: BP.px(8)) {
                Text(which == .subtitles ? "Subtitles" : "Audio").font(BP.sans(19, .bold)).foregroundStyle(BP.ink).padding(.bottom, BP.px(6))
                if which == .subtitles {
                    trackButton(nil, label: "Off", selected: !list.contains { $0.selected }, kind: kind)
                }
                ForEach(list) { t in trackButton(t, label: t.label, selected: t.selected, kind: kind) }
                if list.isEmpty && which == .audio { BPNote(text: "No audio tracks reported yet.") }
                if which == .subtitles {
                    Divider().overlay(BP.edge2).padding(.vertical, BP.px(6))
                    Button(onlineState == "searching" ? "Searching…" : "Search online") { Task { await searchOnline() } }
                        .buttonStyle(BPActionStyle()).disabled(onlineState == "searching")
                        .focused($focus, equals: .track(-2))
                    if let onlineState, onlineState != "searching" { BPNote(text: onlineState) }
                    ForEach(online) { sub in
                        Button { Task { await addOnline(sub) } } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(sub.langName ?? sub.lang).font(BP.sans(14, .semibold))
                                Text(sub.displayTitle ?? sub.title ?? sub.source).font(BP.sans(11)).foregroundStyle(BP.inkMuted).lineLimit(1)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(BPActionStyle())
                    }
                }
            }
            .padding(BP.px(24))
            .frame(width: BP.px(380), alignment: .leading)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(BP.panel.opacity(0.96))
            .focusSection()
        }
        .ignoresSafeArea()
    }

    private func trackButton(_ t: MPVPlayerController.Track?, label: String, selected: Bool, kind: String) -> some View {
        Button {
            controller?.select(track: t, type: kind)
            refreshTracks()
            wake()
        } label: {
            HStack { Text(label); Spacer(); if selected { Image(systemName: "checkmark") } }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(BPActionStyle(primary: selected))
        .focused($focus, equals: .track(t?.id ?? -1))
    }

    private func open(_ p: Panel) {
        refreshTracks()
        panel = p
        hideTask?.cancel()
        // Subtitles has an "Off" row (-1); Audio focuses its first track, or the panel's chip row is left to Menu.
        let kind = p == .subtitles ? "sub" : "audio"
        let target = p == .subtitles ? -1 : (tracks.first { $0.type == kind }?.id ?? -1)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { focus = .track(target) }
    }

    private func refreshTracks() { tracks = controller?.tracks() ?? [] }

    /// OpenSubtitles v3 / Wyzie / subtitle addons through the engine (lib/subtitles/search.ts).
    private func searchOnline() async {
        guard let context else { return }
        onlineState = "searching"
        let p = ProfilesStore.shared.active
        let authKey = p.flatMap { ProfilesStore.shared.stremioSession(for: $0.id)?.authKey }
        do {
            let results: [OnlineSubtitle] = try await HarborEngine.shared.call("subtitles.search",
                [p?.id ?? "default", p?.linked ?? true, authKey, context.meta, context.season, context.episode, context.imdbId])
            online = results
            onlineState = results.isEmpty ? "Nothing found online." : nil
        } catch {
            onlineState = error.localizedDescription
        }
    }

    /// Download + decode through the engine (handles zips, encodings), hand mpv a local file.
    private func addOnline(_ sub: OnlineSubtitle) async {
        struct Prepared: Decodable { var text: String; var format: String }
        do {
            let prep: Prepared = try await HarborEngine.shared.call("subtitles.prepare", [sub.url])
            let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("subs", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let file = dir.appendingPathComponent("\(sub.id.replacingOccurrences(of: "/", with: "_")).\(prep.format)")
            try prep.text.write(to: file, atomically: true, encoding: .utf8)
            controller?.addSubtitle(file: file, title: sub.displayTitle ?? sub.title ?? sub.langName ?? sub.lang, lang: sub.lang)
            refreshTracks()
            onlineState = "Added \(sub.langName ?? sub.lang)."
        } catch {
            onlineState = "Couldn't load that subtitle: \(error.localizedDescription)"
        }
    }

    // MARK: behaviour

    private func togglePause() {
        controller?.togglePause()
        if let c = controller { snap = c.snapshot() }
        wake()
    }

    private func wake() {
        chrome = true
        scheduleHide()
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(Self.hideAfter))
            if !Task.isCancelled, panel == nil, !snap.paused { chrome = false; focus = .surface }
        }
    }

    private func fmt(_ s: Double) -> String {
        guard s.isFinite, s > 0 else { return "0:00" }
        let t = Int(s)
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, (t / 60) % 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
    }

    /// use-resume-autosave.ts: every 4 s while playing, only if moved ≥ 1.5 s since the last save.
    private func saveTick(flush: Bool) async {
        guard let c = controller, let context else { return }
        let s = c.snapshot()
        guard s.duration > 0, flush || (!s.paused && abs(s.position - lastSavedPos) >= 4) else { return }
        lastSavedPos = s.position
        _ = await context.save(positionSec: s.position, durationSec: s.duration, flush: flush)
    }

    private func finish(natural: Bool) {
        Task {
            if natural, let c = controller, let context, c.snapshot().duration > 0 {
                let s = c.snapshot()
                _ = await context.save(positionSec: s.duration, durationSec: s.duration, flush: true)
            } else {
                await saveTick(flush: true)
            }
            onClose(natural)
        }
    }
}
