import SwiftUI

// MARK: - Spotify library page

/// components/music/music-spotify-library.tsx (the "Spotify" view of music-library.tsx) over
/// library.rs through `music.spotifyLibraryPage`: the listener's Spotify playlists or Liked songs,
/// 50 a page with Load more, a readable playlist (owned or collaborative) opened in place, a new
/// private playlist, and upstream's permission / reconnect notices. Upstream's "Import to Harbor"
/// is not offered: the TV has no Harbor playlists yet. "Open on Spotify" shows the link as a QR
/// code for the phone (the TV has no browser).
struct MusicSpotifyLibraryView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var player = MusicPlayer.shared
    @ObservedObject private var copy = MusicCopy.shared
    @ObservedObject private var spotify = SpotifyPlayback.shared
    @State private var kind = "playlists"
    @State private var selected: MusicSpotifyLibraryPlaylist?
    /// music-spotify-library.tsx `pages`: one cache per view ("playlists", "liked", a playlist id).
    @State private var pages: [String: MusicSpotifyLibraryPage] = [:]
    @State private var loading = false
    /// A spotifyLibraryErrorKey key (the engine throws the key).
    @State private var failure: String?
    @State private var notice: String?
    @State private var working = false
    @State private var name = ""
    @State private var generation = 0
    @State private var account: String?
    @State private var setupOpen = false
    @State private var webLink: MusicSpotifyWebLink?
    /// (open-items sweep 3) Where the ring goes when Now Playing's "Stop and close player" took the
    /// dock from under it: "back" (inside a playlist), the view chip in use, or "connect".
    @FocusState private var dockRing: String?

    private var cacheKey: String { selected?.id ?? kind }
    private var page: MusicSpotifyLibraryPage? { pages[cacheKey] }
    private var showsTracks: Bool { selected != nil || kind == "liked" }
    private var itemCount: Int { showsTracks ? (page?.tracks.count ?? 0) : (page?.playlists.count ?? 0) }
    private var needsPermission: Bool {
        failure == "music.spotifyLibrary.permission" || failure == "music.spotifyLibrary.reconnectNeeded" || (failure == nil && page != nil && page?.canCreate == false)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            BP.canvas.ignoresSafeArea()
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: BP.px(20)) {
                    header
                    if !spotify.connected {
                        Button(MusicSpotifyCopy.text("music.spotifyLibrary.connect")) { setupOpen = true }
                            .buttonStyle(BPActionStyle(primary: true))
                            .focused($dockRing, equals: "connect")
                    } else {
                        library
                    }
                    Color.clear.frame(height: BP.px(80))
                }
                .padding(.horizontal, BP.gutter)
                .padding(.top, BP.px(60))
            }
        }
        // (open-items sweep 3) Stop and close player took the dock from under the ring (MusicDockHost
        // ringTo, as the room's other layers): Back inside a playlist, else the view chip in use.
        .musicDock(ringTo: { dockRing = selected != nil ? "back" : (spotify.connected ? kind : "connect") })
        // music-spotify-library.tsx back(): inside a playlist, Back returns to the list first.
        .onExitCommand { if selected != nil { selected = nil } else { dismiss() } }
        .onPlayPauseCommand { player.remoteToggle() }
        .task(id: cacheKey) { await show() }
        .task {
            let status: SpotifyPlayback.Status? = try? await HarborEngine.shared.call("music.spotifyStatus")
            account = status?.username
        }
        // harbor:spotify-library-changed, or a new sign-in: the cached pages are dropped.
        .onChange(of: spotify.libraryVersion) { _, _ in reset() }
        .onChange(of: spotify.connected) { _, _ in reset() }
        // A re-sign-in for permission keeps `connected` true throughout, so onChange never sees it:
        // closing the setup sheet drops the cached pages and re-reads the account (review 25).
        .fullScreenCover(isPresented: $setupOpen, onDismiss: {
            reset()
            Task {
                let status: SpotifyPlayback.Status? = try? await HarborEngine.shared.call("music.spotifyStatus")
                account = status?.username
            }
        }) { MusicSpotifyView() }
        .fullScreenCover(item: $webLink) { link in MusicSpotifyWebLinkView(link: link) }
        .musicSpotifyDestinationHost()
    }

    private func text(_ key: String) -> String { MusicSpotifyCopy.text(key) }

    private var header: some View {
        HStack(alignment: .center, spacing: BP.px(16)) {
            ZStack {
                Circle().fill(BP.panel2)
                Image(systemName: selected == nil ? "music.note.list" : "music.note").font(.system(size: BP.px(22), weight: .semibold)).foregroundStyle(BP.ink).accessibilityHidden(true)
            }
            .frame(width: BP.px(56), height: BP.px(56))
            VStack(alignment: .leading, spacing: BP.px(4)) {
                Text(selected?.name ?? text("music.spotifyLibrary.title")).font(BP.display(32)).foregroundStyle(BP.ink).lineLimit(1)
                Text(subtitle).font(BP.sans(15)).foregroundStyle(BP.inkMuted).lineLimit(1)
            }
            Spacer()
            if selected != nil {
                Button { selected = nil } label: { Label(text("music.spotifyLibrary.back"), systemImage: "chevron.backward") }
                    .buttonStyle(BPActionStyle())
                    .focused($dockRing, equals: "back")
            }
            if spotify.connected {
                Button {
                    guard !loading else { return }
                    Task { await read() }
                } label: { Label(text("music.spotifyLibrary.refresh"), systemImage: "arrow.clockwise") }
                    .buttonStyle(BPActionStyle(busy: loading))
                    .disabled(working)
            }
        }
        .focusSection()
    }

    private var subtitle: String {
        if let selected { return selected.subtitle ?? "" }
        return spotify.connected ? (account ?? "") : text("music.spotifyLibrary.body")
    }

    @ViewBuilder private var library: some View {
        if selected == nil {
            HStack(spacing: BP.px(12)) {
                Button { kind = "playlists" } label: { Label(text("music.spotifyLibrary.playlists"), systemImage: "music.note.list") }
                    .buttonStyle(BPActionStyle(primary: kind == "playlists")).bpSelected(kind == "playlists")
                    .focused($dockRing, equals: "playlists")
                    .accessibilityIdentifier("music-spotify-library-playlists")
                Button { kind = "liked" } label: { Label(text("music.spotifyLibrary.liked"), systemImage: "heart") }
                    .buttonStyle(BPActionStyle(primary: kind == "liked")).bpSelected(kind == "liked")
                    .focused($dockRing, equals: "liked")
                    .accessibilityIdentifier("music-spotify-library-liked")
            }
            .focusSection()
        }
        if needsPermission {
            permissionBlock(failure == "music.spotifyLibrary.reconnectNeeded" ? "music.spotifyLibrary.reconnectNeeded" : "music.spotifyLibrary.permission")
        }
        if let failure, !needsPermission {
            VStack(alignment: .leading, spacing: BP.px(10)) {
                BPNote(text: text(failure), tone: BP.danger)
                Button("Retry") { Task { await read() } }
                    .buttonStyle(BPActionStyle())
                    .disabled(loading || working)
            }
            .focusSection()
        }
        if let notice { BPNote(text: notice) }
        if !showsTracks, page?.canCreate == true { createForm }
        if showsTracks, let tracks = page?.tracks, !tracks.isEmpty {
            // music-collection-controls.tsx: Play and Shuffle; "Open on Spotify" for a playlist.
            HStack(spacing: BP.px(12)) {
                MusicCollectionPlayButton(tracks: tracks)
                if tracks.count > 1 { MusicCollectionShuffleButton() }
                if let selected {
                    Button { webLink = MusicSpotifyWebLink(url: selected.webUrl) } label: { Label(text("music.spotifyLibrary.open"), systemImage: "arrow.up.right") }
                        .buttonStyle(BPActionStyle())
                }
            }
            .focusSection()
        }
        if showsTracks { trackList } else { playlistList }
        if loading {
            HStack(spacing: BP.px(10)) {
                ProgressView()
                BPNote(text: copy("music.loading", "Loading music"))
            }
        }
        if !loading, failure == nil, page != nil, itemCount == 0 {
            BPNote(text: text("music.spotifyLibrary.empty"))
        }
        if let page { footer(page) }
    }

    /// music-spotify-library.tsx music-spotify-permission: Reconnect for permission (a new sign-in
    /// asks Spotify for the playlist scopes again).
    private func permissionBlock(_ key: String) -> some View {
        VStack(alignment: .leading, spacing: BP.px(10)) {
            BPNote(text: text(key))
            Button(text("music.spotifyLibrary.reconnect")) { setupOpen = true }
                .buttonStyle(BPActionStyle())
                .disabled(working)
        }
        .padding(BP.px(16))
        .background(RoundedRectangle(cornerRadius: BP.rMD, style: .continuous).fill(BP.panel))
        .focusSection()
    }

    /// music-spotify-create: a private playlist (library.rs music_spotify_create_playlist).
    private var createForm: some View {
        VStack(alignment: .leading, spacing: BP.px(10)) {
            HStack(alignment: .bottom, spacing: BP.px(12)) {
                BPField(label: copy("music.playlist.nameLabel", "New playlist name"), placeholder: copy("music.playlist.namePlaceholder", "Name a new playlist"), text: $name, phone: true)
                    .frame(maxWidth: BP.px(560))
                Button { Task { await create() } } label: { Label(text("music.spotifyLibrary.create"), systemImage: "plus") }
                    .buttonStyle(BPActionStyle(busy: working))
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Text(text("music.spotifyLibrary.private")).font(BP.sans(13)).foregroundStyle(BP.inkSubtle)
        }
        .focusSection()
    }

    private var playlistList: some View {
        LazyVStack(alignment: .leading, spacing: BP.px(8)) {
            ForEach(page?.playlists ?? []) { playlist in
                Button {
                    // A playlist Spotify only lets its owner read opens on Spotify instead.
                    if playlist.canRead { selected = playlist } else { webLink = MusicSpotifyWebLink(url: playlist.webUrl) }
                } label: { MusicSpotifyPlaylistRow(playlist: playlist) }
                    .buttonStyle(BPTileStyle(radius: BP.rSM))
            }
        }
        .focusSection()
    }

    private var trackList: some View {
        let tracks = page?.tracks ?? []
        return LazyVStack(alignment: .leading, spacing: BP.px(6)) {
            ForEach(Array(tracks.enumerated()), id: \.offset) { i, track in
                Button { player.play(track, queue: tracks) } label: { MusicTrackLine(track: track, number: i + 1) }
                    .buttonStyle(BPTileStyle(radius: BP.rSM))
                    .musicTrackMenu(track)
            }
        }
        .focusSection()
    }

    /// "{count} of {total}", Load more, and the skipped-entries note.
    private func footer(_ page: MusicSpotifyLibraryPage) -> some View {
        let shown = itemCount
        var counter = "\(shown)"
        if let total = page.total {
            counter = text("music.spotifyLibrary.loaded")
                .replacingOccurrences(of: "{count}", with: "\(shown + page.skipped)")
                .replacingOccurrences(of: "{total}", with: "\(total)")
        }
        return VStack(alignment: .leading, spacing: BP.px(8)) {
            HStack(spacing: BP.px(14)) {
                Text(counter)
                    .font(BP.sans(13)).monospacedDigit().foregroundStyle(BP.inkSubtle)
                if let next = page.nextOffset {
                    Button(copy("music.library.loadMore", "Load more")) {
                        guard !loading else { return }
                        Task { await read(offset: next, append: true) }
                    }
                        .buttonStyle(BPActionStyle(busy: loading))
                        .disabled(working)
                        .accessibilityIdentifier("music-spotify-library-more")
                }
            }
            if page.skipped > 0 {
                Text(text("music.spotifyLibrary.skipped").replacingOccurrences(of: "{count}", with: "\(page.skipped)"))
                    .font(BP.sans(12.5)).foregroundStyle(BP.inkSubtle)
            }
        }
        .focusSection()
    }

    // MARK: data

    /// The effect upstream runs when the view changes: a cached page shows at once, otherwise it loads.
    private func show() async {
        generation += 1
        loading = false
        failure = nil
        notice = nil
        if spotify.connected, pages[cacheKey] == nil { await read() }
    }

    private func reset() {
        pages = [:]
        Task { await show() }
    }

    /// music-spotify-library.tsx read(offset, append)
    private func read(offset: Int = 0, append: Bool = false) async {
        generation += 1
        let run = generation
        let key = cacheKey
        let playlistId = selected?.id
        let kindArg = selected == nil ? kind : "playlist"
        loading = true
        failure = nil
        do {
            let next: MusicSpotifyLibraryPage = try await HarborEngine.shared.call("music.spotifyLibraryPage", [kindArg, offset, playlistId])
            guard run == generation else { return }
            if append, let previous = pages[key] {
                var merged = next
                merged.tracks = previous.tracks + next.tracks
                // The list can shift between pages; ForEach needs each id once.
                let seen = Set(previous.playlists.map(\.id))
                merged.playlists = previous.playlists + next.playlists.filter { !seen.contains($0.id) }
                merged.skipped = previous.skipped + next.skipped
                pages[key] = merged
            } else {
                pages[key] = next
            }
        } catch EngineError.js(let message) {
            guard run == generation else { return }
            failure = MusicPlayer.cleanJSError(message)
        } catch {
            guard run == generation else { return }
            failure = "music.spotifyLibrary.error"
        }
        loading = false
    }

    /// music-spotify-library.tsx create(): the list is read again and the new name confirmed.
    private func create() async {
        let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty, !working else { return }
        working = true
        failure = nil
        notice = nil
        do {
            let created: MusicSpotifyLibraryPlaylist = try await HarborEngine.shared.call("music.spotifyCreatePlaylist", [wanted])
            name = ""
            await read()
            notice = text("music.spotifyLibrary.created").replacingOccurrences(of: "{name}", with: created.name)
        } catch EngineError.js(let message) {
            failure = MusicPlayer.cleanJSError(message)
        } catch {
            failure = "music.spotifyLibrary.error"
        }
        working = false
    }
}

