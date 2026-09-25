import SwiftUI
import Combine

// The player's between-episode helpers: the sleep timer (lib/sleep-timer-store.ts,
// views/player/hooks/use-sleep-timer.ts), "Still watching?" (use-still-watching.ts,
// still-watching-prompt.tsx) and the speed & sleep dialog (components/player/transport/speed-menu.tsx).
// Upstream keeps one player mounted across episodes; the TV opens a fresh PlayerScreen for each,
// so the state that must survive an episode change lives here, app-wide.

/// lib/sleep-timer-store.ts: one timer for the whole app. "minutes" pauses the player when it runs
/// out; "End of episode" / "End of next episode" stop playback at a natural end (use-sleep-timer.ts).
@MainActor
final class SleepTimer: ObservableObject {
    static let shared = SleepTimer()

    /// sleep-timer-store.ts SleepMode.
    enum Mode: Equatable {
        case off
        case minutes(total: Int, firesAt: Date)
        case endEpisode
        case endNextEpisode(remaining: Int)
    }

    @Published private(set) var mode: Mode = .off
    /// useSleepRemainingMs, in seconds: what is left on a minutes timer (nil otherwise).
    @Published private(set) var remainingSec: Double?
    private var tick: Timer?
    private var fireHandler: (owner: UUID, run: () -> Void)?
    /// use-sleep-timer.ts lastUrlRef: the stream the player last opened (nil after a close that
    /// did not move on to another episode, like a fresh mount upstream).
    private var lastURL: URL?

    var isActive: Bool { mode != .off }

    /// setSleepMode.
    func set(_ next: Mode) {
        switch next {
        case .minutes(let total, _):
            mode = .minutes(total: total, firesAt: Date().addingTimeInterval(Double(total) * 60))
            startTick()
        case .endNextEpisode(let remaining):
            stopTick()
            remainingSec = nil
            mode = .endNextEpisode(remaining: max(1, remaining))
        case .off, .endEpisode:
            stopTick()
            remainingSec = nil
            mode = next
        }
    }

    /// clearSleepMode.
    func clear() {
        stopTick()
        mode = .off
        remainingSec = nil
    }

    /// registerSleepFireHandler: the playing player pauses when a minutes timer runs out.
    func register(_ owner: UUID, _ run: @escaping () -> Void) { fireHandler = (owner, run) }
    func unregister(_ owner: UUID) { if fireHandler?.owner == owner { fireHandler = nil } }

    /// use-sleep-timer.ts srcUrl effect: another stream in the player drops "End of episode".
    func playerOpened(url: URL) {
        if let last = lastURL, last != url, mode == .endEpisode { clear() }
        lastURL = url
    }

    /// The player closed; `advancing` when the next (or previous) episode opens next.
    func playerClosed(advancing: Bool) {
        if !advancing { lastURL = nil }
    }

    /// use-sleep-timer.ts status "ended": true when the timer ends playback here ("End of episode",
    /// or the last episode of "End of next episode"); "End of next episode" counts one down.
    func episodeEnded() -> Bool {
        switch mode {
        case .endEpisode:
            clear()
            return true
        case .endNextEpisode(let remaining):
            if remaining > 1 {
                mode = .endNextEpisode(remaining: remaining - 1)
                return false
            }
            clear()
            return true
        case .off, .minutes:
            return false
        }
    }

    private func startTick() {
        stopTick()
        step()
        guard case .minutes = mode else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { @Sendable [weak self] _ in
            Task { @MainActor in self?.step() }
        }
        RunLoop.main.add(timer, forMode: .common)
        tick = timer
    }

    private func stopTick() {
        tick?.invalidate()
        tick = nil
    }

    private func step() {
        guard case .minutes(_, let firesAt) = mode else { stopTick(); return }
        let r = firesAt.timeIntervalSinceNow
        remainingSec = max(0, r)
        if r <= 0 {
            stopTick()
            mode = .off
            remainingSec = nil
            fireHandler?.run()
        }
    }

    // speed-menu.tsx labels

    /// speed-menu.tsx formatRemaining: m:ss.
    static func formatRemaining(_ sec: Double) -> String {
        let s = max(0, Int(sec.rounded()))
        return "\(s / 60):" + String(format: "%02d", s % 60)
    }

    /// speed-menu.tsx sleepMinuteLabel.
    static func minuteLabel(_ m: Int) -> String {
        if m >= 60 && m % 60 == 0 { return T("%lld hr", m / 60) }
        return T("%lld min", m)
    }

    /// speed-menu.tsx sleepLabel: what the control's face shows while a timer is armed.
    var faceLabel: String? {
        switch mode {
        case .off: return nil
        case .minutes: return remainingSec.map { Self.formatRemaining($0) }
        case .endEpisode: return T("End ep")
        case .endNextEpisode(let n): return T("+%lld ep", n)
        }
    }
}

