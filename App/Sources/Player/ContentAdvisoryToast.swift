import SwiftUI

/// (player parity pass 2) use-content-advisory.ts + components/player/content-advisory-toast.tsx,
/// mounted by stage-overlays.tsx under both the desktop and the ten-foot player: with
/// settings.contentAdvisoryToast on (off by default), the title's IMDb parental-guide categories
/// and MPA rating appear in the top corner once playback starts, hold 28 s (HOLD_MS) and leave.
/// The engine (player.contentAdvisory) resolves the imdb id, the ignore list and the rows.
/// On the TV the card never takes focus: Big Picture's ring does not reach its Dismiss and
/// "Ignore this title" buttons, and the remote's presses stay the player's.
struct ContentAdvisoryInfo: Decodable, Equatable {
    struct Row: Decodable, Equatable {
        var kind: String
        var label: String
        var severity: String
        var severityLabel: String
        var rank: Int
    }
    var imdbId: String
    var mpaRating: String?
    var rows: [Row]
    var monochrome: Bool
    var title: String
}

struct ContentAdvisoryLayer: View {
    let imdbId: String?
    let metaId: String?
    /// use-content-advisory srcKey: the stream on screen (a source swapped in place shows it again).
    let playKey: URL
    /// snap.status === "playing".
    let playing: Bool
    /// stage-overlays `!pipMode`.
    let hidden: Bool
    @ObservedObject var clock: PlayerClock

    @State private var info: ContentAdvisoryInfo?
    /// use-content-advisory playKey: the stream seen playing (startedRef).
    @State private var playedKey: URL?
    /// content-advisory-toast hasTriggered, per playKey.
    @State private var triggeredFor: URL?
    @State private var shown = false
    @State private var holdTask: Task<Void, Never>?

    private static let holdSec: UInt64 = 28

    var body: some View {
        ZStack(alignment: .topLeading) {
            if shown, !hidden, let info {
                card(info)
                    .transition(AnyTransition.opacity.combined(with: AnyTransition.offset(y: -BP.px(10))))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // content-advisory-toast positionClass "start-6 top-20" (top-start: the TV's room overlays
        // sit top-right, so the top-left corner is never taken).
        .padding(.leading, BP.px(24))
        .padding(.top, BP.px(80))
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.42), value: shown)
        .task(id: imdbId ?? metaId ?? "") {
            info = nil
            guard imdbId != nil || metaId != nil else { return }
            let p = ProfilesStore.shared.active
            let args: [any Encodable] = [p?.id ?? "default", p?.linked ?? true, imdbId, metaId]
            let loaded: ContentAdvisoryInfo? = try? await HarborEngine.shared.call("player.contentAdvisory", args)
            guard !Task.isCancelled else { return }
            info = loaded
            check()
        }
        .onAppear { notePlaying() }
        .onChange(of: playing) { _, _ in notePlaying() }
        .onChange(of: playKey) { _, _ in
            // The effect on [playKey]: a new stream starts the toast over.
            holdTask?.cancel()
            shown = false
            triggeredFor = nil
            playedKey = nil
            notePlaying()
        }
        .onChange(of: clock.snap.position) { _, _ in check() }
        .onDisappear { holdTask?.cancel() }
    }

    private func notePlaying() {
        if playing, playedKey != playKey { playedKey = playKey }
        check()
    }

    /// hasPlaybackStarted (position > 0.3), hasContent, a playKey and not triggered yet.
    private func check() {
        guard info != nil, playedKey == playKey, triggeredFor != playKey, clock.snap.position > 0.3 else { return }
        triggeredFor = playKey
        shown = true
        holdTask?.cancel()
        holdTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: Self.holdSec * 1_000_000_000)
            guard !Task.isCancelled else { return }
            shown = false
        }
    }

    private func card(_ info: ContentAdvisoryInfo) -> some View {
        VStack(alignment: .leading, spacing: BP.px(8)) {
            HStack(spacing: BP.px(8)) {
                HStack(spacing: BP.px(6)) {
                    Image(systemName: "exclamationmark.shield").font(.system(size: BP.px(11.5), weight: .semibold))
                    Text(info.title.uppercased()).font(BP.sans(9.5, .semibold)).tracking(BP.px(1.5)).lineLimit(1)
                }
                .foregroundStyle(Color.white.opacity(0.5))
                Spacer(minLength: 0)
                if let mpa = info.mpaRating, !mpa.isEmpty {
                    Text(mpa).font(BP.sans(9, .semibold)).monospacedDigit().foregroundStyle(Color.white.opacity(0.8))
                        .padding(.horizontal, BP.px(6)).padding(.vertical, BP.px(2))
                        .background(RoundedRectangle(cornerRadius: BP.px(4), style: .continuous).fill(Color.white.opacity(0.1)))
                }
            }
            ForEach(Array(info.rows.enumerated()), id: \.offset) { _, row in
                rowView(row, monochrome: info.monochrome)
            }
        }
        .padding(.horizontal, BP.px(12)).padding(.vertical, BP.px(10))
        .frame(width: BP.px(238), alignment: .leading)
        .background(RoundedRectangle(cornerRadius: BP.px(12), style: .continuous).fill(Color.black.opacity(0.7)))
        .overlay(RoundedRectangle(cornerRadius: BP.px(12), style: .continuous).stroke(Color.white.opacity(0.1), lineWidth: 1))
        .shadow(color: Color.black.opacity(0.85), radius: BP.px(20), y: BP.px(16))
        .accessibilityElement(children: .combine)
    }

    private func rowView(_ row: ContentAdvisoryInfo.Row, monochrome: Bool) -> some View {
        let tint: Color = Self.tint(row.severity, monochrome: monochrome)
        return HStack(spacing: BP.px(8)) {
            Image(systemName: Self.icon(row.kind)).font(.system(size: BP.px(13), weight: .medium)).foregroundStyle(tint)
                .frame(width: BP.px(16))
            Text(row.label).font(BP.sans(11.5)).foregroundStyle(Color.white.opacity(0.9)).lineLimit(1)
            Spacer(minLength: BP.px(6))
            HStack(spacing: BP.px(2.5)) {
                ForEach(1...3, id: \.self) { level in
                    Capsule().fill(level <= row.rank ? tint : Color.white.opacity(0.1))
                        .frame(width: BP.px(4), height: BP.px(10))
                }
            }
            .accessibilityHidden(true)
            Text(row.severityLabel).font(BP.sans(10, .semibold)).foregroundStyle(tint)
                .frame(width: BP.px(46), alignment: .trailing)
                .lineLimit(1)
        }
    }

    /// SEV_STYLE_COLORED / SEV_STYLE_MONO.
    private static func tint(_ severity: String, monochrome: Bool) -> Color {
        switch severity {
        case "Severe": return monochrome ? Color.white.opacity(0.9) : BP.danger
        case "Moderate": return monochrome ? Color.white.opacity(0.65) : BP.accent
        default: return Color.white.opacity(0.45)
        }
    }

    /// metaFor's lucide icons (Heart, Swords, MessageSquareWarning, Wine, Ghost, Info) as SF Symbols.
    private static func icon(_ kind: String) -> String {
        switch kind {
        case "sex": return "heart"
        case "violence": return "burst"
        case "profanity": return "exclamationmark.bubble"
        case "substances": return "wineglass"
        case "frightening": return "theatermasks"
        default: return "info.circle"
        }
    }
}
