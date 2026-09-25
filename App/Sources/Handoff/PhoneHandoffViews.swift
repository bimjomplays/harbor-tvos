import SwiftUI

// The TV-side surfaces of the phone hand-off: the QR panel (onboarding/bp-handoff-panel.tsx),
// the phone step (onboarding/steps/bp-step-phone.tsx), the Connect pane (bp-connect.tsx) and
// "Type on your phone" (bp-phone-typing.tsx). Every surface owns a TvHandoff, starts it when it
// appears and stops it when it goes, so nothing listens on the network once the panel is closed.

/// bp-handoff-apply.ts: turns a delivery from the phone into live state on this TV. Throwing
/// refuses the step, which the phone sees as `applyFailed` and can retry.
@MainActor
enum HandoffApply {
    /// `profileId == nil` parks a Stremio session until the first profile exists, exactly as
    /// StremioSignInForm does during onboarding.
    static func make(profileId: String?,
                     onStremio: @escaping @MainActor @Sendable (String) -> Void = { _ in },
                     afterHarbor: @escaping @MainActor @Sendable () async -> Void = {}) -> @MainActor @Sendable (HandoffPayload) async throws -> Void {
        return { payload in
            switch payload {
            case .tmdb(let key):
                try await SettingsBridge.shared.patch(["tmdbKey": .string(key.trimmingCharacters(in: .whitespacesAndNewlines))])
            case .stremio(let authKey, _):
                let user = try await StremioAPI.getUser(authKey: authKey)
                let session = ProfilesStore.StremioSession(authKey: authKey, user: user)
                if let profileId { ProfilesStore.shared.setStremioSession(session, for: profileId) } else { PendingStremio.session = session }
                onStremio(user.fullname ?? user.email)
            case .harbor(let token, let handle, let refresh):
                try await AccountStore.shared.adopt(token: token, handle: handle, refresh: refresh)
                await afterHarbor()
            }
        }
    }
}

/// bp-handoff-panel.tsx waitingLabel.
func handoffWaitingLabel(_ phase: TvHandoff.Phase) -> String {
    switch phase {
    case .starting: return "Getting a code ready…"
    case .noAddress: return "No network address"
    case .serveFailed: return "Could not start serving"
    default: return "Phone setup unavailable"
    }
}

/// bp-handoff-panel.tsx handoffNote.
func handoffNote(_ phase: TvHandoff.Phase) -> String {
    switch phase {
    case .noAddress: return "Harbor cannot find this TV's network address, so the phone hand-off is unavailable here."
    case .serveFailed: return "Harbor could not open its web server. Try again, or set this up on the TV."
    case .stalled: return "Nothing has connected yet. Your phone may be on a guest network, or this TV may be on a different network from your phone."
    case .claimed: return "Your phone is connected. Keep going there."
    case .complete: return "All set. Everything below came over from your phone."
    case .waiting: return "Your phone needs to be on the same Wi-Fi as this TV."
    default: return "Setting up the hand-off…"
    }
}

/// A QR is a machine-readable image, not chrome: literal black on literal white (handoff-qr.ts).
/// Rendered once per address so a re-render never flashes an empty frame.
struct HandoffQRImage: View {
    let text: String
    @State private var image: UIImage?
    @State private var encoded: String?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).interpolation(.none).resizable()
            } else {
                Color.white
            }
        }
        .accessibilityLabel("Setup QR code")
        .onAppear { render() }
        .onChange(of: text) { _, _ in render() }
    }

    private func render() {
        guard encoded != text else { return }
        encoded = text
        image = QRCode.image(text)
    }
}

/// bp-handoff-panel.tsx: the QR, the grouped code and the address. The QR is never focusable and
/// never the only way through; every surface keeps its own TV path one press away.
struct HandoffPanel: View {
    @ObservedObject var handoff: TvHandoff
    var side: CGFloat = BP.px(220)

    var body: some View {
        HStack(alignment: .center, spacing: BP.px(28)) {
            ZStack {
                if let url = handoff.url {
                    HandoffQRImage(text: url).padding(BP.px(10)).background(Color.white)
                } else {
                    RoundedRectangle(cornerRadius: BP.rMD, style: .continuous).fill(BP.panel)
                    Image(systemName: "iphone").font(.system(size: BP.px(38), weight: .light)).foregroundStyle(BP.inkSubtle).accessibilityHidden(true)
                }
            }
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: BP.rMD, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: BP.rMD, style: .continuous).stroke(BP.edge, lineWidth: 1))

            VStack(alignment: .leading, spacing: BP.px(10)) {
                if let code = handoff.codeDisplay {
                    Text(code).font(BP.display(40)).tracking(4).foregroundStyle(BP.ink).lineLimit(1)
                } else {
                    Text(T(handoffWaitingLabel(handoff.phase))).font(BP.sans(15, .semibold)).foregroundStyle(BP.inkSubtle)
                }
                if let short = handoff.shortURL {
                    Text(short).font(BP.sans(14, .semibold)).foregroundStyle(BP.ink).lineLimit(1)
                        .padding(.horizontal, BP.px(12)).padding(.vertical, BP.px(7))
                        .background(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).fill(BP.panel2))
                }
            }
        }
    }
}

