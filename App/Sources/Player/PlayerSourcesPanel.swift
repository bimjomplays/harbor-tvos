import SwiftUI

// (P8) bp-player-sources.tsx BpPlayerSources and duration-mismatch-chip.tsx: the in-player source
// switcher and the Watch Together guest's "Find closer match" chip that opens it.

/// bp-player-sources.tsx BpPlayerSources: `<BpStreams {...props} mode="switch" />`, the title's
/// streams as a card over the running film. It is the picker itself in its switch mode
/// (PlayPickerView `switching`): the same search, chips, filters, rows and resolve path (P2P consent,
/// the debrid retries, "Debrid is down"), with the stream playing now first and marked. A pick
/// hands the resolved stream to the player (PlayerScreen.switchSource), which swaps it in place at
/// the current position; the panel closes then (bp-ten-foot SourcesPanel closes when the playing
/// URL moves) and stays open on a failed resolve, with the reason.
struct PlayerSourcesPanel: View {
    let meta: Meta
    /// The PlayEpisode the search runs with (the picker's own, else one built from the context).
    let episode: AnyJSON?
    let current: Current
    let onPicked: (ScoredStream?, StreamsModel.Resolved) -> Void
    let onClose: () -> Void

    var body: some View {
        PlayPickerView(meta: meta, episode: episode, onPlay: onPicked, switching: current, onClose: onClose)
    }

    /// What plays now, for switcher-row.tsx isCurrentStream: the URL the player opened, and the
    /// picked stream's own URL, info hash and file (PlayerSrc.streamRef).
    struct Current: Equatable {
        var url: String
        var streamURL: String?
        var infoHash: String?
        var fileIdx: Int?

        /// switcher-row.tsx isCurrentStream: the same torrent (and file, when both know it), else
        /// the same URL.
        func matches(_ s: ScoredStream) -> Bool {
            if let mine = infoHash?.lowercased(), !mine.isEmpty, let theirs = s.infoHash?.lowercased(), theirs == mine {
                if let a = s.fileIndex, let b = fileIdx { return a == b }
                return true
            }
            guard let u = s.url, !u.isEmpty else { return false }
            return u == url || u == streamURL
        }
    }
}

/// duration-mismatch-chip.tsx: a Watch Together guest whose file runs more than DURATION_MISMATCH_S
/// (4 s) longer or shorter than the host's is told so, with "Find closer match" (the switcher) and a
/// dismiss that holds for this pair of files.
enum DurationMismatch {
    /// views/player/player-utils.ts DURATION_MISMATCH_S.
    static let thresholdS: Double = 4

    struct Info: Equatable {
        /// `${hostSource.infoHash ?? hostDuration}|${currentUrl}`: what a dismiss holds for.
        var key: String
        var guestSec: Double
        var hostSec: Double
    }

    /// player.tsx guestHostSource (inRoom && !isHost && hostSourceMatchesMedia) and the chip's
    /// `mismatch` rule. nil when there is nothing to say (casting has no TV counterpart).
    static func info(room: TogetherModel.Snapshot, metaId: String, season: Int?, episode: Int?,
                     guestSec: Double, playKey: String) -> Info? {
        guard room.inRoom, !room.isHost, let host = room.hostSource, host.mediaId == metaId else { return nil }
        // room-derive.ts hostSourceMatchesMedia: the same episode, or both without one.
        let local: (Int, Int)? = season.flatMap { s in episode.map { (s, $0) } }
        if (host.episode != nil) != (local != nil) { return nil }
        if let he = host.episode, let le = local, he.season != le.0 || he.episode != le.1 { return nil }
        let hostSec: Double = host.descriptor.durationSec ?? 0
        guard hostSec > 0, guestSec > 0, abs(guestSec - hostSec) > thresholdS else { return nil }
        let hostKey: String = host.descriptor.infoHash ?? formatNumber(hostSec)
        return Info(key: hostKey + "|" + playKey, guestSec: guestSec, hostSec: hostSec)
    }

    /// JS `String(number)` for the dismiss key (a whole number has no ".0").
    private static func formatNumber(_ v: Double) -> String {
        v == v.rounded() && abs(v) < 1e15 ? String(Int(v)) : String(v)
    }

