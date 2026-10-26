import XCTest
import SwiftData
@testable import CardShowScanner

@MainActor final class ListDeletionTests: XCTestCase {
    private enum InjectedDeleteFailure: Error { case saveRefused }

    private func store() throws -> ModelContainer {
        try ModelContainer(for: CardList.self, InventoryCard.self, ScanSession.self,
                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    func testOpeningCancellingAndDismissingNeverDeleteAndLogEachTransitionOnce() async throws {
        let container = try store(), context = container.mainContext
        let list = CardList(name: "PRIVATE_LIST_NAME"); context.insert(list)
        try CardListService.add(MockScannerProvider.samples(game: "Pokémon", index: 0)[0], to: list, context: context)
        try context.save()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "ListDeletionTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let log = DiagnosticLog(directory: directory, defaults: defaults)
        var invocations = 0
        let model = ListDeletionModel(request: ListDeletionRequest(list: list), delete: { _, _ in invocations += 1 }, log: log)
        model.presented(); model.presented(); model.cancel(); model.cancel(); model.dismissed(); model.dismissed()
        XCTAssertFalse(model.confirm(context: context)); XCTAssertEqual(invocations, 0)
        XCTAssertFalse(model.didDelete); XCTAssertFalse(model.isDeleting); XCTAssertNil(model.error)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<CardList>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<InventoryCard>()), 1)
        XCTAssertFalse(context.hasChanges)
        let export = try log.export()
        defer { try? FileManager.default.removeItem(at: export.deletingLastPathComponent()) }
        let text = try String(contentsOf: export, encoding: .utf8)
        XCTAssertFalse(text.contains("PRIVATE_LIST_NAME"))
        let rows = try text.split(separator: "\n").map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
        let events = rows.compactMap { $0["event"] as? String }.filter { $0.hasPrefix("list.delete_") }
        XCTAssertEqual(events, ["list.delete_presented", "list.delete_cancelled", "list.delete_dismissed"])
        let dismissal = try XCTUnwrap(rows.first { $0["event"] as? String == "list.delete_dismissed" })
        XCTAssertEqual((dismissal["fields"] as? [String: String])?["reason"], "cancelled")
    }

