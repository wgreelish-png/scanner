import SwiftUI
import Charts

/// The documented Opp V2 windows, shown as separate price and daily-volume
/// comparisons. These overlapping summaries are not calendar price history.
struct MarketActivityChartsView: View {
    let sku: OpportunitiesSKU
    @Binding var selectedWindow: Int
    var salesUpdatedAt: String? = nil
    @State private var inspectedPeriod: String?

    private var presentation: MarketActivityPresentation { MarketActivityPresentation(sku: sku) }
    private var periods: [MarketActivityPeriod] {
        presentation.periods.filter { selectedWindow == 365 || $0.windowDays != 365 }
    }
    private var volumePoints: [MarketActivityVolumePoint] {
        presentation.volumePoints.filter { selectedWindow == 365 || $0.windowDays != 365 }
    }
    private var inspected: MarketActivityPeriod? { periods.first { $0.label == inspectedPeriod } }
    private var periodSelection: Binding<String?> {
        Binding(get: { inspectedPeriod }, set: { if let value = $0 { inspectedPeriod = value } })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 7) {
                Text("Average price by window · USD").font(.subheadline.weight(.semibold))
                if let window = presentation.periods.first(where: { $0.windowDays == selectedWindow }) {
                    LabeledContent {
                        Text(window.displayPrice?.money ?? "Unavailable").monospacedDigit()
                            .accessibilityIdentifier("marketActivity.averagePrice")
                    } label: {
                        Text("TCGplayer · " + basisTitle(window.priceBasis))
                            .accessibilityIdentifier("marketActivity.priceBasis")
                    }.font(.caption)
                }
                if periods.contains(where: { $0.displayPrice != nil || $0.manapoolAverage != nil }) {
                    priceChart.frame(height: 205)
                } else {
                    Text("No price averages were returned for these windows.").foregroundStyle(.secondary)
                }
                HStack(spacing: 12) {
                    legend("Sold average", color: .indigo)
                    legend("Market fallback", color: .orange)
                }
                if periods.contains(where: { $0.manapoolAverage != nil }) {
                    legend("Manapool sold average", color: .teal)
                }
            }
            VStack(alignment: .leading, spacing: 7) {
                Text("Average reported units per day").font(.subheadline.weight(.semibold))
                if let window = presentation.periods.first(where: { $0.windowDays == selectedWindow }) {
                    LabeledContent("TCGplayer · " + window.label) {
                        Text(unitsPerDay(window.tcgUnitsPerDay)).monospacedDigit()
                            .accessibilityIdentifier("marketActivity.windowUnitsPerDay")
                    }.font(.caption)
                }
                if volumePoints.isEmpty {
                    Text("No quantities were returned for these windows.").foregroundStyle(.secondary)
                } else {
                    volumeChart.frame(height: 185)
                }
            }
            if let inspected { selectionCard(inspected) }
            Text("Tap or drag across either chart to inspect a window. Select 1 year to add annual context. The windows overlap; daily rates compare different lengths without adding their totals.")
                .font(.caption).foregroundStyle(.secondary)
            DisclosureGroup("View all reported window values") {
                ForEach(presentation.periods) { period in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(period.label).font(.subheadline.weight(.semibold))
                        LabeledContent("TCGplayer reported units", value: period.tcgQuantity.map { $0.formatted() } ?? "Unavailable")
                        LabeledContent("Average units / day", value: unitsPerDay(period.tcgUnitsPerDay))
                        LabeledContent("Sold average", value: period.soldAverage?.money ?? "Unavailable")
                        LabeledContent("Market average", value: period.marketAverage?.money ?? "Unavailable")
                        if let value = period.soldAverageWithShipping {
                            LabeledContent("Sold average with shipping", value: value.money)
                        }
                        if let quantity = period.manapoolQuantity {
                            LabeledContent("Manapool reported units", value: quantity.formatted())
                            LabeledContent("Manapool units / day", value: unitsPerDay(period.manapoolUnitsPerDay))
                        }
                        if let average = period.manapoolAverage {
                            LabeledContent("Manapool sold average", value: average.money)
                        }
                    }.font(.caption).padding(.vertical, 4)
                        .accessibilityIdentifier("marketActivity.values.\(period.windowDays)")
                }
                Text("A missing sold average stays unavailable. The chart separately labels a returned market average when the provider’s fallback is used. Units per day are reported units divided by the window length, not a prediction of sale speed.")
                    .font(.caption).foregroundStyle(.secondary)
            }.accessibilityIdentifier("marketActivity.values")
        }
        .onChange(of: sku) { _, _ in inspectedPeriod = nil }
        .onChange(of: selectedWindow) { _, _ in inspectedPeriod = nil }
    }

    private var priceChart: some View {
        Chart {
            ForEach(periods) { period in
                if let price = period.displayPrice, let basis = period.priceBasis {
                    LineMark(x: .value("Reporting window", period.label), y: .value("Average USD", double(price)),
                             series: .value("Marketplace", "TCGplayer"))
                        .foregroundStyle(.indigo)
                    PointMark(x: .value("Reporting window", period.label), y: .value("Average USD", double(price)))
                        .foregroundStyle(basis == .marketAverage ? Color.orange : Color.indigo)
                        .symbolSize(46)
                        .accessibilityLabel("TCGplayer \(period.label) · \(basisTitle(basis))")
                        .accessibilityValue(price.money)
                }
                if let average = period.manapoolAverage {
                    LineMark(x: .value("Reporting window", period.label), y: .value("Average USD", double(average)),
                             series: .value("Marketplace", "Manapool"))
                        .foregroundStyle(.teal).lineStyle(StrokeStyle(dash: [4, 3]))
                    PointMark(x: .value("Reporting window", period.label), y: .value("Average USD", double(average)))
                        .foregroundStyle(.teal).symbolSize(36)
                        .accessibilityLabel("Manapool \(period.label) sold average")
                        .accessibilityValue(average.money)
                }
            }
            if let inspected {
                RuleMark(x: .value("Selected window", inspected.label)).foregroundStyle(.secondary)
                    .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(inspected.label).font(.caption.bold())
                            Text("TCGplayer: " + (inspected.displayPrice?.money ?? "Unavailable")).font(.caption.monospacedDigit())
                            Text(basisTitle(inspected.priceBasis)).font(.caption2).foregroundStyle(.secondary)
                            if let average = inspected.manapoolAverage {
                                Text("Manapool sold: " + average.money).font(.caption.monospacedDigit())
                            }
                        }.padding(7).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    }
            }
        }
        .chartXScale(domain: periods.map(\.label))
        .chartYScale(domain: 0...priceUpperBound)
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let amount = value.as(Double.self) { Text(amount.formatted(.currency(code: "USD"))) }
                }
            }
        }
        .chartXSelection(value: periodSelection)
        .accessibilityLabel("Average price comparison across overlapping sales windows")
        .accessibilityHint("Touch and drag to inspect the price, price basis and reporting window. Reported values are also available below.")
        .accessibilityIdentifier("marketActivity.priceChart")
    }

    private var volumeChart: some View {
        Chart {
            ForEach(volumePoints) { point in
                BarMark(x: .value("Reporting window", label(for: point.windowDays)),
                        y: .value("Average units per day", point.unitsPerDay))
                    .foregroundStyle(by: .value("Marketplace", point.source))
                    .position(by: .value("Marketplace", point.source))
                    .accessibilityLabel("\(point.source) · \(point.windowDays) days")
                    .accessibilityValue("\(point.quantity.formatted()) reported units; \(unitsPerDay(point.unitsPerDay)) units per day")
            }
            if let inspected {
                RuleMark(x: .value("Selected window", inspected.label)).foregroundStyle(.secondary)
                    .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(inspected.label).font(.caption.bold())
                            Text("TCGplayer: \(unitsPerDay(inspected.tcgUnitsPerDay)) / day").font(.caption)
                            if inspected.manapoolQuantity != nil {
                                Text("Manapool: \(unitsPerDay(inspected.manapoolUnitsPerDay)) / day").font(.caption)
                            }
                        }.padding(7).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    }
            }
        }
        .chartXScale(domain: periods.map(\.label))
        .chartYScale(domain: 0...volumeUpperBound)
        .chartForegroundStyleScale(["TCGplayer": Color.blue, "Manapool": Color.teal])
        .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) }
        .chartYAxisLabel("Units / day")
        .chartXSelection(value: periodSelection)
        .accessibilityLabel("Reported sales normalized to average units per day")
        .accessibilityHint("Touch and drag to inspect a window’s original quantity and calculated daily rate.")
        .accessibilityIdentifier("marketActivity.volumeChart")
    }

    private func selectionCard(_ period: MarketActivityPeriod) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(period.label).font(.subheadline.bold()).accessibilityIdentifier("marketActivity.selectedPeriod")
                Spacer()
                Button("Clear") { inspectedPeriod = nil }.font(.caption)
                    .accessibilityLabel("Clear chart selection")
            }
            LabeledContent {
                Text(period.displayPrice?.money ?? "Unavailable").monospacedDigit()
            } label: {
                Text("TCGplayer · " + basisTitle(period.priceBasis)).accessibilityIdentifier("marketActivity.selectedPriceBasis")
            }
            LabeledContent("TCGplayer reported units") {
                Text(period.tcgQuantity.map { $0.formatted() } ?? "Unavailable")
                    .accessibilityIdentifier("marketActivity.selectedQuantity")
            }
            LabeledContent("Average units / day") {
                Text(unitsPerDay(period.tcgUnitsPerDay)).monospacedDigit().accessibilityIdentifier("marketActivity.unitsPerDay")
            }
            if let average = period.manapoolAverage {
                LabeledContent("Manapool sold average", value: average.money)
            }
            if period.manapoolQuantity != nil || period.manapoolAverage != nil {
                LabeledContent("Manapool reported units", value: period.manapoolQuantity.map { $0.formatted() } ?? "Unavailable")
                LabeledContent("Manapool units / day", value: unitsPerDay(period.manapoolUnitsPerDay))
            }
            Text(salesUpdateLabel).foregroundStyle(.secondary)
        }.font(.caption).padding(10).background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            .accessibilityElement(children: .contain).accessibilityIdentifier("marketActivity.selection")
    }

    private var priceUpperBound: Double {
        let prices = periods.flatMap { [$0.displayPrice, $0.manapoolAverage].compactMap { $0 }.map(double) }
        return max(1, (prices.max() ?? 0) * 1.15)
    }
    private var volumeUpperBound: Double { max(0.1, (volumePoints.map(\.unitsPerDay).max() ?? 0) * 1.15) }
    private var salesUpdateLabel: String {
        guard let date = MarketEvidence.timestamp(salesUpdatedAt) else { return "Sales update time unavailable" }
        return "Sales data updated " + date.formatted(date: .abbreviated, time: .shortened)
    }
    private func label(for days: Int) -> String { presentation.periods.first { $0.windowDays == days }?.label ?? "\(days) days" }
    private func double(_ price: Decimal) -> Double { NSDecimalNumber(decimal: price).doubleValue }
    private func basisTitle(_ basis: MarketActivityPriceBasis?) -> String {
        switch basis {
        case .soldAverage: return "Sold average"
        case .marketAverage: return "Market average · fallback"
        case nil: return "Price average unavailable"
        }
    }
    private func legend(_ title: String, color: Color) -> some View {
        Label { Text(title).font(.caption2) } icon: { Circle().fill(color).frame(width: 7, height: 7) }
    }
    private func unitsPerDay(_ value: Double?) -> String {
        guard let value else { return "Unavailable" }
        if value == 0 { return "0" }
        if value >= 1 { return value.formatted(.number.precision(.fractionLength(0...1))) }
        if value >= 0.1 { return value.formatted(.number.precision(.fractionLength(0...2))) }
        return value.formatted(.number.precision(.significantDigits(1...3)))
    }
}

