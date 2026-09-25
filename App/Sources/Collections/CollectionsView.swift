import SwiftUI

/// Collections room (bp-collections.tsx): source chips (bp-collection-steps BP_COLLECTION_SOURCES:
/// All / Mine / Community / TMDB / TVDB), a 16:9 card grid, and an in-place overlay:
/// bp-collection-items for owned and community collections, bp-collection-detail for TMDB and
/// bp-collection.tsx for TVDB lists. The viewer's own collections are editable from the TV
/// (community-hub.tsx / community-editor.tsx: new, rename, add and remove titles, delete).
@MainActor
final class CollectionsModel: ObservableObject {
    struct Item: Decodable, Identifiable {
        var id: String; var type: String; var name: String; var poster: String?
        var meta: Meta {
            Meta(id: id, type: type, name: name, poster: poster, background: nil, logo: nil, description: nil, releaseInfo: nil, releaseDate: nil, inTheaters: nil, imdbRating: nil, tmdbScore: nil, runtime: nil, genres: nil, adult: nil, isCollection: nil, providerBadge: nil, videos: nil)
        }
    }
    struct Card: Decodable, Identifiable {
        var key: String; var source: String
        /// The collection's own id (uuid for mine/community, TMDB/TVDB id otherwise).
        var ref: String
        var handle: String?; var saved: Bool?
        var name: String; var image: String?; var count: Int?; var byline: String?; var description: String?; var items: [Item]
        var hidden: Int?
        var id: String { key }
    }
    struct All: Decodable { var mine: [Card]; var community: [Card] }
    struct Limits: Decodable { var collections: Int; var items: Int }

    @Published private(set) var mine: [Card] = []
    @Published private(set) var community: [Card] = []
    @Published private(set) var loading = false
    @Published private(set) var loaded = false
    @Published private(set) var failed: String?
    @Published private(set) var source = "all"
    @Published private(set) var limits = Limits(collections: 24, items: 100)
    /// bp-collection-steps "curated": TMDB's franchise catalog, a page at a time, by category.
    @Published private(set) var tmdb: [Card] = []
    @Published private(set) var tmdbDone = false
    @Published private(set) var tmdbLoading = false
    @Published var category = "All"
    @Published private(set) var categories: [String] = ["All"]
    private var tmdbPage = 0
    /// bp-collection-steps stepTvdb: TVDB lists through Harbor's proxy (no key). "all" stops at
    /// ten seed names (tvdbCapped → "See every TVDB list"); the TVDB source walks them all.
    @Published private(set) var tvdb: [Card] = []
    @Published private(set) var tvdbDone = false
    @Published private(set) var tvdbLoading = false
    @Published private(set) var tvdbFailed = false
    @Published private(set) var tvdbCapped = false
    private var tvdbNext = 0
    private(set) var tvdbScope = "all"
    private var tvdbRun = 0
    var hasKey: Bool { !SettingsBridge.shared.slice.tmdbKey.isEmpty }

    func load() async {
        loading = true; defer { loading = false; loaded = true }
        do {
            let a: All = try await HarborEngine.shared.call("collectionsRoom.all", [])
            mine = a.mine; community = a.community
        } catch { failed = error.localizedDescription }
        categories = (try? await HarborEngine.shared.call("collectionsRoom.categories", [])) ?? ["All"]
        if let l: Limits = try? await HarborEngine.shared.call("collectionsRoom.limits", []) { limits = l }
        if hasKey { await loadTmdb(reset: true) } else { await loadTvdb(reset: true) }
    }

    func reloadMine() async {
        if let m: [Card] = try? await HarborEngine.shared.call("collectionsRoom.mine", []) { mine = m }
    }

    func reloadCommunity() async {
        if let c: [Card] = try? await HarborEngine.shared.call("collectionsRoom.community", []) { community = c }
    }

    func set(source s: String) {
        source = s
        Task {
            switch s {
            case "tvdb": await loadTvdb(reset: false)
            case "all": if curatedFinished || tvdbScope != "all" { await loadTvdb(reset: false) }
            case "tmdb": if tmdb.isEmpty && hasKey { await loadTmdb(reset: false) }
            default: break
            }
        }
    }

