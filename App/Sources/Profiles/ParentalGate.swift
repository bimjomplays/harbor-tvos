import Foundation
import Combine

/// lib/parental.tsx (ParentalProvider) + bp-top-bar.tsx useBpTabGate for the active profile.
/// The rule lives in the engine (engine/parental.ts `parental.gate`); the session unlock it takes
/// is ProfilesStore's (profiles.tsx sessionUnlockedIds + parental.tsx sessionUnlockedFor).
///
/// Upstream Big Picture shows a locked tab not at all while the profile is locked (visibleTabs
/// filters it out of the strip and the shoulder cycle alike). It opens again once the profile's
/// PIN is entered: in Who's watching, or in the profile editor's lock section.
@MainActor
final class ParentalGate: ObservableObject {
    static let shared = ParentalGate()

    struct Gate: Decodable, Equatable {
        var hasPin = false
        var anyLocked = false
        var locked = false
        var hiddenTabs: [String: Bool] = [:]
        var animeHidden = false
        /// `Room.rawValue`s the tab bar, tab cycling and every other way into a room skip.
        var hiddenRooms: [String] = []
    }

    /// lockable-tabs.ts LOCKABLE_TABS entry.
    struct LockableTab: Decodable, Identifiable, Equatable {
        var key: String
        var label: String
        var id: String { key }
    }

    @Published private(set) var gate = Gate()
    @Published private(set) var lockable: [LockableTab] = []

    private var bag = Set<AnyCancellable>()
    private var unsubscribe: (() -> Void)?
    private var generation = 0

    private init() {}

    func hides(_ room: Room) -> Bool { gate.hiddenRooms.contains(room.rawValue) }

    /// Follow the active profile, its locks and PIN, the session unlock, and settings writes
    /// (the engine copies a profile's hideContent into settings and says so). Idempotent.
    func attach() {
        guard unsubscribe == nil else { return }
        let store = ProfilesStore.shared
        Publishers.CombineLatest4(store.$profiles, store.$activeId, store.$sessionUnlockedIds, store.$parentalUnlockedFor)
            // @Published fires in willSet: let the store settle before reading it back.
            .debounce(for: .milliseconds(30), scheduler: RunLoop.main)
            .sink { [weak self] _ in Task { @MainActor in await self?.refresh() } }
            .store(in: &bag)
        unsubscribe = HarborEngine.shared.onEvent { [weak self] type, _ in
            guard type == "harbor:settings-updated" else { return }
            Task { @MainActor in await self?.refresh() }
        }
        Task { await refresh() }
    }

    func refresh() async {
        generation += 1
        let mine = generation
        let store = ProfilesStore.shared
        guard let p = store.active else {
            if gate != Gate() { gate = Gate() }
            return
        }
        let next: Gate? = try? await HarborEngine.shared.call("parental.gate", [p.id, p.linked, store.sessionUnlocked(p.id)])
        // A newer refresh started while this one waited: its answer wins.
        guard mine == generation, let next, next != gate else { return }
        gate = next
    }

    func loadLockable() async {
        guard lockable.isEmpty else { return }
        lockable = (try? await HarborEngine.shared.call("parental.lockable", [])) ?? []
    }
}
