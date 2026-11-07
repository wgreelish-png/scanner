import XCTest

/// UI tests scroll only the visible content container. Fixed navigation items
/// use a checked screen coordinate, avoiding XCTest's AXScrollToVisible action
/// on a button that is already in the navigation bar.
@MainActor enum UITestInteraction {
    /// SwiftUI searchable may provide its own keyboard accessory instead of a
    /// screen's custom Done button. Both paths must submit without clearing the query.
    @discardableResult
    static func submitSearch(in app: XCUIApplication, doneIdentifier: String,
                             file: StaticString = #filePath, line: UInt = #line) -> Bool {
        let keyboard = app.keyboards.firstMatch
        guard keyboard.waitForExistence(timeout: 5) else {
            XCTFail("Search must show its keyboard before submission", file: file, line: line)
            return false
        }
        let done = app.buttons[doneIdentifier]
        if waitUntilTouchable(done, in: app, timeout: 1) {
            guard tap(done, in: app, identifier: doneIdentifier, file: file, line: line) else { return false }
        } else {
            let submit = app.keyboards.buttons.matching(NSPredicate(format: "label ==[c] %@", "search")).firstMatch
            // The keyboard key is intentionally outside the content viewport.
            guard wait(timeout: 5, until: {
                submit.exists && submit.isEnabled && submit.isHittable && visibleFrame(submit.frame, in: app)
            }) else {
                XCTFail("The search keyboard must expose Done or its native Search action", file: file, line: line)
                return false
            }
            submit.tap()
        }
        guard wait(timeout: 5, until: { !keyboard.exists }) else {
            XCTFail("Submitting search must dismiss its keyboard", file: file, line: line)
            return false
        }
        return true
    }

    @discardableResult
    static func reveal(_ element: XCUIElement, in app: XCUIApplication,
                       identifier: String? = nil, towardTopWhenMissing: Bool = false, file: StaticString = #filePath,
                       line: UInt = #line) -> Bool {
        if waitUntilTouchable(element, in: app, timeout: 1) { return true }
        if element.exists, belongsToFixedBar(element, in: app) {
            return fail("Fixed control is not touchable", element, in: app,
                        identifier: identifier, file: file, line: line)
        }

        // A missing lazy row is normally below the initial viewport. Pulling
        // down blindly at the top of a sheet can dismiss it and start scrolling
        // the screen underneath. Callers seeking an earlier virtualized row
        // explicitly choose the upward direction instead.
        for _ in 0..<8 {
            if touchable(element, in: app) { return true }
            let towardTop = element.exists ? element.frame.midY < contentViewport(in: app).midY : towardTopWhenMissing
            guard scrollContent(in: app, towardTop: towardTop, file: file, line: line) else { return false }
        }
        if waitUntilTouchable(element, in: app, timeout: 1) { return true }
        return fail("Control did not become visible", element, in: app,
                    identifier: identifier, file: file, line: line)
    }

    @discardableResult
    static func tap(_ element: XCUIElement, in app: XCUIApplication,
                    identifier: String? = nil, file: StaticString = #filePath,
                    line: UInt = #line) -> Bool {
        if element.exists, belongsToFixedBar(element, in: app) {
            return tapToolbar(element, in: app, identifier: identifier, file: file, line: line)
        }
        guard reveal(element, in: app, identifier: identifier, file: file, line: line) else { return false }
        guard element.isEnabled else {
            return fail("Control is disabled", element, in: app, identifier: identifier, file: file, line: line)
        }
        // Navigation transitions can finish while reveal is waiting.
        if belongsToFixedBar(element, in: app) {
            return tapToolbar(element, in: app, identifier: identifier, file: file, line: line)
        }
        element.tap()
        return true
    }

