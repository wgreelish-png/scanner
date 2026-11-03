import XCTest

/// These tests never search for a printer or send Bluetooth data. Queue files
/// use the same isolated fixture token as inventory and financial records.
@MainActor final class InventoryLabelsUITests: XCTestCase {
    func testSingleCardDraftIsIsolatedAndAcceptsZeroWithoutClampingCopies() {
        continueAfterFailure = false
        let app = launch()
        defer { app.terminate() }
        assertBalances(app: app)
        tap(app.buttons["show.inventory"], app: app)
        assertContains("3 cards available", element: app.staticTexts["showInventory.quantity"])
        let row = inventory("Stock A", app: app)
        let inventoryID = inventoryID(of: row)
        tap(row, app: app)
        assertContains("$35.00", element: app.staticTexts["$35.00"])
        assertContains("Cost unknown", element: app.descendants(matching: .any)["inventory.cost"])
        tap(app.buttons["inventory.options"], app: app)
        tap(app.buttons["inventory.printLabel"], app: app)
        XCTAssertTrue(app.navigationBars["Label Details"].waitForExistence(timeout: 5))
        assertContains("1 labels", element: app.staticTexts["labels.totalCount"])

        let edit = app.buttons["labels.edit." + inventoryID]
        tap(edit, app: app)
        XCTAssertEqual(app.textFields["labels.editor.price"].value as? String, "35")
        XCTAssertEqual(app.textFields["labels.editor.copies"].value as? String, "1")
        enter("12", field: app.textFields["labels.editor.price"], app: app)
        tap(app.buttons["labels.editor.cancel"], app: app)
        assertContains("$35", element: edit)

        tap(edit, app: app)
        enter("", field: app.textFields["labels.editor.price"], app: app)
        XCTAssertFalse(app.buttons["labels.editor.save"].isEnabled, "An unknown asking price requires input")
        enter("0", field: app.textFields["labels.editor.price"], app: app)
        enter("101", field: app.textFields["labels.editor.copies"], app: app)
        XCTAssertEqual(app.textFields["labels.editor.copies"].value as? String, "101")
        XCTAssertFalse(app.buttons["labels.editor.save"].isEnabled, "Copies above the explicit limit remain visible for correction")
        enter("2", field: app.textFields["labels.editor.copies"], app: app)
        tap(app.buttons["labels.editor.keyboardDone"], app: app)
        tap(app.buttons["labels.editor.preview"], app: app)
        let preview = app.images["labels.bitmapPreview"].firstMatch
        reveal(preview, app: app)
        XCTAssertTrue((preview.value as? String ?? "").contains("$0"))
        tap(app.buttons["labels.editor.save"], app: app)
        assertContains("$0", element: edit)
        assertContains("2 labels", element: app.staticTexts["labels.totalCount"])
        tap(app.buttons["labels.continueReview"], app: app)
        assertContains("$0", element: app.descendants(matching: .any)["labels.review.price." + inventoryID])
        assertContains("2", element: app.descendants(matching: .any)["labels.review.copies." + inventoryID])
        tap(app.buttons["labels.close"], app: app)

        XCTAssertTrue(app.navigationBars["Card Details"].waitForExistence(timeout: 5))
        reveal(app.staticTexts["$35.00"], app: app)
        XCTAssertTrue(app.staticTexts["$35.00"].exists, "Label price edits must not change the saved market price")
        assertContains("Cost unknown", element: app.descendants(matching: .any)["inventory.cost"])
        app.navigationBars.buttons.element(boundBy: 0).tap()
        assertContains("3 cards available", element: app.staticTexts["showInventory.quantity"])
        app.navigationBars.buttons.element(boundBy: 0).tap()
        assertBalances(app: app)
        assertNoBluetoothPrompt(app: app)
    }

