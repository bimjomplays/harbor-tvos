import SwiftUI

/// The Music room (views/music.tsx, laid out the Big Picture way): a mast with Search and
/// Sources, then the home shelves in upstream's band order, and the player dock pinned above
/// the hint bar (components/music/music-dock.tsx). Pages, search, sources and the full Now
/// Playing screen open as layers over it.
struct MusicView: View {
    @StateObject private var model = MusicModel()
    @ObservedObject private var player = MusicPlayer.shared
    @ObservedObject private var copy = MusicCopy.shared
    @ObservedObject private var spotify = SpotifyPlayback.shared
    @State private var page: MusicPageTarget?
    @State private var searchOpen = false
    @State private var sourcesOpen = false
    @State private var nowPlayingOpen = false
    @State private var spotifyLibraryOpen = false
    /// (open-items sweep 3) The mast's Search, where the ring goes when Now Playing's "Stop and
    /// close player" took the room's own dock from under it (MusicDockHost.ringTo does this for the
    /// room's layers; the room draws its dock itself).
    @FocusState private var searchFocused: Bool

    var body: some View {
        ZStack(alignment: .bottom) {
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: BP.px(28)) {
                    mast
                    if player.radioStatus != nil { MusicRadioStatusNote().padding(.horizontal, BP.gutter) }
                    if model.failed { offline }
                    // (device-flow pass) The first load (a network round per source) showed only the mast.
                    if !model.loaded, !model.failed, model.bands.isEmpty {
                        ProgressView().padding(.horizontal, BP.gutter)
                    }
                    ForEach(model.bands) { band in
                        MusicBandView(band: band, onCard: { open($0, in: $1) })
                    }
                    if model.loaded, model.bands.isEmpty, !model.failed {
                        BPNote(text: copy("music.row.emptyRow", "Nothing here yet.")).padding(.horizontal, BP.gutter)
                    }
                    Color.clear.frame(height: BP.hintHeight + (player.current == nil ? BP.px(20) : BP.px(110)))
                }
                .padding(.top, BP.barHeight + BP.px(12))
            }
            if player.current != nil {
                MusicDockView(onExpand: { nowPlayingOpen = true })
                    .padding(.horizontal, BP.gutter)
                    .padding(.bottom, BP.hintHeight + BP.px(6))
            }
        }
        .task {
            await copy.load()
            await model.load(force: false)
        }
        // use-music-data.ts: harbor:music-library-changed reloads the shelves (liked, recents, queue).
        .onChange(of: player.libraryVersion) { _, _ in Task { await model.load(force: false) } }
        // music-personal-bands.tsx queueBand reads the live queue: Add to queue, Play next, a
        // removal or a radio top-up changes the Up next shelf too (it only followed track starts).
        .onChange(of: player.upcoming.map(\.queueKey)) { _, _ in Task { await model.load(force: false) } }
        .onPlayPauseCommand { player.remoteToggle() }
        .fullScreenCover(item: $page) { target in MusicPageView(target: target) }
        .fullScreenCover(isPresented: $searchOpen) { MusicSearchView() }
        .fullScreenCover(isPresented: $sourcesOpen, onDismiss: { Task { await model.load(force: true) } }) { MusicSourcesView() }
        .fullScreenCover(isPresented: $nowPlayingOpen, onDismiss: { dockClosed() }) { MusicNowPlayingView() }
        .fullScreenCover(isPresented: $spotifyLibraryOpen) { MusicSpotifyLibraryView() }
        .musicSpotifyDestinationHost()
    }

    /// (open-items sweep 3) Now Playing closed with no track loaded ("Stop and close player",
    /// MusicPlayer.close): the dock the ring opened it from is gone, and tvOS dropped the ring
    /// wherever it resets focus. use-bp-focus recovers into the page (bp-focus-core recoverBpFocus:
    /// the page's autofocus seed); the room's first control is the mast's Search.
    private func dockClosed() {
        guard player.current == nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { searchFocused = true }
    }

    private var mast: some View {
        HStack(alignment: .center, spacing: BP.px(14)) {
            VStack(alignment: .leading, spacing: BP.px(4)) {
                Text(copy("music.title", "Music")).font(BP.display(34)).foregroundStyle(BP.ink)
                Text(copy("music.home.title", "Your music. A world beyond it.")).font(BP.sans(15)).foregroundStyle(BP.inkMuted)
            }
            Spacer()
            Button { searchOpen = true } label: {
                Label(copy("music.searchPlaceholder", "Search songs, albums, artists"), systemImage: "magnifyingglass")
            }
            .buttonStyle(BPActionStyle(primary: true))
            .focused($searchFocused)
            .accessibilityIdentifier("music-search")
            // music-library.tsx "Spotify" view (music-spotify-library.tsx): Liked songs and playlists.
            if spotify.connected {
                Button { spotifyLibraryOpen = true } label: {
                    Label(copy("music.spotifyLibrary.title", "Spotify library"), systemImage: "music.note.list")
                }
                .buttonStyle(BPActionStyle())
                .accessibilityIdentifier("music-spotify-library")
            }
            Button { sourcesOpen = true } label: {
                Label(copy("music.connections.title", "Connections"), systemImage: "dot.radiowaves.left.and.right")
            }
            .buttonStyle(BPActionStyle())
            .accessibilityIdentifier("music-sources")
        }
        .padding(.horizontal, BP.gutter)
        .focusSection()
    }

    /// music.offline.*: nothing could load and there is no history to fall back on.
    private var offline: some View {
        VStack(alignment: .leading, spacing: BP.px(12)) {
            Text(copy("music.error.load", "Music could not load.")).font(BP.sans(19, .bold)).foregroundStyle(BP.ink)
            if let first = model.errors.first { BPNote(text: first.message) }
            Button(copy("music.offline.retry", "Try sources again")) { Task { await model.load(force: true) } }
                .buttonStyle(BPActionStyle())
        }
        .padding(BP.px(20))
        .background(RoundedRectangle(cornerRadius: BP.rMD, style: .continuous).fill(BP.panel))
        .padding(.horizontal, BP.gutter)
        .focusSection()
    }

    /// views/music.tsx openItem: a track plays with its shelf as the queue; anything else opens.
    private func open(_ card: MusicCard, in band: MusicBand) {
        if let track = card.track {
            // music-personal-bands.tsx queueBand: an Up next pick plays inside the live queue
            // (playTrack(track, player.queue)). (device-flow pass) It became a queue of the shelf
            // alone, dropping the current track and history (Previous went nowhere) and the radio.
            if band.key == "liked", band.numbered,
               let at = player.queue.indices.first(where: { $0 > player.index && player.queue[$0].queueKey == track.queueKey }) {
                player.jump(to: at)
            } else {
                player.play(track, queue: band.cards.compactMap(\.track))
            }
        } else {
            page = MusicPageTarget(card: card)
        }
    }
}

