import SwiftUI

/// queue/bp-queue.tsx: the Discovery Queue deck. One pick at a time on its own backdrop, Left/Right
/// step through the deck, the rail offers Play now / Save / Details / Skip / Not interested.
@MainActor
final class QueueDeckModel: ObservableObject {
    struct Entry: Decodable, Identifiable { var meta: Meta; var tag: String; var id: String { meta.id } }
    struct Deck: Decodable { var status: String; var entries: [Entry] }

    @Published private(set) var status = "loading"
    @Published private(set) var entries: [Entry] = []
    @Published var index = 0
    @Published private(set) var saved: Set<String> = []
    private var extending = false

    var current: Entry? { entries.indices.contains(index) ? entries[index] : nil }

    private var profile: (id: String, linked: Bool, authKey: String?) {
        let p = ProfilesStore.shared.active
        return (p?.id ?? "default", p?.linked ?? true, p.flatMap { ProfilesStore.shared.stremioSession(for: $0.id)?.authKey })
    }

    /// (bug pass) The view's `.task` runs again whenever a Details / Play now cover closes; the deck
    /// opened again then, back on its first card with a fresh fetch.
    private var opened = false

    /// True for the call that opened the deck (the view seeds focus only then).
    @discardableResult
    func open() async -> Bool {
        guard !opened else { return false }
        opened = true
        let p = profile
        if let d: Deck = try? await HarborEngine.shared.call("discoverRoom.queueOpen", [p.id, p.linked]) {
            entries = d.entries; status = d.status
        } else { status = "unreachable" }
        index = 0
        await CardMarksStore.shared.refresh(entries.map(\.meta))
        return true
    }

    func step(_ delta: Int) {
        let next = index + delta
        guard entries.indices.contains(next) else { return }
        index = next
        // use-bp-queue LOW_WATER_MARK: fetch another page as the end nears.
        if entries.count - index - 1 <= 6 { Task { await extend() } }
    }

    private func extend() async {
        guard !extending else { return }
        extending = true; defer { extending = false }
        let p = profile
        let more: [Entry] = (try? await HarborEngine.shared.call("discoverRoom.queueExtend", [p.id, p.linked])) ?? []
        let have = Set(entries.map(\.id))
        entries += more.filter { !have.contains($0.id) }
    }

    /// Drop the pick (the current one unless named) and land on the next one (or the previous when it was last).
    private func remove(_ fn: String, id: String? = nil) async {
        guard let target = id ?? current?.id else { return }
        _ = try? await HarborEngine.shared.callJSON("discoverRoom.\(fn)", [.string(target)])
        // (bug pass) Left / Right may have moved the deck while the engine answered: drop that pick by id.
        guard let at = entries.firstIndex(where: { $0.id == target }) else { return }
        entries.remove(at: at)
        if at < index { index -= 1 }
        if index >= entries.count { index = max(0, entries.count - 1) }
        if entries.isEmpty { status = "empty" }
        if entries.count - index - 1 <= 6 { await extend() }
    }
    func snooze() async { await remove("queueSnooze") }
    /// bp-queue.tsx: Not interested runs only from the "Hide this permanently?" confirm, on the
    /// title it named.
    func block(_ id: String) async { await remove("queueBlock", id: id) }

    private struct WatchlistState: Decodable { var watchlist: Bool? }
    private var saving = false

    /// bp-queue-rail useInWatchlist(meta.id): Save / Saved follows Harbor's watchlist (and the synced
    /// Stremio/Trakt/Simkl aggregate) for the card on screen.
    func readSaved() async {
        guard let c = current else { return }
        let p = profile
        let noImdb: String? = nil
        guard let s: WatchlistState = try? await HarborEngine.shared.call("actions.heroState", [c.meta, noImdb, p.id, p.linked]) else { return }
        if s.watchlist == true { saved.insert(c.id) } else { saved.remove(c.id) }
    }

