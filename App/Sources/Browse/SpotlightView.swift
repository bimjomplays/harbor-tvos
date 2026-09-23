import SwiftUI

/// bp-spotlight.tsx: a pure display surface mirroring the focused (or hero-cycled) title.
struct SpotlightView: View {
    let meta: Meta?
    /// Height of the hero box the copy is bottom-anchored in (RoomView passes the Home value).
    var boxHeight: CGFloat = BP.px(260 - 56) + BP.barHeight

    var body: some View {
        ZStack(alignment: .topLeading) {
            backdrop
            VStack(alignment: .leading, spacing: BP.px(10)) {
                Spacer(minLength: 0)
                if let logo = meta?.logo, !logo.isEmpty {
                    RemoteImage(url: logo, contentMode: .fit)
                        .frame(maxWidth: BP.px(300), maxHeight: BP.px(90), alignment: .leading)
                } else {
                    Text(meta?.name ?? " ")
                        .font(BP.display(36)).foregroundStyle(BP.ink)
                        .lineLimit(2).shadow(color: .black.opacity(0.5), radius: 12, y: 4)
                }
                HStack(spacing: BP.px(10)) {
                    // bp-spotlight: provider chips from use-bp-card-badges, then TMDB's own score, then facts.
                    ScoreChipsView(meta: meta, surface: "card", limit: 3)
                    if let s = meta?.tmdbScore, s > 0 { scoreChip("TMDB", String(format: "%.1f", s)) }
                    if let f = meta?.facts, !f.isEmpty {
                        Text(f).font(BP.sans(14, .medium)).foregroundStyle(BP.inkMuted)
                    }
                }
                Text(meta?.description ?? "")
                    .font(BP.sans(16)).foregroundStyle(BP.inkMuted).lineSpacing(5)
                    .lineLimit(2).frame(maxWidth: BP.px(520), alignment: .leading)
            }
            .padding(.leading, BP.gutter)
            .padding(.bottom, BP.px(27))
            .frame(height: boxHeight, alignment: .bottomLeading)
            .animation(.easeOut(duration: 0.26), value: meta?.id)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .ignoresSafeArea()
    }

    private var backdrop: some View {
        ZStack {
            BP.void_
            if let url = meta?.background {
                GeometryReader { g in
                    RemoteImage(url: url)
                        .frame(width: g.size.width * 0.76, height: g.size.height)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .mask(LinearGradient(colors: [.clear, .black, .black], startPoint: .leading, endPoint: .init(x: 0.45, y: 0.5)))
                }
                .transition(.opacity)
                .id(url)
            }
            LinearGradient(colors: [BP.void_.opacity(0.82), BP.void_.opacity(0.52), BP.void_.opacity(0.16), .clear],
                           startPoint: .leading, endPoint: .init(x: 0.7, y: 0.5))
            LinearGradient(colors: [.clear, BP.void_.opacity(0.3), BP.void_.opacity(0.88), BP.void_], startPoint: .init(x: 0.5, y: 0.35), endPoint: .bottom)
        }
        .animation(.easeInOut(duration: 0.48), value: meta?.background)
    }

    private func scoreChip(_ label: String, _ value: String) -> some View {
        HStack(spacing: BP.px(4)) {
            Text(label).font(BP.sans(9.8, .bold)).foregroundStyle(BP.canvas)
                .padding(.horizontal, BP.px(5)).padding(.vertical, BP.px(2))
                .background(RoundedRectangle(cornerRadius: BP.px(4)).fill(BP.ink))
            Text(value).font(BP.sans(14, .semibold)).foregroundStyle(BP.ink)
        }
    }
}
