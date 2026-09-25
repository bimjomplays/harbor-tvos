import SwiftUI
import Combine

/// The account area's live state: who is signed in to Harbor and the notification badge
/// (lib/social/use-notification-center.ts polls every 60 s while signed in).
@MainActor
final class SocialCenter: ObservableObject {
    static let shared = SocialCenter()

    @Published private(set) var me = Social.Me(signedIn: false, handle: nil, username: nil, avatar: nil, verified: false)
    @Published private(set) var notifications: Social.Notifications?
    @Published private(set) var badge = 0

    private var poll: Task<Void, Never>?
    private var bag = Set<AnyCancellable>()

    private init() {
        AccountStore.shared.$session.removeDuplicates().receive(on: RunLoop.main).sink { [weak self] _ in
            Task { await self?.refresh() }
        }.store(in: &bag)
    }

    /// use-notification-center.ts: refresh now, then every 60 s.
    func start() {
        guard poll == nil else { return }
        poll = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    /// (account bug pass) Only the newest refresh lands. The 60 s poll's notifications request could
    /// finish after a sign-out or a switch to another profile's account had refreshed, and put the
    /// previous account's notifications and badge back for another minute.
    private var generation = 0

    func refresh() async {
        generation += 1
        let mine = generation
        let m: Social.Me? = try? await HarborEngine.shared.call("social.me")
        guard mine == generation else { return }
        if let m { me = m }
        guard me.signedIn else { notifications = nil; badge = 0; return }
        let n: Social.Notifications? = try? await HarborEngine.shared.call("social.notifications")
        guard mine == generation, let n else { return }
        notifications = n
        badge = n.badge
    }

    /// use-notification-center.ts markRead: optimistic, then the server.
    func markAllRead() async {
        if var n = notifications {
            for i in n.items.indices { n.items[i].read = true }
            n.unread = 0
            n.badge = n.pending.count
            notifications = n
            badge = n.badge
        }
        _ = try? await HarborEngine.shared.callJSON("social.notificationsMarkRead")
    }

    /// dismiss / clearAll (clearAll also marks everything read).
    func dismiss(_ ids: [String], markRead: Bool) async {
        _ = try? await HarborEngine.shared.callJSON("social.notificationsDismiss", [.array(ids.map { .string($0) }), .bool(markRead)])
        await refresh()
    }

    func respond(edgeId: String, accept: Bool) async {
        if var n = notifications {
            n.pending.removeAll { $0.edgeId == edgeId }
            n.badge = n.unread + n.pending.count
            notifications = n
            badge = n.badge
        }
        _ = try? await HarborEngine.shared.callJSON(accept ? "social.friendAccept" : "social.friendDecline", [.string(edgeId)])
        await refresh()
    }
}

/// The top-bar entry to the account area (chrome/topbar.tsx NotificationCenter bell +
/// TogetherButton, folded into one control on the TV): a bell with upstream's badge, which
/// turns into the room glyph while a Watch Together room is open.
struct AccountMenuButton: View {
    @ObservedObject private var center = SocialCenter.shared
    @ObservedObject private var together = TogetherModel.shared
    @State private var open = false

    var body: some View {
        Button { open = true } label: {
            Image(systemName: together.view.inSession ? "person.2.wave.2.fill" : "bell.fill")
                .font(.system(size: BP.px(17), weight: .semibold))
        }
        .buttonStyle(BPTabStyle(active: together.view.inSession))
        .overlay(alignment: .topTrailing) {
            if center.badge > 0 {
                Text(center.badge > 9 ? "9+" : "\(center.badge)")
                    .font(BP.sans(10, .bold)).foregroundStyle(BP.canvas)
                    .padding(.horizontal, BP.px(4))
                    .frame(minWidth: BP.px(17), minHeight: BP.px(17))
                    .background(Capsule().fill(BP.accent))
                    .offset(x: BP.px(4), y: -BP.px(4))
                    .allowsHitTesting(false)
            }
        }
        .accessibilityIdentifier("account-menu")
        .accessibilityLabel(center.badge > 0 ? "Account and notifications, \(center.badge) new" : "Account and notifications")
        .fullScreenCover(isPresented: $open) { AccountMenuView() }
        .task { center.start() }
    }
}

/// chrome/account-menu/account-menu-panel.tsx on the TV: View my profile, Notifications,
/// Activity (views/feed.tsx), Groups (views/groups.tsx), Watch together (the topbar's
/// TogetherButton), a shared list from a link (views/shared-list.tsx), Who's watching and
/// Settings. A kid profile gets none of the social items, as upstream (`!kid`).
struct AccountMenuView: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject private var center = SocialCenter.shared
    @ObservedObject private var together = TogetherModel.shared
    @ObservedObject private var profiles = ProfilesStore.shared
    @Environment(\.dismiss) private var dismiss

