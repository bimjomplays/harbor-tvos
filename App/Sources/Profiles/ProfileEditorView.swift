import SwiftUI

/// Create or edit a profile: name, avatar from upstream's catalog, brand colour, and
/// (editor-view.tsx SecurityView / TabsView) the tabs its PIN locks.
struct ProfileEditorView: View {
    @EnvironmentObject private var profiles: ProfilesStore
    @ObservedObject private var parental = ParentalGate.shared
    let editing: ProfilesStore.Profile?
    let dismiss: () -> Void

    struct AvatarGroup: Decodable, Identifiable { struct Item: Decodable, Identifiable { var id: String; var name: String; var path: String }; var group: String; var transparent: Bool; var items: [Item]; var id: String { group } }

    @State private var name = ""
    @State private var avatar: String?
    @State private var color = ""
    @State private var groups: [AvatarGroup] = []
    @State private var colors: [String] = []
    @State private var confirmDelete = false
    /// editor-view.tsx draftLockedTabs, as the TabsView toggles it ({ ...DEFAULT_HIDDEN, ...initial }).
    @State private var draftLocks: [String: Bool] = [:]
    @State private var initialLocks: [String: Bool] = [:]
    /// editor-view.tsx draftPin: a new profile's PIN, set in the same form.
    @State private var draftPin = ""
    @State private var pinToUnlock = false
    /// (kids parity pass) kid-toggle.tsx / editor-view.tsx draftKid: on turns the security section
    /// into the kid setup panel. Never available for the primary profile (KidToggle's `!isPrimary`).
    @State private var isKid = false
    /// kids-setup-panel.tsx AGES: cosmetic only (upstream never reads it for content filtering,
    /// confirmed by grep of kids-specs.ts/kids-filter.ts — the kid-safe rating filter is fixed).
    @State private var kidAge = 7
    /// kids-setup-panel.tsx CURFEWS: minutes, nil = "No limit".
    @State private var kidCurfewMinutes: Int?
    /// kids-setup-panel.tsx draftParentPin: empty keeps the existing hash (editing a kid that
    /// already has one); 4 digits replaces it, as editor-view.tsx save does.
    @State private var kidParentPin = ""
    /// (profiles bug pass) A second Select on Create while the lock value was fetched made a second profile.
    @State private var saving = false
    @State private var deleting = false
    /// (profiles focus pass) "Enter PIN to change locks" and the lock tiles: the ring comes back
    /// from the PIN pad to the button that opened it (or, once unlocked, to the first tile). The pad
    /// left with the ring on it and tvOS put it on the Name field at the top of the form.
    @FocusState private var lockFocus: String?

