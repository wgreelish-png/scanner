import XCTest

/// Exercises the normal tab shell without launching a camera or modifying a
/// user's selected pricing source, connection, or existing scan session.
@MainActor final class AppNavigationUITests: XCTestCase {
    func testSwitchingMainTabsDoesNotCreateListsOrOpenTheCamera() async throws {
        continueAfterFailure = false
        let app = launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["home.startNewScan"].waitForExistence(timeout: 5))

        selectTab("Lists", in: app)
        let count = app.staticTexts["savedLists.count"]
        XCTAssertTrue(count.waitForExistence(timeout: 5))
        let originalCount = count.label

        selectTab("Show", in: app)
        XCTAssertTrue(app.navigationBars["Show"].waitForExistence(timeout: 5))
        selectTab("Research", in: app)
        XCTAssertTrue(app.buttons["home.psaResearch"].waitForExistence(timeout: 5))
        selectTab("Settings", in: app)
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        selectTab("Scan", in: app)
        XCTAssertTrue(app.buttons["home.startNewScan"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["scanner.options"].exists)
        XCTAssertFalse(app.navigationBars["Choose the Card"].exists)
        XCTAssertFalse(app.alerts.firstMatch.exists)

        selectTab("Lists", in: app)
        XCTAssertTrue(count.waitForExistence(timeout: 5))
        XCTAssertEqual(count.label, originalCount, "Selecting a tab must not create a scan list")
    }

    func testListDetailRemainsOpenWhenSwitchingTabs() async throws {
        continueAfterFailure = false
        let app = launch()
        defer { app.terminate() }
        let name = "UITest Navigation " + String(UUID().uuidString.prefix(8))

        selectTab("Lists", in: app)
        app.buttons["savedLists.newList"].tap()
        let nameField = app.textFields["savedLists.newName"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        nameField.tap(); nameField.typeText(name + "\n")
        app.buttons["savedLists.create"].tap()
        let row = app.cells.containing(.staticText, identifier: name).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5)); row.tap()
        XCTAssertTrue(app.navigationBars[name].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["list.outcomeValue"].exists)

        selectTab("Settings", in: app)
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        selectTab("Lists", in: app)
        XCTAssertTrue(app.navigationBars[name].waitForExistence(timeout: 5), "Each tab keeps its own navigation stack")
        XCTAssertTrue(app.staticTexts["list.outcomeValue"].exists)

