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

    @Published private(set) var categories: [Category] = []
    @Published private(set) var controls: [Control] = []
    @Published var active: String = "picture"

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
        await loadControls()
    }

    func loadControls() async {
        let p = profile
        controls = (try? await HarborEngine.shared.call("settingsRoom.controls", [active, p.id, p.linked])) ?? []
    }

    func select(_ id: String) { active = id; Task { await loadControls() } }

    func commit(_ control: String, _ value: String) async {
        let p = profile
        if let c: Committed = try? await HarborEngine.shared.call("settingsRoom.commit", [control, value, p.id, p.linked]) {
            SettingsBridge.shared.sportsDeclined = !c.sportsShown
        }
        await SettingsBridge.shared.load()
        await load()
    }
}

struct BPSettingsView: View {
    @StateObject private var model = BPSettingsModel()
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var account: AccountStore
    let openConnect: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: BP.px(30)) {
            VStack(alignment: .leading, spacing: BP.px(6)) {
                ForEach(model.categories) { c in
                    Button { model.select(c.id) } label: {
                        HStack(spacing: BP.px(10)) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(c.label).font(BP.sans(16, .bold)).foregroundStyle(BP.ink).lineLimit(1)
                                Text(c.summary).font(BP.sans(12, .medium)).foregroundStyle(BP.ink.opacity(0.65)).lineLimit(1)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.system(size: BP.px(12), weight: .bold)).foregroundStyle(BP.ink.opacity(0.55))
                        }
                        .padding(.horizontal, BP.px(14))
                        .frame(width: BP.px(330), height: BP.px(54), alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).fill(model.active == c.id ? BP.on : .clear))
                    }
                    .buttonStyle(BPTileStyle(radius: BP.rSM))
                }
            }
            .focusSection()
            VStack(alignment: .leading, spacing: BP.px(14)) {
                ForEach(model.controls) { c in controlRow(c) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .focusSection()
        }
        .task { await model.load() }
    }

    @ViewBuilder private func controlRow(_ c: BPSettingsModel.Control) -> some View {
        switch c.kind {
        case "options":
            VStack(alignment: .leading, spacing: BP.px(6)) {
                label(c.label)
                let opts = c.options ?? []
                if c.columns == 2 {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: BP.px(6)) {
                        ForEach(opts) { o in cell(o.label, on: c.value == o.value, letter: c.letter == true ? o.value : nil) { Task { await model.commit(c.id, o.value) } } }
                    }
                    .frame(maxWidth: BP.px(620))
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: BP.px(6)) {
                            ForEach(opts) { o in cell(o.label, on: c.value == o.value, letter: c.letter == true ? o.value : nil) { Task { await model.commit(c.id, o.value) } } }
                        }
                    }
                }
            }
        case "multi":
            VStack(alignment: .leading, spacing: BP.px(6)) {
                label(c.label)
                let items = c.items ?? []
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(BP.px(150)), spacing: BP.px(6)), count: 6), spacing: BP.px(6)) {
                    ForEach(items) { i in
                        Button { Task { await model.commit(c.id, i.value) } } label: {
                            HStack(spacing: BP.px(6)) {
                                if let tint = i.tint, c.render == "logo" { Circle().fill(Color(css: tint) ?? BP.ink).frame(width: BP.px(8), height: BP.px(8)) }
                                Text(i.label).font(BP.sans(13, i.on ? .bold : .semibold)).lineLimit(1)
                                if i.rank > 0 { Text("\(i.rank)").font(BP.sans(10, .bold)).foregroundStyle(BP.inkSubtle) }
                            }
                            .foregroundStyle(i.on ? BP.ink : BP.inkSubtle)
                            .frame(width: BP.px(150), height: BP.px(44))
                            .background(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).fill(i.on ? BP.on : BP.panel))
                            .overlay(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).strokeBorder(i.on ? .clear : BP.edge, lineWidth: 1))
                        }
                        .buttonStyle(BPTileStyle(radius: BP.rSM))
                    }
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
                .frame(maxWidth: BP.px(620), alignment: .leading)
            }
            .buttonStyle(BPActionStyle())
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
            }
        default:
            EmptyView()
        }
    }

    private func label(_ text: String) -> some View {
        Text(text.uppercased()).font(BP.sans(11, .bold)).tracking(1.5).foregroundStyle(BP.inkSubtle)
    }

    private func cell(_ text: String, on: Bool, letter: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(letter.map { _ in text.replacingOccurrences(of: "px", with: "") } ?? text)
                .font(letter.map { BP.sans(CGFloat(Double($0) ?? 15) * 0.55, .bold) } ?? BP.sans(14, on ? .bold : .semibold))
                .foregroundStyle(on ? BP.ink : BP.inkSubtle)
                .padding(.horizontal, BP.px(16))
                .frame(minWidth: BP.px(80), minHeight: BP.px(46))
                .background(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).fill(on ? BP.on : BP.panel))
                .overlay(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).strokeBorder(on ? .clear : BP.edge, lineWidth: 1))
        }
        .buttonStyle(BPTileStyle(radius: BP.rSM))
    }
}
