import SwiftUI

// MARK: - Credits (music-listening-details.tsx MusicCredits)

/// A recording's contributors (main artist, featured artist, composer, lyricist, producer,
/// performer), each opening its own artist page, and the source buttons (Deezer / MusicBrainz)
/// the credits came from. Shared by Now Playing's About tab (MusicAboutArtistPanel.creditsSection,
/// MusicPages.swift) and the standalone track Credits panel below, which upstream draws with the
/// exact same component (music-listening-details.tsx MusicCredits).
struct MusicCreditsBlock: View {
    let credits: [MusicAboutArtistCredit]
    let sources: [MusicAboutArtistLink]
    let onArtist: (MusicCard) -> Void
    let onLink: (String) -> Void
    @ObservedObject private var copy = MusicCopy.shared

    var body: some View {
        VStack(alignment: .leading, spacing: BP.px(10)) {
            HStack(spacing: BP.px(10)) {
                Text(copy("music.credits.title", "Credits")).font(BP.sans(15, .bold)).foregroundStyle(BP.ink)
                ForEach(sources, id: \.self) { source in
                    Button { onLink(source.url) } label: { Label(source.name, systemImage: "arrow.up.right") }
                        .buttonStyle(BPTileStyle(radius: BP.rSM))
                }
            }
            .focusSection()
            ForEach(credits) { credit in
                Button { onArtist(credit.artist) } label: {
                    HStack(spacing: BP.px(10)) {
                        VStack(alignment: .leading, spacing: BP.px(2)) {
                            Text(credit.name).font(BP.sans(14, .semibold)).foregroundStyle(BP.ink)
                            Text(([credit.roleLabel] + credit.attributes).joined(separator: ", ")).font(BP.sans(12, .semibold)).foregroundStyle(BP.inkSubtle)
                        }
                        Spacer()
                        Image(systemName: "arrow.up.right").font(.system(size: BP.px(12)))
                    }
                    .padding(.horizontal, BP.px(14)).padding(.vertical, BP.px(10))
                    .background(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).fill(BP.glass))
                }
                .buttonStyle(BPTileStyle(radius: BP.rSM))
            }
        }
        .focusSection()
    }
}

/// components/music/music-listening-details.tsx MusicTrackCredits: a track's own recording
/// credits, independent of Now Playing's About-the-artist bio (no resolveArtist fallback).
/// Reachable from any track's hold-Select menu ("Credits", MusicTrackMenuItems).
struct MusicTrackCreditsView: View {
    let track: MusicTrack
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var copy = MusicCopy.shared
    @State private var result: MusicTrackCreditsResult?
    @State private var loaded = false
    @State private var page: MusicPageTarget?
    @State private var webLink: MusicWebLink?

    var body: some View {
        ZStack {
            BP.void_.opacity(0.92).ignoresSafeArea()
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: BP.px(16)) {
                    Text(copy("music.credits.title", "Credits")).font(BP.sans(24, .bold)).foregroundStyle(BP.ink)
                    Text([track.title, track.artist].filter { !$0.isEmpty }.joined(separator: " · ")).font(BP.sans(15)).foregroundStyle(BP.inkMuted).lineLimit(1)
                    if let result, !result.credits.isEmpty {
                        MusicCreditsBlock(credits: result.credits, sources: result.creditSources, onArtist: { page = MusicPageTarget(card: $0) }, onLink: { webLink = MusicWebLink(url: $0) })
                    } else if loaded {
                        BPNote(text: copy("music.row.emptyRow", "Nothing here yet."))
                    } else {
                        ProgressView()
                    }
                    Button("Close") { dismiss() }.buttonStyle(BPActionStyle())
                }
                .padding(BP.px(32))
            }
            .frame(width: BP.px(820))
            .frame(maxHeight: BP.px(900))
            .background(RoundedRectangle(cornerRadius: BP.rLG, style: .continuous).fill(BP.panel))
        }
        .onExitCommand { dismiss() }
        .task {
            result = try? await HarborEngine.shared.call("music.trackCredits", [track])
            loaded = true
        }
        .fullScreenCover(item: $page) { MusicPageView(target: $0) }
        .fullScreenCover(item: $webLink) { MusicWebLinkView(link: $0) }
    }
}

