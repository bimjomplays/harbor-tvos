import SwiftUI

/// bp-settings.tsx: a category column (label + summary) and, for the active category, the
/// control rows from upstream's catalog: option rails, multi cells, push rows and actions.
@MainActor
final class BPSettingsModel: ObservableObject {
    struct Category: Decodable, Identifiable { var id: String; var label: String; var summary: String }
    struct Option: Decodable, Identifiable { var value: String; var label: String; var id: String { value } }
    struct MultiItem: Decodable, Identifiable { var value: String; var label: String; var on: Bool; var rank: Int; var tint: String?; var id: String { value } }
    struct Control: Decodable, Identifiable {
        var kind: String; var id: String; var label: String
        var value: String?; var options: [Option]?; var letter: Bool?; var columns: Int?
        var render: String?; var items: [MultiItem]?
        var detail: String?; var pane: String?
    }
    struct Cats: Decodable { var categories: [Category]; var sportsShown: Bool; var overscan: Double }
    struct Committed: Decodable { var ok: Bool; var sportsShown: Bool }

    /// engine settingsRoom.pane: what bp-settings-pane.tsx draws beside the column.
    struct Pane: Decodable {
        struct Subtitle: Decodable { var text: String; var px: Double; var flags: [String] }
        struct Service: Decodable, Identifiable { var value: String; var label: String; var tint: String; var id: String { value } }
        struct Language: Decodable { var code: String; var nativeLabel: String; var greeting: String; var rtl: Bool }
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

    func load() async {
        let p = profile
        if let c: Cats = try? await HarborEngine.shared.call("settingsRoom.categories", [p.id, p.linked]) {
            categories = c.categories
            SettingsBridge.shared.sportsDeclined = !c.sportsShown
        }
        pane = try? await HarborEngine.shared.call("settingsRoom.pane", [p.id, p.linked])
        await loadControls()
    }

    func loadControls() async {
        let p = profile
        let id = active
        let fresh: [Control] = (try? await HarborEngine.shared.call("settingsRoom.controls", [id, p.id, p.linked])) ?? []
        // Focus can walk the column faster than the engine answers; only the latest wins.
        if id == active { controls = fresh }
    }

    func select(_ id: String) {
        guard id != active || controls.isEmpty else { return }
        // bp-settings.tsx: leaving the category puts the committed sound theme back.
        BPSound.shared.audition = nil
        active = id
        Self.lastActive = id
        Task { await loadControls() }
    }

    func commit(_ control: String, _ value: String) async {
        let p = profile
        if let c: Committed = try? await HarborEngine.shared.call("settingsRoom.commit", [control, value, p.id, p.linked]) {
            SettingsBridge.shared.sportsDeclined = !c.sportsShown
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
    @State private var depth = BPSettingsView.initialDepth()
    /// A theme change rebuilds the tree mid-visit (ThemeStore.revision): the column comes back at
    /// the depth it was on; a fresh visit still opens on the categories (review 17).
    private static var saved: (depth: Int, revision: Int)?
    private static func initialDepth() -> Int {
        let now = ThemeStore.shared.revision
        guard let s = saved, s.revision != now else { return 1 }
        saved = (s.depth, now)
        return s.depth
    }
    @FocusState private var focus: String?

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
        .task { await model.load() }
        .onDisappear { BPSound.shared.audition = nil }
    }

    private func goBack() {
        depth = 1
        Self.saved = (1, ThemeStore.shared.revision)
        let id = model.active
        DispatchQueue.main.async { focus = "cat:\(id)" }
    }

    private func open(_ id: String) {
        model.select(id)
        depth = 2
        Self.saved = (2, ThemeStore.shared.revision)
        // bp-settings.tsx: a depth change moves the ring into the swapped column.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { focus = "first" }
    }

    private func categoryRow(_ c: BPSettingsModel.Category) -> some View {
        Button { open(c.id) } label: {
            HStack(spacing: BP.px(10)) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(c.label).font(BP.sans(16, .bold)).foregroundStyle(BP.ink).lineLimit(1)
                    Text(c.summary).font(BP.sans(12, .medium)).foregroundStyle(BP.ink.opacity(0.65)).lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: BP.px(12), weight: .bold)).foregroundStyle(BP.ink.opacity(0.55))
            }
            .padding(.horizontal, BP.px(14))
            .frame(width: BP.px(368), height: BP.px(54), alignment: .leading)
            .background(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).fill(model.active == c.id ? BP.on : .clear))
        }
        .buttonStyle(BPTileStyle(radius: BP.rSM, onFocus: { model.select(c.id) }))
        .focused($focus, equals: "cat:\(c.id)")
    }

    /// bp-settings.tsx: `onCellFocus={control.id === "sound" ? auditionSound : undefined}`.
    private func audition(_ c: BPSettingsModel.Control, _ value: String) -> (() -> Void)? {
        guard c.id == "sound" else { return nil }
        return { BPSound.shared.audition = value }
    }

    @ViewBuilder private func controlRow(_ c: BPSettingsModel.Control, first: Bool) -> some View {
        switch c.kind {
        case "options":
            VStack(alignment: .leading, spacing: BP.px(6)) {
                label(c.label)
                let opts = c.options ?? []
                if c.columns == 2 {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: BP.px(6)) {
                        ForEach(Array(opts.enumerated()), id: \.element.id) { i, o in
                            cell(o.label, on: c.value == o.value, letter: c.letter == true ? o.value : nil, focus: audition(c, o.value)) { Task { await model.commit(c.id, o.value) } }
                                .focused($focus, equals: first && i == 0 ? "first" : "\(c.id):\(o.value)")
                        }
                    }
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: BP.px(6)) {
                            ForEach(Array(opts.enumerated()), id: \.element.id) { i, o in
                                cell(o.label, on: c.value == o.value, letter: c.letter == true ? o.value : nil, focus: audition(c, o.value)) { Task { await model.commit(c.id, o.value) } }
                                    .focused($focus, equals: first && i == 0 ? "first" : "\(c.id):\(o.value)")
                            }
                        }
                        .padding(.vertical, BP.px(8))
                    }
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
                        }
                    }
                    .padding(.vertical, BP.px(8))
                }
            }
        case "push":
            Button {
                if c.pane == "live" { app.room = .live } else { openConnect() }
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(c.label).font(BP.sans(15, .semibold))
                        Text(c.detail ?? "").font(BP.sans(11)).foregroundStyle(BP.inkMuted).lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
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
    }
}
