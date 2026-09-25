import SwiftUI

/// Settings → Anime rows (lib/anime-customization): reorder, hide and rename the Anime room's
/// groups; the room applies the result on its next build.
struct AnimeRowsPanel: View {
    struct Row: Decodable, Identifiable { var key: String; var name: String; var originalName: String; var hidden: Bool; var id: String { key } }
    /// engine actions.animeTune: components/anime-genre-picker.tsx (labels come translated).
    struct Tune: Decodable {
        struct Genre: Decodable, Identifiable { var id: Int; var label: String; var on: Bool }
        struct Origin: Decodable, Identifiable { var code: String; var label: String; var on: Bool; var id: String { code } }
        var genres: [Genre]; var origins: [Origin]; var hideWatched: Bool
    }
    @State private var tune: Tune?
    @State private var rows: [Row] = []
    @State private var loaded = false
    @State private var renaming: Row?
    @State private var newName = ""
    @FocusState private var focus: String?

    /// The editor opens under the list: the ring goes to its Save (the field sits just above).
    private func startRename(_ r: Row) {
        renaming = r
        newName = r.name
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { focus = "rename-save" }
    }

    /// The editor closes under the ring: it goes back to that row's Rename.
    private func endRename(_ key: String) {
        renaming = nil
        focus = "rename:\(key)"
    }

    private var profile: (id: String, linked: Bool) { let p = ProfilesStore.shared.active; return (p?.id ?? "default", p?.linked ?? true) }

    var body: some View {
        VStack(alignment: .leading, spacing: BP.px(8)) {
            if let tune { tunePanel(tune) }
            if rows.isEmpty {
                BPNote(text: loaded ? "Open the Anime room once; its rows appear here to reorder, hide or rename." : "Loading…")
            }
            ForEach(Array(rows.enumerated()), id: \.element.key) { i, r in
                HStack(spacing: BP.px(8)) {
                    Text(r.name).font(BP.sans(14, r.hidden ? .regular : .semibold)).foregroundStyle(r.hidden ? BP.inkSubtle : BP.ink).lineLimit(1).frame(width: BP.px(340), alignment: .leading)
                    // (settings device pass) Dimmed, not disabled, at the ends (HomeRowsPanel).
                    let top = i == 0
                    let bottom = i == rows.count - 1
                    Button { if !top { Task { await call("animeRowMove", [.string(r.key), .number(-1)]) } } } label: { Image(systemName: "arrow.up") }.buttonStyle(BPActionStyle(busy: top)).accessibilityLabel(T("Move up"))
                    Button { if !bottom { Task { await call("animeRowMove", [.string(r.key), .number(1)]) } } } label: { Image(systemName: "arrow.down") }.buttonStyle(BPActionStyle(busy: bottom)).accessibilityLabel(T("Move down"))
                    Button(r.hidden ? "Show" : "Hide") { Task { await call("animeRowToggleHidden", [.string(r.key)]) } }.buttonStyle(BPActionStyle(primary: r.hidden))
                    Button("Rename") { startRename(r) }.buttonStyle(BPActionStyle())
                        .focused($focus, equals: "rename:\(r.key)")
                }
            }
            if let r = renaming {
                BPField(label: T("Rename %@", r.originalName), placeholder: r.originalName, text: $newName)
                HStack(spacing: BP.px(8)) {
                    Button("Save") { Task { await call("animeRowRename", [.string(r.key), .string(newName)]); endRename(r.key) } }.buttonStyle(BPActionStyle(primary: true))
                        .focused($focus, equals: "rename-save")
                    Button("Use original name") { Task { await call("animeRowRename", [.string(r.key), .string("")]); endRename(r.key) } }.buttonStyle(BPActionStyle())
                    Button("Cancel") { endRename(r.key) }.buttonStyle(BPActionStyle())
                }
            }
            if !rows.isEmpty { Button("Reset rows") { Task { await call("animeRowsReset", []) } }.buttonStyle(BPActionStyle()) }
        }
        .task { await load() }
    }

    /// AnimeGenrePicker ("Tune anime"): genres steer Top Picks for You (settings.animeFavoriteGenres);
    /// origins and already-watched titles leave the picks. Each press saves (upstream saves on Done).
    @ViewBuilder private func tunePanel(_ t: Tune) -> some View {
        Text(T("Tune anime")).font(BP.sans(15, .semibold)).foregroundStyle(BP.inkMuted)
        Text(T("Genres you want more of")).font(BP.sans(13, .semibold)).foregroundStyle(BP.inkSubtle)
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(BP.px(190)), spacing: BP.px(8), alignment: .leading), count: 4), alignment: .leading, spacing: BP.px(8)) {
            ForEach(t.genres) { g in
                Button { Task { await tuneCall("animeTuneGenre", [.number(Double(g.id))]) } } label: {
                    HStack(spacing: BP.px(6)) {
                        Text(verbatim: g.label).lineLimit(1)
                        if g.on { Image(systemName: "checkmark") }
                    }
                }
                .buttonStyle(BPActionStyle(primary: g.on))
            }
        }
        Text(T("Hide from your picks")).font(BP.sans(13, .semibold)).foregroundStyle(BP.inkSubtle)
        HStack(spacing: BP.px(8)) {
            ForEach(t.origins) { o in
                Button { Task { await tuneCall("animeTuneOrigin", [.string(o.code)]) } } label: { Text(verbatim: o.label).lineLimit(1) }
                    .buttonStyle(BPActionStyle(primary: o.on))
            }
        }
        HStack(spacing: BP.px(8)) {
            Button { Task { await tuneCall("animeTuneHideWatched", [.bool(!t.hideWatched)]) } } label: {
                Text(verbatim: "\(T("Hide anime I've already watched")): \(T(t.hideWatched ? "On" : "Off"))").lineLimit(1)
            }
            .buttonStyle(BPActionStyle(primary: t.hideWatched))
            if t.genres.contains(where: { $0.on }) {
                Button(T("Clear all")) { Task { await tuneCall("animeTuneClear", []) } }.buttonStyle(BPActionStyle())
            }
        }
    }

    private func load() async {
        let p = profile
        tune = try? await HarborEngine.shared.call("actions.animeTune", [p.id, p.linked])
        rows = (try? await HarborEngine.shared.call("actions.animeRows", [p.id, p.linked])) ?? []
        loaded = true
    }

    /// The engine saves, raises `harbor:anime-updated` itself and returns the new picker state.
    private func tuneCall(_ fn: String, _ args: [AnyJSON]) async {
        let p = profile
        if let out = try? await HarborEngine.shared.callJSON("actions.\(fn)", [.string(p.id), .bool(p.linked)] + args), let next = try? out.decode(Tune.self) { tune = next }
    }

    private func call(_ fn: String, _ args: [AnyJSON]) async {
        let p = profile
        if let out = try? await HarborEngine.shared.callJSON("actions.\(fn)", [.string(p.id), .bool(p.linked)] + args), let list = try? out.decode([Row].self) { rows = list }
        HarborEngine.shared.emitEvent("harbor:anime-updated")
    }
}
