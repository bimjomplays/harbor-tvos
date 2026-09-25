import Foundation
import Combine
import SwiftUI

/// Top-level flow: boot → onboarding (first run) → who's watching → shell.
@MainActor
final class AppModel: ObservableObject {
    enum Stage: Equatable { case boot, onboarding, whoIsWatching, shell }

    @Published var stage: Stage = .boot {
        didSet { if stage != .shell { clearShownLinks() } }
    }
    @Published var room: Room = .home
    /// (review 12) A layer drawn in place over the room is up (the Collections room's collection
    /// overlay): bp-shell passes no onTab while a layer is up, and the layer holds the focus, so the
    /// top bar takes no focus and LB/RB turn no tabs until it closes.
    @Published var roomLayer = false
    /// Quick panel "Search": the Search room opens with this query.
    @Published var searchSeed: String?
    /// lib/deep-link.ts: a title opened from another app (harbor:// or stremio://).
    @Published var deepLinkMeta: Meta?
    @Published var deepLinkNote: String?
    /// lib/deep-link.ts parseHarborList: a shared list opened from another app.
    @Published var deepLinkList: Social.ListRef?

    /// parseHarborOpen / parseStremioOpen / emitDeepLinkInstall, as the TV receives them.
    /// (deep links over covers) A link is only recorded here, in DeepLinkQueue; the shell on screen
    /// shows it (`showWaitingLink`) once nothing is presented over it. It used to be put straight
    /// into the shell's cover binding: over a detail page, the player, a Settings or Addons cover, a
    /// collection page or a page in the PiP browse layer, tvOS drops a second presentation from a
    /// view that is already presenting, so the link never showed (and the binding stayed set).
    /// The link also waits through boot (lifecycle pass: it no longer jumps to the shell mid-boot),
    /// setup and Who's watching (review 6: the chooser opens over a profile that stays active, and a
    /// link must not close it into that profile; upstream's picker layer stays up over it).
    /// (review 15) The old showLinkTarget() is gone: its guard (setup up and already finished)
    /// could never hold, so it never moved a stage.
    func handle(url: URL) {
        let raw = url.absoluteString
        let scheme = (url.scheme ?? "").lowercased()
        guard scheme == "harbor" || scheme == "stremio" else { return }
        let path = raw.dropFirst(scheme.count + 3)   // "scheme://"
        let parts = path.split(separator: "/").map { String($0).removingPercentEncoding ?? String($0) }.filter { !$0.isEmpty }
        if parts.first == "detail", parts.count >= 3 {
            // lib/view.tsx openMeta: the title already on top is not opened again.
            guard deepLinkMeta?.id != parts[2] else { return }
            DeepLinkQueue.shared.add(.title(type: parts[1], id: parts[2]))
            return
        }
        if scheme == "harbor", parts.first == "list", parts.count >= 3, !parts[1].isEmpty, !parts[2].isEmpty {
            let ref = Social.ListRef(handle: parts[1], listId: parts[2])
            // lib/view.tsx openList: the list already on top is not opened again.
            guard deepLinkList != ref else { return }
            DeepLinkQueue.shared.add(.list(ref))
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
            guard deepLinkInstall?.url != raw else { return }
            DeepLinkQueue.shared.add(.install(raw))
        }
    }

