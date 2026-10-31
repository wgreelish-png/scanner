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
        XCTAssertTrue(app.navigationBars["Show Budget"].waitForExistence(timeout: 5))
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
        let inventory = app.buttons["savedLists.cardShowInventory"]
        XCTAssertTrue(inventory.waitForExistence(timeout: 5)); inventory.tap()
        XCTAssertTrue(app.navigationBars["Card Show Inventory"].waitForExistence(timeout: 5))

        selectTab("Show", in: app)
        XCTAssertTrue(app.navigationBars["Show Budget"].waitForExistence(timeout: 5))
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
        XCTAssertTrue(app.buttons["savedLists.cardShowInventory"].exists)
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        if let path = ProcessInfo.processInfo.environment["DYLD_FALLBACK_LIBRARY_PATH"] {
            app.launchEnvironment["DYLD_FALLBACK_LIBRARY_PATH"] = path
        }
        app.launchArguments = ["-autoDatabaseUpdates", "NO"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Scan"].waitForExistence(timeout: 10))
        return app
    }

    private func selectTab(_ title: String, in app: XCUIApplication) {
        let tab = app.tabBars.buttons[title]
        XCTAssertTrue(tab.waitForExistence(timeout: 5)); tab.tap()
    }
}
