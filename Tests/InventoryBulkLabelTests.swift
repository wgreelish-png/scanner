import XCTest
@testable import CardShowScanner

@MainActor final class InventoryBulkLabelTests: XCTestCase {
    private func stock(name: String = "Bulk fixture", market: Decimal = 0.5,
                       quantity: Int = 1, id: UUID = UUID()) -> ShowInventoryItem {
        let card = CardCandidate(identity: .init(game: "Pokémon", productID: "fixture", printing: "Normal"),
            name: name, set: "Set", number: "42", marketPrice: market, confidence: 100, printings: ["Normal"])
        return ShowInventoryItem(id: id, card: card, quantity: quantity, remainingCostCents: 25)
    }

    private func store() -> TagApprovalStore {
        var bytes: Data?
        return TagApprovalStore(read: { _ in bytes }, write: { data, _ in bytes = data })
    }

    private func entries(_ draft: InventoryLabelDraft, revision: UUID? = nil) throws -> [LabelQueueEntry] {
        let raster = LabelRaster(width: draft.paperSize.headDots, height: draft.paperSize.feedDots,
                                 data: Data(repeating: 0x80, count: 12 * draft.paperSize.feedDots))
        return try (1...draft.copies).map {
            try LabelQueueEntry(draft: draft, raster: raster, copyNumber: $0, pricingRevisionID: revision)
        }
    }

    func testFourSelectedInventoryCopiesIncludeTheSavedBulkDealWithoutRepricing() throws {
        let store = store()
        let inventory = [stock(name: "Amaura", market: 9), stock(name: "Bastiodon", market: 9),
                         stock(name: "Battle Cage", market: 9), stock(name: "Big Parasol", market: 9)]
        let tags: [StickerPrice] = [.individual(100), .twoForOne, .individual(100), .individual(200)]
        try store.approve(zip(inventory, tags).map { .init(id: $0.0.id, approvedTag: $0.1, currentMarket: 9) })
        let before = inventory, records = store.records
        for mode in [InventoryLabelBatchMode.all, .priceChanged, .custom] {
            let drafts = inventory.map { InventoryLabelBatch.draft(for: $0, mode: mode, store: store) }
            let printable = drafts.filter { InventoryLabelBatch.shouldPrint($0, approval: store.record(for: $0.id), mode: mode) }
            XCTAssertEqual(printable.count, 4)
            XCTAssertEqual(printable.reduce(0) { $0 + $1.copies }, 4)
            XCTAssertEqual(printable.map(\.tag), tags.map(Optional.some))
            let queued = try printable.flatMap { try entries($0, revision: store.record(for: $0.id)?.priceRevisionID) }
            XCTAssertEqual(queued.count, 4)
            XCTAssertEqual(queued.map(\.stickerTag), tags.map(Optional.some))
            XCTAssertTrue(queued.allSatisfy { TagPricingContext.printingIssue(for: $0, store: store) == nil })
        }
        XCTAssertEqual(inventory, before)
        XCTAssertEqual(store.records, records)
    }

    func testAllBulkStockKeepsEveryRequestedCopyAndItsInventoryIdentity() throws {
        let store = store(), inventory = [stock(quantity: 3), stock(quantity: 2)]
        let drafts = InventoryLabelBatch.drafts(mode: .all, inventory: inventory, store: store)
        XCTAssertEqual(drafts.count, 2)
        XCTAssertTrue(drafts.allSatisfy(\.isBulk))
        let queued = try drafts.flatMap { try entries($0) }
        XCTAssertEqual(queued.count, 5)
        XCTAssertEqual(Set(queued.compactMap(\.inventoryID)), Set(inventory.map(\.id)))
        XCTAssertTrue(queued.allSatisfy { $0.source == .inventory && $0.inventoryBulk == true && $0.customBulk == nil })
        XCTAssertTrue(queued.allSatisfy { $0.stickerTag == .twoForOne && $0.priceText == StickerPrice.twoForOne.displayText })
        for draft in drafts {
            XCTAssertEqual(queued.filter { $0.inventoryID == draft.id }.map(\.copyNumber), Array(1...draft.copies))
        }
    }

    func testBulkCompletionRequiresEveryCopyInItsCurrentPriceRevision() throws {
        let store = store(), item = stock(quantity: 2)
        try store.prepareForPrinting([.init(id: item.id, approvedTag: .twoForOne, currentMarket: 0.5)])
        let original = try XCTUnwrap(store.record(for: item.id))
        let draft = InventoryLabelBatch.draft(for: item, mode: .all, store: store)
        var queued = try entries(draft, revision: original.priceRevisionID)
        queued[0].state = .completed
        try store.observeCompletedQueue(queued)
        XCTAssertTrue(try XCTUnwrap(store.record(for: item.id)).needsLabels)
        queued[1].state = .completed
        try store.observeCompletedQueue(queued)
        let printed = try XCTUnwrap(store.record(for: item.id))
        XCTAssertEqual(printed.lastPrintedTag, .twoForOne)
        XCTAssertFalse(printed.needsLabels)
        XCTAssertTrue(InventoryLabelBatch.selectedIDs(mode: .priceChanged, inventory: [item], store: store).isEmpty)
        XCTAssertTrue(InventoryLabelBatch.shouldPrint(draft, approval: printed, mode: .all))
        XCTAssertTrue(InventoryLabelBatch.shouldPrint(draft, approval: printed, mode: .custom))
        XCTAssertFalse(InventoryLabelBatch.shouldPrint(draft, approval: printed, mode: .priceChanged))

        try store.approve([.init(id: item.id, approvedTag: .individual(0), currentMarket: 0)])
        try store.markLabeled(ids: [item.id])
        try store.approve([.init(id: item.id, approvedTag: .twoForOne, currentMarket: 0.5)])
        let current = try XCTUnwrap(store.record(for: item.id))
        XCTAssertNotEqual(current.priceRevisionID, original.priceRevisionID)
        XCTAssertTrue(current.needsLabels)
        try store.observeCompletedQueue(queued)
        XCTAssertEqual(store.record(for: item.id), current, "An old completed bulk queue cannot confirm a newer price cycle")
        XCTAssertTrue(try XCTUnwrap(store.record(for: item.id)).needsLabels)
    }

