import XCTest
import SwiftData
@testable import CardShowScanner

@MainActor final class MarketInsightsTests: XCTestCase {
    private func card(productID: Int = 42) -> CardCandidate {
        CardCandidate(identity: CardIdentity(game: "Pokémon", productID: "p:\(productID)", skuID: "100",
                                            printing: "1st Edition Holofoil", language: "English", condition: "Near Mint"),
                      name: "Saved card", set: "Saved set", number: "1/10", marketPrice: 7,
                      confidence: 100, printings: ["1st Edition Holofoil"])
    }

    private func activity(for card: CardCandidate) throws -> OpportunitiesDetails {
        let productID = Int(card.identity.productID.dropFirst(2))!
        let body: [String: Any] = [
            "meta": ["category_id": 3, "group_id": 1430, "generated_at": "2026-10-29T10:00:00Z"],
            "product": ["product_id": productID, "name": "Provider card", "skus": [
                "101": ["sku_id": 101, "condition_id": 1, "condition": "Near Mint",
                        "finish": "1st Edition Holofoil", "language": "English",
                        "pricing": ["avg_30d": 999],
                        "trends": ["windows": ["30d": ["tcg_qty": 0, "tcg_sold_avg": NSNull()]]]]
            ]]
        ]
        return try OpportunitiesDetails.decode(JSONSerialization.data(withJSONObject: body), for: card,
                                               expectedCategoryID: 3, expectedGroupID: 1430, expectedProductID: productID)
    }

    func testPublicPricesCompleteWhileOptionalActivityIsPendingAndSurviveItsFailure() async throws {
        let pricing = ControlledInsightsPricing(), opportunities = ControlledInsightsOpportunities()
        let saved = card(), model = MarketInsightsModel(card: saved, publicPricing: pricing, opportunities: opportunities)
        model.refresh(forceRefresh: false)
        try await pricing.waitForCalls(1); try await opportunities.waitForCalls(1)
        XCTAssertTrue(model.publicLoading); XCTAssertTrue(model.activityLoading)
        await pricing.resolve(0, with: MarketDetails(quote: MarketQuote(marketPrice: 12, skuID: "101"),
                                                    context: MarketPriceContext(lowPrice: 10, highPrice: 14, listingCount: 0)))
        try await waitUntil { !model.publicLoading }
        XCTAssertTrue(model.activityLoading, "Optional activity must not delay public prices")
        XCTAssertEqual(model.publicDetails?.quote?.marketPrice, 12)
        XCTAssertEqual(model.publicDetails?.context?.listingCount, 0)
        await opportunities.reject(0, with: OpportunitiesFailure.notCovered)
        try await waitUntil { !model.activityLoading }
        XCTAssertNotNil(model.activityMessage); XCTAssertNil(model.publicMessage)
        XCTAssertEqual(model.publicDetails?.quote?.marketPrice, 12)
        XCTAssertEqual(model.card, saved)
        let publicRequests = await pricing.requests, activityRequests = await opportunities.requests
        XCTAssertEqual(publicRequests, [saved]); XCTAssertEqual(activityRequests, [saved])
    }

    func testPublicFailureDoesNotHideSuccessfulActivityOrFillMissingSoldAverage() async throws {
        let pricing = ControlledInsightsPricing(), opportunities = ControlledInsightsOpportunities()
        let saved = card(), model = MarketInsightsModel(card: saved, publicPricing: pricing, opportunities: opportunities)
        model.refresh()
        try await pricing.waitForCalls(1); try await opportunities.waitForCalls(1)
        await pricing.reject(0, with: OpenAPIPricingFailure.httpStatus(503))
        await opportunities.resolve(0, with: try activity(for: saved))
        try await waitUntil { !model.publicLoading && !model.activityLoading }
        XCTAssertNotNil(model.publicMessage); XCTAssertNil(model.activityMessage)
        XCTAssertEqual(model.activityDetails?.selectedSKUID, "101")
        XCTAssertEqual(model.activityDetails?.sku.trends?.windows["30d"]?.tcgQuantity, 0)
        XCTAssertNil(model.activityDetails?.sku.trends?.windows["30d"]?.tcgSoldAverage)
        XCTAssertNil(model.activityDetails?.sku.trends?.windows["90d"])
        XCTAssertEqual(model.activityDetails?.sku.pricing?.average30Days, 999)
        XCTAssertEqual(model.card, saved)
    }

