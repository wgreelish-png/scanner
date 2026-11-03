import XCTest

@MainActor final class ShowTransactionsUITests: XCTestCase {
    func testPurchasedCostQuickSaleProfitAndUndoPersistAcrossRelaunch() {
        continueAfterFailure = false
        let app = launch(arguments: ["--show-cost-profit-ui-fixture"])
        defer { app.terminate() }
        tap(app.buttons["show.recordTransaction"], app: app)
        tap(app.buttons["showTransaction.kind.purchase"], app: app)
        tap(app.buttons["showTransaction.incomingList"], app: app)
        tap(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Profit Example")).firstMatch, app: app)
        let paid = app.textFields["showTransaction.amount.incoming"]
        reveal(paid, app: app)
        XCTAssertEqual(paid.value as? String, "7.00", "Purchase cost comes from the actual 70% cash offer")
        tap(app.buttons["showTransaction.record"], app: app)
        XCTAssertTrue(app.navigationBars["Show"].waitForExistence(timeout: 5))
        assertBalances(available: "$293.00", saved: "$0.00", app: app)
        assertStock("4", app: app)

        tap(app.buttons["show.inventory"], app: app)
        let acquired = inventory("Profit Example", app: app)
        reveal(acquired, app: app)
        let inventoryID = String(acquired.identifier.dropFirst("showInventory.item.".count))
        XCTAssertNotNil(UUID(uuidString: inventoryID))
        tap(acquired, app: app)
        assertRevealedContains("$7.00", identifier: "inventory.cost", app: app)
        let source = app.buttons["inventory.acquisitionReceipt"]
        reveal(source, app: app)
        assertContains("Purchase Receipt", element: source)
        tap(source, app: app)
        assertRevealedContains("$7.00", identifier: "showTransaction.receipt.paid", app: app)
        app.navigationBars.buttons.element(boundBy: 0).tap()

        tap(app.buttons["quickSell.sell"], app: app)
        assertRevealedContains("1", identifier: "showTransaction.selectedQuantity", app: app)
        reveal(app.buttons["showTransaction.editSaleAmount"], app: app)
        assertSaleAmount("10.00", app: app)
        reveal(app.buttons["showTransaction.editSaleFee"], app: app)
        XCTAssertEqual(app.buttons["showTransaction.editSaleFee"].value as? String, "$0.00")
        assertRevealedContains("$7.00", identifier: "showTransaction.preview.cost", app: app)
        assertRevealedContains("$3.00", identifier: "showTransaction.preview.profit", app: app)
        tap(app.buttons["showTransaction.record"], app: app)
        XCTAssertTrue(app.navigationBars["Card Details"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["quickSell.sell"].isEnabled)
        returnToShow(app: app)
        assertBalances(available: "$299.50", saved: "$3.50", app: app)
        assertStock("3", app: app)
        assertProfit(sales: "$10.00", fees: "$0.00", cost: "$7.00", knownProfit: "$3.00", app: app)

        app.terminate(); app.launch()
        XCTAssertTrue(app.navigationBars["Show"].waitForExistence(timeout: 10))
        assertBalances(available: "$299.50", saved: "$3.50", app: app)
        assertStock("3", app: app)
        assertProfit(sales: "$10.00", fees: "$0.00", cost: "$7.00", knownProfit: "$3.00", app: app)
        tap(app.buttons["show.history"], app: app)
        tap(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "showHistory.receipt.")).firstMatch, app: app)
        assertRevealedContains("$10.00", identifier: "showTransaction.receipt.received", app: app)
        assertRevealedContains("$7.00", identifier: "showTransaction.receipt.cost", app: app)
        assertRevealedContains("$0.00", identifier: "showTransaction.receipt.fees", app: app)
        assertRevealedContains("$3.00", identifier: "showTransaction.receipt.profit", app: app)
        tap(app.descendants(matching: .any)["showTransaction.receipt.releasedCards"], app: app)
        tap(app.buttons["showTransaction.receipt.source." + inventoryID], app: app)
        assertRevealedContains("$7.00", identifier: "showTransaction.receipt.paid", app: app)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        undoTransaction(app: app)
        returnToShow(app: app)
        assertBalances(available: "$293.00", saved: "$0.00", app: app)
        assertStock("4", app: app)
        assertProfit(sales: "$0.00", fees: "$0.00", cost: "$0.00", knownProfit: "$0.00", app: app)

        tap(app.buttons["show.inventory"], app: app)
        tap(app.buttons["showInventory.item." + inventoryID], app: app)
        assertRevealedContains("$7.00", identifier: "inventory.cost", app: app)
        tap(app.buttons["inventory.acquisitionReceipt"], app: app)
        undoTransaction(app: app)
        returnToShow(app: app)
        assertBalances(available: "$300.00", saved: "$0.00", app: app)
        assertStock("3", app: app)
    }

