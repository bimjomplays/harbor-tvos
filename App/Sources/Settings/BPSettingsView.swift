import SwiftUI

/// bp-settings.tsx: a category column (label + summary) and, for the active category, the
/// control rows from upstream's catalog: option rails, multi cells, push rows and actions.
@MainActor
final class BPSettingsModel: ObservableObject {
    struct Category: Decodable, Identifiable, Equatable { var id: String; var label: String; var summary: String }
    struct Option: Decodable, Identifiable, Equatable { var value: String; var label: String; var id: String { value } }
    struct MultiItem: Decodable, Identifiable, Equatable { var value: String; var label: String; var on: Bool; var rank: Int; var tint: String?; var id: String { value } }
    struct Control: Decodable, Identifiable, Equatable {
        var kind: String; var id: String; var label: String
        var value: String?; var options: [Option]?; var letter: Bool?; var columns: Int?
        var render: String?; var items: [MultiItem]?
        var detail: String?; var pane: String?
    }
    struct Cats: Decodable { var categories: [Category]; var sportsShown: Bool; var overscan: Double }
    struct Committed: Decodable { var ok: Bool; var sportsShown: Bool }

    /// engine settingsRoom.pane: what bp-settings-pane.tsx draws beside the column.
    struct Pane: Decodable, Equatable {
        struct Subtitle: Decodable, Equatable { var text: String; var px: Double; var flags: [String] }
        struct Service: Decodable, Identifiable, Equatable { var value: String; var label: String; var tint: String; var id: String { value } }
        struct Language: Decodable, Equatable { var code: String; var nativeLabel: String; var greeting: String; var rtl: Bool }
        var still: String
        var overscan: Double
        var overscanLabel: String
        var subtitle: Subtitle
        var homeMode: String
        var services: [Service]
        var servicesEmpty: String
        var language: Language?
        var playback: [[String]]
        var setup: [[String]]
        var interface: [[String]]
    }

    /// A theme change rebuilds the tree (ThemeStore.revision); the column comes back where it was.
    private static var lastActive = "picture"

    @Published private(set) var categories: [Category] = []
    @Published private(set) var controls: [Control] = []
    @Published private(set) var pane: Pane?
    @Published var active: String = BPSettingsModel.lastActive

    private var profile: (id: String, linked: Bool) {
        let p = ProfilesStore.shared.active
        return (p?.id ?? "default", p?.linked ?? true)
    }

    /// (settings device pass) Only the newest load applies: a commit, harbor:settings-updated and a
    /// closing cover can each start one, and an older answer landing last put old values back.
    private var loadGen = 0
    private var unsubscribe: (() -> Void)?
    private var reloadTask: Task<Void, Never>?

    deinit { reloadTask?.cancel(); unsubscribe?() }

    func load() async {
        watch()
        loadGen &+= 1
        let gen = loadGen
        let p = profile
        let c: Cats? = try? await HarborEngine.shared.call("settingsRoom.categories", [p.id, p.linked])
        guard gen == loadGen else { return }
        if let c {
            if c.categories != categories { categories = c.categories }
            let declined = !c.sportsShown
            if SettingsBridge.shared.sportsDeclined != declined { SettingsBridge.shared.sportsDeclined = declined }
        }
        let fresh: Pane? = try? await HarborEngine.shared.call("settingsRoom.pane", [p.id, p.linked])
        guard gen == loadGen else { return }
        if let fresh, fresh != pane { pane = fresh }
        await loadControls()
    }

    /// (settings device pass) bp-settings.tsx reads the live settings on every render, so a change
    /// synced from another device (profile sync raises harbor:settings-updated) shows at once. The
    /// column loaded once per visit and kept the old values, summaries and preview; a burst of
    /// events (one per synced section) now reloads once.
    private func watch() {
        guard unsubscribe == nil else { return }
        unsubscribe = HarborEngine.shared.onEvent { [weak self] type, _ in
            guard type == "harbor:settings-updated" else { return }
            Task { @MainActor in self?.scheduleReload() }
        }
    }

