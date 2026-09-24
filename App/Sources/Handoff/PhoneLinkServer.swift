import Foundation
import Network

/// The LAN web server a phone reaches from the QR (src-tauri/src/web_server.rs, cut down to what
/// the hand-off needs). Upstream serves its whole web UI plus a WebSocket on 0.0.0.0:11471 while
/// "serve on network" is on; this one exists only while a hand-off panel is open, serves one
/// bundled page and one JSON endpoint, and every request is small and short-lived:
///
/// - `GET /`, `/setup`, `/remote`: the bundled phone page (App/Phone/harbor-phone.html). No other
///   path is served; there is no file system behind it.
/// - `POST /api/remote`: one hand-off frame in, the TV's reply out (see HandoffProtocol).
///
/// Only local-network peers are accepted, requests are capped (8 KB of headers, 16 KB of body),
/// each connection carries one request and is closed, and a slow sender is dropped.
final class PhoneLinkServer: @unchecked Sendable {
    struct Request: Sendable {
        let method: String
        let path: String
        let headers: [String: String]
        let body: Data
    }

    struct Response: Sendable {
        var status: Int
        var contentType: String
        var body: Data
        var headers: [String: String] = [:]

        static func text(_ status: Int, _ message: String) -> Response {
            Response(status: status, contentType: "text/plain; charset=utf-8", body: Data(message.utf8))
        }
    }

    enum State: Sendable {
        case ready(port: UInt16)
        case failed
    }

    typealias Handler = @Sendable (Request) async -> Response

    private static let maxHeader = 8 * 1024
    private static let maxBody = 16 * 1024
    private static let maxConnections = 16
    private static let readDeadline: TimeInterval = 10
    /// Covers the TV's own 20 s apply timeout plus the reply.
    private static let lifeDeadline: TimeInterval = 40

