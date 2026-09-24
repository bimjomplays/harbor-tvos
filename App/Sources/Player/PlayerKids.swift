import SwiftUI

// The player a kid profile sees (upstream gates each piece on useActiveKid()):
// components/player/transport-kids.tsx (TransportKids), stream-switcher/kids-switcher.tsx
// (KidsStreamSwitcher) and resume-prompt.tsx's kid branch. PlayerScreen swaps these in for its
// adult chrome, stream picker and resume fork; the behaviour behind them stays PlayerScreen's.

/// `text-[#0c4a6e]`: the kid prompt / switcher ink and `from-[#3aa6c4] via-[#1c789f] to-[#0a3d5c]`.
enum KidsPlayerColors {
    static let ink = Color(hex: 0x0c4a6e)
    static let top = Color(hex: 0x3aa6c4)
    static let mid = Color(hex: 0x1c789f)
    static let bottom = Color(hex: 0x0a3d5c)
}

/// TransportKids: Back + title on top; a chunky seek bar, mute, ±10 s around a big Play/Pause,
/// the subtitle toggle and "Switch" below. The volume slider and Fullscreen button have no TV
/// counterpart (the remote owns volume; the player is always full screen).
struct KidsPlayerTransport: View {
    let title: String
    let resolution: String?
    let isLive: Bool
    let position: Double
    let duration: Double
    /// The end of the buffered range (seconds), as the adult seek bar reads it.
    let buffered: Double
    let paused: Bool
    let muted: Bool
    let hasSubtitles: Bool
    let subtitlesOn: Bool
    let canPickAnother: Bool
    var focus: FocusState<PlayerScreen.FocusTarget?>.Binding
    let onBack: () -> Void
    let onPlayPause: () -> Void
    let onSeekStep: (Double) -> Void
    let onMute: () -> Void
    let onSubtitles: () -> Void
    let onPickAnother: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Spacer(minLength: 0)
            bottomBar
        }
        .ignoresSafeArea()
    }

    private var topBar: some View {
        HStack(spacing: BP.px(12)) {
            Button(action: onBack) {
                HStack(spacing: BP.px(10)) {
                    Image(systemName: "arrow.left").font(.system(size: BP.px(22), weight: .heavy))
                    Text("Back").font(KidsTheme.font(18, .heavy))
                }
            }
            .buttonStyle(KidsPillStyle(fill: .white.opacity(0.9), focusedFill: .white, ink: KidsTheme.deep, height: BP.px(56)))
            .focused(focus, equals: .chip("kids-back"))
            Spacer(minLength: BP.px(12))
            HStack(spacing: BP.px(12)) {
                Text(title).font(KidsTheme.font(22, .bold)).foregroundStyle(.white).lineLimit(1)
                if let resolution, !resolution.isEmpty {
                    Text(resolution.uppercased()).font(KidsTheme.font(13, .heavy)).foregroundStyle(.white)
                        .padding(.horizontal, BP.px(12)).padding(.vertical, BP.px(4))
                        .background(Capsule().fill(.white.opacity(0.2)))
                }
            }
            .shadow(color: .black.opacity(0.6), radius: 8, y: 2)
            Spacer(minLength: BP.px(12))
            // The FullscreenClock slot (settings.fullscreenClockEnabled is off by default).
            Color.clear.frame(width: BP.px(112), height: 1)
        }
        .padding(.horizontal, BP.gutter)
        .padding(.top, BP.px(28)).padding(.bottom, BP.px(48))
        .background(LinearGradient(colors: [.black.opacity(0.65), .black.opacity(0.2), .clear], startPoint: .top, endPoint: .bottom))
        .focusSection()
    }

    private var bottomBar: some View {
        VStack(spacing: BP.px(20)) {
            if !isLive {
                HStack(spacing: BP.px(20)) {
                    Text(Self.fmt(position)).frame(width: BP.px(76), alignment: .leading)
                    KidsSeekBar(position: position, duration: duration, buffered: buffered)
                    Text(Self.fmt(duration)).frame(width: BP.px(76), alignment: .trailing)
                }
                .font(.system(size: BP.px(17), weight: .bold, design: .monospaced))
                .foregroundStyle(.white)
                .monospacedDigit()
            }
            HStack(spacing: BP.px(16)) {
                // KidsVolume: the mute half (VolumeX / Volume2).
                HStack {
                    Button(action: onMute) {
                        Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill").font(.system(size: BP.px(26), weight: .semibold))
                    }
                    .buttonStyle(KidsRoundStyle(size: BP.px(64)))
                    .focused(focus, equals: .chip("mute"))
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity)
                HStack(spacing: BP.px(24)) {
                    if !isLive {
                        seekButton(-1)
                    }
                    Button(action: onPlayPause) {
                        Image(systemName: paused ? "play.fill" : "pause.fill")
                            .font(.system(size: BP.px(44), weight: .black))
                            .offset(x: paused ? BP.px(3) : 0)
                    }
                    .buttonStyle(KidsRoundStyle(size: BP.px(96), fill: .white, focusedFill: .white, ink: KidsTheme.teal))
                    .focused(focus, equals: .chip("playpause"))
                    if !isLive {
                        seekButton(1)
                    }
                }
                HStack(spacing: BP.px(12)) {
                    Spacer(minLength: 0)
                    if hasSubtitles {
                        Button(action: onSubtitles) {
                            Image(systemName: subtitlesOn ? "captions.bubble.fill" : "captions.bubble").font(.system(size: BP.px(26), weight: .semibold))
                        }
                        .buttonStyle(KidsRoundStyle(size: BP.px(64), fill: subtitlesOn ? .white : .white.opacity(0.15),
                                                    focusedFill: subtitlesOn ? .white : .white.opacity(0.25), ink: subtitlesOn ? KidsTheme.teal : .white))
                        .focused(focus, equals: .chip("kids-subtitles"))
                    }
                    if canPickAnother {
                        Button(action: onPickAnother) {
                            HStack(spacing: BP.px(8)) {
                                Image(systemName: "shuffle").font(.system(size: BP.px(22), weight: .bold))
                                Text("Switch").font(KidsTheme.font(16, .heavy))
                            }
                        }
                        .buttonStyle(KidsPillStyle(fill: .white.opacity(0.15), focusedFill: .white.opacity(0.25), ink: .white, height: BP.px(64)))
                        .focused(focus, equals: .chip("kids-switch"))
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .focusSection()
        }
        .padding(.horizontal, BP.gutter)
        .padding(.top, BP.px(56)).padding(.bottom, BP.px(36))
        .background(LinearGradient(colors: [.clear, .black.opacity(0.35), .black.opacity(0.8)], startPoint: .top, endPoint: .bottom))
    }

    /// SeekBtn: RotateCcw / RotateCw with "10" inside ("Back 10s" / "Forward 10s").
    private func seekButton(_ dir: Double) -> some View {
        Button { onSeekStep(10 * dir) } label: {
            Image(systemName: dir < 0 ? "gobackward.10" : "goforward.10").font(.system(size: BP.px(34), weight: .semibold))
        }
        .buttonStyle(KidsRoundStyle(size: BP.px(64)))
        .focused(focus, equals: .chip(dir < 0 ? "rewind" : "forward"))
        .accessibilityLabel(Text(dir < 0 ? "Back 10s" : "Forward 10s"))
    }

    /// transport-utils fmtTime.
    static func fmt(_ s: Double) -> String {
        guard s.isFinite, s > 0 else { return "0:00" }
        let t = Int(s)
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, (t / 60) % 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
    }
}

/// KidsSeekBar: a thick white track, buffered and played fills, a big knob with a teal halo.
/// On the TV it only shows; Left / Right on the stage seek (PlayerScreen.nudgeSeek).
struct KidsSeekBar: View {
    let position: Double
    let duration: Double
    let buffered: Double

    var body: some View {
        let frac = duration > 0 ? min(1, max(0, position / duration)) : 0
        let bufferedEnd = duration > 0 ? min(1, max(0, max(buffered, position) / duration)) : 0
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.25))
                    .overlay(Capsule().stroke(.white.opacity(0.2), lineWidth: 1))
                Capsule().fill(.white.opacity(0.45)).frame(width: g.size.width * bufferedEnd)
                Capsule().fill(.white).frame(width: g.size.width * frac)
                Circle().fill(.white)
                    .frame(width: BP.px(32), height: BP.px(32))
                    .overlay(Circle().stroke(KidsTheme.teal.opacity(0.3), lineWidth: BP.px(4)))
                    .shadow(color: .black.opacity(0.6), radius: 6, y: 2)
                    .offset(x: g.size.width * frac - BP.px(16))
            }
            .frame(height: BP.px(20))
            .frame(maxHeight: .infinity)
        }
        .frame(height: BP.px(32))
    }
}

