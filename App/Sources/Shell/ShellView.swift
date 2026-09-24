import SwiftUI
import UIKit

/// The Big Picture shell: ambient background, top bar, the current room, hint bar.
/// Rooms ask the shell to re-evaluate default focus (e.g. when their rows arrive).
final class ShellFocus {
    static let shared = ShellFocus()
    var request: (() -> Void)?
    func requestDefault() { request?() }
}

private struct ShellFocusNamespaceKey: EnvironmentKey { static let defaultValue: Namespace.ID? = nil }
extension EnvironmentValues {
    var shellFocusNamespace: Namespace.ID? {
        get { self[ShellFocusNamespaceKey.self] }
        set { self[ShellFocusNamespaceKey.self] = newValue }
    }
}

struct ShellView: View {
    @EnvironmentObject private var app: AppModel
    @Namespace private var focusNS
    @Environment(\.resetFocus) private var resetFocus

    @EnvironmentObject private var settings: SettingsBridge
    /// Per-profile tab locks and hidden anime (Profiles/ParentalGate.swift).
    @ObservedObject private var parental = ParentalGate.shared

    var body: some View {
        ZStack(alignment: .top) {
            room
            TopBarView()
            VStack { Spacer(); HintBarView(actions: hints) }
        }
        // bp-shell.tsx fallback → popBigPicture: a tab is [home, tab], so Back from a tab lands on
        // Home; at Home the press is declined and belongs to the system (the app closes), which
        // is why Home's hint says Exit. Rooms with their own Back handling sit deeper and win.
        .onExitCommand(perform: backToHome)
        // bp-settings "Edge margin": a whole-screen inset for sets that crop the picture.
        .padding(.horizontal, 1920 * CGFloat(settings.slice.bigPictureOverscan ?? 0))
        .padding(.vertical, 1080 * CGFloat(settings.slice.bigPictureOverscan ?? 0))
        .ignoresSafeArea()
        .focusScope(focusNS)
        .environment(\.shellFocusNamespace, focusNS)
        .onAppear {
            ShellFocus.shared.request = { resetFocus(in: focusNS) }
            GamepadMonitor.shared.onTab = { delta in cycleTab(delta) }
            ParentalGate.shared.attach()
            leaveHiddenRoom()
        }
        // App.tsx: a room the profile may not see (anime hidden, a locked tab) falls back to
        // Home, whichever way it was reached: the bar, a shoulder button, a settings row, a
        // profile switch or a lock that just took effect.
        .onChange(of: app.room) { _, _ in leaveHiddenRoom() }
        .onChange(of: parental.gate) { _, _ in leaveHiddenRoom() }
        .onDisappear { GamepadMonitor.shared.onTab = nil }
        .fullScreenCover(item: $app.deepLinkMeta) { m in DetailView(meta: m) }
        // Calendar: lib/reminders-runner.tsx and its toast (Calendar/CalendarPanels.swift).
        .overlay(alignment: .top) { ReminderToastHost() }
        .overlay(alignment: .top) {
            if let n = app.deepLinkNote {
                Text(n).font(BP.sans(14, .semibold)).foregroundStyle(BP.ink).padding(.horizontal, BP.px(16)).padding(.vertical, BP.px(8))
                    .background(Capsule().fill(BP.panel)).padding(.top, BP.barHeight + BP.px(8))
                    .task { try? await Task.sleep(for: .seconds(4)); app.deepLinkNote = nil }
            }
        }
    }

    @ViewBuilder private var room: some View {
        switch app.room {
        case .settings: SettingsView()
        case .home, .movies, .shows, .anime:
            RoomView(room: app.room, source: app.browseSource).id(app.room)
        case .search:
            SearchView()
        case .discover:
            DiscoverView()
        case .library:
            LibraryView()
        case .calendar:
            CalendarView()
        case .live:
            LiveView()
        case .collections:
            CollectionsView()
        case .sports:
            SportsView()
        case .music:
            MusicView()
        default: RoomPlaceholderView(room: app.room)
        }
    }

