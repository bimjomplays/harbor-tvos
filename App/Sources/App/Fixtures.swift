import Foundation

/// Fake data for simulator screenshots: `--fixtures <stage>` where stage is onboarding|who|shell.
/// Nothing here touches the network.
@MainActor
enum Fixtures {
    static var active: Bool { ProcessInfo.processInfo.arguments.contains("--fixtures") }
    static var stage: AppModel.Stage? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "--fixtures"), i + 1 < args.count else { return nil }
        switch args[i + 1] {
        case "onboarding": return .onboarding
        case "who": return .whoIsWatching
        case "shell", "spikes", "live": return .shell
        default: return nil
        }
    }

    static var openSpikes: Bool { ProcessInfo.processInfo.arguments.contains("spikes") }
    /// `--fixtures live`: fixture profiles, but rooms come from the real engine (network).
    static var liveRooms: Bool { ProcessInfo.processInfo.arguments.contains("live") }
    /// `--query <text>` prefills the Search room for screenshots.
    static var query: String? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "--query"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    static func installIfRequested(into app: AppModel) {
        guard active, let stage else { return }
        app.profiles.reset()
        if stage == .onboarding { app.account.signOut(); return }
        app.account.installFixture(user: HarborAPI.User(id: "u_fixture", username: "skipper", avatar: nil, handle: "skipper", verified: true, stremioLinked: true))
        let now = Date().timeIntervalSince1970 * 1000
        app.profiles.installFixture([
            .init(id: "p_fix_1", syncId: "s_1", name: "Skipper", avatar: "/avatars/harbor_person_03.webp", color: "#7dd3fc", isPrimary: true, kid: nil, passwordHash: nil, createdAt: now),
            .init(id: "p_fix_2", syncId: "s_2", name: "Guest", avatar: nil, color: "#a78bfa", isPrimary: false, kid: nil, passwordHash: ProfilesStore.hashPin("1234"), createdAt: now + 1),
            .init(id: "p_fix_3", syncId: "s_3", name: "Kiddo", avatar: "/kids/avatars/kid-2.webp", color: "#fbbf24", isPrimary: false, kid: .init(age: 7, curfewMinutes: nil), passwordHash: nil, createdAt: now + 2),
        ], activeId: stage == .shell ? "p_fix_1" : nil)
    }
}
