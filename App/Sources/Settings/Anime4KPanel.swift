import SwiftUI

/// Settings → Anime4K (settings/defaults.ts playerAnime4k*): on/off, anime-only, mode, tier,
/// indicator, and the one-time shader download.
struct Anime4KPanel: View {
    @ObservedObject private var settings = SettingsBridge.shared
    @ObservedObject private var store = Anime4KStore.shared

    private let modes = ["A", "B", "C", "AA", "BB", "CA"]
    /// (device report 2026-10-01) This TV's own choice (PlayerScreen.anime4kKey), off by default: the
    /// synced desktop setting turned the HQ chain on and anime played like a slideshow.
    @AppStorage(PlayerScreen.anime4kKey) private var tvChoice = "off"
    private var on: Bool { tvChoice != "off" }
    private var indicator: Bool { settings.slice.playerAnime4kIndicator ?? true }
    private var mode: String { settings.slice.playerAnime4kMode ?? "A" }

    var body: some View {
        VStack(alignment: .leading, spacing: BP.px(10)) {
            Text(on ? "On" : "Off").font(BP.sans(16, .semibold)).foregroundStyle(BP.ink)
            Text("Real-time anime upscaling and restoration through mpv shaders (bloc97/Anime4K). This TV runs the light tier only: the HQ tier is too heavy for an Apple TV at 4K.")
                .font(BP.sans(14)).foregroundStyle(BP.inkMuted)
            HStack(spacing: BP.px(8)) {
                Button(on ? "Turn off" : "Turn on") { tvChoice = on ? "off" : "auto" }.buttonStyle(BPActionStyle(primary: !on))
                Button(indicator ? "Indicator on" : "Indicator off") { patch(["playerAnime4kIndicator": .bool(!indicator)]) }.buttonStyle(BPActionStyle())
            }
            HStack(spacing: BP.px(8)) {
                Text("Mode").font(BP.sans(13, .semibold)).foregroundStyle(BP.inkMuted)
                ForEach(modes, id: \.self) { m in
                    Button(m.count == 2 ? "\(m.prefix(1))+\(m.suffix(1))" : m) { patch(["playerAnime4kMode": .string(m)]) }.buttonStyle(BPActionStyle(primary: mode == m)).bpSelected(mode == m)
                }
            }
            HStack(spacing: BP.px(8)) {
                Button(store.busy ? "Downloading…" : (store.installed ? "Re-download shaders" : "Download shaders")) {
                    guard !store.busy else { return }
                    Task { await store.ensure(force: store.installed) }
                }
                    .buttonStyle(BPActionStyle(busy: store.busy))
                Text(store.installed ? "Shaders installed" : "Not downloaded yet (about 3 MB, fetched on first use too)").font(BP.sans(12)).foregroundStyle(BP.inkSubtle)
            }
            if let n = store.note { BPNote(text: n, tone: store.noteOk ? BP.live : BP.danger) }
        }
    }

    private func patch(_ change: [String: AnyJSON]) {
        Task { try? await SettingsBridge.shared.patch(change) }
    }
}