/// One shelf (components/music/music-catalog-row.tsx): header, then covers, circles or a
/// three-row track grid, scrolling sideways.
struct MusicBandView: View {
    let band: MusicBand
    let onCard: (MusicCard, MusicBand) -> Void
    /// views/music.tsx loadMoreArtistReleases: a "Load more" tile ends a shelf that has more.
    var onMore: (() -> Void)? = nil
    @FocusState private var focused: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: BP.px(10)) {
            VStack(alignment: .leading, spacing: BP.px(2)) {
                Text(band.title).font(BP.sans(19, .bold)).foregroundStyle(BP.ink.opacity(focused == nil ? 0.62 : 1)).accessibilityAddTraits(.isHeader)
                if !band.subtitle.isEmpty {
                    Text(band.subtitle).font(BP.sans(13)).foregroundStyle(BP.inkSubtle).lineLimit(1)
                }
            }
            .padding(.horizontal, BP.gutter)
            .animation(.easeOut(duration: 0.26), value: focused == nil)
            if let notice = band.notice {
                Text(notice)
                    .font(BP.sans(15)).foregroundStyle(BP.inkMuted)
                    .frame(maxWidth: BP.px(620), alignment: .leading)
                    .padding(BP.px(18))
                    .background(RoundedRectangle(cornerRadius: BP.rMD, style: .continuous).stroke(BP.edge2, style: StrokeStyle(lineWidth: 1, dash: [6, 5])))
                    .padding(.horizontal, BP.gutter)
                    .focusable()
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    content
                        .padding(.horizontal, BP.gutter)
                        .padding(.vertical, BP.px(14))
                }
                .scrollClipDisabled()
            }
        }
        .focusSection()
    }

    @ViewBuilder private var content: some View {
        if band.layout == "trackGrid" {
            LazyHGrid(rows: Array(repeating: GridItem(.fixed(BP.px(58)), spacing: BP.px(10)), count: min(3, max(1, band.cards.count))), spacing: BP.px(16)) {
                ForEach(Array(band.cards.enumerated()), id: \.offset) { i, card in
                    Button { onCard(card, band) } label: { MusicTrackCell(card: card, number: band.numbered ? i + 1 : nil) }
                        .buttonStyle(BPTileStyle(radius: BP.rSM))
                        .focused($focused, equals: i)
                        .musicTrackMenu(card.track)
                }
            }
        } else {
            LazyHStack(alignment: .top, spacing: BP.trackGap) {
                ForEach(Array(band.cards.enumerated()), id: \.offset) { i, card in
                    Button { onCard(card, band) } label: { MusicCoverCell(card: card, focused: focused == i) }
                        .buttonStyle(BPTileStyle(radius: card.circle ? BP.px(80) : BP.rSM))
                        .focused($focused, equals: i)
                        .musicTrackMenu(card.track)
                }
                if let onMore, band.more != nil {
                    Button(action: onMore) { MusicMoreTile() }
                        .buttonStyle(BPTileStyle(radius: BP.rSM))
                        .focused($focused, equals: band.cards.count)
                        .accessibilityIdentifier("music-band-more")
                }
            }
        }
    }
}

