import SwiftUI

/// Onboarding wizard (src/views/big-picture/onboarding), in bp-onboard-steps.ts order: language,
/// phone, TMDB, Stremio, Harbor, layout, services, subtitles, taste, done. The copy column carries
/// each step's aside (the TMDB and Stremio showcases, the layout and subtitle previews, the done
/// flourish) under the headline, where bp-onboarding-frame.tsx mounts [data-bp-onboard-aside].
/// Unlike upstream, the Harbor step types on the TV: the password goes straight to harbor.site
/// over TLS, never across the LAN, so upstream's objection does not apply.
struct OnboardingView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var account: AccountStore
    @EnvironmentObject private var profiles: ProfilesStore
    @EnvironmentObject private var settings: SettingsBridge

    enum Step: Int, CaseIterable { case language, phone, tmdb, stremio, harbor, layout, streaming, subtitles, taste, done }
    @State private var step: Step = .language
    @State private var stremioName: String?
    /// bp-handoff-context.tsx: the host lives above the steps, not inside the phone screen, so the
    /// code on screen survives Back and Continue and a delivery that lands after the TV moved on to
    /// the Stremio screen still counts. Listening only from the phone step through the Harbor step.
    @StateObject private var handoff = TvHandoff(mode: .setup(HandoffStep.allCases))
    /// advanceBpOnboardRing: once a step's answer is given the ring moves to its primary button.
    @FocusState private var ring: String?
    @State private var facts: OnboardFacts?

    var body: some View {
        VStack(spacing: 0) {
            ProgressBar(fraction: Double(step.rawValue + 1) / Double(Step.allCases.count))
                .padding(.horizontal, BP.gutter).padding(.top, BP.px(28))
            HStack(alignment: .top, spacing: BP.px(60)) {
                VStack(alignment: .leading, spacing: 0) {
                    copy
                    Spacer(minLength: BP.px(16))
                    aside
                }
                .frame(width: BP.px(380), alignment: .leading)
                .frame(maxHeight: .infinity, alignment: .top)
                content.frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .padding(.horizontal, BP.gutter).padding(.top, BP.px(40)).padding(.bottom, BP.hintHeight)
        }
        .onChange(of: step) { _, s in
            syncHandoff(s)
            if s == .done { Task { await loadFacts() } }
        }
        .onChange(of: handoff.done) { _, d in
            if d.contains(.stremio), stremioName == nil, let s = PendingStremio.session { stremioName = s.user.fullname ?? s.user.email }
        }
        .onDisappear { handoff.stop() }
    }

    private func syncHandoff(_ s: Step) {
        guard s.rawValue >= Step.phone.rawValue, s.rawValue <= Step.harbor.rawValue else {
            handoff.stop()
            return
        }
        if handoff.onPayload == nil {
            let a = app
            handoff.onPayload = HandoffApply.make(profileId: nil, afterHarbor: { await a.refreshRoster() })
        }
        handoff.start()
    }

    @ViewBuilder private var copy: some View {
        let (eyebrow, headline, body) = text
        VStack(alignment: .leading, spacing: BP.px(14)) {
            Text(T(eyebrow)).font(BP.sans(13, .semibold)).foregroundStyle(BP.accent).textCase(.uppercase).tracking(1)
            Text(T(headline)).font(BP.display(36)).foregroundStyle(BP.ink).fixedSize(horizontal: false, vertical: true)
            Text(T(body)).font(BP.sans(16)).foregroundStyle(BP.inkMuted).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
        }
        .id(step)
        .transition(.opacity)
    }

    /// bp-onboard-steps.ts BP_ONBOARD_STEPS copy.
    private var text: (String, String, String) {
        switch step {
        case .language: ("Language", "Choose your language", "Harbor speaks this everywhere. You can change it later in Settings.")
        case .phone: ("Your phone", "Finish setup on your phone", "The next three screens need typing. Scan this and your phone does it for you.")
        case .tmdb: ("Artwork and rows", "Connect TMDB", "Free, two minutes. Unlocks Trending, In Theaters, Top Rated and every service rail.")
        case .stremio: ("Your library", "Bring in your library", "Your Continue Watching, your watchlist and your addons.")
        case .harbor: ("Harbor account", "Create a Harbor account", "Sync your profile, themes, lists and friends. You can do this any time.")
        case .layout: ("Home", "How should the home screen read?", "Harbor leads with one big title. Classic leads with rows.")
        case .streaming: ("Your services", "Turn off what you do not have", "All of them start on. Take off the ones you do not pay for.")
        case .subtitles: ("Subtitles", "Which subtitle languages, in order?", "First match wins. Most people need only one.")
        case .taste: ("Taste", "What do you like?", "Pick up to five. It shapes what Harbor surfaces first.")
        case .done: ("Ready", "You are set up", "Saved on this device. Another Harbor install starts fresh.")
        }
    }

    /// The step's showcase or preview (BpOnboardAside), bottom of the copy column; bp-rise in.
    @ViewBuilder private var aside: some View {
        Group {
            switch step {
            case .tmdb: OnboardTmdbShowcase()
            case .stremio: OnboardStremioShowcase()
            case .layout: OnboardLayoutPreview(mode: settings.slice.homeMode)
            case .subtitles: OnboardSubtitlePreview(languages: settings.slice.preferredSubLangs)
            case .done:
                // Dealt once the viewer's own picks are known, so the deal plays on real art.
                if let f = facts { OnboardDoneFlourish(art: f.art) }
            default: EmptyView()
            }
        }
        .id(step)
        .transition(.opacity.combined(with: .offset(y: BP.px(14))))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder private var content: some View {
        switch step {
        case .language:
            OnboardLanguageStep(ring: $ring) { advance() }
        case .phone:
            PhoneSetupStep(handoff: handoff,
                           tmdbConnected: !settings.slice.tmdbKey.isEmpty,
                           stremioName: stremioName,
                           harborName: account.session?.user.username,
                           advance: { advance() })
        case .tmdb:
            TmdbKeyForm(done: { advance() }, skip: { advance() })
        case .stremio:
            StremioSignInForm(profileId: nil) { name in stremioName = name; advance() } skip: { advance() }
        case .harbor:
            HarborSignInForm { advance() } skip: { advance() }
        case .layout:
            VStack(alignment: .leading, spacing: BP.px(16)) {
                HStack(spacing: BP.px(16)) {
                    layoutCard("Harbor", "A hero up top, then Top 10, Trending, In Theaters and your service rows.", mode: "harbor")
                    layoutCard("Classic", "Continue Watching first, then your addon catalogs in install order.", mode: "classic")
                }
                Button("Continue") { advance() }
                    .buttonStyle(BPActionStyle(primary: true))
                    .focused($ring, equals: "primary")
            }
        case .streaming:
            StreamingServicesStep(hasKey: !settings.slice.tmdbKey.isEmpty) { advance() }
        case .subtitles:
            VStack(alignment: .leading, spacing: BP.px(14)) {
                SubtitleLanguageGrid()
                HStack(spacing: BP.px(12)) {
                    Button("Continue") { advance() }.buttonStyle(BPActionStyle(primary: true))
                    Button("Skip") { advance() }.buttonStyle(BPActionStyle())
                }
                BPNote(text: "In order: \(settings.slice.preferredSubLangs.joined(separator: ", "))")
            }
        case .taste:
            TasteStep { advance() }
        case .done:
            // bp-step-done.tsx: the recap lines, then Start watching.
            VStack(alignment: .leading, spacing: BP.px(16)) {
                RecapRow(ok: !settings.slice.tmdbKey.isEmpty, text: settings.slice.tmdbKey.isEmpty ? "Running on Cinemeta. Add a TMDB key in Settings whenever you want." : "TMDB connected")
                if let f = facts {
                    RecapRow(ok: f.servicesOn > 0, text: "\(f.servicesOn) streaming services on")
                }
                RecapRow(ok: stremioName != nil, text: stremioName.map { "Signed in as \($0)" } ?? "Not signed in to Stremio. Your library stays local.")
                RecapRow(ok: account.isSignedIn, text: account.session.map { "Harbor account linked as \($0.user.username)" } ?? "No Harbor account yet")
                RecapRow(ok: !settings.slice.preferredSubLangs.isEmpty,
                         text: settings.slice.preferredSubLangs.isEmpty ? "No subtitle languages set" : "Subtitles: \(settings.slice.preferredSubLangs.joined(separator: ", "))")
                if let f = facts, f.tastePicks > 0 {
                    RecapRow(ok: true, text: "\(f.tastePicks) titles you like")
                }
                Button("Start watching") { app.finishOnboarding() }
                    .buttonStyle(BPActionStyle(primary: true))
                    .accessibilityIdentifier("onboarding-start")
                BPNote(text: "Everything here took effect straight away, and it is saved on this device.")
            }
        }
    }

    private func loadFacts() async {
        let p = ProfilesStore.shared.active
        facts = try? await HarborEngine.shared.call("onboarding.facts", [p?.id ?? "default", p?.linked ?? true])
    }

    /// bp-step-layout.tsx: two choice cards, applied instantly; the ring then moves to Continue
    /// (advanceBpOnboardRing), so the preview beside the copy shows what was picked.
    private func layoutCard(_ title: String, _ blurb: String, mode: String) -> some View {
        Button {
            Task {
                try? await settings.patch(["homeMode": .string(mode)])
                ring = "primary"
            }
        } label: {
            VStack(alignment: .leading, spacing: BP.px(8)) {
                Text(T(title)).font(BP.display(22)).foregroundStyle(BP.ink)
                Text(T(blurb)).font(BP.sans(13)).foregroundStyle(BP.inkMuted).fixedSize(horizontal: false, vertical: true)
                if settings.slice.homeMode == mode { Text("Current").font(BP.sans(11, .bold)).foregroundStyle(BP.accent).textCase(.uppercase) }
            }
            .padding(BP.px(20))
            .frame(width: BP.px(280), height: BP.px(160), alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: BP.rMD, style: .continuous).fill(settings.slice.homeMode == mode ? BP.glass : BP.panel2))
        }
        .buttonStyle(BPTileStyle(radius: BP.rMD))
    }

    /// Steps the phone already delivered are passed over, so nobody signs in twice.
    private func advance() {
        var next = Step(rawValue: step.rawValue + 1) ?? .done
        while let h = Self.handoffStep(next), handoff.done.contains(h), let after = Step(rawValue: next.rawValue + 1) { next = after }
        withAnimation(BP.easeSlow) { step = next }
    }

    private static func handoffStep(_ s: Step) -> HandoffStep? {
        switch s {
        case .tmdb: return .tmdb
        case .stremio: return .stremio
        case .harbor: return .harbor
        default: return nil
        }
    }
}

