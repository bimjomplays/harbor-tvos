import SwiftUI

/// Home / Movies / Shows: spotlight up top, Continue Watching, then the rail of rows.
struct RoomView: View {
    @StateObject private var model: BrowseModel

    init(room: Room, source: BrowseSource) {
        _model = StateObject(wrappedValue: BrowseModel(room: room, source: source))
    }

    var body: some View {
        ZStack(alignment: .top) {
            SpotlightView(meta: model.spotlight)
            if let failed = model.failed {
                VStack(spacing: BP.px(10)) {
                    Text("Couldn't load this room.").font(BP.sans(19, .bold)).foregroundStyle(BP.ink)
                    BPNote(text: failed)
                }
                .padding(.top, BP.px(300)).padding(.horizontal, BP.gutter)
            } else if model.loading && model.rows.isEmpty {
                ProgressView().tint(BP.inkMuted).padding(.top, BP.px(320))
            } else {
                BPRailView(rows: allRows, onFocus: { m, _ in model.focus(m) }, onSelect: { _ in }, topInset: BP.px(300))
            }
        }
        .task { await model.load() }
    }

    /// Continue Watching leads (bp-home.tsx row 1) as a wide row until BpCwCard lands.
    private var allRows: [BrowseRow] {
        var rows = model.rows
        if !model.continueWatching.isEmpty {
            let metas = model.continueWatching.map {
                Meta(id: $0.id, type: $0.type, name: $0.name, poster: $0.poster, background: $0.background, logo: $0.logo,
                     description: nil, releaseInfo: nil, releaseDate: nil, inTheaters: nil, imdbRating: nil, tmdbScore: nil,
                     runtime: nil, genres: nil, adult: nil, isCollection: nil, providerBadge: nil, videos: nil)
            }
            rows.insert(BrowseRow(key: "cw", title: "Jump back in", metas: metas, shape: .wide), at: 0)
        }
        return rows
    }
}
