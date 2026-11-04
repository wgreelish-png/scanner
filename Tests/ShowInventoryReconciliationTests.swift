import XCTest
@testable import CardShowScanner

@MainActor final class ShowInventoryReconciliationTests: XCTestCase {
    private final class Disk {
        var data: Data?
        var writes = 0
        var fail = false
        var now = Date(timeIntervalSince1970: 1_800_000_000)
    }

    private func card(_ product: String = "stock", price: Decimal? = 10,
                      condition: String = "Near Mint", language: String = "English",
                      game: String = "Pokémon", sku: String? = "100") -> CardCandidate {
        CardCandidate(identity: .init(game: game, productID: product, skuID: sku,
            printing: "Normal", language: language, condition: condition),
            name: "Inventory " + product, set: "Reconciliation fixtures", number: "1",
            marketPrice: price, confidence: 100, printings: ["Normal"])
    }

    private func store(_ disk: Disk) -> ShowBudgetStore {
        ShowBudgetStore(read: { _ in disk.data }, write: { bytes, _ in
            disk.writes += 1
            if disk.fail { throw CocoaError(.fileWriteOutOfSpace) }
            disk.data = bytes
        }, now: { disk.now })
    }

    private func seed(_ source: Int = 1, card value: CardCandidate? = nil,
                      quantity: Int = 1) -> ShowInventorySeed {
        .init(sourceInventoryID: source, card: value ?? card(), quantity: quantity)
    }

    private func snapshot(_ value: String) -> Data { Data(value.utf8) }

    private func item(_ id: UUID, in ledger: ShowBudgetStore) throws -> ShowInventoryItem {
        try XCTUnwrap(ledger.inventory.first { $0.id == id })
    }

    private func total(_ ledger: ShowBudgetStore) -> Int {
        ledger.inventory.reduce(0) { $0 + $1.quantity }
    }

