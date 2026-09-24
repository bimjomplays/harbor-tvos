import Foundation
import Security

// Wire contract for the TV hand-off (lib/tv-handoff/handoff-protocol.ts, handoff-code.ts,
// handoff-session.ts), ported to Swift so the LAN server never waits on the engine.
//
// Upstream rides the remote WebSocket; here each frame is one HTTP POST to /api/remote and the
// reply carries what the TV would have broadcast (see PhoneLinkServer). Two things change with
// the transport: the per-socket client id the Rust server assigned now travels in the frame as
// `client` (minted by the phone page), and a dropped socket becomes a phone that stopped polling.
// The port adds one command, `text`, carrying upstream's remote typing actions
// (lib/remote/protocol.ts setText / submitText / blurText) behind the same token and binding,
// because upstream's remote had no pairing at all and this server only speaks to a paired phone.

enum Handoff {
    static let msg = "harborSetup"
    static let proto = 1
    /// Matches the Trakt device flow's shape: long enough to finish, short enough to be safe.
    static let ttl: TimeInterval = 10 * 60
    /// Nothing has connected by now: the TV says why and moves focus to its own path.
    static let stall: TimeInterval = 45
    /// Wrong-token attempts before the offer is burned and reminted.
    static let maxFailedClaims = 8
    /// Query parameter the phone page reads the code from.
    static let param = "setup"
    /// lib/remote/protocol.ts WEB_PORT. Tried first; any free port if it is taken.
    static let webPort: UInt16 = 11471
    /// handoff-host.ts APPLY_TIMEOUT_MS: a wedged applier must not wedge the queue behind it.
    static let applyTimeout: TimeInterval = 20
    /// Codes already replaced. Recognised so a stale retry reads as expired.
    static let retiredKeep = 6
    /// Longest text a phone may type into a TV field.
    static let textMax = 2048

    // MARK: handoff-code.ts

    /// Crockford base32: no I, L, O or U. Read aloud across a room and scanned from a QR.
    /// 32 symbols divide 256 evenly, so a raw byte modulo is unbiased.
    private static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
    /// 12 symbols of 32 is 60 bits.
    static let tokenLength = 12
    static let idLength = 8