    /// source-descriptor.ts formatRuntime: rounded seconds, m:ss or h:mm:ss.
    static func runtime(_ sec: Double) -> String {
        guard sec.isFinite, sec > 0 else { return "0:00" }
        let total = Int(sec.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

    /// Where Up from the stage lands on the chip.
    static let entry: PlayerScreen.FocusTarget = .chip("mismatch-find")
    static let dismissTarget: PlayerScreen.FocusTarget = .chip("mismatch-dismiss")
}

/// duration-mismatch-chip.tsx on the TV: a pill centred over the bottom of the picture (above the
/// transport while the chrome is up), "Your copy runs {guest}, host's runs {host}. Sync may drift."
/// with "Find closer match" and a ✕. Like the skip pill it is a soft target: it never takes the
/// ring when it appears (Select keeps meaning pause); Up from the stage or the transport reaches it
/// and Menu hands the ring back. A leaf: it observes the playback clock (the guest's duration) and
/// the room (the host's source), so neither redraws the player.
struct DurationMismatchChip: View {
    @ObservedObject var clock: PlayerClock
    @ObservedObject private var room = TogetherModel.shared
    let metaId: String
    let season: Int?
    let episode: Int?
    /// The URL playing now (currentUrl): a new file asks again.
    let playKey: String
    /// The player's gate: no panel (the switcher's `switcherOpen`), prompt, room or PiP over it.
    let allowed: Bool
    let chromeUp: Bool
    @Binding var dismissed: String?
    var focus: FocusState<PlayerScreen.FocusTarget?>.Binding
    let onFindCloser: () -> Void

    var body: some View {
        let info: DurationMismatch.Info? = allowed
            ? DurationMismatch.info(room: room.view, metaId: metaId, season: season, episode: episode,
                                    guestSec: clock.snap.duration, playKey: playKey)
            : nil
        ZStack {
            if let info, info.key != dismissed { chip(info).transition(.opacity) }
        }
        .animation(.easeOut(duration: 0.25), value: info?.key)
    }

    private func chip(_ info: DurationMismatch.Info) -> some View {
        let text: String = T("Your copy runs %@, host's runs %@. Sync may drift.",
                             DurationMismatch.runtime(info.guestSec), DurationMismatch.runtime(info.hostSec))
        return VStack {
            Spacer()
            HStack(spacing: BP.px(10)) {
                Text(verbatim: text).font(BP.sans(13, .medium)).foregroundStyle(BP.ink).lineLimit(1)
                    .padding(.leading, BP.px(8))
                Button { onFindCloser() } label: { Text("Find closer match") }
                    .buttonStyle(MismatchChipButtonStyle(accent: true))
                    .focused(focus, equals: DurationMismatch.entry)
                Button {
                    dismissed = info.key
                    focus.wrappedValue = .surface
                } label: {
                    Image(systemName: "xmark").font(.system(size: BP.px(12), weight: .bold))
                }
                .buttonStyle(MismatchChipButtonStyle())
                .focused(focus, equals: DurationMismatch.dismissTarget)
                .accessibilityLabel(Text(T("Dismiss")))
            }
            .padding(.vertical, BP.px(6)).padding(.leading, BP.px(10)).padding(.trailing, BP.px(6))
            .background(Capsule().fill(BP.elevated.opacity(0.95)))
            .overlay(Capsule().stroke(BP.edge, lineWidth: 1))
            .shadow(color: .black.opacity(0.7), radius: 22, y: 18)
            .focusSection()
            .padding(.bottom, chromeUp ? BP.px(300) : BP.px(40))
        }
        .frame(maxWidth: .infinity)
        .ignoresSafeArea()
    }
}

/// The chip's two buttons: accent (Find closer match) or muted (✕) text, flooding ink on focus.
private struct MismatchChipButtonStyle: ButtonStyle {
    var accent = false
    func makeBody(configuration: Configuration) -> some View {
        BPFocusReader { focused in
            configuration.label
                .font(BP.sans(13, .semibold))
                .foregroundStyle(focused ? BP.canvas : (accent ? BP.accent : BP.inkMuted))
                .lineLimit(1)
                .padding(.horizontal, BP.px(12))
                .frame(minWidth: BP.px(34), minHeight: BP.px(34))
                .background(Capsule().fill(focused ? BP.ink : Color.clear))
                .modifier(BPFocusModifier(focused: focused, pressed: configuration.isPressed, radius: BP.px(17), lift: 1.04))
        }
    }
}
