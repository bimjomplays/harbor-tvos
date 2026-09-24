import SwiftUI

// MARK: - album / artist / playlist / station page

/// views/music/music-detail.tsx: the header (art, kind, title, credit, Play and Shuffle), the
/// track list, then the source's extra shelves (an artist's albums, related artists).
struct MusicPageView: View {
    let target: MusicPageTarget
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var player = MusicPlayer.shared
    @ObservedObject private var copy = MusicCopy.shared
    @State private var data: MusicPageData?
    @State private var error: String?
    @State private var child: MusicPageTarget?

    var body: some View {
        ZStack(alignment: .topLeading) {
            BP.canvas.ignoresSafeArea()
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: BP.px(26)) {
                    header
                    if player.radioStatus != nil { MusicRadioStatusNote().padding(.horizontal, BP.gutter) }
                    if let error {
                        BPNote(text: error, tone: BP.danger).padding(.horizontal, BP.gutter)
                    } else if data == nil {
                        ProgressView().padding(.horizontal, BP.gutter)
                    }
                    if let data {
                        VStack(alignment: .leading, spacing: BP.px(6)) {
                            ForEach(Array(data.tracks.enumerated()), id: \.offset) { i, track in
                                Button { player.play(track, queue: data.tracks) } label: { MusicTrackLine(track: track, number: i + 1) }
                                    .buttonStyle(BPTileStyle(radius: BP.rSM))
                                    .musicTrackMenu(track)
                            }
                        }
                        .padding(.horizontal, BP.gutter)
                        .focusSection()
                        ForEach(data.bands) { band in
                            MusicBandView(band: band) { card, band in
                                if let t = card.track { player.play(t, queue: band.cards.compactMap(\.track)) } else { child = MusicPageTarget(card: card) }
                            }
                        }
                    }
                    Color.clear.frame(height: BP.px(80))
                }
                .padding(.top, BP.px(60))
            }
        }
        .onExitCommand { dismiss() }
        .onPlayPauseCommand { player.toggle() }
        .task { await load() }
        .fullScreenCover(item: $child) { t in MusicPageView(target: t) }
    }

    private var header: some View {
        HStack(alignment: .bottom, spacing: BP.px(28)) {
            ZStack {
                let art = data?.artwork.isEmpty == false ? data!.artwork : target.card.artwork
                if art.isEmpty { BP.panel2 } else { RemoteImage(url: art) }
            }
            .frame(width: BP.px(200), height: BP.px(200))
            .clipShape(RoundedRectangle(cornerRadius: target.card.circle ? BP.px(100) : BP.rMD, style: .continuous))
            .shadow(color: .black.opacity(0.5), radius: 30, y: 16)
            VStack(alignment: .leading, spacing: BP.px(8)) {
                Text(kindLabel).font(BP.sans(13, .semibold)).foregroundStyle(BP.inkSubtle).textCase(.uppercase)
                Text(data?.title ?? target.card.title).font(BP.display(36)).foregroundStyle(BP.ink).lineLimit(2)
                let sub = data?.subtitle ?? target.card.subtitle
                if !sub.isEmpty { Text(sub).font(BP.sans(16)).foregroundStyle(BP.inkMuted).lineLimit(1) }
                if let tracks = data?.tracks, !tracks.isEmpty {
                    HStack(spacing: BP.px(12)) {
                        Button { player.play(tracks[0], queue: tracks) } label: { Label(copy("music.play", "Play"), systemImage: "play.fill") }
                            .buttonStyle(BPActionStyle(primary: true))
                            .accessibilityIdentifier("music-page-play")
                        Button {
                            let shuffled = tracks.shuffled()
                            player.play(shuffled[0], queue: shuffled)
                        } label: { Label("Shuffle", systemImage: "shuffle") }
                            .buttonStyle(BPActionStyle())
                        Text(copy("music.trackCount", "{count} tracks").replacingOccurrences(of: "{count}", with: "\(tracks.count)"))
                            .font(BP.sans(14)).foregroundStyle(BP.inkSubtle)
                    }
                    .padding(.top, BP.px(6))
                    .focusSection()
                }
            }
        }
        .padding(.horizontal, BP.gutter)
    }

    private var kindLabel: String {
        switch target.card.kind {
        case "album": return copy("music.search.albums", "Albums").dropLastS
        case "artist": return copy("music.search.artists", "Artists").dropLastS
        case "playlist": return copy("music.search.playlists", "Playlists").dropLastS
        case "station": return copy("music.row.stationBadge", "Radio")
        default: return ""
        }
    }

    private func load() async {
        do {
            data = try await HarborEngine.shared.call("music.open", [target.card.item])
        } catch EngineError.js(let message) {
            error = MusicPlayer.cleanJSError(message)
        } catch {
            self.error = copy("music.error.load", "Music could not load.")
        }
    }
}

