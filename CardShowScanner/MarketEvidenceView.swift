import SwiftUI
import Charts

/// Visual evidence for the exact selection; never writes a quote or invents a score.
struct MarketEvidenceView: View {
    let publicDetails: MarketDetails?
    let activity: OpportunitiesDetails?
    let publicLoading: Bool
    let activityLoading: Bool
    @State private var selectedWindow = 30
    @State private var inspectedPrice: String?
    @State private var inspectedMarketplace: String?

    private var evidence: MarketEvidence {
        MarketEvidence(publicDetails: publicDetails, activity: activity)
    }

    var body: some View {
        Group {
            summarySection
            if !evidence.priceComparisons.isEmpty { comparisonSection }
            if activity != nil { volumeSection }
        }
        .onChange(of: evidence.priceComparisons) { _, _ in inspectedPrice = nil }
        .onChange(of: evidence.volumePoints) { _, _ in inspectedMarketplace = nil }
        .onChange(of: selectedWindow) { _, _ in inspectedMarketplace = nil }
    }

    private var summarySection: some View {
        Section("Evidence at a glance") {
            VStack(alignment: .leading, spacing: 14) {
                matchFact
                fact("Public price data", value: priceAvailability,
                     detail: publicDetails?.metadata?.isOffline == true ? "Using an offline cached response." : publicCacheLabel,
                     symbol: "tag")
                freshnessFact("Public price updated", date: publicDetails?.metadata?.updatedAt)
                if let activity {
                    freshnessFact("Activity data generated", date: MarketEvidence.timestamp(activity.meta.generatedAt))
                    freshnessFact("TCGplayer sales updated", date: MarketEvidence.timestamp(activity.sku.timestamps?.tcgSalesUpdatedAt))
                    fact("30-day TCGplayer volume", value: activity.sku.trends?.windows["30d"]?.tcgQuantity.map { $0.formatted() + " reported units" } ?? "Quantity unavailable",
                         detail: "Reported units describe past activity; they are not a count of independent price observations.", symbol: "shippingbox")
                    fact("30-day sold-price evidence", value: activity.sku.trends?.windows["30d"]?.tcgSoldAverage?.money ?? "Sold average unavailable",
                         detail: "Uses the explicit sold-average field. A market-price average never fills a missing sold average.", symbol: "receipt")
                } else {
                    fact("Sales evidence", value: activityLoading ? "Loading…" : "Market activity unavailable",
                         detail: "Missing coverage does not mean zero sales.", symbol: "chart.bar")
                }
            }
            .padding(.vertical, 4)
            Text("These are supporting facts, not a confidence percentage. Both services use TCGTracking data and are not independent price checks. A recent dataset can contain older sales and listings.")
                .font(.caption).foregroundStyle(.secondary)
        }.accessibilityIdentifier("marketEvidence.summary")
    }

    @ViewBuilder private var matchFact: some View {
        switch evidence.skuAgreement {
        case .same:
            fact("Exact selection", value: "Matching SKU across services",
                 detail: "Printing, language and condition were matched before displaying this data.", symbol: "checkmark.seal")
        case .different:
            fact("Verify the SKU", value: "Services returned different SKU identifiers",
                 detail: "Cross-service prices are not compared. Check the matched identifiers below.", symbol: "exclamationmark.triangle", tint: .orange)
        case .unavailable:
            fact("Exact selection", value: "Cross-service SKU check unavailable",
                 detail: "A comparison needs an exact SKU from both services. Each available source is shown with its own coverage.", symbol: "info.circle")
        }
    }

    private var priceAvailability: String {
        if publicLoading { return "Loading…" }
        return publicDetails?.quote?.marketPrice == nil ? "Market price unavailable" : "Exact-condition quote available"
    }

    private var publicCacheLabel: String {
        guard let metadata = publicDetails?.metadata else { return "Provider update time and retrieval time are separate." }
        let state = metadata.isCached == true ? "Cached response" : "Response retrieved"
        return state + " • " + metadata.fetchedAt.formatted(date: .abbreviated, time: .shortened)
    }

