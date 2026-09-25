import SwiftUI
import UIKit
import Combine

/// Browsing Harbor while Picture in Picture plays (AVPlayer engine; upstream use-pip-mode.ts /
/// the html5 bridge's requestPiP leave the rest of the app usable while the picture floats).
///
/// The player screen is a fullScreenCover, and its state (the engine, progress saves, scrobbles,
/// Now Playing, the torrent it owns, the Together room) lives only as long as that cover. So
/// the player never leaves: when PiP starts, it *steps aside*. A second Big Picture shell goes
/// up in a window above the app's own (under the curfew lock and the screensaver), on its own
/// AppModel so switching tabs there never swaps the room that presented the player. The player
/// keeps running under it, the picture plays in the PiP window above everything.
///
/// - PiP window restore button → the layer goes down (AVKit is told once it has), the picture
///   flies back to the player screen.
/// - Back on the layer's Home → the layer goes down; the player screen is in front, still in PiP
///   (its placard: Exit Picture in Picture / Browse Harbor / Leave).
/// - PiP window closed → the player stops and saves; the viewer keeps browsing.
/// - A video (or Multiview) opened from the layer → the one in PiP stops and saves first.
/// - A natural end that goes on to the next episode (or asks Still watching) → the layer goes
///   down first, so what follows is on screen.
/// - The profile changes → the player stops and the layer goes down.
@MainActor
final class PiPBrowse: ObservableObject {
    static let shared = PiPBrowse()

    /// The player that stepped aside.
    struct Owner {
        /// PlayerScreen's own id (its Now Playing claim).
        let id: UUID
        /// The remote's Play/Pause while the viewer browses (the player screen is not key then).
        let toggle: () -> Void
        /// Stop for good and save: another video is starting, or the profile changed.
        let end: () -> Void
        /// The layer went down on Back and the player screen (still in PiP) is in front again.
        let returned: () -> Void
    }

    /// The layer is up (or going up). RootView builds its window when this turns on (syncBrowse).
    @Published private(set) var isUp = false
    private var owner: Owner? {
        didSet { if filmInPiP != (owner != nil) { filmInPiP = owner != nil } }
    }
    /// The film that stepped aside still plays in the PiP window under the layer. Any other
    /// playback while the layer is up was opened from the layer itself (PiPBrowseRoot holds its
    /// language for it; BPSound stays quiet for it).
    @Published private(set) var filmInPiP = false
    private var window: HarborOverlayWindow?
    /// The AppModel the layer's shell runs on (ShellView tells its own layer apart by it).
    private weak var browseApp: AppModel?
    /// The main shell's hooks, which the layer's ShellView takes over while it is up.
    private var savedFocusRequest: (() -> Void)?
    private var savedOnTab: ((Int) -> Void)?

    /// The main shell's onAppear / onDisappear while the layer is up (its player cover closing
    /// under the layer re-appears it): its hooks go to the stash the layer hands back on lowering,
    /// never over the layer's own (review 36). Returns whether the stash took them.
    func stashMainHooks(request: (() -> Void)?, onTab: ((Int) -> Void)?, appearing: Bool) -> Bool {
        guard window != nil else { return false }
        if appearing { savedFocusRequest = request }
        savedOnTab = onTab
        return true
    }
    private var bag = Set<AnyCancellable>()

    private init() {
        // A profile switch (the top bar's profile chip, the account menu) rebuilds the app's own
        // tree, player included: stop the player properly and take the layer down with it.
        ProfilesStore.shared.$activeId.dropFirst().removeDuplicates().receive(on: RunLoop.main).sink { [weak self] _ in
            self?.profileChanged()
        }.store(in: &bag)
    }

    /// The layer's window while it is up (ShellOverlay hands the key back to it).
    var layerWindow: UIWindow? { window }

    /// The player owning the layer is `id`.
    func owns(_ id: UUID) -> Bool { owner?.id == id }

    /// `app` is the layer's own AppModel: that ShellView is the layer's.
    func isBrowseApp(_ app: AppModel) -> Bool { browseApp === app }

    /// The layer's AppModel while its window is up: RootView sends deep links there, so the
    /// detail page or shared list opens where the viewer is looking (the app's own shell is
    /// hidden under the layer).
    var layerApp: AppModel? { window == nil ? nil : browseApp }

    /// UI sounds may play over playback: the only film is the one in the PiP window, small in a
    /// corner, while the viewer browses the layer (upstream's lib/sfx.ts never mutes for video;
    /// BPSound's own rule is about panels drawn over a full-screen picture).
    var soundsOverPiP: Bool { filmInPiP && window != nil }

    /// Nothing is presented over the layer's shell (its shoulder-button tabs may turn).
    var noCoverPresented: Bool { window?.rootViewController?.presentedViewController == nil }

    /// PiP is on: the player screen steps aside and the layer goes up.
    func stepAside(_ next: Owner) {
        guard !isUp else { return }
        owner = next
        isUp = true
    }