/// RoundBtn / SeekBtn / the Play button: a filled circle, the kids sunny ring on focus.
struct KidsRoundStyle: ButtonStyle {
    var size: CGFloat
    var fill: Color = .white.opacity(0.15)
    var focusedFill: Color = .white.opacity(0.25)
    var ink: Color = .white
    func makeBody(configuration: Configuration) -> some View {
        BPFocusReader { focused in
            configuration.label
                .foregroundStyle(ink)
                .frame(width: size, height: size)
                .background(Circle().fill(focused ? focusedFill : fill))
                .overlay(Circle().stroke(focused ? KidsTheme.sunny : .clear, lineWidth: 5))
                .shadow(color: .black.opacity(focused ? 0.55 : 0.3), radius: focused ? 18 : 10, y: focused ? 10 : 6)
                .scaleEffect(focused ? (configuration.isPressed ? 0.97 : 1.08) : 1)
                .animation(BP.easeFast, value: focused)
        }
    }
}

/// The curfew / kids-player backdrop: the sky-to-sea gradient, rising bubbles (index.css
/// .curfew-bubble: 0 → -100vh, scale .8 → 1.2, opacity 0 → .6 at 20 % → 0) and two octopus doodles.
struct KidsSeaBackdrop: View {
    /// Left positions in percent (resume prompt KID_BUBBLES, switcher BUBBLES).
    let bubbles: [Double]
    /// `12 + (i % 3) * step` px.
    let bubbleStep: Double
    var translucent = false
    var octoRed: (bottom: CGFloat, left: CGFloat, height: CGFloat, opacity: Double) = (0.12, 0.09, 96, 0.85)
    var octoPurple: (bottom: CGFloat, right: CGFloat, height: CGFloat, opacity: Double) = (0.10, 0.10, 80, 0.75)

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .topLeading) {
                LinearGradient(colors: [KidsPlayerColors.top.opacity(translucent ? 0.95 : 1), KidsPlayerColors.mid.opacity(translucent ? 0.96 : 1),
                                        KidsPlayerColors.bottom.opacity(translucent ? 0.98 : 1)], startPoint: .top, endPoint: .bottom)
                TimelineView(.animation) { tl in
                    let now = tl.date.timeIntervalSinceReferenceDate
                    ZStack(alignment: .topLeading) {
                        ForEach(Array(bubbles.enumerated()), id: \.offset) { i, left in
                            bubble(i, left: left, now: now, in: g.size)
                        }
                        KidsArt(doodle: "liloctored")
                            .frame(height: BP.px(octoRed.height))
                            .opacity(octoRed.opacity)
                            .position(redCentre(now: now, in: g.size))
                    }
                }
                KidsArt(doodle: "lilpurpocto")
                    .frame(height: BP.px(octoPurple.height))
                    .opacity(octoPurple.opacity)
                    .position(x: g.size.width * (1 - octoPurple.right) - BP.px(octoPurple.height) * 0.5,
                              y: g.size.height * (1 - octoPurple.bottom) - BP.px(octoPurple.height) / 2)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    /// One `.curfew-bubble`: duration `6 + i % 4` s, delay `-(1 + (i * 1.7) % 6)` s.
    private func bubble(_ i: Int, left: Double, now: Double, in box: CGSize) -> some View {
        let size = BP.px(CGFloat(12 + Double(i % 3) * bubbleStep))
        let dur = 6 + Double(i % 4)
        let delay = 1 + (Double(i) * 1.7).truncatingRemainder(dividingBy: 6)
        let p = (now + delay).truncatingRemainder(dividingBy: dur) / dur
        let opacity: Double = p < 0.2 ? p / 0.2 * 0.6 : 0.6 * (1 - (p - 0.2) / 0.8)
        let x: CGFloat = box.width * CGFloat(left / 100) + size / 2
        let y: CGFloat = box.height - size / 2 - box.height * CGFloat(p)
        return Circle().fill(Color.white.opacity(0.25))
            .frame(width: size, height: size)
            .scaleEffect(CGFloat(0.8 + 0.4 * p))
            .opacity(opacity)
            .position(x: x, y: y)
    }

    /// The red octopus sits `bottom`/`left` in from the corner and bobs (.curfew-bob: 4.5 s, up 9 px).
    private func redCentre(now: Double, in box: CGSize) -> CGPoint {
        let bob = CGFloat((1 - cos(now / 4.5 * 2 * Double.pi)) / 2) * BP.px(9)
        let h = BP.px(octoRed.height)
        return CGPoint(x: box.width * octoRed.left + h * 0.5, y: box.height * (1 - octoRed.bottom) - h / 2 - bob)
    }
}

