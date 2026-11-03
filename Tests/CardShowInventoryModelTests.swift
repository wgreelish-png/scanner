import XCTest
import SwiftData
@testable import CardShowScanner

@MainActor final class CardShowInventoryModelTests: XCTestCase {
    private final class WorkingDisk {
        var data: Data?
        var writes = 0
        var fail = false
    }
    private func workingStore(_ disk: WorkingDisk = WorkingDisk()) -> ShowBudgetStore {
        ShowBudgetStore(read: { _ in disk.data }, write: { bytes, _ in
            if disk.fail { throw CocoaError(.fileWriteOutOfSpace) }
            disk.data = bytes; disk.writes += 1
        })
    }
    private func store() throws -> ModelContainer {
        try ModelContainer(for: CardList.self, InventoryCard.self, ScanSession.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }
    private func snapshot(quantity: Int = 2, locationID: Int = 9001, date: Date = Date(timeIntervalSince1970: 100)) -> CardShowInventorySnapshot {
        let card = CardCandidate(identity: CardIdentity(game: "Pokémon", productID: "p:42", skuID: "100", printing: "Holofoil"),
            name: "Model fixture card", set: "Fixture set", number: "42", marketPrice: 10, confidence: 100, printings: ["Holofoil"])
        return .init(location: .init(id: locationID, name: "Card Show"),
            rows: [.init(inventoryID: 7001, card: card, quantity: quantity)], fetchedAt: date)
    }

    func testOpeningSavedInventoryDoesNotRequestNetwork() throws {
        let container = try store(), context = container.mainContext
        let list = try CardShowInventoryService.apply(snapshot(), context: context)
        let provider = ImportModelProvider()
        let model = CardShowInventoryModel(provider: provider, workingStore: workingStore())
        model.setActive(true)
        XCTAssertEqual(provider.expectedLocations.count, 0)
        XCTAssertEqual(list.quantity, 2); XCTAssertFalse(model.isRefreshing)
        XCTAssertNil(model.message)
    }

    func testImportAndRefreshUseSavedLocationAndKeepOneListAndRow() async throws {
        let container = try store(), context = container.mainContext
        let provider = ImportModelProvider(responses: [.success(snapshot()), .success(snapshot(quantity: 3))])
        let model = CardShowInventoryModel(provider: provider, workingStore: workingStore())
        model.setActive(true); model.refresh(context: context); try await idle(model)
        let list = try XCTUnwrap(CardShowInventoryService.importedList(context: context))
        let listID = list.id, rowID = try XCTUnwrap(list.cards.first).id
        XCTAssertEqual(list.quantity, 2)
        model.refresh(context: context); try await idle(model)
        XCTAssertEqual(provider.expectedLocations, [nil, 9001])
        XCTAssertEqual(list.id, listID); XCTAssertEqual(list.cards.first?.id, rowID)
        XCTAssertEqual(list.cards.count, 1); XCTAssertEqual(list.quantity, 3)
        XCTAssertEqual(try context.fetch(FetchDescriptor<CardList>()).count, 1)
        XCTAssertEqual(model.lastImportedListID, listID)
    }

    func testDoubleTapStartsOnlyOneFetchAndOneSave() async throws {
        let container = try store(), context = container.mainContext
        let provider = ImportModelProvider(held: true)
        var saves = 0
        let model = CardShowInventoryModel(provider: provider, workingStore: workingStore(), applySnapshot: {
            saves += 1; return try CardShowInventoryService.apply($0, context: $1)
        })
        model.setActive(true); model.refresh(context: context); model.refresh(context: context)
        try await provider.waitForRequests(1)
        XCTAssertEqual(provider.expectedLocations.count, 1)
        provider.finish(0, with: .success(snapshot())); try await idle(model)
        XCTAssertEqual(saves, 1)
        XCTAssertEqual(try CardShowInventoryService.importedList(context: context)?.quantity, 2)
    }

    func testInactivePageDoesNotStartRequests() async throws {
        let container = try store(), provider = ImportModelProvider()
        let model = CardShowInventoryModel(provider: provider, workingStore: workingStore())
        model.refresh(context: container.mainContext)
        await settle()
        XCTAssertTrue(provider.expectedLocations.isEmpty); XCTAssertFalse(model.isRefreshing)
    }

    func testCanceledResponseCannotCreateListAndNextRefreshCanSucceed() async throws {
        let container = try store(), context = container.mainContext
        let provider = ImportModelProvider(held: true)
        let model = CardShowInventoryModel(provider: provider, workingStore: workingStore())
        model.setActive(true); model.refresh(context: context); try await provider.waitForRequests(1)
        model.setActive(false)
        provider.finish(0, with: .success(snapshot())); await settle()
        XCTAssertNil(try CardShowInventoryService.importedList(context: context))
        XCTAssertFalse(model.isRefreshing); XCTAssertGreaterThan(provider.cancels, 0)
        model.setActive(true); model.refresh(context: context); try await provider.waitForRequests(2)
        provider.finish(1, with: .success(snapshot(quantity: 3))); try await idle(model)
        XCTAssertEqual(try CardShowInventoryService.importedList(context: context)?.quantity, 3)
    }

    func testOldReplyCannotOverwriteNewRefreshOrItsTimestamp() async throws {
        let container = try store(), context = container.mainContext
        let provider = ImportModelProvider(held: true)
        let model = CardShowInventoryModel(provider: provider, workingStore: workingStore())
        model.setActive(true); model.refresh(context: context); try await provider.waitForRequests(1)
        model.cancel(); model.refresh(context: context); try await provider.waitForRequests(2)
        let recent = Date(timeIntervalSince1970: 200)
        provider.finish(1, with: .success(snapshot(quantity: 3, date: recent))); try await idle(model)
        provider.finish(0, with: .success(snapshot(quantity: 99))); await settle()
        let list = try XCTUnwrap(CardShowInventoryService.importedList(context: context))
        XCTAssertEqual(list.quantity, 3); XCTAssertEqual(list.cardShowInventory?.refreshedAt, recent)
    }

    func testDeletedSavedListIsNotRecreatedByLateRefresh() async throws {
        let container = try store(), context = container.mainContext
        let list = try CardShowInventoryService.apply(snapshot(), context: context)
        let provider = ImportModelProvider(held: true)
        let model = CardShowInventoryModel(provider: provider, workingStore: workingStore())
        model.setActive(true); model.refresh(context: context); try await provider.waitForRequests(1)
        context.delete(list); try context.save()
        provider.finish(0, with: .success(snapshot(quantity: 99))); try await idle(model)
        XCTAssertNil(try CardShowInventoryService.importedList(context: context))
        XCTAssertNil(model.lastImportedListID); XCTAssertNotNil(model.message)
    }

    func testCompetingFirstImportKeepsItsListAndRows() async throws {
        let container = try store(), context = container.mainContext
        let provider = ImportModelProvider(held: true)
        let model = CardShowInventoryModel(provider: provider, workingStore: workingStore())
        model.setActive(true); model.refresh(context: context); try await provider.waitForRequests(1)
        let current = try CardShowInventoryService.apply(snapshot(quantity: 3), context: context)
        let id = current.id, rowID = try XCTUnwrap(current.cards.first).id
        provider.finish(0, with: .success(snapshot(quantity: 99))); try await idle(model)
        XCTAssertEqual(try CardShowInventoryService.importedList(context: context)?.id, id)
        XCTAssertEqual(current.quantity, 3); XCTAssertEqual(current.cards.first?.id, rowID)
        XCTAssertNil(model.lastImportedListID); XCTAssertNotNil(model.message)
    }

    func testNewerCommittedSnapshotWinsOverAnotherModelsLateRefresh() async throws {
        let container = try store(), context = container.mainContext
        let list = try CardShowInventoryService.apply(snapshot(), context: context)
        let provider = ImportModelProvider(held: true)
        let older = CardShowInventoryModel(provider: provider, workingStore: workingStore())
        older.setActive(true); older.refresh(context: context); try await provider.waitForRequests(1)
        let recentDate = Date(timeIntervalSince1970: 300)
        let newerProvider = ImportModelProvider(responses: [.success(snapshot(quantity: 4, date: recentDate))])
        let newer = CardShowInventoryModel(provider: newerProvider, workingStore: workingStore())
        newer.setActive(true); newer.refresh(context: context); try await idle(newer)
        provider.finish(0, with: .success(snapshot(quantity: 99, date: Date(timeIntervalSince1970: 200))))
        try await idle(older)
        XCTAssertEqual(list.quantity, 4); XCTAssertEqual(list.cardShowInventory?.refreshedAt, recentDate)
        XCTAssertNil(older.lastImportedListID); XCTAssertNotNil(older.message)
        XCTAssertEqual(newer.lastImportedListID, list.id)
    }

    func testSignInFailureKeepsSavedInventoryAndAllowsRetry() async throws {
        let container = try store(), context = container.mainContext
        let previous = snapshot(), list = try CardShowInventoryService.apply(previous, context: context)
        let provider = ImportModelProvider(responses: [.failure(CardShowInventoryFailure.signInRequired), .success(snapshot(quantity: 4))])
        let model = CardShowInventoryModel(provider: provider, workingStore: workingStore())
        model.setActive(true); model.refresh(context: context); try await idle(model)
        XCTAssertTrue(model.needsSignIn); XCTAssertNotNil(model.message)
        XCTAssertEqual(list.quantity, 2); XCTAssertEqual(list.cardShowInventory?.refreshedAt, previous.fetchedAt)
        model.refresh(context: context); try await idle(model)
        XCTAssertFalse(model.needsSignIn); XCTAssertEqual(list.quantity, 4)
    }

    func testConnectivityFailureKeepsSavedInventoryAndDoesNotClaimRefresh() async throws {
        let container = try store(), context = container.mainContext
        let previous = snapshot(), list = try CardShowInventoryService.apply(previous, context: context)
        let provider = ImportModelProvider(responses: [.failure(CardShowInventoryFailure.networkUnavailable)])
        let model = CardShowInventoryModel(provider: provider, workingStore: workingStore())
        model.setActive(true); model.refresh(context: context); try await idle(model)
        XCTAssertFalse(model.needsSignIn); XCTAssertNotNil(model.message); XCTAssertNil(model.lastImportedListID)
        XCTAssertEqual(list.quantity, 2); XCTAssertEqual(list.cardShowInventory?.refreshedAt, previous.fetchedAt)
    }

    func testPersistenceFailureLeavesPreviousSavedCopyAvailable() async throws {
        let container = try store(), context = container.mainContext
        let previous = snapshot(), list = try CardShowInventoryService.apply(previous, context: context)
        let provider = ImportModelProvider(responses: [.success(snapshot(quantity: 99))])
        let model = CardShowInventoryModel(provider: provider, workingStore: workingStore(), applySnapshot: { _, _ in throw CardShowInventoryFailure.persistenceFailed })
        model.setActive(true); model.refresh(context: context); try await idle(model)
        XCTAssertNotNil(model.message); XCTAssertNil(model.lastImportedListID)
        XCTAssertEqual(list.quantity, 2); XCTAssertEqual(list.cardShowInventory?.refreshedAt, previous.fetchedAt)
    }

    func testFreshRefreshReplacesStaleWorkingQuantityAndAcknowledgesSource() async throws {
        let container = try store(), context = container.mainContext
        let working = workingStore()
        try working.seedInventory([.init(sourceInventoryID: 7001, card: snapshot().rows[0].card,
            quantity: 86)], sourceLocationID: 9001)
        let provider = ImportModelProvider(responses: [.success(snapshot(quantity: 80))])
        let model = CardShowInventoryModel(provider: provider, workingStore: working)
        model.setActive(true); model.refresh(context: context); try await idle(model)

        let imported = try XCTUnwrap(CardShowInventoryService.importedList(context: context))
        XCTAssertEqual(imported.quantity, 80)
        XCTAssertEqual(working.inventory.reduce(0) { $0 + $1.quantity }, 80)
        XCTAssertEqual(working.book.inventoryReconciliations.count, 1)
        XCTAssertEqual(imported.cardShowInventory?.pendingWorkingSync, false)
        XCTAssertEqual(model.lastImportedListID, imported.id)
        XCTAssertFalse(model.workingSyncFailed)
    }

    func testFailedWorkingSaveKeepsDownloadedSourcePendingAndRetriesWithoutNetwork() async throws {
        let container = try store(), context = container.mainContext
        let disk = WorkingDisk(), working = workingStore(disk)
        disk.fail = true
        let provider = ImportModelProvider(responses: [.success(snapshot(quantity: 4))])
        let model = CardShowInventoryModel(provider: provider, workingStore: working)
        model.setActive(true); model.refresh(context: context); try await idle(model)

        let imported = try XCTUnwrap(CardShowInventoryService.importedList(context: context))
        let syncID = imported.cardShowInventory?.syncID
        XCTAssertEqual(imported.quantity, 4)
        XCTAssertEqual(imported.cardShowInventory?.pendingWorkingSync, true)
        XCTAssertTrue(working.inventory.isEmpty)
        XCTAssertTrue(model.workingSyncFailed); XCTAssertNotNil(model.message)
        XCTAssertNil(model.lastImportedListID)
        XCTAssertEqual(provider.expectedLocations.count, 1)

        disk.fail = false
        model.retryWorkingInventory(context: context)
        XCTAssertFalse(model.workingSyncFailed)
        XCTAssertEqual(model.lastImportedListID, imported.id)
        XCTAssertEqual(imported.cardShowInventory?.syncID, syncID)
        XCTAssertEqual(imported.cardShowInventory?.pendingWorkingSync, false)
        XCTAssertEqual(working.inventory.reduce(0) { $0 + $1.quantity }, 4)
        XCTAssertEqual(provider.expectedLocations.count, 1)
        XCTAssertEqual(workingStore(disk).book, working.book)
    }

    func testPendingEarlierDownloadMustFinishBeforeAnotherWebsiteRequest() async throws {
        let container = try store(), context = container.mainContext
        let imported = try CardShowInventoryService.apply(snapshot(quantity: 2), context: context)
        let sourceData = imported.inventorySourceData
        let working = workingStore()
        var refuseSync = true
        let provider = ImportModelProvider(responses: [.success(snapshot(quantity: 99))])
        let model = CardShowInventoryModel(provider: provider, workingStore: working,
            synchronizeWorkingInventory: { list, context, store in
                if refuseSync { throw CocoaError(.fileWriteOutOfSpace) }
                return try ShowInventoryBridge.synchronizeImportedList(list, context: context, store: store)
            })
        model.setActive(true); model.refresh(context: context)
        XCTAssertTrue(model.workingSyncFailed)
        XCTAssertTrue(provider.expectedLocations.isEmpty)
        XCTAssertEqual(imported.inventorySourceData, sourceData)
        XCTAssertEqual(imported.quantity, 2)

        refuseSync = false
        model.retryWorkingInventory(context: context)
        XCTAssertFalse(model.workingSyncFailed)
        XCTAssertTrue(provider.expectedLocations.isEmpty)
        XCTAssertEqual(working.inventory.reduce(0) { $0 + $1.quantity }, 2)
        model.refresh(context: context); try await idle(model)
        XCTAssertEqual(provider.expectedLocations.count, 1)
        XCTAssertEqual(working.inventory.reduce(0) { $0 + $1.quantity }, 99)
    }

    func testRetryAfterCommittedWorkingSyncPreservesASubsequentSale() async throws {
        let container = try store(), context = container.mainContext
        let working = workingStore()
        let showID = try working.create(name: "Retry show", startingCents: 30_000)
        var failAcknowledgement = true
        let provider = ImportModelProvider(responses: [.success(snapshot(quantity: 4))])
        let model = CardShowInventoryModel(provider: provider, workingStore: working,
            synchronizeWorkingInventory: { list, context, store in
                let pending = list.inventorySourceData
                let result = try ShowInventoryBridge.synchronizeImportedList(list, context: context, store: store)
                if failAcknowledgement {
                    failAcknowledgement = false
                    list.inventorySourceData = pending; try context.save()
                    throw CocoaError(.fileWriteOutOfSpace)
                }
                return result
            })
        model.setActive(true); model.refresh(context: context); try await idle(model)
        let imported = try XCTUnwrap(CardShowInventoryService.importedList(context: context))
        XCTAssertTrue(model.workingSyncFailed)
        XCTAssertEqual(imported.cardShowInventory?.pendingWorkingSync, true)
        let stockID = try XCTUnwrap(working.inventory.first?.id)
        let sold = try working.recordTransaction(.init(kind: .sale,
            outgoing: [.init(inventoryID: stockID, quantity: 1)], saleReceivedCents: 1_000), showID: showID)
        let afterSale = working.book

        model.retryWorkingInventory(context: context)
        XCTAssertFalse(model.workingSyncFailed)
        XCTAssertEqual(imported.cardShowInventory?.pendingWorkingSync, false)
        XCTAssertEqual(working.book, afterSale)
        XCTAssertEqual(working.inventory.first { $0.id == stockID }?.quantity, 3)
        XCTAssertEqual(working.transactions, [sold])
        XCTAssertEqual(provider.expectedLocations.count, 1)
    }

    func testSaleDuringDownloadKeepsWorkingStockAndDiscardsLateWebsiteSnapshot() async throws {
        let container = try store(), context = container.mainContext
        let imported = try CardShowInventoryService.apply(snapshot(), context: context)
        let working = workingStore()
        try ShowInventoryBridge.seedFromImportedList(context: context, store: working)
        let showID = try working.create(name: "Concurrent sale", startingCents: 30_000)
        let source = imported.inventorySourceData
        let provider = ImportModelProvider(held: true)
        let model = CardShowInventoryModel(provider: provider, workingStore: working)
        model.setActive(true); model.refresh(context: context); try await provider.waitForRequests(1)
        let stockID = try XCTUnwrap(working.inventory.first?.id)
        try working.recordTransaction(.init(kind: .sale,
            outgoing: [.init(inventoryID: stockID, quantity: 1)], saleReceivedCents: 1_000), showID: showID)
        let afterSale = working.book
        provider.finish(0, with: .success(snapshot(quantity: 99))); try await idle(model)

        XCTAssertEqual(working.book, afterSale)
        XCTAssertEqual(imported.inventorySourceData, source)
        XCTAssertEqual(imported.quantity, 2)
        XCTAssertEqual(working.inventory.first { $0.id == stockID }?.quantity, 1)
        XCTAssertNil(model.lastImportedListID); XCTAssertNotNil(model.message)
    }

    func testAnotherStoresCostAdjustmentDuringDownloadIsReloadedAndPreserved() async throws {
        let container = try store(), context = container.mainContext
        let imported = try CardShowInventoryService.apply(snapshot(), context: context)
        let disk = WorkingDisk(), working = workingStore(disk)
        try ShowInventoryBridge.seedFromImportedList(context: context, store: working)
        let source = imported.inventorySourceData
        let provider = ImportModelProvider(held: true)
        let model = CardShowInventoryModel(provider: provider, workingStore: working)
        model.setActive(true); model.refresh(context: context); try await provider.waitForRequests(1)
        let other = workingStore(disk), stockID = try XCTUnwrap(other.inventory.first?.id)
        try other.setInventoryCost(itemID: stockID, totalCostCents: 700)
        provider.finish(0, with: .success(snapshot(quantity: 99))); try await idle(model)

        XCTAssertEqual(working.book, other.book)
        XCTAssertEqual(working.inventory.first?.remainingCostCents, 700)
        XCTAssertEqual(imported.inventorySourceData, source)
        XCTAssertEqual(imported.quantity, 2)
        XCTAssertNil(model.lastImportedListID); XCTAssertNotNil(model.message)
    }

    func testRefreshReloadsEarlierCommittedSaleBeforeCapturingWorkingVersion() async throws {
        let container = try store(), context = container.mainContext
        try CardShowInventoryService.apply(snapshot(), context: context)
        let disk = WorkingDisk(), working = workingStore(disk)
        try ShowInventoryBridge.seedFromImportedList(context: context, store: working)
        let showID = try working.create(name: "Saved sale", startingCents: 30_000)
        let other = workingStore(disk), stockID = try XCTUnwrap(other.inventory.first?.id)
        let sold = try other.recordTransaction(.init(kind: .sale,
            outgoing: [.init(inventoryID: stockID, quantity: 1)], saleReceivedCents: 1_000), showID: showID)
        let provider = ImportModelProvider(responses: [.success(snapshot(quantity: 3))])
        let model = CardShowInventoryModel(provider: provider, workingStore: working)
        model.setActive(true); model.refresh(context: context); try await idle(model)

        XCTAssertEqual(working.transactions, [sold])
        XCTAssertEqual(working.inventory.reduce(0) { $0 + $1.quantity }, 3)
        XCTAssertNotNil(model.lastImportedListID)
        XCTAssertEqual(workingStore(disk).book, working.book)
    }

    func testDeletedSourceRetainsWorkingLocationAndRejectsWrongLocationBeforeApplying() async throws {
        let container = try store(), context = container.mainContext
        let imported = try CardShowInventoryService.apply(snapshot(), context: context)
        let working = workingStore()
        try ShowInventoryBridge.seedFromImportedList(context: context, store: working)
        context.delete(imported); try context.save()
        let before = working.book
        var applies = 0
        let provider = ImportModelProvider(responses: [.success(snapshot(quantity: 99, locationID: 9002))])
        let model = CardShowInventoryModel(provider: provider, workingStore: working, applySnapshot: { snapshot, context in
            applies += 1
            return try CardShowInventoryService.apply(snapshot, context: context)
        })
        model.setActive(true); model.refresh(context: context); try await idle(model)

        XCTAssertEqual(provider.expectedLocations, [9001])
        XCTAssertEqual(applies, 0)
        XCTAssertNil(try CardShowInventoryService.importedList(context: context))
        XCTAssertEqual(working.book, before)
        XCTAssertNil(model.lastImportedListID); XCTAssertNotNil(model.message)
    }

    func testFailedUncommittedSyncCannotRestoreALaterSaleAndFreshRefreshCanRecover() async throws {
        let container = try store(), context = container.mainContext
        let disk = WorkingDisk(), working = workingStore(disk)
        try working.seedInventory([.init(sourceInventoryID: 7001, card: snapshot().rows[0].card,
            quantity: 4)], sourceLocationID: 9001)
        let showID = try working.create(name: "Sale after failed sync", startingCents: 30_000)
        let provider = ImportModelProvider(responses: [.success(snapshot(quantity: 4)), .success(snapshot(quantity: 2))])
        let model = CardShowInventoryModel(provider: provider, workingStore: working)
        disk.fail = true
        model.setActive(true); model.refresh(context: context); try await idle(model)
        let imported = try XCTUnwrap(CardShowInventoryService.importedList(context: context))
        XCTAssertTrue(model.workingSyncFailed)
        XCTAssertEqual(imported.cardShowInventory?.pendingWorkingSync, true)
        XCTAssertTrue(working.book.inventoryReconciliations.isEmpty)

        disk.fail = false
        let stockID = try XCTUnwrap(working.inventory.first?.id)
        let sold = try working.recordTransaction(.init(kind: .sale,
            outgoing: [.init(inventoryID: stockID, quantity: 1)], saleReceivedCents: 1_000), showID: showID)
        let afterSale = working.book
        let cash = try XCTUnwrap(working.activeShow).totals()
        model.retryWorkingInventory(context: context)
        XCTAssertTrue(model.workingSyncFailed)
        XCTAssertEqual(working.book, afterSale)
        XCTAssertEqual(working.inventory.reduce(0) { $0 + $1.quantity }, 3)
        XCTAssertEqual(imported.cardShowInventory?.pendingWorkingSync, true)
        XCTAssertEqual(provider.expectedLocations.count, 1)

        model.refresh(context: context); try await idle(model)
        XCTAssertFalse(model.workingSyncFailed)
        XCTAssertEqual(provider.expectedLocations, [9001, 9001])
        XCTAssertEqual(imported.quantity, 2)
        XCTAssertEqual(imported.cardShowInventory?.pendingWorkingSync, false)
        XCTAssertEqual(working.inventory.reduce(0) { $0 + $1.quantity }, 2)
        XCTAssertEqual(working.transactions, [sold])
        XCTAssertEqual(try XCTUnwrap(working.activeShow).totals(), cash)
        XCTAssertEqual(working.book.inventoryReconciliations.count, 1)
    }

    func testUnreadableWorkingLedgerBlocksWebsiteRequestAndPreservesSavedSource() throws {
        let container = try store(), context = container.mainContext
        let imported = try CardShowInventoryService.apply(snapshot(), context: context)
        let source = imported.inventorySourceData
        let disk = WorkingDisk(); disk.data = Data("damaged financial file".utf8)
        let provider = ImportModelProvider(responses: [.success(snapshot(quantity: 99))])
        let model = CardShowInventoryModel(provider: provider, workingStore: workingStore(disk))
        model.setActive(true); model.refresh(context: context)

        XCTAssertTrue(provider.expectedLocations.isEmpty)
        XCTAssertFalse(model.isRefreshing); XCTAssertNotNil(model.message)
        XCTAssertEqual(imported.inventorySourceData, source)
        XCTAssertEqual(imported.quantity, 2)
        XCTAssertEqual(disk.data, Data("damaged financial file".utf8))
        XCTAssertEqual(disk.writes, 0)
    }

    private func idle(_ model: CardShowInventoryModel) async throws {
        for _ in 0..<200 {
            if !model.isRefreshing { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Inventory refresh did not finish"); throw URLError(.timedOut)
    }
    private func settle() async { for _ in 0..<30 { await Task.yield() } }
}

@MainActor private final class ImportModelProvider: CardShowInventoryProviding {
    var expectedLocations: [Int?] = []
    var cancels = 0
    private let held: Bool
    private var responses: [Result<CardShowInventorySnapshot, Error>]
    private var pending: [CheckedContinuation<CardShowInventorySnapshot, Error>?] = []
    init(responses: [Result<CardShowInventorySnapshot, Error>] = [], held: Bool = false) {
        self.responses = responses; self.held = held
    }
    func fetch(expectedLocationID: Int?) async throws -> CardShowInventorySnapshot {
        expectedLocations.append(expectedLocationID)
        if held { return try await withCheckedThrowingContinuation { pending.append($0) } }
        guard !responses.isEmpty else { throw CardShowInventoryFailure.networkUnavailable }
        return try responses.removeFirst().get()
    }
    func cancel() { cancels += 1 }
    func finish(_ index: Int, with result: Result<CardShowInventorySnapshot, Error>) {
        let continuation = pending[index]; pending[index] = nil; continuation?.resume(with: result)
    }
    func waitForRequests(_ count: Int) async throws {
        for _ in 0..<200 {
            if expectedLocations.count >= count { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw URLError(.timedOut)
    }
}