/// use-bp-onboard-facts.ts (the counts) plus bp-done-flourish's five posters (engine onboarding.facts).
struct OnboardFacts: Decodable {
    var servicesOn: Int
    var subLangs: [String]
    var tastePicks: Int
    var art: [String]
}

struct ProgressBar: View {
    let fraction: Double
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(BP.edge)
                Capsule().fill(BP.ink).frame(width: g.size.width * fraction)
            }
        }
        .frame(height: BP.px(4))
        .animation(BP.easeSlow, value: fraction)
        .accessibilityLabel("Setup progress")
    }
}

struct RecapRow: View {
    let ok: Bool
    let text: String
    var body: some View {
        HStack(spacing: BP.px(10)) {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle.dashed").foregroundStyle(ok ? BP.live : BP.inkSubtle)
            Text(T(text)).font(BP.sans(15)).foregroundStyle(BP.ink)
        }
    }
}

/// Stremio email + password (bp-step-stremio.tsx). Signs in to api.strem.io and stores the
/// authKey for a profile; `profileId == nil` parks it until the first profile exists.
struct StremioSignInForm: View {
    let profileId: String?
    let done: (String) -> Void
    let skip: (() -> Void)?
    @EnvironmentObject private var profiles: ProfilesStore
    @State private var email = ""
    @State private var password = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: BP.px(14)) {
            BPField(label: "Email", placeholder: "you@example.com", text: $email, keyboard: .emailAddress)
            BPField(label: "Password", placeholder: "Your Stremio password", text: $password, secure: true)
            HStack(spacing: BP.px(12)) {
                Button(busy ? "Signing in…" : "Sign in") { Task { await signIn() } }
                    .buttonStyle(BPActionStyle(primary: true)).disabled(busy || email.isEmpty || password.isEmpty)
                if let skip { Button("Not now", action: skip).buttonStyle(BPActionStyle()) }
            }
            if let error { BPNote(text: error, tone: BP.danger) }
            BPNote(text: "Skip this and Harbor still works. Your library just stays local.")
        }
        .frame(maxWidth: BP.px(520))
    }

    private func signIn() async {
        busy = true; defer { busy = false }
        do {
            let r = try await StremioAPI.login(email: email.trimmingCharacters(in: .whitespaces), password: password)
            let session = ProfilesStore.StremioSession(authKey: r.authKey, user: r.user)
            if let profileId { profiles.setStremioSession(session, for: profileId) }
            else { PendingStremio.session = session }
            done(r.user.fullname ?? r.user.email)
        } catch {
            self.error = error.localizedDescription.isEmpty ? "Sign-in failed" : error.localizedDescription
        }
    }
}