/// music-spotify-playlist: cover, name, and the owner (or "View on Spotify" when it only opens there).
struct MusicSpotifyPlaylistRow: View {
    let playlist: MusicSpotifyLibraryPlaylist
    var body: some View {
        HStack(spacing: BP.px(14)) {
            ZStack {
                if let art = playlist.artwork.first, !art.isEmpty {
                    RemoteImage(url: art)
                } else {
                    BP.panel2
                    Image(systemName: "music.note.list").font(.system(size: BP.px(20))).foregroundStyle(BP.inkSubtle).accessibilityHidden(true)
                }
            }
            .frame(width: BP.px(56), height: BP.px(56))
            .clipShape(RoundedRectangle(cornerRadius: BP.rXS, style: .continuous))
            VStack(alignment: .leading, spacing: BP.px(2)) {
                Text(playlist.name).font(BP.sans(16, .semibold)).foregroundStyle(BP.ink).lineLimit(1)
                Text(playlist.canRead ? (playlist.subtitle ?? "") : MusicSpotifyCopy.text("music.spotifyLibrary.readOnly"))
                    .font(BP.sans(13)).foregroundStyle(BP.inkSubtle).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if !playlist.canRead {
                Image(systemName: "arrow.up.right").font(.system(size: BP.px(14), weight: .semibold)).foregroundStyle(BP.inkSubtle).accessibilityHidden(true)
            }
        }
        .padding(.horizontal, BP.px(12))
        .frame(height: BP.px(72))
        .background(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).fill(BP.glass))
    }
}

