import XCTest

@MainActor final class MarketEvidenceUITests: XCTestCase {
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

}
