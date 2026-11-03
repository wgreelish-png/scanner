import XCTest
import SwiftData
@testable import CardShowScanner

@MainActor final class TagPricingContextTests: XCTestCase {
    private func card(_ product: String = "p:42", market: Decimal? = 10.49, condition: String = "Near Mint", sku: String? = nil) -> CardCandidate {
        CardCandidate(identity: .init(game: "Pokémon", productID: product, skuID: sku, printing: "Normal", condition: condition),
            name: "Pricing fixture", set: "Set", number: "42", marketPrice: market, confidence: 100, printings: ["Normal"])
    }
    private func item(_ product: String = "p:42", market: Decimal? = 10.49, quantity: Int = 2,
                      cost: Int64? = 700) -> ShowInventoryItem {
        ShowInventoryItem(card: card(product, market: market), quantity: quantity, remainingCostCents: cost)
    }
    private func approvals() -> TagApprovalStore {
        var data: Data?
        return TagApprovalStore(read: { _ in data }, write: { value, _ in data = value })
    }

    func testLatestQuoteDoesNotMutateAcquisitionSnapshotAndManualStickerIsRetainedUntilSuggestedPriceChosen() throws {
        let item = item(), original = item, store = approvals()
        try store.approve([.init(id: item.id, approvedTag: .individual(1_100), currentMarket: 10.49, isManualOverride: true)])
        var draft = TagPricingContext.draft(for: item,
            marketQuotes: [item.id: .init(market: 18)], store: store)
        XCTAssertEqual(draft.marketValue, 18)
        XCTAssertEqual(draft.tag, .individual(1_100))
        XCTAssertEqual(draft.pricing.tag, .individual(1_800))
        XCTAssertTrue(draft.isManualOverride)
        XCTAssertEqual(draft.profitInputs.acquisitionCost, Decimal(string: "3.50"))
        XCTAssertTrue(TagPricingContext.review(for: draft, store: store).reasons.contains(.marketIncrease))
        draft.useSuggestedPrice()
        XCTAssertEqual(draft.tag, .individual(1_800))
        XCTAssertFalse(draft.isManualOverride)
        XCTAssertEqual(item, original)
        XCTAssertEqual(store.record(for: item.id)?.marketAtLastApproval, 10.49, "Loading and editing never approve")
    }

    func testExplicitUnavailableQuoteDoesNotReuseOldMarketAndKnownZeroBecomesBulk() throws {
        let item = item(), store = approvals()
        try store.approve([.init(id: item.id, approvedTag: .individual(1_000), currentMarket: 10.49)])
        let unknown = TagPricingContext.draft(for: item, marketQuotes: [item.id: .init(market: nil)], store: store)
        XCTAssertNil(unknown.marketValue)
        XCTAssertEqual(unknown.tag, .individual(1_000), "Previously approved sticker remains until explicit approval")
        XCTAssertTrue(TagPricingContext.review(for: unknown, store: store).reasons.contains(.marketUnavailable))
        let zero = TagPricingContext.draft(for: item, marketQuotes: [item.id: .init(market: 0)], store: store)
        XCTAssertEqual(zero.marketValue, 0)
        XCTAssertTrue(zero.isBulk)
        XCTAssertNil(zero.priceCents)
        XCTAssertEqual(zero.tag, .twoForOne)
        XCTAssertThrowsError(try InventoryLabelRenderer.render(zero))
    }

    func testOlderImportCannotReplaceANewerSavedQuoteButNewerUnavailableQuoteIsRespected() {
        var stock = item()
        let store = approvals()
        let fetched = Date(timeIntervalSince1970: 1_800_000_000)
        stock.card.marketPriceMetadata = MarketPriceMetadata(source: .openAPI, fetchedAt: fetched)
        let older = [stock.id: TagMarketQuote(market: 8, observedAt: fetched.addingTimeInterval(-1))]
        XCTAssertEqual(TagPricingContext.draft(for: stock, marketQuotes: older, store: store).marketValue, 10.49)
        let newer = [stock.id: TagMarketQuote(market: 12, observedAt: fetched.addingTimeInterval(1))]
        XCTAssertEqual(TagPricingContext.draft(for: stock, marketQuotes: newer, store: store).marketValue, 12)
        let unavailable = [stock.id: TagMarketQuote(market: nil, observedAt: fetched.addingTimeInterval(1))]
        XCTAssertNil(TagPricingContext.draft(for: stock, marketQuotes: unavailable, store: store).marketValue)
        XCTAssertEqual(stock.card.marketPrice, 10.49)
    }