private extension String {
    /// "Albums" → "Album" for the eyebrow; other languages keep the plural as upstream shows it.
    var dropLastS: String { hasSuffix("s") ? String(dropLast()) : self }
}

/// music-track-row.tsx: number (or the playing wave), title, artist, album, length.
struct MusicTrackLine: View {
    let track: MusicTrack
    let number: Int
    @ObservedObject private var player = MusicPlayer.shared
    private var playing: Bool { player.current?.queueKey == track.queueKey }

    var body: some View {
        HStack(spacing: BP.px(14)) {
            Group {
                if playing { Image(systemName: "waveform").foregroundStyle(BP.accent) } else { Text("\(number)").foregroundStyle(BP.inkSubtle) }
            }
            .font(BP.sans(14, .semibold)).frame(width: BP.px(28))
            ZStack {
                if let art = track.artwork, !art.isEmpty { RemoteImage(url: art) } else { BP.panel2 }
            }
            .frame(width: BP.px(40), height: BP.px(40))
            .clipShape(RoundedRectangle(cornerRadius: BP.rXS, style: .continuous))
            VStack(alignment: .leading, spacing: BP.px(2)) {
                Text(track.title).font(BP.sans(15, .semibold)).foregroundStyle(playing ? BP.accent : BP.ink).lineLimit(1)
                Text(track.artist).font(BP.sans(13)).foregroundStyle(BP.inkSubtle).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let album = track.album {
                Text(album).font(BP.sans(13)).foregroundStyle(BP.inkSubtle).lineLimit(1).frame(width: BP.px(260), alignment: .leading)
            }
            if player.isLiked(track) { Image(systemName: "heart.fill").font(.system(size: BP.px(12))).foregroundStyle(BP.inkMuted) }
            Text(track.seconds > 0 ? (track.durationLabel ?? MusicProgressBar.stamp(track.seconds)) : "")
                .font(BP.sans(13)).monospacedDigit().foregroundStyle(BP.inkSubtle).frame(width: BP.px(56), alignment: .trailing)
        }
        .padding(.horizontal, BP.px(12))
        .frame(height: BP.px(54))
        .background(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).fill(BP.glass))
    }
}

// MARK: - search

/// music-search-panel.tsx + music-mast.tsx search, in the TV search room's shape: the keyboard
/// on the left, results on the right (top result, tracks, then albums / artists / playlists).
struct MusicSearchView: View {
    @StateObject private var model = MusicSearchModel()
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var player = MusicPlayer.shared
    @ObservedObject private var copy = MusicCopy.shared
    @State private var page: MusicPageTarget?
    @State private var phoneOpen = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            BP.canvas.ignoresSafeArea()
            HStack(alignment: .top, spacing: BP.px(36)) {
                VStack(alignment: .leading, spacing: BP.px(16)) {
                    HStack(spacing: BP.px(8)) {
                        Image(systemName: "magnifyingglass").foregroundStyle(BP.inkMuted)
                        Text(model.query.isEmpty ? copy("music.searchPlaceholder", "Search songs, albums, artists") : model.query)
                            .font(BP.sans(22, .semibold)).foregroundStyle(model.query.isEmpty ? BP.inkSubtle : BP.ink).lineLimit(1)
                        Rectangle().fill(BP.ink).frame(width: 2, height: BP.px(26)).opacity(0.8)
                    }
                    .frame(height: BP.px(44))
                    BPKeyboardView(onChar: { model.query += $0 },
                                   onBackspace: { if !model.query.isEmpty { model.query.removeLast() } },
                                   onClear: { model.query = "" })
                    Button { phoneOpen = true } label: { Label("Type on your phone", systemImage: "iphone") }
                        .buttonStyle(BPActionStyle())
                    if model.searching { ProgressView() }
                    if let error = model.error { BPNote(text: error, tone: BP.danger) }
                    if player.radioStatus != nil { MusicRadioStatusNote() }
                }
                .padding(.leading, BP.gutter)
                .padding(.top, BP.px(60))
                .frame(width: BP.px(560), alignment: .leading)
                results
            }
        }
        .onExitCommand { dismiss() }
        .fullScreenCover(item: $page) { t in MusicPageView(target: t) }
        .fullScreenCover(isPresented: $phoneOpen) {
            PhoneTypingSheet(label: copy("music.searchLabel", "Search music"), placeholder: copy("music.searchPlaceholder", "Search songs, albums, artists"),
                             text: $model.query, onClose: { phoneOpen = false })
        }
    }

    @ViewBuilder private var results: some View {
        if let r = model.results {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: BP.px(24)) {
                    if r.isEmpty {
                        BPNote(text: copy("music.searchEmpty", "No tracks matched this search."))
                    }
                    if let top = r.top {
                        section(copy("music.search.top", "Top result")) {
                            Button { open(top, among: r.tracks) } label: { MusicCoverCell(card: top) }
                                .buttonStyle(BPTileStyle(radius: top.circle ? BP.px(80) : BP.rSM))
                                .musicTrackMenu(top.track)
                        }
                    }
                    if !r.tracks.isEmpty {
                        section(copy("music.search.tracks", "Tracks")) {
                            LazyVGrid(columns: [GridItem(.fixed(BP.px(330)), spacing: BP.px(14)), GridItem(.fixed(BP.px(330)), spacing: BP.px(14))], alignment: .leading, spacing: BP.px(10)) {
                                ForEach(Array(r.tracks.prefix(12).enumerated()), id: \.offset) { _, card in
                                    Button { open(card, among: r.tracks) } label: { MusicTrackCell(card: card) }
                                        .buttonStyle(BPTileStyle(radius: BP.rSM))
                                        .musicTrackMenu(card.track)
                                }
                            }
                        }
                    }
                    shelf(copy("music.search.artists", "Artists"), r.artists)
                    shelf(copy("music.search.albums", "Albums"), r.albums)
                    shelf(copy("music.search.playlists", "Playlists"), r.playlists)
                    Color.clear.frame(height: BP.px(80))
                }
                .padding(.top, BP.px(60))
                .padding(.trailing, BP.gutter)
            }
        } else {
            Spacer()
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: BP.px(10)) {
            Text(title).font(BP.sans(19, .bold)).foregroundStyle(BP.ink)
            content()
        }
        .focusSection()
    }

    @ViewBuilder private func shelf(_ title: String, _ cards: [MusicCard]) -> some View {
        if !cards.isEmpty {
            section(title) {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: BP.trackGap) {
                        ForEach(Array(cards.enumerated()), id: \.offset) { _, card in
                            Button { open(card, among: []) } label: { MusicCoverCell(card: card) }
                                .buttonStyle(BPTileStyle(radius: card.circle ? BP.px(80) : BP.rSM))
                        }
                    }
                    .padding(.vertical, BP.px(14))
                }
                .scrollClipDisabled()
            }
        }
    }

    private func open(_ card: MusicCard, among tracks: [MusicCard]) {
        if let t = card.track {
            let queue = tracks.compactMap(\.track)
            player.play(t, queue: queue.isEmpty ? [t] : queue)
        } else {
            page = MusicPageTarget(card: card)
        }
    }
}

