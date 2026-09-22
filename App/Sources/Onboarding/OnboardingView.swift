import SwiftUI

/// Onboarding wizard (src/views/big-picture/onboarding). Stage 1 ships the steps that exist yet:
/// language, Stremio, Harbor account, done. TMDB, layout, services, subtitles and taste join
/// with their features. Unlike upstream, the Harbor step types on the TV: the password goes
/// straight to harbor.site over TLS, never across the LAN, so upstream's objection does not apply.
struct OnboardingView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var account: AccountStore
    @EnvironmentObject private var profiles: ProfilesStore

    enum Step: Int, CaseIterable { case language, stremio, harbor, done }
    @State private var step: Step = .language
    @State private var stremioName: String?

    var body: some View {
        VStack(spacing: 0) {
            ProgressBar(fraction: Double(step.rawValue + 1) / Double(Step.allCases.count))
                .padding(.horizontal, BP.gutter).padding(.top, BP.px(28))
            HStack(alignment: .top, spacing: BP.px(60)) {
                copy.frame(width: BP.px(380), alignment: .leading)
                content.frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .padding(.horizontal, BP.gutter).padding(.top, BP.px(40))
            Spacer()
        }
    }

    @ViewBuilder private var copy: some View {
        let (eyebrow, headline, body) = text
        VStack(alignment: .leading, spacing: BP.px(14)) {
            Text(eyebrow).font(BP.sans(13, .semibold)).foregroundStyle(BP.accent).textCase(.uppercase).tracking(1)
            Text(headline).font(BP.display(36)).foregroundStyle(BP.ink).fixedSize(horizontal: false, vertical: true)
            Text(body).font(BP.sans(16)).foregroundStyle(BP.inkMuted).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var text: (String, String, String) {
        switch step {
        case .language: ("Language", "Choose your language", "Harbor speaks this everywhere. You can change it later in Settings.")
        case .stremio: ("Your library", "Bring in your library", "Your Continue Watching, your watchlist and your addons.")
        case .harbor: ("Harbor account", "Sign in to Harbor", "Sync your profile, themes, lists and friends. You can do this any time.")
        case .done: ("Ready", "You are set up", "Saved on this device. Another Harbor install starts fresh.")
        }
    }

    @ViewBuilder private var content: some View {
        switch step {
        case .language:
            VStack(alignment: .leading, spacing: BP.px(10)) {
                Button("English") { advance() }.buttonStyle(BPActionStyle(primary: true))
                BPNote(text: "More languages arrive with Stage 9.")
            }
        case .stremio:
            StremioSignInForm(profileId: nil) { name in stremioName = name; advance() } skip: { advance() }
        case .harbor:
            HarborSignInForm { advance() } skip: { advance() }
        case .done:
            VStack(alignment: .leading, spacing: BP.px(16)) {
                RecapRow(ok: stremioName != nil, text: stremioName.map { "Signed in as \($0)" } ?? "Not signed in to Stremio. Your library stays local.")
                RecapRow(ok: account.isSignedIn, text: account.session.map { "Harbor account linked as \($0.user.username)" } ?? "No Harbor account yet")
                Button("Start watching") { app.finishOnboarding() }
                    .buttonStyle(BPActionStyle(primary: true))
                    .accessibilityIdentifier("onboarding-start")
                BPNote(text: "Everything here took effect straight away, and it is saved on this device.")
            }
        }
    }

    private func advance() {
        withAnimation(BP.easeSlow) { step = Step(rawValue: step.rawValue + 1) ?? .done }
    }
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
            Text(text).font(BP.sans(15)).foregroundStyle(BP.ink)
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
