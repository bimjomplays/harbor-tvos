import SwiftUI

/// bp-anime-awards.tsx BpAnimeAward: the anime award overlay opened from an anime award tile in
/// Discover's Awards band. Header ("Anime award", the source's name, "{n} recorded winners •
/// {n} categories • span"), a chip row per bundled source, a year row ("All years" with the total,
/// then each year with its count; picking the selected year again clears it), then each category
/// (the "Grand" prize first) with its winners. A winner opens its mapped anime id, else a TMDB
/// search when a key is set; with neither it stays focusable but dimmed.
struct AnimeAwardView: View {
    let sources: [DiscoverModel.AnimeAwardTile]
    @State private var source: String
    @State private var year: Int?
    @State private var data: Award?
    @State private var busy: String?
    @State private var detail: Meta?
    @Environment(\.dismiss) private var dismiss

    struct Award: Decodable {
        struct Winner: Decodable { var year: Int; var title: String; var mapped: Bool }
        struct Category: Decodable, Identifiable { var key: String; var name: String; var isAOTY: Bool; var winners: [Winner]; var id: String { key } }
        struct YearCount: Decodable { var year: Int; var count: Int }
        var id: String; var name: String; var totalWins: Int; var yearSpan: String; var years: [Int]; var perYear: [YearCount]; var categories: [Category]
    }

    init(sources: [DiscoverModel.AnimeAwardTile], initial: String) {
        self.sources = sources
        _source = State(initialValue: initial)
    }

    private static let columns = [GridItem(.adaptive(minimum: BP.px(230), maximum: BP.px(400)), spacing: BP.px(14))]
    private var hasKey: Bool { !SettingsBridge.shared.slice.tmdbKey.isEmpty }

