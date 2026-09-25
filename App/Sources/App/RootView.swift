import SwiftUI

struct RootView: View {
    @ObservedObject private var saver = ScreensaverModel.shared
    @ObservedObject private var curfew = CurfewState.shared
    @StateObject private var app = AppModel()
    @ObservedObject private var theme = ThemeStore.shared
    @StateObject private var intro = IntroModel(enabled: !Fixtures.active)
    @ObservedObject private var pool = AmbientPool.shared
    /// The active profile decides which shell a `.shell` stage shows (kid → Kids).
    @ObservedObject private var profiles = ProfilesStore.shared
    /// settings.uiLanguage drives every string on screen (App/L10n.swift), not the system language.
    @ObservedObject private var settings = SettingsBridge.shared
    /// A film or channel is up: a theme or language that profile sync pulls in meanwhile waits for
    /// it to end, because either one rebuilds the whole tree (and the player with it).
    @ObservedObject private var playback = PlaybackState.shared
    /// Picture in Picture's browse layer (Player/PiPBrowse.swift): built here, like the overlay.
    @ObservedObject private var browse = PiPBrowse.shared
    /// The language the tree was built in, kept while playback runs (nil = follow settings).
    @State private var heldLanguage: String?
    private var language: String { heldLanguage ?? L10n.normalize(settings.slice.uiLanguage) }

    var body: some View {
        ZStack {
            BPAmbientBackground(mosaic: rootMosaic, root: true)
            Group {
                switch app.stage {
                case .boot: BootSplashView()
                case .onboarding: OnboardingView()
                case .whoIsWatching: WhoIsWatchingView()
                // App.tsx: a kid profile is pinned to the Kids surface (see KidsShellView).
                case .shell: if profiles.active?.kid != nil { KidsShellView() } else { ShellView() }
                }
            }
            // bp-shell passes navigationEnabled && !introUp: nothing under the wall takes a press.
            .disabled(intro.phase == .showing)
            // The screensaver and the curfew lock (curfew-guard: topmost on every entry, or it is the
            // appearance of child safety without any of it) are hosted in a window above this one
            // (ShellOverlay), so no fullScreenCover can hide them; see `overlayUp`.
            // bp-controller-toast.tsx: mounted beside the screensaver, over every Big Picture surface.
            ControllerToastView(monitor: GamepadMonitor.shared).zIndex(15)
            // bp-shell.tsx: {introUp && <BpIntro …/>}, the front door after the boot splash.
            if app.stage != .boot, intro.phase != .done { IntroView(model: intro).zIndex(30) }
        }
        // Stage 9: a theme change re-renders every view against the new BP tokens; a language
        // change does the same, so T() copy and engine-built rows are read again in it.
        .id("\(theme.revision)|\(language)")
        // lib/i18n/store.ts applyDocument: lang and dir follow the chosen language. SwiftUI resolves
        // every Text/Button/Label key against this locale in App/Locales/<lang>.lproj.
        .environment(\.locale, Locale(identifier: language))
        .environment(\.layoutDirection, L10n.rtlLanguages.contains(language) ? .rightToLeft : .leftToRight)
        .onAppear { GamepadMonitor.shared.start() }
        .onChange(of: app.stage) { old, st in
            // bp-shell.tsx mount (the first Big Picture surface, settings now loaded): SFX.boot(); SFX.open().
            if st != .boot { BPSound.shared.bootOnce() }
            if st == .shell { saver.start(); curfew.start() }
            if old == .boot, st != .boot { startIntro() }
            theme.holding = st == .onboarding
        }
        .onChange(of: overlayUp) { _, up in syncOverlay(up) }
        .onChange(of: browse.isUp) { _, up in syncBrowse(up) }
        .onChange(of: playback.active) { _, on in
            heldLanguage = on ? language : nil
            theme.holdingForPlayback = on
        }
        .onChange(of: pool.posters) { _, posters in
            // bp-shell.tsx: remember this session's art for the next boot, feed the wall if it
            // opened on too little, and let it leave once the art behind it has arrived.
            guard posters.count >= 16 else { return }
            let urls = posters
            Task { let _: Int? = try? await HarborEngine.shared.call("intro.poolSave", [urls]) }
            intro.offer(live: posters)
            intro.contentReady()
        }
        // Any press skips the wall (read without observing, so presses never re-render the root).
        .onReceive(ActivityMonitor.shared.$last.dropFirst()) { _ in intro.skip() }
        .environmentObject(app)
        .environmentObject(app.account)
        .environmentObject(app.profiles)
        .environmentObject(app.sync)
        .environmentObject(SettingsBridge.shared)
        .task { await app.boot() }
        // While the PiP browse layer is up the app's own shell is hidden under it: the link opens in the
        // layer. Links wait in DeepLinkQueue until the shell on screen is clear (AppModel.handle).
        .onOpenURL { (PiPBrowse.shared.layerApp ?? app).handle(url: $0) }
        // lib/theme.ts applyTheme: data-theme-mode follows the canvas (MinUI and Kawaii are light).
        .preferredColorScheme(theme.state?.light == true ? .light : .dark)
    }