// MARK: - Now Playing

/// music-now-playing.tsx: large art, title and credit, the seekable bar, transport, and beside
/// them the tabbed panel: the queue (music-queue.tsx) or the lyrics. Left/Right on the bar seeks
/// 10 s. Upstream's other two tabs (About the artist, Signal) are not on the TV yet.
struct MusicNowPlayingView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var player = MusicPlayer.shared
    @ObservedObject private var copy = MusicCopy.shared
    @State private var panel = "queue"

    var body: some View {
        ZStack {
            BP.canvas.ignoresSafeArea()
            if let art = player.current?.artwork, !art.isEmpty {
                RemoteImage(url: art).blur(radius: 80).opacity(0.35).ignoresSafeArea()
            }
            HStack(alignment: .top, spacing: BP.px(50)) {
                VStack(alignment: .leading, spacing: BP.px(18)) {
                    ZStack {
                        if let art = player.current?.artwork, !art.isEmpty { RemoteImage(url: art) } else { BP.panel2 }
                    }
                    .frame(width: BP.px(340), height: BP.px(340))
                    .clipShape(RoundedRectangle(cornerRadius: BP.rMD, style: .continuous))
                    .shadow(color: .black.opacity(0.55), radius: 40, y: 20)
                    Text(player.current?.title ?? "").font(BP.display(30)).foregroundStyle(BP.ink).lineLimit(2)
                    Text([player.current?.artist, player.current?.album].compactMap { $0 }.joined(separator: " · "))
                        .font(BP.sans(16)).foregroundStyle(BP.inkMuted).lineLimit(1)
                    if player.phase == .error, let e = player.error { BPNote(text: e, tone: BP.danger) }
                    if player.phase == .resolving { BPNote(text: copy("music.row.resolving", "Finding a source for this")) }
                    // The seek bar with ten-second steps either side (the dock's scrub, by remote).
                    HStack(spacing: BP.px(12)) {
                        Button { player.skip(by: -10) } label: { Image(systemName: "gobackward.10").font(.system(size: BP.px(15), weight: .semibold)) }
                            .buttonStyle(MusicIconStyle())
                            .accessibilityLabel(copy("music.position", "Track position"))
                        MusicProgressBar(clock: player.clock)
                        Button { player.skip(by: 10) } label: { Image(systemName: "goforward.10").font(.system(size: BP.px(15), weight: .semibold)) }
                            .buttonStyle(MusicIconStyle())
                            .accessibilityLabel(copy("music.position", "Track position"))
                    }
                    .focusSection()
                    HStack(spacing: BP.px(18)) {
                        MusicTransportButtons()
                        Spacer()
                        Button { player.close(); dismiss() } label: { Label(copy("music.player.close", "Stop and close player"), systemImage: "xmark") }
                            .buttonStyle(BPActionStyle())
                    }
                    .focusSection()
                }
                .frame(width: BP.px(560), alignment: .leading)
                VStack(alignment: .leading, spacing: BP.px(14)) {
                    HStack(spacing: BP.px(10)) {
                        tab("queue", copy("music.now.next", "Up next"))
                        tab("lyrics", copy("Lyrics", "Lyrics"))
                    }
                    .focusSection()
                    if panel == "lyrics" { MusicLyricsPanel(clock: player.clock) } else { MusicQueueList(showsTitle: false) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, BP.gutter)
            .padding(.top, BP.px(70))
        }
        .onExitCommand { dismiss() }
        .onPlayPauseCommand { player.toggle() }
        .onChange(of: player.current == nil) { _, gone in if gone { dismiss() } }
    }

    private func tab(_ id: String, _ title: String) -> some View {
        Button { panel = id } label: {
            Text(title).font(BP.sans(15, .semibold))
                .padding(.horizontal, BP.px(16)).padding(.vertical, BP.px(8))
                .background(Capsule().fill(panel == id ? BP.ink.opacity(0.14) : .clear))
        }
        .buttonStyle(BPTileStyle(radius: BP.px(20)))
        .accessibilityIdentifier("music-now-tab-\(id)")
    }
}

/// music-now-playing.tsx lyrics panel: LRCLIB's synced lines (lyrics.ts), the active line kept
/// in the middle as it plays (karaoke-scroll.ts anchor 0.5), and the per-track Lyric sync nudge
/// (lyric-offset.ts, ±0.25 s). Upstream makes each line a seek button; on the TV the lines are
/// text so the list can follow the song without the focus engine pulling it back.
struct MusicLyricsPanel: View {
    @ObservedObject var clock: MusicClock
    @ObservedObject private var player = MusicPlayer.shared
    @ObservedObject private var copy = MusicCopy.shared
    @State private var lines: [MusicLyrics.Line] = []
    @State private var state = "loading"
    @State private var offset: Double = 0

    /// lyric-offset.ts LYRIC_OFFSET_STEP
    private static let step = 0.25

    var body: some View {
        VStack(alignment: .leading, spacing: BP.px(12)) {
            if state == "ready" {
                HStack(spacing: BP.px(10)) {
                    Text(copy("Lyric sync", "Lyric sync")).font(BP.sans(13, .semibold)).foregroundStyle(BP.inkSubtle)
                    Button { nudge(-Self.step) } label: { Text("-").font(BP.sans(16, .bold)) }
                        .buttonStyle(MusicIconStyle())
                        .accessibilityLabel(copy("Lyrics earlier", "Lyrics earlier"))
                    Text(offsetLabel).font(BP.sans(13)).monospacedDigit().foregroundStyle(BP.inkMuted).frame(width: BP.px(64))
                    Button { nudge(Self.step) } label: { Text("+").font(BP.sans(16, .bold)) }
                        .buttonStyle(MusicIconStyle())
                        .accessibilityLabel(copy("Lyrics later", "Lyrics later"))
                }
                .focusSection()
                let active = Self.index(lines, at: max(0, clock.position - offset))
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: BP.px(14)) {
                            ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                                Text(line.text.isEmpty ? "♪" : line.text)
                                    .font(BP.sans(i == active ? 26 : 22, i == active ? .bold : .semibold))
                                    .foregroundStyle(i == active ? BP.ink : (i < active ? BP.inkSubtle : BP.inkMuted))
                                    .fixedSize(horizontal: false, vertical: true)
                                    .id(i)
                            }
                        }
                        .padding(.vertical, BP.px(140))
                        .animation(.easeOut(duration: 0.25), value: active)
                    }
                    .onChange(of: active) { _, now in
                        guard now >= 0 else { return }
                        withAnimation(.easeInOut(duration: 0.35)) { proxy.scrollTo(now, anchor: .center) }
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: BP.px(10)) {
                    Image(systemName: "music.mic").font(.system(size: BP.px(26))).foregroundStyle(BP.inkSubtle)
                    BPNote(text: state == "loading" ? copy("Finding lyrics", "Finding lyrics") : copy("No lyrics for this track", "No lyrics for this track"))
                }
                .padding(.top, BP.px(20))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: player.current?.queueKey) { await load() }
    }

    private var offsetLabel: String {
        offset == 0 ? "0.00s" : String(format: "%@%.2fs", offset > 0 ? "+" : "", offset)
    }

    /// lyrics.ts lyricIndexAt: the last line whose time has come, or -1 before the first.
    static func index(_ lines: [MusicLyrics.Line], at seconds: Double) -> Int {
        guard !lines.isEmpty, seconds.isFinite else { return -1 }
        var low = 0, high = lines.count - 1, found = -1
        while low <= high {
            let mid = (low + high) / 2
            if lines[mid].at <= seconds { found = mid; low = mid + 1 } else { high = mid - 1 }
        }
        return found
    }

    private func load() async {
        guard let track = player.current else { return }
        lines = []
        state = "loading"
        let result: MusicLyrics? = try? await HarborEngine.shared.call("music.lyrics", [track])
        guard !Task.isCancelled, player.current?.queueKey == track.queueKey else { return }
        lines = result?.lines ?? []
        offset = result?.offset ?? 0
        state = lines.isEmpty ? "empty" : "ready"
    }

    private func nudge(_ delta: Double) {
        guard let track = player.current else { return }
        let target = offset + delta
        Task {
            if let stored: Double = try? await HarborEngine.shared.call("music.setLyricOffset", [track, target]) { offset = stored }
        }
    }
}

