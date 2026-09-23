import AVFoundation
import Foundation

/// The cues Big Picture plays (lib/sfx.ts SoundEffects methods).
enum BPSoundCue: String {
    case hover, click, open, close, boot, turnNext, turnPrev
}

/// lib/sfx.ts `SFX`: Big Picture's UI sounds. Upstream has no sound files; every cue is a small
/// Web Audio graph (oscillators, gain ramps, a low-pass). `BPSynth` renders the same graphs into
/// PCM buffers once per theme, and this class plays them through an AVAudioEngine.
/// Theme is settings.bigPictureSound (use-bp-sound.ts), volume settings.sfxVolume / 100
/// (bp-tv-app.tsx BpTvSound). The audio session is left alone so mpv keeps owning it.
@MainActor
final class BPSound {
    static let shared = BPSound()

    private let engine = AVAudioEngine()
    private var players: [AVAudioPlayerNode] = []
    private var nextPlayer = 0
    private let format: AVAudioFormat
    private var cache: [String: AVAudioPCMBuffer] = [:]
    private var idleTask: Task<Void, Never>?
    private var hoverQueued = false
    private var lastTurnAt = Date.distantPast
    private var booted = false

    /// bp-settings-commit.ts auditionSound: focusing a Sound cell moves the live theme without
    /// committing it; bp-settings.tsx puts the committed theme back on the way out.
    var audition: String?

    private var theme: String { audition ?? SettingsBridge.shared.slice.bigPictureSound ?? "cinematic" }
    private var volume: Float {
        let v = (SettingsBridge.shared.slice.sfxVolume ?? 50) / 100
        return Float(max(0, min(1, v)))
    }

    private init() {
        format = AVAudioFormat(standardFormatWithSampleRate: BPSynth.rate, channels: 2)!
        // A few voices so a click does not cut off the hover still ringing under it.
        for _ in 0..<4 {
            let p = AVAudioPlayerNode()
            engine.attach(p)
            engine.connect(p, to: engine.mainMixerNode, format: format)
            players.append(p)
        }
    }

    /// use-bp-focus.ts moveFocus: SFX.hover() after every focus move. Deferred one hop so an
    /// audition that lands on the same focus change is already the theme it plays in.
    func hover() {
        guard !hoverQueued else { return }
        hoverQueued = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.hoverQueued = false
            self.play(.hover)
        }
    }

    /// use-bp-focus.ts select(): SFX.click().
    func click() { play(.click) }
    /// use-bp-focus.ts Escape/Backspace: SFX.close() before onBack.
    func close() { play(.close) }
    /// bp-shell.tsx mount, the quick panel and other layers opening: SFX.open().
    func open() { play(.open) }

    /// bp-shell.tsx mount: SFX.boot() then SFX.open(), once per session.
    func bootOnce() {
        guard !booted else { return }
        booted = true
        let t = theme
        guard t != "none" else { return }
        // The chord is ~3 s of 28 partials, too heavy to render on the main thread.
        let fmt = format
        Task.detached(priority: .userInitiated) {
            let buffer = BPSynth.render(.boot, theme: t, format: fmt)
            await MainActor.run {
                guard let buffer else { return }
                self.cache["\(t).boot"] = buffer
                self.schedule(buffer)
            }
        }
        open()
    }

    /// use-bp-focus.ts PageUp/PageDown (LB/RB): SFX.pageTurn. Upstream checks only `muted`
    /// here, never the theme, and drops a turn within 55 ms of the last one.
    func pageTurn(next: Bool) {
        let now = Date()
        guard now.timeIntervalSince(lastTurnAt) >= 0.055 else { return }
        lastTurnAt = now
        play(next ? .turnNext : .turnPrev)
    }

    private func play(_ cue: BPSoundCue) {
        let t = theme
        let themed = cue != .turnNext && cue != .turnPrev
        if themed && t == "none" { return }
        let key = themed ? "\(t).\(cue.rawValue)" : cue.rawValue
        if let hit = cache[key] { schedule(hit); return }
        guard let made = BPSynth.render(cue, theme: t, format: format) else { return }
        cache[key] = made
        schedule(made)
    }

    private func schedule(_ buffer: AVAudioPCMBuffer) {
        engine.mainMixerNode.outputVolume = volume
        if !engine.isRunning {
            // Also the recovery path: a route or configuration change stops the engine.
            do { try engine.start() } catch { return }
        }
        let p = players[nextPlayer]
        nextPlayer = (nextPlayer + 1) % players.count
        p.stop()
        p.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
        p.play()
        // Nothing renders while the app is quiet (bp-hero-pips' "a surface that never rests").
        idleTask?.cancel()
        idleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, let self else { return }
            self.engine.pause()
        }
    }
}

/// Offline renderer for lib/sfx.ts's Web Audio graphs: the same oscillator types, the same
/// AudioParam ramps (setValueAtTime / linearRamp / exponentialRamp), the same BiquadFilter
/// low-pass (Q in dB, as Web Audio defines it for lowpass) and the same stereo panner law.
enum BPSynth {
    static let rate: Double = 44100

