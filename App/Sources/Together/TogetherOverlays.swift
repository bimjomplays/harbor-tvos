import SwiftUI
import UIKit

/// The room's toasts outside the player: together-invite-toast.tsx (auto-joins after 4 s unless
/// dismissed), together-summon-toast.tsx, together-participant-left-toast.tsx and
/// together-chat-toast.tsx. Mounted over the shell and over the room screen.
struct TogetherToastHost: View {
    var inRoomScreen = false
    @ObservedObject private var room = TogetherModel.shared
    @State private var inviteStarted: Double?
    @State private var progress: Double = 0
    @State private var handledInviteAt: Double?
    @State private var opening: TogetherOpen?
    @State private var chatShown: TogetherModel.ChatMessage?
    @State private var summonDetail: Meta?

    // together-invite-toast.tsx AUTO_JOIN_MS / together-chat-toast.tsx VISIBLE_MS
    private static let autoJoinS = 4.0
    private static let chatVisibleS = 5.5
    private let clock = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: BP.px(10)) {
            Spacer()
            if let chat = chatShown, !inRoomScreen { chatToast(chat) }
            if let left = room.view.incomingParticipantLeft, room.view.state == "joined" { leftToast(left) }
            if let s = room.view.incomingSummon { summonToast(s) }
            if let inv = room.view.incomingInvite, inv.at != handledInviteAt, inviteStarted != nil { inviteToast(inv) }
        }
        .padding(.leading, BP.gutter).padding(.bottom, BP.hintHeight + BP.px(16))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .onReceive(clock) { _ in tickInvite() }
        .onChange(of: room.view.chat.count) { _, _ in showLatestChat() }
        .onChange(of: room.view.incomingParticipantLeft) { _, left in
            guard left != nil else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { room.dismiss("participantLeft") }
        }
        .fullScreenCover(item: $opening) { o in DetailView(meta: o.meta, autoPlay: true, roomEpisode: o.episode, roomPick: o.guestPick) }
        .fullScreenCover(item: $summonDetail) { m in DetailView(meta: m) }
    }

    // MARK: invite

    /// The shell's host stays quiet while anything is presented over the shell (a page, the
    /// player, the account menu): it could not present the title, and the invite must survive.
    private var covered: Bool {
        guard !inRoomScreen else { return opening != nil }
        guard let root = HarborOverlayWindow.mainWindow?.rootViewController else { return false }
        return root.presentedViewController != nil
    }

    private func tickInvite() {
        guard let inv = room.view.incomingInvite, inv.at != handledInviteAt, !covered else {
            if inviteStarted != nil { inviteStarted = nil; progress = 0 }
            return
        }
        let now = Date().timeIntervalSince1970
        let start = inviteStarted ?? now
        if inviteStarted == nil { inviteStarted = start }
        progress = min(1, (now - start) / Self.autoJoinS)
        if progress >= 1 { join(inv) }
    }

    private func join(_ inv: TogetherModel.IncomingInvite) {
        handledInviteAt = inv.at
        inviteStarted = nil
        let i = inv.invite
        let meta = Meta(id: i.mediaId, type: i.mediaType, name: i.mediaTitle, poster: i.posterUrl, background: i.backgroundUrl, logo: i.logoUrl, releaseInfo: i.releaseInfo)
        opening = TogetherOpen(meta: meta, episode: i.episode, guestPick: i.guestPick == true)
        room.dismiss("invite")
    }

    private func inviteToast(_ inv: TogetherModel.IncomingInvite) -> some View {
        let i = inv.invite
        let ep = i.episodeRef.map { "S\($0.imdbSeason ?? $0.season) · E\(String(format: "%02d", $0.imdbEpisode ?? $0.episode))" }
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: BP.px(12)) {
                RemoteImage(url: i.backgroundUrl ?? i.posterUrl).frame(width: BP.px(96), height: BP.px(54)).clipShape(RoundedRectangle(cornerRadius: BP.px(6)))
                VStack(alignment: .leading, spacing: BP.px(2)) {
                    Text(i.guestPick == true ? "Pick your source" : "\(inv.name) started watching").font(BP.sans(12, .semibold)).foregroundStyle(BP.inkMuted)
                    Text(i.mediaTitle).font(BP.sans(16, .semibold)).foregroundStyle(BP.ink).lineLimit(1)
                    if let ep { Text(ep).font(BP.sans(12)).foregroundStyle(BP.inkSubtle) }
                }
                Button { join(inv) } label: { Image(systemName: "arrow.right") }.buttonStyle(BPActionStyle(primary: true)).accessibilityLabel("Join")
                Button { handledInviteAt = inv.at; room.dismiss("invite") } label: { Image(systemName: "xmark") }.buttonStyle(BPActionStyle()).accessibilityLabel("Dismiss")
            }
            .padding(BP.px(12))
            GeometryReader { g in Rectangle().fill(BP.accent).frame(width: g.size.width * progress) }.frame(height: BP.px(3))
        }
        .frame(width: BP.px(560))
        .background(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).fill(BP.panel))
        .clipShape(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous))
        .focusSection()
    }

    // MARK: summon (together-summon-toast.tsx)

    private func summonToast(_ s: TogetherModel.IncomingSummon) -> some View {
        let label = s.target.label ?? s.target.mediaTitle ?? (s.target.view.map { $0 == "queue" ? T("My Library") : $0.capitalized } ?? T("a title"))
        return HStack(spacing: BP.px(12)) {
            Text("\(s.name) wants you here").font(BP.sans(14, .semibold)).foregroundStyle(BP.ink)
            Text(label).font(BP.sans(14)).foregroundStyle(BP.inkMuted).lineLimit(1)
            if let id = s.target.mediaId {
                Button("Sure") {
                    summonDetail = Meta(id: id, type: s.target.mediaType ?? "movie", name: s.target.mediaTitle ?? "", poster: s.target.posterUrl, background: s.target.backgroundUrl)
                    room.dismiss("summon")
                }.buttonStyle(BPActionStyle(primary: true))
            }
            Button("Dismiss") { room.dismiss("summon") }.buttonStyle(BPActionStyle())
        }
        .padding(BP.px(12))
        .background(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).fill(BP.panel))
        .focusSection()
    }

    private func leftToast(_ left: TogetherModel.IncomingParticipantLeft) -> some View {
        HStack(spacing: BP.px(10)) {
            SocialAvatar(url: nil, name: left.name, size: BP.px(32), tint: Color.room(left.color) ?? BP.inkSubtle)
            Text("\(left.name) left the room").font(BP.sans(14, .semibold)).foregroundStyle(BP.ink)
        }
        .padding(.horizontal, BP.px(14)).padding(.vertical, BP.px(10))
        .background(Capsule().fill(BP.panel))
    }

    // MARK: chat (together-chat-toast.tsx: others' messages while the room panel is closed)

    private func showLatestChat() {
        guard let last = room.view.chat.last, last.from != room.view.clientId else { return }
        chatShown = last
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.chatVisibleS) { if chatShown == last { chatShown = nil } }
    }

    private func chatToast(_ m: TogetherModel.ChatMessage) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: BP.px(8)) {
            Text(m.name).font(BP.sans(14, .semibold)).foregroundStyle(Color.room(room.view.participants.first(where: { $0.id == m.from })?.color) ?? BP.accent)
            Text(m.text).font(BP.sans(14)).foregroundStyle(BP.ink).lineLimit(2)
        }
        .padding(.horizontal, BP.px(14)).padding(.vertical, BP.px(10))
        .frame(maxWidth: BP.px(560), alignment: .leading)
        .background(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).fill(BP.panel.opacity(0.92)))
    }
}

