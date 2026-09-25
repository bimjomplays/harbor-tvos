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
    /// views/music.tsx releasesLoadingMore / releasesMoreError
    @State private var loadingMore = false
    @State private var moreError: String?
    @State private var retrying = false
    @FocusState private var playFocused: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            BP.canvas.ignoresSafeArea()
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: BP.px(26)) {
                    header
                    if player.radioStatus != nil { MusicRadioStatusNote().padding(.horizontal, BP.gutter) }
                    if let error, data == nil {
                        // music-detail.tsx: the error with Try sources again (onRetry). (device-flow
                        // pass) The page had only the note: nothing to focus, no way to try again.
                        VStack(alignment: .leading, spacing: BP.px(12)) {
                            BPNote(text: error, tone: BP.danger)
                            Button(copy("music.offline.retry", "Try sources again")) {
                                guard !retrying else { return }
                                Task {
                                    retrying = true
                                    await load()
                                    retrying = false
                                    // (device-flow pass 4) The error and its button leave once the
                                    // page lands: the ring goes to Play, as on a first open (it fell
                                    // to the dock at the bottom of the screen).
                                    if data?.tracks.isEmpty == false { DispatchQueue.main.async { playFocused = true } }
                                }
                            }
                            .buttonStyle(BPActionStyle(busy: retrying))
                        }
                        .padding(.horizontal, BP.gutter)
                        .focusSection()
                    } else if data == nil {
                        ProgressView().padding(.horizontal, BP.gutter)
                    }
                    if let data {
                        // (perf/memory pass) Lazy: an album or playlist can list hundreds of tracks
                        // (iTunes 200, Deezer pages to the end, Spotify playlists), and each line is
                        // an artwork load plus a MusicPlayer observer. All of them were built, fetched
                        // and re-rendered on every track change, not just the dozen on screen.
                        LazyVStack(alignment: .leading, spacing: BP.px(6)) {
                            ForEach(Array(data.tracks.enumerated()), id: \.offset) { i, track in
                                Button { player.play(track, queue: data.tracks) } label: { MusicTrackLine(track: track, number: i + 1) }
                                    .buttonStyle(BPTileStyle(radius: BP.rSM))
                                    .musicTrackMenu(track)
                            }
                        }
                        .padding(.horizontal, BP.gutter)
                        .focusSection()
                        ForEach(data.bands) { band in
                            MusicBandView(band: band, onCard: { card, band in
                                if let t = card.track { player.play(t, queue: band.cards.compactMap(\.track)) } else { child = MusicPageTarget(card: card) }
                            }, onMore: moreAction(band))
                        }
                        if loadingMore { ProgressView().padding(.horizontal, BP.gutter) }
                        if let moreError { BPNote(text: moreError, tone: BP.danger).padding(.horizontal, BP.gutter) }
                    }
                    Color.clear.frame(height: BP.px(80))
                }
                .padding(.top, BP.px(60))
            }
        }
        // (open-items sweep 2) Stop and close player took the dock from under the ring: Play takes it.
        .musicDock(ringTo: { if data?.tracks.isEmpty == false { playFocused = true } })
        .onExitCommand { dismiss() }
        .onPlayPauseCommand { player.remoteToggle() }
        // (bug pass 3) Once per page: `.task` runs again whenever a cover over it closes (an album
        // opened from this artist, the Spotify playlist picker), and each re-run fetched the whole
        // page again from the server and dropped the albums "Load more" had added.
        .task {
            guard data == nil else { return }
            await load()
            // (kids/music pass 2) With music playing, the dock (since the device-flow pass) is the
            // only focus stop while the page loads, so the ring started there and stayed at the
            // bottom of the screen once the tracks arrived. The page opens on Play, as it does
            // when nothing is playing.
            if data?.tracks.isEmpty == false { DispatchQueue.main.async { playFocused = true } }
        }
        .fullScreenCover(item: $child) { t in MusicPageView(target: t) }
        .musicSpotifyDestinationHost()
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
                        // music-collection-controls.tsx: Play (Play/Pause once it is the queue) and
                        // the Shuffle mode toggle, offered from two tracks.
                        MusicCollectionPlayButton(tracks: tracks)
                            .focused($playFocused)
                            .accessibilityIdentifier("music-page-play")
                        if tracks.count > 1 { MusicCollectionShuffleButton() }
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

    private func moreAction(_ band: MusicBand) -> (() -> Void)? {
        guard band.more != nil else { return nil }
        return { Task { await loadMore(band) } }
    }

    /// views/music.tsx loadMoreArtistReleases: the next page of the artist's albums joins the
    /// shelf (items it already has are skipped); the cursor ends when Spotify has no more.
    private func loadMore(_ band: MusicBand) async {
        guard let cursor = band.more, !loadingMore else { return }
        loadingMore = true
        moreError = nil
        defer { loadingMore = false }
        do {
            let page: MusicArtistMore = try await HarborEngine.shared.call("music.artistMore", [target.card.item, cursor])
            guard var current = data, let i = current.bands.firstIndex(where: { $0.key == band.key }) else { return }
            let known = Set(current.bands[i].cards.map(\.key))
            current.bands[i].cards.append(contentsOf: page.cards.filter { !known.contains($0.key) })
            current.bands[i].more = page.more == cursor ? nil : page.more
            data = current
        } catch EngineError.js(let message) {
            moreError = MusicPlayer.cleanJSError(message)
        } catch {
            moreError = copy("music.error.load", "Music could not load.")
        }
    }

    private func load() async {
        do {
            // The error stays up while a retry runs, so its button keeps the focus.
            data = try await HarborEngine.shared.call("music.open", [target.card.item])
            error = nil
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
    private var playing: Bool { player.isCurrent(track) }

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
            if player.isLiked(track) { Image(systemName: "heart.fill").font(.system(size: BP.px(12))).foregroundStyle(BP.inkMuted).accessibilityLabel(Text(verbatim: MusicCopy.shared("music.saved", "Saved"))) }
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
    /// (open-items sweep 2) "Type on your phone", the keyboard column's last stop above the dock.
    @FocusState private var phoneFocused: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            BP.canvas.ignoresSafeArea()
            HStack(alignment: .top, spacing: BP.px(36)) {
                VStack(alignment: .leading, spacing: BP.px(16)) {
                    HStack(spacing: BP.px(8)) {
                        Image(systemName: "magnifyingglass").foregroundStyle(BP.inkMuted).accessibilityHidden(true)
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
                        .focused($phoneFocused)
                    if model.searching { ProgressView() }
                    if let error = model.error {
                        // music-search-panel.tsx MusicSectionError onRetry (on one line: the
                        // keyboard column has to stay clear of the dock).
                        HStack(spacing: BP.px(12)) {
                            BPNote(text: error, tone: BP.danger)
                            Button("Retry") { model.retry() }.buttonStyle(BPActionStyle())
                        }
                    }
                    if player.radioStatus != nil { MusicRadioStatusNote() }
                }
                .padding(.leading, BP.gutter)
                .padding(.top, BP.px(60))
                .frame(width: BP.px(560), alignment: .leading)
                results
            }
        }
        // (open-items sweep 2) Stop and close player took the dock from under the ring: the keyboard
        // column's stop above the dock takes it.
        .musicDock(ringTo: { phoneFocused = true })
        .onExitCommand { dismiss() }
        .onPlayPauseCommand { player.remoteToggle() }
        .fullScreenCover(item: $page) { t in MusicPageView(target: t) }
        .musicSpotifyDestinationHost()
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
            Text(title).font(BP.sans(19, .bold)).foregroundStyle(BP.ink).accessibilityAddTraits(.isHeader)
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
    /// (device-flow pass) Play/Pause takes the focus when the screen opens: the top-most control,
    /// the Up next tab, did before, a long way from the transport.
    @Namespace private var focusNS

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
                    // 280 (was 340) leaves room for the volume row without pushing the transport off screen (review 37).
                    .frame(width: BP.px(280), height: BP.px(280))
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
                    // The dock's mute button and volume slider (music-dock.tsx), by remote.
                    MusicVolumeControl()
                        .focusSection()
                    HStack(spacing: BP.px(18)) {
                        MusicTransportButtons(focusNamespace: focusNS)
                        Spacer()
                        // music-dock.tsx's close: an X titled "Stop and close player". Icon-only now
                        // Shuffle and Repeat share the row (the labelled button no longer fit 560).
                        Button { player.close(); dismiss() } label: { Image(systemName: "xmark").font(.system(size: BP.px(16), weight: .semibold)) }
                            .buttonStyle(MusicIconStyle())
                            .accessibilityLabel(copy("music.player.close", "Stop and close player"))
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
                    if panel == "lyrics" { MusicLyricsPanel(clock: player.clock) } else { MusicQueueList(showsTitle: false, suggests: true) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, BP.gutter)
            .padding(.top, BP.px(70))
        }
        .focusScope(focusNS)
        .onExitCommand { dismiss() }
        .onPlayPauseCommand { player.remoteToggle() }
        .onChange(of: player.current == nil) { _, gone in if gone { dismiss() } }
        // (device-flow pass) The Up next suggestions' track menu offers Add to playlist: without a
        // host of its own the environment reached MusicView's, which cannot present while this
        // screen is up, so the choice did nothing.
        .musicSpotifyDestinationHost()
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

/// (perf pass 5) MusicLyricsPanel's line list, compared by value (`.equatable()`): the panel's
/// body runs on every 0.5 s clock tick, the list only when the sung line or the lines change.
private struct MusicLyricsLines: View, Equatable {
    let lines: [MusicLyrics.Line]
    let active: Int

    var body: some View {
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
            // (kids/music pass 2) music-now-playing.tsx scrolls on [panel, activeLyric,
            // lyricsState], so also when the tab opens or the lines arrive: lyrics opened
            // mid-song showed the first lines, the sung one off screen, until the next line
            // changed (a long instrumental break kept it there).
            .onAppear {
                guard active >= 0 else { return }
                let at: Int = active
                DispatchQueue.main.async { proxy.scrollTo(at, anchor: .center) }
            }
        }
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
                // (perf pass 5) The clock ticks twice a second; only the sung line's index goes to
                // the list, which redraws when that index (or the lines) change instead of laying
                // out every line of the song on each tick.
                let active: Int = Self.index(lines, at: max(0, clock.position - offset))
                MusicLyricsLines(lines: lines, active: active)
                    .equatable()
            } else {
                VStack(alignment: .leading, spacing: BP.px(10)) {
                    Image(systemName: "music.mic").font(.system(size: BP.px(26))).foregroundStyle(BP.inkSubtle).accessibilityHidden(true)
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
        // (device-flow pass 8) music-now-playing.tsx giveUp: after 9 s still loading reads "No lyrics
        // for this track" (a late answer still lands). A lookup LRCLIB never answered kept "Finding
        // lyrics" up until the engine call itself timed out.
        let giveUp = Task { @MainActor in
            try? await Task.sleep(for: .seconds(9))
            guard !Task.isCancelled, state == "loading" else { return }
            state = "empty"
        }
        defer { giveUp.cancel() }
        // (review 29) The effect's cleanup clears the timer: a newer track, or the panel closing and
        // opening again, cancels this load while the engine call is still out, and the old timer
        // then put "No lyrics" over the next lookup's "Finding lyrics" (the defer waits for the call).
        let result: MusicLyrics? = await withTaskCancellationHandler {
            let found: MusicLyrics? = try? await HarborEngine.shared.call("music.lyrics", [track])
            return found
        } onCancel: {
            giveUp.cancel()
        }
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

/// up-next.ts useUpNextSuggestions (upstream 770ca0bd): with nothing after the current track,
/// Now Playing's Up next tab shows the radio built for that track (engine `music.upNext`, which
/// leaves the track itself out), kept per track for the session like upstream's module cache.
/// A station that can't be built is simply no suggestions (and is asked for again next time).
@MainActor
final class MusicUpNextSuggestions: ObservableObject {
    @Published private(set) var tracks: [MusicTrack] = []
    @Published private(set) var loading = false
    /// up-next.ts `cache`: queueKey (connectorId:id) → the suggestions, only when there were some.
    private static var cache: [String: [MusicTrack]] = [:]

    /// The effect for (enabled, track). Run from `.task(id:)`, so a newer track or the tab closing
    /// cancels it (the hook's `live` flag): a late answer is cached but not shown.
    func load(_ track: MusicTrack?, enabled: Bool) async {
        guard enabled, let track else {
            tracks = []
            loading = false
            return
        }
        let key = track.queueKey
        if let held = Self.cache[key] {
            tracks = held
            loading = false
            return
        }
        tracks = []
        loading = true
        let answer: [MusicTrack]? = try? await HarborEngine.shared.call("music.upNext", [track])
        let following = answer ?? []
        if !following.isEmpty { Self.cache[key] = following }
        guard !Task.isCancelled else { return }
        tracks = following
        loading = false
    }
}

/// music-queue.tsx: now playing, then up next; Select jumps, hold for Remove. On Now Playing
/// (`suggests`), an empty queue offers radio suggestions instead (up-next.ts, upstream 770ca0bd).
/// The rows are what will really play, in that order (music-now-playing.tsx
/// `musicUpcoming(player.queue, player.queueIndex, 40)`): the shuffled order with Shuffle on, the
/// wrap to the start with Repeat all; Repeat one has nothing next, so the suggestions show, as
/// upstream's do. Move up / down change the stored order, so they are offered only without shuffle.
struct MusicQueueList: View {
    var showsTitle = true
    var suggests = false
    @ObservedObject private var player = MusicPlayer.shared
    @ObservedObject private var copy = MusicCopy.shared
    @StateObject private var suggested = MusicUpNextSuggestions()

    /// Upstream reads 40 ahead; the TV lists the whole queue (its rows carry the queue actions).
    private var upNext: [Int] { player.upNext(max(40, player.queue.count)) }
    /// music-now-playing.tsx: `useUpNextSuggestions(current, panel === "queue" && next.length === 0)`.
    private func suggesting(_ next: [Int]) -> Bool { suggests && next.isEmpty && player.current != nil }

    var body: some View {
        let next: [Int] = upNext
        let suggestingNow: Bool = suggesting(next)
        let suggestionKey: String = suggestingNow ? (player.current?.queueKey ?? "") : ""
        let suggestions: [MusicTrack] = suggestingNow ? suggested.tracks : []
        VStack(alignment: .leading, spacing: BP.px(10)) {
            if showsTitle {
                Text(copy("music.row.upNext", "Up next")).font(BP.sans(19, .bold)).foregroundStyle(BP.ink).accessibilityAddTraits(.isHeader)
            }
            // music-queue.tsx: `shuffle && !priorityNext` → "Shuffle is on, so the next track is picked at random."
            if player.shuffle, player.priorityNext == nil, !next.isEmpty {
                BPNote(text: copy("music.queue.shuffleNote", "Shuffle is on, so the next track is picked at random."))
            }
            if next.isEmpty, suggestions.isEmpty {
                // music-now-playing.tsx: "Building up next" while the suggestions load.
                BPNote(text: suggestingNow && suggested.loading ? copy("music.now.queueBuilding", "Building up next") : copy("music.queue.empty", "Nothing is queued."))
            }
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: BP.px(6)) {
                    // (review 24) Keyed by the entry, not its place: after Move up / down (or Play next)
                    // the row, and the ring on it, go with the track (music-queue.tsx keys rows by
                    // connectorId:id; the occurrence tells a track queued twice apart).
                    ForEach(Self.entries(next, in: player.queue), id: \.key) { entry in
                        if player.queue.indices.contains(entry.index) {
                            row(player.queue[entry.index], at: entry.index, position: entry.position)
                        }
                    }
                    // up-next.ts: a suggestion plays with [current, ...suggestions] as the queue.
                    ForEach(Array(suggestions.enumerated()), id: \.offset) { i, track in
                        Button { playSuggestion(track, among: suggestions) } label: { MusicTrackLine(track: track, number: i + 1) }
                            .buttonStyle(BPTileStyle(radius: BP.rSM))
                            .musicTrackMenu(track)
                    }
                }
                .padding(.vertical, BP.px(10))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .focusSection()
        .task(id: suggestionKey) { await suggested.load(player.current, enabled: !suggestionKey.isEmpty) }
    }

    private struct QueueEntry { let key: String; let index: Int; let position: Int }

    /// The upcoming queue indices with a stable key each: queueKey plus its occurrence so far.
    private static func entries(_ next: [Int], in queue: [MusicTrack]) -> [QueueEntry] {
        var seen: [String: Int] = [:]
        var out: [QueueEntry] = []
        for (position, i) in next.enumerated() {
            let base: String = queue.indices.contains(i) ? queue[i].queueKey : "missing"
            let n: Int = seen[base, default: 0]
            seen[base] = n + 1
            out.append(QueueEntry(key: base + "#" + String(n), index: i, position: position))
        }
        return out
    }

    /// One upcoming entry: queue index `i`, `position` places from the current track.
    private func row(_ track: MusicTrack, at i: Int, position: Int) -> some View {
        let upcoming: Bool = i > player.index
        let canMove: Bool = !player.shuffle && upcoming
        return Button { player.jump(to: i) } label: { MusicTrackLine(track: track, number: position + 1) }
            .buttonStyle(BPTileStyle(radius: BP.rSM))
            .contextMenu {
                // music-queue.tsx row actions: Play next, Move up / down, Remove.
                if position > 0 {
                    Button { player.playQueuedNext(at: i) } label: { Label(copy("music.queue.playNext", "Play next"), systemImage: "text.line.first.and.arrowtriangle.forward") }
                }
                if canMove, i > player.index + 1 {
                    Button { player.move(from: i, to: i - 1) } label: {
                        Label(copy("music.queue.moveUp", "Move {title} up").replacingOccurrences(of: "{title}", with: track.title), systemImage: "arrow.up")
                    }
                }
                if canMove, i < player.queue.count - 1 {
                    Button { player.move(from: i, to: i + 1) } label: {
                        Label(copy("music.queue.moveDown", "Move {title} down").replacingOccurrences(of: "{title}", with: track.title), systemImage: "arrow.down")
                    }
                }
                if i != player.index {
                    Button(role: .destructive) { player.remove(at: i) } label: {
                        Label(copy("music.queue.remove", "Remove {title} from the queue").replacingOccurrences(of: "{title}", with: track.title), systemImage: "minus.circle")
                    }
                }
                Button { player.toggleLiked(track) } label: {
                    Label(player.isLiked(track) ? copy("music.unsaveTrack", "Remove from saved tracks") : copy("music.saveTrack", "Save track"),
                          systemImage: player.isLiked(track) ? "heart.slash" : "heart")
                }
            }
    }

    /// music-now-playing.tsx `playMusic(track, upNextQueue)` with `upNextQueue = [current, ...suggested.tracks]`.
    private func playSuggestion(_ track: MusicTrack, among suggestions: [MusicTrack]) {
        guard let current = player.current else { player.play(track, queue: suggestions); return }
        player.play(track, queue: [current] + suggestions)
    }
}

// MARK: - sources

/// components/music/music-connections.tsx, for the sources the TV has: the open catalog (always
/// on), Jellyfin and Plex (signed in under Settings › Home servers), Navidrome / Subsonic with its
/// own sign-in (connectors/subsonic), SoundCloud behind upstream's source consent
/// (music-source-consent.tsx; YouTube is not offered, docs/music-spec.md) and Last.fm
/// scrobbling (music-lastfm.tsx), and Spotify Premium with the listener's own Spotify app
/// (spotify-setup.tsx; playback through librespot, SpotifyPlayback.swift).
struct MusicSourcesView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var copy = MusicCopy.shared
    @State private var rows: [MusicConnectionRow] = []
    @State private var consentOpen = false
    @State private var subsonicOpen = false
    @State private var lastfmOpen = false
    @State private var spotifyOpen = false

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
        .fullScreenCover(isPresented: $spotifyOpen, onDismiss: { Task { await reload() } }) { MusicSpotifyView() }
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
        case "jellyfin", "plex": return row.status == "disconnected" ? T("Sign in to %@ under Settings › Home servers; its music library appears here.", row.name) : row.detail
        case "catalog": return "Charts, new releases and search from Deezer, ListenBrainz and Apple’s public catalog. Songs play from a connected source."
        case "subsonic":
            guard row.status != "disconnected" else { return copy("music.connect.serverBody", "Point Harbor at a folder, Plex, Jellyfin, Navidrome or Subsonic and this shelf fills with albums you already own.") }
            let who = copy("music.connect.connected", "Connected as {account}").replacingOccurrences(of: "{account}", with: row.account ?? "")
            return [who, row.detail].compactMap { $0 }.joined(separator: " · ")
        case "lastfm":
            return row.status == "disconnected" ? copy("music.lastfm.history", "Keep your listening history") : (row.account ?? copy("music.lastfm.connected", "Scrobbling connected"))
        case "spotify":
            // mod.rs connection(): the account and tier when connected, else the setup line; a
            // recorded failure (Free account, rejected sign-in) shows underneath.
            if row.status == "connected" {
                let who = copy("music.spotify.connectedAs", "Connected as {username}").replacingOccurrences(of: "{username}", with: row.account ?? "")
                return [who, row.detail].compactMap { $0 }.joined(separator: " · ")
            }
            let base = "\(copy("music.spotify.connect", "Spotify Premium")) · \(copy("music.spotify.connectDetail", "Connect once for native, ad-free playback."))"
            return row.error.map { "\(base)\n\($0)" } ?? base
        default: return row.detail
        }
    }

    /// Rows with their own action: SoundCloud (consent), Navidrome (sign-in), Last.fm (authorize).
    private func actionable(_ row: MusicConnectionRow) -> Bool { row.gated || row.id == "subsonic" || row.id == "lastfm" || row.id == "spotify" }

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
            if row.id == "spotify" {
                let connected = row.status == "connected"
                Button(connected ? copy("music.connect.disconnect", "Disconnect") : copy("music.spotify.connectAction", "Connect")) {
                    if connected {
                        Task {
                            await SpotifyPlayback.shared.disconnect()
                            await reload()
                        }
                    } else {
                        spotifyOpen = true
                    }
                }
                .buttonStyle(BPActionStyle(primary: !connected))
                .accessibilityIdentifier("music-source-spotify")
            } else if row.id == "subsonic" || row.id == "lastfm" {
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
                Button(row.enabled ? T("Turn off") : copy("music.connect.action", "Connect")) {
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
                        Text(T("Read the %@ terms", "SoundCloud") + ": soundcloud.com/terms-of-use").font(BP.sans(14)).foregroundStyle(BP.inkSubtle)
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
                        .buttonStyle(BPActionStyle(primary: true, busy: busy))
                        .disabled(url.trimmingCharacters(in: .whitespaces).isEmpty || username.trimmingCharacters(in: .whitespaces).isEmpty || password.isEmpty)
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
        guard !busy else { return }
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
                Text(verbatim: "Last.fm").font(BP.sans(24, .bold)).foregroundStyle(BP.ink)
                Text(subtitle).font(BP.sans(15)).foregroundStyle(BP.inkMuted)
                if let pending {
                    HStack(alignment: .top, spacing: BP.px(18)) {
                        if let qr = QRCode.image(pending.authUrl) {
                            Image(uiImage: qr).interpolation(.none).resizable().frame(width: BP.px(170), height: BP.px(170)).accessibilityLabel(Text(T("QR code")))
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
                    .buttonStyle(BPActionStyle(primary: true, busy: working))
                    .disabled(pending == nil && !canBegin)
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
        guard !working else { return }
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
        guard let pending, !working else { return }
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

// MARK: - Spotify

/// components/music/music-connections/spotify-setup.tsx on the TV. Upstream ships no Spotify client
/// id (auth.rs BRING_YOUR_OWN): the listener creates an app in Spotify's dashboard, adds Harbor's
/// redirect URI and pastes the client id (typed on the phone here). Upstream then opens the
/// authorize page in the desktop browser and catches the redirect on 127.0.0.1:8898; the TV shows
/// the authorize page as a QR code, the phone signs in, and the address the phone ends on (which
/// does not load) is pasted back, also from the phone. Premium only (librespot): a Free account
/// gets upstream's copy (session.rs FREE_ACCOUNT).
struct MusicSpotifyView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var copy = MusicCopy.shared
    @ObservedObject private var spotify = SpotifyPlayback.shared
    @State private var setup: MusicSpotifySetup?
    @State private var clientId = ""
    @State private var pending: MusicSpotifyAuthStart?
    @State private var pasted = ""
    @State private var working = false
    @State private var error: String?

    var body: some View {
        ZStack {
            BP.void_.opacity(0.92).ignoresSafeArea()
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: BP.px(16)) {
                    Text(copy("music.spotify.connect", "Spotify Premium")).font(BP.sans(24, .bold)).foregroundStyle(BP.ink)
                    Text(copy("music.spotify.connectDetail", "Connect once for native, ad-free playback.")).font(BP.sans(15)).foregroundStyle(BP.inkMuted)
                    if let pending { authorize(pending) } else { steps }
                    if let error { BPNote(text: error, tone: BP.danger) }
                    HStack(spacing: BP.px(12)) {
                        Button {
                            guard !spotify.connecting else { return }
                            Task { if pending == nil { await begin() } else { await finish() } }
                        } label: {
                            Label(label, systemImage: pending == nil ? "arrow.up.right" : "checkmark")
                        }
                        .buttonStyle(BPActionStyle(primary: true, busy: working || spotify.connecting))
                        .disabled(!canGo)
                        .accessibilityIdentifier("music-spotify-go")
                        if pending != nil {
                            Button(copy("music.spotifySetup.authorize", "Authorize Spotify")) { pending = nil; pasted = ""; error = nil }
                                .buttonStyle(BPActionStyle())
                        }
                        Button("Cancel") { dismiss() }.buttonStyle(BPActionStyle())
                    }
                    .focusSection()
                }
                .padding(BP.px(32))
            }
            .frame(width: BP.px(900))
            .frame(maxHeight: BP.px(900))
            .background(RoundedRectangle(cornerRadius: BP.rLG, style: .continuous).fill(BP.panel))
        }
        .onExitCommand { dismiss() }
        .task {
            setup = try? await HarborEngine.shared.call("music.spotifySetup")
            if clientId.isEmpty, let saved = setup?.clientId { clientId = saved }
        }
    }

    private var redirectUri: String { setup?.redirectUri ?? "http://127.0.0.1:8898/login" }

    private var label: String {
        if working || spotify.connecting { return copy("music.connect.connecting", "Connecting") }
        return pending == nil ? copy("music.spotifySetup.authorize", "Authorize Spotify") : copy("music.lastfm.finish", "Finish connection")
    }

    /// spotify-setup.tsx: a typed client id, or the one saved on this device (Use saved configuration).
    private var canGo: Bool {
        pending == nil ? !clientId.trimmingCharacters(in: .whitespaces).isEmpty : !pasted.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// The three numbered steps of spotify-setup.tsx.
    @ViewBuilder private var steps: some View {
        step(1, copy("music.spotifySetup.createTitle", "Create a Spotify app"), copy("music.spotifySetup.createBody", "Use a Spotify Premium account to create an app in the developer dashboard.")) {
            HStack(alignment: .center, spacing: BP.px(14)) {
                if let qr = QRCode.image(setup?.dashboardUrl ?? "https://developer.spotify.com/dashboard") {
                    Image(uiImage: qr).interpolation(.none).resizable().frame(width: BP.px(120), height: BP.px(120)).accessibilityLabel(Text(T("QR code")))
                        .padding(BP.px(6)).background(RoundedRectangle(cornerRadius: BP.rXS, style: .continuous).fill(.white))
                }
                VStack(alignment: .leading, spacing: BP.px(4)) {
                    Text(copy("music.spotifySetup.dashboard", "Open Spotify dashboard")).font(BP.sans(14, .semibold)).foregroundStyle(BP.ink)
                    Text("Scan the code to open it on your phone.").font(BP.sans(13)).foregroundStyle(BP.inkMuted)
                }
            }
        }
        step(2, copy("music.spotifySetup.redirectTitle", "Add Harbor’s redirect URI"), copy("music.spotifySetup.redirectBody", "In your app’s settings, add this exact redirect URI and save.")) {
            VStack(alignment: .leading, spacing: BP.px(4)) {
                Text(copy("music.spotifySetup.redirectLabel", "Redirect URI")).font(BP.sans(12, .semibold)).foregroundStyle(BP.inkSubtle)
                Text(redirectUri).font(.system(size: BP.px(17), design: .monospaced)).foregroundStyle(BP.ink)
                    .padding(.horizontal, BP.px(12)).padding(.vertical, BP.px(8))
                    .background(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).fill(BP.glass))
            }
        }
        step(3, copy("music.spotifySetup.clientTitle", "Paste your Client ID"), nil) {
            VStack(alignment: .leading, spacing: BP.px(6)) {
                BPField(label: copy("music.spotifySetup.clientTitle", "Paste your Client ID"), placeholder: copy("music.spotifySetup.clientPlaceholder", "Client ID from your Spotify app settings"), text: $clientId, phone: true)
                BPNote(text: copy("music.spotifySetup.accountHint", "Connecting a different Spotify account? Add it in your app’s Settings → Users Management first."))
                if setup?.clientId.isEmpty == false {
                    BPNote(text: copy("music.spotifySetup.savedHint", "Already set up on this device? Continue with your saved Client ID."))
                }
            }
        }
    }

    private func step<Content: View>(_ number: Int, _ title: String, _ detail: String?, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: BP.px(12)) {
            Text("\(number)").font(BP.sans(12, .semibold)).foregroundStyle(BP.inkMuted)
                .frame(width: BP.px(24), height: BP.px(24))
                .background(Circle().fill(BP.glass))
            VStack(alignment: .leading, spacing: BP.px(6)) {
                Text(title).font(BP.sans(15, .semibold)).foregroundStyle(BP.ink)
                if let detail { Text(detail).font(BP.sans(14)).foregroundStyle(BP.inkMuted).fixedSize(horizontal: false, vertical: true) }
                content()
            }
        }
    }

    /// The phone hand-off: the authorize page as a QR code, then the address the phone ended on.
    @ViewBuilder private func authorize(_ started: MusicSpotifyAuthStart) -> some View {
        HStack(alignment: .top, spacing: BP.px(18)) {
            if let qr = QRCode.image(started.authorizeUrl) {
                Image(uiImage: qr).interpolation(.none).resizable().frame(width: BP.px(190), height: BP.px(190)).accessibilityLabel(Text(T("QR code")))
                    .padding(BP.px(8)).background(RoundedRectangle(cornerRadius: BP.rXS, style: .continuous).fill(.white))
            }
            VStack(alignment: .leading, spacing: BP.px(8)) {
                Text("Scan the code with your phone and sign in with your Spotify Premium account.").font(BP.sans(15)).foregroundStyle(BP.ink).fixedSize(horizontal: false, vertical: true)
                Text("Spotify then sends your phone to an address starting with \(started.redirectUri) that does not open. Copy that whole address and paste it below.")
                    .font(BP.sans(14)).foregroundStyle(BP.inkMuted).fixedSize(horizontal: false, vertical: true)
            }
        }
        BPField(label: "Address your phone ended on", placeholder: "\(started.redirectUri)?code=…", text: $pasted, keyboard: .URL, phone: true)
    }

    /// music.spotifySetup.missingSaved / rejected: spotify-setup.ts spotifySetupErrorKey swaps the
    /// backend's walkthrough for the form's own guidance.
    private func describe(_ message: String) -> String {
        if message.contains("Spotify needs your own client id") { return copy("music.spotifySetup.missingSaved", "No Client ID is saved on this device. Follow the setup steps and paste your Client ID.") }
        if message.contains("Spotify rejected that client id") { return copy("music.spotifySetup.rejected", "Check the Client ID and redirect URI in your Spotify app settings, then try again.") }
        return message
    }

    private func begin() async {
        guard !working else { return }
        working = true
        defer { working = false }
        error = nil
        do {
            pending = try await HarborEngine.shared.call("music.spotifyBegin", [clientId])
            pasted = ""
        } catch EngineError.js(let message) {
            error = describe(MusicPlayer.cleanJSError(message))
        } catch {
            self.error = "\(error)"
        }
    }

    private func finish() async {
        guard !working else { return }
        working = true
        defer { working = false }
        error = nil
        do {
            let granted: SpotifyPlayback.Granted = try await HarborEngine.shared.call("music.spotifyFinish", [pasted])
            let status = try await spotify.connect(granted)
            if status.connected {
                dismiss()
            } else {
                // A Free account (or a session Spotify closed): upstream's message, and back to the start.
                error = status.error ?? copy("music.recovery.premium", "Spotify playback here requires Premium. Check your subscription or choose another source.")
                pending = nil
            }
        } catch EngineError.js(let message) {
            error = describe(MusicPlayer.cleanJSError(message))
        } catch let failure as SpotifyPlayback.Failure {
            error = describe(failure.message)
            pending = nil
        } catch {
            self.error = "\(error)"
        }
    }
}