    @discardableResult
    static func tapToolbar(_ element: XCUIElement, in app: XCUIApplication,
                           identifier: String? = nil, file: StaticString = #filePath,
                           line: UInt = #line) -> Bool {
        var previous: CGRect?
        let ready = wait(timeout: 5) {
            guard element.exists, element.isEnabled, visibleFrame(element.frame, in: app),
                  belongsToFixedBar(element, in: app) else { previous = nil; return false }
            let current = element.frame
            defer { previous = current }
            return previous == current
        }
        guard ready else {
            return fail("Toolbar control is missing, disabled or outside the visible bar", element, in: app,
                        identifier: identifier, file: file, line: line)
        }
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        return true
    }

    @discardableResult
    static func scrollToTop(in app: XCUIApplication, file: StaticString = #filePath,
                            line: UInt = #line) -> Bool {
        for _ in 0..<4 {
            guard scrollContent(in: app, towardTop: true, file: file, line: line) else { return false }
        }
        return true
    }

    @discardableResult
    static func scrollContent(in app: XCUIApplication, towardTop: Bool,
                              file: StaticString = #filePath, line: UInt = #line) -> Bool {
        let viewport = contentViewport(in: app)
        let containers = app.collectionViews.allElementsBoundByIndex +
            app.tables.allElementsBoundByIndex + app.scrollViews.allElementsBoundByIndex
        let visible = containers.filter {
            $0.exists && $0.isHittable && $0.frame.intersection(viewport).width > 100 &&
                $0.frame.intersection(viewport).height > 100
        }
        guard let container = visible.max(by: {
            area($0.frame.intersection(viewport)) < area($1.frame.intersection(viewport))
        }) else {
            XCTFail("No visible foreground scroll container; viewport=\(viewport)", file: file, line: line)
            return false
        }
        let frame = container.frame.intersection(viewport)
        let x = frame.minX + frame.width * 0.97
        let upper = frame.minY + frame.height * 0.24
        let lower = frame.minY + frame.height * 0.77
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let start = origin.withOffset(CGVector(dx: x, dy: towardTop ? upper : lower))
        let end = origin.withOffset(CGVector(dx: x, dy: towardTop ? lower : upper))
        start.press(forDuration: 0.05, thenDragTo: end)
        return true
    }

    private static func waitUntilTouchable(_ element: XCUIElement, in app: XCUIApplication,
                                          timeout: TimeInterval) -> Bool {
        wait(timeout: timeout) { touchable(element, in: app) }
    }

