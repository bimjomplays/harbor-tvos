import XCTest

/// Remote-navigation checks, sixth batch: Settings' Spoilers panel persistence (proving the Slice
/// decoder fix in ef2a2eb round-trips the nested spoiler keys through a real relaunch) and the
/// Profiles editor's Kids setup (App/Sources/Profiles/ProfileEditorView.swift). The kid toggle and
/// the "PIN & sidebar locks" section only ever show for the primary profile (editing itself or
/// anyone else) or on the create form (editor-view.tsx `canEditAdvanced`/`showAdvanced`) — a
/// non-primary profile editing itself gets neither, by upstream's own design, so this batch proves
/// that for both the fixture's primary (Skipper) and its PIN-protected Guest ("1234", reached by
/// switching the active profile to it via Who's watching, since Settings' "Edit profile" only ever
/// opens `profiles.active`), and proves the positive case on the create form instead, since this
/// app has no path for the primary to open another EXISTING profile's editor. `--fixtures shell` only.
final class NavigationTests6: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private var remote: XCUIRemote { XCUIRemote.shared }

    private func launch(_ scenario: String, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--fixtures", scenario] + extra
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
    /// lands on whichever of its buttons is nearest and seeks the exact one — Down between
    /// sections does not always keep the same column. Four buttons for a non-primary active
    /// profile, five (a trailing "Manage profiles") for the primary (SettingsView.swift).
    private static func inProfilesRow(_ id: String) -> Bool {
        ["settings-switch-profile", "settings-pin-button", "settings-edit-profile", "settings-add-profile", "settings-manage-profiles"].contains(id)
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
        // The nested toggles sit below the master (run 36306455265: Right/Left never left it).
        require(seek("spoilers-thumb", app, max: 4, first: .down), "could not reach the Thumbnails toggle (focus: \(focusNote(app)))", app)
        let thumbBefore = thumb.label
        sleep(1)
        remote.press(.select)
        require(waitUntil(timeout: 5) { thumb.label != thumbBefore }, "Select on the Thumbnails toggle did not flip its label (still \"\(thumb.label)\")", app)
        sleep(1)
        remote.press(.select)
        require(waitUntil(timeout: 5) { thumb.label == thumbBefore }, "a second Select on Thumbnails did not flip it back to \"\(thumbBefore)\" (now \"\(thumb.label)\")", app)
        sleep(1)
        require(seek("spoilers-hide", app, max: 4, first: .up), "could not walk back to the master toggle (focus: \(focusNote(app)))", app)
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

    /// Profiles editor Kids setup (App/Sources/Profiles/ProfileEditorView.swift): upstream's own rule
    /// (reference/harbor/src/components/profile-picker/editor-view.tsx lines 111-113/496-500,
    /// `canEditAdvanced = activeIsPrimary`, `showAdvanced = canEditAdvanced || mode.kind === "create"`)
    /// is parental control by design — a non-primary profile editing ITSELF never gets the kid toggle
    /// or the "PIN & sidebar locks" section, only the primary (editing anyone) or the create form do.
    /// This proves both halves: editing the fixture's primary (Skipper, active by fixture) shows
    /// neither, editing the fixture's PIN-protected Guest ("1234") as itself shows neither either, and
    /// creating a brand-new profile (as Skipper, via Settings' own "Add profile") shows both, lets
    /// Kids be turned on with an age and curfew pick, and Save creates it (checked via the Profiles
    /// row's own count text — there is no UI path on this TV for the primary to open ANOTHER existing
    /// profile's editor to prove the positive case there instead; tracked in docs/parity-gaps.md).
    /// The created profile needs no cleanup: `Fixtures.installIfRequested`
    /// (App/Sources/App/Fixtures.swift) calls `profiles.reset()` (wipes `KeyValueStore`/`Prefs`) then
    /// `installFixture(...)` (sets the roster in memory without persisting) on every `--fixtures
    /// shell` launch, so nothing created here survives to the next one — confirmed by reading
    /// `ProfilesStore.reset()`/`installFixture()` directly rather than assumed.
    func testKidsProfileEditorSetup() {
        let app = launch("shell", extra: ["--new-profile-name", "Kid test"])
        waitForHome(app)
        openSettings(app)
        openProfilesRow(app)

        // Editing the primary (Skipper, active by fixture) itself: never gets the kid toggle.
        sleep(1)
        require(seek("settings-edit-profile", app, max: 4), "could not reach Edit profile from Switch profile (focus: \(focusNote(app)))", app)
        sleep(1)
        remote.press(.select)
        require(app.staticTexts["Edit profile"].waitForExistence(timeout: 15), "Edit profile did not open for Skipper", app)
        require(!app.buttons["profile-kid-toggle"].exists, "the kid toggle shows while editing the primary profile Skipper", app)
        sleep(1)
        remote.press(.menu)
        require(waitForGone(app.staticTexts["Edit profile"], timeout: 10), "Menu did not close Skipper's editor", app)

        // Create (Add profile), still as Skipper: upstream's other showAdvanced path
        // (`mode.kind === "create"`) — shows both the kid toggle and the locks section.
        openProfilesRow(app)
        sleep(1)
        require(seek("settings-add-profile", app, max: 6), "could not reach Add profile from Switch profile (focus: \(focusNote(app)))", app)
        sleep(1)
        remote.press(.select)
        require(app.staticTexts["New profile"].waitForExistence(timeout: 15), "Add profile did not open the create form", app)
        require(app.buttons["profile-kid-toggle"].waitForExistence(timeout: 10), "the kid toggle is missing on the create form", app)
        require(app.staticTexts["PIN & sidebar locks"].waitForExistence(timeout: 10), "the PIN & sidebar locks section is missing on the create form", app)

        // Name is required (Save is disabled while it's empty): XCUITest cannot type into a tvOS
        // TextField without the system keyboard up, so the launch seeded it (`--new-profile-name`,
        // Fixtures.newProfileName, the way `--query` seeds Search).
        require(app.descendants(matching: .any)["profile-name-field"].waitForExistence(timeout: 10), "the Name field is missing on the create form", app)
        sleep(1)

        let kidToggle = app.buttons["profile-kid-toggle"]
        require(press(.down, app, max: 8, until: { $0 == "profile-kid-toggle" }) != nil, "Down never reached the kid toggle (focus: \(focusNote(app)))", app)
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
        require(waitForGone(app.staticTexts["New profile"], timeout: 15), "Save did not close the create form", app)
        let count4 = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] %@", "4 profiles on this account"))
        require(count4.firstMatch.waitForExistence(timeout: 10), "the Profiles row did not read 4 profiles after Save created one", app)

        // A non-primary profile editing ITSELF (Guest, PIN "1234") also never gets the kid toggle or
        // the locks section — same upstream rule; switch the active profile to Guest via Who's
        // watching first, since Settings' "Edit profile" only ever opens `profiles.active` and this
        // app has no path for the primary to open ANOTHER profile's editor without switching to it
        // (tracked in docs/parity-gaps.md).
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
        // After a profile switch Home comes back with the ring on the bar, not a card (run
        // 36306455265: "tab-home"); either is fine, goToBar copes with both.
        require(app.buttons["tile-trending-0"].waitForExistence(timeout: 30), "fixture Home rows never appeared after the profile switch", app)
        require(waitForFocus(app, timeout: 20, where: { Self.isHomeCard($0) || Self.inBar($0) }) != nil, "Home never seeded focus after the profile switch (focus: \(focusNote(app)))", app)
        openSettings(app)
        openProfilesRow(app)
        sleep(1)
        require(seek("settings-edit-profile", app, max: 4), "could not reach Edit profile from Switch profile for Guest (focus: \(focusNote(app)))", app)
        sleep(1)
        remote.press(.select)
        require(app.staticTexts["Edit profile"].waitForExistence(timeout: 15), "Edit profile did not open for Guest", app)
        require(!app.buttons["profile-kid-toggle"].exists, "the kid toggle shows while Guest edits itself (upstream: only the primary, or Create)", app)
        require(!app.staticTexts["PIN & sidebar locks"].exists, "the PIN & sidebar locks section shows while Guest edits itself", app)
        sleep(1)
        remote.press(.menu)
        require(waitForGone(app.staticTexts["Edit profile"], timeout: 10), "Menu did not close Guest's editor", app)
    }

    /// Manage profiles (Settings/SettingsView.swift's Profiles row → Profiles/ManageProfilesView.swift):
    /// editor-view.tsx `canEditAdvanced = activeIsPrimary` and picker-modal.tsx `ListView`'s
    /// `canEditThis = isPrimary || own` let the primary open any profile's own editor. Unlike
    /// testKidsProfileEditorSetup above, the fixture's primary (Skipper) is already active, so this
    /// test never switches profiles: it opens Manage profiles straight from the Profiles row, picks
    /// the PIN-protected Guest ("p_fix_2") from the list it shows, and checks that Guest's own kid
    /// toggle and "PIN & sidebar locks" section are reachable — both hidden when the primary edits
    /// itself, both open here because the *active* profile, not the one being edited, is primary.
    /// Backs out with Menu (editor, then the panel) rather than Save, so no fixture profile changes.
    func testManageProfilesOpensGuestEditor() {
        let app = launch("shell")
        waitForHome(app)
        openSettings(app)
        openProfilesRow(app)
        require(seek("settings-manage-profiles", app, max: 5), "could not reach Manage profiles from Switch profile (focus: \(focusNote(app)))", app)
        remote.press(.select)
        require(app.staticTexts["Manage profiles"].waitForExistence(timeout: 15), "Manage profiles did not open", app)
        let guestRow = app.buttons["manage-profile-p_fix_2"]
        require(guestRow.waitForExistence(timeout: 10), "Guest's row is missing from Manage profiles", app)
        require(seek("manage-profile-p_fix_2", app, max: 6, first: .down), "could not reach Guest's row in Manage profiles (focus: \(focusNote(app)))", app)
        remote.press(.select)
        require(app.staticTexts["Edit profile"].waitForExistence(timeout: 15), "Select on Guest's row in Manage profiles did not open its editor", app)
        require(app.buttons["profile-kid-toggle"].waitForExistence(timeout: 10), "the kid toggle is missing while the primary edits Guest through Manage profiles", app)
        require(app.staticTexts["PIN & sidebar locks"].waitForExistence(timeout: 10), "Guest's PIN & sidebar locks section is missing while the primary edits it through Manage profiles", app)
        remote.press(.menu)
        require(waitForGone(app.staticTexts["Edit profile"], timeout: 10), "Menu did not close Guest's editor back to Manage profiles", app)
        require(guestRow.waitForExistence(timeout: 10), "Manage profiles did not return after closing Guest's editor", app)
        remote.press(.menu)
        require(waitForGone(app.staticTexts["Manage profiles"], timeout: 10), "Menu did not close the Manage profiles panel", app)
    }
}
