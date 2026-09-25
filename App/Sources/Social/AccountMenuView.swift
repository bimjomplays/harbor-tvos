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
        // (perf/memory pass) Publish only on a change: this runs every 60 s for every profile.
        if let m, m != me { me = m }
        guard me.signedIn else {
            if notifications != nil { notifications = nil }
            if badge != 0 { badge = 0 }
            return
        }
        let n: Social.Notifications? = try? await HarborEngine.shared.call("social.notifications")
        guard mine == generation, let n else { return }
        if n != notifications { notifications = n }
        if badge != n.badge { badge = n.badge }
    }

    /// use-notification-center.ts markRead: optimistic, then the server.
    func markAllRead() async {
        // markRead: `if (!unread) return` — closing the center with nothing unread sends nothing.
        guard (notifications?.unread ?? 0) > 0 else { return }
        // A poll already in flight read the unread state from before this; it must not land.
        generation += 1
        if var n = notifications {
            for i in n.items.indices { n.items[i].read = true }
            n.unread = 0
            n.badge = n.pending.count
            notifications = n
            badge = n.badge
        }
        _ = try? await HarborEngine.shared.callJSON("social.notificationsMarkRead")
        // (social pass) A poll that started while the server was still marking read the old unread
        // state; it would bring the badge back for a minute.
        generation += 1
    }

    /// dismiss / clearAll (clearAll also marks everything read).
    /// (social pass) Optimistic like use-notification-center.ts (dismissNotifs hides the rows at once):
    /// the row stayed until the refresh answered, and offline, where that refresh fails, for good.
    func dismiss(_ ids: [String], markRead: Bool) async {
        generation += 1
        if var n = notifications {
            let gone = Set(ids)
            n.items.removeAll { gone.contains($0.id) }
            if markRead { for i in n.items.indices { n.items[i].read = true } }
            n.unread = n.items.filter { !$0.read }.count
            n.badge = n.unread + n.pending.count
            notifications = n
            badge = n.badge
        }
        _ = try? await HarborEngine.shared.callJSON("social.notificationsDismiss", [.array(ids.map { .string($0) }), .bool(markRead)])
        await refresh()
    }

    func respond(edgeId: String, accept: Bool) async {
        generation += 1   // an in-flight poll would put the answered request back until the next one
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
                    .accessibilityHidden(true)
            }
        }
        .accessibilityIdentifier("account-menu")
        // notification-center.tsx aria-label t("Notifications"), after the account menu it opens; the
        // badge count follows. (The English-only "Account and notifications" had no catalog key.)
        .accessibilityLabel(Text(verbatim: "\(T("Account")), \(T("Notifications"))"))
        .accessibilityValue(Text(verbatim: center.badge > 0 ? "\(center.badge)" : ""))
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
    /// The open cover is the notification center: closing it marks everything read.
    @State private var readOnClose = false
    @FocusState private var focus: String?
    /// (device-flow pass 4) onAppear also runs when a page opened from here closes (Groups,
    /// Notifications, Watch together…): the ring went back to its item, then 0.12 s later was
    /// pulled up to "View my profile". The seed is placed once, when the menu opens.
    @State private var seeded = false

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
                            item("Notifications", "bell", key: "notifications", badge: center.badge) { readOnClose = true; sheet = .notifications }
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
        .onAppear {
            guard !seeded else { return }
            seeded = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { focus = kid ? "who" : (center.me.signedIn ? "profile" : "groups") }
        }
        .task {
            await center.refresh()
            // (social pass) The refresh can change which items exist (signed out elsewhere: "View my
            // profile" goes, taking the seeded ring with it); seed again when nothing holds it.
            if focus == nil && sheet == nil { focus = kid ? "who" : (center.me.signedIn ? "profile" : "groups") }
        }
        .fullScreenCover(item: $sheet, onDismiss: {
            // (settings/social bug pass) notification-center.tsx: closing the center marks everything
            // read (`if (!open && wasOpen.current) void nc.markRead()`). The TV never did, so the bell
            // kept its badge for notifications the viewer had just read.
            let read = readOnClose
            readOnClose = false
            Task {
                if read { await center.markAllRead() }
                await center.refresh()
            }
        }) { s in
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
                Image(systemName: icon).frame(width: BP.px(24)).accessibilityHidden(true)
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
