import Foundation
import Combine

/// Watch Together on the TV: the Swift mirror of upstream's TogetherProvider
/// (lib/together/provider.tsx), which runs in the engine (engine/together.ts). The engine
/// pushes its whole view as `harbor:together` (throttled) and the room's playback state and
/// commands as `harbor:together-sync` (immediately); this model republishes both.
@MainActor
final class TogetherModel: ObservableObject {
    static let shared = TogetherModel()

    struct Participant: Decodable, Identifiable, Equatable {
        var id: String
        var name: String
        var ready: Bool
        var avatar: String?
        var color: String?
        var isSelf: Bool
        var host: Bool
        var activeAt: Double?
        var locationLabel: String?
    }

    struct ChatMessage: Decodable, Identifiable, Equatable {
        var from: String
        var name: String
        var text: String
        var at: Double
        var id: String { "\(from)-\(at)-\(text.hashValue)" }
    }

    /// lib/together/protocol.ts EpisodeRef (the fields the TV reads; the rest ride along in `raw`).
    struct EpisodeRef: Decodable, Equatable {
        var season: Int
        var episode: Int
        var name: String?
        var imdbSeason: Int?
        var imdbEpisode: Int?
    }

    struct SourceDescriptor: Decodable, Equatable {
        var title: String?
        var resolution: String?
        var sizeBytes: Double?
        var infoHash: String?
        var fileIdx: Int?
        var durationSec: Double?
    }

    /// lib/together/protocol.ts SyncState.
    struct SyncState: Decodable, Equatable {
        var mediaId: String?
        var mediaTitle: String?
        var episode: EpisodeRef?
        var posterUrl: String?
        var positionSeconds: Double
        var playing: Bool
        var speed: Double?
        var source: SourceDescriptor?
        var guestPick: Bool?
        var updatedAt: Double
        var updatedBy: String
    }

    /// lib/together/protocol.ts PlayInvite.
    struct PlayInvite: Decodable, Equatable {
        var mediaId: String
        var mediaType: String
        var mediaTitle: String
        var releaseInfo: String?
        var posterUrl: String?
        var backgroundUrl: String?
        var logoUrl: String?
        var episode: AnyJSON?
        var guestPick: Bool?
        var episodeRef: EpisodeRef? { episode.flatMap { try? $0.decode(EpisodeRef.self) } }
    }

    struct IncomingInvite: Decodable, Equatable { var from: String; var name: String; var invite: PlayInvite; var at: Double }
    struct IncomingHostLeaving: Decodable, Equatable { var from: String; var name: String; var at: Double }
    struct IncomingParticipantLeft: Decodable, Equatable { var clientId: String; var name: String; var at: Double; var color: String? }
    struct SummonTarget: Decodable, Equatable {
        var mediaId: String?
        var mediaType: String?
        var mediaTitle: String?
        var posterUrl: String?
        var backgroundUrl: String?
        var view: String?
        var label: String?
    }
    struct IncomingSummon: Decodable, Equatable { var from: String; var name: String; var target: SummonTarget; var at: Double }

    struct Cursor: Decodable, Equatable { var from: String; var name: String; var x: Double; var y: Double; var path: String }
    struct Point: Decodable, Equatable { var x: Double; var y: Double }
    struct Stroke: Decodable, Equatable, Identifiable { var id: String; var authorName: String; var color: String; var points: [Point]; var path: String }
    struct HostSource: Decodable, Equatable { var descriptor: SourceDescriptor; var mediaId: String? }

    /// engine/together.ts view().
    struct Snapshot: Decodable, Equatable {
        var rev: Double = 0
        var enabled = false
        var relayUrl = ""
        var publicRelay = "wss://pub.harbor.site"
        var isPublicRelay = false
        var relayOutdated = false
        var state = "disconnected"
        var room: String?
        var lastError: String?
        var started = false
        var hostClientId: String?
        var syncState: SyncState?
        var clientId = ""
        var displayName = ""
        var selfColor: String?
        var inSession = false
        var inRoom = false
        var isHost = false
        var guestsPick = false
        var shareCursors = true
        var hostSource: HostSource?
        var roomGuestPick = false
        var lastInviteProto: Double = 0
        var participants: [Participant] = []
        var chat: [ChatMessage] = []
        var incomingInvite: IncomingInvite?
        var incomingHostLeaving: IncomingHostLeaving?
        var incomingParticipantLeft: IncomingParticipantLeft?
        var incomingSummon: IncomingSummon?
        var cursors: [Cursor] = []
        var strokes: [Stroke] = []
        var inviteUrl: String?
    }

    enum RoomCommand: Equatable {
        case play, pause
        case seek(Double, seq: Double?)
    }

    @Published private(set) var view = Snapshot()
    /// Room playback state from someone else (use-room-sync onIncomingState).
    let incomingState = PassthroughSubject<SyncState, Never>()
    /// A guest's play/pause/seek request (use-room-sync onIncomingCommand; the host applies it).
    let incomingCommand = PassthroughSubject<(from: String, command: RoomCommand), Never>()

    private var unsubscribe: (() -> Void)?

    private init() {}

    /// The identity the room shows (use-self-identity.ts): the profile's avatar, else the Harbor
    /// account's, and the profile colour (the engine lets settings.harborColor win).
    private struct Identity: Encodable {
        var profileId: String
        var linked: Bool
        var avatar: String?
        var color: String?
    }

