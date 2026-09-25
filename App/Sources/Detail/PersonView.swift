import SwiftUI

/// Person page (bp-person.tsx): portrait, name, department, facts, biography, awards; then
/// Known For, IMDb Top, Frequent Collaborators, and the filmography sections with Sort and
/// Rating filter rows. Needs a TMDB key.
@MainActor
final class PersonModel: ObservableObject {
    struct Person: Decodable { var id: Int; var name: String; var department: String; var portrait: String?; var imdbId: String?; var biography: String; var facts: [String] }
    struct Collaborator: Decodable, Identifiable { var id: Int; var name: String; var portrait: String?; var role: String?; var titles: Int }
    struct Award: Decodable, Identifiable { var type: String; var wins: Int; var nominations: Int; var id: String { type } }
    struct Section: Decodable, Identifiable { var id: String; var title: String; @LossyArray var metas: [Meta] }   // (bug pass 2) lossy
    struct Page: Decodable {
        var hasKey: Bool; var person: Person?
        var knownFor: [Meta]?; var topRated: [Meta]?; var collaborators: [Collaborator]?; var awards: [Award]?
        var sections: [Section]?; var total: Int?; var shownTotal: Int?; var sort: String?; var minRating: Int?
    }

    let personId: Int
    @Published private(set) var page: Page?
    @Published private(set) var loading = false
    @Published var sort = "popularity"
    @Published var minRating = 0
    private var unsubscribe: (() -> Void)?

    init(personId: Int) { self.personId = personId }
    deinit { unsubscribe?() }

    func load() async {
        loading = true; defer { loading = false }
        if unsubscribe == nil {
            unsubscribe = HarborEngine.shared.onEvent { [weak self] type, detail in
                guard type == "harbor:person-updated", let self, (try? detail?.decode(Ping.self))?.personId == self.personId else { return }
                Task { await self.load() }
            }
        }
        let p = ProfilesStore.shared.active
        if let pg: Page = try? await HarborEngine.shared.call("personRoom.page", [personId, p?.id ?? "default", p?.linked ?? true, sort, minRating]) {
            page = pg
            await CardMarksStore.shared.refresh((pg.knownFor ?? []) + (pg.sections ?? []).flatMap(\.metas))
        }
    }
    private struct Ping: Decodable { var personId: Int }
}

struct PersonView: View {
    @StateObject private var model: PersonModel
    let name: String
    @State private var detail: Meta?
    @State private var other: PersonModel.Collaborator?
    @State private var bioExpanded = false
    @Environment(\.dismiss) private var dismiss

    /// Set when the page is drawn inside the player (PlayerXRay.swift, xray-overlay.tsx CastModal
    /// without onOpenDetail/onPlay): Back and Menu call it instead of dismissing the presentation
    /// (the player's own cover), and titles and collaborators stay put, because a fullScreenCover
    /// over the player makes it disappear (PlaybackState, the torrent's owner).
    let onClose: (() -> Void)?

    init(personId: Int, name: String, onClose: (() -> Void)? = nil) {
        _model = StateObject(wrappedValue: PersonModel(personId: personId)); self.name = name; self.onClose = onClose
    }

    private func close() { if let onClose { onClose() } else { dismiss() } }
    private func openTitle(_ m: Meta) { if onClose == nil { detail = m } }

