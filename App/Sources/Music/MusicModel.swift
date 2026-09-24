import Foundation
import Combine

/// views/music/use-music-data.ts: the home shelves, reloaded when the library changes
/// (harbor:music-library-changed) and on Try again. The engine keeps upstream's six-hour row cache.
@MainActor
final class MusicModel: ObservableObject {
    @Published private(set) var bands: [MusicBand] = []
    @Published private(set) var errors: [MusicSourceError] = []
    @Published private(set) var loading = false
    @Published private(set) var loaded = false
    /// views/music.tsx `stalled`: nothing loaded and nothing personal to show.
    @Published private(set) var failed = false
    private var generation = 0
    private var spotifyRestoreStarted = false

    func load(force: Bool) async {
        generation += 1
        let run = generation
        loading = true
        // spotify/mod.rs initialize: a saved Spotify sign-in comes back in the background (it can
        // take a while on a slow network); its shelves join the home once the session is up.
        if !spotifyRestoreStarted {
            spotifyRestoreStarted = true
            Task {
                let spotify = SpotifyPlayback.shared
                guard !spotify.connected else { return }
                await spotify.restoreIfNeeded()
                if spotify.connected { await self.load(force: true) }
            }
        }
        do {
            let home: MusicHomeData = try await HarborEngine.shared.call("music.home", [force, MusicPlayer.shared.upcoming])
            guard run == generation else { return }
            bands = home.bands
            errors = home.errors
            failed = home.failed
        } catch {
            guard run == generation else { return }
            failed = bands.isEmpty
        }
        loading = false
        loaded = true
    }
}

/// music-search-panel.tsx: typed search across every searchable source, debounced like upstream.
@MainActor
final class MusicSearchModel: ObservableObject {
    @Published var query = "" { didSet { schedule() } }
    @Published private(set) var results: MusicSearchData?
    @Published private(set) var searching = false
    @Published private(set) var error: String?
    private var task: Task<Void, Never>?

    private func schedule() {
        task?.cancel()
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else { results = nil; error = nil; searching = false; return }
        task = Task {
            try? await Task.sleep(for: .milliseconds(420))
            guard !Task.isCancelled else { return }
            searching = true
            do {
                let r: MusicSearchData = try await HarborEngine.shared.call("music.search", [q, String?.none])
                guard !Task.isCancelled, q == query.trimmingCharacters(in: .whitespaces) else { return }
                results = r
                error = nil
            } catch {
                guard !Task.isCancelled else { return }
                self.error = MusicCopy.shared("music.error.search", "Search failed.")
            }
            searching = false
        }
    }
}

/// An album / artist / playlist / station card to open as a page.
struct MusicPageTarget: Identifiable {
    var card: MusicCard
    var id: String { card.key }
}
