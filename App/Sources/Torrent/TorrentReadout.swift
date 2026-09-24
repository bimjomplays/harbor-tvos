import SwiftUI

/// The P2P part of the player's connecting card: bp-p2p-status.tsx (useBpP2pStatus polling the
/// engine once a second, bpStageLabel, BpP2pReadout's meter and "peers · speed · bytes") and
/// bp-connecting.tsx's notes, for a stream served by the TV's torrent engine.
struct TorrentReadout: View {
    let url: URL
    /// The player already holds the stream and waits on the next piece (snap.buffering).
    var buffering = false
    /// cinematic-player-loader.tsx kid branch: white type on the sea plate, and no large-file P2P
    /// warning (`!kid && heavyForP2p`).
    var kid = false
    /// use-p2p-preparing-status phase "no-peers": called once when the torrent is declared dead,
    /// so the kid loader can swap in its "Try again" block (cinematic-player-loader.tsx).
    var onNoPeers: (() -> Void)? = nil

    private var ink: Color { kid ? .white : BP.ink }
    private var inkMuted: Color { kid ? .white.opacity(0.7) : BP.inkMuted }

    enum Phase { case searching, connected, slow, noPeers }
    struct Sample {
        var phase: Phase = .searching
        var peers = 0
        var speed: Double = 0
        var downloaded: Double = 0
        var total: Double?
        var readiness: Double = 0
        var elapsedMs: Double = 0
    }

    @State private var sample = Sample()
    /// useMonotonicPct: the meter only ever climbs.
    @State private var pct: Double = 0

    // bp-p2p-status.tsx / bp-connecting.tsx windows.
    private static let noPeersMs: Double = 75_000
    private static let slowMs: Double = 90_000
    private static let stillLookingMs: Double = 22_000
    private static let heavyBytes: Double = 20 * 1_073_741_824

    var body: some View {
        VStack(alignment: .leading, spacing: BP.px(9)) {
            meter
            HStack(alignment: .firstTextBaseline, spacing: BP.px(10)) {
                if sample.peers == 0, sample.phase != .noPeers {
                    Circle().fill(ink.opacity(0.45)).frame(width: BP.px(9), height: BP.px(9))
                }
                Text(label).font(BP.sans(15, .bold)).textCase(.uppercase).tracking(2.4).foregroundStyle(ink)
                Spacer(minLength: BP.px(10))
                if pct >= 1 { Text("\(Int(pct.rounded()))%").font(BP.sans(19, .semibold)).monospacedDigit().foregroundStyle(inkMuted) }
            }
            if !parts.isEmpty {
                Text(parts.joined(separator: " · ")).font(BP.sans(19, .medium)).monospacedDigit().foregroundStyle(inkMuted)
            }
            if let note { Text(note).font(BP.sans(15, .medium)).foregroundStyle(inkMuted.opacity(0.8)).fixedSize(horizontal: false, vertical: true) }
            if !kid, let heavyNote { Text(heavyNote).font(BP.sans(15, .medium)).foregroundStyle(inkMuted.opacity(0.8)).fixedSize(horizontal: false, vertical: true) }
        }
        .frame(maxWidth: BP.px(620), alignment: .leading)
        .task(id: url) { await poll() }
    }

