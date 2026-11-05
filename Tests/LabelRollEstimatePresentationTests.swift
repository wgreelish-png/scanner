import XCTest
@testable import CardShowScanner

final class LabelRollEstimatePresentationTests: XCTestCase {
    private let estimate = NiimbotRollEstimate(productCode: "fixture", totalLabels: 100, usedLabels: 25, labelType: 1)

    func testFreshEstimateShowsRemainingAndCounterContextWithoutWarningAtCapacity() {
        let view = LabelRollEstimatePresentation(estimate: estimate, freshness: .fresh, isReading: false, pendingLabels: 75)
        XCTAssertEqual(view.title, "Estimated labels remaining: 75")
        XCTAssertTrue(view.detail?.contains("25 used of 100 reported") == true)
        XCTAssertTrue(view.detail?.contains("actual labels can differ") == true)
        XCTAssertNil(view.warning)
    }

    func testFreshLowRollShowsAnAdvisoryIncludingAReportedEmptyRoll() {
        let low = LabelRollEstimatePresentation(estimate: estimate, freshness: .fresh, isReading: false, pendingLabels: 76)
        XCTAssertTrue(low.warning?.contains("76 queued labels") == true)
        let empty = NiimbotRollEstimate(productCode: "fixture", totalLabels: 100, usedLabels: 100, labelType: 1)
        let view = LabelRollEstimatePresentation(estimate: empty, freshness: .fresh, isReading: false, pendingLabels: 1)
        XCTAssertEqual(view.title, "Estimated labels remaining: 0")
        XCTAssertNotNil(view.warning, "A valid reported zero is distinct from an unavailable estimate")
    }

    func testUnknownAndUnsupportedReadingsNeverBecomeZeroOrWarnAboutQueueCapacity() {
        for freshness in [NiimbotRollEstimateFreshness.unknown, .unavailable] {
            let view = LabelRollEstimatePresentation(estimate: nil, freshness: freshness, isReading: false, pendingLabels: 250)
            XCTAssertEqual(view.title, "Estimated labels remaining: Unknown")
            XCTAssertNil(view.warning)
        }
        let missing = LabelRollEstimatePresentation(estimate: nil, freshness: .fresh, isReading: false, pendingLabels: 1)
        XCTAssertEqual(missing.title, "Estimated labels remaining: Unknown")
        XCTAssertNil(missing.warning)
    }

    func testStaleEstimateKeepsItsLastCountAndSurfacesReconnectInstructions() {
        let view = LabelRollEstimatePresentation(estimate: estimate, freshness: .stale, isReading: false, pendingLabels: 250,
            status: "Reconnect to refresh the roll estimate.")
        XCTAssertEqual(view.title, "Estimated labels remaining: 75 (stale)")
        XCTAssertTrue(view.detail?.contains("Reconnect to refresh") == true)
        XCTAssertTrue(view.detail?.contains("Last report: 25 used of 100") == true)
        XCTAssertNil(view.warning, "Stale counts cannot make a fresh queue-capacity claim")
    }

    func testRefreshShowsReadingStateUntilAResultIsAvailable() {
        let view = LabelRollEstimatePresentation(estimate: estimate, freshness: .fresh, isReading: true, pendingLabels: 250)
        XCTAssertEqual(view.title, "Estimated labels remaining: Checking…")
        XCTAssertTrue(view.detail?.contains("Reading") == true)
        XCTAssertNil(view.warning)
    }
}
