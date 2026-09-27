import Foundation

/// Fake data for simulator screenshots: `--fixtures <stage>` where stage is onboarding|who|shell.
/// Nothing here touches the network. `roomfail` is the shell with every room's rows failing
/// (FixtureBrowseSource), for the failure card's Try again. `calfail` is the shell with every
/// Calendar month read failing, `detail` the shell whose series titles carry a one-season episode
/// list (DetailModel reads it instead of Cinemeta), and `kidsfail` is Who's watching with the kids
/// page failing to build (NavigationTests3). `discfail` is the shell with every Discover build
/// failing, and `bands` the shell whose Home carries the Your streaming, Your addons and
/// Collections band rows (NavigationTests4). `ebook` is the shell with a Gutendex source already
/// installed (EBookStore.addGutendex, a local config write) and the eBook tab turned on, and
/// `music` is the shell with a fixture track already handed to MusicPlayer, so the dock and Now
/// Playing have something to open (NavigationTests5).
@MainActor
enum Fixtures {
    static var active: Bool { ProcessInfo.processInfo.arguments.contains("--fixtures") }
    static var stage: AppModel.Stage? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "--fixtures"), i + 1 < args.count else { return nil }
        switch args[i + 1] {
        case "onboarding": return .onboarding
        case "who", "kidsfail": return .whoIsWatching
        case "shell", "spikes", "live", "roomfail", "calfail", "detail", "discfail", "bands", "ebook", "music": return .shell
        default: return nil
        }
    }

    static var openSpikes: Bool { ProcessInfo.processInfo.arguments.contains("spikes") }
    /// `--fixtures live`: fixture profiles, but rooms come from the real engine (network).
    static var liveRooms: Bool { ProcessInfo.processInfo.arguments.contains("live") }
    /// `--fixtures ebook`: EBookGate is turned on and a Gutendex source installed at boot, so the
    /// room's browse chips, Collections card and Sources page render without ever asking the real
    /// Gutendex API for books (NavigationTests5).
    static var installEBookSource: Bool { ProcessInfo.processInfo.arguments.contains("ebook") }
    /// `--fixtures music`: MusicPlayer starts a fixture track at boot. Its connector matches no real
    /// source, so it resolves to the same "couldn't play" phase a real mismatched source would; Now
    /// Playing and the dock already draw that state (NavigationTests5).
    static var startMusicFixture: Bool { ProcessInfo.processInfo.arguments.contains("music") }
    /// `--query <text>` prefills the Search room for screenshots.
    static var query: String? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "--query"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    /// `--new-profile-name <text>` prefills the create-profile form's Name (NavigationTests6: XCUITest
    /// cannot type into a tvOS TextField without the system keyboard up, so the test seeds it here
    /// the same way `--query` seeds Search).
    static var newProfileName: String? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "--new-profile-name"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    /// `--new-playlist-name <text>` prefills MusicLibraryView's create-playlist form Name the same
    /// way `--new-profile-name` seeds the profile editor (NavigationTests7: no system keyboard here
    /// either).
    static var newPlaylistName: String? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "--new-playlist-name"), i + 1 < args.count else { return nil }
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
            // A parent PIN on the kid, so leaving the kids shell asks for it (NavigationTests2).
            .init(id: "p_fix_3", syncId: "s_3", name: "Kiddo", avatar: "/kids/avatars/kid-2.webp", color: "#fbbf24", isPrimary: false, kid: .init(age: 7, curfewMinutes: nil, parentPinHash: ProfilesStore.hashPin("4321")), passwordHash: nil, createdAt: now + 2),
        ], activeId: stage == .shell ? "p_fix_1" : nil)
        if !installEBookSource {
            // (CI fix 2026-09-27) The gate is a UserDefaults key: `ebook` runs left it on for every
            // later fixture launch on the same simulator, and tests that count the bar's tabs
            // (ScreenshotTests.testSearchRoom) landed one tab short.
            UserDefaults.standard.removeObject(forKey: EBookGate.key)
        } else {
            UserDefaults.standard.set(true, forKey: EBookGate.key)
            // A local config write (lib/ebook/sources.ts addEBookGutendex): no network, so this is
            // safe to fire and forget before the eBook tab is even reachable.
            Task {
                let installed: EBookState? = try? await HarborEngine.shared.call("ebook.addGutendex")
                _ = installed
            }
        }
        if startMusicFixture {
            MusicPlayer.shared.play(MusicTrack(id: "fixture-song", title: "Fixture Song", artist: "Fixture Artist", album: "Fixture Album",
                                                artwork: nil, durationSeconds: 180, durationLabel: "3:00", connectorId: "fixture", sourceId: nil,
                                                playbackUrl: nil, explicit: false, version: nil, mediaKind: nil, collectionOrigin: nil))
        }
    }
}
