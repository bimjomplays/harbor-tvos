import SwiftUI
import Combine
import UIKit
import ObjectiveC

/// Every remote press reaches the key window through sendEvent; that is the whole idle signal.
@MainActor
final class ActivityMonitor: ObservableObject {
    static let shared = ActivityMonitor()
    @Published private(set) var last = Date()
    func touch() { last = Date() }

    private static var installed = false
    static func install() {
        guard !installed else { return }
        installed = true
        guard let a = class_getInstanceMethod(UIWindow.self, #selector(UIWindow.sendEvent(_:))),
              let b = class_getInstanceMethod(UIWindow.self, #selector(UIWindow.harbor_sendEvent(_:))) else { return }
        method_exchangeImplementations(a, b)
    }
}

extension UIWindow {
    @objc dynamic func harbor_sendEvent(_ event: UIEvent) {
        ActivityMonitor.shared.touch()
        // use-bp-focus.ts: SFX.click() on select, SFX.close() on Back. Remote and pad presses both
        // arrive here as UIPresses (pad A = select, B = menu). Playback owns its presses.
        if let presses = event as? UIPressesEvent, !PlaybackState.shared.active {
            for press in presses.allPresses where press.phase == .began {
                if press.type == .select { BPSound.shared.click() }
                else if press.type == .menu { BPSound.shared.close() }
            }
        }
        harbor_sendEvent(event)   // swapped: the original implementation
    }
}

/// Playback and pickers suppress the saver (use-bp-screensaver `suppressed`).
@MainActor
final class PlaybackState: ObservableObject {
    static let shared = PlaybackState()
    @Published private(set) var active = false
    /// The players (and Multiview) that hold playback. Two can overlap for a moment: a video
    /// started from the PiP browse layer opens while the one in Picture in Picture is still
    /// closing, and the late close must not clear the new one's claim (PiPBrowse).
    private var claims: Set<UUID> = []

    func claim(_ id: UUID) {
        claims.insert(id)
        if !active { active = true }
    }

    func release(_ id: UUID) {
        guard claims.remove(id) != nil else { return }
        if claims.isEmpty, active { active = false }
    }
}

/// Live previews (the guide portal, Home's Live hero) stop streaming whenever anything is over
/// them that they cannot see from their own state: the real player or Multiview, any presented
/// cover (the account menu, a Together invite's page, a deep link), the screensaver or the
/// curfew lock, or the app leaving the screen. Covers are not observable, so the main window is
/// polled twice a second.
@MainActor
final class PreviewGate: ObservableObject {
    static let shared = PreviewGate()
    @Published private(set) var blocked = false
    private var bag = Set<AnyCancellable>()

    private init() {
        // @Published fires before the value lands: read it on the next main-queue turn.
        PlaybackState.shared.$active.sink { [weak self] _ in Task { @MainActor in self?.refresh() } }.store(in: &bag)
        ScreensaverModel.shared.$active.sink { [weak self] _ in Task { @MainActor in self?.refresh() } }.store(in: &bag)
        CurfewState.shared.$locked.sink { [weak self] _ in Task { @MainActor in self?.refresh() } }.store(in: &bag)
        Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &bag)
    }

    func refresh() {
        // Off screen too: the `audio` background mode (music) keeps the app, and mpv, running.
        // The PiP browse layer (PiPBrowse) sits over the main window: nothing under it may stream,
        // and one video (in the PiP window, or just ended there) is enough for it too.
        let b = PlaybackState.shared.active || ScreensaverModel.shared.active || CurfewState.shared.locked
            || !HarborOverlayWindow.noCoverPresented || PiPBrowse.shared.isUp
            || UIApplication.shared.applicationState != .active
        if b != blocked { blocked = b }
    }
}

/// use-bp-screensaver + bp-screensaver: after `screensaverDelayMin` idle minutes, rotating hero art
/// with the title and "#N in {list} today"; the first press wakes it and is swallowed.
@MainActor
final class ScreensaverModel: ObservableObject {
    /// One per app: RootView drives it, and live previews read `active` to stop streaming under it.
    static let shared = ScreensaverModel()
    struct Item: Equatable { var bg: String; var title: String; var sub: String }
    @Published private(set) var active = false
    @Published private(set) var items: [Item] = []
    @Published private(set) var at = 0
    private var ticker: Task<Void, Never>?
    private var rotor: Task<Void, Never>?
    private var fetchedFor = ""
    private var activatedAt = Date.distantFuture

