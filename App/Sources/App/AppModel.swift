import Foundation
import Combine
import SwiftUI

/// Top-level flow: boot → onboarding (first run) → who's watching → shell.
@MainActor
final class AppModel: ObservableObject {
    enum Stage: Equatable { case boot, onboarding, whoIsWatching, shell }

    @Published var stage: Stage = .boot
    @Published var room: Room = .home
    /// Quick panel "Search": the Search room opens with this query.
    @Published var searchSeed: String?
    /// lib/deep-link.ts: a title opened from another app (harbor:// or stremio://).
    @Published var deepLinkMeta: Meta?
    @Published var deepLinkNote: String?
    /// lib/deep-link.ts parseHarborList: a shared list opened from another app.
    @Published var deepLinkList: Social.ListRef?

    /// parseHarborOpen / parseStremioOpen / emitDeepLinkInstall, as the TV receives them.
    /// (lifecycle pass) A link that cold-launches the app arrives while `boot()` is still loading
    /// settings, the theme and the account: it only records what to open, and boot's own
    /// `goToWhoOrShell()` shows it. It used to jump to the shell mid-boot, which then rebuilt
    /// under the opened title as the theme and language landed (and the intro wall rose over it).
    func handle(url: URL) {
        let raw = url.absoluteString
        let scheme = (url.scheme ?? "").lowercased()
        guard scheme == "harbor" || scheme == "stremio" else { return }
        let path = raw.dropFirst(scheme.count + 3)   // "scheme://"
        let parts = path.split(separator: "/").map { String($0).removingPercentEncoding ?? String($0) }.filter { !$0.isEmpty }
        if parts.first == "detail", parts.count >= 3 {
            deepLinkMeta = Meta(id: parts[2], type: parts[1], name: "", poster: nil, background: nil, logo: nil, description: nil, releaseInfo: nil, releaseDate: nil,
                                inTheaters: nil, imdbRating: nil, tmdbScore: nil, runtime: nil, genres: nil, adult: nil, isCollection: nil, providerBadge: nil, videos: nil)
            if stage != .shell, stage != .boot, onboardingDone, !profiles.profiles.isEmpty { goToWhoOrShell() }
            return
        }
        if scheme == "harbor", parts.first == "list", parts.count >= 3, !parts[1].isEmpty, !parts[2].isEmpty {
            deepLinkList = Social.ListRef(handle: parts[1], listId: parts[2])
            if stage != .shell, stage != .boot, onboardingDone, !profiles.profiles.isEmpty { goToWhoOrShell() }
            return
        }
        if scheme == "stremio", raw.hasSuffix("manifest.json") {
            // (addons bug pass) addons.tsx onDeepLinkInstall → setInstallModal({ kind: "install", url }):
            // the link opens the install dialog (AddonConfigureView reads it like install-modal's
            // tryResolve: new, update, or a re-configure that replaces the old entry) and nothing is
            // installed until Install is pressed. It used to install straight away, with no word to
            // the viewer, whatever sent the link and whichever profile (a kid's too) was active, and
            // a re-configured addon arrived as a second copy. ShellView shows it; like upstream's
            // pendingUrl it waits for the shell when the link lands earlier.
            deepLinkInstall = DeepLinkInstall(url: raw)
            if stage != .shell, stage != .boot, onboardingDone, !profiles.profiles.isEmpty { goToWhoOrShell() }
        }
    }

    /// lib/deep-link.ts emitDeepLinkInstall's pending URL, until ShellView's install dialog takes it.
    struct DeepLinkInstall: Identifiable, Equatable {
        let id = UUID()
        let url: String
    }
    @Published var deepLinkInstall: DeepLinkInstall?

    /// Rooms read through this; swapped for the engine-backed source in Stage 2.
    var browseSource: BrowseSource = (Fixtures.active && !Fixtures.liveRooms) ? FixtureBrowseSource() : EngineBrowseSource()
    let account = AccountStore.shared
    let profiles = ProfilesStore.shared
    let sync = SyncReader.shared

