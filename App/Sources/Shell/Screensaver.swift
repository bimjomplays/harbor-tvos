import SwiftUI
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
    @Published var active = false
}

/// use-bp-screensaver + bp-screensaver: after `screensaverDelayMin` idle minutes, rotating hero art
/// with the title and "#N in {list} today"; the first press wakes it and is swallowed.
@MainActor
final class ScreensaverModel: ObservableObject {
    struct Item: Equatable { var bg: String; var title: String; var sub: String }
    @Published private(set) var active = false
    @Published private(set) var items: [Item] = []
    @Published private(set) var at = 0
    private var ticker: Task<Void, Never>?
    private var rotor: Task<Void, Never>?
    private var fetchedFor = ""

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
        if active { return }
        let delay = max(1, slice.screensaverDelayMin ?? 5) * 60
        if Date().timeIntervalSince(ActivityMonitor.shared.last) >= delay {
            await load(source: slice.heroFeed ?? "trending")
            active = true
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