    private static func mint(_ length: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: length)
        if SecRandomCopyBytes(kSecRandomDefault, length, &bytes) != errSecSuccess {
            bytes = (0..<length).map { _ in UInt8.random(in: 0...255) }
        }
        return String(bytes.map { alphabet[Int($0) % alphabet.count] })
    }

    static func mintToken() -> String { mint(tokenLength) }
    /// Public correlation id. Sent to every poller, so deliberately not the token.
    static func mintId() -> String { mint(idLength) }

    /// Accepts what a person actually types: lower case, spaces, dashes, and the glyph confusions
    /// the alphabet was chosen to absorb.
    static func normalize(_ input: String) -> String {
        let upper = input.uppercased()
        var out = ""
        for ch in upper where ch.isASCII && (ch.isLetter || ch.isNumber) {
            switch ch {
            case "O": out.append("0")
            case "I", "L": out.append("1")
            default: out.append(ch)
            }
        }
        return out
    }

    /// Grouped for reading at ten feet. Strip before comparing.
    static func format(_ code: String) -> String {
        let clean = Array(normalize(code))
        return stride(from: 0, to: clean.count, by: 4)
            .map { String(clean[$0..<min($0 + 4, clean.count)]) }
            .joined(separator: " ")
    }

    /// handoffUrl: `/setup` is its own surface; `/remote` is the typing surface. The token rides
    /// along so the phone can claim the pairing.
    static func url(host: String, port: UInt16, path: String, token: String) -> String {
        "http://\(host):\(port)/\(path)?\(param)=\(token)"
    }

    // MARK: validation (hostile input from the LAN; every field shape-checked and length-capped)

    private static let alnum = Set("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")
    private static let upperAlnum = Set("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ")
    private static let tokenish = alnum.union("._~+/=-")
    private static let handleChars = alnum.union("._-")

    private static func str(_ v: Any?, _ allowed: Set<Character>, _ range: ClosedRange<Int>) -> String? {
        guard let s = v as? String, range.contains(s.count), s.allSatisfy({ allowed.contains($0) }) else { return nil }
        return s
    }

    static func isToken(_ v: Any?) -> String? { str(v, upperAlnum, 8...32) }
    static func isNonce(_ v: Any?) -> String? { str(v, alnum, 4...32) }
    static func isClientId(_ v: Any?) -> String? { str(v, alnum, 8...32) }

    /// parseHandoffPayload. Alphanumeric-only TMDB key: it is later spliced into query strings.
    static func parsePayload(_ v: Any?) -> HandoffPayload? {
        guard let o = v as? [String: Any], let step = o["step"] as? String else { return nil }
        switch step {
        case "tmdb":
            return str(o["key"], alnum, 8...128).map { .tmdb(key: $0) }
        case "stremio":
            guard let authKey = str(o["authKey"], tokenish, 8...512) else { return nil }
            let label = (o["label"] as? String).flatMap { $0.count <= 64 ? $0 : nil }
            return .stremio(authKey: authKey, label: label)
        case "harbor":
            guard let session = str(o["session"], tokenish, 8...4096),
                  let handle = str(o["handle"], handleChars, 2...40) else { return nil }
            return .harbor(session: session, handle: handle, refresh: str(o["refresh"], tokenish, 8...4096))
        default:
            return nil
        }
    }

    /// Port extension: upstream's remote typing actions. Control characters never reach a field.
    static func parseText(_ o: [String: Any]) -> HandoffTextAction? {
        func clean(_ v: Any?) -> String?? {
            guard let v else { return .some(nil) }
            guard let s = v as? String, s.count <= textMax else { return nil }
            var scalars = String.UnicodeScalarView()
            for u in s.unicodeScalars where !CharacterSet.controlCharacters.contains(u) { scalars.append(u) }
            return .some(String(scalars))
        }
        switch o["action"] as? String {
        case "setText":
            guard let v = clean(o["value"]), let value = v else { return nil }
            return .set(value)
        case "submitText":
            guard let v = clean(o["value"]) else { return nil }
            return .submit(v)
        case "blurText":
            return .blur
        default:
            return nil
        }
    }

    private static func parseCommand(_ v: Any?) -> HandoffCommand? {
        guard let o = v as? [String: Any], let kind = o["kind"] as? String else { return nil }
        if kind == "hello" { return .hello }
        guard let token = isToken(o["token"]) else { return nil }
        switch kind {
        case "claim": return .claim(token: token)
        case "abandon": return .abandon(token: token)
        case "deliver": return parsePayload(o["payload"]).map { .deliver(token: token, payload: $0) }
        case "text": return parseText(o).map { .text(token: token, action: $0) }
        default: return nil
        }
    }

    /// parseHandoffEnvelope: nil for "not our frame"; `.bad` for a frame addressed to us whose
    /// command did not survive validation, so the host answers badPayload instead of dropping it.
    static func parseEnvelope(_ data: Data) -> HandoffEnvelope? {
        guard let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              parsed["t"] as? String == msg,
              let proto = parsed["proto"] as? Int,
              let nonce = isNonce(parsed["nonce"]),
              let client = isClientId(parsed["client"]) else { return nil }
        guard let cmd = parseCommand(parsed["cmd"]) else { return .bad(nonce: nonce) }
        return .ok(HandoffClientMessage(proto: proto, nonce: nonce, client: client, cmd: cmd))
    }

    /// HandoffServerMessage, plus the port's `surface` and `entry` for the typing surface.
    static func serverMessage(offer: HandoffOffer?, ack: HandoffAck?, surface: String, entry: [String: Any]?) -> Data {
        var o: [String: Any] = ["t": msg, "proto": proto, "surface": surface]
        if let offer { o["offer"] = offer.json } else { o["offer"] = NSNull() }
        if let ack {
            var a: [String: Any] = ["nonce": ack.nonce, "ok": ack.ok]
            if let reason = ack.reason { a["reason"] = reason.rawValue } else { a["reason"] = NSNull() }
            o["ack"] = a
        }
        if let entry { o["entry"] = entry }
        return (try? JSONSerialization.data(withJSONObject: o)) ?? Data("{}".utf8)
    }
}

enum HandoffStep: String, CaseIterable, Sendable {
    case tmdb, stremio, harbor
}

/// Phone to TV only. These carry credentials and never appear in a reply.
enum HandoffPayload: Sendable {
    case tmdb(key: String)
    case stremio(authKey: String, label: String?)
    case harbor(session: String, handle: String, refresh: String?)

    var step: HandoffStep {
        switch self {
        case .tmdb: return .tmdb
        case .stremio: return .stremio
        case .harbor: return .harbor
        }
    }
}

enum HandoffTextAction: Sendable, Equatable {
    case set(String)
    case submit(String?)
    case blur
}

enum HandoffCommand: Sendable {
    case hello
    case claim(token: String)
    case deliver(token: String, payload: HandoffPayload)
    case abandon(token: String)
    case text(token: String, action: HandoffTextAction)
}

struct HandoffClientMessage: Sendable {
    let proto: Int
    let nonce: String
    let client: String
    let cmd: HandoffCommand
}

enum HandoffEnvelope: Sendable {
    case ok(HandoffClientMessage)
    case bad(nonce: String)
}

enum HandoffReject: String, Error {
    case badProto, noOffer, badToken, expired, notBound, boundElsewhere, stepUnknown, stepDone, lockedOut, badPayload, applyFailed
}