/// resume-prompt.tsx, kid branch: the title, "Where do you want to start?", Keep Watching /
/// Start Over over the sea backdrop. The focus ids are PlayerScreen's adult prompt's, so its
/// ring seeding and Back handling apply unchanged.
struct KidsResumePrompt: View {
    let title: String
    var focus: FocusState<PlayerScreen.FocusTarget?>.Binding
    let onResume: () -> Void
    let onStartOver: () -> Void

    var body: some View {
        ZStack {
            KidsSeaBackdrop(bubbles: [10, 24, 40, 55, 70, 84, 93], bubbleStep: 5)
            VStack(spacing: 0) {
                Text(title)
                    .font(KidsTheme.font(64, .bold)).foregroundStyle(.white)
                    .multilineTextAlignment(.center).lineLimit(2)
                    .frame(maxWidth: BP.px(896))
                    .shadow(color: .black.opacity(0.4), radius: 12, y: 3)
                Text("Where do you want to start?")
                    .font(KidsTheme.font(22, .bold)).foregroundStyle(.white.opacity(0.9))
                    .padding(.top, BP.px(20))
                HStack(spacing: BP.px(20)) {
                    Button(action: onResume) {
                        HStack(spacing: BP.px(12)) {
                            Image(systemName: "play.fill").font(.system(size: BP.px(28), weight: .black))
                            Text("Keep Watching").font(KidsTheme.font(24, .heavy))
                        }
                        .frame(minWidth: BP.px(232))
                    }
                    .buttonStyle(KidsPillStyle(fill: .white, focusedFill: .white, ink: KidsPlayerColors.ink, height: BP.px(80)))
                    .focused(focus, equals: .chip("Pick up where you left off"))
                    Button(action: onStartOver) {
                        HStack(spacing: BP.px(12)) {
                            Image(systemName: "arrow.counterclockwise").font(.system(size: BP.px(26), weight: .heavy))
                            Text("Start Over").font(KidsTheme.font(24, .heavy))
                        }
                        .frame(minWidth: BP.px(172))
                    }
                    .buttonStyle(KidsPillStyle(fill: .white.opacity(0.15), focusedFill: .white.opacity(0.25), ink: .white, height: BP.px(80)))
                    .focused(focus, equals: .chip("Start over"))
                }
                .padding(.top, BP.px(40))
                .focusSection()
            }
            .padding(.horizontal, BP.gutter)
        }
        .ignoresSafeArea()
    }
}