    func testBulkAndWriteInZeroCannotCompleteEachOthersApproval() throws {
        let store = store(), item = stock()
        try store.prepareForPrinting([.init(id: item.id, approvedTag: .twoForOne, currentMarket: 0.5)])
        var draft = InventoryLabelBatch.draft(for: item, mode: .all, store: store)
        var bulk = try XCTUnwrap(entries(draft, revision: store.record(for: item.id)?.priceRevisionID).first)
        XCTAssertNil(TagPricingContext.printingIssue(for: bulk, store: store))
        try store.prepareForPrinting([.init(id: item.id, approvedTag: .individual(0), currentMarket: 0)])
        XCTAssertNotNil(TagPricingContext.printingIssue(for: bulk, store: store))
        bulk.state = .completed
        try store.observeCompletedQueue([bulk])
        XCTAssertTrue(try XCTUnwrap(store.record(for: item.id)).needsLabels)
        XCTAssertNil(store.record(for: item.id)?.lastPrintedTag)

        draft.isBulk = false; draft.askingPriceText = "0"
        var zero = try XCTUnwrap(entries(draft, revision: store.record(for: item.id)?.priceRevisionID).first)
        XCTAssertNil(zero.stickerTag)
        XCTAssertEqual(zero.blankPrice, true)
        XCTAssertNil(zero.inventoryBulk)
        XCTAssertNil(TagPricingContext.printingIssue(for: zero, store: store))
        try store.prepareForPrinting([.init(id: item.id, approvedTag: .twoForOne, currentMarket: 0.5)])
        XCTAssertNil(TagPricingContext.printingIssue(for: zero, store: store), "A write-in label carries no outdated printed price")
        zero.state = .completed
        try store.observeCompletedQueue([zero])
        XCTAssertTrue(try XCTUnwrap(store.record(for: item.id)).needsLabels)
        XCTAssertNil(store.record(for: item.id)?.lastPrintedTag)
    }

    func testBulkQueueRoundTripsItsCategoryAndLegacyZeroQueuesRemainOrdinary() throws {
        var draft = InventoryLabelDraft(item: stock(quantity: 2)); draft.copies = 2
        let original = try entries(draft)
        var bytes: Data?
        let queue = LabelPrintQueue(read: { _ in bytes }, write: { data, _ in bytes = data })
        try queue.replace(with: original)
        let before = bytes
        let restored = LabelPrintQueue(read: { _ in bytes }, write: { data, _ in XCTFail("Reload cannot rewrite a pending queue") })
        XCTAssertTrue(restored.isLoaded)
        XCTAssertEqual(restored.entries, original)
        XCTAssertTrue(restored.entries.allSatisfy { $0.stickerTag == .twoForOne && $0.inventoryBulk == true })
        XCTAssertEqual(bytes, before)

        draft.isBulk = false; draft.askingPriceText = "0"; draft.copies = 1
        let zero = try XCTUnwrap(entries(draft).first)
        var row = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(zero)) as? [String: Any])
        row.removeValue(forKey: "source"); row.removeValue(forKey: "inventoryBulk"); row.removeValue(forKey: "blankPrice")
        let legacy = try JSONDecoder().decode(LabelQueueEntry.self, from: JSONSerialization.data(withJSONObject: row))
        XCTAssertNoThrow(try legacy.validate())
        XCTAssertEqual(legacy.stickerTag, .individual(0))
        XCTAssertNil(legacy.inventoryBulk)
    }

    func testMalformedBulkSourceOrPriceCannotLoadOrEnablePrinting() throws {
        let bulk = try XCTUnwrap(entries(InventoryLabelDraft(item: stock())).first)
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(bulk)) as? [String: Any])
        let mutations: [(inout [String: Any]) -> Void] = [
            { $0["priceCents"] = 100 },
            { $0["source"] = LabelQueueSource.custom.rawValue },
            { $0.removeValue(forKey: "source") },
            { $0["customBulk"] = true },
            { $0["inventoryBulk"] = "true" }
        ]
        for mutate in mutations {
            var row = original; mutate(&row)
            let bytes = try JSONSerialization.data(withJSONObject: ["version": 1, "entries": [row]])
            let queue = LabelPrintQueue(read: { _ in bytes }, write: { _, _ in XCTFail("Invalid saved data must be preserved") })
            XCTAssertFalse(queue.isLoaded)
            XCTAssertFalse(queue.canStart)
        }
    }

    func testExplicitBulkStickerRetentionAndMarkLabeledPreserveTheDeal() throws {
        let store = store(), first = stock(), second = stock()
        try store.prepareForPrinting([
            .init(id: first.id, approvedTag: .twoForOne, currentMarket: 0.5),
            .init(id: second.id, approvedTag: .twoForOne, currentMarket: 0.5)
        ], keepingExistingStickerIDs: [first.id])
        XCTAssertFalse(try XCTUnwrap(store.record(for: first.id)).needsLabels)
        XCTAssertTrue(try XCTUnwrap(store.record(for: second.id)).needsLabels)
        try store.markLabeled(ids: [second.id])
        XCTAssertTrue(store.records.allSatisfy { $0.approvedTag == .twoForOne && $0.lastPrintedTag == .twoForOne && !$0.needsLabels })
    }
}