    /// RootView's half: the layer's window, holding `content` (a shell on `app`).
    func present<Content: View>(_ content: Content, app: AppModel) {
        guard isUp, window == nil else { return }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = HarborOverlayWindow.mainWindow?.windowScene ?? scenes.first else { lower(returning: true); return }
        savedFocusRequest = ShellFocus.shared.request
        savedOnTab = GamepadMonitor.shared.onTab
        browseApp = app
        let w = HarborOverlayWindow(windowScene: scene)
        // Over the app's window (and the player's cover in it), under ShellOverlay's lock and saver (+1).
        w.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.normal.rawValue + 0.5)
        w.backgroundColor = .black
        let host = UIHostingController(rootView: content)
        host.view.backgroundColor = .black
        w.rootViewController = host
        window = w
        // Key, so the remote's presses and the focus go to the layer, never to the player under it.
        w.makeKeyAndVisible()
        if let saver = ShellOverlay.shared.keyWindow { saver.makeKey() }
    }

    /// Play/Pause pressed on the layer: the film in the PiP window pauses or plays.
    func togglePlayback() { owner?.toggle() }

    /// A player (or Multiview) is opening. The one in PiP stops first and saves its spot; the
    /// layer stays, since what is opening lives in it.
    func playbackOpening(_ id: UUID?) {
        guard let o = owner, o.id != id else { return }
        owner = nil
        o.end()
    }

    /// The owner is closing for its own reasons. `keepBrowsing`: the layer stays up with nothing
    /// under it (the PiP window was closed, or the film ended); otherwise it goes down with it.
    func release(_ id: UUID, keepBrowsing: Bool) {
        guard owner?.id == id else { return }
        if keepBrowsing { owner = nil } else { lower(returning: false) }
    }

    /// The PiP window's restore button: the player screen is in front before the picture returns.
    func restore(_ id: UUID) {
        guard owner?.id == id else { return }
        lower(returning: false)
    }

    /// Back on the layer's Home: back to the player screen (still in PiP), or, when nothing plays
    /// any more, to wherever the player was opened from.
    func backToPlayer() { lower(returning: true) }

    private func profileChanged() {
        guard isUp else { return }
        let o = owner
        owner = nil
        o?.end()
        lower(returning: false)
    }

    private func lower(returning: Bool) {
        let o = owner
        owner = nil
        isUp = false
        hideWindow()
        if returning { o?.returned() }
    }

    private func hideWindow() {
        guard let w = window else { return }
        window = nil
        // Whatever the layer's shell presented (a detail page, a person page…) goes with it.
        if let root = w.rootViewController, root.presentedViewController != nil { root.dismiss(animated: false) }
        w.isHidden = true
        w.rootViewController = nil
        // The main shell gets its default-focus hook and shoulder-button tabs back.
        ShellFocus.shared.request = savedFocusRequest
        GamepadMonitor.shared.onTab = savedOnTab
        savedFocusRequest = nil
        savedOnTab = nil
        (ShellOverlay.shared.keyWindow ?? HarborOverlayWindow.mainWindow)?.makeKey()
    }
}

/// What the layer's window shows: the Big Picture shell over the ambient background, as RootView
/// draws it (adult profiles only: a kid never gets Picture in Picture).
///
/// Like RootView, the tree is keyed on the theme revision and the display language, so a theme
/// or language chosen in the layer's Settings (or pulled in by profile sync) repaints it while it
/// is up. The film in PiP lives in the app's own tree, so the layer never waits for it; a player
/// or Multiview opened from the layer is in this tree, and the language waits for it to end.
/// (ThemeStore itself holds a new theme while anything plays: it lands when the film stops.)
struct PiPBrowseRoot: View {
    @ObservedObject private var theme = ThemeStore.shared
    @ObservedObject private var settings = SettingsBridge.shared
    @ObservedObject private var playback = PlaybackState.shared
    @ObservedObject private var browse = PiPBrowse.shared
    /// The language the layer was built in, kept while a player opened from it runs.
    @State private var heldLanguage: String?
    private var language: String { heldLanguage ?? L10n.normalize(settings.slice.uiLanguage) }
    /// Something opened from the layer plays (anything but the film in the PiP window).
    private var layerPlaying: Bool { playback.active && !browse.filmInPiP }

    var body: some View {
        ZStack {
            BPAmbientBackground(root: true)
            ShellView()
        }
        .id("\(theme.revision)|\(language)")
        .environment(\.locale, Locale(identifier: language))
        .environment(\.layoutDirection, L10n.rtlLanguages.contains(language) ? .rightToLeft : .leftToRight)
        .onChange(of: layerPlaying) { _, on in heldLanguage = on ? language : nil }
        // The remote's Play/Pause, when nothing focused on the layer uses it, drives the film in PiP.
        .onPlayPauseCommand { PiPBrowse.shared.togglePlayback() }
        // lib/theme.ts applyTheme: data-theme-mode follows the canvas (MinUI and Kawaii are light).
        .preferredColorScheme(theme.state?.light == true ? .light : .dark)
    }
}
