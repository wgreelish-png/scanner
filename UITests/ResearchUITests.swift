import XCTest

@MainActor final class ResearchUITests: XCTestCase {
    func testResearchConnectionRejectsInvalidSettingsWithoutNetwork() async throws {
        continueAfterFailure = false
        let app = launch()
        defer { app.terminate() }
        app.buttons["home.settings"].tap()
        let connection = app.buttons["settings.researchConnection"]
        for _ in 0..<4 {
            if connection.exists && connection.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(connection.waitForExistence(timeout: 5)); connection.tap()
        XCTAssertTrue(app.navigationBars["Research Connection"].waitForExistence(timeout: 5))
        let address = app.textFields["researchConnection.address"]
        XCTAssertTrue(address.waitForExistence(timeout: 5)); address.tap(); address.typeText("http://invalid.example.com\n")
        app.buttons["researchConnection.save"].tap()
        let status = app.staticTexts["researchConnection.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertTrue(status.label.contains("HTTPS"))
    }

    func testPSAResearchHasTypedCertificateAndCatalogFallbackWithoutCamera() async throws {
        continueAfterFailure = false
        let app = launch()
        defer { app.terminate() }
        let research = app.buttons["home.psaResearch"]
        for _ in 0..<4 {
            if research.exists && research.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(research.waitForExistence(timeout: 5)); research.tap()
        XCTAssertTrue(app.navigationBars["Research a PSA Slab"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["psa.scan"].exists)
        XCTAssertTrue(app.textFields["psa.certificate"].exists)
        XCTAssertTrue(app.textFields["psa.catalogSearch"].exists)
        XCTAssertFalse(app.alerts.firstMatch.exists)
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        if let path = ProcessInfo.processInfo.environment["DYLD_FALLBACK_LIBRARY_PATH"] {
            app.launchEnvironment["DYLD_FALLBACK_LIBRARY_PATH"] = path
        }
        app.launchArguments = ["-autoDatabaseUpdates", "NO"]
        app.launch(); XCTAssertTrue(app.buttons["home.openExistingLists"].waitForExistence(timeout: 10))
        return app
    }
}
