import Foundation
import Combine

/// TV side of the phone hand-off: lib/tv-handoff/handoff-host.ts (the command queue, remint,
/// retired codes) and use-tv-handoff.ts (the phases a surface turns into copy), holding the
/// PhoneLinkServer for exactly as long as a surface keeps it active.
///
/// Two surfaces use it. `.setup` is upstream's hand-off: the phone signs in to TMDB, Stremio and
/// Harbor and delivers the results (onboarding "phone" step, Settings → Connect). `.typing` is
/// bp-phone-typing.tsx: the phone becomes the keyboard for one text field on the TV.
@MainActor
final class TvHandoff: ObservableObject {
    enum Mode: Equatable {
        case setup([HandoffStep])
        case typing
    }

    /// use-tv-handoff.ts TvHandoffPhase. There is no `servingOff`: the server here is started by
    /// the panel itself and stops with it, so nothing stays open on the network afterwards.
    enum Phase: Equatable {
        case off, starting, noAddress, serveFailed, waiting, stalled, claimed, complete
    }

    /// What the phone shows for the typing surface (lib/remote/protocol.ts RemoteTextEntry).
    struct Entry {
        var label: String
        var placeholder: String
        var secure = false
        /// Read when the phone binds, so it starts from what the field already holds.
        var value: () -> String
    }

    @Published private(set) var phase: Phase = .off
    /// The address the QR encodes. Nil before `waiting`.
    @Published private(set) var url: String?
    /// The address without the code, for someone typing it into a phone browser.
    @Published private(set) var shortURL: String?
    /// Grouped for reading at ten feet.
    @Published private(set) var codeDisplay: String?
    @Published private(set) var pending: [HandoffStep] = []
    @Published private(set) var done: [HandoffStep] = []

    /// Applied on the TV. Throwing refuses the step (the phone sees `applyFailed`).
    var onPayload: (@MainActor @Sendable (HandoffPayload) async throws -> Void)?
    var onText: ((HandoffTextAction) -> Void)?
    var entry: Entry?

    let mode: Mode
    private var active = false
    private var session: HandoffSession?
    private var server: PhoneLinkServer?
    private var port: UInt16?
    private var serveFailed = false
    private var lanHost: String?
    private var lanResolved = false
    private var lanCheckedAt = Date.distantPast
    private var offerSince = Date()
    private var offerId: String?
    private var wasClaimed = false
    private var lastSeen: [String: Date] = [:]
    private var ticker: Task<Void, Never>?
    private var chain: Task<Void, Never>?
    private var serverGeneration: UUID?

    /// Module scope in upstream too: a phone re-claims with the code in its URL, so a host that
    /// was torn down and rebuilt must read those retries as expired, not as wrong guesses.
    private static var retired: [String] = []

    /// handoff-reach.ts LAN_RETRY_MS / LAN_RECHECK_MS: the TV can take a new lease mid-setup.
    private static let lanRetry: TimeInterval = 5
    private static let lanRecheck: TimeInterval = 15
    /// A phone polls every 2 s while its page is visible; this long without one is a dropped socket.
    private static let clientSilence: TimeInterval = 12

    private static let page: Data? = Bundle.main.url(forResource: "harbor-phone", withExtension: "html")
        .flatMap { try? Data(contentsOf: $0) }

    init(mode: Mode) {
        self.mode = mode
    }

    private var steps: [HandoffStep] {
        if case .setup(let s) = mode { return s }
        return []
    }

    private var surface: String { mode == .typing ? "typing" : "setup" }

    // MARK: lifecycle

