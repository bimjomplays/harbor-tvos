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
    @Published private(set) var busy = false

    init(service: String, label: String) { self.service = service; self.label = label }

    func refresh() async {
        status = (try? await HarborEngine.shared.call("\(service).status", [])) ?? Status(authenticated: false, username: nil)
    }

    func begin() async {
        note = nil
        url = try? await HarborEngine.shared.call("\(service).authorizeUrl", [])
        if url == nil { note = "Couldn't build the sign-in link." }
    }

    func complete(_ pasted: String) async {
        busy = true; defer { busy = false }
        struct Done: Decodable { var userName: String }
        do {
            let d: Done = try await HarborEngine.shared.call("\(service).complete", [pasted])
            url = nil
            await refresh()
            note = "Connected as \(d.userName)."
        } catch {
            let text = "\(error)"
            note = text.split(separator: "\n").first.map(String.init)?.replacingOccurrences(of: "Error: ", with: "") ?? "Sign-in failed."
        }
    }

    func disconnect() async {
        _ = try? await HarborEngine.shared.callJSON("\(service).disconnect", [])
        url = nil
        await refresh()
    }
}

struct PasteTrackerPanel: View {
    @StateObject private var model: PasteTrackerModel
    @State private var pasted = ""
    init(service: String, label: String) { _model = StateObject(wrappedValue: PasteTrackerModel(service: service, label: label)) }

    var body: some View {
        VStack(alignment: .leading, spacing: BP.px(10)) {
            if model.status.authenticated {
                Text("Connected as \(model.status.username ?? "\(model.label) user")").font(BP.sans(16, .semibold)).foregroundStyle(BP.ink)
                Text("Your lists show in the Anime room and the Library.").font(BP.sans(14)).foregroundStyle(BP.inkMuted)
                Button("Disconnect") { Task { await model.disconnect() } }.buttonStyle(BPActionStyle())
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
                            Button(model.busy ? "Connecting…" : "Connect") { Task { await model.complete(pasted); pasted = "" } }
                                .buttonStyle(BPActionStyle(primary: true)).disabled(model.busy || pasted.trimmingCharacters(in: .whitespaces).isEmpty)
                            Button("Cancel") { Task { await model.disconnect() } }.buttonStyle(BPActionStyle())
                        }
                    }
                }
            } else {
                Text("Not connected").font(BP.sans(16, .semibold)).foregroundStyle(BP.ink)
                Text("Your \(model.label) lists in the Anime room and the Library").font(BP.sans(14)).foregroundStyle(BP.inkMuted)
                Button("Connect \(model.label)") { Task { await model.begin() } }.buttonStyle(BPActionStyle(primary: true))
            }
            if let n = model.note { BPNote(text: n, tone: n.hasPrefix("Connected") ? BP.live : BP.danger) }
        }
        .task { await model.refresh() }
    }

    private static func qr(_ text: String) -> UIImage? { QRCode.image(text) }
}
