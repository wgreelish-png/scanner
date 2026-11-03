import XCTest
import SwiftData
@testable import CardShowScanner

@MainActor final class ShowInventoryBridgeTests: XCTestCase {
    private final class Disk {
        var data: Data?
        var writes = 0
        var fail = false
        let now = Date(timeIntervalSince1970: 1_800_000_000)
    }

    private func container() throws -> ModelContainer {
        let result = try ModelContainer(for: CardList.self, InventoryCard.self, ScanSession.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        result.mainContext.autosaveEnabled = false
        return result
    }
    private func store(_ disk: Disk) -> ShowBudgetStore {
        ShowBudgetStore(read: { _ in disk.data }, write: { bytes, _ in
            if disk.fail { throw CocoaError(.fileWriteOutOfSpace) }
            disk.data = bytes; disk.writes += 1
        }, now: { disk.now })
    }
    private func card(_ id: String = "source") -> CardCandidate {
        CardCandidate(identity: .init(game: "Pokémon", productID: id, printing: "Normal"),
            name: "Bridge " + id, set: "Fixture", number: "1", marketPrice: 10,
            confidence: 100, printings: ["Normal"])
    }
    private func snapshot(quantity: Int = 3) -> CardShowInventorySnapshot {
        .init(location: .init(id: 9, name: "Card Show"),
            rows: [.init(inventoryID: 7, card: card(), quantity: quantity)],
            fetchedAt: Date(timeIntervalSince1970: 1_800_000_000))
    }
    private func legacyLink(for list: CardList, context: ModelContext) throws {
        let link = try XCTUnwrap(list.cardShowInventory)
        list.inventorySourceData = try JSONEncoder().encode(CardShowInventoryLink(locationID: link.locationID,
            locationName: link.locationName, refreshedAt: link.refreshedAt, version: 1))
        try context.save()
    }

    func testLegacySourceKeepsEstablishedSalesAndPurchasesUntilAFreshImport() throws {
        let container = try container(), context = container.mainContext
        let list = try CardShowInventoryService.apply(snapshot(quantity: 99), context: context)
        try legacyLink(for: list, context: context)
        let disk = Disk(), working = store(disk)
        try working.seedInventory([.init(sourceInventoryID: 7, card: card(), quantity: 2)], sourceLocationID: 9)
        let showID = try working.create(name: "Legacy stock", startingCents: 30_000)
        let sourceID = try XCTUnwrap(working.inventory.first?.id)
        try working.recordTransaction(.init(kind: .sale, outgoing: [.init(inventoryID: sourceID, quantity: 1)],
            saleReceivedCents: 1_000), showID: showID)
        let bought = try working.recordTransaction(.init(kind: .purchase,
            incoming: [.init(card: card("local"), quantity: 3)], incomingValueCents: 2_100), showID: showID)
        let acquiredID = try XCTUnwrap(bought.incoming.first?.inventoryID)
        let before = working.book, writes = disk.writes
        let cash = try XCTUnwrap(working.activeShow).totals()

        try ShowInventoryBridge.seedFromImportedList(context: context, store: working)
        XCTAssertEqual(working.book, before); XCTAssertEqual(disk.writes, writes)
        XCTAssertEqual(list.quantity, 99)
        XCTAssertEqual(list.cardShowInventory?.version, 1)

        try CardShowInventoryService.apply(snapshot(quantity: 4), context: context)
        try ShowInventoryBridge.seedFromImportedList(context: context, store: working)
        XCTAssertEqual(working.inventory.reduce(0) { $0 + $1.quantity }, 4)
        XCTAssertEqual(working.inventory.filter { $0.card.identity == card().identity }.reduce(0) { $0 + $1.quantity }, 4)
        XCTAssertEqual(working.inventory.first { $0.id == acquiredID }?.quantity, 0)
        XCTAssertEqual(working.inventory.first { $0.id == acquiredID }?.remainingCostCents, 0)
        XCTAssertEqual(working.transactions, before.transactions)
        XCTAssertEqual(try XCTUnwrap(working.activeShow).totals(), cash)
        XCTAssertEqual(list.cardShowInventory?.version, 2)
        XCTAssertEqual(list.cardShowInventory?.pendingWorkingSync, false)
        XCTAssertEqual(store(disk).book, working.book)
    }

    func testLegacySourceSeedsAnEmptyLedgerOnceWithoutInventingARefreshMarker() throws {
        let container = try container(), context = container.mainContext
        let list = try CardShowInventoryService.apply(snapshot(), context: context)
        try legacyLink(for: list, context: context)
        let disk = Disk(), working = store(disk)
        try ShowInventoryBridge.seedFromImportedList(context: context, store: working)
        XCTAssertEqual(working.inventory.reduce(0) { $0 + $1.quantity }, 3)
        XCTAssertEqual(working.inventorySourceLocationID, 9)
        XCTAssertTrue(working.book.inventoryReconciliations.isEmpty)
        XCTAssertNil(list.cardShowInventory?.inventorySnapshotID)
        let before = working.book, writes = disk.writes
        try ShowInventoryBridge.seedFromImportedList(context: context, store: working)
        XCTAssertEqual(working.book, before); XCTAssertEqual(disk.writes, writes)
    }

    func testFailedWorkingWriteRetainsPendingSnapshotAcrossReopenAndRetriesOnce() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ShowInventoryBridge-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("source.store")
        let disk = Disk(); disk.fail = true
        func firstAttempt() throws -> (UUID, Data) {
            let container = try AppPersistence.open(url: url), context = container.mainContext
            let list = try CardShowInventoryService.apply(snapshot(quantity: 4), context: context)
            let marker = try XCTUnwrap(list.cardShowInventory?.inventorySnapshotID)
            let working = store(disk)
            XCTAssertThrowsError(try ShowInventoryBridge.synchronizeImportedList(list, context: context, store: working))
            XCTAssertEqual(list.cardShowInventory?.pendingWorkingSync, true)
            XCTAssertTrue(working.inventory.isEmpty)
            XCTAssertNil(disk.data); XCTAssertEqual(disk.writes, 0)
            return (list.id, marker)
        }
        let (listID, marker) = try firstAttempt()
        disk.fail = false
        let container = try AppPersistence.open(url: url), context = container.mainContext
        let list = try XCTUnwrap(CardShowInventoryService.importedList(context: context))
        let working = store(disk)
        XCTAssertEqual(list.id, listID)
        XCTAssertEqual(list.cardShowInventory?.inventorySnapshotID, marker)
        XCTAssertEqual(list.cardShowInventory?.pendingWorkingSync, true)
        let result = try ShowInventoryBridge.synchronizeImportedList(list, context: context, store: working)
        XCTAssertEqual(result.totalQuantity, 4); XCTAssertFalse(result.unchangedSnapshot)
        XCTAssertEqual(list.cardShowInventory?.pendingWorkingSync, false)
        XCTAssertEqual(list.cardShowInventory?.inventorySnapshotID, marker)
        XCTAssertEqual(working.book.inventoryReconciliations.map(\.snapshotID), [marker])
        let committed = working.book, writes = disk.writes
        try ShowInventoryBridge.seedFromImportedList(context: context, store: working)
        XCTAssertEqual(working.book, committed); XCTAssertEqual(disk.writes, writes)
        XCTAssertEqual(store(disk).book, committed)
    }

