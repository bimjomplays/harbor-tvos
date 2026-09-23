import SwiftUI

/// Live TV (Stage 8 slice): M3U playlists → grouped channel list → mpv with live options.
@MainActor
final class LiveModel: ObservableObject {
    struct Playlist: Decodable, Identifiable { var id: String; var name: String; var url: String }
    struct Channel: Decodable, Identifiable { var id: String; var name: String; var logo: String?; var url: String; var group: String? }
    struct Group: Decodable, Identifiable { var name: String; var channels: [Channel]; var id: String { name } }
    struct Parsed: Decodable { var groups: [Group]; var total: Int; var truncated: Bool }

    @Published private(set) var playlists: [Playlist] = []
    @Published private(set) var groups: [Group] = []
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    @Published private(set) var truncatedNote: String?
    @Published var selectedPlaylist: String?
    @Published var selectedGroup: String?

    func load() async {
        playlists = (try? await HarborEngine.shared.call("live.playlists", [])) ?? []
        if selectedPlaylist == nil { selectedPlaylist = playlists.first?.id }
        await loadChannels()
    }

    func loadChannels() async {
        guard let id = selectedPlaylist else { groups = []; return }
        loading = true; defer { loading = false }
        error = nil
        do {
            let p: Parsed = try await HarborEngine.shared.call("live.channels", [id])
            groups = p.groups
            truncatedNote = p.truncated ? "Showing the first 4,000 of \(p.total) channels." : nil
            if selectedGroup == nil || !groups.contains(where: { $0.name == selectedGroup }) { selectedGroup = groups.first?.name }
        } catch { self.error = error.localizedDescription; groups = [] }
    }

    func add(name: String, url: String) async {
        struct Added: Decodable { var id: String }
        if let a: Added = try? await HarborEngine.shared.call("live.addPlaylist", [name, url]) { selectedPlaylist = a.id }
        await load()
    }

    func remove(_ id: String) async {
        _ = try? await HarborEngine.shared.callJSON("live.removePlaylist", [.string(id)])
        if selectedPlaylist == id { selectedPlaylist = nil }
        await load()
    }

    var channels: [Channel] { groups.first { $0.name == selectedGroup }?.channels ?? [] }
}

struct LiveView: View {
    @StateObject private var model = LiveModel()
    @State private var playing: LiveModel.Channel?
    @State private var addUrl = ""
    @State private var addName = ""
    @State private var showAdd = false
    @State private var adding = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            if model.playlists.isEmpty || showAdd {
                addForm
            } else {
                HStack(alignment: .top, spacing: BP.px(30)) {
                    sidebar
                    channelGrid
                }
                .padding(.horizontal, BP.gutter).padding(.top, BP.barHeight + BP.px(16))
            }
        }
        .task { await model.load() }
        .fullScreenCover(item: $playing) { ch in
            PlayerScreen(title: ch.name, subtitle: ch.group, url: URL(string: ch.url) ?? URL(string: "about:blank")!, isLive: true) { _ in playing = nil }
        }
    }

    private var addForm: some View {
        VStack(alignment: .leading, spacing: BP.px(14)) {
            Text("Live TV").font(BP.display(36)).foregroundStyle(BP.ink)
            BPNote(text: "Add an M3U playlist URL. Xtream Codes logins and EPG guides arrive with the rest of Stage 8.")
            BPField(label: "Playlist name", placeholder: "My channels", text: $addName)
            BPField(label: "M3U URL", placeholder: "https://…/playlist.m3u", text: $addUrl, keyboard: .URL)
            HStack(spacing: BP.px(12)) {
                Button(adding ? "Adding…" : "Add playlist") {
                    adding = true
                    Task { await model.add(name: addName, url: addUrl); addUrl = ""; addName = ""; showAdd = false; adding = false }
                }
                .buttonStyle(BPActionStyle(primary: true)).disabled(adding || addUrl.count < 8)
                if !model.playlists.isEmpty { Button("Cancel") { showAdd = false }.buttonStyle(BPActionStyle()) }
            }
            if let e = model.error { BPNote(text: e, tone: BP.danger) }
        }
        .frame(maxWidth: BP.px(560))
        .padding(.horizontal, BP.gutter).padding(.top, BP.barHeight + BP.px(20))
        .focusSection()
    }

    private var sidebar: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: BP.px(8)) {
                Text("Live TV").font(BP.display(30)).foregroundStyle(BP.ink)
                ForEach(model.playlists) { pl in
                    Button(pl.name) { model.selectedPlaylist = pl.id; Task { await model.loadChannels() } }
                        .buttonStyle(BPActionStyle(primary: model.selectedPlaylist == pl.id))
                }
                HStack(spacing: BP.px(8)) {
                    Button("Add") { showAdd = true }.buttonStyle(BPActionStyle())
                    if let id = model.selectedPlaylist { Button("Remove") { Task { await model.remove(id) } }.buttonStyle(BPActionStyle()) }
                }
                Divider().overlay(BP.edge2).padding(.vertical, BP.px(6))
                if model.loading { ProgressView().tint(BP.inkMuted) }
                ForEach(model.groups) { g in
                    Button("\(g.name)  \(g.channels.count)") { model.selectedGroup = g.name }
                        .buttonStyle(BPActionStyle(primary: model.selectedGroup == g.name))
                }
                if let e = model.error { BPNote(text: e, tone: BP.danger) }
                if let t = model.truncatedNote { BPNote(text: t) }
            }
            .padding(.bottom, BP.hintHeight + BP.px(40))
        }
        .frame(width: BP.px(300))
        .focusSection()
    }

    private var channelGrid: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(BP.px(190)), spacing: BP.px(14)), count: 5), spacing: BP.px(14)) {
                ForEach(model.channels) { ch in
                    Button { playing = ch } label: {
                        VStack(spacing: BP.px(6)) {
                            RemoteImage(url: ch.logo, contentMode: .fit).frame(width: BP.px(120), height: BP.px(60))
                            Text(ch.name).font(BP.sans(12, .semibold)).foregroundStyle(BP.ink).lineLimit(2).multilineTextAlignment(.center)
                        }
                        .padding(BP.px(10))
                        .frame(width: BP.px(190), height: BP.px(120))
                        .background(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).fill(BP.panel2))
                    }
                    .buttonStyle(BPTileStyle(radius: BP.rSM))
                }
            }
            .padding(.vertical, BP.px(14)).padding(.bottom, BP.hintHeight + BP.px(40))
        }
        .focusSection()
    }
}