    func testSavedImportQuotesMatchExactCardDimensionsAndConflictsStayUnavailable() throws {
        let container = try ModelContainer(for: CardList.self, InventoryCard.self, ScanSession.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        context.autosaveEnabled = false
        var stock = item()
        stock.card.identity.skuID = "77"
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = CardShowInventorySnapshot(location: .init(id: 9, name: "Card Show"), rows: [
            .init(inventoryID: 1, card: card(market: 18, sku: "77"), quantity: 1),
            .init(inventoryID: 2, card: card(market: 1, condition: "Lightly Played", sku: "78"), quantity: 1)
        ], fetchedAt: date)
        _ = try CardShowInventoryService.apply(snapshot, context: context)
        let quotes = TagPricingContext.currentQuotes(inventory: [stock], context: context)
        XCTAssertEqual(quotes[stock.id]?.market, 18)
        XCTAssertEqual(quotes[stock.id]?.observedAt, date)
        XCTAssertEqual(stock.card.marketPrice, 10.49)
        let conflict = CardShowInventorySnapshot(location: snapshot.location, rows: [
            .init(inventoryID: 1, card: card(market: 18, sku: "77"), quantity: 1),
            .init(inventoryID: 3, card: card(market: 19, sku: "77"), quantity: 1)
        ], fetchedAt: date.addingTimeInterval(1))
        _ = try CardShowInventoryService.apply(conflict, context: context)
        let conflicting = TagPricingContext.currentQuotes(inventory: [stock], context: context)
        XCTAssertNotNil(conflicting[stock.id])
        XCTAssertNil(conflicting[stock.id]?.market)
        XCTAssertFalse(context.hasChanges)
    }

    func testApprovedStickersBecomeCheckoutSuggestionsImmediatelyWithExactPerRowProceeds() throws {
        let first = item(), second = item("p:43", market: 5, quantity: 1, cost: nil)
        let store = approvals()
        try store.approve([.init(id: first.id, approvedTag: .individual(1_100), currentMarket: 10.49)])
        let lines = [ShowTransactionCardLine(inventoryID: first.id, card: first.card, quantity: 1),
                     .init(inventoryID: second.id, card: second.card, quantity: 1)]
        let suggestion = try XCTUnwrap(TagPricingContext.saleSuggestion(lines: lines, inventory: [first, second], store: store))
        XCTAssertEqual(suggestion.totalCents, 1_600)
        XCTAssertEqual(suggestion.allocations.map(\.receivedCents), [1_100, 500])
        XCTAssertTrue(suggestion.usesApprovedPrices)
        XCTAssertEqual(ShowSaleMath.suggestedTotal(lines), 1_500, "Historical reference math remains stable")
        XCTAssertTrue(try XCTUnwrap(store.record(for: first.id)).needsLabels, "Checkout does not wait for printing")
    }

    func testBulkCheckoutRequiresCompleteProfitablePairsAndDoesNotAssumeUnknownCostsAreFree() throws {
        let stock = item(market: Decimal(string: "0.50"), quantity: 2, cost: 80), store = approvals()
        var preferences = store.preferences
        preferences.minimumDesiredProfitCents = 0
        try store.updatePreferences(preferences)
        try store.approve([.init(id: stock.id, approvedTag: .twoForOne, currentMarket: Decimal(string: "0.50"))])
        let pair = ShowTransactionCardLine(inventoryID: stock.id, card: stock.card, quantity: 2)
        XCTAssertEqual(TagPricingContext.saleSuggestion(lines: [pair], inventory: [stock], store: store)?.totalCents, 100)
        let single = ShowTransactionCardLine(inventoryID: stock.id, card: stock.card, quantity: 1)
        XCTAssertNil(TagPricingContext.saleSuggestion(lines: [single], inventory: [stock], store: store))
        preferences.fixedPaymentFeeCents = 30
        try store.updatePreferences(preferences)
        XCTAssertNil(TagPricingContext.saleSuggestion(lines: [pair], inventory: [stock], store: store), "Pair costs $0.80 plus $0.30 fee")
        preferences.fixedPaymentFeeCents = 0
        try store.updatePreferences(preferences)
        var unknown = stock; unknown.remainingCostCents = nil
        XCTAssertNil(TagPricingContext.saleSuggestion(lines: [pair], inventory: [unknown], store: store))
    }

    func testRepricingLeavesSavedSaleAccountingAndUndoValid() throws {
        var financialData: Data?
        let ledger = ShowBudgetStore(read: { _ in financialData }, write: { data, _ in financialData = data })
        try ledger.seedInventory([.init(sourceInventoryID: 1, card: card(), quantity: 2)], sourceLocationID: 9)
        let stock = try XCTUnwrap(ledger.inventory.first)
        try ledger.setInventoryCost(itemID: stock.id, totalCostCents: 700)
        let showID = try ledger.create(name: "Pricing test", startingCents: 30_000)
        let store = approvals()
        try store.approve([.init(id: stock.id, approvedTag: .individual(1_100), currentMarket: 10.49)])
        let line = ShowTransactionCardLine(inventoryID: stock.id, card: stock.card, quantity: 1)
        let offer = try XCTUnwrap(TagPricingContext.saleSuggestion(lines: [line], inventory: ledger.inventory, store: store))
        let receipt = try ledger.recordTransaction(.init(kind: .sale,
            outgoing: [.init(inventoryID: stock.id, quantity: 1, allocatedProceedsCents: offer.totalCents)],
            saleReceivedCents: offer.totalCents), showID: showID)
        XCTAssertEqual(receipt.totalCostCents, 350)
        XCTAssertEqual(receipt.profitCents, 750)
        let original = ledger.book, bytes = financialData
        try store.approve([.init(id: stock.id, approvedTag: .individual(1_800), currentMarket: 18)])
        try ledger.book.validate()
        XCTAssertEqual(ledger.book, original)
        XCTAssertEqual(financialData, bytes)
        try ledger.undoTransaction(receipt.id)
        XCTAssertEqual(ledger.inventory.first?.quantity, 2)
        XCTAssertEqual(ledger.inventory.first?.remainingCostCents, 700)
        XCTAssertEqual(ledger.inventory.first?.card.marketPrice, 10.49)
    }

    func testStaleQueuedPriceIsRejectedBeforeSendingAndUnchangedApprovalStillPrints() async throws {
        let stock = item(), store = approvals()
        try store.approve([.init(id: stock.id, approvedTag: .individual(1_000), currentMarket: 10.49)])
        let draft = TagPricingContext.draft(for: stock, store: store)
        let raster = LabelRaster(width: 96, height: 240, data: Data(repeating: 0x80, count: 2_880))
        let revision = try XCTUnwrap(store.record(for: stock.id)?.priceRevisionID)
        let entry = try LabelQueueEntry(draft: draft, raster: raster, copyNumber: 1, pricingRevisionID: revision)
        XCTAssertNil(TagPricingContext.printingIssue(for: entry, store: store))
        try store.approve([.init(id: stock.id, approvedTag: .individual(1_000), currentMarket: 12)])
        XCTAssertNil(TagPricingContext.printingIssue(for: entry, store: store), "Retained sticker remains valid despite baseline reset")
        try store.approve([.init(id: stock.id, approvedTag: .individual(1_200), currentMarket: 12)])
        XCTAssertNotNil(TagPricingContext.printingIssue(for: entry, store: store))
        var bytes: Data?
        let queue = LabelPrintQueue(read: { _ in bytes }, write: { data, _ in bytes = data },
            approvalIssue: { TagPricingContext.printingIssue(for: $0, store: store) })
        try queue.replace(with: [entry])
        let printer = TagContextPrinter()
        await queue.start(using: printer)
        XCTAssertEqual(printer.calls, 0)
        XCTAssertEqual(queue.entries.first?.state, .failed)
        XCTAssertNotNil(queue.error)
        try store.approve([.init(id: stock.id, approvedTag: .individual(1_000), currentMarket: 10)])
        XCTAssertNotNil(TagPricingContext.printingIssue(for: entry, store: store), "Returning to an old price does not revive its stale revision")
    }
}

@MainActor private final class TagContextPrinter: LabelPrinterSending {
    var calls = 0
    func printLabel(_ raster: LabelRaster) async -> LabelSendOutcome { calls += 1; return .completed }
    func cancelPrinting() {}
}
