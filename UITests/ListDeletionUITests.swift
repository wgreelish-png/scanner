import XCTest

/// Exercises real swipe/sheet presentation and persistence through normal app UI.
@MainActor final class ListDeletionUITests: XCTestCase {
    func testSwipeCancelAndConfirmDeletionPersistAcrossRelaunch() async throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        // The CI simulator's existing WebKit Swift-library workaround must reach
        // the separately launched app as well as this UI test runner.
        if let path = ProcessInfo.processInfo.environment["DYLD_FALLBACK_LIBRARY_PATH"] {
            app.launchEnvironment["DYLD_FALLBACK_LIBRARY_PATH"] = path
        }
        let suffix = String(UUID().uuidString.prefix(8))
        let deletedName = "UITest Delete \(suffix)", keptName = "UITest Keep \(suffix)"
        app.launch()
        defer { app.terminate() }
        openLists(in: app)
        createList(keptName, in: app)
        createList(deletedName, in: app)

        // A partial swipe may reveal Delete or trigger the permitted full swipe.
        // In either case, confirmation must appear before any row is removed.
        requestDeletion(of: deletedName, in: app, fullSwipe: false)
        XCTAssertTrue(app.navigationBars["Delete List?"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts[deletedName].exists)
        app.buttons["listDeletion.cancel"].tap()
        XCTAssertTrue(waitForAbsence(app.buttons["listDeletion.cancel"]))
        XCTAssertTrue(row(deletedName, in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(row(keptName, in: app).exists)

        // Cancellation must preserve the actual store, not only a displayed row.
        app.terminate(); app.launch(); openLists(in: app)
        XCTAssertTrue(row(deletedName, in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(row(keptName, in: app).exists)

        // A full swipe still requests confirmation; only its Delete button saves.
        requestDeletion(of: deletedName, in: app, fullSwipe: true)
        let confirm = app.buttons["listDeletion.confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(waitForAbsence(confirm))
        XCTAssertTrue(waitForAbsence(row(deletedName, in: app)))
        XCTAssertTrue(row(keptName, in: app).exists)

        app.terminate(); app.launch(); openLists(in: app)
        XCTAssertTrue(row(keptName, in: app).waitForExistence(timeout: 5))
        XCTAssertFalse(row(deletedName, in: app).exists)
    }

    private func openLists(in app: XCUIApplication) {
        let open = app.tabBars.buttons["Lists"]
        XCTAssertTrue(open.waitForExistence(timeout: 10)); open.tap()
        XCTAssertTrue(app.navigationBars["My Lists"].waitForExistence(timeout: 5))
    }
    private func createList(_ name: String, in app: XCUIApplication) {
        app.buttons["savedLists.newList"].tap()
        let input = app.textFields["savedLists.newName"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap(); input.typeText(name + "\n")
        app.buttons["savedLists.create"].tap()
        XCTAssertTrue(row(name, in: app).waitForExistence(timeout: 5))
    }
    private func row(_ name: String, in app: XCUIApplication) -> XCUIElement {
        app.cells.containing(.staticText, identifier: name).firstMatch
    }
    private func requestDeletion(of name: String, in app: XCUIApplication, fullSwipe: Bool) {
        let cell = row(name, in: app)
        XCTAssertTrue(cell.waitForExistence(timeout: 5))
        if fullSwipe {
            cell.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5))
                .press(forDuration: 0.05, thenDragTo: cell.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.5)))
        } else { cell.swipeLeft() }
        let cancel = app.buttons["listDeletion.cancel"]
        if !cancel.waitForExistence(timeout: 1) {
            let delete = app.buttons["savedList.requestDelete"].firstMatch
            XCTAssertTrue(delete.waitForExistence(timeout: 3)); delete.tap()
        }
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
    }
    private func waitForAbsence(_ element: XCUIElement) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        return XCTWaiter.wait(for: [expectation], timeout: 5) == .completed
    }
}
