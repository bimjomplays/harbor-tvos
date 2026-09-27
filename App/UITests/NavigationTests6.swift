import XCTest

/// Remote-navigation checks, sixth batch: Settings' Spoilers panel persistence (proving the Slice
/// decoder fix in ef2a2eb round-trips the nested spoiler keys through a real relaunch) and the
/// Profiles editor's Kids setup (App/Sources/Profiles/ProfileEditorView.swift). The kid toggle,
/// age pills and curfew pills only ever appear when editing a profile that is not the primary one;
/// this app's only path to a non-primary profile's own editor is to switch the active profile to it
/// first (Settings' "Edit profile" always opens `profiles.active`), so this batch also switches to
/// the fixture's PIN-protected Guest profile along the way. `--fixtures shell` only.
final class NavigationTests6: XCTestCase {
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

    /// Walks the top bar to Settings and opens it (as testSpoilersMasterToggleAndMenu does).
    private func openSettings(_ app: XCUIApplication) {
        goToBar(app)
        require(seek("tab-settings", app), "could not walk the top bar to Settings (focus: \(focusNote(app)))", app)
        remote.press(.select)
        require(app.staticTexts["Settings"].waitForExistence(timeout: 15), "Settings did not open", app)
    }

    /// The Profiles section's own row is far down the Settings page; every visit walks Down to it
    /// from wherever the ring currently is (the top of a fresh page, or already on that row), then
    /// lands on whichever of its four buttons is nearest and seeks the exact one — Down between
    /// sections does not always keep the same column.
    private static func inProfilesRow(_ id: String) -> Bool {
        ["settings-switch-profile", "settings-pin-button", "settings-edit-profile", "settings-add-profile"].contains(id)
    }

    private func openProfilesRow(_ app: XCUIApplication) {
        require(press(.down, app, max: 200, until: Self.inProfilesRow) != nil,
                "Down never reached the Profiles row (focus: \(focusNote(app)))", app)
        require(seek("settings-switch-profile", app, max: 4), "could not reach Switch profile within the Profiles row (focus: \(focusNote(app)))", app)
    }

    // MARK: tests

