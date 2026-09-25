import SwiftUI

/// Settings → Home rows: settings.homeRows through lib/home-customization (engine/homeExtras.ts).
/// Upstream's Big Picture has no customize page (use-bp-row-layout.ts takes the desktop's layout
/// through sync); the TV edits the same object: reorder, hide, rename, Top 10 numerals, custom
/// lists as Home rows (homeRows.listRows) and the Simkl home rail switches. Home re-reads on
/// `harbor:home-updated`, which every change raises.
struct HomeRowsPanel: View {
    struct RowsState: Decodable {
        struct Row: Decodable, Identifiable { var key: String; var name: String; var originalName: String; var hidden: Bool; var numerals: Bool; var id: String { key } }
        struct ListEntry: Decodable, Identifiable { var id: String; var name: String; var count: Int; var onHome: Bool }
        struct Simkl: Decodable { var connected: Bool; var home: Bool; var upNext: Bool; var trending: Bool }
        struct Cw: Decodable { var advanceNext: Bool; var hideCaughtUp: Bool; var animeCwEnd: String }
        var rows: [Row]
        var lists: [ListEntry]
        var simkl: Simkl
        var cw: Cw?
    }
    @State private var layout: RowsState?
    @State private var renaming: RowsState.Row?
    @State private var newName = ""
    @FocusState private var focus: String?
    /// (settings pass 2) A layout synced from another device (profile sync's `home` section is
    /// settings.homeRows) or a Simkl / Continue Watching switch changed elsewhere: the panel read its
    /// state once per visit and kept showing, and editing, the old one.
    @StateObject private var watch = SettingsFieldWatch { f in
        f == "homeRows" || f == "animeCwEnd" || f.hasPrefix("simkl") || f.hasPrefix("cw")
    }

