import SwiftUI

/// (perf pass 4) PlayerScreen's playback clock: the 1 s tick's snapshot (position, duration, pause
/// flag) and the buffered end. The screen holds it in a plain @State (not @StateObject), so its
/// body is not redrawn when the clock moves; only the leaves that show time observe it
/// (PlayerClockReader, PlayerSeekValue). Logic in the screen reads `snap` straight from here, and
/// a read is always the newest value. A tick publishes only what changed, so a paused video
/// redraws nothing.
final class PlayerClock: ObservableObject {
    @Published private(set) var snap: (position: Double, duration: Double, paused: Bool) = (0, 0, false)
    /// bp-player-scrub: demuxer cache end, drawn as the buffered fill.
    @Published private(set) var buffered: Double = 0
    /// The last spot the picture reached (duration and position both known), for Switch source.
    /// Not published: nothing draws it.
    var lastGoodPos: Double = 0

    /// A snapshot from the engine: stored (and published) only when it differs.
    func update(_ s: (position: Double, duration: Double, paused: Bool)) {
        if s.duration > 0, s.position > 0 { lastGoodPos = s.position }
        let same: Bool = s.position == snap.position && s.duration == snap.duration && s.paused == snap.paused
        if !same { snap = s }
    }

    /// A seek the player just asked for: the readout moves there before the next tick.
    func seeked(to position: Double) {
        if snap.position != position { snap.position = position }
    }

    func updateBuffered(_ sec: Double) {
        if sec != buffered { buffered = sec }
    }

    /// bp-player-scrub.tsx fmtTime: m:ss, or h:mm:ss from an hour.
    static func fmt(_ s: Double) -> String {
        guard s.isFinite, s > 0 else { return "0:00" }
        let t = Int(s)
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, (t / 60) % 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
    }
}

/// (perf pass 4) A leaf that observes the playback clock and draws `content` from it, so a tick
/// redraws this view alone and not the player around it.
struct PlayerClockReader<Content: View>: View {
    @ObservedObject private var clock: PlayerClock
    private let content: (PlayerClock) -> Content

    init(_ clock: PlayerClock, @ViewBuilder content: @escaping (PlayerClock) -> Content) {
        _clock = ObservedObject(wrappedValue: clock)
        self.content = content
    }

    var body: some View { content(clock) }
}

/// (perf pass 4) bp-player-scrub.tsx role="slider" aria-valuetext={fmtTime(position)}: the stage's
/// VoiceOver value, read from the clock inside this modifier so the player's body does not observe it.
struct PlayerSeekValue: ViewModifier {
    @ObservedObject var clock: PlayerClock
    let isLive: Bool
    let pending: Double?

    func body(content: Content) -> some View {
        let position: Double = pending ?? clock.snap.position
        let value: String = isLive ? "" : PlayerClock.fmt(position)
        return content.accessibilityValue(Text(verbatim: value))
    }
}

/// (perf pass 4) A leaf that observes the app-wide sleep timer (its minutes countdown publishes
/// every second) for the Speed & sleep control's face; the player's body no longer observes it.
struct PlayerSleepReader<Content: View>: View {
    @ObservedObject private var timer: SleepTimer
    private let content: (SleepTimer) -> Content

    init(@ViewBuilder content: @escaping (SleepTimer) -> Content) {
        _timer = ObservedObject(wrappedValue: SleepTimer.shared)
        self.content = content
    }

    var body: some View { content(timer) }
}
