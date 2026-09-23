import Foundation
import Combine

/// The Harbor account session on this Apple TV, mirrored from the engine. Upstream's
/// theme-auth owns the session (per-profile Keychain keys, the 6-hour refresh, 401 retry);
/// Swift never refreshes a token itself, so two refreshers can never race on one rotating
/// refresh token. Before the engine has booted, `session` is a best-effort Keychain read so
/// the boot screen knows whether to pull the roster.
@MainActor
final class AccountStore: ObservableObject {
    struct Session: Codable, Equatable {
        var user: HarborAPI.User
        var token: String
        var hasRefresh: Bool
    }

    static let shared = AccountStore()
    private static let legacyKey = "harbor.theme-session"
    private static let prefix = "harbor.theme-session."

    @Published private(set) var session: Session?
    @Published private(set) var busy = false
    private var unsubscribe: (() -> Void)?

    private init() {
        session = Self.peekKeychain()
    }

    var isSignedIn: Bool { session != nil }

    /// Attach to the running engine: adopt its view of the session, start upstream's refresh
    /// runner, and follow every change it reports.
    func attachEngine() async {
        if unsubscribe == nil {
            unsubscribe = HarborEngine.shared.onEvent { [weak self] type, detail in
                guard type == "harbor:account-changed" else { return }
                self?.session = detail.flatMap { try? $0.decode(Session?.self) } ?? nil
            }
        }
        let current: Session?? = try? await HarborEngine.shared.call("account.session")
        session = current ?? nil
        _ = try? await HarborEngine.shared.callJSON("account.start")
    }

    func signIn(username: String, password: String) async throws {
        busy = true; defer { busy = false }
        do {
            session = try await HarborEngine.shared.call("account.login", [username, password])
        } catch { throw Self.translate(error) }
    }

    func register(username: String, password: String) async throws {
        busy = true; defer { busy = false }
        struct Out: Decodable { var recoveryCode: String; var session: Session? }
        do {
            let out: Out = try await HarborEngine.shared.call("account.register", [username, password])
            session = out.session
        } catch { throw Self.translate(error) }
    }

    func signOut() {
        session = nil
        Task { _ = try? await HarborEngine.shared.callJSON("account.logout") }
    }

    /// A bearer for one native request; the engine rotates it first when overdue.
    func token() async throws -> String {
        let t: String? = try await HarborEngine.shared.call("account.token")
        guard let t else { throw HarborAPI.APIError(status: 401, code: "auth_required", reason: nil) }
        return t
    }

    /// Simulator fixtures only: an in-memory session that never reaches the engine.
    func installFixture(user: HarborAPI.User) {
        session = Session(user: user, token: "fixture", hasRefresh: true)
    }

    /// Whatever session upstream last stored, before the engine is up: the legacy global key
    /// (a sign-in made before any profile existed) or any per-profile key.
    private static func peekKeychain() -> Session? {
        struct Raw: Decodable { var token: String; var refresh: String?; var user: HarborAPI.User }
        var keys = [legacyKey]
        keys += SecretStore.allKeys().filter { $0.hasPrefix(prefix) && !$0.hasSuffix(".repaired.v2") }
        for key in keys {
            if let raw = SecretStore.get(key), let data = raw.data(using: .utf8), let r = try? JSONDecoder().decode(Raw.self, from: data) {
                return Session(user: r.user, token: r.token, hasRefresh: r.refresh != nil)
            }
        }
        return nil
    }

    /// `account.login/register` re-throw API failures as one `harbor-api:{json}` line carrying
    /// upstream's status/code/reason; anything else is shown as the engine reported it.
    private static func translate(_ error: Error) -> Error {
        guard case EngineError.js(let text) = error else { return error }
        let first = text.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? text
        let line = first.hasPrefix("Error: ") ? String(first.dropFirst(7)) : first
        struct Wire: Decodable { var status: Int; var code: String?; var reason: String?; var message: String }
        if line.hasPrefix("harbor-api:"), let w = try? JSONDecoder().decode(Wire.self, from: Data(line.dropFirst(11).utf8)) {
            // The identity API puts the code in `error` (the message) when `code` is absent.
            let code = w.code ?? (w.message.allSatisfy { $0 == "_" || ($0.isLetter && $0.isLowercase) } ? w.message : nil)
            return HarborAPI.APIError(status: w.status, code: code, reason: w.reason ?? (code == nil ? w.message : nil))
        }
        return HarborAPI.APIError(status: 0, code: nil, reason: line)
    }
}
