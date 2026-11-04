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

    func testLongSelectionScrollsWhileDeleteConfirmationStaysFixed() async throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        if let path = ProcessInfo.processInfo.environment["DYLD_FALLBACK_LIBRARY_PATH"] {
            app.launchEnvironment["DYLD_FALLBACK_LIBRARY_PATH"] = path
        }
        app.launchArguments = ["-autoDatabaseUpdates", "NO", "--uitest-bulk-list-delete", "--uitest-long-bulk-list-delete"]
        app.launch(); defer { app.terminate() }
        XCTAssertTrue(app.navigationBars["My Lists"].waitForExistence(timeout: 10))
        _ = UITestInteraction.tapToolbar(app.buttons["savedLists.selectionMode"], in: app)
        _ = UITestInteraction.tapToolbar(app.buttons["savedLists.selectAll"], in: app)
        let delete = app.buttons["savedLists.deleteSelected"]
        XCTAssertEqual(delete.label, "Delete Selected (63)")
        delete.tap()

        let confirm = app.buttons["bulkDeletion.confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        let window = app.windows.firstMatch.frame
        XCTAssertTrue(confirm.isHittable, "Confirm must be available before scrolling the selected lists")
        XCTAssertTrue(window.contains(confirm.frame))
        XCTAssertGreaterThanOrEqual(confirm.frame.height, 44)
        let fixedFrame = confirm.frame
        let content = app.descendants(matching: .any).matching(identifier: "bulkDeletion.selectedLists").firstMatch
        XCTAssertTrue(content.waitForExistence(timeout: 5))
        let bounds = content.frame.intersection(window)
        let top = max(bounds.minY, app.navigationBars["Delete Selected Lists"].frame.maxY) + 16
        let bottom = min(bounds.maxY, fixedFrame.minY) - 16
        XCTAssertGreaterThan(bottom - top, 100)
        let rows = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Bulk Fixture Extra "))
        let visibleRow = try XCTUnwrap(rows.allElementsBoundByIndex.first { row in
            row.exists && row.isHittable && row.frame.height > 0 && row.frame.midY > top && row.frame.midY < bottom
        })
        let trackedRow = app.staticTexts.matching(NSPredicate(format: "label == %@", visibleRow.label)).firstMatch
        let initialRowFrame = trackedRow.frame
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let start = origin.withOffset(CGVector(dx: bounds.midX, dy: top + (bottom - top) * 0.8))
        let end = origin.withOffset(CGVector(dx: bounds.midX, dy: top + (bottom - top) * 0.2))
        for _ in 0..<3 {
            start.press(forDuration: 0.05, thenDragTo: end)
            XCTAssertTrue(confirm.isHittable)
            XCTAssertTrue(window.contains(confirm.frame))
            XCTAssertEqual(confirm.frame.minY, fixedFrame.minY, accuracy: 2)
            XCTAssertEqual(confirm.frame.maxY, fixedFrame.maxY, accuracy: 2)
        }
        XCTAssertTrue(!trackedRow.exists || !trackedRow.isHittable || abs(trackedRow.frame.minY - initialRowFrame.minY) > 24,
                      "The selected-list content must move independently of the confirmation action")
        _ = UITestInteraction.tapToolbar(app.buttons["bulkDeletion.cancel"], in: app)
        XCTAssertTrue(app.navigationBars["My Lists"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["savedLists.count"].label, "63", "Cancelling must retain every selected list")
        XCTAssertEqual(delete.label, "Delete Selected (63)")
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication,
                        file: StaticString = #filePath, line: UInt = #line) {
        _ = UITestInteraction.reveal(element, in: app, file: file, line: line)
    }
}
