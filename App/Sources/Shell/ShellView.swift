import SwiftUI

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

    var body: some View {
        ZStack(alignment: .top) {
            room
            TopBarView()
            VStack { Spacer(); HintBarView(actions: hints) }
        }
        .ignoresSafeArea()
        .focusScope(focusNS)
        .environment(\.shellFocusNamespace, focusNS)
        .onAppear { ShellFocus.shared.request = { resetFocus(in: focusNS) } }
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
        default: RoomPlaceholderView(room: app.room)
        }
    }

    private var hints: [(String, String)] {
        [("OK", "Select"), ("Menu", "Back")]
    }
}

/// Top bar (bp-top-bar.tsx): brand at the start, icon-only tabs in the middle,
/// profile chip + Settings cog at the end, clock last. Sits over an upward scrim.
struct TopBarView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var profiles: ProfilesStore
    @FocusState private var focusedTab: Room?

    var body: some View {
        HStack(spacing: BP.px(9)) {
            HStack(spacing: BP.px(7)) {
                HarborMark(size: BP.px(28))
                HarborWordmark(px: 24)
            }
            .padding(.trailing, BP.px(12))
            ForEach(Room.tabs) { r in
                Button { app.room = r } label: { Image(systemName: r.icon).font(.system(size: BP.px(17), weight: .semibold)) }
                    .buttonStyle(BPTabStyle(active: app.room == r))
                    .focused($focusedTab, equals: r)
                    .overlay(alignment: .bottom) { tabHint(r) }
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

struct ClockView: View {
    @State private var now = Date()
    private let timer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()
    var body: some View {
        Text(now, format: .dateTime.hour().minute())
            .font(BP.sans(15, .medium)).foregroundStyle(BP.inkMuted)
            .onReceive(timer) { now = $0 }
    }
}

/// Hint bar (bp-hint-bar.tsx): right-aligned glyph chips with labels.
struct HintBarView: View {
    let actions: [(String, String)]
    var body: some View {
        HStack(spacing: BP.px(18)) {
            Spacer()
            ForEach(actions, id: \.1) { glyph, label in
                HStack(spacing: BP.px(7)) {
                    Text(glyph)
                        .font(BP.sans(11, .bold)).foregroundStyle(BP.ink)
                        .padding(.horizontal, BP.px(7)).frame(height: BP.px(22))
                        .background(RoundedRectangle(cornerRadius: BP.rXS, style: .continuous).fill(BP.on))
                    Text(label).font(BP.sans(13.4, .medium)).foregroundStyle(BP.inkMuted)
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