    func testRetryActivityLeavesPublicDetailsAndPublicRequestUntouched() async throws {
        let pricing = ControlledInsightsPricing(), opportunities = ControlledInsightsOpportunities()
        let saved = card(), model = MarketInsightsModel(card: saved, publicPricing: pricing, opportunities: opportunities)
        model.refresh(forceRefresh: false)
        try await pricing.waitForCalls(1); try await opportunities.waitForCalls(1)
        await pricing.resolve(0, with: MarketDetails(quote: MarketQuote(marketPrice: 12, skuID: "101")))
        await opportunities.reject(0, with: OpportunitiesFailure.directNotConfigured)
        try await waitUntil { !model.publicLoading && !model.activityLoading }
        model.refreshActivity()
        XCTAssertEqual(model.publicDetails?.quote?.marketPrice, 12)
        XCTAssertFalse(model.publicLoading); XCTAssertTrue(model.activityLoading)
        try await opportunities.waitForCalls(2)
        await opportunities.resolve(1, with: try activity(for: saved))
        try await waitUntil { !model.activityLoading }
        XCTAssertNil(model.activityMessage)
        let publicCount = await pricing.requests.count
        let refreshes = await opportunities.forceRefreshes
        XCTAssertEqual(publicCount, 1); XCTAssertEqual(refreshes, [false, true])
    }

    func testChangingCapturedCardRejectsLateRepliesFromBothServices() async throws {
        let pricing = ControlledInsightsPricing(), opportunities = ControlledInsightsOpportunities()
        let first = card(), second = card(productID: 43)
        let model = MarketInsightsModel(card: first, publicPricing: pricing, opportunities: opportunities)
        model.refresh()
        try await pricing.waitForCalls(1); try await opportunities.waitForCalls(1)
        model.changeCard(second)
        try await pricing.waitForCalls(2); try await opportunities.waitForCalls(2)
        await pricing.resolve(1, with: MarketDetails(quote: MarketQuote(marketPrice: 43, skuID: "101")))
        await opportunities.resolve(1, with: try activity(for: second))
        try await waitUntil { !model.publicLoading && !model.activityLoading }
        await pricing.resolve(0, with: MarketDetails(quote: MarketQuote(marketPrice: 999, skuID: "999")))
        await opportunities.reject(0, with: OpportunitiesFailure.accessDenied)
        await settle()
        XCTAssertEqual(model.card, second)
        XCTAssertEqual(model.publicDetails?.quote?.marketPrice, 43)
        XCTAssertEqual(model.activityDetails?.product.productID, 43)
        XCTAssertNil(model.publicMessage); XCTAssertNil(model.activityMessage)
    }

    func testNewRefreshAndDismissalRejectLateSuccessesAndErrors() async throws {
        let pricing = ControlledInsightsPricing(), opportunities = ControlledInsightsOpportunities()
        let saved = card(), model = MarketInsightsModel(card: saved, publicPricing: pricing, opportunities: opportunities)
        model.refresh()
        try await pricing.waitForCalls(1); try await opportunities.waitForCalls(1)
        model.refresh()
        try await pricing.waitForCalls(2); try await opportunities.waitForCalls(2)
        await pricing.reject(0, with: OpenAPIPricingFailure.invalidResponse)
        await opportunities.resolve(0, with: try activity(for: saved))
        await settle()
        XCTAssertTrue(model.publicLoading); XCTAssertTrue(model.activityLoading)
        XCTAssertNil(model.publicMessage); XCTAssertNil(model.activityDetails)
        model.cancel()
        await pricing.resolve(1, with: MarketDetails(quote: MarketQuote(marketPrice: 999, skuID: "999")))
        await opportunities.reject(1, with: OpportunitiesFailure.accessDenied)
        await settle()
        XCTAssertFalse(model.publicLoading); XCTAssertFalse(model.activityLoading)
        XCTAssertNil(model.publicDetails); XCTAssertNil(model.activityDetails)
        XCTAssertNil(model.publicMessage); XCTAssertNil(model.activityMessage)
        XCTAssertEqual(model.card, saved)
    }

