import SwiftUI

/// music-similar-page.tsx (upstream `a821e273`, ahead of the pinned submodule at `770ca0bd` —
/// docs/upstream-drift-2026-09-27.md, added by the same squash that renamed the track menu's
/// "Start radio" to "More Like This" there): "Songs like <track>", the More Like This mix shown
/// as its own browsable page rather than queued straight into playback the way Start radio
/// (MusicPlayer.startRadio, still kept alongside this) does. Reached from any track's menu
/// (MusicTrackMenuItems "More like this") through the same .musicTrackActionsHost() environment
/// pattern as Credits / Add to playlist (MusicLibrary.swift's creditsTarget / addTarget).
///
/// Copy note: upstream's own keys for this page (`music.similar.*`) are not in the pinned
/// submodule's i18n catalogs (they ship with the same not-yet-pinned commit as the page itself),
/// so this file's new strings are plain literal `T(...)` calls — correct English today, English
/// on every other language until a translation-coverage pass adds them to tools/locales-tvos.json
/// (out of this pass's file scope). "Add to queue" / "Saved" / the loading and error notes reuse
/// existing, already-localized keys through MusicCopy, same as the rest of the room.
struct MusicSimilarPageView: View {
    let seed: MusicTrack
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var player = MusicPlayer.shared
    @ObservedObject private var copy = MusicCopy.shared
    @State private var tracks: [MusicTrack]?
    @State private var error: String?
    @State private var retrying = false
    @State private var saveState: SaveState = .idle
    @FocusState private var playFocused: Bool

    private enum SaveState: Equatable { case idle, saving, done, error }

    var body: some View {
        ZStack(alignment: .topLeading) {
            BP.canvas.ignoresSafeArea()
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: BP.px(22)) {
                    header
                    statusOrList
                    Color.clear.frame(height: BP.px(40))
                }
                .padding(.top, BP.px(60))
            }
        }
        .onExitCommand { dismiss() }
        .task {
            guard tracks == nil else { return }
            await load()
        }
        .musicTrackActionsHost()
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: BP.px(10)) {
            // (no on-screen Back button, matching MusicLibraryView / MusicPlaylistDetailView: this
            // is a full page, dismissed by the remote's Menu button, .onExitCommand below.)
            Text(T("Songs like %@", seed.title)).font(BP.display(30)).foregroundStyle(BP.ink).lineLimit(2)
            if let tracks, !tracks.isEmpty {
                Text(T("%lld songs from %lld artists", tracks.count, leadArtistCount(tracks)))
                    .font(BP.sans(14)).foregroundStyle(BP.inkMuted)
                HStack(spacing: BP.px(12)) {
                    Button { playAll() } label: { Label(T("Play all"), systemImage: "play.fill") }
                        .buttonStyle(BPActionStyle(primary: true))
                        .focused($playFocused)
                        .accessibilityIdentifier("music-similar-play")
                    Button { queueAll() } label: { Label(copy("music.card.addToQueue", "Add to queue"), systemImage: "text.append") }
                        .buttonStyle(BPTileStyle(radius: BP.rSM))
                        .accessibilityIdentifier("music-similar-queue")
                    saveButton
                }
            }
        }
        .padding(.horizontal, BP.gutter)
        .focusSection()
    }

    @ViewBuilder private var saveButton: some View {
        switch saveState {
        case .idle, .error:
            Button {
                Task { await save() }
            } label: {
                Label(saveState == .error ? copy("music.error.load", "Music could not load.") : T("Save as playlist"), systemImage: saveState == .error ? "exclamationmark.triangle" : "plus")
            }
            .buttonStyle(BPTileStyle(radius: BP.rSM))
            .accessibilityIdentifier("music-similar-save")
        case .saving:
            Label(T("Save as playlist"), systemImage: "plus").opacity(0.6)
        case .done:
            Label(copy("music.saved", "Saved"), systemImage: "checkmark")
        }
    }

    /// The list, or the loading / error state in its place (loading/failed copy reused from
    /// MusicRadioStatusNote's own "music.loading" / "music.radio.error", MusicView.swift).
    @ViewBuilder private var statusOrList: some View {
        if let error {
            VStack(alignment: .leading, spacing: BP.px(12)) {
                BPNote(text: error, tone: BP.danger)
                Button(copy("music.offline.retry", "Try sources again")) {
                    guard !retrying else { return }
                    Task {
                        retrying = true
                        await load()
                        retrying = false
                    }
                }
                .buttonStyle(BPActionStyle(busy: retrying))
            }
            .padding(.horizontal, BP.gutter)
            .focusSection()
        } else if let tracks {
            if tracks.isEmpty {
                BPNote(text: copy("music.row.emptyRow", "Nothing here yet.")).padding(.horizontal, BP.gutter)
            } else {
                LazyVStack(alignment: .leading, spacing: BP.px(6)) {
                    ForEach(Array(tracks.enumerated()), id: \.offset) { i, track in
                        Button { player.play(track, queue: tracks) } label: { MusicTrackLine(track: track, number: i + 1) }
                            .buttonStyle(BPTileStyle(radius: BP.rSM))
                            .musicTrackMenu(track)
                    }
                }
                .padding(.horizontal, BP.gutter)
                .focusSection()
            }
        } else {
            HStack(spacing: BP.px(10)) {
                ProgressView()
                BPNote(text: copy("music.loading", "Loading music"))
            }
            .padding(.horizontal, BP.gutter)
        }
    }

    /// A simplified stand-in for radio.ts's artistCreditParts (splits "A, B & C" credits): no
    /// Swift equivalent exists yet, so this counts distinct full artist strings instead of leads.
    private func leadArtistCount(_ tracks: [MusicTrack]) -> Int {
        Set(tracks.map(\.artist)).count
    }

    private func playAll() {
        guard let tracks, let first = tracks.first else { return }
        player.play(first, queue: tracks)
    }

    private func queueAll() {
        guard let tracks else { return }
        for track in tracks { player.enqueue(track) }
    }

    private func load() async {
        error = nil
        do {
            let result: [MusicTrack] = try await HarborEngine.shared.call("music.similarTracks", [seed])
            tracks = result
            if !result.isEmpty { DispatchQueue.main.async { playFocused = true } }
        } catch EngineError.js(let message) {
            error = MusicPlayer.cleanJSError(message)
        } catch {
            self.error = MusicCopy.shared("music.radio.error", "Couldn’t start radio. Try again or choose another source.")
        }
    }

    private func save() async {
        guard let tracks, saveState != .saving else { return }
        saveState = .saving
        do {
            let created: MusicPlaylist = try await HarborEngine.shared.call("music.createPlaylist", [T("Songs like %@", seed.title)])
            let _: MusicPlaylist = try await HarborEngine.shared.call("music.addTracksToPlaylist", [created.id, tracks])
            saveState = .done
        } catch {
            saveState = .error
        }
    }
}
