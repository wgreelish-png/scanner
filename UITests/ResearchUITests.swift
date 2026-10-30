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
        app.buttons["home.settings"].tap()
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
        app.buttons["home.settings"].tap()
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

    func testMarketEvidenceKeepsReportedZeroDistinctFromMissingAcrossWindows() async throws {
        continueAfterFailure = false
        let app = launchEvidence("--uitest-market-evidence")
        defer { app.terminate() }
        XCTAssertTrue(app.navigationBars["Market Details"].waitForExistence(timeout: 10))
        reveal(app.descendants(matching: .any)["marketEvidence.priceChart"], in: app)
        let windows = app.segmentedControls["marketEvidence.volumeWindow"]
        reveal(windows, in: app)
        let tcg = app.staticTexts["marketEvidence.tcgQuantity"]
        let manapool = app.staticTexts["marketEvidence.mpQuantity"]
        reveal(manapool, in: app)
        XCTAssertEqual(tcg.label, "12")
        XCTAssertEqual(manapool.label, "0", "A returned zero must remain a known zero")
        windows.buttons["365 days"].tap()
        XCTAssertEqual(tcg.label, "120")
        XCTAssertEqual(manapool.label, "Unavailable", "An absent quantity must never become zero")
        windows.buttons["90 days"].tap()
        XCTAssertEqual(tcg.label, "30")
        XCTAssertEqual(manapool.label, "7")
        XCTAssertTrue(app.descendants(matching: .any)["marketEvidence.volumeChart"].exists)
    }

    func testResearchEvidenceUsesCalendarPeriodsAndShowsSeparatePriceAndCountCharts() async throws {
        continueAfterFailure = false
        let app = launchEvidence("--uitest-research-evidence")
        defer { app.terminate() }
        XCTAssertTrue(app.navigationBars["Research & Demand"].waitForExistence(timeout: 10))
        let windows = app.segmentedControls["research.historyPeriod"]
        reveal(windows, in: app)
        let days = app.staticTexts["research.evidenceDays"]
        reveal(days, in: app)
        XCTAssertEqual(days.label, "3", "90 days must select calendar days, not the last 90 rows")
        windows.buttons["30d"].tap()
        XCTAssertEqual(days.label, "2")
        windows.buttons["All"].tap()
        XCTAssertEqual(days.label, "4")
        reveal(app.descendants(matching: .any)["research.historyChart"], in: app)
        reveal(app.descendants(matching: .any)["research.salesHistoryChart"], in: app)
        XCTAssertFalse(app.alerts.firstMatch.exists)
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        if let path = ProcessInfo.processInfo.environment["DYLD_FALLBACK_LIBRARY_PATH"] {
            app.launchEnvironment["DYLD_FALLBACK_LIBRARY_PATH"] = path
        }
        app.launchArguments = ["-autoDatabaseUpdates", "NO", "-researchAccessMethod", "direct"]
        app.launch(); XCTAssertTrue(app.buttons["home.openExistingLists"].waitForExistence(timeout: 10))
        return app
    }

    private func launchEvidence(_ argument: String) -> XCUIApplication {
        let app = XCUIApplication()
        if let path = ProcessInfo.processInfo.environment["DYLD_FALLBACK_LIBRARY_PATH"] {
            app.launchEnvironment["DYLD_FALLBACK_LIBRARY_PATH"] = path
        }
        app.launchArguments = ["-autoDatabaseUpdates", "NO", argument]
        app.launch()
        return app
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<12 {
            if element.exists && element.isHittable { return }
            app.swipeUp()
        }
        XCTAssertTrue(element.waitForExistence(timeout: 5))
        XCTAssertTrue(element.isHittable)
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
