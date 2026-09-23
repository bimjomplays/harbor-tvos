import SwiftUI

/// Device-code / PIN sign-in for Trakt (lib/trakt/device-auth.ts) and Simkl (lib/simkl/device-auth.ts):
/// show a code, the viewer types it on a phone, we poll until the service says yes.
@MainActor
final class TraktModel: ObservableObject {
    /// Engine export prefix ("trakt" or "simkl") and the display name.
    let service: String
    let label: String
    init(service: String = "trakt", label: String = "Trakt") { self.service = service; self.label = label }

    struct Status: Decodable { var authenticated: Bool; var username: String? }
    struct Code: Decodable { var deviceCode: String; var userCode: String; var verificationUrl: String; var expiresIn: Double; var pollIntervalSec: Double }
    struct Poll: Decodable { var kind: String; var message: String?; var username: String? }

    @Published private(set) var status = Status(authenticated: false, username: nil)
    @Published private(set) var code: Code?
    @Published private(set) var note: String?
    private var pollTask: Task<Void, Never>?

    func refresh() async {
        status = (try? await HarborEngine.shared.call("\(service).status", [])) ?? Status(authenticated: false, username: nil)
    }

    func connect() async {
        note = nil
        do {
            let c: Code = try await HarborEngine.shared.call("\(service).deviceCode", [])
            code = c
            pollTask?.cancel()
            pollTask = Task { [weak self] in
                let deadline = Date().addingTimeInterval(c.expiresIn)
                var interval = max(3, c.pollIntervalSec)
                while !Task.isCancelled, Date() < deadline {
                    try? await Task.sleep(for: .seconds(interval))
                    guard let self, !Task.isCancelled else { return }
                    let r: Poll = (try? await HarborEngine.shared.call("\(self.service).poll", [c.deviceCode])) ?? Poll(kind: "error", message: "poll failed", username: nil)
                    guard !Task.isCancelled, self.code?.deviceCode == c.deviceCode else { return }
                    switch r.kind {
                    case "authorized":
                        self.code = nil
                        await self.refresh()
                        self.note = "Connected as \(r.username ?? self.status.username ?? "\(self.label) user")."
                        return
                    case "slow_down": interval += 2
                    case "expired": self.code = nil; self.note = "That code expired. Try again."; return
                    case "denied": self.code = nil; self.note = "\(self.label) said no."; return
                    case "error": self.note = r.message
                    default: break
                    }
                }
            }
        } catch {
            note = error.localizedDescription
        }
    }

    func disconnect() async {
        pollTask?.cancel(); code = nil
        _ = try? await HarborEngine.shared.callJSON("\(service).disconnect", [])
        await refresh()
    }
}

struct TraktPanel: View {
    @StateObject private var model: TraktModel
    init(service: String = "trakt", label: String = "Trakt") {
        _model = StateObject(wrappedValue: TraktModel(service: service, label: label))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: BP.px(10)) {
            if model.status.authenticated {
                Text("Connected as \(model.status.username ?? "\(model.label) user")").font(BP.sans(16, .semibold)).foregroundStyle(BP.ink)
                Text("Scrobbles what you watch; watchlist and history sync arrive with Stage 5.").font(BP.sans(14)).foregroundStyle(BP.inkMuted)
                Button("Disconnect") { Task { await model.disconnect() } }.buttonStyle(BPActionStyle())
            } else if let c = model.code {
                Text("On your phone, open \(c.verificationUrl) and enter").font(BP.sans(14)).foregroundStyle(BP.inkMuted)
                Text(c.userCode).font(BP.display(44)).foregroundStyle(BP.ink).tracking(6)
                HStack(spacing: BP.px(8)) { ProgressView().tint(BP.inkMuted); Text("Waiting for \(model.label)…").font(BP.sans(13)).foregroundStyle(BP.inkSubtle) }
            } else {
                Text("Not connected").font(BP.sans(16, .semibold)).foregroundStyle(BP.ink)
                Text("Scrobbling, watchlist and history").font(BP.sans(14)).foregroundStyle(BP.inkMuted)
                Button("Connect \(model.label)") { Task { await model.connect() } }.buttonStyle(BPActionStyle(primary: true))
            }
            if let n = model.note { BPNote(text: n, tone: n.hasPrefix("Connected") ? BP.live : BP.danger) }
        }
        .task { await model.refresh() }
    }
}
