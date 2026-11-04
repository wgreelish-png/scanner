import XCTest

@MainActor final class ReviewPresentationUITests: XCTestCase {
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
