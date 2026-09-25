import Foundation

/// The single string key/value surface the engine's `localStorage` shim will talk to.
/// Routes by key: secrets → Keychain, small durable state → UserDefaults, the rest → Caches.
/// Upstream's own key names decide the class, so the tables here grow as modules are ported.
final class KeyValueStore {
    static let shared = KeyValueStore()

    enum Tier { case secret, durable, cache }

    /// Keychain-only keys: the app's own sessions plus upstream's secret-store prefixes
    /// (docs/engine-report.md §4; `secretStore.isSecretKey` is the authoritative list).
    private static let secretPrefixes = ["harbor.manga.suwayomi.servers.v1", "harbor.auth.", "harbor.theme-session", "harbor.debrid.", "harbor.keys.",
                                         "harbor.trakt.session.v1", "harbor.simkl.session.v1", "harbor.mal.session.v1", "harbor.anilist.session.v1",
                                         "harbor.lastfm.v1", "harbor.subsonic.v1", "harbor.spotify.v1", "harbor.media-server.token.v1", "harbor.plex-auth.device.v1", "harbor.sports.api-sports.v1",
                                         // engine/aiSearch.ts AI_KEYS_PREFIX: the viewer's OpenRouter / Groq / Jina keys
                                         // (upstream's aiSearchKey / aiGroqKey / jinaKey, kept out of the settings blob).
                                         "harbor.ai-search.keys.v1"]
    /// Small, user-authored state that must survive a cache purge: profiles, settings blobs
    /// (`harbor.settings`, `.shared`, `.<profile>`), sync bookkeeping, sports choices, consent.
    private static let durableKeys: Set<String> = ["harbor.profiles.v1", "harbor.active-profile", "harbor.settings", "harbor.settings.shared", "harbor.sync.account",
                                                   "harbor.sports.favourites.v1", "harbor.sports.sources.v1", "harbor.sports.reminders.v1", "harbor-sports-consent", "harbor.iptv.playlists.v1",
                                                   "harbor.iptv.favorites.v2", "harbor.iptv.pins.v1", "harbor.iptv.epgmap.v1", "harbor.iptv.groupPrefs.v1", "harbor.iptv.countryPrefs.v1", "harbor.iptv.stats.v1",
                                                   "harbor.installed-addons", "harbor.onboarding.bp", "harbor.customlists.v1",
                                                   "harbor.reminders.v1", "harbor.reminders.unseen.v1", "harbor.moviewatched.v1",
                                                   "harbor.manga.suwayomi.active.v1", "harbor.manga.activesource.v2", "harbor.manga.configured.v1",
                                                   "harbor.media-server.connections.v1", "harbor.media-server.mappings.v1", "harbor.media-server.summaries.v1",
                                                   // Stage 13 eBooks (lib/ebook/sources, library, reader-state): sources, shelf, favourites, reader prefs.
                                                   "harbor.ebook.sources.v1", "harbor.ebook.library.v1", "harbor.ebook.favorites.v1", "harbor.ebook.read-later.v1", "harbor.ebook.reader.v1",
                                                   // engine/music.ts LIKED_KEY: the viewer's liked songs (stored without source credentials).
                                                   "harbor.music.liked.v1",
                                                   // lib/music/player.ts VOLUME_KEY: the music volume (MusicPlayer).
                                                   "harbor.music.volume.v1",
                                                   // lib/player-prefs.ts + lib/subtitles/subtitle-memory.ts: per-show audio/subtitle
                                                   // language, subtitles off, subtitle delay (≤200 shows, ~20 KB); per-episode remembered
                                                   // subtitle (≤500 entries; past Prefs' 64 KB cap `set` moves it to Caches by itself).
                                                   "harbor.player.prefs.v1", "harbor.subtitle.memory.v1"]
    private static let durablePrefixes = ["harbor.sync.revs", "harbor.sync.idmap", "harbor.settings.", "harbor.installed-addons.", "harbor.tvsettings.v1.",
                                          "harbor.favorites.v1.", "harbor.customlists.v1.", "harbor.localwatchlist.v1.", "harbor.moviewatched.v1.",
                                          "harbor.ebook.progress.v1.", "harbor.ebook.resume.v1.", "harbor.ebook.bookmarks.v1.",
                                          // engine/manga.ts FAV_PREFIX (lib/manga-favorites.tsx): manga favourites per profile.
                                          "harbor.mangafav.v1.",
                                          // (review 11) views/library/filter-preferences: Media Servers' saved type, server,
                                          // library, genres, sort and direction per profile (a Caches purge reset them).
                                          "harbor.library.filters."]
    /// Every key the engine may own: upstream uses both `harbor.` and `harbor-` spellings.
    static func isEngineKey(_ key: String) -> Bool { key.hasPrefix("harbor.") || key.hasPrefix("harbor-") }

