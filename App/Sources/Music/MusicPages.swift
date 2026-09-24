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

/// music-now-playing.tsx: large art, title and credit, the seekable bar, transport, and the
/// queue (music-queue.tsx) beside it. Left/Right on the bar seeks 10 s.
struct MusicNowPlayingView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var player = MusicPlayer.shared
    @ObservedObject private var copy = MusicCopy.shared

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
                MusicQueueList()
            }
            .padding(.horizontal, BP.gutter)
            .padding(.top, BP.px(70))
        }
        .onExitCommand { dismiss() }
        .onPlayPauseCommand { player.toggle() }
        .onChange(of: player.current == nil) { _, gone in if gone { dismiss() } }
    }
}

/// music-queue.tsx: now playing, then up next; Select jumps, hold for Remove.
struct MusicQueueList: View {
    @ObservedObject private var player = MusicPlayer.shared
    @ObservedObject private var copy = MusicCopy.shared

    var body: some View {
        VStack(alignment: .leading, spacing: BP.px(10)) {
            Text(copy("music.row.upNext", "Up next")).font(BP.sans(19, .bold)).foregroundStyle(BP.ink)
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
/// on), Jellyfin and Plex (signed in under Settings › Home servers), SoundCloud behind upstream's
/// source consent (music-source-consent.tsx; YouTube is not offered, docs/music-spec.md).
struct MusicSourcesView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var copy = MusicCopy.shared
    @State private var rows: [MusicConnectionRow] = []
    @State private var consentOpen = false

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
        case "catalog": return "Charts, new releases and search from Deezer and Apple’s public catalog. Songs play from a connected source."
        default: return row.detail
        }
    }

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
            if row.gated {
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
        if row.gated {
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
