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
        /// sub-style.ts sub-filter-sdh on mpv (the AVPlayer overlay strips SDH in subtitles.cues).
        var subHideSdh: Bool? = false
        /// (player parity pass) sub-style.ts mpvFontFor(subFontFamily) → mpv sub-font
        /// ("inter" | "system" | "rounded" | "serif" | "arabic" | "custom:<id>").
        var subFontFamily: String? = "inter"
        /// sub-style.ts sub-ass-override ("no" | "yes" | "force" | "scale" | "strip").
        var subAssOverride: String? = "no"
        /// (player parity pass) mpv.ts applyAudioFilters: settings.audioNormalize (dynaudnorm) and
        /// settings.audioProfile ("off" | "bass" | "voice" | "bass-reduce" | "night"), mpv only.
        var audioNormalize: Bool? = false
        var audioProfile: String? = "off"
        /// (player parity pass 2) use-video-fill.ts settings.cropMode ("fit" | "fill" | "stretch" |
        /// "zoom" | "16:9" | "4:3" | "21:9" | "1.85:1" | "original") and use-live-picture-eq.ts
        /// settings.mpvTweaks (its picture keys), both set on desktop and applied by the players.
        var cropMode: String? = "fit"
        var mpvTweaks: [String: String]? = nil
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
        /// bp-stream-row.tsx: the quality pill and format badges (showQualityBadge) and the anime
        /// DUB/SUB pill (showDubBadge), both on by default (settings/defaults.ts).
        var showQualityBadge: Bool? = true
        var showDubBadge: Bool? = true
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
        if let next, next != navLayout { navLayout = next }
    }

    /// The Sports tab hides when the viewer declined the notice (bp-top-bar useBpTabGate).
    @Published var sportsDeclined = false

    /// T() and RootView's locale follow the slice's uiLanguage the moment it changes (App/L10n.swift).
    @Published private(set) var slice = Slice() { didSet { L10n.setLanguage(slice.uiLanguage) } }
    @Published private(set) var loaded = false

    private var unsubscribe: (() -> Void)?
    /// (bug pass) `load()` runs once per harbor:settings-updated and per profile switch, each with
    /// several awaits (the language catalog can take a while): an older run finishing last put the
    /// previous profile's slice and language back. Only the newest load applies, and a patch is
    /// newer than any load already in flight as far as the slice goes.
    private var loadGen = 0
    private var sliceGen = 0
    /// (perf pass 2) A burst of harbor:settings-updated (a profile-sync apply writes several
    /// sections) ran this whole load, four engine calls, once per event and side by side, when
    /// only the newest result was ever kept. Loads now run one at a time: at most one in flight
    /// and one pending, and every call made while one is pending joins it (it has not started
    /// yet, so it still reads whatever that caller just wrote). Queueing a load retires the one
    /// in flight at its next await, as the newest-wins rule above always did. With nothing in
    /// flight a load starts at once, so the first one at boot is not delayed; `patch` never queues.
    private var currentLoad: Task<Void, Never>?
    private var pendingLoad: Task<Void, Never>?
    private var runGen = 0

    func load() async {
        if unsubscribe == nil {
            // Profile sync applied a settings section (home rows, services…): re-read the slice.
            unsubscribe = HarborEngine.shared.onEvent { [weak self] type, _ in
                guard type == "harbor:settings-updated" else { return }
                Task { await self?.load() }
            }
        }
        if let pending = pendingLoad {
            await pending.value
            return
        }
        let prior = currentLoad
        if prior != nil {
            // The run in flight is stale now: it stops applying at its next await.
            loadGen &+= 1
        }
        runGen &+= 1
        let run = runGen
        let task = Task { @MainActor [weak self] in
            if let prior {
                await prior.value
            }
            guard let self else { return }
            if prior != nil {
                self.pendingLoad = nil
            }
            await self.runLoad()
            if self.runGen == run {
                self.currentLoad = nil
            }
        }
        currentLoad = task
        if prior != nil {
            pendingLoad = task
        }
        await task.value
    }

    private func runLoad() async {
        loadGen &+= 1
        sliceGen &+= 1
        let gen = loadGen
        let sgen = sliceGen
        // (bug pass) settings.activate is lib/settings.tsx for the active profile: loadEffective (an
        // unlinked profile without a blob of its own reads the shared one, not the defaults), and
        // the `harbor.settings` mirror that upstream modules read follows the profile (switchProfile).
        let p = ProfilesStore.shared.active
        let id = p?.id ?? "default"
        let linked = p?.linked ?? true
        let s: Slice? = try? await HarborEngine.shared.call("settings.activate", [id, linked])
        guard gen == loadGen else { return }
        // lib/i18n follows the profile's uiLanguage (store.ts only reads it once, at load), with
        // its catalog installed first (load-locale.ts). Both land before the slice is published,
        // so the rooms a language change rebuilds already read translated engine copy.
        let lang: String? = try? await HarborEngine.shared.call("settingsRoom.applyUiLanguage", [id, linked])
        guard gen == loadGen else { return }
        if let lang = lang ?? s?.uiLanguage { await L10n.installEngineCatalog(lang) }
        guard gen == loadGen else { return }
        // (perf pass) Published only when something changed: RootView and every screen holding this
        // object redraw on each publish, and harbor:settings-updated (every profile-sync apply, every
        // engine settings write) re-reads an unchanged slice most of the time.
        if let s, sgen == sliceGen {
            if slice != s { slice = s }
            if !loaded { loaded = true }
        }
        // (perf pass 2) A newer load is queued behind this one and reads both of these again.
        guard gen == loadGen else { return }
        // (bug pass) The Sports tab gate was only set by the Settings page: at launch a declined
        // notice still showed the tab until Settings was opened. Read the stored consent here.
        struct Consent: Decodable { var status: String }
        if let c: Consent = try? await HarborEngine.shared.call("sports.consent", []) {
            let declined = c.status == "declined"
            if sportsDeclined != declined { sportsDeclined = declined }
        }
        await loadNavLayout()
    }

    func patch(_ change: [String: AnyJSON]) async throws {
        sliceGen &+= 1
        let sgen = sliceGen
        let p = ProfilesStore.shared.active
        // (bug pass) settings.patchFor saves through persistEffective (the profile's source key and
        // the mirror); settings.patch(…, sourceKey) left the mirror that upstream modules read behind.
        let s: Slice = try await HarborEngine.shared.call("settings.patchFor", [AnyJSON.object(change), AnyJSON.string(p?.id ?? "default"), AnyJSON.bool(p?.linked ?? true)])
        if sgen == sliceGen { slice = s }
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
        // (settings bug pass) Only TMDB's own line: the fallback was whatever the bundle logged last
        // (another module's request line, possibly carrying its token), shown on screen. Query
        // secrets are masked in case a TMDB line ever carries its URL.
        let fresh = HarborEngine.shared.logs(since: before)
        let tmdbLine = fresh.last { $0.contains("[tmdb]") }.map(Self.redacted)
        return (false, tmdbLine)
    }

    /// Masks `api_key=…`, `token=…`, `access_token=…`, `key=…` and bearer values in a log line.
    nonisolated static func redacted(_ line: String) -> String {
        var out = line
        let patterns = [#"(?i)\b(api_key|apikey|access_token|refresh_token|token|key)=[^&\s"']+"#, #"(?i)\bBearer\s+[A-Za-z0-9._~+/=-]+"#]
        for p in patterns {
            guard let re = try? NSRegularExpression(pattern: p) else { continue }
            let range = NSRange(out.startIndex..., in: out)
            out = re.stringByReplacingMatches(in: out, range: range, withTemplate: p.contains("Bearer") ? "Bearer ***" : "$1=***")
        }
        return out
    }
}