/// kids-switcher.tsx KidsStreamSwitcher: "Pick a video", the first six sources as big numbered
/// rows ("Playing now" / "Video n" with its quality), resolved and handed back to the player.
/// It runs the title's stream search itself (upstream's switcher reads the player's list).
struct KidsStreamSwitcher: View {
    let meta: Meta
    let episode: AnyJSON?
    let currentURL: URL
    let onPicked: (URL, [String: String]) -> Void
    let onClose: () -> Void

    @StateObject private var model = StreamsModel()
    @State private var resolving: String?
    @State private var failure: String?
    @FocusState private var focus: String?

    var body: some View {
        ZStack {
            KidsSeaBackdrop(bubbles: [10, 26, 44, 62, 78, 90], bubbleStep: 6, translucent: true,
                            octoRed: (0.08, 0.07, 80, 0.8), octoPurple: (0.07, 0.08, 64, 0.7))
            VStack(spacing: BP.px(24)) {
                HStack {
                    Spacer()
                    Button(action: onClose) { Image(systemName: "xmark").font(.system(size: BP.px(22), weight: .heavy)) }
                        .buttonStyle(KidsRoundStyle(size: BP.px(48)))
                        .focused($focus, equals: "close")
                }
                Text("Pick a video")
                    .font(KidsTheme.font(46, .heavy)).foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.35), radius: 12, y: 3)
                Text("Tap one until your show plays nice and clear!")
                    .font(KidsTheme.font(19, .bold)).foregroundStyle(.white.opacity(0.9))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: BP.px(448))
                if options.isEmpty {
                    if model.phase == .searching || model.phase == .idle {
                        ProgressView().tint(.white).padding(.top, BP.px(16))
                    } else {
                        Text("No videos right now. Ask a grown-up!")
                            .font(KidsTheme.font(17, .bold)).foregroundStyle(.white.opacity(0.85))
                            .padding(.top, BP.px(16))
                    }
                } else {
                    VStack(spacing: BP.px(14)) {
                        ForEach(Array(options.enumerated()), id: \.element.id) { i, s in row(s, i) }
                    }
                    .focusSection()
                }
                if let failure {
                    Text(failure).font(KidsTheme.font(14, .bold)).foregroundStyle(.white.opacity(0.85)).lineLimit(2)
                }
            }
            .frame(maxWidth: BP.px(620))
            .padding(.horizontal, BP.gutter)
        }
        .ignoresSafeArea()
        .task {
            await model.search(meta: meta, episode: episode)
        }
        .onChange(of: options.count) { old, new in
            if old == 0, new > 0 {
                let seed = options.first { isCurrent($0) } ?? options[0]
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { focus = "row-\(seed.id)" }
            }
        }
        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { if focus == nil { focus = "close" } } }
        .onDisappear { model.cancel() }
    }

    /// `list.slice(0, 6)`.
    private var options: [ScoredStream] { Array(model.streams.prefix(6)) }

    /// switcher-row.tsx isCurrentStream: the same torrent (and file), else the same URL.
    private func isCurrent(_ s: ScoredStream) -> Bool {
        if let ref = TorrentEngine.streamRef(currentURL), let hash = s.infoHash, hash.lowercased() == ref.infoHash { return true }
        return s.url != nil && s.url == currentURL.absoluteString
    }

    /// quality.ts qualityKey → QUALITY_LABEL.
    private func quality(_ s: ScoredStream) -> String {
        switch s.source {
        case "CAM": return "CAM"
        case "TS", "HDTS": return "Telesync"
        case "TC": return "Telecine"
        default: break
        }
        switch s.resolution {
        case "4K": return "4K UHD"
        case "1080p", "720p", "480p": return s.resolution ?? "SD"
        default: return "SD"
        }
    }

    private func row(_ s: ScoredStream, _ i: Int) -> some View {
        let current = isCurrent(s)
        let busy = resolving == s.id
        return Button { Task { await pick(s) } } label: {
            HStack(spacing: BP.px(16)) {
                Text("\(i + 1)").font(KidsTheme.font(22, .heavy))
                    .foregroundStyle(.white)
                    .frame(width: BP.px(48), height: BP.px(48))
                    .background(Circle().fill(current ? KidsTheme.teal : .white.opacity(0.25)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(current ? T("Playing now") : T("Video %lld", i + 1)).font(KidsTheme.font(20, .heavy))
                    Text(quality(s)).font(KidsTheme.font(14, .bold)).opacity(0.7)
                }
                .foregroundStyle(current ? KidsPlayerColors.ink : .white)
                Spacer(minLength: 0)
                Group {
                    if busy { ProgressView().tint(.white) }
                    else { Image(systemName: "play.fill").font(.system(size: BP.px(22), weight: .black)) }
                }
                .foregroundStyle(.white)
                .frame(width: BP.px(48), height: BP.px(48))
                .background(Circle().fill(current ? KidsTheme.teal : .white.opacity(0.2)))
            }
            .padding(.horizontal, BP.px(20))
            .frame(height: BP.px(76))
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(KidsSwitcherRowStyle(current: current))
        .disabled(busy)
        .focused($focus, equals: "row-\(s.id)")
    }

    /// onPick: resolve the stream (debrid link, or the TV's torrent engine) and play it in place.
    private func pick(_ s: ScoredStream) async {
        guard resolving == nil else { return }
        if isCurrent(s) { onClose(); return }
        resolving = s.id
        failure = nil
        let r = await model.resolve(s)
        resolving = nil
        guard r.ok, let link = r.data, let url = URL(string: link.url) else {
            failure = r.message ?? r.code
            return
        }
        await model.remember(s, meta: meta, episode: episode, url: link.url)
        onPicked(url, link.headers ?? [:])
    }
}

/// A switcher row: white with a ring when it is the one playing, glassy otherwise; sunny on focus.
struct KidsSwitcherRowStyle: ButtonStyle {
    let current: Bool
    func makeBody(configuration: Configuration) -> some View {
        BPFocusReader { focused in
            let shape = RoundedRectangle(cornerRadius: BP.px(24), style: .continuous)
            configuration.label
                .background(shape.fill(current ? Color.white : Color.white.opacity(focused ? 0.25 : 0.15)))
                .overlay(shape.stroke(focused ? KidsTheme.sunny : .white.opacity(current ? 0.6 : 0.25), lineWidth: focused ? 5 : (current ? 4 : 2)))
                .scaleEffect(focused ? (configuration.isPressed ? 0.98 : 1.02) : 1)
                .animation(BP.easeFast, value: focused)
        }
    }
}
