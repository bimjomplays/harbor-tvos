import SwiftUI

/// Collections room (bp-collections.tsx, first slice): source chips, a 16:9 card grid,
/// and an in-place items overlay. Community + this device's lists; TMDB/TVDB sources later.
@MainActor
final class CollectionsModel: ObservableObject {
    struct Item: Decodable, Identifiable { var id: String; var type: String; var name: String; var poster: String? }
    struct Card: Decodable, Identifiable {
        var key: String; var source: String; var name: String; var image: String?; var count: Int; var byline: String?; var description: String?; var items: [Item]
        var hidden: Int?
        var id: String { key }
    }
    struct All: Decodable { var mine: [Card]; var community: [Card] }

    @Published private(set) var mine: [Card] = []
    @Published private(set) var community: [Card] = []
    @Published private(set) var loading = false
    @Published private(set) var failed: String?
    @Published var source = "all"

    func load() async {
        loading = true; defer { loading = false }
        do {
            let a: All = try await HarborEngine.shared.call("collectionsRoom.all", [])
            mine = a.mine; community = a.community
        } catch { failed = error.localizedDescription }
    }

    var cards: [Card] {
        switch source {
        case "mine": return mine
        case "community": return community
        default: return mine + community
        }
    }
}

struct CollectionsView: View {
    @StateObject private var model = CollectionsModel()
    @State private var open: CollectionsModel.Card?
    @State private var detail: Meta?

    private static let columns = Array(repeating: GridItem(.fixed(BP.px(240)), spacing: BP.px(16)), count: 6)

    var body: some View {
        ZStack(alignment: .topLeading) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: BP.px(16)) {
                    Text("Collections").font(BP.display(36)).foregroundStyle(BP.ink)
                    HStack(spacing: BP.px(8)) {
                        ForEach([("all", "All"), ("mine", "Mine"), ("community", "Community")], id: \.0) { key, label in
                            Button(label) { model.source = key }.buttonStyle(BPActionStyle(primary: model.source == key))
                        }
                        Text("\(model.cards.count) collections").font(BP.sans(13)).foregroundStyle(BP.inkMuted).padding(.leading, BP.px(8))
                    }
                    .focusSection()
                    if model.loading && model.cards.isEmpty { ProgressView().tint(BP.inkMuted) }
                    if let f = model.failed { BPNote(text: f, tone: BP.danger) }
                    if !model.loading && model.cards.isEmpty {
                        BPNote(text: model.source == "mine" ? "No collections on this device yet. Make some in Harbor on your computer; they sync through your account later." : "Nothing here yet.")
                    }
                    LazyVGrid(columns: Self.columns, alignment: .leading, spacing: BP.px(20)) {
                        ForEach(model.cards) { c in
                            Button { open = c } label: { CollectionCardView(card: c) }
                                .buttonStyle(BPTileStyle())
                                .accessibilityIdentifier("collection-\(c.key)")
                        }
                    }
                    .padding(.vertical, BP.px(14))
                    .focusSection()
                    Color.clear.frame(height: BP.hintHeight + BP.px(40))
                }
                .padding(.horizontal, BP.gutter).padding(.top, BP.barHeight + BP.px(20))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let c = open {
                CollectionItemsOverlay(card: c, onClose: { open = nil }) { item in
                    detail = Meta(id: item.id, type: item.type, name: item.name, poster: item.poster, background: nil, logo: nil, description: nil, releaseInfo: nil, releaseDate: nil, inTheaters: nil, imdbRating: nil, tmdbScore: nil, runtime: nil, genres: nil, adult: nil, isCollection: nil, providerBadge: nil, videos: nil)
                }
                .transition(.opacity)
            }
        }
        .task { await model.load() }
        .fullScreenCover(item: $detail) { m in DetailView(meta: m) }
        .animation(BP.easeFast, value: open?.key)
    }
}

struct CollectionCardView: View {
    let card: CollectionsModel.Card
    var body: some View {
        VStack(alignment: .leading, spacing: BP.px(6)) {
            ZStack(alignment: .bottomLeading) {
                RemoteImage(url: card.image)
                LinearGradient(colors: [.clear, BP.void_.opacity(0.85)], startPoint: .center, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 2) {
                    Text(card.name).font(BP.sans(14, .bold)).foregroundStyle(BP.ink).lineLimit(1)
                    Text("\(card.count) titles" + (card.byline.map { " · \($0)" } ?? "")).font(BP.sans(11)).foregroundStyle(BP.inkMuted).lineLimit(1)
                }
                .padding(BP.px(10))
            }
            .frame(width: BP.px(240), height: BP.px(135))
            .clipShape(RoundedRectangle(cornerRadius: BP.rXS, style: .continuous))
        }
    }
}

/// bp-collection-items.tsx: full-screen overlay with the collection's posters.
struct CollectionItemsOverlay: View {
    let card: CollectionsModel.Card
    let onClose: () -> Void
    let onOpen: (CollectionsModel.Item) -> Void
    private static let columns = Array(repeating: GridItem(.fixed(BPTileView.posterWidth), spacing: BP.px(21)), count: 6)

    var body: some View {
        ZStack {
            BP.void_.opacity(0.97).ignoresSafeArea()
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: BP.px(14)) {
                    if let b = card.byline { Text(b).font(BP.sans(12, .bold)).foregroundStyle(BP.accent).textCase(.uppercase).tracking(1) }
                    Text(card.name).font(BP.display(32)).foregroundStyle(BP.ink)
                    Text("\(card.count + (card.hidden ?? 0)) items").font(BP.sans(14)).foregroundStyle(BP.inkMuted)
                    if let h = card.hidden, h > 0 { Text("\(h) manga items are not shown in Big Picture.").font(BP.sans(12)).foregroundStyle(BP.inkSubtle) }
                    if let d = card.description, !d.isEmpty { Text(d).font(BP.sans(14)).foregroundStyle(BP.inkMuted).lineLimit(3).frame(maxWidth: BP.px(700), alignment: .leading) }
                    Button("Close", action: onClose).buttonStyle(BPActionStyle())
                    if card.items.isEmpty { BPNote(text: "This collection is empty.") }
                    LazyVGrid(columns: Self.columns, alignment: .leading, spacing: BP.px(24)) {
                        ForEach(card.items) { item in
                            Button { onOpen(item) } label: {
                                BPTileView(meta: Meta(id: item.id, type: item.type, name: item.name, poster: item.poster, background: nil, logo: nil, description: nil, releaseInfo: nil, releaseDate: nil, inTheaters: nil, imdbRating: nil, tmdbScore: nil, runtime: nil, genres: nil, adult: nil, isCollection: nil, providerBadge: nil, videos: nil), shape: .poster)
                            }
                            .buttonStyle(BPTileStyle())
                        }
                    }
                    .padding(.vertical, BP.px(14))
                    Color.clear.frame(height: BP.px(60))
                }
                .padding(.horizontal, BP.gutter).padding(.top, BP.px(60))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onExitCommand { onClose() }
    }
}
