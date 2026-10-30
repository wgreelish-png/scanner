import XCTest

/// The source choice is made through Settings and survives a real app restart.
@MainActor final class PricingSourceUITests: XCTestCase {
    func testSettingsSourceChoicePersistsInBothDirectionsAcrossRelaunch() async throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        if let path = ProcessInfo.processInfo.environment["DYLD_FALLBACK_LIBRARY_PATH"] {
            app.launchEnvironment["DYLD_FALLBACK_LIBRARY_PATH"] = path
        }
        // Keep this Settings-only case independent of background database access.
        // The source itself must use the saved preference, never a launch default.
        app.launchArguments = ["-autoDatabaseUpdates", "NO"]
        app.launch()
        defer { app.terminate() }

        openSettings(in: app)
        chooseSource("Existing TCGTracking", in: app)
        chooseSource("Open API", in: app)
        app.terminate()
        app.launch()
        openSettings(in: app)
        assertSelectedSource("Open API", in: app)

        // Restore the existing source through the same UI so later scanner
        // cases inherit their normal source, then verify that write too.
        chooseSource("Existing TCGTracking", in: app)
        app.terminate()
        app.launch()
        openSettings(in: app)
        assertSelectedSource("Existing TCGTracking", in: app)
    }

    private func openSettings(in app: XCUIApplication) {
        let settings = app.tabBars.buttons["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        let picker = sourcePicker(in: app)
        for _ in 0..<6 {
            if picker.exists && picker.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(picker.waitForExistence(timeout: 5), "Settings must expose the price source chooser")
        XCTAssertTrue(picker.isHittable, "The source chooser must be reachable in Settings")
    }

    private func chooseSource(_ title: String, in app: XCUIApplication) {
        sourcePicker(in: app).tap()
        let choice = app.descendants(matching: .any).matching(identifier: title).firstMatch
        XCTAssertTrue(choice.waitForExistence(timeout: 5), "Missing price source choice: \(title)")
        choice.tap()
        assertSelectedSource(title, in: app)
    }

    private func sourcePicker(in app: XCUIApplication) -> XCUIElement {
        app.buttons["settings.pricingSource"]
    }

    private func assertSelectedSource(_ title: String, in app: XCUIApplication) {
        let selected = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", title), object: sourcePicker(in: app))
        XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 5), .completed,
                       "Settings must retain the selected price source: \(title)")
    }
}
