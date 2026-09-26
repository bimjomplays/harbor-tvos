import SwiftUI

/// bp-cw-row.tsx card: 16:9 backdrop, bottom scrim, logo or title, status pill, progress bar.
struct ContinueCardView: View {
    let item: ContinueItem
    var focused = false
    /// bp-cw-card-meta episodeTitleFor: fetched the first time the card takes the ring.
    @State private var episodeTitle = ""
    @State private var titleAskedFor: String?
    /// bp-cw-card-meta episodeTitleFor: fetched the first time the card takes the ring.
    @State private var episodeTitle = ""
    @State private var titleAskedFor: String?
    /// (P11) snapshots.ts useSnapshotVersion: a frame saved while the card is on screen redraws it.
    @ObservedObject private var snapshots = ExitSnapshotVersion.shared

    static let width = BP.px(268)
    static var size: CGSize { CGSize(width: width, height: (width * 0.5625).rounded()) }

    var body: some View {
        let snap: String? = snapshotArt
        let art: String? = item.background ?? item.poster
        ZStack(alignment: .bottomLeading) {
            RemoteImage(url: snap ?? art, fallback: snap != nil ? art : nil)
            LinearGradient(colors: [.clear, BP.void_.opacity(0.88), BP.void_], startPoint: .init(x: 0.5, y: 0.4), endPoint: .bottom)
            VStack(alignment: .leading, spacing: BP.px(4)) {
                if let logo = item.logo, !logo.isEmpty {
                    RemoteImage(url: logo, contentMode: .fit)
                        .frame(maxWidth: Self.width * 0.76, maxHeight: BP.px(24), alignment: .leading)
                } else {
                    Text(item.name).font(BP.sans(14, .bold)).foregroundStyle(BP.ink).lineLimit(1)
                }
                HStack(spacing: BP.px(6)) {
                    // bp-cw-card-meta BpCwCardPill: nothing to say and no service mark, no pill.
                    if !episodeText.isEmpty || !trailingText.isEmpty || isExternal {
                        HStack(spacing: BP.px(4)) {
                            Image(systemName: item.external == "trakt" ? "checkmark.circle" : item.external == "simkl" ? "circle.dotted" : item.waitingForAir ? "clock" : "play.fill").accessibilityHidden(true).font(.system(size: BP.px(8), weight: .bold))
                            if !episodeText.isEmpty { Text(episodeText).lineLimit(1).fixedSize() }
                            if !episodeText.isEmpty && !trailingText.isEmpty { Text(verbatim: "·").opacity(0.4).accessibilityHidden(true) }
                            if !trailingText.isEmpty {
                                Text(trailingText).lineLimit(1)
                                    // bp-cw-card-meta: Up Next reads in the touch colour.
                                    .foregroundStyle(upNextShown ? BP.accent : BP.ink)
                            }
                        }
                        .font(BP.sans(10.5, .semibold)).foregroundStyle(BP.ink)
                        .padding(.horizontal, BP.px(7)).padding(.vertical, BP.px(4))
                        .background(RoundedRectangle(cornerRadius: BP.px(4)).fill(BP.void_.opacity(0.92)))
                    }
                    // bp-cw-card-meta badges: watched on Trakt, new episodes since the last watch.
                    if item.watched { Image(systemName: "checkmark").font(.system(size: BP.px(9), weight: .bold)).foregroundStyle(BP.canvas).padding(BP.px(4)).background(Circle().fill(BP.live)) }
                    if item.newEpisode > 0 {
                        Text("+\(item.newEpisode) new").font(BP.sans(9.5, .bold)).foregroundStyle(BP.canvas)
                            .padding(.horizontal, BP.px(6)).padding(.vertical, BP.px(3)).background(Capsule().fill(BP.accent))
                    }
                    if let w = item.watcher { Text("Watched by \(w)").font(BP.sans(9.5)).foregroundStyle(BP.inkMuted).lineLimit(1) }
                }
                if !episodeTitle.isEmpty { Text(episodeTitle).font(BP.sans(10.5)).foregroundStyle(BP.inkMuted).lineLimit(1) }
                if !episodeTitle.isEmpty { Text(episodeTitle).font(BP.sans(10.5)).foregroundStyle(BP.inkMuted).lineLimit(1) }
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
        .onChange(of: focused, initial: true) { _, on in
            guard on, titleAskedFor != item.id, (item.episode ?? 0) > 0 || (item.videoId?.split(separator: ":").count ?? 0) == 3 else { return }
            titleAskedFor = item.id
            Task {
                let p = ProfilesStore.shared.active
                let wire: AnyJSON = .object(["id": .string(item.id), "name": .string(item.name), "season": item.season.map { .number(Double($0)) } ?? .null,
                                             "episode": item.episode.map { .number(Double($0)) } ?? .null, "videoId": item.videoId.map { .string($0) } ?? .null])
                let t: String = (try? await HarborEngine.shared.call("rooms.cwEpisodeTitle", [wire, p?.id ?? "default", p?.linked ?? true])) ?? ""
                if !t.isEmpty { episodeTitle = t }
            }
        }
        // bp-cw-row.tsx aria-label={bpCwCardLabel(…)}: name, state, badges as one phrase (the logo
        // art carries no name of its own).
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: accessibilityText))
    }

