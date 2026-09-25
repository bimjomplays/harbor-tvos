import SwiftUI
import CoreImage.CIFilterBuiltins

/// AniList / MyAnimeList sign-in for a television: the authorize link as text and a QR code,
/// the viewer signs in on a phone and pastes the code back (the tvOS keyboard accepts a paste
/// from the iPhone remote), then upstream exchanges it through Harbor's token proxy.
@MainActor
final class PasteTrackerModel: ObservableObject {
    struct Status: Decodable { var authenticated: Bool; var username: String? }
    let service: String   // "anilist" | "mal"
    let label: String
    @Published private(set) var status = Status(authenticated: false, username: nil)
    @Published private(set) var url: String?
    @Published private(set) var note: String?
    /// Whether `note` reports a success; set with it (LetterboxdPanel), so the tint no longer
    /// depends on the English wording.
    @Published private(set) var noteOk = false
    @Published private(set) var busy = false

    init(service: String, label: String) { self.service = service; self.label = label }

    func refresh() async {
        status = (try? await HarborEngine.shared.call("\(service).status", [])) ?? Status(authenticated: false, username: nil)
    }

    func begin() async {
        note = nil
        noteOk = false
        url = try? await HarborEngine.shared.call("\(service).authorizeUrl", [])
        if url == nil { note = "Couldn't build the sign-in link." }
    }

    /// Whether the code was accepted.
    func complete(_ pasted: String) async -> Bool {
        guard !busy else { return false }
        busy = true; defer { busy = false }
        struct Done: Decodable { var userName: String }
        do {
            let d: Done = try await HarborEngine.shared.call("\(service).complete", [pasted])
            url = nil
            await refresh()
            // anilist-connect-modal.tsx / mal-connect-modal.tsx: t("Connected as {username}").
            note = T("Connected as %@", d.userName)
            noteOk = true
            return true
        } catch {
            let text = "\(error)"
            note = text.split(separator: "\n").first.map(String.init)?.replacingOccurrences(of: "Error: ", with: "") ?? T("Sign-in failed.")
            noteOk = false
            return false
        }
    }

    func disconnect() async {
        _ = try? await HarborEngine.shared.callJSON("\(service).disconnect", [])
        url = nil
        // (settings pass 2) The last "Connected as …" stayed up under "Not connected".
        note = nil
        noteOk = false
        await refresh()
    }
}

struct PasteTrackerPanel: View {
    @StateObject private var model: PasteTrackerModel
    @State private var pasted = ""
    /// (settings pass 2) anilist-panel.tsx / mal-panel.tsx: Disconnect asks first.
    @State private var confirmDisconnect = false
    /// (settings pass 2) Each step swaps the button under the ring (Connect → the code's Connect →
    /// Disconnect → Connect): the ring fell off the panel. It follows to the step's lead button.
    @FocusState private var lead: Bool
    init(service: String, label: String) { _model = StateObject(wrappedValue: PasteTrackerModel(service: service, label: label)) }

    var body: some View {
        VStack(alignment: .leading, spacing: BP.px(10)) {
            if model.status.authenticated {
                Text("Connected as \(model.status.username ?? "\(model.label) user")").font(BP.sans(16, .semibold)).foregroundStyle(BP.ink)
                Text("Your lists show in the Anime room and the Library.").font(BP.sans(14)).foregroundStyle(BP.inkMuted)
                Button("Disconnect") { confirmDisconnect = true }.buttonStyle(BPActionStyle())
                    .focused($lead)
            } else if let url = model.url {
                HStack(alignment: .top, spacing: BP.px(18)) {
                    if let qr = Self.qr(url) {
                        Image(uiImage: qr).interpolation(.none).resizable().frame(width: BP.px(150), height: BP.px(150)).accessibilityLabel(Text(T("QR code")))
                            .padding(BP.px(8)).background(RoundedRectangle(cornerRadius: BP.rXS, style: .continuous).fill(.white))
                    }
                    VStack(alignment: .leading, spacing: BP.px(8)) {
                        Text("1. Scan the code (or open the link) on your phone and sign in to \(model.label).").font(BP.sans(14)).foregroundStyle(BP.inkMuted)
                        Text(url).font(BP.sans(11)).foregroundStyle(BP.inkSubtle).lineLimit(3)
                        Text("2. Copy the code it shows and paste it here (the iPhone keyboard for Apple TV can paste).").font(BP.sans(14)).foregroundStyle(BP.inkMuted)
                        BPField(label: "Code from \(model.label)", placeholder: "Paste the code or the whole page address", text: $pasted, phone: true)
                        HStack(spacing: BP.px(8)) {
                            // (settings pass 2) Dimmed, not disabled, while the field is empty, so
                            // the ring can wait here for the pasted code.
                            let empty = pasted.trimmingCharacters(in: .whitespaces).isEmpty
                            Button(model.busy ? "Connecting…" : "Connect") {
                                guard !model.busy, !empty else { return }
                                // (settings device pass) A rejected code stays in the field to fix
                                // or retry; clearing it also disabled the focused Connect button.
                                Task {
                                    if await model.complete(pasted) {
                                        pasted = ""
                                        refocus()
                                    }
                                }
                            }
                                .buttonStyle(BPActionStyle(primary: true, busy: model.busy || empty))
                                .focused($lead)
                            Button("Cancel") { Task { await model.disconnect(); refocus() } }.buttonStyle(BPActionStyle())
                        }
                    }
                }
            } else {
                Text("Not connected").font(BP.sans(16, .semibold)).foregroundStyle(BP.ink)
                Text("Your \(model.label) lists in the Anime room and the Library").font(BP.sans(14)).foregroundStyle(BP.inkMuted)
                Button("Connect \(model.label)") { Task { await model.begin(); refocus() } }.buttonStyle(BPActionStyle(primary: true))
                    .focused($lead)
            }
            if let n = model.note { BPNote(text: n, tone: model.noteOk ? BP.live : BP.danger) }
        }
        .task { await model.refresh() }
        .alert(disconnectTitle, isPresented: $confirmDisconnect) {
            Button(T("Disconnect"), role: .destructive) { Task { await model.disconnect(); refocus() } }
            Button(T("Cancel"), role: .cancel) {}
        } message: {
            Text(verbatim: disconnectMessage)
        }
    }

    /// The step's lead button, once it is on screen.
    private func refocus() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { lead = true }
    }

    private var disconnectTitle: String {
        T(model.service == "mal" ? "Disconnect from MyAnimeList" : "Disconnect from AniList")
    }

    private var disconnectMessage: String {
        T(model.service == "mal" ? "Disconnect MyAnimeList? Your progress will stop syncing until you reconnect." : "Disconnect AniList? Your lists will stop showing on the Anime page until you reconnect.")
    }

    private static func qr(_ text: String) -> UIImage? { QRCode.image(text) }
}