    private func leaveHiddenRoom() {
        if parental.hides(app.room) { app.room = .home }
    }

    private var backToHome: (() -> Void)? {
        if app.room == .home { return nil }
        return { app.room = .home }
    }

    /// bp-shell.tsx HINTS per route kind. "search" and "phone" are left out: both name the pad's
    /// Y button (the quick panel / phone typing), which this port does not bind, and the bar
    /// exists to stop advertising dead keys. "nav" needs a jump key (bp-shell passes jump only
    /// when one works); on Apple TV Up already reaches the bar, so it is never advertised.
    private var hints: [BPHintAction] {
        switch app.room {
        case .home: return [.select, .exit, .tabs]
        case .search: return [.type, .back, .tabs]
        default: return [.select, .back, .tabs]
        }
    }

    /// use-bp-focus.ts PageUp/PageDown → bp-shell onTab → goBigPictureTab(cycleTab(order, active, delta)).
    /// Only on a bare route: bp-shell passes no onTab while a layer is up, and a full-screen cover
    /// (detail, pages, panels) or playback is exactly that here.
    private func cycleTab(_ delta: Int) {
        guard app.stage == .shell, !PlaybackState.shared.active, !CurfewState.shared.locked, Self.noCoverPresented else { return }
        let order = Room.shellTabs(sportsDeclined: settings.sportsDeclined, gate: parental)
        guard !order.isEmpty else { return }
        let from = order.firstIndex(of: app.room) ?? 0
        let next = ((from + delta) % order.count + order.count) % order.count
        ActivityMonitor.shared.touch()
        BPSound.shared.pageTurn(next: delta > 0)
        app.room = order[next]
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { ShellFocus.shared.requestDefault() }
    }

    private static var noCoverPresented: Bool {
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        guard let root = (windows.first(where: \.isKeyWindow) ?? windows.first)?.rootViewController else { return false }
        return root.presentedViewController == nil
    }
}

/// bp-hint-bar.tsx BpAction and its three glyph maps. Hardware key names are not translated.
enum BPHintAction: String {
    case select, back, exit, search, type, clear, toggle, phone, tabs, nav, actions, advance

    var label: String {
        switch self {
        case .select: return "Select"
        case .toggle: return "Toggle"
        case .type: return "Type"
        case .phone: return "Phone keyboard"
        case .back: return "Back"
        case .exit: return "Exit"
        case .search: return "Search"
        case .clear: return "Clear"
        case .tabs: return "Switch tab"
        case .nav: return "Nav"
        case .actions: return "Hold to skip or continue"
        case .advance: return "Hold to continue"
        }
    }

    var padGlyph: String? {
        switch self {
        case .select, .toggle, .type: return "A"
        case .back, .exit: return "B"
        case .search, .phone: return "Y"
        case .tabs: return "LB / RB"
        case .actions, .advance: return "▼"
        default: return nil
        }
    }

    /// A hint with no remote glyph is dropped on a remote without a pad.
    var remoteGlyph: String? {
        switch self {
        case .select, .toggle, .type: return "OK"
        case .back, .exit: return "Back"
        case .nav: return "Menu"
        case .actions, .advance: return "▼"
        default: return nil
        }
    }

    var keyGlyph: String {
        switch self {
        case .select, .toggle, .type: return "Enter"
        case .back, .exit: return "Esc"
        case .search, .phone: return "Tab"
        case .clear: return "Del"
        case .tabs: return "PgUp / PgDn"
        case .nav: return "Home"
        case .actions, .advance: return "↓"
        }
    }
}

extension Room {
    /// bp-top-bar.tsx visibleTabs: the tab strip and the shoulder cycle both read this, so a tab
    /// can never be hidden from one and reachable through the other.
    @MainActor static func shellTabs(sportsDeclined: Bool, gate: ParentalGate) -> [Room] {
        tabs.filter { !(sportsDeclined && $0 == .sports) && !gate.hides($0) }
    }
}

