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
    /// "S1 E2 · Title" of what follows; drives the up-next card and Next episode (bp-up-next.tsx).
    var upNext: String? = nil
    /// Live streams: live mpv cache options, no seek bar, no progress saves.
    var isLive: Bool = false
    /// `true` when the file played to its end (next-episode logic keys off this).
    /// source-error-card "Pick another source": the caller reopens the picker after this closes.
    var onChooseAnother: (() -> Void)? = nil
    /// bp-player-sources "Switch source": reopen the picker and resume the new stream here.
    var onSwitchSource: ((Double) -> Void)? = nil
    /// bp-player-controls "Previous episode": the caller opens the previous episode's picker.
    /// "Next episode" needs nothing new: closing with `true` is how the caller advances.
    var onPreviousEpisode: (() -> Void)? = nil
    /// Live TV (use-live-channel-overlay.ts): the source the channel came from. It turns on the
    /// transport's "TV Guide" (switch channel in place) and "Previous channel".
    var liveGuide: LiveModel? = nil
    /// The channel being played, when it came from `liveGuide`.
    var liveChannel: LiveModel.Channel? = nil
    /// "Add to Multiview": the caller closes the player and opens Multiview with this channel.
    var onAddToMultiview: ((LiveModel.Channel) -> Void)? = nil
    /// use-live-channel-overlay switchChannel: the channel tuned in place (nil = the one opened).
    @State private var tuned: LiveModel.Channel?
    /// goPrevChannel: the channels tuned before, newest last, 12 at most.
    @State private var prevChannels: [LiveModel.Channel] = []
    @State private var subDelay: Double = 0
    /// bp-player-sources BpAudioLane: mpv audio-delay, ±0.1 / ±0.5 s.
    @State private var audioDelay: Double = 0
    /// bp-player-rail mute chip.
    @State private var muted = false
    /// bp-player-scrub: demuxer cache end, drawn as the buffered fill.
    @State private var buffered: Double = 0
    /// bp-player-scrub nudge(): presses accumulate into one seek committed 420 ms after the last.
    @State private var pendingSeek: Double?
    @State private var seekRun = 0
    @State private var seekCommit: Task<Void, Never>?
    /// player.tsx autoNextCancelled: "Keep watching" on the up-next card.
    @State private var autoNextCancelled = false
    @State private var prefs = PlayerPrefs()
    @State private var finishing = false
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
    @FocusState private var focus: FocusTarget?

    /// engine player.prefs: settings/defaults.ts nextEpisodeLeadSec, autoPlayNextEpisode, seek steps.
    struct PlayerPrefs: Decodable {
        var autoPlayNextEpisode = true
        var nextEpisodeLeadSec: Double = -1
        var seekBackStepSec: Double = 10
        var seekForwardStepSec: Double = 10
    }

    enum Panel { case audio, subtitles, anime4k, channels }
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
                MPVPlayerView(url: playURL, headers: playHeaders, startAt: startAt, isLive: isLive,
                              preferredAudio: SettingsBridge.shared.slice.preferredAudioLangs ?? ["English", "Japanese"],
                              preferredSubs: SettingsBridge.shared.slice.preferredSubLangs,
                              onStatus: { status = $0 }, onEnded: { endedNaturally() },
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
                    case .left: if isLive { controller?.seek(-10); wake() } else { nudgeSeek(ahead: false) }
                    case .right: if isLive { controller?.seek(10); wake() } else { nudgeSeek(ahead: true) }
                    case .up where showUpNextCard: focus = .chip("upnext-keep")
                    case .up where activeSegment != nil: focus = .chip("skip")
                    default: wake()
                    }
                }
            // The Subtitles and Audio dialogs cover the stage, so the transport steps aside for them.
            if chrome, resumePending == nil, !leaveConfirm, panel == nil || panel == .anime4k, status.state != "error" || (isLive && liveGuide == nil) { chromeView.transition(.opacity) }
            if let resumePending { resumePrompt(resumePending).transition(.opacity) }
            if leaveConfirm { leaveConfirmView.transition(.opacity) }
            if status.state == "error", !isLive { sourceErrorCard.transition(.opacity) }
            if status.state == "error", isLive, liveGuide != nil, panel == nil { liveErrorCard.transition(.opacity) }
            if status.state == "loading", !isLive, resumePending == nil, Date().timeIntervalSince(loadingSince) >= 2 { connectingCard.transition(.opacity) }
            if panel == nil, !leaveConfirm, resumePending == nil {
                if showUpNextCard, let upNext {
                    upNextCard(upNext).transition(.move(edge: .bottom).combined(with: .opacity))
                } else if let seg = activeSegment {
                    skipPill(seg).transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            if let panel {
                panelView(panel).transition(panel == .anime4k ? AnyTransition.move(edge: .trailing).combined(with: .opacity) : AnyTransition.opacity)
            }
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
            else if panel != nil { closePanel() }
            else if showUpNextCard { cancelAutoNext() }                     // bp-up-next: Back is "Keep watching"
            else if focus == .chip("skip") { focus = .surface }
            else if chrome { chrome = false }
            else { requestClose() }
        }
        // use-player-media: a torrent served by the TV's engine belongs to this player while it is
        // open, and is removed once it closes (TorrentEngine; a no-op for every other URL).
        .onAppear { focus = .surface; scheduleHide(); PlaybackState.shared.active = true; TorrentEngine.shared.playerOpened(url: url) }
        .onDisappear { PlaybackState.shared.active = false; TorrentEngine.shared.playerClosed(url: url) }
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
            let profile = ProfilesStore.shared.active
            do {
                let loaded: PlayerPrefs = try await HarborEngine.shared.call("player.prefs", [profile?.id ?? "default", profile?.linked ?? true])
                prefs = loaded
            } catch {}
        }
        .onReceive(tick) { _ in
            if let c = controller {
                snap = c.snapshot()
                muted = c.isMuted()
                buffered = c.bufferedSec()
            }
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
        guard let context, !context.playlistVod, snap.duration > 0 else { return }
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
        // bp-skip-pill: an outro with an episode after it reads "Next Episode" and plays it.
        let outroNext = isOutro(seg) && hasNextEp && leadSec > 0
        return VStack {
            Spacer()
            HStack {
                Spacer()
                Button {
                    if outroNext { playNext(); return }
                    skippedIds.insert(seg.id)
                    controller?.seek(to: seg.endSec)
                    wake()
                } label: {
                    HStack(spacing: BP.px(8)) {
                        Image(systemName: outroNext ? "chevron.forward.2" : "forward.fill")
                        Text(outroNext ? "Next Episode" : seg.label).font(BP.sans(14, .semibold))
                    }
                    .foregroundStyle(BP.ink)
                    .padding(.horizontal, BP.px(14)).padding(.vertical, BP.px(10))
                    .background(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).fill(BP.void_.opacity(0.92)))
                    .overlay(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).stroke(BP.edge2, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .focused($focus, equals: .chip("skip"))
            }
            .padding(.bottom, chrome ? BP.px(300) : BP.px(40)).padding(.trailing, BP.gutter)
        }
        .ignoresSafeArea()
        // bp-skip-pill: a soft target. It never takes the ring on arrival (Select must keep meaning
        // pause); Up from the surface or the transport reaches it, Menu hands the ring back.
    }

    // MARK: up next (bp-up-next.tsx, skip-pill-container.tsx, use-auto-next-episode.ts)

    private var hasNextEp: Bool { upNext != nil && !autoNextCancelled && !isLive }
    private var remainingSec: Double { max(0, snap.duration - snap.position) }
    /// skip-pill-container.tsx nextEpisodeLead: 0 = off, > 0 = fixed, -1 = 4 % of the runtime within 15–45 s.
    private var leadSec: Double {
        let setting = prefs.nextEpisodeLeadSec
        if setting == 0 { return 0 }
        if setting > 0 { return setting }
        return min(45, max(15, (snap.duration * 0.04).rounded()))
    }
    private func isOutro(_ seg: SkipSegment) -> Bool { seg.kind == "outro" || seg.kind == "credits" }

    /// The card shows inside the lead: over a real outro segment, or as the synthetic outro when the
    /// title has none (skip-pill-container syntheticOutro).
    private var showUpNextCard: Bool {
        guard hasNextEp, leadSec > 0, snap.duration > 0, remainingSec > 0, remainingSec <= leadSec else { return false }
        if let seg = activeSegment { return isOutro(seg) }
        return remainingSec >= 0.5 && !segments.contains { isOutro($0) }
    }

    /// use-episode-navigation goToEpisode: the caller opens the next episode's picker with instant play.
    private func playNext() { finish(natural: false, advance: true) }

    private func cancelAutoNext() {
        autoNextCancelled = true
        focus = .surface
        wake()
    }

    /// use-auto-next-episode.ts: at a natural end the next episode follows unless the viewer chose
    /// "Keep watching", autoPlayNextEpisode is off, or the file is a stub (under 150 s).
    private func endedNaturally() {
        let advance = upNext != nil && prefs.autoPlayNextEpisode && !autoNextCancelled && snap.duration >= 150
        finish(natural: true, advance: advance)
    }

    /// bp-up-next.tsx BpUpNext: the next episode, a countdown ring, "Play now" and "Keep watching".
    /// It never takes the ring on arrival (Select keeps meaning pause); Up or the chrome reaches it.
    private func upNextCard(_ text: String) -> some View {
        let seconds = Int(remainingSec.rounded(.up))
        let progress = leadSec > 0 ? min(1, max(0, 1 - Double(seconds) / leadSec)) : 0
        let parts = text.components(separatedBy: " · ")
        let epLabel = parts.first ?? text
        let name = parts.dropFirst().joined(separator: " · ")
        let heading = name.isEmpty ? epLabel : name
        return VStack {
            Spacer()
            HStack {
                Spacer()
                HStack(alignment: .top, spacing: BP.px(16)) {
                    ZStack {
                        RoundedRectangle(cornerRadius: BP.rMD, style: .continuous).fill(BP.panel)
                        Text(epLabel).font(BP.sans(11, .bold)).textCase(.uppercase).tracking(1.8).foregroundStyle(BP.inkSubtle)
                    }
                    .frame(width: BP.px(200), height: BP.px(112))
                    VStack(alignment: .leading, spacing: BP.px(6)) {
                        HStack(alignment: .top) {
                            Text("Up Next").font(BP.sans(11.5, .bold)).textCase(.uppercase).tracking(1.6).foregroundStyle(BP.inkSubtle)
                            Spacer()
                            countdownRing(seconds: seconds, progress: progress)
                        }
                        Text(heading).font(BP.display(20)).foregroundStyle(BP.ink).lineLimit(2)
                        if heading != epLabel {
                            Text(epLabel).font(BP.sans(12, .medium)).foregroundStyle(BP.inkSubtle).lineLimit(1)
                        }
                        HStack(spacing: BP.px(10)) {
                            Button { playNext() } label: { Label("Play now", systemImage: "play.fill") }
                                .buttonStyle(BPActionStyle())
                                .focused($focus, equals: .chip("upnext-play"))
                            Button { cancelAutoNext() } label: { Label("Keep watching", systemImage: "xmark") }
                                .buttonStyle(BPActionStyle())
                                .focused($focus, equals: .chip("upnext-keep"))
                        }
                        .padding(.top, BP.px(6))
                    }
                }
                .padding(BP.px(18))
                .frame(width: BP.px(600), alignment: .leading)
                .background(RoundedRectangle(cornerRadius: BP.rLG, style: .continuous).fill(BP.panel2))
                .overlay(RoundedRectangle(cornerRadius: BP.rLG, style: .continuous).stroke(BP.edge2, lineWidth: 1))
                .shadow(color: .black.opacity(0.9), radius: 60, y: 40)
                .focusSection()
            }
            .padding(.bottom, chrome ? BP.px(300) : BP.px(40)).padding(.trailing, BP.gutter)
        }
        .ignoresSafeArea()
    }

    /// bp-up-next.tsx CountdownRing: whole seconds left, the ring filling toward the jump.
    private func countdownRing(seconds: Int, progress: Double) -> some View {
        ZStack {
            Circle().stroke(BP.edge2, lineWidth: 3.5)
            Circle().trim(from: 0, to: progress)
                .stroke(BP.accent, style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(seconds)").font(BP.sans(15, .bold)).foregroundStyle(BP.ink).monospacedDigit()
        }
        .frame(width: BP.px(46), height: BP.px(46))
        .animation(.linear(duration: 0.2), value: progress)
    }

    // MARK: chrome

    private var chromeView: some View {
        VStack(alignment: .leading, spacing: BP.px(14)) {
            Spacer()
            HStack(alignment: .lastTextBaseline, spacing: BP.px(14)) {
                VStack(alignment: .leading, spacing: BP.px(4)) {
                    Text(shownTitle).font(BP.display(26)).foregroundStyle(BP.ink)
                    if let s = shownSubtitle { Text(s).font(BP.sans(15, .semibold)).foregroundStyle(BP.inkMuted) }
                }
                Spacer()
                Text(status.state == "loading" ? "Loading…" : status.videoParams.split(separator: " ").prefix(3).joined(separator: " "))
                    .font(BP.sans(12, .medium)).foregroundStyle(BP.inkSubtle)
            }
            if !isLive {
                seekBar
                scrubReadout
            }
            // bp-player-controls.tsx: the transport. A series gets Previous / Next episode, each dimmed
            // when there is none; VOD gets Back / Forward by the seek step.
            HStack(spacing: BP.px(10)) {
                if !isLive, onPreviousEpisode != nil || upNext != nil {
                    iconChip("prev", "backward.end.fill") { let go = onPreviousEpisode; finish(natural: false); go?() }
                        .disabled(onPreviousEpisode == nil)
                }
                if !isLive { iconChip("rewind", "gobackward") { seekBy(-prefs.seekBackStepSec) } }
                chip(snap.paused ? "Play" : "Pause", snap.paused ? "play.fill" : "pause.fill", id: "playpause") { togglePause() }
                if !isLive { iconChip("forward", "goforward") { seekBy(prefs.seekForwardStepSec) } }
                if !isLive, onPreviousEpisode != nil || upNext != nil {
                    iconChip("next", "forward.end.fill") { playNext() }
                        .disabled(upNext == nil)
                }
                Spacer()
            }
            .focusSection()
            // bp-player-rail.tsx: Back, one chip per panel, then the mute toggle.
            HStack(spacing: BP.px(10)) {
                chip("Back", "chevron.left") { requestClose() }
                chip("Subtitles", "captions.bubble") { open(.subtitles) }
                chip("Audio", "waveform") { open(.audio) }
                if !isLive { chip(anime4kChipLabel, "sparkles", id: "anime4k") { open(.anime4k) } }
                if onSwitchSource != nil { chip("Sources", "list.bullet") { let go = onSwitchSource; let at = snap.position; finish(natural: false); go?(at) } }
                // control-renderer.tsx: on a live channel the pick-another control is the "TV Guide".
                if isLive, liveGuide != nil { chip("TV Guide", "list.bullet.rectangle", id: "tvguide") { open(.channels) } }
                // use-player-hotkeys playerPrevChannel: back to the last channel watched.
                if isLive, !prevChannels.isEmpty { chip("Previous channel", "arrow.uturn.backward", id: "prevchannel") { goPrevChannel() } }
                if isLive, let add = onAddToMultiview, let ch = currentChannel {
                    chip("Add to Multiview", "rectangle.split.2x2", id: "multiview") { finish(natural: false); add(ch) }
                }
                // bp-player-rail: the mute toggle ("Muted" / "Sound on").
                chip(muted ? "Muted" : "Sound on", muted ? "speaker.slash.fill" : "speaker.wave.2.fill", id: "mute", active: muted) {
                    controller?.setMuted(!muted)
                    muted.toggle()
                }
                Spacer()
                if isLive { Text("LIVE").font(BP.sans(14, .semibold)).foregroundStyle(BP.live) }
            }
            .focusSection()
        }
        .padding(BP.gutter)
        .padding(.bottom, BP.px(10))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .background(LinearGradient(colors: [.clear, BP.void_.opacity(0.75), BP.void_.opacity(0.95)], startPoint: .init(x: 0.5, y: 0.45), endPoint: .bottom))
        .ignoresSafeArea()
    }

    /// bp-player-scrub.tsx: buffered fill under the played fill; while presses accumulate, a
    /// marker stays where playback really is.
    private var seekBar: some View {
        let shown = pendingSeek ?? snap.position
        return GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(BP.edge2)
                Capsule().fill(BP.ink.opacity(0.3)).frame(width: g.size.width * fraction(max(buffered, shown)))
                Capsule().fill(BP.ink).frame(width: g.size.width * fraction(shown))
                if pendingSeek != nil {
                    Capsule().fill(BP.accent).frame(width: 3).offset(x: g.size.width * fraction(snap.position) - 1.5)
                }
            }
        }
        .frame(height: BP.px(5))
        .padding(.vertical, BP.px(3))
    }

    private func fraction(_ sec: Double) -> CGFloat {
        guard snap.duration > 0, sec.isFinite else { return 0 }
        return CGFloat(min(1, max(0, sec / snap.duration)))
    }

    /// bp-player-scrub.tsx readout: position, "{time} left", "Ends {time}".
    private var scrubReadout: some View {
        let shown = pendingSeek ?? snap.position
        let remaining = snap.duration > 0 ? max(0, snap.duration - shown) : 0
        return HStack(spacing: BP.px(10)) {
            Text(fmt(shown)).foregroundStyle(pendingSeek == nil ? BP.inkSubtle : BP.ink)
            Spacer()
            if snap.duration > 0 {
                Text("\(fmt(remaining)) left").foregroundStyle(BP.inkSubtle)
                Text("Ends \(Date().addingTimeInterval(remaining).formatted(date: .omitted, time: .shortened))").foregroundStyle(BP.inkMuted)
            }
        }
        .font(BP.sans(13, .semibold))
        .monospacedDigit()
    }

    /// bp-player-scrub.tsx nudge(): each press adds a step to one pending seek, committed 420 ms after
    /// the last; a held direction ramps the step 1× → 3× (after 10) → 6× (after 26).
    private func nudgeSeek(ahead: Bool) {
        guard controller != nil else { return }
        let run = seekRun
        seekRun = run + 1
        let scale: Double = run < 10 ? 1 : (run < 26 ? 3 : 6)
        let delta = (ahead ? prefs.seekForwardStepSec : -prefs.seekBackStepSec) * scale
        let base = pendingSeek ?? snap.position
        let cap = snap.duration > 0 ? snap.duration - 1 : base + delta
        pendingSeek = max(0, min(cap, base + delta))
        wake()
        seekCommit?.cancel()
        seekCommit = Task {
            try? await Task.sleep(for: .milliseconds(420))
            if Task.isCancelled { return }
            if let target = pendingSeek {
                controller?.seek(to: target)
                snap.position = target
            }
            pendingSeek = nil
            seekRun = 0
        }
    }

    private func chip(_ label: String, _ icon: String, id: String? = nil, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: { action(); wake() }) { Label(label, systemImage: icon) }
            .buttonStyle(BPActionStyle(primary: active))
            .focused($focus, equals: .chip(id ?? label))
    }

    /// use-bp-playback seekBy: one step, clamped inside the file.
    private func seekBy(_ delta: Double) {
        let target = snap.position + delta
        let clamped = snap.duration > 0 ? min(snap.duration - 1, max(0, target)) : max(0, target)
        controller?.seek(to: clamped)
        snap.position = clamped
    }

    /// bp-player-controls.tsx BpControl: an icon-only transport button.
    private func iconChip(_ id: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: { action(); wake() }) { Image(systemName: icon) }
            .buttonStyle(BPActionStyle())
            .focused($focus, equals: .chip(id))
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
            closePanel()
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

    @ViewBuilder private func panelView(_ which: Panel) -> some View {
        switch which {
        case .anime4k:
            anime4kPanel()
        case .subtitles:
            PlayerSubtitlesPanel(controller: controller, context: context, title: title, subDelay: $subDelay) { closePanel() }
        case .audio:
            PlayerAudioPanel(controller: controller, title: title, audioDelay: $audioDelay) { closePanel() }
        case .channels:
            if let liveGuide {
                LivePlayerGuidePanel(model: liveGuide, current: currentChannel, onPick: { tune($0) }, onClose: { closePanel() })
            }
        }
    }

    // MARK: live channels (use-live-channel-overlay.ts)

    private var currentChannel: LiveModel.Channel? { tuned ?? liveChannel }
    private var playURL: URL { tuned.flatMap { URL(string: $0.url) } ?? url }
    private var playHeaders: [String: String] { tuned.map { $0.headers ?? [:] } ?? headers }
    private var shownTitle: String { tuned?.name ?? title }
    private var shownSubtitle: String? {
        guard let t = tuned else { return subtitle }
        return liveGuide?.guide[t.id]?.now?.title ?? t.group
    }

    /// switchChannel: the new stream replaces the old one in place; the channel we leave goes on
    /// the "Previous channel" stack (12 deep, no repeats on top).
    private func tune(_ ch: LiveModel.Channel) {
        let from = currentChannel
        guard ch.id != from?.id else { closePanel(); return }
        if let from {
            if prevChannels.last?.id != from.id { prevChannels.append(from) }
            if prevChannels.count > 12 { prevChannels.removeFirst() }
        }
        tuned = ch
        liveGuide?.played(ch)
        status = MPVPlayerController.Status()
        loadingSince = Date()
        controller = nil
        reloadToken += 1
        if panel != nil { closePanel() } else { wake() }
    }

    /// goPrevChannel: pop to the last channel that is not the one playing; tuning it pushes the
    /// one we leave, so the button flips between the two most recent channels.
    private func goPrevChannel() {
        let playing = currentChannel?.id
        var prev = prevChannels.popLast()
        while let p = prev, p.id == playing { prev = prevChannels.popLast() }
        guard let prev else { return }
        tune(prev)
    }

    /// live-channel-error.tsx: the channel is not answering; Back, Try again, or Browse channels.
    private var liveErrorCard: some View {
        VStack(alignment: .leading, spacing: BP.px(12)) {
            Spacer()
            HStack(spacing: BP.px(10)) {
                Image(systemName: "antenna.radiowaves.left.and.right.slash").foregroundStyle(BP.danger)
                Text("This channel isn't responding").font(BP.display(30)).foregroundStyle(BP.ink)
            }
            Text("It looks offline right now. Free playlists often include channels that have gone dark, so another one is usually a click away.")
                .font(BP.sans(16)).foregroundStyle(BP.inkMuted).frame(maxWidth: BP.px(900), alignment: .leading)
            HStack(spacing: BP.px(10)) {
                chip("Back", "chevron.left", id: "live-back") { finish(natural: false) }
                chip("Try again", "arrow.clockwise", id: "live-retry") { status = MPVPlayerController.Status(); loadingSince = Date(); controller = nil; reloadToken += 1 }
                chip("Browse channels", "list.bullet.rectangle", id: "live-browse") { open(.channels) }
            }
            .focusSection()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(BP.gutter).padding(.bottom, BP.px(20))
        .background(LinearGradient(colors: [.clear, BP.void_.opacity(0.6), BP.void_.opacity(0.95)], startPoint: .top, endPoint: .bottom).ignoresSafeArea())
        .onAppear { hideTask?.cancel(); focusLater(.chip("live-browse")) }
    }

    private func open(_ p: Panel) {
        panel = p
        hideTask?.cancel()
        // The Subtitles and Audio dialogs seed their own ring; Anime4K lands on its first option.
        if p == .anime4k { DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { focus = .track(-10) } }
    }

    private func closePanel() {
        panel = nil
        focus = .surface
        wake()
    }

    /// bp-connecting: while the stream is still opening, elapsed time and a way out; after 22 s the
    /// copy admits it is still looking. Focus moves here only once a start is clearly slow.
    private var connectingCard: some View {
        let elapsed = Int(Date().timeIntervalSince(loadingSince))
        return VStack(alignment: .leading, spacing: BP.px(10)) {
            Spacer()
            HStack(spacing: BP.px(10)) { ProgressView().tint(BP.ink); Text("Connecting…").font(BP.display(28)).foregroundStyle(BP.ink) }
            if TorrentEngine.streamRef(url) != nil {
                // bp-connecting with a torrent: bp-p2p-status's stage, readiness and peers/speed.
                TorrentReadout(url: url)
            } else {
                Text(elapsed >= 22 ? "Still looking. Some sources take a while to answer." : "The player is opening the stream. \(elapsed) s").font(BP.sans(15)).foregroundStyle(BP.inkMuted)
            }
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
        guard let context, !context.playlistVod, !isLive, snap.duration > 150 else { return }
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

    /// `natural`: the file played to its end (saved as finished). `advance`: the caller should move
    /// on to the next episode (defaults to `natural`, the way onClose always read).
    private func finish(natural: Bool, advance: Bool? = nil) {
        // "Play now" and the file's own end can both land in the last second; close once.
        guard !finishing else { return }
        finishing = true
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
            onClose(advance ?? natural)
            // The watched check on the tiles reads the flags this session just wrote.
            await CardMarksStore.shared.remark()
        }
    }
}