    func testBrowsingLeavesEditorInventoryAndOfferOverridesUnchanged() async throws {
        let container = try ModelContainer(for: CardList.self, InventoryCard.self, ScanSession.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let item = try InventoryCard(card: card(), quantity: 3)
        item.cashOverrideText = "3.50"; item.tradeOverrideText = "5"; item.maximumOverrideText = "4"
        container.mainContext.insert(item); try container.mainContext.save()
        let saved = item.snapshot, savedData = item.data, addedAt = item.addedAt, itemID = item.id
        let pricing = ControlledInsightsPricing(), opportunities = ControlledInsightsOpportunities()
        let editor = CardEditorPricingModel(card: saved, pricing: pricing)
        let model = MarketInsightsModel(card: editor.card, publicPricing: pricing, opportunities: opportunities)
        model.refresh()
        try await pricing.waitForCalls(1); try await opportunities.waitForCalls(1)
        await pricing.resolve(0, with: MarketDetails(quote: MarketQuote(marketPrice: 999, skuID: "999"),
                                                    printings: ["Provider printing"],
                                                    metadata: MarketPriceMetadata(source: .openAPI, fetchedAt: Date())))
        await opportunities.resolve(0, with: try activity(for: saved))
        try await waitUntil { !model.publicLoading && !model.activityLoading }
        XCTAssertEqual(model.card, saved); XCTAssertEqual(editor.card, saved); XCTAssertEqual(editor.price, "7")
        XCTAssertFalse(editor.priceLoading)
        XCTAssertEqual(item.snapshot, saved); XCTAssertEqual(item.data, savedData)
        XCTAssertEqual(item.id, itemID); XCTAssertEqual(item.addedAt, addedAt); XCTAssertEqual(item.quantity, 3)
        XCTAssertEqual(item.cashOverrideText, "3.50"); XCTAssertEqual(item.tradeOverrideText, "5")
        XCTAssertEqual(item.maximumOverrideText, "4")
        XCTAssertFalse(container.mainContext.hasChanges)
    }

    func testServerHealthKeepsOlderServersAndOptionalActivityStatusDistinct() throws {
        let legacy = try JSONDecoder().decode(ResearchServerHealth.self,
            from: Data(#"{"status":"ok","researchConfigured":true,"psaConfigured":false}"#.utf8))
        XCTAssertTrue(legacy.researchConfigured); XCTAssertNil(legacy.opportunitiesConfigured)
        XCTAssertEqual(legacy.marketActivityStatus, "not reported by this server")
        for configured in [true, false] {
            let data = try JSONSerialization.data(withJSONObject: ["status": "ok", "researchConfigured": true,
                "psaConfigured": false, "opportunitiesConfigured": configured])
            let health = try JSONDecoder().decode(ResearchServerHealth.self, from: data)
            XCTAssertEqual(health.opportunitiesConfigured, configured)
            XCTAssertEqual(health.marketActivityStatus, configured ? "configured" : "needs server credentials")
        }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Market details did not reach the expected state")
        throw URLError(.timedOut)
    }

    private func settle() async { for _ in 0..<30 { await Task.yield() } }
}

private actor ControlledInsightsPricing: MarketPricing {
    private(set) var requests: [CardCandidate] = []
    private var pending: [CheckedContinuation<MarketDetails, Error>?] = []
    func quote(for card: CardCandidate) async throws -> MarketQuote? {
        try await details(for: card, candidates: [card], forceRefresh: false).quote
    }
    func details(for card: CardCandidate, candidates: [CardCandidate], forceRefresh: Bool) async throws -> MarketDetails {
        requests.append(card)
        return try await withCheckedThrowingContinuation { pending.append($0) }
    }
    func resolve(_ index: Int, with details: MarketDetails) { let continuation = pending[index]; pending[index] = nil; continuation?.resume(returning: details) }
    func reject(_ index: Int, with error: Error) { let continuation = pending[index]; pending[index] = nil; continuation?.resume(throwing: error) }
    func waitForCalls(_ count: Int) async throws {
        for _ in 0..<100 {
            if requests.count >= count { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Public pricing did not start"); throw URLError(.timedOut)
    }
}

private actor ControlledInsightsOpportunities: OpportunitiesProviding {
    private(set) var requests: [CardCandidate] = []
    private(set) var forceRefreshes: [Bool] = []
    private var pending: [CheckedContinuation<OpportunitiesDetails, Error>?] = []
    func opportunities(for card: CardCandidate, forceRefresh: Bool) async throws -> OpportunitiesDetails {
        requests.append(card); forceRefreshes.append(forceRefresh)
        return try await withCheckedThrowingContinuation { pending.append($0) }
    }
    func resolve(_ index: Int, with details: OpportunitiesDetails) { let continuation = pending[index]; pending[index] = nil; continuation?.resume(returning: details) }
    func reject(_ index: Int, with error: Error) { let continuation = pending[index]; pending[index] = nil; continuation?.resume(throwing: error) }
    func waitForCalls(_ count: Int) async throws {
        for _ in 0..<100 {
            if requests.count >= count { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Optional market activity did not start"); throw URLError(.timedOut)
    }
}
