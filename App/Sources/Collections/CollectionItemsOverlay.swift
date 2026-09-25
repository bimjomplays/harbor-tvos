import SwiftUI

/// The collection overlay. Owned and community collections follow bp-collection-items.tsx; TMDB
/// follows bp-collection-detail.tsx and TVDB bp-collection.tsx (both inside BpCollectionShell: a
/// faint backdrop behind the header). The viewer's own collections add community-editor.tsx's
/// edits (rename, add titles through search, remove titles) and community-hub's delete; a
/// community collection offers community-hub's "Save to my collections".
struct CollectionItemsOverlay: View {
    let limits: CollectionsModel.Limits
    let onClose: () -> Void
    /// Something changed in "mine" or "community"; the room re-reads that source.
    let onChanged: (String) -> Void
    let onOpen: (CollectionsModel.Item) -> Void
    @State private var card: CollectionsModel.Card
    @State private var loading = false
    @State private var panel: Panel?
    @State private var editing = false
    @State private var confirmDelete = false
    @State private var nameDraft = ""
    @State private var query = ""
    @State private var results: [Meta] = []
    @State private var searching = false

    enum Panel { case rename, add }

    private struct NewItem: Encodable { var id: String; var type: String; var name: String; var poster: String? }
    private struct TvdbDetail: Decodable { var name: String; var overview: String?; var image: String?; @LossyArray var items: [CollectionsModel.Item]; var failed: Bool }

    init(card: CollectionsModel.Card, limits: CollectionsModel.Limits, onClose: @escaping () -> Void,
         onChanged: @escaping (String) -> Void, onOpen: @escaping (CollectionsModel.Item) -> Void) {
        _card = State(initialValue: card)
        _loading = State(initialValue: card.source == "tvdb" && card.items.isEmpty)
        self.limits = limits
        self.onClose = onClose
        self.onChanged = onChanged
        self.onOpen = onOpen
    }

    /// (layout pass) Six 298 pt columns plus gaps (1 963 pt) overran the 1 632 pt page; five fit.
    private static let columns = Array(repeating: GridItem(.fixed(BPTileView.posterWidth), spacing: BP.px(21)), count: 5)
    private var isMine: Bool { card.source == "mine" }
    private var isDetail: Bool { card.source == "tmdb" || card.source == "tvdb" }

    var body: some View {
        ZStack(alignment: .top) {
            BP.void_.opacity(0.97).ignoresSafeArea()
            if isDetail, let backdrop = card.image {
                // bp-collection-shell: the backdrop at 22 % over the top 46 % of the screen, under a scrim.
                RemoteImage(url: backdrop)
                    .frame(maxWidth: .infinity)
                    .frame(height: BP.px(524))
                    .clipped()
                    .opacity(0.22)
                    .overlay(LinearGradient(colors: [BP.void_.opacity(0.55), BP.void_.opacity(0.88), BP.void_], startPoint: .top, endPoint: .bottom))
                    .ignoresSafeArea()
            }
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: BP.px(14)) {
                    header
                    actions
                    if panel == .rename { renamePanel }
                    if panel == .add { addPanel }
                    grid
                    Color.clear.frame(height: BP.px(60))
                }
                .padding(.horizontal, BP.gutter).padding(.top, BP.px(60))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .task { if card.source == "tvdb" && card.items.isEmpty { await loadTvdb() } }
        .onExitCommand {
            if panel != nil { panel = nil }
            else if editing { editing = false }
            else if confirmDelete { confirmDelete = false }
            else { onClose() }
        }
    }

    // bp-collection-items: eyebrow (byline or "My collection"), name, "{count} items", manga note;
    // bp-collection-detail: "Collection", name, "{count} films", overview.
    @ViewBuilder private var header: some View {
        Text(isDetail ? T("Collection") : (card.byline ?? T("My collection")))
            .font(BP.sans(12, .bold)).foregroundStyle(BP.accent).textCase(.uppercase).tracking(1)
        Text(card.name).font(BP.display(32)).foregroundStyle(BP.ink)
        if let line = countLine { Text(line).font(BP.sans(14)).foregroundStyle(BP.inkMuted) }
        if let h = card.hidden, h > 0 {
            Text("\(h) manga items are not shown in Big Picture.").font(BP.sans(12)).foregroundStyle(BP.inkSubtle)
        }
        if let d = card.description, !d.isEmpty {
            Text(d).font(BP.sans(14)).foregroundStyle(BP.inkMuted).lineLimit(3).frame(maxWidth: BP.px(700), alignment: .leading)
        }
    }

