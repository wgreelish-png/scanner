import SwiftUI
import Charts

/// Visual evidence for the exact selection; never writes a quote or invents a score.
struct MarketEvidenceView: View {
    let publicDetails: MarketDetails?
    let activity: OpportunitiesDetails?
    let publicLoading: Bool
    let activityLoading: Bool
    @State private var selectedWindow = 30

    private var evidence: MarketEvidence {
        MarketEvidence(publicDetails: publicDetails, activity: activity)
    }

    var body: some View {
        summarySection
        if !evidence.priceComparisons.isEmpty { comparisonSection }
        if activity != nil { volumeSection }
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
            Chart(evidence.priceComparisons) { point in
                BarMark(x: .value("USD", NSDecimalNumber(decimal: point.price).doubleValue),
                        y: .value("Price reference", point.label))
                    .foregroundStyle(color(for: point.kind))
                    .accessibilityLabel(point.label)
                    .accessibilityValue(point.price.money)
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
            .frame(height: CGFloat(max(1, evidence.priceComparisons.count)) * 48 + 42)
            .accessibilityLabel("Market, sold-average and listing price references in US dollars")
            .accessibilityIdentifier("marketEvidence.priceChart")
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
            Picker("Reporting window", selection: $selectedWindow) {
                Text("30 days").tag(30)
                Text("90 days").tag(90)
                Text("365 days").tag(365)
            }.pickerStyle(.segmented).accessibilityIdentifier("marketEvidence.volumeWindow")
            if !selectedVolume.isEmpty {
                Chart(selectedVolume) { point in
                    BarMark(x: .value("Marketplace", point.source), y: .value("Reported units", point.quantity))
                        .foregroundStyle(point.source == "TCGplayer" ? Color.blue : Color.teal)
                        .accessibilityLabel(point.source + " • " + String(selectedWindow) + " days")
                        .accessibilityValue(point.quantity.formatted() + " reported units")
                }
                .chartYScale(domain: 0...volumeUpperBound)
                .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) }
                .chartYAxisLabel("Reported units")
                .frame(height: 180)
                .accessibilityIdentifier("marketEvidence.volumeChart")
            } else {
                Text("No quantities were returned for this window.").foregroundStyle(.secondary)
                    .accessibilityIdentifier("marketEvidence.volumeEmpty")
            }
            LabeledContent("TCGplayer reported units") {
                Text(quantity(for: "TCGplayer")).monospacedDigit().accessibilityIdentifier("marketEvidence.tcgQuantity")
            }
            LabeledContent("Manapool reported units") {
                Text(quantity(for: "Manapool")).monospacedDigit().accessibilityIdentifier("marketEvidence.mpQuantity")
            }
            Text("Each window is a cumulative period ending at the provider’s reporting time. The windows overlap and must not be added together. Unknown quantities remain unavailable; zero is shown only when returned. These counts do not predict your sale speed.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var volumeUpperBound: Double { max(1, Double(selectedVolume.map(\.quantity).max() ?? 0) * 1.15) }
    private func quantity(for source: String) -> String {
        selectedVolume.first { $0.source == source }?.quantity.formatted() ?? "Unavailable"
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
