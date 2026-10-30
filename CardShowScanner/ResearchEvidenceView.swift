import SwiftUI
import Charts

/// Currency and sales counts use separate charts and retain their own units.
struct ResearchEvidenceView: View {
    let grade: ResearchGrade
    @State private var range: ResearchHistoryRange = .quarter
    @State private var selectedDate: Date?
    private var evidence: ResearchEvidence { ResearchEvidence(history: grade.dailyHistory, range: range) }

    var body: some View {
        Section("Evidence for this grade") {
            Picker("History period", selection: $range) {
                ForEach(ResearchHistoryRange.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).accessibilityIdentifier("research.historyPeriod")
            LabeledContent("Reported days in this period") {
                Text(evidence.points.count.formatted()).accessibilityIdentifier("research.evidenceDays")
            }
            LabeledContent("Days with a sold average") {
                Text(evidence.priceDayCount.formatted()).accessibilityIdentifier("research.evidencePriceDays")
            }
            LabeledContent("Days with a sales count") {
                Text(evidence.countDayCount.formatted()).accessibilityIdentifier("research.evidenceCountDays")
            }
            LabeledContent("Sales in returned days") {
                Text(evidence.knownSalesTotal?.formatted() ?? "Unavailable").accessibilityIdentifier("research.evidenceSales")
            }
            if let last = evidence.points.last {
                LabeledContent("Latest returned history day", value: last.day)
            }
            if let rating = grade.confidence {
                LabeledContent("Provider-rated evidence", value: "\(rating) of 5")
            }
            Text("The provider’s rating is not a measured probability. The Research API is in testing; these observations may cover only part of the market.")
                .font(.caption).foregroundStyle(.secondary)
            if evidence.countsArePartial {
                Text("Some returned days have no sales count. The sum includes only known counts and is not a complete period total.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if evidence.duplicateDayCount > 0 {
                Text("\(evidence.duplicateDayCount.formatted()) duplicate history dates were omitted because their daily values are ambiguous.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if evidence.futureRowCount > 0 {
                Text("\(evidence.futureRowCount.formatted()) future-dated history rows were omitted.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Periods use calendar days ending today in UTC. Missing dates and values stay missing; a reported zero stays zero.")
                .font(.caption).foregroundStyle(.secondary)
        }.accessibilityIdentifier("research.evidence")

        Section("Daily sold average • USD") {
            if evidence.priceMarks.isEmpty {
                Text("No recorded sold averages in this period.").foregroundStyle(.secondary)
            } else {
                priceChart.frame(height: 200)
            }
            Text("Each point is the provider’s average for one reported day, not an individual sale. Lines connect consecutive reported days only.")
                .font(.caption).foregroundStyle(.secondary)
        }

        Section("Daily recorded sales") {
            if evidence.countDayCount == 0 {
                Text("No recorded sales counts in this period.").foregroundStyle(.secondary)
            } else {
                salesChart.frame(height: 170)
            }
            if let selectedDate, let point = evidence.point(nearest: selectedDate) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(point.day).font(.subheadline.bold())
                    LabeledContent("Recorded sales", value: point.sales?.formatted() ?? "Unavailable")
                    LabeledContent("Sold average", value: point.average?.money ?? "Unavailable")
                }.font(.caption).accessibilityElement(children: .combine)
                    .accessibilityIdentifier("research.historySelection")
            }
            Text("Tap or drag across a chart to inspect a reported day. Gaps do not establish that no sales occurred.")
                .font(.caption).foregroundStyle(.secondary)
            DisclosureGroup("View reported daily values") {
                ForEach(Array(evidence.points.suffix(30).reversed()), id: \.day) { point in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(point.day).font(.caption.bold())
                        Text("Sales: \(point.sales?.formatted() ?? "Unavailable") • Sold average: \(point.average?.money ?? "Unavailable")")
                            .font(.caption).foregroundStyle(.secondary)
                    }.accessibilityElement(children: .combine)
                }
                if evidence.points.count > 30 {
                    Text("Showing the latest 30 of \(evidence.points.count.formatted()) returned days in this period.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.accessibilityIdentifier("research.historyValues")
        }
        .onChange(of: range) { _, _ in selectedDate = nil }
    }

    private var priceChart: some View {
        Chart {
            ForEach(evidence.priceMarks) { point in
                LineMark(x: .value("Reported day", point.date), y: .value("Sold average USD", point.value),
                         series: .value("Reporting segment", point.segment))
                    .foregroundStyle(.blue)
                PointMark(x: .value("Reported day", point.date), y: .value("Sold average USD", point.value))
                    .foregroundStyle(.blue).symbolSize(24)
                    .accessibilityLabel(Text(point.id))
                    .accessibilityValue(Text(point.value.formatted(.currency(code: "USD"))))
            }
            if let selectedDate, let point = evidence.point(nearest: selectedDate) {
                RuleMark(x: .value("Selected day", point.date)).foregroundStyle(.secondary)
            }
        }
        .chartXScale(domain: evidence.domain)
        .chartYScale(domain: .automatic(includesZero: true))
        .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) }
        .chartYAxisLabel("USD")
        .chartXSelection(value: $selectedDate)
        .environment(\.timeZone, TimeZone(secondsFromGMT: 0)!)
        .accessibilityLabel("Daily recorded sold average in US dollars")
        .accessibilityIdentifier("research.historyChart")
    }

    private var salesChart: some View {
        Chart {
            ForEach(evidence.points, id: \.day) { point in
                if let count = point.sales {
                    BarMark(x: .value("Reported day", point.date, unit: .day), y: .value("Recorded sales", count))
                        .foregroundStyle(.teal)
                        .accessibilityLabel(Text(point.day))
                        .accessibilityValue(Text("\(count.formatted()) recorded sales"))
                }
            }
            if let selectedDate, let point = evidence.point(nearest: selectedDate) {
                RuleMark(x: .value("Selected day", point.date)).foregroundStyle(.secondary)
            }
        }
        .chartXScale(domain: evidence.domain)
        .chartYScale(domain: .automatic(includesZero: true))
        .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) }
        .chartYAxisLabel("Sales")
        .chartXSelection(value: $selectedDate)
        .environment(\.timeZone, TimeZone(secondsFromGMT: 0)!)
        .accessibilityLabel("Daily recorded sales counts")
        .accessibilityIdentifier("research.salesHistoryChart")
    }
}
