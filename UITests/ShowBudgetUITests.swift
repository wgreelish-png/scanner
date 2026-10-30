import XCTest

@MainActor final class ShowBudgetUITests: XCTestCase {
    func testGrossSaleFeesPurchaseAndRelaunchPreserveBuyingAndPersonalFunds() async throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        if let path = ProcessInfo.processInfo.environment["DYLD_FALLBACK_LIBRARY_PATH"] {
            app.launchEnvironment["DYLD_FALLBACK_LIBRARY_PATH"] = path
        }
        app.launchArguments = ["-autoDatabaseUpdates", "NO", "--uitest-show-budget", "--budget-test-id", UUID().uuidString]
        app.launch()
        defer { app.terminate() }
        tapVisible(app.buttons["budget.setup"], in: app)
        enter("300", into: app.textFields["budget.starting"])
        app.buttons["budget.keyboardDone"].tap()
        tapVisible(app.buttons["budget.create"], in: app)
        assertMoney("$300.00", title: "Available to buy", element: app.staticTexts["budget.available"])

        tapVisible(app.buttons["budget.sell"], in: app)
        enter("200", into: app.textFields["budget.amount"])
        enter("10", into: app.textFields["budget.fees"])
        app.buttons["budget.keyboardDone"].tap()
        tapVisible(app.buttons["budget.record"], in: app)
        assertMoney("$420.00", title: "Available to buy", element: app.staticTexts["budget.available"])
        assertMoney("$70.00", title: "Saved for you", element: app.staticTexts["budget.saved"])

        tapVisible(app.buttons["budget.buy"], in: app)
        enter("100", into: app.textFields["budget.amount"])
        app.buttons["budget.keyboardDone"].tap()
        tapVisible(app.buttons["budget.record"], in: app)
        assertMoney("$320.00", title: "Available to buy", element: app.staticTexts["budget.available"])
        assertMoney("$70.00", title: "Saved for you", element: app.staticTexts["budget.saved"])

        app.terminate(); app.launch()
        assertMoney("$320.00", title: "Available to buy", element: app.staticTexts["budget.available"])
        assertMoney("$70.00", title: "Saved for you", element: app.staticTexts["budget.saved"])
        XCTAssertFalse(app.alerts.firstMatch.exists)
    }

    private func enter(_ value: String, into field: XCUIElement) {
        XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap(); field.typeText(value)
    }

    private func assertMoney(_ expected: String, title: String, element: XCUIElement,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.waitForExistence(timeout: 5), file: file, line: line)
        let value = element.label
        XCTAssertTrue([expected, title + ", " + expected].contains(value),
                      "Expected \(title): \(expected); got \(value)", file: file, line: line)
    }

    private func tapVisible(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<6 {
            if element.exists && element.isHittable { element.tap(); return }
            app.swipeUp()
        }
        XCTFail("The requested budget action is not visible")
    }
}