/// An open.spotify.com address to open on the phone.
struct MusicSpotifyWebLink: Identifiable {
    var url: String
    var id: String { url }
}

/// openUrl on the TV: the address as a QR code for the phone, as the other sign-ins do.
struct MusicSpotifyWebLinkView: View {
    let link: MusicSpotifyWebLink
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        ZStack {
            BP.void_.opacity(0.92).ignoresSafeArea()
            VStack(alignment: .leading, spacing: BP.px(16)) {
                Text(MusicSpotifyCopy.text("music.spotifyLibrary.open")).font(BP.sans(24, .bold)).foregroundStyle(BP.ink)
                HStack(alignment: .top, spacing: BP.px(18)) {
                    if let qr = QRCode.image(link.url) {
                        Image(uiImage: qr).interpolation(.none).resizable().frame(width: BP.px(190), height: BP.px(190)).accessibilityLabel(Text(T("QR code")))
                            .padding(BP.px(8)).background(RoundedRectangle(cornerRadius: BP.rXS, style: .continuous).fill(.white))
                    }
                    VStack(alignment: .leading, spacing: BP.px(8)) {
                        Text("Scan the code to open it on your phone.").font(BP.sans(15)).foregroundStyle(BP.ink)
                        Text(link.url).font(BP.sans(13)).foregroundStyle(BP.inkSubtle).lineLimit(2)
                    }
                }
                Button("Close") { dismiss() }.buttonStyle(BPActionStyle())
            }
            .padding(BP.px(32))
            .frame(width: BP.px(760))
            .background(RoundedRectangle(cornerRadius: BP.rLG, style: .continuous).fill(BP.panel))
        }
        .onExitCommand { dismiss() }
    }
}

