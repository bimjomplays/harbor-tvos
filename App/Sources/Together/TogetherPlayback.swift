import Foundation
import Combine
import UIKit

/// The player's side of Watch Together: views/player/hooks/use-room-sync.ts, use-lobby-gate.ts
/// and the guest/host control rules of use-playback-controls.ts, ported to the TV player.
///
/// PlayerScreen owns one of these and talks to it through five calls only:
///   playerOpened()                      the player's first appearance (a pending reopen went through)
///   tick(controller:context:url:rate:)  every second (heartbeat, lobby, readiness, initial sync)
///   interceptToggle(controller)         Play/Pause; true when the room handled it
///   interceptSeek(to:controller)        a committed seek; true when the room handled it
///   closing(reopening:)                 the player is leaving (use-player-exit.ts)
/// Incoming room state and commands arrive through TogetherModel's publishers; the room's speed
/// goes back to the player through `onRoomRate`.
@MainActor
final class TogetherPlayback: ObservableObject {
    // views/player/player-utils.ts
    static let driftToleranceS = 0.6
    static let suppressMs = 1400.0
    static let playLookaheadS = 0.4
    static let maxAgeS = 30.0
    static let seekJumpS = 10.0
    static let heartbeatS = 1.0
    static let seekApplyDebounceMs = 120
    static let guestEscapeS = 45.0

    struct ForeignNotice: Equatable { var title: String?; var from: String }

    @Published private(set) var hasStarted = false
    @Published var foreignNotice: ForeignNotice?
    @Published private(set) var guestEscapeReady = false
    @Published private(set) var inSession = false

    private let room = TogetherModel.shared
    private weak var controller: (any PlayerEngineControlling)?
    private var context: PlaybackContext?
    private var url: URL?
    private var bag = Set<AnyCancellable>()
    private var bound = false

    private var syncCatchUp = false
    private var lastAppliedStateAt: Double = 0
    private var seekSeq: [String: Double] = [:]
    private var pendingSeek: Double?
    private var seekApply: Task<Void, Never>?
    private var selfFrameReady = false
    private var lobbySeeded = false
    private var initialSyncDone = false
    private var lastHeartbeat = Date.distantPast
    private var guestWaitingSince: Date?
    private var source: AnyJSON?
    private var sourceAsked = false
    private var openedSent = false
    private var lastInRoom: Bool?
    /// The player's playback speed (snap.rate upstream), published with every state.
    private var rate: Double = 1
    /// The last spot the picture reached (duration and position both known). (review 5) mpv reports
    /// 0 / 0 once its stream has died, so a host's "Switch source" from the error card held the room
    /// at 0:00 and every guest jumped back to the start.
    private var lastPosition: Double = 0
    /// use-room-sync `b.setRate(state.speed)`: the player applies the room's speed (its own `rate`
    /// state and the engine), without remembering it for the show.
    var onRoomRate: ((Double) -> Void)?

    var inRoom: Bool { room.view.inRoom }
    var isHost: Bool { room.view.isHost }
    /// player.tsx canControl: in a room nobody drives the video until it has started.
    var canControl: Bool { !inRoom || hasStarted }
    /// player.tsx showWaiting: the lobby card.
    var showWaiting: Bool { inRoom && !hasStarted }
    var hostName: String? { room.view.participants.first(where: { $0.host })?.name }
    /// The draw/cursor path of this player (lib/view.tsx syncFrameKey).
    var framePath: String? {
        guard let c = context else { return nil }
        if let s = c.season, let e = c.episode { return "player:\(c.meta.id):\(s):\(e)" }
        return "player:\(c.meta.id)"
    }

    private func episodeJSON() -> AnyJSON {
        guard let c = context, let s = c.season, let e = c.episode else { return .null }
        return .object(["season": .number(Double(s)), "episode": .number(Double(e))])
    }

    private func metaJSON() -> AnyJSON {
        guard let m = context?.meta else { return .null }
        var o: [String: AnyJSON] = ["id": .string(m.id), "type": .string(m.type), "name": .string(m.name)]
        if let p = m.poster { o["poster"] = .string(p) }
        if let b = m.background { o["background"] = .string(b) }
        if let l = m.logo { o["logo"] = .string(l) }
        if let r = m.releaseInfo { o["releaseInfo"] = .string(r) }
        return .object(o)
    }

    // MARK: PlayerScreen hooks