    var body: some View {
        ZStack(alignment: .topLeading) {
            BPAmbientBackground()
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: BP.px(24)) {
                    hero.padding(.horizontal, BP.gutter)
                    if let pg = model.page {
                        if !pg.hasKey { BPNote(text: "Add a TMDB key in Settings to see filmographies.").padding(.horizontal, BP.gutter) }
                        if let k = pg.knownFor, !k.isEmpty { BPRowView(row: BrowseRow(key: "knownFor", title: "Known For", metas: k), onFocus: { _ in }, onSelect: { openTitle($0) }) }
                        if let t = pg.topRated, !t.isEmpty { BPRowView(row: BrowseRow(key: "topRated", title: "IMDb Top", metas: t), onFocus: { _ in }, onSelect: { openTitle($0) }) }
                        if let c = pg.collaborators, c.count >= 3 { collaborators(c) }
                        if let secs = pg.sections, !secs.isEmpty {
                            VStack(alignment: .leading, spacing: BP.px(10)) {
                                Text("Filmography").font(BP.display(24)).foregroundStyle(BP.ink)
                                filterRow("Sort", [("popularity", "Popularity"), ("rating", "Rating"), ("newest", "Newest")], active: model.sort, trailing: "\(pg.shownTotal ?? 0) of \(pg.total ?? 0)") { model.sort = $0; Task { await model.load() } }
                                filterRow("Rating", [("0", "Any rating"), ("6", "Rated 6+"), ("7", "Rated 7+"), ("8", "Rated 8+")], active: String(model.minRating), trailing: nil) { model.minRating = Int($0) ?? 0; Task { await model.load() } }
                            }
                            .padding(.horizontal, BP.gutter)
                            ForEach(secs) { s in BPRowView(row: BrowseRow(key: "film:\(s.id)", title: s.title, metas: s.metas), onFocus: { _ in }, onSelect: { openTitle($0) }) }
                        }
                    } else if model.loading {
                        ProgressView().tint(BP.inkMuted).padding(.horizontal, BP.gutter)
                    }
                    Color.clear.frame(height: BP.hintHeight + BP.px(40))
                }
                .padding(.top, BP.px(40))
            }
        }
        .task { await model.load() }
        .onExitCommand { close() }
        .fullScreenCover(item: $detail) { m in DetailView(meta: m) }
        .fullScreenCover(item: $other) { c in PersonView(personId: c.id, name: c.name) }
    }

    private var hero: some View {
        HStack(alignment: .top, spacing: BP.px(24)) {
            ZStack {
                Circle().fill(BP.panel2)
                if let p = model.page?.person?.portrait { RemoteImage(url: p).clipShape(Circle()) } else { Image(systemName: "person.fill").font(.system(size: BP.px(48))).foregroundStyle(BP.inkSubtle) }
            }
            .frame(width: BP.px(160), height: BP.px(160))
            VStack(alignment: .leading, spacing: BP.px(8)) {
                Text(model.page?.person?.name ?? name).font(BP.display(40)).foregroundStyle(BP.ink)
                if let p = model.page?.person {
                    Text(([p.department] + p.facts).filter { !$0.isEmpty }.joined(separator: " · ")).font(BP.sans(14, .medium)).foregroundStyle(BP.inkMuted)
                    if let a = model.page?.awards, !a.isEmpty {
                        Text(a.prefix(4).map { "\($0.type.replacingOccurrences(of: "_", with: " ").capitalized): \($0.wins) win\($0.wins == 1 ? "" : "s"), \($0.nominations) nom\($0.nominations == 1 ? "" : "s")" }.joined(separator: " · "))
                            .font(BP.sans(12)).foregroundStyle(BP.inkSubtle).lineLimit(1)
                    }
                    if !p.biography.isEmpty {
                        Button { bioExpanded.toggle() } label: {
                            Text(p.biography).font(BP.sans(13)).foregroundStyle(BP.inkMuted).lineSpacing(4).lineLimit(bioExpanded ? nil : 4).frame(maxWidth: BP.px(760), alignment: .leading)
                        }
                        .buttonStyle(.plain)
                    }
                }
                Button { close() } label: { Label("Back", systemImage: "chevron.left") }.buttonStyle(BPActionStyle())
            }
        }
        .focusSection()
    }

    // bp-collaborators: round portraits with the shared-title count and role.
    private func collaborators(_ people: [PersonModel.Collaborator]) -> some View {
        VStack(alignment: .leading, spacing: BP.px(10)) {
            Text("Frequent Collaborators").font(BP.sans(19, .bold)).foregroundStyle(BP.ink).padding(.horizontal, BP.gutter)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: BP.trackGap) {
                    ForEach(people.prefix(18)) { c in
                        Button { if onClose == nil { other = c } } label: {
                            VStack(spacing: BP.px(8)) {
                                ZStack {
                                    Circle().fill(BP.panel2)
                                    if let p = c.portrait { RemoteImage(url: p).clipShape(Circle()) } else { Image(systemName: "person.fill").font(.system(size: BP.px(30))).foregroundStyle(BP.inkSubtle) }
                                }
                                .frame(width: BP.px(110), height: BP.px(110))
                                Text(c.name).font(BP.sans(12, .semibold)).foregroundStyle(BP.ink).lineLimit(1)
                                Text("\(c.titles) titles" + (c.role.map { " · \($0)" } ?? "")).font(BP.sans(10)).foregroundStyle(BP.inkSubtle).lineLimit(1)
                            }
                            .frame(width: BP.px(130))
                        }
                        .buttonStyle(BPTileStyle(radius: BP.px(55)))
                    }
                }
                .padding(.horizontal, BP.gutter).padding(.vertical, BP.px(14))
            }
            .scrollClipDisabled()
        }
        .focusSection()
    }

    private func filterRow(_ heading: String, _ options: [(String, String)], active: String, trailing: String?, pick: @escaping (String) -> Void) -> some View {
        HStack(spacing: BP.px(8)) {
            Text(heading.uppercased()).font(BP.sans(11, .bold)).tracking(1.5).foregroundStyle(BP.inkSubtle).frame(width: BP.px(80), alignment: .leading)
            ForEach(options, id: \.0) { o in Button(o.1) { pick(o.0) }.buttonStyle(BPActionStyle(primary: active == o.0)) }
            if let trailing { Text(trailing).font(BP.sans(12)).foregroundStyle(BP.inkSubtle).padding(.leading, BP.px(8)) }
        }
        .focusSection()
    }
}
