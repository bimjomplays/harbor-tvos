import SwiftUI

/// bp-award.tsx BpAward: one award body's page. Header (the mark on the body's tint, shorthand,
/// title, "{n} winners • span • {n} categories" of what the filters leave), a decade chip row
/// ("All years", then "{d}s"; the picked decade again clears it) and a category chip row ("All
/// categories", then each category with the count its decade leaves), then each category's
/// winners as tiles, paged in 90 at a time as the ring nears the end (use-bp-auto-page).
///
/// A winner tile (BpAwardWinner) shows metahub's poster when the bundle has an IMDb id, else the
/// year; Select opens the title (an IMDb id at once, else a TMDB lookup scored by
/// use-bp-award-work: "Checking with TMDB…", "No match found"). Without a TMDB key a winner with no
/// id is dimmed but stays focusable, and Select goes to Settings, as upstream's does.
struct AwardDetailView: View {
    let summary: DiscoverModel.Awards.Summary
    /// pushBigPicture({ kind: "settings" }): the caller closes this page and opens Settings.
    var onOpenSettings: (() -> Void)? = nil

    struct Page: Decodable {
        struct Chip: Decodable, Identifiable { var key: String; var name: String; var count: Int; var id: String { key } }
        struct Winner: Decodable { var year: Int; var workTitle: String; var recipients: [String]; var imdb: String?; var poster: String? }
        struct Group: Decodable, Identifiable { var key: String; var name: String; var preferTv: Bool; var entries: [Winner]; var id: String { key } }
        var title: String; var shorthand: String; var tint: String
        var wins: Int; var span: String; var categoryCount: Int
        var decades: [Int]; var categories: [Chip]; var groups: [Group]
        var mounted: Int; var more: Bool
    }
    struct Outcome: Decodable { var status: String; var meta: Meta? }

    /// bp-award.tsx PAGE.
    private static let pageSize = 90
    private static let columns = [GridItem(.adaptive(minimum: BP.px(250), maximum: BP.px(420)), spacing: BP.px(12))]

    @State private var page: Page?
    @State private var failed = false
    @State private var decade: Int?
    @State private var category = "all"
    @State private var limit = AwardDetailView.pageSize
    @State private var busy: String?
    @State private var missing: Set<String> = []
    @State private var detail: Meta?
    @State private var seeded = false
    @FocusState private var focusedWinner: String?
    @Environment(\.dismiss) private var dismiss

    private var hasKey: Bool { !SettingsBridge.shared.slice.tmdbKey.isEmpty }
    private var tint: Color { Color(oklch: summary.tint) ?? Color(css: summary.tint) ?? BP.accent }
    /// The filters on screen, and one read per filter and page size.
    private var filterKey: String { (decade.map { String($0) } ?? "all") + "|" + category }
    private var readKey: String { filterKey + "|" + String(limit) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            BPAmbientBackground()
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: BP.px(14)) {
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
        .task(id: readKey) { await read() }
        .onChange(of: decade) { _, _ in resetPaging() }
        .onChange(of: category) { _, _ in resetPaging() }
        .onExitCommand { dismiss() }
        .fullScreenCover(item: $detail) { m in DetailView(meta: m) }
    }

    private func read() async {
        let want = readKey
        let dec: AnyJSON = decade.map { AnyJSON.number(Double($0)) } ?? AnyJSON.null
        let got: Page? = try? await HarborEngine.shared.call("discoverRoom.awardPage", [summary.type, dec, category, limit])
        // Engine calls don't stop on cancel: a chip pressed while the last read ran must not get its answer.
        guard !Task.isCancelled, want == readKey else { return }
        if let got {
            page = got
            failed = false
            // data-bp-autofocus on the first winner, once: later reads leave the ring where it is.
            if !seeded, let g = got.groups.first, !g.entries.isEmpty {
                seeded = true
                // (review 33) A runloop later: set in the same update that first draws the winners,
                // the tile did not exist yet and tvOS put the ring on "All years" instead.
                let first: String = Self.key(g.key, 0)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { if focusedWinner == nil { focusedWinner = first } }
            }
        } else if page == nil {
            failed = true
        }
    }

    /// useEffect(() => setLimit(PAGE), [decade, categoryKey, awardType]).
    private func resetPaging() {
        limit = Self.pageSize
        missing = []
    }