struct HandoffAck {
    let nonce: String
    let ok: Bool
    let reason: HandoffReject?
}

enum HandoffOfferState: String {
    case open, claimed, complete, expired
}

/// TV to phone. Carries an opaque correlation id rather than the token.
struct HandoffOffer: Equatable {
    let offerId: String
    let state: HandoffOfferState
    let expiresAt: Date
    let pending: [HandoffStep]
    let done: [HandoffStep]

    var json: [String: Any] {
        [
            "offerId": offerId,
            "state": state.rawValue,
            "expiresAt": Int(expiresAt.timeIntervalSince1970 * 1000),
            "pending": pending.map(\.rawValue),
            "done": done.map(\.rawValue),
        ]
    }
}

/// handoff-session.ts: one code, one binding, a lockout budget. Not thread-safe; the host owns it
/// on the main actor. A typing session has no steps and never completes (port extension).
final class HandoffSession {
    /// Never sent to a poller. Lives on the TV screen, in the QR, and in the phone's URL.
    let token: String
    let offerId: String
    let expiresAt: Date
    private let typing: Bool
    private let now: () -> Date
    private let maxFailed: Int
    private(set) var pending: [HandoffStep]
    private(set) var done: [HandoffStep]
    private(set) var bound: String?
    private var failed = 0
    private var dead = false

    init(steps: [HandoffStep], typing: Bool = false, initialDone: [HandoffStep] = [],
         ttl: TimeInterval = Handoff.ttl, maxFailedClaims: Int = Handoff.maxFailedClaims,
         now: @escaping () -> Date = Date.init) {
        self.now = now
        self.typing = typing
        self.maxFailed = maxFailedClaims
        token = Handoff.mintToken()
        offerId = Handoff.mintId()
        expiresAt = now().addingTimeInterval(ttl)
        var seen: [HandoffStep] = []
        for s in initialDone where !seen.contains(s) { seen.append(s) }
        done = seen
        var p: [HandoffStep] = []
        for s in steps where !p.contains(s) && !seen.contains(s) { p.append(s) }
        pending = p
    }

    private var isExpired: Bool { now() >= expiresAt }
    private var isComplete: Bool { !typing && pending.isEmpty }

    private var state: HandoffOfferState {
        if isComplete { return .complete }
        if dead || isExpired { return .expired }
        return bound == nil ? .open : .claimed
    }

    func offer() -> HandoffOffer {
        HandoffOffer(offerId: offerId, state: state, expiresAt: expiresAt, pending: pending, done: done)
    }

    var needsRemint: Bool { !isComplete && (dead || isExpired) }

    /// A wrong token is an oracle. Count it, and burn the offer once it is abused.
    private func badToken() -> HandoffReject {
        failed += 1
        if failed >= maxFailed {
            dead = true
            return .lockedOut
        }
        return .badToken
    }

    /// Constant-time compare: the code is short and the attacker is on the same network.
    private static func same(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<x.count { diff |= x[i] ^ y[i] }
        return diff == 0
    }

    private func gate(_ client: String, _ given: String, needBinding: Bool) -> HandoffReject? {
        if dead { return .lockedOut }
        if isExpired { return .expired }
        if !Self.same(given, token) { return badToken() }
        if !needBinding { return nil }
        guard let bound else { return .notBound }
        return bound == client ? nil : .boundElsewhere
    }

    func claim(_ client: String, _ given: String) -> HandoffReject? {
        if let r = gate(client, given, needBinding: false) { return r }
        if bound == nil || bound == client {
            bound = client
            failed = 0
            return nil
        }
        return .boundElsewhere
    }

    /// Validates without mutating, so a failed apply does not consume the step.
    func checkDeliver(_ client: String, _ given: String, _ payload: HandoffPayload) -> HandoffReject? {
        if let r = gate(client, given, needBinding: true) { return r }
        if done.contains(payload.step) { return .stepDone }
        if !pending.contains(payload.step) { return .stepUnknown }
        return nil
    }

    func commitDeliver(_ payload: HandoffPayload) {
        guard !done.contains(payload.step) else { return }
        pending.removeAll { $0 == payload.step }
        done.append(payload.step)
    }

    /// Port extension: typing needs the same token and binding as a delivery, and only on a
    /// typing session.
    func checkText(_ client: String, _ given: String) -> HandoffReject? {
        if let r = gate(client, given, needBinding: true) { return r }
        return typing ? nil : .stepUnknown
    }

    func abandon(_ client: String, _ given: String) -> HandoffReject? {
        if let r = gate(client, given, needBinding: false) { return r }
        if bound == client { bound = nil }
        return nil
    }

    /// Phone went quiet. Frees the binding so a reload can re-claim with the same code.
    @discardableResult
    func releaseClient(_ client: String) -> Bool {
        guard bound == client else { return false }
        bound = nil
        return true
    }
}