// MARK: - Add to a Spotify playlist

/// music-spotify-destination.tsx (the Spotify side of music-playlist-picker.tsx): the listener's
/// playlists, the ones Spotify lets this account change enabled, a private one created on the spot,
/// then the track is added (library.rs music_spotify_add_to_playlist) and the sheet closes.
struct MusicSpotifyDestinationView: View {
    let track: MusicTrack
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var copy = MusicCopy.shared
    @ObservedObject private var spotify = SpotifyPlayback.shared
    @State private var page: MusicSpotifyLibraryPage?
    @State private var loading = false
    @State private var busy = false
    @State private var error: String?
    @State private var notice: String?
    @State private var saved: String?
    @State private var name = ""
    @State private var generation = 0
    @State private var setupOpen = false

    private func text(_ key: String) -> String { MusicSpotifyCopy.text(key) }

    var body: some View {
        ZStack {
            BP.void_.opacity(0.92).ignoresSafeArea()
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: BP.px(14)) {
                    Text(copy("music.card.addToPlaylist", "Add to playlist")).font(BP.sans(24, .bold)).foregroundStyle(BP.ink)
                    Text([track.title, track.artist].filter { !$0.isEmpty }.joined(separator: " · ")).font(BP.sans(15)).foregroundStyle(BP.inkMuted).lineLimit(1)
                    content
                    Button("Cancel") { dismiss() }.buttonStyle(BPActionStyle())
                }
                .padding(BP.px(32))
            }
            .frame(width: BP.px(820))
            .frame(maxHeight: BP.px(900))
            .background(RoundedRectangle(cornerRadius: BP.rLG, style: .continuous).fill(BP.panel))
        }
        .onExitCommand { dismiss() }
        .task { if spotify.connected, track.spotifyTrackUri != nil { await load() } }
        .onChange(of: spotify.connected) { _, now in if now, track.spotifyTrackUri != nil { Task { await load() } } }
        .fullScreenCover(isPresented: $setupOpen, onDismiss: {
            if spotify.connected, track.spotifyTrackUri != nil { Task { await load() } }
        }) { MusicSpotifyView() }
    }

    @ViewBuilder private var content: some View {
        if !spotify.connected {
            Button(text("music.spotifyLibrary.connect")) { setupOpen = true }.buttonStyle(BPActionStyle(primary: true))
        } else if track.spotifyTrackUri == nil {
            BPNote(text: text("music.spotifyLibrary.spotifyTrackOnly"))
        } else {
            if let error, error != "music.spotifyLibrary.permission", error != "music.spotifyLibrary.reconnectNeeded" {
                BPNote(text: text(error), tone: BP.danger)
            }
            if page?.canCreate == false || error == "music.spotifyLibrary.permission" || error == "music.spotifyLibrary.reconnectNeeded" {
                VStack(alignment: .leading, spacing: BP.px(10)) {
                    BPNote(text: text("music.spotifyLibrary.permission"))
                    Button(text("music.spotifyLibrary.reconnect")) { setupOpen = true }
                        .buttonStyle(BPActionStyle())
                        .disabled(busy)
                }
                .focusSection()
            }
            if let notice { BPNote(text: notice) }
            VStack(alignment: .leading, spacing: BP.px(6)) {
                ForEach(page?.playlists ?? []) { playlist in
                    Button { Task { await add(playlist) } } label: {
                        HStack(spacing: BP.px(12)) {
                            Text(playlist.name).font(BP.sans(16, .semibold)).lineLimit(1)
                            Spacer()
                            if saved == playlist.id { Image(systemName: "checkmark").font(.system(size: BP.px(16), weight: .bold)).accessibilityLabel(Text(verbatim: MusicCopy.shared("music.saved", "Saved"))) }
                        }
                        .foregroundStyle(BP.ink)
                        .padding(.horizontal, BP.px(14))
                        .frame(height: BP.px(50))
                        .background(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).fill(BP.glass))
                        .opacity(playlist.editable && !busy ? 1 : 0.4)
                    }
                    .buttonStyle(BPTileStyle(radius: BP.rSM))
                    .disabled(!playlist.editable)
                }
            }
            .focusSection()
            if !loading, let page, page.playlists.isEmpty {
                BPNote(text: copy("music.playlist.none", "No playlists yet."))
            }
            if loading {
                HStack(spacing: BP.px(10)) {
                    ProgressView()
                    BPNote(text: copy("music.loading", "Loading music"))
                }
            }
            if error != nil, page == nil {
                Button("Retry") { Task { await load() } }.buttonStyle(BPActionStyle()).disabled(loading)
            }
            if let next = page?.nextOffset {
                Button(copy("music.library.loadMore", "Load more")) {
                    guard !loading else { return }
                    Task { await load(offset: next) }
                }
                    .buttonStyle(BPActionStyle(busy: loading))
                    .disabled(busy)
            }
            if page?.canCreate == true {
                VStack(alignment: .leading, spacing: BP.px(10)) {
                    Text(text("music.spotifyLibrary.createThenAdd")).font(BP.sans(14)).foregroundStyle(BP.inkMuted)
                    HStack(alignment: .bottom, spacing: BP.px(12)) {
                        BPField(label: copy("music.playlist.nameLabel", "New playlist name"), placeholder: copy("music.playlist.namePlaceholder", "Name a new playlist"), text: $name, phone: true)
                        Button { Task { await create() } } label: { Label(text("music.spotifyLibrary.create"), systemImage: "plus") }
                            .buttonStyle(BPActionStyle(busy: busy))
                            .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .padding(.top, BP.px(8))
                .focusSection()
            }
        }
    }

    /// music-spotify-destination.tsx load(offset): later pages are appended.
    private func load(offset: Int = 0) async {
        generation += 1
        let run = generation
        loading = true
        error = nil
        do {
            let next: MusicSpotifyLibraryPage = try await HarborEngine.shared.call("music.spotifyLibraryPage", ["playlists", offset, String?.none])
            guard run == generation else { return }
            if offset > 0, var merged = page {
                let seen = Set(merged.playlists.map(\.id))
                merged.playlists += next.playlists.filter { !seen.contains($0.id) }
                merged.nextOffset = next.nextOffset
                merged.total = next.total
                merged.canCreate = next.canCreate
                merged.writePermission = next.writePermission
                page = merged
            } else {
                page = next
            }
        } catch EngineError.js(let message) {
            guard run == generation else { return }
            error = MusicPlayer.cleanJSError(message)
        } catch {
            guard run == generation else { return }
            self.error = "music.spotifyLibrary.error"
        }
        loading = false
    }

    /// addTrackToSpotifyPlaylist, then a check mark and the sheet closes half a second later.
    private func add(_ playlist: MusicSpotifyLibraryPlaylist) async {
        guard !busy, saved == nil else { return }
        busy = true
        error = nil
        do {
            let _: Bool = try await HarborEngine.shared.call("music.spotifyAddToPlaylist", [playlist.id, track])
            saved = playlist.id
            spotify.libraryChanged()
            busy = false
            try? await Task.sleep(for: .milliseconds(500))
            dismiss()
            return
        } catch EngineError.js(let message) {
            error = MusicPlayer.cleanJSError(message)
        } catch {
            self.error = "music.spotifyLibrary.error"
        }
        busy = false
    }

    /// createSpotifyPlaylist: the new playlist goes to the top of the list, ready to be picked.
    private func create() async {
        let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty, !busy else { return }
        busy = true
        error = nil
        do {
            let created: MusicSpotifyLibraryPlaylist = try await HarborEngine.shared.call("music.spotifyCreatePlaylist", [wanted])
            name = ""
            notice = text("music.spotifyLibrary.created").replacingOccurrences(of: "{name}", with: created.name)
            if var current = page {
                current.playlists.insert(created, at: 0)
                current.total = current.total.map { $0 + 1 }
                // Spotify's list moved down by one: the next page starts one later.
                current.nextOffset = current.nextOffset.map { $0 + 1 }
                page = current
            }
            spotify.libraryChanged()
        } catch EngineError.js(let message) {
            error = MusicPlayer.cleanJSError(message)
        } catch {
            self.error = "music.spotifyLibrary.error"
        }
        busy = false
    }
}