/// music.library.loadMore as a cover-sized tile at the end of a shelf.
struct MusicMoreTile: View {
    @ObservedObject private var copy = MusicCopy.shared
    var body: some View {
        VStack(alignment: .leading, spacing: BP.px(8)) {
            ZStack {
                BP.panel2
                Image(systemName: "ellipsis").font(.system(size: BP.px(30), weight: .semibold)).foregroundStyle(BP.inkMuted).accessibilityHidden(true)
            }
            .frame(width: BP.px(150), height: BP.px(150))
            .clipShape(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous))
            Text(copy("music.library.loadMore", "Load more")).font(BP.sans(14, .semibold)).foregroundStyle(BP.ink).lineLimit(1)
                .frame(width: BP.px(150), alignment: .leading)
        }
    }
}

/// music-cover-card.tsx: square art (a 2×2 mosaic for playlists that have several covers) or a
/// circle for artists, with two lines of text under it.
struct MusicCoverCell: View {
    let card: MusicCard
    var focused = false
    private var side: CGFloat { card.circle ? BP.px(128) : BP.px(150) }

    var body: some View {
        VStack(alignment: card.circle ? .center : .leading, spacing: BP.px(8)) {
            art
                .frame(width: side, height: side)
                .clipShape(RoundedRectangle(cornerRadius: card.circle ? side / 2 : BP.rSM, style: .continuous))
                .overlay(alignment: .bottomTrailing) {
                    if card.kind == "station" {
                        Image(systemName: "dot.radiowaves.left.and.right")
                            .font(.system(size: BP.px(12), weight: .bold)).foregroundStyle(BP.ink)
                            .padding(BP.px(6)).background(Circle().fill(BP.void_.opacity(0.7))).padding(BP.px(6))
                            .accessibilityLabel(Text(verbatim: MusicCopy.shared("music.row.stationBadge", "Radio")))
                    }
                }
            VStack(alignment: card.circle ? .center : .leading, spacing: BP.px(2)) {
                Text(card.title).font(BP.sans(14, .semibold)).foregroundStyle(BP.ink).lineLimit(1)
                if !card.subtitle.isEmpty {
                    Text(card.subtitle).font(BP.sans(12.5)).foregroundStyle(BP.inkSubtle).lineLimit(1)
                }
            }
            .frame(width: side, alignment: card.circle ? .center : .leading)
        }
    }