    /// The year filter keeps only that year's winners and drops the categories left empty.
    private var categories: [Award.Category] {
        guard let data else { return [] }
        guard let year else { return data.categories }
        return data.categories.compactMap { c in
            let w = c.winners.filter { $0.year == year }
            return w.isEmpty ? nil : Award.Category(key: c.key, name: c.name, isAOTY: c.isAOTY, winners: w)
        }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            BPAmbientBackground()
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: BP.px(12)) {
                    header
                    chips
                    list
                    Color.clear.frame(height: BP.hintHeight)
                }
                .padding(.horizontal, BP.gutter).padding(.top, BP.px(50))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .ignoresSafeArea()
        .task(id: source) {
            // (bug pass) The task also re-runs when a title's cover closes (same source): keep the
            // viewer's year filter and the loaded award then.
            if data?.id == source { return }
            year = nil
            data = try? await HarborEngine.shared.call("discoverRoom.animeAward", [source])
        }
        .onExitCommand { dismiss() }
        .fullScreenCover(item: $detail) { m in DetailView(meta: m) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: BP.px(6)) {
            HStack(spacing: BP.px(6)) {
                Image(systemName: "trophy").font(.system(size: BP.px(11), weight: .bold))
                Text("Anime award").font(BP.sans(12, .bold)).textCase(.uppercase).tracking(BP.px(2))
            }
            .foregroundStyle(BP.inkSubtle)
            Text(data?.name ?? sources.first(where: { $0.id == source })?.name ?? "")
                .font(BP.display(30)).foregroundStyle(BP.ink)
            if let d = data {
                Text(summary(d)).font(BP.sans(15, .semibold)).foregroundStyle(BP.inkMuted)
            }
        }
    }

    private func summary(_ d: Award) -> String {
        // bp-anime-awards.tsx: t("{n} recorded winners") • t("{n} category" / "{n} categories").
        var parts = [T("%lld recorded winners", d.totalWins), d.categories.count == 1 ? T("%lld category", 1) : T("%lld categories", d.categories.count)]
        if !d.yearSpan.isEmpty { parts.append(d.yearSpan) }
        return parts.joined(separator: "  •  ")
    }

    private var chips: some View {
        VStack(alignment: .leading, spacing: BP.px(8)) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: BP.px(8)) {
                    ForEach(sources) { s in
                        Button(s.name) { source = s.id }.buttonStyle(BPActionStyle(primary: s.id == source)).bpSelected(s.id == source)
                    }
                }
                .padding(.vertical, BP.px(6))
            }
            .focusSection()
            if let d = data, !d.years.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: BP.px(8)) {
                        Button("All years  \(d.totalWins)") { year = nil }.buttonStyle(BPActionStyle(primary: year == nil)).bpSelected(year == nil)
                        ForEach(d.perYear, id: \.year) { y in
                            Button("\(String(y.year))  \(y.count)") { year = year == y.year ? nil : y.year }
                                .buttonStyle(BPActionStyle(primary: year == y.year)).bpSelected(year == y.year)
                                .accessibilityLabel("\(String(y.year)), \(y.count) winners")
                        }
                    }
                    .padding(.vertical, BP.px(6))
                }
                .focusSection()
            }
        }
    }

    @ViewBuilder private var list: some View {
        if let d = data {
            if categories.isEmpty {
                Text(d.categories.isEmpty ? "No data shipped for this award yet." : "No winners match these filters.")
                    .font(BP.sans(16)).foregroundStyle(BP.inkSubtle).padding(.top, BP.px(10))
            } else {
                VStack(alignment: .leading, spacing: BP.px(26)) {
                    ForEach(categories) { c in category(c) }
                }
                .padding(.top, BP.px(6))
            }
        } else {
            ProgressView().tint(BP.inkMuted)
        }
    }

    private func category(_ c: Award.Category) -> some View {
        VStack(alignment: .leading, spacing: BP.px(10)) {
            HStack(alignment: .firstTextBaseline, spacing: BP.px(10)) {
                if c.isAOTY {
                    Text("Grand").font(BP.sans(11, .bold)).textCase(.uppercase).tracking(BP.px(1.8)).foregroundStyle(BP.inkMuted)
                        .padding(.horizontal, BP.px(8)).padding(.vertical, BP.px(2))
                        .background(Capsule().fill(BP.glass))
                }
                Text(c.name).font(BP.sans(18, .bold)).foregroundStyle(BP.ink)
                Spacer(minLength: BP.px(10))
                Text(c.winners.count == 1 ? "1 winner" : "\(c.winners.count) winners")
                    .font(BP.sans(11, .bold)).textCase(.uppercase).tracking(BP.px(1.7)).foregroundStyle(BP.inkSubtle)
            }
            .padding(.bottom, BP.px(5))
            .overlay(alignment: .bottom) { Rectangle().fill(BP.edge).frame(height: 1) }
            LazyVGrid(columns: Self.columns, alignment: .leading, spacing: BP.px(14)) {
                ForEach(Array(c.winners.enumerated()), id: \.offset) { i, w in
                    winner(w, latest: year == nil && i == 0)
                }
            }
        }
        .focusSection()
    }

    /// BpAwardWinner: year and title; the latest winner (unfiltered) sits on a darker plate.
    private func winner(_ w: Award.Winner, latest: Bool) -> some View {
        let inert = !w.mapped && !hasKey
        let key = "\(w.year):\(w.title)"
        return Button { open(w, key: key) } label: {
            HStack(spacing: BP.px(12)) {
                Text(String(w.year)).font(BP.sans(15, .bold)).monospacedDigit()
                    .foregroundStyle(latest ? BP.ink : BP.inkSubtle).frame(width: BP.px(50), alignment: .leading)
                Text(w.title).font(BP.sans(16, .semibold)).foregroundStyle(BP.ink).lineLimit(2).multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, BP.px(12))
            .frame(maxWidth: .infinity, minHeight: BP.px(48), alignment: .leading)
            .background(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).fill(latest ? BP.void_.opacity(0.6) : BP.panel))
            .opacity(inert || busy == key ? 0.55 : 1)
        }
        .buttonStyle(BPTileStyle(radius: BP.rSM))
        .accessibilityLabel(w.title + ", " + String(w.year))
    }

    private func open(_ w: Award.Winner, key: String) {
        guard busy == nil else { return }
        if !w.mapped && !hasKey { return }
        busy = key
        Task {
            let p = ProfilesStore.shared.active
            let meta: Meta? = try? await HarborEngine.shared.call("discoverRoom.animeAwardOpen", [w.title, w.year, p?.id ?? "default", p?.linked ?? true])
            busy = nil
            if let meta { detail = meta }
        }
    }
}