    /// Settings → Spoilers (App/Sources/Settings/SpoilersPanel.swift), reached the same way as
    /// NavigationTests5.testSpoilersMasterToggleAndMenu: this proves the persistence path the Slice
    /// decoder fix in ef2a2eb added (the nested spoiler keys now round-trip through the engine), so
    /// it does not repeat that test's own assertions beyond reaching the panel. The master shows and
    /// hides the nested toggles as before, one nested toggle flips (and is flipped back, so only the
    /// master's own state is left changed), and then a real relaunch of the same fixture proves the
    /// master's "On" survived the round trip through UserDefaults/engine storage before it is turned
    /// back off so later tests start clean.
    func testSpoilersNestedTogglesAndPersistence() {
        var app = launch("shell")
        waitForHome(app)
        openSettings(app)
        var master = app.buttons["spoilers-hide"]
        require(master.waitForExistence(timeout: 20), "the Spoilers panel's master toggle never appeared", app)
        require(press(.down, app, max: 60, until: { $0 == "spoilers-hide" }) != nil, "Down never reached the Spoilers panel (focus: \(focusNote(app)))", app)
        require(master.label == "Blur spoilers: Off", "Blur spoilers did not start Off on a fresh fixture launch (was \"\(master.label)\")", app)
        sleep(1)
        remote.press(.select)
        require(waitUntil(timeout: 5) { master.label == "Blur spoilers: On" }, "Select on Blur spoilers did not turn it on (now \"\(master.label)\")", app)
        let thumb = app.buttons["spoilers-thumb"]
        require(thumb.waitForExistence(timeout: 5), "turning Blur spoilers on did not show the nested toggles", app)
        sleep(1)
        require(seek("spoilers-thumb", app, max: 4), "could not reach the Thumbnails toggle (focus: \(focusNote(app)))", app)
        let thumbBefore = thumb.label
        sleep(1)
        remote.press(.select)
        require(waitUntil(timeout: 5) { thumb.label != thumbBefore }, "Select on the Thumbnails toggle did not flip its label (still \"\(thumb.label)\")", app)
        sleep(1)
        remote.press(.select)
        require(waitUntil(timeout: 5) { thumb.label == thumbBefore }, "a second Select on Thumbnails did not flip it back to \"\(thumbBefore)\" (now \"\(thumb.label)\")", app)
        sleep(1)
        require(seek("spoilers-hide", app, max: 4), "could not walk back to the master toggle (focus: \(focusNote(app)))", app)
        sleep(1)
        remote.press(.select)
        require(waitUntil(timeout: 5) { master.label == "Blur spoilers: Off" }, "Select on Blur spoilers did not turn it off again (now \"\(master.label)\")", app)
        require(!thumb.exists, "turning Blur spoilers off again left the nested toggles up", app)
        sleep(1)
        // Leave it On for the relaunch check below (default is Off, so seeing it back on is the proof).
        remote.press(.select)
        require(waitUntil(timeout: 5) { master.label == "Blur spoilers: On" }, "Select on Blur spoilers did not turn it back on before the relaunch check (now \"\(master.label)\")", app)

        app.terminate()
        app = launch("shell")
        waitForHome(app)
        openSettings(app)
        master = app.buttons["spoilers-hide"]
        require(master.waitForExistence(timeout: 20), "the Spoilers panel's master toggle never appeared after relaunch", app)
        require(press(.down, app, max: 60, until: { $0 == "spoilers-hide" }) != nil, "Down never reached the Spoilers panel after relaunch (focus: \(focusNote(app)))", app)
        require(master.label == "Blur spoilers: On", "Blur spoilers did not persist across a relaunch (now \"\(master.label)\")", app)
        sleep(1)
        remote.press(.select)
        require(waitUntil(timeout: 5) { master.label == "Blur spoilers: Off" }, "could not turn Blur spoilers back off after the relaunch check (now \"\(master.label)\")", app)
    }

