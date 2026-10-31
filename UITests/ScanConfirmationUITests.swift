import XCTest

/// Follows the normal testing menu; no camera, account or network result is required.
@MainActor final class ScanConfirmationUITests: XCTestCase {
    func testVisibleDropdownsEditBeforeConfirmationAndSavedListCanExport() async throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        if let path = ProcessInfo.processInfo.environment["DYLD_FALLBACK_LIBRARY_PATH"] {
            app.launchEnvironment["DYLD_FALLBACK_LIBRARY_PATH"] = path
        }
        // Launch-domain defaults acknowledge the optional connection step only.
        // Mock recognition is still selected explicitly through the normal UI.
        app.launchArguments = ["-tcgTrackingConnectionIntroduced", "YES", "-defaultGame", "Pokémon"]
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
        let options = app.buttons["scanner.options"]
        tapCameraOptions(options, in: app)
        tapMenuItem("Developer Testing", in: app)
        let mock = menuItem("Mock — sample cards", in: app)
        if !mock.waitForExistence(timeout: 2) { tapMenuItem("Scanner source", in: app) }
        tapMenuItem("Mock — sample cards", in: app)

        let confirmation = app.navigationBars["Choose the Card"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 10))
        let firstProduct = "mock:Pokémon:0"
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
        XCTAssertTrue(app.staticTexts["scanner.lastAdded"].waitForExistence(timeout: 10),
            "Explicit confirmation must return with a committed last-card action")
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
        XCTAssertTrue(exportOptions.waitForExistence(timeout: 5)); exportOptions.tap()
        let export = app.buttons["list.exportCSV"], share = app.buttons["list.shareCSV"]
        XCTAssertTrue(export.waitForExistence(timeout: 5)); XCTAssertTrue(export.isHittable); XCTAssertTrue(export.isEnabled)
        XCTAssertTrue(share.waitForExistence(timeout: 5)); XCTAssertTrue(share.isHittable); XCTAssertTrue(share.isEnabled)
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