/// Top bar (bp-top-bar.tsx): brand at the start, icon-only tabs in the middle,
/// profile chip + Settings cog at the end, clock last. Sits over an upward scrim.
struct TopBarView: View {
    @EnvironmentObject private var settings: SettingsBridge
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var profiles: ProfilesStore
    @ObservedObject private var parental = ParentalGate.shared
    @FocusState private var focusedTab: Room?

    var body: some View {
        HStack(spacing: BP.px(9)) {
            HStack(spacing: BP.px(7)) {
                HarborMark(size: BP.px(28))
                HarborWordmark(px: 24)
            }
            .padding(.trailing, BP.px(12))
            ForEach(Room.shellTabs(sportsDeclined: settings.sportsDeclined, gate: parental)) { r in
                Button { app.room = r } label: { Image(systemName: r.icon).font(.system(size: BP.px(17), weight: .semibold)) }
                    .buttonStyle(BPTabStyle(active: app.room == r))
                    .focused($focusedTab, equals: r)
                    .overlay(alignment: .bottom) { tabHint(r) }
                    // Calendar: nav-items.tsx unseen-reminder badge (Calendar/CalendarPanels.swift).
                    .overlay(alignment: .topTrailing) { if r == .calendar { CalendarTabBadge() } }
                    .accessibilityIdentifier("tab-\(r.rawValue)")
                    .accessibilityLabel(r.label)
            }
            Spacer(minLength: BP.px(8))
            Rectangle().fill(BP.edge2).frame(width: 1, height: BP.px(26))
            if let p = profiles.active {
                Button { app.switchProfile() } label: {
                    HStack(spacing: BP.px(8)) {
                        ProfileFace(profile: p, size: BP.px(28))
                        Text(p.name).font(BP.sans(14, .semibold)).foregroundStyle(BP.ink).lineLimit(1)
                    }
                    .padding(.horizontal, BP.px(8))
                    .frame(height: BP.tabItem)
                }
                .buttonStyle(BPTabStyleWide())
                .accessibilityIdentifier("profile-chip")
            }
            Button { app.room = .settings } label: { Image(systemName: Room.settings.icon).font(.system(size: BP.px(17), weight: .semibold)) }
                .buttonStyle(BPTabStyle(active: app.room == .settings))
                .accessibilityIdentifier("tab-settings")
                .accessibilityLabel("Settings")
            StatusGlyphs()
            ClockView().padding(.leading, BP.px(6))
        }
        .padding(.horizontal, BP.gutter)
        .frame(height: BP.barHeight)
        // One full-width focus target: Up from anything in a room reaches the bar even when
        // nothing focusable sits directly above it (the brand mark is not a button).
        .focusSection()
        .background(
            LinearGradient(colors: [BP.void_.opacity(0.95), BP.void_.opacity(0.6), .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: BP.barHeight * 1.9), alignment: .top
        )
    }

    @ViewBuilder private func tabHint(_ r: Room) -> some View {
        if focusedTab == r {
            Text(r.label)
                .font(BP.sans(12, .semibold)).foregroundStyle(BP.ink)
                .padding(.horizontal, BP.px(10)).padding(.vertical, BP.px(4))
                .background(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).fill(BP.panel2))
                .overlay(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).stroke(BP.edge2, lineWidth: 1))
                .shadow(color: .black.opacity(0.45), radius: 14, y: 10)
                .fixedSize()
                .offset(y: BP.px(38))
                .transition(.opacity)
        }
    }
}

struct BPTabStyleWide: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        BPFocusReader { focused in
            configuration.label
                .background(RoundedRectangle(cornerRadius: BP.rXS, style: .continuous).fill(focused ? BP.glass : .clear))
                .overlay { if focused { RoundedRectangle(cornerRadius: BP.rXS, style: .continuous).stroke(BP.focusStroke, lineWidth: 3) } }
                .scaleEffect(focused ? 1.04 : 1)
                .animation(BP.easeFast, value: focused)
        }
    }
}

