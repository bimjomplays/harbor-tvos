import Foundation
import Combine

/// The Harbor account session on this Apple TV. One account per device (upstream keys the
/// session per local profile, but every profile of one install shares the same account in practice).
@MainActor
final class AccountStore: ObservableObject {
    struct Session: Codable, Equatable {
        var token: String
        var refresh: String?
        var refreshedAt: Double
        var user: HarborAPI.User
    }

    static let shared = AccountStore()
    private static let key = "harbor.theme-session"
    /// Proactive refresh cadence from upstream (SESSION_REFRESH_MS = 6 h).
    private static let refreshInterval: TimeInterval = 6 * 60 * 60

    @Published private(set) var session: Session?
    @Published private(set) var busy = false

    private var refreshTask: Task<Void, Never>?

    private init() {
        if let raw = SecretStore.get(Self.key), let data = raw.data(using: .utf8) {
            session = try? JSONDecoder().decode(Session.self, from: data)
        }
        armRefresh()
    }

    var isSignedIn: Bool { session != nil }

    func signIn(username: String, password: String) async throws {
        busy = true; defer { busy = false }
        let r = try await HarborAPI.login(username: username, password: password)
        apply(r)
    }

    func register(username: String, password: String) async throws {
        busy = true; defer { busy = false }
        let r = try await HarborAPI.register(username: username, password: password)
        apply(r)
    }

    func signOut() {
        session = nil
        SecretStore.remove(Self.key)
        refreshTask?.cancel()
    }

    /// A bearer token for one request. Refreshes first when overdue.
    func token() async throws -> String {
        guard var s = session else { throw HarborAPI.APIError(status: 401, code: "auth_required", reason: nil) }
        if Date().timeIntervalSince1970 - s.refreshedAt > Self.refreshInterval, let refresh = s.refresh {
            if let rotated = try? await HarborAPI.refresh(refresh) {
                s.token = rotated.token; s.refresh = rotated.refresh; s.refreshedAt = Date().timeIntervalSince1970
                save(s)
            }
        }
        return s.token
    }

    /// One refresh-and-retry, as upstream's authenticatedFetch does.
    func withToken<T>(_ body: (String) async throws -> T) async throws -> T {
        let t = try await token()
        do {
            return try await body(t)
        } catch let e as HarborAPI.APIError where e.status == 401 {
            guard let s = session, let refresh = s.refresh else { throw e }
            do {
                let rotated = try await HarborAPI.refresh(refresh)
                var next = s
                next.token = rotated.token; next.refresh = rotated.refresh; next.refreshedAt = Date().timeIntervalSince1970
                save(next)
                return try await body(rotated.token)
            } catch let re as HarborAPI.APIError where re.status == 401 && re.code == "refresh_invalid" {
                signOut()
                throw re
            }
        }
    }

    /// Simulator fixtures only: an in-memory session that never reaches the Keychain.
    func installFixture(user: HarborAPI.User) {
        session = Session(token: "fixture", refresh: nil, refreshedAt: Date().timeIntervalSince1970, user: user)
    }

    private func apply(_ r: HarborAPI.AuthResult) {
        save(Session(token: r.token, refresh: r.refresh, refreshedAt: Date().timeIntervalSince1970, user: r.user))
        armRefresh()
    }

    private func save(_ s: Session) {
        session = s
        if let data = try? JSONEncoder().encode(s), let raw = String(data: data, encoding: .utf8) {
            try? SecretStore.set(raw, for: Self.key)
        }
    }

    private func armRefresh() {
        refreshTask?.cancel()
        guard session != nil else { return }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30 * 60))
                _ = try? await self?.token()
            }
        }
    }
}
