import Foundation
import SwiftUI

/// Wire types for engine/social.ts. Every optional here is optional on the wire; numbers that
/// can be fractional stay Double.
enum Social {
    struct Me: Decodable, Equatable {
        var signedIn: Bool
        var handle: String?
        var username: String?
        var avatar: String?
        var verified: Bool
    }

    // ---- profile (views/profile/profile-types.ts, reduced by engine/social.ts profile())
    struct Watching: Decodable, Equatable {
        var kind: String?
        var title: String?
        var sub: String?
        var posterUrl: String?
        var partySize: Double?
        var paused: Bool?
    }

    struct ListCard: Decodable, Equatable, Identifiable {
        var id: String
        var name: String
        var description: String?
        var count: Int
        var posters: [String]
        var likeCount: Double
    }

    struct Summary: Decodable, Equatable {
        var handle: String
        var alias: String
        var avatarUrl: String?
        var bannerUrl: String?
        var verified: Bool
        var level: Double
        var xp: Double
        var xpToNext: Double
        var slogan: String?
        var description: String?
        var location: String?
        var pronouns: String?
        var online: Bool
        var memberSince: String?
        var isOwner: Bool
        var friendStatus: String
        var friendEdgeId: String?
        var watching: Watching?
        var featuredLists: [ListCard]
    }

    struct Stat: Decodable, Equatable, Identifiable { var key: String; var label: String; var value: String; var id: String { key } }
    struct Friend: Decodable, Equatable, Identifiable { var handle: String; var alias: String; var avatarUrl: String?; var online: Bool; var slogan: String?; var id: String { handle } }
    struct Badge: Decodable, Equatable, Identifiable { var id: String; var name: String; var description: String?; var iconUrl: String?; var tier: String?; var shown: Bool }
    struct Activity: Decodable, Equatable, Identifiable {
        var id: String
        var kind: String
        var title: String
        var posterUrl: String?
        var subtitle: String?
        var rating: Double?
        var at: String
        var metaId: String?
    }

    struct ProfilePage: Decodable, Equatable {
        var state: String
        var handle: String?
        var locked: Bool?
        var summary: Summary?
        var stats: [Stat]?
        var friends: [Friend]?
        var badges: [Badge]?
        var activity: [Activity]?
    }

    struct Comment: Decodable, Equatable, Identifiable {
        var id: String
        var parentId: String?
        var authorHandle: String
        var authorAlias: String
        var authorAvatarUrl: String?
        var body: String
        var at: String
        var likeCount: Double
        var liked: Bool
    }
    struct CommentPage: Decodable, Equatable { var total: Double?; var nextCursor: String?; var comments: [Comment] }
    struct LikeState: Decodable, Equatable { var likeCount: Double; var liked: Bool }
    struct FriendState: Decodable, Equatable { var friendStatus: String }

    // ---- notifications (use-notification-center.ts)
    struct NotifTarget: Decodable, Equatable { var open: String; var id: String?; var label: String? }
    struct Notif: Decodable, Equatable, Identifiable {
        var id: String
        var kind: String
        var source: String
        var title: String
        var body: String?
        var cover: String?
        var createdAt: Double
        var read: Bool
        var target: NotifTarget
    }
    struct Pending: Decodable, Equatable, Identifiable {
        var edgeId: String
        var handle: String
        var alias: String
        var avatarUrl: String?
        var slogan: String?
        var createdAt: String
        var id: String { edgeId }
    }
    struct Notifications: Decodable, Equatable {
        var authed: Bool
        var items: [Notif]
        var pending: [Pending]
        var unread: Int
        var badge: Int
    }

    // ---- feed (lib/social/feed.ts)
    struct Actor: Decodable, Equatable { var handle: String; var alias: String; var avatarUrl: String?; var online: Bool }
    struct FeedItem: Decodable, Equatable, Identifiable {
        var id: String
        var kind: String
        var title: String
        var posterUrl: String?
        var subtitle: String?
        var rating: Double?
        var at: String
        var metaId: String
        var type: String
        var actor: Actor
    }
    struct FeedPage: Decodable, Equatable { var items: [FeedItem]; var nextCursor: String?; var friendCount: Int; var sharingCount: Int }
    struct WatchingNow: Decodable, Equatable, Identifiable {
        var handle: String
        var alias: String
        var avatarUrl: String?
        var since: String?
        var kind: String
        var title: String?
        var sub: String?
        var posterUrl: String?
        var partySize: Double?
        var paused: Bool
        var id: String { handle }
    }