    /// (deep links over covers) The shell on screen shows the newest waiting link it may show, once
    /// `clear` says nothing is presented over it (the caller polls: covers are not observable). One
    /// at a time: the next waits until this one's page closes, so no two presentations race and none
    /// is dropped. Taking the link out of the queue and setting the binding happen together on the
    /// main actor, so a link opens once. A kid's shell (`kidShell`) takes titles only; a shared list
    /// or an addon install waits for an adult shell (App.tsx pins a kid to kids / meta pages, and a
    /// kid never gets the install dialog).
    @discardableResult
    func showWaitingLink(kidShell: Bool, clear: Bool) -> Bool {
        guard stage == .shell, clear, deepLinkMeta == nil, deepLinkList == nil, deepLinkInstall == nil,
              let link = DeepLinkQueue.shared.take(kidShell: kidShell) else { return false }
        switch link {
        case .title(let type, let id):
            deepLinkMeta = Meta(id: id, type: type, name: "", poster: nil, background: nil, logo: nil, description: nil, releaseInfo: nil, releaseDate: nil,
                                inTheaters: nil, imdbRating: nil, tmdbScore: nil, runtime: nil, genres: nil, adult: nil, isCollection: nil, providerBadge: nil, videos: nil)
        case .list(let ref):
            deepLinkList = ref
        case .install(let raw):
            deepLinkInstall = DeepLinkInstall(url: raw)
        }
        return true
    }

    /// The shell's deep-link covers go with the shell when the stage leaves it (Who's watching, setup):
    /// the bindings are cleared, so a page the viewer never closed does not come back (or block the
    /// next link) when a shell appears again.
    private func clearShownLinks() {
        if deepLinkMeta != nil { deepLinkMeta = nil }
        if deepLinkList != nil { deepLinkList = nil }
        if deepLinkInstall != nil { deepLinkInstall = nil }
    }

    /// lib/deep-link.ts emitDeepLinkInstall's pending URL, until ShellView's install dialog takes it.
    struct DeepLinkInstall: Identifiable, Equatable {
        let id = UUID()
        let url: String
    }
    @Published var deepLinkInstall: DeepLinkInstall?

    /// A link this shell may show is waiting (ShellView / KidsShellView poll while one is).
    func hasWaitingLink(kidShell: Bool) -> Bool { DeepLinkQueue.shared.hasWaiting(kidShell: kidShell) }

    /// Rooms read through this; swapped for the engine-backed source in Stage 2.
    var browseSource: BrowseSource = (Fixtures.active && !Fixtures.liveRooms) ? FixtureBrowseSource() : EngineBrowseSource()
    let account = AccountStore.shared
    let profiles = ProfilesStore.shared
    let sync = SyncReader.shared

    private var bag = Set<AnyCancellable>()
    private let isBrowseLayer: Bool

    /// `isBrowseLayer`: the PiP browse layer's own model (Player/PiPBrowse.swift). It leaves the
    /// app-wide reloads a profile switch makes to the app's model (which runs them once), and the
    /// layer goes down on a switch anyway.
    init(isBrowseLayer: Bool = false) {
        self.isBrowseLayer = isBrowseLayer
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
        // (review 14) After Finish later the app runs on profiles while setup stays unfinished. A kid
        // profile never gets setup (App.tsx pins a kid to the Kids surface, where bp-shell's
        // onboarding gate is not mounted): it opened adult setup over the kid's profile, before the
        // curfew lock started.
        // (review 14 follow-up) bp-shell.tsx mounts BpWhoIsWatching over BpOnboarding (z-80 over
        // z-60), so a setup resumed over existing profiles waits under the launch path: the "Start
        // as" default, Who's watching at launch (a PIN profile asks for its PIN) and a kid's PIN lock
        // come first, and setup then edits the profile that was picked. First run (no profiles yet)
        // still opens setup straight away.
        if !onboardingDone {
            if profiles.profiles.isEmpty {
                stage = .onboarding
                return
            }
            setupWaiting = true
        }
        await goToWhoOrShellAtLaunch()
    }

    /// (review 14 follow-up) bp-onboarding.tsx useBpOnboardingGate `open` (!onboarded && !snoozed)
    /// for a setup that waits under Who's watching: set at launch when setup is unfinished and
    /// profiles exist, cleared when setup is left (Start watching, Finish later, Do not show this
    /// again). While it is set, leaving Who's watching onto an adult profile opens setup; a kid
    /// profile goes to the Kids surface, where upstream's gate is not mounted.
    private var setupWaiting = false

