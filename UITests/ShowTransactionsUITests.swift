import XCTest

@MainActor final class ShowTransactionsUITests: XCTestCase {
    func testMultiCardSaleAndUndoPersistInventoryAndBudgetAcrossRelaunch() throws {
        continueAfterFailure = false
        let app = launch()
        defer { app.terminate() }
        assertStock("3", app: app)
        tap(app.buttons["show.recordTransaction"], app: app)
        let stock = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "showTransaction.stock."))
        XCTAssertEqual(stock.count, 2)
        let selected = stock.allElementsBoundByIndex
        for row in selected { tap(row, app: app) }
        enter("100", field: app.textFields["showTransaction.amount.sale"], app: app)
        app.buttons["showTransaction.keyboardDone"].tap()
        tap(app.buttons["showTransaction.record"], app: app)
        XCTAssertTrue(app.navigationBars["Show"].waitForExistence(timeout: 5))
        assertBalances(available: "$365.00", saved: "$35.00", app: app)
        assertStock("1", app: app)
        app.terminate(); app.launch()
        assertBalances(available: "$365.00", saved: "$35.00", app: app)
        assertStock("1", app: app)
        tap(app.buttons["show.history"], app: app)
        let receipt = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "showHistory.receipt.")).firstMatch
        tap(receipt, app: app)
        tap(app.buttons["showTransaction.undo"], app: app)
        tap(app.buttons["showTransaction.confirmUndo"], app: app)
        XCTAssertTrue(app.descendants(matching: .any)["showTransaction.undone"].waitForExistence(timeout: 5))
        app.terminate(); app.launch()
        assertBalances(available: "$300.00", saved: "$0.00", app: app)
        assertStock("3", app: app)
    }

    func testEvenTradeRequiresExplicitConcessionAndKeepsCashAtZero() throws {
        continueAfterFailure = false
        let app = launch()
        defer { app.terminate() }
        tap(app.buttons["show.recordTransaction"], app: app)
        tap(app.buttons["showTransaction.kind"], app: app)
        tap(app.buttons["Trade"].firstMatch, app: app)
        tap(app.buttons["showTransaction.incomingList"], app: app)
        tap(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Trade 32")).firstMatch, app: app)
        let stockA = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label BEGINSWITH %@", "showTransaction.stock.", "Stock A")).firstMatch
        tap(stockA, app: app)
        tap(app.buttons["showTransaction.makeEven"], app: app)
        let paid = app.descendants(matching: .any)["showTransaction.preview.paid"]
        let received = app.descendants(matching: .any)["showTransaction.preview.received"]
        assertContains("$0.00", element: paid); assertContains("$0.00", element: received)
        tap(app.buttons["showTransaction.record"], app: app)
        assertBalances(available: "$300.00", saved: "$0.00", app: app)
        tap(app.buttons["show.history"], app: app)
        tap(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "showHistory.receipt.")).firstMatch, app: app)
        let concession = app.descendants(matching: .any)["showTransaction.receipt.concession"]
        for _ in 0..<6 {
            if concession.exists && concession.isHittable { break }
            app.swipeUp()
        }
        assertContains("$3.00", element: concession)
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        if let path = ProcessInfo.processInfo.environment["DYLD_FALLBACK_LIBRARY_PATH"] { app.launchEnvironment["DYLD_FALLBACK_LIBRARY_PATH"] = path }
        app.launchArguments = ["--show-transactions-ui-fixture", "--show-transactions-fixture-id=" + UUID().uuidString]
        app.launch()
        XCTAssertTrue(app.navigationBars["Show"].waitForExistence(timeout: 10))
        return app
    }
    private func assertBalances(available: String, saved: String, app: XCUIApplication) {
        tap(app.buttons["budget.summary"], app: app)
        assertContains(available, element: app.staticTexts["budget.available"])
        assertContains(saved, element: app.staticTexts["budget.saved"])
        app.navigationBars.buttons.element(boundBy: 0).tap()
    }
    private func assertStock(_ count: String, app: XCUIApplication) {
        tap(app.buttons["show.inventory"], app: app)
        assertContains(count + " cards available", element: app.staticTexts["showInventory.quantity"])
        app.navigationBars.buttons.element(boundBy: 0).tap()
    }
    private func assertContains(_ value: String, element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.waitForExistence(timeout: 5), file: file, line: line)
        let text = element.label + " " + element.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " ")
        XCTAssertTrue(text.contains(value), "Expected \(value), received \(text)", file: file, line: line)
    }
    private func enter(_ value: String, field: XCUIElement, app: XCUIApplication) {
        tap(field, app: app); field.typeText(value)
    }
    private func tap(_ element: XCUIElement, app: XCUIApplication) {
        for _ in 0..<10 {
            if element.exists && element.isHittable { element.tap(); return }
            app.swipeUp()
        }
        XCTFail("Requested transaction control was not visible: \(element.identifier)")
    }
}
