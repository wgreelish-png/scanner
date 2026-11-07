import XCTest

@MainActor final class MarketEvidenceUITests: XCTestCase {
    func testCombinedResearchRetainsSharedSelectionAndSwitchesModesWithoutCharts() async throws {
        continueAfterFailure = false
        let app = launchEvidence("--uitest-card-research")
        defer { app.terminate() }
        XCTAssertTrue(app.navigationBars["Card Research"].waitForExistence(timeout: 10))
        let modes = app.segmentedControls["cardResearch.section"]
        XCTAssertTrue(modes.waitForExistence(timeout: 5))
        assertCompactResearchLayout(in: app)
        let condition = app.buttons["cardResearch.condition.LP"]
        UITestInteraction.tap(condition, in: app, identifier: "cardResearch.condition.LP")
        let period = app.segmentedControls["marketDetails.period"]
        UITestInteraction.tap(period.buttons["90D"], in: app, identifier: "marketDetails.period.90D")
        UITestInteraction.tap(modes.buttons["Graded"], in: app, identifier: "cardResearch.section.Graded")
        let grade = app.buttons["research.grade"]
        reveal(grade, in: app)
        XCTAssertTrue(grade.exists)
        XCTAssertFalse(app.buttons["cardResearch.condition.LP"].exists)
        scrollToTop(in: app)
        XCTAssertEqual(app.staticTexts.matching(identifier: "cardResearch.name").count, 1)
        XCTAssertFalse(app.staticTexts["Evidence at a glance"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["research.historyChart"].exists)
        UITestInteraction.tap(modes.buttons["Market"], in: app, identifier: "cardResearch.section.Market")
        scrollToTop(in: app)
        reveal(condition, in: app)
        XCTAssertTrue(condition.isSelected)
        reveal(period, in: app)
        XCTAssertTrue(period.buttons["90D"].isSelected)
        XCTAssertFalse(app.descendants(matching: .any)["marketEvidence.priceChart"].exists)
        XCTAssertTrue(app.navigationBars["Card Research"].exists)
    }

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
        UITestInteraction.tap(windows.buttons["365 days"], in: app)
        assertReportedValue("120", title: "TCGplayer reported units", element: tcg)
        assertReportedValue("Unavailable", title: "Manapool reported units", element: manapool)
        UITestInteraction.tap(windows.buttons["90 days"], in: app)
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
        guard windows.waitForExistence(timeout: 5) else {
            XCTFail("Missing research.historyPeriod: the evidence fixture must expose its history picker")
            return
        }
        guard UITestInteraction.reveal(windows, in: app, identifier: "research.historyPeriod") else { return }
        let days = app.descendants(matching: .any).matching(identifier: "research.evidenceDays").firstMatch
        guard UITestInteraction.reveal(days, in: app, identifier: "research.evidenceDays"),
              assertReportedValue("3", title: "Reported days in this period", element: days) else { return }
        let sales = app.descendants(matching: .any).matching(identifier: "research.evidenceSales").firstMatch
        guard UITestInteraction.reveal(sales, in: app, identifier: "research.evidenceSales"),
              assertReportedValue("5", title: "Sales in returned days", element: sales) else { return }
        guard UITestInteraction.tap(windows.buttons["30d"], in: app, identifier: "research.historyPeriod.30d"),
              assertReportedValue("2", title: "Reported days in this period", element: days),
              assertReportedValue("2", title: "Sales in returned days", element: sales) else { return }
        guard UITestInteraction.tap(windows.buttons["All"], in: app, identifier: "research.historyPeriod.All"),
              assertReportedValue("4", title: "Reported days in this period", element: days),
              assertReportedValue("6", title: "Sales in returned days", element: sales) else { return }
        revealChart(app.descendants(matching: .any)["research.historyChart"], in: app)
        revealChart(app.descendants(matching: .any)["research.salesHistoryChart"], in: app)
        XCTAssertFalse(app.alerts.firstMatch.exists)
    }

