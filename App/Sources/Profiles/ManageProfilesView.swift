import SwiftUI

/// profile-picker/editor-view.tsx: `canEditAdvanced = activeIsPrimary` lets the primary profile
/// edit any profile's advanced settings (kid toggle, PIN & sidebar locks), and picker-modal.tsx's
/// `ListView` gives every tile an edit affordance (`canEditThis = isPrimary || p.id === activeId`)
/// that opens `EditorView` for that profile. The TV had no route to this: Settings' "Edit profile"
/// only ever opened `profiles.active`'s own editor (see ProfileEditorView.showAdvanced's own
/// comment), so a primary viewer could never reach a kid's or a guest's advanced settings without
/// switching the active profile to it first. This panel is that route: reachable only when the
/// active profile is primary (SettingsView hides the button that opens it otherwise), it lists
/// every profile and opens `ProfileEditorView(editing:)` for whichever one is picked.
struct ManageProfilesView: View {
    @EnvironmentObject private var profiles: ProfilesStore
    let dismiss: () -> Void
    @State private var editing: ProfilesStore.Profile?

    var body: some View {
        ZStack {
            BP.canvas.ignoresSafeArea()
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: BP.px(18)) {
                    Text("Manage profiles").font(BP.display(32)).foregroundStyle(BP.ink)
                    BPNote(text: "Pick a profile to edit its name, avatar, kid setup, PIN and sidebar locks.")
                    VStack(spacing: BP.px(10)) {
                        ForEach(profiles.profiles) { p in row(p) }
                    }
                    .focusSection()
                }
                .padding(.horizontal, BP.gutter).padding(.top, BP.px(40)).padding(.bottom, BP.hintHeight + BP.px(40))
                .frame(maxWidth: BP.px(680), alignment: .leading)
            }
        }
        .fullScreenCover(item: $editing) { p in
            ProfileEditorView(editing: p, dismiss: { editing = nil })
                // (review) A cover nested in Settings' cover: re-inject the store the editor reads.
                .environmentObject(profiles)
        }
        .onExitCommand { dismiss() }
    }

    private func row(_ p: ProfilesStore.Profile) -> some View {
        Button {
            editing = p
        } label: {
            HStack(spacing: BP.px(14)) {
                ProfileFace(profile: p, size: BP.px(48))
                VStack(alignment: .leading, spacing: BP.px(2)) {
                    Text(p.name).font(BP.sans(16, .semibold)).foregroundStyle(BP.ink)
                    Text(subtitle(p)).font(BP.sans(13)).foregroundStyle(BP.inkMuted)
                }
                Spacer(minLength: 0)
                if p.passwordHash != nil {
                    Image(systemName: "lock.fill").accessibilityHidden(true).foregroundStyle(BP.inkMuted)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(BPActionStyle())
        // UI tests (NavigationTests6): one identifier per profile row, keyed by id like who-tile-<id>.
        .accessibilityIdentifier("manage-profile-\(p.id)")
        .accessibilityLabel(Text(verbatim: T("Edit %@", p.name)))
    }

    private func subtitle(_ p: ProfilesStore.Profile) -> String {
        if p.isPrimary { return T("Primary") }
        if p.kid != nil { return T("Kid profile") }
        return T("Standard profile")
    }
}