    @ViewBuilder private var art: some View {
        if card.artworks.count >= 4 {
            VStack(spacing: 0) {
                HStack(spacing: 0) { RemoteImage(url: card.artworks[0]).clipped(); RemoteImage(url: card.artworks[1]).clipped() }
                HStack(spacing: 0) { RemoteImage(url: card.artworks[2]).clipped(); RemoteImage(url: card.artworks[3]).clipped() }
            }
        } else if !card.artwork.isEmpty {
            RemoteImage(url: card.artwork)
        } else {
            ZStack {
                BP.panel2
                Image(systemName: card.circle ? "person.fill" : "music.note").font(.system(size: BP.px(30))).foregroundStyle(BP.inkSubtle).accessibilityHidden(true)
            }
        }
    }
}

/// music-track-grid.tsx / music-track-row.tsx cell: art, title, artist, duration.
struct MusicTrackCell: View {
    let card: MusicCard
    var number: Int?
    @ObservedObject private var player = MusicPlayer.shared

    private var playing: Bool { player.isCurrent(card.track) }

    var body: some View {
        HStack(spacing: BP.px(10)) {
            if let number {
                Text("\(number)").font(BP.sans(14, .bold)).foregroundStyle(BP.inkSubtle).frame(width: BP.px(22))
            }
            ZStack {
                if card.artwork.isEmpty { BP.panel2 } else { RemoteImage(url: card.artwork) }
                if playing {
                    BP.void_.opacity(0.55)
                    Image(systemName: "waveform").font(.system(size: BP.px(16), weight: .bold)).foregroundStyle(BP.ink)
                        .accessibilityLabel(Text(verbatim: MusicCopy.shared("music.nowPlaying", "Now playing")))
                }
            }
            .frame(width: BP.px(46), height: BP.px(46))
            .clipShape(RoundedRectangle(cornerRadius: BP.rXS, style: .continuous))
            VStack(alignment: .leading, spacing: BP.px(2)) {
                Text(card.title).font(BP.sans(14, .semibold)).foregroundStyle(playing ? BP.accent : BP.ink).lineLimit(1)
                Text(card.subtitle).font(BP.sans(12.5)).foregroundStyle(BP.inkSubtle).lineLimit(1)
            }
            Spacer(minLength: BP.px(6))
            if player.isLiked(card.track) {
                Image(systemName: "heart.fill").font(.system(size: BP.px(11))).foregroundStyle(BP.inkMuted)
                    .accessibilityLabel(Text(verbatim: MusicCopy.shared("music.saved", "Saved")))
            }
            if let label = card.track?.durationLabel, (card.track?.seconds ?? 0) > 0 {
                Text(label).font(BP.sans(12.5)).monospacedDigit().foregroundStyle(BP.inkSubtle)
            }
        }
        .padding(.horizontal, BP.px(8))
        .frame(width: BP.px(330), height: BP.px(58))
        .background(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).fill(BP.glass))
    }
}

extension View {
    /// music-track-menu.tsx on the TV: hold Select on a track for Play next / Add to queue / Save.
    @ViewBuilder func musicTrackMenu(_ track: MusicTrack?) -> some View {
        if let track {
            contextMenu {
                MusicTrackMenuItems(track: track)
            }
        } else {
            self
        }
    }
}

