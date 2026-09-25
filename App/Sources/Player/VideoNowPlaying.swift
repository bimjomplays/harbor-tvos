import MediaPlayer
import UIKit

/// lib/media-session.ts on the TV: while a film, episode or channel plays, Now Playing shows it
/// (updateMediaControls: title, subtitle, art, duration, position, playing) and the system's media
/// commands drive it (use-keyboard-shortcuts.ts harbor://media-key / media-seek-relative /
/// media-seek-absolute). MusicPlayer owns Now Playing the rest of the time: while
/// PlaybackState.active its commands stand down and it writes no info, and when the player closes
/// (clearMediaControls) it writes its own track back.
///
/// One claim at a time: each PlayerScreen begins with its own id and only that id can update or
/// end it, so a player closing late never clears the next one's.
@MainActor
final class VideoNowPlaying {
    static let shared = VideoNowPlaying()

    /// What the commands call on the player that owns Now Playing.
    struct Actions {
        var isPlaying: () -> Bool
        var toggle: () -> Void
        var seekStep: (Double) -> Void
        var seekTo: (Double) -> Void
        var next: (() -> Void)?
        var previous: (() -> Void)?
    }

    private var owner: UUID?
    private var actions: Actions?
    private var installed = false
    // media-session.ts: write only when the metadata changed or the position drifted.
    private var lastState = ""
    private var lastPositionSec: Double?
    private var lastPositionAt = Date.distantPast
    private var lastPlaying = false
    private var lastInfo: [String: Any] = [:]
    private var artworkFor: String?
    private var artwork: MPMediaItemArtwork?
    private var lastActionAt = Date.distantPast
    /// (bug pass 2) Runs right after end() clears Now Playing: MusicPlayer writes its track back
    /// if nothing holds playback any more, whichever order end() and PlaybackState.release run in.
    var onEnded: (@MainActor () -> Void)?

    /// media-session.ts mediaKeyGate: one media action per 350 ms. The remote's own Play/Pause
    /// goes through it too, so a press that also arrives as a remote command toggles once.
    func mediaKeyGate() -> Bool {
        let now = Date()
        if now.timeIntervalSince(lastActionAt) < 0.35 { return false }
        lastActionAt = now
        return true
    }

    func begin(_ id: UUID, actions: Actions, seekBack: Double, seekForward: Double) {
        install()
        if owner != id {
            lastState = ""
            lastPositionSec = nil
            lastInfo = [:]
        }
        owner = id
        self.actions = actions
        let c = MPRemoteCommandCenter.shared()
        c.skipBackwardCommand.preferredIntervals = [NSNumber(value: seekBack)]
        c.skipForwardCommand.preferredIntervals = [NSNumber(value: seekForward)]
        c.skipBackwardCommand.isEnabled = true
        c.skipForwardCommand.isEnabled = true
        c.stopCommand.isEnabled = true
        c.changePlaybackPositionCommand.isEnabled = true
    }

