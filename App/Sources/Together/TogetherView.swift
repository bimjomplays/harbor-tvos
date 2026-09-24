import SwiftUI

/// components/together-modal.tsx on the TV. Without a relay: upstream's explanation, Harbor's
/// public relay (relay-panel.tsx) and "join from an invite link". Outside a room: your name,
/// "Start a new room", or join by code / link. In a room: the code and an invite QR
/// (invite-panel.tsx), "Now watching" (return-to-video.tsx), who is here and where
/// (presence), the chat with quick replies and phone typing (chat-panel.tsx), guests-pick
/// (guest-pick-toggle.tsx, host only) and Leave room.
struct TogetherView: View {
    /// Opened from the player's Room chip: no invite toasts and no "Now watching" (return-to-video.tsx
    /// canReturn is false on the player), so a room event can never stack a second player.
    var inPlayer = false
    /// The player draws this view over the picture instead of presenting it (a cover would take
    /// the player off screen), so Back and the Back buttons call this rather than `dismiss`.
    var onClose: (() -> Void)? = nil
    @ObservedObject private var room = TogetherModel.shared
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var note: String?
    @State private var typing: Typing?
    @State private var draft = ""
    @State private var opening: TogetherOpen?
    @FocusState private var focus: String?

    private enum Typing: String, Identifiable { case chat, name, link, relay; var id: String { rawValue } }

    /// chat-panel.tsx has a free text box; a remote gets one-press replies and the phone.
    private static let quickReplies = ["👍", "Ready!", "Pause please", "One sec", "😂", "Rewind a bit?"]

