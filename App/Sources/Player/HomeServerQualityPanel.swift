import SwiftUI

/// bp-ten-foot.tsx HomeServerQualityPanel: the Plex / Jellyfin / Emby copy playing now, at another
/// quality without losing the place (lib/media-server/playback.ts switchMediaServerQuality, through
/// engine/homeServers.ts switchQuality: the connection's preferredQuality follows the pick and the
/// old transcode session is stopped). `onSwitched` hands the new URL to the player, which swaps it
/// in place at the same position (PlayerScreen.switchStream).
struct HomeServerQualityPanel: View {
    let session: HomeServerSession
    let positionSec: Double
    let playing: Bool
    /// The new URL, its headers and the server's subtitle files (switchMediaServerQuality `subtitles`).
    let onSwitched: (URL, [String: String], [SeedSubtitle]) -> Void
    let onClose: () -> Void

    struct Option: Decodable, Identifiable { var id: String; var label: String }
    private struct Options: Decodable { var current: String; var options: [Option] }
    private struct Switched: Decodable { var url: String; var headers: [String: String]?; var quality: String; var subtitles: [SeedSubtitle]? }

    @State private var options: [Option] = []
    @State private var current = "original"
    @State private var switching: String?
    @State private var error: String?
    @FocusState private var focus: String?

    var body: some View {
        ZStack {
            BP.void_.opacity(0.5).ignoresSafeArea()
            VStack(alignment: .leading, spacing: BP.px(18)) {
                VStack(alignment: .leading, spacing: BP.px(6)) {
                    Label("Home server quality", systemImage: "speedometer").font(BP.display(26)).foregroundStyle(BP.ink)
                    Text("Switch quality without losing your place.").font(BP.sans(13, .medium)).foregroundStyle(BP.inkSubtle)
                }
                // The two-column grid of MEDIA_SERVER_QUALITIES; the one playing wears the check.
                LazyVGrid(columns: [GridItem(.flexible(), spacing: BP.px(12)), GridItem(.flexible(), spacing: BP.px(12))], spacing: BP.px(12)) {
                    ForEach(options) { q in
                        Button { Task { await select(q.id) } } label: {
                            HStack(spacing: BP.px(10)) {
                                Text(verbatim: q.label).font(BP.sans(15, .semibold)).lineLimit(1)
                                Spacer(minLength: 0)
                                if switching == q.id {
                                    ProgressView().tint(BP.ink).scaleEffect(0.7)
                                } else if current == q.id {
                                    Image(systemName: "checkmark").font(.system(size: BP.px(15), weight: .bold)).accessibilityHidden(true)
                                }
                            }
                        }
                        .buttonStyle(PlayerLineStyle(on: current == q.id))
                        .focused($focus, equals: q.id)
                        .bpSelected(current == q.id)
                    }
                }
                .focusSection()
                if let error {
                    Text(verbatim: error).font(BP.sans(13, .medium)).foregroundStyle(BP.danger).fixedSize(horizontal: false, vertical: true)
                }
                Button("Back") { onClose() }
                    .buttonStyle(BPActionStyle())
                    .focused($focus, equals: "back")
            }
            .padding(BP.px(30))
            .frame(width: BP.px(1049), alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: BP.rLG, style: .continuous).fill(BP.void_))
            .overlay(RoundedRectangle(cornerRadius: BP.rLG, style: .continuous).stroke(BP.edge, lineWidth: 1))
            .focusSection()
        }
        .task { await load() }
    }

    private func load() async {
        guard let o: Options = try? await HarborEngine.shared.call("homeServers.qualityOptions", [session.connectionId, session.itemId]) else {
            focus = "back"
            return
        }
        options = o.options
        current = o.current
        // The first quality takes the ring (data-bp-autofocus on index 0), once the grid is laid out.
        try? await Task.sleep(for: .milliseconds(120))
        focus = o.options.first?.id ?? "back"
    }

    /// HomeServerQualityPanel select(): the one playing just closes; another swaps the stream, and a
    /// failure leaves the current one playing with upstream's note.
    private func select(_ id: String) async {
        // (focus pass 2) Was .disabled(switching != nil) on every row: the pressed row lost the ring.
        guard switching == nil else { return }
        if id == current { onClose(); return }
        switching = id
        error = nil
        defer { switching = nil }
        do {
            let r: Switched = try await HarborEngine.shared.call("homeServers.switchQuality",
                [session.connectionId, session.itemId, session.versionId, id, (positionSec * 1000).rounded(), playing, session.playbackSessionId])
            guard let url = URL(string: r.url) else {
                error = T("The current stream is still playing. Original remains available.")
                return
            }
            current = r.quality
            onSwitched(url, r.headers ?? [:], r.subtitles ?? [])
        } catch {
            self.error = "\(error.localizedDescription) \(T("The current stream is still playing. Original remains available."))"
        }
    }
}
