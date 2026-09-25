import Foundation
import Combine

/// Harbor Voyages through the engine (engine/voyage.ts → voyageRoom): upstream's lib/voyage store
/// runs there as is (pool, headings, TMDB enrichment, streak, "harbor.voyage.v1"); this holds the
/// last snapshot it returned and the per-heading credits (port-hover-credits.ts).
@MainActor
final class VoyageModel: ObservableObject {
    struct Slot: Decodable { var index: Int; var meta: Meta?; var done: Bool; var progress: Double; var current: Bool }
    struct Active: Decodable {
        var id: String
        var themeId: String
        var themeLabel: String
        var tagline: String
        var accent: String
        var phase: String
        var targetLength: Int
        var picked: Int
        var ready: Bool
        var stuck: Bool
        var slots: [Slot]
        var watched: Int
        var current: Int
        var headings: [Meta]
        var next: Meta?
        var nextPosition: Int
        var played: Int
        var bannerItems: [Meta]
        var sailing: Bool { phase == "sailing" }
    }
    struct Snapshot: Decodable { var active: Active?; var streak: Int }
    struct Theme: Decodable, Identifiable {
        var id: String
        var label: String
        var tagline: String
        var type: String
        var genre: String?
        var accent: String
        var backdrop: String?
        var from: String
        var to: String
    }
    struct Credits: Decodable {
        struct Person: Decodable, Identifiable { var id: Int; var name: String; var profile: String? }
        var cast: [Person]
        var director: String?
    }
    private struct Started: Decodable { var ok: Bool; var state: Snapshot }
    private struct Launched: Decodable { var first: Meta?; var state: Snapshot }

    @Published private(set) var snapshot: Snapshot?
    @Published private(set) var themes: [Theme] = []
    /// voyage-chooser.tsx: the theme being charted, and the error when it would not chart.
    @Published private(set) var busy: String?
    @Published private(set) var error: String?
    /// voyage-chooser.tsx LengthPicker (3 / 5 / 7, 5 by default).
    @Published var length = 5
    /// port-hover-credits.ts `held`: a heading's credits once asked (nil inside = none found).
    @Published private(set) var credits: [String: Credits?] = [:]
    /// (open-items sweep) Headings whose last credits ask failed (not cached: the next focus asks
    /// again). usePortCredits' catch sets null, so the card drops its cast placeholders; here they
    /// stayed grey until an answer came.
    @Published private(set) var creditsFailed: Set<String> = []

    private var profile: (id: String, linked: Bool) {
        let p = ProfilesStore.shared.active
        return (p?.id ?? "default", p?.linked ?? true)
    }

    var active: Active? { snapshot?.active }

    /// (review 28) The voyage could not be read (no state, or no themes to choose from with no
    /// voyage under way): the view shows the error with Try again instead of a spinner for good.
    @Published private(set) var loadFailed = false

    func load() async {
        if themes.isEmpty { themes = (try? await HarborEngine.shared.call("voyageRoom.themes", [])) ?? [] }
        await refresh()
        loadFailed = snapshot == nil || (snapshot?.active == nil && themes.isEmpty)
    }

    func refresh() async {
        if let s: Snapshot = try? await HarborEngine.shared.call("voyageRoom.state", []) { snapshot = s }
    }

    /// voyage-chooser.tsx start(): one theme at a time; a pool under four titles does not chart.
    func start(_ theme: Theme) async {
        guard busy == nil else { return }
        busy = theme.id; error = nil
        let p = profile
        if let r: Started = try? await HarborEngine.shared.call("voyageRoom.start", [p.id, p.linked, theme.id, length]) {
            snapshot = r.state
            if !r.ok { error = "That route wouldn't chart. Try a different direction." }
        } else {
            error = "That route wouldn't chart. Try a different direction."
        }
        busy = nil
    }

    /// store.ts chooseHeading, then the headings the pick's TMDB related titles refine (refineAfterPick).
    /// Returns once the pick shows; `settle` brings the refinement later (review 33: focus moves
    /// at the pick, not a network round trip after it).
    func choose(_ meta: Meta) async {
        let p = profile
        guard let s: Snapshot = try? await HarborEngine.shared.call("voyageRoom.choose", [p.id, p.linked, meta.id]) else { return }
        snapshot = s
    }

    func settle(_ meta: Meta) async {
        guard let a = snapshot?.active, !a.ready else { return }
        let p = profile
        if let settled: Snapshot = try? await HarborEngine.shared.call("voyageRoom.settle", [p.id, p.linked, meta.id]) { snapshot = settled }
    }

    func undo() async {
        let p = profile
        if let s: Snapshot = try? await HarborEngine.shared.call("voyageRoom.undo", [p.id, p.linked]) { snapshot = s }
    }

    func reroll() async {
        let p = profile
        if let s: Snapshot = try? await HarborEngine.shared.call("voyageRoom.reroll", [p.id, p.linked]) { snapshot = s }
    }

    /// voyage-route.tsx sail(): launchVoyage, then the first film to play.
    func launch() async -> Meta? {
        guard let r: Launched = try? await HarborEngine.shared.call("voyageRoom.launch", []) else { return nil }
        snapshot = r.state
        return r.first
    }

    func end() async {
        if let s: Snapshot = try? await HarborEngine.shared.call("voyageRoom.end", []) { snapshot = s }
        error = nil
    }

    /// port-hover-credits.ts usePortCredits: director and cast faces, fetched once per heading.
    func loadCredits(_ meta: Meta) async {
        guard credits[meta.id] == nil else { return }
        let p = profile
        // A failed call is not cached as "no credits": the next focus asks again (review 33).
        creditsFailed.remove(meta.id)
        do {
            let c: Credits? = try await HarborEngine.shared.call("voyageRoom.credits", [p.id, p.linked, meta.id, meta.type])
            credits[meta.id] = .some(c)
        } catch {
            creditsFailed.insert(meta.id)
        }
    }
}
