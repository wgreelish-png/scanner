import XCTest
import SwiftData
@testable import CardShowScanner

@MainActor final class CardEditorPricingTests: XCTestCase {
    private func card() -> CardCandidate {
        var card = MockScannerProvider.samples(game: "Pokémon", index: 0)[0]
        card.marketPrice = 10; card.identity.skuID = "100"
        return card
    }

    func testOpeningAndUnchangedIdentityRetainSavedQuoteWithoutRequest() async {
        let pricing = ControlledEditorPricing()
        let saved = card(), model = CardEditorPricingModel(card: card(), pricing: pricing)
        model.changeIdentity { $0.condition = saved.identity.condition }
        for _ in 0..<10 { await Task.yield() }
        let requests = await pricing.requests
        XCTAssertTrue(requests.isEmpty)
        XCTAssertEqual(model.card, saved); XCTAssertEqual(model.price, "10")
        XCTAssertFalse(model.priceLoading)
    }

    func testConditionChangeClearsOldQuoteThenAcceptsKnownZeroAndExactSKU() async throws {
        let pricing = ControlledEditorPricing()
        let edited = CardEditorPricingModel(card: card(), pricing: pricing)
        edited.changeIdentity { $0.condition = "Damaged" }
        XCTAssertNil(edited.card.marketPrice); XCTAssertNil(edited.card.identity.skuID)
        XCTAssertEqual(edited.price, ""); XCTAssertTrue(edited.priceLoading)
        try await waitForRequests(1, pricing: pricing)
        let requests = await pricing.requests
        XCTAssertEqual(requests[0].identity.condition, "Damaged")
        await pricing.resolve(0, with: MarketQuote(marketPrice: 0, skuID: "101"))
        await waitForIdle(edited)
        XCTAssertEqual(edited.card.marketPrice, 0); XCTAssertEqual(edited.card.identity.skuID, "101")
        XCTAssertEqual(edited.price, "0"); XCTAssertNil(edited.priceMessage)
    }

    func testUnavailableConditionDoesNotRetainPreviousPriceOrSKU() async throws {
        let pricing = ControlledEditorPricing()
        let edited = CardEditorPricingModel(card: card(), pricing: pricing)
        edited.changeIdentity { $0.condition = "Lightly Played" }
        try await waitForRequests(1, pricing: pricing)
        await pricing.resolve(0, with: nil); await waitForIdle(edited)
        XCTAssertNil(edited.card.marketPrice); XCTAssertNil(edited.card.identity.skuID)
        XCTAssertEqual(edited.price, ""); XCTAssertNotNil(edited.priceMessage)
        edited.refreshPrice(); try await waitForRequests(2, pricing: pricing)
        await pricing.resolve(1, with: MarketQuote(marketPrice: nil, skuID: "202"))
        await waitForIdle(edited)
        XCTAssertNil(edited.card.marketPrice); XCTAssertEqual(edited.card.identity.skuID, "202")
        XCTAssertEqual(edited.price, ""); XCTAssertNotNil(edited.priceMessage)
    }

    func testRapidConditionChangesRejectLateResponse() async throws {
        let pricing = ControlledEditorPricing()
        let model = CardEditorPricingModel(card: card(), pricing: pricing)
        model.changeIdentity { $0.condition = "Lightly Played" }
        try await waitForRequests(1, pricing: pricing)
        model.changeIdentity { $0.condition = "Damaged" }
        try await waitForRequests(2, pricing: pricing)
        await pricing.resolve(1, with: MarketQuote(marketPrice: 1, skuID: "300")); await waitForIdle(model)
        await pricing.resolve(0, with: MarketQuote(marketPrice: 8, skuID: "200"))
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(model.card.identity.condition, "Damaged")
        XCTAssertEqual(model.card.marketPrice, 1); XCTAssertEqual(model.card.identity.skuID, "300")
        XCTAssertEqual(model.price, "1")
    }

    func testManualPriceAndSKUInvalidatePendingLookup() async throws {
        let pricing = ControlledEditorPricing()
        let model = CardEditorPricingModel(card: card(), pricing: pricing)
        model.setPrice("12.25")
        XCTAssertEqual(model.card.marketPrice, Decimal(string: "12.25"))
        XCTAssertEqual(model.card.identity.skuID, "100", "A manual price retains the current exact SKU")
        model.refreshPrice(); try await waitForRequests(1, pricing: pricing)
        model.setPrice("7.50"); model.setSKU("999")
        await pricing.resolve(0, with: MarketQuote(marketPrice: 3, skuID: "333"))
        for _ in 0..<20 { await Task.yield() }
        XCTAssertFalse(model.priceLoading); XCTAssertEqual(model.price, "7.50")
        XCTAssertEqual(model.card.marketPrice, Decimal(string: "7.50")); XCTAssertEqual(model.card.identity.skuID, "999")
        model.refreshPrice(); try await waitForRequests(2, pricing: pricing)
        model.setSKU("888")
        await pricing.resolve(1, with: MarketQuote(marketPrice: 4, skuID: "444"))
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(model.card.identity.skuID, "888"); XCTAssertNil(model.card.marketPrice)
        model.setSKU(""); XCTAssertNil(model.card.identity.skuID)
        model.setPrice(""); XCTAssertEqual(model.price, ""); XCTAssertNil(model.card.marketPrice)
    }