    func start() {
        guard !active else { return }
        active = true
        serveFailed = false
        refreshLan(force: true)
        let generation = UUID()
        serverGeneration = generation
        let server = PhoneLinkServer(
            handler: { [weak self] request in
                guard let self else { return .text(404, "Not found") }
                return await self.respond(request)
            },
            onState: { [weak self] state in
                Task { @MainActor [weak self] in self?.serverState(state, generation: generation) }
            })
        self.server = server
        server.start()
        ticker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, self.active else { return }
                self.tick()
            }
        }
        derive()
    }

    /// Stop the listener. Every surface calls this when it closes.
    func stop() {
        guard active else { return }
        active = false
        ticker?.cancel()
        ticker = nil
        server?.stop()
        server = nil
        port = nil
        if let s = session { retire(s.token) }
        session = nil
        lastSeen.removeAll()
        derive()
    }

    /// "Show a new code": fresh code, keeping whatever the phone already delivered.
    func restart() {
        guard active, session != nil else { return }
        remint()
        derive()
    }

    // MARK: host

    private func serverState(_ state: PhoneLinkServer.State, generation: UUID) {
        // A listener from an earlier start can still report in; only the current one counts.
        guard active, generation == serverGeneration else { return }
        switch state {
        case .ready(let p):
            port = p
            if session == nil { session = makeSession(initialDone: done) }
        case .failed:
            serveFailed = true
        }
        derive()
    }

    private func makeSession(initialDone: [HandoffStep]) -> HandoffSession {
        mode == .typing ? HandoffSession(steps: [], typing: true) : HandoffSession(steps: steps, initialDone: initialDone)
    }

    private func retire(_ token: String) {
        Self.retired = Array(([token] + Self.retired.filter { $0 != token }).prefix(Handoff.retiredKeep))
    }

    private func remint() {
        guard let prev = session else { return }
        retire(prev.token)
        let offer = prev.offer()
        session = mode == .typing
            ? HandoffSession(steps: [], typing: true)
            : HandoffSession(steps: offer.pending, initialDone: offer.done)
    }

    private func tick() {
        if let s = session, s.needsRemint { remint() }
        if let s = session, let bound = s.bound, Date().timeIntervalSince(lastSeen[bound] ?? .distantPast) > Self.clientSilence {
            s.releaseClient(bound)
        }
        let cutoff = Date().addingTimeInterval(-60)
        lastSeen = lastSeen.filter { $0.value > cutoff }
        refreshLan(force: false)
        derive()
    }

    private func refreshLan(force: Bool) {
        let wait = lanHost == nil ? Self.lanRetry : Self.lanRecheck
        guard force || Date().timeIntervalSince(lanCheckedAt) >= wait else { return }
        lanCheckedAt = Date()
        lanHost = LanAddress.current()
        lanResolved = true
    }

    /// use-tv-handoff.ts derivePhase, plus the stall clock (reset when the offer or the claim changes).
    private func derive() {
        let offer = session?.offer()
        if offer?.offerId != offerId || (offer?.state == .claimed) != wasClaimed {
            offerId = offer?.offerId
            wasClaimed = offer?.state == .claimed
            offerSince = Date()
        }
        let next: Phase
        if !active { next = .off }
        else if !lanResolved { next = .starting }
        else if lanHost == nil { next = .noAddress }
        else if serveFailed { next = .serveFailed }
        else if port == nil { next = .starting }
        else if let offer {
            switch offer.state {
            case .complete: next = .complete
            case .claimed: next = .claimed
            default: next = Date().timeIntervalSince(offerSince) >= Handoff.stall ? .stalled : .waiting
            }
        } else { next = .starting }

        let live = next == .waiting || next == .stalled || next == .claimed
        let newURL: String?
        let newShort: String?
        let newCode: String?
        if live, let host = lanHost, let port, let token = session?.token {
            newURL = Handoff.url(host: host, port: port, path: mode == .typing ? "remote" : "setup", token: token)
            newShort = "\(host):\(port)"
            newCode = Handoff.format(token)
        } else {
            newURL = nil; newShort = nil; newCode = nil
        }
        if phase != next { phase = next }
        if url != newURL { url = newURL }
        if shortURL != newShort { shortURL = newShort }
        if codeDisplay != newCode { codeDisplay = newCode }
        let p = offer?.pending ?? [], d = offer?.done ?? done
        if pending != p { pending = p }
        if done != d { done = d }
    }

    // MARK: HTTP

    private func respond(_ request: PhoneLinkServer.Request) async -> PhoneLinkServer.Response {
        guard active else { return .text(404, "Not found") }
        switch (request.method, request.path) {
        case ("GET", "/"), ("GET", "/setup"), ("GET", "/remote"):
            guard let page = Self.page else { return .text(500, "Missing page") }
            return PhoneLinkServer.Response(
                status: 200, contentType: "text/html; charset=utf-8", body: page,
                headers: ["Content-Security-Policy": "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data:; connect-src 'self' https://api.themoviedb.org https://api.strem.io https://harbor.site; form-action 'none'; frame-ancestors 'none'; base-uri 'none'"])
        case ("POST", "/api/remote"):
            // A JSON content type forces a CORS preflight, which this server never answers, so
            // another page open in the phone's browser cannot post here.
            guard (request.headers["content-type"] ?? "").lowercased().hasPrefix("application/json") else {
                return .text(415, "Unsupported")
            }
            guard let envelope = Handoff.parseEnvelope(request.body) else { return .text(400, "Bad frame") }
            let body = await handle(envelope)
            return PhoneLinkServer.Response(status: 200, contentType: "application/json", body: body)
        case (_, "/"), (_, "/setup"), (_, "/remote"), (_, "/api/remote"):
            return .text(405, "Method not allowed")
        default:
            return .text(404, "Not found")
        }
    }

    private func reply(_ nonce: String, _ reject: HandoffReject?, client: String?) -> Data {
        let offer = session?.offer()
        derive()
        return Handoff.serverMessage(offer: offer, ack: HandoffAck(nonce: nonce, ok: reject == nil, reason: reject),
                                     surface: surface, entry: entryJSON(for: client))
    }

    /// The field's label always; its current value only to the bound phone, and never a secret.
    private func entryJSON(for client: String?) -> [String: Any]? {
        guard mode == .typing, let entry else { return nil }
        var o: [String: Any] = ["label": entry.label, "placeholder": entry.placeholder, "secure": entry.secure]
        if let client, session?.bound == client, !entry.secure { o["value"] = entry.value() }
        return o
    }

    /// handoff-host.ts enqueue: one command at a time, so a delivery's check, apply and commit
    /// never interleave with another command.
    private func handle(_ envelope: HandoffEnvelope) async -> Data {
        let previous = chain
        let work = Task { @MainActor [weak self] () -> Data in
            await previous?.value
            guard let self else { return Data("{}".utf8) }
            return await self.run(envelope)
        }
        chain = Task { _ = await work.value }
        return await work.value
    }

    private func run(_ envelope: HandoffEnvelope) async -> Data {
        guard case .ok(let msg) = envelope else {
            if case .bad(let nonce) = envelope { return reply(nonce, .badPayload, client: nil) }
            return Data("{}".utf8)
        }
        guard active, let session else { return reply(msg.nonce, .noOffer, client: nil) }
        // Bounded: every poller has an id, but only the bound phone's matters.
        if lastSeen.count >= 256 { let keep = session.bound; lastSeen = lastSeen.filter { $0.key == keep } }
        lastSeen[msg.client] = Date()
        if msg.proto != Handoff.proto { return reply(msg.nonce, .badProto, client: msg.client) }

        switch msg.cmd {
        case .hello:
            return reply(msg.nonce, nil, client: msg.client)
        case .claim(let token):
            if Self.retired.contains(token) { return reply(msg.nonce, .expired, client: msg.client) }
            let r = session.claim(msg.client, token)
            if session.needsRemint { remint() }
            return reply(msg.nonce, r, client: msg.client)
        case .abandon(let token):
            if Self.retired.contains(token) { return reply(msg.nonce, .expired, client: msg.client) }
            let r = session.abandon(msg.client, token)
            if session.needsRemint { remint() }
            return reply(msg.nonce, r, client: msg.client)
        case .text(let token, let action):
            if Self.retired.contains(token) { return reply(msg.nonce, .expired, client: msg.client) }
            if let r = session.checkText(msg.client, token) {
                if session.needsRemint { remint() }
                return reply(msg.nonce, r, client: msg.client)
            }
            onText?(action)
            return reply(msg.nonce, nil, client: msg.client)
        case .deliver(let token, let payload):
            if Self.retired.contains(token) { return reply(msg.nonce, .expired, client: msg.client) }
            if let r = session.checkDeliver(msg.client, token, payload) {
                if session.needsRemint { remint() }
                return reply(msg.nonce, r, client: msg.client)
            }
            do {
                try await applyWithTimeout(payload)
            } catch {
                return reply(msg.nonce, .applyFailed, client: msg.client)
            }
            guard active else { return reply(msg.nonce, .noOffer, client: nil) }
            session.commitDeliver(payload)
            // A remint during the apply carried the old pending list; the step landed anyway.
            if let current = self.session, current !== session { current.commitDeliver(payload) }
            return reply(msg.nonce, nil, client: msg.client)
        }
    }

    private struct ApplyTimedOut: Error {}

    private func applyWithTimeout(_ payload: HandoffPayload) async throws {
        guard let apply = onPayload else { throw ApplyTimedOut() }
        let once = Once()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            Task { @MainActor in
                do {
                    try await apply(payload)
                    if once.claim() { cont.resume() }
                } catch {
                    if once.claim() { cont.resume(throwing: error) }
                }
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(Handoff.applyTimeout * 1_000_000_000))
                if once.claim() { cont.resume(throwing: ApplyTimedOut()) }
            }
        }
    }
}

/// Resumes a continuation exactly once, whichever of the apply and its timeout finishes first.
@MainActor
private final class Once {
    private var fired = false
    func claim() -> Bool {
        if fired { return false }
        fired = true
        return true
    }
}