/// music-queue.tsx: now playing, then up next; Select jumps, hold for Remove.
struct MusicQueueList: View {
    var showsTitle = true
    @ObservedObject private var player = MusicPlayer.shared
    @ObservedObject private var copy = MusicCopy.shared

    var body: some View {
        VStack(alignment: .leading, spacing: BP.px(10)) {
            if showsTitle {
                Text(copy("music.row.upNext", "Up next")).font(BP.sans(19, .bold)).foregroundStyle(BP.ink)
            }
            if player.upcoming.isEmpty {
                BPNote(text: copy("music.queue.empty", "Nothing is queued."))
            }
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: BP.px(6)) {
                    ForEach(Array(player.queue.enumerated()), id: \.offset) { i, track in
                        if i > player.index {
                            Button { player.jump(to: i) } label: { MusicTrackLine(track: track, number: i - player.index) }
                                .buttonStyle(BPTileStyle(radius: BP.rSM))
                                .contextMenu {
                                    Button(role: .destructive) { player.remove(at: i) } label: { Label("Remove", systemImage: "minus.circle") }
                                    Button { player.toggleLiked(track) } label: {
                                        Label(player.isLiked(track) ? copy("music.unsaveTrack", "Remove from saved tracks") : copy("music.saveTrack", "Save track"),
                                              systemImage: player.isLiked(track) ? "heart.slash" : "heart")
                                    }
                                }
                        }
                    }
                }
                .padding(.vertical, BP.px(10))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .focusSection()
    }
}

