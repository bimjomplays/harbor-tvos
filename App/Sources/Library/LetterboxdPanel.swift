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
        busy = true
        defer { busy = false }
        let p = profile
        do {
            let r: Connect = try await HarborEngine.shared.call("letterboxd.connect", [p.id, p.linked, username])
            noteOk = r.ok
            note = r.ok ? "Connected. \(r.catalogs) catalogs are available." : (r.message ?? "Could not reach Stremboxd. Check your connection.")
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

    init() {}

    var body: some View {
        VStack(alignment: .leading, spacing: BP.px(10)) {
            if let s = model.status, s.active {
                Text("Connected as \(s.username)").font(BP.sans(16, .semibold)).foregroundStyle(BP.ink)
                Text("Your watchlist shows in the Library, and your Letterboxd rows on Movies.").font(BP.sans(14)).foregroundStyle(BP.inkMuted)
                Button("Disconnect") { Task { await model.disable() } }.buttonStyle(BPActionStyle())
            } else {
                Text("Letterboxd username").font(BP.sans(16, .semibold)).foregroundStyle(BP.ink)
                Text("The handle in your profile address, letterboxd.com/your-name.").font(BP.sans(14)).foregroundStyle(BP.inkMuted)
                HStack(alignment: .bottom, spacing: BP.px(8)) {
                    BPField(label: "Letterboxd username", placeholder: "your-name", text: $username)
                        .frame(maxWidth: BP.px(420))
                    Button(model.busy ? "Connecting…" : "Connect") { Task { await model.connect(username) } }
                        .buttonStyle(BPActionStyle(primary: true))
                        .disabled(model.busy || username.trimmingCharacters(in: .whitespaces).isEmpty)
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
}
