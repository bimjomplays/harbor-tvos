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
    /// Counts closed covers, so the column above re-reads what a sign-in or key change did.
    @State private var coversClosed = 0
    /// The Artwork and rows section's first button (Connect TMDB / Use a different key).
    @FocusState private var tmdbLead: Bool

    @EnvironmentObject private var settings: SettingsBridge
    /// The eBook tab (EBook/EBookModels.swift EBookGate): a choice for this TV.
    @AppStorage(EBookGate.key) private var ebookOn = false
    enum Sheet: Identifiable { case harbor, stremio, pin, removePin, spikes, tmdb, addons, subLangs, newProfile, editProfile, connect; var id: Int { hashValue } }


    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BP.px(28)) {
                Text("Settings").font(BP.display(36)).foregroundStyle(BP.ink)
                BPSettingsView(openConnect: { sheet = .connect }, refresh: coversClosed)
                    .padding(.bottom, BP.px(10))
                // Stage 9: settings-sidebar.tsx "LOOK & FEEL" → Appearance (theme-panel.tsx).
                section("Appearance") { AppearancePanel() }
                // chrome/nav-edit.tsx in-place sidebar editing, for the top bar (Settings/TabsPanel.swift).
                section("Tabs") { TabsPanel() }
                section("Harbor account") {
                    if let s = account.session {
                        row(T("Signed in as %@", s.user.username), detail: s.user.stremioLinked == true ? "Stremio linked" : "Stremio not linked")
                        Button("Sign out") { app.signOutHarbor() }.buttonStyle(BPActionStyle())
                    } else {
                        row("Not signed in", detail: "Sync, themes and friends")
                        Button("Sign in") { sheet = .harbor }.buttonStyle(BPActionStyle(primary: true))
                    }
                }
                section("Stremio") {
                    if let p = profiles.active {
                        if let s = profiles.stremioSession(for: p.id) {
                            row(T("Signed in as %@", s.user.fullname ?? s.user.email), detail: "For the \(p.name) profile")
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
                section("Letterboxd") { LetterboxdPanel() }
                section("Home servers") { HomeServersPanel() }
                section("Addons") {
                    row("Stream and catalog addons", detail: "Installed on this TV plus the ones on your Stremio account")
                    Button("Manage addons") { sheet = .addons }.buttonStyle(BPActionStyle(primary: true))
                }
                section("Artwork and rows") {
                    row(settings.slice.tmdbKey.isEmpty ? "Running on Cinemeta" : "TMDB key saved",
                        detail: settings.slice.tmdbKey.isEmpty ? "Add a free TMDB key for Trending, In Theaters, Top Rated and service rows" : "Saved on this device only (\(settings.slice.tmdbKey.count) characters)")
                    HStack(spacing: BP.px(12)) {
                        Button(settings.slice.tmdbKey.isEmpty ? "Connect TMDB" : "Use a different key") { sheet = .tmdb }.buttonStyle(BPActionStyle(primary: settings.slice.tmdbKey.isEmpty))
                            .focused($tmdbLead)
                        Button { sheet = .connect } label: { Label("Use your phone", systemImage: "iphone") }.buttonStyle(BPActionStyle())
                        if !settings.slice.tmdbKey.isEmpty {
                            Button(tmdbTesting ? "Testing…" : "Test saved key") { Task { await testSavedKey() } }.buttonStyle(BPActionStyle(busy: tmdbTesting))
                            // (settings device pass) Removing the key takes Test and Remove away with it:
                            // the ring goes to Connect TMDB instead of jumping off the section, and a
                            // failed save says so instead of doing nothing.
                            Button("Remove key") {
                                Task {
                                    do {
                                        try await settings.patch(["tmdbKey": .string("")])
                                        tmdbTestNote = nil
                                        tmdbLead = true
                                    } catch {
                                        tmdbTestNote = T("Failed: %@", error.localizedDescription)
                                    }
                                }
                            }
                            .buttonStyle(BPActionStyle())
                        }
                    }
                    if let tmdbTestNote { BPNote(text: tmdbTestNote, tone: tmdbTestNote.hasPrefix("OK") ? BP.live : BP.danger) }
                }
                section("Playback") {
                    row("Subtitle languages: \(settings.slice.preferredSubLangs.joined(separator: ", "))", detail: "First match wins when searching online subtitles")
                    Button("Choose subtitle languages") { sheet = .subLangs }.buttonStyle(BPActionStyle())
                    HStack(spacing: BP.px(8)) {
                        onOff("Resume where you left off", settings.slice.resumePlayback ?? true, key: "resumePlayback")
                        onOff("Ask before resuming", settings.slice.resumePrompt ?? false, key: "resumePrompt")
                        onOff("Confirm before leaving the player", settings.slice.playerConfirmLeave ?? true, key: "playerConfirmLeave")
                    }
                }
                section("Anime4K") { Anime4KPanel() }
                // settings.homeRows (lib/home-customization) and the Simkl home rails (Settings/HomeRowsPanel.swift).
                section("Home rows") { HomeRowsPanel() }
                section("Anime rows") { AnimeRowsPanel() }
                // settings.mangaEnabled (views/manga.tsx EnableGate): the Manga tab, Search's manga
                // results and the anime hero's "Read the Manga" all wait for it.
                section("Manga") {
                    row("Read manga in Harbor", detail: "Reads from a Suwayomi server you run. Adds the Manga tab, manga results in Search and “Read the Manga” on anime pages.")
                    onOff("Manga", settings.slice.mangaEnabled ?? false, key: "mangaEnabled")
                }
                // views/ebook.tsx: the desktop sidebar always lists eBooks; the TV keeps the tab
                // hidden until it is turned on here (Stage 13).
                section("eBooks") {
                    row("Read eBooks in Harbor", detail: "Adds the eBook tab. Apple TV reads Project Gutenberg's public-domain library, with read aloud.")
                    let title: String = "\(T("eBook")): \(T(ebookOn ? "On" : "Off"))"
                    Button(title) { ebookOn.toggle() }.buttonStyle(BPActionStyle(primary: ebookOn))
                        .bpSelected(ebookOn)
                }
                // settings/webhooks-panel.tsx (sports reminders) and sports-api-setting.tsx.
                section("Where alerts go") { SportsWebhooksPanel() }
                section("Sports metadata") { SportsApiKeyPanel() }
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
                                if p.passwordHash == nil { pinDraft = ""; sheet = .pin } else { sheet = .removePin }
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
        .fullScreenCover(item: $sheet, onDismiss: { coversClosed &+= 1 }) { which in
            ZStack {
                BPAmbientBackground()
                switch which {
                case .harbor:
                    HarborSignInForm(done: { sheet = nil }, skip: { sheet = nil }).padding(BP.gutter)
                case .stremio:
                    if let p = profiles.active {
                        StremioSignInForm(profileId: p.id, done: { _ in sheet = nil }, skip: { sheet = nil }).padding(BP.gutter)
                    }
                case .removePin:
                    // Removing a PIN needs that PIN, or it would unlock every locked tab.
                    if let p = profiles.active {
                        PinPadView(profile: p, finish: { ok in
                            if ok { profiles.setPin(nil, for: p.id) }
                            sheet = nil
                        }, title: "Enter the PIN to remove it")
                    }
                case .pin:
                    VStack(alignment: .leading, spacing: BP.px(16)) {
                        Text("Set a 4-digit PIN").font(BP.display(30)).foregroundStyle(BP.ink)
                        BPField(label: "PIN", placeholder: "4 digits", text: $pinDraft, secure: true, keyboard: .numberPad)
                        HStack(spacing: BP.px(12)) {
                            Button("Save") { if let p = profiles.active { profiles.setPin(pinDraft, for: p.id) }; sheet = nil }
                                .buttonStyle(BPActionStyle(primary: true)).disabled(!ProfilesStore.isValidPin(pinDraft))
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
                case .connect:
                    ConnectPane(onBack: { sheet = nil })
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
        guard !tmdbTesting else { return }
        tmdbTesting = true; defer { tmdbTesting = false }
        let r = await settings.verifyTmdb(key: settings.slice.tmdbKey)
        tmdbTestNote = r.ok ? "OK: TMDB accepted the saved key." : "Rejected. TMDB said: \(r.reason ?? "no details")"
    }

    private var syncLine: String {
        switch sync.phase {
        case .idle: return account.isSignedIn ? "Connected" : "Sign in to Harbor to sync"
        case .pulling: return "Pulling…"
        case .failed(let why): return T("Failed: %@", why)
        }
    }

    private var build: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: BP.px(12)) {
            Text(T(title)).font(BP.sans(19, .bold)).foregroundStyle(BP.ink).accessibilityAddTraits(.isHeader)
            content()
        }
        .padding(BP.px(22))
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(BPThemeCardFace(radius: BP.rMD))
        .background(RoundedRectangle(cornerRadius: BP.rMD, style: .continuous).fill(BP.panel))
        .overlay(RoundedRectangle(cornerRadius: BP.rMD, style: .continuous).stroke(BP.edge, lineWidth: 1))
        // The whole panel is a focus target, so Down from the Settings cog (far right) lands
        // on the buttons at the left instead of finding nothing under the cog.
        .focusSection()
    }

    private func onOff(_ label: String, _ on: Bool, key: String) -> some View {
        // A String value, not a literal: an interpolated literal would become the LocalizedStringKey
        // "%@: %@" and borrow an unrelated catalog entry (review 20).
        let title: String = "\(T(label)): \(T(on ? "On" : "Off"))"
        return Button(title) { Task { try? await settings.patch([key: .bool(!on)]) } }.buttonStyle(BPActionStyle(primary: on))
            .bpSelected(on)
    }

    private func row(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: BP.px(3)) {
            Text(T(title)).font(BP.sans(16, .semibold)).foregroundStyle(BP.ink)
            Text(T(detail)).font(BP.sans(14)).foregroundStyle(BP.inkMuted)
        }
    }
}


/// Numbered toggle chips for preferred subtitle languages (bp-step-subtitles.tsx), shared by
/// onboarding and Settings. Writes `preferredSubLangs` through the engine on every change.
struct SubtitleLanguageGrid: View {
    @EnvironmentObject private var settings: SettingsBridge
    /// (settings bug pass) bp-step-subtitles.tsx COMMON: ALL_LANGUAGE_NAMES.slice(0, 24) in upstream's
    /// order (lib/subtitles/language.ts NAMES), the cells the Settings column's subLang row shows.
    /// The TV had its own list, so Spanish (Latin America), Portuguese (Brazil), Thai, Vietnamese or
    /// Hebrew picked there or on the desktop showed here without a cell and could not be removed.
    private static let common = ["English", "Spanish", "Spanish (Latin America)", "French", "German", "Italian", "Japanese", "Korean", "Chinese", "Russian", "Portuguese", "Portuguese (Brazil)", "Arabic", "Hindi", "Thai", "Vietnamese", "Turkish", "Polish", "Dutch", "Swedish", "Norwegian", "Danish", "Finnish", "Hebrew"]

    /// "A language chosen elsewhere but outside the common set still needs a cell, otherwise this
    /// screen can select it away but never give it back."
    private var languages: [String] {
        var out: [String] = Self.common
        for lang in settings.slice.preferredSubLangs where !out.contains(lang) { out.append(lang) }
        return out
    }

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: BP.px(10)), count: 4), spacing: BP.px(10)) {
            ForEach(languages, id: \.self) { lang in
                let idx = settings.slice.preferredSubLangs.firstIndex(of: lang)
                Button(idx.map { "\($0 + 1) · \(lang)" } ?? lang) {
                    var list = settings.slice.preferredSubLangs
                    // Upstream's toggle allows an empty list (the Subtitles summary reads "Off", the
                    // onboarding recap "No subtitle languages set"); forcing English back meant the
                    // last language could never be removed.
                    if let i = idx { list.remove(at: i) } else { list.append(lang) }
                    Task { try? await settings.patch(["preferredSubLangs": .array(list.map { .string($0) })]) }
                }
                .buttonStyle(BPActionStyle(primary: idx != nil))
                .bpSelected(idx != nil)
            }
        }
        .focusSection()
    }
}