    func scheduleReload() {
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await self?.load()
        }
    }

    func loadControls() async {
        let p = profile
        let id = active
        let fresh: [Control]? = try? await HarborEngine.shared.call("settingsRoom.controls", [id, p.id, p.linked])
        // Focus can walk the column faster than the engine answers; only the latest wins.
        guard id == active, let fresh, fresh != controls else { return }
        controls = fresh
    }

    /// The chosen category's rows, loaded now if the focus walk has not brought them in yet.
    func ensureControls() async {
        if controls.isEmpty { await loadControls() }
    }

    func select(_ id: String) {
        guard id != active || controls.isEmpty else { return }
        // bp-settings.tsx: leaving the category puts the committed sound theme back.
        BPSound.shared.audition = nil
        // (settings device pass) upstream derives the rows from the active category in the same
        // render; here they arrive later, and Select pressed before they did opened the previous
        // category's rows (and a press there changed that category's setting).
        if id != active { controls = [] }
        active = id
        Self.lastActive = id
        Task { await loadControls() }
    }

    func commit(_ control: String, _ value: String) async {
        let p = profile
        if let c: Committed = try? await HarborEngine.shared.call("settingsRoom.commit", [control, value, p.id, p.linked]) {
            let declined = !c.sportsShown
            if SettingsBridge.shared.sportsDeclined != declined { SettingsBridge.shared.sportsDeclined = declined }
        }
        await SettingsBridge.shared.load()
        BPSound.shared.audition = nil
        await load()
    }
}

/// bp-settings.tsx page: one column that is the category list at depth 1 and the chosen
/// category's controls at depth 2 (Back returns), with BpSettingsPane's live preview beside it.
/// Focusing a category moves the preview, exactly as upstream's onFocus → setActive does.
struct BPSettingsView: View {
    @StateObject private var model = BPSettingsModel()
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var account: AccountStore
    let openConnect: () -> Void
    /// SettingsView bumps this when one of its covers closes (sign-ins, Accounts and TMDB, the
    /// subtitle languages): the Setup summary and push-row details read what they changed.
    var refresh = 0
    @EnvironmentObject private var settings: SettingsBridge
    @State private var depth = BPSettingsView.restoredDepth
    /// A theme change rebuilds the tree mid-visit (ThemeStore.revision): the column comes back at
    /// the depth it was on; a fresh visit still opens on the categories (review 17).
    /// (bug pass) RootView's `.id` is "theme revision|language": picking a language in Settings
    /// rebuilds the tree just as a theme does, and the column fell back to the category list.
    /// (settings device pass) Read without side effects: a @State initial value is evaluated on
    /// every init of this view, and the old consume-and-restamp could spend the saved depth on
    /// the outgoing tree. The stamp happens on appear; leaving the room forgets it.
    private static var saved: (depth: Int, revision: String)?
    private static var treeToken: String {
        "\(ThemeStore.shared.revision)|\(L10n.normalize(SettingsBridge.shared.slice.uiLanguage))"
    }
    private static var restoredDepth: Int {
        guard let s = saved, s.revision != treeToken else { return 1 }
        return s.depth
    }
    /// (settings device pass) The option cell a pick came from, while that pick may rebuild the
    /// tree (Display language): the ring came back on the top bar instead of the cell, the way
    /// AppearancePanel's `refocus` already brings it back to a theme tile.
    private static var refocus: (key: String, revision: String)?
    @FocusState private var focus: String?
    /// Setup → AI search (engine settingsRoom TvControl, pane "ai"): the key and model panel.
    @State private var aiOpen = false
    /// Setup → Live TV (pane "live"): bp-settings renders BpLiveSetup in place; here the Sources
    /// sheet over Settings. (live sources device pass) It left Settings for the Live TV tab (ST-3).
    @State private var liveOpen = false

