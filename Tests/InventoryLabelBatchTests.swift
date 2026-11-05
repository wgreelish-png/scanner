import XCTest
@testable import CardShowScanner

@MainActor final class InventoryLabelBatchTests: XCTestCase {
    private func store() -> TagApprovalStore {
        TagApprovalStore(url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
                         read: { _ in nil }, write: { _, _ in })
    }

    private func item(_ index: Int, name: String = "Card", market: Decimal? = 10,
                      quantity: Int = 1) -> ShowInventoryItem {
        let card = CardCandidate(identity: .init(game: "Pokémon", productID: "p:42", printing: "Normal"),
            name: name, set: "Set", number: "42", marketPrice: market, confidence: 100, printings: ["Normal"])
        return ShowInventoryItem(id: UUID(uuidString: String(format: "20000000-0000-0000-0000-%012d", index))!,
                                 card: card, quantity: quantity)
    }

    private func approve(_ item: ShowInventoryItem, in store: TagApprovalStore,
                         tag: StickerPrice = .individual(1_000), baseline: Decimal? = 10,
                         manual: Bool = false, labeled: Bool = true) throws {
        try store.approve([.init(id: item.id, approvedTag: tag, currentMarket: baseline, isManualOverride: manual)])
        if labeled, tag.integerPriceCents != nil { try store.markLabeled(ids: [item.id]) }
    }

    func testAllUsesAvailableStockQuantitiesInDeterministicOrderWithoutChangingSource() {
        let store = store(), first = item(1, quantity: 3), second = item(2, quantity: 4)
        let later = item(3, name: "Zubat", quantity: 101), soldOut = item(4, quantity: 0)
        let source = [later, second, soldOut, first]
        XCTAssertEqual(InventoryLabelBatch.selectedIDs(mode: .all, inventory: source, store: store),
                       Set([first.id, second.id, later.id]))
        let drafts = InventoryLabelBatch.drafts(mode: .all, inventory: source, store: store)
        XCTAssertEqual(drafts.map(\.id), [first.id, second.id, later.id])
        XCTAssertEqual(drafts.map(\.copies), [3, 4, 101], "Oversized quantities must reach the existing validation unchanged")
        XCTAssertEqual(source, [later, second, soldOut, first])
        XCTAssertTrue(store.records.isEmpty)
        XCTAssertTrue(InventoryLabelBatch.selectedIDs(mode: .custom, inventory: source, store: store).isEmpty)
        XCTAssertTrue(InventoryLabelBatch.drafts(mode: .custom, inventory: source, store: store).isEmpty)
    }

    func testPriceChangedIncludesNewUnprintedAndExactExistingThresholds() throws {
        let store = store(), unchanged = item(1), new = item(2), unprinted = item(3)
        let below = item(4, market: Decimal(string: "10.99")), increase = item(5, market: 11, quantity: 3)
        let decrease = item(6, market: Decimal(string: "9.50"))
        try approve(unchanged, in: store)
        try approve(unprinted, in: store, labeled: false)
        for card in [below, increase, decrease] { try approve(card, in: store) }
        let records = store.records
        let source = [unchanged, new, unprinted, below, increase, decrease]
        XCTAssertEqual(InventoryLabelBatch.selectedIDs(mode: .priceChanged, inventory: source, store: store),
                       Set([new.id, unprinted.id, increase.id, decrease.id]))
        let drafts = InventoryLabelBatch.drafts(mode: .priceChanged, inventory: source, store: store)
        XCTAssertEqual(drafts.first { $0.id == increase.id }?.priceCents, 1_100)
        XCTAssertEqual(drafts.first { $0.id == increase.id }?.copies, 3)
        XCTAssertEqual(drafts.first { $0.id == decrease.id }?.priceCents, 900)
        XCTAssertEqual(store.records, records, "Selection and suggestions cannot approve a new baseline")
    }

    func testOverpricedStickerTriggersReviewBeforeMarketMovementThreshold() throws {
        let store = store(), card = item(1, market: 10)
        try approve(card, in: store, tag: .individual(1_100), baseline: 10)
        let drafts = InventoryLabelBatch.drafts(mode: .priceChanged, inventory: [card], store: store)
        XCTAssertEqual(drafts.count, 1)
        XCTAssertEqual(drafts.first?.priceCents, 1_000)
    }