    func testCommittedMarkerRetryAndAcknowledgedOpeningCannotRestoreSoldCardsOrCosts() throws {
        let container = try container(), context = container.mainContext
        let source = snapshot(), list = try CardShowInventoryService.apply(source, context: context)
        let pending = list.inventorySourceData
        let marker = try XCTUnwrap(list.cardShowInventory?.inventorySnapshotID)
        let disk = Disk(), working = store(disk)
        // Simulate a committed financial write whose source acknowledgment did not complete.
        try working.reconcileInventory(source.rows.map {
            .init(sourceInventoryID: $0.inventoryID, card: $0.card, quantity: $0.quantity)
        }, sourceLocationID: source.location.id, snapshotID: marker)
        let stockID = try XCTUnwrap(working.inventory.first?.id)
        try working.setInventoryCost(itemID: stockID, totalCostCents: 900)
        let showID = try working.create(name: "Interrupted handoff", startingCents: 30_000)
        let sold = try working.recordTransaction(.init(kind: .sale,
            outgoing: [.init(inventoryID: stockID, quantity: 1)], saleReceivedCents: 1_000, feeCents: 100), showID: showID)
        let afterSale = working.book, writes = disk.writes
        XCTAssertEqual(list.inventorySourceData, pending)

        let result = try ShowInventoryBridge.synchronizeImportedList(list, context: context, store: working)
        XCTAssertTrue(result.unchangedSnapshot); XCTAssertEqual(result.totalQuantity, 2)
        XCTAssertEqual(list.cardShowInventory?.pendingWorkingSync, false)
        XCTAssertEqual(list.cardShowInventory?.inventorySnapshotID, marker)
        XCTAssertEqual(working.book, afterSale); XCTAssertEqual(disk.writes, writes)
        XCTAssertEqual(working.inventory.first?.remainingCostCents, 600)
        XCTAssertEqual(working.transactions, [sold])
        XCTAssertEqual(try working.profitSummary().knownProfitCents, 600)
        XCTAssertEqual(list.quantity, 3)

        let reopened = store(disk)
        try ShowInventoryBridge.seedFromImportedList(context: context, store: reopened)
        let checked = try ShowInventoryBridge.synchronizeImportedList(list, context: context, store: reopened)
        XCTAssertTrue(checked.unchangedSnapshot)
        XCTAssertEqual(reopened.book, afterSale); XCTAssertEqual(disk.writes, writes)
    }