    /// Profiles editor Kids setup (App/Sources/Profiles/ProfileEditorView.swift): the kid toggle only
    /// shows for a non-primary profile, and Settings' "Edit profile" always opens `profiles.active`,
    /// so the fixture's primary (Skipper) proves the negative and the PIN-protected Guest ("1234")
    /// is made active to prove the positive. Turning Kids on shows the age and curfew pills and hides
    /// the "PIN & sidebar locks" section; Save commits the picks, and reopening the editor (still the
    /// same Settings visit, no relaunch needed) shows them unchanged. Kids is turned back off and
    /// saved at the end so Guest is clean for later tests (each `--fixtures shell` launch actually
    /// reinstalls the three fixture profiles from scratch anyway — Fixtures.installIfRequested calls
    /// `profiles.reset()` first — but this also leaves the profile clean within this one run).
    func testKidsProfileEditorSetup() {
        let app = launch("shell")
        waitForHome(app)
        openSettings(app)
        openProfilesRow(app)
        sleep(1)
        require(seek("settings-edit-profile", app, max: 4), "could not reach Edit profile from Switch profile (focus: \(focusNote(app)))", app)
        sleep(1)
        remote.press(.select)
        require(app.staticTexts["Edit profile"].waitForExistence(timeout: 15), "Edit profile did not open for Skipper", app)
        require(!app.buttons["profile-kid-toggle"].exists, "the kid toggle shows while editing the primary profile Skipper", app)
        sleep(1)
        remote.press(.menu)
        require(waitForGone(app.staticTexts["Edit profile"], timeout: 10), "Menu did not close Skipper's editor", app)

        // Switch the active profile to Guest: the only way this app's Settings reaches a non-primary
        // profile's own editor.
        openProfilesRow(app)
        sleep(1)
        remote.press(.select)
        require(app.buttons["who-tile-p_fix_2"].waitForExistence(timeout: 20), "Switch profile did not open Who's watching", app)
        require(waitForFocus(app, timeout: 10, where: { $0.hasPrefix("who-tile-") }) != nil, "no profile tile took focus", app)
        require(seek("who-tile-p_fix_2", app, max: 5), "could not reach the Guest profile tile (focus: \(focusNote(app)))", app)
        sleep(1)
        remote.press(.select)
        let key1 = app.buttons["pin-key-1"]
        require(key1.waitForExistence(timeout: 15), "picking Guest did not open its PIN pad", app)
        require(waitForFocus(app, timeout: 10, where: { $0 == "pin-key-1" }) != nil, "the PIN pad did not seed its first key (focus: \(focusNote(app)))", app)
        // Guest's fixture PIN is "1234"; the keypad is a 3-column grid (1 2 3 / 4 5 6 / 7 8 9 / ⌫ 0 ‹).
        sleep(1)
        remote.press(.select) // "1"
        sleep(1)
        remote.press(.right)
        require(waitForFocus(app, timeout: 5, where: { $0 == "pin-key-2" }) != nil, "Right from 1 did not reach 2 (focus: \(focusNote(app)))", app)
        sleep(1)
        remote.press(.select) // "2"
        sleep(1)
        remote.press(.right)
        require(waitForFocus(app, timeout: 5, where: { $0 == "pin-key-3" }) != nil, "Right from 2 did not reach 3 (focus: \(focusNote(app)))", app)
        sleep(1)
        remote.press(.select) // "3"
        sleep(1)
        remote.press(.down)
        require(waitForFocus(app, timeout: 5, where: { $0 == "pin-key-6" }) != nil, "Down from 3 did not reach 6 (focus: \(focusNote(app)))", app)
        sleep(1)
        remote.press(.left)
        require(waitForFocus(app, timeout: 5, where: { $0 == "pin-key-5" }) != nil, "Left from 6 did not reach 5 (focus: \(focusNote(app)))", app)
        sleep(1)
        remote.press(.left)
        require(waitForFocus(app, timeout: 5, where: { $0 == "pin-key-4" }) != nil, "Left from 5 did not reach 4 (focus: \(focusNote(app)))", app)
        sleep(1)
        remote.press(.select) // "4" completes "1234"
        require(waitForGone(key1, timeout: 10), "the correct PIN did not close the PIN pad", app)
        waitForHome(app)
        openSettings(app)
        openProfilesRow(app)
        sleep(1)
        require(seek("settings-edit-profile", app, max: 4), "could not reach Edit profile from Switch profile for Guest (focus: \(focusNote(app)))", app)
        sleep(1)
        remote.press(.select)
        require(app.staticTexts["Edit profile"].waitForExistence(timeout: 15), "Edit profile did not open for Guest", app)
        let kidToggle = app.buttons["profile-kid-toggle"]
        require(kidToggle.waitForExistence(timeout: 15), "the kid toggle is missing while editing the non-primary profile Guest", app)
        require(app.staticTexts["PIN & sidebar locks"].waitForExistence(timeout: 10), "Guest's own PIN & sidebar locks section never appeared", app)
        require(press(.down, app, max: 6, until: { $0 == "profile-kid-toggle" }) != nil, "Down never reached the kid toggle (focus: \(focusNote(app)))", app)
        sleep(1)
        remote.press(.select)
        require(waitUntil(timeout: 5) { kidToggle.label == "On" }, "Select on the kid toggle did not turn Kids on (now \"\(kidToggle.label)\")", app)
        require(app.buttons["profile-kid-age-7"].waitForExistence(timeout: 10), "turning Kids on did not show the age pills", app)
        require(app.buttons["profile-kid-curfew-none"].waitForExistence(timeout: 5), "turning Kids on did not show the curfew pills", app)
        require(waitForGone(app.staticTexts["PIN & sidebar locks"], timeout: 10), "turning Kids on did not hide the PIN & sidebar locks section", app)
        sleep(1)
        // The toggle sits at the right edge of its row (a trailing Spacer pushes it there), so Down
        // may not land on the age row's own leftmost pill: match any age pill first, then seek the
        // exact one — same for the curfew row and the final Save/Cancel row below.
        require(press(.down, app, max: 8, until: { $0.hasPrefix("profile-kid-age-") }) != nil, "Down never reached the age pills (focus: \(focusNote(app)))", app)
        require(seek("profile-kid-age-7", app, max: 6), "could not reach the age 7 pill (focus: \(focusNote(app)))", app)
        sleep(1)
        remote.press(.select)
        require(waitUntil(timeout: 5) { app.buttons["profile-kid-age-7"].isSelected }, "Select on the age 7 pill did not select it", app)
        sleep(1)
        require(press(.down, app, max: 8, until: { $0.hasPrefix("profile-kid-curfew-") }) != nil, "Down never reached the curfew pills (focus: \(focusNote(app)))", app)
        require(seek("profile-kid-curfew-60", app, max: 6), "could not reach the 1 hour curfew pill (focus: \(focusNote(app)))", app)
        sleep(1)
        remote.press(.select)
        require(waitUntil(timeout: 5) { app.buttons["profile-kid-curfew-60"].isSelected }, "Select on the 1 hour curfew pill did not select it", app)
        sleep(1)
        // Past the (unfocusable) parent PIN field and the avatar catalog to the form's Save/Cancel
        // row; Down may land on either button in it, so seek recovers if it is Cancel.
        require(press(.down, app, max: 120, until: { $0 == "profile-save" || $0 == "profile-cancel" }) != nil, "Down never reached the Save/Cancel row (focus: \(focusNote(app)))", app)
        require(seek("profile-save", app, max: 3), "could not reach Save from the Save/Cancel row (focus: \(focusNote(app)))", app)
        sleep(1)
        remote.press(.select)
        require(waitForGone(app.staticTexts["Edit profile"], timeout: 15), "Save did not close the editor", app)

        // Reopen (same Settings visit, no relaunch): the picks and the master toggle must have
        // survived the round trip through ProfilesStore.setKid.
        openProfilesRow(app)
        sleep(1)
        require(seek("settings-edit-profile", app, max: 4), "could not reach Edit profile to reopen Guest (focus: \(focusNote(app)))", app)
        sleep(1)
        remote.press(.select)
        require(app.staticTexts["Edit profile"].waitForExistence(timeout: 15), "Edit profile did not reopen for Guest", app)
        let reopenedToggle = app.buttons["profile-kid-toggle"]
        require(waitUntil(timeout: 10) { reopenedToggle.label == "On" }, "Kids did not read On on reopen (now \"\(reopenedToggle.label)\")", app)
        require(app.buttons["profile-kid-age-7"].isSelected, "age 7 was not still picked on reopen", app)
        require(app.buttons["profile-kid-curfew-60"].isSelected, "the 1 hour curfew was not still picked on reopen", app)

        // Turn Kids back off and save, so Guest is clean for later tests.
        require(press(.down, app, max: 6, until: { $0 == "profile-kid-toggle" }) != nil, "Down never reached the kid toggle again (focus: \(focusNote(app)))", app)
        sleep(1)
        remote.press(.select)
        require(waitUntil(timeout: 5) { reopenedToggle.label == "Off" }, "Select on the kid toggle did not turn Kids back off (now \"\(reopenedToggle.label)\")", app)
        sleep(1)
        // Kids is off again, so this Down instead crosses the (now visible) PIN & sidebar locks
        // section before the avatar catalog and the Save/Cancel row.
        require(press(.down, app, max: 120, until: { $0 == "profile-save" || $0 == "profile-cancel" }) != nil, "Down never reached the Save/Cancel row again (focus: \(focusNote(app)))", app)
        require(seek("profile-save", app, max: 3), "could not reach Save again from the Save/Cancel row (focus: \(focusNote(app)))", app)
        sleep(1)
        remote.press(.select)
        require(waitForGone(app.staticTexts["Edit profile"], timeout: 15), "Save did not close the editor after turning Kids off", app)
    }
}