    func testBatchSearchCopiesPreviewAndSavedQueueRequireManualPrintingAfterRelaunch() {
        continueAfterFailure = false
        let app = launch()
        defer { app.terminate() }
        tap(app.buttons["show.inventory"], app: app)
        let stockAID = inventoryID(of: inventory("Stock A", app: app))
        let stockBID = inventoryID(of: inventory("Stock B", app: app))
        openBatch(app: app)
        XCTAssertTrue(app.navigationBars["Select Label Cards"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["labels.continueSelection"].isEnabled)
        let search = app.searchFields.firstMatch
        tap(search, app: app)
        search.typeText("Stock A")
        tap(app.buttons["labels.selection.keyboardDone"], app: app)
        XCTAssertFalse(app.buttons["labels.select." + stockBID].exists)
        tap(app.buttons["labels.select." + stockAID], app: app)
        enter("", field: search, app: app)
        tap(app.buttons["labels.selection.keyboardDone"], app: app)
        tap(app.buttons["labels.select." + stockBID], app: app)
        assertContains("2 cards selected", element: app.staticTexts["labels.selectedCount"])
        tap(app.buttons["labels.continueSelection"], app: app)
        assertContains("2 labels", element: app.staticTexts["labels.totalCount"])
        tap(app.buttons["labels.matchQuantities"], app: app)
        assertContains("3 labels", element: app.staticTexts["labels.totalCount"])
        tap(app.buttons["labels.oneEach"], app: app)
        assertContains("2 labels", element: app.staticTexts["labels.totalCount"])

        tap(app.buttons["labels.edit." + stockAID], app: app)
        enter("32.50", field: app.textFields["labels.editor.price"], app: app)
        XCTAssertFalse(app.buttons["labels.editor.save"].isEnabled, "Individual tags reject cents")
        enter("32", field: app.textFields["labels.editor.price"], app: app)
        tap(app.buttons["labels.editor.keyboardDone"], app: app)
        tap(app.buttons["labels.editor.save"], app: app)

        tap(app.buttons["labels.style"], app: app)
        tap(app.buttons["Price only"], app: app)
        tap(app.buttons["labels.paper"], app: app)
        tap(app.buttons["40 × 12 mm"], app: app)
        let preview = app.images["labels.bitmapPreview"].firstMatch
        reveal(preview, app: app)
        XCTAssertTrue((preview.value as? String ?? "").contains("Price only"))
        XCTAssertTrue((preview.value as? String ?? "").contains("40 × 12 mm"))
        tap(app.buttons["labels.continueReview"], app: app)
        assertContains("2", element: app.descendants(matching: .any)["labels.reviewCount"])
        let prices = [(stockAID, "$32"), (stockBID, "$5")]
        for (id, price) in prices {
            let amount = app.descendants(matching: .any)["labels.review.price." + id]
            reveal(amount, app: app)
            assertContains(price, element: amount)
            assertContains("1", element: app.descendants(matching: .any)["labels.review.copies." + id])
        }
        XCTAssertFalse(app.buttons["labels.prepare"].isEnabled, "Unknown costs require explicit manual review")
        tap(app.switches["labels.acknowledgePricingWarnings"], app: app)
        XCTAssertTrue(app.buttons["labels.prepare"].isHittable, "The final action stays available after reviewing every label")
        tap(app.buttons["labels.prepare"], app: app)
        assertUnstartedQueue(app: app)
        tap(app.buttons["labels.close"], app: app)
        assertContains("3 cards available", element: app.staticTexts["showInventory.quantity"])
        app.navigationBars.buttons.element(boundBy: 0).tap()
        assertBalances(app: app)

        app.terminate()
        app.launch()
        XCTAssertTrue(app.navigationBars["Show"].waitForExistence(timeout: 10))
        assertBalances(app: app)
        tap(app.buttons["show.inventory"], app: app)
        assertContains("3 cards available", element: app.staticTexts["showInventory.quantity"])
        openBatch(app: app)
        tap(app.buttons["labels.select." + stockAID], app: app)
        tap(app.buttons["labels.continueSelection"], app: app)
        tap(app.buttons["labels.reviewSavedQueue"], app: app)
        assertUnstartedQueue(app: app)
        let queued = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "labelQueue.entry.")).firstMatch
        tap(queued, app: app)
        XCTAssertTrue(app.navigationBars["Queued Label"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.images["labels.bitmapPreview"].waitForExistence(timeout: 5))
        assertNoBluetoothPrompt(app: app)
    }

