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
    /// (settings pass 2) A layout synced from another device (profile sync's `anime` section is
    /// settings.animeRows) or picks tuned elsewhere: the panel kept the state it read on open.
    @StateObject private var watch = SettingsFieldWatch { f in f.hasPrefix("anime") }

    /// The editor opens under the list: the ring goes to its Save (the field sits just above).
    private func startRename(_ r: Row) {
        renaming = r
        newName = r.name
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { focus = "rename-save" }
    }

    /// The editor closes under the ring: it goes back to that row's Rename. (review 7) Not when a
    /// sync already closed this editor (its row went away while Save / the reset waited).
    private func endRename(_ key: String) {
        guard renaming?.key == key else { return }
        renaming = nil
        focus = "rename:\(key)"
    }

    /// (review 7) Every new row list goes through here: a sync (SettingsFieldWatch re-read) that
    /// removed the row being renamed left its editor open, and closing it aimed the ring at a Rename
    /// that no longer exists. The editor closes, and a ring on its buttons goes to the Rename of the
    /// row now in the removed one's place (the one above at the end), or Tune's Hide-watched switch.
    private func apply(_ next: [Row]) {
        let before = rows
        rows = next
        guard let r = renaming, !next.contains(where: { $0.key == r.key }) else { return }
        renaming = nil
        // Only a ring on one of the editor's buttons is moved; one on the field (untagged, as is
        // the rest of the panel) is left to tvOS, which finds the nearest button that exists.
        let inEditor = focus == "rename-save" || focus == "rename-reset" || focus == "rename-cancel"
        guard inEditor else { return }
        let was = before.firstIndex(where: { $0.key == r.key }) ?? 0
        if !next.isEmpty {
            focus = "rename:\(next[min(was, next.count - 1)].key)"
        } else if tune != nil {
            focus = "tune-hide"
        } else {
            focus = nil
        }
    }

    /// Menu while the rename editor is open closes it; nil otherwise, so Menu still leaves Settings.
    private var exitAction: (() -> Void)? {
        guard let r = renaming else { return nil }
        return { endRename(r.key) }
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
                        .focused($focus, equals: "rename-reset")
                    Button("Cancel") { endRename(r.key) }.buttonStyle(BPActionStyle())
                        .focused($focus, equals: "rename-cancel")
                }
            }
            if !rows.isEmpty { Button("Reset rows") { Task { await call("animeRowsReset", []) } }.buttonStyle(BPActionStyle()) }
        }
        .task { await load() }
        .onChange(of: watch.tick) { _, _ in Task { await load() } }
        // (settings pass 2) Menu closes the rename editor first; it used to leave Settings.
        .onExitCommand(perform: exitAction)
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
                        if g.on { Image(systemName: "checkmark").accessibilityHidden(true) }
                    }
                }
                .buttonStyle(BPActionStyle(primary: g.on))
                .bpSelected(g.on)
            }
        }
        Text(T("Hide from your picks")).font(BP.sans(13, .semibold)).foregroundStyle(BP.inkSubtle)
        HStack(spacing: BP.px(8)) {
            ForEach(t.origins) { o in
                Button { Task { await tuneCall("animeTuneOrigin", [.string(o.code)]) } } label: { Text(verbatim: o.label).lineLimit(1) }
                    .buttonStyle(BPActionStyle(primary: o.on))
                    .bpSelected(o.on)
            }
        }
        HStack(spacing: BP.px(8)) {
            Button { Task { await tuneCall("animeTuneHideWatched", [.bool(!t.hideWatched)]) } } label: {
                Text(verbatim: "\(T("Hide anime I've already watched")): \(T(t.hideWatched ? "On" : "Off"))").lineLimit(1)
            }
            .buttonStyle(BPActionStyle(primary: t.hideWatched))
            .focused($focus, equals: "tune-hide")
            if t.genres.contains(where: { $0.on }) {
                // (settings pass 2) Clear all goes away with the genres it cleared, from under the
                // ring: the ring moves to its neighbour instead of falling off the panel.
                Button(T("Clear all")) {
                    Task {
                        await tuneCall("animeTuneClear", [])
                        focus = "tune-hide"
                    }
                }
                .buttonStyle(BPActionStyle())
            }
        }
    }

    private func load() async {
        let p = profile
        // (review 7) A failed re-read (SettingsFieldWatch) keeps what is on screen instead of
        // dropping the Tune section and emptying the rows under the ring.
        if let t: Tune = try? await HarborEngine.shared.call("actions.animeTune", [p.id, p.linked]) { tune = t }
        if let list: [Row] = try? await HarborEngine.shared.call("actions.animeRows", [p.id, p.linked]) { apply(list) }
        loaded = true
    }

    /// The engine saves, raises `harbor:anime-updated` itself and returns the new picker state.
    private func tuneCall(_ fn: String, _ args: [AnyJSON]) async {
        let p = profile
        if let out = try? await HarborEngine.shared.callJSON("actions.\(fn)", [.string(p.id), .bool(p.linked)] + args), let next = try? out.decode(Tune.self) { tune = next }
    }

    private func call(_ fn: String, _ args: [AnyJSON]) async {
        let p = profile
        if let out = try? await HarborEngine.shared.callJSON("actions.\(fn)", [.string(p.id), .bool(p.linked)] + args), let list = try? out.decode([Row].self) { apply(list) }
        HarborEngine.shared.emitEvent("harbor:anime-updated")
    }
}