    func testEveryPricingIdentityFieldTriggersNewLookup() async throws {
        let pricing = ControlledEditorPricing()
        let model = CardEditorPricingModel(card: card(), pricing: pricing)
        let changes: [(inout CardIdentity) -> Void] = [
            { $0.language = "Japanese" }, { $0.printing = "Reverse Holofoil" },
            { $0.productID = "p:999" }, { $0.game = "Magic: The Gathering" }
        ]
        for (index, change) in changes.enumerated() {
            model.changeIdentity(change)
            XCTAssertNil(model.card.marketPrice); XCTAssertNil(model.card.identity.skuID)
            try await waitForRequests(index + 1, pricing: pricing)
            let requests = await pricing.requests
            XCTAssertEqual(requests[index].identity, model.card.identity)
            await pricing.resolve(index, with: MarketQuote(marketPrice: Decimal(index), skuID: String(index + 1)))
            await waitForIdle(model)
        }
    }

    func testSelectionUsesCachedCatalogAndExplicitRetryRequestsRefresh() async throws {
        let pricing = ControlledEditorPricing()
        let model = CardEditorPricingModel(card: card(), pricing: pricing)
        model.changeIdentity { $0.condition = "Lightly Played" }
        try await waitForRequests(1, pricing: pricing)
        await pricing.resolve(0, with: nil); await waitForIdle(model)
        model.refreshPrice(); try await waitForRequests(2, pricing: pricing)
        await pricing.resolve(1, with: MarketQuote(marketPrice: 3, skuID: "333")); await waitForIdle(model)
        let refreshes = await pricing.forceRefreshes
        XCTAssertEqual(refreshes, [false, true])
    }

    func testRejectedAccessCanRetryWithoutLosingSelectedCondition() async throws {
        let pricing = ControlledEditorPricing()
        let model = CardEditorPricingModel(card: card(), pricing: pricing)
        model.changeIdentity { $0.condition = "Moderately Played" }
        try await waitForRequests(1, pricing: pricing)
        await pricing.reject(0, with: MarketPricingFailure.accessRejected(401)); await waitForIdle(model)
        XCTAssertTrue(model.priceConnectionRequired); XCTAssertNotNil(model.priceMessage)
        XCTAssertEqual(model.card.identity.condition, "Moderately Played"); XCTAssertNil(model.card.marketPrice)
        model.refreshPrice(); XCTAssertFalse(model.priceConnectionRequired)
        try await waitForRequests(2, pricing: pricing)
        let requests = await pricing.requests
        XCTAssertEqual(requests[1].identity.condition, "Moderately Played")
        await pricing.resolve(1, with: MarketQuote(marketPrice: 2, skuID: "222")); await waitForIdle(model)
        XCTAssertEqual(model.card.marketPrice, 2); XCTAssertEqual(model.card.identity.skuID, "222")
        XCTAssertNil(model.priceMessage); XCTAssertFalse(model.priceConnectionRequired)
    }

    func testClosingEditorInvalidatesLateLookup() async throws {
        let pricing = ControlledEditorPricing()
        let model = CardEditorPricingModel(card: card(), pricing: pricing)
        model.refreshPrice(); try await waitForRequests(1, pricing: pricing)
        model.cancelLookup()
        await pricing.resolve(0, with: MarketQuote(marketPrice: 99, skuID: "999"))
        for _ in 0..<20 { await Task.yield() }
        XCTAssertNil(model.card.marketPrice); XCTAssertNil(model.card.identity.skuID)
        XCTAssertEqual(model.price, ""); XCTAssertFalse(model.priceLoading)
    }

    func testOpeningCatalogRefreshAddsPrintingsWithoutReplacingSavedQuote() async throws {
        let pricing = ControlledEditorPricing()
        let model = CardEditorPricingModel(card: card(), pricing: pricing)
        model.loadPrintingOptions(); try await waitForRequests(1, pricing: pricing)
        XCTAssertEqual(model.price, "10"); XCTAssertEqual(model.card.identity.skuID, "100")
        XCTAssertFalse(model.priceLoading)
        await pricing.resolve(0, with: MarketQuote(marketPrice: 99, skuID: "999"), printings: ["Normal", "Reverse Holofoil"])
        await waitForPrintings(["Normal", "Reverse Holofoil"], model: model)
        XCTAssertEqual(model.card.printings, ["Normal", "Reverse Holofoil"])
        XCTAssertEqual(model.card.marketPrice, 10); XCTAssertEqual(model.price, "10")
        XCTAssertEqual(model.card.identity.skuID, "100")
    }