    func loadTmdb(reset: Bool) async {
        if reset { tmdb = []; tmdbPage = 0; tmdbDone = false }
        guard !tmdbLoading, !tmdbDone, hasKey else { return }
        tmdbLoading = true; defer { tmdbLoading = false }
        struct Page: Decodable { var cards: [Card]; var done: Bool }
        let p = ProfilesStore.shared.active
        let want = category
        let got: Page? = try? await HarborEngine.shared.call("collectionsRoom.tmdb", [p?.id ?? "default", p?.linked ?? true, category, tmdbPage + 1])
        // (bug pass) A category chip pressed while this page loaded reset the list, and its own load
        // bounced off tmdbLoading: load the new category now instead of leaving the grid empty (and a
        // failed stale page must not mark the new category done).
        guard want == category else { tmdbLoading = false; await loadTmdb(reset: false); return }
        if let page = got {
            tmdbPage += 1
            tmdb = (tmdb + page.cards).uniquedById()   // (bug pass) repeats inside a page too
            tmdbDone = page.done
        } else { tmdbDone = true }
    }

    /// use-bp-collection-feed pull: up to three steps until one adds a card (STEPS_PER_PULL).
    func loadTvdb(reset: Bool) async {
        let scope = source == "tvdb" ? "tvdb" : "all"
        if reset || scope != tvdbScope {
            tvdbRun += 1
            tvdb = []; tvdbNext = 0; tvdbDone = false; tvdbFailed = false; tvdbCapped = false; tvdbLoading = false
            tvdbScope = scope
        }
        guard !tvdbLoading, !tvdbDone else { return }
        tvdbLoading = true
        let run = tvdbRun
        struct Page: Decodable { var cards: [Card]; var next: Int; var done: Bool; var failed: Bool; var capped: Bool }
        var added = 0
        var steps = 0
        while added == 0 && steps < 3 && !tvdbDone {
            steps += 1
            let page: Page? = try? await HarborEngine.shared.call("collectionsRoom.tvdb", [scope, tvdbNext])
            guard run == tvdbRun else { return }
            guard let page else { tvdbDone = true; tvdbFailed = true; break }
            let known = Set(tvdb.map(\.key))
            let fresh = page.cards.filter { !known.contains($0.key) }
            tvdb += fresh
            added += fresh.count
            tvdbNext = page.next; tvdbDone = page.done; tvdbFailed = page.failed; tvdbCapped = page.capped
        }
        tvdbLoading = false
    }

    func set(category c: String) { category = c; Task { await loadTmdb(reset: true) } }

    /// The last card appeared: pull the next page of whichever source is still open.
    func more() async {
        switch source {
        case "tmdb": await loadTmdb(reset: false)
        case "tvdb": await loadTvdb(reset: false)
        case "all":
            if curatedFinished { await loadTvdb(reset: false) } else { await loadTmdb(reset: false) }
        default: break
        }
    }

    var cards: [Card] {
        switch source {
        case "mine": return mine
        case "community": return community
        case "tmdb": return tmdb
        case "tvdb": return tvdb
        default:
            // bp-collection-steps PHASES.all: community, curated, then TVDB (ten names).
            let curated = category == "All" ? tmdb : []
            let lists = curatedFinished && tvdbScope == "all" ? tvdb : []
            var seen = Set<String>()
            return (mine + community + curated + lists).filter { seen.insert($0.key).inserted }
        }
    }

    var busy: Bool { loading || tmdbLoading || tvdbLoading }

    /// All's curated phase is over (or not in play), so the TVDB phase may show and pull.
    private var curatedFinished: Bool { !hasKey || tmdbDone || category != "All" }

    /// "See every TVDB list" (bp-collections.tsx) after the capped TVDB run in All.
    var showAllTvdb: Bool { source == "all" && tvdbScope == "all" && tvdbCapped && !cards.filter { $0.source == "tvdb" }.isEmpty }

    var done: Bool {
        switch source {
        case "mine", "community": return loaded
        case "tmdb": return !hasKey || tmdbDone
        case "tvdb": return tvdbDone
        default: return loaded && curatedFinished && tvdbScope == "all" && tvdbDone
        }
    }