// MARK: - Harbor's own playlists (library.rs, music-library.tsx "Playlists" view)

/// The Music room's Library: Harbor's own playlists (create / open / rename / delete), the way
/// music-library.tsx's "Playlists" view does over library.rs, with tracks kept in engine storage
/// instead of the Rust SQLite database (as liked tracks and recents already are, engine/music.ts).
/// Not ported: M3U import/export (no user-visible file system on tvOS, docs/music-spec.md).
struct MusicLibraryView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var copy = MusicCopy.shared
    @State private var playlists: [MusicPlaylist] = []
    @State private var loading = true
    @State private var error: String?
    @State private var creating = false
    @State private var name = ""
    @State private var busy = false
    @State private var opened: MusicPlaylist?
    @FocusState private var createFocused: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            BP.canvas.ignoresSafeArea()
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: BP.px(22)) {
                    header
                    if creating { createForm }
                    if let error { BPNote(text: error, tone: BP.danger) }
                    if loading {
                        ProgressView().padding(.horizontal, BP.gutter)
                    } else if playlists.isEmpty {
                        BPNote(text: copy("music.playlist.first", "Your first playlist starts with a name.")).padding(.horizontal, BP.gutter)
                    } else {
                        grid
                    }
                    Color.clear.frame(height: BP.px(40))
                }
                .padding(.top, BP.px(60))
            }
        }
        .onExitCommand { dismiss() }
        .task { await load() }
        .fullScreenCover(item: $opened, onDismiss: { Task { await load() } }) { MusicPlaylistDetailView(playlist: $0) }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: BP.px(14)) {
            VStack(alignment: .leading, spacing: BP.px(4)) {
                Text(copy("music.playlists", "Playlists")).font(BP.display(30)).foregroundStyle(BP.ink)
                Text(copy("music.row.newPlaylistHint", "Name and create playlists in your library")).font(BP.sans(14)).foregroundStyle(BP.inkMuted)
            }
            Spacer()
            Button { creating.toggle(); if creating { createFocused = true } } label: { Label(copy("music.row.newPlaylist", "New playlist"), systemImage: "plus") }
                .buttonStyle(BPActionStyle(primary: true))
        }
        .padding(.horizontal, BP.gutter)
        .focusSection()
    }

    private var createForm: some View {
        HStack(alignment: .bottom, spacing: BP.px(12)) {
            BPField(label: copy("music.playlist.nameLabel", "New playlist name"), placeholder: copy("music.playlist.namePlaceholder", "Name a new playlist"), text: $name, phone: true, focus: $createFocused)
            Button { Task { await create() } } label: { Label(copy("music.playlist.create", "Create playlist"), systemImage: "plus") }
                .buttonStyle(BPActionStyle(busy: busy))
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || busy)
        }
        .padding(.horizontal, BP.gutter)
        .focusSection()
    }

    private var grid: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: BP.px(20)), count: 4)
        return LazyVGrid(columns: columns, spacing: BP.px(24)) {
            ForEach(playlists) { playlist in
                Button { opened = playlist } label: {
                    VStack(alignment: .leading, spacing: BP.px(8)) {
                        MusicPlaylistCoverView(tracks: playlist.tracks)
                            .aspectRatio(1, contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: BP.rMD, style: .continuous))
                        Text(playlist.name).font(BP.sans(15, .semibold)).foregroundStyle(BP.ink).lineLimit(1)
                        Text(copy("music.trackCount", "{count} tracks").replacingOccurrences(of: "{count}", with: "\(playlist.tracks.count)")).font(BP.sans(12.5)).foregroundStyle(BP.inkSubtle)
                    }
                }
                .buttonStyle(BPTileStyle(radius: BP.rMD))
            }
        }
        .padding(.horizontal, BP.gutter)
        .focusSection()
    }

    private func load() async {
        loading = true
        error = nil
        do {
            playlists = try await HarborEngine.shared.call("music.playlists")
        } catch EngineError.js(let message) {
            error = MusicPlayer.cleanJSError(message)
        } catch {
            self.error = copy("music.error.load", "Music could not load.")
        }
        loading = false
    }

    private func create() async {
        let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty, !busy else { return }
        busy = true
        error = nil
        do {
            let created: MusicPlaylist = try await HarborEngine.shared.call("music.createPlaylist", [wanted])
            playlists.insert(created, at: 0)
            name = ""
            creating = false
        } catch EngineError.js(let message) {
            error = MusicPlayer.cleanJSError(message)
        } catch {
            self.error = copy("music.error.load", "Music could not load.")
        }
        busy = false
    }
}