/// Interactive benchmark chart; the parent retains every row, including missing
/// references, so a missing value is never rendered as a zero-price opportunity.
struct MarketBenchmarkChartView: View {
    let benchmarks: [MarketActivityBenchmark]
    @State private var selectedReference: String?
    private var points: [MarketActivityBenchmark] { benchmarks.filter { $0.value != nil } }
    private var selected: MarketActivityBenchmark? { points.first { $0.label == selectedReference } }
    private var selection: Binding<String?> {
        Binding(get: { selectedReference }, set: { if let value = $0 { selectedReference = value } })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if points.isEmpty {
                Text("No reference prices were returned.").foregroundStyle(.secondary)
            } else {
                Chart {
                    ForEach(points) { point in
                        if let value = point.value {
                            BarMark(x: .value("USD", NSDecimalNumber(decimal: value).doubleValue),
                                    y: .value("Reference", point.label))
                                .foregroundStyle(point.includesShipping ? Color.teal : Color.indigo)
                                .accessibilityLabel(point.label).accessibilityValue(value.money)
                        }
                    }
                    if let selected {
                        RuleMark(y: .value("Selected reference", selected.label)).foregroundStyle(.secondary)
                    }
                }
                .chartXScale(domain: 0...upperBound)
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) }
                .chartYAxis {
                    AxisMarks { value in
                        AxisValueLabel {
                            if let name = value.as(String.self) { Text(name).font(.caption2).lineLimit(2) }
                        }
                    }
                }
                .chartXAxisLabel("USD")
                .chartYSelection(value: selection)
                .frame(height: CGFloat(points.count) * 35 + 36)
                .accessibilityLabel("Marketplace costs and reference prices in US dollars")
                .accessibilityHint("Touch and drag vertically to inspect a reference price. All reference values are also listed below.")
                .accessibilityIdentifier("marketActivity.benchmarkChart")
            }
            if let selected {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(selected.label).font(.caption.bold())
                        Text(selected.value?.money ?? "Unavailable").font(.subheadline.monospacedDigit())
                        Text(selected.includesShipping ? "Includes shipping" : "Card price reference").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Clear") { selectedReference = nil }.font(.caption).accessibilityLabel("Clear benchmark selection")
                }.padding(8).background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityElement(children: .contain).accessibilityIdentifier("marketActivity.benchmarkSelection")
            }
        }.onChange(of: benchmarks.map { $0.id + "|" + ($0.value?.description ?? "nil") }) { _, _ in selectedReference = nil }
    }
    private var upperBound: Double {
        max(1, (points.compactMap(\.value).map { NSDecimalNumber(decimal: $0).doubleValue }.max() ?? 0) * 1.12)
    }
}
