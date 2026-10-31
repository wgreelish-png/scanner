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
        app.buttons["savedLists.selectionMode"].tap()
        let delete = app.buttons["savedLists.deleteSelected"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5)); XCTAssertFalse(delete.isEnabled)
        let first = app.buttons["savedLists.select.Bulk Fixture Alpha"]
        let second = app.buttons["savedLists.select.Bulk Fixture Beta"]
        reveal(first, in: app); first.tap()
        reveal(second, in: app); second.tap()
        XCTAssertEqual(delete.label, "Delete Selected (2)")
        delete.tap()
        let cancel = app.buttons["bulkDeletion.cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5)); cancel.tap()
        XCTAssertTrue(app.navigationBars["My Lists"].waitForExistence(timeout: 5))
        XCTAssertEqual(delete.label, "Delete Selected (2)")
        delete.tap()
        let confirm = app.buttons["bulkDeletion.confirm"]
        reveal(confirm, in: app); confirm.tap()
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
        for _ in 0..<8 {
            if element.exists && element.isHittable { return }
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.79))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.30))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        XCTAssertTrue(element.waitForExistence(timeout: 5), file: file, line: line)
        XCTAssertTrue(element.isHittable, file: file, line: line)
    }
}
