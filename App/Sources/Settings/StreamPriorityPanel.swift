import SwiftUI

/// (TV, owner request 2026-10-01) Settings → Addons "Sources first": the stream addon whose sources
/// lead the stream picker (settings.streamPriority, which upstream's pipeline already honours; the
/// engine also orders the picker's addon groups by it). One addon first, the rest in installed order.
struct StreamPriorityPanel: View {
    struct Entry: Decodable, Identifiable {
        var key: String
        var name: String
        var first: Bool
        var id: String { key }
    }
    @State private var entries: [Entry] = []
    @State private var loaded = false

    private var who: (id: String, linked: Bool, authKey: String?) {
        let p = ProfilesStore.shared.active
        let authKey: String? = p.flatMap { ProfilesStore.shared.stremioSession(for: $0.id)?.authKey }
        return (p?.id ?? "default", p?.linked ?? true, authKey)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: BP.px(8)) {
            Text(T("Sources first")).font(BP.sans(15, .semibold)).foregroundStyle(BP.inkMuted)
            Text(T("The addon whose sources lead the stream list.")).font(BP.sans(13)).foregroundStyle(BP.inkSubtle)
            if loaded && entries.isEmpty {
                BPNote(text: "No stream addons found.")
            }
            PickerFlowRow(spacing: BP.px(8), lineSpacing: BP.px(8)) {
                Button(T("Installed order")) { Task { await set(nil, nil) } }
                    .buttonStyle(BPActionStyle(primary: !entries.contains { $0.first }))
                    .bpSelected(!entries.contains { $0.first })
                ForEach(entries) { e in
                    Button(e.name) { Task { await set(e.key, e.name) } }
                        .buttonStyle(BPActionStyle(primary: e.first))
                        .bpSelected(e.first)
                }
            }
            .focusSection()
        }
        .padding(.top, BP.px(8))
        .task { await load() }
    }

    private func load() async {
        let w = who
        let args: [AnyJSON] = [.string(w.id), .bool(w.linked), w.authKey.map { AnyJSON.string($0) } ?? AnyJSON.null]
        let list: [Entry] = (try? await HarborEngine.shared.call("streamsRoom.priorityList", args)) ?? []
        entries = list
        loaded = true
    }

    private func set(_ key: String?, _ name: String?) async {
        let w = who
        let args: [AnyJSON] = [.string(w.id), .bool(w.linked), key.map { AnyJSON.string($0) } ?? AnyJSON.null, name.map { AnyJSON.string($0) } ?? AnyJSON.null]
        let _: Bool? = try? await HarborEngine.shared.call("streamsRoom.setPriorityFirst", args)
        await load()
    }
}
