import SwiftUI

/// views/shared-list.tsx on the TV: the maker, the list's name and description, its heart
/// (list-heart.tsx), "Save to my lists" (save-list-button.tsx) for someone else's list,
/// "View all" to the maker's profile, and the posters, which open the title.
struct SharedListView: View {
    let ref: Social.ListRef
    @State private var data: Social.SharedList?
    @State private var loading = true
    @State private var note: String?
    @State private var busy = false
    @State private var detail: Meta?
    @State private var profile: Social.HandleRef?
    @Environment(\.dismiss) private var dismiss

    private let columns = Array(repeating: GridItem(.flexible(), spacing: BP.px(18)), count: 6)

    var body: some View {
        ZStack(alignment: .topLeading) {
            BPAmbientBackground()
            if let banner = data?.owner?.bannerUrl {
                RemoteImage(url: banner).frame(height: BP.px(320)).clipped().opacity(0.55)
                    .overlay(LinearGradient(colors: [.clear, BP.canvas], startPoint: .top, endPoint: .bottom))
                    .ignoresSafeArea()
            }
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: BP.px(24)) {
                    content
                    Color.clear.frame(height: BP.px(40))
                }
                .padding(.horizontal, BP.gutter).padding(.top, BP.px(90))
            }
        }
        .ignoresSafeArea()
        .onExitCommand { dismiss() }
        .task { await load() }
        .fullScreenCover(item: $detail) { m in DetailView(meta: m) }
        .fullScreenCover(item: $profile) { h in ProfilePageView(handle: h.handle) }
    }

    @ViewBuilder private var content: some View {
        if let d = data, d.state == "ready", let owner = d.owner, let list = d.list {
            HStack(spacing: BP.px(16)) {
                SocialAvatar(url: owner.avatarUrl, name: owner.alias, size: BP.px(72))
                VStack(alignment: .leading, spacing: BP.px(4)) {
                    Text("A LIST BY \(owner.alias.uppercased())").font(BP.sans(11, .bold)).tracking(2).foregroundStyle(BP.inkSubtle)
                    Text(list.name).font(BP.display(38, .medium)).foregroundStyle(BP.ink).lineLimit(2)
                    Text("\(list.items.count) \(list.items.count == 1 ? "title" : "titles")").font(BP.sans(14)).foregroundStyle(BP.inkMuted)
                }
            }
            if let desc = list.description, !desc.isEmpty {
                Text(desc).font(BP.sans(16)).foregroundStyle(BP.inkMuted).frame(maxWidth: BP.px(900), alignment: .leading)
            }
            HStack(spacing: BP.px(10)) {
                Button { dismiss() } label: { Label("Back", systemImage: "chevron.left") }.buttonStyle(BPActionStyle())
                let canLike = (d.signedIn ?? false) && !owner.isOwner
                Button { Task { await toggleLike(list) } } label: {
                    Label("\(Int(list.likeCount))", systemImage: list.liked ? "heart.fill" : "heart")
                }
                .buttonStyle(BPActionStyle(primary: list.liked)).disabled(!canLike || busy)
                if canLike {
                    Button { Task { await save() } } label: { Label("Save to my lists", systemImage: "square.and.arrow.down") }
                        .buttonStyle(BPActionStyle()).disabled(busy)
                }
                Button { profile = Social.HandleRef(handle: owner.handle) } label: { Label("View all", systemImage: "chevron.right") }
                    .buttonStyle(BPActionStyle())
            }
            .focusSection()
            if let note { BPNote(text: note) }
            LazyVGrid(columns: columns, alignment: .leading, spacing: BP.px(22)) {
                ForEach(list.items) { item in
                    Button {
                        detail = Meta(id: item.id, type: item.type, name: item.name, poster: item.poster)
                    } label: {
                        VStack(alignment: .leading, spacing: BP.px(6)) {
                            RemoteImage(url: item.poster).aspectRatio(2 / 3, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: BP.rXS))
                            Text(item.name).font(BP.sans(13, .semibold)).foregroundStyle(BP.ink).lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        } else if loading {
            HStack(spacing: BP.px(10)) { ProgressView().tint(BP.ink); Text("Loading list…").foregroundStyle(BP.inkMuted) }.focusable()
        } else if data?.state == "missing" {
            // shared-list-states.tsx
            SocialEmpty(title: "This list is gone", message: "The link may be old, or the list is no longer shared.", action: ("Back", { dismiss() }))
        } else {
            SocialEmpty(title: "Could not load this list", message: "Check your connection and try again.", action: ("Try again", { Task { await load() } }))
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        data = try? await HarborEngine.shared.call("social.sharedList", [ref.handle, ref.listId])
    }

    private func toggleLike(_ list: Social.SharedListBody) async {
        busy = true
        defer { busy = false }
        do {
            let r: Social.LikeState = try await HarborEngine.shared.call("social.listLike", [AnyJSON.string(ref.handle), .string(ref.listId), .bool(!list.liked)])
            data?.list?.liked = r.liked
            data?.list?.likeCount = r.likeCount
        } catch {
            note = Social.message(error)
        }
    }

    /// save-list-button.tsx: "Saved", "Already in your lists", or "Your lists are full".
    private func save() async {
        busy = true
        defer { busy = false }
        do {
            let r: Social.SaveResult = try await HarborEngine.shared.call("social.listSave", [ref.handle, ref.listId])
            note = r.already == true ? "Already in your lists." : (r.full == true ? "Your lists are full." : "Saved to your lists.")
        } catch {
            note = Social.message(error)
        }
    }
}

/// Opening a shared list from a code or link: `harbor://list/<handle>/<id>`, a
/// harbor.site/list/… share link, or `handle/listId`, typed on the phone (lib/deep-link.ts
/// parseHarborList / featured-lists.ts listShareUrl).
struct SharedListOpenView: View {
    @State private var text = ""
    @State private var typing = false
    @State private var error: String?
    @State private var open: Social.ListRef?
    @State private var submitted = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SocialPage(eyebrow: "Lists", title: "Open a shared list",
                   subtitle: "Paste the list's share link on your phone, or type the maker's handle and the list id as handle/list.") {
            HStack(spacing: BP.px(10)) {
                Button { typing = true } label: { Label(text.isEmpty ? "Type the link on your phone" : text, systemImage: "iphone") }
                    .buttonStyle(BPActionStyle(primary: true))
                Button("Open") { Task { await go() } }.buttonStyle(BPActionStyle()).disabled(text.isEmpty)
                Button("Back") { dismiss() }.buttonStyle(BPActionStyle())
            }
            .focusSection()
            if let error { BPNote(text: error, tone: BP.danger) }
        }
        .fullScreenCover(isPresented: $typing) {
            PhoneTypingSheet(label: "List link", placeholder: "https://harbor.site/list/handle/list", text: $text,
                             purpose: "Scan this with your phone camera, then paste the shared list's link.",
                             onSubmit: { submitted = true },
                             onClose: {
                                 typing = false
                                 // Present after the typing cover has gone; a present-while-dismissing is dropped on tvOS.
                                 if submitted { submitted = false; DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { Task { await go() } } }
                             })
        }
        .fullScreenCover(item: $open) { r in SharedListView(ref: r) }
    }

    private func go() async {
        let r: Social.ListRef? = try? await HarborEngine.shared.call("social.parseListLink", [text])
        if let r { error = nil; open = r } else { error = "That doesn't look like a shared list link." }
    }
}