    func start() {
        guard ticker == nil else { return }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4))
                await self?.tick()
            }
        }
    }

    private func tick() async {
        let slice = SettingsBridge.shared.slice
        guard slice.screensaver ?? true, !PlaybackState.shared.active else { if active { wake() }; return }
        if active {
            // (bug pass) The saver only wakes from its own overlay, which is up on the shell stage
            // only. It also turned on (unseen) on Who's watching or onboarding; presses there never
            // woke it, so it jumped up the moment a profile was picked. Any press since it came
            // on wakes it.
            if ActivityMonitor.shared.last > activatedAt { wake() }
            return
        }
        let delay = max(1, slice.screensaverDelayMin ?? 5) * 60
        if Date().timeIntervalSince(ActivityMonitor.shared.last) >= delay {
            await load(source: slice.heroFeed ?? "trending")
            // Pressed while the art loaded: stay down.
            guard Date().timeIntervalSince(ActivityMonitor.shared.last) >= delay else { return }
            active = true
            activatedAt = Date()
            at = 0
            rotor?.cancel()
            rotor = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(8))
                    guard let self, !self.items.isEmpty else { continue }
                    self.at = (self.at + 1) % self.items.count
                }
            }
        }
    }

    func wake() {
        ActivityMonitor.shared.touch()
        rotor?.cancel(); rotor = nil
        active = false
    }

    private func load(source: String) async {
        let src = source == "classic" ? "trending" : source
        guard fetchedFor != src || items.isEmpty else { return }
        struct Ranked: Decodable { var name: String?; var background: String?; var rank: Int?; var rankLabel: String? }
        let metas: [Ranked] = (try? await HarborEngine.shared.call("feed.hero", [src])) ?? []
        var out: [Item] = []
        var seen: Set<String> = []
        for m in metas {
            guard let bg = m.background, !seen.contains(bg) else { continue }
            seen.insert(bg)
            let sub = (m.rank != nil && m.rankLabel != nil) ? "#\(m.rank!) in \(m.rankLabel!) today" : ""
            out.append(Item(bg: bg, title: m.name ?? "", sub: sub))
            if out.count >= 16 { break }
        }
        if !out.isEmpty { items = out; fetchedFor = src }
    }
}

struct ScreensaverView: View {
    @ObservedObject var model: ScreensaverModel
    @FocusState private var focused: Bool

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Color(hex: 0x08090a).ignoresSafeArea()
            if model.items.indices.contains(model.at) {
                let item = model.items[model.at]
                RemoteImage(url: item.bg).ignoresSafeArea().id(item.bg).transition(.opacity)
                LinearGradient(colors: [.clear, BP.void_.opacity(0.35), BP.void_.opacity(0.9)], startPoint: .top, endPoint: .bottom).ignoresSafeArea()
                VStack(alignment: .leading, spacing: BP.px(6)) {
                    Text(item.title).font(BP.display(38)).foregroundStyle(BP.ink).lineLimit(1)
                    if !item.sub.isEmpty { Text(item.sub).font(BP.sans(15, .medium)).foregroundStyle(BP.inkMuted) }
                }
                .padding(BP.gutter).padding(.bottom, BP.px(30))
            } else {
                HarborMark(size: BP.px(120)).opacity(0.6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            ClockView().padding(BP.gutter).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            // The whole surface is one focusable target so the waking press never reaches a tile.
            Button { model.wake() } label: { Color.clear.contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .focused($focused)
                .onMoveCommand { _ in model.wake() }
                .onExitCommand { model.wake() }
                .onPlayPauseCommand { model.wake() }
        }
        .animation(.easeInOut(duration: 0.9), value: model.at)
        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { focused = true } }
        .ignoresSafeArea()
    }
}

/// A window above the app's own. The curfew lock and the screensaver live here rather than in
/// RootView's ZStack, because a fullScreenCover (a detail page, a kids page, the account menu)
/// sits above everything in the main window and would hide them.
final class HarborOverlayWindow: UIWindow {
    /// The app's own window (never this overlay): key-window lookups for covers and display
    /// criteria go through it, so the lock or the saver being key never confuses them.
    static var mainWindow: UIWindow? {
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).filter { !($0 is HarborOverlayWindow) }
        // (bug pass) While an overlay is key no app window is, and `windows.first` could be a system
        // window UIKit adds to the scene after the first text entry (the keyboard's, far above
        // .normal), and hide() would hand the key there instead of to the shell. App windows first.
        let app = windows.filter { $0.windowLevel == .normal }
        return app.first(where: \.isKeyWindow) ?? app.first ?? windows.first(where: \.isKeyWindow) ?? windows.first
    }

    /// Nothing is presented over the main window's root (no fullScreenCover or sheet is up).
    static var noCoverPresented: Bool {
        guard let root = mainWindow?.rootViewController else { return false }
        return root.presentedViewController == nil
    }
}

/// Shows and hides the overlay window; RootView (syncOverlay) follows the lock and the saver.
@MainActor
final class ShellOverlay {
    static let shared = ShellOverlay()
    private var window: HarborOverlayWindow?

    func show<Content: View>(_ content: Content) {
        guard window == nil else { return }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = HarborOverlayWindow.mainWindow?.windowScene ?? scenes.first else { return }
        let w = HarborOverlayWindow(windowScene: scene)
        w.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.normal.rawValue + 1)
        w.backgroundColor = .clear
        let host = UIHostingController(rootView: content)
        host.view.backgroundColor = .clear
        w.rootViewController = host
        window = w
        // Key, so the remote's presses and the focus go to the lock / saver, never to what is under it.
        w.makeKeyAndVisible()
    }

    /// Up (the lock or the saver): the window that must stay key.
    var keyWindow: UIWindow? { window }

    func hide() {
        guard let w = window else { return }
        window = nil
        w.isHidden = true
        w.rootViewController = nil
        // The PiP browse layer, when up, is what the viewer was using under the saver.
        (PiPBrowse.shared.layerWindow ?? HarborOverlayWindow.mainWindow)?.makeKey()
    }
}

/// What the overlay window shows: the curfew lock (topmost, curfew-guard.tsx) or the screensaver.
struct ShellOverlayView: View {
    @ObservedObject var saver: ScreensaverModel
    @ObservedObject var curfew: CurfewState

    var body: some View {
        ZStack {
            if curfew.locked { CurfewLockView(state: curfew).transition(.opacity) }
            else if saver.active { ScreensaverView(model: saver).transition(.opacity) }
        }
        .animation(.easeInOut(duration: 0.3), value: curfew.locked)
    }
}