    /// bp-cw-card-meta.tsx bpCwCardLabel: name, episode, state, badges.
    private var accessibilityText: String {
        let fresh = item.newEpisode <= 0 ? "" : (item.newEpisode == 1 ? T("1 new episode since you last watched") : T("%lld new episodes since you last watched", item.newEpisode))
        let watcher: String = item.watcher.map { T("Watched by %@", $0) } ?? ""
        let parts: [String] = [item.name, episodeText, trailingText, item.watched ? T("Watched on Trakt") : "", fresh, watcher]
        return parts.filter { !$0.isEmpty }.joined(separator: ", ")
    }

    private var isExternal: Bool { !(item.external ?? "").isEmpty }

    /// (P11) bp-cw-row.tsx BpCwCard `pinned` = readSnapshot(item._id): the frame use-exit-snapshot
    /// saved when the viewer left this title leads the card ("the card itself leads with them"), and
    /// the card's own art stands behind it when the file is gone (tvOS purged the cache) or will not
    /// load. Upstream's card only pins it over a library item with no background; Stremio's cloud
    /// entries carry none there, but the TV writes the meta's background into them and into every
    /// local entry, so that gate would hide the frame on nearly every card. An Up Next card shows
    /// the next episode, not the spot left (continue-card.tsx `thumb = upNext ? undefined : snapshot`).
    private var snapshotArt: String? {
        _ = snapshots.version
        guard !item.upNext else { return nil }
        let days: Int = ExitSnapshotSettings.current.days
        return ExitSnapshotStore.shared.url(for: item.id, retentionDays: days)?.absoluteString
    }

    /// lib/stremio isAnimeCwItem (the card's flag, or an anime catalogue id).
    private var isAnime: Bool {
        item.anime || ["kitsu:", "mal:", "anilist:", "anidb:"].contains { item.id.hasPrefix($0) }
    }

    /// bp-cw-row.tsx episodeLabel: "Episode {n}" for anime (absolute numbering), "S{s} E{e}" for a
    /// series, nothing for a film.
    private var episodeText: String {
        guard item.type != "movie", let e = item.episode, e > 0 else { return "" }
        if isAnime { return T("Episode %lld", e) }
        return T("S%lld E%lld", item.season ?? 0, e)
    }

    /// bp-cw-card-meta BpCwCardPill: Up Next shows only while the card is not waiting for air.
    private var upNextShown: Bool { item.upNext && !item.waitingForAir }

    /// BpCwCardPill trailing: the air countdown, else "Up Next", else the time left (upstream puts
    /// the TMDB episode title first when it has one; the TV does not look it up).
    private var trailingText: String {
        if item.waitingForAir { return Self.countdown(item.nextAirDate) }
        if upNextShown { return T("Up Next") }
        return remainingText
    }

    /// bp-cw-row.tsx remainingLabel: "Almost done", "{n}m left", "{h}h {m}m left" from the saved
    /// duration and offset; nothing without a duration or for a Trakt / Simkl entry.
    private var remainingText: String {
        guard item.durationMs > 0, !isExternal else { return "" }
        // (review 18) Synced library values: a stray huge duration made Int() trap, crashing the app
        // on Home. Clamped before the conversion.
        let rawMins: Double = (item.durationMs - item.timeOffsetMs) / 60000
        guard rawMins.isFinite else { return "" }
        let mins: Int = Int(min(max(rawMins, 0), 100_000).rounded())
        if mins < 1 { return T("Almost done") }
        if mins < 60 { return T("%lldm left", mins) }
        return T("%lldh %lldm left", mins / 60, mins % 60)
    }

    /// bp-cw-card-meta useAirCountdown: "Airing now" / "Next in 2d 3h" / "Next in 40m".
    /// (regression pass) An air date upstream's Date.parse cannot read gives "" (the pill then shows
    /// the episode alone), not the English-only "Waiting for air". Addon and Kitsu air dates carry
    /// milliseconds ("2026-10-02T00:00:00.000Z"), which the plain ISO8601DateFormatter refuses, so
    /// every such card read "Waiting for air" instead of its countdown. The formatters are made once.
    private static func countdown(_ at: String?) -> String {
        guard let at, let date = Self.airDate(at) else { return "" }
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

extension ContinueCardView {
    private static let isoPlain = ISO8601DateFormatter()
    private static let isoFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Date.parse for the shapes an air date arrives in: with or without milliseconds, or a bare day.
    static func airDate(_ raw: String) -> Date? {
        if let d = isoFraction.date(from: raw) { return d }
        if let d = isoPlain.date(from: raw) { return d }
        return ISO8601DateFormatter.dateOnly.date(from: raw)
    }
}