// MARK: - sources

/// components/music/music-connections.tsx, for the sources the TV has: the open catalog (always
/// on), Jellyfin and Plex (signed in under Settings › Home servers), Navidrome / Subsonic with its
/// own sign-in (connectors/subsonic), SoundCloud behind upstream's source consent
/// (music-source-consent.tsx; YouTube is not offered, docs/music-spec.md) and Last.fm
/// scrobbling (music-lastfm.tsx).
struct MusicSourcesView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var copy = MusicCopy.shared
    @State private var rows: [MusicConnectionRow] = []
    @State private var consentOpen = false
    @State private var subsonicOpen = false
    @State private var lastfmOpen = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            BP.canvas.ignoresSafeArea()
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: BP.px(16)) {
                    Text(copy("music.connections.title", "Connections")).font(BP.display(32)).foregroundStyle(BP.ink)
                    Text(copy("music.connections.subtitle", "Everything Harbor can play music from")).font(BP.sans(15)).foregroundStyle(BP.inkMuted)
                    ForEach(rows) { row in focusableRow(row) }
                    Color.clear.frame(height: BP.px(60))
                }
                .padding(.horizontal, BP.gutter)
                .padding(.top, BP.px(60))
                .frame(maxWidth: BP.px(900), alignment: .leading)
            }
        }
        .onExitCommand { dismiss() }
        .task { await reload() }
        .fullScreenCover(isPresented: $consentOpen, onDismiss: { Task { await reload() } }) { MusicConsentView() }
        .fullScreenCover(isPresented: $subsonicOpen, onDismiss: { Task { await reload() } }) { MusicSubsonicSignInView() }
        .fullScreenCover(isPresented: $lastfmOpen, onDismiss: { Task { await reload() } }) { MusicLastFmView() }
    }

    private func reload() async {
        if let r: [MusicConnectionRow] = try? await HarborEngine.shared.call("music.connections") { rows = r }
    }

    private func status(_ row: MusicConnectionRow) -> String {
        switch row.status {
        case "connected": return copy("music.connections.statusConnected", "Connected")
        case "error": return copy("music.connections.statusError", "Needs attention")
        case "unavailable": return copy("music.connections.statusUnavailable", "Unavailable")
        default: return copy("music.connections.statusDisconnected", "Not connected")
        }
    }

    private func hint(_ row: MusicConnectionRow) -> String? {
        switch row.id {
        case "jellyfin", "plex": return row.status == "disconnected" ? "Sign in to \(row.name) under Settings › Home servers; its music library appears here." : row.detail
        case "catalog": return "Charts, new releases and search from Deezer, ListenBrainz and Apple’s public catalog. Songs play from a connected source."
        case "subsonic":
            guard row.status != "disconnected" else { return copy("music.connect.serverBody", "Point Harbor at a folder, Plex, Jellyfin, Navidrome or Subsonic and this shelf fills with albums you already own.") }
            let who = copy("music.connect.connected", "Connected as {account}").replacingOccurrences(of: "{account}", with: row.account ?? "")
            return [who, row.detail].compactMap { $0 }.joined(separator: " · ")
        case "lastfm":
            return row.status == "disconnected" ? copy("music.lastfm.history", "Keep your listening history") : (row.account ?? copy("music.lastfm.connected", "Scrobbling connected"))
        default: return row.detail
        }
    }

    /// Rows with their own action: SoundCloud (consent), Navidrome (sign-in), Last.fm (authorize).
    private func actionable(_ row: MusicConnectionRow) -> Bool { row.gated || row.id == "subsonic" || row.id == "lastfm" }

    @ViewBuilder private func rowView(_ row: MusicConnectionRow) -> some View {
        HStack(alignment: .center, spacing: BP.px(16)) {
            VStack(alignment: .leading, spacing: BP.px(4)) {
                HStack(spacing: BP.px(10)) {
                    Text(row.name).font(BP.sans(18, .semibold)).foregroundStyle(BP.ink)
                    Text(status(row)).font(BP.sans(12.5, .semibold))
                        .foregroundStyle(row.status == "connected" ? BP.live : (row.status == "error" ? BP.danger : BP.inkSubtle))
                        .padding(.horizontal, BP.px(8)).padding(.vertical, BP.px(3))
                        .background(Capsule().fill(BP.glass))
                }
                if let h = hint(row) { BPNote(text: h) }
            }
            Spacer()
            if row.id == "subsonic" || row.id == "lastfm" {
                let connected = row.status != "disconnected"
                Button(connected ? copy("music.connect.disconnect", "Disconnect") : copy("music.connect.action", "Connect")) {
                    if connected {
                        Task {
                            if row.id == "subsonic" {
                                let _: Bool? = try? await HarborEngine.shared.call("music.subsonicDisconnect")
                            } else {
                                let _: MusicLastFmStatus? = try? await HarborEngine.shared.call("music.lastfmDisconnect")
                            }
                            await reload()
                        }
                    } else if row.id == "subsonic" {
                        subsonicOpen = true
                    } else {
                        lastfmOpen = true
                    }
                }
                .buttonStyle(BPActionStyle(primary: !connected))
                .accessibilityIdentifier("music-source-\(row.id)")
            } else if row.gated {
                Button(row.enabled ? "Turn off" : copy("music.connect.action", "Connect")) {
                    if row.enabled {
                        Task {
                            let _: MusicConsentState? = try? await HarborEngine.shared.call("music.setSoundCloud", [false])
                            await reload()
                        }
                    } else {
                        consentOpen = true
                    }
                }
                .buttonStyle(BPActionStyle(primary: !row.enabled))
                .accessibilityIdentifier("music-source-\(row.id)")
            }
        }
        .padding(BP.px(18))
        .background(RoundedRectangle(cornerRadius: BP.rMD, style: .continuous).fill(BP.panel))
        .focusSection()
    }

    /// Rows without an action still take focus, so the list scrolls and reads with the remote.
    @ViewBuilder private func focusableRow(_ row: MusicConnectionRow) -> some View {
        if actionable(row) {
            rowView(row)
        } else {
            Button {} label: { rowView(row) }.buttonStyle(BPTileStyle(radius: BP.rMD))
        }
    }
}