    /// media-session.ts updateMediaControls.
    func update(_ id: UUID, playing: Bool, title: String, subtitle: String?, artURL: String?,
                durationSec: Double, positionSec: Double, rate: Double, isLive: Bool) {
        guard owner == id else { return }
        let dur = durationSec.isFinite && durationSec > 0 ? durationSec.rounded() : 0
        let pos: Double? = positionSec.isFinite && positionSec >= 0 ? positionSec : nil
        let now = Date()
        let state = "\(playing ? 1 : 0)|\(title)|\(subtitle ?? "")|\(artURL ?? "")|\(Int(dur))|\(rate)"
        let metadataChanged = state != lastState
        var drift = false
        if let pos {
            if lastPositionSec == nil || playing != lastPlaying {
                drift = true
            } else if let last = lastPositionSec {
                if playing {
                    let expected = last + now.timeIntervalSince(lastPositionAt) * rate
                    drift = abs(pos - expected) > 1.2
                } else {
                    drift = abs(pos - last) > 0.5
                }
            }
        }
        guard metadataChanged || drift else { return }
        lastState = state
        lastPlaying = playing
        if let pos {
            lastPositionSec = pos
            lastPositionAt = now
        }

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
            MPNowPlayingInfoPropertyPlaybackRate: playing ? rate : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyIsLiveStream: isLive,
        ]
        if let subtitle, !subtitle.isEmpty { info[MPMediaItemPropertyArtist] = subtitle }
        if dur > 0, !isLive { info[MPMediaItemPropertyPlaybackDuration] = dur }
        if let pos, !isLive { info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = pos }
        if let art = artwork, artworkFor == artURL { info[MPMediaItemPropertyArtwork] = art }
        lastInfo = info
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        loadArtwork(artURL, for: id)
    }

    /// media-session.ts clearMediaControls: the player closed; Now Playing goes back to music.
    func end(_ id: UUID) {
        guard owner == id else { return }
        owner = nil
        actions = nil
        lastState = ""
        lastPositionSec = nil
        lastInfo = [:]
        let c = MPRemoteCommandCenter.shared()
        // Music has no skip or stop controls; next/previous and scrubbing stay for it.
        c.skipBackwardCommand.isEnabled = false
        c.skipForwardCommand.isEnabled = false
        c.stopCommand.isEnabled = false
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        onEnded?()
    }

    private func loadArtwork(_ raw: String?, for id: UUID) {
        guard let raw, !raw.isEmpty, artworkFor != raw, let url = URL(string: raw) else { return }
        artworkFor = raw
        artwork = nil
        Task {
            guard let image = await ImageLoader.shared.image(for: url), self.artworkFor == raw, self.owner == id else { return }
            let art = MusicPlayer.makeArtwork(image)
            self.artwork = art
            guard !self.lastInfo.isEmpty else { return }
            self.lastInfo[MPMediaItemPropertyArtwork] = art
            MPNowPlayingInfoCenter.default().nowPlayingInfo = self.lastInfo
        }
    }

    /// use-keyboard-shortcuts.ts media-key handling, once for the app. Every handler hops to the
    /// main actor and only acts while a player holds the claim (MusicPlayer's do the reverse).
    private func install() {
        guard !installed else { return }
        installed = true
        let c = MPRemoteCommandCenter.shared()
        func on(_ command: MPRemoteCommand, _ run: @escaping @MainActor @Sendable (VideoNowPlaying, Actions) -> Void) {
            _ = command.addTarget { @Sendable [weak self] _ in
                guard let self else { return .commandFailed }
                Task { @MainActor in
                    guard self.owner != nil, let a = self.actions else { return }
                    run(self, a)
                }
                return .success
            }
        }
        // "playpause" / "play" (only when paused) / "pause" and "stop" (only when playing).
        on(c.togglePlayPauseCommand) { s, a in if s.mediaKeyGate() { a.toggle() } }
        on(c.playCommand) { s, a in if !a.isPlaying(), s.mediaKeyGate() { a.toggle() } }
        on(c.pauseCommand) { s, a in if a.isPlaying(), s.mediaKeyGate() { a.toggle() } }
        on(c.stopCommand) { s, a in if a.isPlaying(), s.mediaKeyGate() { a.toggle() } }
        // "next" / "previous": the episode after or before, when there is one.
        on(c.nextTrackCommand) { s, a in if let go = a.next, s.mediaKeyGate() { go() } }
        on(c.previousTrackCommand) { s, a in if let go = a.previous, s.mediaKeyGate() { go() } }
        // harbor://media-seek-relative and media-seek-absolute.
        _ = c.skipForwardCommand.addTarget { @Sendable [weak self] event in
            guard let self, let e = event as? MPSkipIntervalCommandEvent else { return .commandFailed }
            let step = e.interval
            Task { @MainActor in if self.owner != nil, let a = self.actions { a.seekStep(step) } }
            return .success
        }
        _ = c.skipBackwardCommand.addTarget { @Sendable [weak self] event in
            guard let self, let e = event as? MPSkipIntervalCommandEvent else { return .commandFailed }
            let step = e.interval
            Task { @MainActor in if self.owner != nil, let a = self.actions { a.seekStep(-step) } }
            return .success
        }
        _ = c.changePlaybackPositionCommand.addTarget { @Sendable [weak self] event in
            guard let self, let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let at = e.positionTime
            Task { @MainActor in if self.owner != nil, let a = self.actions { a.seekTo(at) } }
            return .success
        }
        c.skipBackwardCommand.isEnabled = false
        c.skipForwardCommand.isEnabled = false
        c.stopCommand.isEnabled = false
    }
}
