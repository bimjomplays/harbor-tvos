import SwiftUI

/// Settings → Startup & default (views/settings/account/startup-defaults.tsx StartupDefaults):
/// "Who's watching" (profilePromptInterval: Every launch, Every 15 min, Every 30 min, Never) and
/// "Start as" (defaultProfileId: No default profile, or any profile without a PIN). Upstream
/// shows the group only when there is more than one profile (SettingsView does the same). The
/// values are read at launch and on return by the engine (profilesRoom.launchPicker /
/// returnPicker, lib/profiles.tsx), and AppModel acts on them. The "Who's watching background"
/// group beside them is a desktop picker's uploaded image, which the TV's chooser does not draw.
struct StartupDefaultsPanel: View {
    @EnvironmentObject private var settings: SettingsBridge
    @EnvironmentObject private var profiles: ProfilesStore
    /// A pick whose save is still running: a second press waits for it (the cells stay focusable).
    @State private var saving = false

    /// startup-defaults.tsx INTERVALS.
    private static let intervals: [(String, String)] = [("launch", "Every launch"), ("15m", "Every 15 min"), ("30m", "Every 30 min"), ("never", "Never")]

    /// `settings.profilePromptInterval ?? "launch"`.
    private var interval: String { settings.slice.profilePromptInterval ?? "launch" }
    /// `settings.defaultProfileId ?? ""`.
    private var defaultId: String { settings.slice.defaultProfileId ?? "" }

    /// The Dropdown's options: "No default profile", then `profiles.filter((p) => !p.passwordHash)`.
    private var choices: [(String, String)] {
        let open: [(String, String)] = profiles.profiles.filter { $0.passwordHash == nil }.map { ($0.id, $0.name) }
        return [("", T("No default profile"))] + open
    }

    var body: some View {
        VStack(alignment: .leading, spacing: BP.px(12)) {
            heading("Who's watching", detail: "Choose when Harbor asks you to pick a profile. Timed prompts appear when you return to Harbor.")
            HStack(spacing: BP.px(8)) {
                ForEach(Self.intervals, id: \.0) { value, label in
                    let on: Bool = interval == value
                    Button(T(label)) { pick("profilePromptInterval", value) }
                        .buttonStyle(BPActionStyle(primary: on))
                        .bpSelected(on)
                }
            }
            .focusSection()
            heading("Start as", detail: "Open this profile at launch. Timed prompts can still appear later. Profiles with a PIN cannot be a default.")
                .padding(.top, BP.px(6))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: BP.px(8)) {
                    ForEach(choices, id: \.0) { id, name in
                        let on: Bool = defaultId == id
                        Button(name) { pick("defaultProfileId", id) }
                            .buttonStyle(BPActionStyle(primary: on))
                            .bpSelected(on)
                    }
                }
                .padding(.vertical, BP.px(4))
            }
            .scrollClipDisabled()
            .focusSection()
        }
    }

    private func heading(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: BP.px(3)) {
            Text(T(title)).font(BP.sans(16, .semibold)).foregroundStyle(BP.ink)
            Text(T(detail)).font(BP.sans(14)).foregroundStyle(BP.inkMuted).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// startup-defaults.tsx `update({ [key]: value })`: the effective settings of the profile in use.
    private func pick(_ key: String, _ value: String) {
        guard !saving else { return }
        saving = true
        Task {
            try? await settings.patch([key: .string(value)])
            saving = false
        }
    }
}