    var body: some View {
        ZStack(alignment: .topLeading) {
            BPAmbientBackground()
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: BP.px(22)) {
                    VStack(alignment: .leading, spacing: BP.px(6)) {
                        Text("Watch together").textCase(.uppercase).font(BP.sans(11, .bold)).tracking(2.4).foregroundStyle(BP.inkSubtle)
                        Text(room.view.inSession ? T("Room code") + " " + (room.view.room ?? "") : T("Watch together")).font(BP.display(34, .medium)).foregroundStyle(BP.ink)
                    }
                    relayBanner
                    if !room.view.enabled { noRelay }
                    else if room.view.inSession { inRoom }
                    else { lobby }
                    if let note { BPNote(text: note, tone: BP.danger) }
                    Color.clear.frame(height: BP.px(40))
                }
                .padding(.horizontal, BP.gutter).padding(.top, BP.px(56))
            }
            .disabled(inPlayer && typing != nil)
            if !inPlayer { TogetherToastHost(inRoomScreen: true) }
            // In the player the phone-typing sheet is drawn in place too, never as a cover.
            if inPlayer, let t = typing { typingSheet(t).transition(.opacity) }
        }
        .ignoresSafeArea()
        .onExitCommand { close() }
        .task { await room.attach() }
        .fullScreenCover(item: Binding(get: { inPlayer ? nil : typing }, set: { typing = $0 })) { t in typingSheet(t) }
        .fullScreenCover(item: $opening) { o in DetailView(meta: o.meta, autoPlay: true, roomEpisode: o.episode, roomPick: o.guestPick) }
    }

    private func close() {
        if let onClose { onClose() } else { dismiss() }
    }

    // MARK: states

    /// together-relay-banner.tsx
    @ViewBuilder private var relayBanner: some View {
        if room.view.relayOutdated {
            BPNote(text: "Relay outdated. Your self-hosted relay is running an older version.", tone: BP.danger)
        }
    }

    private var noRelay: some View {
        VStack(alignment: .leading, spacing: BP.px(14)) {
            Text("A relay is a tiny Cloudflare Worker that passes play/pause/seek messages between you and your friends. No video data ever touches it. Deploy your own in one click (free tier is plenty), or paste a friend's invite link to use theirs.")
                .font(BP.sans(15)).foregroundStyle(BP.inkMuted).frame(maxWidth: BP.px(900), alignment: .leading).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: BP.px(10)) {
                Button { Task { await room.setRelay(room.view.publicRelay) } } label: { Label("Use Harbor's public relay", systemImage: "antenna.radiowaves.left.and.right") }
                    .buttonStyle(BPActionStyle(primary: true)).focused($focus, equals: "public")
                Button { draft = ""; typing = .link } label: { Label("Paste invite link", systemImage: "iphone") }.buttonStyle(BPActionStyle())
                Button { draft = ""; typing = .relay } label: { Label("Your relay URL", systemImage: "link") }.buttonStyle(BPActionStyle())
                Button("Back") { close() }.buttonStyle(BPActionStyle())
            }
            .focusSection()
        }
        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { focus = "public" } }
    }

    private var lobby: some View {
        VStack(alignment: .leading, spacing: BP.px(16)) {
            HStack(spacing: BP.px(10)) {
                Text("Your name").font(BP.sans(13, .semibold)).foregroundStyle(BP.inkMuted)
                Button { draft = room.view.displayName; typing = .name } label: { Label(room.view.displayName, systemImage: "pencil") }
                    .buttonStyle(BPActionStyle())
            }
            .focusSection()
            HStack(spacing: BP.px(10)) {
                Button {
                    note = nil
                    Task { await room.start() }
                } label: {
                    Label(room.view.state == "connecting" ? "Starting…" : "Start a new room", systemImage: "plus")
                }
                .buttonStyle(BPActionStyle(primary: true)).disabled(room.view.state == "connecting").focused($focus, equals: "start")
                Button { draft = ""; typing = .link } label: { Label("Paste invite link", systemImage: "iphone") }.buttonStyle(BPActionStyle())
                Button("Back") { close() }.buttonStyle(BPActionStyle())
            }
            .focusSection()
            HStack(alignment: .bottom, spacing: BP.px(10)) {
                BPField(label: "or join", placeholder: "ABCD23", text: $code, phone: true)
                    .frame(width: BP.px(360))
                Button("Join") { Task { await join(code) } }
                    .buttonStyle(BPActionStyle()).disabled(code.trimmingCharacters(in: .whitespaces).isEmpty || room.view.state == "connecting")
            }
            .focusSection()
            if room.view.state == "error" {
                VStack(alignment: .leading, spacing: BP.px(8)) {
                    BPNote(text: room.view.lastError ?? "Couldn't reach the relay.", tone: BP.danger)
                    Button("Try again") { Task { await room.retry() } }.buttonStyle(BPActionStyle())
                }
            } else if room.view.state == "connecting" {
                HStack(spacing: BP.px(8)) { ProgressView().tint(BP.ink); Text("Connecting to the relay…").font(BP.sans(14)).foregroundStyle(BP.inkMuted) }
            }
            Text(T("Relay") + ": " + (room.view.isPublicRelay ? T("Harbor's public relay") : room.view.relayUrl)).font(BP.sans(12)).foregroundStyle(BP.inkSubtle)
        }
        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { if focus == nil { focus = "start" } } }
    }

    private var inRoom: some View {
        let v = room.view
        return VStack(alignment: .leading, spacing: BP.px(20)) {
            HStack(alignment: .top, spacing: BP.px(28)) {
                VStack(alignment: .leading, spacing: BP.px(12)) {
                    // return-to-video.tsx
                    if !inPlayer, let media = v.syncState, let id = media.mediaId {
                        Button {
                            let meta = Meta(id: id, type: media.episode == nil ? "movie" : "series", name: media.mediaTitle ?? "Now playing", poster: media.posterUrl)
                            var ep: AnyJSON? = nil
                            if let e = media.episode { ep = .object(["season": .number(Double(e.season)), "episode": .number(Double(e.episode)), "name": e.name.map { AnyJSON.string($0) } ?? AnyJSON.null]) }
                            opening = TogetherOpen(meta: meta, episode: ep, guestPick: v.roomGuestPick)
                        } label: {
                            HStack(spacing: BP.px(12)) {
                                RemoteImage(url: media.posterUrl).frame(width: BP.px(46), height: BP.px(68)).clipShape(RoundedRectangle(cornerRadius: BP.px(4)))
                                VStack(alignment: .leading, spacing: BP.px(2)) {
                                    Text("Now watching").textCase(.uppercase).font(BP.sans(10, .bold)).tracking(2).foregroundStyle(BP.live)
                                    Text(media.mediaTitle ?? T("Untitled")).font(BP.sans(16, .semibold)).foregroundStyle(BP.ink)
                                    if let e = media.episode { Text("S\(e.season) · E\(e.episode)").font(BP.sans(12)).foregroundStyle(BP.inkMuted) }
                                }
                            }
                        }
                        .buttonStyle(BPActionStyle(primary: true))
                    }
                    Text("\(v.participants.count) watching").font(BP.sans(13, .semibold)).foregroundStyle(BP.inkMuted)
                    ForEach(v.participants) { p in participantRow(p) }
                }
                .frame(maxWidth: BP.px(560), alignment: .leading)
                if let link = v.inviteUrl, let qr = QRCode.image(link) {
                    VStack(alignment: .leading, spacing: BP.px(8)) {
                        Image(uiImage: qr).interpolation(.none).resizable().frame(width: BP.px(170), height: BP.px(170))
                            .padding(BP.px(10)).background(RoundedRectangle(cornerRadius: BP.rSM).fill(.white))
                        Text("Invite link").font(BP.sans(13, .semibold)).foregroundStyle(BP.ink)
                        Text("Scan to join, or share code \(v.room ?? "")").font(BP.sans(12)).foregroundStyle(BP.inkMuted)
                    }
                }
            }
            chat
            HStack(spacing: BP.px(10)) {
                if v.isHost || v.hostClientId == v.clientId {
                    Button { Task { await room.setGuestsPick(!v.guestsPick) } } label: {
                        Label("Guests pick their own source", systemImage: v.guestsPick ? "checkmark.circle.fill" : "circle")
                    }
                    .buttonStyle(BPActionStyle())
                }
                Button { draft = room.view.displayName; typing = .name } label: { Label(T("Your name") + ": " + v.displayName, systemImage: "pencil") }.buttonStyle(BPActionStyle())
                Button { Task { await room.leave() } } label: { Label("Leave room", systemImage: "rectangle.portrait.and.arrow.right") }.buttonStyle(BPActionStyle())
                Button("Back") { close() }.buttonStyle(BPActionStyle())
            }
            .focusSection()
        }
    }

    private func participantRow(_ p: TogetherModel.Participant) -> some View {
        HStack(spacing: BP.px(10)) {
            SocialAvatar(url: p.avatar, name: p.name, size: BP.px(36), tint: Color.room(p.color) ?? BP.accent)
            VStack(alignment: .leading, spacing: BP.px(1)) {
                HStack(spacing: BP.px(6)) {
                    Text(p.isSelf ? p.name + T(" (you)") : p.name).font(BP.sans(15, .semibold)).foregroundStyle(BP.ink)
                    if p.host { Text("Host").textCase(.uppercase).font(BP.sans(9, .bold)).tracking(1).foregroundStyle(BP.canvas).padding(.horizontal, BP.px(5)).padding(.vertical, BP.px(1)).background(Capsule().fill(BP.accent)) }
                    if p.ready { Image(systemName: "checkmark.circle.fill").foregroundStyle(BP.live).font(.system(size: BP.px(12))) }
                }
                if let loc = p.locationLabel, !p.isSelf { Text(loc).font(BP.sans(12)).foregroundStyle(BP.inkMuted).lineLimit(1) }
            }
        }
    }

    /// chat-panel.tsx: newest at the bottom; "Say hi." when empty.
    private var chat: some View {
        VStack(alignment: .leading, spacing: BP.px(10)) {
            Text("Chat").font(BP.sans(18, .semibold)).foregroundStyle(BP.ink)
            VStack(alignment: .leading, spacing: BP.px(6)) {
                if room.view.chat.isEmpty {
                    Text("Say hi.").font(BP.sans(14)).foregroundStyle(BP.inkSubtle)
                }
                ForEach(room.view.chat.suffix(12)) { m in
                    HStack(alignment: .firstTextBaseline, spacing: BP.px(8)) {
                        Text(m.from == room.view.clientId ? T("You") : m.name).font(BP.sans(14, .semibold))
                            .foregroundStyle(Color.room(room.view.participants.first(where: { $0.id == m.from })?.color) ?? BP.accent)
                        Text(m.text).font(BP.sans(14)).foregroundStyle(BP.ink).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(BP.px(14)).frame(maxWidth: BP.px(900), alignment: .leading)
            .background(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).fill(BP.panel.opacity(0.85)))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: BP.px(8)) {
                    ForEach(Self.quickReplies, id: \.self) { q in
                        Button(q) { room.sendChat(q) }.buttonStyle(BPActionStyle())
                    }
                    Button { draft = ""; typing = .chat } label: { Label("Message", systemImage: "iphone") }.buttonStyle(BPActionStyle(primary: true))
                }
                .padding(.vertical, BP.px(8))
            }
            .focusSection()
        }
    }

    // MARK: typing on the phone

    @ViewBuilder private func typingSheet(_ t: Typing) -> some View {
        switch t {
        case .chat:
            PhoneTypingSheet(label: "Message", placeholder: "Say something to the room", text: $draft,
                             purpose: "Scan this with your phone camera, then type your message; Send posts it to the room.",
                             onSubmit: { room.sendChat(draft); draft = "" }, onClose: { typing = nil })
        case .name:
            PhoneTypingSheet(label: "Your name", placeholder: "Guest", text: $draft,
                             purpose: "Scan this with your phone camera, then type the name the room sees.",
                             onSubmit: { let n = draft; Task { await room.setName(n) } }, onClose: { typing = nil })
        case .link:
            PhoneTypingSheet(label: "Invite link", placeholder: "https://…?harbor-relay=…&harbor-room=…", text: $draft,
                             purpose: "Scan this with your phone camera, then paste the invite link a friend sent you.",
                             onSubmit: { let l = draft; Task { await join(l) } }, onClose: { typing = nil })
        case .relay:
            PhoneTypingSheet(label: "Relay URL", placeholder: "wss://your-relay.workers.dev", text: $draft,
                             purpose: "Scan this with your phone camera, then paste your relay's address (Settings → Relay on desktop Harbor shows it).",
                             onSubmit: { let r = draft; Task { await setRelay(r) } }, onClose: { typing = nil })
        }
    }

    private func join(_ input: String) async {
        note = await room.join(input)
        if note == nil { code = "" }
    }

    private func setRelay(_ raw: String) async {
        let url = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard url.range(of: "^(wss?|https?)://", options: [.regularExpression, .caseInsensitive]) != nil else {
            note = "A relay address starts with wss:// or https://."
            return
        }
        note = nil
        await room.setRelay(url)
    }
}

/// What a room asks the TV to open: the title (and episode) the host is playing.
struct TogetherOpen: Identifiable, Equatable {
    var meta: Meta
    var episode: AnyJSON?
    var guestPick: Bool
    var id: String {
        guard let s = episode?["season"]?.number, let e = episode?["episode"]?.number else { return meta.id }
        return "\(meta.id):\(Int(s)):\(Int(e))"
    }
}
