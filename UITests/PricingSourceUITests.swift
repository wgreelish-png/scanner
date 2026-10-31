import XCTest

/// A previously saved provider choice cannot restore the retired selector.
@MainActor final class PricingSourceUITests: XCTestCase {
    func testOpenAPIRemainsTheReadOnlyProviderWithLegacyDefaultsAcrossRelaunch() async throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        if let path = ProcessInfo.processInfo.environment["DYLD_FALLBACK_LIBRARY_PATH"] {
            app.launchEnvironment["DYLD_FALLBACK_LIBRARY_PATH"] = path
        }
        app.launchArguments = ["-autoDatabaseUpdates", "NO", "-marketPricingSource", "tcgtracking"]
        app.launch()
        defer { app.terminate() }
        assertStandardPricing(in: app)
        app.terminate(); app.launch()
        assertStandardPricing(in: app)
    }

    private func assertStandardPricing(in app: XCUIApplication) {
        let settings = app.tabBars.buttons["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10)); settings.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        let info = app.descendants(matching: .any).matching(identifier: "settings.marketPricing").firstMatch
        XCTAssertTrue(info.waitForExistence(timeout: 5))
        XCTAssertTrue((info.label + " " + (info.value as? String ?? "")).contains("Open API"))
        XCTAssertFalse(app.buttons["settings.pricingSource"].exists)
        XCTAssertFalse(app.buttons["Price source"].exists)
        XCTAssertTrue(app.buttons["settings.websiteConnection"].exists, "The account sign-in remains available separately")
    }
}