/// music-playlist-cover.tsx: up to four of the playlist's own track covers in a mosaic, or the
/// note glyph when it has none.
struct MusicPlaylistCoverView: View {
    let tracks: [MusicTrack]
    private var artworks: [String] { Array(tracks.compactMap { $0.artwork }.filter { !$0.isEmpty }.prefix(4)) }
    var body: some View {
        ZStack {
            BP.panel2
            if artworks.count > 1 {
                let columns = Array(repeating: GridItem(.flexible(), spacing: 1), count: 2)
                LazyVGrid(columns: columns, spacing: 1) {
                    ForEach(artworks.indices, id: \.self) { i in RemoteImage(url: artworks[i]).aspectRatio(1, contentMode: .fill).clipped() }
                }
            } else if let art = artworks.first {
                RemoteImage(url: art).aspectRatio(1, contentMode: .fill).clipped()
            } else {
                Image(systemName: "music.note.list").font(.system(size: BP.px(30))).foregroundStyle(BP.inkSubtle)
            }
        }
    }
}

/// A playlist opened from MusicLibraryView: its header (art, Play / Shuffle, rename / delete),
/// its tracks (hold Select for the usual track actions plus Move up / down / Remove), and a way
/// to add from the liked and recent lists (music-library.tsx's "Ready to add to {name}").
struct MusicPlaylistDetailView: View {
    @State var playlist: MusicPlaylist
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var player = MusicPlayer.shared
    @ObservedObject private var copy = MusicCopy.shared
    @State private var renaming = false
    @State private var name = ""
    @State private var busy = false
    @State private var error: String?
    @State private var confirmDelete = false
    @State private var addingOpen = false
    /// music.library: the liked and recent tracks the picker below adds from. MusicPlayer only
    /// keeps their ids (likedIds), so this view reads the full lists itself.
    @State private var library: MusicLibraryState?

