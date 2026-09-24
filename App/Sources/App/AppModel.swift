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
    func handle(url: URL) {
        let raw = url.absoluteString
        let scheme = (url.scheme ?? "").lowercased()
        guard scheme == "harbor" || scheme == "stremio" else { return }
        let path = raw.dropFirst(scheme.count + 3)   // "scheme://"
        let parts = path.split(separator: "/").map { String($0).removingPercentEncoding ?? String($0) }.filter { !$0.isEmpty }
        if parts.first == "detail", parts.count >= 3 {
            deepLinkMeta = Meta(id: parts[2], type: parts[1], name: "", poster: nil, background: nil, logo: nil, description: nil, releaseInfo: nil, releaseDate: nil,
                                inTheaters: nil, imdbRating: nil, tmdbScore: nil, runtime: nil, genres: nil, adult: nil, isCollection: nil, providerBadge: nil, videos: nil)
            if stage != .shell, onboardingDone, !profiles.profiles.isEmpty { goToWhoOrShell() }
            return
        }
        if scheme == "harbor", parts.first == "list", parts.count >= 3, !parts[1].isEmpty, !parts[2].isEmpty {
            deepLinkList = Social.ListRef(handle: parts[1], listId: parts[2])
            if stage != .shell, onboardingDone, !profiles.profiles.isEmpty { goToWhoOrShell() }
            return
        }
        if scheme == "stremio", raw.hasSuffix("manifest.json") {
            // stremio://host/path/manifest.json installs the addon at https://host/path/manifest.json.
            let https = "https://" + String(path)
            Task {
                struct Result: Decodable { var replaced: Bool; var syncedToStremio: Bool }
                if let r: Result = try? await HarborEngine.shared.call("addonStore.installFromUrl", [https]) {
                    HarborEngine.shared.emitEvent("harbor:addons-changed")
                    deepLinkNote = r.replaced ? "Addon updated." : "Addon installed."
                } else { deepLinkNote = "Couldn't install that addon." }
            }
        }
    }

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
            await SettingsBridge.shared.load()
            // Stage 9: the profile's theme is painted from the first Big Picture frame.
            await ThemeStore.shared.load()
            profiles.attachEngine()
            await account.attachEngine()
            if account.isSignedIn { await refreshRoster() }
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
