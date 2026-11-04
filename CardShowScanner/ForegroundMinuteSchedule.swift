import Foundation
import SwiftUI

/// Date eligibility needs minute ticks, not an animation display link. Keep
/// the same TimelineView type while visibility changes so drafts retain their
/// identity. An inactive view gets its initial value and no future ticks.
struct ForegroundMinuteSchedule: TimelineSchedule {
    let enabled: Bool

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> AnySequence<Date> {
        guard enabled else { return AnySequence(CollectionOfOne(startDate)) }
        let schedule = PeriodicTimelineSchedule(from: startDate, by: 60)
        return AnySequence(schedule.entries(from: startDate, mode: mode))
    }
}