    var body: some View {
        ZStack {
            BP.canvas.ignoresSafeArea()
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: BP.px(16)) {
                    HStack(spacing: BP.px(18)) {
                        ProfileFace(profile: preview, size: BP.px(96))
                        Text(editing == nil ? "New profile" : "Edit profile").font(BP.display(32)).foregroundStyle(BP.ink)
                    }
                    BPField(label: "Name", placeholder: "Who is this for?", text: $name)
                        // UI tests (NavigationTests6): Save is disabled until this has text, so the
                        // create-profile test needs to type into it.
                        .accessibilityIdentifier("profile-name-field")
                    HStack(spacing: BP.px(8)) {
                        Text("Colour").font(BP.sans(13, .semibold)).foregroundStyle(BP.inkMuted)
                        ForEach(colors, id: \.self) { c in
                            Button { color = c } label: {
                                Circle().fill(Color(css: c) ?? BP.ink).frame(width: BP.px(30), height: BP.px(30))
                                    .overlay(Circle().strokeBorder(BP.ink, lineWidth: color == c ? 3 : 0))
                            }
                            .buttonStyle(.plain)
                            // A swatch has no words: "Color 3", selected when it is the profile's.
                            .accessibilityLabel(Text(verbatim: "\(T("Color")) \((colors.firstIndex(of: c) ?? 0) + 1)"))
                            .bpSelected(color == c)
                        }
                    }
                    .focusSection()
                    if showKidToggle { kidSection }
                    if showSecurity { security }
                    ForEach(groups) { g in
                        VStack(alignment: .leading, spacing: BP.px(6)) {
                            Text(g.group).font(BP.sans(13, .semibold)).foregroundStyle(BP.inkMuted)
                            // (layout pass) 14 faces (1 863 pt) overran the 1 632 pt page; 12 fit (1 595 pt).
                            LazyVGrid(columns: Array(repeating: GridItem(.fixed(BP.px(72)), spacing: BP.px(8)), count: 12), spacing: BP.px(8)) {
                                ForEach(g.items) { item in
                                    Button { avatar = item.path } label: {
                                        ZStack {
                                            Circle().fill(Color(css: color) ?? BP.panel2)
                                            if let img = Self.bundled(item.path) { Image(uiImage: img).resizable().scaledToFill() }
                                        }
                                        .frame(width: BP.px(72), height: BP.px(72))
                                        .clipShape(Circle())
                                        .overlay(Circle().strokeBorder(BP.ink, lineWidth: avatar == item.path ? 3 : 0))
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel(item.name)
                                    .bpSelected(avatar == item.path)
                                }
                            }
                        }
                        .focusSection()
                    }
                    HStack(spacing: BP.px(10)) {
                        Button(editing == nil ? "Create" : "Save") { Task { await save() } }
                        .buttonStyle(BPActionStyle(primary: true, busy: saving)).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !pinDraftValid || !kidPinDraftValid)
                        // UI tests (NavigationTests6): the one button that commits everything in this
                        // form, including the kid parent PIN field above (it has no Save of its own).
                        .accessibilityIdentifier("profile-save")
                        Button("Cancel") { dismiss() }.buttonStyle(BPActionStyle())
                            // UI tests (NavigationTests6): Down from the avatar catalog can land on
                            // either button in this row; this lets a test recover from landing here.
                            .accessibilityIdentifier("profile-cancel")
                        if let e = editing, !e.isPrimary {
                            Button(confirmDelete ? "Delete for real" : "Delete profile") {
                                // (profiles device pass) The delete awaits two engine calls before the
                                // profile leaves the roster: a second Select meanwhile ran it again
                                // (a second tombstone and purge) and Save could still write to it.
                                if confirmDelete {
                                    guard !deleting else { return }
                                    deleting = true
                                    Task { await profiles.delete(e.id); dismiss() }
                                } else { confirmDelete = true }
                            }
                            .buttonStyle(BPActionStyle(busy: deleting))
                        }
                    }
                    .focusSection()
                    if confirmDelete { BPNote(text: "This removes the profile from every device on your account, with its PIN and resume points on this TV.", tone: BP.danger) }
                }
                .padding(.horizontal, BP.gutter).padding(.top, BP.px(40)).padding(.bottom, BP.hintHeight + BP.px(40))
            }
            .opacity(pinToUnlock ? 0 : 1)
            .disabled(pinToUnlock)
            if pinToUnlock, let e = editing {
                PinPadView(profile: e) { ok in
                    if ok { profiles.unlockParental(e.id) }
                    pinToUnlock = false
                    returnRingFromPin()
                }
                .transition(.opacity)
            }
        }
        .task {
            // (profiles bug pass) Before any await: a name typed while the lock list loaded was
            // overwritten when the task resumed.
            name = editing?.name ?? (Fixtures.active ? (Fixtures.newProfileName ?? "") : "")
            avatar = editing?.avatar
            // (kids parity pass) editor-view.tsx draftKid seed: `editing?.kid ?? null`.
            if let kid = editing?.kid {
                isKid = true
                kidAge = kid.age
                kidCurfewMinutes = kid.curfewMinutes
            }
            await parental.loadLockable()
            if case .object(let o)? = editing?.lockedTabs {
                initialLocks = o.compactMapValues { $0.bool }
                draftLocks = initialLocks
            }
            groups = (try? await HarborEngine.shared.call("profilesRoom.avatars", [])) ?? []
            colors = (try? await HarborEngine.shared.call("profilesRoom.colors", [])) ?? ProfilesStore.colors
            if color.isEmpty {
                if let c = editing?.color { color = c }
                else {
                    // Not inside `??`: its right-hand side is an autoclosure that cannot await.
                    let picked: String? = try? await HarborEngine.shared.call("profilesRoom.pickColor", [profiles.profiles.map(\.color)])
                    color = picked ?? colors.first ?? ProfilesStore.colors[0]
                }
            }
        }
        .onExitCommand { dismiss() }
    }

    // MARK: PIN & sidebar locks (editor-view.tsx SecurityRow / SecurityView / TabsView)

    /// editor-view.tsx lines 111-113/496-500: `canEditAdvanced = activeIsPrimary`,
    /// `showAdvanced = canEditAdvanced || mode.kind === "create"`. This is parental control by
    /// design: a non-primary profile editing ITSELF never gets the kid toggle or PIN & sidebar locks
    /// either (only the primary, or the create form) — upstream's own `isOwnProfile` only widens a
    /// separate gate (letting a non-primary open its own editor at all, `!isOwnProfile &&
    /// !canEditAdvanced` → BlockedView) and is never part of `showAdvanced` itself. (NavigationTests6
    /// review) An earlier version of this line treated self-edit as advanced too, matching upstream's
    /// visible symptom (a non-primary profile could never re-open its own kid toggle after creation)
    /// but not the cause: the actual gap is that this app has no call site at all for "the primary
    /// opens ANOTHER profile's editor" (Settings' `.editProfile` always passes `profiles.active`), so
    /// upstream's one intended path to a non-primary profile's advanced settings does not exist here
    /// yet — tracked in docs/parity-gaps.md rather than worked around by loosening this rule.
    private var showAdvanced: Bool { editing == nil || profiles.active?.isPrimary == true }

    /// editor-view.tsx `showAdvanced && !isPrimary`: KidToggle is never shown for the primary
    /// profile (it can't become a kid — ProfilesStore.setKid refuses it too).
    private var showKidToggle: Bool { showAdvanced && editing?.isPrimary != true }

    /// editor-view.tsx `showAdvanced && !draftKid`: a kid profile has its own parent PIN instead
    /// of tab locks.
    private var showSecurity: Bool { showAdvanced && !isKid }

    /// editor-view.tsx `canSave`'s kid half: `!draftKid || !draftParentPin || draftParentPin.length === 4`.
    private var kidPinDraftValid: Bool { !isKid || kidParentPin.isEmpty || ProfilesStore.isValidPin(kidParentPin) }

    /// editor-view.tsx `locked`: the profile has a PIN (or the new one will).
    private var hasPin: Bool { editing.map { $0.passwordHash != nil } ?? ProfilesStore.isValidPin(draftPin) }

    /// The active profile is locked right now (parental.tsx `locked`): its locks change only after
    /// its PIN, or a kid at the TV could open Settings and lift them.
    private var needsUnlock: Bool {
        guard let e = editing, e.id == profiles.activeId else { return false }
        return parental.gate.locked
    }

    private var lockedCount: Int { draftLocks.values.filter { $0 }.count }

    private var pinDraftValid: Bool { draftPin.isEmpty || ProfilesStore.isValidPin(draftPin) }

    private var securityLine: String {
        let pin = T(hasPin ? "PIN on" : "PIN off")
        let tabs = lockedCount == 0 ? T("no tab locks") : (hasPin ? T("%lld tabs locked", lockedCount) : T("Locks only activate once a PIN is set."))
        return "\(pin) · \(tabs)"
    }

    // MARK: Kid profile setup (kid-toggle.tsx + kids-setup-panel.tsx)

    /// kids-setup-panel.tsx `KID_AVATARS`: 5 kid-themed faces distinct from the general catalog
    /// below (upstream shows both; the general grid already covers "any avatar for any profile").
    private static let kidAvatars = (1...5).map { "/kids/avatars/kid-\($0).webp" }
    /// kids-setup-panel.tsx `AGES`.
    private static let kidAges = [3, 5, 7, 9, 12]
    /// kids-setup-panel.tsx `CURFEWS`.
    private static let kidCurfews: [(label: String, minutes: Int?)] = [
        ("No limit", nil), ("30 min", 30), ("1 hour", 60), ("1½ hr", 90), ("2 hr", 120), ("3 hr", 180),
    ]

    @ViewBuilder private var kidSection: some View {
        VStack(alignment: .leading, spacing: BP.px(10)) {
            HStack(spacing: BP.px(10)) {
                Image(systemName: "star.fill").foregroundStyle(isKid ? BP.live : BP.inkMuted).accessibilityHidden(true)
                Text("Kids profile").font(BP.sans(16, .semibold)).foregroundStyle(BP.ink)
                Spacer(minLength: 0)
                // No SwiftUI Toggle/switch elsewhere on this remote-driven UI: a two-state button
                // matches the lock tiles below (BPActionStyle(primary:) reads as the "on" state).
                Button(isKid ? "On" : "Off") { isKid.toggle() }.buttonStyle(BPActionStyle(primary: isKid)).bpSelected(isKid)
                    // UI tests (NavigationTests6): the master toggle for the kid setup panel below.
                    .accessibilityIdentifier("profile-kid-toggle")
            }
            if !isKid {
                BPNote(text: "Gives this profile its own Kids space, a kid-safe catalog, an optional daily watch limit and a parent PIN — instead of PIN & sidebar locks.")
            } else {
                HStack(spacing: BP.px(10)) {
                    ForEach(Self.kidAvatars, id: \.self) { path in
                        Button { avatar = path } label: {
                            ZStack {
                                Circle().fill(BP.panel2)
                                if let img = Self.bundled(path) { Image(uiImage: img).resizable().scaledToFill() }
                            }
                            .frame(width: BP.px(56), height: BP.px(56))
                            .clipShape(Circle())
                            .overlay(Circle().strokeBorder(BP.ink, lineWidth: avatar == path ? 3 : 0))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text(verbatim: T("Kids avatar %lld", (Self.kidAvatars.firstIndex(of: path) ?? 0) + 1)))
                        .bpSelected(avatar == path)
                    }
                }
                .focusSection()
                VStack(alignment: .leading, spacing: BP.px(4)) {
                    Text("Age level").font(BP.sans(13, .semibold)).foregroundStyle(BP.inkMuted)
                    HStack(spacing: BP.px(8)) {
                        ForEach(Self.kidAges, id: \.self) { a in
                            Button("\(a)") { kidAge = a }.buttonStyle(BPActionStyle(primary: kidAge == a)).bpSelected(kidAge == a)
                                // UI tests (NavigationTests6): one identifier per age pill.
                                .accessibilityIdentifier("profile-kid-age-\(a)")
                        }
                    }
                    Text("Sets the age level for the kids space.").font(BP.sans(13)).foregroundStyle(BP.inkMuted)
                }
                // (CI fix 2026-09-27) Full width: the Kids toggle sits at the row's right edge, and a
                // section only as wide as its pills had no overlap below it, so Down went nowhere
                // (run 36308550673). A full-width section takes the move and lands on its nearest pill.
                .frame(maxWidth: .infinity, alignment: .leading)
                .focusSection()
                VStack(alignment: .leading, spacing: BP.px(4)) {
                    Text("Daily watch time").font(BP.sans(13, .semibold)).foregroundStyle(BP.inkMuted)
                    HStack(spacing: BP.px(8)) {
                        ForEach(Self.kidCurfews, id: \.label) { c in
                            Button(T(c.label)) { kidCurfewMinutes = c.minutes }.buttonStyle(BPActionStyle(primary: kidCurfewMinutes == c.minutes)).bpSelected(kidCurfewMinutes == c.minutes)
                                // UI tests (NavigationTests6): one identifier per curfew pill, "none" for "No limit".
                                .accessibilityIdentifier("profile-kid-curfew-\(c.minutes.map { String($0) } ?? "none")")
                        }
                    }
                    Text("Stops playback when the daily limit is reached. A parent PIN lets you allow more time.").font(BP.sans(13)).foregroundStyle(BP.inkMuted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .focusSection()
                VStack(alignment: .leading, spacing: BP.px(4)) {
                    BPField(label: "Parent PIN", placeholder: editing?.kid?.parentPinHash != nil ? "••••" : "4 digits", text: $kidParentPin, secure: true, keyboard: .numberPad)
                        .frame(maxWidth: BP.px(420), alignment: .leading)
                    Text(editing?.kid?.parentPinHash != nil && kidParentPin.isEmpty
                         ? "PIN set"
                         : "Optional. Used to allow more watch time. Without a PIN, switch profiles when time is up.")
                        .font(BP.sans(13)).foregroundStyle(BP.inkMuted)
                    if !kidPinDraftValid { BPNote(text: "Enter all 4 digits to save this PIN.", tone: BP.danger) }
                }
            }
        }
        .focusSection()
    }

    @ViewBuilder private var security: some View {
        VStack(alignment: .leading, spacing: BP.px(10)) {
            HStack(spacing: BP.px(10)) {
                Image(systemName: hasPin ? "lock.fill" : "lock.open").foregroundStyle(hasPin ? BP.live : BP.inkMuted).accessibilityHidden(true)
                Text("PIN & sidebar locks").font(BP.sans(16, .semibold)).foregroundStyle(BP.ink)
                Text(securityLine).font(BP.sans(14)).foregroundStyle(BP.inkMuted)
            }
            if editing == nil {
                BPField(label: "PIN", placeholder: "4 digits (optional)", text: $draftPin, secure: true, keyboard: .numberPad)
                    .frame(maxWidth: BP.px(420), alignment: .leading)
            } else if !hasPin {
                BPNote(text: "No PIN set. Set one in Settings › Profiles.")
            }
            if needsUnlock {
                HStack(spacing: BP.px(12)) {
                    Button("Enter PIN to change locks") { pinToUnlock = true }.buttonStyle(BPActionStyle(primary: true))
                        .focused($lockFocus, equals: "unlock")
                    BPNote(text: T("%lld tabs require this profile's PIN.", lockedCount))
                }
            } else {
                Text("Lock sidebar tabs").font(BP.sans(13, .semibold)).foregroundStyle(BP.inkMuted)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: BP.px(10)), count: 5), alignment: .leading, spacing: BP.px(10)) {
                    ForEach(parental.lockable) { tab in
                        let on = draftLocks[tab.key] ?? false
                        Button { draftLocks[tab.key] = !on } label: {
                            HStack(spacing: BP.px(8)) {
                                Image(systemName: on ? "lock.fill" : "lock.open").accessibilityHidden(true)
                                Text(tab.label).lineLimit(1)
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(BPActionStyle(primary: on))
                        .focused($lockFocus, equals: "lock:" + tab.key)
                        .accessibilityIdentifier("lock-tab-\(tab.key)")
                        // The padlock: a locked tab reads as selected.
                        .bpSelected(on)
                    }
                }
                BPNote(text: lockedCount == 0 ? "No tabs selected" : (hasPin ? T("%lld selected · locked tabs disappear until this profile's PIN is entered.", lockedCount) : T("%lld selected · Locks only activate once a PIN is set.", lockedCount)))
            }
        }
        .focusSection()
    }

    /// (profiles focus pass) After the PIN pad: the unlock button when it is still there (Back, a
    /// miss), else the first lock tile (the gate's refresh after the unlock takes the button away a
    /// moment later). Set again once the pad's fade has ended, as Who's watching does for its tiles.
    private func returnRingFromPin() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { placeRingAfterPin() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { placeRingAfterPin() }
    }

    private func placeRingAfterPin() {
        guard !pinToUnlock else { return }
        if needsUnlock {
            lockFocus = "unlock"
        } else if let first = parental.lockable.first {
            lockFocus = "lock:" + first.key
        }
    }

    /// editor-view.tsx save: updateProfile (edit) or createProfile + patch { passwordHash, lockedTabs }.
    private func save() async {
        guard !saving else { return }
        saving = true
        var writeLocks = false
        var lockValue: AnyJSON? = nil
        let changed = draftLocks.filter { $0.value } != initialLocks.filter { $0.value }
        if showSecurity, !needsUnlock, changed,
           let v = try? await HarborEngine.shared.callJSON("parental.lockedTabsValue", [.object(draftLocks.mapValues { AnyJSON.bool($0) })]) {
            writeLocks = true
            lockValue = v
        }
        if let e = editing {
            profiles.update(e.id, name: name, avatar: .some(avatar), color: color)
            if writeLocks { profiles.setLockedTabs(lockValue, for: e.id) }
            // (kids parity pass) Only when the toggle was actually shown: `showKidToggle` false
            // (editing without being the primary profile) means the draft was never editable, so
            // leave the existing kid config untouched rather than resubmit it.
            if showKidToggle { profiles.setKid(kidToSave(existing: e.kid), for: e.id) }
        } else {
            let p = profiles.create(name: name, avatar: avatar, color: color)
            if showSecurity, ProfilesStore.isValidPin(draftPin) {
                profiles.setPin(draftPin, for: p.id)
                // editor-view.tsx: selectProfile(p.id, { unlocked: true }) — the PIN was typed seconds ago.
                profiles.markSessionUnlocked(p.id)
            }
            if writeLocks { profiles.setLockedTabs(lockValue, for: p.id) }
            if isKid { profiles.setKid(kidToSave(existing: nil), for: p.id) }
        }
        dismiss()
    }

    /// editor-view.tsx save's `kidToSave`: `nil` when the toggle is off (turns a kid back into an
    /// adult profile); else the draft age/curfew, keeping the existing parent-PIN hash unless a
    /// fresh 4-digit PIN was typed.
    private func kidToSave(existing: ProfilesStore.Profile.Kid?) -> ProfilesStore.Profile.Kid? {
        guard isKid else { return nil }
        let hash = ProfilesStore.isValidPin(kidParentPin) ? ProfilesStore.hashPin(kidParentPin) : existing?.parentPinHash
        return ProfilesStore.Profile.Kid(age: kidAge, curfewMinutes: kidCurfewMinutes, parentPinHash: hash)
    }

    private var preview: ProfilesStore.Profile {
        ProfilesStore.Profile(id: editing?.id ?? "preview", syncId: nil, name: name.isEmpty ? "?" : name, avatar: avatar, color: color.isEmpty ? ProfilesStore.colors[0] : color,
                              isPrimary: editing?.isPrimary ?? false, kid: nil, passwordHash: nil, createdAt: 0)
    }

    private static func bundled(_ path: String) -> UIImage? {
        // (perf pass) Cached: this grid of 65 avatars re-read every file on each keystroke and pick.
        ProfileFace.bundledArt(path)
    }
}
