import SwiftUI

/// bp-trailer.tsx overlay. Upstream resolves the YouTube id to a playable file with yt-dlp on the
/// native side (lib/trailer fetch_trailer); tvOS has no yt-dlp, so the clip opens in the Apple TV
/// YouTube app, or on the phone through the QR code. Back closes, as upstream.
struct TrailerView: View {
    let ytId: String
    let title: String
    var clipName: String? = nil
    let onClose: () -> Void
    @State private var note: String?

    private var watchURL: String { "https://www.youtube.com/watch?v=\(ytId)" }

    var body: some View {
        ZStack {
            BP.void_.opacity(0.94).ignoresSafeArea()
            HStack(alignment: .center, spacing: BP.px(48)) {
                VStack(alignment: .leading, spacing: BP.px(14)) {
                    RemoteImage(url: "https://img.youtube.com/vi/\(ytId)/hqdefault.jpg")
                        .aspectRatio(16 / 9, contentMode: .fill)
                        .frame(width: BP.px(560), height: BP.px(315))
                        .clipShape(RoundedRectangle(cornerRadius: BP.rMD, style: .continuous))
                    Text(title).font(BP.display(30)).foregroundStyle(BP.ink).lineLimit(2)
                    if let c = clipName, !c.isEmpty { Text(c).font(BP.sans(15, .medium)).foregroundStyle(BP.inkMuted).lineLimit(1) }
                    HStack(spacing: BP.px(10)) {
                        Button { openInYouTube() } label: { Label("Open in YouTube", systemImage: "play.fill") }
                            .buttonStyle(BPActionStyle(primary: true))
                        Button("Close") { onClose() }.buttonStyle(BPActionStyle())
                    }
                    if let n = note { BPNote(text: n) }
                }
                VStack(spacing: BP.px(10)) {
                    if let qr = QRCode.image(watchURL) {
                        Image(uiImage: qr).interpolation(.none).resizable().frame(width: BP.px(220), height: BP.px(220)).accessibilityLabel(Text(T("QR code")))
                            .padding(BP.px(10)).background(Color.white).clipShape(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous))
                    }
                    Text("Scan to watch on your phone").font(BP.sans(13, .semibold)).foregroundStyle(BP.ink)
                    Text(watchURL.replacingOccurrences(of: "https://www.", with: "")).font(BP.sans(11)).foregroundStyle(BP.inkSubtle)
                }
            }
            .padding(BP.gutter)
        }
        .onExitCommand { onClose() }
    }

    // The YouTube tvOS app answers its own scheme; a universal link is the second try.
    private func openInYouTube() {
        Task { @MainActor in
            if let app = URL(string: "youtube://watch/\(ytId)"), await UIApplication.shared.open(app) { return }
            if let web = URL(string: watchURL), await UIApplication.shared.open(web) { return }
            note = "The YouTube app is not installed on this Apple TV. Scan the code to watch on your phone."
        }
    }
}
