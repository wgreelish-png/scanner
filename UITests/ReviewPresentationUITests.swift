import XCTest

@MainActor final class ReviewPresentationUITests: XCTestCase {
    func testReviewKeepsExportAndRatesInOptionsAndOutcomesInsideOffer() async throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        if let path = ProcessInfo.processInfo.environment["DYLD_FALLBACK_LIBRARY_PATH"] {
            app.launchEnvironment["DYLD_FALLBACK_LIBRARY_PATH"] = path
        }
        app.launchArguments = ["-autoDatabaseUpdates", "NO", "--uitest-streamlined-review"]
        app.launch(); defer { app.terminate() }
        XCTAssertTrue(app.navigationBars["Review & Offer"].waitForExistence(timeout: 10))

        XCTAssertFalse(app.staticTexts["Export inventory"].exists)
        XCTAssertFalse(app.buttons["list.exportCSV"].exists)
        XCTAssertFalse(app.buttons["list.shareCSV"].exists)
        XCTAssertFalse(app.buttons["Save Offer Estimate"].exists)
        XCTAssertFalse(app.buttons["Session Offer Percentages"].exists)
        XCTAssertFalse(app.textFields["Custom cash offer for the whole list"].exists)

        let price = app.textFields["My Card Price"]
        reveal(price, in: app); price.tap(); price.typeText("20")
        let done = app.buttons["offer.keyboardDone"]
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        XCTAssertEqual(done.label, "Done")
        XCTAssertGreaterThanOrEqual(done.frame.width, 60, "Done needs room for its full title")
        done.tap()
        let keyboardDismissed = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.keyboards.firstMatch)
        await fulfillment(of: [keyboardDismissed], timeout: 5)

        let options = app.buttons["list.options"]
        XCTAssertTrue(options.isHittable); options.tap()
        XCTAssertTrue(app.buttons["list.exportCSV"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["list.shareCSV"].exists)
        let percentages = app.buttons["list.offerPercentages"]
        XCTAssertTrue(percentages.exists); percentages.tap()
        let rateEditor = app.navigationBars["Session Pricing"]
        XCTAssertTrue(rateEditor.waitForExistence(timeout: 5))
        rateEditor.buttons["Cancel"].tap()
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

    private func reveal(_ element: XCUIElement, in app: XCUIApplication,
                        file: StaticString = #filePath, line: UInt = #line) {
        for _ in 0..<10 {
            if element.exists && element.isHittable { return }
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.80))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.28))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        XCTAssertTrue(element.waitForExistence(timeout: 5), file: file, line: line)
        XCTAssertTrue(element.isHittable, file: file, line: line)
    }
}