    private var bag = Set<AnyCancellable>()

    /// `isBrowseLayer`: the PiP browse layer's own model (Player/PiPBrowse.swift). It leaves the
    /// app-wide reloads a profile switch makes to the app's model (which runs them once), and the
    /// layer goes down on a switch anyway.
    init(isBrowseLayer: Bool = false) {
        // A pull can adopt a roster that no longer holds the active profile (deleted on another
        // device): the engine clears the active id and the shell must go back to who-is-watching.
        profiles.$activeId.dropFirst().receive(on: RunLoop.main).sink { [weak self] id in
            guard let self, id == nil, self.stage == .shell else { return }
            self.stage = .whoIsWatching
        }.store(in: &bag)
        guard !isBrowseLayer else { return }
        // (profiles bug pass) The Harbor session is per profile (theme-auth sessionKey). Boot starts
        // profile sync only when the restored profile is signed in, and Sign out stops it, but
        // nothing started it again when a signed-in profile became active later (a switch to the
        // primary, which holds the account's session): sync then stayed off for the whole run,
        // edits never uploaded. Upstream's ProfileSyncRunner is always mounted and re-pulls on
        // every author change; here a session appearing after boot starts it (idempotent).
        account.$session.map { $0 != nil }.removeDuplicates().dropFirst().receive(on: RunLoop.main).sink { [weak self] signedIn in
            guard let self, signedIn, self.stage != .boot, !Fixtures.active else { return }
            Task { @MainActor in await self.sync.start() }
        }.store(in: &bag)
        // Settings (and so the theme and display language) can be per profile: a switch re-reads them.
        profiles.$activeId.dropFirst().removeDuplicates().receive(on: RunLoop.main).sink { id in
            guard id != nil, !Fixtures.active else { return }
            Task { @MainActor in
                await SettingsBridge.shared.load()
                await ThemeStore.shared.load()
                // Watch Together's relay lives in each profile's settings too (togetherRelayUrl).
                await TogetherModel.shared.attach()
            }
        }.store(in: &bag)
    }

    private static let onboardingKey = "harbor.onboarding.bp"
    var onboardingDone: Bool {
        get { Prefs.get(Bool.self, for: Self.onboardingKey) ?? false }
        set { try? Prefs.set(newValue, for: Self.onboardingKey) }
    }

    func boot() async {
        ActivityMonitor.install()
        Fixtures.installIfRequested(into: self)
        if !Fixtures.active {
            // (lifecycle pass) The first `HarborEngine.shared` evaluates the ~4.4 MB bundle and reads
            // every stored key; SettingsBridge.load() below made it on the main actor, freezing the
            // boot splash (and every press) for seconds on an Apple TV. Build it off the main thread.
            _ = await Task.detached(priority: .userInitiated) { (try? HarborEngine.sharedOrThrow()) != nil }.value
            // Background/foreground and the network path reach the engine (visibilitychange, online).
            AppLifecycle.shared.start()
            await SettingsBridge.shared.load()
            // Stage 9: the profile's theme is painted from the first Big Picture frame.
            await ThemeStore.shared.load()
            profiles.attachEngine()
            await account.attachEngine()
            if account.isSignedIn { await refreshRosterAtBoot() }
            // App.tsx MediaServerSyncRunner: due home-server indexes at launch, then every 15 minutes.
            _ = try? await HarborEngine.shared.callJSON("homeServers.startRunner", [])
            // Stage 10: the Watch Together room client (engine/together.ts) for the active profile.
            await TogetherModel.shared.attach()
        }
        try? await Task.sleep(for: .seconds(Fixtures.active ? 0.2 : 1.2))
        if let fixed = Fixtures.stage {
            if Fixtures.openSpikes { room = .settings }
            stage = fixed
            return
        }
        if !onboardingDone { stage = .onboarding; return }
        goToWhoOrShell()
    }

