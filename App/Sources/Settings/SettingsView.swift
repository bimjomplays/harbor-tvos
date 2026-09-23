import SwiftUI

/// Settings room, Stage 1 slice: account, sync, profiles, developer, about.
struct SettingsView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var account: AccountStore
    @EnvironmentObject private var profiles: ProfilesStore
    @EnvironmentObject private var sync: SyncReader
    @State private var sheet: Sheet?
    @State private var pinDraft = ""
    @State private var tmdbTesting = false
    @State private var tmdbTestNote: String?

    @EnvironmentObject private var settings: SettingsBridge
    enum Sheet: Identifiable { case harbor, stremio, pin, spikes, tmdb, addons, subLangs, newProfile, editProfile; var id: Int { hashValue } }


    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BP.px(28)) {
                Text("Settings").font(BP.display(36)).foregroundStyle(BP.ink)
                BPSettingsView(openConnect: { sheet = account.isSignedIn ? .tmdb : .harbor })
                    .padding(.bottom, BP.px(10))
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
                section("Trakt") { TraktPanel() }
                section("Simkl") { TraktPanel(service: "simkl", label: "Simkl") }
                section("AniList") { PasteTrackerPanel(service: "anilist", label: "AniList") }
                section("MyAnimeList") { PasteTrackerPanel(service: "mal", label: "MyAnimeList") }
                section("Addons") {
                    row("Stream and catalog addons", detail: "Installed on this TV plus the ones on your Stremio account")
                    Button("Manage addons") { sheet = .addons }.buttonStyle(BPActionStyle(primary: true))
                }
                section("Artwork and rows") {
                    row(settings.slice.tmdbKey.isEmpty ? "Running on Cinemeta" : "TMDB key saved",
                        detail: settings.slice.tmdbKey.isEmpty ? "Add a free TMDB key for Trending, In Theaters, Top Rated and service rows" : "Saved on this device only (\(settings.slice.tmdbKey.count) characters)")
                    HStack(spacing: BP.px(12)) {
                        Button(settings.slice.tmdbKey.isEmpty ? "Connect TMDB" : "Use a different key") { sheet = .tmdb }.buttonStyle(BPActionStyle(primary: settings.slice.tmdbKey.isEmpty))
                        if !settings.slice.tmdbKey.isEmpty {
                            Button(tmdbTesting ? "Testing…" : "Test saved key") { Task { await testSavedKey() } }.buttonStyle(BPActionStyle()).disabled(tmdbTesting)
                            Button("Remove key") { Task { try? await settings.patch(["tmdbKey": .string("")]); tmdbTestNote = nil } }.buttonStyle(BPActionStyle())
                        }
                    }
                    if let tmdbTestNote { BPNote(text: tmdbTestNote, tone: tmdbTestNote.hasPrefix("OK") ? BP.live : BP.danger) }
                }
                section("Playback") {
                    row("Subtitle languages: \(settings.slice.preferredSubLangs.joined(separator: ", "))", detail: "First match wins when searching online subtitles")
                    Button("Choose subtitle languages") { sheet = .subLangs }.buttonStyle(BPActionStyle())
                }
                section("Anime4K") { Anime4KPanel() }
                section("Sync") {
                    row(syncLine, detail: sync.lastPull.map { "Last pulled \($0.formatted(date: .omitted, time: .shortened))" } ?? "Never pulled on this TV")
                    HStack(spacing: BP.px(12)) {
                        Button("Pull now") { Task { await app.refreshRoster() } }.buttonStyle(BPActionStyle()).disabled(!account.isSignedIn)
                        BPNote(text: sync.queued > 0 ? "\(sync.queued) change\(sync.queued == 1 ? "" : "s") waiting to upload" : "Profiles, home rows and services sync both ways. PINs never leave this TV.")
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
                            Button("Edit profile") { sheet = .editProfile }.buttonStyle(BPActionStyle())
                            Button("Add profile") { sheet = .newProfile }.buttonStyle(BPActionStyle())
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
            .padding(.horizontal, BP.gutter).padding(.top, BP.barHeight + BP.px(20)).padding(.bottom, BP.hintHeight + BP.px(20))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { if Fixtures.openSpikes && sheet == nil { sheet = .spikes } }
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
                case .tmdb:
                    VStack(alignment: .leading, spacing: BP.px(16)) {
                        Text("Connect TMDB").font(BP.display(30)).foregroundStyle(BP.ink)
                        TmdbKeyForm(done: { sheet = nil }, skip: { sheet = nil })
                    }
                    .padding(BP.gutter)
                case .addons:
                    AddonsView()
                case .newProfile:
                    ProfileEditorView(editing: nil, dismiss: { sheet = nil })
                case .editProfile:
                    ProfileEditorView(editing: profiles.active, dismiss: { sheet = nil })
                case .subLangs:
                    ScrollView {
                        VStack(alignment: .leading, spacing: BP.px(12)) {
                            Text("Which subtitle languages, in order?").font(BP.display(30)).foregroundStyle(BP.ink)
                            BPNote(text: "First match wins. Most people need only one. Pick again to remove.")
                            SubtitleLanguageGrid()
                            Button("Done") { sheet = nil }.buttonStyle(BPActionStyle(primary: true))
                        }
                        .padding(BP.gutter)
                    }
                case .spikes:
                    SpikeMenuView()
                }
            }
            .environmentObject(app).environmentObject(account).environmentObject(profiles).environmentObject(sync).environmentObject(settings)
        }
    }

    private func testSavedKey() async {
        tmdbTesting = true; defer { tmdbTesting = false }
        let r = await settings.verifyTmdb(key: settings.slice.tmdbKey)
        tmdbTestNote = r.ok ? "OK: TMDB accepted the saved key." : "Rejected. TMDB said: \(r.reason ?? "no details")"
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
        // The whole panel is a focus target, so Down from the Settings cog (far right) lands
        // on the buttons at the left instead of finding nothing under the cog.
        .focusSection()
    }

    private func row(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: BP.px(3)) {
            Text(title).font(BP.sans(16, .semibold)).foregroundStyle(BP.ink)
            Text(detail).font(BP.sans(14)).foregroundStyle(BP.inkMuted)
        }
    }
}


/// Numbered toggle chips for preferred subtitle languages (bp-step-subtitles.tsx), shared by
/// onboarding and Settings. Writes `preferredSubLangs` through the engine on every change.
struct SubtitleLanguageGrid: View {
    @EnvironmentObject private var settings: SettingsBridge
    private static let languages = ["English", "Spanish", "Portuguese", "French", "German", "Italian", "Dutch", "Polish", "Russian", "Turkish", "Arabic", "Japanese", "Korean", "Chinese", "Hindi", "Swedish", "Norwegian", "Danish", "Finnish", "Greek", "Czech", "Hungarian", "Romanian", "Indonesian"]

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: BP.px(10)), count: 4), spacing: BP.px(10)) {
            ForEach(Self.languages, id: \.self) { lang in
                let idx = settings.slice.preferredSubLangs.firstIndex(of: lang)
                Button(idx.map { "\($0 + 1) · \(lang)" } ?? lang) {
                    var list = settings.slice.preferredSubLangs
                    if let i = idx { list.remove(at: i) } else { list.append(lang) }
                    if list.isEmpty { list = ["English"] }
                    Task { try? await settings.patch(["preferredSubLangs": .array(list.map { .string($0) })]) }
                }
                .buttonStyle(BPActionStyle(primary: idx != nil))
            }
        }
        .focusSection()
    }
}
