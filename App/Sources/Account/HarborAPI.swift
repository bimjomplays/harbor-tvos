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
/// (device-flow pass 5) Upstream's own copy and order (accountErrorMessage): the TV had its own
/// shorter lines ("That username is taken.", "Invalid taken.", "Harbor error: handle_taken"),
/// which no catalog translates and which named the raw code. Now BY_REASON, then BY_CODE, then a
/// network failure, then the server's own text, then "Something went wrong. Try again.".
enum HarborErrorMessages {
    /// error-messages.ts BY_CODE.
    private static let byCode: [String: String] = [
        "username_taken": "That username is already taken. Try a different one.",
        "bad_credentials": "That username and password don't match. Check both and try again.",
        "banned": "This account has been suspended. Reach out to support if you think that's wrong.",
        "rate_limited": "Too many attempts in a row. Wait a minute, then try again.",
        "auth_required": "Please sign in again to continue.",
        "recovery_invalid": "That username and recovery key don't match.",
        "refresh_invalid": "Your session expired. Sign in again.",
        "handle_locked": "Your handle is locked. Contact support to change it.",
        "handle_reserved": "That handle is reserved. Pick a different one.",
        "handle_too_short": "Handles need at least 3 characters.",
        "handle_too_long": "That handle is too long. Use at most 24 characters.",
        "handle_invalid": "Handles can use letters, numbers, and single hyphens only.",
        "handle_taken": "That handle is already taken. Try one of the suggestions.",
        "handle_cooldown_other": "Someone released that handle recently. It frees up 14 days after they dropped it.",
        "handle_cooldown": "You changed your handle recently. You can change it again after the cooldown.",
        "stremio_already_bound": "That Stremio account is already linked to a different Harbor account. Unlink it there first.",
        "stremio_key_invalid": "That Stremio sign-in did not go through. Try again.",
        "stremio_anonymous": "Sign in to a real Stremio account, not a guest, to verify.",
        "stremio_unreachable": "Could not reach Stremio right now. Try again in a moment.",
        "challenge_invalid": "That verification attempt expired. Start it again.",
        "password_required": "Set a password before unlinking, so you don't get locked out.",
        "no_image": "Choose an image file first.",
        "bad_image": "That file could not be read as an image. Try a PNG, JPG, or WEBP.",
        "slow_down": "You're doing that too fast. Wait a moment and try again.",
        "blocked_text": "That text isn't allowed. Try different wording.",
        "password_too_short": "Your password needs to be at least 8 characters.",
    ]
    /// error-messages.ts BY_REASON.
    private static let byReason: [String: String] = [
        "password_too_short": "Your password needs to be at least 8 characters.",
        "too-short": "That name is too short. Use at least 3 characters.",
        "invalid": "That name has characters that aren't allowed. Stick to letters, numbers, and underscores.",
        "reserved": "That name is reserved. Pick a different one.",
        "taken": "That name is already taken. Try another.",
        "profanity": "Please choose a different name.",
        "max-length": "That name is too long.",
    ]
    private static let validationKey = "Please check the details you entered and try again."
    private static let networkKey = "Couldn't reach Harbor. Check your connection and try again."
    private static let genericKey = "Something went wrong. Try again."

    /// `code` is the server's code (or its snake_case message, AccountStore.translate); `reason`
    /// its reason, or its message / the engine's error line when there is no code.
    static func message(code: String?, reason: String?, status: Int) -> String {
        let c: String = (code ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let r: String = (reason ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if c == "validation" { return T(byReason[r] ?? validationKey) }
        if let key = byReason[r] { return T(key) }
        if let key = byCode[c] { return T(key) }
        // isNetworkError: a fetch that never reached the server ("Load failed", a TypeError).
        let lower: String = r.lowercased()
        if c.isEmpty, lower.hasPrefix("typeerror") || lower.contains("failed to fetch") || lower.contains("networkerror") || lower.contains("load failed") {
            return T(networkKey)
        }
        if c.isEmpty, !r.isEmpty { return r }
        // SNAKE_CODE_RE: an unknown code reads as the generic line, not as "handle_whatever".
        if c.range(of: "^[a-z0-9]+(_[a-z0-9]+)+$", options: .regularExpression) != nil { return T(genericKey) }
        if !c.isEmpty { return c }
        return T(genericKey)
    }
}
