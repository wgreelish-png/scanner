import XCTest
import SwiftData
@testable import CardShowScanner

@MainActor final class ScannerUndoTests: XCTestCase {
    private enum InjectedFailure: Error { case saveRefused }

    private func store() throws -> ModelContainer {
        try ModelContainer(for: CardList.self, InventoryCard.self, ScanSession.self,
                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }
    private func card(_ ref: String, price: Decimal?) -> CardCandidate {
        var card = MockScannerProvider.samples(game: "Pokémon", index: 0)[0]
        card.identity.productID = ref; card.identity.skuID = "12345"
        card.identity.printing = "Holofoil"; card.identity.condition = "Lightly Played"
        card.name = ref; card.marketPrice = price
        return card
    }
    private func batch(_ context: ModelContext) throws -> (ScanSession, CardList) {
        let session = try SessionService.start(game: "Pokémon", context: context)
        return (session, try XCTUnwrap(SessionService.list(for: session, context: context)))
    }
    @discardableResult private func add(_ card: CardCandidate, session: ScanSession, list: CardList,
                                       context: ModelContext) throws -> ScannerAddReceipt {
        let previous = session.lastConsumedRecognitionRef
        try SessionService.add(card, session: session, list: list, context: context)
        let item = try XCTUnwrap(list.orderedCards.last)
        return ScannerAddReceipt(item: item, session: session, list: list, previousRecognitionRef: previous)
    }

    func testUndoRemovesOnlyLastPhysicalDuplicateAndKeepsOrderAndHistoricalOffers() async throws {
        let container = try store(), context = container.mainContext
        let (session, list) = try batch(context)
        let a = card("p:100", price: Decimal(string: "12.50")), b = card("p:200", price: Decimal(string: "2.25"))
        try add(a, session: session, list: list, context: context)
        try add(b, session: session, list: list, context: context)
        let keptIDs = list.orderedCards.map(\.id), keptDates = list.orderedCards.map(\.addedAt)
        let undo = try add(a, session: session, list: list, context: context)
        try SessionService.saveOffer(session, list: list, context: context, customCashOffer: 15)
        let offers = session.savedOffersData, listID = list.id, sessionID = session.id
        XCTAssertTrue(SessionService.canUndoScannerAdd(undo, session: session, list: list))

        try SessionService.undoScannerAdd(undo, session: session, list: list, context: context)
        XCTAssertEqual(list.orderedCards.map(\.id), keptIDs); XCTAssertEqual(list.orderedCards.map(\.addedAt), keptDates)
        XCTAssertEqual(list.orderedCards.map(\.snapshot), [a, b]); XCTAssertTrue(list.cards.allSatisfy { $0.quantity == 1 })
        XCTAssertEqual(list.id, listID); XCTAssertEqual(session.id, sessionID); XCTAssertEqual(session.listID, listID)
        XCTAssertEqual(session.addedQuantity, 2); XCTAssertEqual(session.knownValue, Decimal(string: "14.75"))
        XCTAssertEqual(session.unpricedQuantity, 0); XCTAssertEqual(session.lastConsumedRecognitionRef, b.identity.productID)
        XCTAssertEqual(session.savedOffersData, offers)
        XCTAssertEqual(try session.savedOffers().first?.lines.count, 3)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<InventoryCard>()), 2)
        XCTAssertFalse(SessionService.canUndoScannerAdd(undo, session: session, list: list))
        XCTAssertThrowsError(try SessionService.undoScannerAdd(undo, session: session, list: list, context: context))
        XCTAssertEqual(list.quantity, 2); XCTAssertEqual(session.addedQuantity, 2)
    }

    func testUndoKnownZeroDoesNotCountAsUnpriced() async throws {
        let container = try store(), context = container.mainContext
        let (session, list) = try batch(context)
        try add(card("p:100", price: Decimal(string: "4.25")), session: session, list: list, context: context)
        let undo = try add(card("p:200", price: 0), session: session, list: list, context: context)
        XCTAssertEqual(list.unpricedQuantity, 0); XCTAssertEqual(session.unpricedQuantity, 0)
        XCTAssertEqual(undo.card.marketPrice, 0)
        try SessionService.undoScannerAdd(undo, session: session, list: list, context: context)
        XCTAssertEqual(session.addedQuantity, 1); XCTAssertEqual(session.knownValue, Decimal(string: "4.25"))
        XCTAssertEqual(session.unpricedQuantity, 0); XCTAssertEqual(list.unpricedQuantity, 0)
    }

    func testUndoUnpricedRowRestoresOnlyUnpricedCounter() async throws {
        let container = try store(), context = container.mainContext
        let (session, list) = try batch(context)
        try add(card("p:100", price: Decimal(string: "4.25")), session: session, list: list, context: context)
        let undo = try add(card("p:200", price: nil), session: session, list: list, context: context)
        XCTAssertEqual(session.unpricedQuantity, 1)
        try SessionService.undoScannerAdd(undo, session: session, list: list, context: context)
        XCTAssertEqual(session.addedQuantity, 1); XCTAssertEqual(session.knownValue, Decimal(string: "4.25"))
        XCTAssertEqual(session.unpricedQuantity, 0); XCTAssertEqual(list.unpricedQuantity, 0)
    }

    func testUndoSubtractsFromCurrentHistoryAndDoesNotOverwriteLaterRecognitionState() async throws {
        let container = try store(), context = container.mainContext
        let (session, list) = try batch(context)
        try add(card("p:100", price: 10), session: session, list: list, context: context)
        let undo = try add(card("p:200", price: 2), session: session, list: list, context: context)
        // Historical scan counters can include another row removed in list review.
        session.record(card("p:300", price: 7)); session.lastConsumedRecognitionRef = "p:300"
        try context.save()
        try SessionService.undoScannerAdd(undo, session: session, list: list, context: context)
        XCTAssertEqual(session.addedQuantity, 2); XCTAssertEqual(session.knownValue, 17)
        XCTAssertEqual(session.lastConsumedRecognitionRef, "p:300"); XCTAssertEqual(list.quantity, 1)
    }

    func testUndoRejectsAnOlderReceiptWhenAnotherPhysicalRowWasAdded() async throws {
        let container = try store(), context = container.mainContext
        let (session, list) = try batch(context)
        let older = try add(card("p:100", price: 10), session: session, list: list, context: context)
        try add(card("p:200", price: 2), session: session, list: list, context: context)
        let order = list.orderedCards.map(\.id)
        XCTAssertFalse(SessionService.canUndoScannerAdd(older, session: session, list: list))
        XCTAssertThrowsError(try SessionService.undoScannerAdd(older, session: session, list: list, context: context))
        XCTAssertEqual(list.orderedCards.map(\.id), order); XCTAssertEqual(session.addedQuantity, 2)
    }

    func testUndoRefusesCounterUnderflowAndInvalidKnownValueWithoutChangingTheRow() async throws {
        for change in ["quantity", "known", "invalid", "unpriced"] {
            let container = try store(), context = container.mainContext
            let (session, list) = try batch(context)
            let receipt = try add(card("p:100", price: change == "unpriced" ? nil : 10),
                                  session: session, list: list, context: context)
            switch change {
            case "quantity": session.addedQuantity = 0
            case "known": session.knownValueText = "1"
            case "invalid": session.knownValueText = "invalid"
            default: session.unpricedQuantity = 0
            }
            try context.save()
            let quantity = session.addedQuantity, value = session.knownValueText, unpriced = session.unpricedQuantity
            XCTAssertThrowsError(try SessionService.undoScannerAdd(receipt, session: session, list: list, context: context), change)
            XCTAssertEqual(list.cards.first?.id, receipt.inventoryID); XCTAssertEqual(list.quantity, 1)
            XCTAssertEqual(session.addedQuantity, quantity); XCTAssertEqual(session.knownValueText, value)
            XCTAssertEqual(session.unpricedQuantity, unpriced)
        }
    }

    func testUndoRejectsEditedDataOrderQuantityAndOfferOverrides() async throws {
        for change in ["data", "date", "quantity", "override"] {
            let container = try store(), context = container.mainContext
            let (session, list) = try batch(context)
            let undo = try add(card("p:100", price: 10), session: session, list: list, context: context)
            let item = try XCTUnwrap(list.cards.first)
            switch change {
            case "data": var edited = item.snapshot; edited.identity.condition = "Damaged"; try item.update(edited)
            case "date": item.addedAt = item.addedAt.addingTimeInterval(1)
            case "quantity": item.quantity = 2
            default: item.cashOverrideText = "80"
            }
            try context.save()
            let data = item.data, quantity = item.quantity, date = item.addedAt, override = item.cashOverrideText
            XCTAssertFalse(SessionService.canUndoScannerAdd(undo, session: session, list: list), change)
            XCTAssertThrowsError(try SessionService.undoScannerAdd(undo, session: session, list: list, context: context), change)
            XCTAssertEqual(item.data, data); XCTAssertEqual(item.quantity, quantity); XCTAssertEqual(item.addedAt, date)
            XCTAssertEqual(item.cashOverrideText, override); XCTAssertEqual(session.addedQuantity, 1)
        }
    }

    func testUndoNeverRemovesALegacyMergedQuantity() async throws {
        let container = try store(), context = container.mainContext
        let (session, list) = try batch(context)
        let legacy = try InventoryCard(card: card("p:100", price: 10), quantity: 4)
        context.insert(legacy); list.cards.append(legacy); session.record(legacy.snapshot); try context.save()
        let receipt = ScannerAddReceipt(item: legacy, session: session, list: list, previousRecognitionRef: nil)
        XCTAssertFalse(SessionService.canUndoScannerAdd(receipt, session: session, list: list))
        XCTAssertThrowsError(try SessionService.undoScannerAdd(receipt, session: session, list: list, context: context))
        XCTAssertEqual(list.quantity, 4); XCTAssertEqual(list.cards.first?.id, legacy.id)
    }

    func testUndoRejectsWrongListSessionInactiveSessionAndDeletedTarget() async throws {
        let container = try store(), context = container.mainContext
        let (session, list) = try batch(context)
        let receipt = try add(card("p:100", price: 10), session: session, list: list, context: context)
        let otherList = CardList(name: "Other"), otherSession = ScanSession(listName: "Other")
        otherSession.listID = list.id; otherSession.game = "Pokémon"; otherSession.statusRaw = "active"
        context.insert(otherList); context.insert(otherSession); try context.save()
        XCTAssertThrowsError(try SessionService.undoScannerAdd(receipt, session: session, list: otherList, context: context))
        XCTAssertThrowsError(try SessionService.undoScannerAdd(receipt, session: otherSession, list: list, context: context))
        session.statusRaw = "completed"; try context.save()
        XCTAssertThrowsError(try SessionService.undoScannerAdd(receipt, session: session, list: list, context: context))
        session.statusRaw = "active"; context.delete(try XCTUnwrap(list.cards.first)); try context.save()
        XCTAssertThrowsError(try SessionService.undoScannerAdd(receipt, session: session, list: list, context: context))
        XCTAssertEqual(session.addedQuantity, 1); XCTAssertEqual(try context.fetchCount(FetchDescriptor<CardList>()), 2)
    }

    func testStagedSaveFailureRestoresTheRowAndCountersThenRetryPreservesPendingOtherList() async throws {
        let container = try store(), context = container.mainContext
        let (session, list) = try batch(context)
        try add(card("p:100", price: 10), session: session, list: list, context: context)
        let receipt = try add(card("p:200", price: nil), session: session, list: list, context: context)
        try SessionService.saveOffer(session, list: list, context: context, customCashOffer: 8)
        let offers = session.savedOffersData, order = list.orderedCards.map(\.id), dates = list.orderedCards.map(\.addedAt)
        let other = CardList(name: "Preserve this pending list"); context.insert(other)
        let otherID = other.id
        var attempts = 0
        XCTAssertThrowsError(try SessionService.undoScannerAdd(receipt, session: session, list: list, context: context, save: { staged in
            attempts += 1
            staged.processPendingChanges()
            XCTAssertEqual(list.quantity, 1); XCTAssertEqual(session.addedQuantity, 1)
            throw InjectedFailure.saveRefused
        }))
        XCTAssertEqual(attempts, 1); XCTAssertEqual(list.orderedCards.map(\.id), order)
        XCTAssertEqual(list.orderedCards.map(\.addedAt), dates); XCTAssertTrue(list.cards.allSatisfy { $0.list?.id == list.id })
        XCTAssertEqual(session.addedQuantity, 2); XCTAssertEqual(session.knownValue, 10); XCTAssertEqual(session.unpricedQuantity, 1)
        XCTAssertEqual(session.savedOffersData, offers); XCTAssertEqual(session.lastConsumedRecognitionRef, receipt.consumedRecognitionRef)
        XCTAssertTrue(try context.fetch(FetchDescriptor<CardList>()).contains { $0.id == otherID })
        XCTAssertTrue(SessionService.canUndoScannerAdd(receipt, session: session, list: list))
        try SessionService.undoScannerAdd(receipt, session: session, list: list, context: context)
        XCTAssertEqual(list.quantity, 1); XCTAssertEqual(session.addedQuantity, 1); XCTAssertEqual(session.unpricedQuantity, 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<InventoryCard>()), 1)
        XCTAssertTrue(try context.fetch(FetchDescriptor<CardList>()).contains { $0.id == otherID })
        XCTAssertEqual(session.savedOffersData, offers)
    }

    func testUndoPersistsAcrossReopeningAndKeepsLegacyQuantitiesOrderAndOffers() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("scanner-undo.store")
        func write() throws -> (UUID, UUID, [UUID], [Date], Data?) {
            let container = try AppPersistence.open(url: url), context = container.mainContext
            let (session, list) = try batch(context)
            let legacy = try InventoryCard(card: card("p:50", price: 1), quantity: 4)
            context.insert(legacy); list.cards.append(legacy); try context.save()
            try add(card("p:100", price: Decimal(string: "12.50")), session: session, list: list, context: context)
            try add(card("p:200", price: Decimal(string: "1.75")), session: session, list: list, context: context)
            let keptIDs = list.orderedCards.map(\.id), keptDates = list.orderedCards.map(\.addedAt)
            let receipt = try add(card("p:100", price: Decimal(string: "12.50")), session: session, list: list, context: context)
            try SessionService.saveOffer(session, list: list, context: context, customCashOffer: 20)
            let offers = session.savedOffersData
            try SessionService.undoScannerAdd(receipt, session: session, list: list, context: context)
            return (list.id, session.id, keptIDs, keptDates, offers)
        }
        let expected = try write()
        let reopened = try AppPersistence.open(url: url), context = reopened.mainContext
        let list = try XCTUnwrap(context.fetch(FetchDescriptor<CardList>()).first { $0.id == expected.0 })
        let session = try XCTUnwrap(context.fetch(FetchDescriptor<ScanSession>()).first { $0.id == expected.1 })
        XCTAssertEqual(list.orderedCards.map(\.id), expected.2); XCTAssertEqual(list.orderedCards.map(\.addedAt), expected.3)
        XCTAssertEqual(list.orderedCards.map(\.quantity), [4, 1, 1])
        XCTAssertEqual(list.orderedCards.map { $0.snapshot.identity.productID }, ["p:50", "p:100", "p:200"])
        XCTAssertEqual(list.quantity, 6); XCTAssertEqual(session.addedQuantity, 2)
        XCTAssertEqual(session.knownValue, Decimal(string: "14.25")); XCTAssertEqual(session.savedOffersData, expected.4)
        XCTAssertEqual(try session.savedOffers().first?.lines.count, 4)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<InventoryCard>()), 3)
    }
}
