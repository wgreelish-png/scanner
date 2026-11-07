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
        _ = UITestInteraction.tapToolbar(app.buttons["savedLists.newList"], in: app)
        let nameField = app.textFields["savedLists.newName"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        nameField.tap(); nameField.typeText(name + "\n")
        _ = UITestInteraction.tapToolbar(app.buttons["savedLists.create"], in: app)
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
        _ = UITestInteraction.tapToolbar(app.navigationBars.buttons.element(boundBy: 0), in: app)
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
        _ = UITestInteraction.tapToolbar(app.buttons["savedLists.newList"], in: app)
        let field = app.textFields["savedLists.newName"]
        XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap(); field.typeText(name + "\n")
        _ = UITestInteraction.tapToolbar(app.buttons["savedLists.create"], in: app)
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
        openFixtureResearch(in: app)
        tapVisible(app.buttons["cardResearch.condition.LP"], in: app)
        openEditorFromResearch(in: app)
        let savedCondition = app.buttons["cardEditor.condition.NM"]
        reveal(savedCondition, in: app)
        XCTAssertTrue(savedCondition.isSelected, "Research selections must not change the saved card")
        setFixtureDraft(price: "18", in: app)
        tapVisible(app.buttons["cardEditor.research"], in: app)
        XCTAssertTrue(app.navigationBars["Card Research"].waitForExistence(timeout: 5))
        assertMainTabs(in: app)
        _ = UITestInteraction.tapToolbar(app.buttons["cardResearch.connection"], in: app)
        XCTAssertTrue(app.navigationBars["TCGTracking API Connection"].waitForExistence(timeout: 5))
        assertMainTabs(in: app)
        let shipper = app.textFields["researchConnection.shipperID"]
        _ = UITestInteraction.tap(shipper, in: app)
        let previousShipper = shipper.value as? String ?? ""
        shipper.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: max(1, previousShipper.count)) + "navigation-draft")
        _ = UITestInteraction.tap(app.buttons["researchConnection.keyboardDone"], in: app)

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
        _ = UITestInteraction.tapToolbar(app.buttons["cardEditor.cancel"], in: app)
        assertDirectMarket(in: app, cardName: "Navigation Draft Card")

        openEditorFromResearch(in: app)
        assertDraft(price: "25", quantity: 1, in: app)
        _ = UITestInteraction.tapToolbar(app.buttons["cardEditor.cancel"], in: app)
        assertDirectMarket(in: app, cardName: "Navigation Draft Card")
        goBack(from: "Card Research", in: app)
        XCTAssertTrue(app.navigationBars["Navigation Test List"].waitForExistence(timeout: 5))
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
        _ = UITestInteraction.tapToolbar(app.buttons["cardEditor.save"], in: app)
        assertDirectMarket(in: app, cardName: "Navigation Draft Card")
        openEditorFromResearch(in: app)
        assertDraft(price: "18", quantity: 2, in: app)
        _ = UITestInteraction.tapToolbar(app.buttons["cardEditor.cancel"], in: app)
        assertDirectMarket(in: app, cardName: "Navigation Draft Card")
        goBack(from: "Card Research", in: app)
        XCTAssertTrue(app.navigationBars["Navigation Test List"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["scanner.options"].exists)
    }

    func testImportedCardAndResearchKeepMainTabsAndReadonlyInventory() async throws {
        continueAfterFailure = false
        let app = launch(persistentNavigation: true)
        defer { app.terminate() }
        let importedAt = openImportedFixtureResearch(in: app)
        openResearchOptions(in: app)
        XCTAssertFalse(app.buttons["cardResearch.editCard"].exists, "Imported cards remain read-only")
        tapVisible(app.buttons["cardResearch.importedDetails"], in: app)
        XCTAssertTrue(app.navigationBars["Card Details"].waitForExistence(timeout: 5))
        assertMainTabs(in: app)
        XCTAssertFalse(app.buttons["cardEditor.save"].exists)
        assertImportedCardUnchanged(in: app)
        _ = UITestInteraction.tapToolbar(app.navigationBars["Card Details"].buttons["Done"], in: app)
        assertDirectMarket(in: app, cardName: "Navigation Imported Card")
        assertImportedSnapshotUnchanged(importedAt, in: app)
    }

    func testImportedResearchConnectionRetainsTabsAndReadonlySnapshotAcrossSections() async throws {
        continueAfterFailure = false
        let app = launch(persistentNavigation: true)
        defer { app.terminate() }
        let importedAt = openImportedFixtureResearch(in: app)
        _ = UITestInteraction.tapToolbar(app.buttons["cardResearch.connection"], in: app)
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
        assertDirectMarket(in: app, cardName: "Navigation Imported Card")
        openResearchOptions(in: app)
        tapVisible(app.buttons["cardResearch.importedDetails"], in: app)
        assertImportedCardUnchanged(in: app)
        _ = UITestInteraction.tapToolbar(app.navigationBars["Card Details"].buttons["Done"], in: app)
        assertDirectMarket(in: app, cardName: "Navigation Imported Card")
        assertImportedSnapshotUnchanged(importedAt, in: app)
    }

    /// Both scenarios start from the same real imported-card navigation path;
    /// their separate launches keep each bounded without dropping assertions.
    private func openImportedFixtureResearch(in app: XCUIApplication) -> String {
        selectTab("Show", in: app)
        tapVisible(app.buttons["show.inventory"], in: app)
        tapVisible(app.buttons["showInventory.importSnapshot"], in: app)
        XCTAssertTrue(app.navigationBars["Card Show Inventory"].waitForExistence(timeout: 5))
        let updated = app.staticTexts["cardShowInventory.updated"]
        reveal(updated, in: app)
        let importedAt = updated.label
        XCTAssertFalse(importedAt.isEmpty)
        tapVisible(app.buttons["cardShowInventory.open"], in: app)
        XCTAssertTrue(app.navigationBars["Card Show"].waitForExistence(timeout: 5))
        let source = app.staticTexts["This list mirrors your Card Show location. Use an editable copy to scan or change cards locally."]
        reveal(source, in: app)
        XCTAssertTrue(source.exists)
        tapVisible(app.buttons["list.card.10000000-0000-0000-0000-000000000002"], in: app)
        assertDirectMarket(in: app, cardName: "Navigation Imported Card")
        return importedAt
    }

    private func assertImportedSnapshotUnchanged(_ importedAt: String, in app: XCUIApplication) {
        goBack(from: "Card Research", in: app)
        XCTAssertTrue(app.navigationBars["Card Show"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["scanner.options"].exists)
        XCTAssertFalse(app.buttons["list.searchAndAdd"].exists)
        let source = app.staticTexts["This list mirrors your Card Show location. Use an editable copy to scan or change cards locally."]
        reveal(source, in: app)
        XCTAssertTrue(source.exists)
        goBack(from: "Card Show", in: app)
        XCTAssertTrue(app.navigationBars["Card Show Inventory"].waitForExistence(timeout: 5))
        let updated = app.staticTexts["cardShowInventory.updated"]
        reveal(updated, in: app)
        XCTAssertEqual(updated.label, importedAt, "Research must not refresh or replace the saved snapshot")
        let quantity = app.descendants(matching: .any)["cardShowInventory.quantity"]
        reveal(quantity, in: app)
        XCTAssertTrue(["2", "Physical cards, 2"].contains(quantity.label))
    }

    private func openFixtureEditor(in app: XCUIApplication) {
        openFixtureResearch(in: app)
        openEditorFromResearch(in: app)
    }

    private func openFixtureResearch(in app: XCUIApplication) {
        selectTab("Lists", in: app)
        XCTAssertEqual(app.staticTexts["savedLists.count"].label, "1")
        tapVisible(app.staticTexts["Navigation Test List"], in: app)
        tapVisible(app.buttons["list.card.10000000-0000-0000-0000-000000000001"], in: app)
        assertDirectMarket(in: app, cardName: "Navigation Draft Card")
    }

    private func openResearchOptions(in app: XCUIApplication) {
        _ = UITestInteraction.tapToolbar(app.descendants(matching: .any)
            .matching(identifier: "cardResearch.options").firstMatch, in: app,
            identifier: "cardResearch.options")
    }

    private func openEditorFromResearch(in app: XCUIApplication) {
        XCTAssertTrue(app.navigationBars["Card Research"].waitForExistence(timeout: 5))
        openResearchOptions(in: app)
        tapVisible(app.buttons["cardResearch.editCard"], in: app)
        XCTAssertTrue(app.navigationBars["Card Details"].waitForExistence(timeout: 5))
        assertMainTabs(in: app)
    }

    private func assertDirectMarket(in app: XCUIApplication, cardName: String,
                                    file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(app.navigationBars["Card Research"].waitForExistence(timeout: 5), file: file, line: line)
        let sections = app.segmentedControls["cardResearch.section"]
        XCTAssertTrue(sections.waitForExistence(timeout: 5), file: file, line: line)
        XCTAssertTrue(sections.buttons["Market"].isSelected,
                      "Cards open directly in Market research", file: file, line: line)
        XCTAssertEqual(app.staticTexts["cardResearch.name"].label, cardName, file: file, line: line)
        XCTAssertFalse(app.buttons["cardEditor.save"].exists,
                       "Viewing research must not enter the editable card draft", file: file, line: line)
        assertMainTabs(in: app, file: file, line: line)
    }

    private func assertImportedCardUnchanged(in app: XCUIApplication,
                                              file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(app.navigationBars["Card Details"].waitForExistence(timeout: 5), file: file, line: line)
        let price = app.staticTexts["cardShowInventory.cardPrice"]
        reveal(price, in: app, file: file, line: line)
        XCTAssertEqual(price.label, "$10.00", file: file, line: line)
        let quantity = app.staticTexts["cardShowInventory.cardQuantity"]
        reveal(quantity, in: app, file: file, line: line)
        XCTAssertTrue(["2", "Quantity, 2"].contains(quantity.label), file: file, line: line)
        XCTAssertFalse(app.buttons["cardEditor.save"].exists, file: file, line: line)
        let source = app.staticTexts["Refresh Card Show Inventory to update this saved card. Make an editable copy of the list for local changes."]
        reveal(source, in: app, file: file, line: line)
        XCTAssertTrue(source.exists, file: file, line: line)
    }

    private func priceAdjustment(in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label == %@", "Adjust market price")).firstMatch
    }

    private func setFixtureDraft(price: String, in app: XCUIApplication) {
        let quantity = app.steppers["cardEditor.quantity"]
        _ = UITestInteraction.tap(quantity.buttons["cardEditor.quantity-Increment"], in: app,
                                  identifier: "cardEditor.quantity-Increment")
        tapVisible(priceAdjustment(in: app), in: app)
        let field = app.textFields["cardEditor.manualPrice"]
        _ = UITestInteraction.tap(field, in: app)
        let existing = field.value as? String ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: max(1, existing.count)) + price)
        let done = app.buttons["cardEditor.keyboardDone"]
        _ = UITestInteraction.tap(done, in: app)
    }

    private func assertDraft(price: String, quantity: Int, in app: XCUIApplication,
                             file: StaticString = #filePath, line: UInt = #line) {
        let amount = app.textFields["cardEditor.manualPrice"]
        let disclosure = priceAdjustment(in: app)
        reveal(disclosure, in: app, identifier: "cardEditor.adjustPrice", file: file, line: line)
        if !amount.exists { _ = UITestInteraction.tap(disclosure, in: app) }
        reveal(amount, in: app, identifier: "cardEditor.manualPrice", file: file, line: line)
        XCTAssertEqual(amount.value as? String, price, file: file, line: line)
        let stepper = app.steppers["cardEditor.quantity"]
        // UIKit exposes the stepper's actionable buttons as hittable; its
        // composite parent may remain non-hittable while fully on screen.
        reveal(stepper.buttons["cardEditor.quantity-Increment"], in: app, identifier: "cardEditor.quantity-Increment", file: file, line: line)
        let value = String(quantity)
        XCTAssertTrue(stepper.value as? String == value || stepper.label.contains(value) ||
                      stepper.staticTexts[value].exists, "Expected draft quantity \(quantity)", file: file, line: line)
    }

    private func assertMainTabs(in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        for title in ["Lists", "Scan", "Show", "Research", "Settings"] {
            let tab = app.tabBars.buttons[title]
            XCTAssertTrue(tab.exists || tab.waitForExistence(timeout: 5), "Missing \(title) tab", file: file, line: line)
            XCTAssertTrue(tab.isHittable, "\(title) must be usable without dismissing screens", file: file, line: line)
        }
    }

    private func goBack(from title: String, in app: XCUIApplication) {
        let bar = app.navigationBars[title]
        XCTAssertTrue(bar.waitForExistence(timeout: 5))
        _ = UITestInteraction.tapToolbar(bar.buttons.element(boundBy: 0), in: app)
    }

    private func tapVisible(_ element: XCUIElement, in app: XCUIApplication,
                            identifier: String? = nil, file: StaticString = #filePath, line: UInt = #line) {
        _ = UITestInteraction.tap(element, in: app, identifier: identifier, file: file, line: line)
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication,
                        identifier: String? = nil, file: StaticString = #filePath, line: UInt = #line) {
        _ = UITestInteraction.reveal(element, in: app, identifier: identifier, file: file, line: line)
    }

    private func launch(persistentNavigation: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        if let path = ProcessInfo.processInfo.environment["DYLD_FALLBACK_LIBRARY_PATH"] {
            app.launchEnvironment["DYLD_FALLBACK_LIBRARY_PATH"] = path
        }
        app.launchArguments = ["-autoDatabaseUpdates", "NO", "-betaAutomaticIPAllowlist", "NO"]
        if persistentNavigation {
            app.launchArguments += ["--uitest-persistent-navigation"]
        }
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Scan"].waitForExistence(timeout: 10))
        return app
    }

    private func selectTab(_ title: String, in app: XCUIApplication) {
        let tab = app.tabBars.buttons[title]
        _ = UITestInteraction.tapToolbar(tab, in: app, identifier: "tab." + title)
    }
}
