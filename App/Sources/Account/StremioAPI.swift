import Foundation

/// Stremio's official API (api.strem.io), mirroring src/lib/stremio.ts and src/lib/addons.ts.
private struct Envelope<R: Decodable>: Decodable {
    struct Err: Decodable { var message: String? }
    var error: Err?
    var result: R?
}

enum StremioAPI {
    static let base = URL(string: "https://api.strem.io/api")!

    struct User: Codable, Equatable {
        var _id: String
        var email: String
        var fullname: String?
        var avatar: String?
    }

    struct Failure: Error, LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    static func login(email: String, password: String) async throws -> (authKey: String, user: User) {
        struct Out: Codable { var authKey: String; var user: User }
        let o: Out = try await call("login", ["email": email, "password": password, "facebook": false])
        return (o.authKey, o.user)
    }

    static func getUser(authKey: String) async throws -> User {
        try await call("getUser", ["authKey": authKey])
    }

    /// Raw addon collection; kept as JSON so nothing upstream relies on is lost.
    static func addonCollection(authKey: String) async throws -> [AnyJSON] {
        struct Out: Codable { var addons: [AnyJSON] }
        let o: Out = try await call("addonCollectionGet", ["authKey": authKey, "type": "user", "update": false])
        return o.addons
    }

    private static func call<T: Decodable>(_ path: String, _ body: [String: Any]) async throws -> T {
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 20
        let (data, resp) = try await URLSession.shared.data(for: req)
        let env = try JSONDecoder().decode(Envelope<T>.self, from: data)
        if let err = env.error { throw Failure(message: err.message ?? "Stremio request failed") }
        guard let result = env.result else {
            throw Failure(message: "stremio \(path) failed (\((resp as? HTTPURLResponse)?.statusCode ?? 0))")
        }
        return result
    }
}
