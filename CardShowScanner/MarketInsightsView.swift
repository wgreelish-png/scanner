import SwiftUI

/// Compatibility entry point; both modes now share one card research page.
struct MarketInsightsView: View {
    let card: CardCandidate
    private let publicPricing: any MarketPricing
    private let opportunities: any OpportunitiesProviding
    init(card: CardCandidate, publicPricing: any MarketPricing = StandardMarketPricing(),
         opportunities: any OpportunitiesProviding = ConfiguredOpportunitiesProvider()) {
        self.card = card; self.publicPricing = publicPricing; self.opportunities = opportunities
    }
    var body: some View {
        CardResearchView(card: card, publicPricing: publicPricing, opportunities: opportunities)
    }
}

/// The shared card header owns the only visible market quote.
struct MarketPriceSummary: View {
    let model: MarketInsightsModel
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Card price").font(.caption).foregroundStyle(.secondary)
            if model.publicLoading {
                ProgressView("Checking price…").accessibilityIdentifier("marketDetails.publicLoading")
            } else {
                Text(model.publicDetails?.quote?.marketPrice?.money ?? "Price unavailable")
                    .font(model.publicDetails?.quote?.marketPrice == nil ? .headline : .largeTitle.bold())
                    .monospacedDigit().fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("marketDetails.marketPrice")
            }
            Text("USD per card").font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Sections only: the shared parent owns the List, card header and lifecycle.
struct MarketInsightsContent: View {
    @Bindable var model: MarketInsightsModel
    @Binding var window: Int
    var onConnection: (() -> Void)? = nil
    @ObservedObject private var allowlist = BetaIPAllowlistSync.shared
    @State private var showingListingDetails = false

    var body: some View {
        Section {
            DisclosureGroup(isExpanded: $showingListingDetails) {
                if let message = model.publicMessage {
                    Text(message).font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("marketDetails.publicStatus")
                    Button("Retry Market Price") { model.refreshPublic() }.disabled(model.publicLoading)
                }
                if let context = model.publicDetails?.context {
                    LabeledContent("Lowest listing", value: money(context.lowPrice)).accessibilityIdentifier("marketDetails.lowestListing")
                    LabeledContent("Highest listing", value: money(context.highPrice))
                    LabeledContent("Listing count", value: count(context.listingCount))
                } else {
                    Text("Listing details unavailable").font(.footnote).foregroundStyle(.secondary)
                }
                if let metadata = model.publicDetails?.metadata {
                    LabeledContent("Price data", value: metadata.summary)
                }
                Text("Asking prices are separate from completed sales.").font(.caption).foregroundStyle(.secondary)
            } label: {
                Text("Listing details").accessibilityIdentifier("marketDetails.listingDetails")
            }
        }
        Section {
            if model.activityLoading { ProgressView("Loading activity…").accessibilityIdentifier("marketDetails.activityLoading") }
            if let message = model.activityMessage {
                Text(message).font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("marketDetails.activityStatus")
                if model.activityFailure != .unsupportedCard {
                    Button("Retry Market Activity") { model.refreshActivity() }.disabled(model.activityLoading)
                }
                if model.activityNeedsConnection {
                    if allowlist.needsSignIn {
                        Text("Automatic IP updates need website sign-in. Activity access is unverified.")
                            .font(.caption).foregroundStyle(.secondary)
                            .accessibilityIdentifier("marketDetails.accessContext")
                    } else if allowlist.isCoolingPaused {
                        Text("Automatic website checks are paused while this iPhone cools. API requests remain available.")
                            .font(.caption).foregroundStyle(.secondary)
                            .accessibilityIdentifier("marketDetails.accessContext")
                    }
                    if let onConnection {
                        Button("Review API Connection", systemImage: "gearshape", action: onConnection)
                            .accessibilityIdentifier("marketDetails.connection")
                    }
                }
            }
            if let details = model.activityDetails {
                Picker("Period", selection: $window) {
                    ForEach([30, 90, 365], id: \.self) { Text("\($0)D").tag($0) }
                }.pickerStyle(.segmented).accessibilityIdentifier("marketDetails.period")
                salesSummary(details.sku.trends?.windows["\(window)d"])
                MarketActivityChartsView(sku: details.sku, selectedWindow: $window,
                    salesUpdatedAt: details.sku.timestamps?.tcgSalesUpdatedAt)
                DisclosureGroup("More activity") {
                    LabeledContent("30-day vs 90-day trend", value: percent(details.sku.trends?.trend30DaysVersus90DaysPercent))
                    LabeledContent("90-day trend", value: percent(details.sku.trends?.trend90DaysPercent))
                    LabeledContent("TCG MP 30-day trend", value: percent(details.sku.trends?.tcgMPTrend30DaysPercent))
                    LabeledContent("Lowest listed card", value: money(details.sku.pricing?.listedLowCard))
                    LabeledContent("Shipping", value: money(details.sku.pricing?.listedLowShipping))
                    LabeledContent("Lowest listed total", value: money(details.sku.pricing?.listedLowTotal))
                    if let direct = details.sku.pricing?.directLowCard { LabeledContent("TCGplayer Direct", value: direct.money) }
                    ForEach(details.sku.marketplaces.keys.sorted(), id: \.self) { name in
                        if let marketplace = details.sku.marketplaces[name] { marketplaceRows(name, marketplace) }
                    }
                    sourceRows(details)
                }
            }
        } header: {
            Text("Market Activity").accessibilityIdentifier("marketDetails.activityHeader")
        }
        if let details = model.activityDetails {
            benchmarkSection(details)
            coveredSKUsSection(details)
        }
    }

