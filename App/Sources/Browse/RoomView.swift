import SwiftUI

/// Home / Movies / Shows: spotlight up top, Continue Watching, then the rail of rows.
struct RoomView: View {
    @StateObject private var model: BrowseModel

    init(room: Room, source: BrowseSource) {
        _model = StateObject(wrappedValue: BrowseModel(room: room, source: source))
    }

    var body: some View {
        ZStack(alignment: .top) {
            SpotlightView(meta: model.spotlight, boxHeight: heroHeight)
            if let failed = model.failed {
                VStack(spacing: BP.px(10)) {
                    Text("Couldn't load this room.").font(BP.sans(19, .bold)).foregroundStyle(BP.ink)
                    BPNote(text: failed)
                }
                .padding(.top, BP.px(300)).padding(.horizontal, BP.gutter)
            } else if model.loading && model.rows.isEmpty {
                ProgressView().tint(BP.inkMuted).padding(.top, BP.px(320))
            } else {
                BPRailView(rows: model.rows, onFocus: { m, _ in model.focus(m) }, onSelect: { _ in }, topInset: heroHeight) {
                    if !model.continueWatching.isEmpty {
                        ContinueRowView(items: model.continueWatching,
                                        onFocus: { model.focus(Meta(continue: $0)) }, onSelect: { _ in })
                    }
                }
            }
        }
        .task { await model.load() }
    }

    /// Home hero box: clamp(260px, 34vh, 380px) − 56px give (bp-tokens.ts:227-228, 172-175).
    private var heroHeight: CGFloat { BP.px(260 - 56) + BP.barHeight }
}

extension Meta {
    init(continue c: ContinueItem) {
        self.init(id: c.id, type: c.type, name: c.name, poster: c.poster, background: c.background, logo: c.logo,
                  description: nil, releaseInfo: nil, releaseDate: nil, inTheaters: nil, imdbRating: nil, tmdbScore: nil,
                  runtime: nil, genres: nil, adult: nil, isCollection: nil, providerBadge: nil, videos: nil)
    }
}
