import XCTest

/// Records only explicit list outcomes through the ordinary saved-list UI.
@MainActor final class ListOutcomeUITests: XCTestCase {
    func testExplicitOutcomesPersistAcrossRelaunchAndUnmarkedListStaysUnmarked() async throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        if let path = ProcessInfo.processInfo.environment["DYLD_FALLBACK_LIBRARY_PATH"] {
            app.launchEnvironment["DYLD_FALLBACK_LIBRARY_PATH"] = path
        }
        let suffix = String(UUID().uuidString.prefix(8))
        let recordedName = "UITest Outcome \(suffix)"
        let untouchedName = "UITest Unmarked \(suffix)"
        app.launch()
        defer { app.terminate() }
        openLists(in: app)
        createList(recordedName, in: app)
        createList(untouchedName, in: app)
        openList(untouchedName, in: app)
        assertOutcome("No status", in: app)
        XCTAssertEqual(app.buttons["list.recordTransaction"].label, "Record Transaction")

        // Merely opening the chooser, cancelling, or leaving the list does not
        // describe a purchase. Both lists must remain unmarked after restart.
        app.buttons["list.recordTransaction"].tap()
        XCTAssertTrue(choice("purchase", title: "Purchase", in: app).waitForExistence(timeout: 5))
        let cancel = app.buttons["Cancel"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 5)); cancel.tap()
        assertOutcome("No status", in: app)
        relaunchToLists(in: app)
        assertRow(untouchedName, outcome: "No status", in: app)
        assertRow(recordedName, outcome: "No status", in: app)
        openList(recordedName, in: app)

        // Replacing a recorded outcome is an explicit choice each time. Check
        // every transaction choice in the reopened row and detail screen.
        let outcomes = [
            (id: "purchase", title: "Purchase"),
            (id: "tradeAndPurchase", title: "Trade + Purchase"),
            (id: "trade", title: "Trade")
        ]
        for outcome in outcomes {
            let record = app.buttons["list.recordTransaction"]
            XCTAssertTrue(record.waitForExistence(timeout: 5)); record.tap()
            let selected = choice(outcome.id, title: outcome.title, in: app)
            XCTAssertTrue(selected.waitForExistence(timeout: 5)); selected.tap()
            assertOutcome(outcome.title, in: app)
            XCTAssertEqual(app.buttons["list.recordTransaction"].label, outcome.title)
            relaunchToLists(in: app)
            assertRow(recordedName, outcome: outcome.title, in: app)
            assertRow(untouchedName, outcome: "No status", in: app)
            openList(recordedName, in: app)
            assertOutcome(outcome.title, in: app)
        }

        let nothing = app.buttons["list.nothingHappened"]
        XCTAssertTrue(nothing.waitForExistence(timeout: 5)); nothing.tap()
        assertOutcome("Nothing Happened", in: app)
        XCTAssertEqual(app.buttons["list.recordTransaction"].label, "Record Transaction")
        relaunchToLists(in: app)
        assertRow(recordedName, outcome: "Nothing Happened", in: app)
        assertRow(untouchedName, outcome: "No status", in: app)
        openList(recordedName, in: app)
        assertOutcome("Nothing Happened", in: app)

        // Clearing the outcome retains the saved list and restores the original
        // unmarked state, which is distinct from explicit Nothing Happened.
        tapListOptions(in: app)
        let identifiedClear = app.buttons["list.clearOutcome"]
        let clear = identifiedClear.waitForExistence(timeout: 1)
            ? identifiedClear : app.buttons["Clear List Outcome"].firstMatch
        XCTAssertTrue(clear.waitForExistence(timeout: 5), "The physical Options tap must open Clear List Outcome. " + String(app.debugDescription.prefix(3000))); clear.tap()
        assertOutcome("No status", in: app)
        relaunchToLists(in: app)
        assertRow(recordedName, outcome: "No status", in: app)
        assertRow(untouchedName, outcome: "No status", in: app)
        openList(recordedName, in: app)
        assertOutcome("No status", in: app)
        XCTAssertEqual(app.buttons["list.recordTransaction"].label, "Record Transaction")
    }

    private func openLists(in app: XCUIApplication) {
        let open = app.buttons["home.openExistingLists"]
        XCTAssertTrue(open.waitForExistence(timeout: 10)); open.tap()
        XCTAssertTrue(app.textFields["savedLists.newName"].waitForExistence(timeout: 5))
    }

    private func createList(_ name: String, in app: XCUIApplication) {
        let input = app.textFields["savedLists.newName"]
        input.tap(); input.typeText(name + "\n")
        app.buttons["savedLists.create"].tap()
        XCTAssertTrue(row(name, in: app).waitForExistence(timeout: 5))
    }

    private func row(_ name: String, in app: XCUIApplication) -> XCUIElement {
        app.cells.containing(.staticText, identifier: name).firstMatch
    }

    private func openList(_ name: String, in app: XCUIApplication) {
        let saved = row(name, in: app)
        XCTAssertTrue(saved.waitForExistence(timeout: 5)); saved.tap()
        XCTAssertTrue(app.staticTexts["list.outcomeValue"].waitForExistence(timeout: 5))
    }

    private func assertRow(_ name: String, outcome: String, in app: XCUIApplication) {
        let saved = row(name, in: app)
        XCTAssertTrue(saved.waitForExistence(timeout: 5))
        XCTAssertTrue(saved.staticTexts[outcome].exists, "Saved list \(name) must show \(outcome)")
    }

    private func assertOutcome(_ expected: String, in app: XCUIApplication) {
        let value = app.staticTexts["list.outcomeValue"]
        XCTAssertTrue(value.waitForExistence(timeout: 5))
        let label = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", expected), object: value)
        XCTAssertEqual(XCTWaiter.wait(for: [label], timeout: 5), .completed,
                       "Expected explicit list outcome \(expected); actual: \(value.label)")
        if expected == "No status" {
            XCTAssertFalse(app.staticTexts["list.outcomeRecordedAt"].exists)
        } else {
            XCTAssertTrue(app.staticTexts["list.outcomeRecordedAt"].exists)
        }
    }

    private func choice(_ id: String, title: String, in app: XCUIApplication) -> XCUIElement {
        let identified = app.buttons["list.outcome." + id]
        if identified.waitForExistence(timeout: 1) { return identified }
        // UIKit may expose confirmation-dialog actions by title rather than
        // forwarding their SwiftUI identifier. The chosen title differs from
        // the underlying current-outcome button in each step of this test.
        return app.buttons[title].firstMatch
    }

    private func tapListOptions(in app: XCUIApplication) {
        let options = app.navigationBars.buttons["list.options"]
        XCTAssertTrue(options.waitForExistence(timeout: 5))
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND enabled == true"), object: options)
        let enabled = XCTWaiter.wait(for: [ready], timeout: 5) == .completed
        XCTAssertTrue(enabled, "List options must be enabled after navigation completes. " + optionsFailureContext(in: app))
        guard enabled else { return }
        XCTAssertEqual(app.state, .runningForeground)
        XCTAssertFalse(app.alerts.firstMatch.exists)
        XCTAssertFalse(XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch.exists)
        let bounds = options.frame, window = app.windows.firstMatch.frame
        let onScreen = bounds.width >= 44 && bounds.height >= 44 && window.contains(bounds)
        XCTAssertTrue(onScreen, "List options must be entirely on screen with a 44-point target: \(bounds), window: \(window). " + optionsFailureContext(in: app))
        guard onScreen else { return }
        // This simulator reports the enabled, fully visible Menu as non-hittable
        // and element.tap() fails AXScrollToVisible. Tap the identified control's
        // validated center, as for the existing camera Options test. The caller
        // requires the actual menu action, clear result and disk relaunch below.
        options.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    private func optionsFailureContext(in app: XCUIApplication) -> String {
        let matches = app.buttons.matching(identifier: "list.options").allElementsBoundByIndex
        let controls = matches.map {
            "label=\($0.label), frame=\($0.frame), enabled=\($0.isEnabled), hittable=\($0.isHittable)"
        }.joined(separator: "; ")
        return "App state: \(app.state.rawValue); window: \(app.windows.firstMatch.frame); "
            + "matching options: [\(controls)]; navigation bars: "
            + String(app.navigationBars.debugDescription.prefix(3500))
    }

    private func relaunchToLists(in app: XCUIApplication) {
        app.terminate(); app.launch(); openLists(in: app)
    }
}
