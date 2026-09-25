import AVFoundation
import Foundation
import HarborFFI

/// Spotify Premium playback on the TV: the Swift side of upstream's src-tauri/src/music/spotify
/// (mod.rs connect/disconnect/initialize, control.rs play/pause/seek/stop), over the librespot
/// session in rust/harbor-ffi/src/spotify.
///
/// - Sign-in: the engine (engine/musicSpotify.ts) runs the OAuth hand-off with the phone and keeps
///   the tokens; this class signs the librespot session in with the access token, or with the
///   reusable credentials the engine saved (upstream `initialize`), and reports the session back
///   (`music.spotifySessionReady`), which also refuses a Free account with upstream's copy.
/// - Audio: librespot decodes into a ring in Rust; `SpotifyAudioOutput` drains it from an
///   AVAudioSourceNode render callback (no cpal/rodio on tvOS). The shared AVAudioSession is set
///   to playback and never deactivated (review 19).
/// - Transport and events: MusicPlayer drives the calls below and polls `drainEvents()` (upstream's
///   music://event stream: playing / paused / time-pos / end-file / player-failure).
///
/// Blocking C calls (connect, session token, disconnect) run on `SpotifyPlayback.queue`; the
/// transport calls only queue a player command in Rust and return at once.
@MainActor
final class SpotifyPlayback: ObservableObject {
    static let shared = SpotifyPlayback()

    /// mod.rs SpotifyStatus as harbor_spotify_connect answers it (+ the reusable sign-in).
    struct RustStatus: Codable {
        var connected: Bool
        var username: String?
        var country: String?
        var premium: Bool
        var accountType: String?
        var error: String?
        var credentials: String?
    }
    /// engine/musicSpotify.ts sessionReady / recordFailure / forget.
    struct Status: Decodable {
        var connected: Bool
        var username: String?
        var country: String?
        var premium: Bool
        var accountType: String?
        var error: String?
        var shutdown: Bool?
    }
    struct Event: Decodable { var event: String; var position: Double?; var reason: String? }
    struct Events: Decodable { var events: [Event]; var connected: Bool }
    struct SessionToken: Codable { var accessToken: String; var expiresAt: Double }
    /// engine/musicSpotify.ts restore (mod.rs initialize: keystore::load).
    struct Restore: Decodable { var credentials: String?; var deviceId: String }
    /// engine/musicSpotify.ts finish: the token from the phone sign-in.
    struct Granted: Decodable { var accessToken: String; var deviceId: String }
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// The URI the engine's prepare() returns for a Spotify track (musicSpotify.ts SPOTIFY_STREAM_MIME).
    static let streamMime = "audio/x-spotify-uri"

    @Published private(set) var connected = false
    @Published private(set) var connecting = false
    /// spotify-library.ts harbor:spotify-library-changed: a playlist was created or a track added.
    @Published private(set) var libraryVersion = 0

    let output = SpotifyAudioOutput()
    nonisolated static let queue = DispatchQueue(label: "harbor.spotify", qos: .userInitiated)
    private var restoreTask: Task<Void, Never>?
    private var restoreSerial = 0
    /// (bug pass 2) When the last restore from the saved sign-in failed. Every Spotify entry asks
    /// for a restore before it plays, and with the network down each one waited out Rust's 45 s
    /// CONNECT_TIMEOUT, so a queue of Spotify tracks took minutes to fail over to other sources.
    /// Upstream tries once at launch (mod.rs initialize) and a play without a session fails at once.
    private var restoreFailedAt: Date?
    private static let restoreRetryAfter: TimeInterval = 60
    /// Bumped by disconnect: a sign-in still in flight from before is shut down when it lands.
    private var generation = 0

    private init() {}

    // MARK: C calls

    private struct ErrorProbe: Decodable { var error: String? }

