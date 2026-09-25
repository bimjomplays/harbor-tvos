import SwiftUI
import Combine

/// What a kid profile gets instead of the Big Picture shell. Upstream (App.tsx) pins a kid profile
/// to the "kids" view — only kids, meta (the kids detail page), picker, grid and collection are
/// allowed, anything else snaps back to kids — and chrome/sidebar.tsx shows it exactly two nav
/// items, "Watch" (the Kids page) and "Play" (which opens the Play Zone), plus the profile chip.
/// No Home, Search, Live, Library or Settings. The curfew lock and the parent PIN stay with
/// RootView / ProfilesStore and apply here unchanged.
struct KidsShellView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var settings: SettingsBridge
    @Namespace private var focusNS
    @Environment(\.resetFocus) private var resetFocus
    @EnvironmentObject private var profiles: ProfilesStore
    @State private var playOpen = false
    /// account-menu requestSwitch: leaving a kid profile that has a parent PIN asks for it first.
    @State private var parentPin = false
    /// (pass 3) The profile chip, so a cancelled parent PIN hands the ring back to it.
    @FocusState private var chipFocused: Bool
    /// Deep links waiting to be shown (AppModel.showWaitingLink): titles only here.
    @ObservedObject private var links = DeepLinkQueue.shared

    var body: some View {
        ZStack(alignment: .top) {
            KidsTheme.canvas.ignoresSafeArea()
            // App.tsx mounts music-dock.tsx over every view, the kids surface included (visible
            // whenever a track is loaded, top not player/picker): music started before the switch to
            // a kid keeps its dock and Now Playing here. The shell ignores the safe area, so the dock
            // keeps the TV's bottom inset itself.
            KidsView(openPlay: openPlay)
                .musicDock(bottomPadding: BP.px(60))
                .disabled(pinUp)
            KidsTopBar(onPlay: openPlay, onSwitch: requestSwitch, chipFocus: $chipFocused)
                .disabled(pinUp)
            if parentPin, let p = profiles.active, let hash = p.kid?.parentPinHash {
                ZStack {
                    BP.void_.opacity(0.94).ignoresSafeArea()
                    // The parent PIN clears the kid lock on the profile being left; a target with its
                    // own PIN still unlocks itself on Who's watching.
                    PinPadView(profile: p, finish: { ok in
                        parentPin = false
                        if ok { app.switchProfile() } else { returnRingToChip() }
                    }, hashOverride: hash, title: "Parent PIN")
                }
                .transition(.opacity)
                .zIndex(5)
            }
        }
        .animation(BP.easeFast, value: pinUp)
        // bp-settings "Edge margin" applies here too: it is the TV's crop, not a room setting.
        .padding(.horizontal, 1920 * CGFloat(settings.slice.overscanFraction))
        .padding(.vertical, 1080 * CGFloat(settings.slice.overscanFraction))
        .ignoresSafeArea()
        .focusScope(focusNS)
        .environment(\.shellFocusNamespace, focusNS)
        .onAppear {
            ShellFocus.shared.request = { resetFocus(in: focusNS) }
            // A kid has one page; the shoulder buttons have no tabs to cycle.
            GamepadMonitor.shared.onTab = nil
        }
        .fullScreenCover(isPresented: $playOpen) { KidsPlayZoneView() }
        // lib/deep-link.ts: a title handed to the TV opens as the kids detail page (App.tsx meta → KidsDetailView).
        // (review 16) The page reports that it came on screen (AppModel.requeueDroppedLink).
        .fullScreenCover(item: $app.deepLinkMeta) { m in
            KidsDetailView(meta: m).onAppear { app.deepLinkCoverAppeared() }
        }
        // (deep links over covers) A title link waits until nothing is presented over the kids
        // surface (a kids page, the Play Zone, the player) and the parent PIN pad is down; a shared
        // list or an addon install keeps waiting for an adult shell.
        .task(id: links.waiting) { await showWaitingLinks() }
    }

    /// (bug pass) The keypad is actually on screen. A profile sync that clears the parent PIN while
    /// it is up removes the keypad; disabling on `parentPin` alone then left nothing focusable.
    private var pinUp: Bool { parentPin && profiles.active?.kid?.parentPinHash != nil }

    private func showWaitingLinks() async {
        while !Task.isCancelled, app.hasWaitingLink(kidShell: true) {
            let clear = !pinUp && !PiPBrowse.shared.isUp && !PlaybackState.shared.active && HarborOverlayWindow.noCoverPresented
            if app.showWaitingLink(kidShell: true, clear: clear) { return }
            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    /// (pass 3) Back or ‹ on the parent PIN: the ring goes back to the profile chip that opened it.
    /// The rows and the bar were disabled under the pad, so tvOS put it on the first hero card at
    /// the top of the page instead. Set again once the pad's fade has ended (Who's watching's PIN
    /// tile does the same).
    private func returnRingToChip() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { if !parentPin { chipFocused = true } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { if !parentPin { chipFocused = true } }
    }

    /// use-account-menu.ts requestSwitch: a kid profile with a parent PIN needs it to switch away.
    private func requestSwitch() {
        if profiles.active?.kid?.parentPinHash != nil { parentPin = true } else { app.switchProfile() }
    }

    /// sidebar.tsx "Play": setView("kids") + harbor:kids-play → the Play Zone opens.
    private func openPlay() {
        ActivityMonitor.shared.touch()
        BPSound.shared.open()
        playOpen = true
    }
}

/// chrome/sidebar.tsx under a kid profile, laid out as a top bar: the "Harb(wheel)r" wordmark,
/// the Watch and Play items, then the profile chip and the clock on the kids chrome colour.
struct KidsTopBar: View {
    let onPlay: () -> Void
    let onSwitch: () -> Void
    /// (pass 3) The profile chip's focus (KidsShellView returns the ring to it after the parent PIN).
    let chipFocus: FocusState<Bool>.Binding
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var profiles: ProfilesStore

    var body: some View {
        HStack(spacing: BP.px(12)) {
            HStack(spacing: BP.px(8)) {
                // `[data-kids="on"] .harbor-mark-sail`: the sail in kids teal on the light chrome.
                Image("HarborMark").resizable().renderingMode(.template).scaledToFit()
                    .foregroundStyle(KidsTheme.sail)
                    .frame(width: BP.px(30), height: BP.px(30))
                // sidebar.tsx kid wordmark: "Harb" + the ship's wheel as the o + "r".
                HStack(spacing: -BP.px(3)) {
                    Text("Harb")
                    KidsArt("/kids/wheel.png").frame(width: BP.px(24), height: BP.px(24)).offset(y: BP.px(2))
                    Text("r")
                }
                .font(KidsTheme.font(28, .bold)).foregroundStyle(KidsTheme.ink)
            }
            .padding(.trailing, BP.px(16))
            // "Watch" is the kids nav item's label (nav.kids), a popcorn icon.
            Button {} label: { label("Watch", icon: "popcorn.fill") }
                .buttonStyle(KidsNavStyle(active: true))
                .accessibilityIdentifier("tab-kids")
                .bpSelected(true)
            Button(action: onPlay) { label("Play", icon: "play.circle.fill") }
                .buttonStyle(KidsNavStyle(active: false))
                .accessibilityIdentifier("tab-kids-play")
            Spacer(minLength: BP.px(8))
            if let p = profiles.active {
                Button(action: onSwitch) {
                    HStack(spacing: BP.px(8)) {
                        ProfileFace(profile: p, size: BP.px(30))
                        Text(p.name).font(KidsTheme.font(15, .bold)).foregroundStyle(KidsTheme.ink).lineLimit(1)
                    }
                    .padding(.horizontal, BP.px(10))
                    .frame(height: BP.tabItem)
                }
                .buttonStyle(KidsNavStyle(active: false))
                .focused(chipFocus)
                .accessibilityIdentifier("profile-chip")
            }
            KidsClock().padding(.leading, BP.px(6))
        }
        .padding(.horizontal, BP.gutter)
        .frame(height: BP.barHeight)
        .focusSection()
        .background(
            LinearGradient(colors: [KidsTheme.bar.opacity(0.95), KidsTheme.bar.opacity(0.6), .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: BP.barHeight * 1.6), alignment: .top
        )
    }

    private func label(_ text: String, icon: String) -> some View {
        HStack(spacing: BP.px(8)) {
            Image(systemName: icon).font(.system(size: BP.px(18), weight: .bold)).accessibilityHidden(true)
            Text(T(text)).font(KidsTheme.font(16, .bold))
        }
        .padding(.horizontal, BP.px(14))
        .frame(height: BP.tabItem)
    }
}

/// The big kids nav item: teal when it is the page you are on, a white wash and ring on focus.
struct KidsNavStyle: ButtonStyle {
    var active: Bool
    func makeBody(configuration: Configuration) -> some View {
        BPFocusReader { focused in
            configuration.label
                .foregroundStyle(active ? .white : KidsTheme.deep)
                .background(Capsule().fill(active ? KidsTheme.teal : (focused ? .white : .white.opacity(0.0))))
                .overlay { if focused { Capsule().stroke(KidsTheme.sunny, lineWidth: 4) } }
                .scaleEffect(focused ? 1.06 : 1)
                .animation(BP.easeFast, value: focused)
        }
    }
}

/// ClockView in the kids ink (the Big Picture clock is drawn for a dark bar).
struct KidsClock: View {
    @State private var now = Date()
    private let timer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()
    var body: some View {
        Text(now, format: .dateTime.hour().minute())
            .font(KidsTheme.font(15, .semibold)).foregroundStyle(KidsTheme.inkMuted)
            .onReceive(timer) { now = $0 }
    }
}
