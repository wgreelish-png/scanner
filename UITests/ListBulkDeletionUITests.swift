import XCTest

@MainActor final class ListBulkDeletionUITests: XCTestCase {
    func testSelectingSeveralListsCancelsSafelyThenDeletesOnlySelection() async throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        if let path = ProcessInfo.processInfo.environment["DYLD_FALLBACK_LIBRARY_PATH"] {
            app.launchEnvironment["DYLD_FALLBACK_LIBRARY_PATH"] = path
        }
        app.launchArguments = ["-autoDatabaseUpdates", "NO", "--uitest-bulk-list-delete"]
        app.launch(); defer { app.terminate() }
        XCTAssertTrue(app.navigationBars["My Lists"].waitForExistence(timeout: 10))
        _ = UITestInteraction.tapToolbar(app.buttons["savedLists.selectionMode"], in: app)
        let delete = app.buttons["savedLists.deleteSelected"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5)); XCTAssertFalse(delete.isEnabled)
        let first = app.buttons["savedLists.select.Bulk Fixture Alpha"]
        let second = app.buttons["savedLists.select.Bulk Fixture Beta"]
        _ = UITestInteraction.tap(first, in: app)
        _ = UITestInteraction.tap(second, in: app)
        XCTAssertEqual(delete.label, "Delete Selected (2)")
        delete.tap()
        let cancel = app.buttons["bulkDeletion.cancel"]
        _ = UITestInteraction.tapToolbar(cancel, in: app)
        XCTAssertTrue(app.navigationBars["My Lists"].waitForExistence(timeout: 5))
        XCTAssertEqual(delete.label, "Delete Selected (2)")
        delete.tap()
        let confirm = app.buttons["bulkDeletion.confirm"]
        _ = UITestInteraction.tap(confirm, in: app)
        XCTAssertTrue(app.navigationBars["My Lists"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Bulk Fixture Alpha"].exists)
        XCTAssertFalse(app.staticTexts["Bulk Fixture Beta"].exists)
        let keep = app.staticTexts["Bulk Fixture Keep"]
        reveal(keep, in: app)
        XCTAssertTrue(keep.exists)
        XCTAssertEqual(app.staticTexts["savedLists.count"].label, "1")
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication,
                        file: StaticString = #filePath, line: UInt = #line) {
        _ = UITestInteraction.reveal(element, in: app, file: file, line: line)
    }
}
