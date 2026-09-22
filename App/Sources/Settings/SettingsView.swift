import SwiftUI

/// Settings room, Stage 1 slice: account, sync, profiles, developer, about.
struct SettingsView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var account: AccountStore
    @EnvironmentObject private var profiles: ProfilesStore
    @EnvironmentObject private var sync: SyncReader
    @State private var sheet: Sheet?
    @State private var pinDraft = ""

    enum Sheet: Identifiable { case harbor, stremio, pin, spikes; var id: Int { hashValue } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BP.px(28)) {
                Text("Settings").font(BP.display(36)).foregroundStyle(BP.ink)
                section("Harbor account") {
                    if let s = account.session {
                        row("Signed in as \(s.user.username)", detail: s.user.stremioLinked == true ? "Stremio linked" : "Stremio not linked")
                        Button("Sign out") { app.signOutHarbor() }.buttonStyle(BPActionStyle())
                    } else {
                        row("Not signed in", detail: "Sync, themes and friends")
                        Button("Sign in") { sheet = .harbor }.buttonStyle(BPActionStyle(primary: true))
                    }
                }
                section("Stremio") {
                    if let p = profiles.active {
                        if let s = profiles.stremioSession(for: p.id) {
                            row("Signed in as \(s.user.fullname ?? s.user.email)", detail: "For the \(p.name) profile")
                            Button("Sign out") { profiles.setStremioSession(nil, for: p.id) }.buttonStyle(BPActionStyle())
                        } else {
                            row("Not signed in", detail: "Your Stremio library for the \(p.name) profile")
                            Button("Sign in") { sheet = .stremio }.buttonStyle(BPActionStyle(primary: true))
                        }
                    }
                }
                section("Sync") {
                    row(syncLine, detail: sync.lastPull.map { "Last pulled \($0.formatted(date: .omitted, time: .shortened))" } ?? "Never pulled on this TV")
                    HStack(spacing: BP.px(12)) {
                        Button("Pull now") { Task { await app.refreshRoster() } }.buttonStyle(BPActionStyle()).disabled(!account.isSignedIn)
                        BPNote(text: "Read-only for now. Changes made on this TV stay on this TV until Stage 4.")
                    }
                }
                section("Profiles") {
                    if let p = profiles.active {
                        row(p.name, detail: "\(profiles.profiles.count) profiles on this account")
                        HStack(spacing: BP.px(12)) {
                            Button("Switch profile") { app.switchProfile() }.buttonStyle(BPActionStyle())
                            Button(p.passwordHash == nil ? "Set a PIN" : "Remove PIN") {
                                if p.passwordHash == nil { pinDraft = ""; sheet = .pin } else { profiles.setPin(nil, for: p.id) }
                            }.buttonStyle(BPActionStyle())
                        }
                    }
                }
                section("Developer") {
                    Button("Stage 0 spikes") { sheet = .spikes }.buttonStyle(BPActionStyle())
                }
                section("About") {
                    row("Harbor for Apple TV", detail: "Build \(build) · upstream beta-branch")
                }
            }
            .padding(.horizontal, BP.gutter).padding(.vertical, BP.px(40))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .fullScreenCover(item: $sheet) { which in
            ZStack {
                BPAmbientBackground()
                switch which {
                case .harbor:
                    HarborSignInForm(done: { sheet = nil }, skip: { sheet = nil }).padding(BP.gutter)
                case .stremio:
                    if let p = profiles.active {
                        StremioSignInForm(profileId: p.id, done: { _ in sheet = nil }, skip: { sheet = nil }).padding(BP.gutter)
                    }
                case .pin:
                    VStack(alignment: .leading, spacing: BP.px(16)) {
                        Text("Set a 4-digit PIN").font(BP.display(30)).foregroundStyle(BP.ink)
                        BPField(label: "PIN", placeholder: "4 digits", text: $pinDraft, secure: true, keyboard: .numberPad)
                        HStack(spacing: BP.px(12)) {
                            Button("Save") { if let p = profiles.active { profiles.setPin(pinDraft, for: p.id) }; sheet = nil }
                                .buttonStyle(BPActionStyle(primary: true)).disabled(pinDraft.count != 4 || Int(pinDraft) == nil)
                            Button("Cancel") { sheet = nil }.buttonStyle(BPActionStyle())
                        }
                        BPNote(text: "PINs stay on this Apple TV. They never sync.")
                    }
                    .frame(maxWidth: BP.px(520)).padding(BP.gutter)
                case .spikes:
                    SpikeMenuView()
                }
            }
            .environmentObject(app).environmentObject(account).environmentObject(profiles).environmentObject(sync)
        }
        .accessibilityIdentifier("settings")
    }

    private var syncLine: String {
        switch sync.phase {
        case .idle: return account.isSignedIn ? "Connected" : "Sign in to Harbor to sync"
        case .pulling: return "Pulling…"
        case .failed(let why): return "Failed: \(why)"
        }
    }

    private var build: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: BP.px(12)) {
            Text(title).font(BP.sans(19, .bold)).foregroundStyle(BP.ink)
            content()
        }
        .padding(BP.px(22))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: BP.rMD, style: .continuous).fill(BP.panel))
        .overlay(RoundedRectangle(cornerRadius: BP.rMD, style: .continuous).stroke(BP.edge, lineWidth: 1))
    }

    private func row(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: BP.px(3)) {
            Text(title).font(BP.sans(16, .semibold)).foregroundStyle(BP.ink)
            Text(detail).font(BP.sans(14)).foregroundStyle(BP.inkMuted)
        }
    }
}