    func testQuoteSnapshotDrivesThresholdAndMissingMarketAloneDoesNotTriggerChangedBatch() throws {
        let store = store(), current = item(1, market: 10), unavailable = item(2, market: nil)
        let unknownNew = item(3, market: nil), knownZero = item(4, market: 0)
        try approve(current, in: store)
        try approve(unavailable, in: store)
        let quotes: [UUID: TagMarketQuote] = [current.id: .init(market: 11)]
        let drafts = InventoryLabelBatch.drafts(mode: .priceChanged,
            inventory: [current, unavailable, unknownNew, knownZero], marketQuotes: quotes, store: store)
        XCTAssertEqual(Set(drafts.map(\.id)), Set([current.id, unknownNew.id, knownZero.id]))
        XCTAssertEqual(drafts.first { $0.id == current.id }?.priceCents, 1_100)
        let missing = try XCTUnwrap(drafts.first { $0.id == unknownNew.id })
        XCTAssertNil(missing.tag)
        XCTAssertTrue(missing.pricing.reasons.contains(.missingMarket))
        XCTAssertFalse(InventoryLabelBatch.shouldPrint(missing, approval: nil, reprintAll: true))
        let zero = try XCTUnwrap(drafts.first { $0.id == knownZero.id })
        XCTAssertEqual(zero.tag, .twoForOne)
        XCTAssertFalse(InventoryLabelBatch.shouldPrint(zero, approval: nil, reprintAll: true))
    }

    func testManualIndividualAndBulkApprovalsSurviveCrossingTheBulkBoundary() throws {
        let store = store(), individual = item(1, market: Decimal(string: "0.50")), bulk = item(2, market: 10)
        try approve(individual, in: store, tag: .individual(700), baseline: 1, manual: true)
        try approve(bulk, in: store, tag: .twoForOne, baseline: Decimal(string: "0.50"), manual: true)
        for mode in [InventoryLabelBatchMode.all, .priceChanged] {
            let drafts = InventoryLabelBatch.drafts(mode: mode, inventory: [individual, bulk], store: store)
            XCTAssertEqual(drafts.first { $0.id == individual.id }?.tag, .individual(700))
            XCTAssertEqual(drafts.first { $0.id == bulk.id }?.tag, .twoForOne)
            XCTAssertTrue(drafts.allSatisfy(\.isManualOverride))
        }
    }

    func testUnchangedSuppressionAndExplicitReprintsUseTheSameApprovedRevision() throws {
        let store = store(), card = item(1), unprinted = item(2)
        try approve(card, in: store)
        try approve(unprinted, in: store, labeled: false)
        let saved = try XCTUnwrap(store.record(for: card.id))
        var draft = try XCTUnwrap(InventoryLabelBatch.drafts(mode: .all, inventory: [card], store: store).first)
        XCTAssertFalse(InventoryLabelBatch.shouldPrint(draft, approval: saved, reprintAll: false))
        XCTAssertTrue(InventoryLabelBatch.shouldPrint(draft, approval: saved, reprintAll: true))
        XCTAssertFalse(InventoryLabelBatch.shouldPrint(draft, approval: saved, reprintAll: true, keepExisting: true))
        XCTAssertTrue(InventoryLabelBatch.shouldPrint(draft, approval: nil, reprintAll: false))
        XCTAssertTrue(InventoryLabelBatch.shouldPrint(draft, approval: store.record(for: unprinted.id), reprintAll: false))
        draft.askingPriceText = "11"
        XCTAssertTrue(InventoryLabelBatch.shouldPrint(draft, approval: saved, reprintAll: false))
        draft.askingPriceText = "0"
        XCTAssertTrue(InventoryLabelBatch.shouldPrint(draft, approval: saved, reprintAll: true), "Known zero is a valid individual override")
        XCTAssertEqual(store.record(for: card.id), saved)
    }

    func testLargeBatchNeedsNoIndividualSelectionsAndKeepsEveryPhysicalCopy() {
        let store = store()
        let source = (1...137).map { item($0, name: "Card \($0)", quantity: $0 % 3 == 0 ? 2 : 1) }
        let drafts = InventoryLabelBatch.drafts(mode: .all, inventory: source, store: store)
        XCTAssertEqual(drafts.count, 137)
        XCTAssertEqual(Set(drafts.map(\.id)), Set(source.map(\.id)))
        XCTAssertEqual(drafts.reduce(0) { $0 + $1.copies }, source.reduce(0) { $0 + $1.quantity })
        XCTAssertTrue(store.records.isEmpty)
    }

