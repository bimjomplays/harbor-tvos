import Foundation
import Combine

/// Upstream's Settings blob, read and written through the engine so the sanitiser and the
/// per-profile / shared key rules stay upstream's. Swift only ever patches a few keys.
@MainActor
final class SettingsBridge: ObservableObject {
    static let shared = SettingsBridge()

    /// The handful of keys the TV app edits directly; everything else rides along untouched.
    struct Slice: Codable, Equatable {
        var tmdbKey: String = ""
        var region: String = "US"
        var homeMode: String = "harbor"
        var uiLanguage: String = "en"
        var animeOnlyInAnimeRoom: Bool = true
        var preferredSubLangs: [String] = ["English"]
        var preferredAudioLangs: [String]? = nil
        // Subtitle style (settings/defaults.ts:265-293), mapped to mpv in MPVPlayerController.
        var subFontSize: Double? = 32
        var subFontColor: String? = "#FFFFFF"
        var subBorderColor: String? = "#000000"
        var subBorderSize: Double? = 0
        var subMarginY: Double? = 12
        var subAlignX: String? = "center"
        var subStyle: String? = "shadow"
        var subBold: Bool? = false
        var subBoxOpacity: Double? = 0.6
        var subBoxColor: String? = "#000000"
        var subOpacity: Double? = 1
        var subLineSpacing: Double? = 0
        /// stage-overlays.tsx `!pipMode || subShowInPip`: subtitles stay on in Picture in Picture.
        var subShowInPip: Bool? = true
        // Anime4K (settings/defaults.ts:235-261), applied by the player through the engine's gates.
        var playerAnime4k: Bool? = false
        var playerAnime4kAnimeOnly: Bool? = true
        var playerAnime4kIndicator: Bool? = true
        var playerAnime4kMode: String? = "A"
        var playerAnime4kTier: String? = "hq"
        var playerAnime4kOverride: String? = "auto"
        var simklScrobbleEnabled: Bool? = true
        /// views/addons.tsx "Adult" chip (settings/defaults.ts showAdultAddons), set only after the age check.
        var showAdultAddons: Bool? = false
        // Player forks (settings/defaults.ts): resume automatically, ask first, confirm on Back.
        // Instant play (use-bp-stream-play): Play fires the best source; "Sources" forces the list.
        var instantPlay: Bool? = true
        /// use-bp-streams strictMode: "strict" starts narrow; "Search wider" / "Show everything" loosen.
        var streamFilterLevel: String? = "strict"
        var rememberLastStream: Bool? = true
        var seasonSourceLock: Bool? = false
        var resumePlayback: Bool? = true
        var resumePrompt: Bool? = false
        var playerConfirmLeave: Bool? = true
        // Skip pill (skip-pill-container.tsx; settings/defaults.ts:310-315): auto-skip per kind, the
        // pill itself, and the seconds before it hides (0 = stays; load.ts migrates unset to 14).
        var autoSkipIntro: Bool? = false
        var autoSkipRecap: Bool? = false
        var autoSkipOutro: Bool? = false
        var autoSkipAd: Bool? = false
        var showSkipButton: Bool? = true
        var skipButtonHideSec: Double? = 0
        /// use-still-watching.ts: ask "Still watching?" after this many auto-advanced episodes.
        var stillWatching: Bool? = false
        var stillWatchingAfter: Double? = 3
        /// xray-overlay.tsx (settings/defaults.ts xrayEnabled, off): the cast while paused (PlayerXRay.swift).
        var xrayEnabled: Bool? = false
        /// speed-menu.tsx / use-track-autoload.ts: the rate a title starts at, and the viewer's own
        /// speed and sleep presets (numbers, kept as Double so an odd value never fails the decode).
        var defaultPlaybackSpeed: Double? = 1
        var customPlaybackSpeeds: [Double]? = []
        var customSleepMinutes: [Double]? = []
        // fullscreen-clock.tsx (settings/defaults.ts fullscreenClock*): the corner clock TransportKids
        // shows. Read only; a missing key decodes as nil, so readers fall back to these defaults.
        var fullscreenClockEnabled: Bool? = false
        var fullscreenClockFormat: String? = "system"
        var fullscreenClockStyle: String? = "glass"
        var fullscreenClockShowSeconds: Bool? = false
        var fullscreenClockShowEndTime: Bool? = true
        var fullscreenClockSizePx: Double? = 13
        // Screensaver (settings/defaults.ts:122-126) and the hero feed it draws from.
        var screensaver: Bool? = true
        var screensaverDelayMin: Double? = 5
        var heroFeed: String? = "trending"
        /// bp-settings "Animated backdrop": the drifting poster mosaic behind screens without art.
        var bigPictureMosaic: Bool? = true
        /// bp-settings "Edge margin": a fraction of the screen kept clear on every edge.
        var bigPictureOverscan: Double? = 0
        /// (bug pass) bp-safe-area.ts clampOverscan: 0...0.1 (MAX_OVERSCAN). The stored value is synced
        /// from other devices unchecked; a stray 5 (percent) or a negative one made the shells' padding
        /// larger than the screen or negative.
        var overscanFraction: Double {
            guard let v = bigPictureOverscan, v.isFinite else { return 0 }
            return min(0.1, max(0, v))
        }
        /// use-bp-sound.ts: the Big Picture sound theme (none/glass/modern/retro/cinematic) and
        /// bp-tv-app.tsx's SFX volume (0-100); played by BPSound.
        var bigPictureSound: String? = "cinematic"
        var sfxVolume: Double? = 50
        /// settings/defaults.ts mangaEnabled (off): the manga reader, its tab, Search's manga row
        /// and the anime hero's "Read the Manga" entry all wait for it (views/manga.tsx EnableGate).
        var mangaEnabled: Bool? = false
        /// bp-detail.tsx / bp-streams.tsx: what the Play button does ("online" | "home-server" |
        /// "local" | "ask"); anything but "online" turns instant play off and lets the home-server
        /// copy lead (engine/homeServers.ts preferredSource decides).
        var playbackSourcePreference: String? = "online"
        /// mpv-tuning.ts mpvHwdec ("auto" | "on" | "off"), mapped to mpv's hwdec in MPVPlayerController.
        var mpvHwdec: String? = "auto"
        /// poster.tsx posterQuality ("balanced" | "high" | "max"): how large a poster card's art is asked for.
        var posterQuality: String? = "high"
        /// bp-stream-row.tsx: the torrent's filename under the headline (off by default) and the
        /// addon's whole description in place of the one-line summary (on by default).
        var pickerShowFilename: Bool? = false
        var fullStreamDescription: Bool? = true
    }

