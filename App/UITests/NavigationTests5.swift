import XCTest

/// Remote-navigation checks, fifth batch: screens merged on 2026-09-27 that the first four batches
/// do not drive. Offline fixture scenarios only (`--fixtures shell|ebook|music|detail`): Settings'
/// Spoilers panel, the eBook room's browse filter chips and Collections card, the eBook Sources
/// page's New York Times key row, Music's Now Playing (the About the artist tab and the per-source
/// picker), and Detail's episode strip on the `detail` fixture, which now also carries a Special
/// and an episode 0 for DetailModel.buildEpisodes to drop. Focus is only asserted where the app
/// places it itself; everything else is polled, with the same helpers and waits as NavigationTests4.
final class NavigationTests5: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private var remote: XCUIRemote { XCUIRemote.shared }

    private func launch(_ scenario: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--fixtures", scenario]
        app.launch()
        return app
    }

    // MARK: helpers (as NavigationTests4)

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

    // MARK: tests

    /// Settings → Spoilers (App/Sources/Settings/SpoilersPanel.swift): the master toggle
    /// (`spoilers-hide`) shows and hides the three nested toggles at once, and Menu — with no
    /// BPSettingsView column open, the only place Settings itself catches it (testSettingsBackSteps)
    /// — is not caught here either: it reaches the shell, which goes Home, same as any other
    /// Settings row.
    func testSpoilersMasterToggleAndMenu() {
        let app = launch("shell")
        waitForHome(app)
        goToBar(app)
        require(seek("tab-settings", app), "could not walk the top bar to Settings (focus: \(focusNote(app)))", app)
        remote.press(.select)
        require(app.staticTexts["Settings"].waitForExistence(timeout: 15), "Settings did not open", app)
        let master = app.buttons["spoilers-hide"]
        require(master.waitForExistence(timeout: 20), "the Spoilers panel's master toggle never appeared", app)
        require(!app.buttons["spoilers-thumb"].exists, "the nested toggles show before Blur spoilers is on", app)
        sleep(1)
        require(press(.down, app, max: 60, until: { $0 == "spoilers-hide" }) != nil, "Down never reached the Spoilers panel (focus: \(focusNote(app)))", app)
        require(master.label == "Blur spoilers: Off", "Blur spoilers started as \"\(master.label)\", not \"Blur spoilers: Off\"", app)
        sleep(1)
        remote.press(.select)
        require(waitUntil(timeout: 5) { master.label == "Blur spoilers: On" }, "Select on Blur spoilers did not turn it on (now \"\(master.label)\")", app)
        require(app.buttons["spoilers-thumb"].waitForExistence(timeout: 5), "turning Blur spoilers on did not show the nested toggles", app)
        require(app.buttons["spoilers-title"].exists && app.buttons["spoilers-desc"].exists && app.buttons["spoilers-skip-next"].exists,
                "turning Blur spoilers on did not show every nested toggle", app)
        sleep(1)
        remote.press(.select)
        require(waitUntil(timeout: 5) { master.label == "Blur spoilers: Off" }, "Select on Blur spoilers did not turn it off again (now \"\(master.label)\")", app)
        require(!app.buttons["spoilers-thumb"].exists, "turning Blur spoilers off again left the nested toggles up", app)
        sleep(1)
        remote.press(.menu)
        require(waitUntil(timeout: 15) { app.buttons["tab-home"].isSelected }, "Menu from the Spoilers panel did not go Home", app)
        require(app.buttons["tile-trending-0"].waitForExistence(timeout: 30), "Home rows did not come back", app)
    }

    /// eBook (App/Sources/EBook/EBookView.swift; `--fixtures ebook`, a Gutendex source already
    /// installed so the room shows its browse section without the network): the Collections card
    /// opens EBookCollectionsView, and Menu closes it back onto the card, still on the eBook tab.
    /// The five browse filter chips cycle their value and apply it at once, no separate Apply
    /// (unlike upstream's dropdowns): Type, Status, Language and Sort by step to a known next value;
    /// Genre's next value depends on the engine's own category list, so only that one is checked
    /// for existence and that picking it does not disturb its neighbours.
    func testEBookFilterChipsAndCollections() {
        let app = launch("ebook")
        waitForHome(app)
        goToBar(app)
        require(seek("tab-ebook", app), "could not walk the top bar to eBook (focus: \(focusNote(app)))", app)
        remote.press(.select)
        require(waitUntil(timeout: 15) { app.buttons["tab-ebook"].isSelected }, "Select on the eBook tab did not open it", app)
        // The room is a LazyVStack: the Popular rail proves the Gutendex fixture add landed, and the
        // Collections card below it exists only once the ring walks down to it.
        require(app.buttons["tile-ebook-popular-0"].waitForExistence(timeout: 30), "the eBook room never showed its Popular rail (the Gutendex fixture add did not land?)", app)
        sleep(1)
        require(press(.down, app, max: 10, until: { $0 == "ebook-collections" }) != nil, "Down never reached the Collections card (focus: \(focusNote(app)))", app)
        sleep(1)
        remote.press(.select)
        let back = app.buttons["ebook-collections-back"]
        require(back.waitForExistence(timeout: 15), "the Collections card did not open EBookCollectionsView", app)
        sleep(1)
        remote.press(.menu)
        require(waitForGone(back, timeout: 10), "Menu did not close Collections", app)
        require(waitForFocus(app, timeout: 10, where: { $0 == "ebook-collections" }) != nil, "closing Collections did not return the ring to its card (focus: \(focusNote(app)))", app)
        require(app.buttons["tab-ebook"].isSelected, "Collections left the eBook tab", app)
        sleep(1)
        // Down off the cards row can skip the chip row for the results grid below it (run
        // 36304417732): land anywhere in the browse section, then walk back Up onto the chips.
        if press(.down, app, max: 10, until: { $0.hasPrefix("ebook-filter-") }) == nil {
            require(press(.up, app, max: 8, until: { $0.hasPrefix("ebook-filter-") }) != nil, "could not reach the browse filter chips (focus: \(focusNote(app)))", app)
        }
        require(seek("ebook-filter-type", app, max: 6, first: .left), "could not reach the Type chip along the chip row (focus: \(focusNote(app)))", app)
        let type = app.buttons["ebook-filter-type"]
        require(type.label == "Type: All", "the Type chip started as \"\(type.label)\", not \"Type: All\"", app)
        sleep(1)
        remote.press(.select)
        require(waitUntil(timeout: 5) { type.label == "Type: Fiction" }, "Select on the Type chip did not cycle it to Fiction (now \"\(type.label)\")", app)
        require(press(.right, app, max: 3, until: { $0 == "ebook-filter-genre" }) != nil, "Right did not reach the Genre chip (focus: \(focusNote(app)))", app)
        let genre = app.buttons["ebook-filter-genre"]
        let genreBefore = genre.label
        sleep(1)
        remote.press(.select)
        require(waitUntil(timeout: 5) { genre.label != genreBefore }, "Select on the Genre chip did not change it (still \"\(genre.label)\")", app)
        require(press(.right, app, max: 3, until: { $0 == "ebook-filter-status" }) != nil, "Right did not reach the Status chip (focus: \(focusNote(app)))", app)
        let status = app.buttons["ebook-filter-status"]
        require(status.label == "Status: Any", "the Status chip started as \"\(status.label)\", not \"Status: Any\"", app)
        sleep(1)
        remote.press(.select)
        require(waitUntil(timeout: 5) { status.label == "Status: Ongoing" }, "Select on the Status chip did not cycle it to Ongoing (now \"\(status.label)\")", app)
        require(press(.right, app, max: 3, until: { $0 == "ebook-filter-language" }) != nil, "Right did not reach the Language chip (focus: \(focusNote(app)))", app)
        let language = app.buttons["ebook-filter-language"]
        require(language.label == "Language: Any", "the Language chip started as \"\(language.label)\", not \"Language: Any\"", app)
        sleep(1)
        remote.press(.select)
        require(waitUntil(timeout: 5) { language.label == "Language: Chinese" }, "Select on the Language chip did not cycle it to Chinese (now \"\(language.label)\")", app)
        require(press(.right, app, max: 3, until: { $0 == "ebook-filter-sort" }) != nil, "Right did not reach the Sort by chip (focus: \(focusNote(app)))", app)
        let sort = app.buttons["ebook-filter-sort"]
        require(sort.label == "Sort by: Popular", "the Sort by chip started as \"\(sort.label)\", not \"Sort by: Popular\"", app)
        sleep(1)
        remote.press(.select)
        require(waitUntil(timeout: 5) { sort.label == "Sort by: Name" }, "Select on the Sort by chip did not cycle it to Name (now \"\(sort.label)\")", app)
    }

    /// eBook Sources (App/Sources/EBook/EBookView.swift EBookSourcesView), opened from the browse
    /// section's "Manage eBook sources": the New York Times bestsellers row takes the ring (its own
    /// Save button, since a SecureField carries no `hasFocus` button to poll), and Menu closes the
    /// page back onto the button that opened it, still on the eBook tab.
    func testEBookSourcesNytKeyRowFocus() {
        let app = launch("ebook")
        waitForHome(app)
        goToBar(app)
        require(seek("tab-ebook", app), "could not walk the top bar to eBook (focus: \(focusNote(app)))", app)
        remote.press(.select)
        require(waitUntil(timeout: 15) { app.buttons["tab-ebook"].isSelected }, "Select on the eBook tab did not open it", app)
        require(app.buttons["tile-ebook-popular-0"].waitForExistence(timeout: 30), "the eBook room never showed its Popular rail (the Gutendex fixture add did not land?)", app)
        sleep(1)
        // Down into the browse row lands on its first button (Refresh source); Manage is to its right.
        // Down off the cards row can skip the browse row for the results grid below it (run
        // 36304417732): land anywhere in the browse section, then walk back Up onto the row.
        let browseRow: (String) -> Bool = { $0 == "ebook-manage-sources" || $0 == "ebook-refresh-source" }
        if press(.down, app, max: 14, until: browseRow) == nil {
            require(press(.up, app, max: 8, until: browseRow) != nil, "could not reach the browse row (focus: \(focusNote(app)))", app)
        }
        require(seek("ebook-manage-sources", app, max: 4), "could not reach Manage eBook sources along the browse row (focus: \(focusNote(app)))", app)
        sleep(1)
        remote.press(.select)
        let save = app.buttons["ebook-nyt-save"]
        require(save.waitForExistence(timeout: 15), "Manage eBook sources did not open EBookSourcesView", app)
        sleep(1)
        require(press(.down, app, max: 14, until: { $0 == "ebook-nyt-save" }) != nil, "Down never reached the New York Times bestsellers row (focus: \(focusNote(app)))", app)
        sleep(1)
        remote.press(.menu)
        require(waitForGone(save, timeout: 10), "Menu did not close the Sources page", app)
        require(waitForFocus(app, timeout: 10, where: { $0 == "ebook-manage-sources" }) != nil, "closing Sources did not return the ring to Manage eBook sources (focus: \(focusNote(app)))", app)
        require(app.buttons["tab-ebook"].isSelected, "the Sources page left the eBook tab", app)
    }

    /// Music Now Playing (App/Sources/Music/MusicPages.swift; `--fixtures music`, a fixture track
    /// already handed to MusicPlayer so the dock and Now Playing have something to open offline):
    /// Play/Pause takes the ring as the screen opens (MusicPrefersFocus) and Up from the transport
    /// reaches the "About the artist" tab; the source picker opens from the transport row's own
    /// button, its Connect row closes the picker and opens Connections as Now Playing's own layer
    /// (not nested on the picker: closing Connections lands back on Now Playing, never on the
    /// picker), and a further Menu unwinds Now Playing to the Music room.
    func testMusicNowPlayingAboutAndSourcePicker() {
        let app = launch("music")
        waitForHome(app)
        goToBar(app)
        require(seek("tab-music", app), "could not walk the top bar to Music (focus: \(focusNote(app)))", app)
        remote.press(.select)
        require(waitUntil(timeout: 15) { app.buttons["tab-music"].isSelected }, "Select on the Music tab did not open it", app)
        require(app.buttons["music-search"].waitForExistence(timeout: 20), "the Music room did not open", app)
        sleep(1)
        require(press(.down, app, max: 10, until: { $0 == "music-dock-open" }) != nil, "Down never reached the dock (focus: \(focusNote(app)))", app)
        sleep(1)
        remote.press(.select)
        let aboutTab = app.buttons["music-now-tab-about"]
        require(aboutTab.waitForExistence(timeout: 15), "the dock did not open Now Playing", app)
        // prefersDefaultFocus should seed Play/Pause; the simulator lands on the seek row instead
        // (run 36302158467: "gobackward.10"), so walk to the transport row rather than fail on it.
        let transport: Set<String> = ["music-shuffle", "backward.fill", "music-toggle", "forward.fill", "music-repeat", "music-now-picker", "xmark"]
        if waitForFocus(app, timeout: 5, where: { $0 == "music-toggle" }) == nil {
            require(press(.down, app, max: 6, until: { transport.contains($0) }) != nil, "Down never reached the transport row (focus: \(focusNote(app)))", app)
            require(seek("music-toggle", app, max: 6, first: .left), "could not reach Play/Pause along the transport row (focus: \(focusNote(app)))", app)
        }
        sleep(1)
        // The tabs sit at the top of the right column: Up the left column to the seek row, Right out
        // of it, then Up to the tab row and along it (run 36304417732: Up alone stops at the seek row).
        let leftColumn: Set<String> = transport.union(["gobackward.10", "goforward.10", "music-mute", "minus", "plus"])
        require(press(.up, app, max: 6, until: { $0 == "gobackward.10" || $0 == "goforward.10" }) != nil, "Up never reached the seek row (focus: \(focusNote(app)))", app)
        require(press(.right, app, max: 6, until: { !leftColumn.contains($0) }) != nil, "Right never left the left column (focus: \(focusNote(app)))", app)
        require(press(.up, app, max: 8, until: { $0.hasPrefix("music-now-tab-") }) != nil, "Up never reached the tab row (focus: \(focusNote(app)))", app)
        require(seek("music-now-tab-about", app, max: 4), "could not reach the About the artist tab (focus: \(focusNote(app)))", app)
        sleep(1)
        require(press(.down, app, max: 8, until: { $0 == "music-toggle" }) != nil, "could not return to the transport row (focus: \(focusNote(app)))", app)
        require(press(.right, app, max: 6, until: { $0 == "music-now-picker" }) != nil, "Right along the transport row did not reach the source picker button (focus: \(focusNote(app)))", app)
        sleep(1)
        remote.press(.select)
        let connect = app.buttons["music-picker-connect-spotify"]
        require(connect.waitForExistence(timeout: 15), "the source picker did not open", app)
        sleep(1)
        require(press(.down, app, max: 4, until: { $0 == "music-picker-connect-spotify" }) != nil, "could not put the ring on the picker's Connect row (focus: \(focusNote(app)))", app)
        sleep(1)
        remote.press(.select)
        require(waitForGone(connect, timeout: 10), "Connect did not close the source picker", app)
        require(app.staticTexts["Connections"].waitForExistence(timeout: 15), "Connect did not open Connections", app)
        require(aboutTab.exists, "Connections opened nested away from Now Playing instead of on top of it", app)
        sleep(1)
        remote.press(.menu)
        require(waitForGone(app.staticTexts["Connections"], timeout: 10), "Menu did not close Connections", app)
        require(!connect.exists, "closing Connections went back to the source picker instead of Now Playing (nested, not on top)", app)
        require(aboutTab.waitForExistence(timeout: 10), "closing Connections did not return to Now Playing", app)
        sleep(1)
        remote.press(.menu)
        require(waitForGone(aboutTab, timeout: 10), "Menu did not unwind Now Playing", app)
        require(app.buttons["music-dock-open"].waitForExistence(timeout: 15), "closing Now Playing dropped the dock (the fixture track is still \"playing\")", app)
        require(app.buttons["tab-music"].isSelected, "Now Playing left the Music tab", app)
    }

    /// `--fixtures detail`: the fixture series' raw video list now also carries a Special (season 0)
    /// and an episode 0, so DetailModel.buildEpisodes' `guard s > 0, e > 0` (open-items sweep 4) has
    /// something real to drop. The strip still opens on episode 1 with no Special or episode-0 cell
    /// anywhere in it, and no "Specials" button exists on the page (the season stays a lone
    /// Season 1, same as NavigationTests3's "a one-season series shows a lone Season 1 chip").
    func testDetailEpisodeStripDropsSpecialsAndEpisodeZero() {
        let app = launch("detail")
        waitForHome(app)
        let row = press(.down, app, max: 8, until: { $0.hasPrefix("tile-series-") })
        require(row != nil, "Down never reached the Trending Series row (focus: \(focusNote(app)))", app)
        let opener = "tile-series-2"
        require(seek(opener, app, max: 14), "could not walk the row to \(opener) (focus: \(focusNote(app)))", app)
        sleep(1)
        remote.press(.select)
        require(app.buttons["detail-play"].waitForExistence(timeout: 30), "Detail did not open from \(opener)", app)
        require(app.buttons["episode-1-1"].waitForExistence(timeout: 20), "the fixture series' episodes never appeared on Detail", app)
        require(!app.buttons["episode-0-1"].exists, "the Special (season 0) still has a cell in the strip", app)
        require(!app.buttons["episode-1-0"].exists, "episode 0 still has a cell in the strip", app)
        let specials = app.buttons.matching(NSPredicate(format: "label == %@", "Specials"))
        require(specials.count == 0, "a Specials chip shows even though the season is dropped from the strip", app)
        // The strip is a LazyHStack: only the first cells exist until the ring walks the row, so
        // the six real episodes are proven by walking to the last one.
        for n in 1...3 {
            require(app.buttons["episode-1-\(n)"].exists, "episode \(n) is missing from the strip", app)
        }
        let onPlay: String? = waitForFocus(app, timeout: 5, where: { $0 == "detail-play" }) ?? press(.left, app, max: 12, until: { $0 == "detail-play" })
        require(onPlay != nil, "could not put the ring on Play (focus: \(focusNote(app)))", app)
        sleep(1)
        remote.press(.down)
        require(waitForFocus(app, timeout: 5, where: { $0.hasPrefix("episode-1-") }) != nil, "one Down from Play did not reach the episodes (focus: \(focusNote(app)))", app)
        sleep(1)
        require(press(.right, app, max: 8, until: { $0 == "episode-1-6" }) != nil, "Right along the strip never reached episode 6 (focus: \(focusNote(app)))", app)
        require(!app.buttons["episode-1-0"].exists && !app.buttons["episode-0-1"].exists, "a dropped cell appeared once the strip scrolled", app)
    }
}
