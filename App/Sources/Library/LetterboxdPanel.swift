import SwiftUI

/// Settings → Letterboxd (settings/letterboxd-panel.tsx, public mode): a Letterboxd username is
/// checked against Stremboxd and turns on the Library's Letterboxd tab (the watchlist) and the
/// Letterboxd rows on Movies. Full mode (password sign-in) stays on the desktop app.
@MainActor
final class LetterboxdModel: ObservableObject {
    struct Status: Decodable { var enabled: Bool; var mode: String; var username: String; var active: Bool; var fullConnected: Bool }
    struct Connect: Decodable { var ok: Bool; var catalogs: Int; var message: String? }

    @Published private(set) var status: Status?
    @Published private(set) var note: String?
    @Published private(set) var noteOk = false
    @Published private(set) var busy = false

    private var profile: (id: String, linked: Bool) {
        let p = ProfilesStore.shared.active
        return (p?.id ?? "default", p?.linked ?? true)
    }

    func refresh() async {
        let p = profile
        status = try? await HarborEngine.shared.call("letterboxd.status", [p.id, p.linked])
    }

    /// letterboxd-panel handleVerify.
    func connect(_ username: String) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        let p = profile
        do {
            let r: Connect = try await HarborEngine.shared.call("letterboxd.connect", [p.id, p.linked, username])
            noteOk = r.ok
            note = r.ok ? T("Connected. %lld catalogs are available.", r.catalogs) : (r.message ?? "Could not reach Stremboxd. Check your connection.")
        } catch {
            noteOk = false
            note = "Could not reach Stremboxd. Check your connection."
        }
        await refresh()
    }

    /// "Enable Letterboxd integration" switched off.
    func disable() async {
        let p = profile
        _ = try? await HarborEngine.shared.callJSON("letterboxd.disable", [.string(p.id), .bool(p.linked)])
        note = nil
        await refresh()
    }
}

struct LetterboxdPanel: View {
    @StateObject private var model = LetterboxdModel()
    @State private var username = ""
    /// (device-flow pass 3) Disconnect asks nothing first, like letterboxd-panel.tsx
    /// handleDisconnect, and Connect swaps it out under the ring; the ring follows to the step's
    /// lead button (Disconnect ↔ Connect) instead of falling off the panel.
    @FocusState private var lead: Bool

    init() {}

    var body: some View {
        VStack(alignment: .leading, spacing: BP.px(10)) {
            if let s = model.status, s.active {
                Text("Connected as \(s.username)").font(BP.sans(16, .semibold)).foregroundStyle(BP.ink)
                Text("Your watchlist shows in the Library, and your Letterboxd rows on Movies.").font(BP.sans(14)).foregroundStyle(BP.inkMuted)
                Button("Disconnect") { Task { await model.disable(); refocus() } }.buttonStyle(BPActionStyle())
                    .focused($lead)
            } else {
                Text("Letterboxd username").font(BP.sans(16, .semibold)).foregroundStyle(BP.ink)
                Text("The handle in your profile address, letterboxd.com/your-name.").font(BP.sans(14)).foregroundStyle(BP.inkMuted)
                HStack(alignment: .bottom, spacing: BP.px(8)) {
                    BPField(label: "Letterboxd username", placeholder: "your-name", text: $username)
                        .frame(maxWidth: BP.px(420))
                    // Dimmed, not disabled, while the field is empty, so the ring can land here.
                    let empty = username.trimmingCharacters(in: .whitespaces).isEmpty
                    Button(model.busy ? "Connecting…" : "Connect") {
                        guard !empty else { return }
                        Task {
                            await model.connect(username)
                            if model.status?.active == true { refocus() }
                        }
                    }
                        .buttonStyle(BPActionStyle(primary: true, busy: model.busy || empty))
                        .focused($lead)
                }
                Text("Checks the username against Stremboxd and turns on the catalogs it finds.").font(BP.sans(12)).foregroundStyle(BP.inkSubtle)
            }
            if let n = model.note { BPNote(text: n, tone: model.noteOk ? BP.live : BP.danger) }
        }
        .task {
            await model.refresh()
            if username.isEmpty, let s = model.status { username = s.username }
        }
    }

    /// The step's lead button, once it is on screen.
    private func refocus() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { lead = true }
    }
}
