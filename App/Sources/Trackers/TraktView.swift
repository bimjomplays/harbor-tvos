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
    private var connectGen = 0

    func refresh() async {
        status = (try? await HarborEngine.shared.call("\(service).status", [])) ?? Status(authenticated: false, username: nil)
    }

    func connect() async {
        note = nil
        connectGen &+= 1
        let gen = connectGen
        do {
            let c: Code = try await HarborEngine.shared.call("\(service).deviceCode", [])
            // (bug pass) The panel closed (cancelConnect) or Connect was pressed again while the
            // code was being fetched: this code's poll would run unseen until it expired.
            guard gen == connectGen else { return }
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
                // The code's own lifetime ran out without a verdict (Simkl never says "expired").
                guard let self, !Task.isCancelled, self.code?.deviceCode == c.deviceCode else { return }
                self.code = nil
                self.note = "That code expired. Try again."
            }
        } catch {
            note = error.localizedDescription
        }
    }

    /// (bug pass 2) trakt-device-modal.tsx / simkl-device-modal.tsx: closing the panel before the
    /// code is confirmed calls cancelConnect (provider.tsx cancels the poll). The poll kept running
    /// until the code expired while the panel stayed alive off screen.
    func cancelConnect() {
        connectGen &+= 1
        pollTask?.cancel()
        pollTask = nil
        code = nil
    }

    func disconnect() async {
        pollTask?.cancel(); code = nil
        _ = try? await HarborEngine.shared.callJSON("\(service).disconnect", [])
        await refresh()
    }
}

struct TraktPanel: View {
    @StateObject private var model: TraktModel
    @ObservedObject private var settings = SettingsBridge.shared
    init(service: String = "trakt", label: String = "Trakt") {
        _model = StateObject(wrappedValue: TraktModel(service: service, label: label))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: BP.px(10)) {
            if model.status.authenticated {
                Text("Connected as \(model.status.username ?? "\(model.label) user")").font(BP.sans(16, .semibold)).foregroundStyle(BP.ink)
                Text("Scrobbles what you watch; watchlist and history sync arrive with Stage 5.").font(BP.sans(14)).foregroundStyle(BP.inkMuted)
            } else if let c = model.code {
                Text("On your phone, open \(c.verificationUrl) and enter").font(BP.sans(14)).foregroundStyle(BP.inkMuted)
                Text(c.userCode).font(BP.display(44)).foregroundStyle(BP.ink).tracking(6)
                HStack(spacing: BP.px(8)) { ProgressView().tint(BP.inkMuted); Text("Waiting for \(model.label)…").font(BP.sans(13)).foregroundStyle(BP.inkSubtle) }
            } else {
                Text("Not connected").font(BP.sans(16, .semibold)).foregroundStyle(BP.ink)
                Text("Scrobbling, watchlist and history").font(BP.sans(14)).foregroundStyle(BP.inkMuted)
            }
            // (settings device pass) One button that changes with the state (Connect → Cancel →
            // Disconnect) rather than three: Connect vanished once the code showed, leaving the
            // waiting panel with nothing to focus or cancel (trakt-device-modal.tsx has Cancel), and
            // the ring jumped elsewhere on the page; the same happened when the code was approved.
            HStack(spacing: BP.px(8)) {
                Button(primaryTitle) { primaryAction() }.buttonStyle(BPActionStyle(primary: !model.status.authenticated && model.code == nil))
                if model.status.authenticated && model.service == "simkl" {
                    let on = settings.slice.simklScrobbleEnabled ?? true
                    Button(on ? "Scrobbling on" : "Scrobbling off") { Task { try? await settings.patch(["simklScrobbleEnabled": .bool(!on)]) } }.buttonStyle(BPActionStyle(primary: on))
                }
            }
            if let n = model.note { BPNote(text: n, tone: n.hasPrefix("Connected") ? BP.live : BP.danger) }
        }
        .task { await model.refresh() }
        .onDisappear { model.cancelConnect() }   // (bug pass 2)
    }

    // T(): a String title is not looked up the way a Button literal is.
    private var primaryTitle: String {
        if model.status.authenticated { return T("Disconnect") }
        if model.code != nil { return T("Cancel") }
        return T("Connect %@", model.label)
    }

    private func primaryAction() {
        if model.status.authenticated {
            Task { await model.disconnect() }
        } else if model.code != nil {
            model.cancelConnect()
        } else {
            Task { await model.connect() }
        }
    }
}