    var body: some View {
        ZStack(alignment: .topLeading) {
            BP.canvas.ignoresSafeArea()
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: BP.px(24)) {
                    header
                    if let error { BPNote(text: error, tone: BP.danger).padding(.horizontal, BP.gutter) }
                    if playlist.tracks.isEmpty {
                        BPNote(text: copy("music.library.playlistEmpty", "Add a saved or recent track from the lists below.")).padding(.horizontal, BP.gutter)
                    } else {
                        LazyVStack(alignment: .leading, spacing: BP.px(6)) {
                            ForEach(Array(playlist.tracks.enumerated()), id: \.offset) { i, track in
                                Button { player.play(track, queue: playlist.tracks) } label: { MusicTrackLine(track: track, number: i + 1) }
                                    .buttonStyle(BPTileStyle(radius: BP.rSM))
                                    .contextMenu { MusicPlaylistTrackMenu(track: track, index: i, count: playlist.tracks.count, playlist: playlist, onChanged: { playlist = $0 }) }
                            }
                        }
                        .padding(.horizontal, BP.gutter)
                        .focusSection()
                    }
                    Color.clear.frame(height: BP.px(40))
                }
                .padding(.top, BP.px(60))
            }
        }
        .onExitCommand { dismiss() }
        .task { library = try? await HarborEngine.shared.call("music.library") }
        .alert(copy("music.playlist.delete", "Delete playlist"), isPresented: $confirmDelete) {
            Button(copy("music.playlist.delete", "Delete playlist"), role: .destructive) { Task { await delete() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(copy("music.playlist.deleteConfirm", "Delete this playlist? The songs stay in your library."))
        }
        .fullScreenCover(isPresented: $addingOpen) { addPicker }
        // (review) Its own host: the environment closures otherwise reach MusicView's, which cannot
        // present a second cover while this screen is up (see MusicNowPlayingView).
        .musicTrackActionsHost()
    }

    private var header: some View {
        HStack(alignment: .bottom, spacing: BP.px(24)) {
            MusicPlaylistCoverView(tracks: playlist.tracks)
                .frame(width: BP.px(180), height: BP.px(180))
                .clipShape(RoundedRectangle(cornerRadius: BP.rMD, style: .continuous))
                .shadow(color: .black.opacity(0.5), radius: 30, y: 16)
            VStack(alignment: .leading, spacing: BP.px(10)) {
                if renaming {
                    HStack(spacing: BP.px(10)) {
                        BPField(label: copy("music.playlist.nameLabel", "New playlist name"), placeholder: copy("music.playlist.namePlaceholder", "Name a new playlist"), text: $name, phone: true)
                        Button("Save") { Task { await rename() } }.buttonStyle(BPActionStyle(busy: busy)).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Button("Cancel") { renaming = false }.buttonStyle(BPActionStyle())
                    }
                } else {
                    Text(playlist.name).font(BP.display(32)).foregroundStyle(BP.ink).lineLimit(2)
                }
                Text(copy("music.trackCount", "{count} tracks").replacingOccurrences(of: "{count}", with: "\(playlist.tracks.count)")).font(BP.sans(14)).foregroundStyle(BP.inkMuted)
                if !playlist.tracks.isEmpty {
                    HStack(spacing: BP.px(12)) {
                        MusicCollectionPlayButton(tracks: playlist.tracks)
                        if playlist.tracks.count > 1 { MusicCollectionShuffleButton() }
                    }
                }
                if !renaming {
                    HStack(spacing: BP.px(14)) {
                        Button(copy("music.playlist.rename", "Rename")) { name = playlist.name; renaming = true }.buttonStyle(BPTileStyle(radius: BP.rSM))
                        Button(copy("music.playlist.delete", "Delete playlist")) { confirmDelete = true }.buttonStyle(BPTileStyle(radius: BP.rSM))
                        Button(copy("music.playlist.add", "Add to selected playlist")) { addingOpen = true }.buttonStyle(BPTileStyle(radius: BP.rSM))
                    }
                }
            }
        }
        .padding(.horizontal, BP.gutter)
        .focusSection()
    }

    /// music-library.tsx's expandable "Ready to add to {name}": the liked and recent lists, each
    /// track a one-tap add (already-added ones show as done, matching upstream's alreadyAdded).
    @ViewBuilder private var addPicker: some View {
        ZStack {
            BP.void_.opacity(0.92).ignoresSafeArea()
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: BP.px(16)) {
                    Text(copy("music.library.readyForPlaylist", "Ready to add to {name}").replacingOccurrences(of: "{name}", with: playlist.name)).font(BP.sans(20, .bold)).foregroundStyle(BP.ink)
                    if let liked = library?.liked, !liked.isEmpty { addSection(copy("music.library.savedTracks", "Saved tracks"), liked) }
                    if let recent = library?.recents, !recent.isEmpty { addSection(copy("music.library.recent", "Recently played"), recent) }
                    if library?.liked.isEmpty != false, library?.recents.isEmpty != false { BPNote(text: copy("music.library.saveEmpty", "Save a track and it will appear here.")) }
                    Button("Close") { addingOpen = false }.buttonStyle(BPActionStyle())
                }
                .padding(BP.px(32))
            }
            .frame(width: BP.px(820))
            .frame(maxHeight: BP.px(900))
            .background(RoundedRectangle(cornerRadius: BP.rLG, style: .continuous).fill(BP.panel))
        }
        .onExitCommand { addingOpen = false }
    }

    private func addSection(_ title: String, _ tracks: [MusicTrack]) -> some View {
        let already = Set(playlist.tracks.map(\.id))
        return VStack(alignment: .leading, spacing: BP.px(8)) {
            Text(title).font(BP.sans(14, .bold)).foregroundStyle(BP.ink)
            ForEach(tracks) { track in
                let added = already.contains(track.id)
                Button { Task { await add(track) } } label: {
                    HStack(spacing: BP.px(10)) {
                        VStack(alignment: .leading, spacing: BP.px(2)) {
                            Text(track.title).font(BP.sans(14, .semibold)).foregroundStyle(BP.ink).lineLimit(1)
                            Text(track.artist).font(BP.sans(12)).foregroundStyle(BP.inkSubtle).lineLimit(1)
                        }
                        Spacer()
                        Image(systemName: added ? "checkmark" : "plus").font(.system(size: BP.px(14)))
                    }
                    .padding(.horizontal, BP.px(14)).padding(.vertical, BP.px(8))
                    .background(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).fill(BP.glass))
                    .opacity(added ? 0.5 : 1)
                }
                .buttonStyle(BPTileStyle(radius: BP.rSM))
                .disabled(added || busy)
                .accessibilityLabel(Text(added ? copy("music.playlist.alreadyAdded", "Already in playlist") : copy("music.playlist.add", "Add to selected playlist")))
            }
        }
        .focusSection()
    }

    private func add(_ track: MusicTrack) async {
        guard !busy else { return }
        busy = true
        do {
            playlist = try await HarborEngine.shared.call("music.addToPlaylist", [playlist.id, track])
        } catch EngineError.js(let message) {
            error = MusicPlayer.cleanJSError(message)
        } catch {
            self.error = copy("music.error.load", "Music could not load.")
        }
        busy = false
    }

    private func rename() async {
        let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty, !busy else { return }
        busy = true
        error = nil
        do {
            playlist = try await HarborEngine.shared.call("music.renamePlaylist", [playlist.id, wanted])
            renaming = false
        } catch EngineError.js(let message) {
            error = MusicPlayer.cleanJSError(message)
        } catch {
            self.error = copy("music.error.load", "Music could not load.")
        }
        busy = false
    }

    private func delete() async {
        guard !busy else { return }
        busy = true
        error = nil
        do {
            let _: AnyJSON? = try await HarborEngine.shared.call("music.deletePlaylist", [playlist.id])
            dismiss()
            return
        } catch EngineError.js(let message) {
            error = MusicPlayer.cleanJSError(message)
        } catch {
            self.error = copy("music.error.load", "Music could not load.")
        }
        busy = false
    }
}

