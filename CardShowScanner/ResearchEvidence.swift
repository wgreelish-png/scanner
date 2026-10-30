import Foundation

enum ResearchHistoryRange: String, CaseIterable, Identifiable, Sendable {
    case month = "30d", quarter = "90d", year = "365d", all = "All"
    var id: String { rawValue }
    var days: Int? {
        switch self {
        case .month: return 30
        case .quarter: return 90
        case .year: return 365
        case .all: return nil
        }
    }
}

/// Projects returned observations for display, without estimating missing days.
/// Duplicate dates are ambiguous daily aggregates and are all omitted, rather
/// than adding their counts or arbitrarily choosing a price.
struct ResearchEvidence: Sendable {
    let points: [ResearchDailyPoint]
    let duplicateDayCount: Int
    let futureRowCount: Int
    let domain: ClosedRange<Date>

    init(history: ResearchDailyHistory?, range: ResearchHistoryRange, now: Date = Date()) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let today = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .day, value: 1, to: today)!
        let start = range.days.flatMap { calendar.date(byAdding: .day, value: 1 - $0, to: today) }
        let rows = history?.series ?? []
        futureRowCount = rows.filter { $0.date >= end }.count
        let candidates = rows.filter { $0.date < end && (start == nil || $0.date >= start!) }
        let byDay = Dictionary(grouping: candidates, by: \.day)
        duplicateDayCount = byDay.values.filter { $0.count > 1 }.count
        points = byDay.values.compactMap { $0.count == 1 ? $0.first : nil }.sorted { $0.day < $1.day }
        domain = (start ?? points.first?.date ?? today)...end
    }

    var countDayCount: Int { points.filter { $0.sales != nil }.count }
    var priceDayCount: Int { points.filter { $0.average != nil }.count }
    var countsArePartial: Bool { countDayCount < points.count }
    var knownSalesTotal: Int? {
        let counts = points.compactMap(\.sales)
        guard !counts.isEmpty else { return nil }
        var total = 0
        for count in counts {
            let next = total.addingReportingOverflow(count)
            guard !next.overflow else { return nil }
            total = next.partialValue
        }
        return total
    }

    var priceMarks: [ResearchEvidencePriceMark] {
        var result: [ResearchEvidencePriceMark] = []
        var segment = 0
        var previous: Date?
        for point in points {
            guard let average = point.average else { segment += 1; previous = nil; continue }
            if let previous, point.date.timeIntervalSince(previous) > 86_401 { segment += 1 }
            result.append(ResearchEvidencePriceMark(id: point.day, date: point.date,
                value: NSDecimalNumber(decimal: average).doubleValue, segment: segment))
            previous = point.date
        }
        return result
    }

    func point(nearest date: Date) -> ResearchDailyPoint? {
        points.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
            .flatMap { abs($0.date.timeIntervalSince(date)) <= 43_200 ? $0 : nil }
    }
}

struct ResearchEvidencePriceMark: Identifiable, Equatable, Sendable {
    let id: String
    let date: Date
    let value: Double
    let segment: Int
}