struct MusicTrackMenuItems: View {
    let track: MusicTrack
    @ObservedObject private var player = MusicPlayer.shared
    @ObservedObject private var copy = MusicCopy.shared
    @ObservedObject private var spotify = SpotifyPlayback.shared
    @Environment(\.musicAddToSpotifyPlaylist) private var addToSpotifyPlaylist
    var body: some View {
        Button { player.playNext(track) } label: { Label(copy("music.queue.playNext", "Play next"), systemImage: "text.line.first.and.arrowtriangle.forward") }
        Button { player.enqueue(track) } label: { Label(copy("music.card.addToQueue", "Add to queue"), systemImage: "text.append") }
        // music-track-row.tsx onAddToPlaylist → music-playlist-picker.tsx. The TV has no Harbor
        // playlists yet, so the picker is its Spotify destination, offered for Spotify tracks.
        if let addToSpotifyPlaylist, spotify.connected, track.spotifyTrackUri != nil {
            Button { addToSpotifyPlaylist(track) } label: { Label(copy("music.card.addToPlaylist", "Add to playlist"), systemImage: "text.badge.plus") }
        }
        // music-track-menu.tsx "Start radio" (radio.ts): a station seeded by this track.
        Button { player.startRadio(track) } label: { Label(copy("music.card.startRadio", "Start radio"), systemImage: "dot.radiowaves.left.and.right") }
        Button { player.toggleLiked(track) } label: {
            player.isLiked(track)
                ? Label(copy("music.unsaveTrack", "Remove from saved tracks"), systemImage: "heart.slash")
                : Label(copy("music.saveTrack", "Save track"), systemImage: "heart")
        }
    }
}

/// music-track-grid.tsx radio status line: "Loading" while the station is built, then the
/// radio error if it could not be (it stays until the next attempt, as upstream's does).
struct MusicRadioStatusNote: View {
    @ObservedObject private var player = MusicPlayer.shared
    @ObservedObject private var copy = MusicCopy.shared
    var body: some View {
        switch player.radioStatus {
        case .some(.loading):
            HStack(spacing: BP.px(10)) {
                ProgressView()
                BPNote(text: copy("music.loading", "Loading music"))
            }
        case .some(.failed(let message)):
            BPNote(text: message, tone: BP.danger)
        case .none:
            EmptyView()
        }
    }
}

/// components/music/music-dock.tsx: the bar that follows the music around the room.
struct MusicDockView: View {
    let onExpand: () -> Void
    @ObservedObject private var player = MusicPlayer.shared
    @ObservedObject private var copy = MusicCopy.shared

    var body: some View {
        if let t = player.current {
            HStack(spacing: BP.px(14)) {
                Button(action: onExpand) {
                    HStack(spacing: BP.px(12)) {
                        ZStack {
                            if let art = t.artwork, !art.isEmpty { RemoteImage(url: art) } else { BP.panel2 }
                        }
                        .frame(width: BP.px(52), height: BP.px(52))
                        .clipShape(RoundedRectangle(cornerRadius: BP.rXS, style: .continuous))
                        VStack(alignment: .leading, spacing: BP.px(2)) {
                            Text(t.title).font(BP.sans(15, .semibold)).foregroundStyle(BP.ink).lineLimit(1)
                            Text(statusLine(t)).font(BP.sans(12.5)).foregroundStyle(player.phase == .error ? BP.danger : BP.inkSubtle).lineLimit(1)
                        }
                        .frame(width: BP.px(300), alignment: .leading)
                    }
                    .padding(BP.px(6))
                }
                .buttonStyle(BPTileStyle(radius: BP.rSM))
                .accessibilityIdentifier("music-dock-open")
                MusicProgressBar(clock: player.clock)
                MusicTransportButtons(compact: true)
            }
            .padding(.horizontal, BP.px(14)).padding(.vertical, BP.px(10))
            .background(RoundedRectangle(cornerRadius: BP.rMD, style: .continuous).fill(BP.panel.opacity(0.96)))
            .overlay(RoundedRectangle(cornerRadius: BP.rMD, style: .continuous).stroke(BP.edge, lineWidth: 1))
            .shadow(color: .black.opacity(0.5), radius: 24, y: 12)
            .focusSection()
        }
    }

    private func statusLine(_ t: MusicTrack) -> String {
        switch player.phase {
        case .resolving: return copy("music.row.resolving", "Finding a source for this")
        case .error: return player.error ?? copy("music.error.playback", "This source couldn’t play the song. Try another source.")
        default: return t.artist
        }
    }
}

