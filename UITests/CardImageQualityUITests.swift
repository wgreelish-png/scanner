import XCTest

/// Exercises the actual saved setting through relaunch without opening the
/// camera, touching an account or editing any inventory records.
@MainActor final class CardImageQualityUITests: XCTestCase {
    func testLowAndHighQualityPersistAcrossRelaunchWithoutChangingListsOrHaptics() async throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        if let path = ProcessInfo.processInfo.environment["DYLD_FALLBACK_LIBRARY_PATH"] {
            app.launchEnvironment["DYLD_FALLBACK_LIBRARY_PATH"] = path
        }
        // Do not override cardImageQuality here: doing so would hide whether
        // the choice was persisted in the application's defaults domain.
        app.launchArguments = ["-autoDatabaseUpdates", "NO", "-betaAutomaticIPAllowlist", "NO"]
        app.launch()
        defer { app.terminate() }

        selectTab("Lists", in: app)
        let listCount = app.staticTexts["savedLists.count"]
        XCTAssertTrue(listCount.waitForExistence(timeout: 5))
        let originalListCount = listCount.label

        let quality = openImageQuality(in: app)
        let originalChoice = quality.buttons["Low (200px)"].isSelected ? "Low (200px)" : "High (400px)"
        let originalHaptics = hapticsValue(in: app)
        choose("Low (200px)", in: quality, app: app)

        app.terminate()
        app.launch()
        let lowAfterRelaunch = openImageQuality(in: app)
        assertSelected("Low (200px)", in: lowAfterRelaunch)
        XCTAssertEqual(hapticsValue(in: app), originalHaptics)
        choose("High (400px)", in: lowAfterRelaunch, app: app)

        app.terminate()
        app.launch()
        let highAfterRelaunch = openImageQuality(in: app)
        assertSelected("High (400px)", in: highAfterRelaunch)
        XCTAssertEqual(hapticsValue(in: app), originalHaptics)

        // Restore this simulator's initial choice through the same user flow.
        choose(originalChoice, in: highAfterRelaunch, app: app)
        selectTab("Lists", in: app)
        XCTAssertTrue(listCount.waitForExistence(timeout: 5))
        XCTAssertEqual(listCount.label, originalListCount)
        XCTAssertFalse(app.buttons["scanner.options"].exists)
    }

    private func openImageQuality(in app: XCUIApplication) -> XCUIElement {
        selectTab("Settings", in: app)
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        let picker = app.segmentedControls["settings.cardImageQuality"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        _ = UITestInteraction.reveal(picker, in: app, identifier: "settings.cardImageQuality")
        return picker
    }

    private func choose(_ label: String, in picker: XCUIElement, app: XCUIApplication) {
        _ = UITestInteraction.tap(picker.buttons[label], in: app, identifier: "settings.cardImageQuality." + label)
        assertSelected(label, in: picker)
    }

    private func hapticsValue(in app: XCUIApplication) -> String? {
        let control = app.switches["settings.haptics"]
        _ = UITestInteraction.reveal(control, in: app, identifier: "settings.haptics")
        let value = control.value as? String
        XCTAssertNotNil(value, "The unchanged haptics preference must be readable")
        return value
    }

    private func assertSelected(_ label: String, in picker: XCUIElement,
                                file: StaticString = #filePath, line: UInt = #line) {
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "selected == true"), object: picker.buttons[label])
        XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 5), .completed,
                       "Image quality must remain selected after relaunch", file: file, line: line)
    }

    private func selectTab(_ title: String, in app: XCUIApplication) {
        let tab = app.tabBars.buttons[title]
        XCTAssertTrue(tab.waitForExistence(timeout: 10))
        _ = UITestInteraction.tapToolbar(tab, in: app, identifier: "tab." + title)
    }
}
