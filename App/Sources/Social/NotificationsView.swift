import SwiftUI

/// components/notification-center/notification-center.tsx on the TV: friend requests with
/// Accept / Decline, then the merged theme + social feed. A row opens its group or the
/// member's own profile (openNotif / detailAction); anything else opens its detail card,
/// which also offers Dismiss. "Mark all read" and "Clear all" are upstream's header actions.
struct NotificationsView: View {
    @ObservedObject private var center = SocialCenter.shared
    @State private var detail: Social.Notif?
    @State private var group: Social.GroupRef?
    @State private var profile: Social.HandleRef?
    @State private var busy: String?
    /// The first refresh has answered (or failed): offline, "Loading…" otherwise stayed up for good.
    @State private var tried = false
    /// (review 12) Where the ring goes when the row holding it leaves (Accept, Decline, Dismiss).
    @FocusState private var focus: String?
    /// The notification whose detail is up, and where its row sat.
    @State private var opened: (id: String, index: Int)?

    private var noUnread: Bool { (center.notifications?.unread ?? 0) == 0 }
    private var noItems: Bool { center.notifications?.items.isEmpty ?? true }

    var body: some View {
        SocialPage(eyebrow: "Account", title: T("Notifications")) {
            // (social pass) Both used to disable themselves once they had done their job, throwing the
            // ring off; after Clear all with no friend requests nothing on the page could take it.
            // They dim and ignore the press instead.
            HStack(spacing: BP.px(10)) {
                Button {
                    guard !noUnread else { return }
                    Task { await center.markAllRead() }
                } label: { Label("Mark all read", systemImage: "checkmark.circle") }
                    .buttonStyle(BPActionStyle(busy: noUnread))
                    .focused($focus, equals: "mark-read")
                Button {
                    guard !noItems else { return }
                    let ids: [String] = center.notifications?.items.map(\.id) ?? []
                    Task { await center.dismiss(ids, markRead: true) }
                } label: { Label("Clear all", systemImage: "xmark.circle") }
                    .buttonStyle(BPActionStyle(busy: noItems))
                    .focused($focus, equals: "clear-all")
            }
            .focusSection()
            if let n = center.notifications {
                if !n.pending.isEmpty {
                    Text("Friend requests").font(BP.sans(18, .semibold)).foregroundStyle(BP.ink)
                    ForEach(n.pending) { p in requestRow(p) }
                }
                if n.items.isEmpty && n.pending.isEmpty {
                    SocialEmpty(title: "You are all caught up.", message: "Friend requests, comments, badges and group news land here.")
                }
                ForEach(n.items) { item in
                    SocialRow(title: item.title, subtitle: item.body, trailing: Social.ago(ms: item.createdAt), unread: !item.read,
                              seat: (binding: $focus, value: "item:" + item.id)) {
                        icon(item)
                    } action: {
                        open(item)
                    }
                }
            } else if !center.me.signedIn {
                SocialEmpty(title: "Sign in to Harbor", message: "Notifications arrive once this TV is signed in to a Harbor account.")
            } else if !tried {
                HStack(spacing: BP.px(10)) { ProgressView().tint(BP.ink); Text("Loading…").foregroundStyle(BP.inkMuted) }.accessibilityElement(children: .combine).focusable()
            } else {
                SocialEmpty(title: "Notifications", message: "Check your connection and try again.", action: ("Try again", {
                    tried = false
                    Task { await center.refresh(); tried = true }
                }))
            }
        }
        .task { await center.refresh(); tried = true }
        .fullScreenCover(item: $group) { g in GroupPageView(id: g.id) }
        .fullScreenCover(item: $profile) { h in ProfilePageView(handle: h.handle) }
        .fullScreenCover(item: $detail, onDismiss: { settleAfterDetail() }) { n in NotificationDetailView(notif: n) }
    }

    /// (review 12) A dismissed notification's row is gone when its detail closes, and tvOS had nowhere
    /// to put the ring back: it goes to the row now in its place (else the first request, else the
    /// header's first action).
    private func settleAfterDetail() {
        guard let o = opened else { return }
        opened = nil
        let items: [Social.Notif] = center.notifications?.items ?? []
        guard !items.contains(where: { $0.id == o.id }) else { return }
        let firstRequest: String? = center.notifications?.pending.first.map { (p: Social.Pending) -> String in "req:" + p.edgeId }
        let target: String = items.isEmpty ? (firstRequest ?? "mark-read") : "item:" + items[min(o.index, items.count - 1)].id
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { focus = target }
    }

    /// (review 12) An answered request's row goes at once (SocialCenter.respond is optimistic) with the
    /// ring on its Accept or Decline: the next request's profile tile takes it (not its Accept, where a
    /// double press would answer that one too), else the first notification, else the header's first action.
    private func seatAfterAnswering(_ edgeId: String) -> String {
        let pending: [Social.Pending] = center.notifications?.pending ?? []
        let rest: [Social.Pending] = pending.filter { $0.edgeId != edgeId }
        if let at = pending.firstIndex(where: { $0.edgeId == edgeId }), !rest.isEmpty {
            return "req:" + rest[min(at, rest.count - 1)].edgeId
        }
        if let first = center.notifications?.items.first { return "item:" + first.id }
        return "mark-read"
    }