    private func startRename(_ r: RowsState.Row) {
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
            if let s = layout {
                if !s.lists.isEmpty {
                    Text(T("Your lists on Home")).font(BP.sans(15, .semibold)).foregroundStyle(BP.inkMuted)
                    ForEach(s.lists) { l in
                        HStack(spacing: BP.px(8)) {
                            Text(l.name).font(BP.sans(14, .semibold)).foregroundStyle(BP.ink).lineLimit(1).frame(width: BP.px(340), alignment: .leading)
                            Text(verbatim: "\(l.count)").font(BP.sans(13)).foregroundStyle(BP.inkSubtle).frame(width: BP.px(48), alignment: .leading)
                            Button(l.onHome ? T("Remove from Home") : T("Add to Home")) { Task { await call("homeListRowToggle", [.string(l.id)]) } }
                                .buttonStyle(BPActionStyle(primary: l.onHome))
                        }
                    }
                }
                if s.simkl.connected {
                    // lib/simkl/home-rails.ts gates: the rails as a whole, then Up Next and Trending.
                    Text(T("Simkl rails")).font(BP.sans(15, .semibold)).foregroundStyle(BP.inkMuted)
                    HStack(spacing: BP.px(8)) {
                        simklSwitch("Home rails", s.simkl.home, "home")
                        simklSwitch("Up Next rail", s.simkl.upNext, "upNext")
                        simklSwitch("Trending rail", s.simkl.trending, "trending")
                    }
                }
                if let cw = s.cw {
                    // library-panel/home-tab.tsx "Continue Watching": cwAdvanceNext, cwHideCaughtUp,
                    // animeCwEnd (use-cw-advance.ts reads all three, on Home and in the Anime room).
                    Text(T("Continue Watching")).font(BP.sans(15, .semibold)).foregroundStyle(BP.inkMuted)
                    cwSwitch("Advance Continue Watching to the next episode", cw.advanceNext, "advanceNext")
                    cwSwitch("Remove shows once you're caught up", cw.hideCaughtUp, "hideCaughtUp")
                    HStack(spacing: BP.px(8)) {
                        Text(T("When the latest episode ends")).font(BP.sans(14)).foregroundStyle(BP.ink).lineLimit(1)
                        Button(T("Hide")) { Task { await call("homeCwSetting", [.string("animeCwEnd"), .string("hide")]) } }
                            .buttonStyle(BPActionStyle(primary: cw.animeCwEnd != "timer"))
                        Button(T("Timer")) { Task { await call("homeCwSetting", [.string("animeCwEnd"), .string("timer")]) } }
                            .buttonStyle(BPActionStyle(primary: cw.animeCwEnd == "timer")).bpSelected(cw.animeCwEnd == "timer")
                    }
                }
                Text(T("Rows")).font(BP.sans(15, .semibold)).foregroundStyle(BP.inkMuted)
                if s.rows.isEmpty {
                    BPNote(text: "Open Home once; its rows appear here to reorder, hide or rename.")
                }
                ForEach(Array(s.rows.enumerated()), id: \.element.key) { i, r in
                    HStack(spacing: BP.px(8)) {
                        Text(r.name).font(BP.sans(14, r.hidden ? .regular : .semibold)).foregroundStyle(r.hidden ? BP.inkSubtle : BP.ink).lineLimit(1).frame(width: BP.px(340), alignment: .leading)
                        // (settings device pass) The end arrows dim instead of disabling: a row moved
                        // to the top or bottom disabled the arrow under the ring, which then jumped off
                        // the list. The ring stays on the arrow and rides along with its row.
                        let top = i == 0
                        let bottom = i == s.rows.count - 1
                        Button { if !top { Task { await call("homeRowMove", [.string(r.key), .number(-1)]) } } } label: { Image(systemName: "arrow.up") }.buttonStyle(BPActionStyle(busy: top)).accessibilityLabel(T("Move up"))
                        Button { if !bottom { Task { await call("homeRowMove", [.string(r.key), .number(1)]) } } } label: { Image(systemName: "arrow.down") }.buttonStyle(BPActionStyle(busy: bottom)).accessibilityLabel(T("Move down"))
                        Button(r.hidden ? T("Show") : T("Hide")) { Task { await call("homeRowToggleHidden", [.string(r.key)]) } }.buttonStyle(BPActionStyle(primary: r.hidden))
                        // The editor opens under the list: the ring goes to its Save (the field sits just above).
                        Button(T("Rename")) { startRename(r) }.buttonStyle(BPActionStyle())
                            .focused($focus, equals: "rename:\(r.key)")
                        Button(r.numerals ? T("Numbers: On") : T("Numbers: Off")) { Task { await call("homeRowToggleNumerals", [.string(r.key)]) } }.buttonStyle(BPActionStyle(primary: r.numerals))
                    }
                }
                if let r = renaming {
                    BPField(label: T("Rename %@", r.originalName), placeholder: r.originalName, text: $newName)
                    HStack(spacing: BP.px(8)) {
                        Button(T("Save")) { Task { await call("homeRowRename", [.string(r.key), .string(newName)]); endRename(r.key) } }.buttonStyle(BPActionStyle(primary: true))
                            .focused($focus, equals: "rename-save")
                        // row-controls.tsx
                        Button(T("Reset to original name")) { Task { await call("homeRowRename", [.string(r.key), .string("")]); endRename(r.key) } }.buttonStyle(BPActionStyle())
                        Button(T("Cancel")) { endRename(r.key) }.buttonStyle(BPActionStyle())
                    }
                }
                if !s.rows.isEmpty { Button(T("Reset rows")) { Task { await call("homeRowsReset", []) } }.buttonStyle(BPActionStyle()) }
            } else {
                BPNote(text: "Loading…")
            }
        }
        .task { await load() }
        .onChange(of: watch.tick) { _, _ in Task { await load() } }
        // (settings pass 2) Menu closes the rename editor first (row-controls.tsx: Escape cancels
        // the inline rename); it used to leave Settings with the editor still open.
        .onExitCommand(perform: renaming == nil ? nil : { if let r = renaming { endRename(r.key) } })
    }

    private func simklSwitch(_ label: String, _ on: Bool, _ which: String) -> some View {
        let title: String = "\(T(label)): \(T(on ? "On" : "Off"))"
        return Button(title) { Task { await call("homeSimklRail", [.string(which), .bool(!on)]) } }.buttonStyle(BPActionStyle(primary: on))
    }

    private func cwSwitch(_ label: String, _ on: Bool, _ which: String) -> some View {
        let title: String = "\(T(label)): \(T(on ? "On" : "Off"))"
        return Button(title) { Task { await call("homeCwSetting", [.string(which), .bool(!on)]) } }.buttonStyle(BPActionStyle(primary: on))
    }

    private func load() async {
        let p = profile
        layout = try? await HarborEngine.shared.call("rooms.homeRowsState", [p.id, p.linked])
    }

    /// Every edit returns the new state; the engine raises `harbor:home-updated` for Home.
    private func call(_ fn: String, _ args: [AnyJSON]) async {
        let p = profile
        if let out = try? await HarborEngine.shared.callJSON("rooms.\(fn)", [.string(p.id), .bool(p.linked)] + args), let next = try? out.decode(RowsState.self) { layout = next }
    }
}

/// (settings pass 2) Bumps `tick` (debounced 250 ms) when harbor:settings-updated names a field
/// `wants` accepts, or names none: a panel that reads its state once re-reads what profile sync
/// (or another screen) changed while it is open.
@MainActor
final class SettingsFieldWatch: ObservableObject {
    struct Detail: Decodable { var fields: [String]? }
    @Published private(set) var tick = 0
    private var unsubscribe: (() -> Void)?
    private var pending: Task<Void, Never>?

    init(_ wants: @escaping (String) -> Bool) {
        unsubscribe = HarborEngine.shared.onEvent { [weak self] type, detail in
            guard type == "harbor:settings-updated" else { return }
            let decoded: Detail? = detail.flatMap { try? $0.decode(Detail.self) }
            if let fields = decoded?.fields, !fields.contains(where: wants) { return }
            Task { @MainActor in self?.bump() }
        }
    }

    deinit { pending?.cancel(); unsubscribe?() }

    private func bump() {
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            self?.tick &+= 1
        }
    }
}
