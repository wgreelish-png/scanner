import XCTest

@MainActor final class ScannerDownloadPreviewUITests: XCTestCase {
    func testSizeReviewKeepsStorageAndTransferSeparateWithPinnedActions() {
        continueAfterFailure = false
        let app = launch()
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["downloadPreview.title"].waitForExistence(timeout: 10))
        assertSummary("downloadPreview.downloadBytes", contains: "12 MB", in: app)
        assertSummary("downloadPreview.additionalStorage", contains: "At least 10 MB", in: app)
        assertSummary("downloadPreview.cachedBytes", contains: "8 MB", in: app)
        assertSummary("downloadPreview.freeStorage", contains: "4 GB", in: app)
        let explanation = app.staticTexts["downloadPreview.storageExplanation"]
        XCTAssertTrue(UITestInteraction.reveal(explanation, in: app))
        XCTAssertTrue(explanation.label.contains("full size is not published"))
        let scope = app.staticTexts["downloadPreview.scope"]
        XCTAssertTrue(UITestInteraction.reveal(scope, in: app))
        XCTAssertTrue(scope.label.contains("artwork, market prices and research"))
        let approve = app.buttons["downloadPreview.continue"]
        let cancel = app.buttons["downloadPreview.cancel"]
        XCTAssertTrue(approve.isHittable, "Download remains reachable after scrolling the size details")
        XCTAssertTrue(cancel.isHittable, "Cancel remains reachable after scrolling the size details")
        XCTAssertFalse(app.staticTexts["downloadPreview.fixtureOutcome"].exists,
                       "Reading the size review does not authorize a download")
        UITestInteraction.tap(cancel, in: app)
        let outcome = app.staticTexts["downloadPreview.fixtureOutcome"]
        XCTAssertTrue(outcome.waitForExistence(timeout: 5))
        XCTAssertEqual(outcome.label, "Download cancelled")
    }

    func testUnknownSizeRequiresExplicitContinuation() {
        continueAfterFailure = false
        let app = launch(unavailable: true)
        defer { app.terminate() }
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "downloadPreview.unavailable").firstMatch
            .waitForExistence(timeout: 10))
        let approve = app.buttons["downloadPreview.continue"]
        XCTAssertEqual(approve.label, "Continue Without Estimate")
        XCTAssertFalse(app.staticTexts["downloadPreview.fixtureOutcome"].exists)
        UITestInteraction.tap(approve, in: app)
        let outcome = app.staticTexts["downloadPreview.fixtureOutcome"]
        XCTAssertTrue(outcome.waitForExistence(timeout: 5))
        XCTAssertEqual(outcome.label, "Download approved")
    }

    private func launch(unavailable: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        if let path = ProcessInfo.processInfo.environment["DYLD_FALLBACK_LIBRARY_PATH"] {
            app.launchEnvironment["DYLD_FALLBACK_LIBRARY_PATH"] = path
        }
        app.launchArguments = ["-autoDatabaseUpdates", "NO", "-betaAutomaticIPAllowlist", "NO", "--uitest-download-preview"]
        if unavailable { app.launchArguments.append("--uitest-download-preview-unavailable") }
        app.launch()
        return app
    }

    private func assertSummary(_ identifier: String, contains value: String, in app: XCUIApplication,
                               file: StaticString = #filePath, line: UInt = #line) {
        let element = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
        XCTAssertTrue(UITestInteraction.reveal(element, in: app), file: file, line: line)
        let combined = ([element.label] + element.staticTexts.allElementsBoundByIndex.map(\.label)).joined(separator: " ")
        XCTAssertTrue(combined.contains(value), "Expected \(value) in \(identifier), got \(combined)", file: file, line: line)
    }
}
