import XCTest

@MainActor final class PhotoScanUITests: XCTestCase {
    func testPhotoCaptureRequiresRetakeAndRemembersMode() {
        continueAfterFailure = false
        let app = XCUIApplication()
        if let path = ProcessInfo.processInfo.environment["DYLD_FALLBACK_LIBRARY_PATH"] {
            app.launchEnvironment["DYLD_FALLBACK_LIBRARY_PATH"] = path
        }
        let args = ["-autoDatabaseUpdates", "NO", "-betaAutomaticIPAllowlist", "NO",
                    "--uitest-photo-scan", "--photo-fixture-id=" + UUID().uuidString]
        app.launchArguments = args + ["--photo-fixture-reset"]
        app.launch(); defer { app.terminate() }
        let picker = app.segmentedControls["photoScan.modePicker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 10))
        XCTAssertTrue(picker.buttons["Live Scan"].isSelected)
        UITestInteraction.tap(picker.buttons["Photo Scan"], in: app)
        let capture = app.buttons["photoScan.capture"]
        XCTAssertTrue(capture.waitForExistence(timeout: 5)); XCTAssertTrue(capture.isEnabled)
        UITestInteraction.tap(capture, in: app)
        let retake = app.buttons["photoScan.retake"]
        XCTAssertTrue(retake.waitForExistence(timeout: 5))
        XCTAssertFalse(capture.exists, "Another capture requires explicitly reopening the camera")
        XCTAssertTrue(app.staticTexts["Photo scanned · Camera is off"].exists)
        UITestInteraction.tap(retake, in: app)
        XCTAssertTrue(capture.waitForExistence(timeout: 5)); XCTAssertTrue(capture.isEnabled)
        app.terminate(); app.launchArguments = args; app.launch()
        XCTAssertTrue(picker.waitForExistence(timeout: 10))
        XCTAssertTrue(picker.buttons["Photo Scan"].isSelected, "Photo mode preference survives reopening")
    }
}
