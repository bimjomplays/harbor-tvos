import Foundation

/// AI search on the Search screen: components/search/ai-search/use-ai-suggest.ts (status, results,
/// error, ranQuery, run) and the aiMode / auto-run rules of search-overlay.tsx + ai-search-section.tsx.
/// The engine (engine/aiSearch.ts) holds the key, calls the provider and resolves the picks.
@MainActor
final class AISearchModel: ObservableObject {
    /// engine aiSearch.state.
    struct State: Decodable, Equatable {
        struct Saved: Decodable, Equatable { var openrouter: String?; var groq: String?; var jina: String? }
        var tab: String
        var model: String
        var label: String
        var provider: String
        var providerName: String
        var anyKey: Bool
        var hasKey: Bool
        var saved: Saved
        var webSearch: Bool
    }
    /// engine aiSearch.models (ai-models AiModel rows).
    struct ModelRow: Decodable, Identifiable, Equatable {
        var id: String; var label: String; var provider: String; var providerName: String; var free: Bool; var recommended: Bool
    }
    struct Models: Decodable {
        struct Defaults: Decodable { var openrouter: String; var groq: String }
        var openrouter: [ModelRow]
        var groq: [ModelRow]
        var menu: [ModelRow]
        var defaults: Defaults
    }
    /// lib/ai-search AiResult.
    struct Result: Decodable, Identifiable {
        var meta: Meta
        var season: Int?
        var episode: Int?
        var episodeTitle: String?
        var isEpisode: Bool { season != nil && episode != nil }
        var id: String { isEpisode ? "\(meta.id):\(season ?? 0):\(episode ?? 0)" : meta.id }
    }
    private struct Run: Decodable { var status: String; var query: String; var results: [Result]?; var message: String?; var detail: String? }

    enum Status: Equatable { case idle, loading, done, error }

    @Published private(set) var state: State?
    @Published private(set) var menu: [ModelRow] = []
    /// search-overlay.tsx aiMode.
    @Published var aiMode = false { didSet { if aiMode != oldValue { scheduleAuto() } } }
    @Published private(set) var status: Status = .idle
    @Published private(set) var results: [Result] = []
    @Published private(set) var errorMessage: String?
    @Published private(set) var errorDetail: String?
    @Published private(set) var ranQuery = ""

    private var query = ""
    private var reqId = 0
    private var auto: Task<Void, Never>?

    private var profile: (id: String, linked: Bool) {
        let p = ProfilesStore.shared.active
        return (p?.id ?? "default", p?.linked ?? true)
    }

    /// search-overlay.tsx: the AI button shows when either provider has a key.
    var available: Bool { state?.anyKey == true }

    func load() async {
        let p = profile
        state = try? await HarborEngine.shared.call("aiSearch.state", [p.id, p.linked])
        if state?.anyKey != true { aiMode = false }
        // No key, no OpenRouter catalog fetch (review 34).
        guard state?.anyKey == true else { return }
        if let m: Models = try? await HarborEngine.shared.call("aiSearch.models", [p.id, p.linked]) { menu = m.menu }
    }

    /// ai-mode-button.tsx onSelectModel: `update({ aiSearchModel: id, aiSearchProvider: providerTabFor(id) })`, then AI mode on.
    func selectModel(_ id: String) async {
        let p = profile
        let none: String? = nil
        if let s: State = try? await HarborEngine.shared.call("aiSearch.setModel", [id, none, p.id, p.linked]) { state = s }
        aiMode = true
        reset()
        scheduleAuto()
    }

    /// use-ai-suggest.ts: a new query drops the previous answer; ai-search-section.tsx then waits
    /// 1.6 s after the last keystroke (aiMode, a key, at least six characters) before asking.
    func queryChanged(_ q: String) {
        let trimmed = q.trimmingCharacters(in: .whitespaces)
        guard trimmed != query else { return }
        query = trimmed
        reset()
        scheduleAuto()
    }

    private func reset() {
        reqId += 1
        status = .idle
        results = []
        errorMessage = nil
        errorDetail = nil
        ranQuery = ""
    }

    private func scheduleAuto() {
        auto?.cancel()
        guard aiMode, state?.hasKey == true, status == .idle, query.count >= 6 else { return }
        let q = query
        auto = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1600))
            guard !Task.isCancelled, let self, self.query == q, self.status == .idle else { return }
            await self.run()
        }
    }

    /// search-overlay.tsx Enter in AI mode (setAiRunSignal) and the error card's retry.
    func runNow() {
        auto?.cancel()
        guard !query.isEmpty, state?.hasKey == true else { return }
        if !aiMode { aiMode = true }
        Task { await run() }
    }

    /// use-ai-suggest.ts run().
    func run() async {
        reqId += 1
        let id = reqId
        let q = query
        status = .loading
        errorMessage = nil
        errorDetail = nil
        ranQuery = q
        let p = profile
        do {
            let r: Run = try await HarborEngine.shared.call("aiSearch.run", [q, p.id, p.linked])
            guard id == reqId else { return }
            switch r.status {
            case "done":
                results = r.results ?? []
                status = .done
                let metas = results.map(\.meta)
                Task { await CardMarksStore.shared.refresh(metas) }
            default:
                errorMessage = r.message ?? T("AI search failed.")
                errorDetail = r.detail
                status = .error
            }
        } catch {
            guard id == reqId else { return }
            errorMessage = T("AI search failed.")
            errorDetail = error.localizedDescription
            status = .error
        }
    }

    /// ai-search-section.tsx thinkingPhrases.
    var thinkingPhrases: [String] {
        let shortQ = query.count > 26 ? String(query.prefix(25)) + "…" : query
        return [
            T("Reading your search"),
            T("Looking for \"%@\"", shortQ),
            T("Scanning the catalog"),
            T("Cross-referencing titles and episodes"),
            T("Checking plots, cast, and scenes"),
            T("Matching the details"),
            T("Ranking the best matches"),
            T("Pulling posters and ratings"),
            T("Almost there"),
        ]
    }

    /// components/ai-example-hint.tsx SEARCH_EXAMPLES.
    static let examples = [
        "the movie where a hitman spares a kid",
        "a show like Severance but funnier",
        "the south park episode with kanye west",
        "underrated 90s sci-fi thrillers",
        "feel-good anime for a rainy day",
        "movies with a twist you never see coming",
        "the one where they rob a casino",
        "slow-burn mysteries set in small towns",
    ]
}
