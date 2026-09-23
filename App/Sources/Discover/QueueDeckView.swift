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

    func open() async {
        let p = profile
        if let d: Deck = try? await HarborEngine.shared.call("discoverRoom.queueOpen", [p.id, p.linked]) {
            entries = d.entries; status = d.status
        } else { status = "unreachable" }
        index = 0
        await CardMarksStore.shared.refresh(entries.map(\.meta))
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

    /// Drop the current pick and land on the next one (or the previous when it was last).
    private func remove(_ fn: String) async {
        guard let c = current else { return }
        _ = try? await HarborEngine.shared.callJSON("discoverRoom.\(fn)", [.string(c.id)])
        entries.remove(at: index)
        if index >= entries.count { index = max(0, entries.count - 1) }
        if entries.isEmpty { status = "empty" }
        if entries.count - index - 1 <= 6 { await extend() }
    }
    func snooze() async { await remove("queueSnooze") }
    func block() async { await remove("queueBlock") }

    func save() async {
        guard let c = current, let authKey = profile.authKey, !saved.contains(c.id) else { return }
        _ = try? await HarborEngine.shared.callJSON("stremio.saveBookmark", [.string(authKey), .string(c.id), .object(["type": .string(c.meta.type), "name": .string(c.meta.name), "poster": c.meta.poster.map { .string($0) } ?? .null])])
        saved.insert(c.id)
        await CardMarksStore.shared.refreshWatchlist()
    }
    var canSave: Bool { profile.authKey != nil }
}

struct QueueDeckView: View {
    @StateObject private var model = QueueDeckModel()
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var app: AppModel
    @State private var detail: DetailTarget?
    @FocusState private var focus: String?
    struct DetailTarget: Identifiable { var meta: Meta; var autoPlay: Bool; var id: String { meta.id } }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            BP.void_.ignoresSafeArea()
            if let c = model.current {
                RemoteImage(url: c.meta.background ?? c.meta.poster).ignoresSafeArea().id(c.id)
                    .transition(.opacity)
                LinearGradient(colors: [BP.void_.opacity(0.2), BP.void_.opacity(0.75), BP.void_.opacity(0.97)], startPoint: .top, endPoint: .bottom).ignoresSafeArea()
                LinearGradient(colors: [BP.void_.opacity(0.9), .clear], startPoint: .leading, endPoint: .init(x: 0.6, y: 0.5)).ignoresSafeArea()
            }
            VStack(alignment: .leading, spacing: BP.px(14)) {
                Text("Discovery Queue").font(BP.sans(12, .bold)).textCase(.uppercase).tracking(1.4).foregroundStyle(BP.accent)
                if let c = model.current {
                    HStack(alignment: .bottom, spacing: BP.px(24)) {
                        RemoteImage(url: c.meta.poster).frame(width: BP.px(180), height: BP.px(270))
                            .clipShape(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous))
                        VStack(alignment: .leading, spacing: BP.px(8)) {
                            if !c.tag.isEmpty { Text(c.tag).font(BP.sans(12, .bold)).textCase(.uppercase).tracking(0.8).foregroundStyle(BP.inkMuted) }
                            Text(c.meta.name).font(BP.display(40)).foregroundStyle(BP.ink).lineLimit(2)
                            Text(c.meta.facts).font(BP.sans(14, .medium)).foregroundStyle(BP.inkMuted)
                            if let d = c.meta.description, !d.isEmpty { Text(d).font(BP.sans(15)).foregroundStyle(BP.inkMuted).lineLimit(3).frame(maxWidth: BP.px(900), alignment: .leading) }
                            Text("\(model.index + 1) of \(model.entries.count) · Left and Right step through the deck").font(BP.sans(12)).foregroundStyle(BP.inkSubtle)
                        }
                    }
                    HStack(spacing: BP.px(10)) {
                        chip("Play now", "play.fill") { detail = DetailTarget(meta: c.meta, autoPlay: true) }
                        if model.canSave { chip(model.saved.contains(c.id) ? "Saved" : "Save", model.saved.contains(c.id) ? "bookmark.fill" : "bookmark") { Task { await model.save() } } }
                        chip("Details", "info.circle") { detail = DetailTarget(meta: c.meta, autoPlay: false) }
                        chip("Skip", "forward.end") { Task { await model.snooze() } }
                        chip("Not interested", "hand.thumbsdown") { Task { await model.block() } }
                        chip("Back to Discover", "chevron.left") { dismiss() }
                    }
                    .focusSection()
                    Text("Skip hides it for two weeks · Not interested never shows it again").font(BP.sans(11)).foregroundStyle(BP.inkSubtle)
                } else {
                    Text(emptyTitle).font(BP.display(34)).foregroundStyle(BP.ink)
                    Text(emptyBlurb).font(BP.sans(15)).foregroundStyle(BP.inkMuted)
                    HStack(spacing: BP.px(10)) {
                        chip("Back to Discover", "chevron.left") { dismiss() }
                        if model.status == "nokey" { chip("Open Settings", "gearshape") { dismiss(); app.room = .settings } }
                    }
                    .focusSection()
                }
            }
            .padding(BP.gutter).padding(.bottom, BP.px(30))
        }
        .animation(BP.easeFast, value: model.index)
        .onMoveCommand { dir in
            if dir == .left { model.step(-1) } else if dir == .right { model.step(1) }
        }
        .onExitCommand { dismiss() }
        .task { await model.open(); focus = "Play now" }
        .fullScreenCover(item: $detail) { t in DetailView(meta: t.meta, autoPlay: t.autoPlay) }
    }

    private var emptyTitle: String { model.status == "loading" ? "Building tonight's queue…" : model.status == "empty" ? "Nothing left in today's picks" : "Discovery Queue" }
    private var emptyBlurb: String {
        switch model.status {
        case "nokey": return "Add a TMDB key in Settings to unlock the full discovery feed."
        case "unreachable": return "No picks loaded. TMDB might be unreachable."
        case "empty": return "Come back tomorrow, or clear what you skipped in Settings."
        default: return ""
        }
    }

    private func chip(_ label: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(label, systemImage: icon) }
            .buttonStyle(BPActionStyle(primary: label == "Play now"))
            .focused($focus, equals: label)
    }
}