    /// Runs one C call on `queue`, frees the returned string, decodes the JSON.
    nonisolated private static func run<T: Decodable>(_ type: T.Type, _ body: @escaping @Sendable () -> UnsafeMutablePointer<CChar>?) async throws -> T {
        let text: String = await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
            queue.async { cont.resume(returning: take(body())) }
        }
        return try decode(T.self, text)
    }

    /// A call that returns at once (the transport); run where it is asked for.
    private static func now<T: Decodable>(_ type: T.Type, _ body: () -> UnsafeMutablePointer<CChar>?) throws -> T {
        try decode(T.self, take(body()))
    }

    nonisolated private static func take(_ p: UnsafeMutablePointer<CChar>?) -> String {
        guard let p else { return "{\"error\":\"Spotify gave no answer\"}" }
        let s = String(cString: p)
        harbor_string_free(p)
        return s
    }

    nonisolated private static func decode<T: Decodable>(_ type: T.Type, _ text: String) throws -> T {
        let data = Data(text.utf8)
        if let e = try? JSONDecoder().decode(ErrorProbe.self, from: data), let message = e.error { throw Failure(message: message) }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private struct OK: Decodable { var ok: Bool? }
    private struct ConnectRequest: Encodable {
        var cacheDir: String
        var deviceId: String
        var accessToken: String?
        var credentials: String?
    }

    private static var cacheDir: String {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent("spotify", isDirectory: true).path
    }

    // MARK: session

    /// mod.rs initialize: sign in with the saved reusable credentials. Concurrent callers share one
    /// attempt; a failed one (offline, sign-in rejected) may be tried again by the next caller.
    func restoreIfNeeded() async {
        if connected { return }
        if let running = restoreTask { await running.value; return }
        // (bug pass 2) Offline, or a restore failed under a minute ago: don't wait on another one.
        guard NetworkStatus.shared.online else { return }
        if let failedAt = restoreFailedAt, Date().timeIntervalSince(failedAt) < Self.restoreRetryAfter { return }
        let task = Task { @MainActor in
            guard let saved: Restore = try? await HarborEngine.shared.call("music.spotifyRestore"), let credentials = saved.credentials else { return }
            let started = self.generation
            do {
                _ = try await self.establish(ConnectRequest(cacheDir: Self.cacheDir, deviceId: saved.deviceId, accessToken: nil, credentials: credentials))
            } catch {
                // A disconnect meanwhile is not a failed restore (it cleared the mark itself).
                if started == self.generation { self.restoreFailedAt = Date() }
            }
        }
        restoreTask = task
        restoreSerial += 1
        let serial = restoreSerial
        await task.value
        // Only clear our own attempt: a disconnect may have dropped it and a newer restore taken its place.
        if restoreSerial == serial { restoreTask = nil }
    }

    /// mod.rs connect_interactive, after the phone hand-off produced a token.
    func connect(_ granted: Granted) async throws -> Status {
        try await establish(ConnectRequest(cacheDir: Self.cacheDir, deviceId: granted.deviceId, accessToken: granted.accessToken, credentials: nil))
    }

    /// session::connect + player::start in Rust, then the engine keeps the credentials and checks
    /// the tier. A Free account is shut down again (session.rs FREE_ACCOUNT).
    private func establish(_ request: ConnectRequest) async throws -> Status {
        connecting = true
        defer { connecting = false }
        let started = generation
        let body = (try? JSONEncoder().encode(request)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let rust: RustStatus
        do {
            rust = try await Self.run(RustStatus.self) { harbor_spotify_connect(body) }
        } catch let failure as Failure {
            // mod.rs record_failure: the Sources row shows it; a saved sign-in is left alone.
            if started == generation {
                let _: Status? = try? await HarborEngine.shared.call("music.spotifyFailed", [failure.message])
                connected = false
            }
            throw failure
        }
        // A session is live in Rust from here on: any way out that doesn't end connected shuts it down.
        // After a disconnect (generation moved on) the engine's saved sign-in is forgotten again.
        do {
            try abandonIfStale(started)
            let token = try? await Self.run(SessionToken.self) { harbor_spotify_session_token() }
            try abandonIfStale(started)
            let status: Status = try await HarborEngine.shared.call("music.spotifySessionReady", [rust, token])
            if started != generation {
                // Disconnected while the engine was saving the sign-in: forget it again.
                let _: Status? = try? await HarborEngine.shared.call("music.spotifyDisconnect")
                throw Failure(message: "Spotify was disconnected")
            }
            if status.shutdown == true {
                _ = try? await Self.run(OK.self) { harbor_spotify_disconnect() }
            }
            connected = status.connected
            if status.connected { restoreFailedAt = nil }
            return status
        } catch {
            // A stale attempt leaves Rust alone: disconnect() queued its own shutdown behind this
            // connect on the serial queue, and a newer sign-in may own the session by now.
            let stale = started != generation
            if !stale { _ = try? await Self.run(OK.self) { harbor_spotify_disconnect() } }
            let message: String
            switch error {
            case let failure as Failure: message = failure.message
            case EngineError.js(let raw): message = MusicPlayer.cleanJSError(raw)
            default: message = error.localizedDescription
            }
            if !stale {
                let _: Status? = try? await HarborEngine.shared.call("music.spotifyFailed", [message])
                connected = false
            }
            throw Failure(message: message)
        }
    }

    private func abandonIfStale(_ started: Int) throws {
        if started != generation { throw Failure(message: "Spotify was disconnected") }
    }

    /// mod.rs disconnect: stop, shut the session down, forget the saved sign-in (the client id stays).
    func disconnect() async {
        // Marked first and forgotten by the engine before the session goes, so neither the event
        // clock (sessionLost) nor a restore can sign the session back in on the way out.
        connected = false
        restoreTask = nil
        restoreFailedAt = nil
        generation += 1
        output.stop()
        let _: Status? = try? await HarborEngine.shared.call("music.spotifyDisconnect")
        _ = try? await Self.run(OK.self) { harbor_spotify_disconnect() }
    }

    /// Spotify dropped the session while playing: record it and sign in again once from the saved
    /// credentials (upstream's account.connected() goes false the same way).
    func sessionLost() {
        guard connected else { return }
        connected = false
        restoreTask = nil
        restoreFailedAt = nil
        Task {
            let _: Status? = try? await HarborEngine.shared.call("music.spotifyFailed", ["Spotify session connection failed: the session closed"])
            await restoreIfNeeded()
        }
    }

    // MARK: transport (control.rs)

    /// control.rs play: one track from the start at the music volume (0...1, the soft mixer).
    func play(uri: String, volume: Double) throws {
        activateSession()
        output.start()
        _ = try Self.now(OK.self) { harbor_spotify_play(uri, volume) }
    }

    /// control.rs set_volume: librespot's soft mixer scales what it decodes from now on; the ring
    /// already holds up to half a second at the old level, so the change is heard within that.
    /// Without a session this is a no-op (the next play() passes the level).
    func setVolume(_ volume: Double) {
        _ = try? Self.now(OK.self) { harbor_spotify_set_volume(volume) }
    }

    /// A pause drops the buffered audio in Rust (set_paused), so the output has nothing left to
    /// play: it stops shortly after instead of rendering silence, and starts again on resume.
    func setPaused(_ paused: Bool) {
        if !paused {
            activateSession()
            output.start()
        }
        _ = try? Self.now(OK.self) { harbor_spotify_pause(paused) }
        if paused { output.stopSoon() }
    }

    /// Nothing is playing on Spotify (the player paused itself, or the queue ended on a Spotify
    /// track): the output stops once any tail has been heard; play() or a resume starts it again.
    func idle() {
        output.stopSoon()
    }

    /// music-spotify-destination.tsx dispatches harbor:spotify-library-changed after a write.
    func libraryChanged() {
        libraryVersion += 1
    }

    func seek(to seconds: Double) {
        _ = try? Self.now(OK.self) { harbor_spotify_seek(seconds) }
    }

    /// Another source takes over (or the player closes). The output stops once the tail is heard.
    func stop() {
        _ = try? Self.now(OK.self) { harbor_spotify_stop() }
        output.stopSoon()
    }

    /// The queued player events since the last call.
    func drainEvents() -> Events {
        (try? Self.now(Events.self) { harbor_spotify_events() }) ?? Events(events: [], connected: connected)
    }

    private func activateSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default)
        try? session.setActive(true)
    }
}