    /// Manga is switched on: its tab may show and the manga hooks run (use-bp-search gates
    /// `manga: settings.mangaEnabled`). Hiding the tab is tab editing now (navLayout below):
    /// upstream retired the hideContent.manga switch into sidebar editing.
    var mangaOn: Bool { slice.mangaEnabled ?? false }

    // MARK: Tab editing (engine/navEdit.ts: chrome/nav-items.tsx + chrome/nav-edit.tsx)

    /// The top bar's arrangement from settings.navCustomization, the object the desktop sidebar
    /// edits: every Room.tabs raw value in bar order, and the ones the viewer hid.
    struct NavLayout: Decodable, Equatable {
        var order: [String]
        var hidden: [String]
    }
    @Published private(set) var navLayout: NavLayout?

    func loadNavLayout() async {
        await navEdit("navEdit.layout", [])
    }

    /// nav-edit.tsx NavHideBadge / the hidden tray's "Show this tab".
    func toggleTabHidden(_ room: Room) async {
        await navEdit("navEdit.toggleHidden", [room.rawValue])
    }

    /// context-menu.tsx "Move up" / "Move down": one step against a neighbouring tab.
    func moveTab(_ room: Room, beside neighbour: Room, after: Bool) async {
        await navEdit("navEdit.move", [room.rawValue, neighbour.rawValue, after ? "after" : "before"])
    }

