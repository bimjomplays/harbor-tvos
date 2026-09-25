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
                        Image(systemName: item.external == "trakt" ? "checkmark.circle" : item.external == "simkl" ? "circle.dotted" : item.waitingForAir ? "clock" : "play.fill").accessibilityHidden(true).font(.system(size: BP.px(8), weight: .bold))
                        Text(statusText)
                    }
                    .font(BP.sans(10.5, .semibold)).foregroundStyle(BP.ink)
                    .padding(.horizontal, BP.px(7)).padding(.vertical, BP.px(4))
                    .background(RoundedRectangle(cornerRadius: BP.px(4)).fill(BP.void_.opacity(0.92)))
                    // bp-cw-card-meta badges: watched on Trakt, new episodes since the last watch.
                    if item.watched { Image(systemName: "checkmark").font(.system(size: BP.px(9), weight: .bold)).foregroundStyle(BP.canvas).padding(BP.px(4)).background(Circle().fill(BP.live)) }
                    if item.newEpisode > 0 {
                        Text("+\(item.newEpisode) new").font(BP.sans(9.5, .bold)).foregroundStyle(BP.canvas)
                            .padding(.horizontal, BP.px(6)).padding(.vertical, BP.px(3)).background(Capsule().fill(BP.accent))
                    }
                    if let w = item.watcher { Text("Watched by \(w)").font(BP.sans(9.5)).foregroundStyle(BP.inkMuted).lineLimit(1) }
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
        // bp-cw-row.tsx aria-label={bpCwCardLabel(…)}: name, state, badges as one phrase (the logo
        // art carries no name of its own).
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: accessibilityText))
    }

    /// bp-cw-card-meta.tsx bpCwCardLabel.
    private var accessibilityText: String {
        let fresh = item.newEpisode <= 0 ? "" : (item.newEpisode == 1 ? T("1 new episode since you last watched") : T("%lld new episodes since you last watched", item.newEpisode))
        return [item.name, statusText, item.watched ? T("Watched on Trakt") : "", fresh, item.watcher.map { T("Watched by %@", $0) } ?? ""]
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }

    private var statusText: String {
        if item.waitingForAir { return Self.countdown(item.nextAirDate) }
        if item.upNext { return T("Up Next") + (item.season.map { " · S\($0) E\(item.episode ?? 0)" } ?? "") }
        if let s = item.season, let e = item.episode { return "S\(s) E\(e)" }
        let left = Int((1 - item.progress) * 100)
        return item.progress > 0 ? "\(left)% left" : T("Resume")
    }

    /// bp-cw-card-meta useAirCountdown: "Airing now" / "Next in 2d 3h" / "Next in 40m".
    private static func countdown(_ at: String?) -> String {
        guard let at, let date = ISO8601DateFormatter().date(from: at) ?? ISO8601DateFormatter.dateOnly.date(from: at) else { return "Waiting for air" }
        let diff = date.timeIntervalSinceNow
        if diff <= 0 { return T("Airing now") }
        let days = Int(diff / 86_400), hours = Int(diff.truncatingRemainder(dividingBy: 86_400) / 3600), minutes = Int(diff.truncatingRemainder(dividingBy: 3600) / 60)
        if days > 0 { return T("Next in %lldd %lldh", days, hours) }
        if hours > 0 { return T("Next in %lldh %lldm", hours, minutes) }
        return T("Next in %lldm", max(1, minutes))
    }
}


extension ISO8601DateFormatter {
    static let dateOnly: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withFullDate]; return f }()
}