    // ---- groups (lib/social/groups.ts)
    struct GroupCard: Decodable, Equatable, Identifiable, Hashable {
        var id: String
        var name: String
        var description: String?
        var avatarUrl: String?
        var visibility: String
        var tags: [String]
        var memberCount: Int
        var isMember: Bool
        var isOwner: Bool
        var isPending: Bool
        var ownerAlias: String?
    }
    struct GroupsPage: Decodable, Equatable {
        var signedIn: Bool
        var mine: [GroupCard]
        var invites: [GroupCard]
        var groups: [GroupCard]
        var topTags: [String]
        var total: Int
        var nextCursor: String?
        var phase: String
    }
    /// lib/social/groups.ts GroupPerms. The server's own `can` wins upstream; a field it leaves out is false.
    struct GroupPerms: Decodable, Equatable {
        var invite = false, post = false, moderatePosts = false, manageRoles = false, kick = false, editGroup = false, deleteGroup = false
        private enum K: String, CodingKey { case invite, post, moderatePosts, manageRoles, kick, editGroup, deleteGroup }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: K.self)
            invite = (try? c.decodeIfPresent(Bool.self, forKey: .invite)) ?? false
            post = (try? c.decodeIfPresent(Bool.self, forKey: .post)) ?? false
            moderatePosts = (try? c.decodeIfPresent(Bool.self, forKey: .moderatePosts)) ?? false
            manageRoles = (try? c.decodeIfPresent(Bool.self, forKey: .manageRoles)) ?? false
            kick = (try? c.decodeIfPresent(Bool.self, forKey: .kick)) ?? false
            editGroup = (try? c.decodeIfPresent(Bool.self, forKey: .editGroup)) ?? false
            deleteGroup = (try? c.decodeIfPresent(Bool.self, forKey: .deleteGroup)) ?? false
        }
    }
    struct Member: Decodable, Equatable, Identifiable { var userId: String; var handle: String; var alias: String; var avatarUrl: String?; var online: Bool; var role: String; var id: String { userId } }
    struct Group: Decodable, Equatable {
        var id: String
        var name: String
        var description: String?
        var avatarUrl: String?
        var bannerUrl: String?
        var visibility: String
        var tags: [String]
        var memberCount: Int
        var isMember: Bool
        var isOwner: Bool
        var isPending: Bool
        var role: String?
        var can: GroupPerms
        var members: [Member]
    }
    struct PostAuthor: Decodable, Equatable { var handle: String; var alias: String; var avatarUrl: String? }
    struct Post: Decodable, Equatable, Identifiable {
        var id: String
        var text: String
        var pinned: Bool
        var createdAt: String
        var edited: Bool
        var author: PostAuthor?
        var likeCount: Double
        var liked: Bool
    }
    struct PostPage: Decodable, Equatable { var posts: [Post]; var nextCursor: String?; var canPost: Bool }

    // ---- shared lists (views/shared-list, lib/social/featured-lists.ts)
    struct ListRef: Codable, Equatable, Identifiable, Hashable { var handle: String; var listId: String; var id: String { "\(handle)/\(listId)" } }
    struct ListItem: Decodable, Equatable, Identifiable { var id: String; var name: String; var poster: String?; var type: String }
    struct ListOwner: Decodable, Equatable { var handle: String; var alias: String; var avatarUrl: String?; var bannerUrl: String?; var isOwner: Bool }
    struct SharedListBody: Decodable, Equatable { var id: String; var name: String; var description: String?; var likeCount: Double; var liked: Bool; var items: [ListItem] }
    struct SharedList: Decodable, Equatable { var state: String; var signedIn: Bool?; var owner: ListOwner?; var list: SharedListBody? }
    struct SaveResult: Decodable, Equatable { var ok: Bool; var already: Bool?; var full: Bool? }

    /// A handle to open, wrapped so it can drive `fullScreenCover(item:)`.
    struct HandleRef: Identifiable, Equatable, Hashable { var handle: String; var id: String { handle } }
    struct GroupRef: Identifiable, Equatable, Hashable { var id: String }

    /// The engine throws `Error: <message>`; show the message.
    static func message(_ error: Error) -> String {
        if case EngineError.js(let text) = error {
            let first = text.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? text
            return first.hasPrefix("Error: ") ? String(first.dropFirst(7)) : first
        }
        return error.localizedDescription
    }

    /// views/profile/profile-bits.tsx timeAgo.
    static func ago(iso: String?) -> String {
        guard let iso else { return "" }
        guard let d = isoFraction.date(from: iso) ?? isoPlain.date(from: iso) else { return "" }
        return ago(ms: d.timeIntervalSince1970 * 1000)
    }

    /// (perf pass 5) Made once: `ago(iso:)` runs in the Feed, Groups and profile rows' bodies, and
    /// built one or two ISO formatters per row on every redraw of those lists.
    private static let isoFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain = ISO8601DateFormatter()

    static func ago(ms: Double) -> String {
        guard ms > 0 else { return "" }
        let s = max(1, Int((Date().timeIntervalSince1970 * 1000 - ms) / 1000))
        if s < 60 { return T("just now") }
        let m = s / 60
        if m < 60 { return T("%lldm ago", m) }
        let h = m / 60
        if h < 24 { return T("%lldh ago", h) }
        let d = h / 24
        if d < 30 { return T("%lldd ago", d) }
        let mo = d / 30
        if mo < 12 { return T("%lldmo ago", mo) }
        return T("%lldy ago", mo / 12)
    }

    /// The profile of the engine's active profile, as the engine calls expect it.
    @MainActor static var profileArgs: (id: String, linked: Bool) {
        let p = ProfilesStore.shared.active
        return (p?.id ?? "default", p?.linked ?? true)
    }
}

