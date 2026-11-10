import XCTest

@MainActor final class ReviewPresentationUITests: XCTestCase {
    func testSuccessfulManualAddClosesBothSheetsAndCommitsOneRow() async throws {
        continueAfterFailure = false
        let app = launchManualAdd()
        defer { app.terminate() }
        let add = await openManualCardConfirmation(in: app)
        _ = UITestInteraction.tap(add, in: app)

        let returned = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == true"), object: app.buttons["manualAdd.open"])
        await fulfillment(of: [returned], timeout: 5)
        XCTAssertFalse(app.navigationBars["Confirm Card"].exists)
        XCTAssertFalse(app.navigationBars["Search & Add"].exists)
        XCTAssertEqual(app.staticTexts["manualAdd.quantity"].label, "Cards: 1")
        XCTAssertEqual(app.staticTexts["manualAdd.savedRows"].label, "Saved rows: 1")
        XCTAssertEqual(app.staticTexts["manualAdd.card"].label, "Synthetic manual card")
    }

    func testCancellingManualConfirmationKeepsSearchAndDoesNotSave() async throws {
        continueAfterFailure = false
        let app = launchManualAdd()
        defer { app.terminate() }
        _ = await openManualCardConfirmation(in: app)
        _ = UITestInteraction.tapToolbar(app.navigationBars["Confirm Card"].buttons["Cancel"], in: app)

        let query = app.textFields["catalog.query"]
        let searching = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == true"), object: query)
        await fulfillment(of: [searching], timeout: 5)
        XCTAssertEqual(query.value as? String, "Synthetic")
        XCTAssertTrue(app.buttons["catalog.result.mock:manual-add:1"].exists)
        XCTAssertFalse(app.navigationBars["Confirm Card"].exists)
        _ = UITestInteraction.tapToolbar(app.navigationBars["Search & Add"].buttons["Done"], in: app)
        let returned = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == true"), object: app.buttons["manualAdd.open"])
        await fulfillment(of: [returned], timeout: 5)
        XCTAssertFalse(app.navigationBars["Search & Add"].exists)
        XCTAssertEqual(app.staticTexts["manualAdd.quantity"].label, "Cards: 0")
        XCTAssertEqual(app.staticTexts["manualAdd.savedRows"].label, "Saved rows: 0")
        XCTAssertFalse(app.staticTexts["manualAdd.card"].exists)
    }