    @ViewBuilder private func salesSummary(_ value: OpportunitiesSalesWindow?) -> some View {
        LabeledContent("Reported units", value: count(value?.tcgQuantity)).accessibilityIdentifier("marketDetails.sales\(window)d")
        LabeledContent("Sold average", value: money(value?.tcgSoldAverage)).accessibilityIdentifier("marketDetails.soldAverage\(window)d")
        LabeledContent("Average units / day", value: dailyRate(value?.tcgQuantity))
            .accessibilityIdentifier("marketDetails.unitsPerDay\(window)d")
        if let withShipping = value?.tcgSoldAverageWithShipping { LabeledContent("Sold average with shipping", value: withShipping.money) }
        if let quantity = value?.manapoolQuantity { LabeledContent("Manapool units", value: quantity.formatted()) }
        if let average = value?.manapoolAverage { LabeledContent("Manapool sold average", value: average.money) }
    }

    @ViewBuilder private func marketplaceRows(_ name: String, _ marketplace: OpportunitiesMarketplace) -> some View {
        DisclosureGroup(name) {
            LabeledContent("Provider-reported quantity", value: count(marketplace.totalQuantityAvailable))
            Text("Returned offers are a partial snapshot. The provider quantity can cover a different scope than these rows.")
                .font(.caption).foregroundStyle(.secondary)
            if marketplace.available == false { Text("Listings unavailable").foregroundStyle(.secondary) }
            ForEach(Array(marketplace.listings.enumerated()), id: \.offset) { index, listing in
                VStack(alignment: .leading, spacing: 5) {
                    if let url = listing.sellerURL {
                        Link(listing.sellerName ?? "Listing \(listing.rank ?? index + 1)", destination: url)
                            .font(.subheadline.weight(.semibold))
                    } else {
                        Text(listing.sellerName ?? "Listing \(listing.rank ?? index + 1)")
                            .font(.subheadline.weight(.semibold))
                    }
                    LabeledContent("Card price", value: money(listing.price))
                    LabeledContent("Shipping", value: money(listing.shipping))
                    LabeledContent("Total", value: money(listing.landedPrice))
                    LabeledContent("Quantity", value: count(listing.sellerQuantity))
                    if let updated = listing.updatedAt { LabeledContent("Snapshot updated", value: timestamp(updated)) }
                }.font(.caption)
            }
            if marketplace.listings.isEmpty { Text("No individual listings returned").foregroundStyle(.secondary) }
        }
    }