    private enum Sheet: String, Identifiable { case profile, notifications, feed, groups, together, list; var id: String { rawValue } }
    @State private var sheet: Sheet?
    @FocusState private var focus: String?

    private var kid: Bool { profiles.active?.kid != nil }

    var body: some View {
        ZStack {
            BPAmbientBackground()
            BP.void_.opacity(0.55).ignoresSafeArea()
            VStack(alignment: .leading, spacing: BP.px(18)) {
                header
                VStack(alignment: .leading, spacing: BP.px(8)) {
                    if !kid {
                        if center.me.signedIn {
                            item("View my profile", "person.crop.circle", key: "profile") { sheet = .profile }
                            item("Notifications", "bell", key: "notifications", badge: center.badge) { sheet = .notifications }
                            item("Activity", "person.2", key: "feed") { sheet = .feed }
                        }
                        item("Groups", "person.3", key: "groups") { sheet = .groups }
                        item("Watch together", "play.rectangle.on.rectangle", key: "together", note: togetherNote) { sheet = .together }
                        item("Open a shared list", "list.star", key: "list") { sheet = .list }
                    }
                    item("Who's watching?", "person.2.circle", key: "who") { dismiss(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { app.switchProfile() } }
                    item(center.me.signedIn || kid ? "Settings" : "Sign in to Harbor", center.me.signedIn || kid ? "gearshape" : "person.badge.key", key: "settings") {
                        app.room = .settings
                        dismiss()
                    }
                }
                .focusSection()
            }
            .padding(BP.px(34))
            .frame(width: BP.px(560))
            .background(RoundedRectangle(cornerRadius: BP.rLG, style: .continuous).fill(BP.panel))
            .overlay(RoundedRectangle(cornerRadius: BP.rLG, style: .continuous).stroke(BP.edge, lineWidth: 1))
        }
        .onExitCommand { dismiss() }
        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { focus = kid ? "who" : (center.me.signedIn ? "profile" : "groups") } }
        .task { await center.refresh() }
        .fullScreenCover(item: $sheet, onDismiss: { Task { await center.refresh() } }) { s in
            switch s {
            case .profile: ProfilePageView(handle: nil)
            case .notifications: NotificationsView()
            case .feed: FeedView()
            case .groups: GroupsView()
            case .together: TogetherView()
            case .list: SharedListOpenView()
            }
        }
    }

    private var togetherNote: String? {
        let v = together.view
        if v.inSession, let room = v.room { return T("Room code") + " " + room + " · " + T("%lld watching", v.participants.count) }
        if v.state == "connecting" { return T("Connecting…") }
        return nil
    }

    private var header: some View {
        HStack(spacing: BP.px(14)) {
            if let p = profiles.active { ProfileFace(profile: p, size: BP.px(52)) }
            VStack(alignment: .leading, spacing: BP.px(3)) {
                Text(profiles.active?.name ?? "Harbor").font(BP.display(24)).foregroundStyle(BP.ink)
                if center.me.signedIn {
                    Text(center.me.handle.map { "@\($0)" } ?? (center.me.username ?? "")).font(BP.sans(14)).foregroundStyle(BP.inkMuted)
                } else if !kid {
                    Text("Not signed in to a Harbor account").font(BP.sans(14)).foregroundStyle(BP.inkSubtle)
                }
            }
        }
    }

    private func item(_ label: String, _ icon: String, key: String, badge: Int = 0, note: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: BP.px(12)) {
                Image(systemName: icon).frame(width: BP.px(24))
                VStack(alignment: .leading, spacing: BP.px(2)) {
                    Text(T(label))
                    if let note { Text(note).font(BP.sans(12)).foregroundStyle(BP.inkMuted) }
                }
                Spacer()
                if badge > 0 {
                    Text(badge > 9 ? "9+" : "\(badge)").font(BP.sans(11, .bold)).foregroundStyle(BP.canvas)
                        .padding(.horizontal, BP.px(6)).frame(minHeight: BP.px(18)).background(Capsule().fill(BP.accent))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(BPActionStyle())
        .focused($focus, equals: key)
    }
}