    /// An AudioParam automation timeline, times relative to the voice start.
    struct Env {
        private struct Event { var kind: Int; var value: Double; var time: Double }   // 0 set, 1 linear, 2 exponential
        private var events: [Event]
        init(_ value: Double) { events = [Event(kind: 0, value: value, time: 0)] }
        func lin(_ value: Double, _ time: Double) -> Env { var e = self; e.events.append(Event(kind: 1, value: value, time: time)); return e }
        func exp(_ value: Double, _ time: Double) -> Env { var e = self; e.events.append(Event(kind: 2, value: value, time: time)); return e }
        func at(_ t: Double) -> Double {
            var v0 = events[0].value
            var t0 = events[0].time
            for e in events.dropFirst() {
                if t < e.time {
                    let f = (t - t0) / max(e.time - t0, 1e-9)
                    if e.kind == 1 { return v0 + (e.value - v0) * f }
                    if e.kind == 2, v0 > 0, e.value > 0 { return v0 * pow(e.value / v0, f) }
                    return v0
                }
                v0 = e.value
                t0 = e.time
            }
            return v0
        }
    }

    enum Wave { case sine, square, triangle }

    /// One oscillator → gain (→ low-pass) (→ panner) → master.
    struct Voice {
        var wave: Wave = .sine
        var freq: Env
        var gain: Env
        /// playGlass: a sine modulator at `modHz` whose output, scaled by `modDepth`, drives the carrier frequency.
        var modHz: Double = 0
        var modDepth: Env? = nil
        var start: Double = 0
        var length: Double
        var lowpassHz: Double = 0
        var lowpassQ: Double = 1
        var pan: Double? = nil
    }

    /// BiquadFilterNode "lowpass" (Audio EQ Cookbook with Web Audio's dB Q).
    struct Biquad {
        private var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0
        private var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
        private let on: Bool
        init(hz: Double, q: Double) {
            on = hz > 0
            guard on else { return }
            let w0 = 2 * Double.pi * hz / BPSynth.rate
            let alpha = sin(w0) / (2 * pow(10, q / 20))
            let c = cos(w0)
            let a0 = 1 + alpha
            b0 = (1 - c) / 2 / a0
            b1 = (1 - c) / a0
            b2 = (1 - c) / 2 / a0
            a1 = -2 * c / a0
            a2 = (1 - alpha) / a0
        }
        mutating func process(_ x: Double) -> Double {
            guard on else { return x }
            let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1; x1 = x
            y2 = y1; y1 = y
            return y
        }
    }

    static func render(_ cue: BPSoundCue, theme: String, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let list = voices(cue, theme: theme)
        guard !list.isEmpty else { return nil }
        let seconds = list.map { $0.start + $0.length }.max() ?? 0
        let frames = Int(seconds * rate) + 1
        var left = [Float](repeating: 0, count: frames)
        var right = [Float](repeating: 0, count: frames)
        for v in list { mix(v, into: &left, &right) }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let channels = buffer.floatChannelData else { return nil }
        buffer.frameLength = AVAudioFrameCount(frames)
        for i in 0..<frames {
            channels[0][i] = left[i]
            channels[1][i] = right[i]
        }
        return buffer
    }

    private static func mix(_ v: Voice, into left: inout [Float], _ right: inout [Float]) {
        let first = Int(v.start * rate)
        let count = Int(v.length * rate)
        var phase = 0.0
        var modPhase = 0.0
        var filter = Biquad(hz: v.lowpassHz, q: v.lowpassQ)
        // StereoPannerNode on a mono input: equal-power, x = (pan + 1) / 2 · π/2. No panner: both channels at unity.
        var gl = 1.0
        var gr = 1.0
        if let p = v.pan {
            let x = (p + 1) / 2 * Double.pi / 2
            gl = cos(x)
            gr = sin(x)
        }
        let twoPi = 2 * Double.pi
        for i in 0..<count {
            let idx = first + i
            if idx >= left.count { break }
            let t = Double(i) / rate
            var f = v.freq.at(t)
            if let depth = v.modDepth {
                f += depth.at(t) * sin(modPhase)
                modPhase += twoPi * v.modHz / rate
                if modPhase > twoPi { modPhase -= twoPi }
            }
            let s: Double
            switch v.wave {
            case .sine: s = sin(phase)
            case .square: s = sin(phase) >= 0 ? 1 : -1
            case .triangle: s = asin(sin(phase)) * 2 / Double.pi
            }
            phase += twoPi * f / rate
            if phase > twoPi { phase -= twoPi }
            let y = filter.process(s * v.gain.at(t))
            left[idx] += Float(y * gl)
            right[idx] += Float(y * gr)
        }
    }

    // MARK: lib/sfx.ts building blocks

    /// playTone: 0 → vol over 5 % of dur, exponential to 0.0001 at dur, stop at dur + 10 ms.
    private static func tone(_ freq: Double, _ wave: Wave, _ dur: Double, _ vol: Double, at start: Double = 0) -> Voice {
        Voice(wave: wave, freq: Env(freq), gain: Env(0).lin(vol, dur * 0.05).exp(0.0001, dur), start: start, length: dur + 0.01)
    }