    func testLateOpeningCatalogCannotReplaceNewConditionPrintingOptions() async throws {
        let pricing = ControlledEditorPricing()
        let model = CardEditorPricingModel(card: card(), pricing: pricing)
        model.loadPrintingOptions(); try await waitForRequests(1, pricing: pricing)
        model.changeIdentity { $0.condition = "Damaged" }; try await waitForRequests(2, pricing: pricing)
        await pricing.resolve(1, with: MarketQuote(marketPrice: 2, skuID: "222"), printings: ["Normal", "Holofoil"])
        await waitForIdle(model)
        await pricing.resolve(0, with: MarketQuote(marketPrice: 99, skuID: "999"), printings: ["Old metadata"])
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(model.card.printings, ["Normal", "Holofoil"])
        XCTAssertEqual(model.card.marketPrice, 2); XCTAssertEqual(model.card.identity.skuID, "222")
        XCTAssertEqual(model.card.identity.condition, "Damaged")
    }

    func testOpeningCatalogAuthFailureKeepsSavedQuoteAndSuccessfulRetryClearsMessage() async throws {
        let pricing = ControlledEditorPricing()
        let model = CardEditorPricingModel(card: card(), pricing: pricing)
        model.loadPrintingOptions(); try await waitForRequests(1, pricing: pricing)
        await pricing.reject(0, with: MarketPricingFailure.accessRejected(401))
        for _ in 0..<100 {
            if model.priceConnectionRequired { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(model.priceConnectionRequired); XCTAssertNotNil(model.priceMessage)
        XCTAssertEqual(model.price, "10"); XCTAssertEqual(model.card.marketPrice, 10)
        XCTAssertEqual(model.card.identity.skuID, "100")
        model.loadPrintingOptions(); try await waitForRequests(2, pricing: pricing)
        await pricing.resolve(1, with: MarketQuote(marketPrice: 99, skuID: "999"), printings: ["Normal", "Holofoil"])
        await waitForPrintings(["Normal", "Holofoil"], model: model)
        XCTAssertFalse(model.priceConnectionRequired); XCTAssertNil(model.priceMessage)
        XCTAssertEqual(model.price, "10"); XCTAssertEqual(model.card.marketPrice, 10)
        XCTAssertEqual(model.card.identity.skuID, "100")
    }

    func testLookupOnlyChangesDraftUntilExplicitInventorySave() async throws {
        let container = try ModelContainer(for: CardList.self, InventoryCard.self, ScanSession.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext, list = CardList(name: "Existing list")
        context.insert(list)
        try CardListService.add(card(), to: list, context: context); try context.save()
        let item = try XCTUnwrap(list.orderedCards.first), saved = item.snapshot
        let pricing = ControlledEditorPricing()
        let model = CardEditorPricingModel(card: saved, pricing: pricing)
        model.changeIdentity { $0.condition = "Lightly Played" }
        try await waitForRequests(1, pricing: pricing)
        await pricing.resolve(0, with: MarketQuote(marketPrice: 5, skuID: "555")); await waitForIdle(model)
        XCTAssertEqual(item.snapshot, saved, "A fetched quote must not persist before Save")
        let id = item.id, addedAt = item.addedAt
        try CardListService.edit(item, card: model.card, quantity: item.quantity,
                                 cashOverride: nil, tradeOverride: nil, maximumOverride: nil, context: context)
        XCTAssertEqual(item.id, id); XCTAssertEqual(item.addedAt, addedAt)
        XCTAssertEqual(item.snapshot.identity.condition, "Lightly Played")
        XCTAssertEqual(item.snapshot.marketPrice, 5); XCTAssertEqual(item.snapshot.identity.skuID, "555")
    }

    private func waitForRequests(_ count: Int, pricing: ControlledEditorPricing) async throws {
        for _ in 0..<100 {
            let received = await pricing.requests.count
            if received >= count { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Editor pricing request did not start"); throw URLError(.timedOut)
    }

    private func waitForIdle(_ model: CardEditorPricingModel) async {
        for _ in 0..<100 {
            if !model.priceLoading { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Editor pricing did not finish")
    }

    private func waitForPrintings(_ expected: [String], model: CardEditorPricingModel) async {
        for _ in 0..<100 {
            if model.card.printings == expected { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Editor printing options did not finish loading")
    }
}

private actor ControlledEditorPricing: MarketPricing {
    private(set) var requests: [CardCandidate] = []
    private(set) var forceRefreshes: [Bool] = []
    private var pending: [CheckedContinuation<MarketDetails, Error>?] = []
    func quote(for card: CardCandidate) async throws -> MarketQuote? {
        try await details(for: card, candidates: [card], forceRefresh: false).quote
    }
    func details(for card: CardCandidate, candidates: [CardCandidate], forceRefresh: Bool) async throws -> MarketDetails {
        requests.append(card)
        forceRefreshes.append(forceRefresh)
        return try await withCheckedThrowingContinuation { pending.append($0) }
    }
    func resolve(_ index: Int, with quote: MarketQuote?, printings: [String] = []) {
        let continuation = pending[index]; pending[index] = nil
        continuation?.resume(returning: MarketDetails(quote: quote, printings: printings))
    }
    func reject(_ index: Int, with error: Error) {
        let continuation = pending[index]; pending[index] = nil; continuation?.resume(throwing: error)
    }
}
