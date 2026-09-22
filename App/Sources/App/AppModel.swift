import Foundation
import Combine
import SwiftUI

/// Top-level flow: boot → onboarding (first run) → who's watching → shell.
@MainActor
final class AppModel: ObservableObject {
    enum Stage: Equatable { case boot, onboarding, whoIsWatching, shell }

    @Published var stage: Stage = .boot
    @Published var room: Room = .home

    let account = AccountStore.shared
    let profiles = ProfilesStore.shared
    let sync = SyncReader.shared

    private static let onboardingKey = "harbor.onboarding.bp"
    var onboardingDone: Bool {
        get { Prefs.get(Bool.self, for: Self.onboardingKey) ?? false }
        set { try? Prefs.set(newValue, for: Self.onboardingKey) }
    }

    func boot() async {
        Fixtures.installIfRequested(into: self)
        if account.isSignedIn && !Fixtures.active { await refreshRoster() }
        try? await Task.sleep(for: .seconds(Fixtures.active ? 0.2 : 1.2))
        if let fixed = Fixtures.stage { stage = fixed; return }
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

    /// Pull the account roster and adopt it. Called after sign-in and on every boot while signed in.
    func refreshRoster() async {
        await sync.pull()
        if let roster = sync.roster {
            profiles.adopt(roster: roster)
        } else if sync.phase == .idle {
            // Signed in, pull succeeded, but the account has no roster yet: keep local profiles.
            profiles.seedIfEmpty(name: account.session?.user.username ?? "Harbor")
        }
    }

    func signOutHarbor() {
        account.signOut()
        sync.clear()
    }
}

enum Room: String, CaseIterable, Identifiable {
    case home, discover, anime, shows, movies, live, sports, search, library, collections, settings
    var id: String { rawValue }

    var label: String {
        switch self {
        case .home: return "Home"
        case .discover: return "Discover"
        case .anime: return "Anime"
        case .shows: return "Shows"
        case .movies: return "Movies"
        case .live: return "Live TV"
        case .sports: return "Sports"
        case .search: return "Search"
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
        case .shows: return "tv"
        case .movies: return "film"
        case .live: return "antenna.radiowaves.left.and.right"
        case .sports: return "sportscourt"
        case .search: return "magnifyingglass"
        case .library: return "books.vertical"
        case .collections: return "square.grid.2x2"
        case .settings: return "gearshape.fill"
        }
    }
    /// Which plan stage delivers the room, for the placeholder screens.
    var arrivesIn: Int {
        switch self {
        case .home, .discover, .shows, .movies, .search, .collections: return 2
        case .library: return 5
        case .anime: return 7
        case .live: return 8
        case .sports: return 11
        case .settings: return 1
        }
    }
    static var tabs: [Room] { allCases.filter { $0 != .settings } }
}
