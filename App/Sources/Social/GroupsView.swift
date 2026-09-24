import SwiftUI

/// views/groups.tsx on the TV: invites first (group-invite-banner.tsx), "Your groups", then public
/// groups with the tag chips and a search typed on the phone (use-group-discovery.ts). Creating
/// and customising a group stay on the desktop: they need an image picker and long text.
struct GroupsView: View {
    @State private var data: Social.GroupsPage?
    @State private var loading = true
    @State private var loadingMore = false
    @State private var query = ""
    @State private var tag: String?
    @State private var open: Social.GroupRef?
    @State private var searching = false

    var body: some View {
        SocialPage(eyebrow: "Community", title: T("Groups"),
                   subtitle: T("Find people who watch what you watch. Join a group to share lists, post, and watch together.")) {
            HStack(spacing: BP.px(10)) {
                Button { searching = true } label: {
                    Label(query.isEmpty ? "Search groups by name or tag" : "“\(query)”", systemImage: "magnifyingglass")
                }
                .buttonStyle(BPActionStyle())
                if !query.isEmpty {
                    Button("Clear") { query = ""; Task { await load() } }.buttonStyle(BPActionStyle())
                }
            }
            .focusSection()
            if let tags = data?.topTags, !tags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: BP.px(8)) {
                        chip(T("All"), active: tag == nil) { tag = nil; Task { await load() } }
                        ForEach(tags, id: \.self) { t in
                            chip(t, active: tag == t) { tag = (t == tag ? nil : t); Task { await load() } }
                        }
                    }
                    .padding(.vertical, BP.px(8))
                }
            }
            if let d = data {
                if !d.invites.isEmpty { section("Invites", d.invites) }
                if !d.mine.isEmpty { section("Your groups", d.mine) }
                if d.phase == "error" {
                    SocialEmpty(title: "Could not load groups.", message: "Check your connection and try again.", action: ("Try again", { Task { await load() } }))
                } else if d.groups.isEmpty {
                    SocialEmpty(title: query.isEmpty ? "No public groups yet" : T("No groups match “%@”", query), message: "Groups are made on desktop Harbor or harbor.site.")
                } else {
                    section(!query.isEmpty || tag != nil ? "Results" : (d.mine.isEmpty ? "Public groups" : "Discover more"), d.groups, count: d.total)
                    if d.nextCursor != nil {
                        Button(loadingMore ? "Loading" : "Load more") { Task { await more() } }
                            .buttonStyle(BPActionStyle()).disabled(loadingMore)
                    }
                }
            } else if loading {
                HStack(spacing: BP.px(10)) { ProgressView().tint(BP.ink); Text("Loading…").foregroundStyle(BP.inkMuted) }.focusable()
            }
        }
        .task { await load() }
        .fullScreenCover(item: $open, onDismiss: { Task { await load() } }) { g in GroupPageView(id: g.id) }
        .fullScreenCover(isPresented: $searching) {
            PhoneTypingSheet(label: "Search groups", placeholder: "Search groups by name or tag", text: $query,
                             purpose: "Scan this with your phone camera, then type what to look for.",
                             onClose: { searching = false; Task { await load() } })
        }
    }

    private func chip(_ label: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(label, action: action).buttonStyle(BPActionStyle(primary: active))
    }

    private func section(_ title: String, _ groups: [Social.GroupCard], count: Int? = nil) -> some View {
        VStack(alignment: .leading, spacing: BP.px(12)) {
            HStack(alignment: .lastTextBaseline, spacing: BP.px(8)) {
                Text(T(title)).font(BP.sans(20, .semibold)).foregroundStyle(BP.ink)
                if let count, count > 0 { Text("\(count)").font(BP.sans(14)).foregroundStyle(BP.inkSubtle) }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: BP.px(16)), count: 3), alignment: .leading, spacing: BP.px(16)) {
                ForEach(groups) { g in tile(g) }
            }
        }
    }

    /// groups/group-tile.tsx
    private func tile(_ g: Social.GroupCard) -> some View {
        Button { open = Social.GroupRef(id: g.id) } label: {
            HStack(alignment: .top, spacing: BP.px(12)) {
                SocialAvatar(url: g.avatarUrl, name: g.name, size: BP.px(56))
                VStack(alignment: .leading, spacing: BP.px(4)) {
                    Text(g.name).font(BP.sans(16, .semibold)).foregroundStyle(BP.ink).lineLimit(1)
                    Text("\(g.memberCount) \(g.memberCount == 1 ? "member" : "members")\(g.visibility == "invite" ? " · Invite only" : "")\(g.isPending ? " · Invited" : g.isMember ? " · Joined" : "")")
                        .font(BP.sans(12)).foregroundStyle(BP.inkMuted)
                    if let d = g.description, !d.isEmpty { Text(d).font(BP.sans(12)).foregroundStyle(BP.inkSubtle).lineLimit(2) }
                }
                Spacer(minLength: 0)
            }
            .padding(BP.px(14)).frame(maxWidth: .infinity, minHeight: BP.px(110), alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).fill(BP.panel.opacity(0.85)))
        }
        .buttonStyle(BPTileStyle(radius: BP.rSM))
    }

    private func load() async {
        loading = true
        defer { loading = false }
        let q: String? = query.isEmpty ? nil : query
        data = try? await HarborEngine.shared.call("social.groups", [q, tag, String?.none])
    }

    private func more() async {
        guard let cursor = data?.nextCursor, !loadingMore else { return }
        loadingMore = true
        defer { loadingMore = false }
        let q: String? = query.isEmpty ? nil : query
        if let next: Social.GroupsPage = try? await HarborEngine.shared.call("social.groups", [q, tag, cursor]) {
            data?.groups.append(contentsOf: next.groups)
            data?.nextCursor = next.nextCursor
        }
    }
}