    /// bp-collections.tsx endMessage.
    var endMessage: String {
        let empty = cards.isEmpty
        if empty {
            switch source {
            case "mine": return "You have not made a collection yet."
            case "community": return "Nobody has shared a collection yet."
            case "tvdb" where tvdbFailed: return "TVDB lists are unavailable right now."
            default: return "Nothing to show here yet."
            }
        }
        switch source {
        case "tvdb": return tvdbFailed ? "That's every TVDB list we could reach. Some are unavailable right now." : "That's every TVDB list we could find."
        case "community": return "That's every shared collection right now."
        case "mine": return "That's all of your collections."
        case "all" where tvdbFailed: return "That's everything we could reach. Some sources are unavailable right now."
        default: return "That's every collection TMDB knows about."
        }
    }

    /// community-hub "New collection".
    func create(name: String) async -> Card? {
        let c: Card? = try? await HarborEngine.shared.call("collectionsRoom.create", [name])
        await reloadMine()
        return c
    }
}

struct CollectionsView: View {
    @StateObject private var model = CollectionsModel()
    @State private var open: CollectionsModel.Card?
    @State private var detail: Meta?
    @State private var naming = false
    @State private var nameDraft = ""

    private static let sources: [(String, String)] = [("all", "All"), ("mine", "Mine"), ("community", "Community"), ("tmdb", "TMDB"), ("tvdb", "TVDB")]
    private static let columns = Array(repeating: GridItem(.fixed(BP.px(240)), spacing: BP.px(16)), count: 6)

    var body: some View {
        ZStack(alignment: .topLeading) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: BP.px(16)) {
                    Text("Collections").font(BP.display(36)).foregroundStyle(BP.ink)
                    sourceRow
                    if naming { nameRow }
                    if model.source == "tmdb" {
                        // bp-collection-steps categories: Sagas, Superheroes, Action…
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: BP.px(8)) {
                                ForEach(model.categories, id: \.self) { c in Button(c) { model.set(category: c) }.buttonStyle(BPActionStyle(primary: model.category == c)) }
                            }
                            .padding(.vertical, BP.px(4))
                        }
                        .scrollClipDisabled()
                        .focusSection()
                        if !model.hasKey { BPNote(text: "TMDB collections need a TMDB key. Add one in Settings.") }
                    }
                    if model.busy && model.cards.isEmpty { ProgressView().tint(BP.inkMuted) }
                    if let f = model.failed { BPNote(text: f, tone: BP.danger) }
                    LazyVGrid(columns: Self.columns, alignment: .leading, spacing: BP.px(20)) {
                        ForEach(model.cards) { c in
                            Button { open = c } label: { CollectionCardView(card: c) }
                                .onAppear { if c.key == model.cards.last?.key { Task { await model.more() } } }
                                .buttonStyle(BPTileStyle())
                                .accessibilityIdentifier("collection-\(c.key)")
                        }
                        if model.showAllTvdb {
                            Button { model.set(source: "tvdb") } label: { CollectionMoreCard(label: T("See every TVDB list")) }
                                .buttonStyle(BPTileStyle())
                        }
                    }
                    .padding(.vertical, BP.px(14))
                    .focusSection()
                    if model.busy && !model.cards.isEmpty {
                        HStack(spacing: BP.px(8)) {
                            ProgressView().tint(BP.inkSubtle)
                            Text("Loading more collections...").font(BP.sans(13, .semibold)).foregroundStyle(BP.inkSubtle)
                        }
                        .frame(maxWidth: .infinity)
                    } else if model.done {
                        Text(T(model.endMessage)).font(BP.sans(13)).foregroundStyle(BP.inkSubtle).frame(maxWidth: .infinity)
                    }
                    Color.clear.frame(height: BP.hintHeight + BP.px(40))
                }
                .padding(.horizontal, BP.gutter).padding(.top, BP.barHeight + BP.px(20))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let c = open {
                CollectionItemsOverlay(card: c, limits: model.limits, onClose: {
                    open = nil
                    Task { await model.reloadMine() }
                }, onChanged: { source in
                    Task { if source == "community" { await model.reloadCommunity() }; await model.reloadMine() }
                }, onOpen: { item in detail = item.meta })
                .id(c.key)
                .transition(.opacity)
            }
        }
        // (bug pass) `.task` re-runs whenever a title's cover closes (and on every return to the
        // tab): a full load reset the TMDB / TVDB grid each time. Later passes refresh "Mine" only.
        .task { if model.loaded || model.loading { await model.reloadMine() } else { await model.load() } }
        .fullScreenCover(item: $detail) { m in DetailView(meta: m) }
        .animation(BP.easeFast, value: open?.key)
    }

    private var sourceRow: some View {
        HStack(spacing: BP.px(8)) {
            ForEach(Self.sources, id: \.0) { key, label in
                Button(T(label)) { model.set(source: key) }.buttonStyle(BPActionStyle(primary: model.source == key))
            }
            if model.source == "all" || model.source == "mine" {
                // community-hub.tsx: "New collection", with the "{n} / {max}" count beside it.
                Button { nameDraft = ""; naming.toggle() } label: { Label("New collection", systemImage: "plus") }
                    .buttonStyle(BPActionStyle(primary: naming))
                    .disabled(model.mine.count >= model.limits.collections)
                Text("\(model.mine.count) / \(model.limits.collections)").font(BP.sans(12)).foregroundStyle(BP.inkSubtle)
            }
            Text("\(model.cards.count) collections").font(BP.sans(13)).foregroundStyle(BP.inkMuted).padding(.leading, BP.px(8))
        }
        .focusSection()
    }

    private var nameRow: some View {
        HStack(alignment: .bottom, spacing: BP.px(8)) {
            BPField(label: "Name", placeholder: "Name this collection", text: $nameDraft)
                .frame(maxWidth: BP.px(520))
            Button("Create") {
                let name = nameDraft
                Task {
                    if let c = await model.create(name: name) { naming = false; open = c }
                }
            }
            .buttonStyle(BPActionStyle(primary: true))
            Button("Cancel") { naming = false }.buttonStyle(BPActionStyle())
        }
        .focusSection()
    }
}

