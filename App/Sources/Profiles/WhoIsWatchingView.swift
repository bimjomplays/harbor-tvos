import SwiftUI

/// "Who's watching?" (bp-who-is-watching.tsx): centred rows of round faces, max 6 per row,
/// PIN keypad for locked profiles, sync notices while the roster arrives.
struct WhoIsWatchingView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var profiles: ProfilesStore
    @EnvironmentObject private var sync: SyncReader
    @EnvironmentObject private var account: AccountStore
    @State private var pinFor: ProfilesStore.Profile?
    @State private var notice: String?
    /// (focus pass) bp-who-is-watching `returnTo`: backing out of the PIN pad puts the ring on the
    /// tile it came from. The keypad left with the ring on it and tvOS reset focus (the first tile),
    /// so on a big roster the viewer had to walk back across it.
    @FocusState private var tileFocus: String?

    private var faceSize: CGFloat {
        let n = profiles.profiles.count
        return n <= 6 ? BP.px(125) : (n <= 12 ? BP.px(98) : BP.px(78))
    }

    var body: some View {
        ZStack {
            VStack(spacing: BP.px(34)) {
                VStack(spacing: BP.px(8)) {
                    Text("Who's watching?").font(BP.display(36)).foregroundStyle(BP.ink)
                        .accessibilityAddTraits(.isHeader)
                    Text("Pick a profile to continue.").font(BP.sans(16)).foregroundStyle(BP.inkMuted)
                }
                if profiles.profiles.isEmpty {
                    emptyState
                } else {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        HStack(spacing: BP.px(34)) {
                            ForEach(row) { p in tile(p) }
                        }
                    }
                }
                syncNotice
                if let notice { BPNote(text: notice, tone: BP.accent) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .opacity(pinFor == nil ? 1 : 0)
            // (bug pass) Faded out is not gone: the tiles under the keypad could still take focus
            // (Up from the top keys), leaving the ring on something invisible.
            .disabled(pinFor != nil)
            if let pinFor {
                PinPadView(profile: pinFor) { ok in
                    // bp-who-is-watching commit(id, unlocked): the PIN unlocks the profile's locked tabs for the session.
                    let id = pinFor.id
                    self.pinFor = nil
                    if ok, commit(id, unlocked: true) { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { tileFocus = id }
                }
                .transition(.opacity)
            }
        }
        .animation(BP.easeFast, value: pinFor?.id)
        // (profiles device pass) bp-who-is-watching-layer: Back closes the chooser onto the profile
        // still active behind it (opened from the top bar, the account menu, Settings, the kids
        // chip or at launch). With none active there is nothing to return to, and the press is left
        // to the system (the app closes) rather than swallowed. The PIN pad handles its own Back.
        .onExitCommand(perform: backAction)
        .onAppear {
            // bp-who-is-watching: the ring starts on the active profile, not whoever sits first.
            guard let id = profiles.activeId else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { if pinFor == nil { tileFocus = id } }
        }
        // bp-who-is-watching pinTarget: a profile the roster sync removed takes its PIN pad with it.
        .onChange(of: profiles.profiles) { _, list in
            if let p = pinFor, !list.contains(where: { $0.id == p.id }) { pinFor = nil }
        }
    }

    private var backAction: (() -> Void)? {
        guard app.canCloseWho else { return nil }
        let model = app
        return { model.closeWho() }
    }

    /// bp-who-is-watching choose(): the active profile just closes the chooser (no PIN, no switch);
    /// another asks for its PIN when it has one.
    private func choose(_ p: ProfilesStore.Profile) {
        if p.id == profiles.activeId {
            app.closeWho()
            return
        }
        if p.passwordHash != nil { pinFor = p } else { commit(p.id, unlocked: false) }
    }

    /// bp-who-is-watching commit(): a profile that left the roster meanwhile is not selected (the
    /// shell opened on an active id with no profile behind it). Returns whether it switched.
    @discardableResult
    private func commit(_ id: String, unlocked: Bool) -> Bool {
        guard profiles.profiles.contains(where: { $0.id == id }) else { return false }
        profiles.select(id, unlocked: unlocked)
        app.stage = .shell
        return true
    }

    private var rows: [[ProfilesStore.Profile]] {
        let all = profiles.profiles
        guard !all.isEmpty else { return [] }
        let rowCount = ceil(Double(all.count) / 6)
        let perRow = min(6, max(1, Int(ceil(Double(all.count) / rowCount))))
        return stride(from: 0, to: all.count, by: perRow).map { Array(all[$0..<min($0 + perRow, all.count)]) }
    }

    private func tile(_ p: ProfilesStore.Profile) -> some View {
        Button {
            // bpWhoKidSelectable() is true on a TV shell, so a kid tile is never `unavailable` (dimmed):
            // Big Picture stays mounted and the kid lands on the Kids surface (KidsShellView).
            choose(p)
        } label: {
            VStack(spacing: BP.px(12)) {
                ZStack(alignment: .bottomTrailing) {
                    ProfileFace(profile: p, size: faceSize)
                        .modifier(WhoFaceRing())
                    if p.passwordHash != nil {
                        Image(systemName: "lock.fill")
                            .font(.system(size: faceSize * 0.13, weight: .bold))
                            .foregroundStyle(BP.ink)
                            .frame(width: faceSize * 0.28, height: faceSize * 0.28)
                            .background(Circle().fill(BP.panel2))
                            .overlay(Circle().stroke(BP.edge2, lineWidth: 1))
                    }
                }
                Text(p.name).font(BP.sans(15, .semibold)).foregroundStyle(BP.ink).lineLimit(1)
            }
            .frame(width: faceSize * 1.42)
        }
        .buttonStyle(WhoTileStyle())
        .focused($tileFocus, equals: p.id)
        .accessibilityIdentifier("who-tile-\(p.id)")
        // bp-who-is-watching-tile.tsx aria-label t("Switch to {name}"); the lock badge adds "PIN".
        .accessibilityLabel(Text(verbatim: p.passwordHash != nil ? "\(T("Switch to %@", p.name)), \(T("PIN"))" : T("Switch to %@", p.name)))
    }

    /// (profiles device pass) bp-who-is-watching-sync useBpWhoSyncPhase: "pending" is the FIRST
    /// pull for this account only, "failed" only that pull failing ("a device that has synced before
    /// holds a complete local copy and must show no chrome at all"). It read SyncReader.phase, which
    /// is "pulling" for every scheduled pull and push and "failed" for any push error, so the notice
    /// and its Retry came and went under the faces (moving them) on an ordinary visit.
    private enum WhoSync { case idle, pending, failed }

    private var whoSync: WhoSync {
        guard account.isSignedIn, let s = sync.status, s.armed else { return .idle }
        if s.phase == "first-pull" { return .pending }
        if s.phase == "first-pull-failed" { return .failed }
        return .idle
    }

    @ViewBuilder private var syncNotice: some View {
        switch whoSync {
        case .pending:
            BPNote(text: "Signing in to your Harbor account. Your profiles will appear in a moment.")
        case .failed:
            HStack(spacing: BP.px(12)) {
                BPNote(text: "Couldn't reach Harbor. Showing this device only.")
                Button("Retry") { Task { await app.refreshRoster() } }.buttonStyle(BPActionStyle())
            }
        case .idle: EmptyView()
        }
    }

    private var emptyState: some View {
        VStack(spacing: BP.px(12)) {
            BPNote(text: account.isSignedIn ? "This account has no profiles yet." : "Sign in to Harbor to bring your profiles here.")
            Button("Continue with a local profile") {
                profiles.seedIfEmpty(name: account.session?.user.username ?? "Harbor")
                app.attachPendingStremio()
            }.buttonStyle(BPActionStyle(primary: true))
        }
    }
}

/// bp-who-is-watching-style.ts: the whole tile lifts ([data-bp-who-tile] scale --bp-focus-lift) but
/// the ring and shadow sit on the round face ([data-bp-who-face] box-shadow), never around the name.
/// (layout pass) BPTileStyle drew its rounded-rect ring around face and name together: a wide pill
/// enclosing the caption instead of a circle hugging the avatar.
struct WhoTileStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        BPFocusReader { focused in
            configuration.label
                .scaleEffect(focused ? (configuration.isPressed ? BP.focusLift * BP.press : BP.focusLift) : 1)
                .animation(configuration.isPressed ? .timingCurve(0.5, 0, 0.75, 0, duration: 0.09) : BP.ease, value: focused)
                .animation(.timingCurve(0.5, 0, 0.75, 0, duration: 0.09), value: configuration.isPressed)
        }
    }
}