/// A Stremio sign-in made before any profile exists; attached to the first profile that gets created.
enum PendingStremio {
    static var session: ProfilesStore.StremioSession?
}

/// Harbor username + password with a create-account switch (identity API, protocol §1.1).
struct HarborSignInForm: View {
    let done: () -> Void
    let skip: (() -> Void)?
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var account: AccountStore
    @State private var username = ""
    @State private var password = ""
    @State private var creating = false
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: BP.px(14)) {
            BPField(label: "Username", placeholder: "Your Harbor username", text: $username)
            BPField(label: "Password", placeholder: creating ? "Choose a password" : "Your Harbor password", text: $password, secure: true)
            HStack(spacing: BP.px(12)) {
                Button(busy ? "Working…" : (creating ? "Create account" : "Sign in")) { Task { await submit() } }
                    .buttonStyle(BPActionStyle(primary: true)).disabled(busy || username.isEmpty || password.isEmpty)
                Button(creating ? "I have an account" : "Create an account") { creating.toggle() }.buttonStyle(BPActionStyle())
                if let skip { Button("Later", action: skip).buttonStyle(BPActionStyle()) }
            }
            if let error { BPNote(text: error, tone: BP.danger) }
            BPNote(text: "Your profiles, settings and themes follow this account to every Harbor install.")
        }
        .frame(maxWidth: BP.px(560))
    }

    private func submit() async {
        busy = true; defer { busy = false }
        do {
            if creating { try await account.register(username: username.trimmingCharacters(in: .whitespaces), password: password) }
            else { try await account.signIn(username: username.trimmingCharacters(in: .whitespaces), password: password) }
            await app.refreshRoster()
            done()
        } catch {
            self.error = error.localizedDescription
        }
    }
}