    func testKeepingExistingStickerPersistsApprovalWithoutReprintingUnchangedPrice() {
        continueAfterFailure = false
        let app = launch()
        defer { app.terminate() }
        tap(app.buttons["show.inventory"], app: app)
        let stockAID = inventoryID(of: inventory("Stock A", app: app))
        openBatch(app: app)
        tap(app.buttons["labels.select." + stockAID], app: app)
        tap(app.buttons["labels.continueSelection"], app: app)
        assertContains("1 labels", element: app.staticTexts["labels.totalCount"])
        tap(app.buttons["labels.continueReview"], app: app)
        tap(app.switches["labels.keepExistingSticker." + stockAID], app: app)
        tap(app.switches["labels.acknowledgePricingWarnings"], app: app)
        tap(app.buttons["labels.prepare"], app: app)
        assertContains("Approved prices saved. No individual labels need printing.",
            element: app.staticTexts["labels.approvedNotice"])
        XCTAssertTrue(app.navigationBars["Review Labels"].exists)
        XCTAssertFalse(app.navigationBars["Label Print Queue"].exists)
        tap(app.buttons["labels.close"], app: app)
        assertContains("3 cards available", element: app.staticTexts["showInventory.quantity"])

        app.terminate()
        app.launch()
        XCTAssertTrue(app.navigationBars["Show"].waitForExistence(timeout: 10))
        tap(app.buttons["show.inventory"], app: app)
        openBatch(app: app)
        tap(app.buttons["labels.select." + stockAID], app: app)
        tap(app.buttons["labels.continueSelection"], app: app)
        assertContains("0 labels", element: app.staticTexts["labels.totalCount"])
        tap(app.buttons["labels.continueReview"], app: app)
        tap(app.switches["labels.acknowledgePricingWarnings"], app: app)
        tap(app.buttons["labels.prepare"], app: app)
        assertContains("Approved prices saved. No individual labels need printing.",
            element: app.staticTexts["labels.approvedNotice"])
        XCTAssertFalse(app.navigationBars["Label Print Queue"].exists)
        assertNoBluetoothPrompt(app: app)
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        if let path = ProcessInfo.processInfo.environment["DYLD_FALLBACK_LIBRARY_PATH"] {
            app.launchEnvironment["DYLD_FALLBACK_LIBRARY_PATH"] = path
        }
        app.launchArguments = ["--show-transactions-ui-fixture", "--show-transactions-fixture-id=" + UUID().uuidString]
        app.launch()
        XCTAssertTrue(app.navigationBars["Show"].waitForExistence(timeout: 10))
        return app
    }

    private func openBatch(app: XCUIApplication) {
        tap(app.buttons["showInventory.options"], app: app)
        tap(app.buttons["showInventory.printLabels"], app: app)
    }

    private func assertUnstartedQueue(app: XCUIApplication) {
        XCTAssertTrue(app.navigationBars["Label Print Queue"].waitForExistence(timeout: 5))
        assertContains("0/2 completed", element: app.staticTexts["labelQueue.progress"])
        assertContains("2", element: app.descendants(matching: .any)["labelQueue.totalCount"])
        assertContains("40 × 12 mm", element: app.descendants(matching: .any)["labelQueue.paper"])
        assertContains("Price only", element: app.descendants(matching: .any)["labelQueue.style"])
        XCTAssertFalse(app.buttons["labelQueue.print"].isEnabled)
        XCTAssertFalse(app.buttons["labelQueue.pause"].exists)
        let status = app.staticTexts["labelPrinter.status"]
        reveal(status, app: app)
        assertContains("Search for a NIIMBOT D110", element: status)
        assertNoBluetoothPrompt(app: app)
    }

    private func assertBalances(app: XCUIApplication) {
        tap(app.buttons["budget.summary"], app: app)
        assertContains("$300.00", element: app.staticTexts["budget.available"])
        assertContains("$0.00", element: app.staticTexts["budget.saved"])
        app.navigationBars.buttons.element(boundBy: 0).tap()
    }

    private func assertNoBluetoothPrompt(app: XCUIApplication) {
        let bluetooth = NSPredicate(format: "label CONTAINS[c] %@", "Bluetooth")
        XCTAssertFalse(app.alerts.matching(bluetooth).firstMatch.exists)
        XCTAssertFalse(XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.matching(bluetooth).firstMatch.exists)
    }

    private func inventory(_ name: String, app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label BEGINSWITH %@", "showInventory.item.", name)).firstMatch
    }

    private func inventoryID(of row: XCUIElement) -> String {
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        let value = String(row.identifier.dropFirst("showInventory.item.".count))
        XCTAssertNotNil(UUID(uuidString: value))
        return value
    }

    private func assertContains(_ value: String, element: XCUIElement,
                                file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.waitForExistence(timeout: 5), file: file, line: line)
        let text = element.label + " " + element.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " ")
        XCTAssertTrue(text.contains(value), "Expected \(value), received \(text)", file: file, line: line)
    }

    private func enter(_ value: String, field: XCUIElement, app: XCUIApplication) {
        tap(field, app: app)
        if let existing = field.value as? String, existing != field.placeholderValue, !existing.isEmpty {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count))
        }
        if !value.isEmpty { field.typeText(value) }
    }

    private func reveal(_ element: XCUIElement, app: XCUIApplication,
                        file: StaticString = #filePath, line: UInt = #line) {
        if element.exists && element.isHittable { return }
        let list = app.collectionViews.firstMatch
        for _ in 0..<4 { list.swipeDown() }
        for _ in 0..<10 {
            if element.exists && element.isHittable { return }
            list.swipeUp()
        }
        XCTFail("Expected label control was not visible: \(element.identifier)", file: file, line: line)
    }

    private func tap(_ element: XCUIElement, app: XCUIApplication,
                     file: StaticString = #filePath, line: UInt = #line) {
        reveal(element, app: app, file: file, line: line)
        element.tap()
    }
}
