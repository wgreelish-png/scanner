import XCTest

/// Follows the normal testing menu; no camera, account or network result is required.
@MainActor final class ScanConfirmationUITests: XCTestCase {
    func testVisibleDropdownsEditBeforeConfirmationAndSavedListCanExport() async throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        if let path = ProcessInfo.processInfo.environment["DYLD_FALLBACK_LIBRARY_PATH"] {
            app.launchEnvironment["DYLD_FALLBACK_LIBRARY_PATH"] = path
        }
        // Launch-domain defaults acknowledge the optional connection step and
        // isolate the footer preference from earlier test runs.
        // Mock recognition is still selected explicitly through the normal UI.
        app.launchArguments = ["-tcgTrackingConnectionIntroduced", "YES", "-defaultGame", "Pokémon",
                               "-scannerDetailsCollapsed", "NO"]
        addUIInterruptionMonitor(withDescription: "Camera permission") { alert in
            let text = ([alert.label] + alert.staticTexts.allElementsBoundByIndex.map(\.label)).joined(separator: " ").lowercased()
            guard text.contains("camera") else { return false }
            for title in ["Allow", "OK", "Allow Access"] where alert.buttons[title].exists {
                alert.buttons[title].tap(); return true
            }
            return false
        }
        app.launch()
        defer { app.terminate() }

        let listsTab = app.tabBars.buttons["Lists"], scanTab = app.tabBars.buttons["Scan"]
        XCTAssertTrue(listsTab.waitForExistence(timeout: 10)); listsTab.tap()
        let savedCount = app.staticTexts["savedLists.count"]
        XCTAssertTrue(savedCount.waitForExistence(timeout: 5))
        let initialListCount = savedCount.label
        scanTab.tap()
        let hadActiveScan = app.buttons["home.continueScan"].exists
        let start = app.buttons["home.startNewScan"]
        XCTAssertTrue(start.waitForExistence(timeout: 10)); start.tap()
        acceptInitialCameraPermission()
        // Handle the actual first-use screen too if the launch acknowledgment
        // has not been reflected when this scanner is presented.
        let connectionReturn = app.buttons.matching(NSPredicate(format:
            "label == %@ OR label == %@", "Continue to Scanner", "Return to Scanner")).firstMatch
        if connectionReturn.waitForExistence(timeout: 3) {
            tapFixedControl(connectionReturn, in: app)
        }
        // Both ways of closing a zero-card scan must leave saved lists and the
        // prior continuation unchanged. Reopening must still permit a real Add.
        for closeID in ["scanner.close", "scanner.finishSession"] {
            let pendingList = app.buttons["scanner.viewList"]
            assertOverlayVisible(pendingList, in: app)
            XCTAssertFalse(pendingList.isEnabled, "An uncommitted scan has no saved list to review")
            tapFixedControl(app.buttons[closeID], in: app)
            XCTAssertTrue(start.waitForExistence(timeout: 10))
            XCTAssertEqual(app.buttons["home.continueScan"].exists, hadActiveScan)
            listsTab.tap()
            XCTAssertTrue(savedCount.waitForExistence(timeout: 5))
            XCTAssertEqual(savedCount.label, initialListCount, "Closing a zero-card scan must not save a list")
            scanTab.tap(); start.tap()
        }
        // Exercise the live footer before starting Mock's six-second timer.
        let totals = app.staticTexts["scanner.totals"]
        let manualSearch = app.buttons["scanner.manualSearch"]
        let viewList = app.buttons["scanner.viewList"]
        let details = app.buttons["scanner.detailsToggle"]
        let camera = app.descendants(matching: .any)["scanner.cameraSurface"].firstMatch
        XCTAssertTrue(camera.waitForExistence(timeout: 5))
        let cameraFrame = camera.frame
        let header = app.descendants(matching: .any)["scanner.header"].firstMatch
        XCTAssertTrue(header.waitForExistence(timeout: 5))
        XCTAssertLessThan(header.frame.height, 90, "Scanner information stays in a compact top strip")
        XCTAssertTrue(app.statusBars.firstMatch.exists, "The scanner keeps the real system status bar")
        assertOverlayVisible(totals, in: app)
        assertOverlayVisible(manualSearch, in: app)
        XCTAssertTrue(waitForValue("Expanded", of: details))
        tapFixedControl(details, in: app)
        XCTAssertTrue(waitForValue("Collapsed", of: details))
        XCTAssertEqual(camera.frame, cameraFrame, "Collapsing the scanned list cannot resize the camera")
        assertOverlayVisible(totals, in: app)
        assertOverlayVisible(manualSearch, in: app)
        assertOverlayVisible(viewList, in: app)
        tapFixedControl(details, in: app)
        XCTAssertTrue(waitForValue("Expanded", of: details))
        XCTAssertEqual(camera.frame, cameraFrame)
        let options = app.buttons["scanner.options"]
        tapCameraOptions(options, in: app)
        tapMenuItem("Developer Testing", in: app)
        let mock = menuItem("Mock — sample cards", in: app)
        if !mock.waitForExistence(timeout: 2) { tapMenuItem("Scanner source", in: app) }
        tapMenuItem("Mock — sample cards", in: app)