    /// Keep polling on the actor that owns XCUIElement rather than handing an
    /// actor-isolated closure to Foundation's predicate evaluator.
    private static func wait(timeout: TimeInterval, until ready: @MainActor () -> Bool) -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        repeat {
            if ready() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        } while ProcessInfo.processInfo.systemUptime < deadline
        return ready()
    }

    private static func touchable(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        guard element.exists, element.isHittable, visibleFrame(element.frame, in: app) else { return false }
        // SwiftUI can expose a lazy row as hittable even when a safe-area
        // control covers it. Scroll body controls into the unobscured content.
        let bars = fixedBars(in: app)
        if belongsToFixedBar(element, in: app, bars: bars) { return true }
        return contentViewport(in: app, bars: bars).contains(CGPoint(x: element.frame.midX, y: element.frame.midY))
    }

    private static func visibleFrame(_ frame: CGRect, in app: XCUIApplication) -> Bool {
        let window = app.windows.firstMatch
        guard window.exists, frame.width > 0, frame.height > 0,
              frame.origin.x.isFinite, frame.origin.y.isFinite,
              frame.width.isFinite, frame.height.isFinite else { return false }
        let visible = frame.intersection(window.frame)
        return !visible.isNull && window.frame.contains(CGPoint(x: frame.midX, y: frame.midY)) &&
            visible.width >= min(24, frame.width) && visible.height >= min(24, frame.height)
    }

    private static func fixedBars(in app: XCUIApplication,
                                  containing target: (center: CGPoint, identifier: String)? = nil) -> [XCUIElement] {
        let pinned = app.otherElements.matching(NSPredicate(format: "identifier IN %@", [
            "showTransaction.checkoutBar", "showTransaction.receiptActions"
        ])).allElementsBoundByIndex
        return (app.navigationBars.allElementsBoundByIndex + app.tabBars.allElementsBoundByIndex +
         app.toolbars.allElementsBoundByIndex + pinned).filter { bar in
            guard bar.exists, visibleFrame(bar.frame, in: app) else { return false }
            // Classifying a known control need not probe buttons in unrelated
            // covered bars. Matched bars retain the full visibility fallback.
            if let target {
                guard bar.frame.contains(target.center),
                      bar.descendants(matching: .any).matching(identifier: target.identifier).firstMatch.exists else { return false }
            }
            return bar.isHittable || bar.buttons.allElementsBoundByIndex.contains { $0.exists && $0.isHittable }
        }
    }

    private static func belongsToFixedBar(_ element: XCUIElement, in app: XCUIApplication,
                                         bars: [XCUIElement]? = nil) -> Bool {
        guard element.exists else { return false }
        let frame = element.frame
        guard visibleFrame(frame, in: app) else { return false }
        let center = CGPoint(x: frame.midX, y: frame.midY)
        let identifier = element.identifier
        let target = identifier.isEmpty ? nil : (center: center, identifier: identifier)
        return (bars ?? fixedBars(in: app, containing: target)).contains { bar in
            guard bar.frame.contains(center) else { return false }
            if identifier.isEmpty { return element.isHittable }
            return bar.descendants(matching: .any).matching(identifier: identifier).firstMatch.exists
        }
    }

    private static func contentViewport(in app: XCUIApplication, bars: [XCUIElement]? = nil) -> CGRect {
        let window = app.windows.firstMatch
        guard window.exists else { return .zero }
        let bounds = window.frame.insetBy(dx: 6, dy: 6)
        var top = bounds.minY, bottom = bounds.maxY
        for bar in bars ?? fixedBars(in: app) {
            let frame = bar.frame
            if frame.midY < window.frame.midY { top = max(top, frame.maxY) }
            else { bottom = min(bottom, frame.minY) }
        }
        // A number pad has no accessory bar in some forms. Exclude its actual
        // docked frame as well, otherwise reveal gestures land on keyboard keys
        // instead of the foreground list whose row needs to become visible.
        for keyboard in app.keyboards.allElementsBoundByIndex where keyboard.exists {
            let frame = keyboard.frame.intersection(window.frame)
            // Docked keyboards can exclude the home-indicator area from their
            // AX frame, so they need not reach the window's bottom edge.
            if !frame.isNull, !frame.isEmpty, frame.minY > bounds.midY,
               frame.width >= bounds.width * 0.5 {
                bottom = min(bottom, frame.minY)
            }
        }
        return CGRect(x: bounds.minX, y: top, width: bounds.width, height: max(0, bottom - top))
    }

    private static func area(_ frame: CGRect) -> CGFloat {
        frame.isNull ? 0 : frame.width * frame.height
    }

    private static func fail(_ reason: String, _ element: XCUIElement, in app: XCUIApplication,
                             identifier: String?, file: StaticString, line: UInt) -> Bool {
        let exists = element.exists
        let name = identifier ?? (exists ? element.identifier : "unresolved selector")
        let safeName = name.count <= 160 && name.range(of: #"^[A-Za-z0-9_.:-]+$"#, options: .regularExpression) != nil
            ? name : "unnamed control (see caller)"
        let state = exists ? "type=\(element.elementType.rawValue) frame=\(element.frame) enabled=\(element.isEnabled) hittable=\(element.isHittable)"
            : "exists=false"
        XCTFail("\(reason): id=\(safeName) \(state); viewport=\(contentViewport(in: app))", file: file, line: line)
        return false
    }
}