/// music-source-consent.tsx: the four paragraphs, read to the end, then accept. On the TV the
/// only gated source offered is SoundCloud.
struct MusicConsentView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var copy = MusicCopy.shared
    @State private var read = false
    @FocusState private var endFocused: Bool

    var body: some View {
        ZStack {
            BP.void_.opacity(0.92).ignoresSafeArea()
            VStack(alignment: .leading, spacing: BP.px(16)) {
                Label(copy("music.consent.title", "Before you turn on YouTube or SoundCloud"), systemImage: "checkmark.shield")
                    .font(BP.sans(22, .bold)).foregroundStyle(BP.ink)
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: BP.px(14)) {
                        // Each paragraph takes focus, so the remote steps through the text to its end.
                        ForEach(["music.consent.hosting", "music.consent.terms", "music.consent.responsibility", "music.consent.rights"], id: \.self) { key in
                            MusicConsentParagraph(text: copy(key, ""))
                        }
                        Text("SoundCloud terms: soundcloud.com/terms-of-use").font(BP.sans(14)).foregroundStyle(BP.inkSubtle)
                        // The end of the text: reaching it counts as "read to the end" (the scroll check).
                        Button { read = true } label: { Text("I have read this").font(BP.sans(14, .semibold)) }
                            .buttonStyle(BPActionStyle())
                            .focused($endFocused)
                            .onChange(of: endFocused) { _, now in if now { read = true } }
                    }
                    .padding(.vertical, BP.px(8))
                }
                .frame(maxHeight: BP.px(420))
                HStack(spacing: BP.px(12)) {
                    Button(copy("music.consent.accept", "I agree and accept")) {
                        Task {
                            let _: MusicConsentState? = try? await HarborEngine.shared.call("music.acceptSoundCloud")
                            dismiss()
                        }
                    }
                    .buttonStyle(BPActionStyle(primary: true))
                    .disabled(!read)
                    .accessibilityIdentifier("music-consent-accept")
                    Button("Cancel") { dismiss() }.buttonStyle(BPActionStyle())
                }
                .focusSection()
            }
            .padding(BP.px(32))
            .frame(width: BP.px(760))
            .background(RoundedRectangle(cornerRadius: BP.rLG, style: .continuous).fill(BP.panel))
        }
        .onExitCommand { dismiss() }
    }
}