/// A playlist track's hold-Select menu: the usual track actions (MusicTrackMenuItems) plus
/// Move up / down (library.rs reorder_playlist) and Remove from playlist.
struct MusicPlaylistTrackMenu: View {
    let track: MusicTrack
    let index: Int
    let count: Int
    let playlist: MusicPlaylist
    let onChanged: (MusicPlaylist) -> Void
    @ObservedObject private var copy = MusicCopy.shared
    @State private var busy = false

    var body: some View {
        MusicTrackMenuItems(track: track)
        Button {
            Task { await reorder(to: index - 1) }
        } label: { Label(copy("music.playlist.moveUp", "Move {title} up").replacingOccurrences(of: "{title}", with: track.title), systemImage: "chevron.up") }
        .disabled(index == 0 || busy)
        Button {
            Task { await reorder(to: index + 1) }
        } label: { Label(copy("music.playlist.moveDown", "Move {title} down").replacingOccurrences(of: "{title}", with: track.title), systemImage: "chevron.down") }
        .disabled(index == count - 1 || busy)
        Button(role: .destructive) {
            Task { await remove() }
        } label: { Label(copy("music.playlist.remove", "Remove from playlist"), systemImage: "minus.circle") }
    }

    private func reorder(to newIndex: Int) async {
        guard !busy else { return }
        busy = true
        if let updated: MusicPlaylist = try? await HarborEngine.shared.call("music.reorderPlaylist", [playlist.id, track.id, newIndex]) { onChanged(updated) }
        busy = false
    }

