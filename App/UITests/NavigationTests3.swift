import XCTest

/// Remote-navigation checks, third batch: flows fixed on 2026-09-25 (device-flow passes 4-7) that
/// NavigationTests and NavigationTests2 do not drive. Offline fixture scenarios only
/// (`--fixtures shell|detail|calfail|kidsfail`): Detail's one-season episodes and the ring's way
/// back to the tile that opened it, the Library's Filters panel and Menu, the account menu and the
/// bell, a failed Calendar month's Try again, and a failed kids page's Try again. Focus is only
/// asserted where the app places it itself; everything else is polled, with the same helpers and
/// waits as NavigationTests2.
final class NavigationTests3: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private var remote: XCUIRemote { XCUIRemote.shared }

    private func launch(_ scenario: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--fixtures", scenario]
        app.launch()
        return app
    }

    // MARK: helpers (as NavigationTests2)

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

    /// Walks a row to the element with `id`: one way first, then back the other, so neither the
    /// starting cell nor an overshoot matters.
    private func seek(_ id: String, _ app: XCUIApplication, max presses: Int = 25, first: XCUIRemote.Button = .right) -> Bool {
        let then: XCUIRemote.Button = first == .right ? .left : .right
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

    /// Watches the ring for `seconds`: the first other button that took it, or nil if none did.
    private func focusLeft(_ app: XCUIApplication, from id: String, within seconds: TimeInterval) -> String? {
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            if let now = focusedId(app), now != id { return now }
            Thread.sleep(forTimeInterval: 0.25)
        } while Date() < deadline
        return nil
    }

    private static func isHomeCard(_ id: String) -> Bool { id.hasPrefix("cw-") || id.hasPrefix("tile-") }
    private static func inBar(_ id: String) -> Bool { id.hasPrefix("tab-") || id == "profile-chip" || id == "account-menu" }
    private static func inKidsBar(_ id: String) -> Bool { id == "tab-kids" || id == "tab-kids-play" || id == "profile-chip" }

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

    /// `--fixtures detail` (series carry one season of six episodes): a Trending Series tile opens
    /// Detail with no lone "Season 1" chip (bp-episodes.tsx; device-flow pass 6), one Down from
    /// Play reaches the episodes, and Menu from the episodes closes Detail with the ring back on the
    /// tile that opened it (not the row's first tile, not the top bar).
    func testDetailOneSeasonEpisodesAndBack() {
        let app = launch("detail")
        waitForHome(app)
        // Down from Jump back in, past the three movie rows, to Trending Series.
        let row = press(.down, app, max: 8, until: { $0.hasPrefix("tile-series-") })
        require(row != nil, "Down never reached the Trending Series row (focus: \(focusNote(app)))", app)
        let opener = "tile-series-2"
        require(seek(opener, app, max: 14), "could not walk the row to \(opener) (focus: \(focusNote(app)))", app)
        sleep(1)
        remote.press(.select)
        let play = app.buttons["detail-play"]
        require(play.waitForExistence(timeout: 30), "Detail did not open from \(opener)", app)
        require(app.buttons["episode-1-1"].waitForExistence(timeout: 20), "the fixture series' episodes never appeared on Detail", app)
        let chips = app.buttons.matching(NSPredicate(format: "label == %@", "Season 1"))
        require(chips.count == 0, "a one-season series shows a lone Season 1 chip", app)
        let onPlay: String? = waitForFocus(app, timeout: 5, where: { $0 == "detail-play" }) ?? press(.left, app, max: 12, until: { $0 == "detail-play" })
        require(onPlay != nil, "could not put the ring on Play (focus: \(focusNote(app)))", app)
        sleep(1)
        remote.press(.down)
        let episode = waitForFocus(app, timeout: 5, where: { $0.hasPrefix("episode-1-") })
        require(episode != nil, "one Down from Play did not reach the episodes (focus: \(focusNote(app)))", app)
        sleep(1)
        remote.press(.menu)
        require(waitForGone(play, timeout: 15), "Menu on Detail's episodes did not close Detail", app)
        let back = waitForFocus(app, timeout: 15, where: { $0 == opener })
        require(back != nil, "after Detail closed the ring was not back on \(opener) (focus: \(focusNote(app)))", app)
        require(app.buttons["tab-home"].isSelected, "Menu on Detail left Home", app)
    }

    /// Library: Down from the top bar reaches the chip row; Filters opens its panel inline and Down
    /// reaches its chips; Menu in the panel closes it with the ring back on Filters, still on the
    /// Library (it used to leave for Home); a second Menu, with no panel open, goes Home.
    func testLibraryFiltersMenuSteps() {
        let app = launch("shell")
        waitForHome(app)
        goToBar(app)
        require(seek("tab-library", app), "could not walk the top bar to Library (focus: \(focusNote(app)))", app)
        remote.press(.select)
        let filters = app.buttons["library-filters"]
        require(filters.waitForExistence(timeout: 20), "the Library chip row did not appear", app)
        require(waitUntil(timeout: 10) { app.buttons["tab-library"].isSelected }, "Select on the Library tab did not open the Library", app)
        // The tab chips come from the engine a moment later; let them land before walking the row.
        sleep(2)
        let inRow = press(.down, app, max: 3, until: { $0.hasPrefix("library-") })
        require(inRow != nil, "Down from the top bar did not reach the Library chip row (focus: \(focusNote(app)))", app)
        require(seek("library-filters", app, max: 10), "could not walk the chip row to Filters (focus: \(focusNote(app)))", app)
        sleep(1)
        remote.press(.select)
        let anyFilter = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'library-filter-'")).firstMatch
        require(anyFilter.waitForExistence(timeout: 10), "Filters did not open its panel", app)
        let chip = press(.down, app, max: 4, until: { $0.hasPrefix("library-filter-") })
        require(chip != nil, "Down from Filters did not reach the panel's chips (focus: \(focusNote(app)))", app)
        sleep(1)
        remote.press(.menu)
        require(waitForGone(anyFilter, timeout: 10), "Menu in the Filters panel did not close it", app)
        require(waitForFocus(app, timeout: 10, where: { $0 == "library-filters" }) != nil, "closing the Filters panel did not return the ring to Filters (focus: \(focusNote(app)))", app)
        require(app.buttons["tab-library"].isSelected, "Menu in the Filters panel left the Library", app)
        sleep(1)
        remote.press(.menu)
        require(waitUntil(timeout: 15) { app.buttons["tab-home"].isSelected }, "Menu on the Library chip row (no panel open) did not go Home", app)
    }

    /// The top bar's bell opens the account menu with the ring on its first item (View my profile
    /// signed in, else Groups); Menu closes it with the ring back on the bell. Opened again, its
    /// Settings item closes the menu, opens Settings, and the ring is not lost.
    func testAccountMenuBackToBell() {
        let app = launch("shell")
        waitForHome(app)
        goToBar(app)
        require(seek("account-menu", app), "could not walk the top bar to the bell (focus: \(focusNote(app)))", app)
        remote.press(.select)
        let items = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'account-item-'"))
        require(items.firstMatch.waitForExistence(timeout: 15), "the bell did not open the account menu", app)
        let seeded = waitForFocus(app, timeout: 10, where: { $0 == "account-item-profile" || $0 == "account-item-groups" })
        require(seeded != nil, "the account menu did not open with the ring on its first item (focus: \(focusNote(app)))", app)
        sleep(1)
        remote.press(.menu)
        require(waitForGone(items.firstMatch, timeout: 10), "Menu did not close the account menu", app)
        require(waitForFocus(app, timeout: 10, where: { $0 == "account-menu" }) != nil, "closing the account menu did not return the ring to the bell (focus: \(focusNote(app)))", app)
        require(app.buttons["tab-home"].isSelected, "Menu on the account menu left Home", app)
        sleep(1)
        remote.press(.select)
        require(items.firstMatch.waitForExistence(timeout: 15), "the bell did not open the account menu again", app)
        require(waitForFocus(app, timeout: 10, where: { $0.hasPrefix("account-item-") }) != nil, "the account menu opened again without the ring on an item (focus: \(focusNote(app)))", app)
        require(press(.down, app, max: 10, until: { $0 == "account-item-settings" }) != nil, "Down never reached the menu's Settings item (focus: \(focusNote(app)))", app)
        sleep(1)
        remote.press(.select)
        require(waitForGone(items.firstMatch, timeout: 10), "the Settings item did not close the account menu", app)
        require(waitUntil(timeout: 15) { app.buttons["tab-settings"].isSelected }, "the Settings item did not open Settings", app)
        require(app.staticTexts["Settings"].waitForExistence(timeout: 15), "the Settings page did not appear", app)
        require(waitForFocus(app, timeout: 10, where: { _ in true }) != nil, "the ring was lost after the Settings item closed the account menu", app)
    }

    /// `--fixtures calfail` (every month read fails after 2 s): the Calendar shows its error card
    /// (the skeleton used to stay for good), Down from the top bar through the month header reaches
    /// its Try again (a full-width focus section; device-flow pass 7), and Try again keeps the ring
    /// while the retry runs and after it fails again. Twice.
    func testCalendarFailedTryAgain() {
        let app = launch("calfail")
        waitForHome(app)
        goToBar(app)
        require(seek("tab-calendar", app), "could not walk the top bar to Calendar (focus: \(focusNote(app)))", app)
        remote.press(.select)
        let retry = app.buttons["calendar-try-again"]
        require(retry.waitForExistence(timeout: 30), "the failed Calendar did not show its error card", app)
        sleep(1)
        require(press(.down, app, max: 4, until: { $0 == "calendar-try-again" }) != nil, "Down never reached the error card's Try again (focus: \(focusNote(app)))", app)
        for round in 1...2 {
            sleep(1)
            remote.press(.select)
            let strayed = focusLeft(app, from: "calendar-try-again", within: 5)
            require(strayed == nil, "round \(round): the ring left Try again while it ran (focus: \(strayed ?? "none"))", app)
            require(retry.exists, "round \(round): the error card went away after the retry failed", app)
            require(waitForFocus(app, timeout: 5, where: { $0 == "calendar-try-again" }) != nil, "round \(round): the ring was not on Try again after the retry (focus: \(focusNote(app)))", app)
        }
    }

    /// `--fixtures kidsfail` (the kids page build fails after 2 s): the kid's page shows Try again,
    /// one Down from each item of the kids top bar reaches it (it sits at the left edge under no bar
    /// item; device-flow pass 7), and a retry that fails again keeps the ring on it.
    func testKidsFailedTryAgainReachable() {
        let app = launch("kidsfail")
        require(app.buttons["who-tile-p_fix_3"].waitForExistence(timeout: 30), "Who's watching did not appear", app)
        require(waitForFocus(app, timeout: 10, where: { $0.hasPrefix("who-tile-") }) != nil, "no profile tile took focus", app)
        require(seek("who-tile-p_fix_3", app, max: 5), "could not reach the kid profile tile (focus: \(focusNote(app)))", app)
        remote.press(.select)
        require(app.buttons["tab-kids"].waitForExistence(timeout: 30), "picking the kid profile did not open the kids shell", app)
        let retry = app.buttons["kids-try-again"]
        require(retry.waitForExistence(timeout: 30), "the failed kids page did not show Try again", app)
        sleep(1)
        let barItems: [String] = ["tab-kids", "tab-kids-play", "profile-chip"]
        for item in barItems {
            require(press(.up, app, max: 6, until: Self.inKidsBar) != nil, "Up never reached the kids top bar (focus: \(focusNote(app)))", app)
            require(seek(item, app, max: 6), "could not walk the kids bar to \(item) (focus: \(focusNote(app)))", app)
            sleep(1)
            remote.press(.down)
            require(waitForFocus(app, timeout: 5, where: { $0 == "kids-try-again" }) != nil, "one Down from \(item) did not reach Try again (focus: \(focusNote(app)))", app)
        }
        sleep(1)
        remote.press(.select)
        let strayed = focusLeft(app, from: "kids-try-again", within: 5)
        require(strayed == nil, "the ring left Try again while the retry ran (focus: \(strayed ?? "none"))", app)
        require(retry.exists, "the kids page's failure note went away after the retry failed", app)
        require(waitForFocus(app, timeout: 5, where: { $0 == "kids-try-again" }) != nil, "the ring was not on Try again after the retry (focus: \(focusNote(app)))", app)
    }
}
