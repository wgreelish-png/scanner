import XCTest

@MainActor final class MarketEvidenceUITests: XCTestCase {
    func testMarketEvidenceKeepsReportedZeroDistinctFromMissingAcrossWindows() async throws {
        continueAfterFailure = false
        let app = launchEvidence("--uitest-market-evidence")
        defer { app.terminate() }
        XCTAssertTrue(app.navigationBars["Market Details"].waitForExistence(timeout: 10))
        revealChart(app.descendants(matching: .any)["marketEvidence.priceChart"], in: app)
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
        revealChart(app.descendants(matching: .any)["marketEvidence.volumeChart"], in: app)
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
        let sales = app.staticTexts["research.evidenceSales"]
        reveal(sales, in: app)
        assertReportedValue("5", title: "Sales in returned days", element: sales)
        windows.buttons["30d"].tap()
        assertReportedValue("2", title: "Reported days in this period", element: days)
        assertReportedValue("2", title: "Sales in returned days", element: sales)
        windows.buttons["All"].tap()
        assertReportedValue("4", title: "Reported days in this period", element: days)
        assertReportedValue("6", title: "Sales in returned days", element: sales)
        revealChart(app.descendants(matching: .any)["research.historyChart"], in: app)
        revealChart(app.descendants(matching: .any)["research.salesHistoryChart"], in: app)
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
            scrollAlongEdge(in: app)
        }
        XCTAssertTrue(element.waitForExistence(timeout: 5))
        XCTAssertTrue(element.isHittable)
    }

    private func revealChart(_ element: XCUIElement, in app: XCUIApplication,
                             file: StaticString = #filePath, line: UInt = #line) {
        for _ in 0..<12 {
            if chartIsVisible(element, in: app) { return }
            scrollAlongEdge(in: app)
        }
        XCTAssertTrue(element.exists, "The chart must exist", file: file, line: line)
        XCTAssertTrue(chartIsVisible(element, in: app),
                      "The chart must occupy the visible content area; chart: \(element.frame), window: \(app.windows.firstMatch.frame)",
                      file: file, line: line)
    }

    private func chartIsVisible(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        guard element.exists else { return false }
        let bounds = element.frame
        let viewport = app.windows.firstMatch.frame.insetBy(dx: 0, dy: 100)
        let visible = bounds.intersection(viewport)
        return bounds.width > 0 && bounds.height > 0 && !visible.isNull &&
            visible.width >= min(120, bounds.width) && visible.height >= min(80, bounds.height)
    }

    private func scrollAlongEdge(in app: XCUIApplication) {
        // The chart's selection gesture can consume a swipe that begins in its
        // plot. Drag in the List's trailing margin rather than through the plot.
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.80))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.27))
        start.press(forDuration: 0.05, thenDragTo: end)
    }

}
