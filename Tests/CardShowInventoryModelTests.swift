import XCTest
import SwiftData
@testable import CardShowScanner

@MainActor final class CardShowInventoryModelTests: XCTestCase {
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
        let model = CardShowInventoryModel(provider: provider)
        model.setActive(true)
        XCTAssertEqual(provider.expectedLocations.count, 0)
        XCTAssertEqual(list.quantity, 2); XCTAssertFalse(model.isRefreshing)
        XCTAssertNil(model.message)
    }

    func testImportAndRefreshUseSavedLocationAndKeepOneListAndRow() async throws {
        let container = try store(), context = container.mainContext
        let provider = ImportModelProvider(responses: [.success(snapshot()), .success(snapshot(quantity: 3))])
        let model = CardShowInventoryModel(provider: provider)
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
        let model = CardShowInventoryModel(provider: provider, applySnapshot: {
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
        let model = CardShowInventoryModel(provider: provider)
        model.refresh(context: container.mainContext)
        await settle()
        XCTAssertTrue(provider.expectedLocations.isEmpty); XCTAssertFalse(model.isRefreshing)
    }

    func testCanceledResponseCannotCreateListAndNextRefreshCanSucceed() async throws {
        let container = try store(), context = container.mainContext
        let provider = ImportModelProvider(held: true)
        let model = CardShowInventoryModel(provider: provider)
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
        let model = CardShowInventoryModel(provider: provider)
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
        let model = CardShowInventoryModel(provider: provider)
        model.setActive(true); model.refresh(context: context); try await provider.waitForRequests(1)
        context.delete(list); try context.save()
        provider.finish(0, with: .success(snapshot(quantity: 99))); try await idle(model)
        XCTAssertNil(try CardShowInventoryService.importedList(context: context))
        XCTAssertNil(model.lastImportedListID); XCTAssertNotNil(model.message)
    }

    func testCompetingFirstImportKeepsItsListAndRows() async throws {
        let container = try store(), context = container.mainContext
        let provider = ImportModelProvider(held: true)
        let model = CardShowInventoryModel(provider: provider)
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
        let older = CardShowInventoryModel(provider: provider)
        older.setActive(true); older.refresh(context: context); try await provider.waitForRequests(1)
        let recentDate = Date(timeIntervalSince1970: 300)
        let newerProvider = ImportModelProvider(responses: [.success(snapshot(quantity: 4, date: recentDate))])
        let newer = CardShowInventoryModel(provider: newerProvider)
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
        let model = CardShowInventoryModel(provider: provider)
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
        let model = CardShowInventoryModel(provider: provider)
        model.setActive(true); model.refresh(context: context); try await idle(model)
        XCTAssertFalse(model.needsSignIn); XCTAssertNotNil(model.message); XCTAssertNil(model.lastImportedListID)
        XCTAssertEqual(list.quantity, 2); XCTAssertEqual(list.cardShowInventory?.refreshedAt, previous.fetchedAt)
    }

    func testPersistenceFailureLeavesPreviousSavedCopyAvailable() async throws {
        let container = try store(), context = container.mainContext
        let previous = snapshot(), list = try CardShowInventoryService.apply(previous, context: context)
        let provider = ImportModelProvider(responses: [.success(snapshot(quantity: 99))])
        let model = CardShowInventoryModel(provider: provider, applySnapshot: { _, _ in throw CardShowInventoryFailure.persistenceFailed })
        model.setActive(true); model.refresh(context: context); try await idle(model)
        XCTAssertNotNil(model.message); XCTAssertNil(model.lastImportedListID)
        XCTAssertEqual(list.quantity, 2); XCTAssertEqual(list.cardShowInventory?.refreshedAt, previous.fetchedAt)
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
