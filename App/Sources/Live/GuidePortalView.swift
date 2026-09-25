import SwiftUI

/// bp-guide-portal.tsx: the floating preview in the guide's bottom corner. Programme art (or the
/// channel logo over a blurred copy of itself, bp-guide-portal-art), the "Live" label, title,
/// time range and category, description and progress; after a 700 ms dwell on a channel a muted
/// mini-player fades in over the art. A channel whose stream fails once is not retried this session.
struct GuidePortalView: View {
    let channel: LiveModel.Channel
    let program: LiveModel.Program?
    let startMs: Double
    let endMs: Double
    let now: Double
    /// The real player (or any cover) is up: many IPTV accounts allow one connection, so the
    /// preview must let go of its socket (upstream: `!stackKinds.includes("player")`).
    let suspended: Bool

    static let width = BP.px(440)
    static var height: CGFloat { width * 9 / 16 }
    // 400 ms is what a JSON hover-preview uses; a video mount is heavier (upstream DWELL_MS).
    private static let dwell: Duration = .milliseconds(700)
    private static var failed = Set<String>()

    /// Anything over the guide the caller cannot see (a cover, the saver, the lock, playback).
    @ObservedObject private var gate = PreviewGate.shared
    private var stopped: Bool { suspended || gate.blocked }

    @State private var armed = false
    @State private var playing = false
    @State private var failures = 0

    private var mountVideo: Bool {
        _ = failures
        return armed && !channel.url.isEmpty && !Self.failed.contains(channel.id) && !stopped && !UIAccessibility.isReduceMotionEnabled
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            art
            if mountVideo, let url = URL(string: channel.url) {
                MPVPlayerView(url: url, headers: channel.headers ?? [:], isLive: true, preview: true, onStatus: { st in
                    if st.state == "playing" { playing = true }
                    if st.state == "error" { Self.failed.insert(channel.id); playing = false; failures += 1 }
                })
                .id(channel.id)
                .opacity(playing ? 1 : 0)
                .animation(.easeInOut(duration: 0.3), value: playing)
            }
            LinearGradient(colors: [BP.void_.opacity(0), BP.void_.opacity(0.85)], startPoint: .center, endPoint: .bottom)
            VStack(alignment: .leading, spacing: BP.px(4)) {
                HStack(spacing: BP.px(5)) {
                    Circle().fill(BP.live).frame(width: BP.px(6), height: BP.px(6))
                    Text("Live").font(BP.sans(10, .bold)).textCase(.uppercase).tracking(1).foregroundStyle(BP.ink)
                }
                Text(program.map { $0.title.isEmpty ? T("No program info") : $0.title } ?? T("No program info"))
                    .font(BP.sans(16, .bold)).foregroundStyle(BP.ink).lineLimit(1)
                Text(range).font(BP.sans(11)).foregroundStyle(BP.inkMuted).lineLimit(1)
                if let d = program?.description, !d.isEmpty { Text(d).font(BP.sans(11)).foregroundStyle(BP.inkMuted).lineLimit(2) }
                if let p = program {
                    let pct = min(1, max(0, (now - p.startMs) / max(1, p.endMs - p.startMs)))
                    GeometryReader { g in
                        ZStack(alignment: .leading) { Capsule().fill(BP.on); Capsule().fill(BP.live).frame(width: g.size.width * pct) }
                    }
                    .frame(height: BP.px(3))
                }
            }
            .padding(BP.px(14))
        }
        .frame(width: Self.width, height: Self.height)
        .background(BP.panel)
        .clipShape(RoundedRectangle(cornerRadius: BP.rXS, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: BP.rXS, style: .continuous).strokeBorder(BP.edge2, lineWidth: 1))
        .shadow(color: .black.opacity(0.6), radius: 30, y: 16)
        .allowsHitTesting(false)
        .task(id: channel.id) {
            armed = false; playing = false
            try? await Task.sleep(for: Self.dwell)
            if !Task.isCancelled { armed = true }
        }
        // Suspending unmounts the player (MPVPlayerView's dismantle stops mpv); it fades in afresh.
        .onChange(of: stopped) { _, on in if on { playing = false } }
    }

    private var range: String {
        let p = program
        let r = "\(LiveChannelRow.time(p?.startMs ?? startMs)) – \(LiveChannelRow.time(p?.endMs ?? endMs))"
        if let c = p?.category, !c.isEmpty { return "\(r) · \(c)" }
        return r
    }

    @ViewBuilder private var art: some View {
        if let icon = program?.iconUrl, !icon.isEmpty {
            RemoteImage(url: icon).frame(width: Self.width, height: Self.height).clipped()
        } else if let logo = channel.logo, !logo.isEmpty {
            ZStack {
                RemoteImage(url: logo).frame(width: Self.width, height: Self.height).blur(radius: 24).opacity(0.5).clipped()
                RemoteImage(url: logo, contentMode: .fit).frame(width: Self.width * 0.4, height: Self.height * 0.4)
            }
        } else {
            BP.panel
        }
    }
}
