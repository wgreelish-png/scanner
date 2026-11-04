import XCTest

@MainActor final class ResearchUITests: XCTestCase {
    func testResearchConnectionRejectsInvalidSettingsWithoutNetwork() async throws {
        continueAfterFailure = false
        let app = launch()
        defer { app.terminate() }
        _ = UITestInteraction.tapToolbar(app.tabBars.buttons["Settings"], in: app)
        let connection = app.buttons["settings.researchConnection"]
        tapVisible(connection, in: app)
        XCTAssertTrue(app.navigationBars["TCGTracking API Connection"].waitForExistence(timeout: 5))
        tapVisible(app.buttons["researchConnection.method"], in: app)
        tapVisible(app.buttons["My Server"], in: app)
        let address = app.textFields["researchConnection.address"]
        replaceText("http://invalid.example.com", in: address, app: app)
        let done = app.buttons["researchConnection.keyboardDone"]
        _ = UITestInteraction.tapToolbar(done, in: app)
        tapVisible(app.buttons["researchConnection.save"], in: app)
        let status = app.staticTexts["researchConnection.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertTrue(status.label.contains("HTTPS"))
    }

    func testDirectResearchFieldsAreAvailableAndEmptyCredentialsAreRejected() async throws {
        continueAfterFailure = false
        let app = launch()
        defer { app.terminate() }
        _ = UITestInteraction.tapToolbar(app.tabBars.buttons["Settings"], in: app)
        tapVisible(app.buttons["settings.researchConnection"], in: app)
        XCTAssertTrue(app.textFields["researchConnection.shipperID"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.secureTextFields["researchConnection.apiKey"].exists)
        replaceText("", in: app.textFields["researchConnection.shipperID"], app: app)
        replaceText("", in: app.secureTextFields["researchConnection.apiKey"], app: app)
        _ = UITestInteraction.tapToolbar(app.buttons["researchConnection.keyboardDone"], in: app)
        tapVisible(app.buttons["researchConnection.save"], in: app)
        let status = app.staticTexts["researchConnection.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertTrue(status.label.contains("shipper ID"))
    }

    func testMarketActivityTestRejectsEmptyCredentialsWithoutNetwork() async throws {
        continueAfterFailure = false
        let app = launch()
        defer { app.terminate() }
        _ = UITestInteraction.tapToolbar(app.tabBars.buttons["Settings"], in: app)
        tapVisible(app.buttons["settings.researchConnection"], in: app)
        XCTAssertTrue(app.navigationBars["TCGTracking API Connection"].waitForExistence(timeout: 5))
        let shipper = app.textFields["researchConnection.shipperID"]
        XCTAssertTrue(shipper.waitForExistence(timeout: 5))
        replaceText("", in: shipper, app: app)
        let apiKey = app.secureTextFields["researchConnection.apiKey"]
        replaceText("", in: apiKey, app: app)
        _ = UITestInteraction.tapToolbar(app.buttons["researchConnection.keyboardDone"], in: app)
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
        _ = UITestInteraction.tapToolbar(app.tabBars.buttons["Research"], in: app)
        let research = app.buttons["home.psaResearch"]
        tapVisible(research, in: app)
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
        app.launchArguments = ["-autoDatabaseUpdates", "NO", "-betaAutomaticIPAllowlist", "NO", "-researchAccessMethod", "direct"]
        app.launch(); XCTAssertTrue(app.tabBars.buttons["Scan"].waitForExistence(timeout: 10))
        return app
    }

    private func replaceText(_ value: String, in field: XCUIElement, app: XCUIApplication,
                             file: StaticString = #filePath, line: UInt = #line) {
        guard UITestInteraction.tap(field, in: app, file: file, line: line) else { return }
        if let previous = field.value as? String, previous != field.placeholderValue, !previous.isEmpty {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: previous.count))
        }
        if !value.isEmpty { field.typeText(value) }
    }

    private func tapVisible(_ element: XCUIElement, in app: XCUIApplication,
                            file: StaticString = #filePath, line: UInt = #line) {
        _ = UITestInteraction.tap(element, in: app, file: file, line: line)
    }
}
