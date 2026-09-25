import Foundation

/// What a shell keeps for its rooms while the viewer is on another tab. ShellView builds a room
/// afresh on every tab switch, so state held by the room's own @StateObject went with it: Search
/// lost its query and results, Library its tab. Upstream keeps them outside the page:
/// - lib/search-context.tsx SearchProvider (app level): the query and the results;
/// - bp-view-state.ts useBpPersistedState("libraryTab"): the Library tab (its filters are the
///   page's own state and start fresh, except Media Servers', which restore from their saved
///   preferences); "liveCategory": Live TV's category chip; "collectionSource" and
///   "collectionCategory": the Collections source and TMDB category chips;
/// - bp-restore.ts: the cell the ring was on when the route was left, and its scroll.
/// use-bp-profile-reset / resetBpViewState: all of it is dropped when the active profile changes.
/// Owned by AppModel, so the PiP browse layer's shell has its own.
@MainActor
final class ShellViewState {
    private var searchModel: SearchModel?
    private var aiModel: AISearchModel?

    /// Built on first use: SearchModel listens to the engine, which does not exist before boot.
    var search: SearchModel {
        if let searchModel { return searchModel }
        let made = SearchModel()
        searchModel = made
        return made
    }

    var ai: AISearchModel {
        if let aiModel { return aiModel }
        let made = AISearchModel()
        aiModel = made
        return made
    }

    /// bp-view-state libraryTab (nil: LibraryModel's own default).
    var libraryTab: String?

    /// (open-items sweep 2) bp-view-state liveCategory (bp-live.tsx): the chip picked last. Written
    /// only by a pick, as upstream's setKey is; a key the shown source lacks is drawn as All but
    /// stays kept.
    var liveCategory: String = "all"

    /// (open-items sweep 2) bp-view-state collectionSource / collectionCategory (bp-collections.tsx).
    var collectionSource: String = "all"
    var collectionCategory: String = "All"

    /// bp-restore for Search: the result cell the ring was last on, under the query it answered.
    struct SearchSpot: Equatable {
        var query: String
        var row: String
        var cell: String
    }
    var searchSpot: SearchSpot?

    /// use-bp-profile-reset: another profile starts from a clean Search and Library.
    func reset() {
        searchModel = nil
        aiModel = nil
        libraryTab = nil
        searchSpot = nil
        // resetBpViewState: liveCategory "all", collectionCategory "All", collectionSource "all".
        liveCategory = "all"
        collectionSource = "all"
        collectionCategory = "All"
    }
}
