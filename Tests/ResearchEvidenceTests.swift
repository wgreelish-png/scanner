import XCTest
@testable import CardShowScanner

@MainActor final class ResearchEvidenceTests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-10-29T15:30:00Z")!

    private func history(_ rows: [[Any]]) throws -> ResearchDailyHistory {
        try JSONDecoder().decode(ResearchDailyHistory.self,
            from: JSONSerialization.data(withJSONObject: ["series": rows]))
    }
    private func day(_ text: String) -> Date { ISO8601DateFormatter().date(from: text + "T00:00:00Z")! }

    func testThirtyDayPeriodUsesCalendarDaysEndingTodayRatherThanLastThirtyObservations() async throws {
        let data = try history([["2026-09-29", 1, 10], ["2026-09-30", 2, 20], ["2026-10-29", 3, 30]])
        let result = ResearchEvidence(history: data, range: .month, now: now)
        XCTAssertEqual(result.points.map(\.day), ["2026-09-30", "2026-10-29"])
        XCTAssertEqual(result.domain.lowerBound, day("2026-09-30"))
        XCTAssertEqual(result.domain.upperBound, day("2026-10-30"))
    }

    func testStaleHistoryDoesNotMoveCalendarWindowBackToLastSale() async throws {
        let data = try history([["2026-01-10", 3, 20]])
        let result = ResearchEvidence(history: data, range: .quarter, now: now)
        XCTAssertTrue(result.points.isEmpty)
        XCTAssertNil(result.knownSalesTotal)
        XCTAssertEqual(result.priceDayCount, 0)
        XCTAssertLessThan(result.domain.lowerBound, now)
    }

    func testUnknownCountsRemainDifferentFromReportedZeroAndKnownSumIsExplicitlyPartial() async throws {
        let data = try history([["2026-10-27", NSNull(), 9], ["2026-10-28", 0, 0], ["2026-10-29", 2, NSNull()]])
        let result = ResearchEvidence(history: data, range: .month, now: now)
        XCTAssertEqual(result.points.count, 3)
        XCTAssertEqual(result.countDayCount, 2)
        XCTAssertEqual(result.priceDayCount, 2)
        XCTAssertEqual(result.knownSalesTotal, 2)
        XCTAssertTrue(result.countsArePartial)
        XCTAssertEqual(result.priceMarks.last?.value, 0)
        XCTAssertNil(result.points[0].sales)
        XCTAssertNil(result.points[2].average)
    }

    func testDuplicateDailyAggregatesAreOmittedWithoutChoosingOrAddingThem() async throws {
        let data = try history([["2026-10-26", 2, 10], ["2026-10-27", 3, 20], ["2026-10-27", 4, 30], ["2026-10-28", 5, 40]])
        let result = ResearchEvidence(history: data, range: .month, now: now)
        XCTAssertEqual(result.duplicateDayCount, 1)
        XCTAssertEqual(result.points.map(\.day), ["2026-10-26", "2026-10-28"])
        XCTAssertEqual(result.knownSalesTotal, 7)
        XCTAssertNotEqual(result.priceMarks[0].segment, result.priceMarks[1].segment)
    }

    func testEvenIdenticalDuplicateDaysDoNotInflateReportedSales() async throws {
        let data = try history([["2026-10-28", 5, 40], ["2026-10-28", 5, 40]])
        let result = ResearchEvidence(history: data, range: .all, now: now)
        XCTAssertEqual(result.duplicateDayCount, 1)
        XCTAssertTrue(result.points.isEmpty)
        XCTAssertNil(result.knownSalesTotal)
    }

    func testFutureDatedRowsAreExcludedButTodayIsIncluded() async throws {
        let data = try history([["2026-10-29", 1, 10], ["2026-10-30", 8, 80], ["2027-01-01", 9, 90]])
        let result = ResearchEvidence(history: data, range: .all, now: now)
        XCTAssertEqual(result.points.map(\.day), ["2026-10-29"])
        XCTAssertEqual(result.futureRowCount, 2)
        XCTAssertEqual(result.knownSalesTotal, 1)
    }

    func testSoldAverageLinesBreakAtMissingDatesAndUnknownPrices() async throws {
        let data = try history([["2026-10-20", 1, 10], ["2026-10-21", 1, 11], ["2026-10-23", 1, 13],
                                ["2026-10-24", 1, NSNull()], ["2026-10-25", 1, 15]])
        let result = ResearchEvidence(history: data, range: .month, now: now)
        XCTAssertEqual(result.priceMarks.count, 4)
        XCTAssertEqual(result.priceMarks[0].segment, result.priceMarks[1].segment)
        XCTAssertNotEqual(result.priceMarks[1].segment, result.priceMarks[2].segment)
        XCTAssertNotEqual(result.priceMarks[2].segment, result.priceMarks[3].segment)
    }

    func testAllHistoryIsSortedAndKeepsStaleTailVisibleThroughToday() async throws {
        let data = try history([["2026-09-10", 1, 10], ["2025-01-01", 1, 11]])
        let result = ResearchEvidence(history: data, range: .all, now: now)
        XCTAssertEqual(result.points.map(\.day), ["2025-01-01", "2026-09-10"])
        XCTAssertEqual(result.domain.lowerBound, day("2025-01-01"))
        XCTAssertEqual(result.domain.upperBound, day("2026-10-30"))
    }

    func testInspectionDoesNotSnapAcrossMissingDays() async throws {
        let data = try history([["2026-10-20", 1, 10], ["2026-10-29", 1, 11]])
        let result = ResearchEvidence(history: data, range: .month, now: now)
        XCTAssertEqual(result.point(nearest: day("2026-10-20"))?.day, "2026-10-20")
        XCTAssertNil(result.point(nearest: day("2026-10-24")))
    }

    func testOverflowingSalesSumIsUnavailableInsteadOfCrashingOrWrapping() async throws {
        let data = try history([["2026-10-28", Int.max, 10], ["2026-10-29", 1, 10]])
        let result = ResearchEvidence(history: data, range: .month, now: now)
        XCTAssertEqual(result.countDayCount, 2)
        XCTAssertNil(result.knownSalesTotal)
    }

    func testZeroSalesIsARealTotalAndNoHistoryIsUnavailable() async throws {
        let zero = ResearchEvidence(history: try history([["2026-10-29", 0, 0]]), range: .month, now: now)
        XCTAssertEqual(zero.knownSalesTotal, 0)
        XCTAssertFalse(zero.countsArePartial)
        let empty = ResearchEvidence(history: nil, range: .all, now: now)
        XCTAssertTrue(empty.points.isEmpty)
        XCTAssertNil(empty.knownSalesTotal)
        XCTAssertTrue(empty.priceMarks.isEmpty)
    }

    func testWindowBoundariesRemainUTCWhenLocalTimeCouldBePreviousDay() async throws {
        let midnight = ISO8601DateFormatter().date(from: "2026-10-29T00:05:00Z")!
        let data = try history([["2026-09-29", 1, 10], ["2026-09-30", 1, 10], ["2026-10-29", 1, 10]])
        let result = ResearchEvidence(history: data, range: .month, now: midnight)
        XCTAssertEqual(result.points.map(\.day), ["2026-09-30", "2026-10-29"])
    }
}