        selectTab("Research", in: app)
        selectTab("Scan", in: app)
        XCTAssertTrue(app.buttons["home.startNewScan"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["scanner.options"].exists)
        selectTab("Lists", in: app)
        XCTAssertTrue(app.navigationBars[name].waitForExistence(timeout: 5))

        // Remove only this test's new list through the ordinary confirmation.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(row.waitForExistence(timeout: 5)); row.swipeLeft()
        let confirm = app.buttons["listDeletion.confirm"]
        if !confirm.waitForExistence(timeout: 1) {
            let delete = app.buttons["savedList.requestDelete"].firstMatch
            XCTAssertTrue(delete.waitForExistence(timeout: 5)); delete.tap()
        }
        XCTAssertTrue(confirm.waitForExistence(timeout: 5)); confirm.tap()
        let removed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: row)
        XCTAssertEqual(XCTWaiter.wait(for: [removed], timeout: 5), .completed)
    }

    func testOpenExistingListReturnsToListsRootAfterShowDetailsAndRetainedListNavigation() async throws {
        continueAfterFailure = false
        let app = launch()
        defer { app.terminate() }
        selectTab("Lists", in: app)
        let name = "UITest Return " + String(UUID().uuidString.prefix(8))
        app.buttons["savedLists.newList"].tap()
        let field = app.textFields["savedLists.newName"]
        XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap(); field.typeText(name + "\n")
        app.buttons["savedLists.create"].tap()
        let row = app.cells.containing(.staticText, identifier: name).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5)); row.tap()
        XCTAssertTrue(app.navigationBars[name].waitForExistence(timeout: 5))

        selectTab("Show", in: app)
        let inventory = app.buttons["show.inventory"]
        XCTAssertTrue(inventory.waitForExistence(timeout: 5)); inventory.tap()
        XCTAssertTrue(app.navigationBars["Show Inventory"].waitForExistence(timeout: 5))
        selectTab("Scan", in: app)
        let existing = app.buttons["home.openExistingLists"]
        for _ in 0..<5 {
            if existing.exists && existing.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(existing.waitForExistence(timeout: 5)); XCTAssertTrue(existing.isHittable)
        existing.tap()

        XCTAssertTrue(app.tabBars.buttons["Lists"].isSelected)
        XCTAssertTrue(app.navigationBars["My Lists"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.navigationBars["Card Show Inventory"].isHittable)
        XCTAssertFalse(app.navigationBars["Show Budget"].isHittable)
        XCTAssertFalse(app.buttons["scanner.options"].exists)
        XCTAssertFalse(app.navigationBars["Choose the Card"].exists)
        XCTAssertFalse(app.buttons["savedLists.cardShowInventory"].exists)
    }

    func testEditableCardRetainsMainTabsAndUnsavedDraftThroughResearchAndConnection() async throws {
        continueAfterFailure = false
        let app = launch(persistentNavigation: true)
        defer { app.terminate() }
        openFixtureEditor(in: app)
        setFixtureDraft(price: "18", in: app)
        tapVisible(app.buttons["cardEditor.research"], in: app)
        XCTAssertTrue(app.navigationBars["Card Research"].waitForExistence(timeout: 5))
        assertMainTabs(in: app)
        app.buttons["cardResearch.connection"].tap()
        XCTAssertTrue(app.navigationBars["TCGTracking API Connection"].waitForExistence(timeout: 5))
        assertMainTabs(in: app)
        let shipper = app.textFields["researchConnection.shipperID"]
        reveal(shipper, in: app); shipper.tap()
        let previousShipper = shipper.value as? String ?? ""
        shipper.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: max(1, previousShipper.count)) + "navigation-draft")
        app.buttons["researchConnection.keyboardDone"].tap()

        for tab in ["Scan", "Show", "Research", "Settings"] {
            selectTab(tab, in: app)
            assertMainTabs(in: app)
            if tab == "Settings" {
                tapVisible(app.buttons["settings.about"], in: app)
                XCTAssertTrue(app.navigationBars["About & Privacy"].waitForExistence(timeout: 5))
                assertMainTabs(in: app)
            }
            XCTAssertFalse(app.buttons["scanner.options"].exists)
            selectTab("Lists", in: app)
            XCTAssertTrue(app.navigationBars["TCGTracking API Connection"].waitForExistence(timeout: 5),
                          "Switching sections must preserve the deep Lists route")
            XCTAssertEqual(shipper.value as? String, "navigation-draft", "Tab changes must retain unsaved connection fields")
        }
        selectTab("Settings", in: app)
        XCTAssertTrue(app.navigationBars["About & Privacy"].waitForExistence(timeout: 5),
                      "Settings keeps its own navigation position")
        selectTab("Lists", in: app)
        goBack(from: "TCGTracking API Connection", in: app)
        goBack(from: "Card Research", in: app)
        XCTAssertTrue(app.navigationBars["Card Details"].waitForExistence(timeout: 5))
        assertDraft(price: "18", quantity: 2, in: app)
        app.buttons["cardEditor.cancel"].tap()
        XCTAssertTrue(app.navigationBars["Navigation Test List"].waitForExistence(timeout: 5))

        tapVisible(app.staticTexts["Navigation Draft Card"], in: app)
        assertDraft(price: "25", quantity: 1, in: app)
        app.buttons["cardEditor.cancel"].tap()
        goBack(from: "Navigation Test List", in: app)
        XCTAssertEqual(app.staticTexts["savedLists.count"].label, "1", "Tab navigation must not create lists")
        XCTAssertFalse(app.buttons["scanner.options"].exists)
    }

    func testEditableCardSavesOnlyWhenExplicitlySavedAfterSwitchingTabs() async throws {
        continueAfterFailure = false
        let app = launch(persistentNavigation: true)
        defer { app.terminate() }
        openFixtureEditor(in: app)
        setFixtureDraft(price: "18", in: app)
        selectTab("Settings", in: app)
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        selectTab("Lists", in: app)
        XCTAssertTrue(app.navigationBars["Card Details"].waitForExistence(timeout: 5))
        assertMainTabs(in: app)
        assertDraft(price: "18", quantity: 2, in: app)
        app.buttons["cardEditor.save"].tap()
        XCTAssertTrue(app.navigationBars["Navigation Test List"].waitForExistence(timeout: 5))
        tapVisible(app.staticTexts["Navigation Draft Card"], in: app)
        assertDraft(price: "18", quantity: 2, in: app)
        app.buttons["cardEditor.cancel"].tap()
        XCTAssertTrue(app.navigationBars["Navigation Test List"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["scanner.options"].exists)
    }

    func testImportedCardAndResearchKeepMainTabsAndReadonlyInventory() async throws {
        continueAfterFailure = false
        let app = launch(persistentNavigation: true)
        defer { app.terminate() }
        selectTab("Show", in: app)
        tapVisible(app.buttons["show.inventory"], in: app)
        tapVisible(app.buttons["showInventory.importSnapshot"], in: app)
        XCTAssertTrue(app.navigationBars["Card Show Inventory"].waitForExistence(timeout: 5))
        tapVisible(app.buttons["cardShowInventory.open"], in: app)
        tapVisible(app.staticTexts["Navigation Imported Card"], in: app)
        XCTAssertTrue(app.navigationBars["Card Details"].waitForExistence(timeout: 5))
        assertMainTabs(in: app)
        XCTAssertFalse(app.buttons["cardEditor.save"].exists)
        tapVisible(app.buttons["cardShowInventory.cardResearch"], in: app)
        XCTAssertTrue(app.navigationBars["Card Research"].waitForExistence(timeout: 5))
        app.buttons["cardResearch.connection"].tap()
        XCTAssertTrue(app.navigationBars["TCGTracking API Connection"].waitForExistence(timeout: 5))
        assertMainTabs(in: app)

        selectTab("Settings", in: app)
        tapVisible(app.buttons["settings.about"], in: app)
        XCTAssertTrue(app.navigationBars["About & Privacy"].waitForExistence(timeout: 5))
        selectTab("Lists", in: app)
        XCTAssertTrue(app.navigationBars["My Lists"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["savedLists.count"].label, "1")
        selectTab("Scan", in: app)
        XCTAssertTrue(app.buttons["home.startNewScan"].waitForExistence(timeout: 5))
        selectTab("Research", in: app)
        selectTab("Show", in: app)
        XCTAssertTrue(app.navigationBars["TCGTracking API Connection"].waitForExistence(timeout: 5))
        goBack(from: "TCGTracking API Connection", in: app)
        goBack(from: "Card Research", in: app)
        let quantity = app.staticTexts["cardShowInventory.cardQuantity"]
        reveal(quantity, in: app)
        XCTAssertTrue(["2", "Quantity, 2"].contains(quantity.label))
        app.navigationBars["Card Details"].buttons["Done"].tap()
        XCTAssertTrue(app.navigationBars["Card Show"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["scanner.options"].exists)
        XCTAssertFalse(app.buttons["list.searchAndAdd"].exists)
    }

    private func openFixtureEditor(in app: XCUIApplication) {
        selectTab("Lists", in: app)
        XCTAssertEqual(app.staticTexts["savedLists.count"].label, "1")
        tapVisible(app.staticTexts["Navigation Test List"], in: app)
        tapVisible(app.staticTexts["Navigation Draft Card"], in: app)
        XCTAssertTrue(app.navigationBars["Card Details"].waitForExistence(timeout: 5))
        assertMainTabs(in: app)
    }

    private func setFixtureDraft(price: String, in app: XCUIApplication) {
        let quantity = app.steppers["cardEditor.quantity"]
        reveal(quantity, in: app)
        quantity.buttons["Increment"].tap()
        tapVisible(app.buttons["cardEditor.adjustPrice"], in: app)
        let field = app.textFields["cardEditor.manualPrice"]
        reveal(field, in: app); field.tap()
        let existing = field.value as? String ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: max(1, existing.count)) + price)
        let done = app.buttons["cardEditor.keyboardDone"]
        XCTAssertTrue(done.waitForExistence(timeout: 5)); done.tap()
    }

    private func assertDraft(price: String, quantity: Int, in app: XCUIApplication,
                             file: StaticString = #filePath, line: UInt = #line) {
        let amount = app.textFields["cardEditor.manualPrice"]
        let disclosure = app.buttons["cardEditor.adjustPrice"]
        reveal(disclosure, in: app)
        if !amount.exists { disclosure.tap() }
        reveal(amount, in: app)
        XCTAssertEqual(amount.value as? String, price, file: file, line: line)
        let stepper = app.steppers["cardEditor.quantity"]
        reveal(stepper, in: app)
        let value = String(quantity)
        XCTAssertTrue(stepper.value as? String == value || stepper.label.contains(value) ||
                      stepper.staticTexts[value].exists, "Expected draft quantity \(quantity)", file: file, line: line)
    }

    private func assertMainTabs(in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        for title in ["Lists", "Scan", "Show", "Research", "Settings"] {
            let tab = app.tabBars.buttons[title]
            XCTAssertTrue(tab.waitForExistence(timeout: 5), "Missing \(title) tab", file: file, line: line)
            XCTAssertTrue(tab.isHittable, "\(title) must be usable without dismissing screens", file: file, line: line)
        }
    }

    private func goBack(from title: String, in app: XCUIApplication) {
        let bar = app.navigationBars[title]
        XCTAssertTrue(bar.waitForExistence(timeout: 5))
        bar.buttons.element(boundBy: 0).tap()
    }

    private func tapVisible(_ element: XCUIElement, in app: XCUIApplication) {
        reveal(element, in: app); element.tap()
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        if element.exists && element.isHittable { return }
        let list = app.collectionViews.firstMatch
        for _ in 0..<3 { list.swipeDown() }
        for _ in 0..<8 {
            if element.exists && element.isHittable { return }
            list.swipeUp()
        }
        XCTAssertTrue(element.waitForExistence(timeout: 5)); XCTAssertTrue(element.isHittable)
    }

    private func launch(persistentNavigation: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        if let path = ProcessInfo.processInfo.environment["DYLD_FALLBACK_LIBRARY_PATH"] {
            app.launchEnvironment["DYLD_FALLBACK_LIBRARY_PATH"] = path
        }
        app.launchArguments = ["-autoDatabaseUpdates", "NO"]
        if persistentNavigation {
            app.launchArguments += ["--uitest-persistent-navigation", "-betaAutomaticIPAllowlist", "NO"]
        }
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Scan"].waitForExistence(timeout: 10))
        return app
    }

    private func selectTab(_ title: String, in app: XCUIApplication) {
        let tab = app.tabBars.buttons[title]
        XCTAssertTrue(tab.waitForExistence(timeout: 5)); tab.tap()
    }
}
