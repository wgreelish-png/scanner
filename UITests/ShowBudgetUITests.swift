import XCTest

@MainActor final class ShowBudgetUITests: XCTestCase {
    func testGrossSaleFeesPurchaseAndRelaunchPreserveBuyingAndPersonalFunds() async throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        if let path = ProcessInfo.processInfo.environment["DYLD_FALLBACK_LIBRARY_PATH"] {
            app.launchEnvironment["DYLD_FALLBACK_LIBRARY_PATH"] = path
        }
        app.launchArguments = ["-autoDatabaseUpdates", "NO", "-betaAutomaticIPAllowlist", "NO", "--uitest-show-budget", "--budget-test-id", UUID().uuidString]
        app.launch()
        defer { app.terminate() }
        tapVisible(app.buttons["budget.setup"], in: app)
        enter("300", into: app.textFields["budget.starting"], in: app)
        _ = UITestInteraction.tapToolbar(app.buttons["budget.keyboardDone"], in: app)
        XCTAssertTrue(app.descendants(matching: .any)["budget.startDate"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["budget.endDate"].exists)
        tapVisible(app.buttons["budget.create"], in: app)
        assertMoney("$300.00", title: "Available to buy", element: app.staticTexts["budget.available"])
        let dates = app.staticTexts["budget.showDates"]
        XCTAssertTrue(dates.waitForExistence(timeout: 5))
        let showDates = dates.label
        let status = app.staticTexts["budget.scheduleStatus"]
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertTrue(["Active today", "Status, Active today"].contains(status.label))
        XCTAssertTrue(app.buttons["budget.sell"].isEnabled)

        tapVisible(app.buttons["budget.sell"], in: app)
        enter("200", into: app.textFields["budget.amount"], in: app)
        enter("10", into: app.textFields["budget.fees"], in: app)
        _ = UITestInteraction.tapToolbar(app.buttons["budget.keyboardDone"], in: app)
        tapVisible(app.buttons["budget.record"], in: app)
        assertMoney("$420.00", title: "Available to buy", element: app.staticTexts["budget.available"])
        assertMoney("$70.00", title: "Saved for you", element: app.staticTexts["budget.saved"])

        tapVisible(app.buttons["budget.buy"], in: app)
        enter("100", into: app.textFields["budget.amount"], in: app)
        _ = UITestInteraction.tapToolbar(app.buttons["budget.keyboardDone"], in: app)
        tapVisible(app.buttons["budget.record"], in: app)
        assertMoney("$320.00", title: "Available to buy", element: app.staticTexts["budget.available"])
        assertMoney("$70.00", title: "Saved for you", element: app.staticTexts["budget.saved"])

        app.terminate(); app.launch()
        XCTAssertTrue(app.staticTexts["budget.showDates"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["budget.showDates"].label, showDates)
        XCTAssertTrue(["Active today", "Status, Active today"].contains(app.staticTexts["budget.scheduleStatus"].label))
        assertMoney("$320.00", title: "Available to buy", element: app.staticTexts["budget.available"])
        assertMoney("$70.00", title: "Saved for you", element: app.staticTexts["budget.saved"])
        XCTAssertFalse(app.alerts.firstMatch.exists)
    }

    private func enter(_ value: String, into field: XCUIElement, in app: XCUIApplication,
                       file: StaticString = #filePath, line: UInt = #line) {
        guard UITestInteraction.tap(field, in: app, file: file, line: line) else { return }
        field.typeText(value)
    }

    private func assertMoney(_ expected: String, title: String, element: XCUIElement,
                             file: StaticString = #filePath, line: UInt = #line) {
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