    private func remove() async {
        guard !busy else { return }
        busy = true
        if let updated: MusicPlaylist = try? await HarborEngine.shared.call("music.removeFromPlaylist", [playlist.id, track.id]) { onChanged(updated) }
        busy = false
    }
}

// MARK: - "Add to playlist" (music-playlist-picker.tsx)

/// Any track's own "Add to playlist" (music-track-row.tsx onAddToPlaylist → music-playlist-picker.tsx):
/// a Harbor playlist (create one on the spot) or, when Spotify is connected, its own destination
/// (MusicSpotifyDestinationContent, MusicSpotifyLibrary.swift) — upstream's single modal with a
/// destination toggle.
struct MusicPlaylistPickerView: View {
    let track: MusicTrack
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var copy = MusicCopy.shared
    @ObservedObject private var spotify = SpotifyPlayback.shared
    @State private var destination: Destination = .harbor
    @State private var playlists: [MusicPlaylist] = []
    @State private var loading = true
    @State private var busy = false
    @State private var error: String?
    @State private var saved: String?
    @State private var name = ""

    enum Destination { case harbor, spotify }

    var body: some View {
        ZStack {
            BP.void_.opacity(0.92).ignoresSafeArea()
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: BP.px(14)) {
                    Text(copy("music.playlist.add", "Add to selected playlist")).font(BP.sans(24, .bold)).foregroundStyle(BP.ink)
                    Text([track.title, track.artist].filter { !$0.isEmpty }.joined(separator: " · ")).font(BP.sans(15)).foregroundStyle(BP.inkMuted).lineLimit(1)
                    if spotify.connected {
                        HStack(spacing: BP.px(10)) {
                            destinationButton(.harbor, label: copy("music.spotifyLibrary.harbor", "Harbor playlists"))
                            destinationButton(.spotify, label: copy("music.spotifyLibrary.playlists", "Spotify playlists"))
                        }
                        .focusSection()
                        .accessibilityLabel(Text(copy("music.spotifyLibrary.destination", "Playlist destination")))
                    }
                    if destination == .spotify {
                        MusicSpotifyDestinationContent(track: track, onDone: { dismiss() })
                    } else {
                        harborContent
                    }
                    Button("Cancel") { dismiss() }.buttonStyle(BPActionStyle())
                }
                .padding(BP.px(32))
            }
            .frame(width: BP.px(820))
            .frame(maxHeight: BP.px(900))
            .background(RoundedRectangle(cornerRadius: BP.rLG, style: .continuous).fill(BP.panel))
        }
        .onExitCommand { dismiss() }
        .task { await load() }
    }

    private func destinationButton(_ value: Destination, label: String) -> some View {
        Button { destination = value } label: { Text(label) }
            .buttonStyle(BPTileStyle(radius: BP.rSM))
            .opacity(destination == value ? 1 : 0.55)
    }

    @ViewBuilder private var harborContent: some View {
        if let error { BPNote(text: error, tone: BP.danger) }
        if loading {
            ProgressView()
        } else {
            VStack(alignment: .leading, spacing: BP.px(6)) {
                ForEach(playlists) { playlist in
                    Button { Task { await save(playlist) } } label: {
                        HStack(spacing: BP.px(12)) {
                            Text(playlist.name).font(BP.sans(16, .semibold)).lineLimit(1)
                            Spacer()
                            if saved == playlist.id { Image(systemName: "checkmark").font(.system(size: BP.px(16), weight: .bold)) }
                        }
                        .foregroundStyle(BP.ink)
                        .padding(.horizontal, BP.px(14))
                        .frame(height: BP.px(50))
                        .background(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).fill(BP.glass))
                    }
                    .buttonStyle(BPTileStyle(radius: BP.rSM))
                    .disabled(busy)
                }
            }
            .focusSection()
            if playlists.isEmpty { BPNote(text: copy("music.playlist.none", "No playlists yet.")) }
        }
        HStack(alignment: .bottom, spacing: BP.px(12)) {
            BPField(label: copy("music.playlist.nameLabel", "New playlist name"), placeholder: copy("music.playlist.namePlaceholder", "Name a new playlist"), text: $name, phone: true)
            Button { Task { await createAndSave() } } label: { Label(copy("music.playlist.create", "Create playlist"), systemImage: "plus") }
                .buttonStyle(BPActionStyle(busy: busy))
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || busy)
        }
        .padding(.top, BP.px(8))
        .focusSection()
    }

    private func load() async {
        loading = true
        do {
            playlists = try await HarborEngine.shared.call("music.playlists")
        } catch {
            self.error = copy("music.error.load", "Music could not load.")
        }
        loading = false
    }

    private func save(_ playlist: MusicPlaylist) async {
        guard !busy, saved == nil else { return }
        busy = true
        error = nil
        do {
            let _: MusicPlaylist = try await HarborEngine.shared.call("music.addToPlaylist", [playlist.id, track])
            saved = playlist.id
            busy = false
            try? await Task.sleep(for: .milliseconds(500))
            dismiss()
            return
        } catch EngineError.js(let message) {
            error = MusicPlayer.cleanJSError(message)
        } catch {
            self.error = copy("music.error.load", "Music could not load.")
        }
        busy = false
    }

    private func createAndSave() async {
        let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty, !busy else { return }
        busy = true
        error = nil
        do {
            let created: MusicPlaylist = try await HarborEngine.shared.call("music.createPlaylist", [wanted])
            let _: MusicPlaylist = try await HarborEngine.shared.call("music.addToPlaylist", [created.id, track])
            name = ""
            saved = created.id
            playlists.insert(created, at: 0)
            busy = false
            try? await Task.sleep(for: .milliseconds(500))
            dismiss()
            return
        } catch EngineError.js(let message) {
            error = MusicPlayer.cleanJSError(message)
        } catch {
            self.error = copy("music.error.load", "Music could not load.")
        }
        busy = false
    }
}

