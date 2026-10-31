import XCTest
import SwiftData
@testable import CardShowScanner

@MainActor final class ListBulkDeletionTests: XCTestCase {
    private enum Failure: Error { case refused }
    private func store() throws -> ModelContainer {
        try ModelContainer(for: CardList.self, InventoryCard.self, ScanSession.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }
    private func list(_ name: String, context: ModelContext, quantity: Int = 1) throws -> CardList {
        let list = CardList(name: name); context.insert(list)
        let card = CardCandidate(identity: .init(game: "Pokémon", productID: "p:42", printing: "Normal"),
            name: "Fixture card", set: "Fixture set", number: "42", marketPrice: 10, confidence: 100, printings: ["Normal"])
        let row = try InventoryCard(card: card, quantity: quantity); context.insert(row); list.cards.append(row)
        return list
    }
    private func session(_ list: CardList, context: ModelContext, active: Bool) -> ScanSession {
        let session = ScanSession(listName: list.name); session.listID = list.id
        session.game = "Pokémon"; session.statusRaw = active ? "active" : "completed"
        session.savedOffersData = Data("[]".utf8); context.insert(session); return session
    }

    func testSelectedListsDeleteTogetherAndHistoryOffersAndOtherListsRemain() throws {
        let container = try store(), context = container.mainContext
        let first = try list("First", context: context, quantity: 2)
        let second = try list("Second", context: context), keep = try list("Keep", context: context)
        let firstID = first.id, secondID = second.id, keepID = keep.id
        let active = session(first, context: context, active: true)
        let history = session(second, context: context, active: false)
        let retained = session(keep, context: context, active: false)
        let absentID = UUID()
        let orphan = ScanSession(listName: "Older absent list"); orphan.listID = absentID; context.insert(orphan)
        try context.save()
        var saves = 0
        try SessionService.deleteLists(ids: [firstID, secondID, absentID], context: context, save: {
            saves += 1; try $0.save()
        })
        XCTAssertEqual(saves, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<CardList>()).map(\.id), [keepID])
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<InventoryCard>()), 1)
        XCTAssertNil(active.listID); XCTAssertEqual(active.statusRaw, "completed"); XCTAssertNotNil(active.completedAt)
        XCTAssertNil(history.listID); XCTAssertEqual(history.listName, "Second")
        XCTAssertEqual(active.savedOffersData, Data("[]".utf8)); XCTAssertEqual(history.savedOffersData, Data("[]".utf8))
        XCTAssertEqual(retained.listID, keepID)
        XCTAssertEqual(orphan.listID, absentID)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ScanSession>()), 4)
        XCTAssertFalse(context.hasChanges)
    }

    func testEmptyOrAlreadyDeletedSelectionsDoNotSave() throws {
        let container = try store(), context = container.mainContext
        var saves = 0
        try SessionService.deleteLists(ids: [], context: context, save: { _ in saves += 1 })
        try SessionService.deleteLists(ids: [UUID()], context: context, save: { _ in saves += 1 })
        XCTAssertEqual(saves, 0); XCTAssertFalse(context.hasChanges)
    }

    func testFailureRestoresAllRowsAndSessionLinksAndRetryCommitsOnce() throws {
        let container = try store(), context = container.mainContext
        let first = try list("First", context: context, quantity: 3), second = try list("Second", context: context)
        let ids: Set<UUID> = [first.id, second.id]
        let active = session(first, context: context, active: true)
        let originalRows = first.orderedCards.map(\.id), originalOffers = active.savedOffersData
        try context.save()
        XCTAssertThrowsError(try SessionService.deleteLists(ids: ids, context: context, save: { _ in throw Failure.refused }))
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<CardList>()), 2)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<InventoryCard>()), 2)
        XCTAssertEqual(first.orderedCards.map(\.id), originalRows); XCTAssertEqual(first.quantity, 3)
        XCTAssertEqual(active.listID, first.id); XCTAssertTrue(active.isActive); XCTAssertNil(active.completedAt)
        XCTAssertEqual(active.savedOffersData, originalOffers); XCTAssertFalse(context.hasChanges)
        try SessionService.deleteLists(ids: ids, context: context)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<CardList>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<InventoryCard>()), 0)
        XCTAssertNil(active.listID); XCTAssertEqual(active.savedOffersData, originalOffers)
    }

    func testDirtyDraftIsPreservedAndDeletionDoesNotStart() throws {
        let container = try store(), context = container.mainContext
        let target = try list("Target", context: context); try context.save()
        let draft = CardList(name: "Uncommitted draft"); context.insert(draft)
        XCTAssertThrowsError(try SessionService.deleteLists(ids: [target.id], context: context)) {
            XCTAssertEqual($0 as? ListBulkDeletionFailure, .pendingChanges)
        }
        XCTAssertTrue(context.hasChanges)
        XCTAssertTrue(context.insertedModelsArray.contains { ($0 as? CardList)?.id == draft.id })
        XCTAssertEqual(target.quantity, 1)
        XCTAssertEqual(try ModelContext(container).fetchCount(FetchDescriptor<CardList>()), 1)
    }

    func testCancelAndRepeatedConfirmationDoNotDeleteOrDoubleSave() throws {
        let container = try store(), context = container.mainContext
        let first = try list("First", context: context), second = try list("Second", context: context); try context.save()
        let request = ListBulkDeletionRequest(lists: [first, second, first])
        XCTAssertEqual(request.ids.count, 2); XCTAssertEqual(request.quantity, 2)
        var calls = 0
        let cancelled = ListBulkDeletionModel(request: request, delete: { _, _ in calls += 1 })
        cancelled.cancel(); XCTAssertFalse(cancelled.confirm(context: context)); XCTAssertEqual(calls, 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<CardList>()), 2)
        let model = ListBulkDeletionModel(request: request, delete: { ids, context in
            calls += 1; try SessionService.deleteLists(ids: ids, context: context)
        })
        XCTAssertTrue(model.confirm(context: context)); XCTAssertFalse(model.confirm(context: context))
        XCTAssertEqual(calls, 1); XCTAssertTrue(model.didDelete)
    }

    func testImportedCopyCanBeSelectedAndRemovedWithoutAutomaticReimport() throws {
        let container = try store(), context = container.mainContext
        let card = CardCandidate(identity: .init(game: "Pokémon", productID: "p:42", skuID: "100", printing: "Normal"),
            name: "Source fixture", set: "Fixture set", number: "42", marketPrice: 10, confidence: 0, printings: ["Normal"])
        let source = try CardShowInventoryService.apply(.init(location: .init(id: 9001, name: "Card Show"),
            rows: [.init(inventoryID: 7001, card: card, quantity: 2)], fetchedAt: .now), context: context)
        let request = ListBulkDeletionRequest(lists: [source])
        XCTAssertTrue(request.containsImportedInventory)
        try SessionService.deleteLists(ids: request.ids, context: context)
        XCTAssertNil(try CardShowInventoryService.importedList(context: context))
        XCTAssertNil(try CardShowInventoryService.importedList(context: ModelContext(container)))
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<InventoryCard>()), 0)
    }
}