    func testDismissalWithoutConfirmationKeepsTheList() async throws {
        let container = try store(), context = container.mainContext
        let list = CardList(name: "Keep"); context.insert(list); try context.save()
        let model = ListDeletionModel(request: ListDeletionRequest(list: list))
        model.presented(); model.dismissed()
        XCTAssertFalse(model.confirm(context: context)); XCTAssertFalse(model.didDelete)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<CardList>()), 1)
    }

    func testConfirmationTargetsSnapshotUUIDAfterListAndQueryChange() async throws {
        let container = try store(), context = container.mainContext
        let target = CardList(name: "Same name"); context.insert(target); try context.save()
        let request = ListDeletionRequest(list: target)
        target.name = "Renamed while confirmation is open"
        let other = CardList(name: "Same name"); context.insert(other); try context.save()
        let model = ListDeletionModel(request: request)
        XCTAssertEqual(model.request.name, "Same name")
        XCTAssertTrue(model.confirm(context: context)); XCTAssertTrue(model.didDelete)
        let remaining = try context.fetch(FetchDescriptor<CardList>())
        XCTAssertEqual(remaining.count, 1); XCTAssertEqual(remaining.first?.id, other.id)
        XCTAssertEqual(model.request, request)
    }

    func testRepeatedAndReentrantConfirmationCommitOnlyOnce() async throws {
        let container = try store(), context = container.mainContext
        let list = CardList(name: "Delete"); context.insert(list); try context.save()
        var invocations = 0
        var reenter: (() -> Void)?
        let model = ListDeletionModel(request: ListDeletionRequest(list: list), delete: { id, context in
            invocations += 1; reenter?()
            try SessionService.deleteList(id: id, context: context)
        })
        reenter = { [weak model] in
            XCTAssertTrue(model?.isDeleting == true)
            XCTAssertFalse(model?.confirm(context: context) ?? true)
        }
        XCTAssertTrue(model.confirm(context: context))
        XCTAssertFalse(model.confirm(context: context))
        XCTAssertEqual(invocations, 1); XCTAssertTrue(model.didDelete); XCTAssertFalse(model.isDeleting)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<CardList>()), 0)
    }

    func testTargetAlreadyRemovedDoesNotDeleteAnotherList() async throws {
        let container = try store(), context = container.mainContext
        let target = CardList(name: "Target"), other = CardList(name: "Other")
        context.insert(target); context.insert(other); try context.save()
        let request = ListDeletionRequest(list: target)
        try SessionService.deleteList(id: request.id, context: context)
        let model = ListDeletionModel(request: request)
        XCTAssertTrue(model.confirm(context: context)); XCTAssertTrue(model.didDelete)
        let remaining = try context.fetch(FetchDescriptor<CardList>())
        XCTAssertEqual(remaining.count, 1); XCTAssertEqual(remaining.first?.id, other.id)
    }

    func testFailedStagedDeletionRollsBackThenRetryPersistsAndPreservesOtherOrderAndOffers() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("delete-retry.store")
        let container = try AppPersistence.open(url: url), context = container.mainContext
        let targetSession = try SessionService.start(game: "Pokémon", context: context)
        let target = try XCTUnwrap(SessionService.list(for: targetSession, context: context))
        let cards = MockScannerProvider.samples(game: "Pokémon", index: 0)
        for card in [cards[0], cards[1], cards[0]] {
            try SessionService.add(card, session: targetSession, list: target, context: context)
        }
        try SessionService.saveOffer(targetSession, list: target, context: context, customCashOffer: 15)
        let targetOffers = targetSession.savedOffersData
        try SessionService.finish(targetSession, context: context)
        let otherSession = try SessionService.start(game: "Pokémon", context: context)
        let other = try XCTUnwrap(SessionService.list(for: otherSession, context: context))
        for card in [cards[1], cards[0]] {
            try SessionService.add(card, session: otherSession, list: other, context: context)
        }
        try SessionService.saveOffer(otherSession, list: other, context: context)
        let request = ListDeletionRequest(list: target), otherID = other.id, otherSessionID = otherSession.id
        let targetSessionID = targetSession.id, otherOffers = otherSession.savedOffersData
        let otherOrder = other.orderedCards.map(\.id), otherAddedDates = other.orderedCards.map(\.addedAt)
        var invocations = 0
        let model = ListDeletionModel(request: request, delete: { id, context in
            invocations += 1
            if invocations == 1 {
                let selected = try XCTUnwrap(context.fetch(FetchDescriptor<CardList>()).first { $0.id == id })
                let session = try XCTUnwrap(context.fetch(FetchDescriptor<ScanSession>()).first { $0.listID == id })
                session.listID = nil; session.statusRaw = "completed"
                context.delete(selected); context.processPendingChanges()
                throw InjectedDeleteFailure.saveRefused
            }
            try SessionService.deleteList(id: id, context: context)
        })
        XCTAssertFalse(model.confirm(context: context))
        XCTAssertFalse(model.didDelete); XCTAssertFalse(model.isDeleting); XCTAssertNotNil(model.error)
        XCTAssertEqual(model.request, request)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<CardList>()), 2)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<InventoryCard>()), 5)
        XCTAssertEqual(targetSession.listID, request.id); XCTAssertEqual(targetSession.savedOffersData, targetOffers)
        XCTAssertTrue(model.confirm(context: context)); XCTAssertTrue(model.didDelete)
        XCTAssertNil(model.error); XCTAssertEqual(invocations, 2)
        let reopened = try AppPersistence.open(url: url), stored = reopened.mainContext
        let lists = try stored.fetch(FetchDescriptor<CardList>())
        let kept = try XCTUnwrap(lists.first)
        XCTAssertEqual(lists.count, 1); XCTAssertEqual(kept.id, otherID)
        XCTAssertEqual(kept.orderedCards.map(\.id), otherOrder)
        XCTAssertEqual(kept.orderedCards.map(\.addedAt), otherAddedDates)
        XCTAssertEqual(try stored.fetchCount(FetchDescriptor<InventoryCard>()), 2)
        let history = try stored.fetch(FetchDescriptor<ScanSession>())
        let deleted = try XCTUnwrap(history.first { $0.id == targetSessionID })
        XCTAssertNil(deleted.listID); XCTAssertFalse(deleted.isActive)
        XCTAssertEqual(deleted.savedOffersData, targetOffers)
        let live = try XCTUnwrap(history.first { $0.id == otherSessionID })
        XCTAssertTrue(live.isActive); XCTAssertEqual(live.listID, otherID); XCTAssertEqual(live.savedOffersData, otherOffers)
    }
}