    private var overlayUp: Bool { app.stage == .shell && (curfew.locked || saver.active) }

    /// Whether the root background's mosaic may run. Upstream draws none behind the boot splash
    /// (index-tv.html #boot), setup (bp-onboarding, z-60 on --bp-void), Who's watching (z-80 on
    /// --bp-void) or the intro wall (bp-intro, z-60 on --bp-void): each sits opaque over bp-shell's
    /// BpAmbient. It fades in as the wall leaves. A kid's shell paints its own canvas over it, and
    /// bp-shell skips BpAmbient in some rooms (BPAmbientBackground.shellDrawsMosaic).
    private var rootMosaic: Bool {
        app.stage == .shell && intro.phase != .showing && profiles.active?.kid == nil
            && BPAmbientBackground.shellDrawsMosaic(in: app.room)
    }

    private func syncOverlay(_ up: Bool) {
        guard up else { ShellOverlay.shared.hide(); return }
        ShellOverlay.shared.show(
            ShellOverlayView(saver: saver, curfew: curfew)
                .environment(\.locale, Locale(identifier: language))
                .environment(\.layoutDirection, L10n.rtlLanguages.contains(language) ? .rightToLeft : .leftToRight)
                .preferredColorScheme(theme.state?.light == true ? .light : .dark)
                .environmentObject(app)
                .environmentObject(app.account)
                .environmentObject(app.profiles)
                .environmentObject(app.sync)
                .environmentObject(SettingsBridge.shared)
        )
    }

    /// The PiP browse layer: a Big Picture shell on its own AppModel (its tabs must never swap the
    /// room that presented the player under it), with the environment this tree gets (PiPBrowseRoot
    /// follows the theme and language itself). PiPBrowse takes its window down by itself.
    private func syncBrowse(_ up: Bool) {
        guard up else { return }
        let model = AppModel(isBrowseLayer: true)
        model.stage = .shell
        PiPBrowse.shared.present(
            PiPBrowseRoot()
                .environmentObject(model)
                .environmentObject(model.account)
                .environmentObject(model.profiles)
                .environmentObject(model.sync)
                .environmentObject(SettingsBridge.shared),
            app: model)
    }

    /// The wall goes up once per launch (UI-test fixtures never raise it). It opens on this
    /// session's posters when the hero feed already landed, else on last session's (bp-intro-pool).
    private func startIntro() {
        intro.start()
        if pool.posters.count >= 16 {
            intro.offer(live: pool.posters)
            intro.contentReady()
            return
        }
        Task {
            let remembered: [String] = (try? await HarborEngine.shared.call("intro.poolLoad", [])) ?? []
            intro.offer(live: remembered)
        }
    }
}

/// Boot splash (index-tv.html#boot): #08090a, the mark rising in over 1200 ms, then a spinner.
struct BootSplashView: View {
    @State private var shown = false
    var body: some View {
        ZStack {
            Color(hex: 0x08090a).ignoresSafeArea()
            VStack(spacing: BP.px(28)) {
                HarborMark(size: BP.px(120))
                    .opacity(shown ? 1 : 0)
                    .scaleEffect(shown ? 1 : 0.92)
                ProgressView().tint(BP.inkMuted).opacity(shown ? 1 : 0)
            }
        }
        .onAppear { withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 1.2)) { shown = true } }
        .accessibilityIdentifier("boot-splash")
    }
}

/// The sail mark from the app icon, drawn as a shape so it scales crisply.
struct HarborMark: View {
    var size: CGFloat
    var body: some View {
        Image("HarborMark")
            .resizable()
            .renderingMode(.template)
            .scaledToFit()
            .foregroundStyle(BP.ink)
            .frame(width: size, height: size)
            // Decoration: VoiceOver read the asset's name ("HarborMark"). The wordmark or a label says Harbor.
            .accessibilityHidden(true)
    }
}

/// "Harb(o)r" wordmark in Fraunces with the tilted o (bp-top-bar.tsx:320-336).
struct HarborWordmark: View {
    var px: CGFloat = 24
    var body: some View {
        HStack(spacing: 0) {
            Text("Harb")
            Text("o").rotationEffect(.degrees(7), anchor: UnitPoint(x: 0.5, y: 0.65))
            Text("r")
        }
        .font(BP.wordmark(px))
        .foregroundStyle(BP.ink)
    }
}