/// onboarding/steps/bp-step-streaming.tsx: every service as a chip, on/off, through the BP settings
/// catalog's "service" control (settingsRoom.commit toggles settings.streaming).
struct StreamingServicesStep: View {
    let hasKey: Bool
    let done: () -> Void
    @State private var items: [BPSettingsModel.MultiItem] = []
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: BP.px(14)) {
            if items.isEmpty {
                if loaded { BPNote(text: "No services to choose from on this profile.") } else { ProgressView().tint(BP.inkMuted) }
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(BP.px(150)), spacing: BP.px(6)), count: 6), spacing: BP.px(6)) {
                    ForEach(items) { i in
                        Button { Task { await toggle(i) } } label: {
                            HStack(spacing: BP.px(6)) {
                                if let tint = i.tint { Circle().fill(Color(css: tint) ?? BP.ink).frame(width: BP.px(8), height: BP.px(8)) }
                                Text(i.label).font(BP.sans(13, i.on ? .bold : .semibold)).lineLimit(1)
                                if !i.on { Text("Off").font(BP.sans(9, .bold)).foregroundStyle(BP.inkSubtle) }
                            }
                            .foregroundStyle(i.on ? BP.ink : BP.inkSubtle)
                            .padding(.horizontal, BP.px(12)).frame(width: BP.px(150), height: BP.px(46))
                            .background(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).fill(i.on ? BP.panel2 : BP.panel))
                            .overlay(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).strokeBorder(i.on ? BP.edge2 : BP.edge, lineWidth: 1))
                            .opacity(i.on ? 1 : 0.55)
                        }
                        .buttonStyle(BPTileStyle(radius: BP.rSM))
                    }
                }
                .focusSection()
            }
            BPNote(text: hasKey ? "\(items.filter(\.on).count) on" : "These rows need a TMDB key before they show anything.")
            HStack(spacing: BP.px(12)) {
                Button("Continue") { done() }.buttonStyle(BPActionStyle(primary: true))
                Button("Skip") { done() }.buttonStyle(BPActionStyle())
            }
        }
        .task { await load() }
    }

    private var profile: (id: String, linked: Bool) { let p = ProfilesStore.shared.active; return (p?.id ?? "default", p?.linked ?? true) }

    private func load() async {
        let p = profile
        let controls: [BPSettingsModel.Control] = (try? await HarborEngine.shared.call("settingsRoom.controls", ["services", p.id, p.linked])) ?? []
        items = controls.first { $0.id == "service" }?.items ?? []
        loaded = true
    }

    private func toggle(_ i: BPSettingsModel.MultiItem) async {
        let p = profile
        _ = try? await HarborEngine.shared.callJSON("settingsRoom.commit", [.string("service"), .string(i.value), .string(p.id), .bool(p.linked)])
        await load()
    }
}