/// profile-bits.tsx Avatar: the picture, else initials on a quiet disc; an online dot on request.
struct SocialAvatar: View {
    let url: String?
    let name: String
    var size: CGFloat = BP.px(44)
    var online: Bool? = nil
    var tint: Color? = nil

    var body: some View {
        ZStack {
            Circle().fill(tint ?? BP.panel2)
            if let url, !url.isEmpty {
                RemoteImage(url: url).clipShape(Circle())
            } else {
                Text(initials).font(BP.display(size * 0.36 / BP.k, .semibold)).foregroundStyle(tint == nil ? BP.ink : BP.canvas)
            }
        }
        .frame(width: size, height: size)
        .overlay(alignment: .bottomTrailing) {
            if let online {
                Circle().fill(online ? BP.live : BP.inkSubtle)
                    .frame(width: size * 0.26, height: size * 0.26)
                    .overlay(Circle().stroke(BP.canvas, lineWidth: 2))
            }
        }
    }

    private var initials: String {
        let parts = name.split(separator: " ").prefix(2)
        let s = parts.map { String($0.prefix(1)).uppercased() }.joined()
        return s.isEmpty ? "?" : s
    }
}

/// A page frame shared by the social screens: ambient background, title block, Back.
struct SocialPage<Content: View>: View {
    let eyebrow: String
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var content: () -> Content
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .topLeading) {
            BPAmbientBackground()
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: BP.px(22)) {
                    VStack(alignment: .leading, spacing: BP.px(6)) {
                        Text(T(eyebrow).uppercased()).font(BP.sans(11, .bold)).tracking(2.4).foregroundStyle(BP.inkSubtle)
                        Text(title).font(BP.display(34, .medium)).foregroundStyle(BP.ink).lineLimit(2)
                        if let subtitle { Text(subtitle).font(BP.sans(15)).foregroundStyle(BP.inkMuted) }
                    }
                    content()
                    Color.clear.frame(height: BP.px(40))
                }
                .padding(.horizontal, BP.gutter)
                .padding(.top, BP.px(56))
            }
        }
        .ignoresSafeArea()
        .onExitCommand { dismiss() }
    }
}

/// A focusable list row: leading art, title, subtitle, trailing text.
struct SocialRow<Leading: View>: View {
    let title: String
    var subtitle: String? = nil
    var trailing: String? = nil
    var unread = false
    /// (review 12) The page's focus seat for this row, for pages that hand the ring on when a row goes.
    var seat: (binding: FocusState<String?>.Binding, value: String)? = nil
    @ViewBuilder var leading: () -> Leading
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: BP.px(14)) {
                leading()
                VStack(alignment: .leading, spacing: BP.px(3)) {
                    Text(title).font(BP.sans(16, .semibold)).foregroundStyle(BP.ink).lineLimit(1)
                    if let subtitle, !subtitle.isEmpty { Text(subtitle).font(BP.sans(13)).foregroundStyle(BP.inkMuted).lineLimit(2) }
                }
                Spacer(minLength: BP.px(10))
                if let trailing { Text(trailing).font(BP.sans(12, .medium)).foregroundStyle(BP.inkSubtle) }
                if unread { Circle().fill(BP.accent).frame(width: BP.px(8), height: BP.px(8)) }
            }
            .padding(.horizontal, BP.px(16)).padding(.vertical, BP.px(12))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).fill(BP.panel.opacity(0.85)))
        }
        .buttonStyle(BPTileStyle(radius: BP.rSM))
        .modifier(SocialRowSeat(seat: seat))
    }
}

/// SocialRow's optional focus seat, bound on the row's own button.
private struct SocialRowSeat: ViewModifier {
    let seat: (binding: FocusState<String?>.Binding, value: String)?

    @ViewBuilder func body(content: Content) -> some View {
        if let seat {
            content.focused(seat.binding, equals: seat.value)
        } else {
            content
        }
    }
}

/// views/feed.tsx Empty: a dashed card with a title, a line of copy and an optional action.
struct SocialEmpty: View {
    let title: String
    let message: String
    var action: (label: String, run: () -> Void)? = nil

    var body: some View {
        VStack(spacing: BP.px(10)) {
            Text(T(title)).font(BP.sans(17, .semibold)).foregroundStyle(BP.ink)
            Text(T(message)).font(BP.sans(14)).foregroundStyle(BP.inkSubtle).multilineTextAlignment(.center).frame(maxWidth: BP.px(520))
            if let action { Button(T(action.label), action: action.run).buttonStyle(BPActionStyle(primary: true)) }
        }
        .padding(.vertical, BP.px(44)).frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: BP.rMD, style: .continuous).strokeBorder(BP.edge2, style: StrokeStyle(lineWidth: 1, dash: [6, 5])))
    }
}