    /// notification-rows.tsx RequestRow.
    private func requestRow(_ p: Social.Pending) -> some View {
        HStack(spacing: BP.px(12)) {
            Button { profile = Social.HandleRef(handle: p.handle) } label: {
                HStack(spacing: BP.px(12)) {
                    SocialAvatar(url: p.avatarUrl, name: p.alias, size: BP.px(44))
                    VStack(alignment: .leading, spacing: BP.px(2)) {
                        Text(p.alias).font(BP.sans(16, .semibold)).foregroundStyle(BP.ink)
                        Text("@" + p.handle + " " + T("wants to connect")).font(BP.sans(13)).foregroundStyle(BP.inkMuted)
                    }
                    Spacer()
                }
                .padding(BP.px(12)).frame(maxWidth: .infinity)
                .background(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).fill(BP.panel.opacity(0.85)))
            }
            .buttonStyle(BPTileStyle(radius: BP.rSM))
            .focused($focus, equals: "req:" + p.edgeId)
            Button {
                guard busy != p.edgeId else { return }
                let next: String = seatAfterAnswering(p.edgeId)
                busy = p.edgeId; Task { await center.respond(edgeId: p.edgeId, accept: true); busy = nil }
                DispatchQueue.main.async { focus = next }
            } label: { Label("Accept", systemImage: "checkmark") }
                .buttonStyle(BPActionStyle(primary: true, busy: busy == p.edgeId))
            Button {
                guard busy != p.edgeId else { return }
                let next: String = seatAfterAnswering(p.edgeId)
                busy = p.edgeId; Task { await center.respond(edgeId: p.edgeId, accept: false); busy = nil }
                DispatchQueue.main.async { focus = next }
            } label: { Label("Decline", systemImage: "xmark") }
                .buttonStyle(BPActionStyle(busy: busy == p.edgeId))
        }
        .focusSection()
    }

    /// notification-rows.tsx iconFor.
    private func icon(_ n: Social.Notif) -> some View {
        let name: String
        switch n.kind {
        case "downloads": name = "arrow.down.to.line"
        case "stars": name = "star.fill"
        case "mention": name = "at"
        case "friend-request": name = "person.badge.plus"
        case "group-added", "group-post": name = "person.3.fill"
        case "badge-received": name = "rosette"
        case "diagnostics-request": name = "lifepreserver"
        default: name = "bubble.left.fill"
        }
        let accent = ["badge-received", "stars", "downloads", "mention"].contains(n.kind)
        return ZStack {
            Circle().fill(BP.panel2)
            if let cover = n.cover, n.kind == "badge-received" {
                RemoteImage(url: cover, contentMode: .fit).padding(BP.px(6))
            } else {
                Image(systemName: name).foregroundStyle(accent ? BP.accent : BP.inkMuted).accessibilityHidden(true)
            }
        }
        .frame(width: BP.px(44), height: BP.px(44))
    }

    private func open(_ n: Social.Notif) {
        switch n.target.open {
        case "group": if let id = n.target.id { group = Social.GroupRef(id: id) }
        default:
            let index: Int = center.notifications?.items.firstIndex(where: { $0.id == n.id }) ?? 0
            opened = (id: n.id, index: index)
            detail = n
        }
    }
}

/// notification-center.tsx detail pane: the full text, when it came, its one action, Dismiss.
struct NotificationDetailView: View {
    let notif: Social.Notif
    @Environment(\.dismiss) private var dismiss
    @State private var profile: Social.HandleRef?

    var body: some View {
        ZStack {
            BPAmbientBackground()
            BP.void_.opacity(0.6).ignoresSafeArea()
            VStack(alignment: .leading, spacing: BP.px(14)) {
                Text(notif.title).font(BP.display(28)).foregroundStyle(BP.ink)
                if let body = notif.body, !body.isEmpty { Text(body).font(BP.sans(16)).foregroundStyle(BP.inkMuted).fixedSize(horizontal: false, vertical: true) }
                Text(Date(timeIntervalSince1970: notif.createdAt / 1000), format: .dateTime.day().month().year().hour().minute())
                    .font(BP.sans(13)).foregroundStyle(BP.inkSubtle)
                HStack(spacing: BP.px(10)) {
                    if notif.target.open == "profile", let h = notif.target.id, let label = notif.target.label {
                        Button(label) { profile = Social.HandleRef(handle: h) }.buttonStyle(BPActionStyle(primary: true))
                    }
                    // (social pass) Closes at once (the row goes optimistically); it waited for the
                    // network refresh, so offline the press seemed to do nothing for a long while.
                    Button("Dismiss notification") {
                        let id = notif.id
                        Task { await SocialCenter.shared.dismiss([id], markRead: false) }
                        dismiss()
                    }.buttonStyle(BPActionStyle())
                    Button("Back") { dismiss() }.buttonStyle(BPActionStyle())
                }
                .focusSection()
            }
            .padding(BP.px(34)).frame(width: BP.px(640), alignment: .leading)
            .background(RoundedRectangle(cornerRadius: BP.rLG, style: .continuous).fill(BP.panel))
        }
        .onExitCommand { dismiss() }
        .fullScreenCover(item: $profile) { h in ProfilePageView(handle: h.handle) }
    }
}
