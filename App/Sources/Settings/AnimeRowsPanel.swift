import SwiftUI

/// Settings → Anime rows (lib/anime-customization): reorder, hide and rename the Anime room's
/// groups; the room applies the result on its next build.
struct AnimeRowsPanel: View {
    struct Row: Decodable, Identifiable { var key: String; var name: String; var originalName: String; var hidden: Bool; var id: String { key } }
    @State private var rows: [Row] = []
    @State private var loaded = false
    @State private var renaming: Row?
    @State private var newName = ""

    private var profile: (id: String, linked: Bool) { let p = ProfilesStore.shared.active; return (p?.id ?? "default", p?.linked ?? true) }

    var body: some View {
        VStack(alignment: .leading, spacing: BP.px(8)) {
            if rows.isEmpty {
                BPNote(text: loaded ? "Open the Anime room once; its rows appear here to reorder, hide or rename." : "Loading…")
            }
            ForEach(Array(rows.enumerated()), id: \.element.key) { i, r in
                HStack(spacing: BP.px(8)) {
                    Text(r.name).font(BP.sans(14, r.hidden ? .regular : .semibold)).foregroundStyle(r.hidden ? BP.inkSubtle : BP.ink).lineLimit(1).frame(width: BP.px(340), alignment: .leading)
                    Button { Task { await call("animeRowMove", [.string(r.key), .number(-1)]) } } label: { Image(systemName: "arrow.up") }.buttonStyle(BPActionStyle()).disabled(i == 0)
                    Button { Task { await call("animeRowMove", [.string(r.key), .number(1)]) } } label: { Image(systemName: "arrow.down") }.buttonStyle(BPActionStyle()).disabled(i == rows.count - 1)
                    Button(r.hidden ? "Show" : "Hide") { Task { await call("animeRowToggleHidden", [.string(r.key)]) } }.buttonStyle(BPActionStyle(primary: r.hidden))
                    Button("Rename") { renaming = r; newName = r.name }.buttonStyle(BPActionStyle())
                }
            }
            if let r = renaming {
                BPField(label: "Rename \(r.originalName)", placeholder: r.originalName, text: $newName)
                HStack(spacing: BP.px(8)) {
                    Button("Save") { Task { await call("animeRowRename", [.string(r.key), .string(newName)]); renaming = nil } }.buttonStyle(BPActionStyle(primary: true))
                    Button("Use original name") { Task { await call("animeRowRename", [.string(r.key), .string("")]); renaming = nil } }.buttonStyle(BPActionStyle())
                    Button("Cancel") { renaming = nil }.buttonStyle(BPActionStyle())
                }
            }
            if !rows.isEmpty { Button("Reset rows") { Task { await call("animeRowsReset", []) } }.buttonStyle(BPActionStyle()) }
        }
        .task { await load() }
    }

    private func load() async {
        let p = profile
        rows = (try? await HarborEngine.shared.call("actions.animeRows", [p.id, p.linked])) ?? []
        loaded = true
    }

    private func call(_ fn: String, _ args: [AnyJSON]) async {
        let p = profile
        if let out = try? await HarborEngine.shared.callJSON("actions.\(fn)", [.string(p.id), .bool(p.linked)] + args), let list = try? out.decode([Row].self) { rows = list }
        HarborEngine.shared.emitEvent("harbor:anime-updated")
    }
}