    func tick(controller c: (any PlayerEngineControlling)?, context ctx: PlaybackContext?, url u: URL, rate r: Double = 1) {
        // The player's "Room" chip follows this (published at most once a second, not per room event).
        let session = room.view.inSession
        if session != inSession { inSession = session }
        guard let c, let ctx else { return }
        if !bound { bind(c, ctx, u) }
        // (Together pass) The player's current engine: a reload (Try again, the dropped-connection
        // reload, the move to mpv) makes a new controller, and incoming room state and a guest's
        // commands went to the old one (weak, so usually nil): after any reload a guest stopped
        // following the host and a host ignored its guests. use-room-sync reads bridgeRef.current.
        if controller !== c { controller = c }
        rate = r
        let snap = c.snapshot()
        if snap.duration > 0, snap.position > 0 { lastPosition = snap.position }
        let playing = !snap.paused
        let view = room.view

        // (bug pass) use-room-sync resets readiness and the initial sync on [mediaKey, inRoom]:
        // markReady(false), selfFrameReady = false, initialSyncDone = false. Kept for good here, a
        // TV that left a room and joined another from the player's Room panel never said "ready"
        // (the new host's lobby waited on it) and, as a guest, never jumped to the host's position.
        if inRoom != lastInRoom {
            if lastInRoom != nil {
                selfFrameReady = false
                initialSyncDone = false
                // A picture that is already up says "ready" just below; two queued calls could
                // reach the engine out of order, so only the one that applies is sent.
                if !(inRoom && c.videoWidth() > 0 && snap.duration > 0) { room.call("markReady", [.bool(false)]) }
            }
            lastInRoom = inRoom
        }

        // use-room-sync: ready once the first frame and a duration exist; not ready on a new title.
        if inRoom, !selfFrameReady, c.videoWidth() > 0, snap.duration > 0 {
            selfFrameReady = true
            room.call("markReady", [.bool(true)])
        }
        if snap.duration > 0, !sourceAsked { askSource(c, duration: snap.duration) }

        // Lobby (use-room-sync lobby effects): hold at the host's paused spot until the room starts.
        if inRoom, !hasStarted, !view.started {
            if !isHost, let seed = view.syncState, !isDifferentMedia(seed), !seed.playing,
               let hostId = view.hostClientId, seed.updatedBy == hostId, abs(snap.position - seed.positionSeconds) > 1.5 {
                c.seek(to: seed.positionSeconds)
            }
            if playing { c.setPaused(true) }
        }
        // The host seeds the lobby once with its paused position.
        if inRoom, isHost, !hasStarted, !lobbySeeded, snap.duration > 0 {
            lobbySeeded = true
            publish(position: snap.position, playing: false)
        }
        // A guest starts when the room does.
        if inRoom, !isHost, !hasStarted, view.started { hasStarted = true }
        // use-lobby-gate: a host who already started makes sure the room knows.
        if inRoom, isHost, hasStarted, !view.started { room.call("startRoom") }
        // use-lobby-gate guestEscapeReady: after 45 s a guest may play without the room.
        if inRoom, !isHost, !hasStarted {
            let since = guestWaitingSince ?? Date()
            guestWaitingSince = since
            let ready = Date().timeIntervalSince(since) >= Self.guestEscapeS
            if ready != guestEscapeReady { guestEscapeReady = ready }
        } else {
            guestWaitingSince = nil
            if guestEscapeReady { guestEscapeReady = false }
        }
        // Initial guest sync (use-room-sync): jump to the host's live position and play.
        // (Together pass) Not while Harbor is in the background (it waits for the return).
        if inRoom, !isHost, hasStarted, !initialSyncDone, let state = view.syncState, !isDifferentMedia(state), !backgrounded(c) {
            initialSyncDone = true
            room.call("suppressOutgoingFor", [.number(Self.suppressMs)])
            if let sp = state.speed { applyRoomRate(sp) }
            c.seek(to: target(for: state, duration: snap.duration))
            c.setPaused(false)
        }
        // Host heartbeat (HOST_HEARTBEAT_MS): the room follows this TV.
        if inRoom, isHost, hasStarted, snap.duration > 0, snap.position > 0,
           Date().timeIntervalSince(lastHeartbeat) >= Self.heartbeatS - 0.05 {
            lastHeartbeat = Date()
            publish(position: snap.position, playing: playing)
        }
    }

    /// use-playback-controls playPauseToggle. Returns true when the room took the press.
    func interceptToggle(_ c: (any PlayerEngineControlling)?) -> Bool {
        guard inRoom else { return false }
        if isHost, !hasStarted { startHost(c); return true }
        if !isHost, !hasStarted {
            // use-lobby-gate playWithoutSync, bound to Play once the guest escape shows.
            if guestEscapeReady { playWithoutSync(c) }
            return true
        }
        if !canControl { return true }
        if !isHost {
            let paused = c?.snapshot().paused ?? true
            room.sendCommand(paused ? .play : .pause)
            return true
        }
        return false
    }