// MARK: - track action hooks (Add to playlist, Credits) shared by every track menu

private struct MusicAddToPlaylistKey: EnvironmentKey {
    static let defaultValue: ((MusicTrack) -> Void)? = nil
}
private struct MusicShowTrackCreditsKey: EnvironmentKey {
    static let defaultValue: ((MusicTrack) -> Void)? = nil
}

extension EnvironmentValues {
    /// The track menu's "Add to playlist": set by the screen that hosts MusicPlaylistPickerView.
    var musicAddToPlaylist: ((MusicTrack) -> Void)? {
        get { self[MusicAddToPlaylistKey.self] }
        set { self[MusicAddToPlaylistKey.self] = newValue }
    }
    /// The track menu's "Credits": set by the screen that hosts MusicTrackCreditsView.
    var musicShowTrackCredits: ((MusicTrack) -> Void)? {
        get { self[MusicShowTrackCreditsKey.self] }
        set { self[MusicShowTrackCreditsKey.self] = newValue }
    }
}

/// Presents MusicPlaylistPickerView / MusicTrackCreditsView for a track picked from any track
/// menu on this screen (replaces the Spotify-only destination host now that Harbor has its own
/// playlists: every track offers "Add to playlist", not only ones already on Spotify).
struct MusicTrackActionsHost: ViewModifier {
    @State private var addTarget: MusicTrack?
    @State private var creditsTarget: MusicTrack?
    func body(content: Content) -> some View {
        content
            .environment(\.musicAddToPlaylist, { track in addTarget = track })
            .environment(\.musicShowTrackCredits, { track in creditsTarget = track })
            .fullScreenCover(item: $addTarget) { track in MusicPlaylistPickerView(track: track) }
            .fullScreenCover(item: $creditsTarget) { track in MusicTrackCreditsView(track: track) }
    }
}

extension View {
    func musicTrackActionsHost() -> some View { modifier(MusicTrackActionsHost()) }
}
