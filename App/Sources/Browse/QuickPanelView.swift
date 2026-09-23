import SwiftUI

/// bp-quick-panel.tsx: hold Select on a tile. Play, Watchlist, Details, Remove from Continue
/// watching, Search by this title. Sound/backdrop toggles live in Settings on the TV.
struct QuickPanelView: View {
    let meta: Meta
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var app: AppModel
    @State private var detail: Target?
    @State private var saved = false
    @State private var note: String?
    @State private var listDialog = false
    @State private var rateDialog = false
    @FocusState private var focus: String?
    struct Target: Identifiable { var meta: Meta; var autoPlay: Bool; var id: String { meta.id } }

    private var authKey: String? { ProfilesStore.shared.active.flatMap { ProfilesStore.shared.stremioSession(for: $0.id)?.authKey } }

    var body: some View {
        ZStack(alignment: .trailing) {
            BP.void_.opacity(0.55).ignoresSafeArea()
            VStack(alignment: .leading, spacing: BP.px(10)) {
                HStack(spacing: BP.px(14)) {
                    RemoteImage(url: meta.poster).frame(width: BP.px(64), height: BP.px(96)).clipShape(RoundedRectangle(cornerRadius: BP.px(6)))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(meta.name).font(BP.sans(17, .bold)).foregroundStyle(BP.ink).lineLimit(2)
                        Text(meta.facts).font(BP.sans(12)).foregroundStyle(BP.inkMuted).lineLimit(1)
                    }
                }
                .padding(.bottom, BP.px(6))
                action("Play", "play.fill") { detail = Target(meta: meta, autoPlay: true) }
                if authKey != nil { action(saved ? "Saved" : "Watchlist", saved ? "bookmark.fill" : "bookmark") { Task { await save() } } }
                action("Details", "info.circle") { detail = Target(meta: meta, autoPlay: false) }
                action("Add to list", "text.badge.plus") { listDialog = true }
                action("Rate", "star") { rateDialog = true }
                action("Remove from Continue watching", "eye.slash") { Task { await removeCw() } }
                action("Search", "magnifyingglass") { app.searchSeed = meta.name; app.room = .search; dismiss() }
                if let note { BPNote(text: note, tone: BP.inkMuted) }
                Spacer()
                Text("Quick panel").font(BP.sans(11, .bold)).textCase(.uppercase).tracking(1).foregroundStyle(BP.inkSubtle)
            }
            .padding(BP.px(24))
            .frame(width: BP.px(440), alignment: .leading)
            .frame(maxHeight: .infinity)
            .background(BP.panel.opacity(0.98))
            .ignoresSafeArea()
        }
        .onExitCommand { dismiss() }
        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { focus = "Play" } }
        .fullScreenCover(item: $detail) { t in DetailView(meta: t.meta, autoPlay: t.autoPlay) }
        .fullScreenCover(isPresented: $listDialog) { ListDialogView(meta: meta) }
        .fullScreenCover(isPresented: $rateDialog) { RateDialogView(meta: meta) }
    }

    private func action(_ label: String, _ icon: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) { Label(label, systemImage: icon).frame(maxWidth: .infinity, alignment: .leading) }
            .buttonStyle(BPActionStyle())
            .focused($focus, equals: label)
    }

    private func save() async {
        guard let authKey, !saved else { return }
        _ = try? await HarborEngine.shared.callJSON("stremio.saveBookmark", [.string(authKey), .string(meta.id), .object(["type": .string(meta.type), "name": .string(meta.name), "poster": meta.poster.map { .string($0) } ?? .null])])
        saved = true
        await CardMarksStore.shared.refreshWatchlist()
    }

    private func removeCw() async {
        let p = ProfilesStore.shared.active
        let ok = (try? await HarborEngine.shared.callJSON("rooms.dismissContinueWatching", [.string(p?.id ?? "default"), .bool(p?.linked ?? true), authKey.map { .string($0) } ?? .null, .string(meta.id)]))?.bool ?? false
        note = ok ? "Removed from Continue watching." : "This title isn't in Continue watching."
        if ok { HarborEngine.shared.emitEvent("harbor:cw-dismissed") }
    }
}