    func testChangedRowsCannotReuseAPreviouslyCommittedSnapshotMarker() throws {
        let container = try container(), context = container.mainContext
        let source = snapshot(), list = try CardShowInventoryService.apply(source, context: context)
        let marker = try XCTUnwrap(list.cardShowInventory?.inventorySnapshotID)
        let disk = Disk(), working = store(disk)
        try working.reconcileInventory(source.rows.map {
            .init(sourceInventoryID: $0.inventoryID, card: $0.card, quantity: $0.quantity)
        }, sourceLocationID: source.location.id, snapshotID: marker)
        let before = working.book, writes = disk.writes
        let row = try XCTUnwrap(list.cards.first)
        row.quantity = 99
        try context.save()
        XCTAssertThrowsError(try ShowInventoryBridge.synchronizeImportedList(list, context: context, store: working)) {
            XCTAssertEqual($0 as? ShowBudgetStoreFailure, .conflictingEntry)
        }
        XCTAssertEqual(working.book, before); XCTAssertEqual(disk.writes, writes)
        XCTAssertEqual(list.cardShowInventory?.pendingWorkingSync, true)
    }

    func testDifferentWorkingLocationBlocksPendingImportWithoutAcknowledgingIt() throws {
        let container = try container(), context = container.mainContext
        let list = try CardShowInventoryService.apply(snapshot(), context: context)
        let source = list.inventorySourceData
        let disk = Disk(), working = store(disk)
        try working.seedInventory([.init(sourceInventoryID: 7, card: card(), quantity: 8)], sourceLocationID: 10)
        let before = working.book, writes = disk.writes
        XCTAssertThrowsError(try ShowInventoryBridge.synchronizeImportedList(list, context: context, store: working)) {
            XCTAssertEqual($0 as? ShowTransactionFailure, .inventoryLocationConflict)
        }
        XCTAssertEqual(working.book, before); XCTAssertEqual(disk.writes, writes)
        XCTAssertEqual(list.inventorySourceData, source)
        XCTAssertEqual(list.cardShowInventory?.pendingWorkingSync, true)
    }
}
