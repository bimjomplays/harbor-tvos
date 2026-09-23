import Foundation

/// Harbor's own account server. Paths and shapes follow docs/harbor-protocol.md §1.1 and §1.5.
enum HarborAPI {
    static let base = URL(string: "https://harbor.site/themes/api")!

    struct User: Codable, Equatable {
        var id: String
        var username: String
        var avatar: String?
        var handle: String?
        var verified: Bool?
        var stremioLinked: Bool?
    }

    struct AuthResult: Codable {
        var token: String
        var refresh: String?
        var user: User
    }

    struct SyncDoc: Codable {
        var key: String
        var rev: Int
        var at: String
        var value: AnyJSON
    }

    struct SyncState: Codable {
        var rev: Int
        var serverTime: String
        var docs: [SyncDoc]
    }

    struct APIError: Error, LocalizedError {
        var status: Int
        var code: String?
        var reason: String?
        var errorDescription: String? { HarborErrorMessages.message(code: code, reason: reason, status: status) }
    }

    static func login(username: String, password: String) async throws -> AuthResult {
        try await post("/identity/api/login", body: ["username": username, "password": password], token: nil)
    }

    static func register(username: String, password: String) async throws -> AuthResult {
        try await post("/identity/api/register", body: ["username": username, "password": password], token: nil)
    }

    static func me(token: String) async throws -> User {
        struct Wrap: Codable { var user: User }
        let w: Wrap = try await get("/identity/api/me", token: token)
        return w.user
    }

    static func refresh(_ refresh: String) async throws -> (token: String, refresh: String) {
        struct Out: Codable { var token: String; var refresh: String }
        let o: Out = try await post("/identity/api/token/refresh", body: ["refresh": refresh], token: nil)
        return (o.token, o.refresh)
    }

    /// Full sync state. Never treat a malformed body as "empty account" (protocol §1.5).
    static func syncState(token: String) async throws -> SyncState {
        try await get("/sync/v1/state", token: token)
    }

    // MARK: transport

    private static func request(_ path: String, method: String, body: Data?, token: String?) async throws -> Data {
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        req.httpBody = body
        req.timeoutInterval = 20
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            struct Envelope: Codable { var error: String?; var code: String?; var message: String? }
            let env = try? JSONDecoder().decode(Envelope.self, from: data)
            throw APIError(status: status, code: env?.code ?? env?.error, reason: env?.message)
        }
        return data
    }

    private static func get<T: Decodable>(_ path: String, token: String?) async throws -> T {
        try JSONDecoder().decode(T.self, from: try await request(path, method: "GET", body: nil, token: token))
    }

    private static func post<T: Decodable>(_ path: String, body: [String: Any], token: String?) async throws -> T {
        let data = try JSONSerialization.data(withJSONObject: body)
        return try JSONDecoder().decode(T.self, from: try await request(path, method: "POST", body: data, token: token))
    }
}

/// Human-facing strings for the error codes upstream knows (src/lib/account/error-messages.ts).
enum HarborErrorMessages {
    static func message(code: String?, reason: String?, status: Int) -> String {
        switch code {
        case "bad_credentials": return "Wrong username or password."
        case "username_taken": return "That username is taken."
        case "banned": return "This account is banned."
        case "rate_limited", "slow_down": return "Too many attempts. Wait a moment and try again."
        case "auth_required", "refresh_invalid": return "Please sign in again."
        case "password_too_short": return "Password is too short."
        case "stremio_already_bound": return "That Stremio account is already linked to another Harbor account."
        case "stremio_key_invalid": return "Stremio rejected that sign-in."
        case "validation": return "Invalid \(reason ?? "input")."
        default:
            if code == nil, let reason, !reason.isEmpty { return reason }
            return code.map { "Harbor error: \($0)" } ?? "Harbor request failed (\(status))."
        }
    }
}