// MARK: - copy and the menu hook

/// The Spotify library strings: the engine's (upstream's catalog through lib/i18n), else
/// upstream's English (locales/en/music-spotify-library.ts).
@MainActor
enum MusicSpotifyCopy {
    static func text(_ key: String) -> String { MusicCopy.shared(key, english[key] ?? key) }

    static let english: [String: String] = [
        "music.spotifyLibrary.title": "Spotify library",
        "music.spotifyLibrary.body": "Your liked songs and playlists from your connected account.",
        "music.spotifyLibrary.connect": "Connect Spotify",
        "music.spotifyLibrary.liked": "Liked songs",
        "music.spotifyLibrary.playlists": "Spotify playlists",
        "music.spotifyLibrary.back": "Back to Spotify library",
        "music.spotifyLibrary.loaded": "{count} of {total}",
        "music.spotifyLibrary.empty": "Nothing in this Spotify collection yet.",
        "music.spotifyLibrary.noImportable": "This collection has no tracks Harbor can import.",
        "music.spotifyLibrary.error": "Spotify could not complete the request. Check your connection and try again.",
        "music.spotifyLibrary.permission": "Reconnect Spotify to allow playlist changes.",
        "music.spotifyLibrary.reconnect": "Reconnect for permission",
        "music.spotifyLibrary.reconnectNeeded": "Sign in to Spotify again to read this library.",
        "music.spotifyLibrary.restricted": "Spotify allows these tracks only for playlists you own or collaborate on. You can open this playlist on Spotify.",
        "music.spotifyLibrary.rateLimit": "Spotify is limiting requests. Wait a moment, then try again.",
        "music.spotifyLibrary.unconfirmed": "Spotify did not confirm the change. Check the playlist on Spotify before trying again.",
        "music.spotifyLibrary.open": "Open on Spotify",
        "music.spotifyLibrary.create": "Create Spotify playlist",
        "music.spotifyLibrary.private": "New Spotify playlists are private.",
        "music.spotifyLibrary.created": "Created {name} on Spotify.",
        "music.spotifyLibrary.createThenAdd": "Create a private playlist, then select it to add this song.",
        "music.spotifyLibrary.spotifyTrackOnly": "Choose a Spotify version of this song to add it to a Spotify playlist.",
        "music.spotifyLibrary.readOnly": "View on Spotify",
        "music.spotifyLibrary.refresh": "Refresh Spotify library",
        "music.spotifyLibrary.skipped": "Skipped {count} entries Harbor cannot import.",
    ]
}

private struct MusicAddToSpotifyPlaylistKey: EnvironmentKey {
    static let defaultValue: ((MusicTrack) -> Void)? = nil
}

extension EnvironmentValues {
    /// The track menu's "Add to playlist": set by the screen that presents the Spotify destination.
    var musicAddToSpotifyPlaylist: ((MusicTrack) -> Void)? {
        get { self[MusicAddToSpotifyPlaylistKey.self] }
        set { self[MusicAddToSpotifyPlaylistKey.self] = newValue }
    }
}

/// Presents music-spotify-destination.tsx for a track picked from any track menu on this screen.
struct MusicSpotifyDestinationHost: ViewModifier {
    @State private var target: MusicTrack?
    func body(content: Content) -> some View {
        content
            .environment(\.musicAddToSpotifyPlaylist, { track in target = track })
            .fullScreenCover(item: $target) { track in MusicSpotifyDestinationView(track: track) }
    }
}

extension View {
    func musicSpotifyDestinationHost() -> some View { modifier(MusicSpotifyDestinationHost()) }
}
