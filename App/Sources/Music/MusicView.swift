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

    var body: some View {
        ZStack(alignment: .bottom) {
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: BP.px(28)) {
                    mast
                    if player.radioStatus != nil { MusicRadioStatusNote().padding(.horizontal, BP.gutter) }
                    if model.failed { offline }
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
        .onPlayPauseCommand { player.remoteToggle() }
        .fullScreenCover(item: $page) { target in MusicPageView(target: target) }
        .fullScreenCover(isPresented: $searchOpen) { MusicSearchView() }
        .fullScreenCover(isPresented: $sourcesOpen, onDismiss: { Task { await model.load(force: true) } }) { MusicSourcesView() }
        .fullScreenCover(isPresented: $nowPlayingOpen) { MusicNowPlayingView() }
        .fullScreenCover(isPresented: $spotifyLibraryOpen) { MusicSpotifyLibraryView() }
        .musicSpotifyDestinationHost()
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
            player.play(track, queue: band.cards.compactMap(\.track))
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
                Image(systemName: "ellipsis").font(.system(size: BP.px(30), weight: .semibold)).foregroundStyle(BP.inkMuted)
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
                Image(systemName: card.circle ? "person.fill" : "music.note").font(.system(size: BP.px(30))).foregroundStyle(BP.inkSubtle)
            }
        }
    }
}

/// music-track-grid.tsx / music-track-row.tsx cell: art, title, artist, duration.
struct MusicTrackCell: View {
    let card: MusicCard
    var number: Int?
    @ObservedObject private var player = MusicPlayer.shared

    private var playing: Bool { card.track.map { $0.queueKey == player.current?.queueKey } ?? false }

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

/// Previous / play-pause / next / save, shared by the dock and the Now Playing screen.
struct MusicTransportButtons: View {
    var compact = false
    @ObservedObject private var player = MusicPlayer.shared
    @ObservedObject private var copy = MusicCopy.shared

    var body: some View {
        HStack(spacing: BP.px(compact ? 8 : 14)) {
            icon("backward.fill", copy("music.previous", "Previous track")) { player.previous() }
            icon(player.phase == .playing ? "pause.fill" : (player.phase == .error ? "arrow.clockwise" : "play.fill"),
                 player.phase == .playing ? copy("music.pause", "Pause") : copy("music.play", "Play"), big: true) { player.toggle() }
                .accessibilityIdentifier("music-toggle")
            icon("forward.fill", copy("music.next", "Next track")) { player.next() }
            icon(player.isLiked(player.current) ? "heart.fill" : "heart",
                 player.isLiked(player.current) ? copy("music.unsaveTrack", "Remove from saved tracks") : copy("music.saveTrack", "Save track")) { player.toggleLiked() }
        }
    }

    private func icon(_ name: String, _ label: String, big: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).font(.system(size: BP.px(big ? 20 : 16), weight: .semibold))
        }
        .buttonStyle(MusicIconStyle(big: big && !compact))
        .accessibilityLabel(label)
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
    func makeBody(configuration: Configuration) -> some View {
        BPFocusReader { focused in
            configuration.label
                .foregroundStyle(focused ? BP.canvas : BP.ink)
                .frame(width: BP.px(big ? 60 : 44), height: BP.px(big ? 60 : 44))
                .background(Circle().fill(focused ? BP.ink : BP.panel2))
                .scaleEffect(focused ? (configuration.isPressed ? 1.02 : 1.08) : 1)
                .animation(BP.easeFast, value: focused)
        }
    }
}
