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

    var body: some View {
        SocialPage(eyebrow: "Account", title: T("Notifications")) {
            HStack(spacing: BP.px(10)) {
                Button { Task { await center.markAllRead() } } label: { Label("Mark all read", systemImage: "checkmark.circle") }
                    .buttonStyle(BPActionStyle()).disabled((center.notifications?.unread ?? 0) == 0)
                Button { Task { await center.dismiss(center.notifications?.items.map(\.id) ?? [], markRead: true) } } label: { Label("Clear all", systemImage: "xmark.circle") }
                    .buttonStyle(BPActionStyle()).disabled((center.notifications?.items.isEmpty ?? true))
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
                    SocialRow(title: item.title, subtitle: item.body, trailing: Social.ago(ms: item.createdAt), unread: !item.read) {
                        icon(item)
                    } action: {
                        open(item)
                    }
                }
            } else if !center.me.signedIn {
                SocialEmpty(title: "Sign in to Harbor", message: "Notifications arrive once this TV is signed in to a Harbor account.")
            } else {
                HStack(spacing: BP.px(10)) { ProgressView().tint(BP.ink); Text("Loading…").foregroundStyle(BP.inkMuted) }.focusable()
            }
        }
        .task { await center.refresh() }
        .fullScreenCover(item: $group) { g in GroupPageView(id: g.id) }
        .fullScreenCover(item: $profile) { h in ProfilePageView(handle: h.handle) }
        .fullScreenCover(item: $detail) { n in NotificationDetailView(notif: n) }
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
            Button { busy = p.edgeId; Task { await center.respond(edgeId: p.edgeId, accept: true); busy = nil } } label: { Label("Accept", systemImage: "checkmark") }
                .buttonStyle(BPActionStyle(primary: true)).disabled(busy == p.edgeId)
            Button { busy = p.edgeId; Task { await center.respond(edgeId: p.edgeId, accept: false); busy = nil } } label: { Label("Decline", systemImage: "xmark") }
                .buttonStyle(BPActionStyle()).disabled(busy == p.edgeId)
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
                Image(systemName: name).foregroundStyle(accent ? BP.accent : BP.inkMuted)
            }
        }
        .frame(width: BP.px(44), height: BP.px(44))
    }

    private func open(_ n: Social.Notif) {
        switch n.target.open {
        case "group": if let id = n.target.id { group = Social.GroupRef(id: id) }
        default: detail = n
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
                    Button("Dismiss notification") {
                        Task { await SocialCenter.shared.dismiss([notif.id], markRead: false); dismiss() }
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
