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
        if Fixtures.stage != nil { stage = Fixtures.stage!; return }
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
        case .home: "Home"; case .discover: "Discover"; case .anime: "Anime"; case .shows: "Shows"; case .movies: "Movies"
        case .live: "Live TV"; case .sports: "Sports"; case .search: "Search"; case .library: "Library"
        case .collections: "Collections"; case .settings: "Settings"
        }
    }
    var icon: String {
        switch self {
        case .home: "house.fill"; case .discover: "safari.fill"; case .anime: "sparkles"; case .shows: "tv"
        case .movies: "film"; case .live: "antenna.radiowaves.left.and.right"; case .sports: "sportscourt"
        case .search: "magnifyingglass"; case .library: "books.vertical"; case .collections: "square.grid.2x2"
        case .settings: "gearshape.fill"
        }
    }
    /// Which plan stage delivers the room, for the placeholder screens.
    var arrivesIn: Int {
        switch self {
        case .home, .discover, .shows, .movies, .search, .collections: 2
        case .library: 5; case .anime: 7; case .live: 8; case .sports: 11; case .settings: 1
        }
    }
    static var tabs: [Room] { allCases.filter { $0 != .settings } }
}
