import AVFoundation
import Combine
import MediaPlayer
import SwiftUI
import UIKit

/// lib/music/player.ts on the TV: the queue, the phase machine and source recovery, playing
/// through AVQueuePlayer instead of upstream's mpv music engine. The engine (engine/music.ts)
/// matches catalog tracks to a source and resolves stream URLs; this class plays them.
///
/// - Gapless: the next queue entry is resolved ~30 s before the current one ends and queued
///   behind it in the AVQueuePlayer, so it starts without a gap (mpv's prefetch, music/audio.rs).
/// - Background: the app declares the `audio` background mode (project.yml), so music keeps
///   playing on the Apple TV home screen, as upstream's keeps playing with its window hidden.
/// - Now Playing + remote commands: MPNowPlayingInfoCenter / MPRemoteCommandCenter
///   (upstream's updateMediaSession + the OS media keys).
/// - Scrobbles: music/engine.rs counts the seconds actually heard and, when a track that passed
///   should_scrobble ends (EndFile or natural EOF), calls scrobble_track (Navidrome + Last.fm).
/// - Track radio: radio.ts armTrackRadio keeps a started radio topped up near its end.
/// - Spotify: commands/playback.rs music_play_track sends a Spotify track to the librespot session
///   (SpotifyPlayback) instead of the stream engine, stopping whichever engine is not playing.
///   Position, pause and end come from its events; the queue, scrobbles and Now Playing stay here.
@MainActor
final class MusicPlayer: ObservableObject {
    static let shared = MusicPlayer()

    /// types.ts MusicPlaybackPhase
    enum Phase: String { case idle, resolving, playing, paused, error }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var current: MusicTrack?
    @Published private(set) var queue: [MusicTrack] = []
    @Published private(set) var index = -1
    /// Position and length live in `clock`, so the twice-a-second tick only redraws the views
    /// that show time, not every shelf that observes the player.
    private(set) var position: Double = 0 { didSet { if clock.position != position { clock.position = position } } }
    private(set) var duration: Double = 0 { didSet { if clock.duration != duration { clock.duration = duration } } }
    let clock = MusicClock()
    @Published private(set) var error: String?
    @Published private(set) var likedIds: Set<String> = []
    /// Bumps whenever liked tracks or recents change, so the room can re-read its shelves.
    @Published private(set) var libraryVersion = 0

    private let player = AVQueuePlayer()
    /// music/mod.rs ACTIVE_STREAM / ACTIVE_SPOTIFY: which engine the current entry plays on.
    private enum Engine { case none, stream, spotify }
    private var engine: Engine = .none
    private let spotify = SpotifyPlayback.shared
    /// The Spotify entry playing (its queue index); nil while nothing is bound to its events.
    private var spotifyEntry: (track: MusicTrack, index: Int)?
    private var spotifyClock: Timer?
    /// Ticks in a row with nothing playing on Spotify and no events: after two seconds of that the
    /// clock stops (and the output with it) until the next play or resume.
    private var spotifyIdleTicks = 0
    /// player.ts playRequest: a newer play() makes every older async step a no-op.
    private var request = 0
    /// Items in the AVQueuePlayer and the queue entry each one plays.
    private var items: [ObjectIdentifier: (track: MusicTrack, index: Int)] = [:]
    private var preloading: Int?
    /// "request:index" of the last preload attempt, so a failed one is not retried every tick.
    private var preloadAttempt: String?
    private var observations: [NSKeyValueObservation] = []
    private var itemObservations: [ObjectIdentifier: NSKeyValueObservation] = [:]
    private var notes: [NSObjectProtocol] = []
    private var timeObserver: Any?
    private var bag = Set<AnyCancellable>()
    private var commandsReady = false
    /// (bug pass 2) PlaybackState.active as its sink last delivered it. @Published calls the sink
    /// before the value lands, so reading PlaybackState.shared.active there still gives the old one.
    private var videoHoldsNowPlaying = false
    private var artworkFor: String?
    private var artwork: MPMediaItemArtwork?
    /// Keys of sources that failed for the entry now playing (player.ts failedAttempts).
    private var failed: [String] = []
    /// player.ts skipUnavailable: an automatic advance skips a track no source can play.
    private var skipUnavailable = false
    /// The source of the last track that started (player.ts workingSource).
    private var lastSource: String?

    /// engine.rs event loop: the entry being listened to, when it started (unix seconds), the
    /// seconds actually heard (time-pos steps of at most 2 s, so seeks do not count).
    private var scrobbleTrack: MusicTrack?
    private var scrobbleStartedAt = 0
    private var listened: Double = 0
    private var lastTick: Double?

    /// music-track-grid.tsx radioStatus: a station being built, or why it could not be.
    enum RadioStatus: Equatable { case loading, failed(String) }
    @Published private(set) var radioStatus: RadioStatus?
    private var radioRequest = 0
    /// radio.ts armed: the queue came from Start radio and is extended near its end.
    private var radioArmed = false
    private var radioExtending = false
    private var radioGeneration = 0

