import XCTest

@MainActor final class ShowTransactionsUITests: XCTestCase {
    func testMultiCardSaleAndUndoPersistInventoryAndBudgetAcrossRelaunch() throws {
        continueAfterFailure = false
        let app = launch()
        defer { app.terminate() }
        assertStock("3", app: app)
        tap(app.buttons["show.recordTransaction"], app: app)
        tap(app.buttons["showTransaction.selectInventory"], app: app)
        let stock = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "showTransaction.stock."))
        XCTAssertEqual(stock.count, 2)
        let selected = stock.allElementsBoundByIndex
        for row in selected { tap(row, app: app) }
        tap(app.buttons["showInventorySelection.done"], app: app)
        assertSaleAmount("40.00", app: app)
        tap(app.buttons["showTransaction.editSaleAmount"], app: app)
        enterSaleAmount("100", app: app)
        closeCashEditor(.done, app: app)
        assertSaleAmount("100.00", app: app)
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
        tap(app.buttons["showTransaction.kind.trade"], app: app)
        tap(app.buttons["showTransaction.incomingList"], app: app)
        tap(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Trade 32")).firstMatch, app: app)
        tap(app.buttons["showTransaction.selectInventory"], app: app)
        let stockA = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label BEGINSWITH %@", "showTransaction.stock.", "Stock A")).firstMatch
        tap(stockA, app: app)
        tap(app.buttons["showInventorySelection.done"], app: app)
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

    func testInventorySearchDoneDismissesKeyboardAndReturnsToPinnedAutomaticCheckout() {
        continueAfterFailure = false
        let app = launch()
        defer { app.terminate() }
        tap(app.buttons["show.recordTransaction"], app: app)
        tap(app.buttons["showTransaction.selectInventory"], app: app)
        let search = app.searchFields.firstMatch
        tap(search, app: app); search.typeText("Stock A")
        tap(app.buttons["showInventorySelection.keyboardDone"], app: app)
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.keyboards.firstMatch)
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 5), .completed)
        XCTAssertEqual(search.value as? String, "Stock A")
        let stockA = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label BEGINSWITH %@", "showTransaction.stock.", "Stock A")).firstMatch
        tap(stockA, app: app)
        tap(app.buttons["showInventorySelection.done"], app: app)
        let record = app.buttons["showTransaction.record"]
        XCTAssertTrue(record.waitForExistence(timeout: 5)); XCTAssertTrue(record.isHittable); XCTAssertTrue(record.isEnabled)
        assertSaleAmount("35.00", app: app)
        // Checkout is pinned even when the form is scrolled to its final note.
        app.swipeUp(); app.swipeUp()
        XCTAssertTrue(record.isHittable)
        app.buttons["Cancel"].tap()
        assertBalances(available: "$300.00", saved: "$0.00", app: app)
        assertStock("3", app: app)
    }

    func testSaleCashEditorKeepsAutomaticTotalForUnchangedAndCancelledEditsAndRejectsInvalidAmounts() {
        continueAfterFailure = false
        let app = launch()
        defer { app.terminate() }
        tap(app.buttons["show.recordTransaction"], app: app)
        tap(app.buttons["showTransaction.selectInventory"], app: app)
        tap(stock("Stock A", app: app), app: app)
        tap(app.buttons["showInventorySelection.done"], app: app)
        assertSaleAmount("35.00", app: app)

        tap(app.buttons["showTransaction.editSaleAmount"], app: app)
        tap(app.textFields["showTransaction.amount.sale"], app: app)
        closeCashEditor(.done, app: app)
        app.swipeDown(); app.swipeDown()
        tap(app.buttons["showTransaction.selectInventory"], app: app)
        tap(stock("Stock B", app: app), app: app)
        tap(app.buttons["showInventorySelection.done"], app: app)
        assertSaleAmount("40.00", app: app)

        tap(app.buttons["showTransaction.editSaleAmount"], app: app)
        enterSaleAmount("32", app: app)
        closeCashEditor(.cancel, app: app)
        assertSaleAmount("40.00", app: app)

        tap(app.buttons["showTransaction.editSaleAmount"], app: app)
        let done = app.buttons["showTransaction.cashEditor.done"]
        enterSaleAmount("", app: app)
        XCTAssertFalse(done.isEnabled)
        enterSaleAmount("1.234", app: app)
        XCTAssertFalse(done.isEnabled)
        closeCashEditor(.cancel, app: app)
        assertSaleAmount("40.00", app: app)
        app.swipeDown(); app.swipeDown()
        tap(app.buttons["showTransaction.selectInventory"], app: app)
        tap(stock("Stock B", app: app), app: app)
        tap(app.buttons["showInventorySelection.done"], app: app)
        assertSaleAmount("35.00", app: app)
        XCTAssertTrue(app.buttons["showTransaction.record"].isEnabled)
        app.buttons["Cancel"].tap()
        assertBalances(available: "$300.00", saved: "$0.00", app: app)
        assertStock("3", app: app)
    }

    func testRepeatedSaleCashEditsApplyDiscountAndKeepManualTotalUntilReset() {
        continueAfterFailure = false
        let app = launch()
        defer { app.terminate() }
        tap(app.buttons["show.recordTransaction"], app: app)
        tap(app.buttons["showTransaction.selectInventory"], app: app)
        tap(stock("Stock A", app: app), app: app)
        tap(stock("Stock B", app: app), app: app)
        tap(app.buttons["showInventorySelection.done"], app: app)
        assertSaleAmount("40.00", app: app)

        for (input, total, percentage) in [("36", "36.00", "90%"), ("32", "32.00", "80%")] {
            tap(app.buttons["showTransaction.editSaleAmount"], app: app)
            enterSaleAmount(input, app: app)
            closeCashEditor(.done, app: app)
            assertSaleAmount(total, app: app)
            assertContains(percentage, element: app.descendants(matching: .any)["showTransaction.salePercentage"])
            XCTAssertTrue(app.buttons["showTransaction.record"].isHittable)
        }
        assertContains("$32.00", element: app.descendants(matching: .any)["showTransaction.preview.received"])

        app.swipeDown(); app.swipeDown()
        tap(app.buttons["showTransaction.selectInventory"], app: app)
        tap(stock("Stock B", app: app), app: app)
        tap(app.buttons["showInventorySelection.done"], app: app)
        assertSaleAmount("32.00", app: app)
        tap(app.buttons["showTransaction.resetSaleTotal"], app: app)
        assertSaleAmount("35.00", app: app)

        app.swipeDown(); app.swipeDown()
        tap(app.buttons["showTransaction.selectInventory"], app: app)
        tap(stock("Stock B", app: app), app: app)
        tap(app.buttons["showInventorySelection.done"], app: app)
        assertSaleAmount("40.00", app: app)
        XCTAssertTrue(app.buttons["showTransaction.record"].isEnabled)
        app.buttons["Cancel"].tap()
        assertBalances(available: "$300.00", saved: "$0.00", app: app)
        assertStock("3", app: app)
    }

    func testEditingIncomingListReturnsToSameDealWithoutRecordingAndKeepsNegotiatedAmount() {
        continueAfterFailure = false
        let app = launch()
        defer { app.terminate() }
        tap(app.buttons["show.recordTransaction"], app: app)
        tap(app.buttons["showTransaction.kind.purchase"], app: app)
        tap(app.buttons["showTransaction.incomingList"], app: app)
        tap(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Buy 14")).firstMatch, app: app)
        enter("12", field: app.textFields["showTransaction.amount.incoming"], app: app)
        tap(app.buttons["showTransaction.keyboardDone"], app: app)
        app.swipeDown()
        tap(app.buttons["showTransaction.editIncomingList"], app: app)
        XCTAssertFalse(app.buttons["list.recordTransaction"].exists)
        let options = app.navigationBars.buttons["list.options"]
        XCTAssertTrue(options.waitForExistence(timeout: 5))
        options.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        app.buttons["Rename"].tap()
        let rename = app.alerts["Rename List"]
        XCTAssertTrue(rename.waitForExistence(timeout: 5))
        enter("Edited purchase", field: rename.textFields.firstMatch, app: app)
        rename.buttons["Save"].tap()
        tap(app.buttons["showTransaction.returnFromEdit"], app: app)
        assertContains("Your agreed total was kept", element: app.staticTexts["showTransaction.incomingEditStatus"])
        XCTAssertEqual(app.textFields["showTransaction.amount.incoming"].value as? String, "12")
        XCTAssertTrue(app.buttons["showTransaction.record"].isHittable)
        app.buttons["Cancel"].tap()
        assertBalances(available: "$300.00", saved: "$0.00", app: app)
        assertStock("3", app: app)
    }

    func testLargeIncomingListKeepsInventoryCheckoutAndReceiptActionsReachable() {
        continueAfterFailure = false
        let app = launch(arguments: ["--show-transactions-large-incoming"])
        defer { app.terminate() }
        tap(app.buttons["show.inventory"], app: app)
        tap(app.buttons["showInventory.recordTransaction"], app: app)
        for kind in ["sale", "trade", "purchase"] {
            XCTAssertTrue(app.buttons["showTransaction.kind." + kind].isHittable)
        }
        tap(app.buttons["showTransaction.kind.trade"], app: app)
        for kind in ["tradeEven", "tradePayCustomer", "tradeReceiveCash"] {
            XCTAssertTrue(app.buttons["showTransaction.kind." + kind].isHittable)
        }
        tap(app.buttons["showTransaction.kind.purchase"], app: app)
        tap(app.buttons["showTransaction.incomingList"], app: app)
        tap(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Buy 14")).firstMatch, app: app)
        assertContains("80 cards · 80 rows", element: app.descendants(matching: .any)["showTransaction.incomingSummary"])

        let incoming = app.descendants(matching: .any)["showTransaction.incomingCards"]
        XCTAssertTrue(incoming.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Market reference: $20.00 each"].exists,
                       "Incoming rows start collapsed so the agreed amount stays close to the list picker")
        tap(incoming, app: app)
        let firstIncomingPrice = app.staticTexts["Market reference: $20.00 each"]
        for _ in 0..<3 {
            if firstIncomingPrice.exists && firstIncomingPrice.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(firstIncomingPrice.isHittable)
        let record = app.buttons["showTransaction.record"]
        for _ in 0..<3 {
            app.swipeUp()
            XCTAssertTrue(record.isHittable)
            XCTAssertTrue(record.isEnabled)
        }
        record.tap()
        XCTAssertTrue(app.navigationBars["Show Inventory"].waitForExistence(timeout: 5))
        let quantity = app.staticTexts["showInventory.quantity"]
        assertContains("83 cards available", element: quantity)
        let source = app.buttons["showInventory.importSnapshot"]
        let inventoryRecord = app.buttons["showInventory.recordTransaction"]
        for _ in 0..<3 {
            app.swipeUp()
            XCTAssertTrue(quantity.isHittable)
            XCTAssertTrue(source.isHittable)
            XCTAssertTrue(inventoryRecord.isHittable)
        }
        source.tap()
        XCTAssertTrue(app.navigationBars["Card Show Inventory"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        tap(app.buttons["show.history"], app: app)
        tap(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "showHistory.receipt.")).firstMatch, app: app)
        let paid = app.descendants(matching: .any)["showTransaction.receipt.paid"]
        assertContains("$14.00", element: paid)
        XCTAssertTrue(paid.isHittable, "Receipt money is shown before the collapsed acquired cards")
        XCTAssertFalse(app.staticTexts["Market reference: $20.00 each"].exists)
        tap(app.descendants(matching: .any)["showTransaction.receipt.acquiredCards"], app: app)
        let undo = app.buttons["showTransaction.undo"]
        for _ in 0..<3 {
            app.swipeUp()
            XCTAssertTrue(undo.isHittable)
        }
        undo.tap()
        let confirm = app.buttons["showTransaction.confirmUndo"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        app.swipeUp()
        XCTAssertTrue(confirm.isHittable)
        confirm.tap()
        let undone = app.descendants(matching: .any)["showTransaction.undone"]
        for _ in 0..<6 {
            if undone.exists && undone.isHittable { break }
            app.swipeDown()
        }
        XCTAssertTrue(undone.waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        assertStock("3", app: app)
    }

    private func launch(arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        if let path = ProcessInfo.processInfo.environment["DYLD_FALLBACK_LIBRARY_PATH"] { app.launchEnvironment["DYLD_FALLBACK_LIBRARY_PATH"] = path }
        app.launchArguments = ["--show-transactions-ui-fixture", "--show-transactions-fixture-id=" + UUID().uuidString] + arguments
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
    private func assertSaleAmount(_ value: String, app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let row = app.buttons["showTransaction.editSaleAmount"]
        XCTAssertTrue(row.waitForExistence(timeout: 5), file: file, line: line)
        XCTAssertEqual(row.value as? String, value, file: file, line: line)
    }
    private func enterSaleAmount(_ value: String, app: XCUIApplication) {
        let field = app.textFields["showTransaction.amount.sale"]
        tap(field, app: app)
        let clear = app.buttons["showTransaction.cashEditor.clear"]
        if clear.isEnabled { tap(clear, app: app) }
        if !value.isEmpty { field.typeText(value) }
    }
    private enum CashEditorAction: String { case done, cancel }
    private func closeCashEditor(_ action: CashEditorAction, app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        tap(app.buttons["showTransaction.cashEditor." + action.rawValue], app: app)
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"),
                                                object: app.buttons["showTransaction.cashEditor.done"])
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 5), .completed, file: file, line: line)
    }
    private func stock(_ name: String, app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label BEGINSWITH %@", "showTransaction.stock.", name)).firstMatch
    }
    private func assertContains(_ value: String, element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.waitForExistence(timeout: 5), file: file, line: line)
        let text = element.label + " " + element.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " ")
        XCTAssertTrue(text.contains(value), "Expected \(value), received \(text)", file: file, line: line)
    }
    private func enter(_ value: String, field: XCUIElement, app: XCUIApplication) {
        tap(field, app: app)
        if let existing = field.value as? String, existing != field.placeholderValue, !existing.isEmpty {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count))
        }
        field.typeText(value)
    }
    private func tap(_ element: XCUIElement, app: XCUIApplication) {
        for _ in 0..<10 {
            if element.exists && element.isHittable { element.tap(); return }
            app.swipeUp()
        }
        XCTFail("Requested transaction control was not visible: \(element.identifier)")
    }
}