    private var identity: Identity {
        let p = ProfilesStore.shared.active
        var avatar = p?.avatar.flatMap(Self.shareable)
        if p?.avatar == nil, let a = AccountStore.shared.session?.user.avatar, !a.isEmpty {
            // theme-auth.ts: an account avatar is a path on HARBOR_API_BASE unless it is absolute.
            avatar = a.hasPrefix("http") ? a : "https://harbor.site" + (a.hasPrefix("/") ? a : "/" + a)
        }
        return Identity(profileId: p?.id ?? "default", linked: p?.linked ?? true, avatar: avatar, color: p?.color)
    }

    private static var dataURLs: [String: String] = [:]

    /// provider.tsx resolveShareableAvatar: a URL travels as is; bundled art (the TV's profile
    /// avatars are app files) is inlined as a data URL, like upstream's blob → FileReader path.
    /// client.ts drops anything over AVATAR_MAX_CHARS, so large art is not sent at all.
    private static func shareable(_ avatar: String) -> String? {
        if avatar.hasPrefix("http://") || avatar.hasPrefix("https://") || avatar.hasPrefix("data:") { return avatar }
        guard avatar.hasPrefix("/") else { return nil }
        if let hit = dataURLs[avatar] { return hit }
        let url = Bundle.main.bundleURL.appendingPathComponent(String(avatar.dropFirst()))
        guard let data = try? Data(contentsOf: url), data.count < 400_000 else { return nil }
        let mime: String
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg": mime = "image/jpeg"
        case "webp": mime = "image/webp"
        case "svg": mime = "image/svg+xml"
        case "gif": mime = "image/gif"
        default: mime = "image/png"
        }
        let out = "data:\(mime);base64," + data.base64EncodedString()
        dataURLs[avatar] = out
        return out
    }

    /// Attach once the engine is up, and again after a profile switch (the relay is per profile).
    func attach() async {
        if unsubscribe == nil {
            unsubscribe = HarborEngine.shared.onEvent { [weak self] type, detail in
                guard let self, let detail else { return }
                if type == "harbor:together" {
                    if let v = try? detail.decode(Snapshot.self) { self.view = v }
                } else if type == "harbor:together-sync" {
                    self.routeSync(detail)
                }
            }
        }
        if let v: Snapshot = try? await HarborEngine.shared.call("together.configure", [identity]) { view = v }
    }

    private func routeSync(_ detail: AnyJSON) {
        switch detail["kind"]?.string {
        case "state":
            if let raw = detail["state"], let s = try? raw.decode(SyncState.self) { incomingState.send(s) }
        case "command":
            guard let from = detail["from"]?.string, let c = detail["command"], let action = c["action"]?.string else { return }
            switch action {
            case "play": incomingCommand.send((from: from, command: .play))
            case "pause": incomingCommand.send((from: from, command: .pause))
            case "seek":
                if let pos = c["positionSeconds"]?.number { incomingCommand.send((from: from, command: .seek(pos, seq: c["seq"]?.number))) }
            default: break
            }
        default: break
        }
    }

    // MARK: actions (provider.tsx)

    @discardableResult
    func start() async -> String? {
        let code: String? = try? await HarborEngine.shared.call("together.start")
        await refresh()
        return code
    }

    struct JoinResult: Decodable { var ok: Bool; var reason: String?; var view: Snapshot }

    /// A code or an invite link. Returns nil on success, else what to tell the viewer.
    func join(_ input: String) async -> String? {
        guard let r: JoinResult = try? await HarborEngine.shared.call("together.join", [identity, input]) else {
            return "Couldn't join that room."
        }
        view = r.view
        if r.ok { return nil }
        return r.reason == "no-relay" ? "Set up a relay first (Watch together settings), or join with an invite link." : "That doesn't look like a room code or an invite link."
    }

    func leave() async {
        if let v: Snapshot = try? await HarborEngine.shared.call("together.leave") { view = v }
    }

    func retry() async {
        if let v: Snapshot = try? await HarborEngine.shared.call("together.retry") { view = v }
    }

    func setRelay(_ url: String) async {
        if let v: Snapshot = try? await HarborEngine.shared.call("together.setRelay", [identity, url]) { view = v }
    }

    func setName(_ name: String) async {
        if let v: Snapshot = try? await HarborEngine.shared.call("together.setName", [name]) { view = v }
    }

    func setGuestsPick(_ on: Bool) async {
        if let v: Snapshot = try? await HarborEngine.shared.call("together.setGuestsPick", [identity, on]) { view = v }
    }

    func sendChat(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        Task { _ = try? await HarborEngine.shared.callJSON("together.sendChat", [.string(t)]) }
    }

    func dismiss(_ kind: String) {
        Task { if let v: Snapshot = try? await HarborEngine.shared.call("together.dismiss", [kind]) { view = v } }
    }

    func refresh() async {
        if let v: Snapshot = try? await HarborEngine.shared.call("together.view") { view = v }
    }

    // MARK: playback bridge (used by TogetherPlayback)

    func sendCommand(_ command: RoomCommand) {
        let json: AnyJSON
        switch command {
        case .play: json = .object(["action": .string("play")])
        case .pause: json = .object(["action": .string("pause")])
        case .seek(let pos, _): json = .object(["action": .string("seek"), "positionSeconds": .number(pos)])
        }
        Task { _ = try? await HarborEngine.shared.callJSON("together.sendCommand", [json]) }
    }

    func publish(_ state: AnyJSON) {
        Task { _ = try? await HarborEngine.shared.callJSON("together.publishState", [state]) }
    }

    func call(_ fn: String, _ args: [AnyJSON] = []) {
        Task { _ = try? await HarborEngine.shared.callJSON("together.\(fn)", args) }
    }
}