/// A consent paragraph the remote can land on (music-consent-body scrolls; the TV steps).
struct MusicConsentParagraph: View {
    let text: String
    @FocusState private var focused: Bool
    var body: some View {
        Text(text).font(BP.sans(15)).foregroundStyle(focused ? BP.ink : BP.inkMuted).fixedSize(horizontal: false, vertical: true)
            .padding(BP.px(8))
            .background(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).fill(focused ? BP.glass : .clear))
            .focusable()
            .focused($focused)
    }
}

// MARK: - Navidrome / Subsonic sign-in

/// connectors/subsonic/mod.rs connection().needs: Server URL (placeholder
/// https://navidrome.local), Username, Password. Every field can be typed on a phone; the
/// password is only used to make the pairing and is never stored (pairing.rs keeps the token).
struct MusicSubsonicSignInView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var copy = MusicCopy.shared
    @State private var url = ""
    @State private var username = ""
    @State private var password = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        ZStack {
            BP.void_.opacity(0.92).ignoresSafeArea()
            VStack(alignment: .leading, spacing: BP.px(16)) {
                Text(copy("music.connect.title", "Connect {name}").replacingOccurrences(of: "{name}", with: "Navidrome"))
                    .font(BP.sans(24, .bold)).foregroundStyle(BP.ink)
                BPField(label: "Server URL", placeholder: "https://navidrome.local", text: $url, keyboard: .URL)
                BPField(label: "Username", placeholder: "", text: $username, phone: true)
                BPField(label: "Password", placeholder: "", text: $password, secure: true, phone: true)
                if let error { BPNote(text: error, tone: BP.danger) }
                HStack(spacing: BP.px(12)) {
                    Button(busy ? copy("music.connect.connecting", "Connecting") : copy("music.connect.action", "Connect")) { Task { await connect() } }
                        .buttonStyle(BPActionStyle(primary: true))
                        .disabled(busy || url.trimmingCharacters(in: .whitespaces).isEmpty || username.trimmingCharacters(in: .whitespaces).isEmpty || password.isEmpty)
                        .accessibilityIdentifier("music-subsonic-connect")
                    Button("Cancel") { dismiss() }.buttonStyle(BPActionStyle())
                }
                .focusSection()
            }
            .padding(BP.px(32))
            .frame(width: BP.px(760))
            .background(RoundedRectangle(cornerRadius: BP.rLG, style: .continuous).fill(BP.panel))
        }
        .onExitCommand { dismiss() }
    }

    private func connect() async {
        busy = true
        defer { busy = false }
        error = nil
        do {
            let _: MusicSubsonicConnected = try await HarborEngine.shared.call("music.subsonicConnect", [url, username, password])
            password = ""
            dismiss()
        } catch EngineError.js(let message) {
            error = copy("music.connect.failed", "Could not connect. {error}").replacingOccurrences(of: "{error}", with: MusicPlayer.cleanJSError(message))
        } catch {
            self.error = copy("music.connect.failed", "Could not connect. {error}").replacingOccurrences(of: "{error}", with: "")
        }
    }
}

// MARK: - Last.fm

