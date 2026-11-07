import XCTest

@MainActor final class ShowBudgetUITests: XCTestCase {
    func testGrossSaleFeesPurchaseAndRelaunchPreserveBuyingAndPersonalFunds() async throws {
        continueAfterFailure = false
        let app = launch()
        defer { app.terminate() }
        tapVisible(app.buttons["budget.setup"], in: app)
        enter("300", into: app.textFields["budget.starting"], in: app)
        _ = UITestInteraction.tapToolbar(app.buttons["budget.keyboardDone"], in: app)
        XCTAssertTrue(app.descendants(matching: .any)["budget.startDate"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["budget.endDate"].exists)
        tapVisible(app.buttons["budget.create"], in: app)
        assertMoney("$300.00", title: "Available to buy", element: app.staticTexts["budget.available"])
        assertMoney("$300.00", title: "Starting cash on hand", element: app.staticTexts["budget.startingCash"])
        assertMoney("$300.00", title: "Cash on hand", element: app.staticTexts["budget.cashOnHand"])
        let dates = app.staticTexts["budget.showDates"]
        _ = UITestInteraction.reveal(dates, in: app)
        XCTAssertTrue(dates.waitForExistence(timeout: 5))
        let showDates = dates.label
        let status = app.staticTexts["budget.scheduleStatus"]
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertTrue(["Active today", "Status, Active today"].contains(status.label))
        let sell = app.buttons["budget.sell"]
        guard UITestInteraction.reveal(sell, in: app) else { return }
        XCTAssertTrue(sell.isEnabled)

        tapVisible(app.buttons["budget.sell"], in: app)
        enter("200", into: app.textFields["budget.amount"], in: app)
        enter("10", into: app.textFields["budget.fees"], in: app)
        _ = UITestInteraction.tapToolbar(app.buttons["budget.keyboardDone"], in: app)
        tapVisible(app.buttons["budget.record"], in: app)
        assertMoney("$420.00", title: "Available to buy", element: app.staticTexts["budget.available"])
        assertMoney("$70.00", title: "Saved for you", element: app.staticTexts["budget.saved"])
        assertMoney("$490.00", title: "Cash on hand", element: app.staticTexts["budget.cashOnHand"])

        tapVisible(app.buttons["budget.buy"], in: app)
        enter("100", into: app.textFields["budget.amount"], in: app)
        _ = UITestInteraction.tapToolbar(app.buttons["budget.keyboardDone"], in: app)
        tapVisible(app.buttons["budget.record"], in: app)
        assertMoney("$320.00", title: "Available to buy", element: app.staticTexts["budget.available"])
        assertMoney("$70.00", title: "Saved for you", element: app.staticTexts["budget.saved"])
        assertMoney("$390.00", title: "Cash on hand", element: app.staticTexts["budget.cashOnHand"])
        let entryIDs = historyEntryIDs(in: app)

        app.terminate(); app.launch()
        _ = UITestInteraction.reveal(app.staticTexts["budget.showDates"], in: app)
        XCTAssertTrue(app.staticTexts["budget.showDates"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["budget.showDates"].label, showDates)
        XCTAssertTrue(["Active today", "Status, Active today"].contains(app.staticTexts["budget.scheduleStatus"].label))
        assertMoney("$320.00", title: "Available to buy", element: app.staticTexts["budget.available"])
        assertMoney("$70.00", title: "Saved for you", element: app.staticTexts["budget.saved"])
        assertMoney("$300.00", title: "Starting cash on hand", element: app.staticTexts["budget.startingCash"])
        assertMoney("$390.00", title: "Cash on hand", element: app.staticTexts["budget.cashOnHand"])
        XCTAssertEqual(historyEntryIDs(in: app), entryIDs,
                       "Both recorded entries persist across relaunch")
        XCTAssertFalse(app.alerts.firstMatch.exists)
    }

    func testEditingStartingCashPreservesRecordedHistoryAndPersonalFundsAcrossRelaunch() {
        continueAfterFailure = false
        // Recording through the sale/purchase UI is covered above. This case
        // starts with isolated, persisted history to bound the edit scenario.
        let app = launch(arguments: ["--budget-history-fixture"])
        defer { app.terminate() }
        assertMoney("$300.00", title: "Starting cash on hand", element: app.staticTexts["budget.startingCash"])
        assertMoney("$390.00", title: "Cash on hand", element: app.staticTexts["budget.cashOnHand"])
        assertMoney("$320.00", title: "Available to buy", element: app.staticTexts["budget.available"])
        assertMoney("$70.00", title: "Saved for you", element: app.staticTexts["budget.saved"])
        let dates = app.staticTexts["budget.showDates"]
        _ = UITestInteraction.reveal(dates, in: app, towardTopWhenMissing: true)
        XCTAssertTrue(dates.waitForExistence(timeout: 5))
        let showDates = dates.label
        XCTAssertTrue(["Active today", "Status, Active today"].contains(app.staticTexts["budget.scheduleStatus"].label))
        let entryIDs = historyEntryIDs(in: app)
        guard UITestInteraction.reveal(app.buttons["budget.editStartingCash"], in: app,
                                       towardTopWhenMissing: true) else { return }

        tapVisible(app.buttons["budget.editStartingCash"], in: app)
        enter("400", into: app.textFields["budget.starting"], in: app)
        _ = UITestInteraction.tapToolbar(app.buttons["budget.keyboardDone"], in: app)
        tapVisible(app.buttons["budget.cancelStartingCash"], in: app)
        assertMoney("$300.00", title: "Starting cash on hand", element: app.staticTexts["budget.startingCash"])
        assertMoney("$390.00", title: "Cash on hand", element: app.staticTexts["budget.cashOnHand"])
        assertMoney("$320.00", title: "Available to buy", element: app.staticTexts["budget.available"])
        assertMoney("$70.00", title: "Saved for you", element: app.staticTexts["budget.saved"])

        tapVisible(app.buttons["budget.editStartingCash"], in: app)
        enter("400", into: app.textFields["budget.starting"], in: app)
        _ = UITestInteraction.tapToolbar(app.buttons["budget.keyboardDone"], in: app)
        tapVisible(app.buttons["budget.saveStartingCash"], in: app)
        assertMoney("$400.00", title: "Starting cash on hand", element: app.staticTexts["budget.startingCash"])
        assertMoney("$490.00", title: "Cash on hand", element: app.staticTexts["budget.cashOnHand"])
        assertMoney("$420.00", title: "Available to buy", element: app.staticTexts["budget.available"])
        assertMoney("$70.00", title: "Saved for you", element: app.staticTexts["budget.saved"])

        app.terminate(); app.launch()
        _ = UITestInteraction.reveal(app.staticTexts["budget.showDates"], in: app)
        XCTAssertTrue(app.staticTexts["budget.showDates"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["budget.showDates"].label, showDates)
        XCTAssertTrue(["Active today", "Status, Active today"].contains(app.staticTexts["budget.scheduleStatus"].label))
        assertMoney("$400.00", title: "Starting cash on hand", element: app.staticTexts["budget.startingCash"])
        assertMoney("$490.00", title: "Cash on hand", element: app.staticTexts["budget.cashOnHand"])
        assertMoney("$420.00", title: "Available to buy", element: app.staticTexts["budget.available"])
        assertMoney("$70.00", title: "Saved for you", element: app.staticTexts["budget.saved"])
        XCTAssertEqual(historyEntryIDs(in: app), entryIDs,
                       "Changing starting cash preserves both the sale and purchase records")
        XCTAssertFalse(app.alerts.firstMatch.exists)
    }

    private func launch(arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        if let path = ProcessInfo.processInfo.environment["DYLD_FALLBACK_LIBRARY_PATH"] {
            app.launchEnvironment["DYLD_FALLBACK_LIBRARY_PATH"] = path
        }
        app.launchArguments = ["-autoDatabaseUpdates", "NO", "-betaAutomaticIPAllowlist", "NO",
                               "--uitest-show-budget", "--budget-test-id", UUID().uuidString] + arguments
        app.launch()
        return app
    }

    private func historyEntryIDs(in app: XCUIApplication, file: StaticString = #filePath,
                                 line: UInt = #line) -> [String] {
        let entries = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "budget.entry."))
        // History is lazy; materialize the expected second row before counting.
        guard UITestInteraction.reveal(entries.element(boundBy: 1), in: app,
                                       file: file, line: line) else { return [] }
        let identifiers = entries.allElementsBoundByIndex.map(\.identifier).sorted()
        XCTAssertEqual(identifiers.count, 2, file: file, line: line)
        return identifiers
    }

    private func enter(_ value: String, into field: XCUIElement, in app: XCUIApplication,
                       file: StaticString = #filePath, line: UInt = #line) {
        guard UITestInteraction.tap(field, in: app, file: file, line: line) else { return }
        if let existing = field.value as? String, existing != field.placeholderValue, !existing.isEmpty {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count))
        }
        field.typeText(value)
    }

    private func assertMoney(_ expected: String, title: String, element: XCUIElement,
                             file: StaticString = #filePath, line: UInt = #line) {
        // Reading a lazy row does not require it to be touchable. Avoid moving
        // the dashboard for every balance assertion while the value is already
        // in the accessibility tree; explicitly search upward when it is not.
        if !element.exists {
            guard UITestInteraction.reveal(element, in: XCUIApplication(), towardTopWhenMissing: true,
                                           file: file, line: line) else { return }
        }
        XCTAssertTrue(element.waitForExistence(timeout: 5), file: file, line: line)
        let value = element.label
        XCTAssertTrue([expected, title + ", " + expected].contains(value),
                      "Expected \(title): \(expected); got \(value)", file: file, line: line)
    }

    private func tapVisible(_ element: XCUIElement, in app: XCUIApplication,
                            file: StaticString = #filePath, line: UInt = #line) {
        _ = UITestInteraction.tap(element, in: app, file: file, line: line)
    }
}
