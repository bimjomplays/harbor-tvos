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
    /// "S1 E2 · Title" of what follows; drives the up-next pill near the end (player-spec §1.9).
    var upNext: String? = nil
    /// Live streams: live mpv cache options, no seek bar, no progress saves.
    var isLive: Bool = false
    /// `true` when the file played to its end (next-episode logic keys off this).
    /// source-error-card "Pick another source": the caller reopens the picker after this closes.
    var onChooseAnother: (() -> Void)? = nil
    /// bp-player-sources "Switch source": reopen the picker and resume the new stream here.
    var onSwitchSource: ((Double) -> Void)? = nil
    @State private var subDelay: Double = 0
    @State private var subScale: Double = 1
    @State private var loadingSince = Date()
    let onClose: (_ endedNaturally: Bool) -> Void
    @State private var reloadToken = 0

    @State private var status = MPVPlayerController.Status()
    @State private var chrome = true
    @State private var hideTask: Task<Void, Never>?
    @State private var controller: MPVPlayerController?
    @State private var startAt: Double?
    /// bp-resume-prompt: the saved position waits for "Pick up where you left off" / "Start over" (settings.resumePrompt).
    @State private var resumePending: Double?
    /// bp-leave-confirm: Back asks "Leave the show?" (settings.playerConfirmLeave) unless the viewer said don't ask again.
    @State private var leaveConfirm = false
    @State private var leaveRemember = false
    @State private var lastSavedPos: Double = -10
    @State private var snap: (position: Double, duration: Double, paused: Bool) = (0, 0, false)
    @State private var panel: Panel?
    @State private var tracks: [MPVPlayerController.Track] = []
    @State private var online: [OnlineSubtitle] = []
    @State private var segments: [SkipSegment] = []
    @State private var segmentsLoadedFor: Double = 0
    @State private var skippedIds: Set<String> = []

    struct SkipSegment: Decodable, Identifiable {
        var kind: String       // "intro" | "outro" | "recap" | "ad" | ...
        var startSec: Double
        var endSec: Double
        var source: String
        var id: String { "\(kind)-\(startSec)-\(endSec)" }
        var label: String {
            switch kind {
            case "intro": return "Skip intro"
            case "outro", "credits": return "Skip outro"
            case "recap": return "Skip recap"
            case "ad": return "Skip ad"
            default: return "Skip \(kind)"
            }
        }
    }
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

    enum Panel { case audio, subtitles, anime4k }
    struct Anime4KChoice: Decodable { var active: Bool; var choice: String; var mode: String?; var tier: String?; var files: [String]; var indicator: Bool }
    @State private var anime4k: Anime4KChoice?
    @State private var anime4kAppliedFor: Int = -1
    @State private var anime4kNote: String?
    enum FocusTarget: Hashable { case surface, chip(String), track(Int) }

    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    @State private var scrobbleState: String?   // last action sent to Trakt
    @State private var lastScrobblePaused = false
    private static let hideAfter: Double = 4.6   // use-bp-player-chrome.ts

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if let startAt {
                MPVPlayerView(url: url, headers: headers, startAt: startAt, isLive: isLive,
                              preferredAudio: SettingsBridge.shared.slice.preferredAudioLangs ?? ["English", "Japanese"],
                              preferredSubs: SettingsBridge.shared.slice.preferredSubLangs,
                              onStatus: { status = $0 }, onEnded: { finish(natural: true) },
                              onReady: { controller = $0; if resumePending != nil { $0.setPaused(true) } })
                    .ignoresSafeArea()
                    .id(reloadToken)
            } else {
                BP.void_.ignoresSafeArea()
            }
            // The invisible surface holds focus while the chrome is down so remote presses reach us.
            Button { togglePause() } label: { Color.clear.contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .disabled(panel != nil || resumePending != nil || leaveConfirm)
                .focused($focus, equals: .surface)
                .onMoveCommand { dir in
                    switch dir {
                    case .left: controller?.seek(-10); wake()
                    case .right: controller?.seek(10); wake()
                    case .up where activeSegment != nil: focus = .chip("skip")
                    default: wake()
                    }
                }
            if chrome, resumePending == nil, !leaveConfirm, status.state != "error" || isLive { chromeView.transition(.opacity) }
            if let resumePending { resumePrompt(resumePending).transition(.opacity) }
            if leaveConfirm { leaveConfirmView.transition(.opacity) }
            if status.state == "error", !isLive { sourceErrorCard.transition(.opacity) }
            if status.state == "loading", !isLive, resumePending == nil, Date().timeIntervalSince(loadingSince) >= 2 { connectingCard.transition(.opacity) }
            if let seg = activeSegment {
                skipPill(seg).transition(.move(edge: .trailing).combined(with: .opacity))
            } else if let upNext, snap.duration > 120, snap.duration - snap.position <= 40, !snap.paused {
                upNextPill(upNext).transition(.move(edge: .trailing).combined(with: .opacity))
            }
            if let panel { panelView(panel).transition(.move(edge: .trailing).combined(with: .opacity)) }
            if let a = anime4k, a.active, a.indicator, !chrome {
                // anime4k-indicator.tsx: a quiet corner pill while a chain is live.
                Text("Anime4K · Mode \(a.mode ?? "")").font(BP.sans(11, .bold)).foregroundStyle(BP.ink)
                    .padding(.horizontal, BP.px(8)).padding(.vertical, BP.px(4))
                    .background(Capsule().fill(BP.void_.opacity(0.7)))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(BP.gutter)
            }
        }
        .onPlayPauseCommand { togglePause() }
        .onExitCommand {
            if resumePending != nil { acknowledgeResume(true) }          // Back takes the default action (bp-resume-prompt)
            else if leaveConfirm { leaveConfirm = false; controller?.setPaused(false); focus = .surface; wake() }
            else if panel != nil { panel = nil; focus = .surface; wake() }
            else if focus == .chip("skip") { focus = .surface }
            else if chrome { chrome = false }
            else { requestClose() }
        }
        .onAppear { focus = .surface; scheduleHide(); PlaybackState.shared.active = true }
        .onDisappear { PlaybackState.shared.active = false }
        .onReceive(CurfewState.shared.$locked) { if $0 { finish(natural: false) } }
        .task {
            // use-bridge-load: no resume for live or when the viewer turned it off; a saved spot past
            // RESUME_PROMPT_MIN_SEC (30 s) becomes a fork when resumePrompt is on, else a silent seek.
            let slice = SettingsBridge.shared.slice
            var sec = (!isLive && (slice.resumePlayback ?? true)) ? (await context?.startPosition() ?? 0) : 0
            // A source switch or a home-server copy carries its own position (use-bridge-load hasExplicitStart).
            if let x = context?.explicitStartSec, x > 0 { sec = x }
            else if let h = context?.homeServer, h.resumeSec > 0 { sec = h.resumeSec }
            if sec <= 5 { sec = 0 }
            if sec > 30, slice.resumePrompt ?? false, !isLive {
                resumePending = sec
                startAt = 0
                focusLater(.chip("Pick up where you left off"))
            } else {
                startAt = sec
            }
        }
        .onReceive(tick) { _ in
            if let c = controller { snap = c.snapshot() }
            if !isLive, let c = controller, status.state != "loading" {
                let w = c.videoWidth()
                if w > 0, w != anime4kAppliedFor { anime4kAppliedFor = w; Task { await applyAnime4k(srcWidth: w) } }
                // A chain libplacebo refused shows up in mpv's warnings: drop it rather than play blind.
                if let a = anime4k, a.active, status.log.contains(where: { $0.range(of: #"(shader|glsl|hook)"#, options: [.regularExpression, .caseInsensitive]) != nil && $0.range(of: #"(error|fail|invalid|could not)"#, options: [.regularExpression, .caseInsensitive]) != nil }) {
                    var off = a; off.active = false
                    anime4k = off
                    anime4kNote = "mpv rejected the Anime4K shaders on this device; playing without them."
                    c.setShaders([])
                }
            }
            Task { await saveTick(flush: false) }
            scrobbleTick()
            if snap.duration > 0, segmentsLoadedFor != snap.duration { segmentsLoadedFor = snap.duration; Task { await loadSegments() } }
        }
        .animation(.easeOut(duration: 0.32), value: chrome)
        .animation(.easeOut(duration: 0.32), value: panel == nil)
    }

    /// The segment the playhead is inside (skip-intro/index.ts activeSegment), unless already skipped.
    private var activeSegment: SkipSegment? {
        segments.first { $0.startSec <= snap.position && snap.position < $0.endSec - 1 && !skippedIds.contains($0.id) }
    }

    /// AniSkip / SkipDB / TheIntroDB / IntroDB App / chapters through the engine (lib/skip-intro).
    private func loadSegments() async {
        guard let context, snap.duration > 0 else { return }
        let p = ProfilesStore.shared.active
        let ep: AnyJSON = context.season.map { s in
            .object(["season": .number(Double(s)), "episode": .number(Double(context.episode ?? 1)),
                     "imdbId": context.imdbId.map { .string($0) } ?? .null,
                     "imdbSeason": .number(Double(s)), "imdbEpisode": .number(Double(context.episode ?? 1))])
        } ?? .null
        let segs: [SkipSegment] = (try? await HarborEngine.shared.call("skip.segments", [p?.id ?? "default", p?.linked ?? true, context.meta, ep, snap.duration])) ?? []
        segments = segs
    }

    private func skipPill(_ seg: SkipSegment) -> some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                Button {
                    skippedIds.insert(seg.id)
                    controller?.seek(to: seg.endSec)
                    wake()
                } label: {
                    HStack(spacing: BP.px(8)) {
                        Image(systemName: "forward.fill")
                        Text(seg.label).font(BP.sans(14, .semibold))
                    }
                    .foregroundStyle(BP.ink)
                    .padding(.horizontal, BP.px(14)).padding(.vertical, BP.px(10))
                    .background(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).fill(BP.void_.opacity(0.92)))
                    .overlay(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).stroke(BP.edge2, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .focused($focus, equals: .chip("skip"))
            }
            .padding(.bottom, chrome ? BP.px(150) : BP.px(40)).padding(.trailing, BP.gutter)
        }
        .ignoresSafeArea()
        // bp-skip-pill: a soft target. It never takes the ring on arrival (Select must keep meaning
        // pause); Up from the surface or the transport reaches it, Menu hands the ring back.
    }

    /// Up-next pill in the last 40 seconds; Play/Pause or Select skips straight to the next episode.
    private func upNextPill(_ text: String) -> some View {
        VStack {
            HStack {
                Spacer()
                Button { finish(natural: true) } label: {
                    HStack(spacing: BP.px(10)) {
                        Image(systemName: "forward.end.fill")
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Up next in \(max(0, Int(snap.duration - snap.position)))s").font(BP.sans(11, .bold)).foregroundStyle(BP.accent).textCase(.uppercase)
                            Text(text).font(BP.sans(14, .semibold)).foregroundStyle(BP.ink).lineLimit(1)
                        }
                    }
                    .padding(.horizontal, BP.px(14)).padding(.vertical, BP.px(10))
                    .background(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).fill(BP.void_.opacity(0.92)))
                    .overlay(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).stroke(BP.edge2, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .focused($focus, equals: .chip("upnext"))
            }
            .padding(.top, BP.px(40)).padding(.trailing, BP.gutter)
            Spacer()
        }
        .ignoresSafeArea()
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
            if !isLive { seekBar }
            HStack(spacing: BP.px(10)) {
                chip("Back", "chevron.left") { requestClose() }
                chip(snap.paused ? "Play" : "Pause", snap.paused ? "play.fill" : "pause.fill") { togglePause() }
                chip("Subtitles", "captions.bubble") { open(.subtitles) }
                chip("Audio", "waveform") { open(.audio) }
                if !isLive { chip(anime4kChipLabel, "sparkles") { open(.anime4k) } }
                if onSwitchSource != nil { chip("Sources", "list.bullet") { let go = onSwitchSource; let at = snap.position; finish(natural: false); go?(at) } }
                Spacer()
                Text(isLive ? "LIVE" : "\(fmt(snap.position)) / \(fmt(snap.duration))").font(BP.sans(14, .semibold)).foregroundStyle(isLive ? BP.live : BP.ink).monospacedDigit()
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

    private var anime4kChipLabel: String {
        guard let a = anime4k else { return "Anime4K" }
        if a.choice == "off" { return "Anime4K off" }
        return a.active ? "Anime4K \(a.mode ?? "")" : "Anime4K auto"
    }

    /// use-anime4k.ts: ask the engine which chain applies, then hand mpv the shader paths.
    private func applyAnime4k(srcWidth: Int) async {
        guard let context, let c = controller else { return }
        let display = Int(UIScreen.main.nativeBounds.width)
        let meta: AnyJSON = .object(["id": .string(context.meta.id), "genres": .array((context.meta.genres ?? []).map { .string($0) })])
        let p = ProfilesStore.shared.active
        guard let choice: Anime4KChoice = try? await HarborEngine.shared.call("anime4k.choose", [p?.id ?? "default", p?.linked ?? true, meta, srcWidth, display]) else { return }
        if choice.active {
            if !Anime4KStore.shared.installed { await Anime4KStore.shared.ensure() }
            if let paths = Anime4KStore.shared.paths(for: choice.files) {
                anime4k = choice
                anime4kNote = nil
                c.setShaders(paths)
            } else {
                // Not downloaded (offline?): never claim a mode that mpv is not running.
                var off = choice; off.active = false
                anime4k = off
                anime4kNote = Anime4KStore.shared.note ?? "Anime4K shaders are not downloaded yet."
                c.setShaders([])
            }
        } else {
            anime4k = choice
            c.setShaders([])
        }
    }

    private func setAnime4k(_ override: String) {
        Task {
            try? await SettingsBridge.shared.patch(["playerAnime4kOverride": .string(override), "playerAnime4k": .bool(true)])
            anime4kAppliedFor = -1
            panel = nil; focus = .surface; wake()
        }
    }

    private func anime4kPanel() -> some View {
        let options: [(String, String, String)] = [("auto", "Auto", "Follows the Anime4K setting: anime only, or every title."), ("off", "Off", "No shaders for this title."),
                                                   ("A", "Mode A", "Restore + upscale. The best all-rounder for most anime."), ("B", "Mode B", "Softer restore. Kinder to compressed or noisy sources."),
                                                   ("C", "Mode C", "Denoise + upscale. Lightest, cleanest on already-sharp video."), ("AA", "Mode A+A", "Double restore. Sharpest detail, for high-quality sources."),
                                                   ("BB", "Mode B+B", "Double soft restore. For heavy compression artifacts."), ("CA", "Mode C+A", "Denoise then restore. Balanced cleanup and detail.")]
        let current = anime4k?.choice ?? "auto"
        return HStack {
            Spacer()
            VStack(alignment: .leading, spacing: BP.px(8)) {
                Text("Anime4K").font(BP.sans(19, .bold)).foregroundStyle(BP.ink).padding(.bottom, BP.px(6))
                ForEach(Array(options.enumerated()), id: \.offset) { i, o in
                    Button { setAnime4k(o.0) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack { Text(o.1).font(BP.sans(14, .semibold)); Spacer(); if current == o.0 { Image(systemName: "checkmark") } }
                            Text(o.2).font(BP.sans(11)).foregroundStyle(BP.inkMuted).lineLimit(2)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(BPActionStyle(primary: current == o.0))
                    .focused($focus, equals: .track(-10 - i))
                }
                if let a = anime4k, a.active { BPNote(text: "Running mode \(a.mode ?? "") (\(a.tier == "fast" ? "fast" : "HQ")). Stutter? Switch the tier to Fast in Settings.") }
                if let n = anime4kNote { BPNote(text: n, tone: BP.danger) }
                if !Anime4KStore.shared.installed { BPNote(text: "The shaders download on first use (about 3 MB).") }
            }
            .padding(BP.px(24))
            .frame(width: BP.px(420), alignment: .leading)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(BP.panel.opacity(0.96))
            .focusSection()
        }
        .ignoresSafeArea()
    }

    private func panelView(_ which: Panel) -> some View {
        if which == .anime4k { return AnyView(anime4kPanel()) }
        let kind = which == .subtitles ? "sub" : "audio"
        let list = tracks.filter { $0.type == kind }
        return AnyView(HStack {
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
                    // bp-subtitle-tune: manual offset steps and a size stepper.
                    Text("Manual offset · \(subDelay == 0 ? "in sync" : String(format: "%+.1f s", subDelay))").font(BP.sans(12, .semibold)).foregroundStyle(BP.inkMuted)
                    HStack(spacing: BP.px(6)) {
                        ForEach([-1.0, -0.1, 0.1, 1.0], id: \.self) { step in
                            Button(String(format: "%@%.1fs", step > 0 ? "+" : "", step)) { nudgeSubs(step) }.buttonStyle(BPActionStyle()).focused($focus, equals: .chip("sub\(step)"))
                        }
                        Button("Reset") { subDelay = 0; controller?.setSubDelay(0); wake() }.buttonStyle(BPActionStyle()).disabled(subDelay == 0)
                    }
                    Text("Subtitles late? Nudge plus. Early? Nudge minus.").font(BP.sans(11)).foregroundStyle(BP.inkSubtle)
                    HStack(spacing: BP.px(6)) {
                        Text("Size").font(BP.sans(12, .semibold)).foregroundStyle(BP.inkMuted)
                        Button("−") { subScale = max(0.5, subScale - 0.1); controller?.setSubScale(subScale); wake() }.buttonStyle(BPActionStyle())
                        Text(String(format: "%.0f%%", subScale * 100)).font(BP.sans(12)).foregroundStyle(BP.ink).monospacedDigit()
                        Button("+") { subScale = min(2.5, subScale + 0.1); controller?.setSubScale(subScale); wake() }.buttonStyle(BPActionStyle())
                    }
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
        .ignoresSafeArea())
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
        let target = p == .anime4k ? -10 : (p == .subtitles ? -1 : (tracks.first { $0.type == kind }?.id ?? -1))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { focus = .track(target) }
    }

    private func refreshTracks() { tracks = controller?.tracks() ?? [] }

    private func nudgeSubs(_ step: Double) {
        subDelay = (subDelay + step * 10).rounded() / 10
        controller?.setSubDelay(subDelay)
        wake()
    }

    /// bp-connecting: while the stream is still opening, elapsed time and a way out; after 22 s the
    /// copy admits it is still looking. Focus moves here only once a start is clearly slow.
    private var connectingCard: some View {
        let elapsed = Int(Date().timeIntervalSince(loadingSince))
        return VStack(alignment: .leading, spacing: BP.px(10)) {
            Spacer()
            HStack(spacing: BP.px(10)) { ProgressView().tint(BP.ink); Text("Connecting…").font(BP.display(28)).foregroundStyle(BP.ink) }
            Text(elapsed >= 22 ? "Still looking. Some sources take a while to answer." : "The player is opening the stream. \(elapsed) s").font(BP.sans(15)).foregroundStyle(BP.inkMuted)
            if elapsed >= 8 {
                HStack(spacing: BP.px(10)) {
                    chip("Go back", "chevron.left") { finish(natural: false) }
                    chip("Try again", "arrow.clockwise") { status = MPVPlayerController.Status(); loadingSince = Date(); reloadToken += 1 }
                    if onSwitchSource != nil { chip("Switch source", "list.bullet") { let go = onSwitchSource; finish(natural: false); go?(snap.position) } }
                }
                .focusSection()
                .onAppear { focusLater(.chip("Go back")) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(BP.gutter).padding(.bottom, BP.px(20))
        .background(LinearGradient(colors: [.clear, BP.void_.opacity(0.5), BP.void_.opacity(0.9)], startPoint: .top, endPoint: .bottom).ignoresSafeArea())
    }

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

    /// lib/trakt/scrobble-hook.ts: "start" when playing, "pause" on pause, "stop" at the end.
    private func scrobbleTick() {
        guard let context, !isLive, snap.duration > 150 else { return }
        let paused = snap.paused
        if scrobbleState == nil, !paused, snap.position > 1 { sendScrobble("start") }
        else if scrobbleState == "start", paused, !lastScrobblePaused { sendScrobble("pause") }
        else if scrobbleState == "pause", !paused { sendScrobble("start") }
        lastScrobblePaused = paused
        _ = context
    }

    private func sendScrobble(_ action: String) {
        guard let context else { return }
        scrobbleState = action
        let progress = snap.duration > 0 ? snap.position / snap.duration * 100 : 0
        let ep: AnyJSON = context.season.map { s in
            .object(["season": .number(Double(s)), "episode": .number(Double(context.episode ?? 1)),
                     "imdbId": context.imdbId.map { .string($0) } ?? .null,
                     "imdbSeason": .number(Double(s)), "imdbEpisode": .number(Double(context.episode ?? 1))])
        } ?? .null
        let year = context.meta.releaseInfo.flatMap { Double($0.prefix(4)) }
        let info: AnyJSON = .object(["title": .string(context.meta.name), "year": year.map { .number($0) } ?? .null, "imdb": context.imdbId.map { .string($0) } ?? .null])
        Task {
            _ = try? await HarborEngine.shared.callJSON("trakt.scrobble", [.string(action), .string(context.meta.id), ep, .number(progress)])
            _ = try? await HarborEngine.shared.callJSON("simkl.scrobble", [.string(action), .string(context.meta.id), ep, .number(progress), info])
        }
    }

    /// use-resume-autosave.ts: every 4 s while playing, only if moved ≥ 1.5 s since the last save.
    private func saveTick(flush: Bool) async {
        guard let c = controller, let context else { return }
        let s = c.snapshot()
        guard s.duration > 0, flush || (!s.paused && abs(s.position - lastSavedPos) >= 1.5) else { return }
        lastSavedPos = s.position
        _ = await context.save(positionSec: s.position, durationSec: s.duration, flush: flush)
        homeServerTick(s, flush: flush)
    }

    @State private var lastHomeReport: Double = 0
    @State private var lastHomePaused = false
    /// progress-sync.ts: every 15 s while playing, on pause, and when leaving; titles under 150 s never.
    private func homeServerTick(_ s: (position: Double, duration: Double, paused: Bool), flush: Bool) {
        guard let context, context.homeServer != nil, s.duration >= 150 else { return }
        let now = Date().timeIntervalSince1970
        let pausedNow = s.paused && !lastHomePaused
        lastHomePaused = s.paused
        guard flush || pausedNow || (!s.paused && now - lastHomeReport >= 15) else { return }
        lastHomeReport = now
        let watched = s.position / s.duration >= 0.9
        Task { await context.reportHomeServer(positionSec: s.position, durationSec: s.duration, watched: watched) }
    }

    /// request-player-close.ts: Back leaves at once unless playerConfirmLeave is on.
    private func requestClose() {
        if !isLive, SettingsBridge.shared.slice.playerConfirmLeave ?? true {
            leaveRemember = false
            leaveConfirm = true
            controller?.setPaused(true); if let c = controller { snap = c.snapshot() }
            hideTask?.cancel()
            focusLater(.chip("Keep watching"))
        } else {
            finish(natural: false)
        }
    }

    private func acknowledgeResume(_ resume: Bool) {
        guard let sec = resumePending else { return }
        resumePending = nil
        if resume, sec > 0 { controller?.seek(to: sec) }
        controller?.setPaused(false)
        focus = .surface
        scheduleHide()
    }

    /// bp-resume-prompt.tsx: a fork over the paused first frame; the ring lands on Resume.
    private func resumePrompt(_ sec: Double) -> some View {
        VStack(alignment: .leading, spacing: BP.px(14)) {
            Spacer()
            Text("Pick up where you left off").font(BP.display(34)).foregroundStyle(BP.ink)
            Text("\(title)\(subtitle.map { " · \($0)" } ?? "") · \(fmt(sec))\(snap.duration > 0 ? " of \(fmt(snap.duration))" : "")")
                .font(BP.sans(16)).foregroundStyle(BP.inkMuted).lineLimit(1)
            if snap.duration > 0 {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(BP.on)
                        Capsule().fill(BP.accent).frame(width: g.size.width * min(1, max(0, sec / snap.duration)))
                    }
                }.frame(width: BP.px(420), height: BP.px(6))
            }
            HStack(spacing: BP.px(10)) {
                chip("Pick up where you left off", "play.fill") { acknowledgeResume(true) }
                chip("Start over", "arrow.counterclockwise") { acknowledgeResume(false) }
            }
            .focusSection()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(BP.gutter).padding(.bottom, BP.px(20))
        .background(LinearGradient(colors: [.clear, BP.void_.opacity(0.55), BP.void_.opacity(0.92)], startPoint: .top, endPoint: .bottom).ignoresSafeArea())
        .onAppear { controller?.setPaused(true); if let c = controller { snap = c.snapshot() } }
    }

    /// A focus target that is only being inserted this tick cannot take the ring yet.
    private func focusLater(_ target: FocusTarget) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { focus = target }
    }

    /// source-error-card.tsx: the stream would not open; pick another source, retry, or leave.
    private var sourceErrorCard: some View {
        VStack(alignment: .leading, spacing: BP.px(12)) {
            Spacer()
            HStack(spacing: BP.px(10)) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(BP.danger)
                Text("Harbor couldn't play this source").font(BP.display(30)).foregroundStyle(BP.ink)
            }
            Text("The source responded but the stream would not open. Try a different one.").font(BP.sans(16)).foregroundStyle(BP.inkMuted)
            if let e = status.error { Text("Source said: \(e)").font(BP.sans(12)).foregroundStyle(BP.inkSubtle).lineLimit(1) }
            HStack(spacing: BP.px(10)) {
                if onChooseAnother != nil {
                    chip("Pick another source", "list.bullet") { let go = onChooseAnother; finish(natural: false); go?() }
                }
                chip("Try again", "arrow.clockwise") { status = MPVPlayerController.Status(); reloadToken += 1 }
                chip("Back", "chevron.left") { finish(natural: false) }
            }
            .focusSection()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(BP.gutter).padding(.bottom, BP.px(20))
        .background(LinearGradient(colors: [.clear, BP.void_.opacity(0.6), BP.void_.opacity(0.95)], startPoint: .top, endPoint: .bottom).ignoresSafeArea())
        .onAppear { hideTask?.cancel(); focusLater(.chip(onChooseAnother != nil ? "Pick another source" : "Try again")) }
    }

    /// bp-leave-confirm.tsx: Keep watching / Leave / Don't ask again.
    private var leaveConfirmView: some View {
        VStack(alignment: .leading, spacing: BP.px(12)) {
            Spacer()
            Text("Leave the show?").font(BP.display(34)).foregroundStyle(BP.ink)
            Text("We'll save your spot so you can pick up right where you left off.").font(BP.sans(16)).foregroundStyle(BP.inkMuted)
            HStack(spacing: BP.px(10)) {
                chip("Keep watching", "play.fill") { leaveConfirm = false; controller?.setPaused(false); focus = .surface; scheduleHide() }
                chip("Leave", "rectangle.portrait.and.arrow.right") {
                    if leaveRemember { Task { try? await SettingsBridge.shared.patch(["playerConfirmLeave": .bool(false)]) } }
                    leaveConfirm = false
                    finish(natural: false)
                }
                chip("Don't ask again", leaveRemember ? "checkmark.circle.fill" : "circle") { leaveRemember.toggle() }
            }
            .focusSection()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(BP.gutter).padding(.bottom, BP.px(20))
        .background(LinearGradient(colors: [.clear, BP.void_.opacity(0.55), BP.void_.opacity(0.92)], startPoint: .top, endPoint: .bottom).ignoresSafeArea())
    }

    private func finish(natural: Bool) {
        if scrobbleState != nil {
            let progress = snap.duration > 0 ? (natural ? 100 : snap.position / snap.duration * 100) : 0
            sendScrobble(progress >= 90 ? "stop" : "pause")
        }
        Task {
            if natural, let c = controller, let context, c.snapshot().duration > 0 {
                let s = c.snapshot()
                _ = await context.save(positionSec: s.duration, durationSec: s.duration, flush: true)
                if s.duration >= 150 { await context.reportHomeServer(positionSec: s.duration, durationSec: s.duration, watched: true) }
            } else {
                await saveTick(flush: true)
            }
            if let context, context.homeServer != nil, let c = controller { await context.stopHomeServerSession(positionSec: c.snapshot().position) }
            onClose(natural)
            // The watched check on the tiles reads the flags this session just wrote.
            await CardMarksStore.shared.remark()
        }
    }
}