    func testExplicitlyChosenAlreadyLabeledCardsReprintWhilePriceChangedSkipsThem() throws {
        let store = store(), card = item(1, quantity: 4)
        try approve(card, in: store)
        let saved = try XCTUnwrap(store.record(for: card.id))
        var chosen = InventoryLabelBatch.draft(for: card, mode: .custom, store: store)
        XCTAssertEqual(chosen.copies, 1)
        chosen.copies = 4
        XCTAssertTrue(InventoryLabelBatch.shouldPrint(chosen, approval: saved, mode: .custom),
                      "Choosing a card is an explicit request to print its requested copies again")
        XCTAssertTrue(InventoryLabelBatch.shouldPrint(chosen, approval: saved, mode: .all))
        XCTAssertFalse(InventoryLabelBatch.shouldPrint(chosen, approval: saved, mode: .priceChanged))
        XCTAssertEqual(chosen.copies, 4)
        XCTAssertEqual(store.record(for: card.id), saved, "Selecting replacements cannot change approval history")
    }

    func testEveryModeStillHonorsExplicitStickerRetentionAndExcludesBulkOrMissingPrices() throws {
        let store = store(), card = item(1), bulk = item(2, market: 0.5), missing = item(3, market: nil)
        try approve(card, in: store)
        let saved = try XCTUnwrap(store.record(for: card.id))
        let individual = InventoryLabelBatch.draft(for: card, mode: .custom, store: store)
        let bulkDraft = InventoryLabelBatch.draft(for: bulk, mode: .custom, store: store)
        let missingDraft = InventoryLabelBatch.draft(for: missing, mode: .custom, store: store)
        for mode in InventoryLabelBatchMode.allCases {
            XCTAssertFalse(InventoryLabelBatch.shouldPrint(individual, approval: saved, mode: mode, keepExisting: true))
            XCTAssertFalse(InventoryLabelBatch.shouldPrint(individual, approval: nil, mode: mode, keepExisting: true))
            XCTAssertFalse(InventoryLabelBatch.shouldPrint(bulkDraft, approval: nil, mode: mode))
            XCTAssertFalse(InventoryLabelBatch.shouldPrint(missingDraft, approval: nil, mode: mode))
        }
    }

    func testModeBasedReprintsPreserveRequestedCopiesAndDoNotBypassCopyValidation() throws {
        let store = store(), card = item(1, quantity: 7)
        try approve(card, in: store)
        let saved = try XCTUnwrap(store.record(for: card.id))
        for mode in InventoryLabelBatchMode.allCases {
            var draft = InventoryLabelBatch.draft(for: card, mode: mode, store: store)
            draft.askingPriceText = "11"
            draft.copies = 7
            XCTAssertTrue(InventoryLabelBatch.shouldPrint(draft, approval: saved, mode: mode))
            XCTAssertEqual(draft.copies, 7)
            XCTAssertNoThrow(try draft.validate())
            draft.copies = InventoryLabelDraft.maximumCopies + 1
            XCTAssertTrue(InventoryLabelBatch.shouldPrint(draft, approval: saved, mode: mode))
            XCTAssertEqual(draft.copies, 101, "The existing validation must see an oversized request without clamping")
            XCTAssertThrowsError(try draft.validate()) {
                XCTAssertEqual($0 as? InventoryLabelFailure, .invalidCopies)
            }
        }
    }

    func testAddingASelectionAfterBackNavigationUsesModeDefaultsAndPreservesManualCategory() throws {
        let store = store(), card = item(1, market: 12, quantity: 3)
        try approve(card, in: store, tag: .twoForOne, baseline: 1, manual: true)
        for mode in [InventoryLabelBatchMode.all, .priceChanged, .custom] {
            let draft = InventoryLabelBatch.draft(for: card, mode: mode, store: store)
            XCTAssertEqual(draft.copies, mode == .custom ? 1 : 3)
            XCTAssertEqual(draft.tag, .twoForOne)
            XCTAssertTrue(draft.isManualOverride)
        }
    }

    func testUnprofitableSuggestionKeepsExistingWarningsForExplicitManualReview() throws {
        let store = store()
        var preferences = store.preferences
        preferences.minimumDesiredProfitCents = 100
        try store.updatePreferences(preferences)
        var card = item(1, market: 9)
        card.remainingCostCents = 1_000
        try approve(card, in: store)
        let draft = try XCTUnwrap(InventoryLabelBatch.drafts(mode: .priceChanged, inventory: [card], store: store).first)
        XCTAssertEqual(draft.priceCents, 900)
        XCTAssertTrue(draft.pricingWarnings.contains(TagPricingReason.belowBreakEven.message))
        XCTAssertTrue(draft.pricingWarnings.contains(TagPricingReason.belowPreferredProfit.message))
        XCTAssertEqual(store.record(for: card.id)?.approvedTag, .individual(1_000))
    }
}