    private func benchmarkSection(_ details: OpportunitiesDetails) -> some View {
        let benchmarks = MarketActivityPresentation(sku: details.sku).benchmarks
        return Section("Price references & purchase costs") {
            MarketBenchmarkChartView(benchmarks: benchmarks)
            DisclosureGroup("View all reference values") {
                ForEach(benchmarks) { reference in
                    LabeledContent {
                        Text(money(reference.value)).monospacedDigit()
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(reference.label)
                            Text(reference.includesShipping ? "Includes shipping" : "Card price · excludes shipping")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                if let opportunity = details.sku.opportunity {
                    if let source = opportunity.bestSource { LabeledContent("Marketplace source", value: source) }
                    LabeledContent("Opportunity available", value: opportunity.isAvailable.map { $0 ? "Yes" : "No" } ?? "Unavailable")
                    if let benchmark = opportunity.benchmarks["market_sku"] {
                        LabeledContent("Reported market-reference savings", value: money(benchmark.savings))
                        LabeledContent("Reported market-reference discount", value: decimalPercent(benchmark.discountPercent))
                    }
                }
            }.accessibilityIdentifier("marketDetails.benchmarkValues")
            Text("Buy card and landed cost describe a marketplace purchase, separate from the cash offer you give a customer. Reference savings are not a profit forecast.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func coveredSKUsSection(_ details: OpportunitiesDetails) -> some View {
        let skus = details.product.skus.sorted { left, right in
            let a = left.value, b = right.value
            if a.finish != b.finish { return a.finish < b.finish }
            if a.language != b.language { return a.language < b.language }
            if a.conditionID != b.conditionID { return a.conditionID < b.conditionID }
            return left.key < right.key
        }
        return Section {
            DisclosureGroup("Covered SKUs (\(skus.count))") {
                ForEach(skus, id: \.key) { key, sku in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(sku.condition).font(.subheadline.weight(.semibold))
                            if key == details.selectedSKUID {
                                Text("Selected").font(.caption).foregroundStyle(.indigo)
                            }
                        }
                        Text(sku.finish + " · " + sku.language).font(.caption).foregroundStyle(.secondary)
                        LabeledContent("SKU market", value: money(sku.pricing?.marketSKU))
                        LabeledContent("30-day sold average", value: money(sku.trends?.windows["30d"]?.tcgSoldAverage))
                        LabeledContent("30-day reported units", value: count(sku.trends?.windows["30d"]?.tcgQuantity))
                        LabeledContent("Buy card", value: money(sku.opportunity?.buyCard))
                        LabeledContent("Landed 1×", value: money(sku.opportunity?.costOne))
                        LabeledContent("SKU", value: key)
                    }.font(.caption).padding(.vertical, 4)
                }
                Text("This table contains the SKUs returned in this Beta snapshot. Other conditions or printings can still have public pricing. Use the card controls above to change the research selection.")
                    .font(.caption).foregroundStyle(.secondary)
            }.accessibilityIdentifier("marketDetails.coveredSKUs")
        }
    }

    @ViewBuilder private func sourceRows(_ details: OpportunitiesDetails) -> some View {
        DisclosureGroup("Activity source dates") {
            LabeledContent("Dataset generated", value: timestamp(details.meta.generatedAt))
            LabeledContent("TCGplayer sales updated", value: timestamp(details.sku.timestamps?.tcgSalesUpdatedAt))
            LabeledContent("TCGplayer snapshot updated", value: timestamp(details.sku.timestamps?.tcgLiveUpdatedAt))
            LabeledContent("Exact SKU", value: details.selectedSKUID)
            LabeledContent("Live market reference", value: money(details.sku.pricing?.liveMarket))
            Text("Source update times describe snapshots, not the date of the most recent individual sale.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func timestamp(_ value: String?) -> String {
        MarketEvidence.timestamp(value)?.formatted(date: .abbreviated, time: .shortened) ?? "Unavailable"
    }
    private func decimalPercent(_ value: Decimal?) -> String {
        value.map { $0.formatted(.number.precision(.fractionLength(0...1))) + "%" } ?? "Unavailable"
    }
    private func dailyRate(_ quantity: Int?) -> String {
        guard let quantity else { return "Unavailable" }
        let value = Double(quantity) / Double(window)
        if value >= 1 { return value.formatted(.number.precision(.fractionLength(0...1))) }
        if value >= 0.1 { return value.formatted(.number.precision(.fractionLength(0...2))) }
        return value.formatted(.number.precision(.significantDigits(1...3)))
    }
    private func money(_ value: Decimal?) -> String { value?.money ?? "Unavailable" }
    private func count(_ value: Int?) -> String { value.map { $0.formatted() } ?? "Unavailable" }
    private func percent(_ value: Int?) -> String {
        guard let value else { return "Unavailable" }
        return (value > 0 ? "+" : "") + value.formatted() + "%"
    }
}