/// The dock under the Music room's own layers (an album / artist / playlist page, search, the
/// Spotify library). App.tsx mounts music-dock.tsx once over every view, so upstream's stays under
/// a detail page or the search panel. (device-flow pass) A track started there showed nothing:
/// no "Finding a source", no error when every source failed, and no way into Now Playing short of
/// backing out to the room. A bottom inset, so the page scrolls above it rather than under it.
struct MusicDockHost: ViewModifier {
    /// Extra room under the dock where the host ignores the safe area (the kids shell).
    var bottomPadding: CGFloat = 0
    /// (open-items sweep 2) Where the ring goes when the dock went from under it: Now Playing's
    /// "Stop and close player" (MusicPlayer.close, the only way the loaded track goes) closes the
    /// dock the ring opened it from, and tvOS dropped the ring wherever it resets focus. Upstream's
    /// use-bp-focus recovers into the page (bp-focus-core recoverBpFocus: the marked cell, else the
    /// page's autofocus seed); each host names its neighbour (nil: tvOS's default, as before).
    var ringTo: (() -> Void)? = nil
    @State private var nowPlayingOpen = false
    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .bottom, spacing: 0) {
                MusicDockSlot(bottomPadding: bottomPadding, onExpand: { nowPlayingOpen = true })
            }
            .fullScreenCover(isPresented: $nowPlayingOpen, onDismiss: { dockClosed() }) { MusicNowPlayingView() }
    }

    private func dockClosed() {
        guard MusicPlayer.shared.current == nil, let hand = ringTo else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { hand() }
    }
}

/// The dock while something is loaded, else nothing (the inset closes up). It sits on the bottom
/// safe area, which already keeps it off the screen edge (`bottomPadding` where it does not).
private struct MusicDockSlot: View {
    let bottomPadding: CGFloat
    let onExpand: () -> Void
    @ObservedObject private var player = MusicPlayer.shared
    var body: some View {
        if player.current != nil {
            MusicDockView(onExpand: onExpand)
                .padding(.horizontal, BP.gutter)
                .padding(.top, BP.px(8))
                .padding(.bottom, bottomPadding)
        }
    }
}

extension View {
    func musicDock(bottomPadding: CGFloat = 0, ringTo: (() -> Void)? = nil) -> some View {
        modifier(MusicDockHost(bottomPadding: bottomPadding, ringTo: ringTo))
    }
}

