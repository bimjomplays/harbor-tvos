import SwiftUI

/// bp-quick-panel.tsx: hold Select on a tile. Play, Watchlist, Details, Remove from Continue
/// watching, Search by this title, then (parity pass 3, H5) the panel's global rows: Interface
/// sounds and Animated backdrop. The panel still opens on a title only (there is no Y / Tab on a
/// Siri Remote), and the Controls legend (gamepad / keyboard bindings) has no TV counterpart.
struct QuickPanelView: View {
    let meta: Meta
    /// bp-quick-panel `cwItem` (readBpCwItem): opened on a Continue Watching card. Only then is
    /// "Remove from Continue watching" offered.
    var fromContinueWatching = false
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var app: AppModel
    @State private var detail: Target?
    @State private var saved = false
    @State private var saving = false
    @State private var note: String?
    @State private var listDialog = false
    @State private var rateDialog = false
    @FocusState private var focus: String?
    /// bp-quick-panel useSettings: the sound pack and the animated backdrop the rows read and flip.
    @ObservedObject private var settings = SettingsBridge.shared
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
                // (home device pass) bp-quick-panel: toggleWatchlist / useInWatchlist, Harbor's own
                // watchlist (engine actions.setWatchlist, as Detail and the Discovery Queue use). It
                // wrote a Stremio library bookmark: missing without a Stremio account, never showed a
                // title already saved as Saved, and could not be undone. A fixed focus key, so the
                // ring stays on the button when its label turns to Saved.
                action(saved ? "Saved" : "Watchlist", saved ? "checkmark" : "plus", key: "watchlist") { Task { await toggleSaved() } }
                action("Details", "info.circle") { detail = Target(meta: meta, autoPlay: false) }
                action("Add to list", "text.badge.plus") { listDialog = true }
                action("Rate", "star") { rateDialog = true }
                if fromContinueWatching { action("Remove from Continue watching", "eye.slash") { Task { await removeCw() } } }
                action("Search", "magnifyingglass") { app.searchSeed = meta.name; app.room = .search; dismiss() }
                // bp-quick-panel: "Interface sounds" (Off ↔ Glass) and "Animated backdrop" (On / Off).
                settingRow("Interface sounds", soundOn ? "speaker.wave.2" : "speaker.slash", detail: soundDetail, key: "sounds") {
                    let next: String = soundOn ? "none" : "glass"
                    Task { try? await settings.patch(["bigPictureSound": .string(next)]) }
                }
                settingRow("Animated backdrop", "photo.on.rectangle", detail: T(mosaicOn ? "On" : "Off"), key: "backdrop") {
                    let next: Bool = !mosaicOn
                    Task { try? await settings.patch(["bigPictureMosaic": .bool(next)]) }
                }
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
        .task { await readSaved() }
        .fullScreenCover(item: $detail) { t in DetailView(meta: t.meta, autoPlay: t.autoPlay) }
        .fullScreenCover(isPresented: $listDialog) { ListDialogView(meta: meta) }
        .fullScreenCover(isPresented: $rateDialog) { RateDialogView(meta: meta) }
    }

    private func action(_ label: String, _ icon: String, key: String? = nil, _ run: @escaping () -> Void) -> some View {
        Button(action: run) { Label(T(label), systemImage: icon).frame(maxWidth: .infinity, alignment: .leading) }
            .buttonStyle(BPActionStyle())
            .focused($focus, equals: key ?? label)
    }

    /// bp-quick-panel `soundOn = settings.bigPictureSound !== "none"`.
    private var soundOn: Bool { (settings.slice.bigPictureSound ?? "cinematic") != "none" }
    private var mosaicOn: Bool { settings.slice.bigPictureMosaic ?? true }

    /// t("Sound pack: {name}", { name: bpSoundLabel(t, …) }), or t("Off").
    private var soundDetail: String {
        guard soundOn else { return T("Off") }
        let pack: String = settings.slice.bigPictureSound ?? "cinematic"
        return T("Sound pack: %@", T(Self.soundLabels[pack] ?? "Off"))
    }

    /// bp-settings-catalog SOUND_LABELS (proper-cased catalog words, never the stored enum).
    private static let soundLabels: [String: String] = ["none": "Off", "glass": "Glass", "modern": "Modern", "cinematic": "Cinematic", "retro": "Retro"]

    /// BpQuickAction with its `detail` line: the setting's current value under the label. The ring
    /// stays on the row as its value changes (a fixed focus key).
    private func settingRow(_ label: String, _ icon: String, detail: String, key: String, _ run: @escaping () -> Void) -> some View {
        Button {
            BPSound.shared.click()
            run()
        } label: {
            HStack(spacing: BP.px(12)) {
                Image(systemName: icon).frame(width: BP.px(22))
                VStack(alignment: .leading, spacing: BP.px(2)) {
                    Text(T(label))
                    Text(detail).font(BP.sans(11, .medium)).foregroundStyle(BP.inkSubtle)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(BPActionStyle())
        .focused($focus, equals: key)
    }

    private struct WatchlistState: Decodable { var watchlist: Bool? }

    /// useInWatchlist(focused.id) (engine actions.heroState).
    private func readSaved() async {
        let p = ProfilesStore.shared.active
        let noImdb: String? = nil
        guard let s: WatchlistState = try? await HarborEngine.shared.call("actions.heroState", [meta, noImdb, p?.id ?? "default", p?.linked ?? true]) else { return }
        if !saving { saved = s.watchlist == true }
    }

    private func toggleSaved() async {
        guard !saving else { return }
        saving = true
        defer { saving = false }
        let on = !saved
        let noImdb: String? = nil
        let _: Bool? = try? await HarborEngine.shared.call("actions.setWatchlist", [authKey, meta, noImdb, on])
        saved = on
        await CardMarksStore.shared.remark()
    }

    private func removeCw() async {
        let p = ProfilesStore.shared.active
        let ok = (try? await HarborEngine.shared.callJSON("rooms.dismissContinueWatching", [.string(p?.id ?? "default"), .bool(p?.linked ?? true), authKey.map { .string($0) } ?? .null, .string(meta.id)]))?.bool ?? false
        guard ok else { note = "This title isn't in Continue watching."; return }
        HarborEngine.shared.emitEvent("harbor:cw-dismissed")
        // bp-quick-panel: dismissCw(cwItem, authKey); onClose(). Home re-reads the row as the
        // panel's cover closes, so the card is gone when the rail comes back.
        dismiss()
    }
}
