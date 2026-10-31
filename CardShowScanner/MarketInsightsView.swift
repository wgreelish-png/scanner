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

/// Sections only: the shared parent owns the List, card header and lifecycle.
struct MarketInsightsContent: View {
    @Bindable var model: MarketInsightsModel
    @Binding var window: Int

    var body: some View {
        Section("Market price") {
            if model.publicLoading { ProgressView("Checking price…").accessibilityIdentifier("marketDetails.publicLoading") }
            else {
                Text(model.publicDetails?.quote?.marketPrice?.money ?? "Price unavailable")
                    .font(model.publicDetails?.quote?.marketPrice == nil ? .headline : .largeTitle.bold())
                    .monospacedDigit().accessibilityIdentifier("marketDetails.marketPrice")
                Text("USD per card").font(.caption).foregroundStyle(.secondary)
            }
            if let message = model.publicMessage {
                Text(message).font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("marketDetails.publicStatus")
                Button("Retry Market Price") { model.refreshPublic() }.disabled(model.publicLoading)
            }
            if let context = model.publicDetails?.context {
                DisclosureGroup("Listing details") {
                    LabeledContent("Lowest listing", value: money(context.lowPrice))
                    LabeledContent("Highest listing", value: money(context.highPrice))
                    LabeledContent("Listing count", value: count(context.listingCount))
                    Text("Asking prices are separate from completed sales.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        Section("Sales activity") {
            if model.activityLoading { ProgressView("Loading activity…").accessibilityIdentifier("marketDetails.activityLoading") }
            if let message = model.activityMessage {
                Text(message).font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("marketDetails.activityStatus")
                Button("Retry Market Activity") { model.refreshActivity() }.disabled(model.activityLoading)
            }
            if let details = model.activityDetails {
                Picker("Period", selection: $window) {
                    ForEach([30, 90, 365], id: \.self) { Text("\($0)D").tag($0) }
                }.pickerStyle(.segmented).accessibilityIdentifier("marketDetails.period")
                salesSummary(details.sku.trends?.windows["\(window)d"])
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
                }
            }
        }
    }

    @ViewBuilder private func salesSummary(_ value: OpportunitiesSalesWindow?) -> some View {
        LabeledContent("Reported units", value: count(value?.tcgQuantity)).accessibilityIdentifier("marketDetails.sales\(window)d")
        LabeledContent("Sold average", value: money(value?.tcgSoldAverage)).accessibilityIdentifier("marketDetails.soldAverage\(window)d")
        if let withShipping = value?.tcgSoldAverageWithShipping { LabeledContent("Sold average with shipping", value: withShipping.money) }
        if let quantity = value?.manapoolQuantity { LabeledContent("Manapool units", value: quantity.formatted()) }
        if let average = value?.manapoolAverage { LabeledContent("Manapool sold average", value: average.money) }
    }

    @ViewBuilder private func marketplaceRows(_ name: String, _ marketplace: OpportunitiesMarketplace) -> some View {
        DisclosureGroup(name) {
            LabeledContent("Available quantity", value: count(marketplace.totalQuantityAvailable))
            if marketplace.available == false { Text("Listings unavailable").foregroundStyle(.secondary) }
            ForEach(Array(marketplace.listings.enumerated()), id: \.offset) { index, listing in
                VStack(alignment: .leading, spacing: 5) {
                    Text("Listing \(listing.rank ?? index + 1)").font(.subheadline.weight(.semibold))
                    LabeledContent("Card price", value: money(listing.price))
                    LabeledContent("Shipping", value: money(listing.shipping))
                    LabeledContent("Total", value: money(listing.landedPrice))
                    LabeledContent("Quantity", value: count(listing.sellerQuantity))
                }.font(.caption)
            }
            if marketplace.listings.isEmpty { Text("No individual listings returned").foregroundStyle(.secondary) }
        }
    }
    private func money(_ value: Decimal?) -> String { value?.money ?? "Unavailable" }
    private func count(_ value: Int?) -> String { value.map { $0.formatted() } ?? "Unavailable" }
    private func percent(_ value: Int?) -> String {
        guard let value else { return "Unavailable" }
        return (value > 0 ? "+" : "") + value.formatted() + "%"
    }
}