    /// use-playback-controls seekStep / seekTo. Returns true when the room took the seek.
    func interceptSeek(to target: Double, controller c: (any PlayerEngineControlling)?) -> Bool {
        guard inRoom else { return false }
        if !canControl { return true }
        if !isHost {
            room.sendCommand(.seek(max(0, target), seq: nil))
            return true
        }
        return false
    }

    /// use-player-exit.ts closePlayer: a host leaving clears the room's media and says so.
    /// (Together pass) Not when the player closes to open another episode or source from the picker:
    /// upstream's goToEpisode / stream switch open the picker over the player and never run
    /// closePlayer. The relay hands the host role to a guest on "host-leaving", so the TV host's
    /// next episode opened under a foreign host (no invite for anyone, the host itself waiting in
    /// the lobby) and every guest saw "{name} left the video" on each episode change.
    func closing(reopening: Bool = false) {
        seekApply?.cancel()
        bag.removeAll()
        // Opening the next episode or another source keeps the room (and the host role), but the
        // guests should not play on unseen while the host picks: the room holds at this spot.
        if inRoom, isHost, reopening {
            var at = lastPosition
            if let s = controller?.snapshot(), s.duration > 0, s.position > 0 { at = s.position }
            publish(position: at, playing: false)
        }
        if inRoom, isHost, !reopening { room.hostLeaving() }
        // A picker that then closes with no pick still tells the room the host left (abandonReopen).
        room.setReopenPending(reopening)
        room.call("setLocation", [.null])
    }

    /// A player opened (its first appearance): a reopen that was pending went through.
    func playerOpened() {
        room.setReopenPending(false)
    }

    // MARK: lobby (use-lobby-gate.ts)

    private func startHost(_ c: (any PlayerEngineControlling)?) {
        hasStarted = true
        room.call("startRoom")
        room.call("suppressOutgoingFor", [.number(0)])
        c?.setPaused(false)
    }

    private func playWithoutSync(_ c: (any PlayerEngineControlling)?) {
        initialSyncDone = true
        hasStarted = true
        c?.setPaused(false)
    }

    // MARK: sync

    private func bind(_ c: any PlayerEngineControlling, _ ctx: PlaybackContext, _ u: URL) {
        bound = true
        controller = c
        context = ctx
        url = u
        room.call("markReady", [.bool(false)])
        // App.tsx TogetherLocationPublisher: this TV is in the player.
        var loc: [String: AnyJSON] = ["kind": .string("player"), "meta": metaJSON()]
        if case .object = episodeJSON() { loc["episode"] = episodeJSON() }
        room.call("setLocation", [.object(loc)])
        room.incomingState
            .sink { [weak self] s in self?.applyIncoming(s) }
            .store(in: &bag)
        room.incomingCommand
            .sink { [weak self] cmd in self?.applyCommand(from: cmd.from, cmd.command) }
            .store(in: &bag)
    }

    /// use-host-source.ts / source-descriptor.ts: what the host is playing, so guests can match it.
    private func askSource(_ c: any PlayerEngineControlling, duration: Double) {
        sourceAsked = true
        var ref: [String: AnyJSON] = [:]
        if let name = c.streamFilename(), !name.isEmpty { ref["title"] = .string(name) }
        if let u = url, let t = TorrentEngine.streamRef(u) {
            ref["infoHash"] = .string(t.infoHash)
            ref["fileIdx"] = .number(Double(t.fileIdx))
        }
        let meta = metaJSON()
        let ep = episodeJSON()
        Task {
            // use-room-invite.ts: in a room with no other host, playing a title invites the room.
            if !openedSent {
                openedSent = true
                struct Opened: Decodable { var invited: Bool; var source: AnyJSON? }
                if let o: Opened = try? await HarborEngine.shared.call("together.playerOpened", [meta, ep, AnyJSON.object(ref), duration]) {
                    source = o.source
                    // (bug pass) use-host-source.ts: in the lobby the host re-seeds the room whenever its
                    // source descriptor arrives. The one lobby seed usually went out before this answer,
                    // so guests had no source to match until the host pressed play.
                    if let s = o.source, !s.isNull, inRoom, isHost, !hasStarted, lobbySeeded, let ctl = controller {
                        publish(position: ctl.snapshot().position, playing: false)
                    }
                }
            }
        }
    }

    private func publish(position: Double, playing: Bool) {
        guard let ctx = context else { return }
        var state: [String: AnyJSON] = [
            "mediaId": .string(ctx.meta.id),
            "mediaTitle": .string(ctx.meta.name),
            "episode": episodeJSON(),
            "posterUrl": ctx.meta.poster.map { .string($0) } ?? .null,
            "positionSeconds": .number(position),
            "playing": .bool(playing),
            // (Together pass) use-room-sync publishes snap.rate: a host at 1.5x told the room 1x,
            // and every guest drifted and was re-seeked every couple of seconds.
            "speed": .number(rate),
        ]
        if let s = source, !s.isNull { state["source"] = s }
        if room.view.guestsPick { state["guestPick"] = .bool(true) }
        room.publish(.object(state))
    }