    func testLegacyCostZeroAndUnknownStayDistinctAndQuickSaleFeeDebitsCashOnce() {
        continueAfterFailure = false
        let app = launch(arguments: ["--show-cost-profit-ui-fixture"])
        defer { app.terminate() }
        tap(app.buttons["show.inventory"], app: app)
        let row = inventory("Stock A", app: app)
        reveal(row, app: app)
        let inventoryID = String(row.identifier.dropFirst("showInventory.item.".count))
        tap(row, app: app)
        assertRevealedContains("Cost unknown", identifier: "inventory.cost", app: app)
        tap(app.buttons["inventory.editCost"], app: app)
        enter("0", field: app.textFields["inventory.costAmount"], app: app)
        tap(app.buttons["inventory.saveCost"], app: app)
        assertRevealedContains("$0.00", identifier: "inventory.cost", app: app)
        returnToShow(app: app)
        assertBalances(available: "$300.00", saved: "$0.00", app: app)

        app.terminate(); app.launch()
        XCTAssertTrue(app.navigationBars["Show"].waitForExistence(timeout: 10))
        tap(app.buttons["show.inventory"], app: app)
        tap(app.buttons["showInventory.item." + inventoryID], app: app)
        assertRevealedContains("$0.00", identifier: "inventory.cost", app: app)
        tap(app.buttons["inventory.editCost"], app: app)
        tap(app.buttons["inventory.clearCost"], app: app)
        assertRevealedContains("Cost unknown", identifier: "inventory.cost", app: app)
        tap(app.buttons["quickSell.sell"], app: app)
        assertRevealedContains("1", identifier: "showTransaction.selectedQuantity", app: app)
        reveal(app.buttons["showTransaction.editSaleAmount"], app: app)
        assertSaleAmount("35.00", app: app)
        tap(app.buttons["showTransaction.editSaleFee"], app: app)
        enter("1", field: app.textFields["showTransaction.amount.saleFee"], app: app)
        tap(app.buttons["showTransaction.saleFee.done"], app: app)
        XCTAssertEqual(app.buttons["showTransaction.editSaleFee"].value as? String, "$1.00")
        assertRevealedContains("Unknown", identifier: "showTransaction.preview.cost", app: app)
        assertRevealedContains("Unknown", identifier: "showTransaction.preview.profit", app: app)
        tap(app.buttons["showTransaction.record"], app: app)
        XCTAssertTrue(app.navigationBars["Card Details"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["quickSell.sell"].isEnabled, "One of the two legacy copies remains available")
        assertRevealedContains("Cost unknown", identifier: "inventory.cost", app: app)
        returnToShow(app: app)
        assertBalances(available: "$321.75", saved: "$12.25", app: app)
        assertStock("2", app: app)
        assertProfit(sales: "$35.00", fees: "$1.00", cost: "$0.00", knownProfit: "$0.00", unknown: "1", app: app)

        app.terminate(); app.launch()
        XCTAssertTrue(app.navigationBars["Show"].waitForExistence(timeout: 10))
        assertBalances(available: "$321.75", saved: "$12.25", app: app)
        assertStock("2", app: app)
        assertProfit(sales: "$35.00", fees: "$1.00", cost: "$0.00", knownProfit: "$0.00", unknown: "1", app: app)
        tap(app.buttons["show.history"], app: app)
        tap(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "showHistory.receipt.")).firstMatch, app: app)
        assertRevealedContains("$35.00", identifier: "showTransaction.receipt.received", app: app)
        assertRevealedContains("Unknown", identifier: "showTransaction.receipt.cost", app: app)
        assertRevealedContains("$1.00", identifier: "showTransaction.receipt.fees", app: app)
        assertRevealedContains("Unknown", identifier: "showTransaction.receipt.profit", app: app)
        undoTransaction(app: app)
        returnToShow(app: app)
        assertBalances(available: "$300.00", saved: "$0.00", app: app)
        assertStock("3", app: app)
        tap(app.buttons["show.inventory"], app: app)
        tap(app.buttons["showInventory.item." + inventoryID], app: app)
        assertRevealedContains("Cost unknown", identifier: "inventory.cost", app: app)
    }

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

    func testPriceTagPreviewEditsStayLocalAndOpeningDoesNotRequestBluetooth() {
        continueAfterFailure = false
        let app = launch()
        defer { app.terminate() }
        tap(app.buttons["show.inventory"], app: app)
        assertContains("3 cards available", element: app.staticTexts["showInventory.quantity"])
        let options = app.navigationBars.buttons["showInventory.options"]
        XCTAssertTrue(options.waitForExistence(timeout: 5))
        XCTAssertTrue(options.isEnabled)
        XCTAssertTrue(app.windows.firstMatch.frame.contains(options.frame))
        options.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        tap(app.buttons["showInventory.priceTags"], app: app)
        XCTAssertTrue(app.navigationBars["Price Tags"].waitForExistence(timeout: 5))
        let system = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        XCTAssertFalse(system.alerts.firstMatch.waitForExistence(timeout: 1),
            "Opening price tags must not request Bluetooth access before Search is tapped")
        XCTAssertFalse(app.alerts.firstMatch.exists)
        let review = app.buttons["priceTags.review"]
        XCTAssertFalse(review.isEnabled)
        let stockA = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label BEGINSWITH %@",
            "priceTags.select.", "Stock A")).firstMatch
        XCTAssertTrue(stockA.waitForExistence(timeout: 5))
        let inventoryID = String(stockA.identifier.dropFirst("priceTags.select.".count))
        XCTAssertNotNil(UUID(uuidString: inventoryID))
        tap(stockA, app: app)
        XCTAssertEqual(review.label, "Review 1 Label", "Stock quantity must not become the default label count")
        tap(review, app: app)
        let edit = app.buttons["priceTags.edit." + inventoryID]
        tap(edit, app: app)
        XCTAssertTrue(app.descendants(matching: .any)["priceTags.preview"].waitForExistence(timeout: 5))
        let price = app.textFields["priceTags.askingPrice"]
        XCTAssertEqual(price.value as? String, "35")
        enter("32.50", field: price, app: app)
        XCTAssertEqual(price.value as? String, "32.50")
        let printOne = app.buttons["priceTags.printOne"]
        XCTAssertTrue(printOne.exists)
        XCTAssertFalse(printOne.isEnabled, "A preview must not print before a printer is explicitly connected")
        XCTAssertFalse(system.alerts.firstMatch.exists)
        tap(app.navigationBars["Edit Price Tag"].buttons.element(boundBy: 0), app: app)
        assertContains("$32.50", element: edit)
        tap(app.buttons["priceTags.done"], app: app)
        tap(app.buttons["priceTags.close"], app: app)
        assertContains("3 cards available", element: app.staticTexts["showInventory.quantity"])
        app.navigationBars.buttons.element(boundBy: 0).tap()
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
    private func inventory(_ name: String, app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label BEGINSWITH %@", "showInventory.item.", name)).firstMatch
    }
    private func reveal(_ element: XCUIElement, app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        for _ in 0..<10 {
            if element.exists && element.isHittable { return }
            app.swipeUp()
        }
        XCTFail("Expected transaction detail was not visible: \(element.identifier)", file: file, line: line)
    }
    private func assertRevealedContains(_ value: String, identifier: String, app: XCUIApplication,
                                        file: StaticString = #filePath, line: UInt = #line) {
        let element = app.descendants(matching: .any)[identifier]
        reveal(element, app: app, file: file, line: line)
        assertContains(value, element: element, file: file, line: line)
    }
    private func returnToShow(app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        for _ in 0..<4 {
            if app.navigationBars["Show"].exists { return }
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }
        XCTAssertTrue(app.navigationBars["Show"].waitForExistence(timeout: 5), file: file, line: line)
    }
    private func undoTransaction(app: XCUIApplication) {
        tap(app.buttons["showTransaction.undo"], app: app)
        tap(app.buttons["showTransaction.confirmUndo"], app: app)
        for _ in 0..<6 {
            let undone = app.descendants(matching: .any)["showTransaction.undone"]
            if undone.exists && undone.isHittable { break }
            app.swipeDown()
        }
        assertRevealedContains("Undone", identifier: "showTransaction.undone", app: app)
    }
    private func assertProfit(sales: String, fees: String, cost: String, knownProfit: String,
                              unknown: String? = nil, app: XCUIApplication) {
        tap(app.buttons["show.profit"], app: app)
        assertRevealedContains(sales, identifier: "profit.sales", app: app)
        assertRevealedContains(fees, identifier: "profit.fees", app: app)
        assertRevealedContains(cost, identifier: "profit.cost", app: app)
        assertRevealedContains(knownProfit, identifier: "profit.knownProfit", app: app)
        if let unknown { assertRevealedContains(unknown, identifier: "profit.unknown", app: app) }
        app.navigationBars.buttons.element(boundBy: 0).tap()
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