    private func object(_ disk: Disk) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(disk.data)) as? [String: Any])
    }

    private func assertRejected(_ value: [String: Any], file: StaticString = #filePath,
                                line: UInt = #line) throws {
        let disk = Disk()
        disk.data = try JSONSerialization.data(withJSONObject: value)
        let original = disk.data, ledger = store(disk)
        XCTAssertFalse(ledger.isLoaded, file: file, line: line)
        XCTAssertThrowsError(try ledger.reconcileInventory([seed()], sourceLocationID: 9,
            snapshotID: snapshot("replacement")), file: file, line: line)
        XCTAssertEqual(disk.data, original, file: file, line: line)
        XCTAssertEqual(disk.writes, 0, file: file, line: line)
    }

    private func legacyReplaceRetainingKnownLocalPurchase(_ disk: Disk) throws
        -> (ledger: ShowBudgetStore, showID: UUID, purchase: ShowTransactionReceipt, localID: UUID) {
        let ledger = store(disk)
        try ledger.seedInventory([seed(quantity: 2)], sourceLocationID: 9)
        let sourceID = try XCTUnwrap(ledger.inventory.first?.id)
        let showID = try ledger.create(name: "Legacy overlapping local stock", startingCents: 30_000)
        let purchase = try ledger.recordTransaction(.init(kind: .purchase,
            incoming: [.init(card: card(), quantity: 2)], incomingValueCents: 1_400), showID: showID)
        let localID = try XCTUnwrap(purchase.incoming.first?.inventoryID)
        var historical = ledger.book
        let event = ShowInventoryReconciliation(id: UUID(), sourceLocationID: 9,
            snapshotID: snapshot("historical website retains known matching purchase"), recordedAt: disk.now,
            sourceRows: [seed(quantity: 2)], createdInventoryIDs: [])
        let before = historical.inventory
        let plan = try ShowInventoryReconciliationMath.plan(event, inventory: before)
        historical.inventory = plan.inventory
        historical.inventoryReconciliations.append(event)
        historical.costMutations.append(try .capturing(kind: .reconciliation, operationID: event.id,
            recordedAt: event.recordedAt, itemIDs: plan.changedIDs, before: before, after: plan.inventory))
        try historical.validate()
        disk.data = try JSONEncoder().encode(historical)
        let reopened = store(disk)
        XCTAssertTrue(reopened.isLoaded)
        XCTAssertNil(reopened.inventoryReconciliations.last?.mode)
        XCTAssertEqual(try item(sourceID, in: reopened).quantity, 0)
        XCTAssertEqual(try item(localID, in: reopened).quantity, 2)
        XCTAssertEqual(try item(localID, in: reopened).remainingCostCents, 1_400)
        return (reopened, showID, purchase, localID)
    }

    func testSeventyFourSourceRowsReplaceEightySixWorkingCopiesWithEightyAcrossDuplicateSKULots() throws {
        let disk = Disk(), ledger = store(disk)
        let shared = card("shared")
        var existing = [seed(1, card: shared, quantity: 7), seed(2, card: shared, quantity: 7)]
        existing += (3...74).map { seed($0, card: card("product-\($0)", sku: String($0))) }
        try ledger.seedInventory(existing, sourceLocationID: 9)
        let knownID = try XCTUnwrap(ledger.inventory.first?.id)
        try ledger.setInventoryCost(itemID: knownID, totalCostCents: 1_000)
        let original = ledger.inventory
        XCTAssertEqual(total(ledger), 86)

        var refreshed = [seed(1_001, card: shared, quantity: 4), seed(1_002, card: shared, quantity: 4)]
        refreshed += (3...74).map { seed(1_000 + $0, card: card("product-\($0)", sku: String($0))) }
        XCTAssertEqual(refreshed.count, 74)
        let result = try ledger.reconcileInventory(refreshed, sourceLocationID: 9,
            snapshotID: snapshot("74 rows / 80 copies"))

        XCTAssertEqual(result.totalQuantity, 80)
        XCTAssertEqual(result.addedQuantity, 0)
        XCTAssertEqual(result.removedQuantity, 6)
        XCTAssertFalse(result.unchangedSnapshot)
        XCTAssertEqual(total(ledger), 80)
        XCTAssertEqual(ledger.inventory.map(\.id), original.map(\.id))
        XCTAssertEqual(ledger.inventory.map(\.card), original.map(\.card))
        XCTAssertEqual(try item(knownID, in: ledger).quantity, 7)
        XCTAssertEqual(try item(knownID, in: ledger).remainingCostCents, 1_000)
        XCTAssertEqual(ledger.inventory.filter { $0.card.identity == shared.identity }.map(\.quantity).sorted(), [1, 7])
        XCTAssertEqual(ledger.inventoryReconciliations.count, 1)
        XCTAssertEqual(store(disk).book, ledger.book)
    }

    func testReductionKeepsReceiptQuotesLotIdentityAndEveryRemainingCostCentWithoutPostingCash() throws {
        let disk = Disk(), ledger = store(disk)
        let originalCard = card(price: 10)
        try ledger.seedInventory([seed(card: originalCard, quantity: 3)], sourceLocationID: 9)
        let stockID = try XCTUnwrap(ledger.inventory.first?.id)
        try ledger.setInventoryCost(itemID: stockID, totalCostCents: 1_000)
        let showID = try ledger.create(name: "Inventory show", startingCents: 30_000)
        let sold = try ledger.recordTransaction(.init(kind: .sale,
            outgoing: [.init(inventoryID: stockID, quantity: 1)], saleReceivedCents: 1_000), showID: showID)
        let cash = try XCTUnwrap(ledger.activeShow).totals()
        let profit = try ledger.profitSummary()
        let adjustments = ledger.costAdjustments

        let result = try ledger.reconcileInventory([seed(99, card: card(price: 99), quantity: 1)],
            sourceLocationID: 9, snapshotID: snapshot("reduce after sale"))

        XCTAssertEqual(result.removedQuantity, 1)
        let retained = try item(stockID, in: ledger)
        XCTAssertEqual(retained.quantity, 1)
        XCTAssertEqual(retained.remainingCostCents, 333)
        XCTAssertEqual(retained.card, originalCard)
        XCTAssertEqual(ledger.transactions, [sold])
        XCTAssertEqual(sold.totalCostCents, 334)
        XCTAssertEqual(sold.outgoing.first?.card, originalCard)
        XCTAssertEqual(try XCTUnwrap(ledger.activeShow).totals(), cash)
        XCTAssertEqual(try ledger.profitSummary(), profit)
        XCTAssertEqual(ledger.costAdjustments, adjustments)
        let mutation = try XCTUnwrap(ledger.book.costMutations.last)
        XCTAssertEqual(mutation.kind, .reconciliation)
        XCTAssertEqual(mutation.changes.first?.before?.quantity, 2)
        XCTAssertEqual(mutation.changes.first?.before?.remainingCostCents, 666)
        XCTAssertEqual(mutation.changes.first?.after.quantity, 1)
        XCTAssertEqual(mutation.changes.first?.after.remainingCostCents, 333)
        XCTAssertEqual(store(disk).book, ledger.book)
    }

    func testIncreaseAddsOnlyNetNewCopiesAsSeparateUnknownCostLots() throws {
        let disk = Disk(), ledger = store(disk)
        try ledger.seedInventory([seed(quantity: 2)], sourceLocationID: 9)
        let original = try XCTUnwrap(ledger.inventory.first)
        try ledger.setInventoryCost(itemID: original.id, totalCostCents: 1_400)
        let retained = try item(original.id, in: ledger)

        let result = try ledger.reconcileInventory([seed(100, card: card(price: 90), quantity: 5)],
            sourceLocationID: 9, snapshotID: snapshot("increase"))

        XCTAssertEqual(result.addedQuantity, 3)
        XCTAssertEqual(result.removedQuantity, 0)
        XCTAssertEqual(total(ledger), 5)
        XCTAssertEqual(try item(original.id, in: ledger), retained)
        let added = try XCTUnwrap(ledger.inventory.first { $0.id != original.id })
        XCTAssertEqual(added.quantity, 3)
        XCTAssertNil(added.remainingCostCents)
        XCTAssertNil(added.acquiredByTransactionID)
        XCTAssertEqual(added.acquiredByReconciliationID, ledger.inventoryReconciliations.first?.id)
        XCTAssertEqual(added.card.marketPrice, 90)
        XCTAssertEqual(ledger.inventoryReconciliations.first?.createdInventoryIDs, [added.id])
        XCTAssertTrue(ledger.transactions.isEmpty)
        XCTAssertTrue(ledger.book.shows.isEmpty)
        XCTAssertEqual(store(disk).book, ledger.book)
    }

    func testDuplicateSourceRowsCanExceedOneLotQuantityLimitWithoutLosingCopies() throws {
        let disk = Disk(), ledger = store(disk)
        let limit = ShowBudgetBook.maximumQuantity
        let source = [seed(1, quantity: limit), seed(2, quantity: 7)]

        let result = try ledger.reconcileInventory(source, sourceLocationID: 9,
            snapshotID: snapshot("aggregate larger than one lot"))

        XCTAssertEqual(result.addedQuantity, limit + 7)
        XCTAssertEqual(result.totalQuantity, limit + 7)
        XCTAssertEqual(ledger.inventory.map(\.quantity).sorted(), [7, limit])
        XCTAssertEqual(Set(ledger.inventory.map { $0.card.identity }).count, 1)
        XCTAssertTrue(ledger.inventory.allSatisfy { $0.remainingCostCents == nil })
        XCTAssertEqual(ledger.inventoryReconciliations.first?.createdInventoryIDs.count, 2)
        XCTAssertEqual(store(disk).book, ledger.book)
    }

    func testExactVariantIdentityIncludesGameLanguageConditionAndSKU() throws {
        let disk = Disk(), ledger = store(disk)
        let variants = [card(), card(condition: "Lightly Played"), card(language: "Japanese"),
            card(game: "Magic"), card(sku: "200"), card(sku: nil)]
        XCTAssertEqual(Set(variants.prefix(4).map(\.id)).count, 1,
            "CardCandidate.id alone omits game, language, and condition")
        try ledger.seedInventory(variants.enumerated().map { seed($0.offset + 1, card: $0.element, quantity: 2) },
            sourceLocationID: 9)
        let ids = ledger.inventory.map(\.id)
        let refreshed = variants.enumerated().map { seed(100 + $0.offset, card: $0.element, quantity: $0.offset % 2 == 0 ? 1 : 2) }

        let result = try ledger.reconcileInventory(refreshed, sourceLocationID: 9,
            snapshotID: snapshot("exact variants"))

        XCTAssertEqual(result.addedQuantity, 0)
        XCTAssertEqual(result.removedQuantity, 3)
        XCTAssertEqual(ledger.inventory.map(\.id), ids)
        XCTAssertEqual(ledger.inventory.map(\.quantity), [1, 2, 1, 2, 1, 2])
        XCTAssertEqual(store(disk).book, ledger.book)
    }

    func testSourceIdentityChangeRetiresOldConditionWithoutMutatingReceiptCard() throws {
        let disk = Disk(), ledger = store(disk)
        let nearMint = card()
        try ledger.seedInventory([seed(card: nearMint, quantity: 2)], sourceLocationID: 9)
        let original = try XCTUnwrap(ledger.inventory.first)
        try ledger.setInventoryCost(itemID: original.id, totalCostCents: 1_400)
        let showID = try ledger.create(name: "Variant show", startingCents: 10_000)
        let sold = try ledger.recordTransaction(.init(kind: .sale,
            outgoing: [.init(inventoryID: original.id, quantity: 1)], saleReceivedCents: 1_000), showID: showID)
        let lightlyPlayed = card(price: 7, condition: "Lightly Played")
        let result = try ledger.reconcileInventory([seed(card: lightlyPlayed, quantity: 1)],
            sourceLocationID: 9, snapshotID: snapshot("condition corrected"))

        XCTAssertEqual(result.addedQuantity, 1)
        XCTAssertEqual(result.removedQuantity, 1)
        XCTAssertEqual(try item(original.id, in: ledger).quantity, 0)
        XCTAssertEqual(try item(original.id, in: ledger).remainingCostCents, 0)
        XCTAssertEqual(try item(original.id, in: ledger).card, nearMint)
        XCTAssertEqual(ledger.transactions, [sold])
        let replacement = try XCTUnwrap(ledger.inventory.first { $0.id != original.id })
        XCTAssertEqual(replacement.card, lightlyPlayed)
        XCTAssertNil(replacement.remainingCostCents)
        XCTAssertEqual(store(disk).book, ledger.book)
    }

    func testFreshImportKeepsMissingLocalPurchaseWithItsCostAndCashHistory() throws {
        let disk = Disk(), ledger = store(disk)
        try ledger.seedInventory([seed(quantity: 2)], sourceLocationID: 9)
        let showID = try ledger.create(name: "Local purchase show", startingCents: 30_000)
        let bought = try ledger.recordTransaction(.init(kind: .purchase,
            incoming: [.init(card: card("local"), quantity: 3)], incomingValueCents: 2_100), showID: showID)
        let acquiredID = try XCTUnwrap(bought.incoming.first?.inventoryID)
        let acquired = try item(acquiredID, in: ledger)
        let cash = try XCTUnwrap(ledger.activeShow).totals()

        let result = try ledger.reconcileInventory([seed(quantity: 2)], sourceLocationID: 9,
            snapshotID: snapshot("website omits purchase"))

        XCTAssertEqual(result.removedQuantity, 0)
        XCTAssertEqual(result.totalQuantity, 5)
        XCTAssertEqual(total(ledger), 5)
        XCTAssertEqual(try item(acquiredID, in: ledger), acquired)
        XCTAssertEqual(ledger.transactions, [bought])
        XCTAssertEqual(try XCTUnwrap(ledger.activeShow).totals(), cash)
        XCTAssertEqual(ledger.inventoryReconciliations.last?.mode, .merge)
        try ledger.undoTransaction(bought.id)
        XCTAssertEqual(try item(acquiredID, in: ledger).quantity, 0)
        XCTAssertEqual(total(ledger), 2)
        XCTAssertEqual(store(disk).book, ledger.book)
    }

    func testMergeAdoptsNewWebsiteCopiesWithoutDuplicatingLocalStockOrLosingCost() throws {
        let disk = Disk(), ledger = store(disk)
        try ledger.seedInventory([seed(quantity: 2)], sourceLocationID: 9)
        let showID = try ledger.create(name: "Local and source copies", startingCents: 30_000)
        let bought = try ledger.recordTransaction(.init(kind: .purchase,
            incoming: [.init(card: card("newly uploaded"), quantity: 3)], incomingValueCents: 1_000), showID: showID)
        let localID = try XCTUnwrap(bought.incoming.first?.inventoryID)
        let local = try item(localID, in: ledger)
        let cash = try XCTUnwrap(ledger.activeShow).totals()
        let rows = [seed(quantity: 2), seed(2, card: card("newly uploaded"), quantity: 2)]
        let marker = snapshot("two local copies now on the website")

        let result = try ledger.reconcileInventory(rows, sourceLocationID: 9, snapshotID: marker)
        XCTAssertEqual(result.totalQuantity, 5, "The two matched website copies must not duplicate the locally bought cards")
        let retained = try item(localID, in: ledger)
        XCTAssertEqual(retained.quantity, 1); XCTAssertEqual(retained.remainingCostCents, 333)
        XCTAssertEqual(retained.acquiredByTransactionID, bought.id)
        let adopted = try XCTUnwrap(ledger.inventory.first { $0.adoptedFromInventoryID == localID })
        XCTAssertEqual(adopted.quantity, 2); XCTAssertEqual(adopted.remainingCostCents, 667)
        XCTAssertEqual(adopted.sourceInventoryID, 2); XCTAssertEqual(adopted.sourceLocationID, 9)
        XCTAssertNil(adopted.acquiredByTransactionID)
        XCTAssertEqual(adopted.acquiredByReconciliationID, ledger.inventoryReconciliations.last?.id)
        let retainedCost = try XCTUnwrap(retained.remainingCostCents)
        let adoptedCost = try XCTUnwrap(adopted.remainingCostCents)
        XCTAssertEqual(retainedCost + adoptedCost, try XCTUnwrap(local.remainingCostCents))
        XCTAssertEqual(ledger.transactions, [bought]); XCTAssertEqual(bought.incoming.first?.inventoryID, localID)
        XCTAssertEqual(try XCTUnwrap(ledger.activeShow).totals(), cash)
        XCTAssertEqual(store(disk).book, ledger.book)

        let saved = ledger.book, writes = disk.writes
        XCTAssertTrue(try ledger.reconcileInventory(rows, sourceLocationID: 9, snapshotID: marker).unchangedSnapshot)
        XCTAssertEqual(ledger.book, saved); XCTAssertEqual(disk.writes, writes)
        _ = try ledger.reconcileInventory(rows, sourceLocationID: 9, snapshotID: snapshot("same website quantities fetched again"))
        XCTAssertEqual(try item(localID, in: ledger), retained)
        XCTAssertEqual(try item(adopted.id, in: ledger), adopted)
        XCTAssertEqual(total(ledger), 5)
        XCTAssertThrowsError(try ledger.undoTransaction(bought.id)) {
            XCTAssertEqual($0 as? ShowTransactionFailure, .inventoryReconciled,
                           "Adopted copies retain their purchase provenance; Undo cannot strand them in source stock")
        }
        XCTAssertEqual(store(disk).book, ledger.book)

        let reopened = store(disk)
        let sold = try reopened.recordTransaction(.init(kind: .sale,
            outgoing: [.init(inventoryID: adopted.id, quantity: 1)], saleReceivedCents: 1_000), showID: showID)
        XCTAssertEqual(sold.totalCostCents, 334)
        XCTAssertEqual(try item(adopted.id, in: reopened).quantity, 1)
        XCTAssertEqual(try item(adopted.id, in: reopened).remainingCostCents, 333)
        XCTAssertEqual(try item(adopted.id, in: reopened).adoptedFromInventoryID, localID)
        XCTAssertEqual(try item(localID, in: reopened), retained)
        XCTAssertEqual(reopened.transactions.first, bought)
        XCTAssertEqual(total(reopened), 4)
        XCTAssertEqual(store(disk).book, reopened.book)
    }

    func testReplaceRemovesUnmatchedLocalStockWhilePreservingReceiptAndCashHistory() throws {
        let disk = Disk(), ledger = store(disk)
        try ledger.seedInventory([seed(quantity: 2)], sourceLocationID: 9)
        let showID = try ledger.create(name: "Replace website inventory", startingCents: 30_000)
        let bought = try ledger.recordTransaction(.init(kind: .purchase,
            incoming: [.init(card: card("not on website"), quantity: 3)], incomingValueCents: 2_100), showID: showID)
        let localID = try XCTUnwrap(bought.incoming.first?.inventoryID)
        let cash = try XCTUnwrap(ledger.activeShow).totals()
        let result = try ledger.reconcileInventory([seed(quantity: 2)], sourceLocationID: 9,
            snapshotID: snapshot("explicit replace"), mode: .replace)
        XCTAssertEqual(result.totalQuantity, 2); XCTAssertEqual(result.removedQuantity, 3)
        XCTAssertEqual(try item(localID, in: ledger).quantity, 0)
        XCTAssertEqual(try item(localID, in: ledger).remainingCostCents, 0)
        XCTAssertEqual(ledger.transactions, [bought]); XCTAssertEqual(try XCTUnwrap(ledger.activeShow).totals(), cash)
        XCTAssertEqual(ledger.inventoryReconciliations.last?.mode, .replace)
        XCTAssertEqual(store(disk).book, ledger.book)
    }

    func testMergeDecreaseConsumesOnlySourceCostForTheSameCardIdentity() throws {
        let disk = Disk(), ledger = store(disk)
        try ledger.seedInventory([seed(quantity: 4)], sourceLocationID: 9)
        let sourceID = try XCTUnwrap(ledger.inventory.first?.id)
        try ledger.setInventoryCost(itemID: sourceID, totalCostCents: 1_000)
        let showID = try ledger.create(name: "Source decrease keeps local copies", startingCents: 30_000)
        let bought = try ledger.recordTransaction(.init(kind: .purchase,
            incoming: [.init(card: card(), quantity: 2)], incomingValueCents: 1_400), showID: showID)
        let localID = try XCTUnwrap(bought.incoming.first?.inventoryID)
        let local = try item(localID, in: ledger)
        let cash = try XCTUnwrap(ledger.activeShow).totals()

        let result = try ledger.reconcileInventory([seed(quantity: 1)], sourceLocationID: 9,
            snapshotID: snapshot("website reduces the shared identity"))

        XCTAssertEqual(result.removedQuantity, 3); XCTAssertEqual(result.addedQuantity, 0)
        XCTAssertEqual(result.totalQuantity, 3)
        XCTAssertEqual(try item(sourceID, in: ledger).quantity, 1)
        XCTAssertEqual(try item(sourceID, in: ledger).remainingCostCents, 250)
        XCTAssertEqual(try item(localID, in: ledger), local)
        XCTAssertEqual(ledger.transactions, [bought]); XCTAssertEqual(try XCTUnwrap(ledger.activeShow).totals(), cash)
        XCTAssertEqual(store(disk).book, ledger.book)
    }

    func testReplaceAdoptsSurvivingLocalCopiesBeforeAnUnchangedMerge() throws {
        let disk = Disk(), ledger = store(disk)
        try ledger.seedInventory([seed(quantity: 2)], sourceLocationID: 9)
        let showID = try ledger.create(name: "Replace then merge", startingCents: 30_000)
        let bought = try ledger.recordTransaction(.init(kind: .purchase,
            incoming: [.init(card: card("surviving local"), quantity: 2)], incomingValueCents: 1_000), showID: showID)
        let localID = try XCTUnwrap(bought.incoming.first?.inventoryID)
        let source = [seed(2, card: card("surviving local"), quantity: 1)]
        let cash = try XCTUnwrap(ledger.activeShow).totals()

        let replaced = try ledger.reconcileInventory(source, sourceLocationID: 9,
            snapshotID: snapshot("replace keeps one known local copy"), mode: .replace)

        XCTAssertEqual(replaced.totalQuantity, 1)
        XCTAssertEqual(try item(localID, in: ledger).quantity, 0)
        XCTAssertEqual(try item(localID, in: ledger).remainingCostCents, 0)
        let adopted = try XCTUnwrap(ledger.inventory.first { $0.adoptedFromInventoryID == localID })
        XCTAssertEqual(adopted.quantity, 1); XCTAssertEqual(adopted.remainingCostCents, 500)
        XCTAssertEqual(adopted.sourceInventoryID, 2)
        XCTAssertNil(adopted.acquiredByTransactionID)
        XCTAssertEqual(ledger.transactions, [bought]); XCTAssertEqual(try XCTUnwrap(ledger.activeShow).totals(), cash)
        XCTAssertEqual(store(disk).book, ledger.book)

        let merged = try ledger.reconcileInventory(source, sourceLocationID: 9,
            snapshotID: snapshot("merge after explicit replace"))
        XCTAssertEqual(merged.totalQuantity, 1); XCTAssertEqual(merged.addedQuantity, 0)
        XCTAssertEqual(try item(adopted.id, in: ledger), adopted)
        XCTAssertThrowsError(try ledger.undoTransaction(bought.id)) {
            XCTAssertEqual($0 as? ShowTransactionFailure, .inventoryReconciled)
        }
        XCTAssertEqual(store(disk).book, ledger.book)
    }

    func testMergeNeverAdoptsLocalCardsWithAnotherLanguageConditionOrSKU() throws {
        let disk = Disk(), ledger = store(disk)
        try ledger.seedInventory([seed()], sourceLocationID: 9)
        let showID = try ledger.create(name: "Exact local identity", startingCents: 30_000)
        let variants = [card("variant", condition: "Lightly Played"), card("variant", language: "Japanese"),
                        card("variant", sku: "200")]
        let bought = try ledger.recordTransaction(.init(kind: .purchase,
            incoming: variants.map { .init(card: $0, quantity: 1) }, incomingValueCents: 900), showID: showID)
        let locals = try bought.incoming.map { try item($0.inventoryID, in: ledger) }

        let result = try ledger.reconcileInventory([seed(), seed(2, card: card("variant"))],
            sourceLocationID: 9, snapshotID: snapshot("different exact local variants"))

        XCTAssertEqual(result.addedQuantity, 1); XCTAssertEqual(result.totalQuantity, 5)
        for local in locals { XCTAssertEqual(try item(local.id, in: ledger), local) }
        XCTAssertFalse(ledger.inventory.contains { $0.adoptedFromInventoryID != nil })
        XCTAssertEqual(ledger.transactions, [bought])
        XCTAssertEqual(store(disk).book, ledger.book)
    }

    func testUnchangedWebsiteBaselineAfterLocalSalesDoesNotAdoptRemainingLocalCopies() throws {
        let disk = Disk(), ledger = store(disk)
        let source = [seed(quantity: 3)]
        try ledger.seedInventory(source, sourceLocationID: 9)
        _ = try ledger.reconcileInventory(source, sourceLocationID: 9, snapshotID: snapshot("prior website count"))
        let sourceID = try XCTUnwrap(ledger.inventory.first?.id)
        let showID = try ledger.create(name: "Local sales keep website baseline", startingCents: 30_000)
        _ = try ledger.recordTransaction(.init(kind: .sale,
            outgoing: [.init(inventoryID: sourceID, quantity: 2)], saleReceivedCents: 2_000), showID: showID)
        let bought = try ledger.recordTransaction(.init(kind: .purchase,
            incoming: [.init(card: card(), quantity: 2)], incomingValueCents: 1_000), showID: showID)
        let localID = try XCTUnwrap(bought.incoming.first?.inventoryID)
        let soldLocal = try ledger.recordTransaction(.init(kind: .sale,
            outgoing: [.init(inventoryID: localID, quantity: 1)], saleReceivedCents: 1_000), showID: showID)
        let local = try item(localID, in: ledger)
        XCTAssertEqual(local.quantity, 1); XCTAssertEqual(local.remainingCostCents, 500)

        let result = try ledger.reconcileInventory(source, sourceLocationID: 9,
            snapshotID: snapshot("unchanged website after local sales"))

        XCTAssertEqual(result.addedQuantity, 2); XCTAssertEqual(result.removedQuantity, 0)
        XCTAssertEqual(result.totalQuantity, 4)
        XCTAssertEqual(try item(localID, in: ledger), local)
        XCTAssertFalse(ledger.inventory.contains { $0.adoptedFromInventoryID != nil })
        XCTAssertEqual(store(disk).book, ledger.book)
        try ledger.undoTransaction(soldLocal.id)
        XCTAssertEqual(try item(localID, in: ledger).quantity, 2)
        XCTAssertEqual(try item(localID, in: ledger).remainingCostCents, 1_000)
        XCTAssertEqual(total(ledger), 5)
        XCTAssertEqual(store(disk).book, ledger.book)
    }

    func testFailedMergeAdoptionLeavesEveryLocalCostCentAvailableForRetryAfterReopen() throws {
        let disk = Disk(), ledger = store(disk)
        try ledger.seedInventory([seed()], sourceLocationID: 9)
        let showID = try ledger.create(name: "Atomic adoption", startingCents: 30_000)
        let bought = try ledger.recordTransaction(.init(kind: .purchase,
            incoming: [.init(card: card("uploaded"), quantity: 3)], incomingValueCents: 1_000), showID: showID)
        let localID = try XCTUnwrap(bought.incoming.first?.inventoryID)
        let before = ledger.book, bytes = disk.data
        let source = [seed(), seed(2, card: card("uploaded"), quantity: 2)]
        let marker = snapshot("retry atomic adoption")
        disk.fail = true

        XCTAssertThrowsError(try ledger.reconcileInventory(source, sourceLocationID: 9, snapshotID: marker))
        XCTAssertEqual(ledger.book, before); XCTAssertEqual(disk.data, bytes)
        XCTAssertNil(ledger.lastInventorySnapshotID)
        XCTAssertEqual(try item(localID, in: ledger).quantity, 3)
        XCTAssertEqual(try item(localID, in: ledger).remainingCostCents, 1_000)
        let reopened = store(disk)
        XCTAssertEqual(reopened.book, before)
        disk.fail = false

        let result = try reopened.reconcileInventory(source, sourceLocationID: 9, snapshotID: marker)
        XCTAssertEqual(result.totalQuantity, 4); XCTAssertEqual(result.addedQuantity, 0)
        XCTAssertEqual(try item(localID, in: reopened).quantity, 1)
        XCTAssertEqual(try item(localID, in: reopened).remainingCostCents, 333)
        let adopted = try XCTUnwrap(reopened.inventory.first { $0.adoptedFromInventoryID == localID })
        XCTAssertEqual(adopted.quantity, 2); XCTAssertEqual(adopted.remainingCostCents, 667)
        XCTAssertEqual(reopened.transactions, [bought]); XCTAssertEqual(reopened.lastInventorySnapshotID, marker)
        XCTAssertEqual(store(disk).book, reopened.book)
    }

    func testTradeAcquisitionRemainsAvailableForSaleAfterAnEmptyWebsiteRefresh() throws {
        let disk = Disk(), ledger = store(disk)
        try ledger.seedInventory([seed(quantity: 2)], sourceLocationID: 9)
        let sourceID = try XCTUnwrap(ledger.inventory.first?.id)
        try ledger.setInventoryCost(itemID: sourceID, totalCostCents: 1_400)
        let showID = try ledger.create(name: "Trade and sell locally", startingCents: 30_000)
        let traded = try ledger.recordTransaction(.init(kind: .trade,
            incoming: [.init(card: card("trade acquisition"), quantity: 3)],
            outgoing: [.init(inventoryID: sourceID, quantity: 1)],
            incomingValueCents: 2_000, outgoingValueCents: 2_000), showID: showID)
        let localID = try XCTUnwrap(traded.incoming.first?.inventoryID)
        let local = try item(localID, in: ledger)
        let cash = try XCTUnwrap(ledger.activeShow).totals()

        let refreshed = try ledger.reconcileInventory([], sourceLocationID: 9,
            snapshotID: snapshot("empty website keeps the received trade cards"))
        XCTAssertEqual(refreshed.removedQuantity, 1)
        XCTAssertEqual(refreshed.totalQuantity, 3)
        XCTAssertEqual(try item(localID, in: ledger), local)
        XCTAssertEqual(try XCTUnwrap(ledger.activeShow).totals(), cash)
        let reopened = store(disk)
        XCTAssertTrue(reopened.isLoaded)
        XCTAssertEqual(try item(localID, in: reopened), local)

        let sold = try reopened.recordTransaction(.init(kind: .sale,
            outgoing: [.init(inventoryID: localID, quantity: 1)], saleReceivedCents: 1_000), showID: showID)
        XCTAssertEqual(try item(localID, in: reopened).quantity, 2)
        let consumed = try XCTUnwrap(sold.accounting?.outgoing.first?.totalCostCents)
        XCTAssertEqual(try item(localID, in: reopened).remainingCostCents, try XCTUnwrap(local.remainingCostCents) - consumed)
        XCTAssertEqual(store(disk).book, reopened.book)
        XCTAssertThrowsError(try reopened.undoTransaction(traded.id)) {
            XCTAssertEqual($0 as? ShowTransactionFailure, .inventoryReconciled,
                           "The imported outgoing lot changed, so Undo must not restore source copies")
        }
    }

    func testLegacyReconciliationWithoutPolicyReplaysWithoutRevivingRetiredLocalCards() throws {
        let disk = Disk(), ledger = store(disk)
        try ledger.seedInventory([seed(quantity: 2)], sourceLocationID: 9)
        let showID = try ledger.create(name: "Historical authoritative import", startingCents: 30_000)
        let bought = try ledger.recordTransaction(.init(kind: .purchase,
            incoming: [.init(card: card("historically removed"), quantity: 3)], incomingValueCents: 2_100), showID: showID)
        let localID = try XCTUnwrap(bought.incoming.first?.inventoryID)
        var historical = ledger.book
        let event = ShowInventoryReconciliation(id: UUID(), sourceLocationID: 9,
            snapshotID: snapshot("old all-stock refresh"), recordedAt: disk.now,
            sourceRows: [seed(quantity: 2)], createdInventoryIDs: [])
        let before = historical.inventory
        let plan = try ShowInventoryReconciliationMath.plan(event, inventory: before)
        XCTAssertEqual(plan.summary.removedQuantity, 3, "An event without the new policy uses its original all-stock rules")
        historical.inventory = plan.inventory
        historical.inventoryReconciliations.append(event)
        historical.costMutations.append(try .capturing(kind: .reconciliation, operationID: event.id,
            recordedAt: event.recordedAt, itemIDs: plan.changedIDs, before: before, after: plan.inventory))
        try historical.validate()
        var document = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(historical)) as? [String: Any])
        var events = try XCTUnwrap(document["inventoryReconciliations"] as? [[String: Any]])
        for index in events.indices { events[index].removeValue(forKey: "mode") }
        document["inventoryReconciliations"] = events
        disk.data = try JSONSerialization.data(withJSONObject: document)
        let bytes = disk.data, writes = disk.writes

        let reopened = store(disk)
        XCTAssertTrue(reopened.isLoaded)
        XCTAssertEqual(try item(localID, in: reopened).quantity, 0)
        XCTAssertEqual(try item(localID, in: reopened).remainingCostCents, 0)
        XCTAssertEqual(reopened.transactions, [bought])
        XCTAssertEqual(disk.data, bytes); XCTAssertEqual(disk.writes, writes)
        XCTAssertNil(reopened.inventoryReconciliations.first?.mode)
        XCTAssertEqual(reopened.inventoryReconciliations.first?.effectiveMode, .replace)
        XCTAssertThrowsError(try reopened.undoTransaction(bought.id)) {
            XCTAssertEqual($0 as? ShowTransactionFailure, .inventoryReconciled)
        }
        _ = try reopened.reconcileInventory([seed(quantity: 2)], sourceLocationID: 9,
            snapshotID: snapshot("new source-only refresh"))
        XCTAssertEqual(try item(localID, in: reopened).quantity, 0, "The new policy must not guess that an old retired lot can be restored")
        XCTAssertEqual(reopened.inventoryReconciliations.last?.mode, .merge)
        XCTAssertEqual(store(disk).book, reopened.book)
    }

    func testFirstMergeAdoptsLegacyMatchingLocalSurvivorWithoutAdoptingLaterPurchase() throws {
        let disk = Disk()
        let legacy = try legacyReplaceRetainingKnownLocalPurchase(disk)
        let ledger = legacy.ledger
        let later = try ledger.recordTransaction(.init(kind: .purchase,
            incoming: [.init(card: card(), quantity: 1)], incomingValueCents: 600), showID: legacy.showID)
        let laterID = try XCTUnwrap(later.incoming.first?.inventoryID)
        let laterLot = try item(laterID, in: ledger)
        let cash = try XCTUnwrap(ledger.activeShow).totals()

        let result = try ledger.reconcileInventory([seed(quantity: 2)], sourceLocationID: 9,
            snapshotID: snapshot("first merge after historical matching-local replace"))

        XCTAssertEqual(result.totalQuantity, 3)
        XCTAssertEqual(result.addedQuantity, 0); XCTAssertEqual(result.removedQuantity, 0)
        XCTAssertEqual(try item(legacy.localID, in: ledger).quantity, 0)
        XCTAssertEqual(try item(legacy.localID, in: ledger).remainingCostCents, 0)
        let adopted = try XCTUnwrap(ledger.inventory.first { $0.adoptedFromInventoryID == legacy.localID })
        XCTAssertEqual(adopted.quantity, 2); XCTAssertEqual(adopted.remainingCostCents, 1_400)
        XCTAssertEqual(adopted.sourceInventoryID, 1); XCTAssertNil(adopted.acquiredByTransactionID)
        XCTAssertEqual(try item(laterID, in: ledger), laterLot)
        XCTAssertEqual(ledger.transactions, [legacy.purchase, later])
        XCTAssertEqual(try XCTUnwrap(ledger.activeShow).totals(), cash)
        XCTAssertEqual(store(disk).book, ledger.book)

        _ = try ledger.reconcileInventory([seed(quantity: 2)], sourceLocationID: 9,
            snapshotID: snapshot("later unchanged merge after historical overlap consumed"))
        XCTAssertEqual(total(ledger), 3)
        XCTAssertEqual(try item(laterID, in: ledger), laterLot)
        XCTAssertEqual(try item(adopted.id, in: ledger), adopted)
        try ledger.undoTransaction(later.id)
        XCTAssertEqual(total(ledger), 2)
        XCTAssertEqual(try item(adopted.id, in: ledger), adopted)
        XCTAssertEqual(store(disk).book, ledger.book)
    }

    func testFirstMergeRetiresLegacyLocalOverlapButKeepsPurchasesMadeAfterLegacyReplace() throws {
        for websiteQuantity in [1, 0] {
            let disk = Disk()
            let legacy = try legacyReplaceRetainingKnownLocalPurchase(disk)
            let ledger = legacy.ledger
            let later = try ledger.recordTransaction(.init(kind: .purchase,
                incoming: [.init(card: card(), quantity: 2)], incomingValueCents: 1_000), showID: legacy.showID)
            let laterID = try XCTUnwrap(later.incoming.first?.inventoryID)
            let laterLot = try item(laterID, in: ledger)
            let cash = try XCTUnwrap(ledger.activeShow).totals()
            let source = websiteQuantity == 0 ? [] : [seed(quantity: websiteQuantity)]

            let result = try ledger.reconcileInventory(source, sourceLocationID: 9,
                snapshotID: snapshot("first merge reduces historical overlap to \(websiteQuantity)"))

            XCTAssertEqual(result.totalQuantity, websiteQuantity + 2)
            XCTAssertEqual(result.addedQuantity, 0); XCTAssertEqual(result.removedQuantity, 2 - websiteQuantity)
            XCTAssertEqual(try item(legacy.localID, in: ledger).quantity, 0)
            XCTAssertEqual(try item(legacy.localID, in: ledger).remainingCostCents, 0)
            let adopted = ledger.inventory.filter { $0.adoptedFromInventoryID == legacy.localID }
            XCTAssertEqual(adopted.reduce(0) { $0 + $1.quantity }, websiteQuantity)
            XCTAssertEqual(adopted.compactMap(\.remainingCostCents).reduce(0, +), Int64(websiteQuantity * 700))
            XCTAssertEqual(try item(laterID, in: ledger), laterLot)
            XCTAssertEqual(ledger.transactions, [legacy.purchase, later])
            XCTAssertEqual(try XCTUnwrap(ledger.activeShow).totals(), cash)
            XCTAssertEqual(store(disk).book, ledger.book)
        }
    }

    func testChangingOrRemovingMergeModeCannotReinterpretTheNewJournal() throws {
        let disk = Disk(), ledger = store(disk)
        try ledger.seedInventory([seed(quantity: 1)], sourceLocationID: 9)
        let showID = try ledger.create(name: "Preserved import proof", startingCents: 30_000)
        _ = try ledger.recordTransaction(.init(kind: .purchase,
            incoming: [.init(card: card("protected local"), quantity: 2)], incomingValueCents: 1_000), showID: showID)
        _ = try ledger.reconcileInventory([], sourceLocationID: 9, snapshotID: snapshot("source absent, local kept"))
        let valid = try object(disk)
        for mode in [ShowInventoryImportMode.replace.rawValue, nil] as [String?] {
            var changed = valid
            var events = try XCTUnwrap(changed["inventoryReconciliations"] as? [[String: Any]])
            if let mode { events[0]["mode"] = mode }
            else { events[0].removeValue(forKey: "mode") }
            changed["inventoryReconciliations"] = events
            try assertRejected(changed)
        }
    }

    func testReductionPrefersUnknownCostBeforeKnownAndNewerBeforeOlderLots() throws {
        let disk = Disk(), ledger = store(disk)
        try ledger.seedInventory([seed(quantity: 2)], sourceLocationID: 9)
        let knownID = try XCTUnwrap(ledger.inventory.first?.id)
        try ledger.setInventoryCost(itemID: knownID, totalCostCents: 1_400)
        _ = try ledger.reconcileInventory([seed(quantity: 4)], sourceLocationID: 9,
            snapshotID: snapshot("add unknown older"))
        let older = try XCTUnwrap(ledger.inventory.first { $0.id != knownID })
        disk.now.addTimeInterval(10)
        _ = try ledger.reconcileInventory([seed(quantity: 6)], sourceLocationID: 9,
            snapshotID: snapshot("add unknown newer"))
        let newer = try XCTUnwrap(ledger.inventory.first { $0.id != knownID && $0.id != older.id })

        _ = try ledger.reconcileInventory([seed(quantity: 3)], sourceLocationID: 9,
            snapshotID: snapshot("remove unknown first"))

        XCTAssertEqual(try item(knownID, in: ledger).quantity, 2)
        XCTAssertEqual(try item(knownID, in: ledger).remainingCostCents, 1_400)
        XCTAssertEqual(try item(newer.id, in: ledger).quantity, 0)
        XCTAssertEqual(try item(older.id, in: ledger).quantity, 1)
        XCTAssertEqual(store(disk).book, ledger.book)
    }

    func testSameSnapshotAfterLocalSaleAndCostEditDoesNotRestockOrRewriteMarker() throws {
        let disk = Disk(), ledger = store(disk)
        let source = [seed(quantity: 3)], marker = snapshot("one durable source snapshot")
        _ = try ledger.reconcileInventory(source, sourceLocationID: 9, snapshotID: marker)
        let stockID = try XCTUnwrap(ledger.inventory.first?.id)
        let showID = try ledger.create(name: "Snapshot show", startingCents: 30_000)
        _ = try ledger.recordTransaction(.init(kind: .sale,
            outgoing: [.init(inventoryID: stockID, quantity: 1)], saleReceivedCents: 1_000), showID: showID)
        try ledger.setInventoryCost(itemID: stockID, totalCostCents: 1_400)
        let book = ledger.book, writes = disk.writes, bytes = disk.data

        let result = try ledger.reconcileInventory(source, sourceLocationID: 9, snapshotID: marker)

        XCTAssertTrue(result.unchangedSnapshot)
        XCTAssertEqual(ledger.book, book)
        XCTAssertEqual(total(ledger), 2)
        XCTAssertEqual(disk.writes, writes)
        XCTAssertEqual(disk.data, bytes)
        XCTAssertEqual(ledger.lastInventorySnapshotID, marker)
        let restarted = store(disk)
        let relaunchedWrites = disk.writes
        XCTAssertTrue(try restarted.reconcileInventory(source, sourceLocationID: 9,
            snapshotID: marker).unchangedSnapshot)
        XCTAssertEqual(restarted.book, book)
        XCTAssertEqual(disk.writes, relaunchedWrites)
    }

    func testOldCommittedSnapshotCannotReplayAfterAnotherFreshImport() throws {
        let disk = Disk(), ledger = store(disk)
        let old = snapshot("old"), fresh = snapshot("fresh")
        _ = try ledger.reconcileInventory([seed(quantity: 3)], sourceLocationID: 9, snapshotID: old)
        _ = try ledger.reconcileInventory([seed(quantity: 1)], sourceLocationID: 9, snapshotID: fresh)
        let book = ledger.book, writes = disk.writes

        XCTAssertTrue(try ledger.reconcileInventory([seed(quantity: 3)], sourceLocationID: 9,
            snapshotID: old).unchangedSnapshot)
        XCTAssertEqual(ledger.book, book)
        XCTAssertEqual(total(ledger), 1)
        XCTAssertEqual(ledger.lastInventorySnapshotID, fresh)
        XCTAssertEqual(disk.writes, writes)
    }

    func testCommittedSnapshotCannotBeReusedForDifferentDesiredStock() throws {
        let disk = Disk(), ledger = store(disk)
        let marker = snapshot("immutable snapshot identity")
        _ = try ledger.reconcileInventory([seed(quantity: 2)], sourceLocationID: 9, snapshotID: marker)
        let book = ledger.book, bytes = disk.data, writes = disk.writes

        XCTAssertThrowsError(try ledger.reconcileInventory([seed(quantity: 8)], sourceLocationID: 9,
            snapshotID: marker))

        XCTAssertEqual(ledger.book, book)
        XCTAssertEqual(disk.data, bytes)
        XCTAssertEqual(disk.writes, writes)
        XCTAssertEqual(total(ledger), 2)
    }

    func testCommittedSnapshotCannotBeReusedWithADifferentImportMode() throws {
        for mode in ShowInventoryImportMode.allCases {
            let disk = Disk(), ledger = store(disk)
            let source = [seed(quantity: 2)], marker = snapshot("one durable import mode")
            _ = try ledger.reconcileInventory(source, sourceLocationID: 9, snapshotID: marker, mode: mode)
            let book = ledger.book, bytes = disk.data, writes = disk.writes
            let changedMode: ShowInventoryImportMode = mode == .merge ? .replace : .merge

            XCTAssertThrowsError(try ledger.reconcileInventory(source, sourceLocationID: 9,
                snapshotID: marker, mode: changedMode))

            XCTAssertEqual(ledger.book, book); XCTAssertEqual(disk.data, bytes); XCTAssertEqual(disk.writes, writes)
            XCTAssertEqual(store(disk).book, book)
        }
    }

    func testFreshSnapshotCanApplyTheSameQuantitiesAfterALocalSale() throws {
        let disk = Disk(), ledger = store(disk)
        let source = [seed(quantity: 3)]
        _ = try ledger.reconcileInventory(source, sourceLocationID: 9, snapshotID: snapshot("first fetch"))
        let stockID = try XCTUnwrap(ledger.inventory.first?.id)
        let showID = try ledger.create(name: "Fresh refresh show", startingCents: 30_000)
        _ = try ledger.recordTransaction(.init(kind: .sale,
            outgoing: [.init(inventoryID: stockID, quantity: 1)], saleReceivedCents: 1_000), showID: showID)

        let result = try ledger.reconcileInventory(source, sourceLocationID: 9,
            snapshotID: snapshot("later explicit fetch"))

        XCTAssertFalse(result.unchangedSnapshot)
        XCTAssertEqual(result.addedQuantity, 1)
        XCTAssertEqual(total(ledger), 3)
        XCTAssertEqual(try item(stockID, in: ledger).quantity, 2)
        XCTAssertEqual(ledger.inventory.filter { $0.quantity > 0 }.count, 2)
        XCTAssertEqual(store(disk).book, ledger.book)
    }

    func testEmptyFreshInventoryRetiresAllLotsWithoutDeletingTheirHistory() throws {
        let disk = Disk(), ledger = store(disk)
        try ledger.seedInventory([seed(quantity: 3), seed(2, card: card("other"), quantity: 2)], sourceLocationID: 9)
        let originalIDs = ledger.inventory.map(\.id)
        try ledger.setInventoryCost(itemID: originalIDs[0], totalCostCents: 1_000)

        let result = try ledger.reconcileInventory([], sourceLocationID: 9, snapshotID: snapshot("empty website"))

        XCTAssertEqual(result.removedQuantity, 5)
        XCTAssertEqual(result.totalQuantity, 0)
        XCTAssertEqual(ledger.inventory.map(\.id), originalIDs)
        XCTAssertTrue(ledger.inventory.allSatisfy { $0.quantity == 0 })
        XCTAssertEqual(try item(originalIDs[0], in: ledger).remainingCostCents, 0)
        XCTAssertNil(try item(originalIDs[1], in: ledger).remainingCostCents)
        XCTAssertEqual(store(disk).book, ledger.book)
    }

    func testAllFreshRowsAndSnapshotAreValidatedBeforeAnyMutation() throws {
        let disk = Disk(), ledger = store(disk)
        try ledger.seedInventory([seed(quantity: 3)], sourceLocationID: 9)
        let book = ledger.book, bytes = disk.data, writes = disk.writes
        var invalidCard = card("invalid"); invalidCard.name = ""
        let invalidInputs = [[seed(2, quantity: 1), seed(3, quantity: -1)],
            [seed(2, quantity: 1), seed(3, card: invalidCard)],
            [seed(2), seed(2)], [seed(0)], [seed(quantity: ShowBudgetBook.maximumQuantity + 1)]]
        for (index, rows) in invalidInputs.enumerated() {
            XCTAssertThrowsError(try ledger.reconcileInventory(rows, sourceLocationID: 9,
                snapshotID: snapshot("invalid \(index)")))
            XCTAssertEqual(ledger.book, book)
            XCTAssertEqual(disk.data, bytes)
            XCTAssertEqual(disk.writes, writes)
        }
        XCTAssertThrowsError(try ledger.reconcileInventory([seed()], sourceLocationID: 9,
            snapshotID: Data(repeating: 1, count: 4_097)))
        XCTAssertThrowsError(try ledger.reconcileInventory([seed()], sourceLocationID: 10,
            snapshotID: snapshot("another location"))) {
            XCTAssertEqual($0 as? ShowTransactionFailure, .inventoryLocationConflict)
        }
        XCTAssertEqual(ledger.book, book)
        XCTAssertEqual(disk.data, bytes)
        XCTAssertEqual(disk.writes, writes)
    }

    func testAtomicWriteFailureKeepsStockCostsJournalAndMarkerRetryableAcrossRelaunch() throws {
        let disk = Disk(), ledger = store(disk)
        try ledger.seedInventory([seed(quantity: 3)], sourceLocationID: 9)
        let stockID = try XCTUnwrap(ledger.inventory.first?.id)
        try ledger.setInventoryCost(itemID: stockID, totalCostCents: 1_000)
        let showID = try ledger.create(name: "Failure keeps local stock", startingCents: 30_000)
        let bought = try ledger.recordTransaction(.init(kind: .purchase,
            incoming: [.init(card: card("retry local acquisition"), quantity: 3)], incomingValueCents: 2_100), showID: showID)
        let localID = try XCTUnwrap(bought.incoming.first?.inventoryID)
        let local = try item(localID, in: ledger)
        let book = ledger.book, bytes = disk.data, marker = snapshot("retry failed fresh import")
        let source = [seed(10, quantity: 1), seed(11, card: card("new"), quantity: 2)]
        disk.fail = true

        XCTAssertThrowsError(try ledger.reconcileInventory(source, sourceLocationID: 9, snapshotID: marker)) {
            XCTAssertEqual($0 as? ShowBudgetStoreFailure, .saveFailed)
        }
        XCTAssertEqual(ledger.book, book)
        XCTAssertEqual(disk.data, bytes)
        XCTAssertNil(ledger.lastInventorySnapshotID)
        XCTAssertTrue(ledger.inventoryReconciliations.isEmpty)
        XCTAssertEqual(try item(localID, in: ledger), local)
        let restarted = store(disk)
        XCTAssertEqual(restarted.book, book)

        disk.fail = false
        let result = try restarted.reconcileInventory(source, sourceLocationID: 9, snapshotID: marker)
        XCTAssertEqual(result.removedQuantity, 2)
        XCTAssertEqual(result.addedQuantity, 2)
        XCTAssertEqual(restarted.lastInventorySnapshotID, marker)
        XCTAssertEqual(restarted.inventoryReconciliations.count, 1)
        XCTAssertEqual(try item(stockID, in: restarted).remainingCostCents, 333)
        XCTAssertEqual(try item(localID, in: restarted), local)
        XCTAssertEqual(result.totalQuantity, 6)
        let committed = restarted.book, writes = disk.writes
        XCTAssertTrue(try restarted.reconcileInventory(source, sourceLocationID: 9,
            snapshotID: marker).unchangedSnapshot)
        XCTAssertEqual(restarted.book, committed)
        XCTAssertEqual(disk.writes, writes)
        XCTAssertEqual(store(disk).book, committed)
    }

    func testVersionFourMigratesWithoutPretendingExistingSourceWasReconciled() throws {
        let disk = Disk(), ledger = store(disk)
        try ledger.seedInventory([seed(quantity: 3)], sourceLocationID: 9)
        let stockID = try XCTUnwrap(ledger.inventory.first?.id)
        try ledger.setInventoryCost(itemID: stockID, totalCostCents: 1_000)
        let showID = try ledger.create(name: "Before upgrade", startingCents: 30_000)
        let sold = try ledger.recordTransaction(.init(kind: .sale,
            outgoing: [.init(inventoryID: stockID, quantity: 1)], saleReceivedCents: 1_000), showID: showID)
        var legacy = try object(disk)
        legacy["version"] = 4
        legacy.removeValue(forKey: "inventoryReconciliations")
        legacy.removeValue(forKey: "lastInventorySnapshotID")
        disk.data = try JSONSerialization.data(withJSONObject: legacy)
        let bytes = disk.data, writes = disk.writes

        let migrated = store(disk)

        XCTAssertTrue(migrated.isLoaded)
        XCTAssertEqual(migrated.book.version, 5)
        XCTAssertNil(migrated.lastInventorySnapshotID)
        XCTAssertTrue(migrated.inventoryReconciliations.isEmpty)
        XCTAssertEqual(total(migrated), 2)
        XCTAssertEqual(try item(stockID, in: migrated).remainingCostCents, 666)
        XCTAssertEqual(migrated.transactions, [sold])
        XCTAssertEqual(disk.data, bytes)
        XCTAssertEqual(disk.writes, writes)
        _ = try migrated.reconcileInventory([seed(quantity: 1)], sourceLocationID: 9,
            snapshotID: snapshot("first explicit refresh after upgrade"))
        XCTAssertEqual(total(migrated), 1)
        XCTAssertEqual(try item(stockID, in: migrated).remainingCostCents, 333)
        XCTAssertEqual(store(disk).book, migrated.book)
    }

    func testTamperedDesiredQuantityCostDeltaOriginAndMissingAuditAreRejected() throws {
        let disk = Disk(), ledger = store(disk)
        try ledger.seedInventory([seed(quantity: 3)], sourceLocationID: 9)
        let stockID = try XCTUnwrap(ledger.inventory.first?.id)
        try ledger.setInventoryCost(itemID: stockID, totalCostCents: 1_000)
        _ = try ledger.reconcileInventory([seed(quantity: 1), seed(2, card: card("new"), quantity: 2)],
            sourceLocationID: 9, snapshotID: snapshot("audited"))
        let valid = try object(disk)

        var changed = valid
        var events = try XCTUnwrap(changed["inventoryReconciliations"] as? [[String: Any]])
        var rows = try XCTUnwrap(events[0]["sourceRows"] as? [[String: Any]])
        rows[0]["quantity"] = 2
        events[0]["sourceRows"] = rows
        changed["inventoryReconciliations"] = events
        try assertRejected(changed)

        changed = valid
        var mutations = try XCTUnwrap(changed["costMutations"] as? [[String: Any]])
        let reconciliationIndex = try XCTUnwrap(mutations.firstIndex { ($0["kind"] as? String) == "reconciliation" })
        var changes = try XCTUnwrap(mutations[reconciliationIndex]["changes"] as? [[String: Any]])
        let knownIndex = try XCTUnwrap(changes.firstIndex {
            (($0["after"] as? [String: Any])?["id"] as? String) == stockID.uuidString
        })
        var after = try XCTUnwrap(changes[knownIndex]["after"] as? [String: Any])
        after["remainingCostCents"] = 334
        changes[knownIndex]["after"] = after
        mutations[reconciliationIndex]["changes"] = changes
        changed["costMutations"] = mutations
        try assertRejected(changed)

        changed = valid
        var inventory = try XCTUnwrap(changed["inventory"] as? [[String: Any]])
        let addedIndex = try XCTUnwrap(inventory.firstIndex { $0["acquiredByReconciliationID"] != nil })
        inventory[addedIndex]["acquiredByReconciliationID"] = UUID().uuidString
        changed["inventory"] = inventory
        try assertRejected(changed)

        changed = valid
        changed.removeValue(forKey: "inventoryReconciliations")
        try assertRejected(changed)
    }

    func testDowngradingVersionCannotHideAReconciliationJournalAsLegacyStock() throws {
        let disk = Disk(), ledger = store(disk)
        _ = try ledger.reconcileInventory([seed(quantity: 2)], sourceLocationID: 9,
            snapshotID: snapshot("cannot downgrade imported audit"))
        let valid = try object(disk)
        for version in [3, 4] {
            var changed = valid
            changed["version"] = version
            changed.removeValue(forKey: "inventoryReconciliations")
            var inventory = try XCTUnwrap(changed["inventory"] as? [[String: Any]])
            for index in inventory.indices { inventory[index].removeValue(forKey: "acquiredByReconciliationID") }
            changed["inventory"] = inventory
            if version == 3 {
                for key in ["costLedgerBaseline", "legacyTransactionIDs", "legacyReversedTransactionIDs"] {
                    changed.removeValue(forKey: key)
                }
            }

            try assertRejected(changed)
        }
    }

    func testImportedCopiesWithSameIdentityAsPurchaseDoNotPreventLocalPurchaseUndo() throws {
        let disk = Disk(), ledger = store(disk)
        let source = [seed(), seed(2, card: card("purchase"), quantity: 2)]
        try ledger.seedInventory(source, sourceLocationID: 9)
        let showID = try ledger.create(name: "Undo show", startingCents: 30_000)
        let sourceID = try XCTUnwrap(ledger.inventory.first { $0.sourceInventoryID == 2 }?.id)
        let sold = try ledger.recordTransaction(.init(kind: .sale,
            outgoing: [.init(inventoryID: sourceID, quantity: 1)], saleReceivedCents: 1_000), showID: showID)
        let cashBeforePurchase = try XCTUnwrap(ledger.activeShow).totals().availableCents
        let bought = try ledger.recordTransaction(.init(kind: .purchase,
            incoming: [.init(card: card("purchase"), quantity: 2)], incomingValueCents: 1_400), showID: showID)
        let purchasedID = try XCTUnwrap(bought.incoming.first?.inventoryID)
        let purchased = try item(purchasedID, in: ledger)
        let result = try ledger.reconcileInventory(source, sourceLocationID: 9,
            snapshotID: snapshot("website count unchanged after source sale and local purchase"))
        XCTAssertEqual(result.addedQuantity, 1)
        XCTAssertEqual(result.removedQuantity, 0)
        XCTAssertEqual(result.totalQuantity, 5)
        XCTAssertEqual(ledger.book.costMutations.last?.changes.count, 1)
        XCTAssertEqual(try item(purchasedID, in: ledger), purchased,
                       "Only growth from the previous website count may adopt a local purchase")
        let imported = try XCTUnwrap(ledger.inventory.first { $0.acquiredByReconciliationID != nil })
        XCTAssertEqual(imported.quantity, 1)
        XCTAssertNil(imported.adoptedFromInventoryID)
        XCTAssertNil(imported.remainingCostCents)

        try ledger.undoTransaction(bought.id)

        XCTAssertEqual(try item(purchasedID, in: ledger).quantity, 0)
        XCTAssertEqual(try item(purchasedID, in: ledger).remainingCostCents, 0)
        XCTAssertEqual(total(ledger), 3, "The independently imported copies remain after Undo removes the local purchase")
        XCTAssertEqual(try XCTUnwrap(ledger.activeShow).totals().availableCents, cashBeforePurchase)
        XCTAssertThrowsError(try ledger.undoTransaction(sold.id)) {
            XCTAssertEqual($0 as? ShowTransactionFailure, .inventoryReconciled)
        }
        XCTAssertEqual(store(disk).book, ledger.book)
    }

    func testReconciledOutgoingLotBlocksUndoRatherThanAddingCopiesBeyondItsAudit() throws {
        let disk = Disk(), ledger = store(disk)
        try ledger.seedInventory([seed(quantity: 3)], sourceLocationID: 9)
        let stockID = try XCTUnwrap(ledger.inventory.first?.id)
        try ledger.setInventoryCost(itemID: stockID, totalCostCents: 1_000)
        let showID = try ledger.create(name: "Outgoing Undo show", startingCents: 30_000)
        let sold = try ledger.recordTransaction(.init(kind: .sale,
            outgoing: [.init(inventoryID: stockID, quantity: 1)], saleReceivedCents: 1_000), showID: showID)
        _ = try ledger.reconcileInventory([seed(quantity: 1)], sourceLocationID: 9,
            snapshotID: snapshot("outgoing lot reduced"))
        let book = ledger.book, bytes = disk.data, writes = disk.writes

        XCTAssertThrowsError(try ledger.undoTransaction(sold.id)) {
            XCTAssertEqual($0 as? ShowTransactionFailure, .inventoryReconciled)
        }

        XCTAssertEqual(ledger.book, book)
        XCTAssertEqual(disk.data, bytes)
        XCTAssertEqual(disk.writes, writes)
        XCTAssertEqual(store(disk).book, book)
    }

    func testNewImportedLotInSameIdentityGroupBlocksEarlierSaleUndoWithoutChangingCash() throws {
        let disk = Disk(), ledger = store(disk)
        try ledger.seedInventory([seed(quantity: 2)], sourceLocationID: 9)
        let stockID = try XCTUnwrap(ledger.inventory.first?.id)
        try ledger.setInventoryCost(itemID: stockID, totalCostCents: 1_400)
        let showID = try ledger.create(name: "Same identity Undo show", startingCents: 30_000)
        let sold = try ledger.recordTransaction(.init(kind: .sale,
            outgoing: [.init(inventoryID: stockID, quantity: 1)], saleReceivedCents: 1_000), showID: showID)
        let oldRemaining = try item(stockID, in: ledger)
        _ = try ledger.reconcileInventory([seed(quantity: 2)], sourceLocationID: 9,
            snapshotID: snapshot("website adds a separate copy"))
        XCTAssertEqual(try item(stockID, in: ledger), oldRemaining)
        XCTAssertEqual(ledger.inventory.filter { $0.id != stockID }.map(\.quantity), [1])
        let book = ledger.book, bytes = disk.data, writes = disk.writes
        let cash = try XCTUnwrap(ledger.activeShow).totals()

        XCTAssertThrowsError(try ledger.undoTransaction(sold.id)) {
            XCTAssertEqual($0 as? ShowTransactionFailure, .inventoryReconciled)
        }

        XCTAssertEqual(ledger.book, book)
        XCTAssertEqual(disk.data, bytes)
        XCTAssertEqual(disk.writes, writes)
        XCTAssertEqual(total(ledger), 2)
        XCTAssertEqual(try XCTUnwrap(ledger.activeShow).totals(), cash)
        XCTAssertEqual(ledger.transactions, [sold])
        XCTAssertEqual(store(disk).book, book)
    }

    func testImportChangingDifferentIdentityDoesNotBlockUnaffectedReceiptUndo() throws {
        let disk = Disk(), ledger = store(disk)
        try ledger.seedInventory([seed(quantity: 2), seed(2, card: card("other"), quantity: 2)], sourceLocationID: 9)
        let stockID = try XCTUnwrap(ledger.inventory.first?.id)
        try ledger.setInventoryCost(itemID: stockID, totalCostCents: 1_400)
        let showID = try ledger.create(name: "Unaffected Undo show", startingCents: 30_000)
        let sold = try ledger.recordTransaction(.init(kind: .sale,
            outgoing: [.init(inventoryID: stockID, quantity: 1)], saleReceivedCents: 1_000), showID: showID)
        _ = try ledger.reconcileInventory([seed(quantity: 1), seed(2, card: card("other"), quantity: 1)],
            sourceLocationID: 9, snapshotID: snapshot("only the other identity changes"))

        try ledger.undoTransaction(sold.id)

        XCTAssertEqual(try item(stockID, in: ledger).quantity, 2)
        XCTAssertEqual(try item(stockID, in: ledger).remainingCostCents, 1_400)
        XCTAssertEqual(ledger.inventory.first { $0.card.identity.productID == "other" }?.quantity, 1)
        XCTAssertEqual(try XCTUnwrap(ledger.activeShow).totals().availableCents, 30_000)
        XCTAssertEqual(store(disk).book, ledger.book)
    }

    func testReconciliationJournalCanRetireMoreThanTwentyThousandPermanentLots() throws {
        // Build the checked book directly: this exercises the stock journal's
        // larger reconciliation bound independently of the JSON file size cap.
        let groupCount = 7_000
        let cards = (1...groupCount).map { card("capacity-\($0)", sku: String($0)) }
        var book = ShowBudgetBook(inventorySourceLocationID: 9)
        let timestamp = Date(timeIntervalSince1970: 1_800_000_000)
        for quantity in 1...3 {
            let rows = cards.enumerated().map { seed($0.offset + 1, card: $0.element, quantity: quantity) }
            let event = ShowInventoryReconciliation(id: UUID(), sourceLocationID: 9,
                snapshotID: snapshot("capacity step \(quantity)"), recordedAt: timestamp,
                sourceRows: rows, createdInventoryIDs: (0..<groupCount).map { _ in UUID() })
            let before = book.inventory
            let plan = try ShowInventoryReconciliationMath.plan(event, inventory: before)
            book.inventory = plan.inventory
            book.inventoryReconciliations.append(event)
            book.costMutations.append(try .capturing(kind: .reconciliation, operationID: event.id,
                recordedAt: timestamp, itemIDs: plan.changedIDs, before: before, after: plan.inventory))
        }
        XCTAssertEqual(book.inventory.count, 21_000)
        let event = ShowInventoryReconciliation(id: UUID(), sourceLocationID: 9,
            snapshotID: snapshot("retire all capacity stock"), recordedAt: timestamp,
            sourceRows: [], createdInventoryIDs: [])
        let before = book.inventory
        let plan = try ShowInventoryReconciliationMath.plan(event, inventory: before)
        book.inventory = plan.inventory
        book.inventoryReconciliations.append(event)
        book.costMutations.append(try .capturing(kind: .reconciliation, operationID: event.id,
            recordedAt: timestamp, itemIDs: plan.changedIDs, before: before, after: plan.inventory))

        XCTAssertEqual(book.costMutations.last?.changes.count, 21_000)
        XCTAssertEqual(plan.summary.removedQuantity, 21_000)
        XCTAssertTrue(book.inventory.allSatisfy { $0.quantity == 0 })
        try book.validate()
    }

    func testUnknownImportedBasisStaysUnknownWhenSoldAndKnownZeroIsPreserved() throws {
        let disk = Disk(), ledger = store(disk)
        _ = try ledger.reconcileInventory([seed(quantity: 2)], sourceLocationID: 9,
            snapshotID: snapshot("unknown imported acquisition"))
        let stockID = try XCTUnwrap(ledger.inventory.first?.id)
        let showID = try ledger.create(name: "Imported cost show", startingCents: 30_000)
        let sold = try ledger.recordTransaction(.init(kind: .sale,
            outgoing: [.init(inventoryID: stockID, quantity: 1)], saleReceivedCents: 1_000), showID: showID)
        XCTAssertNil(sold.totalCostCents)
        XCTAssertNil(sold.profitCents)
        XCTAssertNil(try item(stockID, in: ledger).remainingCostCents)
        try ledger.setInventoryCost(itemID: stockID, totalCostCents: 0)

        _ = try ledger.reconcileInventory([seed(quantity: 3)], sourceLocationID: 9,
            snapshotID: snapshot("zero and new unknown"))

        XCTAssertEqual(try item(stockID, in: ledger).quantity, 1)
        XCTAssertEqual(try item(stockID, in: ledger).remainingCostCents, 0)
        XCTAssertEqual(ledger.inventory.filter { $0.id != stockID }.map(\.quantity), [2])
        XCTAssertTrue(ledger.inventory.filter { $0.id != stockID }.allSatisfy { $0.remainingCostCents == nil })
        XCTAssertEqual(ledger.transactions, [sold])
        XCTAssertEqual(store(disk).book, ledger.book)
    }
}
