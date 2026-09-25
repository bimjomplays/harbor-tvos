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

    private var faceSize: CGFloat {
        let n = profiles.profiles.count
        return n <= 6 ? BP.px(125) : (n <= 12 ? BP.px(98) : BP.px(78))
    }

    var body: some View {
        ZStack {
            VStack(spacing: BP.px(34)) {
                VStack(spacing: BP.px(8)) {
                    Text("Who's watching?").font(BP.display(36)).foregroundStyle(BP.ink)
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
                    if ok { profiles.select(pinFor.id, unlocked: true); app.stage = .shell }
                    self.pinFor = nil
                }
                .transition(.opacity)
            }
        }
        .animation(BP.easeFast, value: pinFor?.id)
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
            if p.passwordHash != nil { pinFor = p } else { profiles.select(p.id); app.stage = .shell }
        } label: {
            VStack(spacing: BP.px(12)) {
                ZStack(alignment: .bottomTrailing) {
                    ProfileFace(profile: p, size: faceSize)
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
        .buttonStyle(BPTileStyle(radius: faceSize * 0.71))
        .accessibilityIdentifier("who-tile-\(p.id)")
    }

    @ViewBuilder private var syncNotice: some View {
        if account.isSignedIn {
            switch sync.phase {
            case .pulling:
                BPNote(text: "Signing in to your Harbor account. Your profiles will appear in a moment.")
            case .failed:
                HStack(spacing: BP.px(12)) {
                    BPNote(text: "Couldn't reach Harbor. Showing this device only.")
                    Button("Retry") { Task { await app.refreshRoster() } }.buttonStyle(BPActionStyle())
                }
            case .idle: EmptyView()
            }
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

/// Round face: avatar art from the bundled upstream catalog, else initials on the profile color.
struct ProfileFace: View {
    let profile: ProfilesStore.Profile
    let size: CGFloat

    private var art: UIImage? {
        guard let path = profile.avatar, path.hasPrefix("/") else { return nil }
        let url = Bundle.main.bundleURL.appendingPathComponent(String(path.dropFirst()))
        return UIImage(contentsOfFile: url.path)
    }

    var body: some View {
        ZStack {
            Circle().fill(Color(css: profile.color) ?? BP.accent)
            if let art {
                Image(uiImage: art).resizable().scaledToFill()
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
