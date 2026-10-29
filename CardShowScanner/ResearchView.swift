import SwiftUI
import Charts

/// Read-only research for an explicitly selected catalog card and grade.
struct ResearchView: View {
    @State private var model: ResearchModel

    init(card: CardCandidate, grader: String = "RAW", grade: String = "Raw",
         provider: any ResearchProviding = ConfiguredResearchProvider()) {
        _model = State(initialValue: ResearchModel(card: card, provider: provider, grader: grader, grade: grade))
    }

    var body: some View {
        List {
            cardSection
            if model.loading {
                Section { ProgressView("Loading research…").accessibilityIdentifier("research.status") }
            }
            if let message = model.message { errorSection(message) }
            if model.details != nil {
                selectionSection
                if let message = model.selectionMessage {
                    Section { Text(message).foregroundStyle(.secondary).accessibilityIdentifier("research.status") }
                }
                if let grade = model.selectedGrade {
                    activitySection(grade)
                    gradeSection(grade)
                    valuationSection(grade)
                    lastSaleSection(grade)
                    if let history = grade.dailyHistory, !history.series.isEmpty {
                        Section("Recorded daily history") { ResearchHistoryChart(points: history.series) }
                    }
                }
                sourceSection
            }
        }
        .navigationTitle("Research & Demand")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(model.loading).accessibilityLabel("Refresh research")
                    .accessibilityIdentifier("research.refresh")
                NavigationLink { ResearchConnectionView() } label: { Image(systemName: "gearshape") }
                    .accessibilityLabel("Research connection").accessibilityIdentifier("research.connection")
            }
        }
        .onAppear { model.refresh(forceRefresh: false) }
        .onDisappear { model.cancel() }
    }

    private var cardSection: some View {
        Section {
            HStack(alignment: .top, spacing: 16) {
                AsyncImage(url: model.details?.product.imageURL ?? model.card.imageURL) { image in
                    image.resizable().scaledToFit()
                } placeholder: {
                    RoundedRectangle(cornerRadius: 6).fill(.quaternary)
                        .overlay { Image(systemName: "rectangle.portrait").font(.largeTitle).foregroundStyle(.secondary) }
                }
                .frame(width: 110, height: 154).clipShape(RoundedRectangle(cornerRadius: 6))
                .accessibilityLabel("Card preview for " + model.card.name)
                VStack(alignment: .leading, spacing: 7) {
                    Text(model.details?.product.name ?? model.card.name).font(.headline)
                    Text(model.details?.meta.setName ?? model.card.set).font(.subheadline)
                    Text(model.details?.product.number ?? model.card.number).font(.subheadline).foregroundStyle(.secondary)
                    Text(model.card.identity.game).font(.caption).foregroundStyle(.secondary)
                }
            }.padding(.vertical, 4)
        }.accessibilityIdentifier("research.card")
    }

    private func errorSection(_ message: String) -> some View {
        Section("Research unavailable") {
            Text(message).foregroundStyle(.secondary).accessibilityIdentifier("research.status")
            Button("Retry Research") { model.refresh() }.disabled(model.loading).accessibilityIdentifier("research.retry")
            NavigationLink("Research Connection") { ResearchConnectionView() }
        }
    }

    private var selectionSection: some View {
        Section("Research selection") {
            Picker("Language / printing", selection: Binding(get: { model.selectedVariantKey ?? "" }, set: {
                if !$0.isEmpty { model.selectVariant($0) }
            })) {
                if model.selectedVariantKey == nil { Text("Choose a variant").tag("") }
                ForEach(model.variantKeys, id: \.self) { key in Text(variantLabel(key)).tag(key) }
            }.pickerStyle(.menu).accessibilityIdentifier("research.variant")
            Picker("Grader / grade", selection: Binding(get: { selectedGradeChoice }, set: {
                model.selectGrade(grader: $0.grader, grade: $0.grade)
            })) {
                if !gradeChoices.contains(selectedGradeChoice) {
                    Text(selectedGradeChoice.grade.isEmpty ? "Choose a returned research grade" : selectedGradeChoice.label + " • unavailable")
                        .tag(selectedGradeChoice)
                }
                ForEach(gradeChoices) { choice in Text(choice.label).tag(choice) }
            }.pickerStyle(.menu).disabled(model.selectedVariant == nil)
                .accessibilityIdentifier("research.grade")
            if model.selectedGrader == "RAW" {
                Text("Raw research is grouped by printing and language. Card condition is not represented in these research values.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func activitySection(_ grade: ResearchGrade) -> some View {
        let month = grade.dailyHistory?.stats?.month
        return Section("Past 30 days") {
            LabeledContent("Recorded sales", value: count(month?.sales))
                .accessibilityIdentifier("research.sales30d")
            LabeledContent("Sold average", value: money(month?.average))
                .accessibilityIdentifier("research.average30d")
            LabeledContent("Recorded low", value: money(month?.low))
            LabeledContent("Recorded high", value: money(month?.high))
            Text("Recorded sales describe past activity. Missing values remain unavailable.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func gradeSection(_ grade: ResearchGrade) -> some View {
        Section(ResearchGradeChoice(grader: grade.grader, grade: grade.grade).label) {
            LabeledContent("Total historical sales", value: count(grade.sales))
            if grade.grader != "RAW" {
                LabeledContent("Population at this grade", value: count(grade.population))
                    .accessibilityIdentifier("research.population")
            }
            LabeledContent("Provider confidence", value: grade.confidence.map { "\($0) of 5" } ?? "Unavailable")
            if let date = grade.lastSoldAt { LabeledContent("Latest recorded sale date", value: dateLabel(date)) }
        }
    }

    private func valuationSection(_ grade: ResearchGrade) -> some View {
        Section("Research valuation") {
            LabeledContent("Guide estimate", value: money(grade.guideValue))
                .accessibilityIdentifier("research.guideEstimate")
            LabeledContent("Research market value", value: money(grade.marketValue))
                .accessibilityIdentifier("research.marketValue")
            Text("Guide value is a blended valuation estimate. Provider market value is a separate research field.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func lastSaleSection(_ grade: ResearchGrade) -> some View {
        Section("Last recorded sale") {
            LabeledContent("Recorded sale price", value: money(grade.dailyHistory?.stats?.lastSale?.price))
            LabeledContent("History sale date", value: (grade.dailyHistory?.stats?.lastSale?.date).map(dateLabel) ?? "Unavailable")
        }
    }

    private var sourceSection: some View {
        Section("Data source") {
            Text(model.details?.meta.status == "in_testing" ? "TCGTracking Research • In testing" : "TCGTracking Research")
                .font(.subheadline)
            LabeledContent("Data generated", value: (model.details?.meta.generatedAt).map(dateLabel) ?? "Unavailable")
            if let date = model.selectedVariant?.updatedAt { LabeledContent("Variant updated", value: dateLabel(date)) }
            if let date = model.selectedGrade?.syncedOn { LabeledContent("Grade synced", value: dateLabel(date)) }
            if let date = model.selectedGrade?.dailyHistory?.updatedAt { LabeledContent("History updated", value: dateLabel(date)) }
            Text("The provider can update research at most once per hour. Research is displayed separately from saved card prices and offers.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var selectedGradeChoice: ResearchGradeChoice {
        ResearchGradeChoice(grader: model.selectedGrader, grade: model.selectedGradeLabel)
    }
    private var gradeChoices: [ResearchGradeChoice] {
        Array(Set(model.availableGrades.map { ResearchGradeChoice(grader: $0.grader, grade: $0.grade) })).sorted {
            if $0.grader != $1.grader { return $0.grader < $1.grader }
            return $0.grade.localizedStandardCompare($1.grade) == .orderedAscending
        }
    }
    private func variantLabel(_ key: String) -> String {
        guard let variant = model.details?.product.variants[key] else { return key }
        return variant.language + " • " + variant.finish
    }
    private func money(_ value: Decimal?) -> String { value?.money ?? "Unavailable" }
    private func count(_ value: Int?) -> String { value?.formatted() ?? "Unavailable" }
    private func dateLabel(_ text: String) -> String {
        // DATE fields carry no time zone. Keep the reported calendar day intact.
        if text.count == 10 { return text }
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: text) { return date.formatted(date: .abbreviated, time: .shortened) }
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter.date(from: text)?.formatted(date: .abbreviated, time: .shortened) ?? text
    }
}

private struct ResearchGradeChoice: Hashable, Identifiable {
    let grader: String
    let grade: String
    var id: Self { self }
    var label: String { grader == "RAW" && grade == "Raw" ? "Raw (ungraded)" : grader + " " + grade }
}

/// Each mark represents one returned daily aggregate. Gaps are never filled.
private struct ResearchHistoryChart: View {
    enum Metric: String, CaseIterable, Identifiable {
        case sales = "Sales", average = "Sold average"
        var id: String { rawValue }
    }
    let points: [ResearchDailyPoint]
    @State private var metric: Metric = .sales
    @State private var selectedDate: Date?
    private var displayed: [ResearchDailyPoint] { Array(points.suffix(90)) }
    private var hasValues: Bool {
        displayed.contains { metric == .sales ? $0.sales != nil : $0.average != nil }
    }
    private var selectedPoint: ResearchDailyPoint? {
        guard let selectedDate else { return nil }
        return displayed.filter { metric == .sales ? $0.sales != nil : $0.average != nil }
            .min { abs($0.date.timeIntervalSince(selectedDate)) < abs($1.date.timeIntervalSince(selectedDate)) }
            .flatMap { abs($0.date.timeIntervalSince(selectedDate)) <= 43_200 ? $0 : nil }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("History metric", selection: $metric) {
                ForEach(Metric.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).accessibilityIdentifier("research.historyMetric")
            if hasValues { historyChart.frame(height: 220) }
            else { Text("No recorded \(metric == .sales ? "sales counts" : "sold averages") in this history.").foregroundStyle(.secondary) }
            if let point = selectedPoint {
                HStack {
                    Text(point.day)
                    Spacer()
                    Text(metric == .sales ? point.sales.map { "\($0.formatted()) recorded sales" } ?? "Unavailable" : point.average?.money ?? "Unavailable")
                }.font(.caption).accessibilityElement(children: .combine)
            }
            Text("Up to 90 reported days. Missing dates are omitted. Tap or drag to inspect a reported day.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private var historyChart: some View {
        Chart {
            if metric == .sales {
                ForEach(Array(displayed.enumerated()), id: \.offset) { _, point in
                    if let count = point.sales {
                        BarMark(x: .value("Recorded day", point.date, unit: .day), y: .value("Recorded sales", count))
                    }
                }
            } else {
                ForEach(priceMarks) { point in
                    LineMark(x: .value("Recorded day", point.date), y: .value("Sold average USD", point.value),
                             series: .value("Reporting segment", point.segment))
                    PointMark(x: .value("Recorded day", point.date), y: .value("Sold average USD", point.value))
                        .symbolSize(18)
                }
            }
            if let point = selectedPoint { RuleMark(x: .value("Selected day", point.date)).foregroundStyle(.secondary) }
        }
        .chartXSelection(value: $selectedDate)
        .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) }
        .chartYAxisLabel(metric == .sales ? "Recorded sales" : "Sold average (USD)")
        .environment(\.timeZone, TimeZone(secondsFromGMT: 0)!)
        .accessibilityLabel(metric == .sales ? "Daily recorded sales" : "Daily recorded sold average in US dollars")
        .accessibilityIdentifier("research.historyChart")
    }
    private var priceMarks: [ResearchPriceMark] {
        var result: [ResearchPriceMark] = []
        var segment = 0
        var previous: Date?
        for (offset, point) in displayed.enumerated() {
            guard let average = point.average else { segment += 1; previous = nil; continue }
            if let previous, point.date.timeIntervalSince(previous) > 86_401 { segment += 1 }
            result.append(ResearchPriceMark(id: offset, date: point.date,
                value: NSDecimalNumber(decimal: average).doubleValue, segment: segment))
            previous = point.date
        }
        return result
    }
}

private struct ResearchPriceMark: Identifiable {
    let id: Int
    let date: Date
    let value: Double
    let segment: Int
}