    /// use-room-sync isDifferentMedia.
    private func isDifferentMedia(_ s: TogetherModel.SyncState) -> Bool {
        guard let id = s.mediaId, let ctx = context else { return false }
        if id != ctx.meta.id { return true }
        let local: (Int, Int)? = ctx.season.flatMap { se in ctx.episode.map { (se, $0) } }
        if (s.episode != nil) != (local != nil) { return true }
        if let se = s.episode, let le = local, se.season != le.0 || se.episode != le.1 { return true }
        return false
    }

    private func target(for s: TogetherModel.SyncState, duration: Double) -> Double {
        let ageS = min(Self.maxAgeS, max(0, (Date().timeIntervalSince1970 * 1000 - s.updatedAt) / 1000))
        var t = s.playing ? s.positionSeconds + ageS + Self.playLookaheadS : s.positionSeconds
        if duration > 0 { t = min(t, max(0, duration - 0.25)) }
        return t
    }

    /// (Together pass) Harbor is in the background with no Picture in Picture: the player paused
    /// itself on leaving the app, and the host's next heartbeat (every second) started the film
    /// again, sounding unseen behind the TV's Home screen (a host likewise obeyed a guest's play).
    /// The room is followed again from the first state after the viewer comes back.
    private func backgrounded(_ c: (any PlayerEngineControlling)?) -> Bool {
        UIApplication.shared.applicationState == .background && c?.isPictureInPictureActive != true
    }

    /// use-room-sync `if (state.speed != null && Math.abs(state.speed - rate) > 0.01) b.setRate(…)`,
    /// within the speeds the TV's players take (a 0 would stall AVPlayer).
    private func applyRoomRate(_ speed: Double) {
        guard speed.isFinite, speed >= 0.25, speed <= 4, abs(speed - rate) > 0.01 else { return }
        rate = speed
        onRoomRate?(speed)
    }

    /// use-room-sync onIncomingState.
    private func applyIncoming(_ s: TogetherModel.SyncState) {
        guard inRoom, let c = controller else { return }
        if s.updatedBy == room.view.clientId { return }
        if backgrounded(c) { return }
        if isDifferentMedia(s) { foreignNotice = ForeignNotice(title: s.mediaTitle, from: s.updatedBy); return }
        guard s.mediaId != nil else { return }
        if s.updatedAt < lastAppliedStateAt { return }
        lastAppliedStateAt = s.updatedAt
        if let sp = s.speed { applyRoomRate(sp) }
        let snap = c.snapshot()
        let playing = !snap.paused
        let livePos = snap.position
        let t = target(for: s, duration: snap.duration)
        let drift = abs(livePos - t)
        let playStateChanged = s.playing != playing
        let driftTooBig = drift > Self.driftToleranceS
        if syncCatchUp {
            if drift < Self.seekJumpS {
                let buffered = c.bufferedSec()
                let nearEof = snap.duration > 0 && livePos + buffered >= snap.duration - 0.5
                if !playing || (buffered < 2.0 && !nearEof) {
                    if s.playing != playing { c.setPaused(!s.playing) }
                    return
                }
            }
            syncCatchUp = false
        }
        if !playStateChanged && !driftTooBig { return }
        c.seek(to: t)
        if driftTooBig { syncCatchUp = true }
        if s.playing && !playing { c.setPaused(false) }
        if !s.playing && playing { c.setPaused(true) }
    }

    /// use-room-sync onIncomingCommand: the host applies a guest's request (seeks debounced 120 ms).
    private func applyCommand(from: String, _ command: TogetherModel.RoomCommand) {
        guard inRoom, isHost, let c = controller, !backgrounded(c) else { return }
        switch command {
        case .play:
            flushPendingSeek()
            c.setPaused(false)
        case .pause:
            flushPendingSeek()
            c.setPaused(true)
        case .seek(let pos, let seq):
            if let seq {
                if let last = seekSeq[from], seq <= last { return }
                seekSeq[from] = seq
            }
            pendingSeek = pos
            seekApply?.cancel()
            seekApply = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(Self.seekApplyDebounceMs))
                guard let self, !Task.isCancelled else { return }
                self.flushPendingSeek()
            }
        }
    }

    private func flushPendingSeek() {
        seekApply?.cancel()
        seekApply = nil
        guard let pos = pendingSeek, let c = controller else { pendingSeek = nil; return }
        pendingSeek = nil
        guard inRoom, isHost else { return }
        let d = c.snapshot().duration
        guard d > 0 else { return }
        c.seek(to: max(0, min(pos, d - 1)))
    }
}