    private var meter: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(kid ? Color.white.opacity(0.25) : BP.glass)
                if pct >= 1 {
                    Capsule().fill(ink).frame(width: g.size.width * pct / 100)
                        .animation(.linear(duration: 1.9), value: pct)
                } else {
                    Capsule().fill(ink.opacity(0.6)).frame(width: g.size.width * 0.2)
                }
            }
        }
        .frame(height: BP.px(7))
    }

    /// bpStageLabel for a torrent.
    private var label: String {
        if sample.phase == .noPeers { return "No peers found" }
        if buffering { return "Buffering" }
        if sample.phase == .slow { return "Found peers, no data yet" }
        if sample.peers == 0 { return "Looking for peers…" }
        return "Preparing stream"
    }

    /// telemetryParts.
    private var parts: [String] {
        var out: [String] = []
        if sample.peers > 0 {
            out.append("\(sample.peers) \(sample.peers == 1 ? "peer" : "peers")")
            out.append(Self.speedText(sample.speed))
        }
        if sample.downloaded > 0 {
            if let total = sample.total, total > 0 {
                out.append("\(Self.bytes(sample.downloaded)) / \(Self.bytes(total))")
            } else {
                out.append(Self.bytes(sample.downloaded))
            }
        }
        return out
    }

    /// bp-connecting's note chain.
    private var note: String? {
        if sample.phase == .noPeers {
            return "Couldn't connect to any peers for this torrent. It may be unreachable on your network (some ISPs and VPNs block torrent traffic)."
        }
        if sample.phase == .slow { return "Found peers but no data yet. The torrent may be slow." }
        if buffering { return "The player has the stream open and is waiting on the next piece." }
        if sample.peers == 0, sample.elapsedMs >= Self.stillLookingMs { return "Still looking. Some torrents take a minute to find their first peer." }
        if sample.peers > 0 { return "Downloading the start of the file. Playback begins once there is enough to keep going." }
        return nil
    }

    private var heavyNote: String? {
        guard let total = sample.total, total > Self.heavyBytes, sample.phase != .noPeers else { return nil }
        return "Heads up: this is a large file for peer-to-peer streaming, so it can take a while to start. A 1080p source or a debrid service will load faster."
    }

    /// formatBpBytes.
    static func bytes(_ n: Double) -> String {
        if n >= 1_073_741_824 { return String(format: "%.2f GB", n / 1_073_741_824) }
        if n >= 1_048_576 { return "\(Int((n / 1_048_576).rounded())) MB" }
        return "\(Int((n / 1024).rounded())) KB"
    }

    /// speedText.
    static func speedText(_ bps: Double) -> String {
        if bps >= 1_048_576 { return String(format: "%.1f MB/s", bps / 1_048_576) }
        if bps >= 1024 { return "\(Int(bps / 1024)) KB/s" }
        return "Warming up"
    }

    /// engine-stats.ts readinessScore for an info-hash stream.
    static func readiness(peers: Int, downloaded: Double, speed: Double, streamLen: Double?) -> Double {
        let peerScore = min(1, Double(peers) / 8) * 20
        let minDownload = min(8 * 1_048_576, max(2 * 1_048_576, (streamLen ?? 0) * 0.008))
        let downloadedScore = min(1, downloaded / minDownload) * 70
        let speedScore = min(1, speed / 1_048_576) * 10
        return min(99, peerScore + downloadedScore + speedScore)
    }

    /// useBpP2pStatus's poll: once a second until the torrent is declared dead.
    private func poll() async {
        guard let ref = TorrentEngine.streamRef(url) else { return }
        let start = Date()
        var sawData = false
        var failed = false
        var total: Double?
        while !Task.isCancelled {
            if let s = await TorrentEngine.shared.stats(infoHash: ref.infoHash, fileIdx: ref.fileIdx) {
                let peers = s.unchoked > 0 ? s.unchoked : s.peers
                let elapsedMs = Date().timeIntervalSince(start) * 1000
                // Bytes moving is the only proof the torrent is alive; one byte is enough forever.
                if s.downloadSpeed > 0 || s.streamProgress > 0 || s.downloaded > 0 { sawData = true }
                let quiet = !sawData
                if quiet, peers == 0, elapsedMs >= Self.noPeersMs { failed = true }
                if s.streamLen > 0 { total = s.streamLen }
                let phase: Phase = failed ? .noPeers : (quiet && peers > 0 && elapsedMs >= Self.slowMs) ? .slow : peers > 0 ? .connected : .searching
                let readiness = Self.readiness(peers: peers, downloaded: s.downloaded, speed: s.downloadSpeed, streamLen: total)
                sample = Sample(phase: phase, peers: peers, speed: s.downloadSpeed, downloaded: s.downloaded, total: total, readiness: readiness, elapsedMs: elapsedMs)
                pct = max(pct, readiness)
                if failed { onNoPeers?(); return }
            }
            try? await Task.sleep(for: .seconds(1))
        }
    }
}
