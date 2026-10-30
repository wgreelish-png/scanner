import XCTest

@MainActor final class ResearchUITests: XCTestCase {
    func testResearchConnectionRejectsInvalidSettingsWithoutNetwork() async throws {
        continueAfterFailure = false
        let app = launch()
        defer { app.terminate() }
        app.tabBars.buttons["Settings"].tap()
        let connection = app.buttons["settings.researchConnection"]
        for _ in 0..<4 {
            if connection.exists && connection.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(connection.waitForExistence(timeout: 5)); connection.tap()
        XCTAssertTrue(app.navigationBars["TCGTracking API Connection"].waitForExistence(timeout: 5))
        app.buttons["researchConnection.method"].tap()
        app.buttons["My Server"].tap()
        let address = app.textFields["researchConnection.address"]
        XCTAssertTrue(address.waitForExistence(timeout: 5)); address.tap(); address.typeText("http://invalid.example.com")
        let done = app.buttons["researchConnection.keyboardDone"]
        XCTAssertTrue(done.waitForExistence(timeout: 5)); done.tap()
        tapVisible(app.buttons["researchConnection.save"], in: app)
        let status = app.staticTexts["researchConnection.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertTrue(status.label.contains("HTTPS"))
    }

    func testDirectResearchFieldsAreAvailableAndEmptyCredentialsAreRejected() async throws {
        continueAfterFailure = false
        let app = launch()
        defer { app.terminate() }
        app.tabBars.buttons["Settings"].tap()
        tapVisible(app.buttons["settings.researchConnection"], in: app)
        XCTAssertTrue(app.textFields["researchConnection.shipperID"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.secureTextFields["researchConnection.apiKey"].exists)
        tapVisible(app.buttons["researchConnection.save"], in: app)
        let status = app.staticTexts["researchConnection.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertTrue(status.label.contains("shipper ID"))
    }

    func testMarketActivityTestRejectsEmptyCredentialsWithoutNetwork() async throws {
        continueAfterFailure = false
        let app = launch()
        defer { app.terminate() }
        app.tabBars.buttons["Settings"].tap()
        tapVisible(app.buttons["settings.researchConnection"], in: app)
        XCTAssertTrue(app.navigationBars["TCGTracking API Connection"].waitForExistence(timeout: 5))
        let shipper = app.textFields["researchConnection.shipperID"]
        XCTAssertTrue(shipper.waitForExistence(timeout: 5))
        shipper.tap()
        shipper.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: max(1, (shipper.value as? String)?.count ?? 0)))
        let apiKey = app.secureTextFields["researchConnection.apiKey"]
        apiKey.tap()
        apiKey.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: max(1, (apiKey.value as? String)?.count ?? 0)))
        app.buttons["researchConnection.keyboardDone"].tap()
        tapVisible(app.buttons["researchConnection.testMarketActivity"], in: app)
        let status = app.staticTexts["researchConnection.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertTrue(status.label.contains("shipper ID"))
        XCTAssertTrue(app.buttons["researchConnection.save"].isEnabled)
        XCTAssertTrue(app.buttons["researchConnection.test"].exists)
    }

    func testPSAResearchHasTypedCertificateAndCatalogFallbackWithoutCamera() async throws {
        continueAfterFailure = false
        let app = launch()
        defer { app.terminate() }
        app.tabBars.buttons["Research"].tap()
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
        app.launchArguments = ["-autoDatabaseUpdates", "NO", "-researchAccessMethod", "direct"]
        app.launch(); XCTAssertTrue(app.tabBars.buttons["Scan"].waitForExistence(timeout: 10))
        return app
    }

    private func tapVisible(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<5 {
            if element.exists && element.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(element.waitForExistence(timeout: 5))
        XCTAssertTrue(element.isHittable)
        element.tap()
    }
}