/// views/group.tsx on the TV: the hero with Join / Leave (or the invite's Accept / Decline),
/// then Posts (like, and write one on the phone when allowed), Members and About.
struct GroupPageView: View {
    let id: String
    @State private var group: Social.Group?
    @State private var phase = "loading"
    @State private var busy = false
    @State private var error: String?
    @State private var tab = "posts"
    @State private var posts: Social.PostPage?
    @State private var composing = false
    @State private var draft = ""
    @State private var profile: Social.HandleRef?
    @State private var confirmLeave = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SocialPage(eyebrow: "Group", title: group?.name ?? T(phase == "error" ? "Group unavailable" : "Loading…"),
                   subtitle: group.map { "\($0.memberCount) " + T($0.memberCount == 1 ? "member" : "members") + " · " + T($0.visibility == "invite" ? "Invite only" : "Public group") }) {
            if phase == "error" {
                SocialEmpty(title: "This group could not be loaded.", message: error ?? "It may be invite only, or it no longer exists.", action: ("Try again", { Task { await load() } }))
            } else if let g = group {
                actions(g)
                if let error { BPNote(text: error, tone: BP.danger) }
                HStack(spacing: BP.px(8)) {
                    tabButton("posts", T("Posts"))
                    tabButton("members", T("Members") + " (\(g.memberCount))")
                    tabButton("about", T("About"))
                }
                .focusSection()
                switch tab {
                case "members": members(g)
                case "about": about(g)
                default: postsView(g)
                }
            } else {
                HStack(spacing: BP.px(10)) { ProgressView().tint(BP.ink); Text("Loading…").foregroundStyle(BP.inkMuted) }.focusable()
            }
        }
        .task { await load() }
        .fullScreenCover(item: $profile) { h in ProfilePageView(handle: h.handle) }
        .fullScreenCover(isPresented: $composing) {
            PhoneTypingSheet(label: "Post", placeholder: group.map { T("Share something with %@", $0.name) } ?? "Share something with the group", text: $draft,
                             purpose: "Scan this with your phone camera, then write your post on your phone.",
                             onSubmit: { Task { await post() } }, onClose: { composing = false })
        }
        .alert("Leave this group?", isPresented: $confirmLeave) {
            Button("Leave", role: .destructive) { Task { await leave() } }
            Button("Cancel", role: .cancel) {}
        }
    }

    @ViewBuilder private func actions(_ g: Social.Group) -> some View {
        HStack(spacing: BP.px(10)) {
            Button { dismiss() } label: { Label("Back", systemImage: "chevron.left") }.buttonStyle(BPActionStyle())
            if g.isPending {
                // group-invite-banner.tsx
                Button("Accept") { Task { await respond(true) } }.buttonStyle(BPActionStyle(primary: true)).disabled(busy)
                Button("Decline") { Task { await respond(false) } }.buttonStyle(BPActionStyle()).disabled(busy)
            } else if g.isMember || g.isOwner {
                if g.can.post { Button { draft = ""; composing = true } label: { Label("Write a post", systemImage: "iphone") }.buttonStyle(BPActionStyle()) }
                if !g.isOwner { Button("Leave group") { confirmLeave = true }.buttonStyle(BPActionStyle()).disabled(busy) }
            } else if g.visibility == "public", SocialCenter.shared.me.signedIn {
                Button("Join group") { Task { await join() } }.buttonStyle(BPActionStyle(primary: true)).disabled(busy)
            }
        }
        .focusSection()
    }

    private func tabButton(_ key: String, _ label: String) -> some View {
        Button(label) { tab = key }.buttonStyle(BPActionStyle(primary: tab == key))
    }

    @ViewBuilder private func postsView(_ g: Social.Group) -> some View {
        if let p = posts {
            if p.posts.isEmpty {
                SocialEmpty(title: "Nothing posted yet", message: p.canPost ? "Share what you're watching, drop a recommendation, or announce a watch night." : "Members' posts show here.")
            }
            ForEach(p.posts) { post in
                SocialRow(title: post.author?.alias ?? T("Someone"),
                          subtitle: post.text,
                          trailing: "\(post.pinned ? "Pinned · " : "")\(Social.ago(iso: post.createdAt))\(post.likeCount > 0 ? " · ♥ \(Int(post.likeCount))" : "")",
                          unread: post.liked) {
                    SocialAvatar(url: post.author?.avatarUrl, name: post.author?.alias ?? "?", size: BP.px(40))
                } action: {
                    Task { await like(post) }
                }
            }
            if p.nextCursor != nil {
                Button("Load more") { Task { await morePosts() } }.buttonStyle(BPActionStyle())
            }
        } else {
            ProgressView().tint(BP.ink)
        }
    }

    private func members(_ g: Social.Group) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: BP.px(14)), count: 3), alignment: .leading, spacing: BP.px(14)) {
            ForEach(g.members) { m in
                SocialRow(title: m.alias, subtitle: "@\(m.handle)", trailing: m.role == "member" ? nil : m.role.capitalized) {
                    SocialAvatar(url: m.avatarUrl, name: m.alias, size: BP.px(40), online: m.online)
                } action: {
                    profile = Social.HandleRef(handle: m.handle)
                }
            }
        }
    }

    private func about(_ g: Social.Group) -> some View {
        VStack(alignment: .leading, spacing: BP.px(10)) {
            Text(g.description?.isEmpty == false ? g.description! : T("This group has not written a description yet.")).font(BP.sans(16)).foregroundStyle(BP.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
            if !g.tags.isEmpty { Text(g.tags.map { "#\($0)" }.joined(separator: "  ")).font(BP.sans(14, .semibold)).foregroundStyle(BP.inkSubtle) }
            if let role = g.role { Text("Your role: \(T(role.capitalized))").font(BP.sans(13)).foregroundStyle(BP.inkSubtle) }
        }
        .focusable()
    }

    private func load() async {
        phase = "loading"
        do {
            group = try await HarborEngine.shared.call("social.group", [id])
            phase = "ready"
            posts = try? await HarborEngine.shared.call("social.groupPosts", [id, String?.none])
        } catch {
            self.error = Social.message(error)
            phase = "error"
        }
    }

    private func run(_ body: () async throws -> Void) async {
        busy = true; error = nil
        defer { busy = false }
        do { try await body() } catch { self.error = Social.message(error) }
    }

    private func join() async {
        await run { group = try await HarborEngine.shared.call("social.groupJoin", [id]) }
        posts = try? await HarborEngine.shared.call("social.groupPosts", [id, String?.none])
    }

    private func leave() async {
        await run {
            let _: Bool = try await HarborEngine.shared.call("social.groupLeave", [id])
            dismiss()
        }
    }

    private func respond(_ accept: Bool) async {
        await run {
            let g: Social.Group? = try await HarborEngine.shared.call("social.groupRespond", [AnyJSON.string(id), AnyJSON.bool(accept)])
            if accept, let g { group = g } else if !accept { dismiss() }
        }
    }

    private func like(_ post: Social.Post) async {
        guard SocialCenter.shared.me.signedIn, group?.isMember == true || group?.isOwner == true else { return }
        guard let next: Social.Post = try? await HarborEngine.shared.call("social.groupPostLike", [AnyJSON.string(id), .string(post.id), .bool(!post.liked)]) else { return }
        if let i = posts?.posts.firstIndex(where: { $0.id == post.id }) { posts?.posts[i] = next }
    }

    private func post() async {
        await run {
            let p: Social.Post = try await HarborEngine.shared.call("social.groupPost", [id, draft])
            draft = ""
            let at = posts?.posts.firstIndex(where: { !$0.pinned }) ?? 0
            posts?.posts.insert(p, at: at)
        }
    }

    private func morePosts() async {
        guard let cursor = posts?.nextCursor else { return }
        if let next: Social.PostPage = try? await HarborEngine.shared.call("social.groupPosts", [id, cursor]) {
            posts?.posts.append(contentsOf: next.posts)
            posts?.nextCursor = next.nextCursor
        }
    }
}