    private var countLine: String? {
        switch card.source {
        case "mine", "community": return T("%lld items", card.items.count + (card.hidden ?? 0))
        case "tmdb": return card.items.isEmpty ? nil : T("%lld films", card.items.count)
        default: return nil
        }
    }

    private var emptyText: String {
        switch card.source {
        case "tmdb": return "No films found in this collection."
        case "tvdb": return "Couldn't load this collection right now."
        default: return "This collection is empty."
        }
    }

    private var actions: some View {
        HStack(spacing: BP.px(8)) {
            Button("Close", action: onClose).buttonStyle(BPActionStyle())
            if isMine {
                Button("Rename") { nameDraft = card.name; panel = panel == .rename ? nil : .rename }
                    .buttonStyle(BPActionStyle(primary: panel == .rename)).bpSelected(panel == .rename)
                Button("Add titles") { panel = panel == .add ? nil : .add }
                    .buttonStyle(BPActionStyle(primary: panel == .add)).bpSelected(panel == .add)
                    .disabled(card.items.count >= limits.items && panel != .add)
                Button(editing ? "Done" : "Remove titles") { editing.toggle() }
                    .buttonStyle(BPActionStyle(primary: editing))
                    .disabled(card.items.isEmpty && !editing)
                if confirmDelete {
                    Text("Delete this collection?").font(BP.sans(14, .semibold)).foregroundStyle(BP.danger)
                    Button("Delete") { Task { await deleteCollection() } }.buttonStyle(BPActionStyle(primary: true))
                    Button("Cancel") { confirmDelete = false }.buttonStyle(BPActionStyle())
                } else {
                    Button("Delete") { confirmDelete = true }.buttonStyle(BPActionStyle())
                }
                Text("\(card.items.count) / \(limits.items) titles").font(BP.sans(12)).foregroundStyle(BP.inkSubtle)
            } else if card.source == "community", let handle = card.handle {
                Button { Task { await save(handle: handle) } } label: {
                    Label(card.saved == true ? "Saved to your collections" : "Save to my collections",
                          systemImage: card.saved == true ? "checkmark" : "bookmark")
                }
                .buttonStyle(BPActionStyle(primary: card.saved != true))
                .disabled(card.saved == true)
            }
        }
        .focusSection()
    }