/// use-still-watching.ts: after `threshold` episodes advanced on their own with no press in
/// between, the next auto-advance asks first. `runs` is app-wide because the TV reopens the
/// player per episode; any press in the player resets it (upstream's window keydown listener).
@MainActor
enum StillWatching {
    static var runs = 0

    static func reset() { runs = 0 }

    /// gateAdvance: true when the prompt should show instead of advancing.
    static func gate(enabled: Bool, threshold: Int) -> Bool {
        guard enabled, threshold > 0 else { return false }
        if runs + 1 >= threshold { return true }
        runs += 1
        return false
    }
}

/// still-watching-prompt.tsx: "Still watching?" over the ended episode; Keep watching (the ring's
/// seed) goes on, Stop ({n}) counts down 45 s and closes the player at zero.
struct StillWatchingPrompt: View {
    let show: String
    var nextLabel: String? = nil
    var focus: FocusState<PlayerScreen.FocusTarget?>.Binding
    let onContinue: () -> Void
    let onExit: () -> Void

    private static let timeoutSec = 45
    @State private var secs = StillWatchingPrompt.timeoutSec
    @State private var fired = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.7).ignoresSafeArea()
            VStack(spacing: 0) {
                Text("Still watching?").font(BP.display(27)).foregroundStyle(BP.ink)
                Text(verbatim: nextLabel.map { "\(show) · \($0)" } ?? show)
                    .font(BP.sans(14)).foregroundStyle(BP.inkMuted).multilineTextAlignment(.center).lineLimit(2)
                    .padding(.top, BP.px(8))
                VStack(spacing: BP.px(10)) {
                    Button { exitOnce(continuing: true) } label: {
                        Text("Keep watching").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(BPActionStyle(primary: true))
                    .focused(focus, equals: .chip("still-continue"))
                    Button { exitOnce(continuing: false) } label: {
                        Text(T("Stop (%lld)", secs)).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(BPActionStyle())
                    .focused(focus, equals: .chip("still-stop"))
                }
                .padding(.top, BP.px(28))
                .focusSection()
            }
            .padding(.horizontal, BP.px(32)).padding(.vertical, BP.px(36))
            .frame(width: BP.px(448))
            .background(RoundedRectangle(cornerRadius: BP.rLG, style: .continuous).fill(BP.void_.opacity(0.8)))
            .overlay(RoundedRectangle(cornerRadius: BP.rLG, style: .continuous).stroke(BP.edge2, lineWidth: 1))
            .shadow(color: .black.opacity(0.8), radius: 40, y: 30)
        }
        // The countdown lives with the prompt (the player redraws every second; a timer publisher
        // rebuilt with it would never get to fire).
        .task {
            while secs > 0 {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
                secs -= 1
            }
            exitOnce(continuing: false)
        }
    }

    /// Continue, Stop and the countdown can land together; the player moves on once.
    private func exitOnce(continuing: Bool) {
        guard !fired else { return }
        fired = true
        if continuing { onContinue() } else { onExit() }
    }
}

/// speed-menu.tsx SpeedMenu as a Big Picture dialog: "Playback speed" (curated speeds plus
/// settings.customPlaybackSpeeds, the default one marked) beside "Sleep timer" (30 min, 1 hr,
/// settings.customSleepMinutes, End of episode, End of next episode). A pick applies and closes.
/// Editing presets needs a keyboard, so the TV only lists them; "Set as default speed" pins the
/// rate playing now (upstream's per-row pin).
struct PlayerSpeedPanel: View {
    let rate: Double
    /// A live channel has no speed to change; only the sleep timer shows.
    let isLive: Bool
    let onRate: (Double) -> Void
    let onClose: () -> Void

    @ObservedObject private var sleep = SleepTimer.shared
    @ObservedObject private var settings = SettingsBridge.shared
    @FocusState private var focus: String?

    private static let curatedSpeeds: [Double] = [0.75, 1, 1.25, 1.5, 2]
    private static let curatedSleepMinutes = [30, 60]

    private var defaultSpeed: Double { settings.slice.defaultPlaybackSpeed ?? 1 }

    private var speeds: [Double] {
        var all = Self.curatedSpeeds
        // A synced custom speed outside what both engines play (0 would stall AVPlayer) is skipped (bug pass).
        for s in settings.slice.customPlaybackSpeeds ?? [] where s.isFinite && s >= 0.25 && s <= 4 && !all.contains(where: { abs($0 - s) < 0.001 }) { all.append(s) }
        return all.sorted()
    }

    private var sleepMinutes: [Int] {
        var all = Self.curatedSleepMinutes
        for raw in settings.slice.customSleepMinutes ?? [] {
            let m = Int(raw.rounded())
            if m >= 1, !all.contains(m) { all.append(m) }
        }
        return all.sorted()
    }

    static func rateLabel(_ v: Double) -> String {
        abs(v - 1) < 0.001 ? T("Normal") : String(format: "%g×", v)
    }

