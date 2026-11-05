import XCTest
@testable import CardShowScanner

final class DeviceMetricReportsTests: XCTestCase {
    func testReportsContainOnlyFixedKindsAndNumericWindowCounts() throws {
        let report = try XCTUnwrap(makeReport(crashes: 2, hangs: 3, cpuExceptions: 4, diskWriteExceptions: 5))
        XCTAssertEqual(report.diagnosticFields, [
            ["health_report_kind": "crash", "health_report_count": "2", "health_report_window_s": "3600"],
            ["health_report_kind": "hang", "health_report_count": "3", "health_report_window_s": "3600"],
            ["health_report_kind": "cpu_exception", "health_report_count": "4", "health_report_window_s": "3600"],
            ["health_report_kind": "disk_write_exception", "health_report_count": "5", "health_report_window_s": "3600"]
        ])
        XCTAssertTrue(try XCTUnwrap(makeReport()).diagnosticFields.isEmpty)
    }

    func testCountsAreBoundedAndNegativeOrZeroCountsAreNotReported() throws {
        let report = try XCTUnwrap(makeReport(crashes: Int.max, hangs: -1, cpuExceptions: 0, diskWriteExceptions: Int.max))
        XCTAssertEqual(report.diagnosticFields, [
            ["health_report_kind": "crash", "health_report_count": "1000", "health_report_window_s": "3600"],
            ["health_report_kind": "disk_write_exception", "health_report_count": "1000", "health_report_window_s": "3600"]
        ])
    }

    func testMalformedAndOversizedWindowsAreRejectedWithoutLoggingAbsoluteTimes() throws {
        let begin = Date(timeIntervalSinceReferenceDate: 1_000)
        for end in [Date(timeIntervalSinceReferenceDate: .infinity),
                    Date(timeIntervalSinceReferenceDate: .nan), begin.addingTimeInterval(-1),
                    begin.addingTimeInterval(604_801)] {
            XCTAssertNil(DeviceMetricReport(begin: begin, end: end, crashes: 1, hangs: 0,
                                            cpuExceptions: 0, diskWriteExceptions: 0))
        }
        let maximum = try XCTUnwrap(DeviceMetricReport(begin: begin, end: begin.addingTimeInterval(604_800),
            crashes: 1, hangs: 0, cpuExceptions: 0, diskWriteExceptions: 0))
        XCTAssertEqual(maximum.diagnosticFields.first?["health_report_window_s"], "604800")
        XCTAssertEqual(Set(try XCTUnwrap(maximum.diagnosticFields.first).keys),
                       ["health_report_kind", "health_report_count", "health_report_window_s"])
    }

    func testReplayedWindowsAreDeduplicatedWhileDistinctWindowsRemainIndependent() throws {
        var deduplicator = DeviceMetricReportDeduplicator()
        let first = try XCTUnwrap(makeReport(crashes: 2))
        let replay = try XCTUnwrap(makeReport(crashes: 2))
        let next = try XCTUnwrap(makeReport(offset: 3_600, crashes: 2))
        XCTAssertTrue(deduplicator.insert(first.window))
        XCTAssertFalse(deduplicator.insert(replay.window))
        XCTAssertTrue(deduplicator.insert(next.window), "Report counts belong to their individual windows")
    }

    func testReplayHistoryIsBoundedInMemory() throws {
        var deduplicator = DeviceMetricReportDeduplicator()
        for index in 0..<40 {
            XCTAssertTrue(deduplicator.insert(try XCTUnwrap(makeReport(offset: Double(index) * 3_600)).window))
        }
        XCTAssertFalse(deduplicator.insert(try XCTUnwrap(makeReport(offset: 39 * 3_600)).window))
        XCTAssertTrue(deduplicator.insert(try XCTUnwrap(makeReport()).window), "Old windows expire from the bounded history")
    }

    private func makeReport(offset: TimeInterval = 0, crashes: Int = 0, hangs: Int = 0,
                            cpuExceptions: Int = 0, diskWriteExceptions: Int = 0) -> DeviceMetricReport? {
        let begin = Date(timeIntervalSinceReferenceDate: 1_000 + offset)
        return DeviceMetricReport(begin: begin, end: begin.addingTimeInterval(3_600), crashes: crashes, hangs: hangs,
                                  cpuExceptions: cpuExceptions, diskWriteExceptions: diskWriteExceptions)
    }
}
