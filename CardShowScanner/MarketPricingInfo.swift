import SwiftUI

/// Market quotes have one standard provider; account connections are separate.
struct MarketPricingInfo: View {
    var body: some View {
        LabeledContent("Market pricing", value: "Open API")
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("settings.marketPricing")
    }
}