    private var renamePanel: some View {
        HStack(alignment: .bottom, spacing: BP.px(8)) {
            BPField(label: "Name", placeholder: "Name this collection", text: $nameDraft)
                .frame(maxWidth: BP.px(520))
            Button("Save") { Task { await rename() } }
                .buttonStyle(BPActionStyle(primary: true))
                .disabled(nameDraft.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .focusSection()
    }

    // community-editor.tsx search: Select adds a title, or removes it when it is already in.
    private var addPanel: some View {
        VStack(alignment: .leading, spacing: BP.px(10)) {
            HStack(alignment: .bottom, spacing: BP.px(8)) {
                BPField(label: "Titles", placeholder: "Search movies, shows, and manga to add", text: $query)
                    .frame(maxWidth: BP.px(620))
                    .onSubmit { Task { await search() } }
                Button("Search") { Task { await search() } }.buttonStyle(BPActionStyle(primary: true))
            }
            .focusSection()
            if searching { Text("Searching...").font(BP.sans(13)).foregroundStyle(BP.inkSubtle) }
            if !results.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: BP.px(21)) {
                        ForEach(results.uniquedById()) { m in   // (bug pass) unique ids
                            Button { Task { await toggle(m) } } label: {
                                ZStack(alignment: .topTrailing) {
                                    BPTileView(meta: m, shape: .poster)
                                    if contains(m.id) {
                                        Image(systemName: "checkmark.circle.fill")
                                            .font(.system(size: BP.px(22), weight: .bold))
                                            .foregroundStyle(BP.live)
                                            .padding(BP.px(6))
                                            .accessibilityHidden(true)
                                    }
                                }
                            }
                            .buttonStyle(BPTileStyle())
                            // The tick on a title already in the list reads as selected.
                            .bpSelected(contains(m.id))
                        }
                    }
                    .padding(.vertical, BP.px(12))
                }
                .scrollClipDisabled()
                .focusSection()
            }
        }
    }

    @ViewBuilder private var grid: some View {
        if loading && card.items.isEmpty {
            ProgressView().tint(BP.inkMuted)
        } else if card.items.isEmpty {
            BPNote(text: emptyText)
        } else {
            LazyVGrid(columns: Self.columns, alignment: .leading, spacing: BP.px(24)) {
                ForEach(card.items.uniquedById()) { item in   // (bug pass) a list can repeat a title
                    Button {
                        if editing { Task { await removeItem(item) } } else { onOpen(item) }
                    } label: {
                        ZStack(alignment: .topTrailing) {
                            BPTileView(meta: item.meta, shape: .poster)
                            if editing {
                                Image(systemName: "minus.circle.fill")
                                    .font(.system(size: BP.px(22), weight: .bold))
                                    .foregroundStyle(BP.danger)
                                    .padding(BP.px(6))
                                    .accessibilityHidden(true)
                            }
                        }
                    }
                    .buttonStyle(BPTileStyle())
                    // Editing, a press removes the title: upstream's "Remove {name}".
                    .accessibilityLabel(Text(verbatim: editing ? T("Remove %@", item.meta.name) : item.meta.name))
                }
            }
            .padding(.vertical, BP.px(14))
            .focusSection()
        }
    }

    private func contains(_ id: String) -> Bool { card.items.contains { $0.id == id } }

    // MARK: - Engine calls

    @MainActor private func loadTvdb() async {
        loading = true
        defer { loading = false }
        // A failed or empty list shows "Couldn't load this collection right now." (emptyText).
        guard let d: TvdbDetail = try? await HarborEngine.shared.call("collectionsRoom.tvdbDetail", [card.ref, card.name]), !d.failed else { return }
        card.name = d.name
        if let o = d.overview, !o.isEmpty { card.description = o }
        if card.image == nil { card.image = d.image }
        card.items = d.items
    }

    @MainActor private func rename() async {
        let c: CollectionsModel.Card? = try? await HarborEngine.shared.call("collectionsRoom.rename", [card.ref, nameDraft])
        if let c { card = c; onChanged("mine") }
        panel = nil
    }

    @MainActor private func removeItem(_ item: CollectionsModel.Item) async {
        let c: CollectionsModel.Card? = try? await HarborEngine.shared.call("collectionsRoom.removeItem", [card.ref, item.id])
        guard let c else { return }
        card = c
        onChanged("mine")
        if c.items.isEmpty { editing = false }
    }

    @MainActor private func toggle(_ m: Meta) async {
        let c: CollectionsModel.Card?
        if contains(m.id) {
            c = try? await HarborEngine.shared.call("collectionsRoom.removeItem", [card.ref, m.id])
        } else {
            c = try? await HarborEngine.shared.call("collectionsRoom.addItem", [card.ref, NewItem(id: m.id, type: m.type, name: m.name, poster: m.poster)])
        }
        if let c { card = c; onChanged("mine") }
    }

    @MainActor private func search() async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        searching = true
        defer { searching = false }
        let p = ProfilesStore.shared.active
        results = (try? await HarborEngine.shared.call("collectionsRoom.searchTitles", [q, p?.id ?? "default", p?.linked ?? true])) ?? []
    }

    @MainActor private func deleteCollection() async {
        _ = try? await HarborEngine.shared.callJSON("collectionsRoom.remove", [.string(card.ref)])
        onChanged("mine")
        onClose()
    }

    @MainActor private func save(handle: String) async {
        let c: CollectionsModel.Card? = try? await HarborEngine.shared.call("collectionsRoom.saveCommunity", [handle, card.ref])
        if c != nil { card.saved = true; onChanged("community") }
    }
}