struct CollectionCardView: View {
    let card: CollectionsModel.Card

    /// bp-collection-card.tsx metaLine: byline · "{count} items" (owned) / "{count} films" (TMDB) / "TVDB list".
    private var line: String {
        var bits: [String] = []
        if let b = card.byline, !b.isEmpty { bits.append(b) }
        if card.source == "mine" || card.source == "community" {
            if let n = card.count { bits.append(T("%lld items", n)) }
        } else if let n = card.count {
            bits.append(T("%lld films", n))
        } else if card.source == "tvdb" {
            bits.append(T("TVDB list"))
        } else {
            bits.append(T("Collection"))
        }
        return bits.joined(separator: "  ·  ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: BP.px(6)) {
            ZStack(alignment: .bottomLeading) {
                RemoteImage(url: card.image)
                LinearGradient(colors: [.clear, BP.void_.opacity(0.85)], startPoint: .center, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 2) {
                    Text(card.name).font(BP.sans(14, .bold)).foregroundStyle(BP.ink).lineLimit(1)
                    Text(line).font(BP.sans(11)).foregroundStyle(BP.inkMuted).lineLimit(1)
                }
                .padding(BP.px(10))
            }
            .frame(width: BP.px(240), height: BP.px(135))
            .clipShape(RoundedRectangle(cornerRadius: BP.rXS, style: .continuous))
        }
    }
}

/// bp-collection-card.tsx BpCollectionMoreCard.
struct CollectionMoreCard: View {
    let label: String
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: BP.rXS, style: .continuous).fill(BP.panel2)
            VStack(spacing: BP.px(8)) {
                Image(systemName: "arrow.right.circle").font(.system(size: BP.px(26), weight: .semibold)).foregroundStyle(BP.inkMuted)
                Text(label).font(BP.sans(13, .semibold)).foregroundStyle(BP.ink).multilineTextAlignment(.center)
            }
            .padding(BP.px(12))
        }
        .frame(width: BP.px(240), height: BP.px(135))
    }
}
