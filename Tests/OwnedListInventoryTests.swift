import XCTest
@testable import CardShowScanner

@MainActor final class OwnedListInventoryTests: XCTestCase {
    private final class Disk {
        var data: Data?
        var writes = 0
        var fail = false
        var now = Date(timeIntervalSince1970: 1_800_000_000)
    }

    private func store(_ disk: Disk) -> ShowBudgetStore {
        ShowBudgetStore(read: { _ in disk.data }, write: { bytes, _ in
            disk.writes += 1
            if disk.fail { throw CocoaError(.fileWriteOutOfSpace) }
            disk.data = bytes
        }, now: { disk.now })
    }

    private func card(_ product: String = "owned", price: Decimal? = 10,
                      condition: String = "Near Mint") -> CardCandidate {
        CardCandidate(identity: .init(game: "Pokémon", productID: product, skuID: "sku:" + product,
            printing: "Normal", condition: condition), name: "Owned " + product, set: "Owned fixtures",
            number: "1", marketPrice: price, confidence: 100, printings: ["Normal"])
    }

    private func total(_ ledger: ShowBudgetStore) -> Int {
        ledger.inventory.reduce(0) { $0 + $1.quantity }
    }

    private func json(_ data: Data?) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(data)) as? [String: Any])
    }

    func testOwnedListAddsDistinctUnknownCostLotsWithoutAWebsiteImportShowOrCashReceipt() throws {
        let disk = Disk(), ledger = store(disk), listID = UUID()
        let rows = [ShowIncomingCard(card: card(), quantity: 2), ShowIncomingCard(card: card(), quantity: 1),
                    ShowIncomingCard(card: card("unpriced", price: nil), quantity: 3)]
        let source = rows
        let result = try ledger.addOwnedInventory(listID: listID, listName: "My cards", rows: rows)

        XCTAssertEqual(result.addedQuantity, 6)
        XCTAssertEqual(result.addedLots, 3)
        XCTAssertEqual(result.alreadyAddedQuantity, 0)
        XCTAssertEqual(total(ledger), 6)
        XCTAssertEqual(ledger.inventory.map(\.card), rows.map(\.card))
        XCTAssertEqual(ledger.inventory.map(\.quantity), [2, 1, 3])
        XCTAssertEqual(Set(ledger.inventory.map(\.id)).count, 3, "Physical scan rows remain separate lots")
        XCTAssertTrue(ledger.inventory.allSatisfy {
            $0.isLocalAcquisition && $0.originTitle == "Acquired locally" && $0.remainingCostCents == nil &&
                $0.sourceInventoryID == nil && $0.sourceLocationID == nil && $0.acquiredByTransactionID == nil &&
                $0.acquiredByListAdditionID != nil
        })
        XCTAssertTrue(ledger.hasOwnedInventory(forListID: listID))
        XCTAssertFalse(ledger.hasOwnedInventory(forListID: UUID()))
        XCTAssertEqual(ledger.inventoryListAdditions.count, 1)
        XCTAssertTrue(ledger.visibleShows.isEmpty)
        XCTAssertTrue(ledger.transactions.isEmpty)
        XCTAssertNil(ledger.inventorySourceLocationID)
        XCTAssertTrue(ledger.book.costLedgerBaseline.isEmpty)
        let mutation = try XCTUnwrap(ledger.book.costMutations.first)
        XCTAssertEqual(mutation.changes.map(\.after.quantity), [2, 1, 3])
        XCTAssertTrue(mutation.changes.allSatisfy { $0.before == nil && $0.after.remainingCostCents == nil })
        XCTAssertEqual(rows, source)
        XCTAssertEqual(disk.writes, 1)
        XCTAssertEqual(store(disk).book, ledger.book)
    }

    func testRepeatedRowsAreIdempotentAndAppendingANewRowCannotInflatePriorStock() throws {
        let disk = Disk(), ledger = store(disk), listID = UUID()
        let original = ShowIncomingCard(card: card(), quantity: 3)
        try ledger.addOwnedInventory(listID: listID, listName: "Owned", rows: [original])
        let firstBook = ledger.book, writes = disk.writes
        let replay = try ledger.addOwnedInventory(listID: listID, listName: "Renamed source", rows: [original])
        XCTAssertEqual(replay.addedQuantity, 0)
        XCTAssertEqual(replay.addedLots, 0)
        XCTAssertEqual(replay.alreadyAddedQuantity, 3)
        XCTAssertEqual(ledger.book, firstBook)
        XCTAssertEqual(disk.writes, writes)

        let appended = ShowIncomingCard(card: card("new"), quantity: 2)
        let result = try ledger.addOwnedInventory(listID: listID, listName: "Renamed source", rows: [original, appended])
        XCTAssertEqual(result.addedQuantity, 2)
        XCTAssertEqual(result.addedLots, 1)
        XCTAssertEqual(result.alreadyAddedQuantity, 3)
        XCTAssertEqual(total(ledger), 5)
        XCTAssertEqual(ledger.inventory.count, 2)
        XCTAssertEqual(ledger.inventoryListAdditions.count, 2)
        let unchanged = ledger.book
        var changed = original
        changed.quantity = 4
        XCTAssertThrowsError(try ledger.addOwnedInventory(listID: listID, listName: "Owned", rows: [changed, appended]))
        changed = original; changed.card = card("different")
        XCTAssertThrowsError(try ledger.addOwnedInventory(listID: listID, listName: "Owned", rows: [changed]))
        XCTAssertEqual(ledger.book, unchanged)
        XCTAssertEqual(store(disk).book, unchanged)
    }

    func testRelaunchAndSoldOutStockCannotReplayAnOwnedRowOrRecordItAgainAsAPurchase() throws {
        let disk = Disk(), ledger = store(disk), listID = UUID()
        let row = ShowIncomingCard(card: card(), quantity: 2)
        try ledger.addOwnedInventory(listID: listID, listName: "Owned", rows: [row])
        let stockID = try XCTUnwrap(ledger.inventory.first?.id)
        let showID = try ledger.create(name: "Show", startingCents: 30_000)
        let receipt = try ledger.recordTransaction(.init(kind: .sale,
            outgoing: [.init(inventoryID: stockID, quantity: 2)], saleReceivedCents: 2_000), showID: showID)
        XCTAssertNil(receipt.totalCostCents, "Unknown acquisition cost must not become free stock")
        let reopened = store(disk), before = reopened.book, writes = disk.writes
        let retry = try reopened.addOwnedInventory(listID: listID, listName: "Owned", rows: [row])
        XCTAssertEqual(retry.addedQuantity, 0)
        XCTAssertEqual(retry.alreadyAddedQuantity, 2)
        XCTAssertEqual(total(reopened), 0)
        XCTAssertEqual(reopened.book, before)
        XCTAssertEqual(disk.writes, writes)
        XCTAssertThrowsError(try reopened.recordTransaction(.init(kind: .purchase,
            incomingListID: listID, incomingListName: "Owned", incoming: [row], incomingValueCents: 1_000), showID: showID))
        XCTAssertEqual(reopened.transactions, [receipt])
        XCTAssertEqual(reopened.book, before)
    }

    func testMergeAdoptsMatchingOwnedCardsAndReplaceUsesWebsiteCountsWithoutErasingDeduplication() throws {
        let disk = Disk(), ledger = store(disk), listID = UUID()
        let matching = ShowIncomingCard(card: card("matching"), quantity: 2)
        let unmatched = ShowIncomingCard(card: card("unmatched"), quantity: 1)
        try ledger.addOwnedInventory(listID: listID, listName: "Owned", rows: [matching, unmatched])
        let originalIDs = ledger.inventory.map(\.id)
        try ledger.setInventoryCost(itemID: originalIDs[0], totalCostCents: 700)
        let merged = try ledger.reconcileInventory([.init(sourceInventoryID: 7, card: matching.card, quantity: 2)],
            sourceLocationID: 9, snapshotID: Data("first owned adoption".utf8), mode: .merge)
        XCTAssertEqual(merged.totalQuantity, 3)
        XCTAssertEqual(total(ledger), 3)
        XCTAssertEqual(ledger.inventory.first { $0.id == originalIDs[0] }?.quantity, 0)
        XCTAssertEqual(ledger.inventory.first { $0.id == originalIDs[1] }?.quantity, 1)
        let adopted = try XCTUnwrap(ledger.inventory.first { $0.adoptedFromInventoryID == originalIDs[0] })
        XCTAssertEqual(adopted.quantity, 2)
        XCTAssertEqual(adopted.sourceInventoryID, 7)
        XCTAssertEqual(adopted.remainingCostCents, 700)
        XCTAssertEqual(adopted.originTitle, "TCGTracking")

        let replaced = try ledger.reconcileInventory([.init(sourceInventoryID: 7, card: matching.card, quantity: 1)],
            sourceLocationID: 9, snapshotID: Data("replace owned inventory".utf8), mode: .replace)
        XCTAssertEqual(replaced.totalQuantity, 1)
        XCTAssertEqual(total(ledger), 1)
        XCTAssertEqual(ledger.inventory.first { $0.id == adopted.id }?.remainingCostCents, 350)
        XCTAssertTrue(originalIDs.allSatisfy { id in ledger.inventory.contains { $0.id == id } })
        let reopened = store(disk), before = reopened.book
        let retry = try reopened.addOwnedInventory(listID: listID, listName: "Owned", rows: [matching, unmatched])
        XCTAssertEqual(retry.addedQuantity, 0)
        XCTAssertEqual(retry.alreadyAddedQuantity, 3)
        XCTAssertEqual(reopened.book, before)
        XCTAssertEqual(total(reopened), 1)
        XCTAssertTrue(reopened.transactions.isEmpty)
        XCTAssertTrue(reopened.visibleShows.isEmpty)
    }

    func testVersionFiveMigratesInMemoryWithoutWritingAndVersionSixRequiresItsAcquisitionAudit() throws {
        let disk = Disk(), original = store(disk)
        try original.seedInventory([.init(sourceInventoryID: 1, card: card("website"), quantity: 2)], sourceLocationID: 9)
        var legacy = try json(disk.data)
        legacy["version"] = 5
        legacy.removeValue(forKey: "inventoryListAdditions")
        disk.data = try JSONSerialization.data(withJSONObject: legacy)
        let saved = disk.data, writes = disk.writes
        let migrated = store(disk)
        XCTAssertTrue(migrated.isLoaded)
        XCTAssertEqual(migrated.book.version, 6)
        XCTAssertTrue(migrated.inventoryListAdditions.isEmpty)
        XCTAssertEqual(migrated.inventory, original.inventory)
        XCTAssertEqual(disk.data, saved)
        XCTAssertEqual(disk.writes, writes)
        try migrated.addOwnedInventory(listID: UUID(), listName: "Owned", rows: [.init(card: card(), quantity: 1)])
        XCTAssertEqual(try json(disk.data)["version"] as? Int, 6)
        XCTAssertEqual(total(migrated), 3)

        var damaged = try json(disk.data)
        damaged.removeValue(forKey: "inventoryListAdditions")
        let broken = Disk(); broken.data = try JSONSerialization.data(withJSONObject: damaged)
        let bytes = broken.data, unavailable = store(broken)
        XCTAssertFalse(unavailable.isLoaded)
        XCTAssertThrowsError(try unavailable.addOwnedInventory(listID: UUID(), listName: "Replacement", rows: [.init(card: card())]))
        XCTAssertEqual(broken.data, bytes)
        XCTAssertEqual(broken.writes, 0)
    }

    func testPersistenceFailureLeavesBothStockAndRowMarkersAvailableForOneSafeRetry() throws {
        let disk = Disk(), ledger = store(disk), listID = UUID()
        let first = ShowIncomingCard(card: card(), quantity: 2)
        try ledger.addOwnedInventory(listID: listID, listName: "Owned", rows: [first])
        let before = ledger.book, bytes = disk.data
        let appended = ShowIncomingCard(card: card("later"), quantity: 3)
        disk.fail = true
        XCTAssertThrowsError(try ledger.addOwnedInventory(listID: listID, listName: "Owned", rows: [first, appended]))
        XCTAssertEqual(ledger.book, before)
        XCTAssertEqual(disk.data, bytes)
        disk.fail = false; ledger.reload()
        let retry = try ledger.addOwnedInventory(listID: listID, listName: "Owned", rows: [first, appended])
        XCTAssertEqual(retry.addedQuantity, 3)
        XCTAssertEqual(retry.alreadyAddedQuantity, 2)
        XCTAssertEqual(total(ledger), 5)
        XCTAssertEqual(ledger.inventoryListAdditions.count, 2)
        XCTAssertEqual(store(disk).book, ledger.book)
    }

    func testInvalidOrOversizedInputsCannotPartiallyAddCardsOrPostAnyCash() throws {
        let disk = Disk(), ledger = store(disk), listID = UUID(), row = ShowIncomingCard(card: card(), quantity: 2)
        var invalidCard = card(); invalidCard.name = ""
        let oversized = (0...ShowBudgetBook.maximumTransactionCards).map { _ in ShowIncomingCard(card: card()) }
        let batches: [[ShowIncomingCard]] = [[], [row, row], [.init(card: card(), quantity: 0)],
            [.init(card: card(), quantity: -1)], [.init(card: card(), quantity: ShowBudgetBook.maximumQuantity + 1)],
            [row, .init(card: invalidCard)], oversized]
        for rows in batches {
            let before = ledger.book, bytes = disk.data, writes = disk.writes
            XCTAssertThrowsError(try ledger.addOwnedInventory(listID: listID, listName: "Owned", rows: rows))
            XCTAssertEqual(ledger.book, before)
            XCTAssertEqual(disk.data, bytes)
            XCTAssertEqual(disk.writes, writes)
            XCTAssertFalse(ledger.hasOwnedInventory(forListID: listID))
        }
        XCTAssertTrue(ledger.inventory.isEmpty)
        XCTAssertTrue(ledger.transactions.isEmpty)
        XCTAssertTrue(ledger.visibleShows.isEmpty)
    }
}
