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
        assertReportedValue("12", title: "TCGplayer reported units", element: tcg)
        assertReportedValue("0", title: "Manapool reported units", element: manapool)
        windows.buttons["365 days"].tap()
        assertReportedValue("120", title: "TCGplayer reported units", element: tcg)
        assertReportedValue("Unavailable", title: "Manapool reported units", element: manapool)
        windows.buttons["90 days"].tap()
        assertReportedValue("30", title: "TCGplayer reported units", element: tcg)
        assertReportedValue("7", title: "Manapool reported units", element: manapool)
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
        assertReportedValue("3", title: "Reported days in this period", element: days)
        windows.buttons["30d"].tap()
        assertReportedValue("2", title: "Reported days in this period", element: days)
        windows.buttons["All"].tap()
        assertReportedValue("4", title: "Reported days in this period", element: days)
        reveal(app.descendants(matching: .any)["research.historyChart"], in: app)
        reveal(app.descendants(matching: .any)["research.salesHistoryChart"], in: app)
        XCTAssertFalse(app.alerts.firstMatch.exists)
    }

    // LabeledContent can expose its value as an independent text element or
    // combine it with its title. Both representations must retain the exact
    // expected value; substring matches would confuse 12 with 120 or 0.
    private func assertReportedValue(_ expected: String, title: String, element: XCUIElement,
                                     file: StaticString = #filePath, line: UInt = #line) {
        let actual = element.label
        XCTAssertTrue([expected, title + ", " + expected].contains(actual),
                      "Expected \(title): \(expected); got \(actual)", file: file, line: line)
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
