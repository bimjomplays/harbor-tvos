import Foundation
import SwiftUI

/// views/calendar.tsx state: the shown month, the session-only filter / "Watchlist only" / Sub-Dub
/// choices, and the engine's month build (`calendar.month`). The source, week start and poster
/// size are settings, written through `calendar.setPref` like upstream's update().
@MainActor
final class CalendarModel: ObservableObject {
    struct Source: Decodable, Identifiable, Equatable { var id: String; var label: String; var hint: String; var icon: String }
    struct Filter: Decodable, Identifiable, Equatable { var id: String; var label: String; var count: Int }
    struct CustomSummary: Decodable, Equatable { var activeCount: Int; var summary: String }

    struct Entry: Decodable, Identifiable, Equatable {
        var id: String
        var name: String
        var type: String
        var poster: String?
        var releaseDate: String
        var releaseTime: String?
        var releaseAtMs: Double?
        var upcoming: Bool?
        var isAnime: Bool
        var overview: String?
        var voteAverage: Double?
        var tag: String
        var dateLong: String?
        var meta: Meta
        var season: Int?
        var episode: Int?

        static func == (a: Entry, b: Entry) -> Bool { a.id == b.id && a.releaseAtMs == b.releaseAtMs && a.name == b.name }
        var rating: Double { voteAverage ?? 0 }
        /// calendar-chip.tsx tagClass: rose for anime, amber for movies, blue for TV.
        var tagColor: Color { isAnime ? Color(hex: 0xfb7185) : (type == "movie" ? Color(hex: 0xfbbf24) : Color(hex: 0x60a5fa)) }
    }

    struct Cell: Decodable, Identifiable, Equatable {
        var iso: String
        var day: Int
        var inMonth: Bool
        var isToday: Bool
        @LossyArray var items: [Entry]   // (bug pass 2) lossy: synced titles
        var id: String { iso }
    }

    struct Month: Decodable, Equatable {
        var year: Int
        var month: Int
        var monthLabel: String
        var todayISO: String
        var source: String
        var sources: [Source]
        var traktConnected: Bool
        var simklConnected: Bool
        var signedIn: Bool
        var weekStartsMonday: Bool
        var posterSize: String
        var weekdays: [String]
        var animeDubToggle: Bool
        var animeDub: Bool
        var hideTypeTag: Bool
        var filters: [Filter]
        var filter: String
        var watchlistToggle: Bool
        var watchlistOnly: Bool
        var custom: CustomSummary?
        var status: String
        var error: String?
        var emptyHeading: String
        var emptyBody: String
        var total: Int
        var cells: [Cell]
    }

    @Published private(set) var data: Month?
    @Published private(set) var loading = false
    @Published private(set) var year: Int
    /// 0-based, as upstream's Date months.
    @Published private(set) var month: Int
    @Published private(set) var filter = "all"
    @Published private(set) var watchlistOnly = false
    @Published private(set) var animeDub = false
    private var generation = 0

    init() {
        let now = Calendar.current.dateComponents([.year, .month], from: Date())
        year = now.year ?? 2026
        month = (now.month ?? 1) - 1
    }

    private var profile: (id: String, linked: Bool, authKey: String?) {
        let p = ProfilesStore.shared.active
        return (p?.id ?? "default", p?.linked ?? true, p.flatMap { ProfilesStore.shared.stremioSession(for: $0.id)?.authKey })
    }

    var large: Bool { data?.posterSize == "large" }

    func load() async {
        generation += 1
        let mine = generation
        loading = true
        let p = profile
        let input: AnyJSON = .object([
            "profileId": .string(p.id), "linked": .bool(p.linked), "authKey": p.authKey.map { .string($0) } ?? .null,
            "year": .number(Double(year)), "month": .number(Double(month)),
            "filter": .string(filter), "watchlistOnly": .bool(watchlistOnly), "animeDub": .bool(animeDub),
        ])
        let out: Month? = try? await HarborEngine.shared.call("calendar.month", [input])
        // A newer request (month flipped again) owns the screen.
        guard mine == generation else { return }
        if let out {
            data = out
            filter = out.filter
            watchlistOnly = out.watchlistOnly
        }
        // The picked source's month (or a failure, which must not leave the skeleton up for good).
        if out.map({ $0.source == pendingSource }) ?? true { pendingSource = nil }
        loading = false
    }

    // calendar.tsx goPrev / goNext / goToday.
    func prev() { if month == 0 { month = 11; year -= 1 } else { month -= 1 }; Task { await load() } }
    func next() { if month == 11 { month = 0; year += 1 } else { month += 1 }; Task { await load() } }
    func today() {
        let now = Calendar.current.dateComponents([.year, .month], from: Date())
        year = now.year ?? year
        month = (now.month ?? 1) - 1
        Task { await load() }
    }

