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
///   sourceSwitched(url:ref:at:)         a stream swapped in place (use-stream-switcher, P8)
///   sourceFailed()                      that stream would not open (the source error card)
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
    /// (P8) use-host-source.ts: the stream swapped in place (its PlayerStreamRef, when the switcher
    /// knew it), when, and a count that drops an older descriptor answer landing after a swap.
    private var switchRef: AnyJSON?
    private var switchedAt = Date.distantPast
    private var sourceGen = 0
    /// (review 22 follow-up) The spot a started host's swap in place holds the room at, and whether
    /// the room was playing before it; cleared once the new stream plays (the heartbeat publishes)
    /// or the hold is let go (sourceFailed, closing).
    private var swapHold: (at: Double, playing: Bool)?
    private var openedSent = false
    private var lastInRoom: Bool?
    /// The player's playback speed (snap.rate upstream), published with every state.
    private var rate: Double = 1
    /// The last spot the picture reached (duration and position both known). (review 5) mpv reports
    /// 0 / 0 once its stream has died, so a host's "Switch source" from the error card held the room
    /// at 0:00 and every guest jumped back to the start.
    private var lastPosition: Double = 0
    /// The position the previous tick read (the host heartbeat's stall check).
    private var lastTickPosition: Double = -1
    private var lastTickPlaying = false
    /// The invite to this very video that was already dropped (tick).
    private var droppedInviteAt: Double?
    /// Since when the room has listed this TV as not ready while its picture is up (tick).
    private var notReadySince: Date?
    /// (review 9) Ready re-sends since the room last listed this TV as ready (capped).
    private var readyResends = 0
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
        // (together pass 2) use-room-sync's heartbeat publishes only while the status is "playing" or
        // "paused". The TV's snapshot has no buffering state, so a host whose stream stalled told the
        // room "playing" at a frozen spot every second, and every guest (ahead by then) was sent back
        // once a second until the host's stream recovered. Playing on two ticks without moving is a
        // stall: no heartbeat for it (a press of Play just before a tick still goes out).
        let stalled: Bool = playing && lastTickPlaying && abs(snap.position - lastTickPosition) < 0.05
        lastTickPosition = snap.position
        lastTickPlaying = playing

        // (together pass 2) An invite to the video this player already shows: the relay repeats the
        // host's invite to everyone whenever someone joins, and sends the room's media as an invite on
        // every reconnect (a dropped network, the TV back from sleep). Under the player the toast
        // waited, then auto-joined 4 s after this player closed and opened the same film again.
        if let inv = view.incomingInvite, inv.at != droppedInviteAt, view.inSession, showsInvited(inv.invite) {
            droppedInviteAt = inv.at
            room.dismiss("invite")
        }

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
        // (P8) use-host-source URL_CHANGE_DURATION_GUARD_MS: a length read in the first 1.5 s after
        // a swap in place is not the new file's yet.
        if snap.duration > 0, !sourceAsked, Date().timeIntervalSince(switchedAt) >= 1.5 { askSource(c, duration: snap.duration) }
        // (together pass 2) The relay marks everyone not ready when a host claims the room afresh
        // (engine playerOpened: a host's source switch or reopen of the same title, and the TV host's
        // own claim, which can land after its own "ready"). Upstream's guest reloads on the re-invite
        // and says ready again; a TV guest keeps its picture, so the host's lobby read "still loading"
        // for good. A picture that is up for the room's video says so again after 2 s.
        let roomOnOtherMedia: Bool = view.syncState.map { isDifferentMedia($0) } ?? false
        let selfListedReady: Bool = view.participants.first(where: { $0.isSelf })?.ready ?? true
        // (review 9) A host moving on to the next episode claims the room afresh (everyone not
        // ready) and invites to it, but the room's state names this TV's episode until the host's
        // new player loads and publishes: the re-send said "ready" for an episode this TV had not
        // opened, and the host's lobby read everyone as loaded. An invite elsewhere waits.
        let invitedElsewhere: Bool = !isHost && (view.incomingInvite.map { !showsInvited($0.invite) } ?? false)
        if selfListedReady { readyResends = 0 }
        // (review 9) Capped: a relay that never lists the TV as ready again got one every 2 s for good.
        if inRoom, selfFrameReady, !selfListedReady, !roomOnOtherMedia, !invitedElsewhere, readyResends < 3 {
            let since = notReadySince ?? Date()
            notReadySince = since
            if Date().timeIntervalSince(since) >= 2 {
                notReadySince = nil
                readyResends += 1
                room.call("markReady", [.bool(true)])
            }
        } else {
            notReadySince = nil
        }

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
        if inRoom, isHost, hasStarted, snap.duration > 0, snap.position > 0, !stalled,
           Date().timeIntervalSince(lastHeartbeat) >= Self.heartbeatS - 0.05 {
            lastHeartbeat = Date()
            swapHold = nil
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
        swapHold = nil
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

    /// (P8) use-stream-switcher onSwitchStream + use-host-source.ts: the player swapped its stream in
    /// place (bp-player-sources, the kid switcher, a home-server quality). Nothing closes, so the
    /// room, the host role and the guests' session stay as they are: no host-leaving, no reopen.
    /// The source descriptor follows the new stream: at once from its ref (no length yet, as
    /// upstream's liveStreamRef descriptor), and again with the new file's length once it has one
    /// (askSource, past the 1.5 s guard). A started host holds the room at the swap spot while the
    /// new stream opens (the heartbeat stops until it plays), as the reopening close does, rather
    /// than leave the guests playing on unseen and pull them back when it resumes; a host still in
    /// the lobby seeds it again from the new stream.
    func sourceSwitched(url u: URL, ref: AnyJSON?, at: Double) {
        url = u
        switchRef = ref
        switchedAt = Date()
        sourceAsked = false
        sourceGen += 1
        let gen: Int = sourceGen
        guard inRoom, isHost else {
            if let ref { describe(ref, duration: nil, gen: gen) }
            return
        }
        if hasStarted {
            // The room's play state before this swap (the host's last heartbeat), for sourceFailed.
            let wasPlaying: Bool = swapHold?.playing ?? room.view.syncState?.playing ?? lastTickPlaying
            swapHold = (at, wasPlaying)
            publish(position: at, playing: false)
        } else {
            lobbySeeded = false
        }
        if let ref { describe(ref, duration: nil, gen: gen) }
    }

    /// (review 22 follow-up) The stream a started host swapped in place would not open. Upstream
    /// never holds the room for a swap (use-stream-switcher loads the new stream; use-room-sync's
    /// heartbeat only goes quiet while the host's status is not playing or paused), so its guests
    /// play on while the host sits on the source error card. The TV's hold is let go here: the room
    /// plays again from the spot it held, when it was playing before the swap. The host's next
    /// stream (Try again, another source) holds it again or pulls the guests back with its heartbeat.
    func sourceFailed() {
        guard let hold = swapHold else { return }
        swapHold = nil
        guard inRoom, isHost, hasStarted, hold.playing else { return }
        publish(position: hold.at, playing: true)
    }

    /// source-descriptor.ts buildSourceDescriptor through the engine (together.sourceDescriptor);
    /// only the newest swap's answer lands.
    private func describe(_ ref: AnyJSON, duration: Double?, gen: Int) {
        let args: [AnyJSON] = [ref, duration.map { AnyJSON.number($0) } ?? AnyJSON.null]
        Task {
            guard let d = try? await HarborEngine.shared.callJSON("together.sourceDescriptor", args), gen == sourceGen else { return }
            source = d
        }
    }

    // MARK: lobby (use-lobby-gate.ts)

    private func startHost(_ c: (any PlayerEngineControlling)?) {
        hasStarted = true
        room.call("startRoom")
        room.call("suppressOutgoingFor", [.number(0)])
        c?.setPaused(false)
        // (together pass 2) use-room-sync's heartbeat effect publishes at once when the host starts
        // (its tick() before the interval). The TV's waited for the next tick, up to a second after
        // "started" reached the guests, and their initial sync played from the lobby seed, which
        // is 0:00 when the host resumed from the "Pick up where you left off" fork, then jumped.
        if let s = c?.snapshot(), s.duration > 0 {
            lastHeartbeat = Date()
            publish(position: s.position, playing: true)
        }
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
        // (P8) A stream swapped in place after the player's first open: its descriptor, now with
        // the new file's length (the room was already told about this player, so no second invite).
        if openedSent {
            let picked: AnyJSON = switchRef ?? AnyJSON.object(ref)
            let gen: Int = sourceGen
            let args: [AnyJSON] = [picked, .number(duration)]
            Task {
                guard let d = try? await HarborEngine.shared.callJSON("together.sourceDescriptor", args), gen == sourceGen else { return }
                source = d
                // use-host-source.ts: in the lobby the host seeds the room again with the new descriptor.
                if !d.isNull, inRoom, isHost, !hasStarted, lobbySeeded, let ctl = controller {
                    publish(position: ctl.snapshot().position, playing: false)
                }
            }
            return
        }
        // (P8) A swap in place before this first ask: the picked stream's ref describes it.
        let opened: AnyJSON = switchRef ?? AnyJSON.object(ref)
        let gen: Int = sourceGen
        Task {
            // use-room-invite.ts: in a room with no other host, playing a title invites the room.
            if !openedSent {
                openedSent = true
                struct Opened: Decodable { var invited: Bool; var source: AnyJSON? }
                if let o: Opened = try? await HarborEngine.shared.call("together.playerOpened", [meta, ep, opened, duration]) {
                    // (P8) A swap in place meanwhile: its own descriptor is on its way; this one is the old stream's.
                    guard gen == sourceGen else { return }
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

    /// The invite names the title and episode this player shows (provider-events inviteMediaKey).
    private func showsInvited(_ i: TogetherModel.PlayInvite) -> Bool {
        guard let ctx = context, i.mediaId == ctx.meta.id else { return false }
        if let ep = i.episodeRef {
            guard let s = ctx.season, let e = ctx.episode else { return false }
            return ep.season == s && ep.episode == e
        }
        return ctx.season == nil || ctx.episode == nil
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
                // (together pass 2) Upstream's buffered is the seconds held ahead of the playhead
                // (mpv demuxer-cache-duration); the TV's bufferedSec() is where the buffer ends (the
                // scrub bar's fill). Read as is, "under 2 s buffered" never held and "near the end"
                // held past the film's half, so a guest still buffering after a sync seek was seeked
                // again at every heartbeat and a slow source never caught up.
                let buffered = max(0, c.bufferedSec() - livePos)
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