/// bp-phone-typing.tsx "Type on your phone": the phone becomes the keyboard for one field.
/// Upstream points the phone at its unauthenticated /remote; here the QR carries a pairing code
/// and only the phone that scanned it can type (lib/remote/text-entry.ts setText / submitText /
/// blurText drive the binding).
struct PhoneTypingSheet: View {
    let label: String
    let placeholder: String
    @Binding var text: String
    var secure = false
    /// The line under the heading. Upstream's copy is written for the search box.
    var purpose = "Scan this with your phone camera to open the Harbor remote, then type straight into the search box."
    var onSubmit: (() -> Void)?
    let onClose: () -> Void

    @StateObject private var handoff = TvHandoff(mode: .typing)
    @FocusState private var closeFocused: Bool

    var body: some View {
        ZStack {
            BPAmbientBackground()
            BP.void_.opacity(0.82).ignoresSafeArea()
            VStack(alignment: .leading, spacing: BP.px(22)) {
                HStack(spacing: BP.px(12)) {
                    Image(systemName: "iphone").font(.system(size: BP.px(22), weight: .semibold)).foregroundStyle(BP.inkMuted).accessibilityHidden(true)
                    Text("Type on your phone").font(BP.display(30)).foregroundStyle(BP.ink)
                    Spacer()
                    // bp-phone-typing.tsx: SFX.close() then onClose.
                    Button { BPSound.shared.close(); onClose() } label: { Image(systemName: "xmark").font(.system(size: BP.px(18), weight: .bold)) }
                        .buttonStyle(BPActionStyle())
                        .focused($closeFocused)
                        .accessibilityLabel("Close")
                }
                if handoff.phase == .noAddress {
                    BPNote(text: "Couldn't find this TV's Wi-Fi address.", tone: BP.danger)
                } else {
                    HStack(alignment: .center, spacing: BP.px(28)) {
                        HandoffPanel(handoff: handoff, side: BP.px(236))
                    }
                    VStack(alignment: .leading, spacing: BP.px(8)) {
                        Text(T(purpose)).font(BP.sans(17)).foregroundStyle(BP.inkMuted).fixedSize(horizontal: false, vertical: true)
                        Text("Same Wi-Fi as this TV").font(BP.sans(13, .semibold)).foregroundStyle(BP.inkSubtle).textCase(.uppercase).tracking(1.5)
                    }
                    if handoff.phase != .waiting {
                        BPNote(text: handoffNote(handoff.phase), tone: handoff.phase == .stalled || handoff.phase == .serveFailed ? BP.danger : BP.inkMuted)
                    }
                }
                VStack(alignment: .leading, spacing: BP.px(6)) {
                    Text(T(label)).font(BP.sans(13, .semibold)).foregroundStyle(BP.inkMuted)
                    Text(text.isEmpty ? T(placeholder) : (secure ? String(repeating: "•", count: text.count) : text))
                        .font(BP.sans(19, .semibold)).foregroundStyle(text.isEmpty ? BP.inkSubtle : BP.ink).lineLimit(2)
                        .padding(.horizontal, BP.px(14)).frame(maxWidth: .infinity, minHeight: BP.px(50), alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).fill(BP.panel2))
                }
                if handoff.phase == .stalled || handoff.phase == .serveFailed {
                    Button("Show a new code") { handoff.restart() }.buttonStyle(BPActionStyle())
                }
            }
            .padding(BP.px(38))
            .frame(width: BP.px(640))
            .background(RoundedRectangle(cornerRadius: BP.rLG, style: .continuous).fill(BP.panel))
        }
        .onAppear {
            let binding = $text
            let isSecure = secure
            handoff.entry = TvHandoff.Entry(label: T(label), placeholder: T(placeholder), secure: isSecure, value: { binding.wrappedValue })
            let submit = onSubmit, close = onClose
            handoff.onText = { action in
                switch action {
                case .set(let v):
                    binding.wrappedValue = v
                case .submit(let v):
                    if let v { binding.wrappedValue = v }
                    submit?()
                    close()
                case .blur:
                    close()
                }
            }
            handoff.start()
            closeFocused = true
        }
        .onDisappear { handoff.stop() }
        .onExitCommand { onClose() }
    }
}

