import Foundation
import Combine
import CryptoKit

/// Local profiles on this Apple TV. The roster is adopted and pushed by the engine's profile
/// sync (see engine/sync.ts); PINs, the active profile and per-profile Stremio sessions are
/// device-local, as upstream intends.
@MainActor
final class ProfilesStore: ObservableObject {
    struct Profile: Codable, Equatable, Identifiable {
        struct Kid: Codable, Equatable { var age: Int; var curfewMinutes: Int?; var parentPinHash: String? }
        var id: String            // local id, `p_<base36>_<rand>` like upstream
        var syncId: String?
        var name: String
        var avatar: String?
        var color: String
        var isPrimary: Bool
        var kid: Kid?
        var passwordHash: String?
        var createdAt: Double
        /// Settings shared with the primary profile (upstream `settingsLinked`, default true).
        var settingsLinked: Bool? = nil
        var linked: Bool { settingsLinked ?? true }
        /// Upstream `ContentFilters | null`; copied into the effective settings by the engine
        /// (engine/parental.ts syncIdentity), carried so a re-save never drops it.
        var hideContent: AnyJSON? = nil
        /// Upstream `HiddenTabs | null` (lib/lockable-tabs.ts), edited in ProfileEditorView and
        /// read by ParentalGate; `null` when no tab is locked, exactly as desktop writes it.
        var lockedTabs: AnyJSON? = nil
        var shareStremioWith: String? = nil
        /// The profile a fresh TV makes before sign-in. Roster adoption drops it instead of
        /// pushing it up as a duplicate (upstream planRoster, isBootstrapProfile).
        var bootstrap: Bool? = nil
    }

    struct StremioSession: Codable, Equatable {
        var authKey: String
        var user: StremioAPI.User
    }

    static let shared = ProfilesStore()
    static let colors = ["#7dd3fc", "#60a5fa", "#a78bfa", "#f472b6", "#fb7185", "#fb923c", "#fbbf24", "#a3e635", "#34d399", "#22d3ee"]

    @Published private(set) var profiles: [Profile]
    @Published private(set) var activeId: String?
    /// lib/profiles.tsx sessionUnlockedIds: profiles whose PIN was entered this app session.
    /// Never persisted; a cold launch that restores the active profile starts locked.
    @Published private(set) var sessionUnlockedIds: Set<String> = []
    /// lib/parental.tsx sessionUnlockedFor: an unlock (PIN entered or changed) that holds only
    /// until the active profile changes.
    @Published private(set) var parentalUnlockedFor: String?

    private static let profilesKey = "harbor.profiles.v1"
    private static let activeKey = "harbor.active-profile"
    private static let idMapKey = "harbor.sync.idmap"
    private static let lastSelectKey = "harbor.profile.lastSelectAt"

    /// Upstream's `harbor.profiles.v1` shape (`{ activeId, profiles: [...] }`, lib/profiles.tsx),
    /// so the bundled modules that read it (addon store, settings, resume) see the same profiles.
    private struct Blob: Codable {
        var activeId: String?
        var profiles: [Profile]

        init(activeId: String?, profiles: [Profile]) {
            self.activeId = activeId
            self.profiles = profiles
        }

