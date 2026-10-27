import XCTest

/// Follows the normal testing menu; no camera, account or network result is required.
@MainActor final class ScanConfirmationUITests: XCTestCase {
    func testVisibleDropdownsEditBeforeConfirmationAndSavedListCanExport() async throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        if let path = ProcessInfo.processInfo.environment["DYLD_FALLBACK_LIBRARY_PATH"] {
            app.launchEnvironment["DYLD_FALLBACK_LIBRARY_PATH"] = path
        }
        // Launch-domain defaults acknowledge the optional connection step only.
        // Mock recognition is still selected explicitly through the normal UI.
        app.launchArguments = ["-tcgTrackingConnectionIntroduced", "YES", "-defaultGame", "Pokémon"]
        addUIInterruptionMonitor(withDescription: "Camera permission") { alert in
            for title in ["Allow", "OK", "Allow While Using App"] where alert.buttons[title].exists {
                alert.buttons[title].tap(); return true
            }
            return false
        }
        app.launch()
        defer { app.terminate() }

        let start = app.buttons["home.startNewScan"]
        XCTAssertTrue(start.waitForExistence(timeout: 10)); start.tap()
        let options = app.buttons["scanner.options"]
        XCTAssertTrue(options.waitForExistence(timeout: 10)); options.tap()
        tapMenuItem("Developer Testing", in: app)
        let mock = menuItem("Mock — sample cards", in: app)
        if !mock.waitForExistence(timeout: 2) { tapMenuItem("Scanner source", in: app) }
        tapMenuItem("Mock — sample cards", in: app)

        let confirmation = app.navigationBars["Choose the Card"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 10))
        let firstProduct = "mock:Pokémon:0"
        let condition = app.buttons["scanReview.condition"]
        let printing = app.buttons["scanReview.printing." + firstProduct]
        XCTAssertTrue(condition.waitForExistence(timeout: 5)); XCTAssertTrue(condition.isHittable)
        XCTAssertTrue(printing.waitForExistence(timeout: 5)); XCTAssertTrue(printing.isHittable)
        XCTAssertEqual(condition.value as? String, "Near Mint")
        XCTAssertEqual(printing.value as? String, "Normal")

        condition.tap(); tapMenuItem("Lightly Played", in: app)
        XCTAssertTrue(waitForValue("Lightly Played", of: condition))
        XCTAssertTrue(confirmation.exists, "Changing condition must not confirm the card")
        printing.tap(); tapMenuItem("Holofoil", in: app)
        XCTAssertTrue(waitForValue("Holofoil", of: printing))
        XCTAssertTrue(waitForValue("Lightly Played", of: condition))
        XCTAssertTrue(confirmation.exists, "Changing printing must not confirm the card")
        XCTAssertFalse(app.buttons["scanner.scanNext"].exists)

        let add = app.buttons["scanReview.add." + firstProduct]
        XCTAssertTrue(add.waitForExistence(timeout: 5)); add.tap()
        XCTAssertTrue(app.buttons["scanner.scanNext"].waitForExistence(timeout: 10),
            "Explicit confirmation must return to scanning")
        let viewList = app.buttons["scanner.viewList"]
        XCTAssertTrue(viewList.waitForExistence(timeout: 5)); viewList.tap()
        XCTAssertTrue(app.navigationBars["Review & Offer"].waitForExistence(timeout: 5))
        let export = app.buttons["list.exportCSV"], share = app.buttons["list.shareCSV"]
        XCTAssertTrue(export.waitForExistence(timeout: 5)); XCTAssertTrue(export.isHittable); XCTAssertTrue(export.isEnabled)
        XCTAssertTrue(share.waitForExistence(timeout: 5)); XCTAssertTrue(share.isHittable); XCTAssertTrue(share.isEnabled)
    }

    private func menuItem(_ title: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: title).firstMatch
    }
    private func tapMenuItem(_ title: String, in app: XCUIApplication) {
        let item = menuItem(title, in: app)
        XCTAssertTrue(item.waitForExistence(timeout: 5), "Missing menu item: \(title)")
        item.tap()
    }
    private func waitForValue(_ expected: String, of element: XCUIElement) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", expected), object: element)
        return XCTWaiter.wait(for: [expectation], timeout: 5) == .completed
    }
}