    private static func key(_ group: String, _ index: Int) -> String { group + "#" + String(index) }

    // MARK: header

    private var header: some View {
        HStack(spacing: BP.px(18)) {
            Image(systemName: "trophy.fill")
                .font(.system(size: BP.px(34), weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: BP.px(84), height: BP.px(84))
                .background(Circle().fill(tint.opacity(0.16)))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: BP.px(4)) {
                Text(verbatim: page?.shorthand ?? summary.shorthand)
                    .font(BP.sans(13, .bold)).textCase(.uppercase).tracking(BP.px(2.6))
                    .foregroundStyle(tint).lineLimit(1)
                Text(verbatim: T(page?.title ?? summary.title))
                    .font(BP.display(40)).foregroundStyle(BP.ink).lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                if let p = page {
                    Text(verbatim: counts(p)).font(BP.sans(16, .semibold)).foregroundStyle(BP.inkMuted).lineLimit(1)
                }
            }
        }
    }

    /// t("{n} winners") • span • t("{n} categories").
    private func counts(_ p: Page) -> String {
        var parts: [String] = [TCount(p.wins, one: "%lld winner", "%lld winners")]
        if !p.span.isEmpty { parts.append(p.span) }
        parts.append(TCount(p.categoryCount, one: "%lld category", "%lld categories"))
        return parts.joined(separator: "  •  ")
    }

    // MARK: chips

    @ViewBuilder private var chips: some View {
        if let p = page {
            VStack(alignment: .leading, spacing: BP.px(6)) {
                if !p.decades.isEmpty { decadeRow(p) }
                if !p.categories.isEmpty { categoryRow(p) }
            }
        }
    }

