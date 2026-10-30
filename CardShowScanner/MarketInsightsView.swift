import SwiftUI

/// Supplemental market information never changes the inventory editor's draft.
struct MarketInsightsView: View {
    @State private var model: MarketInsightsModel
    private let inputCard: CardCandidate

    init(card: CardCandidate, publicPricing: any MarketPricing = OpenAPIMarketPricing.shared,
         opportunities: any OpportunitiesProviding = ConfiguredOpportunitiesProvider()) {
        inputCard = card
        _model = State(initialValue: MarketInsightsModel(card: card, publicPricing: publicPricing, opportunities: opportunities))
    }

    var body: some View {
        List {
            identitySection
            MarketEvidenceView(publicDetails: model.publicDetails, activity: model.activityDetails,
                               publicLoading: model.publicLoading, activityLoading: model.activityLoading)
            publicSection
            activitySection
            if let details = model.activityDetails {
                ForEach([30, 90, 365], id: \.self) { days in
                    salesSection(days: days, window: details.sku.trends?.windows["\(days)d"])
                }
                trendsSection(details.sku.trends)
                listingPricesSection(details.sku.pricing)
                ForEach(details.sku.marketplaces.keys.sorted(), id: \.self) { name in
                    if let marketplace = details.sku.marketplaces[name] {
                        listingsSection(name: name, marketplace: marketplace)
                    }
                }
                activitySourceSection(details)
            }
            Section("Graded Research (experimental)") {
                NavigationLink { ResearchView(card: model.card) } label: {
                    Label("View Graded Research", systemImage: "chart.bar.xaxis")
                }.accessibilityIdentifier("marketDetails.research")
                Text("Catalog-linked grading population and valuation estimates have separate coverage from raw market activity.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Market Details")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .accessibilityLabel("Refresh market details").accessibilityIdentifier("marketDetails.refresh")
                NavigationLink { ResearchConnectionView() } label: { Image(systemName: "gearshape") }
                    .accessibilityLabel("TCGTracking API Connection").accessibilityIdentifier("marketDetails.connection")
            }
        }
        .onAppear { model.refresh(forceRefresh: false) }
        .onChange(of: inputCard.identity) { _, _ in model.changeCard(inputCard) }
        .onDisappear { model.cancel() }
    }

