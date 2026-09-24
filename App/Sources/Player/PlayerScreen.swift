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
    /// The picked stream's facts for the Auto engine rule (engine/player.ts pickEngine); nil plays
    /// by URL alone (live channels, sports links).
    var streamHints: PlayerStreamHints? = nil
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
    /// KidsStreamSwitcher onPick: the stream picked in place of the one opened (nil = the one opened).
    @State private var switched: SwitchedStream?
    /// Whether the stream was swapped in place (the kid switcher, a quality change): TrackMemory keys by the original release otherwise.
    var switchedInPlace: Bool { switched != nil }
    struct SwitchedStream { var url: URL; var headers: [String: String] }
    /// TransportKids' subtitle toggle reads the subtitle tracks (refreshed while its chrome is up).
    @State private var kidSubs: [MPVPlayerController.Track] = []
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
    @State private var controller: (any PlayerEngineControlling)?
    /// use-player-bridge.ts engine: mpv, or AVPlayer standing in for html5. Settled before startAt.
    @State private var engine: PlayerEngineKind = .mpv
    /// settings.playerEngine as read for this stream ("auto" | "mpv" | "html5").
    @State private var engineWant = "auto"
    /// use-player-bridge.ts autoFallbackTried: the native engine failed once; mpv has it now.
    @State private var engineFallbackTried = false
    /// player.tsx showNoAudioWarning: the native engine plays but cannot decode the audio.
    @State private var noAudioWarning = false
    /// use-pip-mode.ts pipMode: the picture is in the Picture in Picture window (AVPlayer engine only).
    @State private var pipActive = false
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
    /// skip-pill-container.tsx autoSkippedRef: the segment already auto-skipped (never twice, even
    /// when the viewer seeks back into it).
    @State private var autoSkippedId: String?
    /// The segment the last tick saw playing: auto-skip waits for a second tick inside it, so a
    /// position read before a resume seek lands never skips the viewer away from their spot.
    @State private var autoSkipSeen: String?
    /// skip-pill-container.tsx autoHiddenKey / dismissedKeys / prevSkipKeyRef: the pill hidden after
    /// skipButtonHideSec, or by its ✕, for the segment it belongs to.
    @State private var skipAutoHiddenKey: String?
    @State private var skipDismissedKeys: Set<String> = []
    @State private var prevSkipKey: String?
    @State private var skipHideTask: Task<Void, Never>?
    /// use-still-watching.ts prompt: the auto-advance waits on "Still watching?".
    @State private var stillPrompt = false
    /// speed-menu.tsx rate (bridge setRate); a title starts at settings.defaultPlaybackSpeed.
    @State private var rate: Double = 1
    /// use-sleep-timer.ts: the app-wide sleep timer, on the Speed & sleep control's face.
    @ObservedObject private var sleepTimer = SleepTimer.shared
    /// lib/media-session.ts: this player's claim on Now Playing and the remote commands.
    @State private var nowPlayingId = UUID()

    struct SkipSegment: Decodable, Identifiable {
        var kind: String       // "intro" | "outro" | "recap" | "ad" | ...
        var startSec: Double
        var endSec: Double
        var source: String
        var id: String { "\(kind)-\(startSec)-\(endSec)" }
        var label: String {
            switch kind {
            case "intro": return "Skip Intro"
            case "outro", "credits": return "Skip Credits"
            case "recap": return "Skip Recap"
            case "ad": return "Skip injected ad?"
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

    enum Panel { case audio, subtitles, anime4k, channels, kidsSources, homeServerQuality, speed }
    struct Anime4KChoice: Decodable { var active: Bool; var choice: String; var mode: String?; var tier: String?; var files: [String]; var indicator: Bool }
    @State private var anime4k: Anime4KChoice?
    @State private var anime4kAppliedFor: Int = -1
    @State private var anime4kNote: String?
    enum FocusTarget: Hashable { case surface, chip(String), track(Int) }

    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    @State private var scrobbleState: String?   // last action sent to Trakt
    @State private var lastScrobblePaused = false
    /// Watch Together (Together/TogetherPlayback.swift): room sync, lobby and the Room panel.
    @StateObject private var together = TogetherPlayback()
    @State private var roomOpen = false
    private static let hideAfter: Double = 4.6   // use-bp-player-chrome.ts

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if let startAt, engine == .native {
                // A report from a native player that is being replaced by mpv is dropped.
                NativePlayerView(url: playURL, headers: playHeaders, startAt: startAt, isLive: isLive,
                                 preferredAudio: SettingsBridge.shared.slice.preferredAudioLangs ?? ["English", "Japanese"],
                                 preferredSubs: SettingsBridge.shared.slice.preferredSubLangs,
                                 trackMemory: trackMemory,
                                 onStatus: { s in if engine == .native { status = s } },
                                 onEnded: { if engine == .native { endedNaturally() } },
                                 onUnsupported: { nativeUnsupported($0) },
                                 onReady: { c in
                                     guard engine == .native else { return }
                                     controller = c
                                     pipActive = false
                                     applyRate(c)
                                     if resumePending != nil { c.setPaused(true) }
                                 },
                                 onPictureInPicture: { on in if engine == .native { pipChanged(on) } })
                    .ignoresSafeArea()
                    .id(reloadToken)
            } else if let startAt {
                MPVPlayerView(url: playURL, headers: playHeaders, startAt: startAt, isLive: isLive,
                              preferredAudio: SettingsBridge.shared.slice.preferredAudioLangs ?? ["English", "Japanese"],
                              preferredSubs: SettingsBridge.shared.slice.preferredSubLangs,
                              trackMemory: trackMemory,
                              onStatus: { status = $0 }, onEnded: { endedNaturally() },
                              onReady: { controller = $0; pipActive = false; applyRate($0); if resumePending != nil { $0.setPaused(true) } })
                    .ignoresSafeArea()
                    .id(reloadToken)
            } else {
                BP.void_.ignoresSafeArea()
            }
            // Watch Together: roster, lobby, room chat lines, drawings/cursors (view-only, no focus).
            TogetherPlayerLayer(playback: together)
            // The invisible surface holds focus while the chrome is down so remote presses reach us.
            Button { togglePause() } label: { Color.clear.contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .disabled(panel != nil || resumePending != nil || leaveConfirm || roomOpen || pipActive || kidsLoading || stillPrompt)
                .focused($focus, equals: .surface)
                .onMoveCommand { dir in
                    switch dir {
                    case .left: if isLive { controller?.seek(-10); wake() } else { nudgeSeek(ahead: false) }
                    case .right: if isLive { controller?.seek(10); wake() } else { nudgeSeek(ahead: true) }
                    case .up where showUpNextCard: StillWatching.reset(); focus = .chip("upnext-keep")
                    case .up where activeSkip != nil: StillWatching.reset(); focus = .chip("skip")
                    default: wake()
                    }
                }
            // The Subtitles and Audio dialogs cover the stage, so the transport steps aside for them.
            if chrome, !pipActive, !roomOpen, resumePending == nil, !leaveConfirm, !kidsLoading, !stillPrompt, panel == nil || panel == .anime4k, status.state != "error" || (isLive && liveGuide == nil) {
                // transport.tsx: a kid profile gets TransportKids instead of the full transport
                // (`kid && !pipMode`; TransportKids has no PiP control, so a kid never leaves for PiP).
                Group { if isKid { kidsChrome } else { chromeView } }.transition(.opacity)
            }
            if let resumePending {
                Group { if isKid { kidsResumePrompt } else { resumePrompt(resumePending) } }.transition(.opacity)
            }
            if leaveConfirm { leaveConfirmView.transition(.opacity) }
            if status.state == "error", !isLive, !roomOpen, !pipActive { sourceErrorCard.transition(.opacity) }
            if status.state == "error", isLive, liveGuide != nil, panel == nil, !roomOpen, !pipActive { liveErrorCard.transition(.opacity) }
            if status.state == "loading", !isKid, !isLive, !roomOpen, !pipActive, resumePending == nil, Date().timeIntervalSince(loadingSince) >= 2 { connectingCard.transition(.opacity) }
            // cinematic-player-loader.tsx: a kid gets the sea loader over everything until the first frame.
            if kidsLoading { kidsLoader.transition(.opacity) }
            if noAudioWarning, engine == .native, panel == nil, !leaveConfirm, !roomOpen, !pipActive, resumePending == nil, status.state != "error" {
                noAudioCard.transition(.opacity)
            }
            if panel == nil, !leaveConfirm, !roomOpen, resumePending == nil, !pipActive, !stillPrompt {
                if showUpNextCard, let upNext {
                    upNextCard(upNext).transition(.move(edge: .bottom).combined(with: .opacity))
                } else if let seg = activeSkip {
                    skipPill(seg).transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            // player.tsx StillWatchingPrompt: over everything but the Together room and PiP.
            if stillPrompt, !roomOpen, !pipActive {
                StillWatchingPrompt(show: context?.meta.name ?? title, nextLabel: stillWatchingNextLabel, focus: $focus,
                                    onContinue: { continueWatching() }, onExit: { stopWatching() })
                    .transition(.opacity)
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
            // The Watch Together room over the picture. Not a fullScreenCover: covering the player
            // would make it disappear (PlaybackState, the torrent's owner) while the room is open.
            if roomOpen {
                TogetherView(inPlayer: true, onClose: { roomOpen = false; focus = .surface; wake() })
                    .transition(.opacity)
            }
            if pipActive { pipPlacard.transition(.opacity) }
        }
        // media-session.ts mediaKeyGate: a press that also reaches us as a remote command toggles once.
        .onPlayPauseCommand { if VideoNowPlaying.shared.mediaKeyGate() { togglePause() } }
        .onExitCommand {
            StillWatching.reset()
            if pipActive { controller?.stopPictureInPicture() }                 // back to the full picture first
            else if stillPrompt { stopWatching() }                              // still-watching-prompt: Escape is Stop
            else if roomOpen { roomOpen = false; focus = .surface; wake() }   // the inline Watch Together room closes first (review 22)
            else if resumePending != nil { acknowledgeResume(true) }     // Back takes the default action (bp-resume-prompt)
            else if leaveConfirm { leaveConfirm = false; controller?.setPaused(false); focus = .surface; wake() }
            else if panel != nil { closePanel() }
            else if kidsLoading { finish(natural: false) }                   // the kid loader's Cancel (onCancel closes, no leave dialog)
            else if noAudioWarning, engine == .native { noAudioWarning = false; focus = .surface; wake() }  // header-warning "Dismiss"
            else if showUpNextCard { cancelAutoNext() }                     // bp-up-next: Back is "Keep watching"
            else if focus == .chip("skip") || focus == .chip("skip-dismiss") { focus = .surface }
            else if chrome { chrome = false }
            else { requestClose() }
        }
        // use-player-media: a torrent served by the TV's engine belongs to this player while it is
        // open, and is removed once it closes (TorrentEngine; a no-op for every other URL).
        .onAppear {
            focus = .surface; scheduleHide(); PlaybackState.shared.active = true; TorrentEngine.shared.playerOpened(url: url)
            SleepTimer.shared.playerOpened(url: url)
            // use-sleep-timer.ts registerSleepFireHandler: a minutes timer running out pauses this player.
            SleepTimer.shared.register(nowPlayingId) { sleepFired() }
            beginNowPlaying()
        }
        .onDisappear {
            SleepTimer.shared.unregister(nowPlayingId)
            skipHideTask?.cancel()
            // media-session.ts clearMediaControls before PlaybackState lets the music take Now Playing back.
            VideoNowPlaying.shared.end(nowPlayingId)
            PlaybackState.shared.active = false; TorrentEngine.shared.playerClosed(url: switched?.url ?? url)
        }
        .onReceive(CurfewState.shared.$locked) { if $0 { finish(natural: false) } }
        // The app now declares background audio for music; a film or channel still stops
        // when the viewer leaves the app (mpv would otherwise keep sounding), unless it is
        // playing in Picture in Picture, which is how it keeps going over other apps.
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
            if controller?.isPictureInPictureActive != true { controller?.setPaused(true) }
        }
        .task {
            // use-player-bridge.ts / player-utils.ts pickBridge: settle the engine before anything loads.
            await settleEngine(for: playURL, hints: streamHints)
            // use-bridge-load: no resume for live or when the viewer turned it off; a saved spot past
            // RESUME_PROMPT_MIN_SEC (30 s) becomes a fork when resumePrompt is on, else a silent seek.
            let slice = SettingsBridge.shared.slice
            var sec = (!isLive && (slice.resumePlayback ?? true)) ? (await context?.startPosition() ?? 0) : 0
            // A source switch or a home-server copy carries its own position (use-bridge-load hasExplicitStart).
            if let x = context?.explicitStartSec, x > 0 { sec = x }
            else if let h = context?.homeServer, h.resumeSec > 0 { sec = h.resumeSec }
            if sec <= 5 { sec = 0 }
            // use-track-autoload.ts: a title starts at settings.defaultPlaybackSpeed (live has no speed).
            if !isLive, let r = slice.defaultPlaybackSpeed, r.isFinite, r > 0 { rate = r }
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
                // A player that closed meanwhile must not claim Now Playing back (review 28).
                if !Task.isCancelled, !finishing { beginNowPlaying() }   // the remote's skip intervals follow the seek steps
            } catch {}
        }
        .onReceive(tick) { _ in
            if let c = controller {
                snap = c.snapshot()
                muted = c.isMuted()
                if pipActive, !c.isPictureInPictureActive { pipChanged(false) }
                buffered = c.bufferedSec()
                if isKid, chrome { kidSubs = c.tracks().filter { $0.type == "sub" } }
            }
            // Anime4K is an mpv shader chain (html5 bridge: setAnime4kShaders() {}).
            if !isLive, engine == .mpv, let c = controller, status.state != "loading" {
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
            together.tick(controller: controller, context: isLive ? nil : context, url: url)
            if snap.duration > 0, segmentsLoadedFor != snap.duration { segmentsLoadedFor = snap.duration; Task { await loadSegments() } }
            skipTick()
            nowPlayingTick()
        }
        .animation(.easeOut(duration: 0.32), value: chrome)
        .animation(.easeOut(duration: 0.32), value: panel == nil)
        .animation(.easeOut(duration: 0.32), value: roomOpen)
    }

    // MARK: skip pill (skip-pill-container.tsx, bp-skip-pill.tsx)

    /// skip-intro/index.ts activeSegment: the segment the playhead is inside (realActiveSkip).
    private var realActiveSkip: SkipSegment? {
        segments.first { snap.position >= $0.startSec && snap.position < $0.endSec - 0.75 }
    }

    /// player.tsx hasNextEpisodeNow: there is an episode after this one ("Keep watching" aside).
    private var hasNextEpisodeNow: Bool { upNext != nil && !isLive }

    /// skip-pill-container syntheticOutro: inside the up-next lead, a title with no real outro gets
    /// one that runs to the end.
    private var syntheticOutro: SkipSegment? {
        guard realActiveSkip == nil, hasNextEpisodeNow, snap.duration > 0, leadSec > 0 else { return nil }
        let remaining = snap.duration - snap.position
        guard remaining <= leadSec, remaining >= 0.5, !segments.contains(where: { isOutro($0) }) else { return nil }
        return SkipSegment(kind: "outro", startSec: max(0, snap.duration - leadSec), endSec: snap.duration, source: "chapters")
    }

    /// skip-pill-container buttonKey: the real segment the pill is showing, when showSkipButton is on.
    private var skipButtonKey: String? {
        guard let seg = realActiveSkip, SettingsBridge.shared.slice.showSkipButton ?? true else { return nil }
        return "\(seg.kind):\(Int(seg.startSec.rounded())):\(Int(seg.endSec.rounded()))"
    }

    /// skip-pill-container displaySkip: the real segment, unless showSkipButton is off or its pill
    /// was hidden (skipButtonHideSec ran out, or the viewer pressed its ✕).
    private var displaySkip: SkipSegment? {
        guard let key = skipButtonKey, key != skipAutoHiddenKey, !skipDismissedKeys.contains(key) else { return nil }
        return realActiveSkip
    }

    /// skip-pill-container activeSkip: what the pill (or the up-next card) is about.
    private var activeSkip: SkipSegment? { displaySkip ?? syntheticOutro }

    /// player.tsx allowAutoSkip = !roomGuest: in a Watch Together room only the host auto-skips.
    private var allowAutoSkip: Bool { !(together.inRoom && !together.isHost) }

    /// skip-pill-container.tsx effects on the 1 s tick: auto-skip (autoSkipIntro / Recap / Outro / Ad,
    /// once per segment), then the pill's skipButtonHideSec timer, keyed to the segment it shows.
    private func skipTick() {
        let s = SettingsBridge.shared.slice
        let playingIn = status.state == "playing" && resumePending == nil ? realActiveSkip : nil
        if allowAutoSkip, let seg = playingIn, autoSkippedId != seg.id, autoSkipSeen == seg.id {
            let want = (seg.kind == "intro" && (s.autoSkipIntro ?? false))
                || (seg.kind == "recap" && (s.autoSkipRecap ?? false))
                || (isOutro(seg) && (s.autoSkipOutro ?? false))
                || (seg.kind == "ad" && (s.autoSkipAd ?? false))
            if want {
                autoSkippedId = seg.id
                skipTo(seg.endSec)
            }
        }
        autoSkipSeen = playingIn?.id
        let key = skipButtonKey
        if key != prevSkipKey {
            // prevSkipKeyRef: the segment we left gets its pill back if the viewer returns to it.
            if let previous = prevSkipKey {
                if skipAutoHiddenKey == previous { skipAutoHiddenKey = nil }
                skipDismissedKeys.remove(previous)
            }
            prevSkipKey = key
            skipHideTask?.cancel()
            let hideSec = s.skipButtonHideSec ?? 0
            if let key, hideSec > 0 {
                skipHideTask = Task {
                    try? await Task.sleep(for: .seconds(hideSec))
                    if !Task.isCancelled { skipAutoHiddenKey = key }
                }
            }
        }
        // A pill that went away takes the ring back to the stage.
        if activeSkip == nil, focus == .chip("skip") || focus == .chip("skip-dismiss") { focus = .surface }
    }

    /// player-overlay-layers onSkip = seekTo: through the Watch Together room when in one.
    private func skipTo(_ sec: Double) {
        let target = snap.duration > 0 ? min(sec, snap.duration) : sec
        if together.interceptSeek(to: target, controller: controller) { return }
        controller?.seek(to: target)
        snap.position = target
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
        // skip-pill-container: new segments start over (auto-skip memory, hidden pills).
        if segs.map(\.id) != segments.map(\.id) {
            autoSkippedId = nil
            skipAutoHiddenKey = nil
            skipDismissedKeys = []
            prevSkipKey = nil
            skipHideTask?.cancel()
        }
        segments = segs
    }

    /// bp-skip-pill isOutroNext: an outro with an episode after it reads "Next Episode" and plays it.
    private func isOutroNext(_ seg: SkipSegment) -> Bool { isOutro(seg) && hasNextEp && leadSec > 0 }

    private func skipPill(_ seg: SkipSegment) -> some View {
        let outroNext = isOutroNext(seg)
        // bp-skip-pill onDismiss: a real segment's pill carries a ✕ ("Hide this Skip button").
        let dismissKey = displaySkip != nil && !outroNext ? skipButtonKey : nil
        return VStack {
            Spacer()
            HStack(spacing: BP.px(10)) {
                Spacer()
                Button {
                    if outroNext { playNext(); return }
                    skipTo(seg.endSec)
                    wake()
                } label: {
                    HStack(spacing: BP.px(8)) {
                        Image(systemName: outroNext ? "chevron.forward.2" : "forward.fill")
                        Text(T(outroNext ? "Next Episode" : seg.label)).font(BP.sans(14, .semibold))
                    }
                    .foregroundStyle(BP.ink)
                    .padding(.horizontal, BP.px(14)).padding(.vertical, BP.px(10))
                    .background(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).fill(BP.void_.opacity(0.92)))
                    .overlay(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).stroke(BP.edge2, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .focused($focus, equals: .chip("skip"))
                if let dismissKey {
                    Button {
                        skipDismissedKeys.insert(dismissKey)
                        focus = .surface
                        wake()
                    } label: {
                        Image(systemName: "xmark").font(.system(size: BP.px(14), weight: .bold))
                            .foregroundStyle(BP.inkSubtle)
                            .padding(BP.px(12))
                            .background(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).fill(BP.void_.opacity(0.92)))
                            .overlay(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).stroke(BP.edge2, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .focused($focus, equals: .chip("skip-dismiss"))
                    .accessibilityLabel(Text(T("Hide this Skip button")))
                }
            }
            .focusSection()
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

    /// bp-skip-pill asUpNext: the pill turns into the up-next card inside the lead, over a real
    /// outro or the synthetic one. A real outro whose pill is hidden (or showSkipButton off) shows neither.
    private var showUpNextCard: Bool {
        guard let seg = activeSkip, isOutroNext(seg) else { return false }
        return remainingSec > 0 && remainingSec <= leadSec
    }

    /// use-episode-navigation goToEpisode: the caller opens the next episode's picker with instant play.
    private func playNext() { StillWatching.reset(); finish(natural: false, advance: true) }

    private func cancelAutoNext() {
        autoNextCancelled = true
        focus = .surface
        wake()
    }

    /// use-auto-next-episode.ts: at a natural end the next episode follows unless the viewer chose
    /// "Keep watching", autoPlayNextEpisode is off, or the file is a stub (under 150 s).
    private func endedNaturally() {
        guard !stillPrompt else { return }
        // use-sleep-timer.ts: "End of episode" (or the last of "End of next episode") stops here.
        let sleepStops = SleepTimer.shared.episodeEnded()
        let advance = !sleepStops && upNext != nil && prefs.autoPlayNextEpisode && !autoNextCancelled && snap.duration >= 150
        // player.tsx autoAdvance → use-still-watching gateAdvance: enough episodes in a row with no
        // press asks "Still watching?" instead of moving on.
        let s = SettingsBridge.shared.slice
        if advance, StillWatching.gate(enabled: s.stillWatching ?? false, threshold: Int((s.stillWatchingAfter ?? 3).rounded())) {
            stillPrompt = true
            hideTask?.cancel()
            chrome = false
            if panel != nil { panel = nil }
            focusLater(.chip("still-continue"))
            return
        }
        finish(natural: true, advance: advance)
    }

    /// still-watching-prompt "S{season} E{episode}" of the episode that would play next.
    private var stillWatchingNextLabel: String? {
        guard context?.season != nil, let upNext else { return nil }
        return upNext.components(separatedBy: " · ").first
    }

    /// use-still-watching continueWatching: the count starts over and the next episode plays.
    private func continueWatching() {
        StillWatching.reset()
        stillPrompt = false
        finish(natural: true, advance: true)
    }

    /// use-still-watching stopWatching: the count starts over and the player closes.
    private func stopWatching() {
        StillWatching.reset()
        stillPrompt = false
        finish(natural: true, advance: false)
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
                Text(status.state == "loading" ? T("Loading…") : status.videoParams.split(separator: " ").prefix(3).joined(separator: " "))
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
                // speed-menu.tsx "Speed & sleep": its face shows the sleep countdown, else a changed rate.
                chip(speedChipLabel, sleepTimer.isActive ? "clock" : "speedometer", id: "speed",
                     active: sleepTimer.isActive || (!isLive && abs(rate - 1) > 0.01)) { open(.speed) }
                // control-renderer.tsx "pip": only when the engine can (capabilities().pictureInPicture);
                // mpv cannot, so the control is not there on that engine.
                if controller?.supportsPictureInPicture == true {
                    chip("Picture in Picture", "pip.enter", id: "pip") { controller?.startPictureInPicture() }
                }
                if !isLive, engine == .mpv { chip(anime4kChipLabel, "sparkles", id: "anime4k") { open(.anime4k) } }
                if onSwitchSource != nil { chip("Sources", "list.bullet") { let go = onSwitchSource; let at = snap.position; finish(natural: false); go?(at) } }
                // bp-ten-foot.tsx home-server-quality slot: a Plex/Jellyfin/Emby copy switches quality in place.
                if !isLive, context?.homeServer != nil { chip("Quality", "dial.medium", id: "hsquality") { open(.homeServerQuality) } }
                // control-renderer.tsx: on a live channel the pick-another control is the "TV Guide".
                if isLive, liveGuide != nil { chip("TV Guide", "list.bullet.rectangle", id: "tvguide") { open(.channels) } }
                // use-player-hotkeys playerPrevChannel: back to the last channel watched.
                if isLive, !prevChannels.isEmpty { chip("Previous channel", "arrow.uturn.backward", id: "prevchannel") { goPrevChannel() } }
                if isLive, let add = onAddToMultiview, let ch = currentChannel {
                    chip("Add to Multiview", "rectangle.split.2x2", id: "multiview") { finish(natural: false); add(ch) }
                }
                // Watch Together: the room panel (chat, people) over the playing video.
                if together.inSession { chip("Room", "person.2.fill") { roomOpen = true } }
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
                if !together.interceptSeek(to: target, controller: controller) {
                    controller?.seek(to: target)
                    snap.position = target
                }
            }
            pendingSeek = nil
            seekRun = 0
        }
    }

    private func chip(_ label: String, _ icon: String, id: String? = nil, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: { action(); wake() }) { Label(T(label), systemImage: icon) }
            .buttonStyle(BPActionStyle(primary: active))
            .focused($focus, equals: .chip(id ?? label))
    }

    /// use-bp-playback seekBy: one step, clamped inside the file.
    private func seekBy(_ delta: Double) {
        let target = snap.position + delta
        let clamped = snap.duration > 0 ? min(snap.duration - 1, max(0, target)) : max(0, target)
        if together.interceptSeek(to: clamped, controller: controller) { return }
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
                            HStack { Text(T(o.1)).font(BP.sans(14, .semibold)); Spacer(); if current == o.0 { Image(systemName: "checkmark") } }
                            Text(T(o.2)).font(BP.sans(11)).foregroundStyle(BP.inkMuted).lineLimit(2)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(BPActionStyle(primary: current == o.0))
                    .focused($focus, equals: .track(-10 - i))
                }
                if let a = anime4k, a.active { BPNote(text: T("Running mode %@ (%@). Stutter? Switch the tier to Fast in Settings.", a.mode ?? "", a.tier == "fast" ? T("Fast") : "HQ")) }
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
        case .homeServerQuality:
            if let h = context?.homeServer {
                HomeServerQualityPanel(session: h, positionSec: snap.position, playing: !snap.paused,
                                       onSwitched: { next, headers in switchStream(to: next, headers: headers) }, onClose: { closePanel() })
            }
        case .kidsSources:
            if let context {
                KidsStreamSwitcher(meta: context.meta, episode: kidsEpisode(context), currentURL: playURL,
                                   onPicked: { next, headers in switchStream(to: next, headers: headers) }, onClose: { closePanel() })
            }
        case .speed:
            PlayerSpeedPanel(rate: rate, isLive: isLive, onRate: { setRate($0) }, onClose: { closePanel() })
        }
    }

    // MARK: kid profiles (transport-kids.tsx, kids-switcher.tsx, resume-prompt.tsx; useActiveKid)

    private var isKid: Bool { ProfilesStore.shared.active?.kid != nil }

    /// player.tsx canPickAnother, for a title the kid switcher can search again.
    private var kidsCanSwitch: Bool {
        guard let context, !isLive else { return false }
        return !context.playlistVod && context.homeServer == nil
    }

    private var kidsChrome: some View {
        KidsPlayerTransport(title: shownTitle, resolution: resolutionLabel, isLive: isLive, position: pendingSeek ?? snap.position,
                            duration: snap.duration, buffered: buffered, paused: snap.paused, muted: muted,
                            hasSubtitles: !kidSubs.isEmpty, subtitlesOn: kidSubs.contains { $0.selected }, canPickAnother: kidsCanSwitch,
                            focus: $focus,
                            onBack: { requestClose() },
                            onPlayPause: { togglePause() },
                            onSeekStep: { seekBy($0); wake() },
                            onMute: { controller?.setMuted(!muted); muted.toggle(); wake() },
                            onSubtitles: { toggleKidSubtitles(); wake() },
                            onPickAnother: { open(.kidsSources) })
    }

    /// cinematic-player-loader.tsx `showing` for a kid: from the start until the stream plays (a
    /// switched video, a retry or a new source starts it again), never over the resume fork, an
    /// error, a live channel (its own card) or the Together room.
    private var kidsLoading: Bool {
        guard isKid, !isLive, !roomOpen, !pipActive, resumePending == nil, !stillPrompt else { return false }
        return status.state == "idle" || status.state == "loading"
    }

    private var kidsLoader: some View {
        let meta = context?.meta
        return KidsPlayerLoader(backdrop: meta?.background ?? meta?.poster, logo: meta?.logo, title: shownTitle,
                                episodeLine: kidsEpisodeLine,
                                torrentURL: TorrentEngine.streamRef(playURL) != nil ? playURL : nil,
                                isLocalFile: playURL.isFileURL, focus: $focus,
                                onCancel: { finish(natural: false) },
                                // The connecting card's Try again (player.tsx onLoaderRetry reloads the same URL).
                                onRetry: { status = MPVPlayerController.Status(); loadingSince = Date(); reloadToken += 1 })
            .onAppear { focusLater(.chip("kids-cancel")) }
            // The ring goes back to the stage once the picture is up (the resume fork and the error
            // card seed their own).
            .onDisappear { if resumePending == nil, status.state != "error", panel == nil, !finishing { focusLater(.surface) } }
    }

    /// The loader's `S{season} · E{02}{ · name}` line.
    private var kidsEpisodeLine: String? {
        guard let context, let s = context.season else { return nil }
        var line = "S\(s) · E" + String(format: "%02d", context.episode ?? 1)
        if let sub = subtitle, let r = sub.range(of: " · ") { line += " · " + String(sub[r.upperBound...]) }
        return line
    }

    private var kidsResumePrompt: some View {
        KidsResumePrompt(title: shownTitle, focus: $focus, onResume: { acknowledgeResume(true) }, onStartOver: { acknowledgeResume(false) })
            .onAppear { controller?.setPaused(true); if let c = controller { snap = c.snapshot() } }
    }

    /// resolution-label.ts realQualityLabel from the decoded picture ("w h codec…" in status).
    private var resolutionLabel: String? {
        let parts = status.videoParams.split(separator: " ")
        guard parts.count >= 2, let w = Int(parts[0]), let h = Int(parts[1]), w > 0 || h > 0 else { return nil }
        if h >= 2160 || w >= 3840 { return "4K" }
        if h >= 1440 || w >= 2560 { return "1440p" }
        if h >= 1080 || w >= 1920 { return "1080p" }
        if h >= 720 || w >= 1280 { return "720p" }
        if h >= 480 || w >= 854 { return "480p" }
        return "SD"
    }

    /// TransportKids toggleSub: off when one is on, else the first subtitle track.
    private func toggleKidSubtitles() {
        guard let c = controller else { return }
        let subs = c.tracks().filter { $0.type == "sub" }
        if subs.contains(where: { $0.selected }) { c.select(track: nil, type: "sub"); c.rememberSubtitle(nil) }
        else if let first = subs.first { c.select(track: first, type: "sub"); c.rememberSubtitle(first) }
        kidSubs = c.tracks().filter { $0.type == "sub" }
    }

    /// The PlayEpisode the switcher searches with.
    private func kidsEpisode(_ context: PlaybackContext) -> AnyJSON? {
        guard let s = context.season else { return nil }
        var ep: [String: AnyJSON] = ["season": .number(Double(s)), "episode": .number(Double(context.episode ?? 1))]
        if let v = context.videoId { ep["videoId"] = .string(v) }
        if let i = context.imdbId { ep["imdbId"] = .string(i) }
        return .object(ep)
    }

    /// stream-switcher onPick: the picked stream replaces this one in place at the same position
    /// (use-bridge-load hasExplicitStart), through the engine rule again; a torrent stays owned by
    /// the player while it plays (use-player-media).
    private func switchStream(to next: URL, headers nextHeaders: [String: String]) {
        let at = snap.position > 5 ? snap.position : 0
        let owned = switched?.url ?? url
        if next != owned {
            TorrentEngine.shared.playerOpened(url: next)
            TorrentEngine.shared.playerClosed(url: owned)
        }
        switched = SwitchedStream(url: next, headers: nextHeaders)
        status = MPVPlayerController.Status()
        loadingSince = Date()
        controller = nil
        subDelay = 0
        anime4kAppliedFor = -1
        startAt = nil
        let target = playURL
        Task {
            guard await settleEngine(for: target, hints: nil) else { return }
            startAt = at
            reloadToken += 1
        }
        closePanel()
    }

    // MARK: live channels (use-live-channel-overlay.ts)

    private var currentChannel: LiveModel.Channel? { tuned ?? liveChannel }
    private var playURL: URL { tuned.flatMap { URL(string: $0.url) } ?? switched?.url ?? url }
    private var playHeaders: [String: String] { tuned.map { $0.headers ?? [:] } ?? switched?.headers ?? headers }
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
        // A new channel is a new source: the engine rule runs again before it plays
        // (use-player-bridge.ts keys the bridge on the source).
        startAt = nil
        let target = playURL
        Task {
            guard await settleEngine(for: target, hints: nil) else { return }
            startAt = 0
            reloadToken += 1
        }
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
            if TorrentEngine.streamRef(playURL) != nil {
                // bp-connecting with a torrent: bp-p2p-status's stage, readiness and peers/speed.
                TorrentReadout(url: playURL)
            } else {
                Text(elapsed >= 22 ? T("Still looking. Some sources take a while to answer.") : T("The player is opening the stream. %lld s", elapsed)).font(BP.sans(15)).foregroundStyle(BP.inkMuted)
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
        // In a Watch Together room the lobby, or the host, may own the press (use-playback-controls).
        if together.interceptToggle(controller) { wake(); return }
        controller?.togglePause()
        if let c = controller { snap = c.snapshot() }
        wake()
    }

    private func wake() {
        // use-still-watching.ts: any press in the player starts the episode count over.
        StillWatching.reset()
        chrome = true
        scheduleHide()
    }

    // MARK: speed, sleep timer, Now Playing (speed-menu.tsx, use-sleep-timer.ts, lib/media-session.ts)

    /// bridge setRate for a new engine: the rate this player is at (defaultPlaybackSpeed to start).
    private func applyRate(_ c: any PlayerEngineControlling) {
        if abs(rate - 1) > 0.001 { c.setRate(rate) }
    }

    /// speed-menu.tsx onRate.
    private func setRate(_ value: Double) {
        rate = value
        controller?.setRate(value)
    }

    /// speed-menu.tsx trigger face: the sleep countdown while a timer is armed, else a changed rate.
    private var speedChipLabel: String {
        if let face = sleepTimer.faceLabel { return face }
        if !isLive, abs(rate - 1) > 0.01 { return PlayerSpeedPanel.rateLabel(rate) }
        return isLive ? "Sleep timer" : "Speed & sleep"
    }

    /// use-sleep-timer.ts fire handler (bridge.pause()); the chrome comes up so the pause shows.
    private func sleepFired() {
        // A Watch Together room pauses for everyone, as a press would (review 28).
        if let c = controller, !c.snapshot().paused, !together.interceptToggle(c) { c.setPaused(true) }
        if let c = controller { snap = c.snapshot() }
        chrome = true
        scheduleHide()
    }

    /// media-session.ts / use-keyboard-shortcuts.ts media keys: what the system's commands do here.
    private func beginNowPlaying() {
        var previous: (() -> Void)? = nil
        if !isLive, let go = onPreviousEpisode { previous = { finish(natural: false); go() } }
        var next: (() -> Void)? = nil
        if hasNextEpisodeNow { next = { playNext() } }
        let actions = VideoNowPlaying.Actions(
            isPlaying: { controller.map { !$0.snapshot().paused } ?? false },
            toggle: { togglePause() },
            seekStep: { delta in if isLive { controller?.seek(delta) } else { seekBy(delta) } },
            seekTo: { sec in if !isLive { seekBy(sec - snap.position) } },
            next: next,
            previous: previous)
        VideoNowPlaying.shared.begin(nowPlayingId, actions: actions, seekBack: prefs.seekBackStepSec, seekForward: prefs.seekForwardStepSec)
    }

    /// player.tsx updateMediaControls: title, "S1 E2 · name", art (backdrop, else poster; a
    /// channel's logo), duration, position and whether it is playing.
    private func nowPlayingTick() {
        let playing = status.state == "playing" && (isLive || snap.position > 0.3)
        let meta = context?.meta
        let art = isLive ? currentChannel?.logo : (meta?.background ?? meta?.poster)
        VideoNowPlaying.shared.update(nowPlayingId, playing: playing, title: shownTitle, subtitle: shownSubtitle, artURL: art,
                                      durationSec: snap.duration, positionSec: snap.position, rate: rate, isLive: isLive)
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(Self.hideAfter))
            if !Task.isCancelled, panel == nil, !roomOpen, !pipActive, !snap.paused { chrome = false; focus = .surface }
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

    // MARK: Picture in Picture (use-pip-mode.ts)

    /// pip://entered / pip://exited: the chrome stands aside while the picture is in the PiP window,
    /// and comes back with it.
    private func pipChanged(_ on: Bool) {
        // A start that failed or timed out reports "off" without ever being on: focus stays put (review 24).
        guard on != pipActive else { return }
        pipActive = on
        if on {
            hideTask?.cancel()
            chrome = false
            if panel != nil { panel = nil }
            leaveConfirm = false
            roomOpen = false
            focusLater(.chip("pip-exit"))
        } else {
            focus = .surface
            wake()
        }
    }

    /// The stage while the picture plays in the PiP window: where it went and the way back. The
    /// viewer can press the TV button and keep watching over other apps.
    private var pipPlacard: some View {
        ZStack {
            BP.void_.ignoresSafeArea()
            VStack(spacing: BP.px(14)) {
                Image(systemName: "pip").font(.system(size: BP.px(56), weight: .light)).foregroundStyle(BP.inkMuted)
                Text(T("Picture in Picture")).font(BP.display(30)).foregroundStyle(BP.ink)
                Text(verbatim: shownTitle).font(BP.sans(16, .semibold)).foregroundStyle(BP.inkMuted).lineLimit(1)
                HStack(spacing: BP.px(10)) {
                    chip("Exit Picture in Picture", "pip.exit", id: "pip-exit") { controller?.stopPictureInPicture() }
                    chip("Leave", "rectangle.portrait.and.arrow.right", id: "pip-leave") { finish(natural: false) }
                }
                .padding(.top, BP.px(8))
                .focusSection()
            }
            .padding(BP.gutter)
        }
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
            if let e = status.error { Text(T("Source said") + ": " + e).font(BP.sans(12)).foregroundStyle(BP.inkSubtle).lineLimit(1) }
            HStack(spacing: BP.px(10)) {
                if onChooseAnother != nil {
                    chip("Pick another source", "list.bullet") { let go = onChooseAnother; finish(natural: false); go?() }
                }
                chip("Try again", "arrow.clockwise") { status = MPVPlayerController.Status(); reloadToken += 1 }
                // header-warning.tsx onUseMpv: the forced native engine could not open it; mpv can try.
                if engine == .native { chip("Use mpv engine", "play.rectangle") { useMpvEngine() } }
                chip("Back", "chevron.left") { finish(natural: false) }
            }
            .focusSection()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(BP.gutter).padding(.bottom, BP.px(20))
        .background(LinearGradient(colors: [.clear, BP.void_.opacity(0.6), BP.void_.opacity(0.95)], startPoint: .top, endPoint: .bottom).ignoresSafeArea())
        .onAppear { hideTask?.cancel(); focusLater(.chip(onChooseAnother != nil ? "Pick another source" : "Try again")) }
    }

    // MARK: engines (use-player-bridge.ts, header-warning.tsx)

    /// use-player-bridge.ts:176-186: in Auto, an html5 decode/codec failure or silent audio moves
    /// the stream to mpv once (autoFallbackTried). A chosen native engine keeps playing and, for
    /// silent audio, shows player.tsx's NoAudioWarning instead.
    private func nativeUnsupported(_ reason: String) {
        guard engine == .native, !finishing else { return }
        if engineWant == "auto", !engineFallbackTried {
            engineFallbackTried = true
            switchToMpv()
        } else if reason == "noAudio" {
            noAudioWarning = true
            hideTask?.cancel()
            focusLater(.chip("Use mpv engine"))
        }
    }

    /// header-warning.tsx onUseMpv → update({ playerEngine: "mpv" }), then this stream moves over.
    private func useMpvEngine() {
        Task { try? await SettingsBridge.shared.patch(["playerEngine": .string("mpv")]) }
        engineWant = "mpv"
        switchToMpv()
    }

    /// use-player-bridge.ts chosenEngine / pickBridge for the source about to play.
    /// `false` when another channel was tuned while the rule ran; that tune settles its own.
    @discardableResult
    private func settleEngine(for target: URL, hints: PlayerStreamHints?) async -> Bool {
        let choice = await PlayerEngineChoice.choose(url: target, isLive: isLive, hints: hints)
        guard playURL == target else { return false }
        engine = choice.engine
        engineWant = choice.want
        engineFallbackTried = false
        noAudioWarning = false
        return true
    }

    /// Hands the stream to mpv where the native player left it (or where it was to start).
    private func switchToMpv() {
        let at = snap.position > 5 ? snap.position : (startAt ?? 0)
        noAudioWarning = false
        controller = nil
        status = MPVPlayerController.Status()
        loadingSince = Date()
        anime4kAppliedFor = -1
        engine = .mpv
        startAt = at
        reloadToken += 1
        focus = .surface
        wake()
    }

    /// header-warning.tsx NoAudioWarning, over the stage above the transport.
    private var noAudioCard: some View {
        VStack {
            Spacer()
            VStack(spacing: BP.px(12)) {
                Text("No audio: this stream's audio format (likely Dolby or DTS) is not supported by the AVPlayer engine.")
                    .font(BP.sans(15, .medium)).foregroundStyle(BP.ink).multilineTextAlignment(.center)
                HStack(spacing: BP.px(10)) {
                    chip("Use mpv engine", "play.rectangle") { useMpvEngine() }
                    chip("Dismiss", "xmark") { noAudioWarning = false; focus = .surface }
                }
                .focusSection()
            }
            .padding(.horizontal, BP.px(24)).padding(.vertical, BP.px(18))
            .frame(maxWidth: BP.px(560))
            .background(RoundedRectangle(cornerRadius: BP.rLG, style: .continuous).fill(BP.void_.opacity(0.85)))
            .overlay(RoundedRectangle(cornerRadius: BP.rLG, style: .continuous).stroke(BP.edge2, lineWidth: 1))
            .padding(.bottom, chrome ? BP.px(300) : BP.px(120))
        }
        .frame(maxWidth: .infinity)
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
        together.closing()
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
            SleepTimer.shared.playerClosed(advancing: advance ?? natural)
            // use-still-watching counts auto-advanced episodes in a row: a close that doesn't advance ends the run (review 28).
            if !(advance ?? natural) { StillWatching.reset() }
            onClose(advance ?? natural)
            // The watched check on the tiles reads the flags this session just wrote.
            await CardMarksStore.shared.remark()
        }
    }
}
