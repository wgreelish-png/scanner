import XCTest

/// Automatic printer discovery is disabled for these offline UI fixtures.
/// Queue files use the same isolated token as inventory and financial records.
@MainActor final class InventoryLabelsUITests: XCTestCase {
    func testSelectedInventoryIsReadyImmediatelyOnFirstNavigation() {
        continueAfterFailure = false
        let app = launch()
        defer { app.terminate() }
        tap(app.buttons["show.inventory"], app: app)
        let stockAID = inventoryID(of: inventory("Stock A", app: app))
        openBatch(app: app)
        tap(app.buttons["labels.select." + stockAID], app: app)
        tap(app.buttons["labels.continueSelection"], app: app)

        assertInventoryReadyWithoutInteraction(price: "$35", labels: 1, app: app)
        app.buttons["labels.prepare"].tap()
        XCTAssertTrue(app.navigationBars["Label Print Queue"].waitForExistence(timeout: 5))
        assertContains("0/1 completed", element: app.staticTexts["labelQueue.progress"])
        let queued = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "labelQueue.entry.")).firstMatch
        reveal(queued, app: app)
        assertContains("Stock A", element: queued)
        assertContains("$35", element: queued)
        XCTAssertFalse(app.buttons["labelQueue.print"].isEnabled, "Preparation cannot start a hardware print")
        assertNoBluetoothPrompt(app: app)
    }

    func testReselectedInventoryIsReadyImmediatelyWithoutLayoutChanges() {
        continueAfterFailure = false
        let app = launch()
        defer { app.terminate() }
        tap(app.buttons["show.inventory"], app: app)
        let stockAID = inventoryID(of: inventory("Stock A", app: app))
        let stockBID = inventoryID(of: inventory("Stock B", app: app))
        openBatch(app: app)
        tap(app.buttons["labels.select." + stockAID], app: app)
        tap(app.buttons["labels.continueSelection"], app: app)
        assertInventoryReadyWithoutInteraction(price: "$35", labels: 1, app: app)

        UITestInteraction.tapToolbar(app.navigationBars.buttons.element(boundBy: 0), in: app, identifier: "navigation.back")
        XCTAssertTrue(app.navigationBars["Select Label Cards"].waitForExistence(timeout: 5))
        tap(app.buttons["labels.select." + stockAID], app: app)
        tap(app.buttons["labels.select." + stockBID], app: app)
        tap(app.buttons["labels.continueSelection"], app: app)
        assertInventoryReadyWithoutInteraction(price: "$5", labels: 1, app: app)
        assertNoBluetoothPrompt(app: app)
    }

    func testPrintAllIsReadyImmediatelyWithoutLayoutChanges() {
        continueAfterFailure = false
        let app = launch()
        defer { app.terminate() }
        tap(app.buttons["show.priceTags"], app: app)
        tap(app.buttons["priceTags.all"], app: app)
        assertInventoryReadyWithoutInteraction(price: "$35", labels: 3, app: app)
        assertNoBluetoothPrompt(app: app)
    }

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
        XCTAssertTrue(app.navigationBars["Card Research"].waitForExistence(timeout: 5))
        let market = app.segmentedControls["cardResearch.section"].buttons["Market"]
        XCTAssertTrue(market.waitForExistence(timeout: 5)); XCTAssertTrue(market.isSelected)
        UITestInteraction.tapToolbar(app.descendants(matching: .any).matching(identifier: "cardResearch.options").firstMatch,
                                     in: app, identifier: "cardResearch.options")
        tap(app.buttons["cardResearch.inventoryDetails"], app: app)
        XCTAssertTrue(app.navigationBars["Card Details"].waitForExistence(timeout: 5))
        assertContains("$35.00", element: app.staticTexts["$35.00"])
        assertContains("Cost unknown", element: app.descendants(matching: .any)["inventory.cost"])
        UITestInteraction.tapToolbar(app.descendants(matching: .any).matching(identifier: "inventory.options").firstMatch,
                                     in: app, identifier: "inventory.options")
        tap(app.buttons["inventory.printLabel"], app: app)
        XCTAssertTrue(app.navigationBars["Label Details"].waitForExistence(timeout: 5))
        assertContains("1 labels", element: app.staticTexts["labels.totalCount"])
        tap(app.buttons["labels.style"], app: app)
        tap(app.buttons["Card details"], app: app)

        let edit = app.buttons["labels.edit." + inventoryID]
        tap(edit, app: app)
        assertNoPrintingPricePrompts(app: app)
        XCTAssertEqual(app.textFields["labels.editor.price"].value as? String, "35")
        XCTAssertEqual(app.textFields["labels.editor.copies"].value as? String, "1")
        enter("12", field: app.textFields["labels.editor.price"], app: app)
        tap(app.buttons["labels.editor.cancel"], app: app)
        assertContains("$35", element: edit)

        tap(edit, app: app)
        enter("", field: app.textFields["labels.editor.price"], app: app)
        XCTAssertTrue(app.buttons["labels.editor.save"].isEnabled, "An empty asking price leaves a write-in area")
        enter("0", field: app.textFields["labels.editor.price"], app: app)
        enter("101", field: app.textFields["labels.editor.copies"], app: app)
        XCTAssertEqual(app.textFields["labels.editor.copies"].value as? String, "101")
        XCTAssertFalse(app.buttons["labels.editor.save"].isEnabled, "Copies above the explicit limit remain visible for correction")
        enter("2", field: app.textFields["labels.editor.copies"], app: app)
        tap(app.buttons["labels.editor.keyboardDone"], app: app)
        tap(app.buttons["labels.editor.preview"], app: app)
        let preview = app.images["labels.bitmapPreview"].firstMatch
        reveal(preview, app: app)
        XCTAssertTrue((preview.value as? String ?? "").contains("Blank price · write in"))
        XCTAssertTrue((preview.value as? String ?? "").contains("Card details"))
        tap(app.buttons["labels.editor.save"], app: app)
        assertContains("Blank price · write in", element: edit)
        assertContains("2 labels", element: app.staticTexts["labels.totalCount"])
        tap(app.buttons["labels.continueReview"], app: app)
        assertContains("Blank price · write in", element: app.descendants(matching: .any)["labels.review.price." + inventoryID])
        assertContains("2", element: app.descendants(matching: .any)["labels.review.copies." + inventoryID])
        tap(app.buttons["labels.close"], app: app)

        XCTAssertTrue(app.navigationBars["Card Details"].waitForExistence(timeout: 5))
        reveal(app.staticTexts["$35.00"], app: app)
        XCTAssertTrue(app.staticTexts["$35.00"].exists, "Label price edits must not change the saved market price")
        assertContains("Cost unknown", element: app.descendants(matching: .any)["inventory.cost"])
        UITestInteraction.tapToolbar(app.navigationBars.buttons.element(boundBy: 0), in: app, identifier: "navigation.back")
        XCTAssertTrue(app.navigationBars["Card Research"].waitForExistence(timeout: 5))
        UITestInteraction.tapToolbar(app.navigationBars.buttons.element(boundBy: 0), in: app, identifier: "navigation.back")
        XCTAssertTrue(app.navigationBars["Show Inventory"].waitForExistence(timeout: 5))
        assertContains("3 cards available", element: app.staticTexts["showInventory.quantity"])
        UITestInteraction.tapToolbar(app.navigationBars.buttons.element(boundBy: 0), in: app, identifier: "navigation.back")
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
        assertInitialInventoryPreview("$35", app: app)

        UITestInteraction.tapToolbar(app.navigationBars.buttons.element(boundBy: 0), in: app, identifier: "navigation.back")
        XCTAssertTrue(app.navigationBars["Select Label Cards"].waitForExistence(timeout: 5))
        tap(app.buttons["labels.select." + stockAID], app: app)
        tap(app.buttons["labels.continueSelection"], app: app)
        assertContains("1 labels", element: app.staticTexts["labels.totalCount"])
        assertInitialInventoryPreview("$5", app: app)

        UITestInteraction.tapToolbar(app.navigationBars.buttons.element(boundBy: 0), in: app, identifier: "navigation.back")
        XCTAssertTrue(app.navigationBars["Select Label Cards"].waitForExistence(timeout: 5))
        tap(app.buttons["labels.select." + stockAID], app: app)
        tap(app.buttons["labels.continueSelection"], app: app)
        assertContains("2 labels", element: app.staticTexts["labels.totalCount"])
        assertInitialInventoryPreview("$35", app: app)
        tap(app.buttons["labels.matchQuantities"], app: app)
        assertContains("3 labels", element: app.staticTexts["labels.totalCount"])
        tap(app.buttons["labels.oneEach"], app: app)
        assertContains("2 labels", element: app.staticTexts["labels.totalCount"])

        tap(app.buttons["labels.individualEdits"], app: app)
        tap(app.buttons["labels.edit." + stockAID], app: app)
        enter("32.50", field: app.textFields["labels.editor.price"], app: app)
        XCTAssertFalse(app.buttons["labels.editor.save"].isEnabled, "Individual tags reject cents")
        enter("32", field: app.textFields["labels.editor.price"], app: app)
        tap(app.buttons["labels.editor.keyboardDone"], app: app)
        tap(app.buttons["labels.editor.save"], app: app)

        tap(app.buttons["labels.style"], app: app)
        tap(app.buttons["PokéDen price"], app: app)
        tap(app.buttons["labels.paper"], app: app)
        tap(app.buttons["40 × 12 mm"], app: app)
        let preview = app.images["labels.bitmapPreview"].firstMatch
        reveal(preview, app: app)
        XCTAssertTrue((preview.value as? String ?? "").contains("PokéDen price"))
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
        assertNoPrintingPricePrompts(app: app)
        XCTAssertTrue(app.buttons["labels.prepare"].isEnabled, "Known label prices do not require cost or profit approval")
        XCTAssertTrue(app.buttons["labels.prepare"].isHittable, "The final action stays available after reviewing every label")
        tap(app.buttons["labels.prepare"], app: app)
        assertUnstartedQueue(app: app)
        closeBatchToInventory(app: app)
        assertContains("3 cards available", element: app.staticTexts["showInventory.quantity"])
        UITestInteraction.tapToolbar(app.navigationBars.buttons.element(boundBy: 0), in: app, identifier: "navigation.back")
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
        XCTAssertFalse(app.buttons["labels.prepare"].isEnabled, "An unfinished saved queue must be cleared before preparing another batch")
        tap(app.buttons["labels.reviewSavedQueue"], app: app)
        assertUnstartedQueue(app: app)
        let queued = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "labelQueue.entry.")).firstMatch
        tap(queued, app: app)
        XCTAssertTrue(app.navigationBars["Queued Label"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.images["labels.bitmapPreview"].waitForExistence(timeout: 5))
        assertNoBluetoothPrompt(app: app)
    }

    func testExplicitlySelectedCardQueuesReplacementAfterKeepingExistingStickerAcrossRelaunch() {
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
        tap(app.buttons["labels.prepare"], app: app)
        assertContains("Label choices saved. No individual labels need printing.",
            element: app.staticTexts["labels.preparationNotice"])
        XCTAssertTrue(app.navigationBars["Review Labels"].exists)
        XCTAssertFalse(app.navigationBars["Label Print Queue"].exists)
        closeBatchToInventory(app: app)
        assertContains("3 cards available", element: app.staticTexts["showInventory.quantity"])

        app.terminate()
        app.launch()
        XCTAssertTrue(app.navigationBars["Show"].waitForExistence(timeout: 10))
        tap(app.buttons["show.inventory"], app: app)
        openBatch(app: app)
        tap(app.buttons["labels.select." + stockAID], app: app)
        tap(app.buttons["labels.continueSelection"], app: app)
        assertContains("1 labels", element: app.staticTexts["labels.totalCount"])
        let preview = app.images["labels.bitmapPreview"].firstMatch
        reveal(preview, app: app)
        XCTAssertTrue((preview.value as? String ?? "").contains("$35"),
                      "Explicitly selecting an already-labeled card prepares its unchanged price for a replacement tag")
        assertNoPrintingPricePrompts(app: app)
        XCTAssertTrue(app.buttons["labels.prepare"].isEnabled)
        tap(app.buttons["labels.prepare"], app: app)
        XCTAssertTrue(app.navigationBars["Label Print Queue"].waitForExistence(timeout: 5))
        assertContains("0/1 completed", element: app.staticTexts["labelQueue.progress"])
        assertContains("1", element: app.descendants(matching: .any)["labelQueue.totalCount"])
        let entry = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "labelQueue.entry.")).firstMatch
        reveal(entry, app: app)
        assertContains("Stock A", element: entry)
        assertContains("$35", element: entry)
        XCTAssertFalse(app.buttons["labelQueue.print"].isEnabled)
        XCTAssertFalse(app.buttons["labelQueue.pause"].exists)
        assertNoBluetoothPrompt(app: app)
        closeBatchToInventory(app: app)
        assertContains("3 cards available", element: app.staticTexts["showInventory.quantity"])
        assertContains("$35.00", element: inventory("Stock A", app: app))
        assertContains("Qty 2", element: inventory("Stock A", app: app))
        assertContains("$5.00", element: inventory("Stock B", app: app))
        assertContains("Qty 1", element: inventory("Stock B", app: app))
        UITestInteraction.tapToolbar(app.navigationBars.buttons.element(boundBy: 0), in: app, identifier: "navigation.back")
        assertBalances(app: app)
    }

    func testPrintAllStartsWithStockQuantitiesAndPreviewCancelPreservesInventoryAndBudget() {
        continueAfterFailure = false
        let app = launch()
        defer { app.terminate() }
        assertBalances(app: app)
        tap(app.buttons["show.inventory"], app: app)
        assertContains("3 cards available", element: app.staticTexts["showInventory.quantity"])
        let stockAID = inventoryID(of: inventory("Stock A", app: app))
        let stockBID = inventoryID(of: inventory("Stock B", app: app))
        openPriceTags(app: app)
        XCTAssertTrue(app.buttons["priceTags.all"].exists)
        XCTAssertTrue(app.buttons["priceTags.changed"].exists)
        XCTAssertTrue(app.buttons["priceTags.chooseCards"].exists)
        XCTAssertTrue(app.buttons["priceTags.custom"].exists)
        tap(app.buttons["priceTags.all"], app: app)

        XCTAssertTrue(app.navigationBars["Label Details"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.navigationBars["Select Label Cards"].exists, "Print All opens details directly")
        assertContains("3 labels", element: app.staticTexts["labels.totalCount"])
        XCTAssertTrue(app.buttons["labels.continueReview"].isHittable,
                      "Review stays pinned and does not require scrolling through the stock list")
        XCTAssertTrue(app.buttons["labels.continueReview"].isEnabled)
        let preview = app.images["labels.bitmapPreview"].firstMatch
        reveal(preview, app: app)
        XCTAssertTrue(preview.exists)
        assertNoBluetoothPrompt(app: app)
        tap(app.buttons["labels.continueReview"], app: app)
        XCTAssertTrue(app.navigationBars["Review Labels"].waitForExistence(timeout: 5))
        assertContains("3", element: app.descendants(matching: .any)["labels.reviewCount"])
        for (id, price, copies) in [(stockAID, "$35", "2"), (stockBID, "$5", "1")] {
            let amount = app.descendants(matching: .any)["labels.review.price." + id]
            reveal(amount, app: app)
            assertContains(price, element: amount)
            assertContains(copies, element: app.descendants(matching: .any)["labels.review.copies." + id])
        }
        assertNoPrintingPricePrompts(app: app)
        XCTAssertTrue(app.buttons["labels.prepare"].isEnabled, "Existing prices can be prepared without another approval")
        XCTAssertFalse(app.navigationBars["Label Print Queue"].exists)
        assertNoBluetoothPrompt(app: app)
        closeBatchToInventory(app: app)

        assertContains("3 cards available", element: app.staticTexts["showInventory.quantity"])
        assertContains("$35.00", element: inventory("Stock A", app: app))
        assertContains("Qty 2", element: inventory("Stock A", app: app))
        assertContains("$5.00", element: inventory("Stock B", app: app))
        assertContains("Qty 1", element: inventory("Stock B", app: app))
        UITestInteraction.tapToolbar(app.navigationBars.buttons.element(boundBy: 0), in: app, identifier: "navigation.back")
        assertBalances(app: app)
        assertNoBluetoothPrompt(app: app)
    }

    func testChooseCardsSelectAllAndSharedPriceRemainDraftsUntilPrepared() {
        continueAfterFailure = false
        let app = launch()
        defer { app.terminate() }
        assertBalances(app: app)
        tap(app.buttons["show.inventory"], app: app)
        let stockAID = inventoryID(of: inventory("Stock A", app: app))
        let stockBID = inventoryID(of: inventory("Stock B", app: app))
        openBatch(app: app)
        XCTAssertTrue(app.navigationBars["Select Label Cards"].waitForExistence(timeout: 5))
        tap(app.buttons["labels.selectAll"], app: app)
        assertContains("2 cards selected", element: app.staticTexts["labels.selectedCount"])
        tap(app.buttons["labels.continueSelection"], app: app)
        assertContains("2 labels", element: app.staticTexts["labels.totalCount"])
        tap(app.buttons["labels.individualEdits"], app: app)

        tap(app.buttons["labels.setBatchPrice"], app: app)
        enter("6", field: app.textFields["labels.batchPrice.amount"], app: app)
        tap(app.buttons["labels.batchPrice.cancel"], app: app)
        assertContains("$35", element: app.buttons["labels.edit." + stockAID])
        assertContains("$5", element: app.buttons["labels.edit." + stockBID])

        tap(app.buttons["labels.setBatchPrice"], app: app)
        enter("7", field: app.textFields["labels.batchPrice.amount"], app: app)
        tap(app.buttons["labels.batchPrice.keyboardDone"], app: app)
        tap(app.buttons["labels.batchPrice.apply"], app: app)
        for id in [stockAID, stockBID] {
            assertContains("$7", element: app.buttons["labels.edit." + id])
        }
        assertContains("2 labels", element: app.staticTexts["labels.totalCount"])
        tap(app.buttons["labels.continueReview"], app: app)
        XCTAssertTrue(app.navigationBars["Review Labels"].waitForExistence(timeout: 5))
        for id in [stockAID, stockBID] {
            let amount = app.descendants(matching: .any)["labels.review.price." + id]
            reveal(amount, app: app)
            assertContains("$7", element: amount)
            let labels = [amount.label] + amount.staticTexts.allElementsBoundByIndex.map(\.label)
            XCTAssertTrue(labels.contains { $0 == "$7" || $0.hasSuffix(", $7") || $0.hasSuffix(" $7") },
                          "Each card must have the exact $7 shared asking price")
            assertContains("1", element: app.descendants(matching: .any)["labels.review.copies." + id])
        }
        assertNoPrintingPricePrompts(app: app)
        XCTAssertTrue(app.buttons["labels.prepare"].isEnabled)
        XCTAssertFalse(app.navigationBars["Label Print Queue"].exists)
        assertNoBluetoothPrompt(app: app)
        closeBatchToInventory(app: app)

        assertContains("3 cards available", element: app.staticTexts["showInventory.quantity"])
        assertContains("$35.00", element: inventory("Stock A", app: app))
        assertContains("Qty 2", element: inventory("Stock A", app: app))
        assertContains("$5.00", element: inventory("Stock B", app: app))
        assertContains("Qty 1", element: inventory("Stock B", app: app))
        UITestInteraction.tapToolbar(app.navigationBars.buttons.element(boundBy: 0), in: app, identifier: "navigation.back")
        assertBalances(app: app)
        assertNoBluetoothPrompt(app: app)
    }

    func testStandaloneCustomPriceAndCopiesPrepareWithoutInventoryApprovalOrAutomaticPrinting() {
        continueAfterFailure = false
        let app = launch()
        defer { app.terminate() }
        assertBalances(app: app)
        tap(app.buttons["show.priceTags"], app: app)
        XCTAssertTrue(app.navigationBars["Price Tags"].waitForExistence(timeout: 5))
        tap(app.buttons["priceTags.custom"], app: app)
        XCTAssertTrue(app.navigationBars["Custom Price Tag"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.navigationBars["Select Label Cards"].exists)
        XCTAssertEqual(app.textFields["customLabels.copies"].value as? String, "1")
        XCTAssertTrue(app.descendants(matching: .any)["customLabels.paper"].exists)
        enter("5", field: app.textFields["customLabels.price"], app: app)
        enter("3", field: app.textFields["customLabels.copies"], app: app)
        tap(app.buttons["customLabels.keyboardDone"], app: app)
        let tag = app.segmentedControls["customLabels.tag"]
        tap(tag.buttons["2 for $1"], app: app)
        XCTAssertFalse(app.textFields["customLabels.price"].exists)
        tap(tag.buttons["Individual price"], app: app)
        XCTAssertEqual(app.textFields["customLabels.price"].value as? String, "5",
                       "Switching tag kinds retains the individual price input")
        let preview = app.images["customLabels.preview"].firstMatch
        reveal(preview, app: app)
        XCTAssertTrue((preview.label + " " + (preview.value as? String ?? "")).contains("$5"))
        XCTAssertFalse(app.switches["labels.acknowledgePricingWarnings"].exists,
                       "A standalone price tag does not claim profitability for an unrelated inventory card")
        XCTAssertTrue(app.buttons["customLabels.prepare"].isEnabled)
        assertNoBluetoothPrompt(app: app)
        tap(app.buttons["customLabels.prepare"], app: app)
        XCTAssertTrue(app.navigationBars["Label Print Queue"].waitForExistence(timeout: 5))
        assertContains("0/3 completed", element: app.staticTexts["labelQueue.progress"])
        assertContains("3", element: app.descendants(matching: .any)["labelQueue.totalCount"])
        XCTAssertFalse(app.buttons["labelQueue.print"].isEnabled)
        XCTAssertFalse(app.buttons["labelQueue.pause"].exists)
        let status = app.staticTexts["labelPrinter.status"]
        reveal(status, app: app)
        assertContains("Search for a NIIMBOT D110", element: status)
        assertNoBluetoothPrompt(app: app)

        UITestInteraction.tapToolbar(app.navigationBars.buttons.element(boundBy: 0), in: app, identifier: "navigation.back")
        XCTAssertTrue(app.navigationBars["Custom Price Tag"].waitForExistence(timeout: 5))
        UITestInteraction.tapToolbar(app.navigationBars.buttons.element(boundBy: 0), in: app, identifier: "navigation.back")
        XCTAssertTrue(app.navigationBars["Price Tags"].waitForExistence(timeout: 5))
        UITestInteraction.tapToolbar(app.navigationBars.buttons.element(boundBy: 0), in: app, identifier: "navigation.back")
        XCTAssertTrue(app.navigationBars["Show"].waitForExistence(timeout: 5))
        assertBalances(app: app)
        tap(app.buttons["show.inventory"], app: app)
        assertContains("3 cards available", element: app.staticTexts["showInventory.quantity"])
        assertContains("$35.00", element: inventory("Stock A", app: app))
        assertContains("Qty 2", element: inventory("Stock A", app: app))
        assertContains("$5.00", element: inventory("Stock B", app: app))
        assertContains("Qty 1", element: inventory("Stock B", app: app))
        assertNoBluetoothPrompt(app: app)
    }

    func testUnavailableAndZeroInventoryPricesPrepareWriteInLabelsAlongsidePricedAndDealTags() {
        continueAfterFailure = false
        let app = launch(extraArguments: ["--inventory-write-in-labels-fixture", "--inventory-bulk-labels-fixture"])
        defer { app.terminate() }
        assertBalances(app: app)
        tap(app.buttons["show.inventory"], app: app)
        assertContains("6 cards available", element: app.staticTexts["showInventory.quantity"])
        let names = ["Unavailable Stock", "Zero Stock"]
        var ids: [String: String] = [:], descriptions: [String: String] = [:]
        for name in names {
            let row = inventory(name, app: app)
            reveal(row, app: app)
            ids[name] = inventoryID(of: row)
            descriptions[name] = row.label
        }
        openPriceTags(app: app)
        tap(app.buttons["priceTags.all"], app: app)
        assertContains("6 labels", element: app.staticTexts["labels.totalCount"])
        XCTAssertFalse(app.buttons["labels.skipUnpriced"].exists)
        tap(app.buttons["labels.continueReview"], app: app)
        assertContains("6", element: app.descendants(matching: .any)["labels.reviewCount"])
        for name in names {
            let id = ids[name]!
            let amount = app.descendants(matching: .any)["labels.review.price." + id]
            reveal(amount, app: app)
            assertContains("Blank price · write in", element: amount)
            XCTAssertFalse(app.switches["labels.keepExistingSticker." + id].exists)
        }
        tap(app.buttons["labels.expandReview." + ids["Unavailable Stock"]!], app: app)
        let preview = app.images["labels.bitmapPreview"].firstMatch
        reveal(preview, app: app)
        XCTAssertTrue((preview.value as? String ?? "").contains("Blank price · write in"))
        XCTAssertFalse((preview.value as? String ?? "").contains("$0"))
        XCTAssertTrue(app.buttons["labels.prepare"].isEnabled)
        tap(app.buttons["labels.prepare"], app: app)
        assertContains("0/6 completed", element: app.staticTexts["labelQueue.progress"])
        for name in names {
            let receipt = app.buttons.matching(NSPredicate(format:
                "identifier BEGINSWITH %@ AND label CONTAINS %@", "labelQueue.entry.", name)).firstMatch
            reveal(receipt, app: app)
            assertContains("Blank price · write in", element: receipt)
            XCTAssertFalse(receipt.label.contains("$0"))
        }
        let deal = app.buttons.matching(NSPredicate(format:
            "identifier BEGINSWITH %@ AND label CONTAINS %@", "labelQueue.entry.", "Bulk Stock")).firstMatch
        reveal(deal, app: app)
        assertContains("2 for $1", element: deal)
        XCTAssertFalse(app.buttons["labelQueue.print"].isEnabled)
        clearQueue("labelQueue.clearQueue", app: app)
        tap(app.buttons["labels.close"], app: app)

        tap(app.buttons["priceTags.chooseCards"], app: app)
        for name in names { tap(app.buttons["labels.select." + ids[name]!], app: app) }
        tap(app.buttons["labels.continueSelection"], app: app)
        assertContains("2 labels", element: app.staticTexts["labels.totalCount"])
        tap(app.buttons["labels.individualEdits"], app: app)
        tap(app.buttons["labels.edit." + ids["Zero Stock"]!], app: app)
        enter("", field: app.textFields["labels.editor.price"], app: app)
        XCTAssertTrue(app.buttons["labels.editor.save"].isEnabled, "A blank field is an intentional write-in label")
        tap(app.buttons["labels.editor.keyboardDone"], app: app)
        tap(app.buttons["labels.editor.preview"], app: app)
        reveal(preview, app: app)
        XCTAssertTrue((preview.value as? String ?? "").contains("Blank price · write in"))
        tap(app.buttons["labels.editor.save"], app: app)
        XCTAssertTrue(app.buttons["labels.prepare"].isEnabled, "A blank-only batch needs no fabricated zero-price approval")
        tap(app.buttons["labels.prepare"], app: app)
        assertContains("0/2 completed", element: app.staticTexts["labelQueue.progress"])
        clearQueue("labelQueue.clearQueue", app: app)
        closeBatchToInventory(app: app)
        assertContains("6 cards available", element: app.staticTexts["showInventory.quantity"])
        for name in names {
            let row = inventory(name, app: app)
            reveal(row, app: app)
            XCTAssertEqual(row.label, descriptions[name], "Preparing blank labels cannot set an inventory price or change its category")
        }
        UITestInteraction.tapToolbar(app.navigationBars.buttons.element(boundBy: 0), in: app, identifier: "navigation.back")
        assertBalances(app: app)
        assertNoBluetoothPrompt(app: app)
    }

    func testMixedAndAllBulkInventoryBatchesIncludeEveryRequestedCopyAndDealPreview() {
        continueAfterFailure = false
        let app = launch(extraArguments: ["--inventory-bulk-labels-fixture"])
        defer { app.terminate() }
        assertBalances(app: app)
        tap(app.buttons["show.inventory"], app: app)
        assertContains("4 cards available", element: app.staticTexts["showInventory.quantity"])
        let bulkID = inventoryID(of: inventory("Bulk Stock", app: app))
        openPriceTags(app: app)
        tap(app.buttons["priceTags.all"], app: app)
        assertContains("4 labels", element: app.staticTexts["labels.totalCount"])
        tap(app.buttons["labels.continueReview"], app: app)
        assertContains("4", element: app.descendants(matching: .any)["labels.reviewCount"])
        let included = app.descendants(matching: .any)["labels.reviewBulkCount"]
        assertContains("included in total", element: included)
        assertContains("1", element: included)
        tap(app.buttons["labels.expandReview." + bulkID], app: app)
        let preview = app.images["labels.bitmapPreview"].firstMatch
        reveal(preview, app: app)
        XCTAssertTrue((preview.value as? String ?? "").contains("2 for $1"))
        XCTAssertTrue(app.buttons["labels.prepare"].isEnabled)
        assertNoPrintingPricePrompts(app: app)
        tap(app.buttons["labels.prepare"], app: app)
        assertContains("0/4 completed", element: app.staticTexts["labelQueue.progress"])
        let bulkReceipt = app.buttons.matching(NSPredicate(format:
            "identifier BEGINSWITH %@ AND label CONTAINS %@", "labelQueue.entry.", "Bulk Stock")).firstMatch
        reveal(bulkReceipt, app: app)
        assertContains("2 for $1", element: bulkReceipt)
        XCTAssertFalse(app.buttons["labelQueue.print"].isEnabled)
        clearQueue("labelQueue.clearQueue", app: app)
        tap(app.buttons["labels.close"], app: app)
        XCTAssertTrue(app.navigationBars["Price Tags"].waitForExistence(timeout: 5))

        tap(app.buttons["priceTags.chooseCards"], app: app)
        tap(app.buttons["labels.select." + bulkID], app: app)
        tap(app.buttons["labels.continueSelection"], app: app)
        assertContains("1 labels", element: app.staticTexts["labels.totalCount"])
        reveal(preview, app: app)
        XCTAssertTrue((preview.value as? String ?? "").contains("2 for $1"),
                      "A batch containing only a 2 for $1 inventory card still has a printable preview")
        tap(app.buttons["labels.edit." + bulkID], app: app)
        XCTAssertFalse(app.textFields["labels.editor.price"].exists, "Printing retains the saved deal")
        enter("2", field: app.textFields["labels.editor.copies"], app: app)
        tap(app.buttons["labels.editor.keyboardDone"], app: app)
        tap(app.buttons["labels.editor.preview"], app: app)
        reveal(preview, app: app)
        XCTAssertTrue((preview.value as? String ?? "").contains("2 for $1"))
        XCTAssertTrue(app.buttons["labels.editor.save"].isEnabled)
        tap(app.buttons["labels.editor.save"], app: app)
        assertContains("2 labels", element: app.staticTexts["labels.totalCount"])
        tap(app.buttons["labels.continueReview"], app: app)
        assertContains("2", element: app.descendants(matching: .any)["labels.reviewCount"])
        assertContains("2", element: app.descendants(matching: .any)["labels.reviewBulkCount"])
        tap(app.buttons["labels.prepare"], app: app)
        assertContains("0/2 completed", element: app.staticTexts["labelQueue.progress"])
        let allBulk = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "labelQueue.entry."))
        XCTAssertEqual(allBulk.count, 2)
        for receipt in allBulk.allElementsBoundByIndex {
            reveal(receipt, app: app)
            assertContains("Bulk Stock", element: receipt)
            assertContains("2 for $1", element: receipt)
        }
        assertNoBluetoothPrompt(app: app)
        closeBatchToInventory(app: app)
        assertContains("4 cards available", element: app.staticTexts["showInventory.quantity"])
        assertContains("Qty 1", element: inventory("Bulk Stock", app: app))
        UITestInteraction.tapToolbar(app.navigationBars.buttons.element(boundBy: 0), in: app, identifier: "navigation.back")
        assertBalances(app: app)
    }

    func testBulkTagsPrepareWithoutPriceUsingThirtyByFifteenPaperAndPersistWithoutPrinting() {
        continueAfterFailure = false
        let app = launch()
        defer { app.terminate() }
        assertBalances(app: app)
        tap(app.buttons["show.priceTags"], app: app)
        tap(app.buttons["priceTags.bulk"], app: app)
        XCTAssertTrue(app.navigationBars["Custom Price Tag"].waitForExistence(timeout: 5))
        let tag = app.segmentedControls["customLabels.tag"]
        XCTAssertTrue(tag.buttons["2 for $1"].isSelected)
        XCTAssertFalse(app.textFields["customLabels.price"].exists)
        XCTAssertTrue(app.buttons["customLabels.prepare"].isEnabled, "A bulk-bin tag does not require an individual price")
        tap(tag.buttons["Individual price"], app: app)
        XCTAssertTrue(app.textFields["customLabels.price"].exists)
        XCTAssertFalse(app.buttons["customLabels.prepare"].isEnabled, "The individual price stays blank rather than becoming a zero-price or bulk tag")
        tap(tag.buttons["2 for $1"], app: app)
        tap(app.buttons["customLabels.paper"], app: app)
        tap(app.buttons["30 × 15 mm"], app: app)
        enter("3", field: app.textFields["customLabels.copies"], app: app)
        tap(app.buttons["customLabels.keyboardDone"], app: app)
        let preview = app.images["customLabels.preview"].firstMatch
        reveal(preview, app: app)
        XCTAssertTrue((preview.value as? String ?? "").contains("2 for $1"))
        XCTAssertTrue((preview.value as? String ?? "").contains("30 × 15 mm"))
        XCTAssertFalse(app.switches["labels.acknowledgePricingWarnings"].exists)
        tap(app.buttons["customLabels.prepare"], app: app)
        XCTAssertTrue(app.navigationBars["Label Print Queue"].waitForExistence(timeout: 5))
        assertContains("0/3 completed", element: app.staticTexts["labelQueue.progress"])
        assertContains("30 × 15 mm", element: app.descendants(matching: .any)["labelQueue.paper"])
        assertContains("PokéDen price", element: app.descendants(matching: .any)["labelQueue.style"])
        let entry = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "labelQueue.entry.")).firstMatch
        reveal(entry, app: app)
        assertContains("2 for $1", element: entry)
        let entryID = entry.identifier
        XCTAssertFalse(app.buttons["labelQueue.print"].isEnabled)
        XCTAssertFalse(app.buttons["labelQueue.pause"].exists)
        assertNoBluetoothPrompt(app: app)

        app.terminate(); app.launch()
        XCTAssertTrue(app.navigationBars["Show"].waitForExistence(timeout: 10))
        assertBalances(app: app)
        tap(app.buttons["show.inventory"], app: app)
        assertContains("3 cards available", element: app.staticTexts["showInventory.quantity"])
        assertContains("Qty 2", element: inventory("Stock A", app: app))
        assertContains("$35.00", element: inventory("Stock A", app: app))
        assertContains("Qty 1", element: inventory("Stock B", app: app))
        assertContains("$5.00", element: inventory("Stock B", app: app))
        openPriceTags(app: app)
        assertContains("Last used: 30 × 15 mm", element: app.staticTexts["priceTags.paperSize"])
        tap(app.buttons["priceTags.queue"], app: app)
        assertContains("0/3 completed", element: app.staticTexts["labelQueue.progress"])
        assertContains("30 × 15 mm", element: app.descendants(matching: .any)["labelQueue.paper"])
        let restored = app.buttons[entryID]
        reveal(restored, app: app)
        assertContains("2 for $1", element: restored)
        XCTAssertFalse(app.buttons["labelQueue.print"].isEnabled)
        XCTAssertFalse(app.buttons["labelQueue.pause"].exists)
        assertNoBluetoothPrompt(app: app)
    }

    func testInventoryBatchPreparesKnownPricesWithoutApprovalsOrAnotherReviewPage() {
        continueAfterFailure = false
        let app = launch()
        defer { app.terminate() }
        assertBalances(app: app)
        tap(app.buttons["show.priceTags"], app: app)
        tap(app.buttons["priceTags.all"], app: app)
        XCTAssertTrue(app.navigationBars["Label Details"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.navigationBars["Review Labels"].exists)
        assertContains("3 labels", element: app.staticTexts["labels.totalCount"])
        assertNoPrintingPricePrompts(app: app)
        XCTAssertTrue(app.buttons["labels.prepare"].isEnabled, "Known prices prepare directly even when acquisition costs are unknown")
        assertContains("Prepare Labels", element: app.buttons["labels.prepare"])
        tap(app.buttons["labels.prepare"], app: app)
        XCTAssertTrue(app.navigationBars["Label Print Queue"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.navigationBars["Review Labels"].exists, "The primary action prepares the queue without an extra review screen")
        assertContains("0/3 completed", element: app.staticTexts["labelQueue.progress"])
        XCTAssertFalse(app.buttons["labelQueue.print"].isEnabled)
        XCTAssertFalse(app.buttons["labelQueue.pause"].exists)
        assertNoBluetoothPrompt(app: app)
        tap(app.buttons["labels.close"], app: app)
        XCTAssertTrue(app.navigationBars["Price Tags"].waitForExistence(timeout: 5))
        UITestInteraction.tapToolbar(app.navigationBars.buttons.element(boundBy: 0), in: app, identifier: "navigation.back")
        assertBalances(app: app)
        tap(app.buttons["show.inventory"], app: app)
        assertContains("3 cards available", element: app.staticTexts["showInventory.quantity"])
        assertContains("$35.00", element: inventory("Stock A", app: app))
        assertContains("Qty 2", element: inventory("Stock A", app: app))
        assertContains("$5.00", element: inventory("Stock B", app: app))
        assertContains("Qty 1", element: inventory("Stock B", app: app))
    }

    func testQueueCanBeClearedFromPriceTagsCustomAndQueueWithoutChangingInventory() {
        continueAfterFailure = false
        let app = launch()
        defer { app.terminate() }
        assertBalances(app: app)
        tap(app.buttons["show.priceTags"], app: app)
        XCTAssertFalse(app.buttons["priceTags.clearQueue"].isEnabled, "An empty queue has nothing to clear")
        tap(app.buttons["priceTags.custom"], app: app)
        XCTAssertFalse(app.buttons["customLabels.clearQueue"].isEnabled)
        enter("5", field: app.textFields["customLabels.price"], app: app)
        enter("3", field: app.textFields["customLabels.copies"], app: app)
        tap(app.buttons["customLabels.keyboardDone"], app: app)
        tap(app.buttons["customLabels.prepare"], app: app)
        XCTAssertTrue(app.navigationBars["Label Print Queue"].waitForExistence(timeout: 5))
        assertContains("0/3 completed", element: app.staticTexts["labelQueue.progress"])
        UITestInteraction.tapToolbar(app.navigationBars.buttons.element(boundBy: 0), in: app, identifier: "navigation.back")
        UITestInteraction.tapToolbar(app.navigationBars.buttons.element(boundBy: 0), in: app, identifier: "navigation.back")
        XCTAssertTrue(app.navigationBars["Price Tags"].waitForExistence(timeout: 5))
        tap(app.buttons["priceTags.clearQueue"], app: app)
        tap(app.buttons["priceTags.clearQueue.cancel"], app: app)
        XCTAssertTrue(app.buttons["priceTags.clearQueue"].isEnabled, "Cancel retains the saved queue")
        tap(app.buttons["priceTags.queue"], app: app)
        assertContains("0/3 completed", element: app.staticTexts["labelQueue.progress"])
        UITestInteraction.tapToolbar(app.navigationBars.buttons.element(boundBy: 0), in: app, identifier: "navigation.back")
        clearQueue("priceTags.clearQueue", app: app)
        XCTAssertFalse(app.buttons["priceTags.clearQueue"].isEnabled)
        tap(app.buttons["priceTags.queue"], app: app)
        assertContains("0/0 completed", element: app.staticTexts["labelQueue.progress"])
        XCTAssertFalse(app.buttons["labelQueue.print"].isEnabled)
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "labelQueue.entry.")).firstMatch.exists)
        UITestInteraction.tapToolbar(app.navigationBars.buttons.element(boundBy: 0), in: app, identifier: "navigation.back")

        tap(app.buttons["priceTags.custom"], app: app)
        enter("9", field: app.textFields["customLabels.price"], app: app)
        enter("2", field: app.textFields["customLabels.copies"], app: app)
        tap(app.buttons["customLabels.keyboardDone"], app: app)
        tap(app.buttons["customLabels.prepare"], app: app)
        assertContains("0/2 completed", element: app.staticTexts["labelQueue.progress"])
        UITestInteraction.tapToolbar(app.navigationBars.buttons.element(boundBy: 0), in: app, identifier: "navigation.back")
        clearQueue("customLabels.clearQueue", app: app)
        XCTAssertFalse(app.buttons["customLabels.clearQueue"].isEnabled)
        XCTAssertEqual(app.textFields["customLabels.price"].value as? String, "9")
        XCTAssertEqual(app.textFields["customLabels.copies"].value as? String, "2")
        XCTAssertTrue(app.buttons["customLabels.prepare"].isEnabled, "Clearing the saved queue keeps the current draft ready")
        tap(app.buttons["customLabels.prepare"], app: app)
        assertContains("0/2 completed", element: app.staticTexts["labelQueue.progress"])
        clearQueue("labelQueue.clearQueue", app: app)
        assertContains("0/0 completed", element: app.staticTexts["labelQueue.progress"])
        XCTAssertFalse(app.buttons["labelQueue.clearQueue"].isEnabled)
        XCTAssertFalse(app.buttons["labelQueue.print"].isEnabled)
        assertNoBluetoothPrompt(app: app)

        app.terminate(); app.launch()
        XCTAssertTrue(app.navigationBars["Show"].waitForExistence(timeout: 10))
        assertBalances(app: app)
        tap(app.buttons["show.inventory"], app: app)
        assertContains("3 cards available", element: app.staticTexts["showInventory.quantity"])
        assertContains("$35.00", element: inventory("Stock A", app: app))
        assertContains("Qty 2", element: inventory("Stock A", app: app))
        assertContains("$5.00", element: inventory("Stock B", app: app))
        assertContains("Qty 1", element: inventory("Stock B", app: app))
        openPriceTags(app: app)
        tap(app.buttons["priceTags.queue"], app: app)
        assertContains("0/0 completed", element: app.staticTexts["labelQueue.progress"])
        XCTAssertFalse(app.buttons["labelQueue.clearQueue"].isEnabled)
        assertNoBluetoothPrompt(app: app)
    }

    func testRememberedLabelSizeIsSharedAcrossPreparationAndKeepsSavedQueueDimensions() {
        continueAfterFailure = false
        let app = launch()
        defer { app.terminate() }
        tap(app.buttons["show.priceTags"], app: app)
        tap(app.buttons["priceTags.custom"], app: app)
        tap(app.buttons["customLabels.paper"], app: app)
        tap(app.buttons["40 × 12 mm"], app: app)
        enter("5", field: app.textFields["customLabels.price"], app: app)
        enter("3", field: app.textFields["customLabels.copies"], app: app)
        tap(app.buttons["customLabels.keyboardDone"], app: app)
        tap(app.buttons["customLabels.prepare"], app: app)
        XCTAssertTrue(app.navigationBars["Label Print Queue"].waitForExistence(timeout: 5))
        assertContains("40 × 12 mm", element: app.descendants(matching: .any)["labelQueue.paper"])
        assertContains("0/3 completed", element: app.staticTexts["labelQueue.progress"])
        let queued = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "labelQueue.entry.")).firstMatch
        reveal(queued, app: app)
        XCTAssertTrue(queued.exists)
        let queuedID = queued.identifier, queuedDescription = queued.label

        UITestInteraction.tapToolbar(app.navigationBars.buttons.element(boundBy: 0), in: app, identifier: "navigation.back")
        XCTAssertTrue(app.navigationBars["Custom Price Tag"].waitForExistence(timeout: 5))
        tap(app.buttons["customLabels.paper"], app: app)
        tap(app.buttons["50 × 14 mm"], app: app)
        assertContains("50 × 14 mm", element: app.descendants(matching: .any)["customLabels.paper"])
        UITestInteraction.tapToolbar(app.navigationBars.buttons.element(boundBy: 0), in: app, identifier: "navigation.back")
        XCTAssertTrue(app.navigationBars["Price Tags"].waitForExistence(timeout: 5))
        assertContains("Last used: 50 × 14 mm", element: app.staticTexts["priceTags.paperSize"])
        tap(app.buttons["priceTags.queue"], app: app)
        XCTAssertTrue(app.navigationBars["Label Print Queue"].waitForExistence(timeout: 5))
        assertContains("40 × 12 mm", element: app.descendants(matching: .any)["labelQueue.paper"])
        assertContains("0/3 completed", element: app.staticTexts["labelQueue.progress"])
        let unchangedEntry = app.buttons[queuedID]
        reveal(unchangedEntry, app: app)
        XCTAssertEqual(unchangedEntry.label, queuedDescription,
                       "A new paper preference cannot resize, complete or reprint saved labels")
        XCTAssertFalse(app.buttons["labelQueue.print"].isEnabled)
        XCTAssertFalse(app.buttons["labelQueue.pause"].exists)
        assertNoBluetoothPrompt(app: app)

        app.terminate(); app.launch()
        XCTAssertTrue(app.navigationBars["Show"].waitForExistence(timeout: 10))
        tap(app.buttons["show.priceTags"], app: app)
        assertContains("Last used: 50 × 14 mm", element: app.staticTexts["priceTags.paperSize"])
        tap(app.buttons["priceTags.custom"], app: app)
        XCTAssertTrue(app.navigationBars["Custom Price Tag"].waitForExistence(timeout: 5))
        assertContains("50 × 14 mm", element: app.descendants(matching: .any)["customLabels.paper"])
        UITestInteraction.tapToolbar(app.navigationBars.buttons.element(boundBy: 0), in: app, identifier: "navigation.back")
        tap(app.buttons["priceTags.all"], app: app)
        XCTAssertTrue(app.navigationBars["Label Details"].waitForExistence(timeout: 5))
        assertContains("50 × 14 mm", element: app.descendants(matching: .any)["labels.paper"])
        let preview = app.images["labels.bitmapPreview"].firstMatch
        reveal(preview, app: app)
        XCTAssertTrue((preview.value as? String ?? "").contains("50 × 14 mm"),
                      "Inventory drafts and their initial preview use the remembered physical size")
        tap(app.buttons["labels.close"], app: app)
        XCTAssertTrue(app.navigationBars["Price Tags"].waitForExistence(timeout: 5))
        UITestInteraction.tapToolbar(app.navigationBars.buttons.element(boundBy: 0), in: app, identifier: "navigation.back")
        assertBalances(app: app)
        tap(app.buttons["show.inventory"], app: app)
        assertContains("3 cards available", element: app.staticTexts["showInventory.quantity"])
        assertNoBluetoothPrompt(app: app)
    }

    func testPricePositionPersistsAcrossPreparationPathsAndDoesNotRedrawSavedLabels() {
        continueAfterFailure = false
        let app = launch()
        defer { app.terminate() }
        tap(app.buttons["show.inventory"], app: app)
        let stockAID = inventoryID(of: inventory("Stock A", app: app))
        openPriceTags(app: app)
        tap(app.buttons["priceTags.printer"], app: app)
        let defaults = app.segmentedControls["labelPrinter.pricePosition"]
        tap(defaults.buttons["Price Left"], app: app)
        XCTAssertTrue(defaults.buttons["Price Left"].isSelected)
        UITestInteraction.tapToolbar(app.navigationBars.buttons.element(boundBy: 0), in: app, identifier: "navigation.back")
        assertContains("Price Left", element: app.staticTexts["priceTags.pricePosition"])
        tap(app.buttons["priceTags.custom"], app: app)
        let customPosition = app.segmentedControls["customLabels.pricePosition"]
        XCTAssertTrue(customPosition.buttons["Price Left"].isSelected)
        enter("5", field: app.textFields["customLabels.price"], app: app)
        enter("2", field: app.textFields["customLabels.copies"], app: app)
        tap(app.buttons["customLabels.keyboardDone"], app: app)
        let customPreview = app.images["customLabels.preview"].firstMatch
        reveal(customPreview, app: app)
        XCTAssertTrue((customPreview.value as? String ?? "").contains("Price Left"))
        tap(app.buttons["customLabels.prepare"], app: app)
        assertContains("0/2 completed", element: app.staticTexts["labelQueue.progress"])
        let entry = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "labelQueue.entry.")).firstMatch
        reveal(entry, app: app)
        let queuedID = entry.identifier
        tap(entry, app: app)
        XCTAssertTrue(app.navigationBars["Queued Label"].waitForExistence(timeout: 5))
        let queuedPreview = app.images["labels.bitmapPreview"].firstMatch
        reveal(queuedPreview, app: app)
        let queuedArtwork = queuedPreview.screenshot().pngRepresentation
        UITestInteraction.tapToolbar(app.navigationBars["Queued Label"].buttons["Done"], in: app)
        UITestInteraction.tapToolbar(app.navigationBars.buttons.element(boundBy: 0), in: app, identifier: "navigation.back")
        XCTAssertTrue(app.navigationBars["Custom Price Tag"].waitForExistence(timeout: 5))
        tap(customPosition.buttons["Price Right"], app: app)
        reveal(customPreview, app: app)
        XCTAssertTrue((customPreview.value as? String ?? "").contains("Price Right"), "New previews follow the changed position")
        XCTAssertFalse(app.buttons["customLabels.prepare"].isEnabled, "A new layout cannot overwrite a pending queue")
        tap(app.buttons["customLabels.reviewQueue"], app: app)
        assertContains("0/2 completed", element: app.staticTexts["labelQueue.progress"])
        tap(app.buttons[queuedID], app: app)
        XCTAssertTrue(app.navigationBars["Queued Label"].waitForExistence(timeout: 5))
        reveal(queuedPreview, app: app)
        XCTAssertEqual(queuedPreview.screenshot().pngRepresentation, queuedArtwork,
                       "Changing the default layout cannot redraw an already prepared label")
        UITestInteraction.tapToolbar(app.navigationBars["Queued Label"].buttons["Done"], in: app)
        UITestInteraction.tapToolbar(app.navigationBars.buttons.element(boundBy: 0), in: app, identifier: "navigation.back")
        tap(customPosition.buttons["Price Left"], app: app)
        UITestInteraction.tapToolbar(app.navigationBars.buttons.element(boundBy: 0), in: app, identifier: "navigation.back")

        app.terminate(); app.launch()
        XCTAssertTrue(app.navigationBars["Show"].waitForExistence(timeout: 10))
        tap(app.buttons["show.priceTags"], app: app)
        assertContains("Price Left", element: app.staticTexts["priceTags.pricePosition"])
        tap(app.buttons["priceTags.printer"], app: app)
        reveal(defaults, app: app)
        XCTAssertTrue(defaults.buttons["Price Left"].isSelected, "The chosen side survives restarting the app")
        UITestInteraction.tapToolbar(app.navigationBars.buttons.element(boundBy: 0), in: app, identifier: "navigation.back")
        tap(app.buttons["priceTags.custom"], app: app)
        XCTAssertTrue(customPosition.buttons["Price Left"].isSelected)
        enter("7", field: app.textFields["customLabels.price"], app: app)
        tap(app.buttons["customLabels.keyboardDone"], app: app)
        reveal(customPreview, app: app)
        XCTAssertTrue((customPreview.value as? String ?? "").contains("Price Left"))
        UITestInteraction.tapToolbar(app.navigationBars.buttons.element(boundBy: 0), in: app, identifier: "navigation.back")
        tap(app.buttons["priceTags.bulk"], app: app)
        XCTAssertTrue(customPosition.buttons["Price Left"].isSelected)
        reveal(customPreview, app: app)
        XCTAssertTrue((customPreview.value as? String ?? "").contains("2 for $1"))
        XCTAssertTrue((customPreview.value as? String ?? "").contains("Price Left"))
        UITestInteraction.tapToolbar(app.navigationBars.buttons.element(boundBy: 0), in: app, identifier: "navigation.back")
        tap(app.buttons["priceTags.all"], app: app)
        let batchPosition = app.segmentedControls["labels.pricePosition"]
        reveal(batchPosition, app: app)
        XCTAssertTrue(batchPosition.buttons["Price Left"].isSelected)
        let batchPreview = app.images["labels.bitmapPreview"].firstMatch
        reveal(batchPreview, app: app)
        XCTAssertTrue((batchPreview.value as? String ?? "").contains("Price Left"))
        tap(app.buttons["labels.style"], app: app)
        tap(app.buttons["Card details"], app: app)
        XCTAssertFalse(batchPosition.exists, "Classic card details keep their existing layout")
        reveal(batchPreview, app: app)
        XCTAssertFalse((batchPreview.value as? String ?? "").contains("Price Left"))
        tap(app.buttons["labels.close"], app: app)
        tap(app.buttons["priceTags.chooseCards"], app: app)
        tap(app.buttons["labels.select." + stockAID], app: app)
        tap(app.buttons["labels.continueSelection"], app: app)
        reveal(batchPosition, app: app)
        XCTAssertTrue(batchPosition.buttons["Price Left"].isSelected, "Newly selected inventory drafts use the remembered side")
        tap(app.buttons["labels.edit." + stockAID], app: app)
        XCTAssertTrue(app.navigationBars["Edit Label"].waitForExistence(timeout: 5))
        reveal(batchPreview, app: app)
        XCTAssertTrue((batchPreview.value as? String ?? "").contains("Price Left"))
        tap(app.buttons["labels.editor.save"], app: app)
        clearQueue("labels.clearQueue", app: app)
        tap(app.buttons["labels.prepare"], app: app)
        assertContains("0/1 completed", element: app.staticTexts["labelQueue.progress"])
        XCTAssertFalse(app.buttons["labelQueue.print"].isEnabled)
        XCTAssertFalse(app.buttons["labelQueue.pause"].exists)
        closeBatchToInventory(app: app)
        assertContains("3 cards available", element: app.staticTexts["showInventory.quantity"])
        assertContains("Qty 2", element: inventory("Stock A", app: app))
        assertContains("$35.00", element: inventory("Stock A", app: app))
        UITestInteraction.tapToolbar(app.navigationBars.buttons.element(boundBy: 0), in: app, identifier: "navigation.back")
        assertBalances(app: app)
        assertNoBluetoothPrompt(app: app)
    }

    func testUnavailableRollEstimateStaysUnknownAcrossPrinterScreensAndDoesNotBlockPreparation() {
        continueAfterFailure = false
        let app = launch()
        defer { app.terminate() }
        tap(app.buttons["show.priceTags"], app: app)
        assertContains("Estimated labels remaining: Unknown", element: app.staticTexts["priceTags.roll.estimate"])
        XCTAssertFalse(app.buttons["priceTags.roll.refresh"].isEnabled)
        XCTAssertFalse(app.staticTexts["priceTags.roll.warning"].exists)
        tap(app.buttons["priceTags.printer"], app: app)
        assertContains("Estimated labels remaining: Unknown", element: app.staticTexts["labelPrinter.roll.estimate"])
        XCTAssertFalse(app.buttons["labelPrinter.roll.refresh"].isEnabled)
        UITestInteraction.tapToolbar(app.navigationBars.buttons.element(boundBy: 0), in: app, identifier: "navigation.back")
        tap(app.buttons["priceTags.custom"], app: app)
        enter("5", field: app.textFields["customLabels.price"], app: app)
        enter("3", field: app.textFields["customLabels.copies"], app: app)
        tap(app.buttons["customLabels.keyboardDone"], app: app)
        XCTAssertTrue(app.buttons["customLabels.prepare"].isEnabled, "An unavailable roll count does not block preparing labels")
        tap(app.buttons["customLabels.prepare"], app: app)
        assertContains("0/3 completed", element: app.staticTexts["labelQueue.progress"])
        let estimate = app.staticTexts["labelQueue.roll.estimate"]
        reveal(estimate, app: app)
        assertContains("Estimated labels remaining: Unknown", element: estimate)
        XCTAssertFalse(app.buttons["labelQueue.roll.refresh"].isEnabled)
        XCTAssertFalse(app.staticTexts["labelQueue.roll.warning"].exists, "An unknown count cannot claim the roll is empty or insufficient")
        clearQueue("labelQueue.clearQueue", app: app)
        assertContains("0/0 completed", element: app.staticTexts["labelQueue.progress"])
        reveal(estimate, app: app)
        assertContains("Estimated labels remaining: Unknown", element: estimate)
        XCTAssertFalse(app.buttons["labelQueue.roll.refresh"].isEnabled)
        assertNoBluetoothPrompt(app: app)
    }

    func testPaperModeCanBeChosenOfflineAndPersistsWithoutChangingTheSavedQueue() {
        continueAfterFailure = false
        let app = launch()
        defer {
            let gap = app.segmentedControls["labelPrinter.paperMode"].buttons["Gap"]
            if app.state == .runningForeground && gap.exists && gap.isHittable { gap.tap() }
            app.terminate()
        }
        assertBalances(app: app)
        tap(app.buttons["show.priceTags"], app: app)
        tap(app.buttons["priceTags.custom"], app: app)
        enter("5", field: app.textFields["customLabels.price"], app: app)
        enter("3", field: app.textFields["customLabels.copies"], app: app)
        tap(app.buttons["customLabels.keyboardDone"], app: app)
        tap(app.buttons["customLabels.prepare"], app: app)
        XCTAssertTrue(app.navigationBars["Label Print Queue"].waitForExistence(timeout: 5))
        assertContains("0/3 completed", element: app.staticTexts["labelQueue.progress"])
        assertContains("3", element: app.descendants(matching: .any)["labelQueue.totalCount"])
        XCTAssertFalse(app.buttons["labelQueue.print"].isEnabled)
        XCTAssertFalse(app.buttons["labelQueue.pause"].exists)
        let queued = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "labelQueue.entry.")).firstMatch
        reveal(queued, app: app)
        XCTAssertTrue(queued.exists)
        let queuedID = queued.identifier, queuedDescription = queued.label

        UITestInteraction.tapToolbar(app.navigationBars.buttons.element(boundBy: 0), in: app, identifier: "navigation.back")
        XCTAssertTrue(app.navigationBars["Custom Price Tag"].waitForExistence(timeout: 5))
        UITestInteraction.tapToolbar(app.navigationBars.buttons.element(boundBy: 0), in: app, identifier: "navigation.back")
        XCTAssertTrue(app.navigationBars["Price Tags"].waitForExistence(timeout: 5))
        tap(app.buttons["priceTags.printer"], app: app)
        XCTAssertTrue(app.navigationBars["Label Printer"].waitForExistence(timeout: 5))
        let mode = app.segmentedControls["labelPrinter.paperMode"]
        XCTAssertTrue(mode.waitForExistence(timeout: 5))
        tap(mode.buttons["Gap"], app: app)
        XCTAssertTrue(mode.buttons["Gap"].isSelected)
        let connection = app.descendants(matching: .any)["labelPrinter.connection"]
        let status = app.staticTexts["labelPrinter.status"]
        let originalConnection = connection.label, originalStatus = status.label
        assertContains("not connected", element: connection)
        XCTAssertTrue(app.buttons["labelPrinter.applyPaperMode"].exists)
        XCTAssertTrue(app.buttons["labelPrinter.readPaperMode"].exists)
        XCTAssertFalse(app.buttons["labelPrinter.applyPaperMode"].isEnabled)
        XCTAssertFalse(app.buttons["labelPrinter.readPaperMode"].isEnabled)
        XCTAssertFalse(app.staticTexts["labelPrinter.paperModeStatus"].exists)

        tap(mode.buttons["Transparent"], app: app)
        XCTAssertTrue(mode.buttons["Transparent"].isSelected)
        XCTAssertFalse(mode.buttons["Gap"].isSelected)
        XCTAssertEqual(connection.label, originalConnection)
        XCTAssertEqual(status.label, originalStatus, "Choosing paper offline cannot start a Bluetooth search or connection")
        XCTAssertFalse(app.buttons["labelPrinter.disconnect"].exists)
        XCTAssertFalse(app.buttons["labelPrinter.applyPaperMode"].isEnabled)
        XCTAssertFalse(app.buttons["labelPrinter.readPaperMode"].isEnabled)
        XCTAssertFalse(app.staticTexts["labelPrinter.paperModeStatus"].exists,
                       "Changing the preference alone must not claim to have configured a printer")
        assertNoBluetoothPrompt(app: app)

        app.terminate(); app.launch()
        XCTAssertTrue(app.navigationBars["Show"].waitForExistence(timeout: 10))
        tap(app.buttons["show.priceTags"], app: app)
        tap(app.buttons["priceTags.printer"], app: app)
        XCTAssertTrue(app.navigationBars["Label Printer"].waitForExistence(timeout: 5))
        XCTAssertTrue(mode.buttons["Transparent"].isSelected, "The explicitly selected stock mode survives relaunch")
        XCTAssertEqual(connection.label, originalConnection)
        XCTAssertEqual(status.label, originalStatus)
        XCTAssertFalse(app.buttons["labelPrinter.applyPaperMode"].isEnabled)
        XCTAssertFalse(app.buttons["labelPrinter.readPaperMode"].isEnabled)
        assertNoBluetoothPrompt(app: app)
        tap(mode.buttons["Gap"], app: app)
        XCTAssertTrue(mode.buttons["Gap"].isSelected)
        UITestInteraction.tapToolbar(app.navigationBars.buttons.element(boundBy: 0), in: app, identifier: "navigation.back")
        XCTAssertTrue(app.navigationBars["Price Tags"].waitForExistence(timeout: 5))
        tap(app.buttons["priceTags.queue"], app: app)
        XCTAssertTrue(app.navigationBars["Label Print Queue"].waitForExistence(timeout: 5))
        reveal(mode, app: app)
        XCTAssertTrue(mode.buttons["Gap"].isSelected, "Settings and the saved queue use the same paper preference")
        XCTAssertEqual(connection.label, originalConnection)
        XCTAssertEqual(status.label, originalStatus)
        XCTAssertFalse(app.buttons["labelPrinter.applyPaperMode"].isEnabled)
        XCTAssertFalse(app.buttons["labelPrinter.readPaperMode"].isEnabled)
        assertContains("0/3 completed", element: app.staticTexts["labelQueue.progress"])
        assertContains("3", element: app.descendants(matching: .any)["labelQueue.totalCount"])
        let unchangedEntry = app.buttons[queuedID]
        reveal(unchangedEntry, app: app)
        XCTAssertEqual(unchangedEntry.label, queuedDescription, "Paper preferences do not replace, complete or reprint saved labels")
        XCTAssertFalse(app.buttons["labelQueue.print"].isEnabled)
        XCTAssertFalse(app.buttons["labelQueue.pause"].exists)
        assertNoBluetoothPrompt(app: app)
        UITestInteraction.tapToolbar(app.navigationBars.buttons.element(boundBy: 0), in: app, identifier: "navigation.back")
        XCTAssertTrue(app.navigationBars["Price Tags"].waitForExistence(timeout: 5))
        UITestInteraction.tapToolbar(app.navigationBars.buttons.element(boundBy: 0), in: app, identifier: "navigation.back")
        XCTAssertTrue(app.navigationBars["Show"].waitForExistence(timeout: 5))
        assertBalances(app: app)
        tap(app.buttons["show.inventory"], app: app)
        assertContains("3 cards available", element: app.staticTexts["showInventory.quantity"])
    }

    func testCustomPrintingShowsProgressWaitsForFinalAcknowledgementAndReturnsToPriceTags() {
        continueAfterFailure = false
        let app = launch(extraArguments: ["--label-print-progress-fixture=success-per-copy"])
        defer { app.terminate() }
        prepareProgressFixture(app: app, copies: "3")
        tap(app.buttons["labelQueue.print"], app: app)
        assertLiveProgress("Confirmed printed: 0 of 3", app: app)
        tap(app.buttons["labelProgress.fixtureConfirm"], app: app)
        assertLiveProgress("Confirmed printed: 1 of 3", app: app)
        XCTAssertFalse(app.buttons["labelProgress.fixtureFinish"].exists,
                       "The first receipt must update the sheet before the next label or final acknowledgement")
        tap(app.buttons["labelProgress.fixtureConfirm"], app: app)
        assertLiveProgress("Confirmed printed: 2 of 3", app: app)
        tap(app.buttons["labelProgress.fixtureConfirm"], app: app)
        assertLiveProgress("Confirmed printed: 3 of 3", app: app)
        assertContains("Finishing print job", element: app.staticTexts["labelProgress.status"])
        XCTAssertTrue(app.buttons["labelProgress.pause"].exists,
                      "The final printer acknowledgement still owns the active job after the counter reaches its total")
        tap(app.buttons["labelProgress.fixtureFinish"], app: app)
        assertReturnedToPriceTags(app: app)
        XCTAssertFalse(app.navigationBars["Custom Price Tag"].exists)
        tap(app.buttons["priceTags.queue"], app: app)
        XCTAssertTrue(app.navigationBars["Label Print Queue"].waitForExistence(timeout: 5))
        assertContains("3/3 completed", element: app.staticTexts["labelQueue.progress"])
        XCTAssertFalse(app.buttons["labelQueue.print"].isEnabled)
        XCTAssertFalse(app.buttons["labelProgress.pause"].exists,
                       "Opening completed receipts must not present progress or automatically navigate away")
        assertNoBluetoothPrompt(app: app)
    }

    func testUploadProgressStaysSeparateFromConfirmedPhysicalCopiesAndFinalAcknowledgement() {
        continueAfterFailure = false
        let app = launch(extraArguments: ["--label-print-progress-fixture=success-upload"])
        defer { app.terminate() }
        prepareProgressFixture(app: app, copies: "3")
        tap(app.buttons["labelQueue.print"], app: app)
        assertLiveProgress("Confirmed printed: 0 of 3", app: app)
        assertUploadProgress("0%", app: app)
        assertContains("Sending labels 1–3", element: app.staticTexts["labelProgress.uploadRange"])
        tap(app.buttons["labelProgress.fixtureUpload"], app: app)
        assertUploadProgress("50%", app: app)
        assertLiveProgress("Confirmed printed: 0 of 3", app: app)
        XCTAssertFalse(app.buttons["labelProgress.fixtureConfirm"].exists)
        tap(app.buttons["labelProgress.fixtureUpload"], app: app)
        assertUploadProgress("100%", app: app)
        assertLiveProgress("Confirmed printed: 0 of 3", app: app)
        XCTAssertFalse(app.buttons["labelProgress.fixtureFinish"].exists,
                       "Accepted image data is not physical completion or final job acknowledgement")
        tap(app.buttons["labelProgress.fixtureUpload"], app: app)
        XCTAssertTrue(app.buttons["labelProgress.fixtureConfirm"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.progressIndicators["labelProgress.uploadBar"].exists)
        assertContains("Waiting for printer confirmation", element: app.staticTexts["labelProgress.status"])
        assertLiveProgress("Confirmed printed: 0 of 3", app: app)
        for count in 1...3 {
            tap(app.buttons["labelProgress.fixtureConfirm"], app: app)
            assertLiveProgress("Confirmed printed: \(count) of 3", app: app)
        }
        assertContains("Finishing print job", element: app.staticTexts["labelProgress.status"])
        XCTAssertTrue(app.buttons["labelProgress.pause"].exists)
        tap(app.buttons["labelProgress.fixtureFinish"], app: app)
        assertReturnedToPriceTags(app: app)
        assertNoBluetoothPrompt(app: app)
    }

    func testPauseDuringUploadKeepsEveryUnconfirmedCopyAvailableForReview() {
        continueAfterFailure = false
        let app = launch(extraArguments: ["--label-print-progress-fixture=success-upload"])
        defer { app.terminate() }
        prepareProgressFixture(app: app, copies: "2")
        tap(app.buttons["labelQueue.print"], app: app)
        assertUploadProgress("0%", app: app)
        tap(app.buttons["labelProgress.fixtureUpload"], app: app)
        assertUploadProgress("50%", app: app)
        tap(app.buttons["labelProgress.pause"], app: app)
        XCTAssertTrue(app.buttons["labelProgress.reviewQueue"].waitForExistence(timeout: 5))
        assertLiveProgress("Confirmed printed: 0 of 2", app: app)
        XCTAssertFalse(app.progressIndicators["labelProgress.uploadBar"].exists)
        XCTAssertFalse(app.buttons["labelProgress.fixtureFinish"].exists)
        tap(app.buttons["labelProgress.reviewQueue"], app: app)
        assertContains("0/2 completed", element: app.staticTexts["labelQueue.progress"])
        XCTAssertTrue(app.buttons["labelQueue.retrySelected"].exists)
        assertNoBluetoothPrompt(app: app)
    }

    func testInventoryPrintCompletionClosesTheBatchSheetAndReturnsToPriceTags() {
        continueAfterFailure = false
        let app = launch(extraArguments: ["--label-print-progress-fixture=success"])
        defer { app.terminate() }
        tap(app.buttons["show.priceTags"], app: app)
        tap(app.buttons["priceTags.all"], app: app)
        tap(app.buttons["labels.prepare"], app: app)
        XCTAssertTrue(app.navigationBars["Label Print Queue"].waitForExistence(timeout: 5))
        tap(app.buttons["labelQueue.print"], app: app)
        tap(app.buttons["labelProgress.fixtureConfirm"], app: app)
        assertContains("Finishing print job", element: app.staticTexts["labelProgress.status"])
        tap(app.buttons["labelProgress.fixtureFinish"], app: app)
        assertReturnedToPriceTags(app: app)
        XCTAssertFalse(app.buttons["labels.close"].exists)
        tap(app.buttons["priceTags.queue"], app: app)
        assertContains("3/3 completed", element: app.staticTexts["labelQueue.progress"])
        assertNoBluetoothPrompt(app: app)
    }

    func testPauseKeepsProgressForQueueReviewInsteadOfReturningToPriceTags() {
        continueAfterFailure = false
        let app = launch(extraArguments: ["--label-print-progress-fixture=success"])
        defer { app.terminate() }
        prepareProgressFixture(app: app, copies: "2")
        tap(app.buttons["labelQueue.print"], app: app)
        XCTAssertTrue(app.buttons["labelProgress.fixtureConfirm"].waitForExistence(timeout: 5))
        tap(app.buttons["labelProgress.pause"], app: app)
        XCTAssertTrue(app.buttons["labelProgress.reviewQueue"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["labelProgress.fixtureFinish"].exists)
        tap(app.buttons["labelProgress.reviewQueue"], app: app)
        XCTAssertTrue(app.navigationBars["Label Print Queue"].waitForExistence(timeout: 5))
        assertContains("0/2 completed", element: app.staticTexts["labelQueue.progress"])
        XCTAssertTrue(app.buttons["labelQueue.retrySelected"].exists)
        assertNoBluetoothPrompt(app: app)
    }

    func testPrintingFailureStaysAvailableForReviewWithoutAutomaticRetryOrNavigation() {
        continueAfterFailure = false
        let app = launch(extraArguments: ["--label-print-progress-fixture=failure-upload"])
        defer { app.terminate() }
        prepareProgressFixture(app: app, copies: "2")
        tap(app.buttons["labelQueue.print"], app: app)
        assertUploadProgress("0%", app: app)
        tap(app.buttons["labelProgress.fixtureUpload"], app: app)
        assertUploadProgress("50%", app: app)
        tap(app.buttons["labelProgress.fixtureUpload"], app: app)
        XCTAssertTrue(app.buttons["labelProgress.reviewQueue"].waitForExistence(timeout: 5))
        assertLiveProgress("Confirmed printed: 0 of 2", app: app)
        XCTAssertFalse(app.progressIndicators["labelProgress.uploadBar"].exists)
        tap(app.buttons["labelProgress.reviewQueue"], app: app)
        XCTAssertTrue(app.navigationBars["Label Print Queue"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["labelQueue.print"].isEnabled)
        XCTAssertTrue(app.buttons["labelQueue.retrySelected"].exists)
        assertNoBluetoothPrompt(app: app)
    }

    private func prepareProgressFixture(app: XCUIApplication, copies: String) {
        tap(app.buttons["show.priceTags"], app: app)
        tap(app.buttons["priceTags.custom"], app: app)
        enter("5", field: app.textFields["customLabels.price"], app: app)
        enter(copies, field: app.textFields["customLabels.copies"], app: app)
        tap(app.buttons["customLabels.keyboardDone"], app: app)
        tap(app.buttons["customLabels.prepare"], app: app)
        XCTAssertTrue(app.navigationBars["Label Print Queue"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["labelProgress.pause"].exists, "Preparation never starts a print job")
        XCTAssertTrue(app.buttons["labelQueue.print"].isEnabled)
    }

    /// Reading accessibility state is passive: revealing or scrolling the list
    /// here could refresh the destination and hide a first-navigation failure.
    private func assertInventoryReadyWithoutInteraction(price: String, labels: Int, app: XCUIApplication,
                                                        file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(app.navigationBars["Label Details"].waitForExistence(timeout: 5), file: file, line: line)
        assertContains("\(labels) labels", element: app.staticTexts["labels.totalCount"], file: file, line: line)
        let prepare = app.buttons["labels.prepare"]
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND isEnabled == true AND isHittable == true"), object: prepare)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed,
                       "Prepare must work before touching a layout control or scrolling", file: file, line: line)
        let preview = app.images["labels.bitmapPreview"].firstMatch
        XCTAssertTrue(preview.waitForExistence(timeout: 5),
                      "The initial preview must appear without a refresh gesture", file: file, line: line)
        let rendered = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS %@ AND value CONTAINS %@", "PokéDen price", price), object: preview)
        XCTAssertEqual(XCTWaiter.wait(for: [rendered], timeout: 5), .completed,
                       "Expected the current selection's initial \(price) preview", file: file, line: line)
    }

    private func assertInitialInventoryPreview(_ price: String, app: XCUIApplication,
                                               file: StaticString = #filePath, line: UInt = #line) {
        let preview = app.images["labels.bitmapPreview"].firstMatch
        reveal(preview, app: app, file: file, line: line)
        XCTAssertTrue(preview.waitForExistence(timeout: 5),
                      "Selected cards must show their default preview before any layout control is changed", file: file, line: line)
        let rendered = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS %@ AND value CONTAINS %@", "PokéDen price", price), object: preview)
        XCTAssertEqual(XCTWaiter.wait(for: [rendered], timeout: 5), .completed,
                       "Expected the selected card's initial PokéDen \(price) preview", file: file, line: line)
    }

    private func assertUploadProgress(_ expected: String, app: XCUIApplication,
                                      file: StaticString = #filePath, line: UInt = #line) {
        let value = app.staticTexts["labelProgress.uploadPercent"]
        XCTAssertTrue(value.waitForExistence(timeout: 5), file: file, line: line)
        let update = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", expected), object: value)
        XCTAssertEqual(XCTWaiter.wait(for: [update], timeout: 5), .completed,
                       "Expected upload progress \(expected), received \(value.label)", file: file, line: line)
        XCTAssertTrue(app.progressIndicators["labelProgress.uploadBar"].exists, file: file, line: line)
    }

    private func assertLiveProgress(_ expected: String, app: XCUIApplication,
                                    file: StaticString = #filePath, line: UInt = #line) {
        let count = app.staticTexts["labelProgress.count"]
        XCTAssertTrue(count.waitForExistence(timeout: 5), file: file, line: line)
        let update = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", expected), object: count)
        XCTAssertEqual(XCTWaiter.wait(for: [update], timeout: 5), .completed,
                       "Expected live progress \(expected), received \(count.label)", file: file, line: line)
    }

    private func assertReturnedToPriceTags(app: XCUIApplication) {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == true"),
                                             object: app.buttons["priceTags.all"])
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed)
        XCTAssertTrue(app.navigationBars["Price Tags"].exists)
        XCTAssertFalse(app.buttons["labelProgress.pause"].exists)
    }

    private func launch(extraArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        if let path = ProcessInfo.processInfo.environment["DYLD_FALLBACK_LIBRARY_PATH"] {
            app.launchEnvironment["DYLD_FALLBACK_LIBRARY_PATH"] = path
        }
        app.launchArguments = ["--show-transactions-ui-fixture", "--show-transactions-fixture-id=" + UUID().uuidString,
                               "--uitest-disable-printer-auto-connect"] + extraArguments
        app.launch()
        XCTAssertTrue(app.navigationBars["Show"].waitForExistence(timeout: 10))
        return app
    }

    private func clearQueue(_ identifier: String, app: XCUIApplication) {
        tap(app.buttons[identifier], app: app)
        tap(app.buttons[identifier + ".confirm"], app: app)
    }

    private func assertNoPrintingPricePrompts(app: XCUIApplication,
                                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(app.switches["labels.acknowledgePricingWarnings"].exists, file: file, line: line)
        XCTAssertFalse(app.buttons["labels.useSuggestedPrices"].exists, file: file, line: line)
        XCTAssertFalse(app.buttons["labels.editor.useSuggestedPrice"].exists, file: file, line: line)
        XCTAssertFalse(app.buttons["labels.pricingSettings"].exists, file: file, line: line)
    }

    private func openBatch(app: XCUIApplication) {
        openPriceTags(app: app)
        tap(app.buttons["priceTags.chooseCards"], app: app)
    }

    private func openPriceTags(app: XCUIApplication) {
        XCTAssertTrue(app.navigationBars["Show Inventory"].waitForExistence(timeout: 5))
        UITestInteraction.tapToolbar(app.navigationBars.buttons.element(boundBy: 0), in: app, identifier: "navigation.back")
        XCTAssertTrue(app.navigationBars["Show"].waitForExistence(timeout: 5))
        tap(app.buttons["show.priceTags"], app: app)
        XCTAssertTrue(app.navigationBars["Price Tags"].waitForExistence(timeout: 5))
    }

    private func closeBatchToInventory(app: XCUIApplication) {
        tap(app.buttons["labels.close"], app: app)
        XCTAssertTrue(app.navigationBars["Price Tags"].waitForExistence(timeout: 5))
        UITestInteraction.tapToolbar(app.navigationBars.buttons.element(boundBy: 0), in: app, identifier: "navigation.back")
        XCTAssertTrue(app.navigationBars["Show"].waitForExistence(timeout: 5))
        tap(app.buttons["show.inventory"], app: app)
        XCTAssertTrue(app.navigationBars["Show Inventory"].waitForExistence(timeout: 5))
    }

    private func assertUnstartedQueue(app: XCUIApplication) {
        XCTAssertTrue(app.navigationBars["Label Print Queue"].waitForExistence(timeout: 5))
        assertContains("0/2 completed", element: app.staticTexts["labelQueue.progress"])
        assertContains("2", element: app.descendants(matching: .any)["labelQueue.totalCount"])
        assertContains("40 × 12 mm", element: app.descendants(matching: .any)["labelQueue.paper"])
        assertContains("PokéDen price", element: app.descendants(matching: .any)["labelQueue.style"])
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
        UITestInteraction.tapToolbar(app.navigationBars.buttons.element(boundBy: 0), in: app, identifier: "navigation.back")
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
        UITestInteraction.reveal(element, in: app, file: file, line: line)
    }

    private func tap(_ element: XCUIElement, app: XCUIApplication,
                     file: StaticString = #filePath, line: UInt = #line) {
        UITestInteraction.tap(element, in: app, file: file, line: line)
    }
}
