#if DEBUG
import SwiftUI

/// Explicit UI-test destinations. Synthetic responses never replace a live
/// provider and are excluded from Release builds.
struct MarketEvidenceFixtureScreen: View {
    let research: Bool

    var body: some View {
        NavigationStack {
            if research {
                ResearchView(card: EvidenceFixtureData.card, grader: "PSA", grade: "9",
                             provider: EvidenceFixtureResearch())
            } else {
                MarketInsightsView(card: EvidenceFixtureData.card,
                                   publicPricing: EvidenceFixturePricing(),
                                   opportunities: EvidenceFixtureOpportunities())
            }
        }
    }
}

private enum EvidenceFixtureData {
    static var card: CardCandidate {
        CardCandidate(identity: CardIdentity(game: "Pokémon", productID: "p:42", skuID: "100",
                                            printing: "Holofoil", language: "English", condition: "Near Mint"),
                      name: "Synthetic evidence fixture", set: "Synthetic test set", number: "42",
                      marketPrice: 7, confidence: 100, printings: ["Holofoil"])
    }

    static func utcDay(offset: Int) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: Date()))!
        let formatter = DateFormatter()
        formatter.calendar = calendar; formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    static var timestamp: String { ISO8601DateFormatter().string(from: Date()) }

    static func activity() throws -> OpportunitiesDetails {
        let body: [String: Any] = [
            "meta": ["category_id": 3, "group_id": 1430, "generated_at": timestamp],
            "product": ["product_id": 42, "name": "Synthetic evidence fixture", "skus": [
                "100": ["sku_id": 100, "condition_id": 1, "condition": "Near Mint",
                        "finish": "Holofoil", "language": "English",
                        "pricing": ["market_sku": "12.25", "listed_low_card": "10.00"],
                        "timestamps": ["tcgp_sales_updated_at": timestamp],
                        "trends": ["updated_at": timestamp, "windows": [
                            "30d": ["tcg_qty": 12, "mp_qty": 0, "tcg_sold_avg": "11.75"],
                            "90d": ["tcg_qty": 30, "mp_qty": 7, "tcg_sold_avg": "10.50"],
                            "365d": ["tcg_qty": 120, "mp_qty": NSNull()]
                        ]]]
            ]]
        ]
        return try OpportunitiesDetails.decode(JSONSerialization.data(withJSONObject: body), for: card,
                                               expectedCategoryID: 3, expectedGroupID: 1430, expectedProductID: 42)
    }

    static func research() throws -> ResearchProductDetails {
        let rows: [[Any]] = [
            [utcDay(offset: -2), 2, "12.00"],
            [utcDay(offset: -1), 0, NSNull()],
            [utcDay(offset: -45), 3, "10.00"],
            [utcDay(offset: -120), 1, "8.00"]
        ]
        let body: [String: Any] = [
            "meta": ["schema_version": "2.0-testing", "status": "in_testing", "category_id": 3,
                     "group_id": 1430, "set_name": "Synthetic test set", "generated_at": timestamp],
            "product": ["product_id": 42, "name": "Synthetic evidence fixture", "variants": [
                "EN:Holofoil": ["language": "EN", "finish": "Holofoil", "updated_at": timestamp, "grades": [
                    ["grader": "PSA", "grade": "9", "sales": 6, "pop": 100, "confidence": 3,
                     "guide_value": "12.50", "market_value": "12.00", "last_sold_at": utcDay(offset: -2),
                     "synced_on": utcDay(offset: 0), "daily_history": ["updated_at": timestamp, "series": rows]]
                ]]
            ]]
        ]
        return try ResearchProductDetails.decode(JSONSerialization.data(withJSONObject: body),
                                                 expectedCategoryID: 3, expectedGroupID: 1430, expectedProductID: 42)
    }
}

private struct EvidenceFixturePricing: MarketPricing {
    func quote(for card: CardCandidate) async throws -> MarketQuote? {
        try Task.checkCancellation()
        return MarketQuote(marketPrice: Decimal(string: "12.50"), skuID: "100")
    }
    func details(for card: CardCandidate, candidates: [CardCandidate], forceRefresh: Bool) async throws -> MarketDetails {
        MarketDetails(quote: try await quote(for: card),
                      metadata: MarketPriceMetadata(source: .openAPI, updatedAt: Date(), fetchedAt: Date(), isCached: true),
                      context: MarketPriceContext(lowPrice: 10, highPrice: 15, listingCount: 5))
    }
}

private struct EvidenceFixtureOpportunities: OpportunitiesProviding {
    func opportunities(for card: CardCandidate, forceRefresh: Bool) async throws -> OpportunitiesDetails {
        try Task.checkCancellation()
        return try EvidenceFixtureData.activity()
    }
}

private struct EvidenceFixtureResearch: ResearchProviding {
    func research(for card: CardCandidate, forceRefresh: Bool) async throws -> ResearchProductDetails {
        try Task.checkCancellation()
        return try EvidenceFixtureData.research()
    }
}
#endif