    /// playGlass: FM bell through a 4 kHz low-pass.
    private static func glass(_ freq: Double, _ dur: Double, _ vol: Double, modRatio: Double = 2.76, modDepth: Double = 6) -> Voice {
        Voice(wave: .sine, freq: Env(freq), gain: Env(0).lin(vol, 0.01).exp(0.0001, dur),
              modHz: freq * modRatio, modDepth: Env(modDepth).exp(0.01, dur * 0.6),
              length: dur, lowpassHz: 4000, lowpassQ: 1)
    }

    /// playSwipe: a panned triangle glide through a 2.2 kHz low-pass.
    private static func swipe(_ startHz: Double, _ endHz: Double, _ dur: Double, _ vol: Double, _ pan: Double) -> Voice {
        Voice(wave: .triangle, freq: startHz == endHz ? Env(startHz) : Env(startHz).exp(endHz, dur),
              gain: Env(0).lin(vol, 0.008).exp(0.0001, dur), length: dur + 0.02, lowpassHz: 2200, lowpassQ: 1, pan: pan)
    }

    private static func voices(_ cue: BPSoundCue, theme: String) -> [Voice] {
        switch cue {
        case .hover:
            switch theme {
            case "glass": return [glass(2200, 0.05, 0.015)]
            case "modern": return [tone(1200, .sine, 0.015, 0.01)]
            case "retro": return [tone(740, .square, 0.016, 0.0035), tone(880, .triangle, 0.018, 0.003, at: 0.010)]
            case "cinematic": return [tone(350, .sine, 0.04, 0.01)]
            default: return []
            }
        case .click:
            switch theme {
            case "glass": return [glass(1500, 0.08, 0.04)]
            case "modern": return [tone(400, .sine, 0.05, 0.035)]
            case "retro": return [tone(520, .square, 0.022, 0.007), tone(360, .triangle, 0.028, 0.005, at: 0.012)]
            case "cinematic": return [tone(180, .sine, 0.12, 0.02)]
            default: return []
            }
        case .open:
            switch theme {
            case "glass": return [glass(720, 0.5, 0.04, modRatio: 3)]
            case "modern": return [tone(523.25, .sine, 0.3, 0.03), tone(659.25, .sine, 0.3, 0.025), tone(783.99, .sine, 0.3, 0.02)]
            case "retro": return [tone(523, .triangle, 0.06, 0.012), tone(659, .triangle, 0.045, 0.01, at: 0.015)]
            case "cinematic":
                // A falling sub thump under a short 900 Hz shimmer.
                return [Voice(wave: .sine, freq: Env(100).exp(35, 0.35), gain: Env(0.0001).exp(0.06, 0.04).exp(0.001, 1.2), length: 1.3),
                        Voice(wave: .sine, freq: Env(900), gain: Env(0.0001).exp(0.012, 0.05).exp(0.0001, 0.5), length: 0.6)]
            default: return []
            }
        case .close:
            switch theme {
            case "glass": return [glass(560, 0.3, 0.03)]
            case "modern": return [tone(392.0, .sine, 0.22, 0.03), tone(329.63, .sine, 0.22, 0.02)]
            case "retro": return [tone(560, .triangle, 0.05, 0.01), tone(430, .triangle, 0.06, 0.008, at: 0.035)]
            case "cinematic": return [tone(90, .sine, 0.4, 0.05)]
            default: return []
            }
        case .boot:
            guard theme != "none" else { return [] }
            // A struck D chord rising; overtones decay faster than the fundamental. 2.6 kHz low-pass, Q 0.4.
            let partials: [(Double, Double)] = [(1, 1), (2, 0.3), (3, 0.11), (4, 0.05)]
            let strikes: [(freq: Double, at: Double, vol: Double, dur: Double)] = [
                (73.42, 0, 0.05, 2.8), (146.83, 0.02, 0.036, 2.5), (220.0, 0.13, 0.03, 2.3), (293.66, 0.25, 0.026, 2.1),
                (369.99, 0.37, 0.022, 2.0), (440.0, 0.49, 0.018, 1.9), (587.33, 0.66, 0.014, 1.8),
            ]
            var out: [Voice] = []
            for s in strikes {
                for (ratio, share) in partials {
                    let life = s.dur / ratio.squareRoot()
                    out.append(Voice(wave: .sine, freq: Env(s.freq * ratio),
                                     gain: Env(0.0001).lin(s.vol * share, 0.018).exp(0.0001, life),
                                     start: 0.05 + s.at, length: life + 0.05, lowpassHz: 2600, lowpassQ: 0.4))
                }
            }
            return out
        case .turnNext:
            return [swipe(390, 560, 0.075, 0.05, 0.4)]
        case .turnPrev:
            return [swipe(430, 300, 0.09, 0.04, -0.4)]
        }
    }
}
