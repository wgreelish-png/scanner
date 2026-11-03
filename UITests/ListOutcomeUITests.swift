import XCTest

/// Records only explicit list outcomes through the ordinary saved-list UI.
@MainActor final class ListOutcomeUITests: XCTestCase {
    func testTransactionReviewDoesNotRecordUntilConfirmedAndNothingHappenedPersists() async throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        if let path = ProcessInfo.processInfo.environment["DYLD_FALLBACK_LIBRARY_PATH"] {
            app.launchEnvironment["DYLD_FALLBACK_LIBRARY_PATH"] = path
        }
        let suffix = String(UUID().uuidString.prefix(8))
        let recordedName = "UITest Outcome \(suffix)"
        let untouchedName = "UITest Unmarked \(suffix)"
        app.launchArguments = ["-autoDatabaseUpdates", "NO", "-betaAutomaticIPAllowlist", "NO"]
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
        _ = UITestInteraction.tap(app.buttons["list.recordTransaction"], in: app)
        XCTAssertTrue(choice("purchase", title: "Purchase", in: app).waitForExistence(timeout: 5))
        let cancel = app.buttons["Cancel"].firstMatch
        _ = UITestInteraction.tap(cancel, in: app)
        assertOutcome("No status", in: app)
        relaunchToLists(in: app)
        assertRow(untouchedName, outcome: "No status", in: app)
        assertRow(recordedName, outcome: "No status", in: app)
        openList(recordedName, in: app)

        // A transaction type opens review. Cancelling an incomplete deal never
        // moves inventory/cash or labels an empty list as a completed purchase.
        let choices = [
            (id: "purchase", title: "Purchase", screen: "Record Purchase"),
            (id: "tradeAndPurchase", title: "Trade + Cash to Customer", screen: "Record Trade + Pay Customer"),
            (id: "trade", title: "Trade", screen: "Record Trade")
        ]
        for selected in choices {
            _ = UITestInteraction.tap(app.buttons["list.recordTransaction"], in: app)
            let action = choice(selected.id, title: selected.title, in: app)
            _ = UITestInteraction.tap(action, in: app)
            XCTAssertTrue(app.navigationBars[selected.screen].waitForExistence(timeout: 5))
            _ = UITestInteraction.tapToolbar(app.buttons["Cancel"].firstMatch, in: app)
            assertOutcome("No status", in: app)
        }
        relaunchToLists(in: app)
        assertRow(recordedName, outcome: "No status", in: app)
        assertRow(untouchedName, outcome: "No status", in: app)
        openList(recordedName, in: app)

        let sections = app.segmentedControls["list.section"]
        XCTAssertTrue(sections.waitForExistence(timeout: 5))
        _ = UITestInteraction.tap(sections.buttons["Offer"], in: app)
        let nothing = app.buttons["list.nothingHappened"]
        _ = UITestInteraction.tap(nothing, in: app)
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
        XCTAssertTrue(clear.waitForExistence(timeout: 5), "List options must open Clear List Outcome.")
        _ = UITestInteraction.tap(clear, in: app)
        assertOutcome("No status", in: app)
        relaunchToLists(in: app)
        assertRow(recordedName, outcome: "No status", in: app)
        assertRow(untouchedName, outcome: "No status", in: app)
        openList(recordedName, in: app)
        assertOutcome("No status", in: app)
        XCTAssertEqual(app.buttons["list.recordTransaction"].label, "Record Transaction")
    }

    private func openLists(in app: XCUIApplication) {
        let open = app.tabBars.buttons["Lists"]
        XCTAssertTrue(open.waitForExistence(timeout: 10))
        _ = UITestInteraction.tapToolbar(open, in: app)
        XCTAssertTrue(app.navigationBars["My Lists"].waitForExistence(timeout: 5))
    }

    private func createList(_ name: String, in app: XCUIApplication) {
        _ = UITestInteraction.tapToolbar(app.buttons["savedLists.newList"], in: app)
        let input = app.textFields["savedLists.newName"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        _ = UITestInteraction.tap(input, in: app); input.typeText(name + "\n")
        _ = UITestInteraction.tapToolbar(app.buttons["savedLists.create"], in: app)
        XCTAssertTrue(row(name, in: app).waitForExistence(timeout: 5))
    }

    private func row(_ name: String, in app: XCUIApplication) -> XCUIElement {
        app.cells.containing(.staticText, identifier: name).firstMatch
    }

    private func openList(_ name: String, in app: XCUIApplication) {
        let saved = row(name, in: app)
        XCTAssertTrue(saved.waitForExistence(timeout: 5))
        _ = UITestInteraction.tap(saved, in: app, identifier: "savedList.row")
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

    private func tapListOptions(in app: XCUIApplication,
                                file: StaticString = #filePath, line: UInt = #line) {
        let options = app.navigationBars.buttons["list.options"]
        XCTAssertTrue(options.waitForExistence(timeout: 5), file: file, line: line)
        guard options.exists else { return }
        XCTAssertEqual(app.state, .runningForeground, file: file, line: line)
        XCTAssertFalse(app.alerts.firstMatch.exists, file: file, line: line)
        XCTAssertFalse(XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch.exists,
                       file: file, line: line)
        let bounds = options.frame, window = app.windows.firstMatch.frame
        XCTAssertTrue(bounds.width >= 44 && bounds.height >= 44 && window.contains(bounds),
                      "List options must remain a fully visible 44-point target; frame: \(bounds), window: \(window)",
                      file: file, line: line)
        _ = UITestInteraction.tapToolbar(options, in: app, file: file, line: line)
    }

    private func relaunchToLists(in app: XCUIApplication) {
        app.terminate(); app.launch(); openLists(in: app)
    }
}