    var body: some View {
        ZStack {
            BP.void_.opacity(0.5).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 0) {
                Label("Speed & sleep", systemImage: "speedometer").font(BP.display(26)).foregroundStyle(BP.ink)
                    .padding(.horizontal, BP.px(30)).padding(.top, BP.px(30))

                HStack(alignment: .top, spacing: BP.px(24)) {
                    if !isLive { speedColumn }
                    sleepColumn
                }
                .padding(.horizontal, BP.px(30)).padding(.vertical, BP.px(18))

                lane
            }
            .frame(width: BP.px(isLive ? 620 : 1049), height: BP.px(640), alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: BP.rLG, style: .continuous).fill(BP.void_))
            .overlay(RoundedRectangle(cornerRadius: BP.rLG, style: .continuous).stroke(BP.edge, lineWidth: 1))
            .focusSection()
        }
        .onAppear {
            let seed = isLive ? "sleep-0" : "speed-\(speeds.firstIndex { abs($0 - rate) < 0.01 } ?? 1)"
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { focus = seed }
        }
    }

    private var speedColumn: some View {
        VStack(alignment: .leading, spacing: BP.px(10)) {
            PlayerRowLabel(text: "Playback speed")
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: BP.px(8)) {
                    ForEach(Array(speeds.enumerated()), id: \.offset) { i, v in
                        let selected = abs(v - rate) < 0.01
                        Button { onRate(v); onClose() } label: {
                            PlayerLineLabel(icon: selected ? "checkmark" : "speedometer", title: Self.rateLabel(v),
                                            detail: abs(v - defaultSpeed) < 0.01 ? T("Default speed") : nil)
                        }
                        .buttonStyle(PlayerLineStyle(on: selected))
                        .focused($focus, equals: "speed-\(i)")
                    }
                }
                .padding(BP.px(6))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .focusSection()
    }

    private var sleepColumn: some View {
        VStack(alignment: .leading, spacing: BP.px(10)) {
            PlayerRowLabel(text: "Sleep timer")
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: BP.px(8)) {
                    ForEach(Array(sleepRows.enumerated()), id: \.offset) { i, row in
                        let selected = isSelected(row.mode)
                        Button { sleep.set(row.mode); onClose() } label: {
                            PlayerLineLabel(icon: selected ? "checkmark" : row.icon, title: row.label,
                                            detail: selected && row.isMinutes ? sleep.remainingSec.map { SleepTimer.formatRemaining($0) } : nil)
                        }
                        .buttonStyle(PlayerLineStyle(on: selected))
                        .focused($focus, equals: "sleep-\(i)")
                    }
                }
                .padding(BP.px(6))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .focusSection()
    }

    private struct SleepRow { var label: String; var mode: SleepTimer.Mode; var icon: String; var isMinutes: Bool }

    /// speed-menu.tsx sleepList: minute rows sorted, then the two episode rows.
    private var sleepRows: [SleepRow] {
        sleepMinutes.map { SleepRow(label: SleepTimer.minuteLabel($0), mode: .minutes(total: $0, firesAt: Date()), icon: "clock", isMinutes: true) }
            + [SleepRow(label: T("End of episode"), mode: .endEpisode, icon: "moon", isMinutes: false),
               SleepRow(label: T("End of next episode"), mode: .endNextEpisode(remaining: 2), icon: "moon.zzz", isMinutes: false)]
    }

    /// speed-menu.tsx isSel: the same minute total, or the same episode kind.
    private func isSelected(_ m: SleepTimer.Mode) -> Bool {
        switch (sleep.mode, m) {
        case (.minutes(let a, _), .minutes(let b, _)): return a == b
        case (.endEpisode, .endEpisode): return true
        case (.endNextEpisode, .endNextEpisode): return true
        default: return false
        }
    }

    private var lane: some View {
        HStack(spacing: BP.px(10)) {
            Button("Back") { onClose() }
                .buttonStyle(BPActionStyle())
                .focused($focus, equals: "back")
            if !isLive {
                // speed-menu.tsx onMakeDefault → update({ defaultPlaybackSpeed }).
                // (player pass 2) Dimmed, not disabled, once the rate is the default: pressing it
                // disabled the button under the ring, which then jumped to Back or Cancel timer.
                let isDefault: Bool = abs(rate - defaultSpeed) < 0.01
                Button {
                    if !isDefault { Task { try? await SettingsBridge.shared.patch(["defaultPlaybackSpeed": .number(rate)]) } }
                } label: {
                    Label("Set as default speed", systemImage: "pin")
                }
                .buttonStyle(BPActionStyle())
                .opacity(isDefault ? 0.45 : 1)
                .focused($focus, equals: "make-default")
            }
            if sleep.isActive {
                Button { sleep.clear(); onClose() } label: { Label("Cancel timer", systemImage: "xmark") }
                    .buttonStyle(BPActionStyle())
                    .focused($focus, equals: "cancel-timer")
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, BP.px(30)).padding(.vertical, BP.px(16))
        .overlay(alignment: .top) { Rectangle().fill(BP.edge).frame(height: 1) }
        .focusSection()
    }
}