    /// Where the app goes once a profile is active: setup when it waits for an adult profile,
    /// else the shell.
    /// (review 15) With no profile active (the pick was removed by a roster sync while
    /// pickedOnWho loaded its settings) it is Who's watching: `active?.kid == nil` read true for a
    /// missing profile, so setup opened for nobody.
    private var stageAfterPick: Stage {
        guard let active = profiles.active else { return .whoIsWatching }
        return setupWaiting && !onboardingDone && active.kid == nil ? .onboarding : .shell
    }

    /// Setup closing (Start watching, Finish later, Do not show this again). A setup resumed over
    /// existing profiles already went through the launch path before it opened, so it closes onto
    /// the profile it edited.
    private func leaveSetup() {
        setupWaiting = false
        goToWhoOrShell()
    }

    /// (review 14 follow-up) about-tab.tsx OnboardingRow "Replay walkthrough": useOnboarding
    /// resetOnboarding clears the finished flag (the TV has no dismissed tips to clear) and
    /// bp-shell's gate opens setup over the room at once. The resume cursor is left alone, as
    /// upstream's: a finished setup cleared it, so setup opens on its first screen; one left with
    /// Finish later picks up where it was. Nothing else is reset: profiles, sign-ins and settings
    /// stay, and leaving setup returns to the active profile's shell. Settings is an adult room
    /// (a kid profile has none), so a kid never starts it.
    func replayOnboarding() {
        guard !isBrowseLayer, stage == .shell, let active = profiles.active, active.kid == nil else { return }
        onboardingDone = false
        stage = .onboarding
    }

    /// (profiles device pass) lib/profiles.tsx at launch (engine `profilesRoom.launchPicker`): a
    /// "Start as" default profile opens directly, and with several profiles Who's watching comes
    /// up over the restored one (profilePromptInterval, every launch by default; Back closes it).
    /// The TV only asked when no profile was active, so it always woke in whoever used it last.
    private func goToWhoOrShellAtLaunch() async {
        struct Launch: Decodable { var open: Bool; var defaultId: String? }
        // A kid profile behind a parent PIN is left only through that PIN (KidsShellView's chip), so
        // neither the prompt nor a default takes it away at launch: quitting and reopening the app
        // must not be a way around the PIN (or the curfew lock).
        let kidLocked = profiles.active?.kid?.parentPinHash != nil
        guard !Fixtures.active, !kidLocked, let launch: Launch = try? await HarborEngine.shared.call("profilesRoom.launchPicker", []) else {
            goToWhoOrShell()
            return
        }
        if let id = launch.defaultId, id != profiles.activeId,
           let target = profiles.profiles.first(where: { $0.id == id }), target.passwordHash == nil {
            profiles.select(id)
            // (review 15) Boot loaded the restored profile's settings and theme; the "Start as"
            // profile's arrived only through the activeId sink, after the stage below was set. The
            // shell painted the previous profile's theme and language, then rebuilt; a resumed
            // setup opened in the old theme (held until setup ends) and flipped language mid-step.
            await SettingsBridge.shared.load()
            await ThemeStore.shared.load()
        }
        if launch.open, profiles.active != nil {
            stage = .whoIsWatching
            return
        }
        goToWhoOrShell()
    }

    func finishOnboarding() {
        onboardingDone = true
        OnboardingView.clearResume()
        if profiles.profiles.isEmpty { profiles.seedIfEmpty(name: account.session?.user.username ?? "Harbor") }
        attachPendingStremio()
        leaveSetup()
    }

    /// (onboarding pass 3) bp-onboarding.tsx BpOnboardingGate.suspend, "Finish later": setup closes
    /// for this run only. The finished flag stays unset and the saved step stays, so the next launch
    /// opens setup where it was left; meanwhile the app runs on a first profile as after setup.
    func suspendOnboarding() {
        if profiles.profiles.isEmpty { profiles.seedIfEmpty(name: account.session?.user.username ?? "Harbor") }
        attachPendingStremio()
        leaveSetup()
    }

