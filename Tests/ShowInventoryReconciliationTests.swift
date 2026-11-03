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

    func testMissingLocalPurchaseIsRetiredWithItsCostAndCashHistoryPreserved() throws {
        let disk = Disk(), ledger = store(disk)
        try ledger.seedInventory([seed(quantity: 2)], sourceLocationID: 9)
        let showID = try ledger.create(name: "Local purchase show", startingCents: 30_000)
        let bought = try ledger.recordTransaction(.init(kind: .purchase,
            incoming: [.init(card: card("local"), quantity: 3)], incomingValueCents: 2_100), showID: showID)
        let acquiredID = try XCTUnwrap(bought.incoming.first?.inventoryID)
        let cash = try XCTUnwrap(ledger.activeShow).totals()

        let result = try ledger.reconcileInventory([seed(quantity: 2)], sourceLocationID: 9,
            snapshotID: snapshot("website omits purchase"))

        XCTAssertEqual(result.removedQuantity, 3)
        XCTAssertEqual(total(ledger), 2)
        XCTAssertEqual(try item(acquiredID, in: ledger).quantity, 0)
        XCTAssertEqual(try item(acquiredID, in: ledger).remainingCostCents, 0)
        XCTAssertEqual(ledger.transactions, [bought])
        XCTAssertEqual(try XCTUnwrap(ledger.activeShow).totals(), cash)
        let bytes = disk.data, book = ledger.book
        XCTAssertThrowsError(try ledger.undoTransaction(bought.id)) {
            XCTAssertEqual($0 as? ShowTransactionFailure, .inventoryReconciled)
        }
        XCTAssertEqual(ledger.book, book)
        XCTAssertEqual(disk.data, bytes)
        XCTAssertEqual(store(disk).book, ledger.book)
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
        let restarted = store(disk)
        XCTAssertEqual(restarted.book, book)

        disk.fail = false
        let result = try restarted.reconcileInventory(source, sourceLocationID: 9, snapshotID: marker)
        XCTAssertEqual(result.removedQuantity, 2)
        XCTAssertEqual(result.addedQuantity, 2)
        XCTAssertEqual(restarted.lastInventorySnapshotID, marker)
        XCTAssertEqual(restarted.inventoryReconciliations.count, 1)
        XCTAssertEqual(try item(stockID, in: restarted).remainingCostCents, 333)
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

    func testUnchangedFreshImportKeepsOrdinaryTransactionUndoAvailable() throws {
        let disk = Disk(), ledger = store(disk)
        try ledger.seedInventory([seed()], sourceLocationID: 9)
        let showID = try ledger.create(name: "Undo show", startingCents: 30_000)
        let bought = try ledger.recordTransaction(.init(kind: .purchase,
            incoming: [.init(card: card("purchase"), quantity: 2)], incomingValueCents: 1_400), showID: showID)
        let purchasedID = try XCTUnwrap(bought.incoming.first?.inventoryID)
        let source = [seed(), seed(2, card: card("purchase"), quantity: 2)]
        let result = try ledger.reconcileInventory(source, sourceLocationID: 9,
            snapshotID: snapshot("quantities already agree"))
        XCTAssertEqual(result.addedQuantity, 0)
        XCTAssertEqual(result.removedQuantity, 0)
        XCTAssertEqual(ledger.book.costMutations.last?.changes.count, 0)

        try ledger.undoTransaction(bought.id)

        XCTAssertEqual(try item(purchasedID, in: ledger).quantity, 0)
        XCTAssertEqual(try item(purchasedID, in: ledger).remainingCostCents, 0)
        XCTAssertEqual(try XCTUnwrap(ledger.activeShow).totals().availableCents, 30_000)
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