        let confirmation = app.navigationBars["Choose the Card"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 10))
        let fallback = app.buttons["scanReview.manualSearch"]
        assertOverlayVisible(fallback, in: app)
        tapFixedControl(fallback, in: app)
        let search = app.navigationBars["Search & Add"]
        XCTAssertTrue(search.waitForExistence(timeout: 5), "A missing candidate can be searched without saving a wrong match")
        let query = app.textFields["catalog.query"]
        XCTAssertTrue(query.waitForExistence(timeout: 5))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "Scanner manual search focuses the keyboard immediately")
        query.typeText("scanner search draft")
        _ = UITestInteraction.tap(app.buttons["catalog.keyboardDone"], in: app)
        let keyboardDismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.keyboards.firstMatch)
        XCTAssertEqual(XCTWaiter.wait(for: [keyboardDismissed], timeout: 5), .completed)
        XCTAssertEqual(query.value as? String, "scanner search draft", "Keyboard Done keeps the search text")
        _ = UITestInteraction.tapToolbar(search.buttons["Done"], in: app)
        XCTAssertTrue(confirmation.waitForExistence(timeout: 10), "Closing catalog search returns to scanning new matches")
        let firstAdd = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "scanReview.add.")).firstMatch
        XCTAssertTrue(firstAdd.waitForExistence(timeout: 5))
        let firstProduct = String(firstAdd.identifier.dropFirst("scanReview.add.".count))
        let condition = app.buttons["scanReview.condition"]
        let printing = app.buttons["scanReview.printing." + firstProduct]
        XCTAssertTrue(condition.waitForExistence(timeout: 5)); XCTAssertTrue(condition.isHittable)
        XCTAssertTrue(printing.waitForExistence(timeout: 5)); XCTAssertTrue(printing.isHittable)
        XCTAssertEqual(condition.value as? String, "Near Mint")
        XCTAssertEqual(printing.value as? String, "Normal")

        tapFixedControl(condition, in: app); tapMenuItem("Lightly Played", in: app)
        XCTAssertTrue(waitForValue("Lightly Played", of: condition))
        XCTAssertTrue(confirmation.exists, "Changing condition must not confirm the card")
        printing.tap(); tapMenuItem("Holofoil", in: app)
        XCTAssertTrue(waitForValue("Holofoil", of: printing))
        XCTAssertTrue(waitForValue("Lightly Played", of: condition))
        XCTAssertTrue(confirmation.exists, "Changing printing must not confirm the card")
        XCTAssertFalse(app.buttons["scanner.addAnotherCopy"].exists)

        let add = app.buttons["scanReview.add." + firstProduct]
        XCTAssertTrue(add.waitForExistence(timeout: 5)); add.tap()
        let recent = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "scanner.recentCard.")).firstMatch
        XCTAssertTrue(recent.waitForExistence(timeout: 10), "Explicit confirmation returns to the newest scanned card")
        XCTAssertTrue(recent.label.contains("Holofoil")); XCTAssertTrue(recent.label.contains("Lightly Played"))
        XCTAssertTrue(app.staticTexts["scanner.totals"].label.contains("1 cards"), "The discarded candidate was never added")
        XCTAssertTrue(app.buttons["scanner.undoLastAdd"].exists)
        XCTAssertTrue(app.buttons["scanner.addAnotherCopy"].exists)
        XCTAssertFalse(app.buttons["scanner.scanNext"].exists, "The next card must not require a Next button")
        // Mock intentionally emits another sample every six seconds. Stop that
        // timer by relaunching before the separate saved-inventory export check;
        // a fresh sample sheet must not race navigation to the already saved list.
        // Reopening also verifies confirmation persisted this physical row.
        app.terminate(); app.launch()
        let open = app.tabBars.buttons["Lists"]
        XCTAssertTrue(open.waitForExistence(timeout: 10)); open.tap()
        let saved = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "1 cards • ")).firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 5), "The confirmed one-card inventory must survive relaunch")
        saved.tap()
        XCTAssertTrue(app.navigationBars["Review & Offer"].waitForExistence(timeout: 5))
        let exportOptions = app.buttons["list.options"]
        _ = UITestInteraction.tapToolbar(exportOptions, in: app)
        let export = app.buttons["list.exportCSV"], share = app.buttons["list.shareCSV"]
        XCTAssertTrue(export.waitForExistence(timeout: 5)); XCTAssertTrue(export.isHittable); XCTAssertTrue(export.isEnabled)
        XCTAssertTrue(share.waitForExistence(timeout: 5)); XCTAssertTrue(share.isHittable); XCTAssertTrue(share.isEnabled)
    }

    func testRecentCardsShowNewestFirstAndOpenTheExistingCardEditor() {
        continueAfterFailure = false
        let app = launchRecentCardsFixture()
        defer { app.terminate() }
        let newestID = "scanner.recentCard.20000000-0000-0000-0000-000000000003"
        let middleID = "scanner.recentCard.20000000-0000-0000-0000-000000000002"
        let newest = app.buttons[newestID], middle = app.buttons[middleID]
        XCTAssertTrue(newest.waitForExistence(timeout: 5))
        XCTAssertTrue(middle.waitForExistence(timeout: 5))
        let recent = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "scanner.recentCard."))
        XCTAssertEqual(recent.firstMatch.identifier, newestID)
        XCTAssertLessThan(newest.frame.minY, middle.frame.minY)
        assertFixedScanActions(in: app)
        tapFixedControl(newest, in: app)
        XCTAssertTrue(app.navigationBars["Card Details"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["cardEditor.name"].label, "Synthetic scan 3")
        let quantity = app.steppers["cardEditor.quantity"]
        _ = UITestInteraction.reveal(quantity, in: app)
        _ = UITestInteraction.tap(quantity.buttons["Increment"], in: app)
        _ = UITestInteraction.tapToolbar(app.buttons["cardEditor.save"], in: app)
        XCTAssertTrue(newest.waitForExistence(timeout: 5))
        XCTAssertTrue(newest.label.contains("Qty 2"), "Quick edits update the same scanned row")
        XCTAssertEqual(recent.firstMatch.identifier, newestID, "Editing a quantity does not reorder scan history")
        XCTAssertTrue(app.staticTexts["scanner.totals"].label.contains("4 cards"))
        XCTAssertTrue(app.staticTexts["scanner.mode"].label.contains("Paused"), "Closing an editor respects a paused camera")
        assertFixedScanActions(in: app)
        tapFixedControl(middle, in: app)
        XCTAssertTrue(app.navigationBars["Card Details"].waitForExistence(timeout: 5), "Another recent card remains editable after a warm return")
        XCTAssertEqual(app.staticTexts["cardEditor.name"].label, "Synthetic scan 2")
        _ = UITestInteraction.tapToolbar(app.buttons["cardEditor.cancel"], in: app)
        assertFixedScanActions(in: app)
    }

    func testRecentCardDrawerKeepsActionsOnScreenAtAccessibilityTextSize() {
        continueAfterFailure = false
        let app = launchRecentCardsFixture(largeText: true)
        defer { app.terminate() }
        let details = app.buttons["scanner.detailsToggle"]
        XCTAssertTrue(waitForValue("Expanded", of: details))
        assertFixedScanActions(in: app)
        tapFixedControl(details, in: app)
        XCTAssertTrue(waitForValue("Collapsed", of: details))
        assertFixedScanActions(in: app)
        tapFixedControl(details, in: app)
        XCTAssertTrue(waitForValue("Expanded", of: details))
        assertFixedScanActions(in: app)
    }

    private func launchRecentCardsFixture(largeText: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        if let path = ProcessInfo.processInfo.environment["DYLD_FALLBACK_LIBRARY_PATH"] {
            app.launchEnvironment["DYLD_FALLBACK_LIBRARY_PATH"] = path
        }
        app.launchArguments = ["--uitest-scanner-recents", "-scannerDetailsCollapsed", "NO"]
        if largeText {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        app.launch()
        XCTAssertTrue(app.buttons["scanner.detailsToggle"].waitForExistence(timeout: 10))
        return app
    }

    private func assertFixedScanActions(in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        for identifier in ["scanner.manualSearch", "scanner.viewList", "scanner.finishSession", "scanner.options"] {
            assertOverlayVisible(app.buttons[identifier], in: app, file: file, line: line)
        }
    }

    private func assertOverlayVisible(_ element: XCUIElement, in app: XCUIApplication,
                                      file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.waitForExistence(timeout: 10), file: file, line: line)
        // Live WebKit video can report false AX hit-testing for native overlays.
        // Check actual bounds, as the fixed overlay interaction helpers do.
        let bounds = element.frame
        XCTAssertTrue(bounds.width > 0 && bounds.height > 0 && app.windows.firstMatch.frame.contains(bounds),
                      "Scanner control must remain on screen: \(element.identifier)", file: file, line: line)
    }

    private func menuItem(_ title: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: title).firstMatch
    }
    private func tapMenuItem(_ title: String, in app: XCUIApplication) {
        let item = menuItem(title, in: app)
        XCTAssertTrue(item.waitForExistence(timeout: 5), "Missing menu item: \(title)")
        item.tap()
    }
    private func acceptInitialCameraPermission() {
        // A fresh simulator asks asynchronously after loading the local camera
        // page. Wait on SpringBoard before taking app/WebKit AX snapshots; those
        // snapshots can finish only after consent and otherwise miss its arrival.
        let alert = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch
        guard alert.waitForExistence(timeout: 45) else { return } // Already authorized is valid too.
        let text = ([alert.label] + alert.staticTexts.allElementsBoundByIndex.map(\.label)).joined(separator: " ").lowercased()
        guard text.contains("camera") else { return }
        let allow = alert.buttons["Allow"]
        XCTAssertTrue(allow.waitForExistence(timeout: 5), "Camera consent has no Allow button: " + alert.debugDescription)
        allow.tap()
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: alert)
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 5), .completed, "Camera consent must close before testing scanner controls")
    }
    private func tapCameraOptions(_ element: XCUIElement, in app: XCUIApplication) {
        XCTAssertTrue(element.waitForExistence(timeout: 10))
        // A cold database load can finish after the initial permission wait.
        // Handle the actual camera prompt at the point of interaction as well.
        dismissCameraPermission(in: app)
        XCTAssertEqual(app.state, .runningForeground)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let noSystemAlert = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: springboard.alerts.firstMatch)
        XCTAssertEqual(XCTWaiter.wait(for: [noSystemAlert], timeout: 5), .completed,
                       "System consent must close before opening Options. " + failureContext(in: app))
        XCTAssertFalse(app.alerts.firstMatch.exists, "An app alert must not cover Options. " + failureContext(in: app))
        XCTAssertTrue(element.isEnabled)
        let bounds = element.frame, window = app.windows.firstMatch.frame
        let onScreen = bounds.width >= 44 && bounds.height >= 44 && window.contains(bounds)
        XCTAssertTrue(onScreen, "Camera Options must be entirely on screen: \(bounds), window: \(window)")
        guard onScreen else { return }
        // WebKit's active video yields unreliable AX hit-testing for this fixed
        // overlay. Tap its verified screen position; the following Developer
        // Testing assertion requires the actual menu to open before proceeding.
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }
    private func tapFixedControl(_ element: XCUIElement, in app: XCUIApplication) {
        let exists = element.waitForExistence(timeout: 10)
        XCTAssertTrue(exists, "Fixed control is missing: \(element.identifier). " + failureContext(in: app))
        guard exists else { return }
        // The first live camera can present native consent after its overlay
        // already exists. Waiting alone never triggers an interruption monitor.
        // Check both owners of the real permission alert while it arrives.
        var hittable = false
        for _ in 0..<5 {
            dismissCameraPermission(in: app)
            let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND hittable == true"), object: element)
            if XCTWaiter.wait(for: [ready], timeout: 2) == .completed { hittable = true; break }
        }
        XCTAssertTrue(hittable, "Fixed control did not become hittable: \(element.identifier). " + failureContext(in: app))
        guard hittable else { return }
        // XCTest's element.tap() attempts AXScrollToVisible even for a fixed
        // camera overlay. Its validated center is already on screen.
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }
    private func dismissCameraPermission(in app: XCUIApplication) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for owner in [springboard, app] {
            for alert in owner.alerts.allElementsBoundByIndex where alert.exists {
                let text = ([alert.label] + alert.staticTexts.allElementsBoundByIndex.map(\.label)).joined(separator: " ").lowercased()
                guard text.contains("camera") else { continue }
                // Interruption monitors run only on an attempted app interaction.
                // Consent correctly makes the underlying Options non-hittable;
                // waiting for it cannot invoke the monitor. The known modal
                // intercepts this interaction before the ordinary camera UI.
                app.tap()
                guard alert.exists else { return }
                for title in ["Allow", "OK", "Allow Access"] {
                    let button = alert.buttons[title]
                    // SpringBoard can report a permission button as non-hittable
                    // even while its actual modal is visible. Use its normal tap;
                    // app controls still require the visibility assertion above.
                    guard button.exists else { continue }
                    button.tap()
                    return
                }
            }
        }
    }
    private func failureContext(in app: XCUIApplication) -> String {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let alerts = springboard.alerts.allElementsBoundByIndex.filter(\.exists).map { alert in
            ([alert.label] + alert.staticTexts.allElementsBoundByIndex.map(\.label)
                + alert.buttons.allElementsBoundByIndex.map { "button=" + $0.label }).joined(separator: " ")
        }.joined(separator: " | ")
        let tree = app.debugDescription.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        let system = alerts.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return "SpringBoard alerts: " + String(system.prefix(800)) + ". App UI: " + String(tree.prefix(2000))
    }
    private func waitForValue(_ expected: String, of element: XCUIElement) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", expected), object: element)
        return XCTWaiter.wait(for: [expectation], timeout: 5) == .completed
    }
}