/// Elapsed / bar / length (music-dock.tsx time part).
struct MusicProgressBar: View {
    @ObservedObject var clock: MusicClock
    private var position: Double { clock.position }
    private var duration: Double { clock.duration }
    var body: some View {
        HStack(spacing: BP.px(10)) {
            Text(Self.stamp(position)).font(BP.sans(12.5)).monospacedDigit().foregroundStyle(BP.inkSubtle)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(BP.edge2)
                    Capsule().fill(BP.ink).frame(width: duration > 0 ? g.size.width * CGFloat(min(1, max(0, position / duration))) : 0)
                }
            }
            .frame(height: BP.px(4))
            Text(Self.stamp(duration)).font(BP.sans(12.5)).monospacedDigit().foregroundStyle(BP.inkSubtle)
        }
        .frame(maxWidth: .infinity)
        // music-dock.tsx aria-label={t("music.position")}: one element, "1:02 of 3:45".
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: MusicCopy.shared("music.position", "Track position")))
        .accessibilityValue(Text(verbatim: T("%@ of %@", Self.stamp(position), Self.stamp(duration))))
    }

    /// music.rs duration_label (m:ss), with hours for long mixes.
    static func stamp(_ seconds: Double) -> String {
        // (bug pass) Int() traps past Int.max: a server's absurd length (Subsonic/Jellyfin durations
        // are not capped) must not crash the dock. 100 000 h is far beyond any real track.
        guard seconds.isFinite, seconds > 0, seconds < 360_000_000 else { return "0:00" }
        let s = Int(seconds)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// Shuffle / previous / play-pause / next / repeat / save, shared by the dock and the Now Playing
/// screen (music-dock.tsx's transport: Shuffle and Repeat either side, lit in the accent when on,
/// Repeat drawn as Repeat1 in "one" and titled Repeat / Repeat all / Repeat one).
struct MusicTransportButtons: View {
    var compact = false
    /// The screen's focus scope, when Play/Pause should take the focus as it opens (Now Playing).
    var focusNamespace: Namespace.ID? = nil
    @ObservedObject private var player = MusicPlayer.shared
    @ObservedObject private var copy = MusicCopy.shared

    var body: some View {
        HStack(spacing: BP.px(compact ? 8 : 14)) {
            icon("shuffle", copy("music.transport.shuffle", "Shuffle"), on: player.shuffle) { player.toggleShuffle() }
                .accessibilityIdentifier("music-shuffle")
            icon("backward.fill", copy("music.previous", "Previous track")) { player.previous() }
            icon(player.phase == .playing ? "pause.fill" : (player.phase == .error ? "arrow.clockwise" : "play.fill"),
                 player.phase == .playing ? copy("music.pause", "Pause") : copy("music.play", "Play"), big: true) { player.toggle() }
                .accessibilityIdentifier("music-toggle")
                .modifier(MusicPrefersFocus(namespace: focusNamespace))
            icon("forward.fill", copy("music.next", "Next track")) { player.next() }
            icon(player.repeatMode == .one ? "repeat.1" : "repeat", repeatLabel, on: player.repeatMode != .off) { player.cycleRepeat() }
                .accessibilityIdentifier("music-repeat")
            icon(player.isLiked(player.current) ? "heart.fill" : "heart",
                 player.isLiked(player.current) ? copy("music.unsaveTrack", "Remove from saved tracks") : copy("music.saveTrack", "Save track")) { player.toggleLiked() }
        }
    }

    /// music-dock.tsx repeatLabel
    private var repeatLabel: String {
        switch player.repeatMode {
        case .one: return copy("music.transport.repeatOne", "Repeat one")
        case .all: return copy("music.transport.repeatAll", "Repeat all")
        case .off: return copy("music.transport.repeat", "Repeat")
        }
    }

    /// `on`: a mode button's aria-pressed (drawn in the accent, read as selected).
    private func icon(_ name: String, _ label: String, big: Bool = false, on: Bool? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).font(.system(size: BP.px(big ? 20 : 16), weight: .semibold))
        }
        .buttonStyle(MusicIconStyle(big: big && !compact, on: on ?? false))
        .accessibilityLabel(label)
        .bpSelected(on ?? false)
    }
}

/// music-collection-controls.tsx Play: "Collection controls retain the stored order; shuffle
/// belongs to playback." The queue is the collection as listed; with shuffle on the first track is
/// a random one and the listening order deals the rest. When this collection is already the queue
/// playing, Play is Play/Pause (upstream's sameQueue && selected), and dims while it resolves.
struct MusicCollectionPlayButton: View {
    let tracks: [MusicTrack]
    @ObservedObject private var player = MusicPlayer.shared
    @ObservedObject private var copy = MusicCopy.shared

    var body: some View {
        let selected: Bool = player.isPlayingCollection(tracks)
        let playing: Bool = selected && player.phase == .playing
        let busy: Bool = selected && player.phase == .resolving
        let title: String = playing ? copy("music.pause", "Pause") : copy("music.play", "Play")
        Button { play(selected: selected, busy: busy) } label: {
            Label(title, systemImage: playing ? "pause.fill" : "play.fill")
        }
        .buttonStyle(BPActionStyle(primary: true, busy: busy))
    }

    private func play(selected: Bool, busy: Bool) {
        guard !busy, let fallback = tracks.first else { return }
        if selected, player.phase == .playing || player.phase == .paused {
            player.toggle()
            return
        }
        let first: MusicTrack = player.shuffle ? (tracks.randomElement() ?? fallback) : fallback
        player.play(first, queue: tracks)
    }
}