/// Watch Together inside the player: who is here, the lobby card (views/player.tsx showWaiting),
/// the last chat lines (read-only; the Room chip opens the full panel), "the host is watching
/// something else" (setForeignNotice), "{name} left the video" (together-host-leaving-prompt.tsx),
/// and other people's drawings and cursors on this video, view-only (PLAN §5).
struct TogetherPlayerLayer: View {
    @ObservedObject var playback: TogetherPlayback
    @ObservedObject private var room = TogetherModel.shared
    @State private var recentChat: [TogetherModel.ChatMessage] = []

    var body: some View {
        let v = room.view
        ZStack(alignment: .topTrailing) {
            if v.inRoom, let path = playback.framePath {
                ink(v, path: path)
            }
            if v.inSession {
                VStack(alignment: .trailing, spacing: BP.px(10)) {
                    roster(v)
                    ForEach(recentChat) { m in
                        HStack(alignment: .firstTextBaseline, spacing: BP.px(6)) {
                            Text(m.name).font(BP.sans(13, .semibold)).foregroundStyle(Color.room(v.participants.first(where: { $0.id == m.from })?.color) ?? BP.accent)
                            Text(m.text).font(BP.sans(13)).foregroundStyle(BP.ink).lineLimit(2)
                        }
                        .padding(.horizontal, BP.px(12)).padding(.vertical, BP.px(7))
                        .frame(maxWidth: BP.px(420), alignment: .trailing)
                        .background(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).fill(BP.void_.opacity(0.72)))
                        .transition(.opacity)
                    }
                    if let notice = playback.foreignNotice { banner(foreign(notice, v)) }
                    if let leaving = v.incomingHostLeaving {
                        banner(T("%@ left the video", leaving.name) + ". " + T("Follow them out?") + " " + T("Back") + ": " + T("Leave the video") + " · " + T("Keep watching"))
                            .task(id: leaving.at) {
                                try? await Task.sleep(for: .seconds(10))
                                room.dismiss("hostLeaving")
                            }
                    }
                }
                .padding(BP.gutter)
            }
            if playback.showWaiting { lobby(v) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.25), value: recentChat)
        .onChange(of: v.chat.count) { _, _ in
            guard let last = v.chat.last, last.from != v.clientId else { return }
            recentChat = Array((recentChat + [last]).suffix(3))
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { recentChat.removeAll { $0 == last } }
        }
        .onChange(of: playback.foreignNotice) { _, n in
            guard n != nil else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { if playback.foreignNotice == n { playback.foreignNotice = nil } }
        }
    }

    private func roster(_ v: TogetherModel.Snapshot) -> some View {
        HStack(spacing: BP.px(-8)) {
            ForEach(v.participants) { p in
                SocialAvatar(url: p.avatar, name: p.name, size: BP.px(34), tint: Color.room(p.color) ?? BP.accent)
                    .overlay(Circle().stroke(p.host ? BP.accent : BP.void_, lineWidth: 2))
            }
            Text(T("Room code") + " " + (v.room ?? "")).font(BP.sans(12, .semibold)).foregroundStyle(BP.inkMuted).padding(.leading, BP.px(16))
        }
        .padding(.horizontal, BP.px(10)).padding(.vertical, BP.px(6))
        .background(Capsule().fill(BP.void_.opacity(0.6)))
    }

    /// room-layer.tsx ForeignNoticeBox.
    private func foreign(_ n: TogetherPlayback.ForeignNotice, _ v: TogetherModel.Snapshot) -> String {
        "Now watching \(n.title ?? "Something else"). Pick it from the home view to follow."
    }

    private func banner(_ text: String) -> some View {
        Text(text).font(BP.sans(14, .semibold)).foregroundStyle(BP.ink)
            .padding(.horizontal, BP.px(14)).padding(.vertical, BP.px(9))
            .frame(maxWidth: BP.px(520), alignment: .trailing)
            .background(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).fill(BP.void_.opacity(0.8)))
    }

    /// room-layer.tsx WaitingForRoom, with use-lobby-gate's two ways out ("Start watching" /
    /// "Start anyway", "Play without sync") bound to the Play button.
    private func lobby(_ v: TogetherModel.Snapshot) -> some View {
        let notReady = v.participants.filter { !$0.ready }
        let hostLine = notReady.isEmpty
            ? T("Everyone is loaded in. Press play to start watching.")
            : T("Loading on %@…", notReady.map(\.name).joined(separator: ", ")) + " ▶ " + T("Start anyway (%lld still loading)", notReady.count)
        return VStack(spacing: BP.px(10)) {
            Text(playback.isHost ? "Ready when you are" : "Waiting for the host to start")
                .font(BP.display(28)).foregroundStyle(BP.ink)
            HStack(spacing: BP.px(14)) {
                ForEach(v.participants) { p in
                    HStack(spacing: BP.px(6)) {
                        Image(systemName: p.ready ? "checkmark.circle.fill" : "circle.dotted").foregroundStyle(p.ready ? BP.live : BP.inkSubtle)
                        Text(p.name + (p.isSelf ? T(" (you)") : "") + (p.ready ? "" : T(" · still loading"))).font(BP.sans(14)).foregroundStyle(BP.inkMuted)
                    }
                }
            }
            Text(playback.isHost ? hostLine : (playback.guestEscapeReady ? "▶ " + T("Play without sync") : T("The host starts playback for the whole room.")))
                .font(BP.sans(15)).foregroundStyle(BP.inkMuted)
        }
        .padding(BP.px(26))
        .background(RoundedRectangle(cornerRadius: BP.rLG, style: .continuous).fill(BP.void_.opacity(0.82)))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// use-draw-mode.ts strokes + together-cursors.tsx, for this video's path only. Coordinates
    /// are fractions of the picture (draw) or of the sender's window (cursors); the TV maps both
    /// to its full screen, which is the picture here.
    private func ink(_ v: TogetherModel.Snapshot, path: String) -> some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            ZStack(alignment: .topLeading) {
                ForEach(v.strokes.filter { $0.path == path }) { s in
                    Path { p in
                        guard let first = s.points.first else { return }
                        p.move(to: CGPoint(x: first.x * w, y: first.y * h))
                        for pt in s.points.dropFirst() { p.addLine(to: CGPoint(x: pt.x * w, y: pt.y * h)) }
                    }
                    .stroke(Color.room(s.color) ?? BP.accent, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                }
                if v.shareCursors {
                    ForEach(v.cursors.filter { $0.path == path }, id: \.from) { c in
                        HStack(spacing: BP.px(4)) {
                            Image(systemName: "cursorarrow").font(.system(size: BP.px(18), weight: .bold))
                            Text(c.name).font(BP.sans(11, .semibold))
                        }
                        .foregroundStyle(Color.room(v.participants.first(where: { $0.id == c.from })?.color) ?? BP.accent)
                        .position(x: c.x * w, y: c.y * h)
                    }
                }
            }
        }
        .ignoresSafeArea()
    }
}

extension Color {
    /// A room colour: a profile's "#rrggbb", or lib/together/colors.ts nameColor's "oklch(…)".
    static func room(_ css: String?) -> Color? {
        guard let css, !css.isEmpty else { return nil }
        return Color(css: css) ?? Color(oklch: css)
    }
}