    private var identitySection: some View {
        Section("Exact card") {
            HStack(alignment: .top, spacing: 12) {
                AsyncImage(url: model.card.imageURL) { image in
                    image.resizable().scaledToFit()
                } placeholder: {
                    RoundedRectangle(cornerRadius: 6).fill(.quaternary)
                        .overlay { Image(systemName: "rectangle.portrait").foregroundStyle(.secondary) }
                }.frame(width: 72, height: 100).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.card.name).font(.headline)
                    Text(model.card.set + (model.card.number.isEmpty ? "" : " • " + model.card.number))
                        .font(.subheadline).foregroundStyle(.secondary)
                    Text(model.card.identity.printing + " • " + model.card.identity.condition)
                        .font(.caption)
                    Text(model.card.identity.language).font(.caption).foregroundStyle(.secondary)
                }
            }
            DisclosureGroup("Verify card identifiers") {
                LabeledContent("Game", value: model.card.identity.game)
                LabeledContent("Product ID", value: model.card.identity.productID)
                LabeledContent("Saved SKU ID", value: model.card.identity.skuID ?? "Unavailable")
            }
            Text("Browsing market details leaves the inventory price, card identity and saved offers unchanged. All amounts are USD.")
                .font(.caption).foregroundStyle(.secondary)
        }.accessibilityIdentifier("marketDetails.card")
    }

    private var publicSection: some View {
        Section("Public market pricing") {
            Text("TCGTracking OpenAPI").font(.subheadline).foregroundStyle(.secondary)
            if model.publicLoading { ProgressView("Loading public prices…").accessibilityIdentifier("marketDetails.publicLoading") }
            if let message = model.publicMessage {
                Text(message).foregroundStyle(.secondary).accessibilityIdentifier("marketDetails.publicStatus")
                Button("Retry Public Prices") { model.refreshPublic() }
            }
            if let details = model.publicDetails {
                LabeledContent("Market price", value: money(details.quote?.marketPrice)).accessibilityIdentifier("marketDetails.marketPrice")
                LabeledContent("Lowest price", value: money(details.context?.lowPrice))
                LabeledContent("Highest price", value: money(details.context?.highPrice))
                LabeledContent("Listing count", value: count(details.context?.listingCount))
                if let skuID = details.quote?.skuID { LabeledContent("Matched public SKU", value: skuID) }
                if let metadata = details.metadata {
                    if metadata.isOffline == true {
                        Label("Offline cached public prices", systemImage: "wifi.slash")
                            .foregroundStyle(.secondary).accessibilityIdentifier("marketDetails.offline")
                    } else if metadata.isCached == true {
                        Label("Cached public prices", systemImage: "clock")
                            .foregroundStyle(.secondary).accessibilityIdentifier("marketDetails.cached")
                    }
                    LabeledContent("Price data updated", value: metadata.updatedAt.map(dateLabel) ?? "Unavailable")
                    LabeledContent("Retrieved", value: dateLabel(metadata.fetchedAt))
                }
                if details.quote?.marketPrice == nil {
                    Text("A public market price is unavailable for this exact printing, condition and language.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("Public prices and listing counts describe market data, not completed sales.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var activitySection: some View {
        Section("Raw market activity (OppsV2)") {
            Text("TCGTracking Beta • active opportunities").font(.subheadline).foregroundStyle(.secondary)
            if model.activityLoading { ProgressView("Loading optional market activity…").accessibilityIdentifier("marketDetails.activityLoading") }
            if let message = model.activityMessage {
                Text(message).foregroundStyle(.secondary).accessibilityIdentifier("marketDetails.activityStatus")
                Button("Retry Market Activity") { model.refreshActivity() }
                NavigationLink("TCGTracking API Connection") { ResearchConnectionView() }
            }
            if let details = model.activityDetails {
                LabeledContent("Matched activity SKU", value: details.selectedSKUID)
                LabeledContent("Condition", value: details.sku.condition)
                LabeledContent("Printing", value: details.sku.finish)
                LabeledContent("Language", value: details.sku.language)
            }
            Text("Requires Beta access. Only active opportunities are covered. Missing activity is unavailable and does not indicate zero sales or stock.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func salesSection(days: Int, window: OpportunitiesSalesWindow?) -> some View {
        Section("Reported activity • \(days) days") {
            LabeledContent("TCGplayer reported quantity", value: count(window?.tcgQuantity))
                .accessibilityIdentifier("marketDetails.sales\(days)d")
            LabeledContent("TCGplayer sold average", value: money(window?.tcgSoldAverage))
                .accessibilityIdentifier("marketDetails.soldAverage\(days)d")
            LabeledContent("Sold average with shipping", value: money(window?.tcgSoldAverageWithShipping))
            if let value = window?.tcgMarketAverage { LabeledContent("TCGplayer market average", value: value.money) }
            if let value = window?.manapoolQuantity { LabeledContent("Manapool reported quantity", value: String(value)) }
            if let value = window?.manapoolAverage { LabeledContent("Manapool reported average", value: value.money) }
            Text("Sold averages use explicitly reported sold-price fields. Quantities are provider-reported units for this exact SKU.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func trendsSection(_ trends: OpportunitiesTrends?) -> some View {
        Section("Provider price trends") {
            LabeledContent("30-day vs 90-day trend", value: percent(trends?.trend30DaysVersus90DaysPercent))
            LabeledContent("90-day trend", value: percent(trends?.trend90DaysPercent))
            LabeledContent("TCG MP 30-day trend", value: percent(trends?.tcgMPTrend30DaysPercent))
            Text("Provider-reported percentages. MP follows the provider’s field name. Trends are displayed separately from reported sold averages.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func listingPricesSection(_ pricing: OpportunitiesPricing?) -> some View {
        Section("Comparable listing prices") {
            LabeledContent("Lowest listed card price", value: money(pricing?.listedLowCard))
            LabeledContent("Lowest listing shipping", value: money(pricing?.listedLowShipping))
            LabeledContent("Lowest listed total", value: money(pricing?.listedLowTotal))
            if let value = pricing?.directLowCard { LabeledContent("TCGplayer Direct card price", value: value.money) }
            Text("Asking prices are listings. Availability, shipping and totals are shown as reported by the provider.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func listingsSection(name: String, marketplace: OpportunitiesMarketplace) -> some View {
        Section("Listings • " + name) {
            LabeledContent("Available quantity", value: count(marketplace.totalQuantityAvailable))
            LabeledContent("Listings updated", value: marketplace.updatedAt.map(timestampLabel) ?? "Unavailable")
            if marketplace.available == false { Text("Comparable listings are not currently reported as available.").foregroundStyle(.secondary) }
            ForEach(Array(marketplace.listings.enumerated()), id: \.offset) { index, listing in
                VStack(alignment: .leading, spacing: 6) {
                    Text("Listing \(listing.rank ?? index + 1)").font(.subheadline.bold())
                    LabeledContent("Card price", value: money(listing.price))
                    LabeledContent("Shipping", value: money(listing.shipping))
                    LabeledContent("Listed total", value: money(listing.landedPrice))
                    LabeledContent("Seller quantity", value: count(listing.sellerQuantity))
                    LabeledContent("Updated", value: listing.updatedAt.map(timestampLabel) ?? "Unavailable")
                }.font(.caption).padding(.vertical, 4)
            }
            if marketplace.listings.isEmpty { Text("Individual comparable listings are unavailable.").foregroundStyle(.secondary) }
        }
    }

    private func activitySourceSection(_ details: OpportunitiesDetails) -> some View {
        Section("Market activity source times") {
            LabeledContent("Data generated", value: details.meta.generatedAt.map(timestampLabel) ?? "Unavailable")
            if let value = details.sku.trends?.updatedAt { LabeledContent("Activity trends updated", value: timestampLabel(value)) }
            if let times = details.sku.timestamps {
                if let value = times.opportunityComputedAt { LabeledContent("Opportunity computed", value: timestampLabel(value)) }
                if let value = times.tcgLiveUpdatedAt { LabeledContent("TCGplayer listings updated", value: timestampLabel(value)) }
                if let value = times.lastVerifiedAt { LabeledContent("Last verified", value: timestampLabel(value)) }
                if let value = times.tcgSalesUpdatedAt { LabeledContent("TCGplayer sales updated", value: timestampLabel(value)) }
                if let value = times.manapoolSalesUpdatedAt { LabeledContent("Manapool sales updated", value: timestampLabel(value)) }
                if let value = times.productScrapeFetchedAt { LabeledContent("Product data retrieved", value: timestampLabel(value)) }
            }
        }
    }

    private func money(_ value: Decimal?) -> String { value?.money ?? "Unavailable" }
    private func count(_ value: Int?) -> String { value.map(String.init) ?? "Unavailable" }
    private func percent(_ value: Int?) -> String {
        guard let value else { return "Unavailable" }
        return (value > 0 ? "+" : "") + String(value) + "%"
    }
    private func dateLabel(_ date: Date) -> String { date.formatted(date: .abbreviated, time: .shortened) }
    private func timestampLabel(_ timestamp: String) -> String {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: timestamp) { return dateLabel(date) }
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter.date(from: timestamp).map(dateLabel) ?? timestamp
    }
}