/// The face half of WhoTileStyle: BPFocusModifier's ring geometry (void gap, then the stroke) as
/// circles, and the contact shadow, while the tile's button holds focus.
struct WhoFaceRing: ViewModifier {
    @Environment(\.isFocused) private var focused

    func body(content: Content) -> some View {
        content
            .overlay {
                if focused {
                    Circle().inset(by: -3).stroke(BP.void_, lineWidth: 3)
                    Circle().inset(by: -7).stroke(BP.focusStroke, lineWidth: 5)
                }
            }
            .shadow(color: .black.opacity(focused ? 0.8 : 0), radius: focused ? 34 : 0, y: focused ? 26 : 0)
    }
}

/// Round face: avatar art from the bundled upstream catalog, else initials on the profile color.
struct ProfileFace: View {
    let profile: ProfilesStore.Profile
    let size: CGFloat

    private var art: UIImage? {
        guard let path = profile.avatar, path.hasPrefix("/") else { return nil }
        return Self.bundledArt(path)
    }

    /// (perf pass) The bundled avatars (65 small WebP files, ~1 MB in all) are read once: `art` ran in
    /// `body`, so every redraw of the top bar's chip, Who's watching and the editor's 65-tile picker
    /// read each file from disk again and handed SwiftUI a new image, decoded again at its first draw.
    private static let artCache = NSCache<NSString, UIImage>()

    static func bundledArt(_ path: String) -> UIImage? {
        if let hit = artCache.object(forKey: path as NSString) { return hit }
        let url = Bundle.main.bundleURL.appendingPathComponent(String(path.dropFirst()))
        guard let image = UIImage(contentsOfFile: url.path) else { return nil }
        artCache.setObject(image, forKey: path as NSString)
        return image
    }

    var body: some View {
        ZStack {
            Circle().fill(Color(css: profile.color) ?? BP.accent)
            if let art {
                Image(uiImage: art).resizable().scaledToFill().accessibilityHidden(true)
            } else {
                Text(initials).font(BP.display(size * 0.34 / BP.k, .semibold)).foregroundStyle(BP.canvas)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }

    private var initials: String {
        let parts = profile.name.split(separator: " ").prefix(2)
        return parts.map { String($0.prefix(1)).uppercased() }.joined()
    }
}