    /// bp-queue-rail Save: toggleWatchlist({ id, type, name, poster }) (engine actions.setWatchlist).
    /// (device-flow pass) It wrote a Stremio library bookmark, so it was missing without a Stremio
    /// account, could not be undone, never showed a title already saved elsewhere as Saved, and
    /// never reached Trakt, Simkl or the Library room's watchlist.
    func toggleSave() async {
        guard let c = current, !saving else { return }
        saving = true
        defer { saving = false }
        let on = !saved.contains(c.id)
        let noImdb: String? = nil
        let _: Bool? = try? await HarborEngine.shared.call("actions.setWatchlist", [profile.authKey, c.meta, noImdb, on])
        if on { saved.insert(c.id) } else { saved.remove(c.id) }
        await CardMarksStore.shared.remark()
    }
}

struct QueueDeckView: View {
    @StateObject private var model = QueueDeckModel()
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var app: AppModel
    @State private var detail: DetailTarget?
    /// bp-queue.tsx `confirming`: the title Not interested would hide for good.
    @State private var confirmBlock: QueueDeckModel.Entry?
    @FocusState private var focus: String?
    struct DetailTarget: Identifiable { var meta: Meta; var autoPlay: Bool; var id: String { meta.id } }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            BP.void_.ignoresSafeArea()
            if let c = model.current {
                RemoteImage(url: c.meta.background ?? c.meta.poster).ignoresSafeArea().id(c.id)
                    .transition(.opacity)
                    .opacity(railFocused ? 0.6 : 1)   // bp-queue-stage dimmed={zone === "rail"}
                LinearGradient(colors: [BP.void_.opacity(0.2), BP.void_.opacity(0.75), BP.void_.opacity(0.97)], startPoint: .top, endPoint: .bottom).ignoresSafeArea()
                LinearGradient(colors: [BP.void_.opacity(0.9), .clear], startPoint: .leading, endPoint: .init(x: 0.6, y: 0.5)).ignoresSafeArea()
                    .flipsForRightToLeftLayoutDirection(true)   // bp-tokens.ts --bp-scrim-side under rtl
            }
            VStack(alignment: .leading, spacing: BP.px(14)) {
                Text("Discovery Queue").font(BP.sans(12, .bold)).textCase(.uppercase).tracking(1.4).foregroundStyle(BP.accent)
                if let c = model.current {
                    // bp-queue.tsx queue-deck cell: the one focusable spot where Left and Right step the
                    // deck (never a tile, so no lift or ring); Select plays like the rail's Play now.
                    Button { detail = DetailTarget(meta: c.meta, autoPlay: true) } label: {
                        HStack(alignment: .bottom, spacing: BP.px(24)) {
                            RemoteImage(url: c.meta.poster).frame(width: BP.px(180), height: BP.px(270))
                                .clipShape(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous))
                            VStack(alignment: .leading, spacing: BP.px(8)) {
                                // bp-queue.tsx BpQueuePosition tag={t(copy.shown.tag)}: pool tags are English keys.
                                if !c.tag.isEmpty { Text(T(c.tag)).font(BP.sans(12, .bold)).textCase(.uppercase).tracking(0.8).foregroundStyle(BP.inkMuted) }
                                Text(c.meta.name).font(BP.display(40)).foregroundStyle(BP.ink).lineLimit(2)
                                Text(c.meta.facts).font(BP.sans(14, .medium)).foregroundStyle(BP.inkMuted)
                                if let d = c.meta.description, !d.isEmpty { Text(d).font(BP.sans(15)).foregroundStyle(BP.inkMuted).lineLimit(3).frame(maxWidth: BP.px(900), alignment: .leading) }
                                Text("\(model.index + 1) of \(model.entries.count) · Left and Right step through the deck").font(BP.sans(12)).foregroundStyle(BP.inkSubtle)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(QueueDeckCellStyle())
                    .focused($focus, equals: "deck")
                    .accessibilityLabel(Text(verbatim: c.meta.name))
                    HStack(spacing: BP.px(10)) {
                        chip("Play now", "play.fill") { detail = DetailTarget(meta: c.meta, autoPlay: true) }
                        chip(model.saved.contains(c.id) ? "Saved" : "Save", model.saved.contains(c.id) ? "bookmark.fill" : "bookmark", key: "save") { Task { await model.toggleSave() } }
                        chip("Details", "info.circle") { detail = DetailTarget(meta: c.meta, autoPlay: false) }
                        chip("Skip", "forward.end") { Task { await model.snooze() } }
                        chip("Not interested", "hand.thumbsdown") { confirmBlock = c }
                        chip("Back to Discover", "chevron.backward") { dismiss() }
                    }
                    .focusSection()
                    Text("Skip hides it for two weeks · Not interested never shows it again").font(BP.sans(11)).foregroundStyle(BP.inkSubtle)
                } else {
                    Text(T(emptyTitle)).font(BP.display(34)).foregroundStyle(BP.ink)
                    Text(T(emptyBlurb)).font(BP.sans(15)).foregroundStyle(BP.inkMuted)
                    HStack(spacing: BP.px(10)) {
                        chip("Back to Discover", "chevron.backward") { dismiss() }
                        if model.status == "nokey" { chip("Open Settings", "gearshape") { dismiss(); app.room = .settings } }
                    }
                    .focusSection()
                }
            }
            .padding(BP.gutter).padding(.bottom, BP.px(30))
        }
        .animation(BP.easeFast, value: model.index)
        .onMoveCommand { dir in
            // bp-queue.tsx: forward is the reading direction (Left steps forward under rtl).
            // Only while the deck cell holds the ring (setBpQueueKeyHandler: zone === "deck"); on the
            // action chips Left and Right move along the chips.
            guard focus == "deck", dir == .left || dir == .right else { return }
            model.step((dir == .right) != L10n.isRTL ? 1 : -1)
        }
        .onExitCommand { dismiss() }
        .task {
            // (device-flow pass) Seed focus on the first open only: the task runs again whenever a
            // Details / Play now cover closes, and threw the ring from the chip used back to the deck
            // (bp-queue restores the ring by data-bp-restore-key).
            guard await model.open() else { return }
            focus = model.current == nil ? "Back to Discover" : "deck"
        }
        // bp-queue-rail useInWatchlist: Save / Saved for the card on screen.
        .task(id: model.current?.id) { await model.readSaved() }
        // bp-queue.tsx recoverBpFocus: the last pick skipped or hidden takes the deck and the rail
        // with it; the ring goes to Back to Discover instead of nowhere.
        .onChange(of: model.current == nil) { _, empty in
            if empty, model.status != "loading" { focus = "Back to Discover" }
        }
        .alert(Text(T("Hide this permanently?")), isPresented: Binding(get: { confirmBlock != nil }, set: { if !$0 { confirmBlock = nil } }), presenting: confirmBlock) { c in
            Button(T("Not interested"), role: .destructive) { Task { await model.block(c.id) } }
            Button(T("Keep"), role: .cancel) {}
        } message: { c in
            Text(T("%@ will not come back in the Discovery Queue.", c.meta.name))
        }
        .fullScreenCover(item: $detail) { t in DetailView(meta: t.meta, autoPlay: t.autoPlay) }
    }

    /// A rail chip holds the ring (bp-queue zone "rail"): the art is veiled.
    private var railFocused: Bool { focus != nil && focus != "deck" }

    private var emptyTitle: String { model.status == "loading" ? "Building tonight's queue…" : model.status == "empty" ? "Nothing left in today's picks" : "Discovery Queue" }
    private var emptyBlurb: String {
        switch model.status {
        case "nokey": return "Add a TMDB key in Settings to unlock the full discovery feed."
        case "unreachable": return "No picks loaded. TMDB might be unreachable."
        case "empty": return "Come back tomorrow, or clear what you skipped in Settings."
        default: return ""
        }
    }

    /// `key` names the focus spot when the label changes under the ring (Save / Saved).
    private func chip(_ label: String, _ icon: String, key: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(T(label), systemImage: icon) }
            .buttonStyle(BPActionStyle(primary: label == "Play now"))
            .focused($focus, equals: key ?? label)
    }
}

/// The deck cell draws nothing of its own: a custom style also keeps tvOS's system lift off it.
private struct QueueDeckCellStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}