    private var memory: [String: String] = [:]
    private let lock = NSLock()
    /// (bug pass) Bumped by every set/remove. `get` reads the disk outside the lock (the engine queue
    /// and the main thread both come here), so a slow first read could land after a concurrent write
    /// and pin the old value in `memory` for good; it now caches only when nothing wrote meanwhile.
    private var writes = 0

    static func tier(for key: String) -> Tier {
        if secretPrefixes.contains(where: key.hasPrefix) { return .secret }
        if durableKeys.contains(key) || durablePrefixes.contains(where: key.hasPrefix) { return .durable }
        return .cache
    }

    func get(_ key: String) -> String? {
        lock.lock(); if let v = memory[key] { lock.unlock(); return v }; let seen = writes; lock.unlock()
        let value: String?
        switch Self.tier(for: key) {
        case .secret: value = SecretStore.get(key)
        case .durable: value = Prefs.get(String.self, for: key) ?? CacheStore.shared.get(String.self, for: key)
        case .cache: value = CacheStore.shared.get(String.self, for: key)
        }
        if let value, !Self.skipsMemo(key, value) { lock.lock(); if writes == seen { memory[key] = value }; lock.unlock() }
        return value
    }

    /// (lifecycle pass) `memory` kept a second copy of every value the engine ever wrote, for the
    /// life of the process: the bundle's localStorage shim already holds each one (it is the
    /// source of truth for every engine read), so parsed playlists, catalog and anime caches, the
    /// eBook/manga caches… sat in RAM twice, as UTF-16, with nothing ever trimming them. A large
    /// Caches-tier value that is safely on disk is no longer memoized; Swift reads only a few small
    /// keys (profiles, the music volume), and a `get` of a big one just reads the file again.
    private static let memoLimit = 16 * 1024

    private static func skipsMemo(_ key: String, _ value: String) -> Bool {
        tier(for: key) == .cache && value.utf16.count >= memoLimit
    }

    func set(_ value: String, for key: String) throws {
        lock.lock(); memory[key] = value; writes &+= 1; let stamp = writes; lock.unlock()
        switch Self.tier(for: key) {
        case .secret: try SecretStore.set(value, for: key)
        case .durable:
            // One live copy per key: a Caches copy left from before the key was durable (or from an
            // oversize fallback) is dropped, and an oversize value never leaves a stale Prefs copy
            // that `get` would prefer.
            do {
                try Prefs.set(value, for: key)
                if CacheStore.shared.exists(key) { CacheStore.shared.remove(key) }
            } catch {
                Prefs.remove(key)
                try CacheStore.shared.set(value, for: key)
            }
        case .cache:
            try CacheStore.shared.set(value, for: key)
            // On disk now: drop the RAM copy of a big one, unless another write came in meanwhile
            // (a failed write keeps it, so the value still reads back this session).
            if Self.skipsMemo(key, value) {
                lock.lock(); if writes == stamp { memory[key] = nil }; lock.unlock()
            }
        }
    }

    /// Every `harbor.*` key/value across all three tiers, in one synchronous pass.
    /// `HarborEngine`'s `__harbor_host.storageSnapshot()` hands this to the bundle at boot so
    /// the JS `localStorage` shim can serve every read from memory. Later tiers win over
    /// earlier ones (an in-memory write is the freshest, then the Keychain / UserDefaults
    /// copy, then a possibly stale Caches copy of the same key).
    func snapshot() -> [String: String] {
        var out: [String: String] = [:]
        for key in CacheStore.shared.allKeys() where Self.isEngineKey(key) {
            if let value = CacheStore.shared.get(String.self, for: key) { out[key] = value }
        }
        for key in Prefs.allKeys() where Self.isEngineKey(key) {
            if let value = Prefs.get(String.self, for: key) { out[key] = value }
        }
        for key in SecretStore.allKeys() where Self.isEngineKey(key) {
            if let value = SecretStore.get(key) { out[key] = value }
        }
        lock.lock()
        for (key, value) in memory where Self.isEngineKey(key) { out[key] = value }
        lock.unlock()
        return out
    }

    func remove(_ key: String) {
        lock.lock(); memory[key] = nil; writes &+= 1; lock.unlock()
        switch Self.tier(for: key) {
        case .secret: SecretStore.remove(key)
        case .durable: Prefs.remove(key); CacheStore.shared.remove(key)
        case .cache: CacheStore.shared.remove(key)
        }
    }
}
