import SwiftUI

/// Settings → Anime4K (settings/defaults.ts playerAnime4k*): on/off, anime-only, mode, tier,
/// indicator, and the one-time shader download.
struct Anime4KPanel: View {
    @ObservedObject private var settings = SettingsBridge.shared
    @ObservedObject private var store = Anime4KStore.shared

    private let modes = ["A", "B", "C", "AA", "BB", "CA"]
    private var on: Bool { settings.slice.playerAnime4k ?? false }
    private var animeOnly: Bool { settings.slice.playerAnime4kAnimeOnly ?? true }
    private var indicator: Bool { settings.slice.playerAnime4kIndicator ?? true }
    private var mode: String { settings.slice.playerAnime4kMode ?? "A" }
    private var tier: String { settings.slice.playerAnime4kTier ?? "hq" }

    var body: some View {
        VStack(alignment: .leading, spacing: BP.px(10)) {
            Text(on ? "On" : "Off").font(BP.sans(16, .semibold)).foregroundStyle(BP.ink)
            Text("Real-time anime upscaling and restoration through mpv shaders (bloc97/Anime4K). HQ may stutter on an Apple TV; pick Fast if it does.")
                .font(BP.sans(14)).foregroundStyle(BP.inkMuted)
            HStack(spacing: BP.px(8)) {
                Button(on ? "Turn off" : "Turn on") { patch(["playerAnime4k": .bool(!on)]) }.buttonStyle(BPActionStyle(primary: !on))
                Button(animeOnly ? "Anime only" : "Every title") { patch(["playerAnime4kAnimeOnly": .bool(!animeOnly)]) }.buttonStyle(BPActionStyle())
                Button(indicator ? "Indicator on" : "Indicator off") { patch(["playerAnime4kIndicator": .bool(!indicator)]) }.buttonStyle(BPActionStyle())
            }
            HStack(spacing: BP.px(8)) {
                Text("Mode").font(BP.sans(13, .semibold)).foregroundStyle(BP.inkMuted)
                ForEach(modes, id: \.self) { m in
                    Button(m.count == 2 ? "\(m.prefix(1))+\(m.suffix(1))" : m) { patch(["playerAnime4kMode": .string(m)]) }.buttonStyle(BPActionStyle(primary: mode == m))
                }
                Text("Tier").font(BP.sans(13, .semibold)).foregroundStyle(BP.inkMuted).padding(.leading, BP.px(10))
                Button("HQ") { patch(["playerAnime4kTier": .string("hq")]) }.buttonStyle(BPActionStyle(primary: tier == "hq"))
                Button("Fast") { patch(["playerAnime4kTier": .string("fast")]) }.buttonStyle(BPActionStyle(primary: tier == "fast"))
            }
            HStack(spacing: BP.px(8)) {
                Button(store.busy ? "Downloading…" : (store.installed ? "Re-download shaders" : "Download shaders")) { Task { await store.ensure(force: store.installed) } }
                    .buttonStyle(BPActionStyle()).disabled(store.busy)
                Text(store.installed ? "Shaders installed" : "Not downloaded yet (about 3 MB, fetched on first use too)").font(BP.sans(12)).foregroundStyle(BP.inkSubtle)
            }
            if let n = store.note { BPNote(text: n, tone: n.hasPrefix("Download failed") ? BP.danger : BP.live) }
        }
    }

    private func patch(_ change: [String: AnyJSON]) {
        Task { try? await SettingsBridge.shared.patch(change) }
    }
}
