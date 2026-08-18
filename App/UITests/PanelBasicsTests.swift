import XCTest

/// Automates the deterministic slice of docs/manual-testing.md. Queries go
/// through PanelAccessibilityID's stable identifiers (compiled into this
/// target), never user-facing copy.
///
/// Local only: the runner needs an Accessibility grant, so these never run in
/// CI. Each launch points the app at a scratch notes file via the
/// `-PewterNotesFile` hook and suppresses onboarding, so a run never touches
/// real notes or depends on TCC state.
@MainActor
final class PanelBasicsTests: XCTestCase {
    private var app: XCUIApplication!
    private var notesFile: URL!

    override func setUp() async throws {
        continueAfterFailure = false
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "PewterUITests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        notesFile = directory.appending(path: "pewter.md")

        app = XCUIApplication()
        app.launchArguments = [
            "-PewterNotesFile", notesFile.path,
            "-onboardingDeclined", "YES",
            "-PewterShowPanelAtLaunch", "YES",
        ]
        app.launch()
    }

    override func tearDown() async throws {
        app?.terminate()
        guard let notesFile else { return }
        do {
            try FileManager.default.removeItem(at: notesFile.deletingLastPathComponent())
        } catch {
            print("scratch-dir cleanup failed: \(error)")
        }
    }

    // MARK: - Checklist: "Status-item click toggles the panel"

    func testStatusItemClickTogglesPanel() throws {
        XCTAssertTrue(
            statusItemButton.waitForExistence(timeout: 10),
            "status item should exist after launch"
        )
        try XCTSkipUnless(
            statusItemButton.isHittable,
            "status item is offscreen — a menu-bar manager (Bartender/Ice) is hiding it; check this item by hand"
        )
        openPanel()
        statusItemButton.click()
        XCTAssertTrue(
            waitForDisappearance(of: composer),
            "status-item click should hide the shown panel"
        )
        statusItemButton.click()
        XCTAssertTrue(
            composer.waitForExistence(timeout: 5),
            "second click should show it again"
        )
    }

    // MARK: - Checklist: quick-add lands in the list and the notes file

    func testQuickAddWritesNoteToFile() {
        openPanel()
        composer.click()
        app.typeText("Buy milk\r")

        XCTAssertTrue(
            noteRows.firstMatch.waitForExistence(timeout: 5),
            "added note should appear as a row"
        )
        XCTAssertTrue(
            noteRows.firstMatch.label.contains("Buy milk"),
            "the row should show the note text"
        )
        XCTAssertTrue(
            waitForNotesFile(toContain: "Buy milk"),
            "added note should reach the notes file (debounced save)"
        )
    }

    func testEmptySubmitAddsNothing() {
        openPanel()
        composer.click()
        app.typeText("Buy milk\r")
        XCTAssertEqual(waitForNoteRowCount(1), 1, "the control note should land")
        app.typeText("\r")
        usleep(1_000_000)
        XCTAssertEqual(noteRows.count, 1, "an empty submit should add no note")
    }

    // MARK: - Checklist: "Cmd+W hides the panel from … the search field, and the composer"

    func testCmdWHidesPanelFromComposer() {
        openPanel()
        composer.click()
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(
            waitForDisappearance(of: composer),
            "Cmd+W should hide the panel"
        )
    }

    func testCmdWHidesPanelFromSearch() {
        openPanel()
        composer.click()
        app.typeText("Buy milk\r")
        XCTAssertEqual(waitForNoteRowCount(1), 1, "the control note should land")
        searchField.click()
        app.typeText("zzz")
        XCTAssertEqual(waitForNoteRowCount(0), 0, "typing should reach the search field")
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(
            waitForDisappearance(of: composer),
            "Cmd+W from the search field should hide the panel"
        )
    }

    // MARK: - Checklist: search narrows the list; Esc clears the filter, then hides

    func testSearchFiltersAndEscLadder() {
        openPanel()
        composer.click()
        app.typeText("Buy milk\r")
        XCTAssertEqual(waitForNoteRowCount(1), 1, "first note should land before the second is typed")
        app.typeText("Walk the dog\r")
        XCTAssertEqual(waitForNoteRowCount(2), 2, "both notes should be listed")

        searchField.click()
        app.typeText("milk")
        XCTAssertEqual(waitForNoteRowCount(1), 1, "filter should narrow the list to the match")
        XCTAssertTrue(
            noteRows.firstMatch.label.contains("Buy milk"),
            "the surviving row should be the match, not the other note"
        )

        app.typeKey(.escape, modifierFlags: [])
        XCTAssertEqual(waitForNoteRowCount(2), 2, "Esc should clear the filter, not hide the panel")

        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(
            waitForDisappearance(of: composer),
            "Esc with no filter should hide the panel"
        )
    }

    // MARK: - Helpers

    private var statusItemButton: XCUIElement {
        app.statusItems.firstMatch
    }

    private var composer: XCUIElement {
        app.textFields[PanelAccessibilityID.composer].firstMatch
    }

    private var searchField: XCUIElement {
        app.textFields[PanelAccessibilityID.searchField].firstMatch
    }

    private var noteRows: XCUIElementQuery {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", PanelAccessibilityID.noteRowPrefix))
    }

    /// The panel is up at launch via `-PewterShowPanelAtLaunch`; this waits
    /// for it rather than clicking the status item, which a menu-bar manager
    /// can park offscreen.
    private func openPanel() {
        XCTAssertTrue(
            composer.waitForExistence(timeout: 10),
            "panel should be shown at launch by the UI-test hook"
        )
    }

    private func waitForDisappearance(of element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let gone = NSPredicate(format: "exists == false")
        let expectation = XCTNSPredicateExpectation(predicate: gone, object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    /// Row counts settle asynchronously; poll instead of asserting a snapshot.
    private func waitForNoteRowCount(_ expected: Int, timeout: TimeInterval = 5) -> Int {
        let deadline = Date(timeIntervalSinceNow: timeout)
        var count = noteRows.count
        while count != expected, Date() < deadline {
            usleep(200_000)
            count = noteRows.count
        }
        return count
    }

    private func waitForNotesFile(toContain text: String, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        var lastContents: String?
        var lastError: Error?
        while Date() < deadline {
            do {
                let contents = try String(contentsOf: notesFile, encoding: .utf8)
                lastContents = contents
                if contents.contains(text) {
                    return true
                }
            } catch {
                lastError = error
            }
            usleep(200_000)
        }
        print(
            "notes file never contained \(text); last contents: "
                + "\(lastContents ?? "<unread>"), last error: \(String(describing: lastError))"
        )
        return false
    }
}