    func set(filter f: String) { filter = f; Task { await load() } }
    func toggleWatchlist() { guard data?.signedIn == true else { return }; watchlistOnly.toggle(); Task { await load() } }
    func set(animeDub dub: Bool) { animeDub = dub; Task { await load() } }

    /// The source just picked while its first month loads (use-calendar-data: rows cleared, loading).
    @Published private(set) var pendingSource: String?

    /// update({ calendarSource }) — use-calendar-data clears the rows when the source changes.
    /// (device-flow pass) Only the rows: dropping the whole month build also emptied the source and
    /// option chip rows, so the chip just pressed vanished under the ring (focus fell to the header
    /// or the tab bar) until the new source answered. The grid shows the skeleton meanwhile.
    func set(source id: String) {
        guard id != (pendingSource ?? data?.source) else { return }
        pendingSource = id
        Task { await pref(["calendarSource": .string(id)]) }
    }
    func toggleWeekStart() { Task { await pref(["weekStartsMonday": .bool(!(data?.weekStartsMonday ?? false))]) } }
    func set(posterSize size: String) { Task { await pref(["calendarPosterSize": .string(size)]) } }

    private func pref(_ patch: [String: AnyJSON]) async {
        let p = profile
        _ = try? await HarborEngine.shared.callJSON("calendar.setPref", [.string(p.id), .bool(p.linked), .object(patch)])
        await load()
    }
}

/// use-now.ts formatRemaining: "2d 4h 10m", "3h 5m", "12m".
enum AiringCountdown {
    static func remaining(_ ms: Double) -> String {
        let totalMinutes = max(0, Int(floor(ms / 60000)))
        let days = totalMinutes / 1440
        let hours = (totalMinutes % 1440) / 60
        let minutes = totalMinutes % 60
        var parts: [String] = []
        if days > 0 { parts.append("\(days)d") }
        if hours > 0 || days > 0 { parts.append("\(hours)h") }
        parts.append("\(minutes)m")
        return parts.joined(separator: " ")
    }

    /// airing-countdown.tsx: " · in 2d 4h" while the release is still ahead, nothing after.
    static func suffix(_ atMs: Double?, now: Date) -> String? {
        guard let atMs else { return nil }
        let left = atMs - now.timeIntervalSince1970 * 1000
        guard left > 0 else { return nil }
        return T("in %@", remaining(left))
    }
}

/// lib/reminders.ts as the TV sees it: the unseen count behind the Calendar tab's badge
/// (nav-items.tsx CalendarNavIcon), the toast the runner raises (emitListToast), and the
/// runner itself (lib/reminders-runner.tsx, run by the engine: 25 s after start, then every 6 h).
@MainActor
final class ReminderCenter: ObservableObject {
    static let shared = ReminderCenter()

    struct Fired: Decodable, Identifiable, Equatable { var id: String; var name: String; var poster: String?; var body: String; var at: Double }
    struct Row: Decodable, Identifiable, Equatable { var id: String; var name: String; var poster: String?; var type: String; var summary: String; var unseen: Bool }
    private struct Unseen: Decodable { var count: Int }

    @Published private(set) var unseen = 0
    @Published var toast: String?
    private var unsubscribe: (() -> Void)?

    private init() {}

    /// Mounted with the shell: follow the engine's reminder events and (re)start the runner for
    /// the active profile's TMDB key.
    func attach() async {
        if unsubscribe == nil {
            unsubscribe = HarborEngine.shared.onEvent { [weak self] type, detail in
                if type == "harbor:reminder-fired" {
                    if let text = detail?["text"]?.string { self?.toast = text }
                    Task { await self?.refresh() }
                } else if type == "harbor:reminders-changed" {
                    self?.unseen = Int(detail?["count"]?.number ?? 0)
                }
            }
        }
        let p = ProfilesStore.shared.active
        _ = try? await HarborEngine.shared.callJSON("calendar.startReminders", [.string(p?.id ?? "default"), .bool(p?.linked ?? true)])
        await refresh()
    }

    func refresh() async {
        if let u: Unseen = try? await HarborEngine.shared.call("calendar.unseen", []) { unseen = u.count }
    }

    /// calendar.tsx mount: clearUnseenReminders(). Returns what fired since the last visit.
    func takeUnseen() async -> [Fired] {
        let fired: [Fired] = (try? await HarborEngine.shared.call("calendar.clearUnseen", [])) ?? []
        unseen = 0
        return fired
    }

    func list() async -> [Row] {
        (try? await HarborEngine.shared.call("calendar.reminders", [])) ?? []
    }

    func remove(_ id: String) async -> [Row] {
        let rows: [Row] = (try? await HarborEngine.shared.call("calendar.removeReminder", [id])) ?? []
        await refresh()
        return rows
    }
}
