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
                        .buttonStyle(BPActionStyle(primary: true, busy: saving)).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !pinDraftValid)
                        Button("Cancel") { dismiss() }.buttonStyle(BPActionStyle())
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
            name = editing?.name ?? ""
            avatar = editing?.avatar
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

    /// editor-view.tsx `showAdvanced && !draftKid`: the primary profile edits locks, and a new
    /// profile gets them in the same form; a kid profile has its own parent PIN instead.
    private var showSecurity: Bool {
        (editing == nil || profiles.active?.isPrimary == true) && editing?.kid == nil
    }

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
                BPNote(text: lockedCount == 0 ? "No tabs selected" : (hasPin ? "\(lockedCount) selected · locked tabs disappear until this profile's PIN is entered." : "\(lockedCount) selected · Locks only activate once a PIN is set."))
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
        } else {
            let p = profiles.create(name: name, avatar: avatar, color: color)
            if showSecurity, ProfilesStore.isValidPin(draftPin) {
                profiles.setPin(draftPin, for: p.id)
                // editor-view.tsx: selectProfile(p.id, { unlocked: true }) — the PIN was typed seconds ago.
                profiles.markSessionUnlocked(p.id)
            }
            if writeLocks { profiles.setLockedTabs(lockValue, for: p.id) }
        }
        dismiss()
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
