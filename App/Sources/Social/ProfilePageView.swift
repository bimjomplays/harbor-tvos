import SwiftUI

/// views/profile/profile.tsx on the TV: the hero (banner, avatar, name, handle, level, presence,
/// stat pills, FriendButton), then the cards a remote can use: what they are watching, featured
/// lists, badges, recent activity, friends and comments. `handle == nil` is the signed-in
/// member's own profile (open-my-profile.ts). Editing a profile stays on the desktop/phone.
struct ProfilePageView: View {
    let handle: String?
    @State private var page: Social.ProfilePage?
    @State private var loading = true
    @State private var comments: Social.CommentPage?
    @State private var friendStatus: String?
    @State private var friendBusy = false
    @State private var friendError = false
    @State private var confirmRemove = false
    @State private var detail: Meta?
    @State private var other: Social.HandleRef?
    @State private var list: Social.ListRef?
    @State private var composing = false
    @State private var draft = ""
    @State private var note: String?
    @FocusState private var focus: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .topLeading) {
            BPAmbientBackground()
            if let banner = page?.summary?.bannerUrl {
                RemoteImage(url: banner).frame(height: BP.px(300)).clipped()
                    .overlay(LinearGradient(colors: [.clear, BP.canvas.opacity(0.7), BP.canvas], startPoint: .top, endPoint: .bottom))
                    .ignoresSafeArea()
            }
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: BP.px(26)) {
                    content
                    Color.clear.frame(height: BP.px(40))
                }
                .padding(.horizontal, BP.gutter)
                .padding(.top, BP.px(page?.summary?.bannerUrl == nil ? 60 : 170))
            }
        }
        .ignoresSafeArea()
        .onExitCommand { dismiss() }
        // (social bug pass) Once, like SharedListView: `.task` re-runs whenever a title, another
        // profile, a list or the comment sheet closes, and that reload dropped the loaded comment
        // pages or, offline, swapped the profile for "Could not load this profile". Retry reloads.
        .task { if page == nil { await load() } }
        .fullScreenCover(item: $detail) { m in DetailView(meta: m) }
        .fullScreenCover(item: $other) { h in ProfilePageView(handle: h.handle) }
        .fullScreenCover(item: $list) { r in SharedListView(ref: r) }
        .fullScreenCover(isPresented: $composing) {
            PhoneTypingSheet(label: "Comments", placeholder: "Leave a comment. No links.", text: $draft,
                             purpose: "Scan this with your phone camera, then write your comment on your phone.",
                             onSubmit: { Task { await postComment() } }, onClose: { composing = false })
        }
        .alert("Remove friend?", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive) { Task { await friendAct("social.friendRemove", arg: page?.summary?.handle ?? "") } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("@\(page?.summary?.handle ?? "") will be removed from your friends. You can add them again later.")
        }
    }

    @ViewBuilder private var content: some View {
        if loading && page == nil {
            HStack(spacing: BP.px(10)) { ProgressView().tint(BP.ink); Text("Loading profile…").font(BP.sans(16)).foregroundStyle(BP.inkMuted) }
                .accessibilityElement(children: .combine)
                .focusable()
        } else if let p = page, p.state == "ready", let s = p.summary {
            hero(s, stats: p.stats ?? [])
            if p.locked == true {
                // profile-states.tsx locked copy.
                SocialEmpty(title: T("%@ keeps this private", s.alias), message: "This member has hidden their showcase, activity and friends from public view.")
            } else {
                if let w = s.watching, let title = w.title { watchingCard(w, title: title) }
                if let about = s.description, !about.isEmpty { section("About") { Text(about).font(BP.sans(15)).foregroundStyle(BP.inkMuted).fixedSize(horizontal: false, vertical: true) } }
                if !s.featuredLists.isEmpty { listsRow(s) }
                if let b = p.badges, !b.isEmpty { badgesRow(b) }
                if let a = p.activity, !a.isEmpty { activityRow(a) }
                if let f = p.friends, !f.isEmpty { friendsRow(f) }
                commentsSection(s)
            }
        } else {
            // profile-states.tsx: "No such captain" / "Could not load this profile".
            let state = page?.state ?? "error"
            if state == "empty" {
                SocialEmpty(title: "No such captain", message: T("We could not find anyone at @%@. The handle may have changed or the profile was removed.", page?.handle ?? handle ?? ""), action: ("Back", { dismiss() }))
            } else if state == "signed-out" || state == "no-handle" {
                SocialEmpty(title: "Sign in to Harbor", message: state == "no-handle" ? "Claim a handle on desktop Harbor or harbor.site to get a public profile." : "Your Harbor account's profile shows here once this TV is signed in (Settings → Account).", action: ("Back", { dismiss() }))
            } else {
                SocialEmpty(title: "Could not load this profile", message: "Something went wrong reaching Harbor. Check your connection and try again.", action: ("Retry", { Task { await load() } }))
            }
        }
    }

    // MARK: hero (profile-hero.tsx)

    private func hero(_ s: Social.Summary, stats: [Social.Stat]) -> some View {
        VStack(alignment: .leading, spacing: BP.px(16)) {
            HStack(alignment: .center, spacing: BP.px(20)) {
                SocialAvatar(url: s.avatarUrl, name: s.alias, size: BP.px(108), online: s.isOwner ? nil : s.online)
                VStack(alignment: .leading, spacing: BP.px(5)) {
                    HStack(spacing: BP.px(8)) {
                        Text(s.alias).font(BP.display(36, .medium)).foregroundStyle(BP.ink).lineLimit(1)
                        if s.verified { Image(systemName: "checkmark.seal.fill").foregroundStyle(BP.accent).font(.system(size: BP.px(20))).accessibilityLabel(Text(T("Verified"))) }
                    }
                    HStack(spacing: BP.px(10)) {
                        Text("@\(s.handle)").font(BP.sans(15, .medium)).foregroundStyle(BP.inkMuted)
                        Text(T("Level") + " \(Int(s.level))").font(BP.sans(12, .bold)).foregroundStyle(BP.canvas)
                            .padding(.horizontal, BP.px(8)).padding(.vertical, BP.px(3)).background(Capsule().fill(BP.accent))
                        Text(s.online ? "Online now" : "Offline").font(BP.sans(13, .semibold)).foregroundStyle(s.online ? BP.live : BP.inkSubtle)
                    }
                    if let slogan = s.slogan, !slogan.isEmpty { Text(slogan).font(BP.sans(15)).foregroundStyle(BP.inkMuted).lineLimit(2) }
                    let facts = [s.pronouns, s.location].compactMap { $0 }.filter { !$0.isEmpty }
                    if !facts.isEmpty { Text(facts.joined(separator: " · ")).font(BP.sans(13)).foregroundStyle(BP.inkSubtle) }
                }
            }
            if !stats.isEmpty {
                HStack(spacing: BP.px(10)) {
                    ForEach(stats) { st in
                        VStack(spacing: BP.px(3)) {
                            Text(st.value).font(BP.sans(17, .semibold)).foregroundStyle(BP.ink).monospacedDigit()
                            Text(st.label.uppercased()).font(BP.sans(10, .bold)).tracking(1.2).foregroundStyle(BP.inkMuted)
                        }
                        .padding(.horizontal, BP.px(16)).padding(.vertical, BP.px(10))
                        .background(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).fill(BP.surface.opacity(0.9)))
                    }
                }
            }
            HStack(spacing: BP.px(10)) {
                Button { dismiss() } label: { Label("Back", systemImage: "chevron.backward") }
                    .buttonStyle(BPActionStyle()).focused($focus, equals: "back")
                if !s.isOwner { friendButton(s) }
            }
            .focusSection()
            if let note { BPNote(text: note, tone: BP.danger) }
        }
    }

    /// profile-hero.tsx FriendButton: Add friend / Requested / Accept request / Friends.
    @ViewBuilder private func friendButton(_ s: Social.Summary) -> some View {
        let rel = friendStatus ?? s.friendStatus
        switch rel {
        case "blocked":
            EmptyView()
        case "friends":
            Button {
                guard !friendBusy else { return }
                confirmRemove = true
            } label: { Label(friendBusy ? "Removing..." : "Friends", systemImage: "checkmark") }
                .buttonStyle(BPActionStyle(busy: friendBusy))
        case "incoming":
            Button { Task { await friendAct("social.friendAccept", arg: s.friendEdgeId ?? "") } } label: {
                Label(friendBusy ? "Accepting..." : "Accept request", systemImage: "checkmark")
            }
            .buttonStyle(BPActionStyle(primary: true, busy: friendBusy)).disabled(s.friendEdgeId == nil)
        case "outgoing":
            Button { Task { await friendAct("social.friendRemove", arg: s.handle) } } label: {
                Label(friendBusy ? "Canceling..." : "Cancel request", systemImage: "clock")
            }
            .buttonStyle(BPActionStyle(busy: friendBusy))
        default:
            if SocialCenter.shared.me.signedIn {
                Button { Task { await friendAct("social.friendRequest", arg: s.handle) } } label: {
                    Label(friendBusy ? "Sending..." : friendError ? "Try again" : "Add friend", systemImage: "person.badge.plus")
                }
                .buttonStyle(BPActionStyle(primary: true, busy: friendBusy))
            }
        }
    }

    private func friendAct(_ fn: String, arg: String) async {
        guard !friendBusy, !arg.isEmpty else { return }
        friendBusy = true; friendError = false
        defer { friendBusy = false }
        do {
            let r: Social.FriendState = try await HarborEngine.shared.call(fn, [arg])
            friendStatus = r.friendStatus
        } catch {
            friendError = true
        }
    }

    // MARK: cards

    private func section<C: View>(_ title: String, @ViewBuilder _ body: () -> C) -> some View {
        VStack(alignment: .leading, spacing: BP.px(12)) {
            Text(T(title)).font(BP.sans(20, .semibold)).foregroundStyle(BP.ink)
            body()
        }
    }

    /// watch-now-card.tsx
    private func watchingCard(_ w: Social.Watching, title: String) -> some View {
        HStack(spacing: BP.px(14)) {
            if let p = w.posterUrl { RemoteImage(url: p).frame(width: BP.px(54), height: BP.px(80)).clipShape(RoundedRectangle(cornerRadius: BP.rXS)) }
            VStack(alignment: .leading, spacing: BP.px(3)) {
                Text(T(w.kind == "party" ? "Watch party" : (w.paused == true ? "Paused" : "Now playing"))).textCase(.uppercase).font(BP.sans(11, .bold)).tracking(2).foregroundStyle(BP.live)
                Text(title).font(BP.sans(18, .semibold)).foregroundStyle(BP.ink)
                if let sub = w.sub { Text(sub).font(BP.sans(13)).foregroundStyle(BP.inkMuted) }
            }
        }
        .padding(BP.px(14))
        .background(RoundedRectangle(cornerRadius: BP.rMD, style: .continuous).fill(BP.panel.opacity(0.85)))
    }

    private func listsRow(_ s: Social.Summary) -> some View {
        section("Lists") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: BP.px(16)) {
                    ForEach(s.featuredLists) { l in
                        Button { list = Social.ListRef(handle: s.handle, listId: l.id) } label: {
                            VStack(alignment: .leading, spacing: BP.px(8)) {
                                HStack(spacing: BP.px(4)) {
                                    ForEach(Array(l.posters.prefix(4).enumerated()), id: \.offset) { _, p in
                                        RemoteImage(url: p).frame(width: BP.px(56), height: BP.px(84)).clipShape(RoundedRectangle(cornerRadius: BP.px(4)))
                                    }
                                }
                                Text(l.name).font(BP.sans(15, .semibold)).foregroundStyle(BP.ink).lineLimit(1)
                                Text(T(l.count == 1 ? "%lld title" : "%lld titles", l.count)).font(BP.sans(12)).foregroundStyle(BP.inkMuted)
                            }
                            .padding(BP.px(12)).frame(width: BP.px(260), alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).fill(BP.panel.opacity(0.85)))
                        }
                        .buttonStyle(BPTileStyle(radius: BP.rSM))
                    }
                }
                .padding(.vertical, BP.px(14))
            }
        }
    }

    private func badgesRow(_ badges: [Social.Badge]) -> some View {
        section("Badges") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: BP.px(12)) {
                    ForEach(badges) { b in
                        Button {} label: {
                            VStack(spacing: BP.px(6)) {
                                if let icon = b.iconUrl { RemoteImage(url: icon, contentMode: .fit).frame(width: BP.px(48), height: BP.px(48)) }
                                Text(b.name).font(BP.sans(12, .semibold)).foregroundStyle(BP.ink).lineLimit(1)
                                if let t = b.tier { Text(t.capitalized).font(BP.sans(10, .bold)).foregroundStyle(BP.inkSubtle) }
                            }
                            .padding(BP.px(10)).frame(width: BP.px(120))
                            .background(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).fill(BP.panel.opacity(0.85)))
                        }
                        .buttonStyle(BPTileStyle(radius: BP.rSM))
                    }
                }
                .padding(.vertical, BP.px(14))
            }
        }
    }

    /// recent-activity.tsx: watched / finished / rated / favorited, newest first.
    private func activityRow(_ items: [Social.Activity]) -> some View {
        section("Recent activity") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: BP.px(14)) {
                    ForEach(items) { a in
                        Button { open(a) } label: {
                            VStack(alignment: .leading, spacing: BP.px(6)) {
                                RemoteImage(url: a.posterUrl).frame(width: BP.px(132), height: BP.px(198)).clipShape(RoundedRectangle(cornerRadius: BP.rXS))
                                Text(activityVerb(a)).font(BP.sans(11, .bold)).tracking(1).foregroundStyle(BP.inkSubtle)
                                Text(a.title).font(BP.sans(13, .semibold)).foregroundStyle(BP.ink).lineLimit(1)
                                Text(Social.ago(iso: a.at)).font(BP.sans(11)).foregroundStyle(BP.inkMuted)
                            }
                            .frame(width: BP.px(132), alignment: .leading)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, BP.px(14))
            }
        }
    }

    private func activityVerb(_ a: Social.Activity) -> String {
        switch a.kind {
        case "finished": return "FINISHED"
        case "rated": return a.rating.map { "RATED \(Int($0))" } ?? "RATED"
        case "favorited": return "FAVORITED"
        case "imported": return "IMPORTED"
        default: return "WATCHED"
        }
    }

    private func open(_ a: Social.Activity) {
        guard let id = a.metaId, !id.hasPrefix("import:") else { return }
        let series = id.range(of: "^(kitsu|mal|anilist|anidb):", options: [.regularExpression, .caseInsensitive]) != nil
            || (a.subtitle?.range(of: #"S\d+\s*E\d+"#, options: .regularExpression) != nil)
        detail = Meta(id: id, type: series ? "series" : "movie", name: a.title, poster: a.posterUrl)
    }

    private func friendsRow(_ friends: [Social.Friend]) -> some View {
        section("Friends") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: BP.px(14)) {
                    ForEach(friends) { f in
                        Button { other = Social.HandleRef(handle: f.handle) } label: {
                            VStack(spacing: BP.px(8)) {
                                SocialAvatar(url: f.avatarUrl, name: f.alias, size: BP.px(72), online: f.online)
                                Text(f.alias).font(BP.sans(13, .semibold)).foregroundStyle(BP.ink).lineLimit(1)
                            }
                            .frame(width: BP.px(110))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, BP.px(14))
            }
        }
    }

    // MARK: comments (comments-section.tsx)

    private func commentsSection(_ s: Social.Summary) -> some View {
        section("Comments") {
            VStack(alignment: .leading, spacing: BP.px(10)) {
                if SocialCenter.shared.me.signedIn {
                    Button { draft = ""; composing = true } label: { Label("Write a comment...", systemImage: "iphone") }
                        .buttonStyle(BPActionStyle())
                }
                if let c = comments {
                    if c.comments.isEmpty {
                        Text("No comments yet. Be the first to say hello.").font(BP.sans(14)).foregroundStyle(BP.inkSubtle)
                    }
                    ForEach(c.comments) { cm in
                        SocialRow(title: cm.authorAlias, subtitle: cm.body, trailing: "\(Social.ago(iso: cm.at))\(cm.likeCount > 0 ? " · ♥ \(Int(cm.likeCount))" : "")", unread: cm.liked) {
                            SocialAvatar(url: cm.authorAvatarUrl, name: cm.authorAlias, size: BP.px(40))
                        } action: {
                            Task { await toggleLike(s.handle, cm) }
                        }
                    }
                    // (social bug pass) use-comments.ts loadMore: the TV only ever showed the first page.
                    if c.nextCursor != nil {
                        Button(loadingMoreComments ? "Loading" : "Load more") { Task { await moreComments(s.handle) } }
                            .buttonStyle(BPActionStyle(busy: loadingMoreComments))
                    }
                }
            }
        }
    }

    @State private var loadingMoreComments = false

    /// use-comments.ts loadMore: the next page appended, total and cursor from the answer.
    private func moreComments(_ handle: String) async {
        guard let cursor = comments?.nextCursor, !loadingMoreComments else { return }
        loadingMoreComments = true
        defer { loadingMoreComments = false }
        guard let next: Social.CommentPage = try? await HarborEngine.shared.call("social.comments", [handle, cursor]),
              comments?.nextCursor == cursor else { return }
        let have = Set(comments?.comments.map(\.id) ?? [])
        comments?.comments.append(contentsOf: next.comments.filter { !have.contains($0.id) })
        if next.total != nil { comments?.total = next.total }
        comments?.nextCursor = next.nextCursor
    }

    private func toggleLike(_ handle: String, _ c: Social.Comment) async {
        guard SocialCenter.shared.me.signedIn else { return }
        guard let r: Social.LikeState = try? await HarborEngine.shared.call("social.commentLike", [handle, c.id, !c.liked]) else { return }
        guard var page = comments, let i = page.comments.firstIndex(where: { $0.id == c.id }) else { return }
        page.comments[i].liked = r.liked
        page.comments[i].likeCount = r.likeCount
        comments = page
    }

    private func postComment() async {
        guard let h = page?.summary?.handle else { return }
        do {
            struct Posted: Decodable { var id: String }
            let _: Posted = try await HarborEngine.shared.call("social.comment", [h, draft])
            note = nil
            draft = ""
            comments = try? await HarborEngine.shared.call("social.comments", [h, String?.none])
        } catch {
            note = Social.message(error)
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        let p: Social.ProfilePage? = try? await HarborEngine.shared.call("social.profile", [handle])
        page = p ?? Social.ProfilePage(state: "error", handle: handle)
        friendStatus = nil
        if let h = p?.summary?.handle, p?.locked != true {
            comments = try? await HarborEngine.shared.call("social.comments", [h, String?.none])
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { if focus == nil { focus = "back" } }
    }
}
