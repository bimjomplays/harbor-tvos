import SwiftUI

/// bp-cw-row.tsx card: 16:9 backdrop, bottom scrim, logo or title, status pill, progress bar.
struct ContinueCardView: View {
    let item: ContinueItem
    var focused = false

    static let width = BP.px(268)
    static var size: CGSize { CGSize(width: width, height: (width * 0.5625).rounded()) }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            RemoteImage(url: item.background ?? item.poster)
            LinearGradient(colors: [.clear, BP.void_.opacity(0.88), BP.void_], startPoint: .init(x: 0.5, y: 0.4), endPoint: .bottom)
            VStack(alignment: .leading, spacing: BP.px(4)) {
                if let logo = item.logo, !logo.isEmpty {
                    RemoteImage(url: logo, contentMode: .fit)
                        .frame(maxWidth: Self.width * 0.76, maxHeight: BP.px(24), alignment: .leading)
                } else {
                    Text(item.name).font(BP.sans(14, .bold)).foregroundStyle(BP.ink).lineLimit(1)
                }
                HStack(spacing: BP.px(6)) {
                    HStack(spacing: BP.px(4)) {
                        Image(systemName: "play.fill").font(.system(size: BP.px(8), weight: .bold))
                        Text(statusText)
                    }
                    .font(BP.sans(10.5, .semibold)).foregroundStyle(BP.ink)
                    .padding(.horizontal, BP.px(7)).padding(.vertical, BP.px(4))
                    .background(RoundedRectangle(cornerRadius: BP.px(4)).fill(BP.void_.opacity(0.92)))
                }
                ZStack(alignment: .leading) {
                    Capsule().fill(BP.edge2)
                    Capsule().fill(BP.accent).frame(width: max(0, (Self.width - BP.px(22)) * item.progress))
                }
                .frame(height: BP.px(3))
                .padding(.top, BP.px(4))
            }
            .padding(BP.px(11))
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .clipShape(RoundedRectangle(cornerRadius: BP.rXS, style: .continuous))
    }

    private var statusText: String {
        if let s = item.season, let e = item.episode { return "S\(s) E\(e)" }
        let left = Int((1 - item.progress) * 100)
        return item.progress > 0 ? "\(left)% left" : "Resume"
    }
}
