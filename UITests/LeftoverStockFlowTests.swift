import XCTest

@MainActor final class LeftoverStockFlowTests: XCTestCase {
    func testCompletedCountExportsOnlyPositiveAbsoluteStockWithoutChangingInventory() {
        continueAfterFailure = false
        let app = XCUIApplication()
        if let path = ProcessInfo.processInfo.environment["DYLD_FALLBACK_LIBRARY_PATH"] {
            app.launchEnvironment["DYLD_FALLBACK_LIBRARY_PATH"] = path
        }
        app.launchArguments = ["-autoDatabaseUpdates", "NO", "-betaAutomaticIPAllowlist", "NO", "--uitest-leftover-stock"]
        app.launch(); defer { app.terminate() }
        XCTAssertTrue(app.navigationBars["Leftover Stock"].waitForExistence(timeout: 10))
        let export = app.buttons["leftoverStock.exportReplacement"]
        XCTAssertFalse(export.exists && export.isEnabled, "Counting must be explicitly completed before export")
        let finish = app.buttons["leftoverStock.finish"]
        UITestInteraction.tap(finish, in: app, identifier: "leftoverStock.finish")
        let confirm = app.buttons["leftoverStock.confirmFinish"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        UITestInteraction.tap(confirm, in: app, identifier: "leftoverStock.confirmFinish")
        XCTAssertTrue(export.isEnabled)
        UITestInteraction.tap(app.buttons["leftoverFixture.verifyExport"], in: app, identifier: "leftoverFixture.verifyExport")
        XCTAssertTrue(app.staticTexts["2 export rows · 3 cards · Inventory unchanged"].waitForExistence(timeout: 5))
    }
}
