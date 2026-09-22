import SwiftUI

/// Poster (2:3), wide (16:9) and rank (numeral + poster) tiles, bp-tile.tsx geometry at the TV canvas.
struct BPTileView: View {
    let meta: Meta
    let shape: TileShape
    var rank: Int? = nil
    var focused = false

    static let posterWidth = BP.px(177)
    static let wideWidth = BP.px(230)
    static var posterSize: CGSize { CGSize(width: posterWidth, height: (posterWidth * 1.5).rounded()) }
    static var wideSize: CGSize { CGSize(width: wideWidth, height: (wideWidth * 9 / 16).rounded()) }
    /// Rank cell: poster covers the right 60 %, cell aspect 10:9, height = poster box × 0.9.
    static var rankSize: CGSize { CGSize(width: (posterWidth / 0.6).rounded(), height: (posterWidth * 1.5 * 0.9).rounded()) }

    var body: some View {
        switch shape {
        case .poster: poster
        case .wide: wide
        case .rank: rankCell
        }
    }

    private var poster: some View {
        VStack(alignment: .leading, spacing: BP.px(6)) {
            art(url: meta.poster ?? meta.background, size: Self.posterSize)
            Text(meta.name)
                .font(BP.sans(10.5, .semibold)).foregroundStyle(BP.ink).lineLimit(1)
                .opacity(focused ? 1 : 0)
                .animation(.easeOut(duration: 0.26), value: focused)
        }
        .frame(width: Self.posterWidth, alignment: .leading)
    }

    private var wide: some View {
        ZStack(alignment: .bottomLeading) {
            art(url: meta.background ?? meta.poster, size: Self.wideSize)
            LinearGradient(colors: [.clear, BP.void_.opacity(0.85)], startPoint: .center, endPoint: .bottom)
            Text(meta.name).font(BP.sans(14, .semibold)).foregroundStyle(BP.ink).lineLimit(1).padding(BP.px(10))
        }
        .frame(width: Self.wideSize.width, height: Self.wideSize.height)
        .clipShape(RoundedRectangle(cornerRadius: BP.rXS, style: .continuous))
    }

    private var rankCell: some View {
        HStack(alignment: .bottom, spacing: 0) {
            Text("\(rank ?? 0)")
                .font(.custom("Switzer-Bold", size: Self.rankSize.height * 0.98))
                .foregroundStyle(BP.ink.opacity(focused ? 0.9 : 0.55))
                .frame(width: Self.rankSize.width * 0.4, alignment: .trailing)
                .offset(x: BP.px(6), y: Self.rankSize.height * 0.18)
                .clipped()
            art(url: meta.poster ?? meta.background, size: CGSize(width: Self.rankSize.width * 0.6, height: Self.rankSize.height))
        }
        .frame(width: Self.rankSize.width, height: Self.rankSize.height, alignment: .bottomTrailing)
    }

    private func art(url: String?, size: CGSize) -> some View {
        ZStack {
            RemoteImage(url: url)
            if url == nil {
                Text(meta.name).font(BP.sans(12, .semibold)).foregroundStyle(BP.inkMuted)
                    .multilineTextAlignment(.center).padding(BP.px(10))
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: BP.rXS, style: .continuous))
    }
}