    private var comparisonSection: some View {
        Section("Price comparison • USD") {
            Chart {
                ForEach(evidence.priceComparisons) { point in
                    BarMark(x: .value("USD", NSDecimalNumber(decimal: point.price).doubleValue),
                            y: .value("Price reference", point.label))
                        .foregroundStyle(color(for: point.kind))
                        .accessibilityLabel(point.label)
                        .accessibilityValue(point.price.money)
                }
                if let point = inspectedPricePoint {
                    RuleMark(y: .value("Selected reference", point.label)).foregroundStyle(.secondary)
                }
            }
            .chartYAxis {
                AxisMarks { value in
                    AxisValueLabel {
                        if let label = value.as(String.self) {
                            Text(label).font(.caption2).lineLimit(3)
                                .frame(maxWidth: 105, alignment: .trailing)
                        }
                    }
                }
            }
            .chartXAxis { AxisMarks(position: .bottom, values: .automatic(desiredCount: 4)) }
            .chartXAxisLabel("USD • bars start at zero")
            .chartXScale(domain: 0...priceUpperBound)
            .chartYSelection(value: priceSelection)
            .accessibilityHint("Touch and drag vertically to inspect a reference. All values are also listed below.")
            .frame(height: CGFloat(max(1, evidence.priceComparisons.count)) * 48 + 42)
            .accessibilityLabel("Market, sold-average and listing price references in US dollars")
            .accessibilityIdentifier("marketEvidence.priceChart")
            if let point = inspectedPricePoint {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(point.label).font(.caption.bold())
                        Spacer()
                        Button("Clear") { inspectedPrice = nil }.font(.caption).accessibilityLabel("Clear price reference selection")
                    }
                    Text(point.price.money).font(.subheadline.monospacedDigit())
                    Text(priceUpdateLabel(point)).font(.caption).foregroundStyle(.secondary)
                }.padding(8).background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityElement(children: .contain).accessibilityIdentifier("marketEvidence.priceSelection")
            }
            ForEach(evidence.priceComparisons) { point in
                LabeledContent {
                    Text(point.price.money).monospacedDigit()
                } label: {
                    Label(point.label, systemImage: symbol(for: point.kind))
                        .foregroundStyle(color(for: point.kind))
                }.font(.caption)
            }
            Text("Blue: market quotes. Purple: reported sold averages. Orange: asking prices without shipping. These are different measures; their agreement does not establish accuracy. Missing values are omitted, and a returned $0 remains $0.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var priceUpperBound: Double {
        let maximum = evidence.priceComparisons.map { NSDecimalNumber(decimal: $0.price).doubleValue }.max() ?? 0
        return max(1, maximum * 1.12)
    }

    private var selectedVolume: [MarketEvidence.VolumePoint] {
        evidence.volumePoints.filter { $0.windowDays == selectedWindow }
    }

    private var volumeSection: some View {
        Section("Reported sales volume") {
            volumePicker
            volumePlot
            volumeInspection
            volumeTotals
            Text("Bars show average units per day: the returned quantity divided by the selected window length. Each window ends at the provider’s reporting time. Windows overlap and must not be added together. Unknown quantities remain unavailable; returned zeroes remain zero. These rates do not predict your sale speed.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var volumePicker: some View {
        Picker("Reporting window", selection: $selectedWindow) {
            Text("30 days").tag(30)
            Text("90 days").tag(90)
            Text("365 days").tag(365)
        }.pickerStyle(.segmented).accessibilityIdentifier("marketEvidence.volumeWindow")
    }

    @ViewBuilder private var volumePlot: some View {
        if selectedVolume.isEmpty {
            Text("No quantities were returned for this window.").foregroundStyle(.secondary)
                .accessibilityIdentifier("marketEvidence.volumeEmpty")
        } else {
            volumeChart
        }
    }

    private var volumeChart: some View {
        Chart {
            ForEach(selectedVolume) { point in
                BarMark(x: .value("Marketplace", point.source),
                        y: .value("Average units per day", dailyRate(point)))
                    .foregroundStyle(point.source == "TCGplayer" ? Color.blue : Color.teal)
                    .accessibilityLabel(point.source + " • " + String(selectedWindow) + " days")
                    .accessibilityValue(volumeAccessibilityValue(point))
            }
            if let point = inspectedVolumePoint {
                RuleMark(x: .value("Selected marketplace", point.source)).foregroundStyle(.secondary)
            }
        }
        .chartXScale(domain: selectedVolume.map(\.source))
        .chartYScale(domain: 0...volumeUpperBound)
        .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) }
        .chartYAxisLabel("Units / day")
        .chartXSelection(value: marketplaceSelection)
        .frame(height: 180)
        .accessibilityHint("Touch and drag to inspect the original reported quantity and average daily units.")
        .accessibilityIdentifier("marketEvidence.volumeChart")
    }

