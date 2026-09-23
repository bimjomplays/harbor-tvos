import Foundation
import Combine

/// Sports room state (use-bp-sports.ts): mode, group, day and the finished page the engine
/// builds from upstream's hub feeds. The engine serves cache first and raises
/// `harbor:sports-updated` as feeds land; we re-read the page on each one.
@MainActor
final class SportsModel: ObservableObject {
    struct Side: Decodable, Equatable { var id: String; var name: String; var abbr: String; var logo: String; var score: String; var winner: Bool; var record: String?; var rank: Int? }
    struct Context: Decodable, Equatable { var id: String; var name: String; var round: String; var draw: String; var venue: String; var major: Bool }
    struct Game: Decodable, Identifiable, Equatable {
        var id: String; var league: String; var state: String; var detail: String
        var home: Side; var away: Side
        var startMs: Double; var dateOnly: String?; var context: Context?; var source: String?
        var artwork: String?; var poster: String?; var broadcasts: [String]?; var savedAt: Double?
        var key: String; var leagueLabel: String; var leagueLogo: String; var group: String
        var statusText: String; var live: Bool; var single: Bool; var faceOff: Bool; var headline: String; var quiet: String; var startLabel: String
        // Only the fields the engine needs back for detail(); Encodable via a trimmed mirror.
        var wire: AnyJSON {
            var o: [String: AnyJSON] = ["id": .string(id), "league": .string(league), "state": .string(state), "detail": .string(detail), "startMs": .number(startMs),
                                        "home": side(home), "away": side(away)]
            if let source { o["source"] = .string(source) }
            if let dateOnly { o["dateOnly"] = .string(dateOnly) }
            if let c = context { o["context"] = .object(["id": .string(c.id), "name": .string(c.name), "round": .string(c.round), "draw": .string(c.draw), "venue": .string(c.venue), "major": .bool(c.major)]) }
            return .object(o)
        }
        private func side(_ s: Side) -> AnyJSON {
            .object(["id": .string(s.id), "name": .string(s.name), "abbr": .string(s.abbr), "logo": .string(s.logo), "score": .string(s.score), "winner": .bool(s.winner)])
        }
    }
    struct Row: Decodable, Identifiable { var key: String; var title: String; var description: String?; var games: [Game]; var id: String { key } }
    struct Chip: Decodable, Identifiable { var key: String; var label: String; var icon: String?; var id: String { key } }
    struct Status: Decodable { var busy: Bool; var failed: Bool; var failedKeys: [String]; var stale: Bool; var at: Double; var note: String? }
    struct Page: Decodable {
        var mode: String; var group: String; var groups: [Chip]; var showGroups: Bool
        var day: String; var today: String; var liveDays: [String]; var dateTitle: String
        var heroes: [Game]; var rows: [Row]; var status: Status; var empty: Bool; var personalized: Bool; var explore: [Chip]
    }
    struct Day: Decodable, Identifiable { var key: String; var label: String; var today: Bool; var id: String { key } }
    struct Consent: Decodable { var status: String }

    enum Mode: String, CaseIterable { case forYou = "for-you", live, schedule, hot, explore
        var label: String { switch self { case .forYou: return "For you"; case .live: return "Live now"; case .schedule: return "Schedule"; case .hot: return "Hot"; case .explore: return "Explore" } }
    }

    @Published private(set) var consent: String = "unknown"
    @Published private(set) var page: Page?
    @Published private(set) var days: [Day] = []
    @Published private(set) var loading = false
    @Published var mode: Mode = .forYou
    @Published var group: String = "all"
    @Published var day: String?
    @Published private(set) var browsing = false

    private var unsubscribe: (() -> Void)?
    private var reloadTask: Task<Void, Never>?
    private var poll: Task<Void, Never>?

    deinit { poll?.cancel(); reloadTask?.cancel(); unsubscribe?() }

    func start() async {
        consent = ((try? await HarborEngine.shared.call("sports.consent", [])) as Consent?)?.status ?? "unknown"
        guard consent == "accepted" else { return }
        if unsubscribe == nil {
            unsubscribe = HarborEngine.shared.onEvent { [weak self] type, _ in
                guard type == "harbor:sports-updated" else { return }
                self?.scheduleReload()
            }
        }
        days = (try? await HarborEngine.shared.call("sports.days", [])) ?? []
        await reload()
        poll?.cancel()
        poll = Task { [weak self] in
            // use-hub.ts: 60 s repoll for day/live boards (the engine decides what is fresh).
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                await self?.reload()
            }
        }
    }

    func accept() async {
        consent = ((try? await HarborEngine.shared.call("sports.accept", [])) as Consent?)?.status ?? "accepted"
        await start()
    }

    func decline() async {
        consent = ((try? await HarborEngine.shared.call("sports.decline", [])) as Consent?)?.status ?? "declined"
    }

    /// Coalesce bursts of slice arrivals (upstream shares one render per 80 ms burst).
    private func scheduleReload() {
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await self?.reload()
        }
    }

    func reload(force: Bool = false) async {
        loading = true; defer { loading = false }
        let input: AnyJSON = .object(["mode": .string(mode.rawValue), "group": .string(group), "day": day.map { .string($0) } ?? .null,
                                      "browsing": .bool(browsing), "force": .bool(force), "locale": .string(Locale.current.identifier.replacingOccurrences(of: "_", with: "-"))])
        if let p: Page = try? await HarborEngine.shared.call("sports.page", [input]) { page = p }
    }

    func setMode(_ m: Mode) {
        mode = m
        if m != .schedule { day = nil }
        if m == .forYou || m == .live { group = "all"; browsing = false }
        Task { await reload() }
    }

    func setGroup(_ key: String) { group = key; browsing = false; Task { await reload() } }
    func browse(_ key: String) { browsing = true; group = key; mode = .forYou; Task { await reload() } }
    func setDay(_ key: String) { day = key; Task { await reload() } }

    func setLeagues(_ keys: [String]) async {
        _ = try? await HarborEngine.shared.callJSON("sports.setLeagues", [.array(keys.map { .string($0) })])
        await reload(force: true)
    }
}
