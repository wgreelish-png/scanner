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
        UITestInteraction.tap(refresh, in: app, identifier: "cardShowInventory.refresh")
        let quantity = app.staticTexts["cardShowInventory.quantity"]
        reveal(quantity, in: app)
        assertValue("2", title: "Physical cards", element: quantity)
        assertValue("1", title: "Inventory rows", element: app.staticTexts["cardShowInventory.rows"])
        assertValue("2", title: "Available in local stock", element: app.staticTexts["cardShowInventory.workingQuantity"])
        XCTAssertTrue(app.staticTexts["cardShowInventory.updated"].exists)
        UITestInteraction.tap(refresh, in: app, identifier: "cardShowInventory.refresh")
        reveal(quantity, in: app)
        let updated = NSPredicate(format: "label == %@ OR label == %@", "3", "Physical cards, 3")
        let changed = expectation(for: updated, evaluatedWith: quantity)
        await fulfillment(of: [changed], timeout: 5)
        assertValue("1", title: "Inventory rows", element: app.staticTexts["cardShowInventory.rows"])
        assertValue("3", title: "Available in local stock", element: app.staticTexts["cardShowInventory.workingQuantity"])
        let open = app.buttons["cardShowInventory.open"]
        UITestInteraction.tap(open, in: app, identifier: "cardShowInventory.open")
        let options = app.descendants(matching: .any).matching(identifier: "list.options").firstMatch
        UITestInteraction.tapToolbar(options, in: app, identifier: "list.options")
        let export = app.buttons["list.exportCSV"]
        XCTAssertTrue(export.waitForExistence(timeout: 5)); XCTAssertTrue(export.isEnabled)
        // The menu's dismissing backdrop covers the bar for accessibility.
        // Its title remains visibly outside the popover; tap that verified
        // location without asking AXScrollToVisible to scroll the fixed bar.
        let title = app.navigationBars["Card Show"].staticTexts["Card Show"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertTrue(app.windows.firstMatch.frame.contains(title.frame))
        XCTAssertGreaterThan(title.frame.width, 0)
        XCTAssertGreaterThan(title.frame.height, 0)
        title.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertFalse(app.buttons["list.searchAndAdd"].exists)
        let card = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "list.card.")).firstMatch
        UITestInteraction.tap(card, in: app)
        XCTAssertTrue(app.navigationBars["Card Research"].waitForExistence(timeout: 5))
        let market = app.segmentedControls["cardResearch.section"].buttons["Market"]
        XCTAssertTrue(market.waitForExistence(timeout: 5)); XCTAssertTrue(market.isSelected)
        XCTAssertFalse(app.buttons["cardEditor.save"].exists, "Imported cards open read-only research")
        UITestInteraction.tapToolbar(app.descendants(matching: .any).matching(identifier: "cardResearch.options").firstMatch,
                                     in: app, identifier: "cardResearch.options")
        UITestInteraction.tap(app.buttons["cardResearch.importedDetails"], in: app)
        XCTAssertTrue(app.navigationBars["Card Details"].waitForExistence(timeout: 5))
        let savedQuantity = app.descendants(matching: .any)["cardShowInventory.cardQuantity"]
        reveal(savedQuantity, in: app)
        assertValue("3", title: "Quantity", element: savedQuantity)
        XCTAssertFalse(app.buttons["cardEditor.save"].exists)
        UITestInteraction.tapToolbar(app.navigationBars.buttons.element(boundBy: 0), in: app,
                                     identifier: "navigation.back")
        XCTAssertTrue(app.navigationBars["Card Research"].waitForExistence(timeout: 5))
        UITestInteraction.tapToolbar(app.navigationBars.buttons.element(boundBy: 0), in: app,
                                     identifier: "navigation.back")
        XCTAssertTrue(app.navigationBars["Card Show"].waitForExistence(timeout: 5))
        UITestInteraction.tapToolbar(app.navigationBars.buttons.element(boundBy: 0), in: app,
                                     identifier: "navigation.back")
        XCTAssertTrue(app.navigationBars["Card Show Inventory"].waitForExistence(timeout: 5))
        reveal(quantity, in: app)
        assertValue("3", title: "Physical cards", element: app.staticTexts["cardShowInventory.quantity"])
        assertValue("1", title: "Inventory rows", element: app.staticTexts["cardShowInventory.rows"])
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication,
                        file: StaticString = #filePath, line: UInt = #line) {
        UITestInteraction.reveal(element, in: app, file: file, line: line)
    }

    private func assertValue(_ expected: String, title: String, element: XCUIElement,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue([expected, title + ", " + expected].contains(element.label),
                      "Expected \(title): \(expected); got \(element.label)", file: file, line: line)
    }
}
