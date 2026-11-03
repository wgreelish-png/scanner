import XCTest
import SwiftUI
@testable import CardShowScanner

final class ForegroundMinuteScheduleTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    func testActiveScheduleUsesMinuteTicksWithoutAnimationFrames() {
        let schedule = ForegroundMinuteSchedule(enabled: true)
        let dates = Array(schedule.entries(from: start, mode: .normal).prefix(4))
        XCTAssertEqual(dates, (0..<4).map { start.addingTimeInterval(Double($0) * 60) })
    }

    func testInactiveScheduleEmitsItsCurrentValueWithoutFutureWorkInEitherMode() {
        let schedule = ForegroundMinuteSchedule(enabled: false)
        for mode in [TimelineScheduleMode.normal, .lowFrequency] {
            XCTAssertEqual(Array(schedule.entries(from: start, mode: mode).prefix(4)), [start])
        }
    }

    func testLowFrequencyScheduleCannotBecomeAnAnimationOrCatchUpLoop() {
        let schedule = ForegroundMinuteSchedule(enabled: true)
        let resumedAt = start.addingTimeInterval(6 * 60 * 60)
        let dates = Array(schedule.entries(from: resumedAt, mode: .lowFrequency).prefix(4))
        XCTAssertEqual(dates.count, 4)
        XCTAssertEqual(dates.first, resumedAt)
        for (earlier, later) in zip(dates, dates.dropFirst()) {
            XCTAssertGreaterThanOrEqual(later.timeIntervalSince(earlier), 60)
        }
    }
}