/// components/music/music-lastfm.tsx on the TV: the viewer's own Last.fm API key and shared
/// secret, then Authorize Last.fm; upstream opens the approval page in the desktop browser, the
/// TV shows it as a QR code for a phone (as the tracker sign-ins do), then Finish connection.
struct MusicLastFmView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var copy = MusicCopy.shared
    @State private var status: MusicLastFmStatus?
    @State private var apiKey = ""
    @State private var apiSecret = ""
    @State private var pending: MusicLastFmAuthStart?
    @State private var working = false
    @State private var error: String?

    var body: some View {
        ZStack {
            BP.void_.opacity(0.92).ignoresSafeArea()
            VStack(alignment: .leading, spacing: BP.px(16)) {
                Text("Last.fm").font(BP.sans(24, .bold)).foregroundStyle(BP.ink)
                Text(subtitle).font(BP.sans(15)).foregroundStyle(BP.inkMuted)
                if let pending {
                    HStack(alignment: .top, spacing: BP.px(18)) {
                        if let qr = QRCode.image(pending.authUrl) {
                            Image(uiImage: qr).interpolation(.none).resizable().frame(width: BP.px(170), height: BP.px(170))
                                .padding(BP.px(8)).background(RoundedRectangle(cornerRadius: BP.rXS, style: .continuous).fill(.white))
                        }
                        VStack(alignment: .leading, spacing: BP.px(8)) {
                            BPNote(text: copy("music.lastfm.browserPrompt", "Approve Harbor in the browser, then finish the connection here."))
                            Text("Scan the code with your phone to open the approval page.").font(BP.sans(14)).foregroundStyle(BP.inkMuted)
                            Text(pending.authUrl).font(BP.sans(11)).foregroundStyle(BP.inkSubtle).lineLimit(3)
                        }
                    }
                } else {
                    BPField(label: copy("music.lastfm.apiKey", "API key"), placeholder: "", text: $apiKey, phone: true)
                    BPField(label: copy("music.lastfm.secret", "Shared secret"), placeholder: status?.saved == true ? "••••••••" : "", text: $apiSecret, secure: true, phone: true)
                }
                if let error { BPNote(text: error, tone: BP.danger) }
                HStack(spacing: BP.px(12)) {
                    Button {
                        Task { if pending == nil { await begin() } else { await finish() } }
                    } label: {
                        Label(working ? copy("music.connect.connecting", "Connecting") : (pending == nil ? copy("music.lastfm.authorize", "Authorize Last.fm") : copy("music.lastfm.finish", "Finish connection")),
                              systemImage: pending == nil ? "arrow.up.right" : "checkmark")
                    }
                    .buttonStyle(BPActionStyle(primary: true))
                    .disabled(working || (pending == nil && !canBegin))
                    .accessibilityIdentifier("music-lastfm-go")
                    Button("Cancel") { dismiss() }.buttonStyle(BPActionStyle())
                }
                .focusSection()
            }
            .padding(BP.px(32))
            .frame(width: BP.px(820))
            .background(RoundedRectangle(cornerRadius: BP.rLG, style: .continuous).fill(BP.panel))
        }
        .onExitCommand { dismiss() }
        .task {
            status = try? await HarborEngine.shared.call("music.lastfmStatus")
            if apiKey.isEmpty, let saved = status?.apiKey { apiKey = saved }
        }
    }

    private var subtitle: String {
        if status?.connected == true { return status?.username ?? copy("music.lastfm.connected", "Scrobbling connected") }
        return status?.saved == true ? copy("music.lastfm.saved", "Credentials saved") : copy("music.lastfm.history", "Keep your listening history")
    }

    /// music-lastfm.tsx: both fields are needed; a saved secret stands in for an empty field.
    private var canBegin: Bool {
        !apiKey.trimmingCharacters(in: .whitespaces).isEmpty && (!apiSecret.trimmingCharacters(in: .whitespaces).isEmpty || status?.saved == true)
    }

    private func begin() async {
        working = true
        defer { working = false }
        error = nil
        do {
            let started: MusicLastFmAuthStart = try await HarborEngine.shared.call("music.lastfmBegin", [apiKey, apiSecret])
            pending = started
            apiSecret = ""
        } catch EngineError.js(let message) {
            error = MusicPlayer.cleanJSError(message)
        } catch {
            self.error = "\(error)"
        }
    }

    private func finish() async {
        guard let pending else { return }
        working = true
        defer { working = false }
        error = nil
        do {
            let done: MusicLastFmStatus = try await HarborEngine.shared.call("music.lastfmFinish", [pending.token])
            status = done
            self.pending = nil
            dismiss()
        } catch EngineError.js(let message) {
            error = MusicPlayer.cleanJSError(message)
        } catch {
            self.error = "\(error)"
        }
    }
}