    /// A Stremio sign-in made before profiles existed goes to the primary profile.
    func attachPendingStremio() {
        guard let s = PendingStremio.session,
              let target = profiles.profiles.first(where: { $0.isPrimary }) ?? profiles.profiles.first else { return }
        profiles.setStremioSession(s, for: target.id)
        PendingStremio.session = nil
    }

    func goToWhoOrShell() {
        stage = profiles.active == nil ? .whoIsWatching : stageAfterPick
    }

    /// (profiles device pass) bp-who-is-watching-layer: the chooser opens over the profile in use,
    /// which stays active until another is picked, so Back returns to it (`canClose`) and picking
    /// it again just closes. The switch used to clear the active profile first: Back on Who's
    /// watching then left the app, re-picking your own PIN profile asked for its PIN again, and a
    /// parental unlock was dropped.
    /// The PiP browse layer still clears it: that is what takes the layer and its film down and
    /// sends the app's own shell to Who's watching (PiPBrowse.profileChanged, the sink in init).
    func switchProfile() {
        if isBrowseLayer { profiles.deselect() }
        stage = .whoIsWatching
    }

    /// Who's watching may close back to the shell: there is a profile behind it.
    var canCloseWho: Bool { profiles.active != nil }

    func closeWho() {
        guard canCloseWho else { return }
        stage = stageAfterPick
    }

    /// bp-who-is-watching commit(): a profile was picked (after its PIN, if it has one). Setup
    /// waiting under the chooser continues for it (review 14 follow-up), else the shell opens.
    func pickedOnWho() {
        guard stageAfterPick == .onboarding, !Fixtures.active else {
            stage = stageAfterPick
            return
        }
        // Setup holds the theme while it runs (ThemeStore.holding) and a new language rebuilds the
        // tree, so the picked profile's settings and theme land before setup opens on them. The
        // activeId sink reloads them too; a second load reads the same stored values.
        Task { @MainActor in
            await SettingsBridge.shared.load()
            await ThemeStore.shared.load()
            guard self.stage == .whoIsWatching else { return }
            self.stage = self.stageAfterPick
        }
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

/// (deep links over covers) lib/deep-link.ts links that have arrived and not been shown yet. One
/// queue for the app: the PiP browse layer's model and the app's own both show from it, so a link
/// still waiting when the layer goes down opens in the app's shell instead of going with the
/// layer's model. Upstream pushes each link as a frame on its view stack (lib/view.tsx openMeta /
/// openList) and Back walks down them; the newest is shown first here too, then the older ones as
/// each page closes.
@MainActor
final class DeepLinkQueue: ObservableObject {
    static let shared = DeepLinkQueue()

    enum Link: Equatable {
        /// parseHarborOpen / parseStremioOpen: a title page.
        case title(type: String, id: String)
        /// parseHarborList: a shared list.
        case list(Social.ListRef)
        /// emitDeepLinkInstall: a stremio://…/manifest.json install link.
        case install(String)

        /// A kid's shell shows titles only (as its kids detail page).
        var kidSafe: Bool {
            switch self {
            case .title: return true
            case .list, .install: return false
            }
        }
    }

    @Published private(set) var waiting: [Link] = []
    /// A burst of links keeps its newest few.
    private static let cap = 8

    /// A link sent again moves up to newest instead of waiting twice.
    func add(_ link: Link) {
        waiting.removeAll { $0 == link }
        waiting.append(link)
        if waiting.count > Self.cap { waiting.removeFirst(waiting.count - Self.cap) }
    }

    func hasWaiting(kidShell: Bool) -> Bool {
        waiting.contains { !kidShell || $0.kidSafe }
    }

    /// The newest link a shell may show, out of the queue.
    func take(kidShell: Bool) -> Link? {
        guard let i = waiting.lastIndex(where: { !kidShell || $0.kidSafe }) else { return nil }
        return waiting.remove(at: i)
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
