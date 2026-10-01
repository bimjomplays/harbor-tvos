import Foundation
import Combine

/// (device build 355) TMDB refused the saved key ("Invalid API key", 401) on every call, while
/// Settings and the setup page still read "TMDB: On" / "Connected": Detail silently lost its cast,
/// More Like This, trailers and facts. The engine's own `[tmdb] 401` log line marks the key the
/// viewer saved as rejected until a different key is saved.
@MainActor
final class TmdbHealth: ObservableObject {
    static let shared = TmdbHealth()

    /// The key TMDB last refused (compared, never shown or stored).
    @Published private var refusedKey: String?

    /// TMDB refused the key saved now.
    var rejected: Bool {
        guard let refusedKey else { return false }
        let key: String = SettingsBridge.shared.slice.tmdbKey.trimmingCharacters(in: .whitespaces)
        return !key.isEmpty && key == refusedKey
    }

    /// A key test (Settings, the TMDB sheet) logs TMDB's 401 for the key it tried, which may not be
    /// the saved one: SettingsBridge.verifyTmdb clears the mark afterwards unless the saved key failed.
    func forgive() { if refusedKey != nil { refusedKey = nil } }

    /// EngineHost's log hook: TMDB's 401 line names the saved key as refused.
    nonisolated static func noteLog(_ message: String) {
        guard message.contains("[tmdb] 401") else { return }
        Task { @MainActor in
            let key: String = SettingsBridge.shared.slice.tmdbKey.trimmingCharacters(in: .whitespaces)
            if !key.isEmpty, shared.refusedKey != key { shared.refusedKey = key }
        }
    }
}