    var body: some View {
        HStack(alignment: .top, spacing: BP.px(23)) {
            VStack(alignment: .leading, spacing: depth == 1 ? BP.px(6) : BP.px(14)) {
                if depth == 1 {
                    ForEach(model.categories) { c in categoryRow(c) }
                } else {
                    ForEach(Array(model.controls.enumerated()), id: \.element.id) { i, c in controlRow(c, first: i == 0) }
                }
            }
            // BpSettingsColumnBox: w-[clamp(330px,38%,470px)] of the page.
            .frame(width: BP.px(368), alignment: .topLeading)
            .focusSection()
            // bp-settings.tsx pushBpBack: depth 2 → depth 1; at depth 1 Back belongs to the shell.
            .onExitCommand(perform: depth == 2 ? { goBack() } : nil)
            BPSettingsPane(cat: model.active, title: model.categories.first { $0.id == model.active }?.label ?? "", pane: model.pane)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        // The page spans the width, so Down from the top bar's cog (far right, above the
        // preview, which has nothing focusable) still lands in the category column.
        .focusSection()
        .task {
            await model.load()
            if let r = Self.refocus, r.revision != Self.treeToken {
                Self.refocus = nil
                guard depth == 2 else { return }
                try? await Task.sleep(for: .milliseconds(150))
                focus = r.key
            }
        }
        .onAppear { Self.saved = (depth, Self.treeToken) }
        .onDisappear {
            BPSound.shared.audition = nil
            // Leaving Settings (another tab, a profile switch): the next visit opens on the
            // categories like upstream's fresh mount, whatever a synced theme did meanwhile.
            if app.room != .settings || app.stage != .shell {
                Self.saved = nil
                Self.refocus = nil
            }
        }
        // Changes written from the panels below (SettingsBridge.patch raises no event).
        .onChange(of: settings.slice) { _, _ in model.scheduleReload() }
        .onChange(of: refresh) { _, _ in model.scheduleReload() }
        .fullScreenCover(isPresented: $aiOpen, onDismiss: { Task { await model.load() } }) {
            AISearchPanel(onClose: { aiOpen = false })
        }
        .fullScreenCover(isPresented: $liveOpen, onDismiss: { Task { await model.load() } }) {
            LiveSourcesCover(dismiss: { liveOpen = false })
        }
    }

    private func goBack() {
        depth = 1
        Self.saved = (1, Self.treeToken)
        let id = model.active
        DispatchQueue.main.async { focus = "cat:\(id)" }
    }

    private func open(_ id: String) {
        model.select(id)
        depth = 2
        Self.saved = (2, Self.treeToken)
        // bp-settings.tsx: a depth change moves the ring into the swapped column (once its rows are in).
        Task {
            await model.ensureControls()
            try? await Task.sleep(for: .milliseconds(150))
            if depth == 2 { focus = "first" }
        }
    }

    /// An option cell's pick. Remembered while it runs, in case it rebuilds the tree (language).
    private func pick(_ control: String, _ value: String, key: String) {
        Self.refocus = (key, Self.treeToken)
        Task {
            await model.commit(control, value)
            // No rebuild happened: nothing to bring back later (a theme pick must not pull the ring here).
            if Self.refocus?.revision == Self.treeToken { Self.refocus = nil }
        }
    }

    private static func cellKey(_ c: BPSettingsModel.Control, _ value: String, first: Bool) -> String {
        first ? "first" : "\(c.id):\(value)"
    }

    private func categoryRow(_ c: BPSettingsModel.Category) -> some View {
        Button { open(c.id) } label: {
            HStack(spacing: BP.px(10)) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(c.label).font(BP.sans(16, .bold)).foregroundStyle(BP.ink).lineLimit(1)
                    Text(c.summary).font(BP.sans(12, .medium)).foregroundStyle(BP.ink.opacity(0.65)).lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.forward").font(.system(size: BP.px(12), weight: .bold)).foregroundStyle(BP.ink.opacity(0.55))
            }
            .padding(.horizontal, BP.px(14))
            .frame(width: BP.px(368), height: BP.px(54), alignment: .leading)
            .background(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).fill(model.active == c.id ? BP.on : .clear))
        }
        .buttonStyle(BPTileStyle(radius: BP.rSM, onFocus: { model.select(c.id) }))
        .focused($focus, equals: "cat:\(c.id)")
        .bpSelected(model.active == c.id)
    }

    /// bp-settings.tsx: `onCellFocus={control.id === "sound" ? auditionSound : undefined}`.
    private func audition(_ c: BPSettingsModel.Control, _ value: String) -> (() -> Void)? {
        guard c.id == "sound" else { return nil }
        return { BPSound.shared.audition = value }
    }

    /// (layout pass) A cell track starts flush with the column, so the scroll view's clip took the
    /// left side of the first cell's ring (9.5 pt out, plus the lift) and the right side of a cell
    /// scrolled to the end. bp-grid's HEADROOM pattern: pad the track, pull the scroller out as much.
    private static let trackHeadroom = BP.px(10)

    @ViewBuilder private func controlRow(_ c: BPSettingsModel.Control, first: Bool) -> some View {
        switch c.kind {
        case "options":
            VStack(alignment: .leading, spacing: BP.px(6)) {
                label(c.label)
                let opts = c.options ?? []
                if c.columns == 2 {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: BP.px(6)) {
                        ForEach(Array(opts.enumerated()), id: \.element.id) { i, o in
                            let key = Self.cellKey(c, o.value, first: first && i == 0)
                            cell(o.label, on: c.value == o.value, letter: c.letter == true ? o.value : nil, focus: audition(c, o.value)) { pick(c.id, o.value, key: key) }
                                .focused($focus, equals: key)
                        }
                    }
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: BP.px(6)) {
                            ForEach(Array(opts.enumerated()), id: \.element.id) { i, o in
                                let key = Self.cellKey(c, o.value, first: first && i == 0)
                                cell(o.label, on: c.value == o.value, letter: c.letter == true ? o.value : nil, focus: audition(c, o.value)) { pick(c.id, o.value, key: key) }
                                    .focused($focus, equals: key)
                            }
                        }
                        .padding(.vertical, BP.px(8))
                        .padding(.horizontal, Self.trackHeadroom)
                    }
                    .padding(.horizontal, -Self.trackHeadroom)
                }
            }
        case "multi":
            // bp-settings-parts.tsx BpMultiRow: one scrolling track, off cells at 60%, rank badges.
            VStack(alignment: .leading, spacing: BP.px(6)) {
                label(c.label)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: BP.px(6)) {
                        ForEach(Array((c.items ?? []).enumerated()), id: \.element.id) { idx, i in
                            Button { Task { await model.commit(c.id, i.value) } } label: {
                                HStack(spacing: BP.px(6)) {
                                    // ServiceLogo's own fallback when there is no mark: the name in its brand tint.
                                    Text(i.label).font(BP.sans(13, i.on ? .bold : .semibold)).lineLimit(1)
                                        .foregroundStyle(c.render == "logo" ? (Color(css: i.tint ?? "") ?? BP.ink) : (i.on ? BP.ink : BP.inkSubtle))
                                    if i.on && i.rank > 0 {
                                        Text("\(i.rank)").font(BP.sans(10, .bold)).foregroundStyle(BP.ink)
                                            .frame(width: BP.px(20), height: BP.px(20))
                                            .background(Circle().fill(BP.void_))
                                    }
                                }
                                .padding(.horizontal, BP.px(14))
                                .frame(height: BP.px(46))
                                .background(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).fill(i.on ? BP.on : BP.panel))
                                .overlay(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).strokeBorder(i.on ? .clear : BP.edge, lineWidth: 1))
                                .opacity(i.on ? 1 : 0.6)
                            }
                            .buttonStyle(BPTileStyle(radius: BP.rSM))
                            .focused($focus, equals: first && idx == 0 ? "first" : "\(c.id):\(i.value)")
                            .bpSelected(i.on)
                        }
                    }
                    .padding(.vertical, BP.px(8))
                    .padding(.horizontal, Self.trackHeadroom)
                }
                .padding(.horizontal, -Self.trackHeadroom)
            }
        case "push":
            Button {
                if c.pane == "live" { liveOpen = true } else if c.pane == "ai" { aiOpen = true } else { openConnect() }
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(c.label).font(BP.sans(15, .semibold))
                        // T(): the TV's own detail lines (tools/locales-tvos.json) never reach the engine's catalog.
                        Text(T(c.detail ?? "")).font(BP.sans(11)).foregroundStyle(BP.inkMuted).lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: "chevron.forward")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(BPActionStyle())
            .focused($focus, equals: first ? "first" : c.id)
        case "action":
            if c.id != "leave" {
                Button(c.label) {
                    Task {
                        await model.commit(c.id, "on")
                        // bp-settings.tsx reviewSportsNotice: reset, then open the Sports tab to show it.
                        if c.id == "sportsNotice" { app.room = .sports }
                    }
                }
                .buttonStyle(BPActionStyle())
                .focused($focus, equals: first ? "first" : c.id)
            }
        default:
            EmptyView()
        }
    }

    private func label(_ text: String) -> some View {
        Text(text.uppercased()).font(BP.sans(11, .bold)).tracking(1.5).foregroundStyle(BP.inkSubtle)
            // The uppercase is styling: VoiceOver reads the control's own spelling as a heading.
            .accessibilityLabel(Text(verbatim: text))
            .accessibilityAddTraits(.isHeader)
    }

    private func cell(_ text: String, on: Bool, letter: String?, focus: (() -> Void)? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(letter.map { _ in text.replacingOccurrences(of: "px", with: "") } ?? text)
                .font(letter.map { BP.sans(CGFloat(Double($0) ?? 15) * 0.55, .bold) } ?? BP.sans(14, on ? .bold : .semibold))
                .foregroundStyle(on ? BP.ink : BP.inkSubtle)
                .lineLimit(1)
                .padding(.horizontal, BP.px(16))
                .frame(minWidth: BP.px(80), minHeight: BP.px(46))
                .background(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).fill(on ? BP.on : BP.panel))
                .overlay(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).strokeBorder(on ? .clear : BP.edge, lineWidth: 1))
        }
        .buttonStyle(BPTileStyle(radius: BP.rSM, onFocus: focus))
        // bp-settings-parts.tsx BpOptionRow cells are aria-pressed: the picked one reads as selected.
        .bpSelected(on)
    }
}