/// music-collection-controls.tsx Shuffle: toggles the shuffle mode (aria-pressed, the accent when
/// on). It no longer plays a shuffled copy of the list: the mode applies to whatever plays.
struct MusicCollectionShuffleButton: View {
    @ObservedObject private var player = MusicPlayer.shared
    @ObservedObject private var copy = MusicCopy.shared

    var body: some View {
        let on: Bool = player.shuffle
        let title: String = copy("music.transport.shuffle", "Shuffle")
        Button { player.toggleShuffle() } label: {
            if on {
                Label(title, systemImage: "shuffle").foregroundStyle(BP.accent)
            } else {
                Label(title, systemImage: "shuffle")
            }
        }
        .buttonStyle(BPActionStyle())
        .bpSelected(on)
        .accessibilityIdentifier("music-page-shuffle")
    }
}

/// prefersDefaultFocus in the given scope, or nothing without one.
private struct MusicPrefersFocus: ViewModifier {
    let namespace: Namespace.ID?
    @ViewBuilder func body(content: Content) -> some View {
        if let namespace {
            content.prefersDefaultFocus(true, in: namespace)
        } else {
            content
        }
    }
}

/// music-dock.tsx volume: the mute button and the "Music volume" slider (0...1, titled
/// "Music volume · 82%"). tvOS has no slider, so − / + either side of the bar step it by 5 % (the
/// dock's wheel step), as the seek row's ten-second buttons do. This is the music's own level
/// (upstream's mpv volume / librespot soft mixer); the remote still sets the TV's volume.
struct MusicVolumeControl: View {
    @ObservedObject private var player = MusicPlayer.shared
    @ObservedObject private var copy = MusicCopy.shared

    var body: some View {
        let muted = player.volume <= 0
        let label = copy("music.volume", "Music volume")
        HStack(spacing: BP.px(12)) {
            Button { player.toggleMute() } label: {
                Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill").font(.system(size: BP.px(15), weight: .semibold))
            }
            .buttonStyle(MusicIconStyle())
            .accessibilityLabel(muted ? copy("music.unmute", "Unmute") : copy("music.mute", "Mute"))
            .accessibilityIdentifier("music-mute")
            Button { player.stepVolume(by: -0.05) } label: { Image(systemName: "minus").font(.system(size: BP.px(15), weight: .semibold)) }
                .buttonStyle(MusicIconStyle())
                .accessibilityLabel(label + " −")
                .accessibilityValue("\(Int((player.volume * 100).rounded()))%")
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(BP.edge2)
                    Capsule().fill(muted ? BP.inkSubtle : BP.ink).frame(width: g.size.width * CGFloat(min(1, max(0, player.volume))))
                }
            }
            .frame(height: BP.px(4))
            Button { player.stepVolume(by: 0.05) } label: { Image(systemName: "plus").font(.system(size: BP.px(15), weight: .semibold)) }
                .buttonStyle(MusicIconStyle())
                .accessibilityLabel(label + " +")
                .accessibilityValue("\(Int((player.volume * 100).rounded()))%")
            Text(verbatim: "\(label) · \(Int((player.volume * 100).rounded()))%")
                .font(BP.sans(12.5)).monospacedDigit().foregroundStyle(BP.inkSubtle).lineLimit(1)
                .fixedSize()
        }
        .frame(maxWidth: .infinity)
    }
}

/// Round icon button in the Big Picture focus language (ring + lift).
struct MusicIconStyle: ButtonStyle {
    var big = false
    /// A mode that is on (music-dock-icon-on: the accent colour).
    var on = false
    func makeBody(configuration: Configuration) -> some View {
        BPFocusReader { focused in
            let ink: Color = on ? BP.accent : BP.ink
            configuration.label
                .foregroundStyle(focused ? BP.canvas : ink)
                .frame(width: BP.px(big ? 60 : 44), height: BP.px(big ? 60 : 44))
                .background(Circle().fill(focused ? BP.ink : BP.panel2))
                .scaleEffect(focused ? (configuration.isPressed ? 1.02 : 1.08) : 1)
                .animation(BP.easeFast, value: focused)
        }
    }
}