    private func decadeRow(_ p: Page) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: BP.px(8)) {
                chip(T("All years"), count: nil, on: decade == nil) { decade = nil }
                ForEach(p.decades, id: \.self) { d in
                    chip(String(d) + "s", count: nil, on: decade == d) { decade = decade == d ? nil : d }
                }
            }
            .padding(.vertical, BP.px(6))
        }
        .scrollClipDisabled()
        .focusSection()
    }

    private func categoryRow(_ p: Page) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: BP.px(8)) {
                chip(T("All categories"), count: nil, on: category == "all") { category = "all" }
                ForEach(p.categories) { c in
                    chip(c.name, count: c.count, on: category == c.key) { category = c.key }
                }
            }
            .padding(.vertical, BP.px(6))
        }
        .scrollClipDisabled()
        .focusSection()
    }

    /// BpChip: the label, then its count in a quieter weight.
    private func chip(_ label: String, count: Int?, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: BP.px(8)) {
                Text(verbatim: label)
                if let count { Text(verbatim: String(count)).opacity(0.62).monospacedDigit() }
            }
        }
        .buttonStyle(BPActionStyle(primary: on))
        .bpSelected(on)
    }

    // MARK: winners

    @ViewBuilder private var list: some View {
        if let p = page {
            if p.groups.isEmpty {
                Text(verbatim: T("No winners match these filters."))
                    .font(BP.sans(17)).foregroundStyle(BP.inkSubtle).padding(.top, BP.px(12))
            } else {
                ForEach(p.groups) { g in section(g) }
                if p.more {
                    // The sentinel: reaching the end of what is mounted pages the next 90 in.
                    ProgressView().tint(BP.inkMuted)
                        .frame(maxWidth: .infinity)
                        .onAppear { if limit <= p.mounted { limit = p.mounted + Self.pageSize } }
                }
            }
        } else if failed {
            BPNote(text: "Couldn't load this award right now.")
        } else {
            ProgressView().tint(BP.inkMuted)
        }
    }

    private func section(_ g: Page.Group) -> some View {
        VStack(alignment: .leading, spacing: BP.px(10)) {
            HStack(alignment: .firstTextBaseline, spacing: BP.px(10)) {
                Text(verbatim: g.name).font(BP.sans(20, .bold)).foregroundStyle(BP.ink)
                Spacer(minLength: BP.px(10))
                Text(verbatim: TCount(g.entries.count, one: "%lld winner", "%lld winners"))
                    .font(BP.sans(12, .bold)).textCase(.uppercase).tracking(BP.px(1.9)).foregroundStyle(BP.inkSubtle)
            }
            .padding(.bottom, BP.px(6))
            .overlay(alignment: .bottom) { Rectangle().fill(BP.edge).frame(height: 1) }
            LazyVGrid(columns: Self.columns, alignment: .leading, spacing: BP.px(12)) {
                ForEach(Array(g.entries.enumerated()), id: \.offset) { i, e in
                    winner(e, key: Self.key(g.key, i), preferTv: g.preferTv)
                }
            }
        }
        .padding(.top, BP.px(12))
        .focusSection()
    }

    private func winner(_ e: Page.Winner, key: String, preferTv: Bool) -> some View {
        // No fade while busy (it reads as disabled); a keyless, id-less winner is dimmed.
        let unlinked: Bool = e.imdb == nil && !hasKey
        let second: String? = secondLine(e, key: key)
        let quiet: Bool = busy == key || missing.contains(key)
        return Button { activate(e, key: key, preferTv: preferTv) } label: {
            HStack(spacing: BP.px(12)) {
                art(e)
                VStack(alignment: .leading, spacing: BP.px(2)) {
                    HStack(alignment: .firstTextBaseline, spacing: BP.px(8)) {
                        Text(verbatim: String(e.year)).font(BP.sans(15, .bold)).monospacedDigit().foregroundStyle(BP.inkSubtle)
                        Text(verbatim: e.workTitle).font(BP.sans(18, .semibold)).foregroundStyle(BP.ink)
                            .lineLimit(2).multilineTextAlignment(.leading)
                    }
                    if let second {
                        Text(verbatim: second).font(BP.sans(14, quiet ? .semibold : .medium))
                            .foregroundStyle(quiet ? BP.inkMuted : BP.inkSubtle).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(BP.px(8))
            .frame(maxWidth: .infinity, minHeight: BP.px(84), alignment: .leading)
            .background(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).fill(BP.panel))
            .overlay(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).stroke(BP.edge, lineWidth: 1))
            .opacity(unlinked ? 0.7 : 1)
        }
        .buttonStyle(BPTileStyle(radius: BP.rSM))
        .focused($focusedWinner, equals: key)
        .accessibilityLabel(Text(verbatim: e.workTitle + ", " + String(e.year)))
    }

    /// The lookup answers in the second text row; otherwise the recipients.
    private func secondLine(_ e: Page.Winner, key: String) -> String? {
        if busy == key { return T("Checking with TMDB…") }
        if missing.contains(key) { return T("No match found") }
        if e.recipients.isEmpty { return nil }
        return e.recipients.joined(separator: ", ")
    }

    /// The poster plate: metahub's small poster, or the year on the tint's edge.
    private func art(_ e: Page.Winner) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: BP.rXS, style: .continuous).fill(BP.panel2)
            if let poster = e.poster {
                RemoteImage(url: poster)
            } else {
                Text(verbatim: String(e.year)).font(BP.sans(12, .bold)).monospacedDigit().foregroundStyle(BP.inkSubtle)
            }
        }
        .frame(width: BP.px(46), height: BP.px(68))
        .clipShape(RoundedRectangle(cornerRadius: BP.rXS, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: BP.rXS, style: .continuous).stroke(tint.opacity(0.22), lineWidth: 1))
    }

    /// BpAwardWinner.activate.
    private func activate(_ e: Page.Winner, key: String, preferTv: Bool) {
        guard busy == nil else { return }
        if e.imdb == nil && !hasKey {
            // One press, one answer: the press goes to the surface that fixes it.
            if let onOpenSettings { onOpenSettings() }
            return
        }
        busy = key
        missing.remove(key)
        let from: String = filterKey
        let p = ProfilesStore.shared.active
        let profileId: String = p?.id ?? "default"
        let linked: Bool = p?.linked ?? true
        let imdb: AnyJSON = e.imdb.map { AnyJSON.string($0) } ?? AnyJSON.null
        Task {
            let out: Outcome? = try? await HarborEngine.shared.call("discoverRoom.awardOpen", [e.workTitle, e.year, imdb, preferTv, profileId, linked])
            busy = nil
            // A lookup answering after the filters changed must not open a title off screen.
            guard from == filterKey else { return }
            let status: String = out?.status ?? "missing"
            switch status {
            case "open":
                if let m = out?.meta { detail = m }
            case "nokey":
                onOpenSettings?()
            default:
                missing.insert(key)
            }
        }
    }
}
