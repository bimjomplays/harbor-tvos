import XCTest

/// Remote-navigation checks, seventh batch: Music's own playlists (App/Sources/Music/MusicLibrary.swift
/// MusicLibraryView/MusicPlaylistDetailView/MusicPlaylistPickerView) and "More like this"
/// (music-track-menu.tsx onMoreLikeThis, MusicTrackMenuItems in MusicView.swift). `--fixtures music`
/// only. Offline under that fixture there is no home-row track card at all to begin with (read
/// engine/music.ts home(): the fixture plays a single track with no queue, so MusicPlayer.upcoming
/// stays empty and the "Up next" shelf never builds, and every other shelf -- recents, new
/// releases, charts, artists, a search result, an artist's About tab -- needs Deezer/MusicBrainz,
/// which this fixture has no network for); both tests below first like the fixture track from the
/// dock's own transport row (`music-save-track`, MusicView.swift MusicTransportButtons), which is a
/// purely local engine call (music.setLiked), so `music.home()`'s own "liked" shelf (layout
/// trackGrid) shows the track as a card with the full MusicTrackMenuItems menu
/// (`music-card-liked-0`) -- the only offline route to a track's hold-Select menu at all. Both
/// unlike the track again at the end: `Fixtures.installIfRequested` only wipes ProfilesStore's own
/// keys (`ProfilesStore.reset()`, read directly), not `harbor.music.liked.v1` or the playlists
/// store, so a track left liked (or a playlist's row index) would otherwise leak into whichever
/// `--fixtures music` test runs next. Focus is only asserted where the app places it itself;
/// everything else is polled, with the same helpers and waits as NavigationTests5/6.
final class NavigationTests7: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private var remote: XCUIRemote { XCUIRemote.shared }

    private func launch(_ scenario: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--fixtures", scenario]
        app.launch()
        return app
    }

    // MARK: helpers (as NavigationTests5)

    /// A failed check leaves a screenshot and the element tree behind, then stops the test.
    private func require(_ ok: Bool, _ message: @autoclosure () -> String, _ app: XCUIApplication) {
        guard !ok else { return }
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "failure-screen"
        shot.lifetime = .keepAlways
        add(shot)
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = "failure-hierarchy"
        tree.lifetime = .keepAlways
        add(tree)
        XCTFail(message())
    }

    /// The identifier of the focused button, if one has focus.
    private func focusedId(_ app: XCUIApplication) -> String? {
        let f = app.buttons.matching(NSPredicate(format: "hasFocus == true")).firstMatch
        return f.exists ? f.identifier : nil
    }

    private func focusNote(_ app: XCUIApplication) -> String { focusedId(app) ?? "none" }

    /// Polls until the focused button's identifier matches; returns it, or nil on timeout.
    @discardableResult
    private func waitForFocus(_ app: XCUIApplication, timeout: TimeInterval, where match: (String) -> Bool) -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let id = focusedId(app), match(id) { return id }
            Thread.sleep(forTimeInterval: 0.25)
        } while Date() < deadline
        return nil
    }

    /// Presses `button` until the focus matches (checked before the first press too).
    @discardableResult
    private func press(_ button: XCUIRemote.Button, _ app: XCUIApplication, max presses: Int, until match: (String) -> Bool) -> String? {
        if let id = waitForFocus(app, timeout: 1, where: match) { return id }
        for _ in 0..<presses {
            remote.press(button)
            if let id = waitForFocus(app, timeout: 1, where: match) { return id }
        }
        return nil
    }

    /// Walks a row (or a column: `first` .up / .down) to the element with `id`: one way first, then
    /// back the other, so neither the starting cell nor an overshoot matters.
    private func seek(_ id: String, _ app: XCUIApplication, max presses: Int = 25, first: XCUIRemote.Button = .right) -> Bool {
        let then: XCUIRemote.Button
        switch first {
        case .left: then = .right
        case .up: then = .down
        case .down: then = .up
        default: then = .left
        }
        if press(first, app, max: presses, until: { $0 == id }) != nil { return true }
        return press(then, app, max: presses, until: { $0 == id }) != nil
    }

    private func waitForGone(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        return XCTWaiter().wait(for: [gone], timeout: timeout) == .completed
    }

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.25)
        } while Date() < deadline
        return false
    }

    private static func isHomeCard(_ id: String) -> Bool { id.hasPrefix("cw-") || id.hasPrefix("tile-") }
    private static func inBar(_ id: String) -> Bool { id.hasPrefix("tab-") || id == "profile-chip" || id == "account-menu" }

    /// Fixture Home is up and its first-focus seed (Continue Watching, else the first row) has landed.
    private func waitForHome(_ app: XCUIApplication) {
        require(app.buttons["tile-trending-0"].waitForExistence(timeout: 30), "fixture Home rows never appeared", app)
        let seeded = waitForFocus(app, timeout: 20, where: Self.isHomeCard)
        require(seeded != nil, "Home never seeded focus on a card (focus: \(focusNote(app)))", app)
    }

    /// Up from Home's cards until the ring is in the top bar.
    private func goToBar(_ app: XCUIApplication) {
        let at = press(.up, app, max: 5, until: Self.inBar)
        require(at != nil, "Up never reached the top bar (focus: \(focusNote(app)))", app)
    }

    // MARK: Music-room helpers (this batch only)

    /// Opens the Music room from wherever the ring is (Home's cards or the bar) and waits for it.
    private func openMusic(_ app: XCUIApplication) {
        goToBar(app)
        require(seek("tab-music", app), "could not walk the top bar to Music (focus: \(focusNote(app)))", app)
        remote.press(.select)
        require(waitUntil(timeout: 15) { app.buttons["tab-music"].isSelected }, "Select on the Music tab did not open it", app)
        require(app.buttons["music-search"].waitForExistence(timeout: 20), "the Music room did not open", app)
    }

    /// Likes (`liked == true`) or unlikes the fixture track from the dock's own transport row
    /// (music-toggle's neighbour, `music-save-track`) -- MusicTransportButtons, shared by the dock
    /// and Now Playing, so the dock alone (no need to open Now Playing) can flip it. This is the
    /// batch's whole reason a home-row track card exists at all offline: see the class doc comment.
    private func setLiked(_ liked: Bool, _ app: XCUIApplication) {
        require(press(.down, app, max: 10, until: { $0 == "music-dock-open" }) != nil, "Down never reached the dock (focus: \(focusNote(app)))", app)
        let save = app.buttons["music-save-track"]
        require(seek("music-save-track", app, max: 8), "could not reach the dock's Save track button (focus: \(focusNote(app)))", app)
        sleep(1)
        let before = save.label
        let wanted = liked ? "Remove from saved tracks" : "Save track"
        guard before != wanted else { return }
        remote.press(.select)
        require(waitUntil(timeout: 5) { save.label == wanted }, "Select on the dock's heart did not \(liked ? "like" : "unlike") the fixture track (still \"\(save.label)\")", app)
    }

    /// Holds Select on the liked-track card the Music room's own "Liked songs" shelf now carries
    /// (`music-card-liked-0`, trackGrid layout, MusicTrackCell + the full MusicTrackMenuItems menu)
    /// and returns once the given menu item exists.
    private func openTrackMenu(item: String, _ app: XCUIApplication) -> XCUIElement {
        require(seek("music-card-liked-0", app, max: 12, first: .up), "liking the track did not add a Liked songs card to the Music room (focus: \(focusNote(app)))", app)
        sleep(1)
        // tvOS reveals a SwiftUI .contextMenu on a press-and-hold of Select, not a plain press
        // (developer.apple.com/documentation/xcuiautomation/xcuiremote/press(_:forduration:)).
        remote.press(.select, forDuration: 1.5)
        // Existence alone is checked loosely (`.any`): unverified here (no simulator/compiler in
        // this environment) whether tvOS reports a SwiftUI .contextMenu's rows as `XCUIElementTypeButton`
        // (the `press(.down, ..., until:)` calls below assume so, matching the rest of this file's
        // `app.buttons` convention) or some other element type.
        let entry = app.descendants(matching: .any)[item]
        require(entry.waitForExistence(timeout: 10), "holding Select on the Liked songs card did not open its track menu (\(item) never appeared)", app)
        return app.buttons[item]
    }

    // MARK: tests

    /// Music Library (App/Sources/Music/MusicLibrary.swift MusicLibraryView), opened from the mast's
    /// "Playlists" button -- MusicView.swift already carries an identifier for it, `music-library`
    /// (music-library.tsx's own "Playlists" view), so this batch does not add a second
    /// `music-playlists`. Creates a playlist (`--new-playlist-name` seeds the Name field the way
    /// `--new-profile-name` seeds ProfileEditorView's, since XCUITest cannot type into a tvOS
    /// TextField without the system keyboard up), opens the new row (empty state), Menu back, then
    /// likes the fixture track from the dock so it becomes a home-row card with the full track menu
    /// (see the class doc comment for why that is the only offline route to one at all): "Add to
    /// playlist" (`music-menu-add-to-playlist`) opens MusicPlaylistPickerView, whose row for the
    /// playlist just created (`music-picker-playlist-<name>` -- named, not indexed, so a playlist
    /// left over from an earlier run, which music.playlists() appends rather than fronts, never
    /// shifts which row this is) adds the track and closes back to the Music room; reopening the
    /// playlist proves the track landed (`music-playlist-track-0`). Unlikes the track at the end (see
    /// the class doc comment); the playlist itself is left behind -- its name-keyed identifiers make
    /// that harmless for a later run, and there is no UI test yet for MusicPlaylistDetailView's own
    /// delete-playlist confirmation alert to drive that cleanup safely.
    func testMusicPlaylistsCreateAddAndDetail() {
        let playlistName = "Fixture Playlist"
        let app = XCUIApplication()
        app.launchArguments = ["--fixtures", "music", "--new-playlist-name", playlistName]
        app.launch()
        waitForHome(app)
        openMusic(app)
        sleep(1)

        // Create the playlist from the mast's Playlists button.
        require(seek("music-library", app, max: 6), "could not reach the Playlists button in the mast (focus: \(focusNote(app)))", app)
        sleep(1)
        remote.press(.select)
        let newPlaylist = app.buttons["music-playlist-new"]
        require(newPlaylist.waitForExistence(timeout: 15), "the Playlists button did not open MusicLibraryView", app)
        sleep(1)
        remote.press(.select)
        let create = app.buttons["music-playlist-create"]
        // The New playlist button toggles the create form open below it; Down usually reaches
        // Create directly, but the form's own TextField (unfocusable via `hasFocus == true` on
        // buttons) or its phone-typing button can take the ring first, so fall back to a seek.
        if press(.down, app, max: 6, until: { $0 == "music-playlist-create" }) == nil {
            require(seek("music-playlist-create", app, max: 5), "could not reach Create playlist in the create form (focus: \(focusNote(app)))", app)
        }
        require(create.exists, "the create form's Create playlist button never showed", app)
        sleep(1)
        remote.press(.select)
        let row = app.buttons["music-playlist-\(playlistName)"]
        require(row.waitForExistence(timeout: 15), "the new playlist's row never appeared in the grid", app)
        // Creating a playlist hides the create form; where the ring lands next is not asserted (it
        // may fall back to the header's New playlist button), so seek the row explicitly rather than
        // assume it already has focus.
        sleep(1)
        require(seek("music-playlist-\(playlistName)", app, max: 6, first: .down), "could not reach the new playlist's row (focus: \(focusNote(app)))", app)
        sleep(1)
        remote.press(.select)
        require(app.staticTexts[playlistName].waitForExistence(timeout: 15), "opening the row did not show MusicPlaylistDetailView", app)
        let empty = app.staticTexts["Add a saved or recent track from the lists below."]
        require(empty.waitForExistence(timeout: 10), "a brand-new playlist did not show its empty state", app)
        sleep(1)
        remote.press(.menu)
        require(waitForGone(empty, timeout: 10), "Menu did not close the playlist back to the library grid", app)
        require(row.waitForExistence(timeout: 10), "closing the playlist did not return to MusicLibraryView's grid", app)
        sleep(1)
        remote.press(.menu)
        require(waitForGone(row, timeout: 10), "Menu did not close MusicLibraryView back to the Music room", app)
        require(app.buttons["tab-music"].isSelected, "MusicLibraryView left the Music tab", app)

        // Like the fixture track so it becomes a home-row card, then hold Select on it for
        // "Add to playlist" → MusicPlaylistPickerView → the playlist just created.
        sleep(1)
        setLiked(true, app)
        sleep(1)
        let addToPlaylist = openTrackMenu(item: "music-menu-add-to-playlist", app)
        require(press(.down, app, max: 4, until: { $0 == "music-menu-add-to-playlist" }) != nil, "Down never reached Add to playlist in the track menu (focus: \(focusNote(app)))", app)
        sleep(1)
        remote.press(.select)
        let pickerRow = app.buttons["music-picker-playlist-\(playlistName)"]
        require(pickerRow.waitForExistence(timeout: 15), "Add to playlist did not open MusicPlaylistPickerView with the created playlist", app)
        require(!addToPlaylist.exists, "the track menu did not close once the picker opened", app)
        sleep(1)
        remote.press(.select)
        require(waitForGone(pickerRow, timeout: 10), "picking the playlist did not close MusicPlaylistPickerView", app)
        require(app.buttons["tab-music"].isSelected, "MusicPlaylistPickerView left the Music tab", app)

        // Back into the playlist: the track landed.
        sleep(1)
        require(seek("music-library", app, max: 12, first: .up), "could not reach the Playlists button again (focus: \(focusNote(app)))", app)
        sleep(1)
        remote.press(.select)
        require(row.waitForExistence(timeout: 15), "the Playlists button did not reopen MusicLibraryView", app)
        // A fresh MusicLibraryView instance defaults focus to the header's New playlist button, not
        // the grid, same as the first time the row was opened above.
        sleep(1)
        require(seek("music-playlist-\(playlistName)", app, max: 6, first: .down), "could not reach the playlist's row again (focus: \(focusNote(app)))", app)
        sleep(1)
        remote.press(.select)
        let trackRow = app.buttons["music-playlist-track-0"]
        require(trackRow.waitForExistence(timeout: 15), "the track added from the card's menu never appeared in the playlist", app)
        sleep(1)
        remote.press(.menu)
        require(waitForGone(trackRow, timeout: 10), "Menu did not close the playlist back to the library grid", app)
        require(row.waitForExistence(timeout: 10), "closing the playlist did not return to MusicLibraryView's grid", app)
        sleep(1)
        remote.press(.menu)
        require(waitForGone(row, timeout: 10), "Menu did not close MusicLibraryView back to the Music room", app)

        // Cleanup (see the class doc comment): unlike the track; the playlist is left behind.
        sleep(1)
        setLiked(false, app)
    }

    /// "More like this" (music-track-menu.tsx onMoreLikeThis, MusicTrackMenuItems in
    /// MusicView.swift): there is no MusicSimilarPage anywhere in this codebase (grepping the whole
    /// App/Sources tree for "MusicSimilarPage" and "music-similar" before this batch found nothing
    /// but the new identifier added for it) -- MusicPlayer.startSimilar reuses radioStatus's own
    /// loading/failed note, the same inline note Start Radio's own error uses
    /// (MusicRadioStatusNote, MusicView.swift), never a separate screen. Reached the same way the
    /// sibling test reaches a home-row track menu offline (liking the fixture track from the dock;
    /// see the class doc comment for why nothing else offline has a track menu at all): holding
    /// Select opens the menu, "More like this" (`music-menu-more-like-this`) calls startSimilar, and
    /// since `--fixtures music` has no network for music.similarTracks, the error note
    /// (`music-similar-error`) appears back in the room -- there is nothing to Menu closed, and the
    /// room (and the Music tab) are never left. Unlikes the track afterwards, as the sibling test does.
    func testMusicMoreLikeThisPageOffline() {
        let app = launch("music")
        waitForHome(app)
        openMusic(app)
        sleep(1)
        setLiked(true, app)
        sleep(1)

        _ = openTrackMenu(item: "music-menu-more-like-this", app)
        require(press(.down, app, max: 5, until: { $0 == "music-menu-more-like-this" }) != nil, "Down never reached More like this in the track menu (focus: \(focusNote(app)))", app)
        sleep(1)
        remote.press(.select)
        let error = app.descendants(matching: .any)["music-similar-error"]
        require(error.waitForExistence(timeout: 15), "More like this never showed the offline error note (music.similarTracks needs Deezer/MusicBrainz, unreachable under --fixtures music)", app)
        require(app.buttons["music-search"].exists, "More like this left the Music room even though it never opened a page", app)
        require(app.buttons["tab-music"].isSelected, "More like this left the Music tab even though it never opened a page", app)

        // Cleanup (see the class doc comment): unlike the track.
        sleep(1)
        setLiked(false, app)
    }
}
