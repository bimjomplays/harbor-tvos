import Foundation
import Combine

/// Profile sync status, mirrored from the engine (upstream's lib/profile-sync runs inside the
/// bundle: pulls on boot and every 15 minutes, pushes 2.5 s after a change). Swift only
/// starts it, asks for an immediate pull, and shows the status.
@MainActor
final class SyncReader: ObservableObject {
    struct Status: Decodable, Equatable {
        var phase: String          // off | signed-out | no-refresh | first-pull | first-pull-failed | idle | pulling | pushing
        var armed: Bool
        var everPulled: Bool
        var queued: Int
        var lastPullAt: Double
        var lastPushAt: Double
        var lastError: String?     // network | auth | rate-limited | server
        var queuedSince: Double?   // ms; a queue older than QUEUE_STALE_MS is "not saved yet" (bp-status CloudOff)
    }

    enum Phase: Equatable { case idle, pulling, failed(String) }

    static let shared = SyncReader()

    @Published private(set) var status: Status?
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var lastPull: Date?
    private var unsubscribe: (() -> Void)?
    private var started = false

    private init() {}

    var queued: Int { status?.queued ?? 0 }
    /// profile-sync/status.ts isQueueStale: queued for over a minute, not merely a push in flight.
    func stale(at now: Date) -> Bool { status?.queuedSince.map { now.timeIntervalSince1970 * 1000 - $0 > 60_000 } ?? false }

    /// Follow the engine's status events and start the scheduler (idempotent).
    func start() async {
        if unsubscribe == nil {
            unsubscribe = HarborEngine.shared.onEvent { [weak self] type, detail in
                guard type == "harbor:sync-status", let s = detail.flatMap({ try? $0.decode(Status.self) }) else { return }
                self?.apply(s)
            }
        }
        guard !started else { return }
        started = true
        if let s: Status = try? await HarborEngine.shared.call("sync.start") { apply(s) }
    }

    /// One awaited pull, for boot and the "Pull now" button. Returns true when it succeeded.
    @discardableResult
    func pull() async -> Bool {
        struct Out: Decodable { var ok: Bool; var reason: String?; var status: Status }
        phase = .pulling
        guard let out: Out = try? await HarborEngine.shared.call("sync.pullNow") else {
            phase = .failed("engine unavailable"); return false
        }
        apply(out.status)
        if !out.ok { phase = .failed(Self.describe(out.reason)) }
        return out.ok
    }

    func stop() {
        started = false
        Task { _ = try? await HarborEngine.shared.callJSON("sync.stop") }
        status = nil
        phase = .idle
    }

    private func apply(_ s: Status) {
        // (perf pass) Each field is published only when it changed: a push cycle sends several
        // status events, and every one redrew the top bar's status glyphs (and Settings / Who's
        // watching when up) three times over.
        if status != s { status = s }
        let pulled = s.lastPullAt > 0 ? Date(timeIntervalSince1970: s.lastPullAt / 1000) : nil
        if lastPull != pulled { lastPull = pulled }
        let next: Phase
        switch s.phase {
        case "pulling", "first-pull", "pushing": next = .pulling
        case "first-pull-failed": next = .failed(Self.describe(s.lastError))
        default: next = s.lastError != nil ? .failed(Self.describe(s.lastError)) : .idle
        }
        if phase != next { phase = next }
    }

    private static func describe(_ reason: String?) -> String {
        switch reason {
        case "auth": return "signed out"
        case "rate-limited": return "rate limited, retrying"
        case "server": return "the server refused a write"
        case "network", nil: return "network"
        default: return reason ?? "unknown"
        }
    }
}