/// bp-status.tsx: CloudOff while sync changes sit unsaved for over a minute, WifiOff when the
/// network path is down. No battery on a television.
struct StatusGlyphs: View {
    @ObservedObject private var sync = SyncReader.shared
    @ObservedObject private var net = NetworkStatus.shared
    @State private var now = Date()
    private let timer = Timer.publish(every: 10, on: .main, in: .common).autoconnect()
    var body: some View {
        HStack(spacing: BP.px(10)) {
            if sync.stale(at: now) {
                Image(systemName: "icloud.slash").foregroundStyle(BP.danger)
                    .accessibilityLabel("Changes not saved to your Harbor account yet")
            }
            Image(systemName: net.online ? "wifi" : "wifi.slash").foregroundStyle(net.online ? BP.inkMuted : BP.danger)
        }
        .font(.system(size: BP.px(15), weight: .semibold))
        .padding(.leading, BP.px(8))
        .onReceive(timer) { now = $0 }
    }
}

struct ClockView: View {
    @State private var now = Date()
    private let timer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()
    var body: some View {
        Text(now, format: .dateTime.hour().minute())
            .font(BP.sans(15, .medium)).foregroundStyle(BP.inkMuted)
            .onReceive(timer) { now = $0 }
    }
}

/// Hint bar (bp-hint-bar.tsx): right-aligned glyph chips with labels. The glyphs follow the
/// input: pad glyphs while a game controller is connected (falling back to the key a keyboard
/// would use), remote glyphs otherwise, and a hint the remote has no button for is dropped.
struct HintBarView: View {
    let actions: [BPHintAction]
    @ObservedObject private var pads = GamepadMonitor.shared

    private struct Hint: Identifiable { var id: String; var glyph: String; var label: String }

    private var hints: [Hint] {
        let shown = actions.filter { $0 != .nav }
        let usable = pads.usingPad ? shown : shown.filter { $0.remoteGlyph != nil }
        return usable.map { a in
            let glyph = (pads.usingPad ? a.padGlyph : a.remoteGlyph) ?? a.keyGlyph
            return Hint(id: a.rawValue, glyph: glyph, label: a.label)
        }
    }

    var body: some View {
        HStack(spacing: BP.px(18)) {
            Spacer()
            ForEach(hints) { h in
                HStack(spacing: BP.px(7)) {
                    // Wide chips (more than one character) are rounded rects; single glyphs are circles.
                    Text(h.glyph)
                        .font(BP.sans(h.glyph.count > 1 ? 12.5 : 13.4, .semibold)).foregroundStyle(BP.ink)
                        .padding(.horizontal, h.glyph.count > 1 ? BP.px(7) : 0)
                        .frame(minWidth: BP.px(22), minHeight: BP.px(22), maxHeight: BP.px(22))
                        .background(RoundedRectangle(cornerRadius: h.glyph.count > 1 ? BP.rXS : BP.px(11), style: .continuous).fill(BP.edge2))
                    Text(h.label).font(BP.sans(13.4, .medium)).foregroundStyle(BP.inkMuted)
                }
            }
        }
        .padding(.horizontal, BP.gutter)
        .frame(height: BP.hintHeight)
        .background(LinearGradient(colors: [.clear, BP.void_.opacity(0.9)], startPoint: .top, endPoint: .bottom))
    }
}

/// Rooms that arrive in a later stage.
struct RoomPlaceholderView: View {
    let room: Room
    var body: some View {
        VStack(alignment: .leading, spacing: BP.px(12)) {
            Text(room.label).font(BP.display(36)).foregroundStyle(BP.ink)
            Text("Coming in Stage \(room.arrivesIn).").font(BP.sans(16)).foregroundStyle(BP.inkMuted)
        }
        .padding(.horizontal, BP.gutter).padding(.top, BP.barHeight + BP.px(20))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .focusable()
    }
}
