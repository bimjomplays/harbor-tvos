import SwiftUI

/// Library repair (settings/advanced-panel/library-repair-rows.tsx): "Repair library" rewrites
/// every Stremio library item to Stremio's exact schema with live progress
/// (`harbor:library-repair`), and "Fix corrupted anime" scans for anime saved under a movie or
/// series id, then removes just those. Both act on the active profile's Stremio library.
@MainActor
final class LibraryRepairModel: ObservableObject {
    struct Step: Decodable { var phase: String; var fetched: Int?; var total: Int?; var needsRepair: Int?; var pushed: Int? }
    struct Outcome: Decodable { var total: Int; var alreadyClean: Int; var repaired: Int; var unrepairable: Int }
    struct Found: Decodable, Identifiable { var id: String; var name: String }

    @Published private(set) var busy = false
    @Published private(set) var step: Step?
    @Published private(set) var outcome: Outcome?
    @Published private(set) var failure: String?
    /// idle | scanning | scanned | removing | done | error
    @Published private(set) var animePhase = "idle"
    @Published private(set) var found: [Found] = []
    @Published private(set) var removed = 0
    @Published private(set) var animeFailure: String?
    private var unsubscribe: (() -> Void)?

    deinit { unsubscribe?() }

    var authKey: String? {
        guard let p = ProfilesStore.shared.active else { return nil }
        return ProfilesStore.shared.stremioSession(for: p.id)?.authKey
    }

    private static func message(_ error: Error) -> String {
        let text = "\(error)"
        return text.split(separator: "\n").first.map(String.init)?.replacingOccurrences(of: "Error: ", with: "") ?? text
    }

    func run() async {
        guard let key = authKey, !busy else { return }
        if unsubscribe == nil {
            unsubscribe = HarborEngine.shared.onEvent { [weak self] type, detail in
                guard type == "harbor:library-repair", let s = detail.flatMap({ try? $0.decode(Step.self) }) else { return }
                self?.step = s
            }
        }
        busy = true
        failure = nil
        outcome = nil
        step = Step(phase: "fetching", fetched: nil, total: nil, needsRepair: nil, pushed: nil)
        defer { busy = false }
        do {
            let r: Outcome = try await HarborEngine.shared.call("libraryRoom.repair", [key])
            outcome = r
        } catch {
            failure = Self.message(error)
        }
    }

    /// LibraryRepairRow statusLine.
    var line: String {
        if let f = failure { return "Failed: \(f)" }
        if let r = outcome {
            if r.total == 0 { return "Library is empty. Nothing to repair." }
            return "\(r.repaired) fixed, \(r.alreadyClean) already clean" + (r.unrepairable > 0 ? ", \(r.unrepairable) unrepairable" : "") + "."
        }
        guard let s = step else {
            return "Rewrites every library item to match Stremio's exact schema. Run once if your Stremio app started crashing after Harbor synced playback."
        }
        switch s.phase {
        case "fetching": return s.total.map { "Fetching \($0) items…" } ?? "Fetching library index…"
        case "normalizing": return s.needsRepair.map { "\($0) items need repair." } ?? "Checking \(s.total ?? 0) items…"
        case "pushing": return "Pushing \(s.pushed ?? 0) of \(s.needsRepair ?? 0)…"
        default: return "Done."
        }
    }

    var cta: String { busy ? "Working…" : (outcome != nil ? "Run again" : "Repair now") }

    /// AnimeRepairRow: scan first; when the scan found entries the same button removes them.
    func animeAction() async {
        guard let key = authKey else { return }
        if animePhase == "scanned" && !found.isEmpty {
            animePhase = "removing"
            do {
                let n: Int = try await HarborEngine.shared.call("libraryRoom.animeHeal", [key])
                removed = n
                animePhase = "done"
            } catch {
                animeFailure = Self.message(error)
                animePhase = "error"
            }
        } else {
            animePhase = "scanning"
            animeFailure = nil
            do {
                let list: [Found] = try await HarborEngine.shared.call("libraryRoom.animeScan", [key])
                found = list
                animePhase = "scanned"
            } catch {
                animeFailure = Self.message(error)
                animePhase = "error"
            }
        }
    }

