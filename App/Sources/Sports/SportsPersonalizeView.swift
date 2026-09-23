import SwiftUI

/// bp-sports-personalize.tsx, steps 1–2: pick sports, then leagues (teams follow later).
/// "Use popular leagues" takes upstream's HUB_DEFAULTS. Saving writes both stores (engine).
struct SportsPersonalizeView: View {
    @ObservedObject var model: SportsModel
    let dismiss: () -> Void

    struct Catalog: Decodable {
        struct Group: Decodable, Identifiable { var key: String; var label: String; var icon: String?; var id: String { key } }
        struct League: Decodable, Identifiable { var key: String; var tag: String; var group: String; var label: String; var logo: String; var id: String { key } }
        var groups: [Group]; var leagues: [League]; var defaults: [String]; var selected: [String]; var personalized: Bool
    }

    @State private var catalog: Catalog?
    @State private var step = 0
    @State private var groups: Set<String> = []
    @State private var leagues: Set<String> = []
    @State private var saving = false

    var body: some View {
        ZStack {
            BP.canvas.ignoresSafeArea()
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: BP.px(16)) {
                    Text(step == 0 ? "Choose your sports" : "Pick your leagues").font(BP.display(32)).foregroundStyle(BP.ink)
                    if let c = catalog {
                        if step == 0 { groupGrid(c) } else { leagueGrid(c) }
                        HStack(spacing: BP.px(10)) {
                            if step == 0 {
                                Button("Use popular leagues") { leagues = Set(c.defaults); groups = Set(c.leagues.filter { leagues.contains($0.key) }.map(\.group)) }.buttonStyle(BPActionStyle())
                                Button("Next") { step = 1 }.buttonStyle(BPActionStyle(primary: true)).disabled(groups.isEmpty)
                            } else {
                                Button("Back") { step = 0 }.buttonStyle(BPActionStyle())
                                Button(saving ? "Saving…" : "Save") {
                                    saving = true
                                    Task { await model.setLeagues(Array(leagues)); saving = false; dismiss() }
                                }
                                .buttonStyle(BPActionStyle(primary: true)).disabled(saving)
                            }
                            Button("Cancel") { dismiss() }.buttonStyle(BPActionStyle())
                            Text("\(leagues.count) leagues selected").font(BP.sans(12)).foregroundStyle(BP.inkSubtle)
                        }
                        .focusSection()
                    } else {
                        ProgressView().tint(BP.inkMuted)
                    }
                }
                .padding(.horizontal, BP.gutter).padding(.top, BP.px(40)).padding(.bottom, BP.hintHeight + BP.px(40))
            }
        }
        .task {
            if let c: Catalog = try? await HarborEngine.shared.call("sports.catalog", []) {
                catalog = c
                leagues = Set(c.selected)
                groups = Set(c.leagues.filter { leagues.contains($0.key) }.map(\.group))
            }
        }
        .onExitCommand { dismiss() }
    }

    private func groupGrid(_ c: Catalog) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(BP.px(200)), spacing: BP.px(12)), count: 7), spacing: BP.px(12)) {
            ForEach(c.groups) { g in
                Button {
                    if groups.contains(g.key) {
                        groups.remove(g.key)
                        for l in c.leagues where l.group == g.key { leagues.remove(l.key) }
                    } else {
                        groups.insert(g.key)
                        // Toggling a sport on adds its first 3 leagues (bp-sports-personalize.tsx:122-130).
                        for l in c.leagues.filter({ $0.group == g.key }).prefix(3) { leagues.insert(l.key) }
                    }
                } label: {
                    VStack(spacing: BP.px(6)) {
                        Text(g.icon ?? "").font(.system(size: BP.px(28)))
                        Text(g.label).font(BP.sans(14, .semibold)).foregroundStyle(BP.ink).lineLimit(1)
                    }
                    .frame(width: BP.px(200), height: BP.px(100))
                    .background(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).fill(groups.contains(g.key) ? BP.on : BP.panel2))
                    .overlay(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).strokeBorder(groups.contains(g.key) ? BP.ink : BP.edge2, lineWidth: 1))
                }
                .buttonStyle(BPTileStyle(radius: BP.rSM))
            }
        }
        .focusSection()
    }

    private func leagueGrid(_ c: Catalog) -> some View {
        VStack(alignment: .leading, spacing: BP.px(14)) {
            ForEach(c.groups.filter { groups.contains($0.key) }) { g in
                VStack(alignment: .leading, spacing: BP.px(6)) {
                    Text(g.label).font(BP.sans(15, .semibold)).foregroundStyle(BP.inkMuted)
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(BP.px(280)), spacing: BP.px(10)), count: 5), spacing: BP.px(10)) {
                        ForEach(c.leagues.filter { $0.group == g.key }) { l in
                            Button {
                                if leagues.contains(l.key) { leagues.remove(l.key) } else { leagues.insert(l.key) }
                            } label: {
                                HStack(spacing: BP.px(8)) {
                                    RemoteImage(url: l.logo.isEmpty ? nil : l.logo, contentMode: .fit).frame(width: BP.px(22), height: BP.px(22))
                                    Text(l.label).font(BP.sans(13, .semibold)).foregroundStyle(BP.ink).lineLimit(1)
                                    Spacer()
                                    if leagues.contains(l.key) { Image(systemName: "checkmark").font(.system(size: BP.px(11), weight: .bold)).foregroundStyle(BP.ink) }
                                }
                                .padding(.horizontal, BP.px(10))
                                .frame(width: BP.px(280), height: BP.px(44), alignment: .leading)
                                .background(RoundedRectangle(cornerRadius: BP.rXS, style: .continuous).fill(leagues.contains(l.key) ? BP.on : BP.panel2))
                            }
                            .buttonStyle(BPTileStyle())
                        }
                    }
                }
            }
        }
        .focusSection()
    }
}