/// onboarding/steps/bp-step-taste.tsx: a poster grid, up to five picks, written on select through
/// the feed vote store (onboarding.vote) so Skip never throws them away.
struct TasteStep: View {
    let done: () -> Void
    @State private var items: [Meta] = []
    @State private var picked: Set<String> = []
    @State private var loaded = false
    @State private var bump: String?
    private static let max = 5
    private static let columns = Array(repeating: GridItem(.fixed(BP.px(150)), spacing: BP.px(10)), count: 6)

    private var onScreen: Int { items.filter { picked.contains($0.id) }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: BP.px(12)) {
            if !loaded { BPNote(text: "Finding titles…") }
            else if items.isEmpty { BPNote(text: "Couldn't load titles right now. You can pick favourites later from any detail page.") }
            else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVGrid(columns: Self.columns, spacing: BP.px(14)) {
                        ForEach(items) { m in
                            let on = picked.contains(m.id)
                            Button { Task { await toggle(m) } } label: {
                                ZStack(alignment: .topTrailing) {
                                    RemoteImage(url: m.poster).frame(width: BP.px(150), height: BP.px(225))
                                        .clipShape(RoundedRectangle(cornerRadius: BP.rXS, style: .continuous))
                                        .overlay(RoundedRectangle(cornerRadius: BP.rXS, style: .continuous).stroke(on ? BP.accent : .clear, lineWidth: 3))
                                    if on { Image(systemName: "checkmark.circle.fill").font(.system(size: BP.px(22))).foregroundStyle(BP.accent).padding(BP.px(6)) }
                                }
                                .offset(y: bump == m.id ? -6 : 0)
                            }
                            .buttonStyle(BPTileStyle(radius: BP.rXS))
                        }
                    }
                    .padding(.vertical, BP.px(10))
                }
                .frame(height: BP.px(500))
                .focusSection()
            }
            BPNote(text: onScreen >= Self.max ? "That is five. Deselect one to swap it out." : "\(onScreen) of \(Self.max) picked")
            HStack(spacing: BP.px(12)) {
                Button("Continue") { done() }.buttonStyle(BPActionStyle(primary: true))
                Button("Skip") { done() }.buttonStyle(BPActionStyle())
            }
        }
        .task {
            let p = ProfilesStore.shared.active
            items = (try? await HarborEngine.shared.call("onboarding.tasteTitles", [p?.id ?? "default", p?.linked ?? true])) ?? []
            picked = Set((try? await HarborEngine.shared.call("onboarding.upvoted", []) as [String]) ?? [])
            loaded = true
        }
    }

    private func toggle(_ m: Meta) async {
        let on = picked.contains(m.id)
        if !on, onScreen >= Self.max {
            // At the cap an unpicked tile refuses visibly (the nudge), never silently.
            withAnimation(.easeOut(duration: 0.19)) { bump = m.id }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { withAnimation { bump = nil } }
            return
        }
        let ids: [String] = (try? await HarborEngine.shared.call("onboarding.vote", [m.id, !on, m.name, m.type])) ?? []
        picked = Set(ids)
    }
}