    var animeBusy: Bool { animePhase == "scanning" || animePhase == "removing" }
    var showRemove: Bool { animePhase == "scanned" && !found.isEmpty }

    var animeLine: String {
        if let f = animeFailure { return "Failed: \(f)" }
        switch animePhase {
        case "scanning": return "Scanning your library…"
        case "scanned":
            if found.isEmpty { return "No issues found. Your anime library looks clean." }
            let names = found.prefix(4).map(\.name).joined(separator: ", ") + (found.count > 4 ? "…" : "")
            return "Found \(found.count): \(names). These are saved under the wrong id, which breaks Continue Watching and Trakt marking."
        case "removing": return "Removing…"
        case "done": return "Removed \(removed). Rewatch and they re-add correctly."
        default: return "Finds anime saved under a movie or series id (which breaks Continue Watching and Trakt) and removes just those so they re-add correctly."
        }
    }

    var animeCta: String {
        switch animePhase {
        case "scanning": return "Scanning…"
        case "removing": return "Removing…"
        case "scanned" where !found.isEmpty: return "Remove \(found.count)"
        case "done", "error", "scanned": return "Scan again"
        default: return "Scan for corruption"
        }
    }
}

struct LibraryRepairPanel: View {
    @StateObject private var model = LibraryRepairModel()
    let onRepaired: () -> Void

    init(onRepaired: @escaping () -> Void) { self.onRepaired = onRepaired }

    var body: some View {
        VStack(alignment: .leading, spacing: BP.px(16)) {
            if model.authKey == nil {
                row("Repair library", "Sign in to Stremio first. The repair scans only the active profile's library.", tone: BP.inkMuted)
                row("Repair anime library", "Sign in to Stremio first. This scans the active profile's library.", tone: BP.inkMuted)
            } else {
                HStack(alignment: .center, spacing: BP.px(16)) {
                    row("Repair library", model.line, tone: (model.outcome?.repaired ?? 0) > 0 && model.failure == nil ? BP.live : BP.inkMuted)
                    Spacer(minLength: BP.px(12))
                    Button {
                        Task {
                            await model.run()
                            onRepaired()
                        }
                    } label: { Label(model.cta, systemImage: "wrench.and.screwdriver") }
                    .buttonStyle(BPActionStyle(primary: model.outcome == nil))
                    .disabled(model.busy)
                }
                HStack(alignment: .center, spacing: BP.px(16)) {
                    VStack(alignment: .leading, spacing: BP.px(6)) {
                        row("Fix corrupted anime", model.animeLine, tone: model.showRemove ? BP.danger : (model.animePhase == "done" && model.removed > 0 ? BP.live : BP.inkMuted))
                        if model.showRemove {
                            Text("This deletes those entries from your library. Playing them again re-adds them.")
                                .font(BP.sans(12)).foregroundStyle(BP.inkSubtle)
                        }
                    }
                    Spacer(minLength: BP.px(12))
                    Button {
                        Task {
                            let removing = model.showRemove
                            await model.animeAction()
                            if removing { onRepaired() }
                        }
                    } label: { Label(model.animeCta, systemImage: "wrench.and.screwdriver") }
                    .buttonStyle(BPActionStyle(primary: model.showRemove))
                    .disabled(model.animeBusy)
                }
            }
        }
        .padding(BP.px(18))
        .frame(maxWidth: BP.px(1100), alignment: .leading)
        .background(RoundedRectangle(cornerRadius: BP.rMD, style: .continuous).fill(BP.panel))
        .focusSection()
    }

    private func row(_ label: String, _ sub: String, tone: Color) -> some View {
        VStack(alignment: .leading, spacing: BP.px(4)) {
            Text(label).font(BP.sans(16, .semibold)).foregroundStyle(BP.ink)
            Text(sub).font(BP.sans(13)).foregroundStyle(tone).fixedSize(horizontal: false, vertical: true)
        }
    }
}