/// AVAudioEngine + AVAudioSourceNode pulling 44.1 kHz stereo float PCM from the Rust ring
/// (`harbor_spotify_pcm_read`, real-time safe). The mixer converts to the output rate. The audio
/// session is shared with AVPlayer, mpv and the UI sounds, so it is never deactivated here.
@MainActor
final class SpotifyAudioOutput {
    private let engine = AVAudioEngine()
    private var source: AVAudioSourceNode?
    private var observers: [NSObjectProtocol] = []
    /// Whether the output should be running (a Spotify track is loaded).
    private var wanted = false
    private var stopTicket = 0

    func start() {
        wanted = true
        stopTicket += 1
        if source == nil { build() }
        guard !engine.isRunning else { return }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            NSLog("[spotify] audio output did not start: \(error.localizedDescription)")
        }
    }

    func stop() {
        wanted = false
        stopTicket += 1
        if engine.isRunning { engine.stop() }
    }

    /// Stops after the buffered tail (at most half a second) has played, unless Spotify starts again.
    func stopSoon() {
        wanted = false
        stopTicket += 1
        let ticket = stopTicket
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            guard ticket == self.stopTicket, !self.wanted else { return }
            if self.engine.isRunning { self.engine.stop() }
        }
    }

    /// Built outside the main actor so the render block carries no actor isolation: it runs on
    /// the real-time audio thread and only calls into the lock-free ring. The standard format is
    /// de-interleaved float32, one buffer per channel.
    nonisolated private static func makeSource(_ format: AVAudioFormat) -> AVAudioSourceNode {
        AVAudioSourceNode(format: format) { @Sendable (_, _, frameCount, audioBufferList) -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard buffers.count >= 2,
                  let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let right = buffers[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            _ = harbor_spotify_pcm_read(left, right, Int(frameCount))
            return noErr
        }
    }

    /// The ring's format: 44.1 kHz stereo, de-interleaved float32.
    private static var ringFormat: AVAudioFormat? {
        AVAudioFormat(standardFormatWithSampleRate: Double(HARBOR_SPOTIFY_SAMPLE_RATE), channels: 2)
    }

    private func build() {
        guard let format = Self.ringFormat else { return }
        let node = Self.makeSource(format)
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        source = node
        let center = NotificationCenter.default
        // A route change (HDMI, AirPlay) stops the engine; start it again if Spotify is playing.
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { @Sendable [weak self] _ in
            Task { @MainActor in self?.configurationChanged() }
        })
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { @Sendable [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            guard raw.flatMap(AVAudioSession.InterruptionType.init(rawValue:)) == .ended else { return }
            Task { @MainActor in self?.resume() }
        })
    }

    /// (bug pass 2) AVAudioEngineConfigurationChange: the output's sample rate or channel count
    /// changed (HDMI to AirPlay, a receiver switching modes). The engine has stopped and uninitialized
    /// and keeps the old connection formats ("the app must reestablish connections if the connection
    /// formats need to change"): the mixer goes back on the output in the new hardware format, the
    /// source back on the mixer in the ring's fixed 44.1 kHz stereo (the mixer converts between
    /// them), then the engine starts again if Spotify is playing.
    private func configurationChanged() {
        if let node = source, let format = Self.ringFormat {
            if engine.isRunning { engine.stop() }
            let hardware = engine.outputNode.outputFormat(forBus: 0)
            if hardware.sampleRate > 0, hardware.channelCount > 0 {
                engine.connect(engine.mainMixerNode, to: engine.outputNode, format: hardware)
            }
            engine.disconnectNodeOutput(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
        }
        resume()
    }

    private func resume() {
        guard wanted, !engine.isRunning else { return }
        // An interruption deactivates the session; it must be active again before the engine starts.
        try? AVAudioSession.sharedInstance().setActive(true)
        engine.prepare()
        do { try engine.start() } catch { NSLog("Spotify audio engine: %@", String(describing: error)) }
    }
}
