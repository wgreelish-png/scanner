import XCTest

@MainActor final class CardShowInventoryUITests: XCTestCase {
    func testExplicitImportAndRefreshKeepOneSavedInventoryRow() async throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        if let path = ProcessInfo.processInfo.environment["DYLD_FALLBACK_LIBRARY_PATH"] {
            app.launchEnvironment["DYLD_FALLBACK_LIBRARY_PATH"] = path
        }
        app.launchArguments = ["-autoDatabaseUpdates", "NO", "--uitest-card-show-inventory"]
        app.launch(); defer { app.terminate() }
        XCTAssertTrue(app.navigationBars["Card Show Inventory"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["cardShowInventory.open"].exists, "Opening the page alone must not import")
        let refresh = app.buttons["cardShowInventory.refresh"]
        reveal(refresh, in: app); refresh.tap()
        let quantity = app.staticTexts["cardShowInventory.quantity"]
        reveal(quantity, in: app)
        assertValue("2", title: "Cards", element: quantity)
        assertValue("1", title: "Inventory rows", element: app.staticTexts["cardShowInventory.rows"])
        XCTAssertTrue(app.staticTexts["cardShowInventory.updated"].exists)
        reveal(refresh, in: app); refresh.tap()
        reveal(quantity, in: app)
        let updated = NSPredicate(format: "label == %@ OR label == %@", "3", "Cards, 3")
        let changed = expectation(for: updated, evaluatedWith: quantity)
        await fulfillment(of: [changed], timeout: 5)
        assertValue("1", title: "Inventory rows", element: app.staticTexts["cardShowInventory.rows"])
        let open = app.buttons["cardShowInventory.open"]
        reveal(open, in: app); open.tap()
        let options = app.buttons["list.options"]
        XCTAssertTrue(options.waitForExistence(timeout: 5)); options.tap()
        let export = app.buttons["list.exportCSV"]
        XCTAssertTrue(export.waitForExistence(timeout: 5)); XCTAssertTrue(export.isEnabled)
        app.navigationBars.firstMatch.staticTexts.firstMatch.tap()
        XCTAssertFalse(app.buttons["list.searchAndAdd"].exists)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["Card Show Inventory"].waitForExistence(timeout: 5))
        reveal(quantity, in: app)
        assertValue("3", title: "Cards", element: app.staticTexts["cardShowInventory.quantity"])
        assertValue("1", title: "Inventory rows", element: app.staticTexts["cardShowInventory.rows"])
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication,
                        file: StaticString = #filePath, line: UInt = #line) {
        let list = app.collectionViews.firstMatch
        for _ in 0..<3 { list.swipeDown() }
        for _ in 0..<8 {
            if element.exists && element.isHittable { return }
            list.swipeUp()
        }
        XCTAssertTrue(element.waitForExistence(timeout: 5), file: file, line: line)
        XCTAssertTrue(element.isHittable, file: file, line: line)
    }

    private func assertValue(_ expected: String, title: String, element: XCUIElement,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue([expected, title + ", " + expected].contains(element.label),
                      "Expected \(title): \(expected); got \(element.label)", file: file, line: line)
    }
}