    private let queue = DispatchQueue(label: "harbor.phonelink")
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: Connection] = [:]
    private var stopped = false
    private let handler: Handler
    private let onState: @Sendable (State) -> Void

    init(handler: @escaping Handler, onState: @escaping @Sendable (State) -> Void) {
        self.handler = handler
        self.onState = onState
    }

    deinit {
        // A started NWListener keeps itself alive; never leave one listening behind its owner.
        listener?.cancel()
        for c in connections.values { c.nw.cancel() }
    }

    func start(preferredPort: UInt16 = Handoff.webPort) {
        queue.async {
            self.stopped = false
            self.listen(on: NWEndpoint.Port(rawValue: preferredPort) ?? .any, fallback: true)
        }
    }

    func stop() {
        queue.async {
            self.stopped = true
            self.listener?.cancel()
            self.listener = nil
            for c in self.connections.values { c.nw.cancel() }
            self.connections.removeAll()
        }
    }

    // MARK: listener

    private func listen(on port: NWEndpoint.Port, fallback: Bool) {
        guard !stopped else { return }
        let params = NWParameters.tcp
        params.acceptLocalOnly = true
        params.allowLocalEndpointReuse = true
        let l: NWListener
        do {
            l = try NWListener(using: params, on: port)
        } catch {
            if fallback { listen(on: .any, fallback: false) } else { onState(.failed) }
            return
        }
        listener = l
        l.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        l.stateUpdateHandler = { [weak self, weak l] state in
            guard let self, let l, self.listener === l else { return }
            switch state {
            case .ready:
                self.onState(.ready(port: l.port?.rawValue ?? port.rawValue))
            case .failed:
                // Port taken (upstream's `port 11471 unavailable`): any free port will do, the
                // QR carries it.
                l.cancel()
                self.listener = nil
                if fallback { self.listen(on: .any, fallback: false) } else { self.onState(.failed) }
            default:
                break
            }
        }
        l.start(queue: queue)
    }

    // MARK: connections

    private final class Connection: @unchecked Sendable {
        let nw: NWConnection
        var buffer = Data()
        var parsed = false
        var finished = false
        init(_ nw: NWConnection) { self.nw = nw }
    }

    private func accept(_ nw: NWConnection) {
        guard !stopped, connections.count < Self.maxConnections, Self.isLocal(nw.endpoint) else {
            nw.cancel()
            return
        }
        let c = Connection(nw)
        connections[ObjectIdentifier(c)] = c
        nw.stateUpdateHandler = { [weak self, weak c] state in
            guard let self, let c else { return }
            switch state {
            case .failed, .cancelled: self.forget(c)
            default: break
            }
        }
        nw.start(queue: queue)
        receive(c)
        queue.asyncAfter(deadline: .now() + Self.readDeadline) { [weak self, weak c] in
            guard let self, let c, !c.parsed else { return }
            self.close(c)
        }
        queue.asyncAfter(deadline: .now() + Self.lifeDeadline) { [weak self, weak c] in
            guard let self, let c else { return }
            self.close(c)
        }
    }

    private func forget(_ c: Connection) {
        c.finished = true
        connections.removeValue(forKey: ObjectIdentifier(c))
    }

    private func close(_ c: Connection) {
        c.nw.cancel()
        forget(c)
    }

    private func receive(_ c: Connection) {
        c.nw.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, !c.finished else { return }
            if let data, !data.isEmpty { c.buffer.append(data) }
            switch Self.parse(c.buffer) {
            case .incomplete:
                if isComplete || error != nil { self.close(c) } else { self.receive(c) }
            case .bad(let status):
                c.parsed = true
                self.respond(c, .text(status, "Bad request"))
            case .ready(let request):
                c.parsed = true
                let handler = self.handler
                Task {
                    let response = await handler(request)
                    self.queue.async { self.respond(c, response) }
                }
            }
        }
    }

    private func respond(_ c: Connection, _ r: Response) {
        guard !c.finished else { return }
        var head = "HTTP/1.1 \(r.status) \(Self.reason(r.status))\r\n"
        var headers = r.headers
        headers["Content-Type"] = r.contentType
        headers["Content-Length"] = String(r.body.count)
        headers["Connection"] = "close"
        headers["Cache-Control"] = "no-store"
        headers["X-Content-Type-Options"] = "nosniff"
        // The token is in the page URL; links out (TMDB, Stremio) must never carry it.
        headers["Referrer-Policy"] = "no-referrer"
        for (k, v) in headers { head += "\(k): \(v)\r\n" }
        head += "\r\n"
        var out = Data(head.utf8)
        out.append(r.body)
        c.nw.send(content: out, completion: .contentProcessed { [weak self] _ in
            guard let self else { return }
            self.close(c)
        })
    }

    // MARK: parsing

    private enum Parse {
        case incomplete
        case bad(Int)
        case ready(Request)
    }

    private static let crlf2 = Data("\r\n\r\n".utf8)

    private static func parse(_ buffer: Data) -> Parse {
        guard let end = buffer.range(of: crlf2) else {
            return buffer.count > maxHeader ? .bad(431) : .incomplete
        }
        let headerLength = end.lowerBound - buffer.startIndex
        guard headerLength <= maxHeader,
              let head = String(data: buffer[buffer.startIndex..<end.lowerBound], encoding: .utf8) else { return .bad(431) }
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines[0].split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 3, parts[2].hasPrefix("HTTP/1."), parts[1].hasPrefix("/"), parts[1].count <= 2048 else { return .bad(400) }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { return .bad(400) }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        if headers["transfer-encoding"] != nil { return .bad(501) }
        var length = 0
        if let raw = headers["content-length"] {
            guard let n = Int(raw), n >= 0 else { return .bad(400) }
            guard n <= maxBody else { return .bad(413) }
            length = n
        }
        let bodyStart = end.upperBound
        let available = buffer.endIndex - bodyStart
        if available < length { return .incomplete }
        let body = Data(buffer[bodyStart..<(bodyStart + length)])
        let target = String(parts[1])
        let path = String(target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
        return .ready(Request(method: String(parts[0]), path: path, headers: headers, body: body))
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 413: return "Payload Too Large"
        case 415: return "Unsupported Media Type"
        case 431: return "Request Header Fields Too Large"
        case 501: return "Not Implemented"
        default: return "Error"
        }
    }

    // MARK: local-network check (acceptLocalOnly is the first line; this is the second)

    static func isLocal(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let a):
            return isLocalV4(Array(a.rawValue))
        case .ipv6(let a):
            let b = Array(a.rawValue)
            guard b.count == 16 else { return false }
            // IPv4-mapped ::ffff:a.b.c.d
            if b[0..<10].allSatisfy({ $0 == 0 }) && b[10] == 0xff && b[11] == 0xff { return isLocalV4(Array(b[12..<16])) }
            if b[0..<15].allSatisfy({ $0 == 0 }) && b[15] == 1 { return true } // ::1
            if b[0] == 0xfe && (b[1] & 0xc0) == 0x80 { return true } // fe80::/10 link-local
            if (b[0] & 0xfe) == 0xfc { return true } // fc00::/7 unique local
            return false
        default:
            return false
        }
    }

    static func isLocalV4(_ b: [UInt8]) -> Bool {
        guard b.count == 4 else { return false }
        switch b[0] {
        case 10, 127: return true
        case 172: return (16...31).contains(b[1])
        case 192: return b[1] == 168
        case 169: return b[1] == 254
        case 100: return (64...127).contains(b[1]) // carrier-grade NAT, some hotel and campus Wi-Fi
        default: return false
        }
    }
}

/// This Apple TV's address on the local network (handoff-reach.ts readLanHost). Prefers a
/// private IPv4 on an `en` interface, which is what a phone on the same Wi-Fi can reach.
enum LanAddress {
    static func current() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        var fallback: String?
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            let flags = ifa.ifa_flags
            guard (flags & UInt32(IFF_UP)) != 0, (flags & UInt32(IFF_LOOPBACK)) == 0,
                  let addr = ifa.ifa_addr, addr.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            let name = String(cString: ifa.ifa_name)
            guard name.hasPrefix("en") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: host)
            let octets = ip.split(separator: ".").compactMap { UInt8($0) }
            if PhoneLinkServer.isLocalV4(octets) && octets.first != 127 { return ip }
            if fallback == nil { fallback = ip }
        }
        return fallback
    }
}