        /// (bug pass 2) One profile the roster sync wrote with a missing or mistyped field failed
        /// the whole blob: launch fell back to the old Prefs copy and every later roster reload
        /// was ignored. A profile without an id is skipped; the rest decode (Profile's lenient
        /// init below). A blob whose `profiles` is not an array still fails, as before.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: LenientKey.self)
            guard let list: [Profile] = c.lossyArray("profiles") else {
                throw DecodingError.keyNotFound(LenientKey("profiles"), .init(codingPath: c.codingPath, debugDescription: "profiles is not an array"))
            }
            activeId = c.lenient("activeId")
            profiles = list
        }
    }

    private init() {
        if let raw = KeyValueStore.shared.get(Self.profilesKey), let data = raw.data(using: .utf8),
           let blob = try? JSONDecoder().decode(Blob.self, from: data) {
            profiles = blob.profiles
            activeId = blob.activeId
        } else {
            // Earlier builds stored a bare array in Prefs plus a separate active-id key.
            profiles = Prefs.get([Profile].self, for: Self.profilesKey) ?? []
            activeId = Prefs.get(String.self, for: Self.activeKey)
            if !profiles.isEmpty { persist() }
        }
        migrateIdMap()
    }

    /// Earlier builds stored the local-id → syncId map as a JSON dictionary through Prefs; the
    /// engine reads it as a JSON string through KeyValueStore. Re-save it once in that form.
    private func migrateIdMap() {
        guard KeyValueStore.shared.get(Self.idMapKey) == nil,
              let old = Prefs.get([String: String].self, for: Self.idMapKey), !old.isEmpty,
              let data = try? JSONEncoder().encode(old), let raw = String(data: data, encoding: .utf8) else { return }
        try? KeyValueStore.shared.set(raw, for: Self.idMapKey)
        HarborEngine.loaded?.syncStorage(key: Self.idMapKey, value: raw)
    }

    private var unsubscribe: (() -> Void)?

    /// Follow the engine: when profile sync adopts a roster it rewrites `harbor.profiles.v1`
    /// and says so; reload without re-persisting (that would echo a roster push).
    func attachEngine() {
        guard unsubscribe == nil else { return }
        unsubscribe = HarborEngine.shared.onEvent { [weak self] type, detail in
            guard type == "harbor:roster-applied" else { return }
            // (bug pass 2) engine/sync.ts purges the dropped profiles' localStorage keys; the
            // Swift-only ones (the curfew record in Prefs) are ours to drop.
            for d in detail?["dropped"]?.array ?? [] { if let id = d.string { CurfewState.purge(profileId: id) } }
            self?.reloadFromStore()
        }
    }

    func reloadFromStore() {
        guard let raw = KeyValueStore.shared.get(Self.profilesKey), let data = raw.data(using: .utf8),
              let blob = try? JSONDecoder().decode(Blob.self, from: data) else { return }
        profiles = blob.profiles
        activeId = blob.activeId
    }

    var active: Profile? { profiles.first { $0.id == activeId } }

    /// Used only when the account has no roster yet: one primary profile named after the account.
    func seedIfEmpty(name: String) {
        guard profiles.isEmpty else { return }
        let seed = Profile(id: Self.newId(), syncId: nil, name: name, avatar: nil, color: Self.colors[0], isPrimary: true,
                           kid: nil, passwordHash: nil, createdAt: Date().timeIntervalSince1970 * 1000, bootstrap: true)
        profiles = [seed]
        persist()
        // (review 15) lib/profiles.tsx makes the first profile active as it creates it
        // ({ profiles: [primary], activeId: primary.id }), so a one-profile household never sees
        // the chooser. The seed stayed inactive: "Start watching" (and Finish later) on a first
        // run landed on a "Who's watching?" with one face, and so did every launch until it was
        // picked (launchPicker opens with no active profile).
        select(seed.id)
    }

    // MARK: Management (lib/profiles.tsx createProfile / updateProfile / deleteProfile)

    /// A new local profile; the roster push mints its syncId on the next flush.
    @discardableResult
    func create(name: String, avatar: String?, color: String) -> Profile {
        let primary = profiles.first { $0.isPrimary } ?? profiles.first
        let p = Profile(id: Self.newId(), syncId: nil, name: String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(32)).isEmpty ? "Profile" : String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(32)),
                        avatar: avatar, color: color, isPrimary: false, kid: nil, passwordHash: nil,
                        createdAt: Date().timeIntervalSince1970 * 1000, settingsLinked: true, shareStremioWith: primary?.id)
        profiles.append(p)
        persist()
        return p
    }

    func update(_ id: String, name: String? = nil, avatar: String?? = nil, color: String? = nil) {
        guard let i = profiles.firstIndex(where: { $0.id == id }) else { return }
        if let name { let n = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(32)); if !n.isEmpty { profiles[i].name = n } }
        if let avatar { profiles[i].avatar = avatar }
        if let color { profiles[i].color = color }
        persist()
    }

    /// Never the primary. Tombstones first (so the delete reaches other devices), then purges.
    func delete(_ id: String) async {
        guard let target = profiles.first(where: { $0.id == id }), !target.isPrimary else { return }
        _ = try? await HarborEngine.shared.callJSON("sync.profileDeleted", [.string(id)])
        _ = try? await HarborEngine.shared.callJSON("profilesRoom.purge", [.string(id)])
        KeyValueStore.shared.remove("harbor.auth.\(id)")
        HarborEngine.loaded?.syncStorage(key: "harbor.auth.\(id)", value: nil)
        CurfewState.purge(profileId: id)   // (bug pass 2) Swift-only key, not in the engine's purge list
        profiles.removeAll { $0.id == id }
        for i in profiles.indices where profiles[i].shareStremioWith == id { profiles[i].shareStremioWith = nil }
        // (profiles bug pass) Upstream only lets the primary delete, and never the active profile
        // (editor-view.tsx canEditAdvanced). Here Settings' editor edits the active profile, so a
        // profile deleting itself used to land in `profiles.first` — the primary — past its PIN
        // and without a word. It now goes back to Who's watching (AppModel follows a nil active id).
        if activeId == id { activeId = nil; parentalUnlockedFor = nil }
        persist()
    }

    /// `unlocked`: the caller just verified this profile's PIN (profiles.tsx selectProfile opts).
    func select(_ id: String, unlocked: Bool = false) {
        if unlocked { sessionUnlockedIds.insert(id) }
        if id != activeId { parentalUnlockedFor = nil }
        activeId = id
        // (profiles device pass) profiles.tsx markProfileSelectedNow: the 15/30-minute launch prompt
        // (engine profilesRoom.launchPicker) counts from the last pick.
        let stamp = String(Int(Date().timeIntervalSince1970 * 1000))
        try? KeyValueStore.shared.set(stamp, for: Self.lastSelectKey)
        HarborEngine.loaded?.syncStorage(key: Self.lastSelectKey, value: stamp)
        persist()
        HarborEngine.loaded?.emitEvent("harbor:active-profile-changed", detail: .object(["id": .string(id)]))
    }

    func deselect() {
        activeId = nil
        parentalUnlockedFor = nil
        persist()
    }

    func setPin(_ pin: String?, for id: String) {
        guard let i = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[i].passwordHash = pin.map(Self.hashPin)
        // parental.tsx setPin / clearPin: whoever just set or removed the PIN stays unlocked.
        if id == activeId { parentalUnlockedFor = id }
        persist()
    }

    /// profiles.tsx selectProfile(id, { unlocked: true }) without the switch: the PIN was typed
    /// seconds ago (editor-view.tsx create flow), so the profile opens unlocked this session.
    func markSessionUnlocked(_ id: String) {
        sessionUnlockedIds.insert(id)
    }

    /// parental.tsx unlock(pin) after a verified PIN: holds until the active profile changes.
    func unlockParental(_ id: String) {
        guard id == activeId else { return }
        parentalUnlockedFor = id
    }

    /// Whether this session may see the profile's locked tabs (parental.tsx `locked`, inverted).
    func sessionUnlocked(_ id: String) -> Bool {
        sessionUnlockedIds.contains(id) || parentalUnlockedFor == id
    }

    /// editor-view.tsx TabsView onSave -> updateProfile(id, { lockedTabs }). `value` is the
    /// engine's `parental.lockedTabsValue` (a full HiddenTabs object, or null when none).
    func setLockedTabs(_ value: AnyJSON?, for id: String) {
        guard let i = profiles.firstIndex(where: { $0.id == id }) else { return }
        if case .object? = value { profiles[i].lockedTabs = value } else { profiles[i].lockedTabs = nil }
        persist()
    }

    func verifyPin(_ pin: String, for profile: Profile) -> Bool {
        guard let hash = profile.passwordHash else { return true }
        return Self.hashPin(pin) == hash
    }

    // MARK: Stremio session per profile (harbor.auth.<localId>)

    /// profiles.tsx stremioSourceProfileId: whose `harbor.auth.<id>` this profile reads. A new
    /// profile shares the primary's Stremio account (createProfile sets shareStremioWith), so
    /// reading only its own key left every TV-made profile without the household's library,
    /// watchlist and Stremio addons, while the engine's own reads (readActiveStremioAuthKey)
    /// followed the share (profiles bug pass).
    func stremioSourceId(for id: String) -> String {
        guard let p = profiles.first(where: { $0.id == id }), let share = p.shareStremioWith else { return id }
        return profiles.contains { $0.id == share } ? share : id
    }

    func stremioSession(for id: String) -> StremioSession? {
        guard let raw = KeyValueStore.shared.get("harbor.auth.\(stremioSourceId(for: id))"), let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(StremioSession.self, from: data)
    }

    /// lib/auth.tsx commitSession / signOut. A sign-in is the profile's own and ends any share; a
    /// sign-out from a sharing profile only ends the share (the primary stays signed in).
    /// (profiles bug pass) Written through KeyValueStore and mirrored into the bundle: the engine's
    /// localStorage map is filled once at boot, so a SecretStore-only write left upstream's
    /// addon-store / watchlist / mark-watched on the old authKey (or none) until a relaunch — a
    /// sign-out kept writing to the account just left.
    func setStremioSession(_ s: StremioSession?, for id: String) {
        let key = "harbor.auth.\(id)"
        let i = profiles.firstIndex { $0.id == id }
        let sharing = i.map { profiles[$0].shareStremioWith != nil } ?? false
        if let s, let data = try? JSONEncoder().encode(s), let raw = String(data: data, encoding: .utf8) {
            if sharing, let i { profiles[i].shareStremioWith = nil; persist() }
            try? KeyValueStore.shared.set(raw, for: key)
            HarborEngine.loaded?.syncStorage(key: key, value: raw)
        } else if sharing, let i {
            profiles[i].shareStremioWith = nil
            persist()
        } else {
            KeyValueStore.shared.remove(key)
            HarborEngine.loaded?.syncStorage(key: key, value: nil)
        }
        objectWillChange.send()
    }

    func reset() {
        for p in profiles { SecretStore.remove("harbor.auth.\(p.id)") }
        profiles = []; activeId = nil; sessionUnlockedIds = []; parentalUnlockedFor = nil
        KeyValueStore.shared.remove(Self.profilesKey); Prefs.remove(Self.activeKey); KeyValueStore.shared.remove(Self.idMapKey)
        HarborEngine.loaded?.syncStorage(key: Self.profilesKey, value: nil)
        HarborEngine.loaded?.syncStorage(key: Self.idMapKey, value: nil)
    }

    func installFixture(_ list: [Profile], activeId: String?) {
        profiles = list
        self.activeId = activeId
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(Blob(activeId: activeId, profiles: profiles)),
              let raw = String(data: data, encoding: .utf8) else { return }
        try? KeyValueStore.shared.set(raw, for: Self.profilesKey)
        HarborEngine.loaded?.syncStorage(key: Self.profilesKey, value: raw)
        HarborEngine.loaded?.emitEvent("harbor:profiles-updated")
    }

    static func newId() -> String {
        let t = String(Int(Date().timeIntervalSince1970 * 1000), radix: 36)
        let r = String((0..<6).map { _ in "abcdefghijklmnopqrstuvwxyz0123456789".randomElement()! })
        return "p_\(t)_\(r)"
    }

    /// A PIN the keypad (PinPadView: 0-9 only) can type back. `Int(_:)` also takes "+123" and
    /// "-123", and phone typing can deliver those, which locked the profile for good (profiles bug pass).
    static func isValidPin(_ pin: String) -> Bool {
        pin.count == 4 && pin.unicodeScalars.allSatisfy { $0.value >= 48 && $0.value <= 57 }
    }

    /// Same scheme as upstream src/lib/profile-password.ts, so a PIN typed here matches desktop semantics.
    static func hashPin(_ pin: String) -> String {
        let digest = SHA256.hash(data: Data("harbor-profile-v1|\(pin)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

// (bug pass 2) Lenient per-field decoding for roster entries written by profile sync / desktop
// (lib/profiles.tsx Profile). Only `id` is required; the others fall back to what a fresh profile
// has. In extensions so the memberwise inits (seedIfEmpty, create, ProfileEditorView) stay.
extension ProfilesStore.Profile {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: LenientKey.self)
        guard let id: String = c.lenient("id"), !id.isEmpty else {
            throw DecodingError.keyNotFound(LenientKey("id"), .init(codingPath: c.codingPath, debugDescription: "profile without an id"))
        }
        self.id = id
        syncId = c.lenient("syncId")
        name = c.lenient("name") ?? "Profile"
        avatar = c.lenient("avatar")
        color = c.lenient("color") ?? "#7dd3fc"   // ProfilesStore.colors[0] (main-actor static)
        isPrimary = c.lenient("isPrimary") ?? false
        // A kid entry that is present keeps kid mode even when one of its fields is off (Kid's
        // own init never drops it for a bad age), so a stray value can't turn a kid profile adult.
        kid = c.lenient("kid")
        passwordHash = c.lenient("passwordHash")
        createdAt = c.lenient("createdAt") ?? 0
        settingsLinked = c.lenient("settingsLinked")
        hideContent = c.lenient("hideContent")
        lockedTabs = c.lenient("lockedTabs")
        shareStremioWith = c.lenient("shareStremioWith")
        bootstrap = c.lenient("bootstrap")
    }
}

extension ProfilesStore.Profile.Kid {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: LenientKey.self)
        // lib/kids.ts KidConfig.age is a number; a fractional or out-of-range one is truncated
        // rather than failing (Int(_:) of a non-finite Double would trap).
        func int(_ key: String) -> Int? {
            if let i: Int = c.lenient(key) { return i }
            if let d: Double = c.lenient(key), d.isFinite, abs(d) < 1_000_000 { return Int(d) }
            return nil
        }
        age = int("age") ?? 0
        curfewMinutes = int("curfewMinutes")
        parentPinHash = c.lenient("parentPinHash")
    }
}
