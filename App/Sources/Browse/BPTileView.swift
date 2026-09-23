import SwiftUI

/// Poster (2:3), wide (16:9) and rank (numeral + poster) tiles, bp-tile.tsx geometry at the TV canvas.
struct BPTileView: View {
    let meta: Meta
    let shape: TileShape
    var rank: Int? = nil
    var focused = false
    @ObservedObject private var marks = CardMarksStore.shared

    static let posterWidth = BP.px(177)
    static let wideWidth = BP.px(230)
    static var posterSize: CGSize { CGSize(width: posterWidth, height: (posterWidth * 1.5).rounded()) }
    static var wideSize: CGSize { CGSize(width: wideWidth, height: (wideWidth * 9 / 16).rounded()) }
    /// Rank cell: poster covers the right 60 %, cell aspect 10:9, height = poster box × 0.9.
    static var rankSize: CGSize { CGSize(width: (posterWidth / 0.6).rounded(), height: (posterWidth * 1.5 * 0.9).rounded()) }
    /// bp-service-row.tsx: clamp(150px, 12.4vw, 244px) wide, 1.2:1.
    static var brandSize: CGSize { CGSize(width: BP.px(238), height: (BP.px(238) / 1.2).rounded()) }

    var body: some View {
        switch shape {
        case .poster: poster
        case .wide: wide
        case .rank: rankCell
        case .brand: brandTile
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
            art(url: meta.background ?? meta.poster, size: Self.wideSize, plateText: false)
            LinearGradient(colors: [.clear, BP.void_.opacity(0.85)], startPoint: .center, endPoint: .bottom)
            Text(meta.name).font(BP.sans(14, .semibold)).foregroundStyle(BP.ink).lineLimit(1).padding(BP.px(10))
        }
        .frame(width: Self.wideSize.width, height: Self.wideSize.height)
        .clipShape(RoundedRectangle(cornerRadius: BP.rXS, style: .continuous))
    }

    private var rankCell: some View {
        HStack(alignment: .bottom, spacing: 0) {
            Text("\(rank ?? 0)")
                .font(.custom("Switzer-Bold", size: Self.rankSize.height * 0.9))
                .foregroundStyle(BP.ink.opacity(focused ? 0.85 : 0.45))
                .frame(width: Self.rankSize.width * 0.4, alignment: .trailing)
                .offset(x: BP.px(6), y: Self.rankSize.height * 0.18)
                .clipped()
            art(url: meta.poster ?? meta.background, size: CGSize(width: Self.rankSize.width * 0.6, height: Self.rankSize.height))
        }
        .frame(width: Self.rankSize.width, height: Self.rankSize.height, alignment: .bottomTrailing)
    }

    /// Streaming-service tile: the brand tint over the panel (62 %, 18 % for white marks), the
    /// name as the mark (the SVG logos are not bundled), a light sheen from the top.
    private var brandTile: some View {
        let tint = Color(css: meta.providerBadge?.tint ?? "") ?? BP.ink
        let white = (meta.providerBadge?.tint ?? "").uppercased() == "#FFFFFF"
        return ZStack {
            RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).fill(BP.panel)
            RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).fill(tint.opacity(white ? 0.18 : (focused ? 0.8 : 0.62)))
            LinearGradient(colors: [BP.ink.opacity(0.12), .clear, BP.void_.opacity(0.55)], startPoint: .top, endPoint: .bottom)
                .clipShape(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous))
            Text(meta.name).font(BP.display(22, .semibold)).foregroundStyle(BP.ink).lineLimit(2).multilineTextAlignment(.center).padding(BP.px(12))
        }
        .frame(width: Self.brandSize.width, height: Self.brandSize.height)
    }

    private func art(url: String?, size: CGSize, plateText: Bool = true) -> some View {
        ZStack(alignment: .topLeading) {
            RemoteImage(url: url)
            if url == nil && plateText {
                Text(meta.name).font(BP.sans(12, .semibold)).foregroundStyle(BP.inkMuted)
                    .multilineTextAlignment(.center).padding(BP.px(10))
                    .frame(width: size.width, height: size.height)
            }
            CardMarksOverlay(marks: marks.byId[meta.id], fallbackChip: marks.byId[meta.id] == nil ? CardMark.identity(for: meta) : nil, size: size)
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: BP.rXS, style: .continuous))
    }
}


/// bp-card-marks.tsx top-start identity chip, the parts that need no extra data:
/// New (released this year) → Rerun (in cinema but >9 months old) → In Cinema.
/// Award and DUB chips join with the awards catalog and anime detection.
enum CardMark {
    static func identity(for meta: Meta) -> String? {
        let year = Calendar.current.component(.year, from: Date())
        let inCinema = meta.type == "movie" && meta.inTheaters == true
        if !inCinema, meta.releaseInfo == String(year) { return "New" }
        if inCinema {
            if let d = meta.releaseDate, let released = ISO8601DateFormatter().date(from: d) ?? Self.dayFormatter.date(from: d),
               Date().timeIntervalSince(released) / (60 * 60 * 24 * 30.44) > 9 {
                return meta.releaseInfo.map { "Rerun · \($0)" } ?? "Rerun"
            }
            return "In Cinema"
        }
        return nil
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX"); return f
    }()
}