    private func assertCompactResearchLayout(in app: XCUIApplication,
                                              file: StaticString = #filePath, line: UInt = #line) {
        let price = app.staticTexts["marketDetails.marketPrice"]
        XCTAssertTrue(price.waitForExistence(timeout: 5), file: file, line: line)
        XCTAssertEqual(app.staticTexts.matching(identifier: "marketDetails.marketPrice").count, 1,
                       "Show the quote once beside the thumbnail", file: file, line: line)
        let name = app.staticTexts["cardResearch.name"]
        let printing = app.buttons["cardResearch.printing.Holofoil"]
        let language = app.buttons["cardResearch.language.English"]
        let condition = app.buttons["cardResearch.condition.NM"]
        let tcgplayer = app.descendants(matching: .any).matching(identifier: "cardResearch.tcgplayer").firstMatch
        let listings = app.descendants(matching: .any).matching(identifier: "marketDetails.listingDetails").firstMatch
        let activity = app.staticTexts["marketDetails.activityHeader"]
        let ordered = [price, name, printing, language, condition, tcgplayer, listings, activity]
        for element in ordered {
            XCTAssertTrue(element.waitForExistence(timeout: 5), "Missing \(element.identifier)", file: file, line: line)
        }
        for index in 1..<ordered.count {
            XCTAssertGreaterThanOrEqual(ordered[index].frame.minY, ordered[index - 1].frame.maxY - 1,
                "Research controls must follow the displayed card order", file: file, line: line)
        }
        XCTAssertTrue(tcgplayer.isHittable, "The primary controls should fit without scrolling", file: file, line: line)
        let bottom = app.tabBars.firstMatch.exists ? app.tabBars.firstMatch.frame.minY : app.windows.firstMatch.frame.maxY
        XCTAssertLessThanOrEqual(activity.frame.maxY, bottom,
            "Market Activity should follow the collapsed details in the initial viewport", file: file, line: line)
        for unavailable in ["Japanese", "French", "German", "Italian", "Spanish", "Portuguese", "Russian", "Korean", "Simplified Chinese", "Traditional Chinese"] {
            XCTAssertFalse(app.buttons["cardResearch.language." + unavailable].exists,
                           "Do not offer an unpriced language", file: file, line: line)
        }
        let lowest = app.descendants(matching: .any).matching(identifier: "marketDetails.lowestListing").firstMatch
        XCTAssertFalse(lowest.exists, "Listing details start collapsed", file: file, line: line)
        UITestInteraction.tap(listings, in: app, identifier: "marketDetails.listingDetails", file: file, line: line)
        XCTAssertTrue(lowest.waitForExistence(timeout: 5), file: file, line: line)
        UITestInteraction.tap(listings, in: app, identifier: "marketDetails.listingDetails", file: file, line: line)
        let collapsed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: lowest)
        XCTAssertEqual(XCTWaiter.wait(for: [collapsed], timeout: 5), .completed, file: file, line: line)
        scrollToTop(in: app)
    }

    // LabeledContent can expose its value as an independent text element or
    // combine it with its title. Both representations must retain the exact
    // expected value; substring matches would confuse 12 with 120 or 0.
    @discardableResult
    private func assertReportedValue(_ expected: String, title: String, element: XCUIElement,
                                     file: StaticString = #filePath, line: UInt = #line) -> Bool {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@ OR label == %@", expected, title + ", " + expected), object: element)
        guard XCTWaiter.wait(for: [ready], timeout: 5) == .completed else {
            XCTFail("The reported value must settle after a window change: \(element.identifier)", file: file, line: line)
            return false
        }
        let actual = element.label
        let matches = [expected, title + ", " + expected].contains(actual)
        XCTAssertTrue(matches,
                      "Expected \(title): \(expected); got \(actual)", file: file, line: line)
        return matches
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

    private func scrollToTop(in app: XCUIApplication) {
        UITestInteraction.scrollToTop(in: app)
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication,
                        file: StaticString = #filePath, line: UInt = #line) {
        UITestInteraction.reveal(element, in: app, file: file, line: line)
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
        // Scroll only the visible List's margin so the chart does not consume
        // the gesture and an off-screen retained container is never selected.
        UITestInteraction.scrollContent(in: app, towardTop: false)
    }

}