/// onboarding/steps/bp-step-phone.tsx. Reads the host, never owns it: OnboardingView holds the
/// TvHandoff for the typing steps so the code survives Back and Continue.
struct PhoneSetupStep: View {
    @ObservedObject var handoff: TvHandoff
    let tmdbConnected: Bool
    let stremioName: String?
    let harborName: String?
    let advance: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: BP.px(18)) {
            HandoffPanel(handoff: handoff)
            HStack(spacing: BP.px(26)) {
                tick(.tmdb, settled: tmdbConnected ? T("TMDB connected") : nil, waiting: "Artwork and rows")
                tick(.stremio, settled: stremioName.map { T("Signed in as %@", $0) }, waiting: "Your Stremio library")
                tick(.harbor, settled: harborName.map { T("Signed in as %@", $0) }, waiting: "A Harbor account")
            }
            BPNote(text: handoffNote(handoff.phase), tone: handoff.phase == .stalled || handoff.phase == .noAddress ? BP.danger : BP.inkMuted)
            HStack(spacing: BP.px(12)) {
                // One button, and it changes meaning when the phone lands (bp-onboard-steps.ts).
                Button(handoff.phase == .complete ? "Continue" : "Set this up on the TV instead", action: advance)
                    .buttonStyle(BPActionStyle(primary: true))
                if handoff.phase != .complete {
                    Button("Show a new code") { handoff.restart() }.buttonStyle(BPActionStyle())
                }
            }
        }
    }

    private func tick(_ step: HandoffStep, settled: String?, waiting: String) -> some View {
        HStack(spacing: BP.px(8)) {
            Image(systemName: settled != nil ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(settled != nil ? BP.live : BP.inkSubtle)
                .accessibilityHidden(true)
            Text(settled ?? T(waiting)).font(BP.sans(15, .semibold)).foregroundStyle(settled != nil ? BP.ink : BP.inkSubtle)
        }
    }
}

/// bp-connect.tsx "Finish setting up Harbor": TMDB, Stremio and Harbor status in one place, the
/// phone QR with its code, and the TMDB key typed on the TV as the fallback.
struct ConnectPane: View {
    let onBack: () -> Void
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var account: AccountStore
    @EnvironmentObject private var profiles: ProfilesStore
    @EnvironmentObject private var settings: SettingsBridge
    @StateObject private var handoff = TvHandoff(mode: .setup(HandoffStep.allCases))
    @State private var typing = false

    private var hasKey: Bool { !settings.slice.tmdbKey.trimmingCharacters(in: .whitespaces).isEmpty }
    private var stremioName: String? {
        guard let p = profiles.active, let s = profiles.stremioSession(for: p.id) else { return nil }
        return s.user.fullname ?? s.user.email
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BP.px(24)) {
                Text("Finish setting up Harbor").font(BP.display(34)).foregroundStyle(BP.ink)
                if !hasKey {
                    Text("Harbor needs a TMDB key for artwork, rows and collections. It is free.")
                        .font(BP.sans(17)).foregroundStyle(BP.inkMuted)
                }
                HStack(alignment: .top, spacing: BP.px(56)) {
                    VStack(alignment: .leading, spacing: BP.px(18)) {
                        status("TMDB", T(hasKey ? "Connected" : "Artwork, rows and collections"), on: hasKey)
                        status("Stremio", stremioName.map { T("Signed in as %@", $0) } ?? T("Your Stremio library"), on: stremioName != nil)
                        status("Harbor account", account.session.map { T("Signed in as %@", $0.user.username) } ?? T("Sync, themes and friends"), on: account.isSignedIn)
                    }
                    VStack(alignment: .leading, spacing: BP.px(12)) {
                        HandoffPanel(handoff: handoff)
                        BPNote(text: handoff.phase == .waiting ? "Scan with your phone to sign in without typing on the remote." : handoffNote(handoff.phase),
                               tone: handoff.phase == .stalled || handoff.phase == .noAddress ? BP.danger : BP.inkMuted)
                            .frame(maxWidth: BP.px(460), alignment: .leading)
                    }
                }
                if typing {
                    TmdbKeyForm(done: { typing = false }, skip: { typing = false })
                }
                HStack(spacing: BP.px(12)) {
                    Button("Settings", action: onBack).buttonStyle(BPActionStyle())
                    if !typing {
                        Button(hasKey ? "Replace the saved key" : "Type a key on this TV") { typing = true }.buttonStyle(BPActionStyle(primary: !hasKey))
                    }
                    if handoff.phase != .complete {
                        Button("Show a new code") { handoff.restart() }.buttonStyle(BPActionStyle())
                    }
                }
            }
            .padding(BP.gutter)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            let a = app
            handoff.onPayload = HandoffApply.make(profileId: profiles.active?.id, afterHarbor: { await a.refreshRoster() })
            handoff.start()
        }
        .onDisappear { handoff.stop() }
    }

    /// bp-connect-parts.tsx BpConnectStatus.
    private func status(_ label: String, _ value: String, on: Bool) -> some View {
        HStack(spacing: BP.px(14)) {
            ZStack {
                Circle().fill(on ? BP.live.opacity(0.24) : BP.panel2)
                if on {
                    Image(systemName: "checkmark").font(.system(size: BP.px(20), weight: .bold)).foregroundStyle(BP.live).accessibilityHidden(true)
                } else {
                    Circle().fill(BP.edge2).frame(width: BP.px(12), height: BP.px(12))
                }
            }
            .frame(width: BP.px(48), height: BP.px(48))
            VStack(alignment: .leading, spacing: 2) {
                Text(T(label)).font(BP.sans(22, .semibold)).foregroundStyle(BP.ink)
                Text(value).font(BP.sans(16, .medium)).foregroundStyle(BP.inkSubtle).lineLimit(1)
            }
        }
    }
}
