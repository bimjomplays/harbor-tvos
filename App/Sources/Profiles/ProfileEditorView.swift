import SwiftUI

/// Create or edit a profile: name, avatar from upstream's catalog, brand colour.
struct ProfileEditorView: View {
    @EnvironmentObject private var profiles: ProfilesStore
    let editing: ProfilesStore.Profile?
    let dismiss: () -> Void

    struct AvatarGroup: Decodable, Identifiable { struct Item: Decodable, Identifiable { var id: String; var name: String; var path: String }; var group: String; var transparent: Bool; var items: [Item]; var id: String { group } }

    @State private var name = ""
    @State private var avatar: String?
    @State private var color = ""
    @State private var groups: [AvatarGroup] = []
    @State private var colors: [String] = []
    @State private var confirmDelete = false

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
                        }
                    }
                    .focusSection()
                    ForEach(groups) { g in
                        VStack(alignment: .leading, spacing: BP.px(6)) {
                            Text(g.group).font(BP.sans(13, .semibold)).foregroundStyle(BP.inkMuted)
                            LazyVGrid(columns: Array(repeating: GridItem(.fixed(BP.px(72)), spacing: BP.px(8)), count: 14), spacing: BP.px(8)) {
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
                                }
                            }
                        }
                        .focusSection()
                    }
                    HStack(spacing: BP.px(10)) {
                        Button(editing == nil ? "Create" : "Save") {
                            if let e = editing { profiles.update(e.id, name: name, avatar: .some(avatar), color: color) }
                            else { profiles.create(name: name, avatar: avatar, color: color) }
                            dismiss()
                        }
                        .buttonStyle(BPActionStyle(primary: true)).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                        Button("Cancel") { dismiss() }.buttonStyle(BPActionStyle())
                        if let e = editing, !e.isPrimary {
                            Button(confirmDelete ? "Delete for real" : "Delete profile") {
                                if confirmDelete { Task { await profiles.delete(e.id); dismiss() } } else { confirmDelete = true }
                            }
                            .buttonStyle(BPActionStyle())
                        }
                    }
                    .focusSection()
                    if confirmDelete { BPNote(text: "This removes the profile from every device on your account, with its PIN and resume points on this TV.", tone: BP.danger) }
                }
                .padding(.horizontal, BP.gutter).padding(.top, BP.px(40)).padding(.bottom, BP.hintHeight + BP.px(40))
            }
        }
        .task {
            name = editing?.name ?? ""
            avatar = editing?.avatar
            groups = (try? await HarborEngine.shared.call("profilesRoom.avatars", [])) ?? []
            colors = (try? await HarborEngine.shared.call("profilesRoom.colors", [])) ?? ProfilesStore.colors
            if color.isEmpty {
                color = editing?.color ?? ((try? await HarborEngine.shared.call("profilesRoom.pickColor", [profiles.profiles.map(\.color)])) ?? colors.first ?? ProfilesStore.colors[0])
            }
        }
        .onExitCommand { dismiss() }
    }

    private var preview: ProfilesStore.Profile {
        ProfilesStore.Profile(id: editing?.id ?? "preview", syncId: nil, name: name.isEmpty ? "?" : name, avatar: avatar, color: color.isEmpty ? ProfilesStore.colors[0] : color,
                              isPrimary: editing?.isPrimary ?? false, kid: nil, passwordHash: nil, createdAt: 0)
    }

    private static func bundled(_ path: String) -> UIImage? {
        UIImage(contentsOfFile: Bundle.main.bundleURL.appendingPathComponent(String(path.dropFirst())).path)
    }
}
