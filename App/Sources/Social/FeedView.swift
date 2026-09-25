import SwiftUI

/// views/feed.tsx on the TV: friends watching right now (watching-strip.tsx, polled every 60 s
/// by use-feed.ts), then friends' activity, newest first, with "Load more". A row's avatar
/// opens the friend's profile; the row opens the title (manga has no reader on the TV yet).
struct FeedView: View {
    @State private var page: Social.FeedPage?
    @State private var watching: [Social.WatchingNow] = []
    @State private var phase = "loading"
    @State private var loadingMore = false
    @State private var detail: Meta?
    @State private var profile: Social.HandleRef?
    /// (review 24) "more" on Load more, "row:<id>" on a row's title. The last page takes Load more
    /// away under the ring: it goes to the first row that page added (else the last row).
    @FocusState private var feedFocus: String?

    var body: some View {
        SocialPage(eyebrow: "Friends", title: T("Activity"),
                   subtitle: page.flatMap { $0.friendCount > 0 ? T("%lld of %lld friends are sharing what they watch.", $0.sharingCount, $0.friendCount) : nil }) {
            if !watching.isEmpty { strip }
            switch phase {
            case "loading":
                HStack(spacing: BP.px(10)) { ProgressView().tint(BP.ink); Text("Loading…").foregroundStyle(BP.inkMuted) }.accessibilityElement(children: .combine).focusable()
            case "error":
                SocialEmpty(title: "Could not load activity", message: "Check your connection and try again.", action: ("Try again", { Task { await load() } }))
            default:
                if let p = page, !p.items.isEmpty {
                    ForEach(p.items) { item in row(item) }
                    if p.nextCursor != nil {
                        Button(loadingMore ? "Loading" : "Load more") { Task { await more() } }
                            .buttonStyle(BPActionStyle(busy: loadingMore))
                            .focused($feedFocus, equals: "more")
                    }
                } else if (page?.friendCount ?? 0) == 0 {
                    SocialEmpty(title: "No friends yet", message: "Add a few friends and their watching, ratings, and favorites land here.")
                } else {
                    SocialEmpty(title: "Nothing here yet", message: "Your friends have not shared anything yet. Activity sharing is off by default.")
                }
            }
        }
        // (social bug pass) Once, like SharedListView: `.task` runs again when a title or a friend's
        // profile closes, and the reload put the spinner over the feed (focus gone, "Load more"
        // pages dropped) or, offline, swapped it for "Could not load activity". Try again reloads.
        .task { if page == nil { await load() } }
        .task {
            // use-feed.ts WATCHING_POLL_MS
            while !Task.isCancelled {
                watching = (try? await HarborEngine.shared.call("social.watching")) ?? watching
                try? await Task.sleep(for: .seconds(60))
            }
        }
        .fullScreenCover(item: $detail) { m in DetailView(meta: m) }
        .fullScreenCover(item: $profile) { h in ProfilePageView(handle: h.handle) }
    }

    private var strip: some View {
        VStack(alignment: .leading, spacing: BP.px(10)) {
            Text("Watching right now").textCase(.uppercase).font(BP.sans(11, .bold)).tracking(2).foregroundStyle(BP.live)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: BP.px(14)) {
                    ForEach(watching) { w in
                        Button { profile = Social.HandleRef(handle: w.handle) } label: {
                            HStack(spacing: BP.px(10)) {
                                SocialAvatar(url: w.avatarUrl, name: w.alias, size: BP.px(44), online: true)
                                VStack(alignment: .leading, spacing: BP.px(2)) {
                                    Text(w.alias).font(BP.sans(14, .semibold)).foregroundStyle(BP.ink)
                                    Text(watchingLine(w)).font(BP.sans(12)).foregroundStyle(BP.inkMuted).lineLimit(1)
                                }
                            }
                            .padding(BP.px(10)).frame(width: BP.px(300), alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).fill(BP.panel.opacity(0.85)))
                        }
                        .buttonStyle(BPTileStyle(radius: BP.rSM))
                    }
                }
                .padding(.vertical, BP.px(12))
            }
        }
    }

    private func watchingLine(_ w: Social.WatchingNow) -> String {
        let title = w.title ?? "Something"
        if w.kind == "party" { return title + " · " + (w.partySize.map { T("In a watch party of %lld", Int($0)) } ?? T("In a watch party")) }
        return w.paused ? title + " · " + T("Paused") : title
    }

    /// feed-row.tsx: "<verb> · <time>" over the title, the rating for "rated".
    private func row(_ item: Social.FeedItem) -> some View {
        let verb: String
        switch item.kind {
        case "finished": verb = T("finished")
        case "favorited": verb = T("favorited")
        case "rated": verb = T("rated")
        default: verb = T("watched")
        }
        return HStack(spacing: BP.px(12)) {
            Button { profile = Social.HandleRef(handle: item.actor.handle) } label: {
                SocialAvatar(url: item.actor.avatarUrl, name: item.actor.alias, size: BP.px(48), online: item.actor.online)
            }
            .buttonStyle(BPTileStyle(radius: BP.px(24)))
            // The avatar opens the actor's profile: it reads their name, not their initials.
            .accessibilityLabel(Text(verbatim: item.actor.alias))
            SocialRow(title: item.title,
                      subtitle: "\(item.actor.alias) \(verb)\(item.subtitle.map { " · \($0)" } ?? "")",
                      trailing: "\(item.rating.map { "★ \(Int($0)) · " } ?? "")\(Social.ago(iso: item.at))",
                      seat: (binding: $feedFocus, value: "row:" + item.id)) {
                RemoteImage(url: item.posterUrl).frame(width: BP.px(40), height: BP.px(60)).clipShape(RoundedRectangle(cornerRadius: BP.px(4)))
            } action: {
                guard item.type != "manga" else { return }
                detail = Meta(id: item.metaId, type: item.type, name: item.title, poster: item.posterUrl)
            }
        }
        .focusSection()
    }

    private func load() async {
        phase = "loading"
        do {
            page = try await HarborEngine.shared.call("social.feed", [String?.none])
            phase = "ready"
        } catch {
            phase = "error"
        }
    }

    private func more() async {
        guard let cursor = page?.nextCursor, !loadingMore else { return }
        loadingMore = true
        defer { loadingMore = false }
        if let next: Social.FeedPage = try? await HarborEngine.shared.call("social.feed", [cursor]) {
            // Only onto the page it continues (a Try again may have reloaded meanwhile), and without
            // repeats: a row shifted across the page edge would give ForEach two rows with one id.
            guard page?.nextCursor == cursor else { return }
            let have = Set(page?.items.map(\.id) ?? [])
            let added: [Social.FeedItem] = next.items.filter { !have.contains($0.id) }
            page?.items.append(contentsOf: added)
            page?.nextCursor = next.nextCursor
            if next.nextCursor == nil, feedFocus == "more", let target = added.first?.id ?? page?.items.last?.id {
                DispatchQueue.main.async { feedFocus = "row:" + target }
            }
        }
    }
}
