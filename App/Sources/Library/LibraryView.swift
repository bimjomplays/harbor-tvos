import SwiftUI

/// Library room (Stage 5 slice): the Stremio library for the active profile, split into
/// Continue Watching, watchlist movies and watchlist series. Needs a Stremio sign-in.
@MainActor
final class LibraryModel: ObservableObject {
    struct Item: Decodable, Identifiable {
        struct State: Decodable { var timeOffset: Double?; var duration: Double?; var flaggedWatched: Int?; var lastWatched: String? }
        var _id: String
        var type: String
        var name: String
        var poster: String?
        var background: String?
        var state: State?
        var removed: Bool?
        var temp: Bool?
        var _mtime: String?
        var id: String { _id }
    }

    @Published private(set) var rows: [BrowseRow] = []
    @Published private(set) var loading = false
    @Published private(set) var signedOut = false
    @Published private(set) var failed: String?

    func load() async {
        loading = true; defer { loading = false }
        let p = ProfilesStore.shared.active
        guard let authKey = p.flatMap({ ProfilesStore.shared.stremioSession(for: $0.id)?.authKey }) else { signedOut = true; return }
        signedOut = false
        do {
            let items: [Item] = try await HarborEngine.shared.call("stremio.library", [authKey])
            let live = items.filter { $0.removed != true && $0.temp != true }
            let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            func date(_ s: String?) -> Date { s.flatMap { iso.date(from: $0) ?? ISO8601DateFormatter().date(from: $0) } ?? .distantPast }
            let byRecent = live.sorted { date($0.state?.lastWatched ?? $0._mtime) > date($1.state?.lastWatched ?? $1._mtime) }
            func metas(_ list: [Item]) -> [Meta] {
                list.map { Meta(id: $0._id, type: $0.type, name: $0.name, poster: $0.poster, background: $0.background, logo: nil, description: nil, releaseInfo: nil, releaseDate: nil, inTheaters: nil, imdbRating: nil, tmdbScore: nil, runtime: nil, genres: nil, adult: nil, isCollection: nil, providerBadge: nil, videos: nil) }
            }
            var out: [BrowseRow] = []
            let inProgress = byRecent.filter { ($0.state?.timeOffset ?? 0) > 0 && ($0.state?.flaggedWatched ?? 0) == 0 }
            if !inProgress.isEmpty { out.append(BrowseRow(key: "lib-cw", title: "Continue watching", metas: metas(inProgress))) }
            let movies = byRecent.filter { $0.type == "movie" }
            let series = byRecent.filter { $0.type == "series" }
            if !movies.isEmpty { out.append(BrowseRow(key: "lib-movies", title: "Movies in your library", metas: metas(movies))) }
            if !series.isEmpty { out.append(BrowseRow(key: "lib-series", title: "Series in your library", metas: metas(series))) }
            let other = byRecent.filter { $0.type != "movie" && $0.type != "series" }
            if !other.isEmpty { out.append(BrowseRow(key: "lib-other", title: "Everything else", metas: metas(other))) }
            rows = out
        } catch {
            failed = error.localizedDescription
        }
    }
}

struct LibraryView: View {
    @StateObject private var model = LibraryModel()
    @State private var spotlight: Meta?
    @State private var detail: Meta?

    var body: some View {
        ZStack(alignment: .top) {
            SpotlightView(meta: spotlight, boxHeight: BP.px(200) + BP.barHeight).opacity(spotlight == nil ? 0 : 1)
            if model.signedOut {
                VStack(alignment: .leading, spacing: BP.px(10)) {
                    Text("Library").font(BP.display(36)).foregroundStyle(BP.ink)
                    BPNote(text: "Sign in to Stremio in Settings to see your library, watchlist and Continue Watching here.")
                }
                .padding(.horizontal, BP.gutter).padding(.top, BP.barHeight + BP.px(20))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .focusable()
            } else if let failed = model.failed {
                BPNote(text: failed, tone: BP.danger).padding(.horizontal, BP.gutter).padding(.top, BP.px(300))
            } else if model.rows.isEmpty {
                (model.loading ? AnyView(ProgressView().tint(BP.inkMuted)) : AnyView(BPNote(text: "Your library is empty.")))
                    .padding(.top, BP.px(320))
            } else {
                BPRailView(rows: model.rows, onFocus: { m, _ in spotlight = m }, onSelect: { detail = $0 }, topInset: BP.px(200) + BP.barHeight) { EmptyView() }
            }
        }
        .task { await model.load() }
        .fullScreenCover(item: $detail) { m in DetailView(meta: m) }
    }
}