    func finishOnboarding() {
        onboardingDone = true
        if profiles.profiles.isEmpty { profiles.seedIfEmpty(name: account.session?.user.username ?? "Harbor") }
        attachPendingStremio()
        goToWhoOrShell()
    }

    /// A Stremio sign-in made before profiles existed goes to the primary profile.
    func attachPendingStremio() {
        guard let s = PendingStremio.session,
              let target = profiles.profiles.first(where: { $0.isPrimary }) ?? profiles.profiles.first else { return }
        profiles.setStremioSession(s, for: target.id)
        PendingStremio.session = nil
    }

    func goToWhoOrShell() {
        stage = profiles.active == nil ? .whoIsWatching : .shell
    }

    func switchProfile() {
        profiles.deselect()
        stage = .whoIsWatching
    }

    /// One awaited pull (the engine adopts the roster and Swift reloads it), then the
    /// scheduler keeps syncing in the background. Called after sign-in, on boot, and by Retry.
    func refreshRoster() async {
        let ok = await sync.pull()
        profiles.reloadFromStore()
        if ok {
            // Pull succeeded but the account has no roster yet: this TV seeds the household.
            profiles.seedIfEmpty(name: account.session?.user.username ?? "Harbor")
        }
        await sync.start()
    }

    /// (lifecycle pass) Boot waits for the first pull only so long: on a slow or captive network
    /// each sync request may sit out a whole fetch timeout (30 s of silence, after a token refresh),
    /// and the boot splash waited with it. The pull carries on; a roster it adopts later reaches
    /// ProfilesStore through harbor:roster-applied, and `refreshRoster` still finishes its work.
    private func refreshRosterAtBoot() async {
        let once = BootOnce()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let finish: @MainActor () -> Void = {
                guard !once.done else { return }
                once.done = true
                continuation.resume()
            }
            Task { @MainActor in
                await self.refreshRoster()
                finish()
            }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(Self.bootPullWait))
                finish()
            }
        }
    }
    private static let bootPullWait: Double = 8

    func signOutHarbor() {
        sync.stop()
        account.signOut()
    }
}

enum Room: String, CaseIterable, Identifiable {
    case home, discover, anime, manga, ebook, shows, movies, music, live, sports, search, calendar, library, collections, settings
    var id: String { rawValue }

    var label: String {
        switch self {
        case .home: return "Home"
        case .discover: return "Discover"
        case .anime: return "Anime"
        case .manga: return "Manga"
        case .ebook: return "eBook"
        case .shows: return "Shows"
        case .movies: return "Movies"
        case .music: return "Music"
        case .live: return "Live TV"
        case .sports: return "Sports"
        case .search: return "Search"
        case .calendar: return "Calendar"
        case .library: return "Library"
        case .collections: return "Collections"
        case .settings: return "Settings"
        }
    }
    var icon: String {
        switch self {
        case .home: return "house.fill"
        case .discover: return "safari.fill"
        case .anime: return "sparkles"
        case .manga: return "book.fill"
        case .ebook: return "book.closed.fill"
        case .shows: return "tv"
        case .movies: return "film"
        case .music: return "music.note"
        case .live: return "antenna.radiowaves.left.and.right"
        case .sports: return "sportscourt"
        case .search: return "magnifyingglass"
        case .calendar: return "calendar"
        case .library: return "books.vertical"
        case .collections: return "square.grid.2x2"
        case .settings: return "gearshape.fill"
        }
    }
    /// Which plan stage delivers the room, for the placeholder screens.
    var arrivesIn: Int {
        switch self {
        case .home, .discover, .shows, .movies, .search, .collections: return 2
        case .library, .calendar: return 5
        case .anime: return 7
        case .live: return 8
        case .music: return 12
        case .sports: return 11
        case .manga, .ebook: return 13
        case .settings: return 1
        }
    }
    static var tabs: [Room] { allCases.filter { $0 != .settings } }
}

/// `AppModel.refreshRosterAtBoot`: whichever of the pull and the deadline ends first resumes boot.
private final class BootOnce { var done = false }