    func testListLookupStaysVisibleAfterScrollingAndPreservesCardsAndOfferDraft() async throws {
        continueAfterFailure = false
        let app = launch(arguments: ["--uitest-long-review"])
        defer { app.terminate() }
        let search = app.textFields["list.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        XCTAssertTrue(search.isHittable)
        let searchY = search.frame.midY
        for _ in 0..<3 {
            _ = UITestInteraction.scrollContent(in: app, towardTop: false)
            XCTAssertTrue(search.isHittable, "List lookup must stay in the fixed header")
            XCTAssertEqual(search.frame.midY, searchY, accuracy: 1)
        }
        _ = UITestInteraction.tap(search, in: app)
        search.typeText("Synthetic card 79")
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "list.card."))
        let matching = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count == 1"), object: rows)
        await fulfillment(of: [matching], timeout: 5)
        XCTAssertTrue(rows.firstMatch.label.contains("Synthetic card 79"))
        _ = UITestInteraction.tap(app.buttons["list.keyboardDone"], in: app)
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.keyboards.firstMatch)
        await fulfillment(of: [dismissed], timeout: 5)
        XCTAssertEqual(search.value as? String, "Synthetic card 79")
        XCTAssertEqual(app.staticTexts["list.quantity"].label, "80 cards", "Filtering cannot remove cards from the saved list")

        let sections = app.segmentedControls["list.section"]
        sections.buttons["Offer"].tap()
        XCTAssertFalse(search.exists, "Offer controls retain their compact layout")
        sections.buttons["Cards"].tap()
        XCTAssertTrue(search.isHittable)
        XCTAssertEqual(search.value as? String, "Synthetic card 79")
        XCTAssertEqual(rows.count, 1)
        _ = UITestInteraction.tap(app.buttons["list.clearSearch"], in: app)
        _ = UITestInteraction.tap(app.buttons["list.keyboardDone"], in: app)
        let restored = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count > 1"), object: rows)
        await fulfillment(of: [restored], timeout: 5)
        XCTAssertEqual(app.staticTexts["list.quantity"].label, "80 cards")
        XCTAssertTrue(app.buttons["list.searchAndAdd"].exists, "Catalog add remains a separate action from filtering this list")
    }

    func testReviewKeepsExportAndRatesInOptionsAndOutcomesInsideOffer() async throws {
        continueAfterFailure = false
        let app = launch()
        defer { app.terminate() }

        XCTAssertFalse(app.staticTexts["Export inventory"].exists)
        XCTAssertFalse(app.buttons["list.exportCSV"].exists)
        XCTAssertFalse(app.buttons["list.shareCSV"].exists)
        XCTAssertFalse(app.buttons["Save Offer Estimate"].exists)
        XCTAssertFalse(app.buttons["Session Offer Percentages"].exists)
        XCTAssertFalse(app.textFields["Custom cash offer for the whole list"].exists)
        XCTAssertFalse(app.textFields["My Card Price"].exists)
        XCTAssertFalse(app.buttons["list.nothingHappened"].exists)
        selectOffer(in: app)

        let price = app.textFields["My Card Price"]
        reveal(price, in: app); price.tap(); price.typeText("20")
        let done = app.buttons["offer.keyboardDone"]
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        XCTAssertEqual(done.label, "Done")
        XCTAssertGreaterThanOrEqual(done.frame.width, 60, "Done needs room for its full title")
        _ = UITestInteraction.tap(done, in: app)
        let keyboardDismissed = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.keyboards.firstMatch)
        await fulfillment(of: [keyboardDismissed], timeout: 5)
        app.segmentedControls["list.section"].buttons["Cards"].tap()
        XCTAssertFalse(price.exists)
        selectOffer(in: app)
        reveal(price, in: app)
        XCTAssertEqual(price.value as? String, "20", "Switching sections must keep the offer draft")

        let options = app.buttons["list.options"]
        _ = UITestInteraction.tapToolbar(options, in: app)
        XCTAssertTrue(app.buttons["list.exportCSV"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["list.shareCSV"].exists)
        let percentages = app.buttons["list.offerPercentages"]
        XCTAssertTrue(percentages.exists); percentages.tap()
        let rateEditor = app.navigationBars["Session Pricing"]
        XCTAssertTrue(rateEditor.waitForExistence(timeout: 5))
        _ = UITestInteraction.tapToolbar(rateEditor.buttons["Cancel"], in: app)
        XCTAssertTrue(app.navigationBars["Review & Offer"].waitForExistence(timeout: 5))

        let record = app.buttons["list.recordTransaction"]
        reveal(record, in: app)
        XCTAssertTrue(record.isHittable)
        let nothing = app.buttons["list.nothingHappened"]
        reveal(nothing, in: app)
        XCTAssertTrue(nothing.isHittable)
        XCTAssertFalse(app.buttons["Save Offer Estimate"].exists)
        XCTAssertFalse(app.buttons["Session Offer Percentages"].exists)
        XCTAssertFalse(app.textFields["Custom cash offer for the whole list"].exists)
        XCTAssertFalse(app.staticTexts["Export inventory"].exists)
    }

    func testLongReviewKeepsCardsAndOfferSectionsAndFooterActionsReachable() {
        continueAfterFailure = false
        let app = launch(arguments: ["--uitest-long-review"])
        defer { app.terminate() }
        let sections = app.segmentedControls["list.section"]
        XCTAssertTrue(sections.waitForExistence(timeout: 5))
        XCTAssertTrue(sections.buttons["Cards"].isSelected)
        XCTAssertEqual(app.staticTexts["list.quantity"].label, "80 cards")
        XCTAssertTrue(app.staticTexts["list.outcomeValue"].isHittable)
        XCTAssertFalse(app.textFields["My Card Price"].exists)
        XCTAssertFalse(app.buttons["list.nothingHappened"].exists)
        let record = app.buttons["list.recordTransaction"]
        let scanning = app.buttons["list.continueScanning"]
        XCTAssertTrue(record.isHittable)
        XCTAssertTrue(scanning.isHittable)
        let footerY = record.frame.midY
        for _ in 0..<4 {
            app.swipeUp()
            XCTAssertTrue(sections.isHittable)
            XCTAssertTrue(record.isHittable)
            XCTAssertTrue(scanning.isHittable)
            XCTAssertEqual(record.frame.midY, footerY, accuracy: 1)
        }
        record.tap()
        XCTAssertTrue(app.navigationBars["Confirm Transaction"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["showTransaction.kind.purchase"].exists)
        XCTAssertFalse(app.buttons["showTransaction.incomingList"].exists)
        XCTAssertTrue(app.buttons["showTransaction.record"].isHittable)
        _ = UITestInteraction.tapToolbar(app.buttons["Cancel"].firstMatch, in: app)
        selectOffer(in: app)
        let nothing = app.buttons["list.nothingHappened"]
        reveal(nothing, in: app)
        XCTAssertTrue(record.isHittable)
        XCTAssertTrue(scanning.isHittable)
        XCTAssertFalse(app.buttons["list.exportCSV"].exists)
        XCTAssertFalse(app.buttons["list.offerPercentages"].exists)
    }

    private func launchManualAdd() -> XCUIApplication {
        let app = XCUIApplication()
        if let path = ProcessInfo.processInfo.environment["DYLD_FALLBACK_LIBRARY_PATH"] {
            app.launchEnvironment["DYLD_FALLBACK_LIBRARY_PATH"] = path
        }
        app.launchArguments = ["-autoDatabaseUpdates", "NO", "--uitest-manual-add"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Manual Add Fixture"].waitForExistence(timeout: 10))
        return app
    }

    private func openManualCardConfirmation(in app: XCUIApplication) async -> XCUIElement {
        _ = UITestInteraction.tap(app.buttons["manualAdd.open"], in: app)
        let query = app.textFields["catalog.query"]
        XCTAssertTrue(query.waitForExistence(timeout: 5))
        _ = UITestInteraction.tap(query, in: app)
        query.typeText("Synthetic")
        let result = app.buttons["catalog.result.mock:manual-add:1"]
        XCTAssertTrue(result.waitForExistence(timeout: 5))
        _ = UITestInteraction.tap(result, in: app)
        XCTAssertTrue(app.navigationBars["Confirm Card"].waitForExistence(timeout: 5))
        let add = app.buttons["catalog.confirmAdd"]
        let priced = expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: add)
        await fulfillment(of: [priced], timeout: 5)
        return add
    }

    private func launch(arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        if let path = ProcessInfo.processInfo.environment["DYLD_FALLBACK_LIBRARY_PATH"] {
            app.launchEnvironment["DYLD_FALLBACK_LIBRARY_PATH"] = path
        }
        app.launchArguments = ["-autoDatabaseUpdates", "NO", "--uitest-streamlined-review"] + arguments
        app.launch()
        XCTAssertTrue(app.navigationBars["Review & Offer"].waitForExistence(timeout: 10))
        return app
    }

    private func selectOffer(in app: XCUIApplication) {
        let sections = app.segmentedControls["list.section"]
        XCTAssertTrue(sections.waitForExistence(timeout: 5))
        sections.buttons["Offer"].tap()
        XCTAssertTrue(sections.buttons["Offer"].isSelected)
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication,
                        file: StaticString = #filePath, line: UInt = #line) {
        _ = UITestInteraction.reveal(element, in: app, file: file, line: line)
    }
}