    @ViewBuilder private var volumeInspection: some View {
        if let point = inspectedVolumePoint {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(point.source + " • " + String(selectedWindow) + " days").font(.caption.bold())
                    Spacer()
                    Button("Clear") { inspectedMarketplace = nil }.font(.caption)
                        .accessibilityLabel("Clear volume selection")
                }
                LabeledContent("Reported units", value: point.quantity.formatted())
                LabeledContent("Average units / day", value: dailyLabel(dailyRate(point)))
                Text(volumeUpdateLabel).foregroundStyle(.secondary)
            }.font(.caption).padding(8)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("marketEvidence.volumeSelection")
        }
    }

    @ViewBuilder private var volumeTotals: some View {
        LabeledContent("TCGplayer reported units") {
            Text(quantity(for: "TCGplayer")).monospacedDigit().accessibilityIdentifier("marketEvidence.tcgQuantity")
        }
        LabeledContent("TCGplayer average units / day") {
            Text(rate(for: "TCGplayer")).monospacedDigit().accessibilityIdentifier("marketEvidence.tcgUnitsPerDay")
        }
        LabeledContent("Manapool reported units") {
            Text(quantity(for: "Manapool")).monospacedDigit().accessibilityIdentifier("marketEvidence.mpQuantity")
        }
        LabeledContent("Manapool average units / day") {
            Text(rate(for: "Manapool")).monospacedDigit().accessibilityIdentifier("marketEvidence.mpUnitsPerDay")
        }
    }

    private var volumeUpdateLabel: String {
        let date = MarketEvidence.timestamp(activity?.sku.timestamps?.tcgSalesUpdatedAt)
        let updated = date?.formatted(date: .abbreviated, time: .shortened) ?? "time unavailable"
        return "Sales data updated " + updated
    }

    private func volumeAccessibilityValue(_ point: MarketEvidence.VolumePoint) -> String {
        point.quantity.formatted() + " reported units; " + dailyLabel(dailyRate(point)) + " units per day"
    }

    private var inspectedPricePoint: MarketEvidence.PricePoint? { evidence.priceComparisons.first { $0.label == inspectedPrice } }
    private var inspectedVolumePoint: MarketEvidence.VolumePoint? { selectedVolume.first { $0.source == inspectedMarketplace } }
    private var priceSelection: Binding<String?> {
        Binding(get: { inspectedPrice }, set: { if let value = $0 { inspectedPrice = value } })
    }
    private var marketplaceSelection: Binding<String?> {
        Binding(get: { inspectedMarketplace }, set: { if let value = $0 { inspectedMarketplace = value } })
    }
    private var volumeUpperBound: Double { max(0.1, (selectedVolume.map(dailyRate).max() ?? 0) * 1.15) }
    private func dailyRate(_ point: MarketEvidence.VolumePoint) -> Double { Double(point.quantity) / Double(point.windowDays) }
    private func dailyLabel(_ value: Double) -> String {
        if value == 0 { return "0" }
        if value >= 1 { return value.formatted(.number.precision(.fractionLength(0...1))) }
        if value >= 0.1 { return value.formatted(.number.precision(.fractionLength(0...2))) }
        return value.formatted(.number.precision(.significantDigits(1...3)))
    }
    private func quantity(for source: String) -> String {
        selectedVolume.first { $0.source == source }?.quantity.formatted() ?? "Unavailable"
    }
    private func rate(for source: String) -> String {
        selectedVolume.first { $0.source == source }.map { dailyLabel(dailyRate($0)) } ?? "Unavailable"
    }
    private func priceUpdateLabel(_ point: MarketEvidence.PricePoint) -> String {
        let date = point.id.hasPrefix("public.") ? publicDetails?.metadata?.updatedAt
            : MarketEvidence.timestamp(activity?.sku.timestamps?.tcgSalesUpdatedAt)
        return "Source updated " + (date?.formatted(date: .abbreviated, time: .shortened) ?? "time unavailable")
    }

    private func freshnessFact(_ title: String, date: Date?) -> some View {
        let age = MarketEvidence.dataAge(date, now: Date())
        let detail: String
        switch age {
        case .withinDay: detail = "Timestamp is within the daily refresh window. This is freshness, not a quality rating."
        case .older: detail = "This source timestamp is more than 24 hours old. Data can remain unchanged after a refresh."
        case .unknown: detail = "The source did not provide a usable update timestamp. Retrieval time is not a substitute."
        case .future: detail = "The provider timestamp is in the future. Check it before relying on freshness."
        }
        return fact(title, value: date?.formatted(date: .abbreviated, time: .shortened) ?? "Unavailable",
                    detail: detail, symbol: "clock", tint: age == .older || age == .future ? .orange : .secondary)
    }

    private func fact(_ title: String, value: String, detail: String, symbol: String, tint: Color = .secondary) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(tint).frame(width: 22).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(value).font(.subheadline.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }.accessibilityElement(children: .combine)
    }

    private func color(for kind: MarketEvidence.PriceKind) -> Color {
        switch kind { case .market: return .blue; case .sold: return .purple; case .listing: return .orange }
    }
    private func symbol(for kind: MarketEvidence.PriceKind) -> String {
        switch kind { case .market: return "tag"; case .sold: return "receipt"; case .listing: return "storefront" }
    }
}