// (bug pass 2) Every field decodes on its own: a synced blob with null or a wrong type in one key
// (a numeric tmdbKey, a null region…) used to fail the whole Slice, and `load()` then kept the
// defaults (TMDB key "missing", English UI). A bad non-optional key now keeps its default; a bad
// optional key reads as nil, exactly like a missing one did, so readers keep their `?? default`.
// Arrays drop only their bad elements. In an extension so the memberwise / no-argument inits stay.
extension SettingsBridge.Slice {
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: LenientKey.self)
        tmdbKey = c.lenient("tmdbKey") ?? tmdbKey
        region = c.lenient("region") ?? region
        homeMode = c.lenient("homeMode") ?? homeMode
        uiLanguage = c.lenient("uiLanguage") ?? uiLanguage
        animeOnlyInAnimeRoom = c.lenient("animeOnlyInAnimeRoom") ?? animeOnlyInAnimeRoom
        preferredSubLangs = c.lossyArray("preferredSubLangs") ?? preferredSubLangs
        preferredAudioLangs = c.lossyArray("preferredAudioLangs")
        subFontSize = c.lenient("subFontSize")
        subFontColor = c.lenient("subFontColor")
        subBorderColor = c.lenient("subBorderColor")
        subBorderSize = c.lenient("subBorderSize")
        subMarginY = c.lenient("subMarginY")
        subAlignX = c.lenient("subAlignX")
        subStyle = c.lenient("subStyle")
        subBold = c.lenient("subBold")
        subBoxOpacity = c.lenient("subBoxOpacity")
        subBoxColor = c.lenient("subBoxColor")
        subOpacity = c.lenient("subOpacity")
        subLineSpacing = c.lenient("subLineSpacing")
        subShowInPip = c.lenient("subShowInPip")
        subHideSdh = c.lenient("subHideSdh")
        subFontFamily = c.lenient("subFontFamily")
        subAssOverride = c.lenient("subAssOverride")
        audioNormalize = c.lenient("audioNormalize")
        audioProfile = c.lenient("audioProfile")
        cropMode = c.lenient("cropMode")
        // mpvTweaks is Record<string, string> upstream; a value synced as a number still counts
        // (use-live-picture-eq parseFloat), and anything else is dropped on its own.
        if let raw = c.lenient("mpvTweaks", as: [String: AnyJSON].self) {
            var tweaks: [String: String] = [:]
            for (key, value) in raw {
                if let text = value.string { tweaks[key] = text }
                else if let n = value.number { tweaks[key] = String(n) }
            }
            mpvTweaks = tweaks
        }
        playerAnime4k = c.lenient("playerAnime4k")
        playerAnime4kAnimeOnly = c.lenient("playerAnime4kAnimeOnly")
        playerAnime4kIndicator = c.lenient("playerAnime4kIndicator")
        playerAnime4kMode = c.lenient("playerAnime4kMode")
        playerAnime4kTier = c.lenient("playerAnime4kTier")
        playerAnime4kOverride = c.lenient("playerAnime4kOverride")
        simklScrobbleEnabled = c.lenient("simklScrobbleEnabled")
        showAdultAddons = c.lenient("showAdultAddons")
        instantPlay = c.lenient("instantPlay")
        streamFilterLevel = c.lenient("streamFilterLevel")
        rememberLastStream = c.lenient("rememberLastStream")
        seasonSourceLock = c.lenient("seasonSourceLock")
        resumePlayback = c.lenient("resumePlayback")
        resumePrompt = c.lenient("resumePrompt")
        playerConfirmLeave = c.lenient("playerConfirmLeave")
        autoSkipIntro = c.lenient("autoSkipIntro")
        autoSkipRecap = c.lenient("autoSkipRecap")
        autoSkipOutro = c.lenient("autoSkipOutro")
        autoSkipAd = c.lenient("autoSkipAd")
        showSkipButton = c.lenient("showSkipButton")
        skipButtonHideSec = c.lenient("skipButtonHideSec")
        stillWatching = c.lenient("stillWatching")
        stillWatchingAfter = c.lenient("stillWatchingAfter")
        xrayEnabled = c.lenient("xrayEnabled")
        defaultPlaybackSpeed = c.lenient("defaultPlaybackSpeed")
        customPlaybackSpeeds = c.lossyArray("customPlaybackSpeeds")
        customSleepMinutes = c.lossyArray("customSleepMinutes")
        fullscreenClockEnabled = c.lenient("fullscreenClockEnabled")
        fullscreenClockFormat = c.lenient("fullscreenClockFormat")
        fullscreenClockStyle = c.lenient("fullscreenClockStyle")
        fullscreenClockShowSeconds = c.lenient("fullscreenClockShowSeconds")
        fullscreenClockShowEndTime = c.lenient("fullscreenClockShowEndTime")
        fullscreenClockSizePx = c.lenient("fullscreenClockSizePx")
        screensaver = c.lenient("screensaver")
        screensaverDelayMin = c.lenient("screensaverDelayMin")
        heroFeed = c.lenient("heroFeed")
        bigPictureMosaic = c.lenient("bigPictureMosaic")
        bigPictureOverscan = c.lenient("bigPictureOverscan")
        bigPictureSound = c.lenient("bigPictureSound")
        sfxVolume = c.lenient("sfxVolume")
        mangaEnabled = c.lenient("mangaEnabled")
        playbackSourcePreference = c.lenient("playbackSourcePreference")
        // (bug pass 3: these two were missed, so the picker ignored the viewer's choice)
        pickerShowFilename = c.lenient("pickerShowFilename")
        fullStreamDescription = c.lenient("fullStreamDescription")
        showQualityBadge = c.lenient("showQualityBadge")
        showDubBadge = c.lenient("showDubBadge")
        mpvHwdec = c.lenient("mpvHwdec")
        posterQuality = c.lenient("posterQuality")
    }
}