    /// "Show all tabs".
    func showAllTabs() async {
        await navEdit("navEdit.showAll", [])
    }

    /// "Reset layout".
    func resetTabs() async {
        await navEdit("navEdit.reset", [])
    }

    private func navEdit(_ fn: String, _ lead: [any Encodable]) async {
        let p = ProfilesStore.shared.active
        let tabs: [String] = Room.tabs.map(\.rawValue)
        var args: [any Encodable] = lead
        args.append(tabs)
        args.append(p?.id ?? "default")
        args.append(p?.linked ?? true)
        let next: NavLayout? = try? await HarborEngine.shared.call(fn, args)
        if let next { navLayout = next }
    }

    /// The Sports tab hides when the viewer declined the notice (bp-top-bar useBpTabGate).
    @Published var sportsDeclined = false

    /// T() and RootView's locale follow the slice's uiLanguage the moment it changes (App/L10n.swift).
    @Published private(set) var slice = Slice() { didSet { L10n.setLanguage(slice.uiLanguage) } }
    @Published private(set) var loaded = false

    private var storageKey: String {
        get async {
            let p = ProfilesStore.shared.active
            let id = p?.id ?? "default"
            return (try? await HarborEngine.shared.call("settings.sourceKeyFor", [id, p?.linked ?? true])) ?? "harbor.settings"
        }
    }

    private var unsubscribe: (() -> Void)?

    func load() async {
        if unsubscribe == nil {
            // Profile sync applied a settings section (home rows, services…): re-read the slice.
            unsubscribe = HarborEngine.shared.onEvent { [weak self] type, _ in
                guard type == "harbor:settings-updated" else { return }
                Task { await self?.load() }
            }
        }
        let key = await storageKey
        let s: Slice? = try? await HarborEngine.shared.call("settings.load", [key])
        // lib/i18n follows the profile's uiLanguage (store.ts only reads it once, at load), with
        // its catalog installed first (load-locale.ts). Both land before the slice is published,
        // so the rooms a language change rebuilds already read translated engine copy.
        let p = ProfilesStore.shared.active
        let lang: String? = try? await HarborEngine.shared.call("settingsRoom.applyUiLanguage", [p?.id ?? "default", p?.linked ?? true])
        if let lang = lang ?? s?.uiLanguage { await L10n.installEngineCatalog(lang) }
        if let s {
            slice = s
            loaded = true
        }
        // (bug pass) The Sports tab gate was only set by the Settings page: at launch a declined
        // notice still showed the tab until Settings was opened. Read the stored consent here.
        struct Consent: Decodable { var status: String }
        if let c: Consent = try? await HarborEngine.shared.call("sports.consent", []) { sportsDeclined = c.status == "declined" }
        await loadNavLayout()
    }

    func patch(_ change: [String: AnyJSON]) async throws {
        let key = await storageKey
        let s: Slice = try await HarborEngine.shared.call("settings.patch", [AnyJSON.object(change), key])
        slice = s
    }

    /// Checks a TMDB v3 key by asking TMDB for one page of trending titles.
    /// On failure returns what the engine logged for TMDB, so the screen can say why.
    func verifyTmdb(key: String) async -> (ok: Bool, reason: String?) {
        let before = HarborEngine.shared.logMark   // (bug pass) was recentLogs.count: blind once the 200-line ring was full
        do {
            let metas: [Meta] = try await HarborEngine.shared.call("tmdb.trending", [key, "movie", "week", 1])
            if !metas.isEmpty { return (true, nil) }
        } catch {
            return (false, error.localizedDescription)
        }
        let fresh = HarborEngine.shared.logs(since: before)
        let tmdbLine = fresh.last { $0.contains("[tmdb]") } ?? fresh.last
        return (false, tmdbLine)
    }
}