    /// player.ts state.volume: the music's own level, 0...1 (upstream's VOLUME_KEY, 0.82 until the
    /// viewer changes it). Both engines follow it; the TV's volume stays with the remote.
    @Published private(set) var volume: Double = 0.82
    /// music-dock.tsx audibleVolume: the level Unmute goes back to.
    private var audibleVolume: Double = 0.82
    private static let volumeKey = "harbor.music.volume.v1"

    private init() {
        volume = Self.readVolume()
        if volume > 0 { audibleVolume = volume }
        player.volume = Self.streamGain(volume)
        player.actionAtItemEnd = .advance
        // Every callback below is @Sendable (never actor-isolated) and hops to the main actor.
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { @Sendable [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.tick() }
        }
        observations.append(player.observe(\.currentItem, options: [.new]) { @Sendable [weak self] _, _ in
            guard let self else { return }
            Task { @MainActor in self.currentItemChanged() }
        })
        observations.append(player.observe(\.timeControlStatus, options: [.new]) { @Sendable [weak self] _, _ in
            guard let self else { return }
            Task { @MainActor in self.refreshPhase() }
        })
        let center = NotificationCenter.default
        notes.append(center.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: nil, queue: .main) { @Sendable [weak self] note in
            guard let self, let item = note.object as? AVPlayerItem else { return }
            let err = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? NSError
            Task { @MainActor in self.itemFailed(item, err?.localizedDescription) }
        })
        notes.append(center.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { @Sendable [weak self] note in
            guard let self, let item = note.object as? AVPlayerItem else { return }
            Task { @MainActor in self.itemEnded(item) }
        })
        // A film or channel starting takes the TV's audio: the music pauses (player.ts stopCastOwner).
        // Now Playing belongs to the video player meanwhile (VideoNowPlaying); when it closes the
        // music's own track goes back up (media-session.ts clearMediaControls).
        // (bug pass 2) Handled synchronously with the delivered value: the write-back used to wait
        // for a Task and read PlaybackState.active itself, so whether it landed after the video's
        // clear depended on the order the player happened to call end() and release() in. Now the
        // release writes the track here, and VideoNowPlaying.end calls back (onEnded) after it clears.
        PlaybackState.shared.$active
            .removeDuplicates()
            .sink { [weak self] video in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.videoHoldsNowPlaying = video
                    // The pause keeps its hop (it publishes phase; claim() runs from a view's onAppear).
                    if video { Task { @MainActor in self.pauseForVideo() } } else { self.refreshNowPlaying() }
                }
            }
            .store(in: &bag)
        VideoNowPlaying.shared.onEnded = { [weak self] in self?.refreshNowPlaying() }
        Task { await reloadLibrary() }
    }

    // MARK: - library (liked / recents)

    func reloadLibrary() async {
        if let lib: MusicLibraryState = try? await HarborEngine.shared.call("music.library") {
            likedIds = Set(lib.likedIds)
        }
    }

    /// liked.ts isMusicLiked
    func isLiked(_ track: MusicTrack?) -> Bool {
        guard let track else { return false }
        return track.likedIds.contains { likedIds.contains($0) }
    }

    /// player.ts toggleMusicLiked
    func toggleLiked(_ track: MusicTrack? = nil) {
        guard let track = track ?? current else { return }
        let liked = !isLiked(track)
        Task {
            if let lib: MusicLibraryState = try? await HarborEngine.shared.call("music.setLiked", [track, liked]) {
                likedIds = Set(lib.likedIds)
                libraryVersion += 1
                refreshNowPlaying()
            }
        }
    }

    // MARK: - transport

    /// player.ts playMusic(track, queue): the queue is replaced and `track` starts.
    func play(_ track: MusicTrack, queue list: [MusicTrack]? = nil) {
        disarmRadio()
        // A radio error belongs to the last attempt; playing something else clears it.
        if radioStatus != .some(.loading) { radioStatus = nil }
        var q = list ?? [track]
        if !q.contains(where: { $0.queueKey == track.queueKey }) { q.insert(track, at: 0) }
        let at = q.firstIndex { $0.queueKey == track.queueKey } ?? 0
        queue = q
        // A new queue has no tracks added with Add to queue (they only line up within one queue).
        manuallyQueued = []
        failed = []
        skipUnavailable = false
        start(at: at)
    }

    /// Queue a track to play after the current one (music-track-menu "Play next").
    func playNext(_ track: MusicTrack) {
        guard current != nil, index >= 0 else { play(track); return }
        // Already coming up: it moves forward (music-queue.tsx playNext) rather than playing twice.
        if let at = queue.indices.first(where: { $0 > index && queue[$0].queueKey == track.queueKey }) {
            playQueuedNext(at: at)
            return
        }
        queue.insert(track, at: min(index + 1, queue.count))
        dropPreloaded()
    }

    /// queue-insert.ts `manual`: queue keys added with Add to queue, so the next one lines up behind them.
    private var manuallyQueued: Set<String> = []

    /// player.ts enqueueMusic: "Queues after what is playing, ahead of the rest of the collection"
    /// (queue-insert.ts queueInsertIndex: behind the tracks already added this way); a track that
    /// is already in the queue is left where it is (insertIntoQueue).
    /// (device-flow pass) It was appended after the whole album or playlist, so a song added while
    /// track 2 of 12 played only came after track 12.
    func enqueue(_ track: MusicTrack) {
        guard current != nil else { play(track); return }
        guard !queue.contains(where: { $0.queueKey == track.queueKey }) else { return }
        var at = max(0, index + 1)
        while at < queue.count, manuallyQueued.contains(queue[at].queueKey) { at += 1 }
        manuallyQueued.insert(track.queueKey)
        queue.insert(track, at: at)
        dropPreloaded()
    }

    /// music-queue.tsx move(from, to): an upcoming entry moves within the upcoming part only.
    func move(from: Int, to: Int) {
        let first = max(0, index + 1)
        guard from != to, from >= first, to >= first, queue.indices.contains(from), queue.indices.contains(to) else { return }
        let track = queue.remove(at: from)
        queue.insert(track, at: to)
        // The entry after the current one may have changed: a preloaded item would play the old one.
        dropPreloaded()
    }

    /// music-queue.tsx playNext(index): an upcoming entry moves to right after the current one.
    func playQueuedNext(at i: Int) {
        move(from: i, to: max(0, index + 1))
    }

    /// music-detail.tsx isCurrent: a row is the one playing when it is the current track or the
    /// catalog entry that track was matched from (collectionOrigin). (device-flow pass) Comparing
    /// queue keys alone lost the mark on album, shelf and search rows the moment a source was found.
    func isCurrent(_ track: MusicTrack?) -> Bool {
        guard let track, let current else { return false }
        if current.id == track.id, current.connectorId == track.connectorId { return true }
        if let origin = current.collectionOrigin, origin.id == track.id, origin.connectorId == track.connectorId { return true }
        return false
    }

    func toggle() {
        switch phase {
        case .playing:
            if engine == .spotify { spotify.setPaused(true); phase = .paused } else { player.pause() }
        case .paused:
            if engine == .spotify {
                // After the queue ran out the Spotify track has ended: play the entry again.
                guard spotifyEntry != nil else { if index >= 0 { failed = []; start(at: index) }; return }
                spotify.setPaused(false)
                startSpotifyClock()
                phase = .playing
            } else if player.currentItem == nil {
                // (bug pass) The queue ran out on a stream: AVQueuePlayer dropped the finished item
                // (.advance), so play() alone would do nothing. Play the entry again, as player.ts
                // does after an automatic end (enginePrimed = false → playMusic(current)).
                if index >= 0 { failed = []; start(at: index) }
                return
            } else {
                activateSession()
                player.play()
            }
        case .error: if index >= 0 { failed = []; start(at: index) }
        default: break
        }
        refreshPhase()
        refreshNowPlaying()
    }

    /// (bug pass) media-session.ts mediaKeyGate, as VideoNowPlaying has it: one Play/Pause per
    /// 350 ms. With music the Now Playing app, one remote press can arrive both as the focused
    /// view's onPlayPauseCommand and as MPRemoteCommandCenter's toggle, which toggled twice (no-op).
    private var lastMediaKeyAt = Date.distantPast
    private func mediaKeyGate() -> Bool {
        let now = Date()
        if now.timeIntervalSince(lastMediaKeyAt) < 0.35 { return false }
        lastMediaKeyAt = now
        return true
    }

    /// The remote's Play/Pause (a music screen's onPlayPauseCommand), through the gate above.
    /// (device-flow pass) While a film holds the TV (PlaybackState: Music opened from the Picture in
    /// Picture browse layer) the press is the film's, as the remote commands below already defer:
    /// the Music room's handler shadowed the layer's own and started the paused music over the film.
    func remoteToggle() {
        guard mediaKeyGate() else { return }
        if PlaybackState.shared.active {
            if PiPBrowse.shared.filmInPiP { PiPBrowse.shared.togglePlayback() }
            return
        }
        toggle()
    }

    func pause() {
        guard phase == .playing else { return }
        if engine == .spotify { spotify.setPaused(true); phase = .paused; refreshNowPlaying() } else { player.pause(); refreshPhase() }
    }

    /// player.ts nextMusic
    func next(auto: Bool = false) {
        guard current != nil else { return }
        if !auto { skipUnavailable = false }
        if index + 1 < queue.count {
            failed = []
            skipUnavailable = auto
            start(at: index + 1)
        } else {
            player.pause()
            if engine == .spotify { spotify.setPaused(true) }
            if auto { position = duration }
            phase = .paused
            refreshNowPlaying()
        }
    }

    /// player.ts previousMusic: past 5 s the track restarts, else the previous entry plays.
    func previous() {
        if position > 5 || index <= 0 { seek(to: 0); return }
        failed = []
        start(at: index - 1)
    }

    func seek(to seconds: Double) {
        let target = max(0, duration > 0 ? min(seconds, duration) : seconds)
        if engine == .spotify {
            spotify.seek(to: target)
            // A seek is a jump, not listening (engine.rs listened_increment).
            lastTick = target
        } else {
            player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        }
        position = target
        refreshNowPlaying()
    }

    func skip(by delta: Double) { seek(to: position + delta) }

    /// Jump to a queue entry (the queue sheet).
    func jump(to i: Int) {
        guard queue.indices.contains(i) else { return }
        failed = []
        skipUnavailable = false
        start(at: i)
    }

    func remove(at i: Int) {
        guard queue.indices.contains(i), i != index else { return }
        if i == 0 { disarmRadio() }
        queue.remove(at: i)
        if i < index {
            index -= 1
            // (bug pass) The playing item and the Spotify binding move with their queue position:
            // a stale index sent recover() / itemEnded to the wrong entry (and stopped tick()).
            for (key, bound) in items where bound.index > i { items[key] = (bound.track, bound.index - 1) }
            if let bound = spotifyEntry, bound.index > i { spotifyEntry = (bound.track, bound.index - 1) }
        }
        dropPreloaded()
    }

    /// player.ts closeMusicPlayer
    func close() {
        finishScrobble()
        disarmRadio()
        request += 1
        player.pause()
        clearItems()
        releaseSpotify()
        engine = .none
        current = nil
        queue = []
        manuallyQueued = []
        index = -1
        position = 0
        duration = 0
        error = nil
        phase = .idle
        Task { let _: AnyJSON? = try? await HarborEngine.shared.callJSON("music.stopped") }
        // A playing video owns Now Playing (VideoNowPlaying); only clear what is the music's.
        if !PlaybackState.shared.active { MPNowPlayingInfoCenter.default().nowPlayingInfo = nil }
        // The session stays active: mpv, AVPlayer and the UI sounds (BPSound) share it and never
        // reactivate it themselves (review 19).
    }

    /// The rest of the queue, for the home's "Up next" shelf.
    var upcoming: [MusicTrack] { index >= 0 && index + 1 < queue.count ? Array(queue[(index + 1)...]) : [] }

    // MARK: - loading

    private func start(at i: Int) {
        guard queue.indices.contains(i) else { return }
        // mpv's EndFile for whatever was playing: it scrobbles if it was heard long enough.
        finishScrobble()
        request += 1
        let ticket = request
        let entry = queue[i]
        index = i
        current = entry
        position = 0
        duration = entry.seconds
        error = nil
        phase = .resolving
        player.pause()
        clearItems()
        // A Spotify track being skipped is silenced at once; after its natural end this is a
        // no-op and the next Spotify track follows its tail (control.rs / player.rs gapless).
        if engine == .spotify { spotify.setPaused(true) }
        spotifyEntry = nil
        installCommands()
        refreshNowPlaying()
        Task { await self.load(entry, at: i, ticket: ticket) }
    }

    private func load(_ entry: MusicTrack, at i: Int, ticket: Int) async {
        do {
            // mod.rs initialize: a saved Spotify sign-in is restored before a Spotify entry plays.
            if entry.connectorId == "spotify" { await spotify.restoreIfNeeded() }
            let prepared = try await prepare(entry, excluding: failed)
            guard ticket == request else { return }
            let track = prepared.track
            failed = prepared.failed
            // player.ts: the substituted source replaces the catalog entry in the queue.
            if queue.indices.contains(i) { queue[i] = track }
            current = track
            if track.seconds > 0 { duration = track.seconds }
            if Self.isSpotify(prepared) {
                // The session can be gone by now: the entry then tries its other sources.
                do { try playSpotify(prepared, at: i) } catch { recover(track, at: i, error.localizedDescription) }
                return
            }
            // music_play_track: the stream engine takes over from Spotify.
            if engine == .spotify { releaseSpotify() }
            engine = .stream
            guard let item = makeItem(prepared) else { throw MusicPlaybackError.message("music.error.playback") }
            items[ObjectIdentifier(item)] = (track, i)
            watch(item)
            player.insert(item, after: nil)
            if PlaybackState.shared.active {
                // A film or channel took the TV while this resolved (pauseForVideo only sees a
                // track that is already playing): queue it paused instead of sounding over it.
                phase = .paused
            } else {
                activateSession()
                player.play()
                phase = .playing
            }
            lastSource = track.connectorId
            beginScrobble(track)
            addRecent(track)
            refreshNowPlaying()
            extendRadioIfDue()
        } catch {
            guard ticket == request else { return }
            fail(error.localizedDescription)
        }
    }

    /// player.ts: a catalog entry prefers the source that is already playing (workingSource).
    /// `preload`: resolved ahead for the gapless hand-off; its server play report waits for
    /// music.started (bug pass 2).
    private func prepare(_ track: MusicTrack, excluding: [String], preload: Bool = false) async throws -> MusicPrepared {
        do {
            return try await HarborEngine.shared.call("music.prepare", [track, excluding, lastSource, preload])
        } catch EngineError.js(let message) {
            throw MusicPlaybackError.message(Self.cleanJSError(message))
        }
    }

    /// "Error: No matching source…" and stack lines stripped to the sentence the viewer reads.
    static func cleanJSError(_ raw: String) -> String {
        let first = raw.split(separator: "\n").first.map(String.init) ?? raw
        return first.replacingOccurrences(of: "Error: ", with: "")
    }

    private func makeItem(_ prepared: MusicPrepared) -> AVPlayerItem? {
        guard !Self.isSpotify(prepared), let url = URL(string: prepared.stream.url) else { return nil }
        var options: [String: Any] = [:]
        if let headers = prepared.stream.httpHeaders, !headers.isEmpty { options["AVURLAssetHTTPHeaderFieldsKey"] = headers }
        let item = AVPlayerItem(asset: AVURLAsset(url: url, options: options))
        // Music needs no big buffer ahead; this keeps gapless preloads light.
        item.preferredForwardBufferDuration = 20
        return item
    }

    private func watch(_ item: AVPlayerItem) {
        itemObservations[ObjectIdentifier(item)] = item.observe(\.status, options: [.new]) { @Sendable [weak self] observed, _ in
            guard let self else { return }
            let failedNow = observed.status == .failed
            let message = observed.error?.localizedDescription
            Task { @MainActor in if failedNow { self.itemFailed(observed, message) } else { self.itemReady(observed) } }
        }
    }

    /// An item left the AVQueuePlayer: stop tracking it.
    private func forget(_ item: AVPlayerItem) {
        let key = ObjectIdentifier(item)
        items[key] = nil
        itemObservations.removeValue(forKey: key)?.invalidate()
    }

    private func clearItems() {
        player.removeAllItems()
        items = [:]
        itemObservations.values.forEach { $0.invalidate() }
        itemObservations = [:]
        preloading = nil
    }

    private func itemReady(_ item: AVPlayerItem) {
        guard item === player.currentItem else { return }
        let d = item.duration.seconds
        if d.isFinite, d > 0 { duration = d }
        refreshNowPlaying()
    }

    /// player.ts recoverPlayback: a source that fails mid-load is swapped for the next match.
    private func itemFailed(_ item: AVPlayerItem, _ message: String?) {
        guard let entry = items[ObjectIdentifier(item)] else { return }
        forget(item)
        if item !== player.currentItem {
            // A gapless preload that failed: drop it; the entry resolves again when it is reached.
            player.remove(item)
            return
        }
        recover(entry.track, at: entry.index, message)
    }

    /// player.ts recoverPlayback for the entry now playing, whichever engine failed it.
    private func recover(_ track: MusicTrack, at index: Int, _ message: String?) {
        // (bug pass 2) engine.rs scrobbles on any EndFile, the error one included: what was heard of
        // the failed stream counts before the retry starts its own listen. The retry plays from the
        // start, as upstream's recoverPlayback → playMusic does (currentTime: 0; resumeAt is only
        // set by a resume after restart, never by recovery), so the clock goes back to 0:00 too.
        finishScrobble()
        position = 0
        failed.append(track.queueKey)
        guard failed.count < 3 else { fail(message ?? "music.error.playback"); return }
        // Retry the original queue entry with every failed source excluded.
        let original = queue.indices.contains(index) ? queue[index] : track
        let origin = original.collectionOrigin
        let retry = origin.map { o in MusicTrack(id: o.id, title: original.title, artist: original.artist, album: original.album, artwork: original.artwork, durationSeconds: original.durationSeconds, durationLabel: original.durationLabel, connectorId: o.connectorId) } ?? original
        if queue.indices.contains(index) { queue[index] = retry }
        request += 1
        let ticket = request
        phase = .resolving
        clearItems()
        spotifyEntry = nil
        Task { await self.load(retry, at: index, ticket: ticket) }
    }

    private func fail(_ message: String) {
        let text = message.hasPrefix("music.") ? MusicCopy.shared(message, "This source couldn’t play the song. Try another source.") : message
        // player.ts skipUnavailableTrack: during an automatic advance a dead track is skipped.
        if skipUnavailable, index + 1 < queue.count {
            failed = []
            start(at: index + 1)
            return
        }
        error = text
        phase = .error
        refreshNowPlaying()
    }

    private func itemEnded(_ item: AVPlayerItem) {
        guard let entry = items[ObjectIdentifier(item)] else { return }
        forget(item)
        // engine.rs natural EOF: the finished entry scrobbles now, before anything else starts.
        if scrobbleTrack?.queueKey == entry.track.queueKey { finishScrobble() }
        // With a preloaded successor the AVQueuePlayer has already moved on (currentItemChanged).
        if items.values.contains(where: { $0.index == entry.index + 1 }) { return }
        next(auto: true)
    }

    /// The AVQueuePlayer advanced into a preloaded item: that entry is now current.
    private func currentItemChanged() {
        guard let item = player.currentItem, let entry = items[ObjectIdentifier(item)], entry.index != index else { return }
        finishScrobble()
        index = entry.index
        current = entry.track
        failed = []
        position = 0
        duration = entry.track.seconds
        beginScrobble(entry.track)
        addRecent(entry.track)
        // (bug pass 2) The preloaded track is heard from now: Jellyfin / Navidrome hear about it now,
        // not when it was resolved ~30 s early (upstream reports as it starts a track).
        let heardTrack = entry.track
        Task { let _: AnyJSON? = try? await HarborEngine.shared.call("music.started", [heardTrack]) }
        refreshNowPlaying()
        extendRadioIfDue()
    }

    /// Resolve the next entry late in the current one and queue it behind (gapless).
    private func preloadNextIfDue() {
        guard engine == .stream, phase == .playing, preloading == nil, duration > 0, duration - position < 30 else { return }
        let n = index + 1
        let attempt = "\(request):\(n)"
        guard queue.indices.contains(n), preloadAttempt != attempt, !items.values.contains(where: { $0.index == n }) else { return }
        preloadAttempt = attempt
        preloading = n
        let ticket = request
        let entry = queue[n]
        Task {
            defer { if self.preloading == n { self.preloading = nil } }
            let prepared = try? await self.prepare(entry, excluding: [], preload: true)
            // A Spotify entry cannot join the AVQueuePlayer; it starts through librespot when reached.
            guard ticket == self.request, let prepared, !Self.isSpotify(prepared), let current = self.player.currentItem, self.queue.indices.contains(n),
                  self.queue[n].queueKey == entry.queueKey, let item = self.makeItem(prepared) else { return }
            guard self.player.canInsert(item, after: current) else { return }
            self.queue[n] = prepared.track
            self.items[ObjectIdentifier(item)] = (prepared.track, n)
            self.watch(item)
            self.player.insert(item, after: current)
        }
    }

    /// The queue changed under a preloaded item: take it back out.
    private func dropPreloaded() {
        for item in player.items() where item !== player.currentItem {
            forget(item)
            player.remove(item)
        }
        preloading = nil
        preloadAttempt = nil
    }

    private func tick() {
        // (bug pass) Only the item bound to the entry now shown: after a gapless hand-off the
        // AVQueuePlayer is already on the next item before currentItemChanged runs, and reading it
        // here put the next track's length on this one (Now Playing, and the scrobble threshold
        // finishScrobble computes from `duration`: a heard 3-minute song followed by a 10-minute
        // one could miss its scrobble).
        guard current != nil, let item = player.currentItem, items[ObjectIdentifier(item)]?.index == index else { return }
        let t = player.currentTime().seconds
        if t.isFinite { heard(at: t) }
        let d = item.duration.seconds
        if d.isFinite, d > 0 { duration = d }
        preloadNextIfDue()
    }

    /// The position moved to `t`. engine.rs listened_increment: forward steps of at most 2 s
    /// count as heard.
    private func heard(at t: Double) {
        position = max(0, t)
        if let previous = lastTick, scrobbleTrack != nil {
            let delta = t - previous
            if delta > 0, delta <= 2 { listened += delta }
        }
        lastTick = t
    }

    private func refreshPhase() {
        // Spotify's phase comes from its own events (spotifyTick).
        guard engine != .spotify, current != nil, phase != .resolving, phase != .error else { return }
        switch player.timeControlStatus {
        case .playing, .waitingToPlayAtSpecifiedRate: phase = .playing
        case .paused: phase = .paused
        @unknown default: break
        }
        refreshNowPlaying()
    }

    private func pauseForVideo() {
        if phase == .playing { pause() }
    }

    private func addRecent(_ track: MusicTrack) {
        Task {
            let _: MusicLibraryState? = try? await HarborEngine.shared.call("music.addRecent", [track])
            libraryVersion += 1
        }
    }

    private func activateSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default)
        try? session.setActive(true)
    }

    // MARK: - volume (player.ts setMusicVolume, music-dock.tsx mute / slider)

    /// player.ts readVolume
    private static func readVolume() -> Double {
        // A viewer who listened before the level existed heard both engines at full: they keep it
        // rather than a sudden drop to upstream's 0.82 (about -5 dB streams, -11 dB Spotify) (review 37).
        // One-shot: the first read stores the level either way, so a new listener's own history
        // (recents written by their first play) can't lift them to 1.0 on the next launch (review 38).
        if KeyValueStore.shared.get(volumeKey) == nil {
            let listenedBefore = KeyValueStore.shared.get("harbor.music.recents.v1") != nil || KeyValueStore.shared.get("harbor.music.liked.v1") != nil
            let level = listenedBefore ? 1.0 : 0.82
            try? KeyValueStore.shared.set(String(level), for: volumeKey)
            return level
        }
        let parsed = Double(KeyValueStore.shared.get(volumeKey) ?? "0.82") ?? .nan
        return parsed.isFinite ? max(0, min(1, parsed)) : 0.82
    }

    /// player.ts setMusicVolume: clamped (musicVolumeCeiling is 1: the TV has no volume boost),
    /// remembered, and applied (music_engine_set_volume). Both engines get it, so whichever plays
    /// next starts at this level too (music_play_track passes state.volume).
    func setVolume(_ value: Double) {
        let next = value.isFinite ? max(0, min(1, value)) : 0.82
        try? KeyValueStore.shared.set(String(next), for: Self.volumeKey)
        volume = next
        if next > 0 { audibleVolume = next }
        player.volume = Self.streamGain(next)
        spotify.setVolume(next)
    }

    /// The remote's step: music-dock.tsx's wheel moves 5 % a notch (kept to whole percents).
    func stepVolume(by delta: Double) {
        setVolume(((volume + delta) * 100).rounded() / 100)
    }

    /// music-dock.tsx mute button: to 0, or back to the last audible level.
    func toggleMute() {
        setVolume(volume > 0 ? 0 : audibleVolume)
    }

    /// engine.rs set_volume hands mpv `volume * 100`, and mpv scales its volume cubically
    /// (player/audio.c audio_update_volume). AVPlayer's volume is a linear gain, so the cube keeps
    /// upstream's curve for the stream engine. Spotify takes the 0...1 value as upstream's mixer does.
    nonisolated static func streamGain(_ volume: Double) -> Float {
        let v = volume.isFinite ? max(0, min(1, volume)) : 0.82
        return Float(v * v * v)
    }

    // MARK: - Spotify (music/spotify through SpotifyPlayback)

    /// engine/music.ts prepare() hands back the Spotify URI with this marker instead of a URL.
    private static func isSpotify(_ prepared: MusicPrepared) -> Bool {
        prepared.stream.mimeType == SpotifyPlayback.streamMime || (prepared.track.connectorId == "spotify" && prepared.stream.url.hasPrefix("spotify:"))
    }

    /// music_play_track for a Spotify track: the stream engine stops, librespot loads the URI.
    private func playSpotify(_ prepared: MusicPrepared, at i: Int) throws {
        player.pause()
        clearItems()
        do {
            try spotify.play(uri: prepared.stream.url, volume: volume)
        } catch let failure as SpotifyPlayback.Failure {
            throw MusicPlaybackError.message(failure.message)
        }
        engine = .spotify
        spotifyEntry = (prepared.track, i)
        startSpotifyClock()
        if PlaybackState.shared.active {
            // A film or channel took the TV while this resolved: queued paused, as the stream path does.
            spotify.setPaused(true)
            phase = .paused
        } else {
            phase = .playing
        }
        lastSource = prepared.track.connectorId
        beginScrobble(prepared.track)
        addRecent(prepared.track)
        refreshNowPlaying()
        extendRadioIfDue()
    }

    /// Stops the librespot player and its event clock (another engine takes over, or close).
    private func releaseSpotify() {
        guard engine == .spotify else { return }
        spotify.stop()
        spotifyEntry = nil
        stopSpotifyClock()
    }

    private func startSpotifyClock() {
        spotifyIdleTicks = 0
        guard spotifyClock == nil else { return }
        // Upstream's player emits time-pos every 250 ms (position_update_interval).
        let timer = Timer(timeInterval: 0.25, repeats: true) { @Sendable [weak self] _ in
            Task { @MainActor in self?.spotifyTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        spotifyClock = timer
    }

    private func stopSpotifyClock() {
        spotifyClock?.invalidate()
        spotifyClock = nil
        spotifyIdleTicks = 0
    }

    /// player.rs spawn_events on this side: time-pos, pause, end-file (eof), player-failure.
    /// The clock runs while a Spotify entry is bound and playing; with no entry bound (the queue
    /// ended, or the next entry is resolving: play() clears Rust's events) it stops, and after two
    /// quiet seconds paused it stops too. A resume or the next play starts it again.
    private func spotifyTick() {
        let batch = spotify.drainEvents()
        guard engine == .spotify, let entry = spotifyEntry else { stopSpotifyClock(); return }
        for event in batch.events {
            switch event.event {
            case "playing":
                if let p = event.position { heard(at: p) }
                phase = .playing
                refreshNowPlaying()
            case "paused":
                if let p = event.position { heard(at: p) }
                if phase == .playing { phase = .paused }
                refreshNowPlaying()
            case "position":
                if let p = event.position { heard(at: p) }
            case "end":
                // engine.rs natural EOF: the finished entry scrobbles now, then the queue advances.
                spotifyEntry = nil
                if scrobbleTrack?.queueKey == entry.track.queueKey { finishScrobble() }
                next(auto: true)
                return
            case "failure":
                spotifyEntry = nil
                recover(entry.track, at: entry.index, event.reason ?? "Spotify track is unavailable")
                return
            default:
                break
            }
        }
        if !batch.connected {
            // Spotify dropped the session: this entry tries its other sources, the session comes back.
            spotifyEntry = nil
            spotify.sessionLost()
            recover(entry.track, at: entry.index, "Spotify session connection failed: the session closed")
            return
        }
        // Paused (by the viewer, a film, or the player itself) and quiet: the pause event has been
        // read by now, so stop polling and let the output go quiet until play resumes.
        if phase == .playing || !batch.events.isEmpty {
            spotifyIdleTicks = 0
        } else {
            spotifyIdleTicks += 1
            if spotifyIdleTicks >= 8 {
                stopSpotifyClock()
                spotify.idle()
            }
        }
    }

    // MARK: - scrobbles (music/engine.rs + commands/accounts.rs scrobble_track)

    /// engine.rs should_scrobble: half the track or four minutes, whichever comes first.
    nonisolated static func shouldScrobble(listened: Double, duration: Double) -> Bool {
        let threshold = duration.isFinite && duration > 0 ? min(duration * 0.5, 240) : 240
        return listened >= threshold
    }

    private func beginScrobble(_ track: MusicTrack) {
        scrobbleTrack = track
        scrobbleStartedAt = Int(Date().timeIntervalSince1970)
        listened = 0
        lastTick = nil
    }

    /// The listened entry ended (finished, skipped or stopped): scrobble it once if it counts.
    private func finishScrobble() {
        guard let track = scrobbleTrack else { return }
        scrobbleTrack = nil
        let heard = listened
        let length = duration > 0 ? duration : track.seconds
        listened = 0
        lastTick = nil
        guard Self.shouldScrobble(listened: heard, duration: length) else { return }
        let startedAt = scrobbleStartedAt
        Task {
            // Failures are only logged upstream (music://lastfm "error"); playback never waits.
            let _: MusicScrobbleResult? = try? await HarborEngine.shared.call("music.scrobble", [track, startedAt])
        }
    }

    // MARK: - track radio (radio.ts via engine/musicRadio.ts)

    /// music-track-grid.tsx startRadio: build the station, play it, arm the extension.
    func startRadio(_ track: MusicTrack) {
        radioRequest += 1
        let ticket = radioRequest
        radioStatus = .loading
        Task {
            do {
                let station: [MusicTrack] = try await HarborEngine.shared.call("music.radio", [track])
                guard ticket == radioRequest else { return }
                guard let first = station.first else { throw MusicPlaybackError.message("music.radio.error") }
                radioStatus = nil
                play(first, queue: station)
                radioArmed = true
                radioGeneration += 1
            } catch {
                guard ticket == radioRequest else { return }
                radioStatus = .failed(MusicCopy.shared("music.radio.error", "Couldn’t start radio. Try again or choose another source."))
            }
        }
    }

    private func disarmRadio() {
        radioArmed = false
        radioExtending = false
        radioGeneration += 1
    }

    /// radio.ts armTrackRadio: within EXTEND_AT (4) entries of the end, append more.
    private func extendRadioIfDue() {
        guard radioArmed, !radioExtending, index >= 0, index >= queue.count - 4 else { return }
        radioExtending = true
        let generation = radioGeneration
        let snapshot = queue
        let at = index
        Task {
            let more: [MusicTrack]? = try? await HarborEngine.shared.call("music.radioExtend", [snapshot, at])
            guard generation == radioGeneration, radioArmed else { return }
            radioExtending = false
            let known = Set(queue.map(\.queueKey))
            let fresh = (more ?? []).filter { !known.contains($0.queueKey) }
            if !fresh.isEmpty { queue.append(contentsOf: fresh) }
        }
    }

    // MARK: - Now Playing + remote commands

    private func installCommands() {
        guard !commandsReady else { return }
        commandsReady = true
        let c = MPRemoteCommandCenter.shared()
        // Films and channels drive their own player; these only act on music.
        func owned(_ run: @escaping @MainActor @Sendable (MusicPlayer) -> Void) -> (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
            return { @Sendable [weak self] _ in
                guard let self else { return .commandFailed }
                Task { @MainActor in
                    guard self.current != nil, !PlaybackState.shared.active else { return }
                    run(self)
                }
                return .success
            }
        }
        // (bug pass) Play/Pause share the media-key gate with the screens' onPlayPauseCommand.
        _ = c.playCommand.addTarget(handler: owned { if $0.phase != .playing, $0.mediaKeyGate() { $0.toggle() } })
        _ = c.pauseCommand.addTarget(handler: owned { if $0.phase == .playing, $0.mediaKeyGate() { $0.pause() } })
        _ = c.togglePlayPauseCommand.addTarget(handler: owned { if $0.mediaKeyGate() { $0.toggle() } })
        _ = c.nextTrackCommand.addTarget(handler: owned { $0.next() })
        _ = c.previousTrackCommand.addTarget(handler: owned { $0.previous() })
        _ = c.changePlaybackPositionCommand.addTarget { @Sendable [weak self] event in
            guard let self, let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let at = e.positionTime
            Task { @MainActor in if self.current != nil, !PlaybackState.shared.active { self.seek(to: at) } }
            return .success
        }
    }

    private func refreshNowPlaying() {
        // While a film or channel plays, VideoNowPlaying holds Now Playing; the sink above writes
        // the music back once it closes. (bug pass 2) The sink's own value, not PlaybackState's:
        // inside the release it still reads true.
        guard let t = current, !videoHoldsNowPlaying else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: t.title,
            MPMediaItemPropertyArtist: t.artist,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyPlaybackRate: phase == .playing ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        if let album = t.album { info[MPMediaItemPropertyAlbumTitle] = album }
        if let art = artwork, artworkFor == t.artwork { info[MPMediaItemPropertyArtwork] = art }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        loadArtwork(for: t)
    }

    private func loadArtwork(for t: MusicTrack) {
        guard let raw = t.artwork, !raw.isEmpty, artworkFor != raw, let url = URL(string: raw) else { return }
        artworkFor = raw
        artwork = nil
        Task {
            guard let image = await ImageLoader.shared.image(for: url), self.artworkFor == raw else { return }
            self.artwork = Self.makeArtwork(image)
            self.refreshNowPlaying()
        }
    }
}

/// The playing position, published on its own (see MusicPlayer.clock).
@MainActor
final class MusicClock: ObservableObject {
    @Published var position: Double = 0
    @Published var duration: Double = 0
}

extension MusicPlayer {
    /// Built outside the main actor: the system asks for the image on a background queue.
    nonisolated static func makeArtwork(_ image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { @Sendable _ in image }
    }
}

enum MusicPlaybackError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let m) = self { return m }; return nil }
}
